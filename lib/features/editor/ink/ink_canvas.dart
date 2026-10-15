import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../../app/theme/app_tokens.dart';
import 'eraser_settings.dart';
import 'ink_controller.dart';
import 'ink_painter.dart';
import 'ink_sample.dart';
import 'notation_playback_layer.dart';
import 'pen_settings.dart';
import 'shape_config.dart';
import 'shape_recognizer.dart';
import 'stroke.dart';

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
    this.eraserConfig = const EraserConfig(),
    this.shapeConfig = const ShapeConfig(),
    this.isInputBlocked,
    this.pastePrompt,
    this.stylusOnly,
    this.selectablePdfBounds,
  });

  final InkController controller;

  /// What a pointer does. An inverted stylus erases whatever this says.
  final ValueListenable<EditorTool> tool;

  final ValueListenable<PenSettings> penSettings;
  final ValueListenable<EraserSettings> eraserSettings;
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
  void _onToolChanged() {
    _endGesture();
    widget.pastePrompt?.value = null;
    if (widget.tool.value != EditorTool.select) {
      widget.controller.clearSelection();
    }
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
    if (kind == InkDeviceKind.invertedStylus ||
        widget.tool.value == EditorTool.eraser) {
      widget.controller.startErase(
        pointer: event.pointer,
        position: _position(event),
        settings: widget.eraserSettings.value,
        config: widget.eraserConfig,
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
    final PenSettings pen = widget.penSettings.value;
    final bool began = widget.controller.startStroke(
      pointer: event.pointer,
      sample: _sample(event, kind),
      style: StrokeStyle(ink: pen.ink, width: pen.width),
    );
    if (began) {
      _cancelShapeHold();
      _shapePointer = event.pointer;
      _shapeAnchor = event.localPosition;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
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
    if (event.pointer == _holdPointer) {
      _cancelHold();
    }
    if (event.pointer == _shapePointer) {
      _cancelShapeHold();
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
      widget.controller.endStroke(event.pointer, _samples(event));
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
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
    );
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
