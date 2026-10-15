// Pure Dart: no Flutter imports, so the selection geometry can run anywhere.
import 'dart:math' as math;
import 'dart:typed_data';

import 'erase_geometry.dart';
import 'ink_sample.dart';

/// The closed region drawn with the lasso, and the test for ink overlapping
/// it.
///
/// The region is the polygon through the given points, closed from the last
/// back to the first. Its interior follows the **even-odd** rule: a point is
/// inside when a ray from it crosses the outline an odd number of times. A
/// lasso that crosses itself therefore has holes wherever it wraps the same
/// area twice. The rule is implemented here, in [containsPoint], and not
/// delegated to a platform path.
///
/// A region with fewer than three distinct points, or whose points all lie
/// within the tolerance of one line, has no area: it [isEmpty] and overlaps
/// nothing.
class LassoRegion {
  LassoRegion._(
    this._xs,
    this._ys,
    this.tolerance, {
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  /// Builds the region through [points]. Non-finite points and consecutive
  /// duplicates are dropped.
  ///
  /// [tolerance] is inclusive slack, in the same units as the points: ink
  /// within it of the outline counts as touching.
  factory LassoRegion(Iterable<InkVector> points, {double tolerance = 1e-3}) {
    final List<InkVector> vertices = <InkVector>[];
    for (final InkVector point in points) {
      if (point.isFinite && (vertices.isEmpty || point != vertices.last)) {
        vertices.add(point);
      }
    }
    // The closing edge already joins the last point to the first.
    while (vertices.length > 1 && vertices.last == vertices.first) {
      vertices.removeLast();
    }
    if (vertices.length < 3 || _isFlat(vertices, tolerance)) {
      return LassoRegion._(
        Float64List(0),
        Float64List(0),
        tolerance,
        left: 0,
        top: 0,
        right: 0,
        bottom: 0,
      );
    }
    final Float64List xs = Float64List(vertices.length);
    final Float64List ys = Float64List(vertices.length);
    double left = double.infinity;
    double top = double.infinity;
    double right = double.negativeInfinity;
    double bottom = double.negativeInfinity;
    for (int i = 0; i < vertices.length; i++) {
      final InkVector vertex = vertices[i];
      xs[i] = vertex.x;
      ys[i] = vertex.y;
      left = math.min(left, vertex.x);
      top = math.min(top, vertex.y);
      right = math.max(right, vertex.x);
      bottom = math.max(bottom, vertex.y);
    }
    return LassoRegion._(
      xs,
      ys,
      tolerance,
      left: left,
      top: top,
      right: right,
      bottom: bottom,
    );
  }

  final Float64List _xs;
  final Float64List _ys;

  final double tolerance;

  /// The box around the outline. All zero when the region [isEmpty].
  final double left;
  final double top;
  final double right;
  final double bottom;

  /// True when the region has no area and so selects nothing.
  bool get isEmpty => _xs.isEmpty;

  int get vertexCount => _xs.length;

  /// Whether the box could touch the region. A box that fails cannot hold
  /// ink that overlaps it, as long as the box includes the ink's width.
  bool overlapsBounds(double left, double top, double right, double bottom) {
    return !isEmpty &&
        left <= this.right + tolerance &&
        right >= this.left - tolerance &&
        top <= this.bottom + tolerance &&
        bottom >= this.top - tolerance;
  }

  /// Whether [point] is in the interior, by the even-odd rule. Points on the
  /// outline itself may fall either way; [overlapsInk] catches those by
  /// distance.
  bool containsPoint(InkVector point) {
    final double px = point.x;
    final double py = point.y;
    bool inside = false;
    for (int i = 0, j = _xs.length - 1; i < _xs.length; j = i++) {
      final double yi = _ys[i];
      final double yj = _ys[j];
      if ((yi > py) != (yj > py) &&
          px < (_xs[j] - _xs[i]) * (py - yi) / (yj - yi) + _xs[i]) {
        inside = !inside;
      }
    }
    return inside;
  }

  /// Whether a convex quadrilateral overlaps this even-odd lasso region.
  /// Corners are expected in perimeter order. Crossing edges count even
  /// when neither shape contains a corner of the other.
  bool overlapsPolygon(List<InkVector> corners) {
    if (isEmpty || corners.length < 3) {
      return false;
    }
    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = double.negativeInfinity;
    double maxY = double.negativeInfinity;
    for (final InkVector point in corners) {
      minX = math.min(minX, point.x);
      minY = math.min(minY, point.y);
      maxX = math.max(maxX, point.x);
      maxY = math.max(maxY, point.y);
      if (containsPoint(point)) {
        return true;
      }
    }
    if (!overlapsBounds(minX, minY, maxX, maxY)) {
      return false;
    }
    bool inPolygon(InkVector point) {
      bool inside = false;
      for (int i = 0, j = corners.length - 1; i < corners.length; j = i++) {
        final InkVector a = corners[i];
        final InkVector b = corners[j];
        if ((a.y > point.y) != (b.y > point.y) &&
            point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x) {
          inside = !inside;
        }
      }
      return inside;
    }

    for (int i = 0; i < _xs.length; i++) {
      if (inPolygon(_vertex(i))) {
        return true;
      }
    }
    for (int a = 0; a < corners.length; a++) {
      final InkVector p = corners[a];
      final InkVector q = corners[(a + 1) % corners.length];
      for (int i = 0; i < _xs.length; i++) {
        if (EraseGeometry.segmentSegmentDistance(
              p,
              q,
              _vertex(i),
              _vertex((i + 1) % _xs.length),
            ) <=
            tolerance) {
          return true;
        }
      }
    }
    return false;
  }

  /// Whether ink of [width] along the centerline [points] overlaps the
  /// region. The ink is everything within half its width of the centerline,
  /// which is what a round-capped, round-joined stroke paints. With [isDot],
  /// or a single point, it is the disc around the first point.
  ///
  /// The ink overlaps when its centerline comes within half the width, plus
  /// [tolerance], of the outline, or lies in the interior. The first covers
  /// a centerline that crosses the outline between two of its points, wide
  /// ink that only grazes the region, and a lasso drawn wholly inside wide
  /// ink. Otherwise the centerline never crosses the outline, so it is all
  /// inside or all outside, and one point decides.
  bool overlapsInk(
    List<InkVector> points, {
    required double width,
    bool isDot = false,
  }) {
    if (isEmpty || points.isEmpty) {
      return false;
    }
    final int count = isDot ? 1 : points.length;
    final double reach = (width > 0 ? width / 2 : 0) + tolerance;

    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = double.negativeInfinity;
    double maxY = double.negativeInfinity;
    for (int i = 0; i < count; i++) {
      final InkVector point = points[i];
      minX = math.min(minX, point.x);
      minY = math.min(minY, point.y);
      maxX = math.max(maxX, point.x);
      maxY = math.max(maxY, point.y);
    }
    minX -= reach;
    minY -= reach;
    maxX += reach;
    maxY += reach;
    if (!(minX <= right && maxX >= left && minY <= bottom && maxY >= top)) {
      return false;
    }

    // Only outline edges near the ink can be within reach of it. Ink far
    // from the outline, which is most of a page, skips straight to the
    // single interior test.
    List<int>? near;
    for (int i = 0, j = _xs.length - 1; i < _xs.length; j = i++) {
      if (_edgeMisses(i, j, minX, minY, maxX, maxY)) {
        continue;
      }
      (near ??= <int>[]).add(i);
    }
    if (near != null) {
      if (count == 1) {
        final InkVector center = points.first;
        for (final int i in near) {
          if (EraseGeometry.pointSegmentDistance(
                center,
                _vertex(_previous(i)),
                _vertex(i),
              ) <=
              reach) {
            return true;
          }
        }
      } else {
        for (int s = 0; s < count - 1; s++) {
          final InkVector p = points[s];
          final InkVector q = points[s + 1];
          final double segmentMinX = math.min(p.x, q.x) - reach;
          final double segmentMinY = math.min(p.y, q.y) - reach;
          final double segmentMaxX = math.max(p.x, q.x) + reach;
          final double segmentMaxY = math.max(p.y, q.y) + reach;
          for (final int i in near) {
            final int j = _previous(i);
            if (_edgeMisses(
              i,
              j,
              segmentMinX,
              segmentMinY,
              segmentMaxX,
              segmentMaxY,
            )) {
              continue;
            }
            if (EraseGeometry.segmentSegmentDistance(
                  p,
                  q,
                  _vertex(j),
                  _vertex(i),
                ) <=
                reach) {
              return true;
            }
          }
        }
      }
    }
    return containsPoint(points.first);
  }

  int _previous(int i) => i == 0 ? _xs.length - 1 : i - 1;

  InkVector _vertex(int i) => InkVector(_xs[i], _ys[i]);

  /// Whether the edge between vertices [i] and [j] lies wholly to one side
  /// of the box.
  bool _edgeMisses(
    int i,
    int j,
    double minX,
    double minY,
    double maxX,
    double maxY,
  ) {
    final double xi = _xs[i];
    final double xj = _xs[j];
    final double yi = _ys[i];
    final double yj = _ys[j];
    return (xi < minX && xj < minX) ||
        (xi > maxX && xj > maxX) ||
        (yi < minY && yj < minY) ||
        (yi > maxY && yj > maxY);
  }

  /// Whether every vertex lies within [tolerance] of a single line, which
  /// leaves the outline with effectively no area. A figure of eight is not
  /// flat, although its signed area can be zero.
  static bool _isFlat(List<InkVector> vertices, double tolerance) {
    final InkVector origin = vertices.first;
    InkVector farthest = origin;
    double span = 0;
    for (final InkVector vertex in vertices) {
      final double distance = (vertex - origin).length;
      if (distance > span) {
        span = distance;
        farthest = vertex;
      }
    }
    if (span <= tolerance) {
      return true;
    }
    final InkVector axis = farthest - origin;
    for (final InkVector vertex in vertices) {
      final InkVector offset = vertex - origin;
      final double across = (axis.x * offset.y - axis.y * offset.x) / span;
      if (across.abs() > tolerance) {
        return false;
      }
    }
    return true;
  }
}
