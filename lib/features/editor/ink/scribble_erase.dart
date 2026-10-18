import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';

import 'erase_geometry.dart';
import 'ink_sample.dart';
import 'stroke.dart';

/// Thresholds for scribbling ink out with the pen. All lengths are logical
/// canvas pixels.
@immutable
class ScribbleConfig {
  const ScribbleConfig({
    this.minReversals = 4,
    this.swingFraction = 0.3,
    this.minSwing = 8,
    this.coverage = 0.6,
  }) : assert(minReversals > 0),
       assert(swingFraction > 0 && swingFraction <= 1),
       assert(coverage > 0 && coverage <= 1);

  /// A scribble swings back and forth at least [minReversals] times, along
  /// either axis, each swing at least [swingFraction] of the stroke's
  /// extent along that axis and at least [minSwing].
  final int minReversals;
  final double swingFraction;
  final double minSwing;

  /// How much of a stroke's box must lie within the scribble's box, by
  /// area, for the scribble to take that stroke out.
  final double coverage;
}

/// Tells a scribble drawn over ink, to cross it out, from writing.
abstract final class ScribbleErase {
  /// How many times [points] turn back along one axis: x when [alongX],
  /// else y. Only turns that come back at least [swing] from the furthest
  /// point reached count, so jitter is never a turn.
  static int reversals(
    List<InkVector> points, {
    required bool alongX,
    required double swing,
  }) {
    if (points.isEmpty) {
      return 0;
    }
    double along(InkVector p) => alongX ? p.x : p.y;
    int reversals = 0;
    int direction = 0;
    double extreme = along(points.first);
    for (final InkVector point in points.skip(1)) {
      final double value = along(point);
      if (direction == 0) {
        if ((value - extreme).abs() >= swing) {
          direction = value > extreme ? 1 : -1;
          extreme = value;
        }
      } else if ((value - extreme) * direction > 0) {
        extreme = value;
      } else if ((extreme - value) * direction >= swing) {
        reversals++;
        direction = -direction;
        extreme = value;
      }
    }
    return reversals;
  }

  /// Whether [points] zigzag like a scribble, sideways or up and down.
  static bool isZigzag(
    List<InkVector> points, [
    ScribbleConfig config = const ScribbleConfig(),
  ]) {
    if (points.length < 2 * config.minReversals) {
      return false;
    }
    final Rect bounds = _boundsOf(points);
    for (final bool alongX in <bool>[true, false]) {
      final double extent = alongX ? bounds.width : bounds.height;
      final double swing = math.max(
        config.minSwing,
        extent * config.swingFraction,
      );
      if (reversals(points, alongX: alongX, swing: swing) >=
          config.minReversals) {
        return true;
      }
    }
    return false;
  }

  /// The indices of the strokes in [strokes] that [scribble] crosses out:
  /// those it touches whose box lies mostly within its own. Empty when
  /// [scribble] is not a scribble, or crosses nothing out; it is then
  /// ordinary ink. Strokes for which [skip] is true are passed over.
  static List<int> targets(
    Stroke scribble,
    List<Stroke> strokes, {
    ScribbleConfig config = const ScribbleConfig(),
    bool Function(Stroke stroke)? skip,
  }) {
    if (scribble.isDot ||
        scribble.style.isHighlighter ||
        !isZigzag(scribble.points, config)) {
      return const <int>[];
    }
    final Rect area = scribble.bounds;
    final List<InkVector> path = scribble.points;
    final List<int> result = <int>[];
    for (int i = 0; i < strokes.length; i++) {
      final Stroke stroke = strokes[i];
      if (skip?.call(stroke) ?? false) {
        continue;
      }
      final Rect bounds = stroke.bounds;
      if (!bounds.overlaps(area) || !_covers(area, bounds, config.coverage)) {
        continue;
      }
      final double reach = (scribble.style.width + stroke.style.width) / 2;
      if (_touches(path, stroke.points, reach)) {
        result.add(i);
      }
    }
    return result;
  }

  static bool _covers(Rect area, Rect bounds, double coverage) {
    // Stroke bounds include half the width, so even a straight line has an
    // area to cover.
    final Rect overlap = area.intersect(bounds);
    if (overlap.width <= 0 || overlap.height <= 0) {
      return false;
    }
    return overlap.width * overlap.height >=
        bounds.width * bounds.height * coverage;
  }

  static bool _touches(
    List<InkVector> scribble,
    List<InkVector> target,
    double reach,
  ) {
    if (scribble.length == 1) {
      return EraseGeometry.polylineTouchesCapsule(
        target,
        scribble.first,
        scribble.first,
        reach,
      );
    }
    for (int i = 1; i < scribble.length; i++) {
      if (EraseGeometry.polylineTouchesCapsule(
        target,
        scribble[i - 1],
        scribble[i],
        reach,
      )) {
        return true;
      }
    }
    return false;
  }

  static Rect _boundsOf(List<InkVector> points) {
    double left = double.infinity;
    double top = double.infinity;
    double right = double.negativeInfinity;
    double bottom = double.negativeInfinity;
    for (final InkVector point in points) {
      left = math.min(left, point.x);
      top = math.min(top, point.y);
      right = math.max(right, point.x);
      bottom = math.max(bottom, point.y);
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }
}
