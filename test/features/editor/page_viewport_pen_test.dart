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

Widget _column(GlobalKey<PageViewportState> key, VoidCallback onScrollEnd) {
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
            onScrollEnd: onScrollEnd,
            pageBuilder:
                (BuildContext context, int index, ValueListenable<Rect> _) =>
                    const SizedBox.expand(),
          ),
        ),
      ),
    ),
  );
}

/// Two fingers flick the column up and lift at speed, so it coasts on.
Future<void> _flick(WidgetTester tester) async {
  const Duration step = Duration(milliseconds: 16);
  Duration time = Duration.zero;
  final TestGesture first = await tester.startGesture(
    const Offset(250, 500),
    pointer: 1,
    kind: PointerDeviceKind.touch,
  );
  final TestGesture second = await tester.startGesture(
    const Offset(350, 500),
    pointer: 2,
    kind: PointerDeviceKind.touch,
  );
  for (int i = 0; i < 6; i++) {
    time += step;
    await first.moveBy(const Offset(0, -40), timeStamp: time);
    await second.moveBy(const Offset(0, -40), timeStamp: time);
  }
  time += const Duration(milliseconds: 4);
  await first.up(timeStamp: time);
  await second.up(timeStamp: time);
}

void main() {
  testWidgets('a pen set down on a coasting column stops it and ends the '
      'scroll', (WidgetTester tester) async {
    final GlobalKey<PageViewportState> key = GlobalKey<PageViewportState>();
    int scrollEnds = 0;
    await tester.pumpWidget(_column(key, () => scrollEnds++));

    await _flick(tester);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    final PageViewportState viewport = key.currentState!;
    expect(viewport.isScrolling, isTrue, reason: 'the flick coasts');
    expect(scrollEnds, 0);

    expect(viewport.yieldToPen(), isTrue);
    expect(scrollEnds, 1);
    expect(viewport.isScrolling, isFalse);

    final Offset stopped = viewport.scrollOffset;
    await tester.pump(const Duration(milliseconds: 100));
    expect(viewport.scrollOffset, stopped, reason: 'the coast is over');
  });

  testWidgets('a pen waits while fingers are still moving the column', (
    WidgetTester tester,
  ) async {
    final GlobalKey<PageViewportState> key = GlobalKey<PageViewportState>();
    int scrollEnds = 0;
    await tester.pumpWidget(_column(key, () => scrollEnds++));

    final TestGesture first = await tester.startGesture(
      const Offset(250, 500),
      pointer: 1,
      kind: PointerDeviceKind.touch,
    );
    final TestGesture second = await tester.startGesture(
      const Offset(350, 500),
      pointer: 2,
      kind: PointerDeviceKind.touch,
    );
    await first.moveBy(const Offset(0, -40));
    await second.moveBy(const Offset(0, -40));

    expect(key.currentState!.yieldToPen(), isFalse);
    expect(scrollEnds, 0);

    await first.up();
    await second.up();
    await tester.pumpAndSettle();
  });
}
