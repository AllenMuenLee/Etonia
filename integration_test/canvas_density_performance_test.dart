// Frame times on a note far denser than handwriting usually gets: two pages
// of 10,000 strokes each, panned with two fingers, pinched from 0.5x to 4x,
// and erased back and forth in both eraser modes. Run it in profile mode on a
// physical tablet; emulator and debug numbers are not representative.
//
//   flutter build apk --profile \
//     --target=integration_test/canvas_density_performance_test.dart
//   adb install -r -t build/app/outputs/flutter-apk/app-profile.apk
//   adb logcat -c
//   adb shell am start -n com.etonia.app/.MainActivity
//   adb logcat -s flutter | grep DENSITY_RESULT
//
// Each scenario prints one `DENSITY_RESULT` line of JSON. It reports frame
// times rather than a timeline, so it needs no VM service, and works over
// wireless adb. Pointers are synthetic: this measures the engine under a
// steady load, not the digitizer, and says nothing about glass-to-photon
// latency, which only a high-speed camera can measure.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/ai/canvas_text_recognizer.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/ink_tile_cache.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/page/note_document.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/page/page_viewport.dart';
import 'package:integration_test/integration_test.dart';

const bool _zoomOnly = bool.fromEnvironment('DENSITY_ZOOM_ONLY');
const int _strokesPerPage = int.fromEnvironment(
  'DENSITY_STROKES',
  defaultValue: 10000,
);
const int _pointsPerStroke = int.fromEnvironment(
  'DENSITY_POINTS',
  defaultValue: 24,
);
const PageSetup _setup = PageSetup(background: PageBackground.lined);

class _NoopTextRecognizer implements CanvasTextRecognizer {
  const _NoopTextRecognizer();

  @override
  Future<String> recognize(HandwritingBatch batch) async => '';
}

/// [_strokesPerPage] short pressure-sensitive strokes, like tiny handwriting
/// filling all of a page of [size].
List<Stroke> _densePage(Size size) {
  final math.Random random = math.Random(7);
  final int columns = math
      .sqrt(_strokesPerPage * size.width / size.height)
      .ceil();
  final int rows = (_strokesPerPage / columns).ceil();
  final double cellWidth = size.width / columns;
  final double cellHeight = size.height / rows;
  const StrokeStyle style = StrokeStyle(ink: InkPalette.ink, width: 1.5);
  return <Stroke>[
    for (int i = 0; i < _strokesPerPage; i++)
      () {
        final double left = (i % columns) * cellWidth;
        final double top = (i ~/ columns) * cellHeight;
        final double phase = random.nextDouble() * 2 * math.pi;
        return Stroke.fromPoints(
          style: style,
          points: <InkVector>[
            for (int p = 0; p < _pointsPerStroke; p++)
              InkVector(
                left + cellWidth * 0.9 * p / _pointsPerStroke,
                top + cellHeight * (0.5 + 0.4 * math.sin(p / 3 + phase)),
              ),
          ],
          widths: <double>[
            for (int p = 0; p < _pointsPerStroke; p++)
              0.7 + 0.5 * math.sin(p / _pointsPerStroke * math.pi),
          ],
        );
      }(),
  ];
}

/// Collects the frames, and the pointer-event costs, of one scenario.
class _Recording {
  _Recording(this.name) {
    SchedulerBinding.instance.addTimingsCallback(_frames.addAll);
  }

  final String name;
  final Map<String, int> _tilesBefore = InkTileCache.renderingStats;
  final List<FrameTiming> _frames = <FrameTiming>[];
  final List<int> eventMicros = <int>[];

  Future<void> finish(
    WidgetTester tester, {
    Map<String, Object?>? extra,
  }) async {
    // Timings arrive in batches.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1500)),
    );
    SchedulerBinding.instance.removeTimingsCallback(_frames.addAll);
    double ms(Duration duration) => duration.inMicroseconds / 1000;
    Map<String, double> stats(List<double> values) {
      if (values.isEmpty) return const <String, double>{};
      final List<double> sorted = values.toList()..sort();
      double at(double p) => sorted[((sorted.length - 1) * p).round()];
      double round(double value) => (value * 100).round() / 100;
      return <String, double>{
        'mean': round(sorted.reduce((a, b) => a + b) / sorted.length),
        'p50': round(at(0.5)),
        'p90': round(at(0.9)),
        'p99': round(at(0.99)),
        'max': round(sorted.last),
      };
    }

