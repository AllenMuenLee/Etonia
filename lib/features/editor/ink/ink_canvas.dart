import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../../app/theme/app_tokens.dart';
import '../ai/ai_canvas_input.dart';
import 'eraser_settings.dart';
import 'ink_controller.dart';
import 'ink_painter.dart';
import 'ink_sample.dart';
import 'notation_playback_layer.dart';
import 'pen_settings.dart';
import 'shape_config.dart';
import 'shape_recognizer.dart';
import 'ink_selection.dart';
import 'stroke.dart';
import 'stroke_follower.dart';
import '../sticky/sticky_note.dart';

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
    this.isInputBlocked,
    this.pastePrompt,
    this.stylusOnly,
    this.selectablePdfBounds,
    this.stickySettings,
    this.onStickyPlaced,
    this.pageGrows = false,
    this.aiInput,
  });

  /// Where writing goes with [EditorTool.ai]: a glowing stroke for the
  /// assistant, never ink. Without it the AI tool writes nothing.
  final AiCanvasInputController? aiInput;

  /// The look the Sticky note tool gives a new note.
  final ValueListenable<StickyNoteSettings>? stickySettings;

  /// Called once a sticky note has been placed, so the writing tool can
  /// come back for writing on it.
  final VoidCallback? onStickyPlaced;

  /// Whether the page grows to the right and down, as an infinite page
  /// does, so a sticky note placed near those edges is not pushed back.
  final bool pageGrows;

  final InkController controller;

  /// What a pointer does. An inverted stylus erases whatever this says.
  final ValueListenable<EditorTool> tool;

  final ValueListenable<PenSettings> penSettings;
  final ValueListenable<EraserSettings> eraserSettings;

  /// Supplies the highlighter's opacity.
  final PenConfig penConfig;
  final EraserConfig eraserConfig;
  final ShapeConfig shapeConfig;

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

  @override
  State<InkCanvas> createState() => _InkCanvasState();
}

