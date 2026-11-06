import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/page/page_viewport.dart';

const PageSetup _a4 = PageSetup(size: PageSize.a4Portrait);
const int _pageCount = 5;
const Size _area = Size(600, 700);
const Duration _frame = Duration(milliseconds: 16);
const Duration _stopped = Duration(milliseconds: 200);

/// What the first page was handed by its viewport.
class _FirstPage {
  ValueListenable<Rect>? visible;
  ValueListenable<Rect>? paintArea;
  ValueListenable<double>? scale;
  ValueListenable<bool>? zooming;
}

Widget _column(
  _FirstPage first,
  double initialZoom, {
  GlobalKey<PageViewportState>? viewportKey,
}) {
  return Theme(
    data: AppTheme.light(),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox.fromSize(
          size: _area,
          child: PageViewport(
            key: viewportKey,
            pages: <PageGeometry>[
              for (int i = 0; i < _pageCount; i++)
                PageGeometry.of(_a4, null, _area),
            ],
            pageKeys: <Key>[
              for (int i = 0; i < _pageCount; i++) ValueKey<int>(i),
            ],
            currentPage: 0,
            initialZoom: initialZoom,
            pageBuilder:
                (
                  BuildContext context,
                  int index,
                  ValueListenable<Rect> visible,
                ) {
                  return Builder(
                    builder: (BuildContext context) {
                      if (index == 0) {
                        first.visible = visible;
                        first.paintArea = PageViewport.paintAreaOf(context);
                        first.scale = PageViewport.scaleOf(context);
                        first.zooming = PageViewport.zoomingOf(context);
                      }
                      return const SizedBox.expand();
                    },
                  );
                },
          ),
        ),
      ),
    ),
  );
}

/// Pinches with two fingers, moving each [step] away from the other for
/// [moves] frames, and running [onFrame] after each.
Future<void> _pinch(
  WidgetTester tester,
  double step,
  int moves,
  VoidCallback onFrame,
) async {
  final TestGesture left = await tester.startGesture(
    const Offset(200, 300),
    pointer: 1,
    kind: PointerDeviceKind.touch,
  );
  final TestGesture right = await tester.startGesture(
    const Offset(400, 300),
    pointer: 2,
    kind: PointerDeviceKind.touch,
  );
  for (int i = 0; i < moves; i++) {
    await left.moveBy(Offset(-step, 0));
    await right.moveBy(Offset(step, 0));
    await tester.pump(_frame);
    onFrame();
  }
  await left.up();
  await right.up();
}

/// Counts its paints, and marks a square on the page to find on screen.
class _SquarePainter extends CustomPainter {
  _SquarePainter(this.onPaint, {super.repaint});

  final VoidCallback onPaint;
  static const Rect square = Rect.fromLTWH(380, 400, 60, 60);

  @override
  void paint(Canvas canvas, Size size) {
    onPaint();
    canvas.drawRect(square, Paint()..color = const Color(0xFFFF0000));
  }

  @override
  bool shouldRepaint(_SquarePainter oldDelegate) => false;
}

/// The box round the red pixels of what [key] shows.
Future<Rect> _redBounds(WidgetTester tester, GlobalKey key) async {
  final RenderRepaintBoundary boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final ui.Image image = (await tester.runAsync(boundary.toImage))!;
  final ByteData bytes = (await tester.runAsync<ByteData?>(image.toByteData))!;
  double left = double.infinity;
  double top = double.infinity;
  double right = -1;
  double bottom = -1;
  for (int y = 0; y < image.height; y++) {
    for (int x = 0; x < image.width; x++) {
      final int at = (y * image.width + x) * 4;
      // Past halfway, so a soft edge counts where it would be drawn.
      if (bytes.getUint8(at) > 200 &&
          bytes.getUint8(at + 1) < 128 &&
          bytes.getUint8(at + 2) < 128) {
        left = math.min(left, x.toDouble());
        top = math.min(top, y.toDouble());
        right = math.max(right, x + 1.0);
        bottom = math.max(bottom, y + 1.0);
      }
    }
  }
  final Rect bounds = Rect.fromLTRB(left, top, right, bottom);
  image.dispose();
  return bounds;
}

bool _covers(Rect outer, Rect inner) =>
    outer.left <= inner.left &&
    outer.top <= inner.top &&
    outer.right >= inner.right &&
    outer.bottom >= inner.bottom;

