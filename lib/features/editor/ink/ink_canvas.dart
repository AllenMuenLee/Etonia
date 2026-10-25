import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../shared/feedback/app_haptics.dart';
import '../document_io/document_models.dart';
import 'eraser_settings.dart';
import 'ink_controller.dart';
import 'ink_painter.dart';
import 'ink_sample.dart';
import 'native_ink_bridge.dart';
import 'notation_playback_layer.dart';
import 'pen_settings.dart';
import 'scribble_erase.dart';
import 'shape_config.dart';
import 'shape_recognizer.dart';
import 'ink_selection.dart';
import 'pointer_claims.dart';
import 'ruler.dart';
import 'ruler_gesture.dart';
import 'ruler_layer.dart';
import 'selection_transform.dart';
import 'stroke.dart';
import '../sticky/sticky_note.dart';
import '../audio/stroke_replay_controller.dart';

/// Coordinates cross-page lasso selection and smooth cross-page selection
/// transforms across all mounted [InkCanvas]es of a note.
class SelectionCarry extends ChangeNotifier {
  final Set<_InkCanvasState> _canvases = <_InkCanvasState>{};

  /// Groups of strokes across pages that represent the same logical stroke
  /// straddling a page boundary.
  final List<Set<Stroke>> _linkedStrokes = <Set<Stroke>>[];

  int? _activePointer;
  _InkCanvasState? _pointerOrigin;
  _InkCanvasState? _lassoOrigin;
  List<_InkCanvasState> _transformCanvases = const <_InkCanvasState>[];
  bool _updating = false;

  void _attach(_InkCanvasState canvas) {
    if (_canvases.add(canvas)) {
      canvas.widget.controller.selectionListenable.addListener(
        _onCanvasSelectionChanged,
      );
    }
  }

  void _detach(_InkCanvasState canvas) {
    if (!_canvases.remove(canvas)) {
      return;
    }
    canvas.widget.controller.selectionListenable.removeListener(
      _onCanvasSelectionChanged,
    );
    if (identical(_pointerOrigin, canvas) ||
        identical(_lassoOrigin, canvas) ||
        _transformCanvases.contains(canvas)) {
      finalizeSelectionGesture();
    }
  }

  void _onCanvasSelectionChanged() {
    if (!_updating) {
      notifyListeners();
    }
  }

  bool _ownsPointer(int pointer, _InkCanvasState origin) {
    return _activePointer == pointer && identical(_pointerOrigin, origin);
  }

  /// Whether any attached canvas currently has an active lasso or transform.
  bool get isGestureActive {
    if (_activePointer != null) {
      return true;
    }
    for (final _InkCanvasState canvas in _canvases) {
      if (!canvas.mounted) continue;
      final InkController controller = canvas.widget.controller;
      if (controller.activeLasso != null ||
          controller.activeTransform != null) {
        return true;
      }
    }
    return false;
  }

  /// Whether [a] and [b] currently share a cross-page selection or gesture.
  bool sharesSelection(InkController a, InkController b) {
    if (identical(a, b)) {
      return true;
    }
    final bool aSelected =
        a.selection != null ||
        a.activeTransform != null ||
        a.activeLasso != null;
    final bool bSelected =
        b.selection != null ||
        b.activeTransform != null ||
        b.activeLasso != null;
    return aSelected && bSelected;
  }

  /// Deselects everything across all attached pages, except [except] when
  /// given.
  void clearSelection({InkController? except}) {
    if (except == null ||
        !identical(_pointerOrigin?.widget.controller, except)) {
      finalizeSelectionGesture();
    }
    _updating = true;
    try {
      for (final _InkCanvasState canvas in List<_InkCanvasState>.of(
        _canvases,
      )) {
        if (canvas.mounted && !identical(canvas.widget.controller, except)) {
          canvas.widget.controller.clearSelection();
        }
      }
    } finally {
      _updating = false;
    }
    notifyListeners();
  }

  /// Cancels the selection gesture owned by [pointer], if any.
  void cancelPointer(int pointer) {
    if (_activePointer != pointer) {
      return;
    }
    final _InkCanvasState? origin = _pointerOrigin;
    if (origin != null) {
      _cancelSelectionGesture(origin, pointer);
    }
  }

  /// Ends any lasso or transform in progress across attached pages.
  void finalizeSelectionGesture() {
    final int? pointer = _activePointer;
    final _InkCanvasState? origin = _pointerOrigin;
    if (pointer == null || origin == null) {
      return;
    }
    if (_lassoOrigin != null) {
      _lassoOrigin!.widget.controller.cancelLasso(pointer);
      _activePointer = null;
      _pointerOrigin = null;
      _lassoOrigin = null;
      notifyListeners();
      return;
    }
    if (_transformCanvases.isNotEmpty) {
      _commitCrossPageTransform(origin, null);
    }
  }

