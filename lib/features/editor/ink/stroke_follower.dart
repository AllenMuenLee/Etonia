import 'dart:math' as math;
import 'dart:ui';

import 'ink_sample.dart';

/// Pulls the pen onto ink already on the page while it is drawn close
/// alongside it, for tracing over or continuing a line.
///
/// A pen-down within [captureRadius] starts directly on the nearest stroke.
/// Later samples are caught when moving roughly along it. Once following,
/// the pull eases off as the pen moves away, reaching nothing at
/// [releaseRadius], so the line peels away
/// smoothly instead of jumping. Crossing a stroke does not catch the pen:
/// it has to be heading the same way, or back along it.
///
/// One follower serves one stroke; it remembers how far it is pulling.
class StrokeFollower {
  StrokeFollower(
    List<List<InkVector>> strokes, {
    required this.captureRadius,
    required this.releaseRadius,
  }) : assert(captureRadius > 0),
       assert(releaseRadius > captureRadius),
       _cellSize = math.max(64, releaseRadius * 4) {
    for (final List<InkVector> points in strokes) {
      if (points.length < 2) {
        continue;
      }
      double left = points.first.x, right = left;
      double top = points.first.y, bottom = top;
      for (final InkVector p in points) {
        left = math.min(left, p.x);
        right = math.max(right, p.x);
        top = math.min(top, p.y);
        bottom = math.max(bottom, p.y);
      }
      _lines.add(points);
      _reach.add(
        Rect.fromLTRB(left, top, right, bottom).inflate(releaseRadius),
      );
      _indexLine(_lines.length - 1, _reach.last);
    }
  }

  /// How close, in page units, the pen comes to a stroke to be caught.
  final double captureRadius;

  /// How far, in page units, the pen moves from a stroke to be let go.
  final double releaseRadius;

  /// How much of the remaining way to the wanted pull each sample closes,
  /// so that catching and letting go both glide.
  static const double _ease = 0.35;

  /// How far the pen moves before its heading is trusted.
  static const double _headingStep = 1.5;

  final List<List<InkVector>> _lines = <List<InkVector>>[];
  final List<Rect> _reach = <Rect>[];
  final double _cellSize;
  final Map<(int, int), List<int>> _cells = <(int, int), List<int>>{};
  final List<int> _overflow = <int>[];

  InkVector _pull = InkVector.zero;
  bool _following = false;
  InkVector? _lastRaw;
  InkVector? _heading;

  /// Whether the pen is being drawn onto a stroke.
  bool get isFollowing => _following;

  /// Where [sample] is drawn.
  RawInkSample follow(RawInkSample sample) {
    final InkVector raw = sample.position;
    final bool isFirstSample = _lastRaw == null;
    _updateHeading(raw);
    final InkVector target = _targetPull(raw);
    // There is no drawn line to ease from at pen-down.
    _pull = isFirstSample ? target : _pull + (target - _pull) * _ease;
    if (!_following && target == InkVector.zero && _pull.length < 0.05) {
      _pull = InkVector.zero;
    }
    if (_pull == InkVector.zero) {
      return sample;
    }
    return RawInkSample(
      position: raw + _pull,
      timestamp: sample.timestamp,
      deviceKind: sample.deviceKind,
      pressure: sample.pressure,
    );
  }

  void _updateHeading(InkVector raw) {
    final InkVector? last = _lastRaw;
    if (last == null) {
      _lastRaw = raw;
      return;
    }
    final InkVector step = raw - last;
    final double length = step.length;
    if (length >= _headingStep) {
      _heading = step * (1 / length);
      _lastRaw = raw;
    }
  }

  /// The pull wanted at [raw]: onto the nearest stroke, in full within the
  /// capture radius, easing to none at the release radius.
  InkVector _targetPull(InkVector raw) {
    final _Nearest? nearest = _nearest(raw);
    if (nearest == null) {
      _following = false;
      return InkVector.zero;
    }
    final InkVector? heading = _heading;
    // Capture immediately at pen-down and keep following until the pen has
    // moved enough to establish a heading.
    // How well the pen runs along the stroke, 0 across it, 1 along it.
    final double along = heading == null
        ? 1
        : _smoothstep(0.55, 0.85, heading.dot(nearest.direction).abs());
    final double d = nearest.distance;
    double weight;
    if (d <= captureRadius) {
      weight = _following || along >= 1 ? 1 : 0;
    } else {
      weight = _following
          ? 1 -
                _smoothstep(
                  0,
                  1,
                  (d - captureRadius) / (releaseRadius - captureRadius),
                )
          : 0;
    }
    weight *= along;
    _following = weight > 0;
    return (nearest.point - raw) * weight;
  }

  _Nearest? _nearest(InkVector p) {
    _Nearest? best;
    final Offset at = Offset(p.x, p.y);
    final Set<int> nearby = <int>{
      ..._overflow,
      ...?_cells[(_cell(p.x), _cell(p.y))],
    };
    final List<int> ordered = nearby.toList()..sort();
    for (final int s in ordered) {
      if (!_reach[s].contains(at)) {
        continue;
      }
      final List<InkVector> points = _lines[s];
      for (int i = 0; i < points.length - 1; i++) {
        final InkVector a = points[i];
        final InkVector d = points[i + 1] - a;
        final double lengthSquared = d.dot(d);
        if (lengthSquared == 0) {
          continue;
        }
        final double t = ((p - a).dot(d) / lengthSquared).clamp(0.0, 1.0);
        final InkVector q = a + d * t;
        final double distance = (p - q).length;
        if (distance < releaseRadius &&
            (best == null || distance < best.distance)) {
          best = _Nearest(q, distance, d * (1 / math.sqrt(lengthSquared)));
        }
      }
    }
    return best;
  }

  int _cell(double coordinate) => (coordinate / _cellSize).floor();

  void _indexLine(int index, Rect bounds) {
    final int left = _cell(bounds.left);
    final int right = _cell(bounds.right);
    final int top = _cell(bounds.top);
    final int bottom = _cell(bounds.bottom);
    if ((right - left + 1) * (bottom - top + 1) > 256) {
      _overflow.add(index);
      return;
    }
    for (int y = top; y <= bottom; y++) {
      for (int x = left; x <= right; x++) {
        (_cells[(x, y)] ??= <int>[]).add(index);
      }
    }
  }

  static double _smoothstep(double edge0, double edge1, double x) {
    final double t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }
}

class _Nearest {
  const _Nearest(this.point, this.distance, this.direction);

  final InkVector point;
  final double distance;

  /// The stroke's heading there, of unit length.
  final InkVector direction;
}
