// Pure Dart: no Flutter imports, so the smoothing engine can run anywhere.
import 'dart:math' as math;

/// A 2D point or vector in writing-surface-local logical pixels.
class InkVector {
  const InkVector(this.x, this.y);

  static const InkVector zero = InkVector(0, 0);

  final double x;
  final double y;

  bool get isFinite => x.isFinite && y.isFinite;

  double get length => math.sqrt(x * x + y * y);

  InkVector operator +(InkVector other) => InkVector(x + other.x, y + other.y);

  InkVector operator -(InkVector other) => InkVector(x - other.x, y - other.y);

  InkVector operator *(double factor) => InkVector(x * factor, y * factor);

  InkVector operator -() => InkVector(-x, -y);

  double dot(InkVector other) => x * other.x + y * other.y;

  /// This vector rotated a quarter turn: `(-y, x)`.
  InkVector get perpendicular => InkVector(-y, x);

  @override
  bool operator ==(Object other) {
    return other is InkVector && other.x == x && other.y == y;
  }

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'InkVector($x, $y)';
}

/// Kept for diagnostics only; it does not affect smoothing or width.
enum InkDeviceKind { stylus, invertedStylus, touch, mouse }

/// One unmodified pointer sample.
class RawInkSample {
  const RawInkSample({
    required this.position,
    required this.timestamp,
    this.deviceKind = InkDeviceKind.stylus,
  });

  final InkVector position;

  /// Monotonic time of the sample, as reported by the platform.
  final Duration timestamp;

  final InkDeviceKind deviceKind;
}
