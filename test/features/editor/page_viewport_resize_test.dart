import 'package:flutter/foundation.dart';
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
  ValueNotifier<int> current,
) {
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

/// The page holding the middle of the area, and how far down it.
(int, double) _middle(PageViewportState state, double width) {
  final double pageHeight = 1123 * width / 794;
  const double gap = 16;
  final double middle = state.scrollOffset.dy + 350;
  final int page = (middle / (pageHeight + gap)).floor();
  return (page, (middle - page * (pageHeight + gap)) / pageHeight);
}

void main() {
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
}
