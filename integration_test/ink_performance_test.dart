// Frame-timing harness for the ink path: writing, erasing on a full page in
// each eraser mode, then lassoing much of a full page and moving, scaling,
// and rotating what was selected. Run it in profile mode on a physical
// tablet; emulator and debug numbers are not representative.
//
//   flutter drive --profile --no-dds \
//     --driver=test_driver/perf_driver.dart \
//     --target=integration_test/ink_performance_test.dart -d <device-id>
//
// One summary per scenario is written to build/, each as
// <name>.timeline_summary.json: ink_performance, eraser_area_performance,
// eraser_stroke_performance, selection_lasso_performance,
// selection_move_performance, selection_scale_performance, and
// selection_rotate_performance.
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/ai/canvas_text_recognizer.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_notation.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/pen_settings.dart';
import 'package:greatnote/features/editor/ink/selection_transform.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:integration_test/integration_test.dart';

/// Samples per second of a current high-rate stylus.
const int _sampleRate = 240;
const int _strokeCount = 6;
const int _samplesPerStroke = 4 * _sampleRate;

/// Several samples arrive per frame on a 60-120 Hz display.
const int _samplesPerFrame = 3;

const int _pageRows = 20;
const int _pageStrokesPerRow = 25;
const int _pagePointsPerStroke = 60;
const int _eraseSamples = 8 * _sampleRate;
const int _lassoSamples = 6 * _sampleRate;
const int _transformSamples = 6 * _sampleRate;

class _NoopTextRecognizer implements CanvasTextRecognizer {
  const _NoopTextRecognizer();

  @override
  Future<String> recognize(HandwritingBatch batch) async => '';
}

/// A page of [_pageRows] x [_pageStrokesPerRow] short, curly strokes, like
/// lines of handwriting, filling a canvas of [size].
List<Stroke> _page(Size size) {
  const StrokeStyle style = StrokeStyle(ink: InkPalette.ink, width: 3);
  final double cellWidth = size.width / _pageStrokesPerRow;
  final double rowHeight = size.height / _pageRows;
  return <Stroke>[
    for (int row = 0; row < _pageRows; row++)
      for (int column = 0; column < _pageStrokesPerRow; column++)
        Stroke.fromPoints(
          style: style,
          points: <InkVector>[
            for (int i = 0; i < _pagePointsPerStroke; i++)
              InkVector(
                column * cellWidth +
                    cellWidth * 0.8 * i / _pagePointsPerStroke +
                    4 * math.cos(i / 3 + column),
                (row + 0.5) * rowHeight +
                    rowHeight * 0.3 * math.sin(i / 4 + row),
              ),
          ],
        ),
  ];
}

