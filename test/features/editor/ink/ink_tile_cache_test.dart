import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_painter.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/ink_tile_cache.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

const Size _page = Size(400, 300);

/// More than enough points for tiles, over the whole of [_page], many crossing
/// where tiles meet, in pen and highlighter, of even and varying width.
List<Stroke> _ink() {
  final math.Random random = math.Random(5);
  return <Stroke>[
    for (int i = 0; i < 400; i++)
      () {
        final double x = random.nextDouble() * _page.width;
        final double y = random.nextDouble() * _page.height;
        final bool highlighter = i % 11 == 0;
        return Stroke.fromPoints(
          style: StrokeStyle(
            ink: InkPalette.ink,
            width: 2.5,
            writing: highlighter ? WritingStyle.highlighter : WritingStyle.pen,
            opacity: highlighter ? 0.35 : 1,
          ),
          points: <InkVector>[
            for (int p = 0; p < 40; p++)
              InkVector(x + p * 3.0, y + 8 * math.sin(p / 3 + i)),
          ],
          widths: i.isEven
              ? <double>[for (int p = 0; p < 40; p++) 0.6 + (p % 5) * 0.2]
              : null,
        );
      }(),
  ];
}

class _Layer {
  _Layer(this.controller, {this.scale = 1, InkTileScheduler? scheduler})
    : tiles = InkTileCache(
        scheduler:
            scheduler ?? InkTileScheduler(scheduleWork: scheduleMicrotask),
      );

  final InkController controller;
  double scale;
  double pixelRatio = 1;
  final InkTileCache tiles;
  final ValueNotifier<bool> zooming = ValueNotifier<bool>(false);

  CompletedStrokesPainter painter({required bool tiled}) {
    return CompletedStrokesPainter(
      controller: controller,
      brightness: Brightness.light,
      visible: ValueNotifier<Rect>(Offset.zero & _page),
      tiles: tiled ? tiles : null,
      scale: ValueNotifier<double>(scale),
      pixelRatio: pixelRatio,
      zooming: zooming,
    );
  }

