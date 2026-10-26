import 'dart:math' as math;
import 'dart:ui';

import 'ink_sample.dart';

/// How opaque each strength of graphite dot is, lightest first.
const List<double> _dotOpacity = <double>[0.2, 0.42, 0.72];

/// A dot's diameter by strength, as a share of the base dot: the darker the
/// dot, the finer the point of graphite that left it.
const List<double> _dotScale = <double>[1.15, 0.95, 0.75];

/// Paints a stable graphite texture over a stroke.
///
/// The stroke is made of many round dots of graphite scattered across its
/// whole width and along its length. Dots overlap and so join into one mark;
/// some are darker and some lighter, which gives the grain. It uses only
/// Flutter's canvas primitives, so the same stroke is reproduced on every
/// supported platform and in previews, thumbnails, snapshots, and image
/// exports, and a stroke being drawn looks as it will when finished.
void paintPencilTexture(
  Canvas canvas, {
  required Color color,
  required double width,
  required Path path,
  required InkVector origin,
  required bool isDot,
  Path? outline,
}) {
  final double dot = (width * 0.2).clamp(0.55, 2.4);
  if (isDot) {
    _paintGraphiteDot(canvas, color, width, dot, origin);
    return;
  }

  // A faint ground keeps the dots from reading as separate specks.
  final Paint body = Paint()
    ..color = color.withValues(alpha: color.a * 0.1)
    ..isAntiAlias = true;

  if (outline != null) {
    canvas
      ..save()
      ..clipPath(outline)
      ..drawPath(outline, body);
  } else {
    canvas.drawPath(
      path,
      body
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  final List<List<Offset>> dots = List<List<Offset>>.generate(
    _dotOpacity.length,
    (_) => <Offset>[],
  );
  int state = _seed(origin, width);
  double randomUnit() {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    return state / 0x7fffffff;
  }

  final double radius = math.max(0.3, width / 2 - dot * 0.35);
  // Close enough along the stroke that neighbouring dots overlap.
  final double spacing = (dot * 0.55).clamp(0.3, 1.2);
  final int density = (width * 1.6 / dot).ceil().clamp(3, 18);
  for (final PathMetric metric in path.computeMetrics()) {
    double distance = randomUnit() * spacing;
    while (distance < metric.length) {
      final Tangent? tangent = metric.getTangentForOffset(distance);
      if (tangent == null) {
        break;
      }
      final Offset direction = Offset(
        math.cos(tangent.angle),
        math.sin(tangent.angle),
      );
      final Offset normal = Offset(-direction.dy, direction.dx);
      for (int i = 0; i < density; i++) {
        final double across = (randomUnit() * 2 - 1) * radius;
        final double along = (randomUnit() - 0.5) * spacing * 2;
        final double pick = randomUnit();
        final int strength = pick < 0.22
            ? 2
            : pick < 0.58
            ? 1
            : 0;
        dots[strength].add(
          tangent.position + direction * along + normal * across,
        );
      }
      distance += spacing;
    }
  }

  for (int i = 0; i < dots.length; i++) {
    canvas.drawPoints(
      PointMode.points,
      dots[i],
      Paint()
        ..color = color.withValues(alpha: color.a * _dotOpacity[i])
        ..strokeWidth = dot * _dotScale[i]
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
  }

  if (outline != null) {
    canvas.restore();
  }
}

void _paintGraphiteDot(
  Canvas canvas,
  Color color,
  double width,
  double dot,
  InkVector origin,
) {
  final Offset center = Offset(origin.x, origin.y);
  final double radius = width / 2;
  canvas.drawCircle(
    center,
    radius,
    Paint()
      ..color = color.withValues(alpha: color.a * 0.1)
      ..isAntiAlias = true,
  );

  int state = _seed(origin, width);
  double randomUnit() {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    return state / 0x7fffffff;
  }

  final List<List<Offset>> dots = List<List<Offset>>.generate(
    _dotOpacity.length,
    (_) => <Offset>[],
  );
  final double reach = math.max(0.3, radius - dot * 0.35);
  final int count = math.max(10, (width * width * 2.2 / (dot * dot)).round());
  for (int i = 0; i < count; i++) {
    final double distance = math.sqrt(randomUnit()) * reach;
    final double angle = randomUnit() * math.pi * 2;
    final double pick = randomUnit();
    final int strength = pick < 0.22
        ? 2
        : pick < 0.58
        ? 1
        : 0;
    dots[strength].add(
      center + Offset(math.cos(angle), math.sin(angle)) * distance,
    );
  }

  for (int i = 0; i < dots.length; i++) {
    canvas.drawPoints(
      PointMode.points,
      dots[i],
      Paint()
        ..color = color.withValues(alpha: color.a * _dotOpacity[i])
        ..strokeWidth = dot * _dotScale[i]
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
  }
}

int _seed(InkVector origin, double width) {
  final int x = (origin.x * 16).round();
  final int y = (origin.y * 16).round();
  final int w = (width * 32).round();
  return (x * 73856093 ^ y * 19349663 ^ w * 83492791) & 0x7fffffff;
}
