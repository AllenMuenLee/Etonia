// Pure Dart: no Flutter imports.
import 'dart:math' as math;

import 'ink_sample.dart';
import 'smoothing_config.dart';

/// Values from the most recent [OneEuroSmoother.add], exposed for diagnostics.
class SmoothingStep {
  const SmoothingStep({
    required this.dt,
    required this.speed,
    required this.cutoff,
    required this.derivativeAlpha,
    required this.positionAlpha,
  });

  /// The clamped time step, in seconds.
  final double dt;

  /// Magnitude of the low-pass-filtered derivative, in logical pixels/second.
  final double speed;

  /// Adaptive position cutoff used for this sample, in hertz.
  final double cutoff;

  /// Low-pass coefficient used for the derivative.
  final double derivativeAlpha;

  /// Low-pass coefficient used for the position.
  final double positionAlpha;
}

/// Streaming implementation of the One Euro filter for 2D pen input.
///
/// The filter is the adaptive first-order low-pass filter described by Casiez,
/// Roussel, and Vogel at CHI 2012. Its cutoff is
///
/// `cutoff = minCutoff + beta * |filtered derivative|`
///
/// so slow movement is heavily smoothed while fast movement remains responsive.
/// A single derivative magnitude drives both axes, making the 2D result
/// rotation-invariant. Work and memory are constant for every sample.
class OneEuroSmoother {
  OneEuroSmoother({this.config = const SmoothingConfig()});

  final SmoothingConfig config;

  InkVector? _start;
  InkVector _lastRaw = InkVector.zero;
  Duration _lastTimestamp = Duration.zero;
  InkVector _output = InkVector.zero;
  InkVector _filteredDerivative = InkVector.zero;
  SmoothingStep? _lastStep;

  /// The latest filtered point.
  InkVector get output => _output;

  SmoothingStep? get lastStep => _lastStep;

  /// Begins a stroke and returns its first point without introducing lag.
  InkVector start(RawInkSample sample) {
    if (!sample.position.isFinite) {
      throw ArgumentError.value(sample.position, 'sample', 'must be finite');
    }
    _start = sample.position;
    _lastRaw = sample.position;
    _lastTimestamp = sample.timestamp;
    _output = sample.position;
    _filteredDerivative = InkVector.zero;
    _lastStep = null;
    return _output;
  }

  /// Filters one sample, or returns null when its position is not finite.
  InkVector? add(RawInkSample sample) {
    assert(_start != null, 'start() must be called before add()');
    final InkVector position = sample.position;
    if (!position.isFinite) {
      return null;
    }

    final double dt = _clampedDt(sample.timestamp);
    _lastRaw = position;
    if (sample.timestamp > _lastTimestamp) {
      _lastTimestamp = sample.timestamp;
    }

    final InkVector delta = position - _output;
    if (!delta.isFinite) {
      // Subtracting two finite, opposite extremes can overflow. Recover
      // without allowing NaN or Infinity into the filter state.
      _output = position;
      _filteredDerivative = InkVector.zero;
      _lastStep = SmoothingStep(
        dt: dt,
        speed: 0,
        cutoff: config.minCutoff,
        derivativeAlpha: _alpha(dt, config.derivativeCutoff),
        positionAlpha: 1,
      );
      return _output;
    }

    // The reference implementation estimates variation from the previous
    // filtered value. This reacts quickly after filtering has accumulated lag.
    final InkVector derivative = delta * (1 / dt);
    final double derivativeAlpha = _alpha(dt, config.derivativeCutoff);
    _filteredDerivative = _lowPass(
      _filteredDerivative,
      derivative,
      derivativeAlpha,
    );

    final double speed = _magnitude(_filteredDerivative);
    // Avoid the IEEE-754 `0 * infinity = NaN` edge case for a deliberately
    // fixed-cutoff filter receiving an extreme but finite coordinate.
    final double cutoff = config.beta == 0
        ? config.minCutoff
        : config.minCutoff + config.beta * speed;
    final double positionAlpha = _alpha(dt, cutoff);
    final InkVector next = _output + delta * positionAlpha;
    if (next.isFinite) {
      _output = next;
    }

    _lastStep = SmoothingStep(
      dt: dt,
      speed: speed,
      cutoff: cutoff,
      derivativeAlpha: derivativeAlpha,
      positionAlpha: positionAlpha,
    );
    return _output;
  }

  /// Returns a short visual tail ending exactly at the final raw sample.
  ///
  /// The adaptive filter intentionally lags at low speed. Closing that small
  /// residual on pointer-up prevents visibly shortened strokes and preserves
  /// the user's intended endpoint.
  List<InkVector> finish() {
    if (_start == null) {
      return const <InkVector>[];
    }
    final InkVector from = _output;
    final InkVector residual = _lastRaw - from;
    final double distance = _magnitude(residual);
    if (distance <= config.endpointTolerance) {
      return const <InkVector>[];
    }
    if (!distance.isFinite) {
      _output = _lastRaw;
      _filteredDerivative = InkVector.zero;
      return <InkVector>[_lastRaw];
    }
    final int count = (distance / config.finalizationSpacing)
        .ceil()
        .clamp(1, config.maxFinalizationPoints)
        .toInt();
    final List<InkVector> tail = <InkVector>[
      for (int i = 1; i < count; i++) from + residual * _easeOut(i / count),
      _lastRaw,
    ];
    _output = _lastRaw;
    _filteredDerivative = InkVector.zero;
    return tail;
  }

  double _clampedDt(Duration timestamp) {
    final double raw =
        (timestamp - _lastTimestamp).inMicroseconds /
        Duration.microsecondsPerSecond;
    return raw.clamp(config.minDtSeconds, config.maxDtSeconds).toDouble();
  }

  static InkVector _lowPass(
    InkVector previous,
    InkVector current,
    double alpha,
  ) {
    return previous + (current - previous) * alpha;
  }

  /// RC low-pass coefficient: alpha = 1 / (1 + tau / dt),
  /// where tau = 1 / (2*pi*cutoff).
  static double _alpha(double dt, double cutoff) {
    final double scaled = 2 * math.pi * cutoff * dt;
    if (scaled.isInfinite) {
      return 1;
    }
    return scaled / (1 + scaled);
  }

  /// Overflow-safe Euclidean magnitude.
  static double _magnitude(InkVector value) {
    final double x = value.x.abs();
    final double y = value.y.abs();
    final double scale = math.max(x, y);
    if (scale == 0 || scale.isInfinite) {
      return scale;
    }
    final double sx = x / scale;
    final double sy = y / scale;
    return scale * math.sqrt(sx * sx + sy * sy);
  }

  static double _easeOut(double t) => 1 - math.pow(1 - t, 2).toDouble();
}