class _InkCanvasState extends State<InkCanvas> with WidgetsBindingObserver {
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.tool.addListener(_onToolChanged);
  }

  @override
  void didUpdateWidget(InkCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tool != widget.tool) {
      oldWidget.tool.removeListener(_onToolChanged);
      widget.tool.addListener(_onToolChanged);
    }
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _shapeTimer?.cancel();
    widget.tool.removeListener(_onToolChanged);
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
    widget.aiInput?.cancelActive();
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
    if (pointer == null || widget.controller.selectionPointer != pointer) {
      return;
    }
    widget.controller.cancelSelectionGesture(pointer);
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
    _endGesture();
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

  void _onPointerDown(PointerDownEvent event) {
    final InkDeviceKind? kind = _deviceKind(event);
    if (kind == null) {
      return;
    }
    if (kind == InkDeviceKind.touch && (widget.stylusOnly?.value ?? false)) {
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
      // Begun on the note open for writing, the eraser erases its ink
      // only; anywhere else, the page's.
      controller.startErase(
        pointer: event.pointer,
        position: position,
        settings: widget.eraserSettings.value,
        config: widget.eraserConfig,
        screenScale: _screenScale(),
        inSticky: onEditing ? editing : null,
      );
      return;
    }
    if (widget.tool.value == EditorTool.ai) {
      if (!controller.isBusy) {
        widget.aiInput?.begin(event.pointer, controller, _sample(event, kind));
      }
      return;
    }
    if (widget.tool.value == EditorTool.sticky) {
      final RenderObject? box = context.findRenderObject();
      final Size size = box is RenderBox && box.hasSize ? box.size : Size.zero;
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
      final bool began = widget.controller.beginSelectionGesture(
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
    final PenSettings pen = widget.penSettings.value;
    // Pen and Highlighter share the capture and smoothing; the highlighter
    // is even along its length, and never follows ink or becomes a shape.
    final bool began = controller.startStroke(
      pointer: event.pointer,
      sample: _sample(event, kind),
      style: pen.strokeStyle(widget.penConfig),
      dynamics: pen.dynamics,
      smoothingConfig: pen.smoothing(controller.smoothing),
      follower: pen.followsStrokes && !onEditing ? _follower() : null,
      intoSticky: onEditing ? editing : null,
    );
    if (began && pen.armsHoldToShape && !onEditing) {
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

  /// Remembers a tap that left a dot on a sticky note, for a double tap.
  void _recordStickyTap(PointerUpEvent event) {
    final InkController controller = widget.controller;
    final Stroke? dot = controller.lastStroke;
    if (dot == null || !dot.isDot) {
      _lastStickyTap = null;
      return;
    }
    final InkVector at = dot.points.first;
    final StickyNoteElement? sticky = controller.stickyAt(at);
    _lastStickyTap = sticky == null
        ? null
        : _StickyTap(
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
    if (event.pointer == _consumedPointer) {
      return;
    }
    if (_isWritingForAi(event)) {
      widget.aiInput!.add(event.pointer, _samples(event));
      return;
    }
    if (_isPlacing(event)) {
      widget.controller.updateStickyPlacement(event.pointer, _position(event));
      return;
    }
    if (_isAdjustingShape(event)) {
      widget.controller.adjustShape(event.pointer, _position(event));
    } else if (_isErasing(event)) {
      widget.controller.eraseTo(event.pointer, _position(event));
    } else if (_isSelecting(event)) {
      final double slop = widget.controller.selectionConfig.pasteHoldSlop;
      if (event.pointer == _holdPointer &&
          (event.localPosition - _holdOrigin).distance > slop) {
        _cancelHold();
      }
      widget.controller.updateSelectionGesture(event.pointer, _position(event));
    } else {
      widget.controller.addSamples(event.pointer, _samples(event));
      _trackShapeHold(event);
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer == _consumedPointer) {
      _consumedPointer = null;
      return;
    }
    if (event.pointer == _holdPointer) {
      _cancelHold();
    }
    if (event.pointer == _shapePointer) {
      _cancelShapeHold();
    }
    if (_isWritingForAi(event)) {
      widget.aiInput!.end(event.pointer, _samples(event));
      return;
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
    if (_isAdjustingShape(event)) {
      widget.controller.endShapeAdjust(event.pointer, _position(event));
    } else if (_isErasing(event)) {
      widget.controller.endErase(event.pointer, _position(event));
    } else if (_isSelecting(event)) {
      widget.controller.endSelectionGesture(
        event.pointer,
        _position(event),
        widget.selectablePdfBounds,
      );
    } else {
      final bool onPage =
          widget.controller.activePointer == event.pointer &&
          widget.controller.activeStrokeSticky == null;
      widget.controller.endStroke(event.pointer, _samples(event));
      if (onPage) {
        _recordStickyTap(event);
      }
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer == _consumedPointer) {
      _consumedPointer = null;
    }
    // A placement not lifted into place inserts nothing.
    widget.controller.cancelStickyPlacement(event.pointer);
    widget.aiInput?.cancel(event.pointer);
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

  bool _isWritingForAi(PointerEvent event) {
    final AiCanvasInputController? input = widget.aiInput;
    return input != null &&
        input.activePointer == event.pointer &&
        identical(input.page, widget.controller);
  }

  bool _isPlacing(PointerEvent event) {
    return widget.controller.activePlacement?.pointer == event.pointer;
  }

  bool _isAdjustingShape(PointerEvent event) {
    return widget.controller.activeShape?.pointer == event.pointer;
  }

  bool _isErasing(PointerEvent event) {
    return widget.controller.activeErase?.pointer == event.pointer;
  }

  bool _isSelecting(PointerEvent event) {
    return widget.controller.selectionPointer == event.pointer;
  }

  /// All samples carried by [event].
  ///
  /// Flutter delivers one sample per event: Android's batched historical
  /// samples arrive as separate move events and iOS coalesced touches are not
  /// exposed to the framework. This is the single place to unpack them if an
  /// API appears.
  List<RawInkSample> _samples(PointerEvent event) {
    final InkDeviceKind? kind = _deviceKind(event);
    return kind == null
        ? const <RawInkSample>[]
        : <RawInkSample>[_sample(event, kind)];
  }

  RawInkSample _sample(PointerEvent event, InkDeviceKind kind) {
    return RawInkSample(
      position: _position(event),
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
  /// How close on screen the pen comes to ink to follow it, and how far
  /// it moves away to be let go, whatever the zoom.
  static const double _followCapture = 10;
  static const double _followRelease = 26;

  StrokeFollower _follower() {
    final double scale = _screenScale();
    return StrokeFollower(
      <List<InkVector>>[
        for (final Stroke stroke in widget.controller.strokes) stroke.points,
      ],
      captureRadius: _followCapture / scale,
      releaseRadius: _followRelease / scale,
    );
  }

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
    final Brightness brightness = Theme.of(context).brightness;
    final AppColors colors = AppColors.of(context);
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
            // Sticky notes lie above images and below the page's ink.
            RepaintBoundary(
              child: CustomPaint(
                key: const ValueKey<String>('sticky-notes-layer'),
                painter: StickyNotesPainter(
                  controller: widget.controller,
                  accent: colors.accent,
                  config: widget.controller.stickyConfig,
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
            RepaintBoundary(
              child: CustomPaint(
                painter: CompletedStrokesPainter(
                  controller: widget.controller,
                  brightness: brightness,
                ),
              ),
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
                  ),
                ),
              ),
            ),
            // What is written for the assistant glows above everything
            // else, and repaints alone as it is written.
            if (widget.aiInput != null)
              ExcludeSemantics(
                child: RepaintBoundary(
                  child: CustomPaint(
                    key: const ValueKey<String>('ai-canvas-stroke-layer'),
                    painter: AiCanvasStrokePainter(
                      input: widget.aiInput!,
                      page: widget.controller,
                      color: colors.accent,
                      core: Color.lerp(
                        colors.accent,
                        const Color(0xFFFFFFFF),
                        0.7,
                      )!,
                      width: widget.aiInput!.config.glowWidth,
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
                  ),
                ),
              ),
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
