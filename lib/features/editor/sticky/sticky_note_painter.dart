import 'dart:math' as math;
import 'dart:ui';

import '../ink/ink_painter.dart';
import '../ink/ink_sample.dart';
import '../ink/stroke.dart';
import 'sticky_note.dart';

/// A sticky note's pattern, in its own coordinates: whole rules and dots
/// only, laid out from the top-left corner so the pattern stays anchored to
/// the paper wherever it moves. A rule or dot past the far edge is left
/// out, and the last row is clipped by the paper rather than the pattern
/// being shifted to fit.
class StickyPattern {
  const StickyPattern({
    this.lines = const <(InkVector, InkVector)>[],
    this.dots = const <InkVector>[],
  });

  /// Rules and grid lines, as their two ends.
  final List<(InkVector, InkVector)> lines;
  final List<InkVector> dots;

  static const StickyPattern none = StickyPattern();

  /// The pattern of [style] on paper [local] units in size. At most
  /// [StickyNoteConfig.maxPatternMarks] marks, whatever the input.
  factory StickyPattern.of(
    StickyPaperStyle style,
    Size local,
    StickyNoteConfig config,
  ) {
    final double spacing = config.patternSpacing;
    if (style == StickyPaperStyle.blank ||
        !local.isFinite ||
        local.isEmpty ||
        !(spacing > 0)) {
      return none;
    }
    final int limit = config.maxPatternMarks;
    final int columns = math.min(limit, (local.width / spacing).ceil());
    final int rows = math.min(limit, (local.height / spacing).ceil());
    switch (style) {
      case StickyPaperStyle.blank:
        return none;
      case StickyPaperStyle.lined:
        final double inset = math.min(config.contentPadding, local.width / 4);
        return StickyPattern(
          lines: <(InkVector, InkVector)>[
            for (int j = 1; j < rows && j <= limit; j++)
              (
                InkVector(inset, j * spacing),
                InkVector(local.width - inset, j * spacing),
              ),
          ],
        );
      case StickyPaperStyle.grid:
        final List<(InkVector, InkVector)> lines = <(InkVector, InkVector)>[];
        for (int j = 1; j < rows && lines.length < limit; j++) {
          lines.add((
            InkVector(0, j * spacing),
            InkVector(local.width, j * spacing),
          ));
        }
        for (int i = 1; i < columns && lines.length < limit; i++) {
          lines.add((
            InkVector(i * spacing, 0),
            InkVector(i * spacing, local.height),
          ));
        }
        return StickyPattern(lines: lines);
      case StickyPaperStyle.dotted:
        final List<InkVector> dots = <InkVector>[];
        for (int j = 1; j < rows && dots.length < limit; j++) {
          for (int i = 1; i < columns && dots.length < limit; i++) {
            dots.add(InkVector(i * spacing, j * spacing));
          }
        }
        return StickyPattern(dots: dots);
    }
  }
}

/// Paints [note] the same way wherever it appears: the editor, library
/// thumbnails, and images for the assistant. Its paper, pattern, and ink
/// are clipped to its rounded rectangle; only the shadow reaches outside.
///
/// The paper is always light, so the note's ink is resolved for light
/// paper whatever the app's theme; a highlighter's opacity is applied
/// once, by [StrokeStyle.resolve].
///
/// A minimized note is only its top-left corner of paper. [showToggle] adds
/// its minimize button, which belongs on the editor's page and nowhere else.
void paintStickyNote(
  Canvas canvas,
  StickyNoteElement note, {
  StickyNoteConfig config = const StickyNoteConfig(),
  bool shadow = true,
  Color shadowColor = const Color(0xFF000000),
  void Function(Canvas canvas)? paintAboveInk,
  bool showToggle = false,
}) {
  if (!note.isValid) {
    return;
  }
  final Size local = note.localSize;
  final RRect paper = stickyPaperRect(note, config);
  canvas
    ..save()
    ..translate(note.center.x, note.center.y)
    ..rotate(note.rotation)
    ..scale(note.scale)
    ..translate(-local.width / 2, -local.height / 2);
  if (shadow) {
    canvas.drawShadow(
      Path()..addRRect(paper),
      shadowColor.withValues(alpha: 0.5),
      config.shadowElevation / note.scale,
      false,
    );
  }
  final StickyPaperColor color = note.color;
  canvas
    ..drawRRect(paper, Paint()..color = color.paper)
    ..save()
    ..clipRRect(paper);
  if (!note.minimized) {
    _paintPattern(canvas, note, config, color.pattern);
    for (final Stroke stroke in note.strokes) {
      paintInkStroke(
        canvas,
        color: stroke.style.resolve(Brightness.light),
        width: stroke.style.width,
        path: stroke.path,
        origin: stroke.points.first,
        isDot: stroke.isDot,
        outline: stroke.outline,
        writing: stroke.style.writing,
      );
    }
  }
  paintAboveInk?.call(canvas);
  if (showToggle) {
    _paintToggle(canvas, note, config, color);
  }
  canvas.restore();
  canvas
    ..drawRRect(
      paper.deflate(0.25 / note.scale),
      Paint()
        ..color = color.edge
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5 / note.scale
        ..isAntiAlias = true,
    )
    ..restore();
}

/// The paper's rounded rectangle, in the note's own coordinates.
RRect stickyPaperRect(StickyNoteElement note, StickyNoteConfig config) {
  final Size local = note.paperLocalSize;
  final double radius = math.min(
    config.cornerRadius,
    math.min(local.width, local.height) / 2,
  );
  return RRect.fromRectAndRadius(Offset.zero & local, Radius.circular(radius));
}

/// The minimize button, in the note's own coordinates: a dash on an open
/// note, a small square on a minimized one.
void _paintToggle(
  Canvas canvas,
  StickyNoteElement note,
  StickyNoteConfig config,
  StickyPaperColor color,
) {
  final Offset middle = Offset(config.toggleCenter, config.toggleCenter);
  final Paint glyph = Paint()
    ..color = color.control
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.6
    ..strokeCap = StrokeCap.round
    ..isAntiAlias = true;
  canvas.drawCircle(
    middle,
    config.toggleRadius,
    Paint()
      ..color = color.control.withValues(alpha: 0.14)
      ..isAntiAlias = true,
  );
  if (note.minimized) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: middle, width: 10, height: 10),
        const Radius.circular(2),
      ),
      glyph,
    );
  } else {
    canvas.drawLine(
      middle - const Offset(5, 0),
      middle + const Offset(5, 0),
      glyph,
    );
  }
}

void _paintPattern(
  Canvas canvas,
  StickyNoteElement note,
  StickyNoteConfig config,
  Color color,
) {
  final StickyPattern pattern = StickyPattern.of(
    note.paper,
    note.localSize,
    config,
  );
  if (pattern.lines.isNotEmpty) {
    final Path path = Path();
    for (final (InkVector a, InkVector b) in pattern.lines) {
      path
        ..moveTo(a.x, a.y)
        ..lineTo(b.x, b.y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = config.ruleWidth
        ..isAntiAlias = true,
    );
  }
  if (pattern.dots.isNotEmpty) {
    final Path path = Path();
    for (final InkVector dot in pattern.dots) {
      path.addOval(
        Rect.fromCircle(center: Offset(dot.x, dot.y), radius: config.dotRadius),
      );
    }
    canvas.drawPath(path, Paint()..color = color);
  }
}