  /// The topmost canvas under [global], if any, as hit testing finds it:
  /// what covers a page, or clips it out of view, hides it.
  _InkCanvasState? _canvasAt(Offset global, int viewId) {
    final HitTestResult result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, global, viewId);
    for (final HitTestEntry entry in result.path) {
      for (final _InkCanvasState canvas in _canvases) {
        if (canvas.mounted &&
            identical(canvas.context.findRenderObject(), entry.target)) {
          return canvas;
        }
      }
    }
    return null;
  }

  List<_InkCanvasState> _orderedCanvases() {
    final List<(_InkCanvasState, double)> mounted =
        <(_InkCanvasState, double)>[];
    for (final _InkCanvasState canvas in _canvases) {
      if (!canvas.mounted) continue;
      final RenderObject? box = canvas.context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final Offset topLeft = box.localToGlobal(Offset.zero);
      mounted.add((canvas, topLeft.dy));
    }
    mounted.sort((a, b) => a.$2.compareTo(b.$2));
    return <_InkCanvasState>[for (final entry in mounted) entry.$1];
  }

  _InkCanvasState? _canvasFor(InkController controller) {
    for (final _InkCanvasState canvas in _canvases) {
      if (canvas.mounted && identical(canvas.widget.controller, controller)) {
        return canvas;
      }
    }
    return null;
  }

  bool get isGesturing => _activePointer != null;

  /// Affine similarity transform mapping [from]'s local coordinates to [to]'s
  /// local coordinates.
  InkTransform? _transformBetween(_InkCanvasState from, _InkCanvasState to) {
    if (identical(from, to)) {
      return InkTransform.identity;
    }
    if (!from.mounted || !to.mounted) {
      return null;
    }
    final RenderObject? fromObj = from.context.findRenderObject();
    final RenderObject? toObj = to.context.findRenderObject();
    if (fromObj is! RenderBox ||
        !fromObj.attached ||
        !fromObj.hasSize ||
        toObj is! RenderBox ||
        !toObj.attached ||
        !toObj.hasSize) {
      return null;
    }
    final Offset originGlobal = fromObj.localToGlobal(Offset.zero);
    final Offset unitXGlobal = fromObj.localToGlobal(const Offset(1, 0));
    final Offset originInTo = toObj.globalToLocal(originGlobal);
    final Offset unitXInTo = toObj.globalToLocal(unitXGlobal);
    final Offset basis = unitXInTo - originInTo;
    final double scale = basis.distance;
    if (!originInTo.isFinite || !basis.isFinite || scale <= 0) {
      return null;
    }
    if ((basis.dx - 1).abs() <= 1e-9 && basis.dy.abs() <= 1e-9) {
      return InkTransform.translation(InkVector(originInTo.dx, originInTo.dy));
    }
    return InkTransform(
      basis.dx,
      basis.dy,
      originInTo.dx,
      originInTo.dy,
      scale,
    );
  }

  /// Composes [outer] after [inner]: `outer.apply(inner.apply(p))`.
  static InkTransform _compose(InkTransform outer, InkTransform inner) {
    if (outer.isIdentity) return inner;
    if (inner.isIdentity) return outer;
    final InkVector translated = outer.apply(InkVector(inner.tx, inner.ty));
    return InkTransform(
      outer.a * inner.a - outer.b * inner.b,
      outer.a * inner.b + outer.b * inner.a,
      translated.x,
      translated.y,
      outer.scale * inner.scale,
    );
  }

  static Stroke _transformStroke(Stroke stroke, InkTransform transform) {
    if (transform.isIdentity) {
      return stroke;
    }
    final double scale = transform.scale;
    return Stroke.fromPoints(
      style: (scale - 1).abs() <= 1e-9
          ? stroke.style
          : stroke.style.withWidth(stroke.style.width * scale),
      points: stroke.points.map(transform.apply).toList(),
      widths: stroke.widths,
    );
  }

  void _pruneLinkedStrokes() {
    if (_linkedStrokes.isEmpty) {
      return;
    }
    final Set<Stroke> alive = HashSet<Stroke>.identity();
    for (final _InkCanvasState canvas in _canvases) {
      if (!canvas.mounted) continue;
      alive.addAll(canvas.widget.controller.strokes);
    }
    _linkedStrokes.removeWhere((Set<Stroke> group) {
      group.removeWhere((Stroke s) => !alive.contains(s));
      return group.length < 2;
    });
  }

  Set<Stroke>? _groupOf(Stroke stroke) {
    for (final Set<Stroke> group in _linkedStrokes) {
      if (group.contains(stroke)) {
        return group;
      }
    }
    return null;
  }

  void _linkStrokes(Iterable<Stroke> strokes) {
    final Set<Stroke> group = LinkedHashSet<Stroke>.identity()..addAll(strokes);
    if (group.length >= 2) {
      _linkedStrokes.add(group);
    }
  }

  void _syncLinkedSelection(List<_InkCanvasState> canvases) {
    _pruneLinkedStrokes();
    if (_linkedStrokes.isEmpty) {
      return;
    }
    final Set<Stroke> wantedPartners = HashSet<Stroke>.identity();
    for (final _InkCanvasState canvas in canvases) {
      final InkSelection? sel = canvas.widget.controller.selection;
      if (sel == null) continue;
      for (final Stroke stroke in sel.strokes) {
        final Set<Stroke>? group = _groupOf(stroke);
        if (group != null) {
          wantedPartners.addAll(group);
        }
      }
    }
    if (wantedPartners.isEmpty) {
      return;
    }
    for (final _InkCanvasState canvas in canvases) {
      canvas.widget.controller.includeStrokesInSelection(wantedPartners);
    }
  }

  void _syncUnifiedFrames(List<_InkCanvasState> canvases) {
    final List<_InkCanvasState> selected = <_InkCanvasState>[
      for (final _InkCanvasState c in canvases)
        if (c.widget.controller.selection != null) c,
    ];
    if (selected.isEmpty) {
      return;
    }
    final _InkCanvasState ref = selected.first;
    final List<Stroke> allStrokes = <Stroke>[];
    final List<NoteImageElement> allImages = <NoteImageElement>[];
    final List<StickyNoteElement> allStickies = <StickyNoteElement>[];
    Rect? pdfBounds;
    final Set<Set<Stroke>> seenGroups = HashSet<Set<Stroke>>.identity();
    for (final _InkCanvasState c in selected) {
      final InkTransform? toRef = _transformBetween(c, ref);
      if (toRef == null) continue;
      final InkSelection sel = c.widget.controller.selection!;
      for (final Stroke s in sel.strokes) {
        final Set<Stroke>? group = _groupOf(s);
        if (group != null && !seenGroups.add(group)) {
          continue;
        }
        allStrokes.add(_transformStroke(s, toRef));
      }
      for (final NoteImageElement img in sel.images) {
        allImages.add(toRef.isIdentity ? img : img.transformed(toRef));
      }
      for (final StickyNoteElement note in sel.stickies) {
        allStickies.add(toRef.isIdentity ? note : note.transformed(toRef));
      }
      if (identical(c, ref) && sel.pdfBounds != null) {
        pdfBounds = sel.pdfBounds;
      }
    }
    if (allStrokes.isEmpty &&
        allImages.isEmpty &&
        allStickies.isEmpty &&
        pdfBounds == null) {
      return;
    }
    final SelectionFrame unifiedInRef = frameAroundContent(
      allStrokes,
      allImages,
      pdfBounds: pdfBounds,
      stickies: allStickies,
    );
    for (final _InkCanvasState c in selected) {
      final InkTransform? fromRef = _transformBetween(ref, c);
      if (fromRef != null) {
        c.widget.controller.setSelectionFrame(
          fromRef.isIdentity ? unifiedInRef : unifiedInRef.transformed(fromRef),
        );
      }
    }
  }

  bool _beginSelectionGesture(
    _InkCanvasState origin, {
    required int pointer,
    required InkVector position,
  }) {
    if (!position.isFinite || _activePointer != null) {
      return false;
    }
    final List<_InkCanvasState> canvases = _orderedCanvases();
    for (final _InkCanvasState c in canvases) {
      if (c.widget.controller.isBusy) {
        return false;
      }
    }
    final InkController originController = origin.widget.controller;
    SelectionHit? hit;
    final InkSelection? ownSelection = originController.selection;
    if (ownSelection != null && !ownSelection.includesPdf) {
      hit = ownSelection.frame.hitTest(
        position,
        handleHitRadius: originController.selectionConfig.handleHitRadius,
        rotationHandleOffset:
            originController.selectionConfig.rotationHandleOffset,
        tolerance: originController.selectionConfig.geometryTolerance,
      );
    }
    if (hit == null) {
      for (final _InkCanvasState c in canvases) {
        if (identical(c, origin)) continue;
        final InkSelection? otherSel = c.widget.controller.selection;
        if (otherSel == null || otherSel.includesPdf) continue;
        final InkTransform? toOrigin = _transformBetween(c, origin);
        if (toOrigin == null) continue;
        final SelectionFrame frameInOrigin = otherSel.frame.transformed(
          toOrigin,
        );
        hit = frameInOrigin.hitTest(
          position,
          handleHitRadius: originController.selectionConfig.handleHitRadius,
          rotationHandleOffset:
              originController.selectionConfig.rotationHandleOffset,
          tolerance: originController.selectionConfig.geometryTolerance,
        );
        if (hit != null) {
          break;
        }
      }
    }
    if (hit != null) {
      return _startTransform(
        origin: origin,
        canvases: canvases,
        pointer: pointer,
        position: position,
        hit: hit,
      );
    }
    if (originController.selectStickyOrImageAt(position)) {
      _updating = true;
      try {
        for (final _InkCanvasState c in canvases) {
          if (!identical(c, origin)) {
            c.widget.controller.clearSelection();
          }
        }
      } finally {
        _updating = false;
      }
      return _startTransform(
        origin: origin,
        canvases: <_InkCanvasState>[origin],
        pointer: pointer,
        position: position,
        hit: const SelectionHit.move(),
      );
    }
    if (!originController.beginLasso(pointer: pointer, position: position)) {
      return false;
    }
    _activePointer = pointer;
    _pointerOrigin = origin;
    _lassoOrigin = origin;
    notifyListeners();
    return true;
  }

  bool _startTransform({
    required _InkCanvasState origin,
    required List<_InkCanvasState> canvases,
    required int pointer,
    required InkVector position,
    required SelectionHit hit,
  }) {
    final List<_InkCanvasState> selected = <_InkCanvasState>[
      for (final _InkCanvasState c in canvases)
        if (c.widget.controller.selection != null &&
            !c.widget.controller.selection!.includesPdf)
          c,
    ];
    if (selected.isEmpty) {
      return false;
    }
    _updating = true;
    try {
      if (selected.length > 1) {
        _syncUnifiedFrames(selected);
      }
      double minScale = 0;
      double maxScale = double.infinity;
      double widest = 0;
      for (final _InkCanvasState c in selected) {
        final (double cMin, double cMax, double cWidest) = c.widget.controller
            .selectionScaleLimits();
        minScale = math.max(minScale, cMin);
        maxScale = math.min(maxScale, cMax);
        widest = math.max(widest, cWidest);
      }
      minScale = math.min(1, minScale);
      maxScale = math.max(minScale, maxScale);

      final List<_InkCanvasState> started = <_InkCanvasState>[];
      for (final _InkCanvasState c in selected) {
        final InkTransform? toC = _transformBetween(origin, c);
        if (toC == null) continue;
        if (c.widget.controller.beginTransform(
          pointer: pointer,
          position: toC.apply(position),
          hit: hit,
          minScaleOverride: minScale,
          maxScaleOverride: maxScale,
          widestStrokeOverride: widest,
        )) {
          started.add(c);
        }
      }
      if (started.isEmpty) {
        return false;
      }
      _activePointer = pointer;
      _pointerOrigin = origin;
      _lassoOrigin = null;
      _transformCanvases = started;
    } finally {
      _updating = false;
    }
    notifyListeners();
    return true;
  }

  void _updateSelectionGesture(
    _InkCanvasState origin,
    int pointer,
    InkVector position,
  ) {
    if (_activePointer != pointer || !identical(_pointerOrigin, origin)) {
      return;
    }
    _updating = true;
    try {
      if (_lassoOrigin != null) {
        _lassoOrigin!.widget.controller.updateLasso(pointer, position);
      } else if (_transformCanvases.isNotEmpty) {
        for (final _InkCanvasState c in _transformCanvases) {
          final InkTransform? toC = _transformBetween(origin, c);
          if (toC != null) {
            c.widget.controller.updateTransform(pointer, toC.apply(position));
          }
        }
      }
    } finally {
      _updating = false;
    }
    notifyListeners();
  }

  void _endSelectionGesture(
    _InkCanvasState origin,
    int pointer,
    InkVector? finalPosition,
    Offset? globalPosition,
  ) {
    if (_activePointer != pointer || !identical(_pointerOrigin, origin)) {
      return;
    }
    if (_lassoOrigin != null) {
      _endCrossPageLasso(origin, pointer, finalPosition);
      return;
    }
    if (_transformCanvases.isNotEmpty) {
      if (finalPosition != null) {
        _updateSelectionGesture(origin, pointer, finalPosition);
      }
      _commitCrossPageTransform(origin, globalPosition);
    }
  }

  void _cancelSelectionGesture(_InkCanvasState origin, int pointer) {
    if (_activePointer != pointer || !identical(_pointerOrigin, origin)) {
      return;
    }
    if (_lassoOrigin != null) {
      _lassoOrigin!.widget.controller.cancelLasso(pointer);
      _activePointer = null;
      _pointerOrigin = null;
      _lassoOrigin = null;
      notifyListeners();
      return;
    }
    if (_transformCanvases.isNotEmpty) {
      _commitCrossPageTransform(origin, null);
    }
  }

  void _endCrossPageLasso(
    _InkCanvasState origin,
    int pointer,
    InkVector? finalPosition,
  ) {
    final InkController originController = origin.widget.controller;
    final LassoGesture? lasso = originController.activeLasso;
    if (lasso == null || lasso.pointer != pointer) {
      _activePointer = null;
      _pointerOrigin = null;
      _lassoOrigin = null;
      return;
    }
    _updating = true;
    _InkCanvasState? targetToActivate;
    try {
      if (finalPosition != null) {
        originController.updateLasso(pointer, finalPosition);
      }
      final List<InkVector> outline = lasso.outline;
      originController.cancelLasso(pointer);
      _activePointer = null;
      _pointerOrigin = null;
      _lassoOrigin = null;

      final List<_InkCanvasState> canvases = _orderedCanvases();
      if (outline.isEmpty) {
        for (final _InkCanvasState c in canvases) {
          c.widget.controller.clearSelection();
        }
      } else {
        bool anyForeground = false;
        // In AI mode the paper comes with the ink; only the page the
        // lasso began on, since the chat reads the paper of one page.
        final bool keepPaper = origin.widget.aiActive?.value ?? false;
        for (final _InkCanvasState c in canvases) {
          final InkTransform? toC = _transformBetween(origin, c);
          if (toC == null) continue;
          final List<InkVector> localOutline = toC.isIdentity
              ? outline
              : <InkVector>[for (final InkVector p in outline) toC.apply(p)];
          final bool withPaper = keepPaper && identical(c, origin);
          if (c.widget.controller.selectWithOutline(
            localOutline,
            selectablePdfBounds: withPaper ? c.widget.selectablePdfBounds : null,
            keepPaper: withPaper,
          )) {
            anyForeground = true;
          }
        }
        if (!anyForeground && origin.widget.selectablePdfBounds != null) {
          originController.selectWithOutline(
            outline,
            selectablePdfBounds: origin.widget.selectablePdfBounds,
          );
        } else if (anyForeground) {
          _syncLinkedSelection(canvases);
          _syncUnifiedFrames(canvases);
          if (originController.selection == null) {
            for (final _InkCanvasState c in canvases) {
              if (c.widget.controller.selection != null) {
                targetToActivate = c;
                break;
              }
            }
          }
        }
      }
    } finally {
      _updating = false;
    }
    targetToActivate?.widget.onSelectionCarried?.call();
    notifyListeners();
  }

  static double _distanceSquaredToRect(Offset point, Rect rect) {
    final double dx = point.dx < rect.left
        ? rect.left - point.dx
        : (point.dx > rect.right ? point.dx - rect.right : 0);
    final double dy = point.dy < rect.top
        ? rect.top - point.dy
        : (point.dy > rect.bottom ? point.dy - rect.bottom : 0);
    return dx * dx + dy * dy;
  }

  void _commitCrossPageTransform(
    _InkCanvasState origin,
    Offset? globalPosition,
  ) {
    final List<_InkCanvasState> sources = _transformCanvases;
    _activePointer = null;
    _pointerOrigin = null;
    _lassoOrigin = null;
    _transformCanvases = const <_InkCanvasState>[];
    if (sources.isEmpty) {
      return;
    }
    final _InkCanvasState ref = sources.first;
    final SelectionTransformGesture? refGesture =
        ref.widget.controller.activeTransform;
    if (refGesture == null || ref.widget.controller.isActiveTransformIdentity) {
      _updating = true;
      try {
        for (final _InkCanvasState c in sources) {
          c.widget.controller.discardActiveTransform();
        }
      } finally {
        _updating = false;
      }
      notifyListeners();
      return;
    }

    final List<_InkCanvasState> allCanvases = _orderedCanvases();
    if (allCanvases.isEmpty) {
      for (final _InkCanvasState c in sources) {
        c.widget.controller.discardActiveTransform();
      }
      notifyListeners();
      return;
    }

    _pruneLinkedStrokes();
    final SelectionFrame refEndFrame = refGesture.frame;

    // Validate images and stickies before mutating any page.
    for (final _InkCanvasState c in sources) {
      final InkSelection? sel = c.widget.controller.selection;
      final SelectionTransformGesture? gesture =
          c.widget.controller.activeTransform;
      if (sel == null || gesture == null) continue;
      for (final NoteImageElement img in sel.images) {
        if (!img.transformed(gesture.transform).isValid) {
          for (final _InkCanvasState s in sources) {
            s.widget.controller.discardActiveTransform();
          }
          notifyListeners();
          return;
        }
      }
      for (final StickyNoteElement note in sel.stickies) {
        if (!note.transformed(gesture.transform).isValid) {
          for (final _InkCanvasState s in sources) {
            s.widget.controller.discardActiveTransform();
          }
          notifyListeners();
          return;
        }
      }
    }

    final Map<_InkCanvasState, Map<int, Stroke>> stayingStrokes =
        <_InkCanvasState, Map<int, Stroke>>{
          for (final _InkCanvasState c in allCanvases) c: <int, Stroke>{},
        };
    final Map<_InkCanvasState, Set<int>> leavingStrokeIndices =
        <_InkCanvasState, Set<int>>{
          for (final _InkCanvasState c in allCanvases) c: <int>{},
        };
    final Map<_InkCanvasState, List<Stroke>> arrivingStrokes =
        <_InkCanvasState, List<Stroke>>{
          for (final _InkCanvasState c in allCanvases) c: <Stroke>[],
        };
    final Map<_InkCanvasState, Set<Stroke>> arrivingHiddenStrokes =
        <_InkCanvasState, Set<Stroke>>{
          for (final _InkCanvasState c in allCanvases)
            c: HashSet<Stroke>.identity(),
        };

    final Map<_InkCanvasState, Map<int, NoteImageElement>> stayingImages =
        <_InkCanvasState, Map<int, NoteImageElement>>{
          for (final _InkCanvasState c in allCanvases)
            c: <int, NoteImageElement>{},
        };
    final Map<_InkCanvasState, Set<int>> leavingImageIndices =
        <_InkCanvasState, Set<int>>{
          for (final _InkCanvasState c in allCanvases) c: <int>{},
        };
    final Map<_InkCanvasState, List<NoteImageElement>> arrivingImages =
        <_InkCanvasState, List<NoteImageElement>>{
          for (final _InkCanvasState c in allCanvases) c: <NoteImageElement>[],
        };

    final Map<_InkCanvasState, Map<int, StickyNoteElement>> stayingStickies =
        <_InkCanvasState, Map<int, StickyNoteElement>>{
          for (final _InkCanvasState c in allCanvases)
            c: <int, StickyNoteElement>{},
        };
    final Map<_InkCanvasState, Set<int>> leavingStickyIndices =
        <_InkCanvasState, Set<int>>{
          for (final _InkCanvasState c in allCanvases) c: <int>{},
        };
    final Map<_InkCanvasState, List<StickyNoteElement>> arrivingStickies =
        <_InkCanvasState, List<StickyNoteElement>>{
          for (final _InkCanvasState c in allCanvases) c: <StickyNoteElement>[],
        };

    // Deduplicate linked straddling strokes into logical strokes.
    final Set<Set<Stroke>> processedGroups = HashSet<Set<Stroke>>.identity();
    for (final _InkCanvasState source in sources) {
      final InkSelection? sel = source.widget.controller.selection;
      final SelectionTransformGesture? gesture =
          source.widget.controller.activeTransform;
      if (sel == null || gesture == null) continue;
      final InkTransform transform = gesture.transform;

      for (int i = 0; i < sel.count; i++) {
        final Stroke stroke = sel.strokes[i];
        final Set<Stroke>? group = _groupOf(stroke);
        if (group != null && !processedGroups.add(group)) {
          continue;
        }
        // Find all (canvas, index) occurrences of this logical stroke across sources.
        final Map<_InkCanvasState, int> existingOn = <_InkCanvasState, int>{};
        if (group == null) {
          existingOn[source] = sel.indices[i];
        } else {
          for (final _InkCanvasState other in sources) {
            final InkSelection? otherSel = other.widget.controller.selection;
            if (otherSel == null) continue;
            for (int j = 0; j < otherSel.count; j++) {
              if (group.contains(otherSel.strokes[j])) {
                existingOn[other] = otherSel.indices[j];
                break;
              }
            }
          }
          _linkedStrokes.remove(group);
        }

        final Stroke transformedInSource = _transformStroke(stroke, transform);
        final bool isHidden = source.widget.controller.isStrokeHidden(stroke);

        final Map<_InkCanvasState, Stroke> overlapping =
            <_InkCanvasState, Stroke>{};
        _InkCanvasState? nearestCanvas;
        Stroke? nearestStroke;
        double nearestDistSq = double.infinity;

        for (final _InkCanvasState page in allCanvases) {
          final InkTransform? toPage = _transformBetween(source, page);
          if (toPage == null) continue;
          final Stroke inPage = _transformStroke(transformedInSource, toPage);
          final Rect pageRect = Offset.zero & page._pageSize;
          if (inPage.bounds.overlaps(pageRect)) {
            overlapping[page] = inPage;
          }
          final double distSq = _distanceSquaredToRect(
            inPage.bounds.center,
            pageRect,
          );
          if (distSq < nearestDistSq) {
            nearestDistSq = distSq;
            nearestCanvas = page;
            nearestStroke = inPage;
          }
        }
        if (overlapping.isEmpty &&
            nearestCanvas != null &&
            nearestStroke != null) {
          overlapping[nearestCanvas] = nearestStroke;
        }

        for (final MapEntry<_InkCanvasState, Stroke> entry
            in overlapping.entries) {
          final _InkCanvasState targetPage = entry.key;
          final Stroke targetStroke = entry.value;
          final int? existingIndex = existingOn[targetPage];
          if (existingIndex != null) {
            stayingStrokes[targetPage]![existingIndex] = targetStroke;
          } else {
            arrivingStrokes[targetPage]!.add(targetStroke);
            if (isHidden) {
              arrivingHiddenStrokes[targetPage]!.add(targetStroke);
            }
          }
        }
        for (final MapEntry<_InkCanvasState, int> oldEntry
            in existingOn.entries) {
          if (!overlapping.containsKey(oldEntry.key)) {
            leavingStrokeIndices[oldEntry.key]!.add(oldEntry.value);
          }
        }
        if (overlapping.length >= 2) {
          _linkStrokes(overlapping.values);
        }
      }

      for (int i = 0; i < sel.imageCount; i++) {
        final NoteImageElement transformedInSource = sel.images[i].transformed(
          transform,
        );
        _InkCanvasState targetPage = source;
        NoteImageElement targetImage = transformedInSource;
        double bestDistSq = double.infinity;
        for (final _InkCanvasState page in allCanvases) {
          final InkTransform? toPage = _transformBetween(source, page);
          if (toPage == null) continue;
          final NoteImageElement inPage = toPage.isIdentity
              ? transformedInSource
              : transformedInSource.transformed(toPage);
          final Rect pageRect = Offset.zero & page._pageSize;
          final double distSq = _distanceSquaredToRect(
            Offset(inPage.center.x, inPage.center.y),
            pageRect,
          );
          if (distSq < bestDistSq) {
            bestDistSq = distSq;
            targetPage = page;
            targetImage = inPage;
          }
        }
        final int oldIndex = sel.imageIndices[i];
        if (identical(targetPage, source)) {
          stayingImages[source]![oldIndex] = targetImage;
        } else {
          leavingImageIndices[source]!.add(oldIndex);
          arrivingImages[targetPage]!.add(targetImage);
        }
      }

      for (int i = 0; i < sel.stickyCount; i++) {
        final StickyNoteElement transformedInSource = sel.stickies[i]
            .transformed(transform);
        _InkCanvasState targetPage = source;
        StickyNoteElement targetSticky = transformedInSource;
        double bestDistSq = double.infinity;
        for (final _InkCanvasState page in allCanvases) {
          final InkTransform? toPage = _transformBetween(source, page);
          if (toPage == null) continue;
          final StickyNoteElement inPage = toPage.isIdentity
              ? transformedInSource
              : transformedInSource.transformed(toPage);
          final Rect pageRect = Offset.zero & page._pageSize;
          final double distSq = _distanceSquaredToRect(
            Offset(inPage.center.x, inPage.center.y),
            pageRect,
          );
          if (distSq < bestDistSq) {
            bestDistSq = distSq;
            targetPage = page;
            targetSticky = inPage;
          }
        }
        final int oldIndex = sel.stickyIndices[i];
        if (identical(targetPage, source)) {
          stayingStickies[source]![oldIndex] = targetSticky;
        } else {
          leavingStickyIndices[source]!.add(oldIndex);
          arrivingStickies[targetPage]!.add(targetSticky);
        }
      }
    }

    final List<_InkCanvasState> resultingCanvases = <_InkCanvasState>[];
    _updating = true;
    try {
      for (final _InkCanvasState page in allCanvases) {
        final Map<int, Stroke> sStrokes = stayingStrokes[page]!;
        final Set<int> lStrokes = leavingStrokeIndices[page]!;
        final List<Stroke> aStrokes = arrivingStrokes[page]!;
        final Map<int, NoteImageElement> sImages = stayingImages[page]!;
        final Set<int> lImages = leavingImageIndices[page]!;
        final List<NoteImageElement> aImages = arrivingImages[page]!;
        final Map<int, StickyNoteElement> sStickies = stayingStickies[page]!;
        final Set<int> lStickies = leavingStickyIndices[page]!;
        final List<StickyNoteElement> aStickies = arrivingStickies[page]!;
        final bool wasSource = sources.contains(page);
        final bool hasChanges =
            sStrokes.isNotEmpty ||
            lStrokes.isNotEmpty ||
            aStrokes.isNotEmpty ||
            sImages.isNotEmpty ||
            lImages.isNotEmpty ||
            aImages.isNotEmpty ||
            sStickies.isNotEmpty ||
            lStickies.isNotEmpty ||
            aStickies.isNotEmpty;
        if (!wasSource && !hasChanges) {
          continue;
        }
        final InkTransform? fromRef = _transformBetween(ref, page);
        final SelectionFrame? frameInPage = fromRef == null
            ? null
            : (fromRef.isIdentity
                  ? refEndFrame
                  : refEndFrame.transformed(fromRef));
        page.widget.controller.commitCrossPageTransform(
          stayingStrokes: sStrokes,
          leavingStrokeIndices: lStrokes,
          arrivingStrokes: aStrokes,
          arrivingHiddenStrokes: arrivingHiddenStrokes[page]!,
          stayingImages: sImages,
          leavingImageIndices: lImages,
          arrivingImages: aImages,
          stayingStickies: sStickies,
          leavingStickyIndices: lStickies,
          arrivingStickies: aStickies,
          selectionFrame: frameInPage,
        );
        if (page.widget.controller.selection != null) {
          resultingCanvases.add(page);
        }
      }
    } finally {
      _updating = false;
    }

    if (resultingCanvases.isNotEmpty) {
      _InkCanvasState? targetToActivate;
      if (globalPosition != null && origin.mounted) {
        final _InkCanvasState? hovered = _canvasAt(
          globalPosition,
          View.of(origin.context).viewId,
        );
        if (hovered != null && resultingCanvases.contains(hovered)) {
          targetToActivate = hovered;
        }
      }
      if (targetToActivate == null && !resultingCanvases.contains(origin)) {
        targetToActivate = resultingCanvases.first;
      }
      if (targetToActivate != null && !identical(targetToActivate, origin)) {
        targetToActivate.widget.onSelectionCarried?.call();
      }
    }
    notifyListeners();
  }

  /// Supplies the cross-page selection and lasso overlay for [target].
  CrossPageSelectionOverlay? _overlayFor(_InkCanvasState target) {
    if (!target.mounted) {
      return null;
    }
    final List<CrossPageSelectionPart> parts = <CrossPageSelectionPart>[];
    SelectionFrame? foreignFrame;
    bool includesPdf = false;
    List<Offset>? lassoLine;

    final Set<Set<Stroke>> coveredGroups = HashSet<Set<Stroke>>.identity();
    final InkSelection? ownSelection = target.widget.controller.selection;
    if (ownSelection != null) {
      for (final Stroke stroke in ownSelection.strokes) {
        final Set<Stroke>? group = _groupOf(stroke);
        if (group != null) {
          coveredGroups.add(group);
        }
      }
    }

    for (final _InkCanvasState other in _canvases) {
      if (identical(other, target) || !other.mounted) {
        continue;
      }
      final InkController otherController = other.widget.controller;
      final InkSelection? otherSelection = otherController.selection;
      if (otherSelection != null) {
        final InkTransform? toTarget = _transformBetween(other, target);
        if (toTarget != null) {
          final SelectionTransformGesture? otherGesture =
              otherController.activeTransform;
          final InkTransform combined = otherGesture == null
              ? toTarget
              : _compose(toTarget, otherGesture.transform);
          final List<Stroke> strokes = <Stroke>[];
          for (final Stroke stroke in otherSelection.strokes) {
            if (otherController.isStrokeHidden(stroke)) {
              continue;
            }
            final Set<Stroke>? group = _groupOf(stroke);
            if (group != null && !coveredGroups.add(group)) {
              continue;
            }
            strokes.add(stroke);
          }
          if (strokes.isNotEmpty || otherSelection.stickies.isNotEmpty) {
            parts.add(
              CrossPageSelectionPart(
                transform: combined,
                strokes: strokes,
                stickies: otherSelection.stickies,
              ),
            );
          }
          if (ownSelection == null && foreignFrame == null) {
            final SelectionFrame sourceFrame =
                otherGesture?.frame ?? otherSelection.frame;
            foreignFrame = toTarget.isIdentity
                ? sourceFrame
                : sourceFrame.transformed(toTarget);
            includesPdf = otherSelection.includesPdf;
          }
        }
      }
      final LassoGesture? otherLasso = otherController.activeLasso;
      if (otherLasso != null && lassoLine == null) {
        final InkTransform? toTarget = _transformBetween(other, target);
        if (toTarget != null) {
          switch (otherLasso.shape) {
            case LassoShape.rectangle:
              final List<InkVector> corners = otherLasso.outline;
              lassoLine = <Offset>[
                for (final InkVector c in corners)
                  Offset(toTarget.apply(c).x, toTarget.apply(c).y),
                Offset(
                  toTarget.apply(corners.first).x,
                  toTarget.apply(corners.first).y,
                ),
              ];
            case LassoShape.freeform:
              lassoLine = <Offset>[
                for (final InkVector p in otherLasso.points)
                  Offset(toTarget.apply(p).x, toTarget.apply(p).y),
                Offset(
                  toTarget.apply(otherLasso.tip).x,
                  toTarget.apply(otherLasso.tip).y,
                ),
              ];
          }
        }
      }
    }

    if (parts.isEmpty && foreignFrame == null && lassoLine == null) {
      return null;
    }
    return CrossPageSelectionOverlay(
      parts: parts,
      frame: foreignFrame,
      includesPdf: includesPdf,
      lassoLine: lassoLine,
    );
  }

  /// Selected images from other pages mapped into [targetController]'s
  /// coordinate space.
  List<NoteImageElement> foreignImagesFor(InkController targetController) {
    final _InkCanvasState? target = _canvasFor(targetController);
    if (target == null) {
      return const <NoteImageElement>[];
    }
    final List<NoteImageElement> result = <NoteImageElement>[];
    for (final _InkCanvasState other in _canvases) {
      if (identical(other, target) || !other.mounted) continue;
      final InkSelection? sel = other.widget.controller.selection;
      if (sel == null || sel.images.isEmpty) continue;
      final InkTransform? toTarget = _transformBetween(other, target);
      if (toTarget == null) continue;
      final SelectionTransformGesture? gesture =
          other.widget.controller.activeTransform;
      final InkTransform combined = gesture == null
          ? toTarget
          : _compose(toTarget, gesture.transform);
      for (final NoteImageElement img in sel.images) {
        final NoteImageElement transformed = combined.isIdentity
            ? img
            : img.transformed(combined);
        if (transformed.isValid) {
          result.add(transformed);
        }
      }
    }
    return result;
  }

  /// Combines all active page selections into [primary]'s coordinates,
  /// deduplicating straddling strokes so actions see the logical selection.
  InkSelection? combinedSelectionFor(InkController primary) {
    if (isGestureActive) {
      return null;
    }
    final _InkCanvasState? primaryCanvas = _canvasFor(primary);
    if (primaryCanvas == null) {
      return primary.selection;
    }
    final List<_InkCanvasState> selectedCanvases = <_InkCanvasState>[
      for (final _InkCanvasState c in _orderedCanvases())
        if (c.widget.controller.selection != null) c,
    ];
    if (selectedCanvases.isEmpty) {
      return null;
    }
    if (selectedCanvases.length == 1 &&
        identical(selectedCanvases.single, primaryCanvas)) {
      return primary.selection;
    }
    _pruneLinkedStrokes();
    final List<Stroke> strokes = <Stroke>[];
    final List<NoteImageElement> images = <NoteImageElement>[];
    final List<StickyNoteElement> stickies = <StickyNoteElement>[];
    final Rect? pdfBounds = primary.selection?.pdfBounds;
    SelectionFrame? frame = primary.selection?.frame;
    final Set<Set<Stroke>> seenGroups = HashSet<Set<Stroke>>.identity();

    for (final _InkCanvasState c in selectedCanvases) {
      final InkTransform? toPrimary = _transformBetween(c, primaryCanvas);
      if (toPrimary == null) continue;
      final InkSelection sel = c.widget.controller.selection!;
      for (final Stroke s in sel.strokes) {
        final Set<Stroke>? group = _groupOf(s);
        if (group != null && !seenGroups.add(group)) {
          continue;
        }
        strokes.add(_transformStroke(s, toPrimary));
      }
      for (final NoteImageElement img in sel.images) {
        images.add(toPrimary.isIdentity ? img : img.transformed(toPrimary));
      }
      for (final StickyNoteElement note in sel.stickies) {
        stickies.add(toPrimary.isIdentity ? note : note.transformed(toPrimary));
      }
      frame ??= toPrimary.isIdentity
          ? sel.frame
          : sel.frame.transformed(toPrimary);
    }
    if (strokes.isEmpty &&
        images.isEmpty &&
        stickies.isEmpty &&
        pdfBounds == null) {
      return null;
    }
    return InkSelection(
      indices: <int>[for (int i = 0; i < strokes.length; i++) i],
      strokes: strokes,
      imageIndices: <int>[for (int i = 0; i < images.length; i++) i],
      images: images,
      stickyIndices: <int>[for (int i = 0; i < stickies.length; i++) i],
      stickies: stickies,
      pdfBounds: pdfBounds,
      frame:
          frame ??
          frameAroundContent(
            strokes,
            images,
            pdfBounds: pdfBounds,
            stickies: stickies,
          ),
    );
  }

  /// Copies the combined cross-page selection onto [primary]'s clipboard and
  /// shares it with the note's other pages.
  bool copySelection(InkController primary) {
    finalizeSelectionGesture();
    final InkSelection? combined = combinedSelectionFor(primary);
    if (combined == null) {
      return primary.copySelection();
    }
    if (!primary.copyCombinedSelection(combined)) {
      return false;
    }
    for (final _InkCanvasState c in _canvases) {
      if (c.mounted && !identical(c.widget.controller, primary)) {
        c.widget.controller.takeClipboardFrom(primary);
      }
    }
    return true;
  }

  /// Cuts the combined cross-page selection onto [primary]'s clipboard and
  /// removes the selected items from all participating pages.
  bool cutSelection(InkController primary) {
    finalizeSelectionGesture();
    final InkSelection? combined = combinedSelectionFor(primary);
    if (combined == null) {
      return primary.cutSelection();
    }
    if (!primary.copyCombinedSelection(combined)) {
      return false;
    }
    _updating = true;
    try {
      for (final _InkCanvasState c in _orderedCanvases()) {
        if (c.widget.controller.selection != null) {
          c.widget.controller.deleteSelection();
        }
      }
      for (final _InkCanvasState c in _canvases) {
        if (c.mounted && !identical(c.widget.controller, primary)) {
          c.widget.controller.takeClipboardFrom(primary);
        }
      }
    } finally {
      _updating = false;
    }
    notifyListeners();
    return true;
  }

  /// Deletes the selected items across all participating pages.
  bool deleteSelection(InkController primary) {
    finalizeSelectionGesture();
    bool deleted = false;
    _updating = true;
    try {
      for (final _InkCanvasState c in _orderedCanvases()) {
        if (c.widget.controller.selection != null) {
          if (c.widget.controller.deleteSelection()) {
            deleted = true;
          }
        }
      }
    } finally {
      _updating = false;
    }
    if (!deleted) {
      return primary.deleteSelection();
    }
    notifyListeners();
    return true;
  }

  /// Duplicates the selected items across all participating pages and keeps
  /// the copies selected under a unified frame.
  bool duplicateSelection(InkController primary) {
    finalizeSelectionGesture();
    final List<_InkCanvasState> selectedCanvases = <_InkCanvasState>[
      for (final _InkCanvasState c in _orderedCanvases())
        if (c.widget.controller.selection != null &&
            !c.widget.controller.selection!.includesPdf)
          c,
    ];
    if (selectedCanvases.isEmpty) {
      return primary.duplicateSelection();
    }
    bool duplicated = false;
    _updating = true;
    try {
      for (final _InkCanvasState c in selectedCanvases) {
        if (c.widget.controller.duplicateSelection()) {
          duplicated = true;
        }
      }
      if (duplicated && selectedCanvases.length > 1) {
        _syncUnifiedFrames(selectedCanvases);
      }
    } finally {
      _updating = false;
    }
    if (duplicated) {
      notifyListeners();
    }
    return duplicated;
  }
}

