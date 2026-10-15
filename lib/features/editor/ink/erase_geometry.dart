// Pure Dart: no Flutter imports, so the erase geometry can run anywhere.
import 'dart:math' as math;

import 'ink_sample.dart';

/// Geometry behind the eraser.
///
/// Between two consecutive samples the eraser covers a capsule: every point
/// within `radius` of the segment joining the two positions. A first sample
/// is a capsule of zero length. Callers fold half the stroke width into
/// `radius`, so every test here is against a stroke's centerline.
abstract final class EraseGeometry {
  /// Lengths at or below this are treated as zero when cutting: a removal
  /// that short is skipped, and a cut point that close to a vertex snaps to
  /// it. This is what makes a repeated erase a no-op instead of shaving off
  /// rounding error, and keeps degenerate vertices out of the pieces.
  static const double cutTolerance = 1e-3;

  /// Distance from [p] to the segment [a]-[b].
  static double pointSegmentDistance(InkVector p, InkVector a, InkVector b) {
    return math.sqrt(_pointSegmentDistanceSquared(p, a, b));
  }

  /// Shortest distance between the segments [a]-[b] and [c]-[d]. Zero when
  /// they cross or touch.
  static double segmentSegmentDistance(
    InkVector a,
    InkVector b,
    InkVector c,
    InkVector d,
  ) {
    return math.sqrt(_segmentSegmentDistanceSquared(a, b, c, d));
  }

  /// Whether [p] lies within [radius] of the segment [a]-[b].
  static bool pointTouchesCapsule(
    InkVector p,
    InkVector a,
    InkVector b,
    double radius,
  ) {
    return _pointSegmentDistanceSquared(p, a, b) <= radius * radius;
  }

  /// Whether any part of the polyline [points] lies within [radius] of the
  /// segment [a]-[b].
  static bool polylineTouchesCapsule(
    List<InkVector> points,
    InkVector a,
    InkVector b,
    double radius,
  ) {
    if (points.isEmpty) {
      return false;
    }
    final double radiusSquared = radius * radius;
    if (points.length == 1) {
      return _pointSegmentDistanceSquared(points.first, a, b) <= radiusSquared;
    }
    final double minX = math.min(a.x, b.x) - radius;
    final double maxX = math.max(a.x, b.x) + radius;
    final double minY = math.min(a.y, b.y) - radius;
    final double maxY = math.max(a.y, b.y) + radius;
    for (int i = 0; i < points.length - 1; i++) {
      final InkVector p = points[i];
      final InkVector q = points[i + 1];
      if (_isOutside(p, q, minX, maxX, minY, maxY)) {
        continue;
      }
      if (_segmentSegmentDistanceSquared(p, q, a, b) <= radiusSquared) {
        return true;
      }
    }
    return false;
  }

  /// Removes from the polyline [points] everything within [radius] of the
  /// segment [a]-[b].
  ///
  /// Returns null when nothing is removed. Otherwise returns the remaining
  /// pieces in order along the polyline, possibly none. A piece ends exactly
  /// where the polyline crosses the capsule's edge: the crossing is computed
  /// on the segment and added as a new end vertex. Pieces whose length is
  /// below [minPieceLength] are dropped.
  static List<List<InkVector>>? cutPolyline(
    List<InkVector> points,
    InkVector a,
    InkVector b,
    double radius, {
    double minPieceLength = 0,
  }) {
    if (points.length < 2) {
      return null;
    }
    final double minX = math.min(a.x, b.x) - radius;
    final double maxX = math.max(a.x, b.x) + radius;
    final double minY = math.min(a.y, b.y) - radius;
    final double maxY = math.max(a.y, b.y) + radius;
    final double radiusSquared = radius * radius;
    final double axisLength = (b - a).length;
    final _Interval inside = _Interval();

    // Both stay null until the first removal, so a miss allocates nothing.
    List<List<InkVector>>? pieces;
    List<InkVector>? current;

    void flush() {
      final List<InkVector> piece = current!;
      if (piece.length >= 2 && _length(piece) >= minPieceLength) {
        pieces!.add(piece);
      }
      current = <InkVector>[];
    }

    for (int i = 0; i < points.length - 1; i++) {
      final InkVector p = points[i];
      final InkVector q = points[i + 1];
      final double dx = q.x - p.x;
      final double dy = q.y - p.y;
      final double length = math.sqrt(dx * dx + dy * dy);

      inside.clear();
      if (!_isOutside(p, q, minX, maxX, minY, maxY)) {
        if (length <= cutTolerance) {
          // Too short to cut: it goes or stays as a whole.
          final InkVector middle = InkVector(p.x + dx / 2, p.y + dy / 2);
          if (_pointSegmentDistanceSquared(middle, a, b) < radiusSquared) {
            inside.include(0, 1);
          }
        } else {
          _clipToCapsule(inside, p, dx, dy, a, b, radius, axisLength);
          if ((inside.end - inside.start) * length <= cutTolerance) {
            inside.clear();
          } else {
            if (inside.start * length <= cutTolerance) {
              inside.start = 0;
            }
            if ((1 - inside.end) * length <= cutTolerance) {
              inside.end = 1;
            }
          }
        }
      }

      if (inside.isEmpty) {
        final List<InkVector>? piece = current;
        if (piece != null) {
          if (piece.isEmpty) {
            piece.add(p);
          }
          piece.add(q);
        }
        continue;
      }

      pieces ??= <List<InkVector>>[];
      final List<InkVector> piece = current ??= points.sublist(0, i + 1);
      if (inside.start > 0) {
        if (piece.isEmpty) {
          piece.add(p);
        }
        piece.add(InkVector(p.x + dx * inside.start, p.y + dy * inside.start));
      }
      flush();
      if (inside.end < 1) {
        current!
          ..add(InkVector(p.x + dx * inside.end, p.y + dy * inside.end))
          ..add(q);
      }
    }

    if (pieces == null) {
      return null;
    }
    flush();
    return pieces;
  }

