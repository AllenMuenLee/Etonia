// Micro-benchmark for selecting and transforming ink on a full page (no
// rendering).
//
//   flutter test benchmark/selection_benchmark.dart
//
// It runs under `flutter test` rather than `dart run` because finished
// strokes own a `dart:ui` Path, so committing a transform includes rebuilding
// the paths of the selected strokes. The test VM is JIT-compiled; a release
// build is faster.
//
// Fills a page with handwriting-sized strokes and draws one long lasso over
// much of it at a 240 Hz sample rate. Selection happens once, at pointer-up,
// and is reported in its parts. A transform preview happens on every pointer
// move and must cost far less than the ~4 ms between samples; the commit
// happens once.
import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/ink_selection.dart';
import 'package:greatnote/features/editor/ink/selection_geometry.dart';
import 'package:greatnote/features/editor/ink/selection_transform.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

const int _sampleRate = 240;
const int _lassoSeconds = 8;
const int _lassoSamples = _lassoSeconds * _sampleRate;
const int _previewMoves = 4 * _sampleRate;
const int _warmUps = 5;
const int _runs = 30;

const double _pageWidth = 1100;
const double _pageHeight = 760;
const int _rows = 24;
const int _strokesPerRow = 30;
const int _pointsPerStroke = 60;

/// A page of [_rows] x [_strokesPerRow] short, curly strokes, like lines of
/// handwriting.
List<Stroke> _page() {
  final math.Random random = math.Random(1);
  const StrokeStyle style = StrokeStyle(ink: InkPalette.ink, width: 3);
  const double cellWidth = _pageWidth / _strokesPerRow;
  const double rowHeight = _pageHeight / _rows;
  return <Stroke>[
    for (int row = 0; row < _rows; row++)
      for (int column = 0; column < _strokesPerRow; column++)
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

/// The pointer's path for the lasso: a wobbly loop over the middle of the
/// page, one sample per 240 Hz tick.
List<InkVector> _lassoSamplePath() {
  return <InkVector>[
    for (int i = 0; i < _lassoSamples; i++)
      () {
        final double turn = i / _lassoSamples * 2 * math.pi;
        final double radius = 1 + 0.15 * math.sin(9 * turn);
        return InkVector(
          _pageWidth * (0.5 + 0.33 * radius * math.cos(turn)),
          _pageHeight * (0.5 + 0.33 * radius * math.sin(turn)),
        );
      }(),
  ];
}

class _Timings {
  final List<int> _micros = <int>[];

  void add(Stopwatch stopwatch) => _micros.add(stopwatch.elapsedMicroseconds);

  String describe() {
    final List<int> sorted = List<int>.of(_micros)..sort();
    final double mean = sorted.reduce((int a, int b) => a + b) / sorted.length;
    int percentile(double p) => sorted[((sorted.length - 1) * p).round()];
    return 'mean ${mean.toStringAsFixed(1)} us, median ${percentile(0.5)} us, '
        'p99 ${percentile(0.99)} us, max ${sorted.last} us';
  }
}

void main() {
  final List<Stroke> page = _page();
  final List<InkVector> samples = _lassoSamplePath();

  test('lasso selection on a full page', () {
    final _Timings perMove = _Timings();
    final _Timings region = _Timings();
    final _Timings broadPhase = _Timings();
    final _Timings geometry = _Timings();
    final _Timings total = _Timings();
    int storedPoints = 0;
    int candidates = 0;
    int selected = 0;
    int inkRepaints = 0;

    for (int run = 0; run < _warmUps + _runs; run++) {
      final bool measured = run >= _warmUps;
      final InkController controller = InkController(strokes: page);
      if (measured) {
        controller.completedStrokesListenable.addListener(() => inkRepaints++);
      }
      final Stopwatch stopwatch = Stopwatch();

      // Capturing the lasso: one call per pointer move.
      controller.beginLasso(pointer: 1, position: samples.first);
      for (int i = 1; i < samples.length; i++) {
        stopwatch
          ..reset()
          ..start();
        controller.updateLasso(1, samples[i]);
        stopwatch.stop();
        if (measured) {
          perMove.add(stopwatch);
        }
      }
      final List<InkVector> points = List<InkVector>.of(
        controller.activeLasso!.points,
      );
      storedPoints = points.length;

      // The parts of selection, timed on their own.
      stopwatch
        ..reset()
        ..start();
      final LassoRegion lasso = LassoRegion(
        points,
        tolerance: controller.selectionConfig.geometryTolerance,
      );
      stopwatch.stop();
      if (measured) {
        region.add(stopwatch);
      }

      stopwatch
        ..reset()
        ..start();
      final List<Stroke> reached = <Stroke>[];
      for (final Stroke stroke in page) {
        final Rect bounds = stroke.bounds;
        if (lasso.overlapsBounds(
          bounds.left,
          bounds.top,
          bounds.right,
          bounds.bottom,
        )) {
          reached.add(stroke);
        }
      }
      stopwatch.stop();
      if (measured) {
        broadPhase.add(stopwatch);
      }

      stopwatch
        ..reset()
        ..start();
      int hits = 0;
      for (final Stroke stroke in reached) {
        if (lasso.overlapsInk(
          stroke.points,
          width: stroke.style.width,
          isDot: stroke.isDot,
        )) {
          hits++;
        }
      }
      stopwatch.stop();
      if (measured) {
        geometry.add(stopwatch);
      }

      // And the whole thing as the app runs it, at pointer-up.
      stopwatch
        ..reset()
        ..start();
      controller.endLasso(1);
      stopwatch.stop();
      if (measured) {
        total.add(stopwatch);
      }

      final StrokeSelectionResult result = selectStrokes(page, lasso);
      candidates = result.candidates;
      selected = controller.selection!.count;
      expect(reached.length, candidates);
      expect(hits, selected);
      expect(result.indices, controller.selection!.indices);
      controller.dispose();
    }

    // ignore: avoid_print
    print(
      '\nlasso selection\n'
      '  page:                 ${page.length} strokes, '
      '${page.length * _pointsPerStroke} points\n'
      '  lasso:                $_lassoSamples samples '
      '($_lassoSeconds s at $_sampleRate Hz), $storedPoints stored points, '
      '$_runs runs\n'
      '  broad-phase:          $candidates candidates of ${page.length} '
      'strokes\n'
      '  selected:             $selected strokes\n'
      '  ink repaints:         ${inkRepaints ~/ _runs} per gesture\n'
      '  per lasso move:       ${perMove.describe()}\n'
      '  build region:         ${region.describe()}\n'
      '  broad phase:          ${broadPhase.describe()}\n'
      '  geometry:             ${geometry.describe()}\n'
      '  total, at pointer-up: ${total.describe()}\n'
      '  sample budget:        '
      '${Duration.microsecondsPerSecond ~/ _sampleRate} us',
    );

    expect(selected, greaterThan(200));
    expect(selected, lessThan(page.length));
    expect(candidates, lessThan(page.length));
  });

  for (final SelectionOperation operation in SelectionOperation.values) {
    test('${operation.name} preview and commit of a large selection', () {
      final _Timings perMove = _Timings();
      final _Timings commit = _Timings();
      int selected = 0;
      int inkRepaints = 0;
      int previews = 0;

      for (int run = 0; run < _warmUps + _runs; run++) {
        final bool measured = run >= _warmUps;
        final InkController controller = InkController(strokes: page);
        controller.beginLasso(pointer: 1, position: samples.first);
        for (int i = 1; i < samples.length; i++) {
          controller.updateLasso(1, samples[i]);
        }
        controller.endLasso(1);
        selected = controller.selection!.count;
        final List<Stroke> before = List<Stroke>.of(controller.strokes);
        if (measured) {
          controller.completedStrokesListenable.addListener(
            () => inkRepaints++,
          );
          controller.selectionListenable.addListener(() => previews++);
        }

        final SelectionFrame frame = controller.selection!.frame;
        final InkVector start = switch (operation) {
          SelectionOperation.move => frame.center,
          SelectionOperation.scale => frame.corners[2],
          SelectionOperation.rotate => frame.rotationHandle(
            controller.selectionConfig.rotationHandleOffset,
          ),
        };
        expect(
          controller.beginSelectionGesture(pointer: 1, position: start),
          isTrue,
        );
        expect(controller.activeTransform!.operation, operation);

        final Stopwatch stopwatch = Stopwatch();
        for (int i = 1; i <= _previewMoves; i++) {
          final double t = i / _previewMoves;
          final InkVector position =
              start + InkVector(140 * t + 30 * math.sin(t * 20), 90 * t);
          stopwatch
            ..reset()
            ..start();
          controller.updateSelectionGesture(1, position);
          stopwatch.stop();
          if (measured) {
            perMove.add(stopwatch);
          }
        }
        // Previews leave the document as it was.
        expect(identical(controller.strokes.first, before.first), isTrue);

        stopwatch
          ..reset()
          ..start();
        controller.endSelectionGesture(1);
        stopwatch.stop();
        if (measured) {
          commit.add(stopwatch);
        }
        expect(controller.selection!.count, selected);
        controller.dispose();
      }

      // ignore: avoid_print
      print(
        '\n${operation.name}\n'
        '  selection:        $selected strokes, '
        '${selected * _pointsPerStroke} points\n'
        '  gesture:          $_previewMoves moves at $_sampleRate Hz, '
        '$_runs runs\n'
        '  selection layer:  ${previews ~/ _runs} notifications per gesture\n'
        '  ink repaints:     ${inkRepaints ~/ _runs} per gesture\n'
        '  per preview move: ${perMove.describe()}\n'
        '  commit:           ${commit.describe()}\n'
        '  sample budget:    '
        '${Duration.microsecondsPerSecond ~/ _sampleRate} us',
      );

      // Paths are rebuilt once, at the commit, and never during a preview.
      expect(inkRepaints ~/ _runs, 1);
    });
  }
}
