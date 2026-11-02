import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/ink_painter.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/ink/stroke_spatial_index.dart';
import 'package:greatnote/features/editor/ink/ink_selection.dart';
import 'package:greatnote/features/editor/ink/selection_geometry.dart';

const StrokeStyle _style = StrokeStyle(ink: InkPalette.ink, width: 4);

Stroke _line(double x, double y) => Stroke.fromPoints(
  style: _style,
  points: <InkVector>[InkVector(x, y), InkVector(x + 12, y)],
);

double _metricLength(ui.Path path) => path.computeMetrics().fold<double>(
  0,
  (double total, ui.PathMetric metric) => total + metric.length,
);

void main() {
  test(
    'native wet ink suppresses the duplicate Flutter active stroke',
    () async {
      final InkController controller = InkController();
      final ValueNotifier<bool> nativePreview = ValueNotifier<bool>(false);
      controller.startStroke(
        pointer: 1,
        sample: const RawInkSample(
          position: InkVector(20, 20),
          timestamp: Duration.zero,
        ),
        style: _style,
      );

      Future<int> centerAlpha() async {
        final ui.PictureRecorder recorder = ui.PictureRecorder();
        ActiveStrokePainter(
          controller: controller,
          brightness: Brightness.light,
          inkHidden: nativePreview,
        ).paint(Canvas(recorder), const Size(40, 40));
        final ui.Image image = await recorder.endRecording().toImage(40, 40);
        final ByteData data = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        image.dispose();
        return data.getUint8((20 * 40 + 20) * 4 + 3);
      }

      expect(await centerAlpha(), greaterThan(0));
      nativePreview.value = true;
      expect(await centerAlpha(), 0);

      nativePreview.dispose();
      controller.dispose();
    },
  );

  test(
    'active dynamic outlines grow at every sample and finish canonically',
    () {
      RawInkSample sample(int i) => RawInkSample(
        position: InkVector(i * 3.0, (i % 7) * 2.0),
        timestamp: Duration(milliseconds: i * 8),
        pressure: 0.2 + (i % 6) * 0.12,
      );
      final ActiveStroke active = ActiveStroke(
        style: _style,
        first: sample(0),
        dynamics: const StrokeDynamics(taper: 0.7, pressure: 0.8),
      );
      for (int i = 1; i < 120; i++) {
        active.add(sample(i));
        expect(active.outline, isNotNull);
        expect(active.outline!.getBounds().isEmpty, isFalse);
      }
      final Stroke finished = active.finish();
      final ui.Path canonical = buildInkOutline(
        finished.points,
        finished.widths!,
        finished.style.width,
      );
      expect(finished.outline!.getBounds(), canonical.getBounds());
      expect(
        _metricLength(finished.outline!),
        closeTo(_metricLength(canonical), 1e-6),
      );
    },
  );

  test('spatial index returns unique candidates in document order', () {
    final List<Stroke> strokes = <Stroke>[
      for (int i = 0; i < 1200; i++) _line((i % 40) * 20.0, (i ~/ 40) * 20.0),
    ];
    final StrokeSpatialIndex index = StrokeSpatialIndex(strokes, cellSize: 32);
    final List<int> candidates = index.query(
      const Rect.fromLTWH(390, 190, 35, 35),
    );
    expect(candidates, orderedEquals(candidates.toSet().toList()..sort()));
    expect(candidates.length, lessThan(40));
    expect(
      candidates.where(
        (int i) =>
            strokes[i].bounds.overlaps(const Rect.fromLTWH(390, 190, 35, 35)),
      ),
      isNotEmpty,
    );
  });

  test('indexed lasso and erase preserve 1200-stroke document semantics', () {
    final List<Stroke> strokes = <Stroke>[
      for (int i = 0; i < 1200; i++) _line((i % 40) * 20.0, (i ~/ 40) * 20.0),
    ];
    const List<InkVector> outline = <InkVector>[
      InkVector(390, 190),
      InkVector(425, 190),
      InkVector(425, 225),
      InkVector(390, 225),
    ];
    final List<int> reference = selectStrokes(
      strokes,
      LassoRegion(outline),
    ).indices;
    final InkController controller = InkController(strokes: strokes);
    expect(controller.selectWithOutline(outline), isTrue);
    expect(controller.selection!.indices, reference);
    controller.clearSelection();

    const InkVector hit = InkVector(405, 205);
    expect(
      controller.startErase(
        pointer: 9,
        position: hit,
        settings: const EraserSettings(mode: EraserMode.stroke, size: 24),
      ),
      isTrue,
    );
    controller.endErase(9);
    final List<Stroke> expected = <Stroke>[
      for (int i = 0; i < strokes.length; i++)
        if (i != 420) strokes[i],
    ];
    expect(controller.strokes, orderedEquals(expected));
    expect(controller.undo(), isTrue);
    expect(controller.strokes, orderedEquals(strokes));
    controller.dispose();
  });

  test('indexed area erase cuts only the strokes the eraser sweeps', () {
    final List<Stroke> strokes = <Stroke>[
      for (int i = 0; i < 1200; i++) _line((i % 40) * 20.0, (i ~/ 40) * 20.0),
    ];
    final InkController controller = InkController(strokes: strokes);
    const InkVector from = InkVector(300, 100);
    const InkVector to = InkVector(300, 300);
    const double radius = 4;
    expect(
      controller.startErase(
        pointer: 3,
        position: from,
        settings: const EraserSettings(mode: EraserMode.area, size: radius * 2),
      ),
      isTrue,
    );
    controller.eraseTo(3, to);
    controller.endErase(3);
    final Rect sweep = Rect.fromLTRB(
      from.x - radius,
      from.y - radius,
      to.x + radius,
      to.y + radius,
    );
    // Every stroke out of the eraser's reach survives as the same object,
    // in its original order; the swept column is cut into pieces.
    final List<Stroke> untouched = <Stroke>[
      for (final Stroke stroke in strokes)
        if (!stroke.bounds.overlaps(sweep)) stroke,
    ];
    expect(
      controller.strokes.where(strokes.contains),
      orderedEquals(untouched),
    );
    expect(untouched.length, lessThan(strokes.length));
    expect(controller.undo(), isTrue);
    expect(controller.strokes, orderedEquals(strokes));
    controller.dispose();
  });

  test('the index follows strokes committed in place', () {
    final InkController controller = InkController(
      strokes: <Stroke>[for (int i = 0; i < 300; i++) _line(i * 2.0, 0)],
    );
    // Builds the index over the first 300 strokes.
    expect(
      controller.selectWithOutline(const <InkVector>[
        InkVector(0, -10),
        InkVector(40, -10),
        InkVector(40, 10),
        InkVector(0, 10),
      ]),
      isTrue,
    );
    controller.clearSelection();
    RawInkSample at(double x, int ms) => RawInkSample(
      position: InkVector(x, 900),
      timestamp: Duration(milliseconds: ms),
    );
    expect(
      controller.startStroke(pointer: 1, sample: at(900, 0), style: _style),
      isTrue,
    );
    controller.addSamples(1, <RawInkSample>[at(920, 8), at(940, 16)]);
    controller.endStroke(1);
    expect(controller.strokes, hasLength(301));
    expect(
      controller.startErase(
        pointer: 2,
        position: const InkVector(920, 900),
        settings: const EraserSettings(mode: EraserMode.stroke, size: 24),
      ),
      isTrue,
    );
    controller.endErase(2);
    expect(controller.strokes, hasLength(300));
    controller.dispose();
  });

  test('a degenerate query area still finds strokes', () {
    final StrokeSpatialIndex index = StrokeSpatialIndex(<Stroke>[
      _line(0, 0),
      _line(500, 500),
    ]);
    expect(index.query(const Rect.fromLTRB(6, -20, 6, 20)), <int>[0]);
  });

  testWidgets('completed painter skips strokes outside the visible page', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final InkController controller = InkController(
        strokes: <Stroke>[_line(5, 10), _line(75, 80)],
      );
      final ValueNotifier<Rect> visible = ValueNotifier<Rect>(
        const Rect.fromLTWH(0, 0, 30, 30),
      );
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final CompletedStrokesPainter painter = CompletedStrokesPainter(
        controller: controller,
        brightness: Brightness.light,
        visible: visible,
      );
      painter.paint(ui.Canvas(recorder), const Size(100, 100));
      final ui.Picture picture = recorder.endRecording();
      final ui.Image image = await picture.toImage(100, 100);
      final ByteData rgba = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      int alphaAt(int x, int y) => rgba.getUint8((y * 100 + x) * 4 + 3);
      expect(alphaAt(10, 10), greaterThan(0));
      expect(alphaAt(80, 80), 0);
      image.dispose();
      picture.dispose();
      visible.dispose();
      controller.dispose();
    });
  });
}
