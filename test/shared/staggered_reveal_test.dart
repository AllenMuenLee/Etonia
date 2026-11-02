import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/shared/motion/motion_memory.dart';
import 'package:greatnote/shared/widgets/staggered_reveal.dart';

const int _items = 20;

Widget _app({required bool loaded, bool reduced = false, Object? key}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: StaggeredReveal(
        semanticsLabel: 'Loading',
        memoryKey: key,
        child: loaded
            ? Column(
                children: <Widget>[
                  for (int i = 0; i < _items; i++)
                    StaggerItem(index: i, child: Text('item $i')),
                ],
              )
            : null,
      ),
    ),
  );
}

double _opacityOf(WidgetTester tester, int index) {
  final FadeTransition fade = tester.widget<FadeTransition>(
    find
        .ancestor(
          of: find.text('item $index'),
          matching: find.byType(FadeTransition),
        )
        .first,
  );
  return fade.opacity.value;
}

void main() {
  setUp(MotionMemory.instance.reset);

  testWidgets('loaded items fade in one after another', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app(loaded: false, key: 'list'));
    expect(find.textContaining('item'), findsNothing);
    expect(MotionMemory.instance.hasSeen('list'), isFalse);

    await tester.pumpWidget(_app(loaded: true, key: 'list'));
    expect(MotionMemory.instance.hasSeen('list'), isTrue);
    // Nothing is in yet as the run starts.
    expect(_opacityOf(tester, 0), 0);

    // The first item is on its way in while later ones still wait.
    await tester.pump(AppMotion.staggerLead + AppMotion.staggerStep);
    expect(_opacityOf(tester, 0), greaterThan(0));
    expect(_opacityOf(tester, 5), 0);
    expect(_opacityOf(tester, 0), greaterThan(_opacityOf(tester, 1)));

    // Each item has come further than the one after it.
    await tester.pump(AppMotion.staggerStep * 4);
    for (int i = 0; i < 5; i++) {
      expect(_opacityOf(tester, i), greaterThan(_opacityOf(tester, i + 1)));
    }

    await tester.pumpAndSettle();
    for (int i = 0; i < _items; i++) {
      expect(_opacityOf(tester, i), 1);
    }
  });

  testWidgets('items past the stagger count arrive with the last', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app(loaded: true));
    await tester.pump(
      AppMotion.staggerLead +
          AppMotion.staggerStep * (AppMotion.staggerCount - 1) +
          AppMotion.fadeIn ~/ 2,
    );
    final double last = _opacityOf(tester, AppMotion.staggerCount - 1);
    expect(last, inExclusiveRange(0, 1));
    expect(_opacityOf(tester, _items - 1), last);
    await tester.pumpAndSettle();
  });

  testWidgets('a list read again in place does not replay', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app(loaded: true));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_app(loaded: true));
    expect(_opacityOf(tester, _items - 1), 1);
  });

  testWidgets('reduced motion fades every item in together', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app(loaded: true, reduced: true));
    await tester.pump(AppMotion.reduced ~/ 2);
    expect(_opacityOf(tester, 0), inExclusiveRange(0, 1));
    expect(_opacityOf(tester, _items - 1), _opacityOf(tester, 0));
    await tester.pump(AppMotion.reduced);
    expect(_opacityOf(tester, _items - 1), 1);
  });
}