void main() {
  group('viewport content remains live during zoom', () {
    late int paints;
    late GlobalKey shown;
    late GlobalKey<PageViewportState> viewport;

    /// One page painting its square with no boundary of its own, the case
    /// that would repaint along with the transform round it.
    Future<void> pumpColumn(WidgetTester tester) async {
      paints = 0;
      shown = GlobalKey();
      viewport = GlobalKey<PageViewportState>();
      await tester.pumpWidget(
        Theme(
          data: AppTheme.light(),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                key: shown,
                child: SizedBox.fromSize(
                  size: _area,
                  child: PageViewport(
                    key: viewport,
                    pages: <PageGeometry>[PageGeometry.of(_a4, null, _area)],
                    pageKeys: const <Key>[ValueKey<int>(0)],
                    currentPage: 0,
                    pageBuilder:
                        (
                          BuildContext context,
                          int index,
                          ValueListenable<Rect> visible,
                        ) {
                          return Builder(
                            builder: (BuildContext context) => CustomPaint(
                              painter: _SquarePainter(
                                () => paints++,
                                repaint: PageViewport.zoomingOf(context),
                              ),
                              size: Size.infinite,
                            ),
                          );
                        },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('content follows each zoom frame and repaints on release', (
      WidgetTester tester,
    ) async {
      await pumpColumn(tester);
      final List<int> during = <int>[];
      await _pinch(tester, 8, 12, () => during.add(paints));
      expect(during.toSet(), hasLength(12));
      expect(find.byType(SnapshotWidget), findsNothing);

      final int settled = paints;
      await tester.pump(_stopped);
      // Once more when it stops, sharp at the new size, and then no more.
      expect(paints, settled + 1);
      await tester.pump(_stopped);
      expect(paints, settled + 1);
    });

    testWidgets('settling keeps content aligned with the live zoom', (
      WidgetTester tester,
    ) async {
      await pumpColumn(tester);
      final TestGesture left = await tester.startGesture(
        const Offset(200, 300),
        pointer: 1,
        kind: PointerDeviceKind.touch,
      );
      final TestGesture right = await tester.startGesture(
        const Offset(400, 300),
        pointer: 2,
        kind: PointerDeviceKind.touch,
      );
      for (int i = 0; i < 10; i++) {
        await left.moveBy(const Offset(-8, 0));
        await right.moveBy(const Offset(8, 3));
        await tester.pump(_frame);
      }
      final int paintsBefore = paints;
      final Rect picture = await _redBounds(tester, shown);
      expect(paints, paintsBefore, reason: 'reading pixels does not repaint');

      // Painted for real, from the same place, it must land in the same spot.
      await left.up();
      await right.up();
      await tester.pump(_stopped);
      expect(paints, greaterThan(paintsBefore));
      final Rect painted = await _redBounds(tester, shown);
      expect(picture.left, closeTo(painted.left, 2));
      expect(picture.top, closeTo(painted.top, 2));
      expect(picture.right, closeTo(painted.right, 2));
      expect(picture.bottom, closeTo(painted.bottom, 2));
    });
  });

  testWidgets('scale follows every zoom frame while paint coverage is reused', (
    WidgetTester tester,
  ) async {
    final _FirstPage first = _FirstPage();
    await tester.pumpWidget(_column(first, 1));
    double previous = first.scale!.value;
    await _pinch(tester, 8, 10, () {
      expect(first.scale!.value, greaterThan(previous));
      expect(_covers(first.paintArea!.value, first.visible!.value), isTrue);
      expect(first.zooming!.value, isTrue);
      previous = first.scale!.value;
    });
    await tester.pump(_frame);
    expect(
      first.zooming!.value,
      isFalse,
      reason: 'release settles immediately',
    );
    expect(first.scale!.value, previous);
    expect(_covers(first.paintArea!.value, first.visible!.value), isTrue);
  });

  testWidgets('reversing a pinch updates vectors without a stale scale', (
    WidgetTester tester,
  ) async {
    final _FirstPage first = _FirstPage();
    await tester.pumpWidget(_column(first, 1));
    final TestGesture left = await tester.startGesture(
      const Offset(200, 300),
      pointer: 1,
      kind: PointerDeviceKind.touch,
    );
    final TestGesture right = await tester.startGesture(
      const Offset(400, 300),
      pointer: 2,
      kind: PointerDeviceKind.touch,
    );
    final double start = first.scale!.value;
    await left.moveBy(const Offset(-40, 0));
    await right.moveBy(const Offset(40, 0));
    await tester.pump(_frame);
    expect(first.scale!.value, greaterThan(start));
    await left.moveBy(const Offset(60, 0));
    await right.moveBy(const Offset(-60, 0));
    await tester.pump(_frame);
    expect(first.scale!.value, lessThan(start));
    expect(_covers(first.paintArea!.value, first.visible!.value), isTrue);
    await left.cancel();
    await right.cancel();
    await tester.pump(_frame);
    expect(first.zooming!.value, isFalse);
  });

  testWidgets('trackpad zoom follows the scale and settles on release', (
    WidgetTester tester,
  ) async {
    final _FirstPage first = _FirstPage();
    await tester.pumpWidget(_column(first, 1));
    final double initialScale = first.scale!.value;
    final TestGesture gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomStart(const Offset(300, 300));
    for (final double scale in <double>[1.2, 1.5, 0.8]) {
      await gesture.panZoomUpdate(const Offset(300, 300), scale: scale);
      await tester.pump(_frame);
      expect(first.scale!.value, closeTo(initialScale * scale, 1e-6));
      expect(first.zooming!.value, isTrue);
      expect(_covers(first.paintArea!.value, first.visible!.value), isTrue);
    }
    await gesture.panZoomEnd();
    await tester.pump(_frame);
    expect(first.zooming!.value, isFalse);
  });

  testWidgets('zooming out maintains paint coverage with fewer area updates', (
    WidgetTester tester,
  ) async {
    final _FirstPage first = _FirstPage();
    await tester.pumpWidget(_column(first, 4));

    int paints = 0;
    void painted() => paints++;
    first.paintArea!.addListener(painted);

    const int moves = 40;
    await _pinch(tester, -2, moves, () {
      expect(_covers(first.paintArea!.value, first.visible!.value), isTrue);
    });

    expect(paints, lessThan(moves));
    expect(paints, greaterThan(0));

    await tester.pump(_stopped);
    await tester.pump(_frame);
    expect(_covers(first.paintArea!.value, first.visible!.value), isTrue);

    first.paintArea!.removeListener(painted);
  });

  testWidgets('a pinch that is paused paints again when it stops', (
    WidgetTester tester,
  ) async {
    final _FirstPage first = _FirstPage();
    await tester.pumpWidget(_column(first, 1));

    final TestGesture left = await tester.startGesture(
      const Offset(200, 300),
      pointer: 1,
      kind: PointerDeviceKind.touch,
    );
    final TestGesture right = await tester.startGesture(
      const Offset(400, 300),
      pointer: 2,
      kind: PointerDeviceKind.touch,
    );
    await left.moveBy(const Offset(-20, 0));
    await right.moveBy(const Offset(20, 0));
    await tester.pump(_frame);
    expect(_covers(first.paintArea!.value, first.visible!.value), isTrue);
    expect(first.zooming!.value, isTrue);

    // The fingers stay down but the zoom has stopped.
    await tester.pump(_stopped);
    await tester.pump(_frame);
    expect(first.zooming!.value, isFalse);
    expect(first.paintArea!.value, isNot(first.visible!.value));
    expect(_covers(first.paintArea!.value, first.visible!.value), isTrue);

    await left.up();
    await right.up();
    await tester.pump(_stopped);
  });

  testWidgets('scrolling paints ahead of the view, and again only once the '
      'view leaves what was painted', (WidgetTester tester) async {
    final _FirstPage first = _FirstPage();
    final GlobalKey<PageViewportState> key = GlobalKey<PageViewportState>();
    await tester.pumpWidget(_column(first, 1, viewportKey: key));

    final Rect before = first.paintArea!.value;
    expect(_covers(before, first.visible!.value), isTrue);
    expect(before, isNot(first.visible!.value), reason: 'painted ahead');

    // A little scroll stays within it: nothing paints again.
    key.currentState!.scrollBy(const Offset(0, 10));
    await tester.pump(_frame);
    expect(first.paintArea!.value, before);
    expect(_covers(first.paintArea!.value, first.visible!.value), isTrue);

    // A longer one leaves it, and the area follows the view.
    key.currentState!.scrollBy(const Offset(0, 400));
    await tester.pump(_frame);
    expect(first.paintArea!.value, isNot(before));
    expect(_covers(first.paintArea!.value, first.visible!.value), isTrue);
  });

  group('zooming out shows what was off screen', () {
    /// A column whose page [redPage] paints a red square, in a boundary to
    /// read the screen from.
    Future<GlobalKey> pumpMarked(
      WidgetTester tester, {
      required double initialZoom,
      required int redPage,
      required Offset at,
      required VoidCallback onPaint,
    }) async {
      final GlobalKey shown = GlobalKey();
      await tester.pumpWidget(
        Theme(
          data: AppTheme.light(),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                key: shown,
                child: SizedBox.fromSize(
                  size: _area,
                  child: PageViewport(
                    pages: <PageGeometry>[
                      for (int i = 0; i < _pageCount; i++)
                        PageGeometry.of(_a4, null, _area),
                    ],
                    pageKeys: <Key>[
                      for (int i = 0; i < _pageCount; i++) ValueKey<int>(i),
                    ],
                    currentPage: 0,
                    initialZoom: initialZoom,
                    pageBuilder:
                        (
                          BuildContext context,
                          int index,
                          ValueListenable<Rect> visible,
                        ) {
                          return index == redPage
                              ? CustomPaint(
                                  painter: _MarkPainter(at, onPaint),
                                  size: Size.infinite,
                                )
                              : const SizedBox.expand();
                        },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return shown;
    }

    Future<void> expectPictureShowsMark(
      WidgetTester tester,
      GlobalKey shown,
      int Function() paints,
    ) async {
      expect(
        (await _redBounds(tester, shown)).isFinite,
        isFalse,
        reason: 'off screen to begin with',
      );
      final TestGesture left = await tester.startGesture(
        const Offset(200, 300),
        pointer: 1,
        kind: PointerDeviceKind.touch,
      );
      final TestGesture right = await tester.startGesture(
        const Offset(400, 300),
        pointer: 2,
        kind: PointerDeviceKind.touch,
      );
      for (int i = 0; i < 10; i++) {
        await left.moveBy(const Offset(4, 0));
        await right.moveBy(const Offset(-4, 0));
        await tester.pump(_frame);
      }
      final int paintsBefore = paints();
      final Rect picture = await _redBounds(tester, shown);
      expect(paints(), paintsBefore, reason: 'reading pixels does not repaint');
      expect(picture.isFinite, isTrue, reason: 'vectors brought into view');

      await left.up();
      await right.up();
      await tester.pump(_stopped);
      expect(paints(), greaterThan(paintsBefore));
      final Rect painted = await _redBounds(tester, shown);
      expect(picture.left, closeTo(painted.left, 2));
      expect(picture.top, closeTo(painted.top, 2));
      expect(picture.right, closeTo(painted.right, 2));
      expect(picture.bottom, closeTo(painted.bottom, 2));
    }

    testWidgets('the next page, in line with where it settles', (
      WidgetTester tester,
    ) async {
      int paints = 0;
      final GlobalKey shown = await pumpMarked(
        tester,
        initialZoom: 1,
        redPage: 1,
        at: const Offset(100, 60),
        onPaint: () => paints++,
      );
      await expectPictureShowsMark(tester, shown, () => paints);
    });

    testWidgets('the rest of a page zoomed in past the screen', (
      WidgetTester tester,
    ) async {
      int paints = 0;
      final GlobalKey shown = await pumpMarked(
        tester,
        initialZoom: 2,
        redPage: 0,
        at: const Offset(520, 200),
        onPaint: () => paints++,
      );
      await expectPictureShowsMark(tester, shown, () => paints);
    });
  });

  testWidgets('the gap between pages scales with the zoom', (
    WidgetTester tester,
  ) async {
    final PageGeometry geometry = PageGeometry.of(_a4, null, _area);
    for (final double zoom in <double>[0.5, 1, 1.25]) {
      // A new viewport for each zoom.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_column(_FirstPage(), zoom));
      final double top0 = tester
          .getTopLeft(find.byKey(const ValueKey<int>(0)))
          .dy;
      final double top1 = tester
          .getTopLeft(find.byKey(const ValueKey<int>(1)))
          .dy;
      final double gap = top1 - top0 - geometry.displaySize.height * zoom;
      expect(gap, closeTo(16 * zoom, 0.01), reason: 'at zoom $zoom');
    }
  });

  testWidgets('a pinch keeps the gap in proportion to the pages', (
    WidgetTester tester,
  ) async {
    final GlobalKey<PageViewportState> key = GlobalKey<PageViewportState>();
    await tester.pumpWidget(_column(_FirstPage(), 0.5, viewportKey: key));
    double ratio() {
      final double top0 = tester
          .getTopLeft(find.byKey(const ValueKey<int>(0)))
          .dy;
      final double top1 = tester
          .getTopLeft(find.byKey(const ValueKey<int>(1)))
          .dy;
      return (top1 - top0) / key.currentState!.zoom;
    }

    final double before = ratio();
    await _pinch(tester, 4, 10, () {});
    await tester.pump(_stopped);
    expect(key.currentState!.zoom, greaterThan(0.5));
    expect(ratio(), closeTo(before, 0.01));
  });
}

/// Marks a square at [at] on the page, counting its paints.
class _MarkPainter extends CustomPainter {
  _MarkPainter(this.at, this.onPaint);

  final Offset at;
  final VoidCallback onPaint;

  @override
  void paint(Canvas canvas, Size size) {
    onPaint();
    canvas.drawRect(
      at & const Size(40, 40),
      Paint()..color = const Color(0xFFFF0000),
    );
  }

  @override
  bool shouldRepaint(_MarkPainter oldDelegate) => false;
}
