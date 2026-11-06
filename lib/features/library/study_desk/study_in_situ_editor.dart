import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../editor/ai/canvas_text_recognizer.dart';
import '../../editor/handwriting/handwriting_indexer.dart';
import '../../editor/handwriting/recognized_handwriting.dart';
import '../../editor/ink/eraser_settings.dart';
import '../../editor/ink/ink_canvas.dart';
import '../../editor/ink/ink_controller.dart';
import '../../editor/ink/ink_palette.dart';
import '../../editor/ink/native_ink_bridge.dart';
import '../../editor/ink/pen_settings.dart';
import '../../editor/ink/stroke.dart';
import '../../editor/page/note_document.dart';

/// One round of annotating a page from the desk: the tools in hand, what was on
/// the page when it began, and the reading of what has been written since.
class StudyInSituSession {
  StudyInSituSession({
    required this.document,
    PenSettings? pen,
    this.recognizer,
    this.renderer = const HandwritingImageRenderer(),
    this.recognitionDelay = const Duration(milliseconds: 1200),
  }) : _startRevision = document.current.ink.documentRevision,
       _startStrokes = Set<Stroke>.identity()
         ..addAll(document.current.ink.strokes),
       _known = Set<Stroke>.identity()..addAll(document.current.ink.strokes),
       tool = ValueNotifier<EditorTool>(EditorTool.pen),
       eraser = ValueNotifier<EraserSettings>(EraserSettings.defaults()),
       pen = ValueNotifier<PenSettings>(
         _forDesk(pen ?? PenSettings(ink: InkPalette.ink, width: 3)),
       ) {
    ink.completedStrokesListenable.addListener(_onStrokesChanged);
  }

  /// The inks offered, kept to those the toolbar has swatches for.
  static PenSettings _forDesk(PenSettings pen) => pen.copyWith(
    style: pen.isHighlighter ? WritingStyle.pen : pen.style,
    ink: PenSettings.defaultSwatches.contains(pen.ink)
        ? pen.ink
        : InkPalette.ink,
    swatches: PenSettings.defaultSwatches,
    highlighterInk:
        PenSettings.defaultHighlighterSwatches.contains(pen.highlighterInk)
        ? pen.highlighterInk
        : InkPalette.highlighterYellow,
    highlighterSwatches: PenSettings.defaultHighlighterSwatches,
  );

  final NoteDocument document;

  /// Reads new handwriting into the page's search index, or nothing does.
  final CanvasTextRecognizer? recognizer;
  final HandwritingImageRenderer renderer;
  final Duration recognitionDelay;

  final ValueNotifier<EditorTool> tool;
  final ValueNotifier<PenSettings> pen;
  final ValueNotifier<EraserSettings> eraser;

  final int _startRevision;
  final Set<Stroke> _startStrokes;
  final Set<Stroke> _known;
  final Set<Stroke> _unread = Set<Stroke>.identity();
  Timer? _readTimer;
  Future<void>? _reading;
  bool _disposed = false;

  InkController get ink => document.current.ink;

  /// Whether the page differs from how it began. Saved after each change back
  /// to how it was, which is harmless, rather than comparing every stroke.
  bool get isDirty => ink.documentRevision != _startRevision;

  /// The strokes written since this began.
  List<Stroke> get annotations => <Stroke>[
    for (final Stroke stroke in ink.strokes)
      if (!_startStrokes.contains(stroke)) stroke,
  ];

  /// Takes back everything written since this began, as one step of the undo
  /// history. What was on the note already stays: this is for marks made while
  /// studying, and is no way to lose the notes they were made on.
  bool clearAnnotations() {
    final List<Stroke> added = annotations;
    if (added.isEmpty) return false;
    ink
      ..clearSelection()
      ..includeStrokesInSelection(added);
    return ink.deleteSelection();
  }

  void _onStrokesChanged() {
    if (recognizer == null || _disposed) return;
    bool added = false;
    for (final Stroke stroke in ink.strokes) {
      if (_known.add(stroke) &&
          stroke.source == StrokeSource.input &&
          !stroke.style.isHighlighter) {
        _unread.add(stroke);
        added = true;
      }
    }
    if (!added) return;
    _readTimer?.cancel();
    _readTimer = Timer(recognitionDelay, _readNow);
  }