/// The drawable area. Captures raw pointer events, feeds them to
/// [controller], and paints the result clipped to its own bounds.
///
/// Only one pointer writes, erases, or selects at a time; others are ignored
/// while a gesture is active. That keeps a resting palm from corrupting the
/// stroke, but it is not platform palm rejection, which remains future work.
///
/// Holding the pen still at the end of a stroke, for
/// [ShapeConfig.holdDuration] within [ShapeConfig.holdSlop], converts the
/// stroke into the shape it was meant to be, if one is recognized. Until
/// the pen lifts, moving it then scales and turns the shape.
///
/// A pen stroke scribbled back and forth over ink erases that ink, and is
/// not kept, when [PenSettings.scribbleToErase] is on.
class InkCanvas extends StatefulWidget {
  const InkCanvas({
    super.key,
    required this.controller,
    required this.tool,
    required this.penSettings,
    required this.eraserSettings,
    this.penConfig = const PenConfig(),
    this.eraserConfig = const EraserConfig(),
    this.shapeConfig = const ShapeConfig(),
    this.scribbleConfig = const ScribbleConfig(),
    this.isInputBlocked,
    this.pastePrompt,
    this.stylusOnly,
    this.selectablePdfBounds,
    this.stickySettings,
    this.onStickyPlaced,
    this.pageGrows = false,
    this.carry,
    this.onSelectionCarried,
    this.visible,
    this.enableNativeInk = true,
    this.exclusionRects,
    this.exclusionsChanged,
    this.replay,
    this.onReplayStrokeTapped,
    this.ruler,
    this.pointerClaims,
    this.aiActive,
  });

