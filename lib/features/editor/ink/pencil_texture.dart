import 'dart:math' as math;
import 'dart:ui';

import 'ink_sample.dart';

/// Paints a stable graphite texture over a stroke.
///
/// The texture is made from many short deposits across the full nib width,
/// like graphite catching on paper fibres. It uses only Flutter's canvas
/// primitives, so the same stroke is reproduced on every supported platform
/// and in previews, thumbnails, snapshots, and image exports.
void paintPencilTexture(
  Canvas canvas, {
  required Color color,
  required double width,
  required Path path,
  required InkVector origin,
  required bool isDot,
  Path? outline,
}) {
  if (isDot) {
    _paintGraphiteDot(canvas, color, width, origin);
    return;
  }

  final Paint body = Paint()
    ..color = color.withValues(alpha: color.a * 0.24)
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

  final List<Path> deposits = List<Path>.generate(3, (_) => Path());
  int state = _seed(origin, width);
  double randomUnit() {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    return state / 0x7fffffff;
  }

  final double radius = math.max(0.35, width / 2);
  final double spacing = (width * 0.17).clamp(0.42, 1.15);
  final int density = (width * 1.4).ceil().clamp(3, 14);
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
        // Adding two random values concentrates graphite toward the middle,
        // while still leaving the softly broken edge of a real pencil mark.
        final double across = (randomUnit() + randomUnit() - 1) * radius * 0.94;
        final double along = (randomUnit() - 0.5) * spacing;
        final Offset start =
            tangent.position + direction * along + normal * across;
        final double length = spacing * (0.3 + randomUnit() * 1.15);
        final Offset end =
            start +
            direction * length +
            normal * ((randomUnit() - 0.5) * width * 0.08);
        final int strength = randomUnit() < 0.18
            ? 2
            : randomUnit() < 0.48
            ? 1
            : 0;
        deposits[strength]
          ..moveTo(start.dx, start.dy)
          ..lineTo(end.dx, end.dy);
      }
      distance += spacing;
    }
  }

  const List<double> opacity = <double>[0.18, 0.29, 0.43];
  const List<double> thickness = <double>[0.075, 0.105, 0.14];
  for (int i = 0; i < deposits.length; i++) {
    canvas.drawPath(
      deposits[i],
      Paint()
        ..color = color.withValues(alpha: color.a * opacity[i])
        ..style = PaintingStyle.stroke
        ..strokeWidth = (width * thickness[i]).clamp(0.22, 0.9)
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
  InkVector origin,
) {
  final Offset center = Offset(origin.x, origin.y);
  final double radius = width / 2;
  canvas.drawCircle(
    center,
    radius,
    Paint()
      ..color = color.withValues(alpha: color.a * 0.24)
      ..isAntiAlias = true,
  );

  int state = _seed(origin, width);
  double randomUnit() {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    return state / 0x7fffffff;
  }

  final List<List<Offset>> deposits = List<List<Offset>>.generate(
    3,
    (_) => <Offset>[],
  );
  final int count = math.max(8, (width * width * 1.7).round());
  for (int i = 0; i < count; i++) {
    final double distance = math.sqrt(randomUnit()) * radius * 0.9;
    final double angle = randomUnit() * math.pi * 2;
    final int strength = randomUnit() < 0.16
        ? 2
        : randomUnit() < 0.46
        ? 1
        : 0;
    deposits[strength].add(
      center + Offset(math.cos(angle), math.sin(angle)) * distance,
    );
  }

  const List<double> opacity = <double>[0.20, 0.32, 0.48];
  for (int i = 0; i < deposits.length; i++) {
    canvas.drawPoints(
      PointMode.points,
      deposits[i],
      Paint()
        ..color = color.withValues(alpha: color.a * opacity[i])
        ..strokeWidth = (width * (0.08 + i * 0.025)).clamp(0.25, 0.8)
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
