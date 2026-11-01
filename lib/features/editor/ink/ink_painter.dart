import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';

import '../../../app/theme/app_tokens.dart';
import 'ink_controller.dart';
import 'ink_sample.dart';
import 'ink_selection.dart';
import 'notation_playback.dart';
import 'pencil_texture.dart';
import 'selection_config.dart';
import 'selection_transform.dart';
import 'stroke.dart';
import '../sticky/sticky_note.dart';
import '../sticky/sticky_note_painter.dart';
import '../audio/stroke_replay_controller.dart';

/// Paints one stroke the way the editor shows it: a filled disc for a dot,
/// otherwise [path] stroked [width] wide with round caps and joins, or,
/// for a stroke of varying width, its [outline] filled. Pencil strokes get
/// a deterministic broken graphite grain. Every ink layer, and the image
/// made of a selection, draws through this.
void paintInkStroke(
  Canvas canvas, {
  required Color color,
  required double width,
  required Path path,
  required InkVector origin,
  required bool isDot,
  Path? outline,
  WritingStyle writing = WritingStyle.pen,
}) {
  if (writing == WritingStyle.pencil) {
    paintPencilTexture(
      canvas,
      color: color,
      width: width,
      path: path,
      origin: origin,
      isDot: isDot,
      outline: outline,
    );
    return;
  }
  final Paint paint = Paint()
    ..color = color
    ..isAntiAlias = true;
  if (isDot) {
    canvas.drawCircle(Offset(origin.x, origin.y), width / 2, paint);
    return;
  }
  if (outline != null) {
    canvas.drawPath(outline, paint);
    return;
  }
  paint
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  canvas.drawPath(path, paint);
}

void _paintStroke(
  Canvas canvas, {
  required StrokeStyle style,
  required Path path,
  required InkVector origin,
  required bool isDot,
  required Brightness brightness,
  Path? outline,
}) {
  paintInkStroke(
    canvas,
    color: style.resolve(brightness),
    width: style.width,
    path: path,
    origin: origin,
    isDot: isDot,
    outline: outline,
    writing: style.writing,
  );
}

/// Paints the page's sticky notes, in order, above the page's completed ink,
/// except selected ones, which belong to [SelectionPainter] while they are
/// selected. The note open for writing is outlined in [accent]. Repaints
/// when the document, the selection, or the note open for writing changes;
/// never for a pointer move.
class StickyNotesPainter extends CustomPainter {
  StickyNotesPainter({
    required this.controller,
    required this.accent,
    this.config = const StickyNoteConfig(),
    this.visible,
  }) : super(
         repaint: Listenable.merge(<Listenable>[
           controller.completedStrokesListenable,
           controller.stickyEditingListenable,
           ?visible,
         ]),
       );

  final InkController controller;
  final Color accent;
  final StickyNoteConfig config;
  final ValueListenable<Rect>? visible;

  @override
  void paint(Canvas canvas, Size size) {
    final List<StickyNoteElement> notes = controller.stickyNotes;
    if (notes.isEmpty) {
      return;
    }
    final List<int> selected =
        controller.selection?.stickyIndices ?? const <int>[];
    final String? editing = controller.editingSticky?.id;
    final Rect? viewport = visible?.value.inflate(16);
    int next = 0;
    for (int i = 0; i < notes.length; i++) {
      if (next < selected.length && selected[next] == i) {
        next++;
        continue;
      }
      final StickyNoteElement note = notes[i];
      if (viewport != null && !note.bounds.overlaps(viewport)) {
        continue;
      }
      paintStickyNote(canvas, note, config: config);
      if (note.id == editing) {
        paintStickyEditingOutline(canvas, note, accent, config);
      }
    }
  }

  @override
  bool shouldRepaint(StickyNotesPainter oldDelegate) {
    return oldDelegate.controller != controller ||
        oldDelegate.accent != accent ||
        oldDelegate.config != config ||
        oldDelegate.visible != visible;
  }
}

