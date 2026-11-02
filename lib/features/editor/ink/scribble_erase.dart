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
    this.minReversals = 6,
    this.swingFraction = 0.3,
    this.minSwing = 8,
    this.minReversalsPerSecond = 6,
    this.maxSpacing = 0.4,
    this.coverage = 0.6,
  }) : assert(minReversals > 1),
       assert(swingFraction > 0 && swingFraction <= 1),
       assert(minReversalsPerSecond > 0),
       assert(maxSpacing > 0),
       assert(coverage > 0 && coverage <= 1);

  /// A scribble turns back vertically at least [minReversals] times, each
  /// swing at least [swingFraction] of the stroke's height and at least
  /// [minSwing].
  final int minReversals;
  final double swingFraction;
  final double minSwing;

  /// How fast a scribble turns back, from its first turn to its last. A rate
  /// rather than a speed, so that it means the same at any zoom.
  final double minReversalsPerSecond;

  /// How far a scribble may travel sideways per swing, as a fraction of how
  /// far it travels vertically: the smaller, the denser the swings must be.
  final double maxSpacing;

  /// How much of a stroke's box must lie within the scribble's box, by
  /// area, for the scribble to take that stroke out.
  final double coverage;
}

/// Tells a scribble drawn over ink, to cross it out, from writing.
abstract final class ScribbleErase {
  /// Whether [samples] rush up and down in densely packed swings. Going by
  /// the raw samples, since only those know when the pen was where.
  static bool isScribble(
    List<RawInkSample> samples, [
    ScribbleConfig config = const ScribbleConfig(),
  ]) {
    if (samples.isEmpty) {
      return false;
    }
    final double swing = math.max(
      config.minSwing,
      _heightOf(samples) * config.swingFraction,
    );
    final List<RawInkSample> turns = _turns(samples, swing);
    if (turns.length < config.minReversals) {
      return false;
    }
    // Between the first and last turns, so that resting the pen before or
    // after the scribble does not slow it down. Samples that all claim the
    // same moment say nothing about speed, and do not count as a rush.
    final Duration elapsed = turns.last.timestamp - turns.first.timestamp;
    if (elapsed <= Duration.zero) {
      return false;
    }
    final double perSecond =
        (turns.length - 1) *
        Duration.microsecondsPerSecond /
        elapsed.inMicroseconds;
    if (perSecond < config.minReversalsPerSecond) {
      return false;
    }
    double vertical = 0;
    double sideways = 0;
    for (int i = 1; i < turns.length; i++) {
      final InkVector step = turns[i].position - turns[i - 1].position;
      vertical += step.y.abs();
      sideways += step.x.abs();
    }
    return sideways <= vertical * config.maxSpacing;
  }

  /// The samples at which [samples] turn back vertically. Only turns that
  /// come back at least [swing] from the furthest point reached count, so
  /// jitter is never a turn.
  static List<RawInkSample> _turns(List<RawInkSample> samples, double swing) {
    final List<RawInkSample> turns = <RawInkSample>[];
    int direction = 0;
    RawInkSample extreme = samples.first;
    for (final RawInkSample sample in samples.skip(1)) {
      final double moved = sample.position.y - extreme.position.y;
      if (direction == 0) {
        if (moved.abs() >= swing) {
          direction = moved > 0 ? 1 : -1;
          extreme = sample;
        }
      } else if (moved * direction > 0) {
        extreme = sample;
      } else if (-moved * direction >= swing) {
        turns.add(extreme);
        direction = -direction;
        extreme = sample;
      }
    }
    return turns;
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
    Iterable<int>? candidateIndices,
  }) {
    if (scribble.isDot ||
        scribble.style.isHighlighter ||
        !isScribble(scribble.rawSamples, config)) {
      return const <int>[];
    }
    final Rect area = scribble.bounds;
    final List<InkVector> path = scribble.points;
    final List<int> result = <int>[];
    for (final int i
        in candidateIndices ?? Iterable<int>.generate(strokes.length)) {
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

  static double _heightOf(List<RawInkSample> samples) {
    double top = double.infinity;
    double bottom = double.negativeInfinity;
    for (final RawInkSample sample in samples) {
      top = math.min(top, sample.position.y);
      bottom = math.max(bottom, sample.position.y);
    }
    return bottom - top;
  }
}