    int over(double budget, double Function(FrameTiming) of) =>
        _frames.where((FrameTiming frame) => of(frame) > budget).length;
    final double refreshRate =
        PlatformDispatcher.instance.views.first.display.refreshRate;
    final double frameBudget = 1000 / (refreshRate > 0 ? refreshRate : 60);
    debugPrint(
      'DENSITY_RESULT ${jsonEncode(<String, Object?>{
        'scenario': name,
        'zoom_repaint_mode': InkTileCache.profileEveryZoomFrame ? 'per-frame' : 'cached-layer',
        'strokes_per_page': _strokesPerPage,
        'points_per_stroke': _pointsPerStroke,
        'frames': _frames.length,
        'display_refresh_hz': refreshRate,
        'frame_budget_ms': frameBudget,
        'build_over_display_budget': over(frameBudget, (f) => ms(f.buildDuration)),
        'raster_over_display_budget': over(frameBudget, (f) => ms(f.rasterDuration)),
        'build_ms': stats(<double>[for (final f in _frames) ms(f.buildDuration)]),
        'raster_ms': stats(<double>[for (final f in _frames) ms(f.rasterDuration)]),
        'total_ms': stats(<double>[for (final f in _frames) ms(f.totalSpan)]),
        'build_over_8_3': over(8.3, (f) => ms(f.buildDuration)),
        'raster_over_8_3': over(8.3, (f) => ms(f.rasterDuration)),
        'build_over_16_6': over(16.6, (f) => ms(f.buildDuration)),
        'raster_over_16_6': over(16.6, (f) => ms(f.rasterDuration)),
        'event_ms': stats(<double>[for (final int e in eventMicros) e / 1000]),
        ...InkTileCache.renderingStats,
        'tile_rasters_delta': InkTileCache.renderingStats['tile_rasters']! - _tilesBefore['tile_rasters']!,
        'tile_fallback_strokes_delta': InkTileCache.renderingStats['tile_fallback_strokes']! - _tilesBefore['tile_fallback_strokes']!,
        ...?extra,
      })}',
    );
  }
}