/// The outline that marks [note] as open for writing.
void paintStickyEditingOutline(
  Canvas canvas,
  StickyNoteElement note,
  Color color,
  StickyNoteConfig config,
) {
  final Size local = note.localSize;
  canvas
    ..save()
    ..translate(note.center.x, note.center.y)
    ..rotate(note.rotation)
    ..scale(note.scale)
    ..translate(-local.width / 2, -local.height / 2)
    ..drawRRect(
      stickyPaperRect(note, config).inflate(1.5 / note.scale),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = AppSizes.focusRingWidth / note.scale
        ..isAntiAlias = true,
    )
    ..restore();
}

/// Paints finished strokes, except the selected ones, which belong to
/// [SelectionPainter] for as long as they are selected, and those of an AI
/// notation still being drawn, which belong to [NotationPlaybackPainter].
/// Repaints only when the collection, the set of selected strokes, or the
/// playback's strokes change hands; never for a playback frame.
class CompletedStrokesPainter extends CustomPainter {
  CompletedStrokesPainter({
    required this.controller,
    required this.brightness,
    this.visible,
    this.replay,
    this.replayHighlight,
  }) : super(
         repaint: Listenable.merge(<Listenable>[
           controller.completedStrokesListenable,
           controller.notationPlaybackListenable,
           ?visible,
           ?replay,
         ]),
       );

  final InkController controller;
  final Brightness brightness;
  final ValueListenable<Rect>? visible;
  final StrokeReplayController? replay;
  final Color? replayHighlight;

  @override
  void paint(Canvas canvas, Size size) {
    final List<Stroke> strokes = controller.strokes;
    final List<int> selected = controller.selection?.indices ?? const <int>[];
    final bool playing = controller.notationPlaybacks.isNotEmpty;
    final Rect? viewport = visible?.value.inflate(8);
    int next = 0;
    for (int i = 0; i < strokes.length; i++) {
      // Selected indices ascend, so one cursor walks them.
      if (next < selected.length && selected[next] == i) {
        next++;
        continue;
      }
      final Stroke stroke = strokes[i];
      if (viewport != null && !stroke.bounds.overlaps(viewport)) {
        continue;
      }
      if ((playing && controller.isPlayingStroke(stroke)) ||
          controller.isStrokeHidden(stroke)) {
        continue;
      }
      _paintReplayStroke(canvas, stroke);
    }
    final StrokeReplayController? activeReplay = replay;
    if (activeReplay != null && activeReplay.isActive) {
      for (final ErasedStrokeRecord erased in controller.erasedStrokeRecords) {
        if (activeReplay.erasedStrokeIsVisible(erased)) {
          _paintReplayStroke(canvas, erased.stroke);
        }
      }
    }
  }

  void _paintReplayStroke(Canvas canvas, Stroke stroke) {
    final StrokeReplayController? activeReplay = replay;
    final double progress = activeReplay?.revealProgress(stroke) ?? 1;
    if (progress < 1 && activeReplay != null) {
      // What is yet to be written lies in light gray under what is.
      const Color unwritten = StrokeReplayController.unwrittenColor;
      paintInkStroke(
        canvas,
        color: unwritten.withValues(alpha: unwritten.a * stroke.style.opacity),
        width: stroke.style.width,
        path: stroke.path,
        origin: stroke.points.first,
        isDot: stroke.isDot,
        outline: stroke.outline,
      );
      if (progress <= 0) return;
    }
    Path path = stroke.path;
    bool isDot = stroke.isDot;
    Path? outline = stroke.outline;
    if (progress < 1 && stroke.points.length > 1) {
      final int count = (stroke.points.length * progress).ceil().clamp(
        1,
        stroke.points.length,
      );
      path = Path()..moveTo(stroke.points.first.x, stroke.points.first.y);
      for (int i = 1; i < count; i++) {
        path.lineTo(stroke.points[i].x, stroke.points[i].y);
      }
      isDot = count == 1;
      outline = null;
    }
    if (identical(activeReplay?.highlightedStroke, stroke) &&
        replayHighlight != null) {
      paintInkStroke(
        canvas,
        color: replayHighlight!.withValues(alpha: 0.55),
        width: stroke.style.width + 8,
        path: path,
        origin: stroke.points.first,
        isDot: isDot,
      );
    }
    _paintStroke(
      canvas,
      style: stroke.style,
      path: path,
      origin: stroke.points.first,
      isDot: isDot,
      brightness: brightness,
      outline: outline,
    );
  }