  void _readNow() {
    _readTimer?.cancel();
    _readTimer = null;
    if (_unread.isEmpty || _disposed) return;
    final Set<Stroke> present = Set<Stroke>.identity()..addAll(ink.strokes);
    final List<Stroke> strokes = _unread.where(present.contains).toList();
    _unread.clear();
    if (strokes.isEmpty) return;
    final Future<void>? before = _reading;
    _reading =
        () async {
          await before;
          final List<RecognizedInkWord> words = await HandwritingIndexer(
            recognizer: recognizer!,
            renderer: renderer,
          ).recognize(strokes);
          if (_disposed) return;
          final Set<Stroke> now = Set<Stroke>.identity()..addAll(ink.strokes);
          for (final RecognizedInkWord word in words) {
            if (word.sourceStrokes.every(now.contains)) {
              document.addRecognizedWord(document.current, word);
            }
          }
        }().catchError((Object _) {
          // The ink is kept unread, and a question sees it as a picture.
        });
  }

  /// Ends what the pointer is doing, and reads what is yet unread, for as long
  /// as a save can reasonably be held up.
  Future<void> settle({
    Duration patience = const Duration(milliseconds: 1500),
  }) async {
    ink
      ..finalizeActiveGesture()
      ..clearSelection();
    _readNow();
    final Future<void>? reading = _reading;
    if (reading == null) return;
    await reading.timeout(patience, onTimeout: () {});
  }

  void dispose() {
    _disposed = true;
    _readTimer?.cancel();
    ink.completedStrokesListenable.removeListener(_onStrokesChanged);
    tool.dispose();
    pen.dispose();
    eraser.dispose();
  }
}

/// The live ink of a page being annotated, in the place of its picture.
class StudyInSituCanvas extends StatelessWidget {
  const StudyInSituCanvas({
    super.key,
    required this.session,
    required this.isNavigating,
    this.stylusOnly,
    this.visible,
    this.exclusionRects,
    this.enableNativeInk = true,
  });

  final StudyInSituSession session;

  /// Whether fingers are moving the page: another that lands writes nothing.
  final ValueGetter<bool> isNavigating;
  final ValueListenable<bool>? stylusOnly;
  final ValueListenable<Rect>? visible;
  final ValueGetter<List<Rect>>? exclusionRects;
  final bool enableNativeInk;

  @override
  Widget build(BuildContext context) {
    return InkCanvas(
      key: const ValueKey<String>('study-in-situ-canvas'),
      controller: session.ink,
      tool: session.tool,
      penSettings: session.pen,
      eraserSettings: session.eraser,
      isInputBlocked: isNavigating,
      stylusOnly: stylusOnly,
      visible: visible,
      exclusionRects: exclusionRects,
      enableNativeInk: enableNativeInk,
    );
  }
}

/// Moves the page under [child] while [session] writes on it: two fingers drag
/// and pinch it and leave no mark, and one does too when fingers are not for
/// writing. The wheel and trackpad move it as well. With no session this does
/// nothing, and the page is the viewer's to move.
class StudyInSituGestures extends StatefulWidget {
  const StudyInSituGestures({
    super.key,
    required this.transform,
    required this.session,
    required this.child,
    this.stylusOnly,
    this.onMoveStart,
    this.minScale = 0.1,
    this.maxScale = 8,
    this.enableNativeInk = true,
  });

  final TransformationController transform;
  final StudyInSituSession? session;
  final Widget child;
  final ValueListenable<bool>? stylusOnly;
  final VoidCallback? onMoveStart;
  final double minScale;
  final double maxScale;
  final bool enableNativeInk;

  @override
  State<StudyInSituGestures> createState() => StudyInSituGesturesState();
}

class StudyInSituGesturesState extends State<StudyInSituGestures> {
  final Map<int, Offset> _touches = <int, Offset>{};
  final Set<int> _styluses = <int>{};
  bool _moving = false;
  Matrix4? _startMatrix;
  Offset _startCentroid = Offset.zero;
  double _startSpan = 0;

  /// Whether fingers are moving the page now.
  bool get isMoving => _moving;