  /// Whether AI mode is on. A lasso then selects the PDF paper and pictures
  /// it encloses together with the ink, since the assistant needs the page
  /// behind the ink to read it.
  final ValueListenable<bool>? aiActive;

  /// Shared with the note's other pages, so that a selection moved onto one
  /// of them goes there. Without it a selection stays on its page.
  final SelectionCarry? carry;

  /// Called once a selection moved from another page has arrived on this
  /// one, still being moved.
  final VoidCallback? onSelectionCarried;

  /// The look the Sticky note tool gives a new note.
  final ValueListenable<StickyNoteSettings>? stickySettings;

  /// Called once a sticky note has been placed, so the writing tool can
  /// come back for writing on it.
  final VoidCallback? onStickyPlaced;

  /// Whether the page grows to the right and down, as an infinite page
  /// does, so a sticky note placed near those edges is not pushed back.
  final bool pageGrows;

  final InkController controller;

  /// The part of this page currently visible in page coordinates. When
  /// omitted (tests, snapshots and exports), every stroke is painted.
  final ValueListenable<Rect>? visible;

  /// Whether real platform stylus events use the native sampling bridge.
  /// This remains on in production; framework-driven performance tests turn
  /// it off so their synthetic stylus packets exercise the Dart pipeline.
  final bool enableNativeInk;

  /// What a pointer does. An inverted stylus erases whatever this says.
  final ValueListenable<EditorTool> tool;

  final ValueListenable<PenSettings> penSettings;
  final ValueListenable<EraserSettings> eraserSettings;

  /// Supplies the highlighter's opacity.
  final PenConfig penConfig;
  final EraserConfig eraserConfig;
  final ShapeConfig shapeConfig;

  /// When a pen stroke scribbles ink out, if the pen allows it.
  final ScribbleConfig scribbleConfig;

  /// Asked at pointer-down; returning true drops that pointer. Lets the tap
  /// that dismisses a popover pass without leaving a dot.
  final ValueGetter<bool>? isInputBlocked;

  /// Where Paste is being offered, in canvas coordinates, or null. With the
  /// Select tool and something on the clipboard, holding a pointer still on
  /// the page sets it; the next pointer on the page, or a tool change,
  /// clears it.
  final ValueNotifier<Offset?>? pastePrompt;