  @override
  bool shouldRepaint(CompletedStrokesPainter oldDelegate) {
    return oldDelegate.controller != controller ||
        oldDelegate.brightness != brightness ||
        oldDelegate.visible != visible ||
        oldDelegate.replay != replay ||
        oldDelegate.replayHighlight != replayHighlight;
  }
}

/// Paints the AI notations while they are drawn over time: each stroke as
/// far as its playback's clock has reached, in document order, above the
/// finished ink. Selected strokes are left to [SelectionPainter]. Repaints
/// on every playback frame, which leaves the finished-ink layer alone. A
/// finished stroke is painted from its own cached path, so the last frame
/// matches the finished ink exactly; a stroke partway drawn is cut from
/// that same path.
class NotationPlaybackPainter extends CustomPainter {
  NotationPlaybackPainter({required this.controller, required this.brightness})
    : super(
        repaint: Listenable.merge(<Listenable>[
          controller.notationPlaybackListenable,
          controller.notationFrameListenable,
          controller.completedStrokesListenable,
        ]),
      );

  final InkController controller;
  final Brightness brightness;

  @override
  void paint(Canvas canvas, Size size) {
    final List<NotationPlayback> playbacks = controller.notationPlaybacks;
    if (playbacks.isEmpty) {
      return;
    }
    final List<Stroke>? selected = controller.selection?.strokes;
    final Set<Stroke> skip = HashSet<Stroke>.identity()
      ..addAll(selected ?? const <Stroke>[]);
    for (final NotationPlayback playback in playbacks) {
      _paintPlayback(canvas, playback, skip);
    }
  }

  void _paintPlayback(
    Canvas canvas,
    NotationPlayback playback,
    Set<Stroke> skip,
  ) {
    final List<Stroke> strokes = playback.strokes;
    for (int i = 0; i < strokes.length; i++) {
      final Stroke stroke = strokes[i];
      if (!playback.owns(stroke) ||
          skip.contains(stroke) ||
          controller.isStrokeHidden(stroke)) {
        continue;
      }
      // Document coordinates do not scale with the surface. The reveal can
      // therefore keep running when the assistant closes and gives the note
      // more room, or when another layout change resizes the canvas.
      final TraceReveal reveal = playback.revealAt(i);
      switch (reveal.state) {
        case TraceRevealState.hidden:
          continue;
        case TraceRevealState.complete:
          playback.releaseMeasure(i);
          _paintStroke(
            canvas,
            style: stroke.style,
            path: stroke.path,
            origin: stroke.points.first,
            isDot: stroke.isDot,
            brightness: brightness,
            outline: stroke.outline,
          );
        case TraceRevealState.partial:
          final Path? path = stroke.isDot
              ? null
              : playback.partialPath(i, reveal);
          _paintStroke(
            canvas,
            style: stroke.style,
            path: path ?? stroke.path,
            origin: stroke.points.first,
            // Touching down, before the pen has moved.
            isDot: path == null,
            brightness: brightness,
          );
      }
    }
  }

  @override
  bool shouldRepaint(NotationPlaybackPainter oldDelegate) {
    return oldDelegate.controller != controller ||
        oldDelegate.brightness != brightness;
  }
}

/// Outlines the eraser while an erase pointer is down: the true eraser size
/// in area mode, the hit radius in stroke mode. Repaints on every eraser
/// move, which leaves the ink layers alone.
class EraserIndicatorPainter extends CustomPainter {
  EraserIndicatorPainter({
    required this.controller,
    required this.color,
    required this.haloColor,
    this.scale = 1,
    this.scaleProvider,
  }) : super(repaint: controller.eraserListenable);

  static const double _outlineWidth = 1;
  static const double _haloWidth = 3;

  final InkController controller;

  /// The outline itself.
  final Color color;

  /// Drawn under the outline so it stays visible over ink of any color.
  final Color haloColor;

  /// Screen scale to prevent outline edge from becoming thicker when zoomed in.
  final double scale;

  /// Optional dynamic provider for the latest screen scale.
  final double Function()? scaleProvider;

