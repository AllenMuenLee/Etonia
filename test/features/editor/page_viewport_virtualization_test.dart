import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/page/page_viewport.dart';

void main() {
  testWidgets('a thousand-page viewport builds only its nearby window', (
    WidgetTester tester,
  ) async {
    const int pageCount = 2000;
    const PageGeometry geometry = PageGeometry(Size(500, 700), 1);
    final List<PageGeometry> pages = List<PageGeometry>.filled(
      pageCount,
      geometry,
    );
    final GlobalKey<PageViewportState> key = GlobalKey<PageViewportState>();
    int builds = 0;
    final List<int> builtIndices = <int>[];

    await tester.pumpWidget(
      GreatnoteApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 800,
            height: 600,
            child: PageViewport(
              key: key,
              pages: pages,
              pageKeys: <Key>[
                for (int index = 0; index < pageCount; index++)
                  ValueKey<int>(index),
              ],
              currentPage: 0,
              pageBuilder: (context, index, visible) {
                builds++;
                builtIndices.add(index);
                return ColoredBox(
                  key: ValueKey<String>('built-$index'),
                  color: Colors.white,
                );
              },
            ),
          ),
        ),
      ),
    );

    expect(builds, lessThan(10));
    key.currentState!.scrollBy(const Offset(0, 700000));
    await tester.pump();

    expect(builds, lessThan(20));
    expect(builtIndices.last, greaterThan(900));
    expect(find.byKey(const ValueKey<String>('built-0')), findsNothing);
  });
}
