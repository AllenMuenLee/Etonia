import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/page/page_viewport.dart';

const PageSetup _a4 = PageSetup(size: PageSize.a4Portrait);
const int _pageCount = 5;

/// A column of A4 pages, each scaled to [width] as the editor does, in an
/// area [width] wide, like the writing area as the AI panel opens and
/// closes beside it. The current page follows the scroll, as in the editor.
Widget _column(
  double width,
  GlobalKey<PageViewportState> key,
  ValueNotifier<int> current, {
  ValueListenable<bool>? fingersNavigate,
}) {
  final Size area = Size(width, 700);
  return Theme(
    data: AppTheme.light(),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox.fromSize(
          size: area,
          child: PageViewport(
            key: key,
            pages: <PageGeometry>[
              for (int i = 0; i < _pageCount; i++)
                PageGeometry.of(_a4, null, area),
            ],
            pageKeys: <Key>[
              for (int i = 0; i < _pageCount; i++) ValueKey<int>(i),
            ],
            currentPage: current.value,
            fingersNavigate: fingersNavigate,
            onVisiblePageChanged: (int page) => current.value = page,
            pageBuilder:
                (BuildContext context, int index, ValueListenable<Rect> _) =>
                    const SizedBox.expand(),
          ),
        ),
      ),
    ),
  );
}

Future<void> _sendTouchDown(
  WidgetTester tester, {
  required int pointer,
  required Offset position,
  double radius = 0,
  double size = 0,
}) {
  return tester.sendEventToBinding(
    PointerDownEvent(
      viewId: tester.view.viewId,
      pointer: pointer,
      kind: PointerDeviceKind.touch,
      position: position,
      buttons: kPrimaryButton,
      radiusMajor: radius,
      radiusMinor: radius,
      size: size,
    ),
  );
}

Future<void> _sendTouchMove(
  WidgetTester tester, {
  required int pointer,
  required Offset from,
  required Offset to,
  double radius = 0,
  double size = 0,
}) {
  return tester.sendEventToBinding(
    PointerMoveEvent(
      viewId: tester.view.viewId,
      pointer: pointer,
      kind: PointerDeviceKind.touch,
      position: to,
      delta: to - from,
      buttons: kPrimaryButton,
      radiusMajor: radius,
      radiusMinor: radius,
      size: size,
    ),
  );
}

Future<void> _sendTouchUp(
  WidgetTester tester, {
  required int pointer,
  required Offset position,
}) {
  return tester.sendEventToBinding(
    PointerUpEvent(
      viewId: tester.view.viewId,
      pointer: pointer,
      kind: PointerDeviceKind.touch,
      position: position,
    ),
  );
}

/// The page holding the middle of the area, and how far down it.
(int, double) _middle(PageViewportState state, double width) {
  final double pageHeight = 1123 * width / 794;
  const double gap = 16;
  final double middle = state.scrollOffset.dy + 350;
  final int page = (middle / (pageHeight + gap)).floor();
  return (page, (middle - page * (pageHeight + gap)) / pageHeight);
}