Future<NoteDocument> _pumpDocument(WidgetTester tester) async {
  final Size size = _setup.size.fixedSize!;
  final NoteDocument document = NoteDocument(
    pages: <NotePage>[
      for (int i = 0; i < 2; i++)
        NotePage(
          ink: InkController(strokes: _densePage(size)),
          setup: _setup,
        ),
    ],
  );
  addTearDown(document.dispose);
  await tester.pumpWidget(
    GreatnoteApp(
      home: EditorScreen(
        document: document,
        enableNativeInk: false,
        textRecognizer: const _NoopTextRecognizer(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return document;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // What the document does for one eraser move, with nothing else around it:
  // no pointer dispatch, painting, or listeners.
  if (!_zoomOnly) {
    for (final EraserMode mode in EraserMode.values) {
      testWidgets('eraser moves alone: ${mode.name}', (
        WidgetTester tester,
      ) async {
        final Size size = _setup.size.fixedSize!;
        final InkController ink = InkController(strokes: _densePage(size));
        addTearDown(ink.dispose);
        final _Recording recording = _Recording('eraser_alone_${mode.name}');
        InkVector position(int i) {
          final double t = i / 2000;
          return InkVector(
            size.width * (0.5 + 0.4 * math.sin(t * 16 * math.pi)),
            size.height * (0.2 + 0.6 * t),
          );
        }

        ink.startErase(
          pointer: 1,
          position: position(0),
          settings: EraserSettings(mode: mode, size: 24),
        );
        for (int i = 1; i <= 2000; i++) {
          final Stopwatch clock = Stopwatch()..start();
          ink.eraseTo(1, position(i));
          clock.stop();
          recording.eventMicros.add(clock.elapsedMicroseconds);
        }
        ink.endErase(1);
        await recording.finish(tester);
      });
    }
  }

  testWidgets('two-finger pan over a dense note', (WidgetTester tester) async {
    await _pumpDocument(tester);
    final Rect area = tester.getRect(find.byType(PageViewport));
    final Offset a = area.center + const Offset(-80, 0);
    final Offset b = area.center + const Offset(80, 0);
    final TestGesture first = await tester.createGesture(pointer: 1);
    final TestGesture second = await tester.createGesture(pointer: 2);
    await first.down(a);
    await second.down(b);
    await tester.pump();

    final _Recording recording = _Recording('pan');
    const int frames = 600;
    Offset last = Offset.zero;
    for (int i = 1; i <= frames; i++) {
      // Up and down, about one screen a second, like reading through a note.
      final Offset moved = Offset(
        0,
        -area.height * 0.45 * (1 - math.cos(i / frames * 6 * math.pi)),
      );
      final Stopwatch clock = Stopwatch()..start();
      await first.moveBy(moved - last);
      await second.moveBy(moved - last);
      clock.stop();
      recording.eventMicros.add(clock.elapsedMicroseconds);
      last = moved;
      await tester.pump();
    }
    await recording.finish(tester);
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
  }, skip: _zoomOnly);

  testWidgets('pinch from 0.5x to 4x over a dense note', (
    WidgetTester tester,
  ) async {
    await _pumpDocument(tester);
    final Rect area = tester.getRect(find.byType(PageViewport));
    final Offset center = area.center;
    final TestGesture first = await tester.createGesture(pointer: 1);
    final TestGesture second = await tester.createGesture(pointer: 2);
    const double spread = 90;
    await first.down(center - const Offset(spread, 0));
    await second.down(center + const Offset(spread, 0));
    await tester.pump();

    final _Recording recording = _Recording('pinch');
    const int frames = 600;
    double lastGap = spread;
    for (int i = 1; i <= frames; i++) {
      // Fingers between a sixth and four times as far apart as they began.
      final double phase = 0.5 - 0.5 * math.cos(i / frames * 4 * math.pi);
      final double gap = spread * (1 / 6 + phase * (4 - 1 / 6));
      final Stopwatch clock = Stopwatch()..start();
      await first.moveBy(Offset(lastGap - gap, 0));
      await second.moveBy(Offset(gap - lastGap, 0));
      clock.stop();
      recording.eventMicros.add(clock.elapsedMicroseconds);
      lastGap = gap;
      await tester.pump();
    }
    await recording.finish(tester);
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
  });

  if (!_zoomOnly) {
    for (final EraserMode mode in EraserMode.values) {
      testWidgets('erase back and forth on a dense page: ${mode.name}', (
        WidgetTester tester,
      ) async {
        final NoteDocument document = await _pumpDocument(tester);
        await tester.tap(find.byTooltip('Eraser'));
        await tester.pumpAndSettle();
        final ValueNotifier<EraserSettings> settings =
            tester
                    .widget<InkCanvas>(find.byType(InkCanvas).first)
                    .eraserSettings
                as ValueNotifier<EraserSettings>;
        settings.value = EraserSettings(mode: mode, size: 24);
        await tester.pumpAndSettle();
        final InkController ink = document.pages.first.ink;
        final int before = ink.strokes.length;
        final Rect canvas = tester.getRect(find.byType(InkCanvas).first);
        final Rect area = canvas.intersect(
          tester.getRect(find.byType(PageViewport)),
        );

        const int frames = 480;
        const int samplesPerFrame = 2;
        Offset position(int sample) {
          final double t = sample / (frames * samplesPerFrame);
          return Offset(
            area.left + area.width * (0.5 + 0.4 * math.sin(t * 16 * math.pi)),
            area.top + area.height * (0.2 + 0.6 * t),
          );
        }

        final _Recording recording = _Recording('erase_${mode.name}');
        final TestGesture gesture = await tester.startGesture(
          position(0),
          kind: PointerDeviceKind.stylus,
        );
        int sample = 0;
        for (int frame = 0; frame < frames; frame++) {
          for (int s = 0; s < samplesPerFrame; s++) {
            sample++;
            final Stopwatch clock = Stopwatch()..start();
            await gesture.moveTo(position(sample));
            clock.stop();
            recording.eventMicros.add(clock.elapsedMicroseconds);
          }
          await tester.pump();
        }
        await gesture.up();
        await tester.pump();
        await recording.finish(
          tester,
          extra: <String, Object?>{
            'strokes_before': before,
            'strokes_after': ink.strokes.length,
          },
        );
        expect(ink.strokes.length, isNot(before));
      });
    }
  }
}