  double _effectiveScale(EraseGesture erase) {
    final double? dynamicScale = scaleProvider?.call();
    if (dynamicScale != null && dynamicScale > 0 && dynamicScale.isFinite) {
      return dynamicScale;
    }
    if (scale > 0 && scale.isFinite) {
      return scale;
    }
    if (erase.scale > 0 && erase.scale.isFinite) {
      return erase.scale;
    }
    return 1;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final EraseGesture? erase = controller.activeErase;
    if (erase == null) {
      return;
    }
    final Offset center = Offset(erase.position.x, erase.position.y);
    final double s = _effectiveScale(erase);
    final double outlineWidth = _outlineWidth / s;
    final double haloWidth = _haloWidth / s;
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    canvas
      ..drawCircle(
        center,
        erase.radius,
        paint
          ..color = haloColor
          ..strokeWidth = haloWidth,
      )
      ..drawCircle(
        center,
        erase.radius,
        paint
          ..color = color
          ..strokeWidth = outlineWidth,
      );
  }

  @override
  bool shouldRepaint(EraserIndicatorPainter oldDelegate) {
    return oldDelegate.controller != controller ||
        oldDelegate.color != color ||
        oldDelegate.haloColor != haloColor ||
        oldDelegate.scale != scale ||
        oldDelegate.scaleProvider != scaleProvider;
  }
}

/// Paints the stroke in progress. Repaints on every accepted sample.
class ActiveStrokePainter extends CustomPainter {
  ActiveStrokePainter({required this.controller, required this.brightness})
    : super(repaint: controller.activeStrokeListenable);

  final InkController controller;
  final Brightness brightness;

  @override
  void paint(Canvas canvas, Size size) {
    final StickyPlacementGesture? placement = controller.activePlacement;
    if (placement != null) {
      // Paint the moving preview directly. Applying whole-note translucency
      // through saveLayer allocates an offscreen render target for every
      // pointer sample, which is particularly costly on tiled mobile GPUs.
      paintStickyNote(
        canvas,
        placement.preview('preview'),
        config: controller.stickyConfig,
      );
      return;
    }
    final Stroke? shape = controller.activeShape?.preview;
    if (shape != null) {
      _paintStroke(
        canvas,
        style: shape.style,
        path: shape.path,
        origin: shape.points.first,
        isDot: shape.isDot,
        brightness: brightness,
      );
      return;
    }
    final ActiveStroke? stroke = controller.activeStroke;
    if (stroke == null) {
      return;
    }
    final StickyNoteElement? sticky = controller.activeStrokeSticky;
    if (sticky != null) {
      // Into the note's own coordinates, clipped to its paper, and resolved
      // for its light paper, exactly as the finished stroke will be.
      final Size local = sticky.localSize;
      canvas
        ..save()
        ..translate(sticky.center.x, sticky.center.y)
        ..rotate(sticky.rotation)
        ..scale(sticky.scale)
        ..translate(-local.width / 2, -local.height / 2)
        ..clipRRect(stickyPaperRect(sticky, controller.stickyConfig));
      _paintStroke(
        canvas,
        style: stroke.style,
        path: stroke.path,
        origin: stroke.origin,
        isDot: stroke.isDot,
        brightness: Brightness.light,
        outline: stroke.outline,
      );
      canvas.restore();
      return;
    }
    _paintStroke(
      canvas,
      style: stroke.style,
      path: stroke.path,
      origin: stroke.origin,
      isDot: stroke.isDot,
      brightness: brightness,
      outline: stroke.outline,
    );
  }

  @override
  bool shouldRepaint(ActiveStrokePainter oldDelegate) {
    return oldDelegate.controller != controller ||
        oldDelegate.brightness != brightness;
  }
}

/// Selected strokes and sticky notes from another page, drawn through
/// [transform] so cached stroke paths are reused without rebuilding.
class CrossPageSelectionPart {
  const CrossPageSelectionPart({
    required this.transform,
    this.strokes = const <Stroke>[],
    this.stickies = const <StickyNoteElement>[],
  });

  final InkTransform transform;
  final List<Stroke> strokes;
  final List<StickyNoteElement> stickies;
}