void main() {
  testWidgets(
    'a palm-sized contact blocks scrolling and zooming in either writing mode',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      for (final bool stylusOnly in <bool>[false, true]) {
        final GlobalKey<PageViewportState> key = GlobalKey<PageViewportState>();
        final ValueNotifier<int> current = ValueNotifier<int>(0);
        final ValueNotifier<bool> fingersNavigate = ValueNotifier<bool>(
          stylusOnly,
        );
        addTearDown(current.dispose);
        addTearDown(fingersNavigate.dispose);
        await tester.pumpWidget(
          _column(1100, key, current, fingersNavigate: fingersNavigate),
        );

        final PageViewportState state = key.currentState!;
        final Offset center = tester.getCenter(find.byType(PageViewport));
        final Offset fingerStart = center - const Offset(50, 0);
        final Offset palmStart = center + const Offset(50, 0);
        final Offset fingerEnd = fingerStart + const Offset(-80, -100);
        final Offset palmEnd = palmStart + const Offset(80, -100);
        final Offset offsetBefore = state.scrollOffset;
        final double zoomBefore = state.zoom;
        // iOS supplies the contact radius. Android devices that omit it
        // still supply Flutter's normalized contact size.
        final double palmRadius = stylusOnly ? 40 : 0;
        final double palmSize = stylusOnly ? 0 : 0.35;

        await _sendTouchDown(
          tester,
          pointer: 10,
          position: fingerStart,
          radius: 8,
        );
        await _sendTouchDown(
          tester,
          pointer: 11,
          position: palmStart,
          radius: palmRadius,
          size: palmSize,
        );
        await _sendTouchMove(
          tester,
          pointer: 10,
          from: fingerStart,
          to: fingerEnd,
          radius: 8,
        );
        await _sendTouchMove(
          tester,
          pointer: 11,
          from: palmStart,
          to: palmEnd,
          radius: palmRadius,
          size: palmSize,
        );
        await tester.pump();

        expect(
          state.scrollOffset,
          offsetBefore,
          reason: 'stylusOnly=$stylusOnly',
        );
        expect(state.zoom, zoomBefore, reason: 'stylusOnly=$stylusOnly');

        await _sendTouchUp(tester, pointer: 10, position: fingerEnd);
        await _sendTouchUp(tester, pointer: 11, position: palmEnd);
      }
    },
  );

  testWidgets('navigation stops when a moving contact grows to palm size', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final GlobalKey<PageViewportState> key = GlobalKey<PageViewportState>();
    final ValueNotifier<int> current = ValueNotifier<int>(0);
    final ValueNotifier<bool> fingersNavigate = ValueNotifier<bool>(true);
    addTearDown(current.dispose);
    addTearDown(fingersNavigate.dispose);
    await tester.pumpWidget(
      _column(1100, key, current, fingersNavigate: fingersNavigate),
    );

    final Offset start = tester.getCenter(find.byType(PageViewport));
    final Offset fingerMove = start - const Offset(0, 40);
    final Offset palmMove = fingerMove - const Offset(0, 100);
    await _sendTouchDown(tester, pointer: 20, position: start, radius: 8);
    await _sendTouchMove(
      tester,
      pointer: 20,
      from: start,
      to: fingerMove,
      radius: 8,
    );
    final Offset beforePalm = key.currentState!.scrollOffset;
    expect(beforePalm.dy, greaterThan(0));

    await _sendTouchMove(
      tester,
      pointer: 20,
      from: fingerMove,
      to: palmMove,
      radius: 40,
    );
    await tester.pump();
    expect(key.currentState!.scrollOffset, beforePalm);

    await _sendTouchUp(tester, pointer: 20, position: palmMove);
  });

  testWidgets('resizing the area keeps the same place of the same page in '
      'view', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final GlobalKey<PageViewportState> key = GlobalKey<PageViewportState>();
    final ValueNotifier<int> current = ValueNotifier<int>(0);
    addTearDown(current.dispose);

    await tester.pumpWidget(_column(1100, key, current));
    key.currentState!.scrollBy(const Offset(0, 3000));
    await tester.pump();
    final (int page, double down) = _middle(key.currentState!, 1100);
    expect(page, 2);
    expect(current.value, 2);

    for (final double width in <double>[740, 1100, 600, 1100]) {
      await tester.pumpWidget(_column(width, key, current));
      final (int nowPage, double nowDown) = _middle(key.currentState!, width);
      expect(nowPage, page, reason: '$width');
      expect(nowDown, closeTo(down, 0.01), reason: '$width');
      expect(current.value, page, reason: '$width');
    }
  });

  testWidgets('a resize at the top leaves the column at its edge', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final GlobalKey<PageViewportState> key = GlobalKey<PageViewportState>();
    final ValueNotifier<int> current = ValueNotifier<int>(0);
    addTearDown(current.dispose);

    await tester.pumpWidget(_column(1100, key, current));
    expect(key.currentState!.scrollOffset, Offset.zero);
    // As when the AI panel opens beside the page: keeping the middle in view
    // must not slide the first page down past its edge.
    await tester.pumpWidget(_column(740, key, current));
    expect(key.currentState!.scrollOffset.dy, 0);

    // Scrolled past the edge by the reader, a resize may stay there.
    await tester.pumpWidget(_column(1100, key, current));
    key.currentState!.scrollBy(const Offset(0, -1000));
    await tester.pump();
    expect(key.currentState!.scrollOffset.dy, -48);
    await tester.pumpWidget(_column(740, key, current));
    expect(key.currentState!.scrollOffset.dy, lessThan(0));
  });

  testWidgets('pages filling the area scroll slightly past every edge', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final GlobalKey<PageViewportState> key = GlobalKey<PageViewportState>();
    final ValueNotifier<int> current = ValueNotifier<int>(0);
    addTearDown(current.dispose);

    await tester.pumpWidget(_column(1100, key, current));
    final PageViewportState state = key.currentState!;
    state.scrollBy(const Offset(-1000, -1000));
    await tester.pump();
    expect(state.scrollOffset, const Offset(-48, -48));

    state.scrollBy(const Offset(1000, 0));
    await tester.pump();
    expect(state.scrollOffset.dx, 48);

    const double pageHeight = 1123 * 1100 / 794;
    const double columnHeight = _pageCount * pageHeight + (_pageCount - 1) * 16;
    state.scrollBy(const Offset(0, 1e6));
    await tester.pump();
    expect(state.scrollOffset.dy, closeTo(columnHeight - 700 + 48, 0.01));
  });

  testWidgets('a tap on the desk is reported; a tap on a page is not', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    int deskTaps = 0;
    await tester.pumpWidget(
      Theme(
        data: AppTheme.light(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 1100,
              height: 700,
              child: PageViewport(
                pages: <PageGeometry>[
                  PageGeometry.of(_a4, null, const Size(1100, 700)),
                ],
                pageKeys: const <Key>[ValueKey<int>(0)],
                currentPage: 0,
                minZoom: 0.3,
                initialZoom: 0.3,
                onDeskTap: () => deskTaps++,
                pageBuilder:
                    (
                      BuildContext context,
                      int index,
                      ValueListenable<Rect> _,
                    ) => const SizedBox.expand(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final Rect page = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey<int>(0)),
        matching: find.byType(ColoredBox),
      ),
    );
    expect(page.left, greaterThan(20));

    await tester.tapAt(page.center);
    expect(deskTaps, 0);
    await tester.tapAt(Offset(page.left / 2, page.center.dy));
    expect(deskTaps, 1);
  });

  testWidgets('a pinch keeps what is under the fingers there, even when '
      'both fingers move within one frame', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final GlobalKey<PageViewportState> key = GlobalKey<PageViewportState>();
    final ValueNotifier<int> current = ValueNotifier<int>(0);
    addTearDown(current.dispose);
    await tester.pumpWidget(_column(1100, key, current));
    final PageViewportState state = key.currentState!;
    expect(state.zoom, 1);

    // Off-center, toward the lower right of the first page.
    const Offset focal = Offset(900, 500);
    // Where on the first page the focal point is, in the page's own pixels.
    Offset onPage() => (focal + state.scrollOffset) / state.zoom;
    final Offset before = onPage();

    Offset a = focal - const Offset(60, 0);
    Offset b = focal + const Offset(60, 0);
    await _sendTouchDown(tester, pointer: 20, position: a);
    await _sendTouchDown(tester, pointer: 21, position: b);
    for (int step = 0; step < 6; step++) {
      // Both fingers report before the next frame lays out the column, as
      // a single multi-touch event from the platform does.
      final Offset nextA = a - const Offset(15, 0);
      final Offset nextB = b + const Offset(15, 0);
      await _sendTouchMove(tester, pointer: 20, from: a, to: nextA);
      await _sendTouchMove(tester, pointer: 21, from: b, to: nextB);
      a = nextA;
      b = nextB;
      await tester.pump();
    }
    expect(state.zoom, greaterThan(1.4));
    expect(onPage().dx, closeTo(before.dx, 1));
    expect(onPage().dy, closeTo(before.dy, 1));

    await _sendTouchUp(tester, pointer: 20, position: a);
    await _sendTouchUp(tester, pointer: 21, position: b);
  });
}
