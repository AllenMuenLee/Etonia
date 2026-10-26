import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/one_euro_smoother.dart';
import 'package:greatnote/features/editor/ink/smoothing_config.dart';

const double _epsilon = 1e-9;

RawInkSample _at(double x, double y, int milliseconds) {
  return RawInkSample(
    position: InkVector(x, y),
    timestamp: Duration(milliseconds: milliseconds),
  );
}

List<InkVector> _run(
  List<RawInkSample> samples, {
  SmoothingConfig config = const SmoothingConfig(),
}) {
  final OneEuroSmoother smoother = OneEuroSmoother(config: config);
  return <InkVector>[
    smoother.start(samples.first),
    for (final RawInkSample sample in samples.skip(1)) smoother.add(sample)!,
  ];
}

void _expectFinite(Iterable<InkVector> points) {
  for (final InkVector point in points) {
    expect(point.isFinite, isTrue, reason: '$point');
  }
}

void main() {
  group('One Euro formula', () {
    test('uses the reference RC coefficient and adaptive cutoff', () {
      const SmoothingConfig config = SmoothingConfig(
        minCutoff: 1,
        beta: 0.02,
        derivativeCutoff: 1,
      );
      final OneEuroSmoother smoother = OneEuroSmoother(config: config)
        ..start(_at(0, 0, 0));

      final InkVector output = smoother.add(_at(10, 0, 10))!;
      final SmoothingStep step = smoother.lastStep!;

      const double dt = 0.01;
      final double derivativeAlpha =
          (2 * math.pi * config.derivativeCutoff * dt) /
          (1 + 2 * math.pi * config.derivativeCutoff * dt);
      final double speed = derivativeAlpha * 1000;
      final double cutoff = config.minCutoff + config.beta * speed;
      final double positionAlpha =
          (2 * math.pi * cutoff * dt) / (1 + 2 * math.pi * cutoff * dt);

      expect(step.dt, dt);
      expect(step.derivativeAlpha, closeTo(derivativeAlpha, _epsilon));
      expect(step.speed, closeTo(speed, _epsilon));
      expect(step.cutoff, closeTo(cutoff, _epsilon));
      expect(step.positionAlpha, closeTo(positionAlpha, _epsilon));
      expect(output.x, closeTo(10 * positionAlpha, _epsilon));
      expect(output.y, 0);
    });

    test('beta zero is a fixed first-order low-pass filter', () {
      const SmoothingConfig config = SmoothingConfig(minCutoff: 2, beta: 0);
      final OneEuroSmoother smoother = OneEuroSmoother(config: config)
        ..start(_at(0, 0, 0));
      final InkVector output = smoother.add(_at(10, 0, 20))!;
      final double scaled = 2 * math.pi * config.minCutoff * 0.02;
      final double alpha = scaled / (1 + scaled);

      expect(smoother.lastStep!.cutoff, config.minCutoff);
      expect(output.x, closeTo(alpha * 10, _epsilon));
    });
  });

  group('slow-speed stabilization', () {
    const SmoothingConfig steady = SmoothingConfig(slowCutoffScale: 0.25);

    test('scales the cutoff fully when slow, not at all when fast', () {
      expect(steady.cutoffScaleAt(0), 0.25);
      expect(steady.cutoffScaleAt(steady.slowSpeed), 0.25);
      expect(steady.cutoffScaleAt(steady.fastSpeed), 1);
      expect(steady.cutoffScaleAt(5000), 1);
      final double middle = steady.cutoffScaleAt(
        (steady.slowSpeed + steady.fastSpeed) / 2,
      );
      expect(middle, inExclusiveRange(0.25, 1));
    });

    test('a scale of 1 leaves the filter as it was', () {
      const SmoothingConfig plain = SmoothingConfig();
      expect(plain.cutoffScaleAt(0), 1);
      expect(plain.cutoffScaleAt(200), 1);
    });

    test('a slow stroke is steadier than with the scale off', () {
      // 60 px/s along x with 1 px of alternating sideways shake.
      final List<RawInkSample> samples = <RawInkSample>[
        for (int i = 0; i < 60; i++) _at(i * 1.0, i.isEven ? 1 : -1, i * 16),
      ];
      double wobble(SmoothingConfig config) {
        final List<InkVector> out = _run(samples, config: config);
        return out.skip(20).map((InkVector p) => p.y.abs()).reduce(math.max);
      }

      expect(wobble(steady), lessThan(wobble(const SmoothingConfig())));
    });

    test('a fast stroke is smoothed the same either way', () {
      final List<RawInkSample> samples = <RawInkSample>[
        for (int i = 0; i < 40; i++) _at(i * 16.0, 0, i * 16),
      ];
      final List<InkVector> a = _run(samples, config: steady);
      final List<InkVector> b = _run(samples);
      // Early samples still count as slow; once up to speed they agree.
      expect(a.last.x, closeTo(b.last.x, 25));
    });
  });

  group('pen behavior', () {
    test('suppresses stationary high-frequency jitter', () {
      final math.Random random = math.Random(7);
      final List<RawInkSample> samples = <RawInkSample>[
        _at(100, 100, 0),
        for (int i = 1; i <= 500; i++)
          _at(
            100 + random.nextDouble() * 2 - 1,
            100 + random.nextDouble() * 2 - 1,
            i * 4,
          ),
      ];
      final List<InkVector> filtered = _run(samples);

      double rawEnergy = 0;
      double filteredEnergy = 0;
      for (int i = 100; i < samples.length; i++) {
        final InkVector raw = samples[i].position - const InkVector(100, 100);
        final InkVector smooth = filtered[i] - const InkVector(100, 100);
        rawEnergy += raw.dot(raw);
        filteredEnergy += smooth.dot(smooth);
      }

      expect(filteredEnergy, lessThan(rawEnergy * 0.1));
    });

    test('adaptive cutoff has less fast-motion lag than a fixed filter', () {
      final List<RawInkSample> samples = <RawInkSample>[
        for (int i = 0; i <= 100; i++) _at(i * 8, 0, i * 4),
      ];
      final List<InkVector> adaptive = _run(samples);
      final List<InkVector> fixed = _run(
        samples,
        config: const SmoothingConfig(beta: 0),
      );
      final double adaptiveLag = samples.last.position.x - adaptive.last.x;
      final double fixedLag = samples.last.position.x - fixed.last.x;

      expect(adaptiveLag, lessThan(10));
      expect(adaptiveLag, lessThan(fixedLag * 0.2));
    });

    test('uses one speed for both axes and is rotation-invariant', () {
      final List<RawInkSample> horizontal = <RawInkSample>[
        for (int i = 0; i <= 80; i++) _at(i * 3, math.sin(i / 7) * 4, i * 5),
      ];
      final List<RawInkSample> vertical = <RawInkSample>[
        for (final RawInkSample sample in horizontal)
          RawInkSample(
            position: InkVector(-sample.position.y, sample.position.x),
            timestamp: sample.timestamp,
          ),
      ];
      final List<InkVector> a = _run(horizontal);
      final List<InkVector> b = _run(vertical);

      for (int i = 0; i < a.length; i++) {
        expect(b[i].x, closeTo(-a[i].y, 1e-7));
        expect(b[i].y, closeTo(a[i].x, 1e-7));
      }
    });

    test('preserves constant-coordinate straight lines', () {
      final List<InkVector> horizontal = _run(<RawInkSample>[
        for (int i = 0; i <= 100; i++) _at(i * 5, 30, i * 8),
      ]);
      final List<InkVector> vertical = _run(<RawInkSample>[
        for (int i = 0; i <= 100; i++) _at(20, i * 5, i * 8),
      ]);

      expect(horizontal.every((InkVector p) => p.y == 30), isTrue);
      expect(vertical.every((InkVector p) => p.x == 20), isTrue);
    });
  });

  group('time and robustness', () {
    test('clamps duplicate, backwards, and long timestamp intervals', () {
      const SmoothingConfig config = SmoothingConfig();
      final OneEuroSmoother smoother = OneEuroSmoother()..start(_at(0, 0, 100));

      smoother.add(_at(1, 0, 100));
      expect(smoother.lastStep!.dt, config.minDtSeconds);
      smoother.add(_at(2, 0, 40));
      expect(smoother.lastStep!.dt, config.minDtSeconds);
      smoother.add(_at(3, 0, 5000));
      expect(smoother.lastStep!.dt, config.maxDtSeconds);
    });

    test('tap and repeated samples remain at the same point', () {
      final OneEuroSmoother smoother = OneEuroSmoother()..start(_at(40, 40, 0));
      for (int i = 1; i < 20; i++) {
        expect(smoother.add(_at(40, 40, i * 8)), const InkVector(40, 40));
      }
      expect(smoother.finish(), isEmpty);
    });

    test('rejects non-finite input and recovers from finite extremes', () {
      final OneEuroSmoother smoother = OneEuroSmoother()
        ..start(_at(0, 0, 0))
        ..add(_at(10, 0, 8));

      expect(smoother.add(_at(double.nan, 5, 16)), isNull);
      expect(smoother.add(_at(double.infinity, 5, 24)), isNull);
      for (final double extreme in <double>[1e300, -1e300, 1e-300]) {
        expect(smoother.add(_at(extreme, extreme, 32))!.isFinite, isTrue);
      }
      _expectFinite(smoother.finish());
    });

    test('identical samples produce identical output', () {
      final math.Random random = math.Random(3);
      final List<RawInkSample> samples = <RawInkSample>[
        for (int i = 0; i < 300; i++)
          _at(random.nextDouble() * 800, random.nextDouble() * 600, i * 7),
      ];

      expect(_run(samples), _run(samples));
    });
  });

  group('finalization', () {
    test(
      'ends exactly at the raw endpoint within the configured point cap',
      () {
        const SmoothingConfig config = SmoothingConfig(
          maxFinalizationPoints: 4,
        );
        final OneEuroSmoother smoother = OneEuroSmoother(config: config)
          ..start(_at(0, 0, 0));
        for (int i = 1; i <= 20; i++) {
          smoother.add(_at(i * 3, i.toDouble(), i * 8));
        }
        final InkVector before = smoother.output;
        final List<InkVector> tail = smoother.finish();

        expect(tail, isNotEmpty);
        expect(tail.length, lessThanOrEqualTo(config.maxFinalizationPoints));
        expect(tail.last, const InkVector(60, 20));
        double previous = (before - tail.last).length;
        for (final InkVector point in tail) {
          final double remaining = (point - tail.last).length;
          expect(remaining, lessThan(previous));
          previous = remaining;
        }
        expect(smoother.finish(), isEmpty);
      },
    );
  });
}
