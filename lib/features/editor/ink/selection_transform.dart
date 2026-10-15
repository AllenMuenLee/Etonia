// Pure Dart: no Flutter imports, so the transform math can run anywhere.
import 'dart:math' as math;

import 'ink_sample.dart';

/// A move, a rotation, and a uniform scale of the page, combined:
///
///     x' = a * x - b * y + tx
///     y' = b * x + a * y + ty
///
/// with `a = scale * cos(angle)` and `b = scale * sin(angle)`. It cannot
/// skew, mirror, or stretch one axis more than the other. This is the source
/// of truth for a transform; the matrix handed to the renderer for a preview
/// is derived from it.
class InkTransform {
  const InkTransform._(this.a, this.b, this.tx, this.ty, this.scale);

  static const InkTransform identity = InkTransform._(1, 0, 0, 0, 1);

  /// Moves every point by [delta].
  factory InkTransform.translation(InkVector delta) {
    return InkTransform._(1, 0, delta.x, delta.y, 1);
  }

  /// Turns the page by [angle] radians around [center]. Positive angles turn
  /// the x axis towards the y axis: clockwise on a page whose y grows down.
  factory InkTransform.rotation(InkVector center, double angle) {
    final double a = math.cos(angle);
    final double b = math.sin(angle);
    return InkTransform._(
      a,
      b,
      center.x - a * center.x + b * center.y,
      center.y - b * center.x - a * center.y,
      1,
    );
  }

  /// Scales the page by [factor] around [fixed], which stays where it is.
  factory InkTransform.scaling(InkVector fixed, double factor) {
    return InkTransform._(
      factor,
      0,
      fixed.x - factor * fixed.x,
      fixed.y - factor * fixed.y,
      factor,
    );
  }

  final double a;
  final double b;
  final double tx;
  final double ty;

  /// The uniform scale factor. Stroke widths are multiplied by it.
  final double scale;

  /// The rotation, in radians, in `-pi..pi`.
  double get angle => math.atan2(b, a);

  bool get isFinite {
    return a.isFinite &&
        b.isFinite &&
        tx.isFinite &&
        ty.isFinite &&
        scale.isFinite &&
        scale > 0;
  }

  InkVector apply(InkVector point) {
    return InkVector(
      a * point.x - b * point.y + tx,
      b * point.x + a * point.y + ty,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is InkTransform &&
        other.a == a &&
        other.b == b &&
        other.tx == tx &&
        other.ty == ty &&
        other.scale == scale;
  }

  @override
  int get hashCode => Object.hash(a, b, tx, ty, scale);

  @override
  String toString() => 'InkTransform($a, $b, $tx, $ty, scale: $scale)';
}

/// What a pointer does to a selection.
enum SelectionOperation { move, scale, rotate }

/// The part of a selection frame under a pointer.
class SelectionHit {
  const SelectionHit.move()
    : operation = SelectionOperation.move,
      corner = null;

  const SelectionHit.rotate()
    : operation = SelectionOperation.rotate,
      corner = null;

  /// [corner] indexes [SelectionFrame.corners].
  const SelectionHit.scale(int this.corner)
    : operation = SelectionOperation.scale;

  final SelectionOperation operation;

  /// The grabbed corner; null unless scaling.
  final int? corner;

  @override
  bool operator ==(Object other) {
    return other is SelectionHit &&
        other.operation == operation &&
        other.corner == corner;
  }

  @override
  int get hashCode => Object.hash(operation, corner);

  @override
  String toString() => 'SelectionHit(${operation.name}, corner: $corner)';
}

/// The rectangle drawn around a selection. It has its own orientation, so
/// rotating a selection turns the frame with it instead of growing a new
/// upright box around the result.
class SelectionFrame {
  const SelectionFrame({
    required this.center,
    required this.halfWidth,
    required this.halfHeight,
    this.angle = 0,
  });

  /// The upright frame around a box.
  factory SelectionFrame.fromBounds(
    double left,
    double top,
    double right,
    double bottom,
  ) {
    return SelectionFrame(
      center: InkVector((left + right) / 2, (top + bottom) / 2),
      halfWidth: (right - left) / 2,
      halfHeight: (bottom - top) / 2,
    );
  }

  final InkVector center;

  /// Half the frame's extent along [xAxis] and [yAxis].
  final double halfWidth;
  final double halfHeight;

  /// How far the frame is turned from upright, in radians.
  final double angle;

  /// The direction of the frame's top edge, left to right.
  InkVector get xAxis => InkVector(math.cos(angle), math.sin(angle));

  /// The direction of the frame's left edge, top to bottom.
  InkVector get yAxis => xAxis.perpendicular;

  /// Top-left, top-right, bottom-right, bottom-left, as seen with the frame
  /// upright. This order also breaks ties between equally near corners.
  List<InkVector> get corners {
    final InkVector across = xAxis * halfWidth;
    final InkVector down = yAxis * halfHeight;
    return <InkVector>[
      center - across - down,
      center + across - down,
      center + across + down,
      center - across + down,
    ];
  }

  /// The corner diagonally opposite corner [index].
  static int oppositeCorner(int index) => (index + 2) % 4;

  InkVector get topCenter => center - yAxis * halfHeight;

  /// Where the rotation handle sits: [offset] beyond the top edge.
  InkVector rotationHandle(double offset) {
    return center - yAxis * (halfHeight + offset);
  }