  /// While true, fingers do not write, erase, or select; only a stylus, or
  /// a mouse, does. Fingers still scroll the page and press its controls.
  ///
  /// A finger is told apart by its [PointerDeviceKind.touch]. iOS reports
  /// Apple Pencil, Android an active pen such as the S Pen, and the web a
  /// `pen` pointer as [PointerDeviceKind.stylus], or
  /// [PointerDeviceKind.invertedStylus] for an eraser end. Windows (Windows
  /// Ink) and Linux (GTK) report a pen and its eraser end as a stylus, and
  /// a touch screen as touch. macOS reports a drawing tablet as a mouse,
  /// which is why a mouse keeps writing.
  final ValueListenable<bool>? stylusOnly;

  /// Page-local PDF paper that a lasso may capture as a bitmap excerpt.
  final Rect? selectablePdfBounds;

  /// Global screen rectangles (such as tool palettes and top bars) where
  /// native stylus strokes must be excluded from previewing and writing.
  final ValueGetter<List<Rect>>? exclusionRects;

  /// Notifies when [exclusionRects] would answer differently.
  final Listenable? exclusionsChanged;

  /// While active, page input seeks recorded ink instead of editing it.
  final StrokeReplayController? replay;
  final ValueChanged<Stroke>? onReplayStrokeTapped;

  /// The ruler laid on this page, if the editor has one. While it shows,
  /// strokes begun near its edge run along it.
  final RulerController? ruler;

  /// Where a touch the ruler takes is recorded, so the scrolling
  /// view above does not also move with it.
  final PointerClaims? pointerClaims;

  @override
  State<InkCanvas> createState() => _InkCanvasState();
}

class _InkCanvasState extends State<InkCanvas> with WidgetsBindingObserver {
  static const int _nativePointerOffset = 0x40000000;
  final int _nativeSurfaceId = NativeInkBridge.instance.allocateSurfaceId();

  /// False while this canvas sits in an offstage tab.
  bool _paneVisible = true;
  bool _nativeRegistered = false;
  bool _nativeRegistering = false;
  bool _nativeSyncScheduled = false;
  bool _dispatchingNative = false;
  List<RawInkSample>? _nativeSamples;
  List<Object?>? _lastNativeSurfaceSignature;

  /// The native pointer whose stroke this canvas is following, if any.
  int? _nativeLivePointer;

  /// Native pointers that are not ink here: they began on a widget above
  /// the page, such as the toolbar, or the pen was put down mid-stroke.
  final Set<int> _ignoredNativePointers = <int>{};

  Timer? _holdTimer;
  int? _holdPointer;
  Offset _holdOrigin = Offset.zero;

  /// The stroke waiting to be held still, and where it last moved on.
  Timer? _shapeTimer;
  int? _shapePointer;
  Offset _shapeAnchor = Offset.zero;

  /// The last tap that left a dot on a sticky note: a second tap there
  /// soon after opens the note for writing.
  _StickyTap? _lastStickyTap;

  /// A pointer whose press opened a sticky note, so the rest of its
  /// gesture is not ink.
  int? _consumedPointer;

  /// A finger that went down while only the pen writes, with where and
  /// when: lifted soon without moving, it is a tap that deselects.
  int? _fingerTapPointer;
  Offset _fingerTapStart = Offset.zero;
  Duration _fingerTapTime = Duration.zero;
  int? _replayPointer;
  Offset _replayStart = Offset.zero;

  /// Touches moving or turning the ruler.
  late final RulerGestureTracker _rulerGesture = RulerGestureTracker(
    widget.ruler?.config ?? const RulerConfig(),
  );

  /// The ruler edge the stroke or erase under way is run along, if any, the
  /// pointer drawing it, and what the distance badge shows.
  RulerGuide? _guide;
  int? _guidePointer;
  final ValueNotifier<RulerReadout?> _rulerReadout =
      ValueNotifier<RulerReadout?>(null);

