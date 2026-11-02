import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/page/page_viewport.dart';

const PageSetup _a4 = PageSetup(size: PageSize.a4Portrait);
const int _pageCount = 8;
const Size _area = Size(300, 700);

/// A column whose current page is kept as the editor keeps it: a touched
/// page becomes current at once, a page scrolled to only when the scroll
/// ends, and either only when the host next builds.
class _Host extends StatefulWidget {
  const _Host({required this.viewportKey});

  final GlobalKey<PageViewportState> viewportKey;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  int current = 0;
  bool _scrolling = false;
  int? _scrolledTo;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: AppTheme.light(),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox.fromSize(
            size: _area,
            child: PageViewport(
              key: widget.viewportKey,
              pages: <PageGeometry>[
                for (int i = 0; i < _pageCount; i++)
                  PageGeometry.of(_a4, null, _area),
              ],
              pageKeys: <Key>[
                for (int i = 0; i < _pageCount; i++) ValueKey<int>(i),
              ],
              currentPage: current,
              onPageTouched: (int page) => setState(() {
                _scrolledTo = null;
                current = page;
              }),
              onVisiblePageChanged: (int page) {
                _scrolledTo = page;
                if (!_scrolling) setState(() => current = page);
              },
              onScrollStart: (Set<int> _) {
                _scrolling = true;
                _scrolledTo = null;
              },
              onScrollEnd: () {
                _scrolling = false;
                final int? settled = _scrolledTo;
                _scrolledTo = null;
                if (settled != null) setState(() => current = settled);
              },
              pageBuilder:
                  (BuildContext context, int index, ValueListenable<Rect> _) =>
                      SizedBox.expand(key: ValueKey<String>('page $index')),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets(
    'fingers set down on a coasting column scroll on from where it stopped, '
    'without jumping to the page they touched',
    (WidgetTester tester) async {
      tester.view.physicalSize = _area;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final GlobalKey<PageViewportState> key = GlobalKey<PageViewportState>();
      await tester.pumpWidget(_Host(viewportKey: key));

      // Flick the column up, so it coasts on past the first page.
      const Duration step = Duration(milliseconds: 16);
      Duration time = Duration.zero;
      final TestGesture a = await tester.startGesture(
        const Offset(100, 600),
        pointer: 1,
        kind: PointerDeviceKind.touch,
      );
      final TestGesture b = await tester.startGesture(
        const Offset(200, 600),
        pointer: 2,
        kind: PointerDeviceKind.touch,
      );
      for (int i = 0; i < 6; i++) {
        time += step;
        await a.moveBy(const Offset(0, -60), timeStamp: time);
        await b.moveBy(const Offset(0, -60), timeStamp: time);
      }
      time += const Duration(milliseconds: 4);
      await a.up(timeStamp: time);
      await b.up(timeStamp: time);
      for (int i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final PageViewportState viewport = key.currentState!;
      expect(viewport.isScrolling, isTrue, reason: 'the flick coasts');

      // A point on a page other than the one holding the middle of the
      // area, so the fingers touch a page that is not the one scrolled to.
      double? touchY;
      for (int i = 0; i < _pageCount && touchY == null; i++) {
        final Finder page = find.byKey(ValueKey<String>('page $i'));
        if (page.evaluate().isEmpty) continue;
        final Rect rect = tester.getRect(page);
        final double top = rect.top.clamp(0, _area.height);
        final double bottom = rect.bottom.clamp(0, _area.height);
        final bool middle =
            rect.top <= _area.height / 2 && rect.bottom >= _area.height / 2;
        if (!middle && bottom - top > 80) touchY = (top + bottom) / 2;
      }
      expect(touchY, isNotNull);

      // Two fingers land and move before the host has built again, as a
      // second flick does on a page heavy enough to delay the frame.
      time += const Duration(milliseconds: 200);
      final TestGesture c = await tester.startGesture(
        Offset(100, touchY!),
        pointer: 3,
        kind: PointerDeviceKind.touch,
      );
      final TestGesture d = await tester.startGesture(
        Offset(200, touchY),
        pointer: 4,
        kind: PointerDeviceKind.touch,
      );
      final double stopped = viewport.scrollOffset.dy;
      time += step;
      await c.moveBy(const Offset(0, -30), timeStamp: time);
      await d.moveBy(const Offset(0, -30), timeStamp: time);
      expect(viewport.scrollOffset.dy, moreOrLessEquals(stopped + 30));

      await tester.pump();
      expect(
        viewport.scrollOffset.dy,
        moreOrLessEquals(stopped + 30),
        reason: 'the page touched becoming current is not a jump to it',
      );

      await c.up(timeStamp: time + const Duration(milliseconds: 200));
      await d.up(timeStamp: time + const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    },
  );
}