/// Cross-page selection content and lasso outline mapped into a page's local
/// coordinates.
class CrossPageSelectionOverlay {
  const CrossPageSelectionOverlay({
    this.parts = const <CrossPageSelectionPart>[],
    this.frame,
    this.includesPdf = false,
    this.lassoLine,
  });

  final List<CrossPageSelectionPart> parts;
  final SelectionFrame? frame;
  final bool includesPdf;
  final List<Offset>? lassoLine;
}

/// Paints the selection outline while it is dragged, and the selection: its strokes, its
/// frame, and its handles. During a move, scale, or rotation the strokes are
/// drawn through the preview transform from their cached paths, so a pointer
/// move repaints this layer alone and builds no path.
class SelectionPainter extends CustomPainter {
  SelectionPainter({
    required this.controller,
    required this.brightness,
    required this.color,
    required this.handleColor,
    this.crossPageListenable,
    this.crossPageOverlay,
    this.scale = 1,
    this.scaleProvider,
  }) : super(
         repaint: crossPageListenable == null
             ? controller.selectionListenable
             : Listenable.merge(<Listenable>[
                 controller.selectionListenable,
                 crossPageListenable,
               ]),
       );

  final InkController controller;
  final Brightness brightness;

  /// The lasso, the frame, and the handle outlines.
  final Color color;

  /// Fills the handles so that ink does not show through them.
  final Color handleColor;

  /// Notifies when another page's selection or lasso changes.
  final Listenable? crossPageListenable;

  /// Supplies another page's selection or lasso in this page's coordinates.
  final ValueGetter<CrossPageSelectionOverlay?>? crossPageOverlay;

  /// Screen scale, so the frame, handles and lasso keep one size on screen
  /// however far the page is zoomed.
  final double scale;

  /// Optional dynamic provider for the latest screen scale.
  final double Function()? scaleProvider;

  double get _screenScale {
    final double? dynamicScale = scaleProvider?.call();
    if (dynamicScale != null && dynamicScale > 0 && dynamicScale.isFinite) {
      return dynamicScale;
    }
    return scale > 0 && scale.isFinite ? scale : 1;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final InkSelection? selection = controller.selection;
    final SelectionTransformGesture? gesture = controller.activeTransform;
    if (selection != null) {
      canvas.save();
      if (gesture != null) {
        canvas.transform(_matrix(gesture.transform));
      }
      for (final Stroke stroke in selection.strokes) {
        if (controller.isStrokeHidden(stroke)) {
          continue;
        }
        _paintStroke(
          canvas,
          style: stroke.style,
          path: stroke.path,
          origin: stroke.points.first,
          isDot: stroke.isDot,
          brightness: brightness,
          outline: stroke.outline,
        );
      }
      // Selected sticky notes above the selected ink, as on the page.
      for (final StickyNoteElement note in selection.stickies) {
        paintStickyNote(canvas, note, config: controller.stickyConfig);
      }
      canvas.restore();
    }
    final CrossPageSelectionOverlay? extra = crossPageOverlay?.call();
    if (extra != null) {
      for (final CrossPageSelectionPart part in extra.parts) {
        canvas.save();
        canvas.transform(_matrix(part.transform));
        for (final Stroke stroke in part.strokes) {
          _paintStroke(
            canvas,
            style: stroke.style,
            path: stroke.path,
            origin: stroke.points.first,
            isDot: stroke.isDot,
            brightness: brightness,
            outline: stroke.outline,
          );
        }
        for (final StickyNoteElement note in part.stickies) {
          paintStickyNote(canvas, note, config: controller.stickyConfig);
        }
        canvas.restore();
      }
    }
    final SelectionFrame? frame =
        extra?.frame ??
        (selection == null ? null : (gesture?.frame ?? selection.frame));
    if (frame != null) {
      _paintFrame(
        canvas,
        frame,
        handles: !(selection?.includesPdf ?? extra?.includesPdf ?? false),
      );
    }
    final LassoGesture? lasso = controller.activeLasso;
    if (lasso != null) {
      _paintLasso(canvas, lasso);
    } else if (extra?.lassoLine != null) {
      _paintLassoLine(canvas, extra!.lassoLine!);
    }
  }