  /// RGBA pixels of the page, painted the way the framework would: in page
  /// units, under the scale from there to device pixels. On white, as the
  /// paper is.
  Future<Uint8List> pixels({
    required bool tiled,
    double? drawnAt,
    bool settle = true,
    double? rasterScale,
  }) async {
    if (tiled && settle) {
      for (int pass = 0; pass < 3; pass++) {
        final ui.PictureRecorder warmup = ui.PictureRecorder();
        painter(tiled: true).paint(Canvas(warmup), _page);
        warmup.endRecording().dispose();
        await tiles.whenIdle;
      }
    }
    final double scale = drawnAt ?? this.scale * pixelRatio;
    final double resolution = rasterScale ?? scale;
    final int width = (_page.width * resolution).ceil();
    final int height = (_page.height * resolution).ceil();
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    canvas
      ..drawColor(const Color(0xFFFFFFFF), BlendMode.src)
      ..scale(resolution);
    painter(tiled: tiled).paint(canvas, _page);
    final ui.Picture picture = recorder.endRecording();
    ui.Image image = await picture.toImage(width, height);
    picture.dispose();
    if (resolution != scale) {
      final ui.PictureRecorder resized = ui.PictureRecorder();
      Canvas(resized)
        ..drawColor(const Color(0xFFFFFFFF), BlendMode.src)
        ..drawImageRect(
          image,
          Rect.fromLTWH(
            0,
            0,
            _page.width * resolution,
            _page.height * resolution,
          ),
          Rect.fromLTWH(0, 0, _page.width * scale, _page.height * scale),
          Paint()
            ..filterQuality = FilterQuality.low
            ..isAntiAlias = false,
        );
      final ui.Picture scaled = resized.endRecording();
      final ui.Image result = await scaled.toImage(
        (_page.width * scale).ceil(),
        (_page.height * scale).ceil(),
      );
      scaled.dispose();
      image.dispose();
      image = result;
    }
    final ByteData data = (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!;
    image.dispose();
    return data.buffer.asUint8List();
  }

  void dispose() {
    tiles.dispose();
    zooming.dispose();
  }
}

/// The largest difference of any channel of any pixel, and the share of the
/// pixels that differ by more than a rounding error.
(int, double) _difference(Uint8List a, Uint8List b, {int? width}) {
  expect(a.length, b.length);
  int largest = 0;
  int differing = 0;
  for (int i = 0; i < a.length; i += 4) {
    if (width != null) {
      final int pixel = i ~/ 4;
      final int height = a.length ~/ 4 ~/ width;
      if (pixel % width == 0 ||
          pixel % width == width - 1 ||
          pixel ~/ width == 0 ||
          pixel ~/ width == height - 1) {
        continue;
      }
    }
    int here = 0;
    for (int c = 0; c < 4; c++) {
      here = math.max(here, (a[i + c] - b[i + c]).abs());
    }
    largest = math.max(largest, here);
    if (here > 2) differing++;
  }
  return (largest, differing / (a.length / 4));
}

void _requestTiles(
  InkTileCache tiles,
  InkController controller, {
  double scale = 1,
  Rect area = const Rect.fromLTWH(0, 0, 400, 300),
  bool zooming = false,
  VoidCallback? onStroke,
}) {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  tiles.paint(
    Canvas(recorder),
    area: area,
    pixelsPerUnit: scale,
    brightness: Brightness.light,
    holdScale: zooming,
    pageBounds: const Rect.fromLTWH(0, 0, 1200, 1200),
    strokes: controller.strokes,
    index: controller.strokeIndex,
    include: (_, _) => true,
    includesAll: true,
    paintStroke: (Canvas canvas, Stroke stroke) {
      onStroke?.call();
      paintInkStroke(
        canvas,
        color: stroke.style.resolve(Brightness.light),
        width: stroke.style.width,
        path: stroke.path,
        origin: stroke.points.first,
        isDot: stroke.isDot,
        outline: stroke.outline,
      );
    },
  );
  recorder.endRecording().dispose();
}

class _CountingInkPainter extends CompletedStrokesPainter {
  _CountingInkPainter(
    this.onPaint, {
    required super.controller,
    required super.brightness,
    super.visible,
    super.tiles,
    super.scale,
    super.zooming,
  });
  final VoidCallback onPaint;
  @override
  void paint(Canvas canvas, Size size) {
    onPaint();
    super.paint(canvas, size);
  }
}

void main() {
  late InkController controller;
  late _Layer layer;

  setUp(() {
    controller = InkController(strokes: _ink());
    layer = _Layer(controller);
  });

  tearDown(() {
    layer.dispose();
    controller.dispose();
  });

  Future<void> expectSameAsPainting(String reason) async {
    final (int largest, double share) = _difference(
      await layer.pixels(tiled: true),
      await layer.pixels(tiled: false, rasterScale: layer.tiles.scale),
      width: (_page.width * layer.scale * layer.pixelRatio).ceil(),
    );
    // The rasterizer's antialiasing depends a little on the size of the
    // surface it draws on, which is why this is not exact: painting directly
    // onto surfaces of two sizes differs by as much. A stroke that went
    // missing or moved would be off by far more, and over far more pixels.
    expect(largest, lessThan(128), reason: reason);
    expect(share, lessThan(0.01), reason: reason);
  }

  testWidgets('fractional zoom transforms reuse the recorded ink layer', (
    WidgetTester tester,
  ) async {
    final List<VoidCallback> work = <VoidCallback>[];
    final InkTileCache tiles = InkTileCache(
      scheduler: InkTileScheduler(scheduleWork: work.add),
    );
    final ValueNotifier<Rect> visible = ValueNotifier<Rect>(
      Offset.zero & _page,
    );
    final ValueNotifier<double> scale = ValueNotifier<double>(1.2);
    final ValueNotifier<bool> zooming = ValueNotifier<bool>(true);
    addTearDown(tiles.dispose);
    addTearDown(visible.dispose);
    addTearDown(scale.dispose);
    addTearDown(zooming.dispose);
    int paints = 0;
    await tester.pumpWidget(
      Center(
        child: ValueListenableBuilder<double>(
          valueListenable: scale,
          builder: (context, value, child) =>
              Transform.scale(scale: value, child: child),
          child: RepaintBoundary(
            child: SizedBox.fromSize(
              size: _page,
              child: CustomPaint(
                willChange: true,
                painter: _CountingInkPainter(
                  () => paints++,
                  controller: controller,
                  brightness: Brightness.light,
                  visible: visible,
                  tiles: tiles,
                  scale: scale,
                  zooming: zooming,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final int initial = paints;
    for (final double value in <double>[1.3, 1.4, 1.7, 1.9]) {
      scale.value = value;
      await tester.pump();
      expect(
        paints,
        initial,
        reason: 'matrix change reuses the existing layer',
      );
    }
    scale.value = 2.2;
    await tester.pump();
    expect(paints, initial + 1, reason: 'a new level requests new detail');
    zooming.value = false;
    await tester.pump();
    expect(paints, initial + 2, reason: 'release resumes sharper rendering');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('tiles look the same as painting the ink', () async {
    for (final (double scale, double ratio) in const <(double, double)>[
      (1, 1),
      (1, 2),
      (1.37, 2.75),
      (0.5, 3),
    ]) {
      layer
        ..scale = scale
        ..pixelRatio = ratio;
      await expectSameAsPainting('at $scale x $ratio');
    }
  });

  test('a light page is not worth textures', () async {
    final InkController light = InkController(
      strokes: _ink().take(10).toList(),
    );
    addTearDown(light.dispose);
    final _Layer page = _Layer(light);
    addTearDown(page.dispose);
    await page.pixels(tiled: true);
    expect(page.tiles.imageCount, 0);
    expect(page.tiles.rasterized, 0);
  });

  test('painting again takes no new pictures', () async {
    await layer.pixels(tiled: true);
    final int taken = layer.tiles.rasterized;
    expect(taken, greaterThan(0));
    await layer.pixels(tiled: true);
    expect(layer.tiles.rasterized, taken);
  });

  test('an erase takes again only the tiles it touched', () async {
    layer.pixelRatio = 3;
    await layer.pixels(tiled: true);
    final int taken = layer.tiles.rasterized;
    controller.startErase(
      pointer: 1,
      position: const InkVector(100, 100),
      settings: const EraserSettings(mode: EraserMode.area, size: 10),
    );
    controller.eraseTo(1, const InkVector(103, 100));
    controller.endErase(1);
    await layer.pixels(tiled: true);
    final int again = layer.tiles.rasterized - taken;
    expect(again, greaterThan(0));
    expect(again, lessThan(taken));
    await expectSameAsPainting('after the erase');
  });

  test('undo, selection, and hiding all show in the tiles', () async {
    await layer.pixels(tiled: true);
    controller.startErase(
      pointer: 1,
      position: const InkVector(0, 150),
      settings: const EraserSettings(mode: EraserMode.stroke, size: 10),
    );
    controller.eraseTo(1, const InkVector(400, 150));
    controller.endErase(1);
    await expectSameAsPainting('after an erase');
    controller.undo();
    await expectSameAsPainting('after undo');
    controller.selectWithOutline(const <InkVector>[
      InkVector(50, 50),
      InkVector(200, 50),
      InkVector(200, 200),
      InkVector(50, 200),
    ]);
    expect(controller.selection, isNotNull);
    await expectSameAsPainting('with a selection');
    controller.clearSelection();
    await expectSameAsPainting('selection cleared');
    final List<Stroke> some = controller.strokes.take(100).toList();
    controller.setStrokesHidden(some, true);
    await expectSameAsPainting('with strokes hidden');
    controller.setStrokesHidden(some, false);
    await expectSameAsPainting('hidden strokes shown');
  });

  test(
    'zoom defers sharper levels until release and retains older levels',
    () async {
      await layer.pixels(tiled: true);
      final int taken = layer.tiles.rasterized;
      final int images = layer.tiles.imageCount;
      layer.zooming.value = true;
      layer.scale = 1.8;
      await layer.pixels(tiled: true);
      expect(layer.tiles.imageCount, images);
      expect(
        layer.tiles.rasterized,
        taken,
        reason: 'no competing detail work during pinch',
      );
      layer.scale = 1.9;
      await layer.pixels(tiled: true);
      expect(layer.tiles.rasterized, taken);
      layer.zooming.value = false;
      await layer.pixels(tiled: true);
      expect(layer.tiles.scale, 2);
      expect(layer.tiles.rasterized, greaterThan(taken));
      expect(layer.tiles.imageCount, greaterThan(images));
      final int detailed = layer.tiles.rasterized;
      layer.scale = 1;
      await layer.pixels(tiled: true);
      expect(
        layer.tiles.rasterized,
        detailed,
        reason: 'previous level retained',
      );
    },
  );

  test(
    'the next finer level is made behind the sharp one, never in a zoom',
    () async {
      layer.zooming.value = true;
      await layer.pixels(tiled: true);
      final int inZoom = layer.tiles.imageCount;
      expect(inZoom, greaterThan(0));

      layer.zooming.value = false;
      await layer.pixels(tiled: true);
      // The sharp level of each tile on show, and the one finer than it, so a
      // pinch in finds sharper tiles ready.
      expect(layer.tiles.imageCount, inZoom * 2);

      // And no further: the finer level's own finer level waits for a zoom
      // that reaches it.
      await layer.pixels(tiled: true);
      expect(layer.tiles.imageCount, inZoom * 2);
    },
  );

  test(
    'cold zoom shows vectors while images are queued asynchronously',
    () async {
      layer.zooming.value = true;
      layer.scale = 1.8;
      final Uint8List during = await layer.pixels(tiled: true, settle: false);
      final (int largest, double share) = _difference(
        during,
        await layer.pixels(tiled: false),
      );
      expect(largest, lessThan(128));
      expect(share, lessThan(0.01));
      await layer.pixels(tiled: true);
      expect(layer.tiles.imageCount, greaterThan(0));
    },
  );

  testWidgets(
    'settling repaints tiles even without a scale or document change',
    (WidgetTester tester) async {
      final ValueNotifier<Rect> visible = ValueNotifier<Rect>(
        Offset.zero & _page,
      );
      final ValueNotifier<double> scale = ValueNotifier<double>(1.8);
      addTearDown(visible.dispose);
      addTearDown(scale.dispose);
      layer.zooming.value = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox.fromSize(
              size: _page,
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: CompletedStrokesPainter(
                    controller: controller,
                    brightness: Brightness.light,
                    visible: visible,
                    tiles: layer.tiles,
                    scale: scale,
                    zooming: layer.zooming,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() => layer.tiles.whenIdle);
      await tester.pump();
      expect(layer.tiles.rasterized, greaterThan(0));
      layer.zooming.value = false;
      await tester.pump();
      await tester.runAsync(() => layer.tiles.whenIdle);
      await tester.pump();
      expect(layer.tiles.scale, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('edits during zoom invalidate affected images immediately', () async {
    await layer.pixels(tiled: true);
    layer.zooming.value = true;
    controller.startErase(
      pointer: 1,
      position: const InkVector(0, 150),
      settings: const EraserSettings(mode: EraserMode.stroke, size: 10),
    );
    controller.eraseTo(1, const InkVector(400, 150));
    controller.endErase(1);
    await expectSameAsPainting('edited during zoom');
  });

  test('all pages and levels share a hard GPU memory budget', () async {
    final List<_Layer> pages = <_Layer>[];
    final List<InkController> controllers = <InkController>[];
    addTearDown(() {
      for (final _Layer page in pages) {
        page.dispose();
      }
      for (final InkController ink in controllers) {
        ink.dispose();
      }
    });
    for (int i = 0; i < 12; i++) {
      final InkController ink = InkController(strokes: _ink());
      controllers.add(ink);
      // Each page, at this scale, needs a good part of the limit.
      final _Layer page = _Layer(ink, scale: 4);
      pages.add(page);
      await page.pixels(tiled: true);
      final int inUse = page.tiles.imageCount;
      expect(inUse, greaterThan(0));
      expect(InkTileCache.totalBytes, lessThanOrEqualTo(InkTileCache.maxBytes));
    }
    expect(
      pages.first.tiles.imageCount,
      greaterThan(0),
      reason: 'coarse previews survive detail-cache pressure',
    );
  });

  test(
    'raster work is deferred and recording is split into bounded slices',
    () async {
      final InkTileScheduler scheduler = InkTileScheduler(
        scheduleWork: scheduleMicrotask,
      );
      final InkTileCache tiles = InkTileCache(scheduler: scheduler);
      addTearDown(tiles.dispose);
      _requestTiles(tiles, controller);
      expect(scheduler.slices, 0, reason: 'no recording work inside paint');
      expect(tiles.rasterized, 0, reason: 'no synchronous image creation');
      expect(scheduler.pendingJobs, greaterThan(0));
      await tiles.whenIdle;
      expect(scheduler.slices, greaterThan(1));
      expect(
        scheduler.largestSlice,
        inInclusiveRange(1, InkTileScheduler.maxStrokesPerSlice),
      );
      expect(tiles.imageCount, greaterThan(0));
    },
  );

  test(
    'warm zoom frames draw images without repainting stroke paths',
    () async {
      final InkTileCache tiles = InkTileCache(
        scheduler: InkTileScheduler(scheduleWork: scheduleMicrotask),
      );
      addTearDown(tiles.dispose);
      int draws = 0;
      for (int pass = 0; pass < 3; pass++) {
        _requestTiles(tiles, controller, onStroke: () => draws++);
        await tiles.whenIdle;
      }
      final int before = draws;
      _requestTiles(
        tiles,
        controller,
        scale: 1.8,
        zooming: true,
        onStroke: () => draws++,
      );
      expect(
        draws,
        before,
        reason: 'existing images cover the first zoom frame',
      );
      await tiles.whenIdle;
      final int detailed = draws;
      _requestTiles(
        tiles,
        controller,
        scale: 1.9,
        zooming: true,
        onStroke: () => draws++,
      );
      expect(draws, detailed);
      await tiles.whenIdle;
      expect(
        draws,
        detailed,
        reason: 'fractional changes reuse the same level',
      );
    },
  );

  test(
    'prefetch warms a neighbouring tile before it scrolls into view',
    () async {
      final Stroke nearby = Stroke.fromPoints(
        style: const StrokeStyle(ink: InkPalette.ink, width: 3),
        points: const <InkVector>[InkVector(300, 50), InkVector(420, 50)],
      );
      final InkController ink = InkController(strokes: <Stroke>[nearby]);
      final InkTileCache tiles = InkTileCache(
        scheduler: InkTileScheduler(scheduleWork: scheduleMicrotask),
      );
      addTearDown(ink.dispose);
      addTearDown(tiles.dispose);
      int draws = 0;
      _requestTiles(
        tiles,
        ink,
        area: const Rect.fromLTWH(0, 0, 200, 200),
        onStroke: () => draws++,
      );
      await tiles.whenIdle;
      expect(tiles.imageCount, greaterThan(0));
      final int warmed = draws;
      _requestTiles(
        tiles,
        ink,
        area: const Rect.fromLTWH(260, 0, 200, 200),
        onStroke: () => draws++,
      );
      expect(draws, warmed, reason: 'newly visible ink is already cached');
      await tiles.whenIdle;
    },
  );

  test(
    'offscreen tiles stay at preview resolution until they become visible',
    () async {
      final Stroke nearby = Stroke.fromPoints(
        style: const StrokeStyle(ink: InkPalette.ink, width: 3),
        points: const <InkVector>[InkVector(300, 50), InkVector(420, 50)],
      );
      final InkController ink = InkController(strokes: <Stroke>[nearby]);
      final InkTileCache tiles = InkTileCache(
        scheduler: InkTileScheduler(scheduleWork: scheduleMicrotask),
      );
      addTearDown(ink.dispose);
      addTearDown(tiles.dispose);
      for (int pass = 0; pass < 2; pass++) {
        _requestTiles(
          tiles,
          ink,
          scale: 4,
          area: const Rect.fromLTWH(0, 0, 200, 200),
        );
        await tiles.whenIdle;
      }
      expect(tiles.imageCount, 1);
      expect(tiles.memoryBytes, lessThan(300000));
      _requestTiles(
        tiles,
        ink,
        scale: 4,
        area: const Rect.fromLTWH(260, 0, 200, 200),
      );
      await tiles.whenIdle;
      expect(tiles.imageCount, 2);
      expect(tiles.memoryBytes, greaterThan(4000000));
    },
  );

  testWidgets(
    'frame scheduling progressively settles and stops requesting frames',
    (WidgetTester tester) async {
      Completer<void>? rasterDone;
      final InkTileScheduler scheduler = InkTileScheduler(
        rasterize: (ui.Picture picture, int width, int height) {
          final Completer<void> done = Completer<void>();
          rasterDone = done;
          return picture.toImage(width, height).whenComplete(done.complete);
        },
      );
      final InkTileCache tiles = InkTileCache(scheduler: scheduler);
      final ValueNotifier<Rect> visible = ValueNotifier<Rect>(
        Offset.zero & _page,
      );
      final ValueNotifier<double> scale = ValueNotifier<double>(1.8);
      addTearDown(tiles.dispose);
      addTearDown(visible.dispose);
      addTearDown(scale.dispose);
      await tester.pumpWidget(
        SizedBox.fromSize(
          size: _page,
          child: CustomPaint(
            painter: CompletedStrokesPainter(
              controller: controller,
              brightness: Brightness.light,
              visible: visible,
              scale: scale,
              tiles: tiles,
            ),
          ),
        ),
      );
      for (int frame = 0; frame < 200; frame++) {
        final Completer<void>? done = rasterDone;
        rasterDone = null;
        if (done != null) await tester.runAsync(() => done.future);
        await tester.pump(const Duration(milliseconds: 16));
        if (scheduler.pendingJobs == 0 && !tester.binding.hasScheduledFrame) {
          break;
        }
      }
      expect(tiles.imageCount, greaterThan(0));
      expect(tiles.scale, 2);
      expect(scheduler.pendingJobs, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'cold frames reuse commands and leaving the view cancels queued work',
    () async {
      final List<VoidCallback> work = <VoidCallback>[];
      final InkTileScheduler scheduler = InkTileScheduler(
        scheduleWork: work.add,
      );
      final InkTileCache tiles = InkTileCache(scheduler: scheduler);
      addTearDown(tiles.dispose);
      int draws = 0;
      _requestTiles(tiles, controller, onStroke: () => draws++);
      final int first = draws;
      expect(first, greaterThan(0));
      _requestTiles(tiles, controller, onStroke: () => draws++);
      expect(draws, first);
      expect(scheduler.pendingJobs, greaterThan(0));
      _requestTiles(tiles, controller, area: Rect.zero);
      expect(scheduler.pendingJobs, 0);
      for (final VoidCallback tick in work) {
        tick();
      }
      await tiles.whenIdle;
      expect(tiles.rasterized, 0);
    },
  );

  for (final bool dispose in <bool>[false, true]) {
    test(
      'late raster results are discarded after ${dispose ? 'disposal' : 'clear'}',
      () async {
        final Completer<void> started = Completer<void>();
        final Completer<void> release = Completer<void>();
        ui.Image? result;
        final InkTileScheduler scheduler = InkTileScheduler(
          scheduleWork: scheduleMicrotask,
          rasterize: (ui.Picture picture, int width, int height) async {
            result = await picture.toImage(width, height);
            started.complete();
            await release.future;
            return result!;
          },
        );
        final InkTileCache tiles = InkTileCache(scheduler: scheduler);
        addTearDown(tiles.dispose);
        _requestTiles(tiles, controller);
        await started.future;
        if (dispose) {
          tiles.dispose();
        } else {
          tiles.clear();
        }
        release.complete();
        await tiles.whenIdle;
        expect(tiles.imageCount, 0);
        expect(tiles.rasterized, 0);
        expect(result!.debugDisposed, isTrue);
        expect(scheduler.pendingJobs, 0);
      },
    );
  }

  test('clear lets go of every tile, and they come back', () async {
    await layer.pixels(tiled: true);
    expect(layer.tiles.imageCount, greaterThan(0));
    layer.tiles.clear();
    expect(layer.tiles.imageCount, 0);
    await layer.pixels(tiled: true);
    expect(layer.tiles.imageCount, greaterThan(0));
  });
}