/// A 57,344-point playback, close to the generated-ink limit of 60,000
/// points, with every trace active together to stress the animation layer.
List<GeneratedInkTrace> _nearLimitNotation(Size size) {
  const int traceCount = 448;
  const int pointsPerTrace = 128;
  final StrokeStyle style = StrokeStyle(
    ink: InkPalette.byId('blue')!,
    width: 1,
  );
  return <GeneratedInkTrace>[
    for (int trace = 0; trace < traceCount; trace++)
      GeneratedInkTrace(
        style: style,
        points: <InkVector>[
          for (int point = 0; point < pointsPerTrace; point++)
            InkVector(
              2 + (size.width - 4) * point / (pointsPerTrace - 1),
              2 +
                  (size.height - 4) * (trace + 0.5) / traceCount +
                  0.25 * math.sin(point / 3),
            ),
        ],
        timesMs: <double>[
          for (int point = 0; point < pointsPerTrace; point++)
            1600 * point / (pointsPerTrace - 1),
        ],
      ),
  ];
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('long high-rate strokes', (WidgetTester tester) async {
    final InkController controller = InkController();
    final ValueNotifier<PenSettings> penSettings = ValueNotifier<PenSettings>(
      PenSettings.defaults().copyWith(scribbleToErase: false),
    );
    addTearDown(controller.dispose);
    addTearDown(penSettings.dispose);
    await tester.pumpWidget(
      GreatnoteApp(
        home: EditorScreen(
          inkController: controller,
          enableNativeInk: false,
          penSettings: penSettings,
          textRecognizer: const _NoopTextRecognizer(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Rect canvas = tester.getRect(find.byType(InkCanvas));
    const Duration sampleInterval = Duration(
      microseconds: Duration.microsecondsPerSecond ~/ _sampleRate,
    );

    await binding.traceAction(() async {
      for (int stroke = 0; stroke < _strokeCount; stroke++) {
        Offset position(int i) {
          final double t = i / _samplesPerStroke;
          return Offset(
            canvas.left + canvas.width * (0.1 + 0.8 * t),
            canvas.top +
                canvas.height *
                    (0.15 + 0.12 * stroke + 0.04 * math.sin(t * 40)),
          );
        }

        final TestGesture gesture = await tester.startGesture(
          position(0),
          kind: PointerDeviceKind.stylus,
        );
        for (int i = 1; i <= _samplesPerStroke; i++) {
          await gesture.moveTo(position(i), timeStamp: sampleInterval * i);
          if (i % _samplesPerFrame == 0) {
            await tester.pump();
          }
        }
        await gesture.up(timeStamp: sampleInterval * (_samplesPerStroke + 1));
        await tester.pump();
      }
    }, reportKey: 'ink_timeline');

    expect(controller.strokes.length, _strokeCount);
  });

  for (final EraserMode mode in EraserMode.values) {
    testWidgets('long high-rate ${mode.name} erase on a full page', (
      WidgetTester tester,
    ) async {
      // The canvas size is only known once the editor is laid out.
      await tester.pumpWidget(
        const GreatnoteApp(home: EditorScreen(enableNativeInk: false)),
      );
      await tester.pumpAndSettle();
      final Size size = tester.getSize(find.byType(InkCanvas));
      final List<Stroke> page = _page(size);
      final InkController controller = InkController(strokes: page);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        GreatnoteApp(
          home: EditorScreen(inkController: controller, enableNativeInk: false),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Eraser'));
      await tester.pumpAndSettle();
      if (mode == EraserMode.stroke) {
        await tester.tap(find.byTooltip('Eraser'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(EraserMode.stroke.label));
        await tester.pumpAndSettle();
        // Dismiss the options; the tap is consumed and erases nothing.
        await tester.tapAt(tester.getRect(find.byType(InkCanvas)).center);
        await tester.pumpAndSettle();
      }

      final Rect canvas = tester.getRect(find.byType(InkCanvas));
      const Duration sampleInterval = Duration(
        microseconds: Duration.microsecondsPerSecond ~/ _sampleRate,
      );
      // A scribble that works its way down the whole page.
      Offset position(int i) {
        final double t = i / _eraseSamples;
        return Offset(
          canvas.left +
              canvas.width * (0.5 + 0.45 * math.sin(t * 12 * math.pi)),
          canvas.top + canvas.height * (0.05 + 0.9 * t),
        );
      }

      await binding.traceAction(() async {
        final TestGesture gesture = await tester.startGesture(
          position(0),
          kind: PointerDeviceKind.stylus,
        );
        for (int i = 1; i <= _eraseSamples; i++) {
          await gesture.moveTo(position(i), timeStamp: sampleInterval * i);
          if (i % _samplesPerFrame == 0) {
            await tester.pump();
          }
        }
        await gesture.up(timeStamp: sampleInterval * (_eraseSamples + 1));
        await tester.pump();
      }, reportKey: 'eraser_${mode.name}_timeline');

      expect(page.length, _pageRows * _pageStrokesPerRow);
      expect(controller.activeErase, isNull);
      if (mode == EraserMode.stroke) {
        expect(controller.strokes.length, lessThan(page.length));
      } else {
        expect(controller.strokes.length, greaterThan(page.length));
      }
    });
  }

  testWidgets('lasso, then long move, scale, and rotate previews', (
    WidgetTester tester,
  ) async {
    // The canvas size is only known once the editor is laid out.
    await tester.pumpWidget(
      const GreatnoteApp(home: EditorScreen(enableNativeInk: false)),
    );
    await tester.pumpAndSettle();
    final Size size = tester.getSize(find.byType(InkCanvas));
    final List<Stroke> page = _page(size);
    final InkController controller = InkController(strokes: page);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      GreatnoteApp(
        home: EditorScreen(inkController: controller, enableNativeInk: false),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Select'));
    await tester.pumpAndSettle();

    final Rect canvas = tester.getRect(find.byType(InkCanvas));
    const Duration sampleInterval = Duration(
      microseconds: Duration.microsecondsPerSecond ~/ _sampleRate,
    );
    int inkRepaints = 0;
    controller.completedStrokesListenable.addListener(() => inkRepaints++);

    /// Drags a stylus along [position], pumping a frame every few samples.
    Future<void> drag(Offset Function(double t) position, int samples) async {
      final TestGesture gesture = await tester.startGesture(
        position(0),
        kind: PointerDeviceKind.stylus,
      );
      for (int i = 1; i <= samples; i++) {
        await gesture.moveTo(
          position(i / samples),
          timeStamp: sampleInterval * i,
        );
        if (i % _samplesPerFrame == 0) {
          await tester.pump();
        }
      }
      await gesture.up(timeStamp: sampleInterval * (samples + 1));
      await tester.pump();
    }

    // A loop over the middle of the page, a quarter of it across.
    await binding.traceAction(() async {
      await drag((double t) {
        final double turn = t * 2 * math.pi;
        return canvas.center +
            Offset(
              canvas.width * 0.25 * math.cos(turn),
              canvas.height * 0.25 * math.sin(turn),
            );
      }, _lassoSamples);
    }, reportKey: 'selection_lasso_timeline');

    final int selected = controller.selection!.count;
    expect(selected, greaterThan(_pageRows * _pageStrokesPerRow ~/ 10));
    expect(selected, lessThan(page.length));
    // Once, as the selected strokes changed layers.
    expect(inkRepaints, 1);

    /// A canvas position in global coordinates.
    Offset global(InkVector point) => canvas.topLeft + Offset(point.x, point.y);

    for (final SelectionOperation operation in SelectionOperation.values) {
      final SelectionFrame frame = controller.selection!.frame;
      final Stroke before =
          controller.strokes[controller.selection!.indices[0]];
      inkRepaints = 0;

      await binding.traceAction(() async {
        switch (operation) {
          case SelectionOperation.move:
            // Round a small circle and back to the start.
            await drag((double t) {
              final double turn = t * 2 * math.pi;
              return global(frame.center) +
                  Offset(60 * (1 - math.cos(turn)), 60 * math.sin(turn));
            }, _transformSamples);
          case SelectionOperation.scale:
            // The bottom-right corner, in towards its opposite, out past
            // where it began, and in again.
            final Offset grabbed = global(frame.corners[2]);
            final Offset fixed = global(frame.corners[0]);
            await drag((double t) {
              final double factor = 1 - 0.4 * math.sin(t * 2.5 * math.pi);
              return fixed + (grabbed - fixed) * factor;
            }, _transformSamples);
          case SelectionOperation.rotate:
            // A third of a turn from the rotation handle.
            final InkVector handle = frame.rotationHandle(
              controller.selectionConfig.rotationHandleOffset,
            );
            await drag((double t) {
              return global(
                InkTransform.rotation(
                  frame.center,
                  t * 2 * math.pi / 3,
                ).apply(handle),
              );
            }, _transformSamples);
        }
      }, reportKey: 'selection_${operation.name}_timeline');

      // Every sample moved the preview; the ink layer was repainted, and
      // the paths rebuilt, once at the end if the selection ended up
      // somewhere new, and not at all if it came back.
      expect(controller.activeTransform, isNull);
      expect(controller.selection!.count, selected);
      expect(inkRepaints, lessThanOrEqualTo(1));
      final Stroke after = controller.strokes[controller.selection!.indices[0]];
      expect(identical(after, before), inkRepaints == 0);
    }
  });

  testWidgets('near-limit AI notation looping and forced finish', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const GreatnoteApp(home: EditorScreen(enableNativeInk: false)),
    );
    await tester.pumpAndSettle();
    final Size size = tester.getSize(find.byType(InkCanvas));
    final List<Stroke> page = _page(size);
    final List<GeneratedInkTrace> notation = _nearLimitNotation(size);
    final InkController controller = InkController(strokes: page);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      GreatnoteApp(
        home: EditorScreen(inkController: controller, enableNativeInk: false),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      controller.addAiNotation(
        traces: notation,
        expectedRevision: 0,
        surfaceSize: size,
        playbackDuration: const Duration(milliseconds: 1800),
      ),
      AddNotationResult.addedWithPlayback,
    );
    final playback = controller.notationPlayback!;
    int documentInvalidations = 0;
    int ownershipInvalidations = 0;
    int animationFrames = 0;
    controller.completedStrokesListenable.addListener(
      () => documentInvalidations++,
    );
    controller.notationPlaybackListenable.addListener(
      () => ownershipInvalidations++,
    );
    controller.notationFrameListenable.addListener(() => animationFrames++);

    // Keep the loop rollover out of the ordinary-frame timeline so build and
    // raster costs for the dedicated animation layer are reported on their
    // own.
    await binding.traceAction(() async {
      for (int frame = 0; frame < 90; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }, reportKey: 'ai_notation_animation_timeline');
    final int peakCachedMetrics = playback.peakCachedPathMetricCount;
    expect(controller.notationPlayback, same(playback));
    expect(documentInvalidations, 0);
    expect(ownershipInvalidations, 0);
    expect(playback.cachedPathMetricCount, lessThanOrEqualTo(notation.length));

    await binding.traceAction(() async {
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
    }, reportKey: 'ai_notation_loop_rollover_timeline');
    expect(controller.notationPlayback, same(playback));
    expect(documentInvalidations, 0);
    expect(ownershipInvalidations, 0);

    await binding.traceAction(() async {
      controller.finishNotationPlayback();
      await tester.pump();
    }, reportKey: 'ai_notation_forced_finish_timeline');
    expect(controller.notationPlayback, isNull);
    expect(documentInvalidations, 0);
    expect(ownershipInvalidations, 1);

    binding.reportData ??= <String, dynamic>{};
    binding.reportData!['ai_notation_metrics'] = <String, Object>{
      'existing_strokes': page.length,
      'existing_points': _pageRows * _pageStrokesPerRow * _pagePointsPerStroke,
      'animated_strokes': notation.length,
      'animated_points': notation.fold<int>(
        0,
        (int total, GeneratedInkTrace trace) => total + trace.points.length,
      ),
      'ordinary_animation_ticks': animationFrames,
      'completed_layer_document_invalidations_during_ticks': 0,
      'completed_layer_ownership_invalidations_during_ticks': 0,
      'peak_cached_path_metrics': peakCachedMetrics,
      'cached_path_metrics_after_forced_finish': playback.cachedPathMetricCount,
      'temporary_allocation_bound':
          'At most one cached PathMetric per animated trace and one extracted '
          'partial Path per active trace per frame; caches are released as '
          'traces complete.',
    };
  });
}