  Size get _pageSize {
    final RenderObject? box = context.findRenderObject();
    return box is RenderBox && box.hasSize ? box.size : Size.zero;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.tool.addListener(_onToolChanged);
    widget.penSettings.addListener(_onNativeSettingsChanged);
    widget.stylusOnly?.addListener(_onNativeSettingsChanged);
    widget.exclusionsChanged?.addListener(_onNativeSettingsChanged);
    widget.replay?.addListener(_onNativeSettingsChanged);
    widget.ruler?.addListener(_onRulerChanged);
    widget.carry?._attach(this);
    _scheduleNativeSync();
    // After the first frame: placing the ruler tells the palette, which
    // must not be told while the tree is being built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onRulerChanged();
    });
  }

  @override
  void didUpdateWidget(InkCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller && widget.carry != null) {
      oldWidget.controller.selectionListenable.removeListener(
        widget.carry!._onCanvasSelectionChanged,
      );
      widget.controller.selectionListenable.addListener(
        widget.carry!._onCanvasSelectionChanged,
      );
    }
    if (oldWidget.tool != widget.tool) {
      oldWidget.tool.removeListener(_onToolChanged);
      widget.tool.addListener(_onToolChanged);
    }
    if (oldWidget.penSettings != widget.penSettings) {
      oldWidget.penSettings.removeListener(_onNativeSettingsChanged);
      widget.penSettings.addListener(_onNativeSettingsChanged);
    }
    if (oldWidget.stylusOnly != widget.stylusOnly) {
      oldWidget.stylusOnly?.removeListener(_onNativeSettingsChanged);
      widget.stylusOnly?.addListener(_onNativeSettingsChanged);
    }
    if (oldWidget.exclusionsChanged != widget.exclusionsChanged) {
      oldWidget.exclusionsChanged?.removeListener(_onNativeSettingsChanged);
      widget.exclusionsChanged?.addListener(_onNativeSettingsChanged);
    }
    if (oldWidget.replay != widget.replay) {
      oldWidget.replay?.removeListener(_onNativeSettingsChanged);
      widget.replay?.addListener(_onNativeSettingsChanged);
    }
    if (oldWidget.ruler != widget.ruler) {
      oldWidget.ruler?.removeListener(_onRulerChanged);
      widget.ruler?.addListener(_onRulerChanged);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onRulerChanged();
      });
    }
    if (oldWidget.carry != widget.carry) {
      _leaveCarry(oldWidget.carry);
      widget.carry?._attach(this);
    }
    _scheduleNativeSync();
  }

  void _leaveCarry(SelectionCarry? carry) {
    carry?._detach(this);
  }

  @override
  void dispose() {
    _leaveCarry(widget.carry);
    _holdTimer?.cancel();
    _shapeTimer?.cancel();
    widget.tool.removeListener(_onToolChanged);
    widget.penSettings.removeListener(_onNativeSettingsChanged);
    widget.stylusOnly?.removeListener(_onNativeSettingsChanged);
    widget.exclusionsChanged?.removeListener(_onNativeSettingsChanged);
    widget.replay?.removeListener(_onNativeSettingsChanged);
    widget.ruler?.removeListener(_onRulerChanged);
    _releaseClaims();
    _rulerReadout.dispose();
    if (_nativeRegistered || _nativeRegistering) {
      NativeInkBridge.instance.unregisterSurface(_nativeSurfaceId);
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // A rotation or resize moves the page under the pointer; end the gesture
    // on the old layout before the new one is applied.
    _endGesture();
  }

  void _endGesture() {
    _cancelHold();
    _cancelShapeHold();
    widget.carry?.finalizeSelectionGesture();
    widget.controller.finalizeActiveGesture();
  }

  /// Starts waiting for [event]'s pointer to be held still, if holding it
  /// would have anything to offer.
  void _startHold(PointerDownEvent event) {
    if (widget.pastePrompt == null || !widget.controller.canPaste) {
      return;
    }
    _holdPointer = event.pointer;
    _holdOrigin = event.localPosition;
    _holdTimer = Timer(
      widget.controller.selectionConfig.pasteHoldDuration,
      _onHeld,
    );
  }

  void _cancelHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _holdPointer = null;
  }

  /// The pointer stayed put: drop the selection drag it began, which went
  /// nowhere, and offer Paste where it is.
  void _onHeld() {
    final int? pointer = _holdPointer;
    _cancelHold();
    if (pointer == null) {
      return;
    }
    final SelectionCarry? carry = widget.carry;
    if (carry != null) {
      if (!carry._ownsPointer(pointer, this)) {
        return;
      }
      carry._cancelSelectionGesture(this, pointer);
    } else {
      if (widget.controller.selectionPointer != pointer) {
        return;
      }
      widget.controller.cancelSelectionGesture(pointer);
    }
    widget.pastePrompt?.value = _holdOrigin;
  }

  void _cancelShapeHold() {
    _shapeTimer?.cancel();
    _shapeTimer = null;
    _shapePointer = null;
  }

  /// Restarts the wait each time the stroke's pointer moves out of the
  /// slop around where it last settled, and starts it once the stroke is
  /// long enough to be a shape.
  void _trackShapeHold(PointerEvent event) {
    if (event.pointer != _shapePointer) {
      return;
    }
    final ActiveStroke? active = widget.controller.activeStroke;
    if (active == null || widget.controller.activePointer != event.pointer) {
      _cancelShapeHold();
      return;
    }
    final ShapeConfig config = widget.shapeConfig;
    if ((event.localPosition - _shapeAnchor).distance > config.holdSlop) {
      _shapeAnchor = event.localPosition;
      _shapeTimer?.cancel();
      _shapeTimer = null;
    }
    if (_shapeTimer == null && active.length >= config.minStrokeLength) {
      _shapeTimer = Timer(config.holdDuration, _onShapeHeld);
    }
  }

  /// The pen stayed put at the end of a stroke: replace the stroke with its
  /// shape, if it has one.
  void _onShapeHeld() {
    final int? pointer = _shapePointer;
    _shapeTimer = null;
    if (pointer == null) {
      return;
    }
    final RecognizedShape? shape = widget.controller.convertActiveStrokeToShape(
      pointer,
      recognizer: ShapeRecognizer(config: widget.shapeConfig),
    );
    if (shape == null || !mounted) {
      return;
    }
    if (pointer >= _nativePointerOffset) {
      // The native stroke was only a latency-hiding preview. Once hold-to-
      // shape takes over, hide it for the rest of this pointer sequence.
      NativeInkBridge.instance.finishPreview(
        _nativeSurfaceId,
        pointer - _nativePointerOffset,
      );
    }
    _shapePointer = null;
    SemanticsService.sendAnnouncement(
      View.of(context),
      shape.label,
      Directionality.of(context),
    );
  }

  /// A gesture never switches tools halfway, and a selection is only shown
  /// while the Select tool can act on it.
  ///
  /// A sticky note open for writing stays open for the pen and the eraser,
  /// and for the Sticky note tool, whose options then restyle it; Select
  /// closes it. Choosing the Sticky note tool with one note selected opens
  /// that note, so its options act on it.
  void _onToolChanged() {
    final int? nativePointer = _nativeLivePointer;
    if (nativePointer != null && !_nativePenTool) {
      // Hide the live preview now rather than after the next frame's sync.
      _ignoreNativePointer(nativePointer);
    }
    if (!_nativePenTool) {
      NativeInkBridge.instance.clearAllPreviews();
    }
    _syncNativeSurface();
    _endGesture();
    _endGuide();
    _lastStickyTap = null;
    widget.pastePrompt?.value = null;
    final EditorTool tool = widget.tool.value;
    final InkController controller = widget.controller;
    if (tool == EditorTool.select) {
      controller.exitStickyEditing();
      return;
    }
    if (tool == EditorTool.ai) {
      // What is selected stays: it is what the assistant was asked about.
      controller.exitStickyEditing();
      return;
    }
    final InkSelection? selection = controller.selection;
    if (tool == EditorTool.sticky &&
        selection != null &&
        selection.stickyCount == 1 &&
        selection.count == 0 &&
        selection.imageCount == 0) {
      controller.enterStickyEditing(selection.stickies.single.id);
    }
    controller.clearSelection();
  }

  void _onNativeSettingsChanged() => _scheduleNativeSync();

  /// Whether the native stylus path draws: with the pen, and not beside the
  /// ruler, whose edge the native preview could not follow. The Flutter
  /// pipeline takes the pen over while the ruler shows.
  bool get _nativePenTool =>
      widget.tool.value == EditorTool.pen &&
      !(widget.ruler?.isVisible ?? false);

  // Ruler.

  /// The ruler as it lies on this page.
  RulerState _rulerState() {
    final Size size = _pageSize;
    // As long as the page's diagonal, so the ruler crosses the whole page
    // at any angle.
    final double? length = size.isEmpty
        ? null
        : size.bottomRight(Offset.zero).distance;
    return widget.ruler!.stateFor(
      widget.controller,
      _rulerFallbackCenter(),
      length: length,
    );
  }

  /// Where a ruler not yet placed on this page is put: the middle of what
  /// shows of it.
  Offset _rulerFallbackCenter() {
    final Rect? visible = widget.visible?.value;
    if (visible != null && !visible.isEmpty) {
      return visible.center;
    }
    final Size size = _pageSize;
    return size.isEmpty ? const Offset(200, 200) : size.center(Offset.zero);
  }

  /// The ruler appeared, or changed: it is put down where it is seen, and
  /// the native stylus path stands aside or comes back.
  void _onRulerChanged() {
    final RulerController? ruler = widget.ruler;
    if (ruler != null &&
        ruler.isVisible &&
        !ruler.hasPose(widget.controller) &&
        mounted) {
      ruler.place(widget.controller, _rulerState());
    }
    if (ruler != null && !ruler.isVisible) {
      _rulerGesture.cancel();
      _endGuide();
    }
    _scheduleNativeSync();
  }

  void _releaseClaims() {
    _rulerGesture.cancel();
  }

  /// Takes a press for the ruler, if that is what it is.
  bool _beginRuler(PointerDownEvent event, InkDeviceKind kind) {
    final RulerController? ruler = widget.ruler;
    if (ruler == null ||
        !ruler.isVisible ||
        ruler.isLocked ||
        kind == InkDeviceKind.stylus ||
        kind == InkDeviceKind.invertedStylus) {
      return false;
    }
    if (_rulerGesture.isActive) {
      // A second finger, anywhere on the page, turns the ruler with the
      // first.
      if (kind == InkDeviceKind.touch &&
          _rulerGesture.join(event.pointer, event.localPosition)) {
        widget.pointerClaims?.claim(event.pointer);
        return true;
      }
      return false;
    }
    final RulerState state = _rulerState();
    final RulerGrab? grab = _rulerGesture.grabAt(state, event.localPosition);
    if (grab == null) {
      return false;
    }
    if (widget.isInputBlocked?.call() ?? false) {
      return true;
    }
    widget.pastePrompt?.value = null;
    _rulerGesture.begin(event.pointer, event.localPosition, state, grab);
    widget.pointerClaims?.claim(event.pointer);
    return true;
  }

  /// Carries a touch the ruler holds. Returns whether it was one.
  bool _moveRuler(PointerMoveEvent event) {
    if (_rulerGesture.owns(event.pointer)) {
      final RulerState? next = _rulerGesture.move(
        event.pointer,
        event.localPosition,
      );
      if (next != null) {
        widget.ruler?.place(widget.controller, next);
        if (_rulerGesture.didSnap) {
          AppHaptics.selectionClick();
        }
      }
      return true;
    }
    return false;
  }

  /// Lets go of a touch the ruler holds. Returns whether it was one.
  bool _endRuler(PointerEvent event) {
    if (_rulerGesture.owns(event.pointer)) {
      widget.pointerClaims?.release(event.pointer);
      _rulerGesture.end(event.pointer);
      return true;
    }
    return false;
  }

  /// A stroke or erase begins at [page]: if it starts at the ruler's edge it
  /// follows it. Returns where it starts.
  Offset _beginGuide(PointerEvent event, Offset page) {
    _endGuide();
    final RulerController? ruler = widget.ruler;
    if (ruler == null || !ruler.isVisible) {
      return page;
    }
    final RulerGuide? guide = RulerGuide.begin(
      RulerGeometry(_rulerState()),
      ruler.config,
      page,
    );
    if (guide == null) {
      return page;
    }
    _guide = guide;
    _guidePointer = event.pointer;
    final Offset snapped = guide.apply(page);
    _rulerReadout.value = guide.readout;
    return snapped;
  }

  /// [event]'s position, run along the ruler's edge if its stroke follows it.
  InkVector _guidedPosition(PointerEvent event) {
    final RulerGuide? guide = _guide;
    if (guide == null || _guidePointer != event.pointer) {
      return _position(event);
    }
    final Offset snapped = guide.apply(event.localPosition);
    _rulerReadout.value = guide.readout;
    return InkVector(snapped.dx, snapped.dy);
  }

  void _endGuide([PointerEvent? event]) {
    if (event != null && event.pointer != _guidePointer) {
      return;
    }
    _guide = null;
    _guidePointer = null;
    _rulerReadout.value = null;
  }

  /// Registers the canvas's current screen transform with the native input
  /// observer. This runs after layout, and again whenever the page viewport
  /// rebuilds while scrolling or zooming.
  void _scheduleNativeSync() {
    if (_nativeSyncScheduled || !mounted) {
      return;
    }
    _nativeSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _nativeSyncScheduled = false;
      if (mounted) {
        _syncNativeSurface();
      }
    });
  }

  Future<void> _syncNativeSurface() async {
    if (!widget.enableNativeInk || (widget.replay?.isActive ?? false)) {
      _lastNativeSurfaceSignature = null;
      if (_nativeRegistered || _nativeRegistering) {
        await NativeInkBridge.instance.unregisterSurface(_nativeSurfaceId);
      }
      _nativeRegistered = false;
      _nativeRegistering = false;
      return;
    }
    final RenderObject? object = context.findRenderObject();
    if (object is! RenderBox || !object.attached || !object.hasSize) {
      return;
    }
    final Offset origin = object.localToGlobal(Offset.zero);
    final Offset xBasis = object.localToGlobal(const Offset(1, 0)) - origin;
    final Offset yBasis = object.localToGlobal(const Offset(0, 1)) - origin;
    final PenSettings pen = widget.penSettings.value;
    final StrokeStyle style = pen.strokeStyle(widget.penConfig);
    // Only editors on screen claim stylus input: with split screen, a hidden
    // tab's stale rectangle must not compete with the two visible panes, and
    // native code then only tests the surfaces the pen can actually land on.
    final bool enabled = _paneVisible && _nativePenTool;
    // A translucent preview would compound with Flutter's active highlighter.
    // Highlighter input is still captured at full native sample rate.
    final bool previewEnabled = enabled && !style.isHighlighter;
    final Color color = style.resolve(Theme.of(context).brightness);
    final List<Rect> exclusions =
        widget.exclusionRects?.call() ?? const <Rect>[];
    final NativeInkSurface surface = NativeInkSurface(
      id: _nativeSurfaceId,
      size: object.size,
      origin: origin,
      xBasis: xBasis,
      yBasis: yBasis,
      enabled: enabled,
      previewEnabled: previewEnabled,
      color: color,
      width: style.width,
      pressureSensitivity: pen.dynamics.pressure,
      stabilization: pen.stabilization,
      writingStyle: style.writing.name,
      exclusionRects: exclusions,
    );
    final List<Object?> signature = <Object?>[
      object.size.width,
      object.size.height,
      origin.dx,
      origin.dy,
      xBasis.dx,
      xBasis.dy,
      yBasis.dx,
      yBasis.dy,
      enabled,
      previewEnabled,
      color.toARGB32(),
      style.width,
      pen.dynamics.pressure,
      pen.stabilization,
      style.writing.name,
      exclusions.length,
      for (final Rect r in exclusions) ...<Object?>[
        r.left,
        r.top,
        r.right,
        r.bottom,
      ],
    ];
    if (_nativeRegistered) {
      if (listEquals(signature, _lastNativeSurfaceSignature)) {
        return;
      }
      _lastNativeSurfaceSignature = signature;
      await NativeInkBridge.instance.updateSurface(surface);
      return;
    }
    if (_nativeRegistering) {
      return;
    }
    _nativeRegistering = true;
    final bool registered = await NativeInkBridge.instance.registerSurface(
      surface,
      _onNativeInkPacket,
    );
    if (!mounted) {
      if (registered) {
        await NativeInkBridge.instance.unregisterSurface(_nativeSurfaceId);
      }
      return;
    }
    _nativeRegistering = false;
    _nativeRegistered = registered;
    _lastNativeSurfaceSignature = registered ? signature : null;
    if (registered) {
      // Layout or settings may have changed while registration was in flight.
      _scheduleNativeSync();
    }
  }

  bool _nativeOwns(PointerEvent event) {
    if (_dispatchingNative ||
        !widget.enableNativeInk ||
        !_nativeRegistered ||
        !_nativePenTool) {
      return false;
    }
    return event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus;
  }

  /// Re-enters the existing ink state machine with the full native sample
  /// batch. Synthetic events carry the last position while [_nativeSamples]
  /// lets start/add/end consume every actual sample in timestamp order.
  void _onNativeInkPacket(NativeInkPacket packet) {
    if (!mounted || packet.surfaceId != _nativeSurfaceId) {
      return;
    }
    if (widget.replay?.isActive ?? false) {
      _ignoreNativePointer(packet.pointer);
      return;
    }
    final bool ends =
        packet.phase == NativeInkPhase.up ||
        packet.phase == NativeInkPhase.cancel;
    if (packet.phase == NativeInkPhase.down) {
      _ignoredNativePointers.remove(packet.pointer);
      if (!_nativePenTool || !_nativeHitsCanvas(packet)) {
        _ignoreNativePointer(packet.pointer);
      } else {
        _nativeLivePointer = packet.pointer;
      }
    } else if (!_nativePenTool) {
      _ignoreNativePointer(packet.pointer);
    }
    if (!_nativePenTool) {
      _ignoreNativePointer(packet.pointer);
      return;
    }
    if (_ignoredNativePointers.contains(packet.pointer)) {
      if (ends) {
        _ignoredNativePointers.remove(packet.pointer);
        if (_nativeLivePointer == packet.pointer) {
          _nativeLivePointer = null;
        }
      }
      return;
    }
    if (ends && _nativeLivePointer == packet.pointer) {
      _nativeLivePointer = null;
    }
    if (packet.samples.isEmpty && packet.phase != NativeInkPhase.cancel) {
      return;
    }
    final NativeInkSample sample = packet.samples.isEmpty
        ? const NativeInkSample(
            position: Offset.zero,
            timestamp: Duration.zero,
            pressure: null,
          )
        : packet.samples.last;
    final PointerDeviceKind kind = packet.kind == NativeInkKind.invertedStylus
        ? PointerDeviceKind.invertedStylus
        : PointerDeviceKind.stylus;
    final int pointer = _nativePointerOffset + packet.pointer;
    final double pressure = sample.pressure ?? 1;
    final double pressureMin = sample.pressure == null ? 1 : 0;
    _nativeSamples = <RawInkSample>[
      for (final NativeInkSample value in packet.samples)
        RawInkSample(
          position: InkVector(value.position.dx, value.position.dy),
          timestamp: value.timestamp,
          deviceKind: packet.kind == NativeInkKind.invertedStylus
              ? InkDeviceKind.invertedStylus
              : InkDeviceKind.stylus,
          pressure: value.pressure,
        ),
    ];
    _dispatchingNative = true;
    try {
      switch (packet.phase) {
        case NativeInkPhase.down:
          _onPointerDown(
            PointerDownEvent(
              timeStamp: sample.timestamp,
              pointer: pointer,
              kind: kind,
              position: sample.position,
              pressure: pressure,
              pressureMin: pressureMin,
              pressureMax: 1,
            ),
          );
        case NativeInkPhase.move:
          _onPointerMove(
            PointerMoveEvent(
              timeStamp: sample.timestamp,
              pointer: pointer,
              kind: kind,
              position: sample.position,
              pressure: pressure,
              pressureMin: pressureMin,
              pressureMax: 1,
            ),
          );
        case NativeInkPhase.up:
          _onPointerUp(
            PointerUpEvent(
              timeStamp: sample.timestamp,
              pointer: pointer,
              kind: kind,
              position: sample.position,
              pressure: pressure,
              pressureMin: pressureMin,
              pressureMax: 1,
            ),
          );
        case NativeInkPhase.cancel:
          _onPointerCancel(
            PointerCancelEvent(
              timeStamp: sample.timestamp,
              pointer: pointer,
              kind: kind,
              position: sample.position,
              pressureMin: pressureMin,
              pressureMax: 1,
            ),
          );
      }
    } finally {
      _dispatchingNative = false;
      _nativeSamples = null;
    }
    if (packet.phase == NativeInkPhase.up ||
        packet.phase == NativeInkPhase.cancel) {
      NativeInkBridge.instance.finishPreview(_nativeSurfaceId, packet.pointer);
    }
  }

  /// Stops treating native [pointer] as ink here and hides its preview.
  void _ignoreNativePointer(int pointer) {
    if (_ignoredNativePointers.add(pointer)) {
      NativeInkBridge.instance.finishPreview(_nativeSurfaceId, pointer);
    }
  }

  /// Native code only knows the page's rectangle, so a stylus pressed on a
  /// toolbar or panel above the page also reaches it. Flutter's own hit test
  /// says whether the page is really what lies under the pen.
  bool _nativeHitsCanvas(NativeInkPacket packet) {
    final RenderObject? object = context.findRenderObject();
    if (object is! RenderBox || !object.attached || packet.samples.isEmpty) {
      return false;
    }
    final Offset global = object.localToGlobal(packet.samples.first.position);
    final HitTestResult result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      result,
      global,
      View.of(context).viewId,
    );
    for (final HitTestEntry entry in result.path) {
      if (entry.target == object) {
        return true;
      }
    }
    return false;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (widget.replay?.isActive ?? false) {
      _replayPointer = event.pointer;
      _replayStart = event.position;
      return;
    }
    if (_nativeOwns(event)) {
      return;
    }
    final InkDeviceKind? kind = _deviceKind(event);
    if (kind == null) {
      return;
    }
    // A finger or mouse on the ruler moves it, before a finger is left to
    // scroll the page.
    if (_beginRuler(event, kind)) {
      return;
    }
    if (kind == InkDeviceKind.touch && (widget.stylusOnly?.value ?? false)) {
      // Fingers only move the page here, but a tap still deselects. A
      // second finger makes it a pinch.
      _fingerTapPointer = _fingerTapPointer == null ? event.pointer : -1;
      _fingerTapStart = event.position;
      _fingerTapTime = event.timeStamp;
      return;
    }
    if (widget.isInputBlocked?.call() ?? false) {
      return;
    }
    widget.pastePrompt?.value = null;
    final InkController controller = widget.controller;
    final InkVector position = _position(event);
    final StickyNoteElement? editing = controller.editingSticky;
    final bool onEditing =
        editing != null &&
        editing.contains(
          position,
          tolerance: controller.stickyConfig.hitSlop,
          cornerRadius: controller.stickyConfig.cornerRadius,
        );
    if (kind == InkDeviceKind.invertedStylus ||
        widget.tool.value == EditorTool.eraser) {
      widget.carry?.clearSelection();
      // Sticky ink is erasable whether or not its note is selected or open
      // for writing. A gesture begun on sticky paper belongs to that note;
      // anywhere else it belongs to the page.
      final StickyNoteElement? eraseTarget = onEditing
          ? editing
          : controller.stickyAt(position);
      final Offset erasePoint = _beginGuide(event, event.localPosition);
      controller.startErase(
        pointer: event.pointer,
        position: InkVector(erasePoint.dx, erasePoint.dy),
        settings: widget.eraserSettings.value,
        config: widget.eraserConfig,
        screenScale: _screenScale(),
        inSticky: eraseTarget,
      );
      return;
    }
    if (widget.tool.value == EditorTool.ai) {
      return;
    }
    if (widget.tool.value == EditorTool.sticky) {
      widget.carry?.clearSelection();
      final Size size = _pageSize;
      // Pressed on a note, the tool picks it up and drags it; anywhere
      // else, it places a new one.
      if (controller.beginStickyDrag(
        pointer: event.pointer,
        position: position,
        pageBounds: Offset.zero & size,
        growsDown: widget.pageGrows,
      )) {
        return;
      }
      controller.beginStickyPlacement(
        pointer: event.pointer,
        position: position,
        pageBounds: Offset.zero & size,
        settings: widget.stickySettings?.value ?? const StickyNoteSettings(),
        growsDown: widget.pageGrows,
      );
      return;
    }
    if (widget.tool.value == EditorTool.select) {
      final SelectionCarry? carry = widget.carry;
      final bool began = carry != null
          ? carry._beginSelectionGesture(
              this,
              pointer: event.pointer,
              position: _position(event),
            )
          : widget.controller.beginSelectionGesture(
              pointer: event.pointer,
              position: _position(event),
            );
      if (began) {
        _startHold(event);
      }
      return;
    }
    if (editing != null && !onEditing && !controller.isBusy) {
      // Writing elsewhere closes the note; the stroke is page ink.
      controller.exitStickyEditing();
    }
    if (!onEditing && _isSecondStickyTap(event, position)) {
      return;
    }
    if (widget.tool.value != EditorTool.pen) {
      return;
    }
    widget.carry?.clearSelection();
    final PenSettings pen = widget.penSettings.value;
    _beginGuide(event, event.localPosition);
    // Pen and Highlighter share the capture and smoothing; the highlighter
    // is even along its length, and never becomes a shape.
    // Ink written on a sticky note belongs to it, whether or not it is
    // open for writing.
    final StickyNoteElement? target = onEditing
        ? editing
        : controller.stickyAt(position);
    final bool began = controller.startStroke(
      pointer: event.pointer,
      sample: _sample(event, kind),
      style: pen.strokeStyle(widget.penConfig),
      dynamics: pen.dynamics,
      smoothingConfig: pen.smoothing(controller.smoothing),
      scribbleErase: pen.armsScribbleToErase ? widget.scribbleConfig : null,
      intoSticky: target,
    );
    if (began && pen.armsHoldToShape && target == null) {
      _cancelShapeHold();
      _shapePointer = event.pointer;
      _shapeAnchor = event.localPosition;
    }
  }

  /// Whether [event] is the second of two quick taps on the same sticky
  /// note: then the dot the first left is taken back and the note opens for
  /// writing.
  bool _isSecondStickyTap(PointerDownEvent event, InkVector position) {
    final _StickyTap? last = _lastStickyTap;
    _lastStickyTap = null;
    if (last == null) {
      return false;
    }
    final InkController controller = widget.controller;
    final StickyNoteElement? sticky = controller.stickyAt(position);
    if (sticky == null ||
        sticky.id != last.stickyId ||
        event.timeStamp - last.time >
            controller.stickyConfig.doubleTapTimeout ||
        (position - last.position).length >
            controller.stickyConfig.doubleTapSlop) {
      return false;
    }
    if (!controller.enterStickyEditing(sticky.id, removingTap: last.dot)) {
      return false;
    }
    _consumedPointer = event.pointer;
    _announce('Writing on ${sticky.label}');
    return true;
  }

  /// Clears the selection on every page, unless [position] is on this
  /// page's selection or its handles.
  void _deselectUnlessOnSelection(InkVector position) {
    final InkController controller = widget.controller;
    final InkSelection? selection = controller.selection;
    if (selection != null &&
        selection.frame.hitTest(
              position,
              handleHitRadius: controller.selectionConfig.handleHitRadius,
              rotationHandleOffset:
                  controller.selectionConfig.rotationHandleOffset,
              tolerance: controller.selectionConfig.geometryTolerance,
            ) !=
            null) {
      return;
    }
    final SelectionCarry? carry = widget.carry;
    if (carry != null) {
      carry.clearSelection();
    } else {
      controller.clearSelection();
    }
  }

  /// Remembers a tap that left a dot on a sticky note, for a double tap.
  void _recordStickyTap(PointerUpEvent event) {
    final InkController controller = widget.controller;
    final StickyNoteElement? sticky = controller.lastWrittenSticky;
    final Stroke? dot = sticky?.strokes.lastOrNull;
    if (sticky == null || dot == null || !dot.isDot) {
      _lastStickyTap = null;
      return;
    }
    // Where it lies on the page: the dot's own points are the note's.
    final InkVector at = _position(event);
    _lastStickyTap = _StickyTap(
      stickyId: sticky.id,
      position: at,
      time: event.timeStamp,
      dot: dot,
    );
  }

  void _announce(String message) {
    if (!mounted) {
      return;
    }
    SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      Directionality.of(context),
    );
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (widget.replay?.isActive ?? false) {
      if (event.pointer == _replayPointer &&
          (event.position - _replayStart).distance > kTouchSlop) {
        _replayPointer = -1;
      }
      return;
    }
    if (_moveRuler(event)) {
      return;
    }
    if (_nativeOwns(event)) {
      return;
    }
    if (event.pointer == _consumedPointer) {
      return;
    }
    if (event.pointer == _fingerTapPointer &&
        (event.position - _fingerTapStart).distance > kTouchSlop) {
      _fingerTapPointer = -1;
    }
    if (_isPlacing(event)) {
      widget.controller.updateStickyPlacement(event.pointer, _position(event));
      return;
    }
    if (_isDraggingSticky(event)) {
      widget.controller.updateStickyDrag(event.pointer, _position(event));
      return;
    }
    if (_isAdjustingShape(event)) {
      widget.controller.adjustShape(event.pointer, _position(event));
    } else if (_isErasing(event)) {
      widget.controller.eraseTo(event.pointer, _guidedPosition(event));
    } else if (_isSelecting(event)) {
      final double slop = widget.controller.selectionConfig.pasteHoldSlop;
      if (event.pointer == _holdPointer &&
          (event.localPosition - _holdOrigin).distance > slop) {
        _cancelHold();
      }
      final SelectionCarry? carry = widget.carry;
      if (carry != null && carry._ownsPointer(event.pointer, this)) {
        carry._updateSelectionGesture(this, event.pointer, _position(event));
      } else {
        widget.controller.updateSelectionGesture(
          event.pointer,
          _position(event),
        );
      }
    } else {
      if (widget.tool.value != EditorTool.pen) {
        return;
      }
      widget.controller.addSamples(event.pointer, _samples(event));
      _trackShapeHold(event);
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (widget.replay?.isActive ?? false) {
      final bool tapped = event.pointer == _replayPointer;
      _replayPointer = null;
      if (tapped) {
        final Stroke? stroke = hitTestStroke(
          widget.controller.strokes,
          _position(event),
        );
        if (stroke?.completedAtMs != null &&
            stroke?.recordingId == widget.replay?.track?.id) {
          widget.onReplayStrokeTapped?.call(stroke!);
        }
      }
      return;
    }
    if (_endRuler(event)) {
      return;
    }
    if (_nativeOwns(event)) {
      return;
    }
    if (event.pointer == _consumedPointer) {
      _consumedPointer = null;
      return;
    }
    if (_fingerTapPointer != null && event.kind == PointerDeviceKind.touch) {
      final bool tapped =
          event.pointer == _fingerTapPointer &&
          event.timeStamp - _fingerTapTime < kLongPressTimeout;
      _fingerTapPointer = null;
      if (tapped) {
        _deselectUnlessOnSelection(_position(event));
      }
      return;
    }
    if (event.pointer == _holdPointer) {
      _cancelHold();
    }
    if (event.pointer == _shapePointer) {
      _cancelShapeHold();
    }
    if (_isPlacing(event)) {
      final StickyNoteElement? placed = widget.controller.endStickyPlacement(
        event.pointer,
        _position(event),
      );
      if (placed != null) {
        _announce('${placed.label} added');
        widget.onStickyPlaced?.call();
      }
      return;
    }
    if (_isDraggingSticky(event)) {
      final bool moved = widget.controller.activeStickyDrag!.moved;
      final StickyNoteElement? note = widget.controller.endStickyDrag(
        event.pointer,
        _position(event),
      );
      if (note != null && moved) {
        _announce('${note.label} moved');
      }
      return;
    }
    if (_isAdjustingShape(event)) {
      widget.controller.endShapeAdjust(event.pointer, _position(event));
    } else if (_isErasing(event)) {
      widget.controller.endErase(event.pointer, _guidedPosition(event));
      _endGuide(event);
    } else if (_isSelecting(event)) {
      final SelectionCarry? carry = widget.carry;
      if (carry != null && carry._ownsPointer(event.pointer, this)) {
        carry._endSelectionGesture(
          this,
          event.pointer,
          _position(event),
          event.position,
        );
      } else {
        widget.controller.endSelectionGesture(
          event.pointer,
          _position(event),
          widget.selectablePdfBounds,
          widget.aiActive?.value ?? false,
        );
      }
    } else {
      // Taps are watched on notes not yet open for writing: a second one
      // opens the note.
      final bool onPage =
          widget.controller.activePointer == event.pointer &&
          widget.controller.activeStrokeSticky != null &&
          widget.controller.activeStrokeSticky?.id !=
              widget.controller.editingSticky?.id;
      final int erased = widget.controller.endStroke(
        event.pointer,
        _samples(event),
      );
      _endGuide(event);
      if (erased > 0) {
        _announce(erased == 1 ? 'Erased 1 stroke' : 'Erased $erased strokes');
      } else if (onPage) {
        _recordStickyTap(event);
      }
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer == _replayPointer || _replayPointer == -1) {
      _replayPointer = null;
      return;
    }
    if (_endRuler(event)) {
      return;
    }
    _endGuide(event);
    if (_nativeOwns(event)) {
      return;
    }
    if (event.pointer == _consumedPointer) {
      _consumedPointer = null;
    }
    if (event.pointer == _fingerTapPointer) {
      _fingerTapPointer = null;
    }
    widget.carry?._cancelSelectionGesture(this, event.pointer);
    // A placement not lifted into place inserts nothing.
    widget.controller
      ..cancelStickyPlacement(event.pointer)
      ..cancelStickyDrag(event.pointer);
    if (event.pointer == _holdPointer) {
      _cancelHold();
    }
    if (event.pointer == _shapePointer) {
      _cancelShapeHold();
    }
    if (_isAdjustingShape(event)) {
      // A cancelled adjustment keeps the shape as it was last shown.
      widget.controller.finalizeShapeAdjust();
    }
    widget.controller
      ..cancelStroke(event.pointer)
      ..cancelErase(event.pointer)
      ..cancelSelectionGesture(event.pointer);
  }

  bool _isPlacing(PointerEvent event) {
    return widget.controller.activePlacement?.pointer == event.pointer;
  }

  bool _isDraggingSticky(PointerEvent event) {
    return widget.controller.activeStickyDrag?.pointer == event.pointer;
  }

  bool _isAdjustingShape(PointerEvent event) {
    return widget.controller.activeShape?.pointer == event.pointer;
  }

  bool _isErasing(PointerEvent event) {
    return widget.controller.activeErase?.pointer == event.pointer;
  }

  bool _isSelecting(PointerEvent event) {
    return widget.controller.selectionPointer == event.pointer ||
        (widget.carry?._ownsPointer(event.pointer, this) ?? false);
  }

  /// All samples carried by [event].
  ///
  /// Flutter delivers one sample per event: Android's batched historical
  /// samples arrive as separate move events and iOS coalesced touches are not
  /// exposed to the framework. This is the single place to unpack them if an
  /// API appears.
  List<RawInkSample> _samples(PointerEvent event) {
    final List<RawInkSample>? native = _nativeSamples;
    if (native != null) {
      return native;
    }
    final InkDeviceKind? kind = _deviceKind(event);
    return kind == null
        ? const <RawInkSample>[]
        : <RawInkSample>[_sample(event, kind)];
  }

  RawInkSample _sample(PointerEvent event, InkDeviceKind kind) {
    final List<RawInkSample>? native = _nativeSamples;
    if (native != null && native.isNotEmpty) {
      return native.last;
    }
    return RawInkSample(
      position: _guidedPosition(event),
      timestamp: event.timeStamp,
      deviceKind: kind,
      pressure: _pressure(event, kind),
    );
  }

  /// The pen's pressure from 0 to 1, or null where there is none to read:
  /// fingers and mice report a constant, and so does a stylus without a
  /// pressure sensor, whose range is then empty.
  double? _pressure(PointerEvent event, InkDeviceKind kind) {
    if (kind != InkDeviceKind.stylus && kind != InkDeviceKind.invertedStylus) {
      return null;
    }
    final double range = event.pressureMax - event.pressureMin;
    if (!(range > 0) || !event.pressure.isFinite) {
      return null;
    }
    return ((event.pressure - event.pressureMin) / range).clamp(0.0, 1.0);
  }

  /// How many screen pixels one canvas pixel covers here, through the
  /// page's fit and any zoom.
  double _screenScale() {
    final RenderObject? box = context.findRenderObject();
    if (box is! RenderBox || !box.attached) {
      return 1;
    }
    final Offset origin = box.localToGlobal(Offset.zero);
    return (box.localToGlobal(const Offset(1, 0)) - origin).distance;
  }

  InkVector _position(PointerEvent event) {
    // localPosition is already in this widget's logical coordinate space.
    final Offset position = event.localPosition;
    return InkVector(position.dx, position.dy);
  }

  InkDeviceKind? _deviceKind(PointerEvent event) {
    switch (event.kind) {
      case PointerDeviceKind.stylus:
        return InkDeviceKind.stylus;
      case PointerDeviceKind.invertedStylus:
        return InkDeviceKind.invertedStylus;
      case PointerDeviceKind.touch:
        return InkDeviceKind.touch;
      case PointerDeviceKind.mouse:
        final bool startsWithOtherButton =
            event is PointerDownEvent && event.buttons != kPrimaryMouseButton;
        return startsWithOtherButton ? null : InkDeviceKind.mouse;
      case PointerDeviceKind.trackpad:
      case PointerDeviceKind.unknown:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    _paneVisible = TickerMode.valuesOf(context).enabled;
    _scheduleNativeSync();
    final Brightness brightness = Theme.of(context).brightness;
    final AppColors colors = AppColors.of(context);
    final SelectionCarry? carry = widget.carry;
    return ClipRect(
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerCancel,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            RepaintBoundary(
              child: CustomPaint(
                painter: CompletedStrokesPainter(
                  controller: widget.controller,
                  brightness: brightness,
                  visible: widget.visible,
                  replay: widget.replay,
                  replayHighlight: colors.accent,
                ),
              ),
            ),
            // Sticky notes lie above images and completed page strokes.
            RepaintBoundary(
              child: CustomPaint(
                key: const ValueKey<String>('sticky-notes-layer'),
                painter: StickyNotesPainter(
                  controller: widget.controller,
                  accent: colors.accent,
                  config: widget.controller.stickyConfig,
                  visible: widget.visible,
                ),
              ),
            ),
            _StickySemantics(
              controller: widget.controller,
              onEdit: (StickyNoteElement note) {
                if (widget.controller.enterStickyEditing(note.id)) {
                  _announce('Writing on ${note.label}');
                }
              },
              onDelete: (StickyNoteElement note) {
                if (widget.controller.deleteStickyNote(note.id)) {
                  _announce('${note.label} deleted');
                }
              },
            ),
            // An AI notation still being drawn, above the finished ink.
            NotationPlaybackLayer(controller: widget.controller),
            RepaintBoundary(
              child: CustomPaint(
                painter: ActiveStrokePainter(
                  controller: widget.controller,
                  brightness: brightness,
                ),
              ),
            ),
            // The lasso, the selected strokes, and their frame. Selected
            // strokes are painted here, not in the completed layer, so a
            // transform preview repaints this layer alone.
            ExcludeSemantics(
              child: RepaintBoundary(
                child: CustomPaint(
                  key: const ValueKey<String>('selection-layer'),
                  painter: SelectionPainter(
                    controller: widget.controller,
                    brightness: brightness,
                    color: colors.accent,
                    handleColor: colors.writingSurface,
                    crossPageListenable: carry,
                    crossPageOverlay: carry == null
                        ? null
                        : () => carry._overlayFor(this),
                    scale: _screenScale(),
                    scaleProvider: _screenScale,
                  ),
                ),
              ),
            ),
            ExcludeSemantics(
              child: RepaintBoundary(
                child: CustomPaint(
                  key: const ValueKey<String>('eraser-indicator'),
                  painter: EraserIndicatorPainter(
                    controller: widget.controller,
                    color: colors.textPrimary,
                    haloColor: colors.writingSurface,
                    scale: _screenScale(),
                    scaleProvider: _screenScale,
                  ),
                ),
              ),
            ),
            // The ruler lies above all ink, in a layer of its own: moving it
            // repaints no strokes. It is not part of the page's ink.
            if (widget.ruler != null)
              RulerLayer(
                controller: widget.ruler!,
                stateOf: _rulerState,
                readout: _rulerReadout,
                accent: colors.accent,
                brightness: brightness,
              ),
          ],
        ),
      ),
    );
  }
}