  int get _fingersToMove => (widget.stylusOnly?.value ?? false) ? 1 : 2;

  Offset get _centroid {
    Offset sum = Offset.zero;
    for (final Offset touch in _touches.values) {
      sum += touch;
    }
    return sum / _touches.length.toDouble();
  }

  double get _span {
    if (_touches.length < 2) return 0;
    final Offset centre = _centroid;
    double sum = 0;
    for (final Offset touch in _touches.values) {
      sum += (touch - centre).distance;
    }
    return sum / _touches.length;
  }

  void _rebase() {
    if (_touches.isEmpty) return;
    _startMatrix = widget.transform.value.clone();
    _startCentroid = _centroid;
    _startSpan = _span;
  }

  void _onDown(PointerDownEvent event) {
    final StudyInSituSession? session = widget.session;
    if (session == null) return;
    if (event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus) {
      _styluses.add(event.pointer);
      return;
    }
    if (event.kind != PointerDeviceKind.touch) return;
    _touches[event.pointer] = event.localPosition;
    if (_moving) {
      _rebase();
      return;
    }
    // A hand resting beside a pen in use is not a pinch.
    if (_touches.length < _fingersToMove || _styluses.isNotEmpty) return;
    _moving = true;
    widget.onMoveStart?.call();
    if (widget.enableNativeInk) NativeInkBridge.instance.clearLivePreview();
    // The first finger may have begun a stroke: it was the start of this.
    final InkController ink = session.ink;
    for (final int pointer in _touches.keys) {
      ink
        ..discardStroke(pointer)
        ..cancelErase(pointer)
        ..cancelSelectionGesture(pointer);
    }
    _rebase();
  }

  void _onMove(PointerMoveEvent event) {
    if (!_touches.containsKey(event.pointer)) return;
    _touches[event.pointer] = event.localPosition;
    final Matrix4? start = _startMatrix;
    if (!_moving || start == null) return;
    final double startScale = start.getMaxScaleOnAxis();
    final double scaleBy = _startSpan > 0 && _span > 0 ? _span / _startSpan : 1;
    final double scale = (startScale * scaleBy).clamp(
      widget.minScale,
      widget.maxScale,
    );
    final Offset startOrigin = Offset(
      start.getTranslation().x,
      start.getTranslation().y,
    );
    // The point of the page that was under the fingers stays under them.
    final Offset onPage = (_startCentroid - startOrigin) / startScale;
    final Offset origin = _centroid - onPage * scale;
    widget.transform.value = Matrix4.diagonal3Values(scale, scale, 1)
      ..setTranslationRaw(origin.dx, origin.dy, 0);
  }

  void _onEnd(PointerEvent event) {
    _styluses.remove(event.pointer);
    if (_touches.remove(event.pointer) == null) return;
    if (_touches.isEmpty) {
      _moving = false;
      _startMatrix = null;
    } else if (_moving) {
      _rebase();
    }
  }

  void _onSignal(PointerSignalEvent event) {
    if (widget.session == null) return;
    if (event is PointerScrollEvent) {
      final Matrix4 matrix = widget.transform.value;
      final double scale = matrix.getMaxScaleOnAxis();
      final Offset origin =
          Offset(matrix.getTranslation().x, matrix.getTranslation().y) -
          event.scrollDelta;
      widget.transform.value = Matrix4.diagonal3Values(scale, scale, 1)
        ..setTranslationRaw(origin.dx, origin.dy, 0);
    } else if (event is PointerScaleEvent) {
      final Matrix4 matrix = widget.transform.value;
      final double from = matrix.getMaxScaleOnAxis();
      final double to = math.max(
        widget.minScale,
        math.min(widget.maxScale, from * event.scale),
      );
      final Offset origin = Offset(
        matrix.getTranslation().x,
        matrix.getTranslation().y,
      );
      final Offset onPage = (event.localPosition - origin) / from;
      final Offset next = event.localPosition - onPage * to;
      widget.transform.value = Matrix4.diagonal3Values(to, to, 1)
        ..setTranslationRaw(next.dx, next.dy, 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onEnd,
      onPointerCancel: _onEnd,
      onPointerSignal: _onSignal,
      child: widget.child,
    );
  }
}
