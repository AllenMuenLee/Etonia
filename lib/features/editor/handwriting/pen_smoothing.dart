import 'dart:math' as math;

import '../ink/ink_sample.dart';
import '../ink/one_euro_smoother.dart';
import '../ink/pen_settings.dart';
import '../ink/smoothing_config.dart';
import 'stroke_runs.dart';

/// How strongly the letters of the writer's own font are smoothed, on the
/// pen's stabilization slider.
const double fontStabilization = 0.3;

/// About how many logical pixels a unit of the font's grid is when the
/// letter is written on the pad, so the pen's filter, tuned in pixels,
/// smooths a letter as it would smooth the pen.
const double _pixelsPerUnit = 6;

/// How fast, in logical pixels a second, and how often the pen is taken
/// to report, for a letter that has no timing of its own.
const double _penSpeed = 250;
const Duration _sampleInterval = Duration(microseconds: 4167); // 240 Hz.

/// How many times longer the pen takes over a sample where the stroke
/// turns right round than where it runs straight.
const double _cornerSlowing = 8;

final SmoothingConfig _config = PenSettings.defaults()
    .copyWith(stabilization: fontStabilization)
    .smoothing(const SmoothingConfig());

/// [stroke], in the font's grid, smoothed by the pen's own filter at
/// [fontStabilization], as if written at a steady pace that slows into
/// corners, then sampled every [spacing] again. Its ends stay where they were; a dot stays a dot.
List<InkVector> penSmoothed(List<InkVector> stroke, {required double spacing}) {
  if (stroke.length < 2) return stroke;
  final double step =
      _penSpeed *
      _sampleInterval.inMicroseconds /
      Duration.microsecondsPerSecond /
      _pixelsPerUnit;
  final List<InkVector> even = resampled(densified(stroke, step), step);
  // A pen slows into a corner and out of it, so its filter keeps the point
  // of a v: here the pen takes longer over a sample the more the stroke
  // turns about it.
  const int reach = 4;
  Duration time = Duration.zero;
  final OneEuroSmoother smoother = OneEuroSmoother(config: _config);
  final List<InkVector> out = <InkVector>[
    smoother.start(
      RawInkSample(position: even.first * _pixelsPerUnit, timestamp: time),
    ),
  ];
  for (int i = 1; i < even.length; i++) {
    final InkVector before = even[i] - even[math.max(0, i - reach)];
    final InkVector after =
        even[math.min(even.length - 1, i + reach)] - even[i];
    // How far the stroke turns about this sample, from 0 to 1.
    final double turn = before.length == 0 || after.length == 0
        ? 0
        : math
                  .atan2(
                    before.x * after.y - before.y * after.x,
                    before.x * after.x + before.y * after.y,
                  )
                  .abs() /
              math.pi;
    time += _sampleInterval * (1 + _cornerSlowing * turn);
    final InkVector? p = smoother.add(
      RawInkSample(position: even[i] * _pixelsPerUnit, timestamp: time),
    );
    if (p != null) out.add(p);
  }
  out.addAll(smoother.finish());
  return resampled(<InkVector>[
    for (final InkVector p in out) p * (1 / _pixelsPerUnit),
  ], spacing);
}
