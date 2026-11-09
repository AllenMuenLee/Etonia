import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/page/page_viewport.dart';

const PageSetup _a4 = PageSetup(size: PageSize.a4Portrait);
const int _pageCount = 5;
const Size _area = Size(600, 700);

Widget _column({
  required GlobalKey<PageViewportState> key,
  ValueNotifier<bool>? fingersNavigate,
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
            key: key,
            pages: <PageGeometry>[
              for (int i = 0; i < _pageCount; i++)
                PageGeometry.of(_a4, null, _area),
            ],
            pageKeys: <Key>[
              for (int i = 0; i < _pageCount; i++) ValueKey<int>(i),
            ],
            currentPage: 0,
            fingersNavigate: fingersNavigate,
            pageBuilder:
                (BuildContext context, int index, ValueListenable<Rect> _) =>
                    const SizedBox.expand(),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('three fingers drag neither scrolls nor zooms', (
    WidgetTester tester,
  ) async {
    final GlobalKey<PageViewportState> key = GlobalKey<PageViewportState>();
    await tester.pumpWidget(_column(key: key));
    final PageViewportState viewport = key.currentState!;
    final Offset initialOffset = viewport.scrollOffset;
    final double initialZoom = viewport.zoom;

    final TestGesture f1 = await tester.startGesture(
      const Offset(200, 300),
      pointer: 1,
      kind: PointerDeviceKind.touch,
    );
    final TestGesture f2 = await tester.startGesture(
      const Offset(300, 300),
      pointer: 2,
      kind: PointerDeviceKind.touch,
    );
    final TestGesture f3 = await tester.startGesture(
      const Offset(400, 300),
      pointer: 3,
      kind: PointerDeviceKind.touch,
    );

    for (int i = 0; i < 5; i++) {
      await f1.moveBy(const Offset(10, -50));
      await f2.moveBy(const Offset(20, -50));
      await f3.moveBy(const Offset(30, -50));
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(viewport.isScrolling, isFalse);
    expect(viewport.scrollOffset, initialOffset);
    expect(viewport.zoom, initialZoom);

    await f1.up();
    await f2.up();
    await f3.up();
    await tester.pumpAndSettle();

    expect(viewport.scrollOffset, initialOffset);
    expect(viewport.zoom, initialZoom);
  });

  testWidgets('three fingers pinch outward does not zoom', (
    WidgetTester tester,
  ) async {
    final GlobalKey<PageViewportState> key = GlobalKey<PageViewportState>();
    await tester.pumpWidget(_column(key: key));
    final PageViewportState viewport = key.currentState!;
    final double initialZoom = viewport.zoom;

    final TestGesture f1 = await tester.startGesture(
      const Offset(200, 300),
      pointer: 1,
      kind: PointerDeviceKind.touch,
    );
    final TestGesture f2 = await tester.startGesture(
      const Offset(300, 300),
      pointer: 2,
      kind: PointerDeviceKind.touch,
    );
    final TestGesture f3 = await tester.startGesture(
      const Offset(400, 300),
      pointer: 3,
      kind: PointerDeviceKind.touch,
    );

    for (int i = 0; i < 5; i++) {
      await f1.moveBy(const Offset(-30, 0));
      await f3.moveBy(const Offset(30, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(viewport.zoom, initialZoom);

    await f1.up();
    await f2.up();
    await f3.up();
    await tester.pumpAndSettle();

    expect(viewport.zoom, initialZoom);
  });

  testWidgets('four fingers drag neither scrolls nor zooms', (
    WidgetTester tester,
  ) async {
    final GlobalKey<PageViewportState> key = GlobalKey<PageViewportState>();
    await tester.pumpWidget(_column(key: key));
    final PageViewportState viewport = key.currentState!;
    final Offset initialOffset = viewport.scrollOffset;
    final double initialZoom = viewport.zoom;

    final TestGesture f1 = await tester.startGesture(
      const Offset(150, 300),
      pointer: 1,
      kind: PointerDeviceKind.touch,
    );
    final TestGesture f2 = await tester.startGesture(
      const Offset(250, 300),
      pointer: 2,
      kind: PointerDeviceKind.touch,
    );
    final TestGesture f3 = await tester.startGesture(
      const Offset(350, 300),
      pointer: 3,
      kind: PointerDeviceKind.touch,
    );
    final TestGesture f4 = await tester.startGesture(
      const Offset(450, 300),
      pointer: 4,
      kind: PointerDeviceKind.touch,
    );

    for (int i = 0; i < 5; i++) {
      await f1.moveBy(const Offset(0, -40));
      await f2.moveBy(const Offset(0, -40));
      await f3.moveBy(const Offset(0, -40));
      await f4.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(viewport.isScrolling, isFalse);
    expect(viewport.scrollOffset, initialOffset);
    expect(viewport.zoom, initialZoom);

    await f1.up();
    await f2.up();
    await f3.up();
    await f4.up();
    await tester.pumpAndSettle();

    expect(viewport.scrollOffset, initialOffset);
    expect(viewport.zoom, initialZoom);
  });

  testWidgets('a third finger down stops an active two-finger scroll', (
    WidgetTester tester,
  ) async {
    final GlobalKey<PageViewportState> key = GlobalKey<PageViewportState>();
    await tester.pumpWidget(_column(key: key));
    final PageViewportState viewport = key.currentState!;
    final Offset initialOffset = viewport.scrollOffset;

    final TestGesture f1 = await tester.startGesture(
      const Offset(200, 400),
      pointer: 1,
      kind: PointerDeviceKind.touch,
    );
    final TestGesture f2 = await tester.startGesture(
      const Offset(300, 400),
      pointer: 2,
      kind: PointerDeviceKind.touch,
    );

    // Two fingers move together - scrolling starts
    for (int i = 0; i < 3; i++) {
      await f1.moveBy(const Offset(0, -30));
      await f2.moveBy(const Offset(0, -30));
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(viewport.isScrolling, isTrue);
    final Offset scrolledOffset = viewport.scrollOffset;
    expect(scrolledOffset.dy, greaterThan(initialOffset.dy));

    // Third finger touches down
    final TestGesture f3 = await tester.startGesture(
      const Offset(400, 400),
      pointer: 3,
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(const Duration(milliseconds: 16));

    expect(viewport.isScrolling, isFalse);

    // All three fingers move further
    for (int i = 0; i < 3; i++) {
      await f1.moveBy(const Offset(0, -30));
      await f2.moveBy(const Offset(0, -30));
      await f3.moveBy(const Offset(0, -30));
      await tester.pump(const Duration(milliseconds: 16));
    }

    // Scroll offset must not have changed while 3 fingers were moving
    expect(viewport.scrollOffset, scrolledOffset);

    await f1.up();
    await f2.up();
    await f3.up();
    await tester.pumpAndSettle();
  });

  testWidgets('lifting third finger allows remaining two fingers to scroll', (
    WidgetTester tester,
  ) async {
    final GlobalKey<PageViewportState> key = GlobalKey<PageViewportState>();
    await tester.pumpWidget(_column(key: key));
    final PageViewportState viewport = key.currentState!;

    final TestGesture f1 = await tester.startGesture(
      const Offset(200, 400),
      pointer: 1,
      kind: PointerDeviceKind.touch,
    );
    final TestGesture f2 = await tester.startGesture(
      const Offset(300, 400),
      pointer: 2,
      kind: PointerDeviceKind.touch,
    );
    final TestGesture f3 = await tester.startGesture(
      const Offset(400, 400),
      pointer: 3,
      kind: PointerDeviceKind.touch,
    );

    // Move with 3 fingers - no scroll
    for (int i = 0; i < 3; i++) {
      await f1.moveBy(const Offset(0, -30));
      await f2.moveBy(const Offset(0, -30));
      await f3.moveBy(const Offset(0, -30));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(viewport.scrollOffset, Offset.zero);

    // Lift the third finger
    await f3.up();
    await tester.pump(const Duration(milliseconds: 16));

    // Now move with the remaining 2 fingers
    for (int i = 0; i < 3; i++) {
      await f1.moveBy(const Offset(0, -30));
      await f2.moveBy(const Offset(0, -30));
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(viewport.isScrolling, isTrue);
    expect(viewport.scrollOffset.dy, greaterThan(0));

    await f1.up();
    await f2.up();
    await tester.pumpAndSettle();
  });

  testWidgets('in fingersNavigate mode three fingers do not scroll', (
    WidgetTester tester,
  ) async {
    final GlobalKey<PageViewportState> key = GlobalKey<PageViewportState>();
    final ValueNotifier<bool> fingersNavigate = ValueNotifier<bool>(true);
    await tester.pumpWidget(
      _column(key: key, fingersNavigate: fingersNavigate),
    );
    final PageViewportState viewport = key.currentState!;

    // 1 finger navigates/scrolls
    final TestGesture f1 = await tester.startGesture(
      const Offset(300, 400),
      pointer: 1,
      kind: PointerDeviceKind.touch,
    );
    await f1.moveBy(const Offset(0, -30));
    await tester.pump(const Duration(milliseconds: 16));
    expect(viewport.scrollOffset.dy, greaterThan(0));
    final Offset oneFingerOffset = viewport.scrollOffset;
    await f1.up();
    await tester.pumpAndSettle();

    // Now 3 fingers touch down
    final TestGesture t1 = await tester.startGesture(
      const Offset(200, 400),
      pointer: 10,
      kind: PointerDeviceKind.touch,
    );
    final TestGesture t2 = await tester.startGesture(
      const Offset(300, 400),
      pointer: 11,
      kind: PointerDeviceKind.touch,
    );
    final TestGesture t3 = await tester.startGesture(
      const Offset(400, 400),
      pointer: 12,
      kind: PointerDeviceKind.touch,
    );

    for (int i = 0; i < 5; i++) {
      await t1.moveBy(const Offset(0, -40));
      await t2.moveBy(const Offset(0, -40));
      await t3.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 16));
    }

    // Scroll offset must not change while 3 fingers moved
    expect(viewport.scrollOffset, oneFingerOffset);

    await t1.up();
    await t2.up();
    await t3.up();
    await tester.pumpAndSettle();
  });
}