  void _paintFrame(
    Canvas canvas,
    SelectionFrame frame, {
    required bool handles,
  }) {
    final SelectionConfig config = controller.selectionConfig;
    final double s = _screenScale;
    final List<Offset> corners = <Offset>[
      for (final InkVector corner in frame.corners) _offset(corner),
    ];
    final Offset handle = _offset(
      frame.rotationHandle(config.rotationHandleOffset),
    );
    final Paint outline = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = AppSizes.hairline / s
      ..isAntiAlias = true;
    canvas.drawPath(Path()..addPolygon(corners, true), outline);
    if (!handles) return;
    canvas.drawLine(_offset(frame.topCenter), handle, outline);

    final Paint fill = Paint()
      ..color = handleColor
      ..isAntiAlias = true;
    outline.strokeWidth = AppSizes.focusRingWidth / s;
    final double radius = config.handleVisualRadius / s;
    for (final Offset center in <Offset>[...corners, handle]) {
      canvas
        ..drawCircle(center, radius, fill)
        ..drawCircle(center, radius, outline);
    }
  }

  /// A dashed outline: the rectangle of a straight drag, or the loop drawn
  /// so far. The loop is left open; no edge is drawn back to its start.
  void _paintLasso(Canvas canvas, LassoGesture lasso) {
    final List<Offset> line;
    switch (lasso.shape) {
      case LassoShape.rectangle:
        final List<InkVector> corners = lasso.outline;
        line = <Offset>[
          for (final InkVector corner in corners) _offset(corner),
          _offset(corners.first),
        ];
      case LassoShape.freeform:
        line = <Offset>[
          for (final InkVector point in lasso.points) _offset(point),
          _offset(lasso.tip),
        ];
    }
    _paintLassoLine(canvas, line);
  }

  void _paintLassoLine(Canvas canvas, List<Offset> line) {
    if (line.length < 2) {
      return;
    }
    final SelectionConfig config = controller.selectionConfig;
    final double s = _screenScale;
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = AppSizes.focusRingWidth / s
      ..isAntiAlias = true;
    canvas.drawPath(
      _dashed(line, config.lassoDashLength / s, config.lassoDashGap / s),
      paint,
    );
  }

  /// The polyline through [line], cut into dashes that run on across its
  /// corners.
  static Path _dashed(List<Offset> line, double dash, double gap) {
    final Path path = Path();
    // How far into the current dash-and-gap cycle the line has got.
    double phase = 0;
    for (int i = 0; i < line.length - 1; i++) {
      final Offset from = line[i];
      final Offset delta = line[i + 1] - from;
      final double length = delta.distance;
      if (length <= 0) {
        continue;
      }
      double travelled = 0;
      while (travelled < length) {
        final bool drawing = phase < dash;
        final double step = math.min(
          (drawing ? dash : dash + gap) - phase,
          length - travelled,
        );
        if (drawing) {
          path
            ..moveTo(
              from.dx + delta.dx * travelled / length,
              from.dy + delta.dy * travelled / length,
            )
            ..lineTo(
              from.dx + delta.dx * (travelled + step) / length,
              from.dy + delta.dy * (travelled + step) / length,
            );
        }
        travelled += step;
        phase += step;
        if (phase >= dash + gap) {
          phase = 0;
        }
      }
    }
    return path;
  }

  static Offset _offset(InkVector vector) => Offset(vector.x, vector.y);

  /// [transform] as a column-major 4x4 matrix.
  static Float64List _matrix(InkTransform transform) {
    return Float64List(16)
      ..[0] = transform.a
      ..[1] = transform.b
      ..[4] = -transform.b
      ..[5] = transform.a
      ..[10] = 1
      ..[12] = transform.tx
      ..[13] = transform.ty
      ..[15] = 1;
  }

  @override
  bool shouldRepaint(SelectionPainter oldDelegate) {
    return oldDelegate.controller != controller ||
        oldDelegate.brightness != brightness ||
        oldDelegate.color != color ||
        oldDelegate.handleColor != handleColor ||
        oldDelegate.crossPageListenable != crossPageListenable ||
        oldDelegate.crossPageOverlay != crossPageOverlay ||
        oldDelegate.scale != scale ||
        oldDelegate.scaleProvider != scaleProvider;
  }
}
