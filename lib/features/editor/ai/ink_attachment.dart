import 'dart:ui' show Rect;

import '../ink/ink_sample.dart';

/// [points] with every point dropped that lies within [tolerance] of the
/// straight line its kept neighbours draw (Ramer-Douglas-Peucker): what is
/// left is the polyline's ends and corners. The first and last points are
/// always kept.
List<InkVector> simplifyPolyline(List<InkVector> points, double tolerance) {
  if (points.length <= 2) {
    return List<InkVector>.of(points);
  }
  final List<bool> keep = List<bool>.filled(points.length, false);
  keep[0] = true;
  keep[points.length - 1] = true;
  final List<(int, int)> spans = <(int, int)>[(0, points.length - 1)];
  while (spans.isNotEmpty) {
    final (int first, int last) = spans.removeLast();
    double farthest = -1;
    int index = -1;
    for (int i = first + 1; i < last; i++) {
      final double distance = _distanceToSegment(
        points[i],
        points[first],
        points[last],
      );
      if (distance > farthest) {
        farthest = distance;
        index = i;
      }
    }
    if (index >= 0 && farthest > tolerance) {
      keep[index] = true;
      spans
        ..add((first, index))
        ..add((index, last));
    }
  }
  return <InkVector>[
    for (int i = 0; i < points.length; i++)
      if (keep[i]) points[i],
  ];
}

/// The outlines of the ink in [region]: each polyline in [strokes] that
/// reaches into it, simplified to within [tolerance], longest first, and no
/// more than [maxPoints] points in all. Dots are left out.
List<List<InkVector>> inkOutlines(
  Iterable<List<InkVector>> strokes,
  Rect region, {
  required double tolerance,
  required int maxPoints,
}) {
  final List<List<InkVector>> outlines = <List<InkVector>>[];
  for (final List<InkVector> points in strokes) {
    if (points.length < 2 || !_reaches(points, region)) {
      continue;
    }
    final List<InkVector> outline = simplifyPolyline(points, tolerance);
    if (_length(outline) > 0) {
      outlines.add(outline);
    }
  }
  outlines.sort(
    (List<InkVector> a, List<InkVector> b) => _length(b).compareTo(_length(a)),
  );
  final List<List<InkVector>> kept = <List<InkVector>>[];
  int total = 0;
  for (final List<InkVector> outline in outlines) {
    if (total + outline.length > maxPoints) {
      continue;
    }
    kept.add(outline);
    total += outline.length;
  }
  return kept;
}

/// Moves the loose ends of new lines onto existing ink they nearly reach,
/// so that a lead drawn to a component touches it instead of stopping just
/// short or running past.
class InkSnapper {
  InkSnapper(Iterable<List<InkVector>> ink, {required this.reach})
    : _ink = <List<InkVector>>[
        for (final List<InkVector> points in ink)
          if (points.isNotEmpty) points,
      ];

  final List<List<InkVector>> _ink;

  /// How far, in logical pixels, an end may be moved.
  final double reach;

  bool get isEmpty => _ink.isEmpty || reach <= 0;

  /// The point of the ink nearest [point], when it lies within [reach];
  /// otherwise [point]. An end of an existing stroke within half of
  /// [reach] wins over a nearer point along a stroke, so that lines join
  /// end to end.
  InkVector snap(InkVector point) {
    if (isEmpty) {
      return point;
    }
    InkVector? nearestEnd;
    double endDistance = reach / 2;
    InkVector? nearest;
    double distance = reach;
    for (final List<InkVector> points in _ink) {
      for (final InkVector end in <InkVector>[points.first, points.last]) {
        final double d = (end - point).length;
        if (d <= endDistance) {
          endDistance = d;
          nearestEnd = end;
        }
      }
      if (points.length == 1) {
        final double d = (points.first - point).length;
        if (d <= distance) {
          distance = d;
          nearest = points.first;
        }
        continue;
      }
      for (int i = 1; i < points.length; i++) {
        final InkVector candidate = _nearestOnSegment(
          point,
          points[i - 1],
          points[i],
        );
        final double d = (candidate - point).length;
        if (d <= distance) {
          distance = d;
          nearest = candidate;
        }
      }
    }
    return nearestEnd ?? nearest ?? point;
  }

  /// [line] with its two ends snapped. An end is left alone when snapping
  /// it would leave the line with no length.
  List<InkVector> snapEnds(List<InkVector> line) {
    if (isEmpty || line.length < 2) {
      return line;
    }
    final List<InkVector> snapped = List<InkVector>.of(line);
    final InkVector start = snap(line.first);
    if (start != line[1]) {
      snapped.first = start;
    }
    final InkVector end = snap(line.last);
    if (end != snapped[snapped.length - 2]) {
      snapped.last = end;
    }
    return snapped;
  }
}

bool _reaches(List<InkVector> points, Rect region) {
  for (final InkVector point in points) {
    if (point.x >= region.left &&
        point.x <= region.right &&
        point.y >= region.top &&
        point.y <= region.bottom) {
      return true;
    }
  }
  return false;
}

double _length(List<InkVector> points) {
  double length = 0;
  for (int i = 1; i < points.length; i++) {
    length += (points[i] - points[i - 1]).length;
  }
  return length;
}

InkVector _nearestOnSegment(InkVector point, InkVector a, InkVector b) {
  final InkVector ab = b - a;
  final double lengthSquared = ab.x * ab.x + ab.y * ab.y;
  if (lengthSquared == 0) {
    return a;
  }
  final InkVector ap = point - a;
  final double t = ((ap.x * ab.x + ap.y * ab.y) / lengthSquared).clamp(0, 1);
  return a + ab * t;
}

double _distanceToSegment(InkVector point, InkVector a, InkVector b) {
  return (point - _nearestOnSegment(point, a, b)).length;
}