/// A tap that left a dot on a sticky note.
class _StickyTap {
  const _StickyTap({
    required this.stickyId,
    required this.position,
    required this.time,
    required this.dot,
  });

  final String stickyId;
  final InkVector position;
  final Duration time;
  final Stroke dot;
}

/// One node per sticky note for assistive technology, over its paper:
/// its label ("Yellow lined sticky note"), whether it is open for writing,
/// and actions to write on it and to delete it. Rebuilt only when a note or
/// the note open for writing changes, never for page ink or a pointer
/// move, and never in the way of a pointer.
class _StickySemantics extends StatefulWidget {
  const _StickySemantics({
    required this.controller,
    required this.onEdit,
    required this.onDelete,
  });

  final InkController controller;
  final ValueChanged<StickyNoteElement> onEdit;
  final ValueChanged<StickyNoteElement> onDelete;

  @override
  State<_StickySemantics> createState() => _StickySemanticsState();
}

class _StickySemanticsState extends State<_StickySemantics> {
  List<StickyNoteElement> _notes = const <StickyNoteElement>[];
  String? _editing;

  late Listenable _listenable = _merged(widget.controller);

  static Listenable _merged(InkController controller) {
    return Listenable.merge(<Listenable>[
      controller.completedStrokesListenable,
      controller.stickyEditingListenable,
    ]);
  }

