import 'dart:collection';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/page/page_viewport.dart';

class _CountingPages extends ListBase<PageGeometry> {
  _CountingPages(this.count);
  final int count;
  int reads = 0;
  @override
  int get length => count;
  @override
  set length(int value) => throw UnsupportedError('read only');
  @override
  PageGeometry operator [](int index) {
    reads++;
    return const PageGeometry(Size(500, 700), 1);
  }

  @override
  void operator []=(int index, PageGeometry value) =>
      throw UnsupportedError('read only');
}

void main() {
  testWidgets(
    'pinch updates inspect nearby pages instead of the full document',
    (WidgetTester tester) async {
      final _CountingPages pages = _CountingPages(10000);
      await tester.pumpWidget(
        GreatnoteApp(
          home: SizedBox(
            width: 800,
            height: 600,
            child: PageViewport(
              pages: pages,
              pageKeys: <Key>[
                for (int i = 0; i < pages.length; i++) ValueKey<int>(i),
              ],
              currentPage: 0,
              pageBuilder: (_, _, _) => const SizedBox.expand(),
            ),
          ),
        ),
      );
      pages.reads = 0;
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
      await tester.pump();
      expect(pages.reads, lessThan(250));
      await left.up();
      await right.up();
      await tester.pump();
    },
  );

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
