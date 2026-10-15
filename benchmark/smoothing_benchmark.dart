// Micro-benchmark for the smoothing engine alone (no rendering).
//
//   dart run benchmark/smoothing_benchmark.dart
//
// Feeds long synthetic strokes at a 240 Hz sample rate and reports the cost
// per sample. One sample must cost far less than the ~4 ms between samples.
import 'dart:io';
import 'dart:math' as math;

import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/one_euro_smoother.dart';

const int _sampleRate = 240;
const int _samplesPerStroke = 60 * _sampleRate;
const int _strokes = 50;

void main() {
  final math.Random random = math.Random(1);
  const Duration interval = Duration(
    microseconds: Duration.microsecondsPerSecond ~/ _sampleRate,
  );
  final List<RawInkSample> samples = <RawInkSample>[
    for (int i = 0; i < _samplesPerStroke; i++)
      RawInkSample(
        position: InkVector(
          600 + 400 * math.cos(i / 90) + random.nextDouble(),
          400 + 300 * math.sin(i / 70) + random.nextDouble(),
        ),
        timestamp: interval * i,
      ),
  ];

  double checksum = 0;
  void run() {
    final OneEuroSmoother smoother = OneEuroSmoother()..start(samples.first);
    for (int i = 1; i < samples.length; i++) {
      checksum += smoother.add(samples[i])!.x;
    }
    checksum += smoother.finish().length;
  }

  for (int i = 0; i < 5; i++) {
    run(); // Warm up the JIT.
  }
  final Stopwatch stopwatch = Stopwatch()..start();
  for (int i = 0; i < _strokes; i++) {
    run();
  }
  stopwatch.stop();

  const int total = _strokes * _samplesPerStroke;
  final double nanosPerSample = stopwatch.elapsedMicroseconds * 1000 / total;
  stdout
    ..writeln('samples:       $total ($_strokes strokes of 60 s at 240 Hz)')
    ..writeln('elapsed:       ${stopwatch.elapsedMilliseconds} ms')
    ..writeln('per sample:    ${nanosPerSample.toStringAsFixed(1)} ns')
    ..writeln('sample budget: ${interval.inMicroseconds} us')
    ..writeln('checksum:      ${checksum.toStringAsFixed(3)}');
}