  /// Whether every corner is finite and within [limit] of the origin on both
  /// axes.
  bool isWithin(double limit) {
    for (final InkVector corner in corners) {
      if (!(corner.x.abs() <= limit && corner.y.abs() <= limit)) {
        return false;
      }
    }
    return true;
  }

  /// Whether [point] is on the frame or inside it, with [tolerance] of
  /// slack.
  bool contains(InkVector point, {double tolerance = 0}) {
    final InkVector offset = point - center;
    return offset.dot(xAxis).abs() <= halfWidth + tolerance &&
        offset.dot(yAxis).abs() <= halfHeight + tolerance;
  }

  /// This frame carried along by [transform].
  SelectionFrame transformed(InkTransform transform) {
    return SelectionFrame(
      center: transform.apply(center),
      halfWidth: halfWidth * transform.scale,
      halfHeight: halfHeight * transform.scale,
      angle: _wrapAngle(angle + transform.angle),
    );
  }

  /// What a pointer going down at [point] grabs, or null when it misses the
  /// frame and its handles.
  ///
  /// A handle is grabbed within [handleHitRadius] of its center. When several
  /// are that close the nearest wins; a tie goes to the rotation handle, then
  /// to the earlier corner in [corners]. Anywhere else on or inside the frame
  /// moves the selection.
  ///
  /// One refinement keeps a frame smaller than its handle targets movable:
  /// inside the frame, a handle is grabbed only where the pointer is at
  /// least as near to it as to the frame's center. On a frame large enough
  /// for its targets not to reach the center, this changes nothing.
  SelectionHit? hitTest(
    InkVector point, {
    required double handleHitRadius,
    required double rotationHandleOffset,
    double tolerance = 0,
  }) {
    if (!point.isFinite) {
      return null;
    }
    final bool inside = contains(point, tolerance: tolerance);
    final double centerDistance = (point - center).length;
    SelectionHit? best;
    double bestDistance = double.infinity;

    void offer(SelectionHit hit, InkVector handle) {
      final double distance = (point - handle).length;
      if (distance > handleHitRadius || (inside && distance > centerDistance)) {
        return;
      }
      if (distance < bestDistance) {
        best = hit;
        bestDistance = distance;
      }
    }

    offer(const SelectionHit.rotate(), rotationHandle(rotationHandleOffset));
    final List<InkVector> handles = corners;
    for (int i = 0; i < handles.length; i++) {
      offer(SelectionHit.scale(i), handles[i]);
    }
    return best ?? (inside ? const SelectionHit.move() : null);
  }

  @override
  String toString() {
    return 'SelectionFrame($center, $halfWidth x $halfHeight, angle: $angle)';
  }
}

/// The transform a selection gesture has reached, computed from where the
/// pointer went down and where it is now. Nothing here depends on the
/// positions in between, so the result does not drift and does not vary with
/// how often the pointer is sampled.
abstract final class SelectionTransforms {
  /// Follows the pointer from [start] to [current]. Null when either is not
  /// finite.
  static InkTransform? move(InkVector start, InkVector current) {
    final InkVector delta = current - start;
    return delta.isFinite ? InkTransform.translation(delta) : null;
  }

  /// Scales about [fixed] by how much further from it the pointer is at
  /// [current] than it was at [start], held within [minScale]..[maxScale].
  /// The factor is a ratio of distances, so it is never zero or negative and
  /// the result is never mirrored.
  ///
  /// Null when a position is not finite, or when the pointer started within
  /// [tolerance] of [fixed], which leaves the ratio undefined.
  static InkTransform? scale({
    required InkVector fixed,
    required InkVector start,
    required InkVector current,
    required double minScale,
    required double maxScale,
    double tolerance = 0,
  }) {
    final double from = (start - fixed).length;
    final double to = (current - fixed).length;
    if (!from.isFinite || !to.isFinite || !fixed.isFinite) {
      return null;
    }
    if (from <= tolerance || from == 0) {
      return null;
    }
    final double factor = (to / from).clamp(minScale, maxScale);
    return InkTransform.scaling(fixed, factor);
  }

  /// Turns about [center] by the angle the pointer has swept from [start] to
  /// [current]. The two directions are subtracted and wrapped into
  /// `-pi..pi`, so sweeping across the `-pi`/`pi` seam does not jump.
  ///
  /// Null when a position is not finite, or within [tolerance] of [center],
  /// where it has no direction.
  static InkTransform? rotate({
    required InkVector center,
    required InkVector start,
    required InkVector current,
    double tolerance = 0,
  }) {
    final InkVector from = start - center;
    final InkVector to = current - center;
    if (!from.isFinite || !to.isFinite) {
      return null;
    }
    if (from.length <= tolerance || to.length <= tolerance) {
      return null;
    }
    final double angle = _wrapAngle(
      math.atan2(to.y, to.x) - math.atan2(from.y, from.x),
    );
    return InkTransform.rotation(center, angle);
  }
}

/// [angle] brought into `-pi..pi`.
double _wrapAngle(double angle) {
  if (!angle.isFinite) {
    return 0;
  }
  double wrapped = angle % (2 * math.pi);
  if (wrapped > math.pi) {
    wrapped -= 2 * math.pi;
  }
  return wrapped;
}
