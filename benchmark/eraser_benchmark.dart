// Micro-benchmark for erasing on a full page (no rendering).
//
//   flutter test benchmark/eraser_benchmark.dart
//
// It runs under `flutter test` rather than `dart run` because finished
// strokes own a `dart:ui` Path, so the timings include rebuilding the paths
// of cut strokes. The test VM is JIT-compiled; a release build is faster.
//
// Fills a page with handwriting-sized strokes, then drags the eraser over it
// at a 240 Hz sample rate and reports the cost per eraser move. One move
// must cost far less than the ~4 ms between samples.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

const int _sampleRate = 240;
const int _gestureSeconds = 20;
const int _moves = _gestureSeconds * _sampleRate;
const int _warmUps = 3;
const int _runs = 10;

const double _pageWidth = 1100;
const double _pageHeight = 760;
const int _rows = 24;
const int _strokesPerRow = 30;
const int _pointsPerStroke = 60;

/// A page of [rows] x [strokesPerRow] short, curly strokes, like lines of
/// handwriting.
List<Stroke> _page({int rows = _rows, int strokesPerRow = _strokesPerRow}) {
  final math.Random random = math.Random(1);
  const StrokeStyle style = StrokeStyle(ink: InkPalette.ink, width: 3);
  final double cellWidth = _pageWidth / strokesPerRow;
  final double rowHeight = _pageHeight / rows;
  return <Stroke>[
    for (int row = 0; row < rows; row++)
      for (int column = 0; column < strokesPerRow; column++)
        Stroke.fromPoints(
          style: style,
          points: <InkVector>[
            for (int i = 0; i < _pointsPerStroke; i++)
              InkVector(
                column * cellWidth +
                    cellWidth * 0.8 * i / _pointsPerStroke +
                    4 * math.cos(i / 3 + column) +
                    random.nextDouble() * 0.2,
                (row + 0.5) * rowHeight +
                    rowHeight * 0.3 * math.sin(i / 4 + row) +
                    random.nextDouble() * 0.2,
              ),
          ],
        ),
  ];
}

/// The eraser's path: a scribble that works its way down the whole page at
/// roughly 1500 px/s.
List<InkVector> _gesture() {
  return <InkVector>[
    for (int i = 0; i <= _moves; i++)
      InkVector(
        _pageWidth * (0.5 + 0.45 * math.sin(i / _moves * 28 * math.pi)),
        _pageHeight * (0.05 + 0.9 * i / _moves) + 12 * math.sin(i / 7),
      ),
  ];
}

void main() {
  final List<InkVector> gesture = _gesture();

  for (final (
        List<Stroke> page,
        EraserSettings settings,
      ) in <(List<Stroke>, EraserSettings)>[
    (_page(), const EraserSettings(mode: EraserMode.area, size: 24)),
    (_page(), const EraserSettings(mode: EraserMode.area, size: 80)),
    (_page(), const EraserSettings(mode: EraserMode.stroke, size: 24)),
    // The density at which a move must stay under a millisecond.
    (
      _page(rows: 100, strokesPerRow: 100),
      const EraserSettings(mode: EraserMode.area, size: 24),
    ),
    (
      _page(rows: 100, strokesPerRow: 100),
      const EraserSettings(mode: EraserMode.stroke, size: 24),
    ),
  ]) {
    final String name =
        '${page.length} strokes, '
        '${settings.mode == EraserMode.area ? 'area, ${settings.size.round()} px' : 'stroke'}';

    test('eraser gesture: $name', () {
      final List<int> moveMicros = <int>[];
      int repaints = 0;
      int strokesLeft = 0;
      int pointsLeft = 0;

      for (int run = 0; run < _warmUps + _runs; run++) {
        final bool measured = run >= _warmUps;
        final InkController controller = InkController(strokes: page);
        if (measured) {
          controller.completedStrokesListenable.addListener(() => repaints++);
        }
        final Stopwatch stopwatch = Stopwatch();
        controller.startErase(
          pointer: 1,
          position: gesture.first,
          settings: settings,
        );
        for (int i = 1; i < gesture.length; i++) {
          stopwatch
            ..reset()
            ..start();
          controller.eraseTo(1, gesture[i]);
          stopwatch.stop();
          if (measured) {
            moveMicros.add(stopwatch.elapsedMicroseconds);
          }
        }
        controller.endErase(1);
        strokesLeft = controller.strokes.length;
        pointsLeft = controller.strokes.fold<int>(
          0,
          (int sum, Stroke stroke) => sum + stroke.points.length,
        );
        controller.dispose();
      }

      moveMicros.sort();
      final double mean =
          moveMicros.reduce((int a, int b) => a + b) / moveMicros.length;
      int percentile(double p) {
        return moveMicros[((moveMicros.length - 1) * p).round()];
      }

      // ignore: avoid_print
      print(
        '\n$name\n'
        '  page:          ${page.length} strokes, '
        '${page.length * _pointsPerStroke} points\n'
        '  gesture:       $_moves moves '
        '($_gestureSeconds s at $_sampleRate Hz), $_runs runs\n'
        '  after:         $strokesLeft strokes, $pointsLeft points\n'
        '  ink repaints:  ${repaints ~/ _runs} of $_moves moves\n'
        '  per move:      mean ${mean.toStringAsFixed(1)} us, '
        'median ${percentile(0.5)} us, p99 ${percentile(0.99)} us, '
        'max ${moveMicros.last} us\n'
        '  sample budget: '
        '${Duration.microsecondsPerSecond ~/ _sampleRate} us',
      );

      expect(strokesLeft, isNot(page.length));
    });
  }
}