  @override
  void initState() {
    super.initState();
    _take();
    _listenable.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(_StickySemantics oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _listenable.removeListener(_onChanged);
      _listenable = _merged(widget.controller);
      _listenable.addListener(_onChanged);
      _take();
    }
  }

  @override
  void dispose() {
    _listenable.removeListener(_onChanged);
    super.dispose();
  }

  bool _take() {
    final List<StickyNoteElement> notes = List<StickyNoteElement>.of(
      widget.controller.stickyNotes,
    );
    final String? editing = widget.controller.editingSticky?.id;
    // Notes are immutable, so an unchanged list holds the same objects.
    final bool changed =
        editing != _editing ||
        notes.length != _notes.length ||
        <int>[
          for (int i = 0; i < notes.length; i++)
            if (!identical(notes[i], _notes[i])) i,
        ].isNotEmpty;
    _notes = notes;
    _editing = editing;
    return changed;
  }

  void _onChanged() {
    if (_take()) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    // No pointer stops here: the canvas's own listener, above, sees every
    // press, and these boxes have nothing to hit.
    return ExcludeFocus(
      child: Builder(
        builder: (BuildContext context) {
          final List<StickyNoteElement> notes = _notes;
          if (notes.isEmpty) {
            return const SizedBox.shrink();
          }
          final String? editing = _editing;
          final ValueChanged<StickyNoteElement> onEdit = widget.onEdit;
          final ValueChanged<StickyNoteElement> onDelete = widget.onDelete;
          return Stack(
            children: <Widget>[
              for (final StickyNoteElement note in notes)
                Positioned.fromRect(
                  key: ValueKey<String>('sticky-semantics-${note.id}'),
                  rect: note.bounds,
                  child: Semantics(
                    container: true,
                    label: note.id == editing
                        ? '${note.label}, open for writing'
                        : note.label,
                    customSemanticsActions:
                        <CustomSemanticsAction, VoidCallback>{
                          const CustomSemanticsAction(
                            label: 'Write on note',
                          ): () =>
                              onEdit(note),
                          const CustomSemanticsAction(
                            label: 'Delete note',
                          ): () =>
                              onDelete(note),
                        },
                    child: const SizedBox.expand(),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