  static bool _isOutside(
    InkVector p,
    InkVector q,
    double minX,
    double maxX,
    double minY,
    double maxY,
  ) {
    return (p.x < minX && q.x < minX) ||
        (p.x > maxX && q.x > maxX) ||
        (p.y < minY && q.y < minY) ||
        (p.y > maxY && q.y > maxY);
  }

  static double _length(List<InkVector> points) {
    double length = 0;
    for (int i = 0; i < points.length - 1; i++) {
      length += (points[i + 1] - points[i]).length;
    }
    return length;
  }

  static double _pointSegmentDistanceSquared(
    InkVector p,
    InkVector a,
    InkVector b,
  ) {
    final double abx = b.x - a.x;
    final double aby = b.y - a.y;
    final double apx = p.x - a.x;
    final double apy = p.y - a.y;
    final double lengthSquared = abx * abx + aby * aby;
    double t = 0;
    if (lengthSquared > 0) {
      t = (apx * abx + apy * aby) / lengthSquared;
      t = t < 0 ? 0 : (t > 1 ? 1 : t);
    }
    final double dx = apx - t * abx;
    final double dy = apy - t * aby;
    return dx * dx + dy * dy;
  }

  static double _segmentSegmentDistanceSquared(
    InkVector a,
    InkVector b,
    InkVector c,
    InkVector d,
  ) {
    final double d1 = _cross(c, d, a);
    final double d2 = _cross(c, d, b);
    final double d3 = _cross(a, b, c);
    final double d4 = _cross(a, b, d);
    if (d1 * d2 < 0 && d3 * d4 < 0) {
      return 0;
    }
    // Not crossing, so the closest approach involves an endpoint.
    return math.min(
      math.min(
        _pointSegmentDistanceSquared(a, c, d),
        _pointSegmentDistanceSquared(b, c, d),
      ),
      math.min(
        _pointSegmentDistanceSquared(c, a, b),
        _pointSegmentDistanceSquared(d, a, b),
      ),
    );
  }

  /// Which side of the line [o]-[a] the point [b] is on.
  static double _cross(InkVector o, InkVector a, InkVector b) {
    return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
  }

  /// Sets [inside] to the part of the segment from [p] along `(dx, dy)`,
  /// as parameters in 0..1, that lies in the capsule around [a]-[b].
  ///
  /// The capsule is the union of a disc at each end and the rectangle
  /// between them. It is convex, so the part of a segment inside it is one
  /// interval: the span of the parts inside the three shapes.
  static void _clipToCapsule(
    _Interval inside,
    InkVector p,
    double dx,
    double dy,
    InkVector a,
    InkVector b,
    double radius,
    double axisLength,
  ) {
    _clipToDisc(inside, p, dx, dy, a, radius);
    if (axisLength <= 0) {
      return;
    }
    _clipToDisc(inside, p, dx, dy, b, radius);

    // Coordinates along (u) and across (v) the eraser's path.
    final double ux = (b.x - a.x) / axisLength;
    final double uy = (b.y - a.y) / axisLength;
    final double pu = (p.x - a.x) * ux + (p.y - a.y) * uy;
    final double pv = (p.y - a.y) * ux - (p.x - a.x) * uy;
    final double du = dx * ux + dy * uy;
    final double dv = dy * ux - dx * uy;
    double start = 0;
    double end = 1;
    if (du == 0) {
      if (pu < 0 || pu > axisLength) {
        return;
      }
    } else {
      final double t1 = -pu / du;
      final double t2 = (axisLength - pu) / du;
      start = math.max(start, math.min(t1, t2));
      end = math.min(end, math.max(t1, t2));
    }
    if (dv == 0) {
      if (pv < -radius || pv > radius) {
        return;
      }
    } else {
      final double t1 = (-radius - pv) / dv;
      final double t2 = (radius - pv) / dv;
      start = math.max(start, math.min(t1, t2));
      end = math.min(end, math.max(t1, t2));
    }
    if (start <= end) {
      inside.include(start, end);
    }
  }

  static void _clipToDisc(
    _Interval inside,
    InkVector p,
    double dx,
    double dy,
    InkVector center,
    double radius,
  ) {
    final double fx = p.x - center.x;
    final double fy = p.y - center.y;
    final double qa = dx * dx + dy * dy;
    final double qb = 2 * (fx * dx + fy * dy);
    final double qc = fx * fx + fy * fy - radius * radius;
    final double discriminant = qb * qb - 4 * qa * qc;
    if (discriminant < 0 || qa <= 0) {
      return;
    }
    final double root = math.sqrt(discriminant);
    final double start = math.max(0, (-qb - root) / (2 * qa));
    final double end = math.min(1, (-qb + root) / (2 * qa));
    if (start <= end) {
      inside.include(start, end);
    }
  }
}

/// A growable span of segment parameters; empty until [include] is called.
class _Interval {
  double start = double.infinity;
  double end = double.negativeInfinity;

  bool get isEmpty => start > end;

  void clear() {
    start = double.infinity;
    end = double.negativeInfinity;
  }

  void include(double from, double to) {
    if (from < start) {
      start = from;
    }
    if (to > end) {
      end = to;
    }
  }
}
