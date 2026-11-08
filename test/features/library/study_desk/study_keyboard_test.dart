import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/library/study_desk/study_keyboard.dart';

void main() {
  Widget window(double keyboard, Widget child) => MediaQuery(
    data: MediaQueryData(
      size: const Size(400, 800),
      viewInsets: EdgeInsets.only(bottom: keyboard),
      viewPadding: const EdgeInsets.only(bottom: 20),
      // What the platform reports: the safe area the keyboard has not yet
      // covered.
      padding: EdgeInsets.only(bottom: keyboard >= 20 ? 0 : 20 - keyboard),
    ),
    child: Directionality(textDirection: TextDirection.ltr, child: child),
  );

  testWidgets('the desk is not built or resized again as the keyboard rises, '
      'and only what is lifted follows it', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    int builds = 0;
    final List<EdgeInsets> seenInsets = <EdgeInsets>[];
    final List<EdgeInsets> seenPadding = <EdgeInsets>[];
    final GlobalKey desk = GlobalKey();
    final GlobalKey lifted = GlobalKey();
    // One instance, as the desk is: the framework skips what it is handed
    // again unchanged.
    final Widget below = Builder(
      builder: (BuildContext context) {
        builds++;
        seenInsets.add(MediaQuery.viewInsetsOf(context));
        seenPadding.add(MediaQuery.paddingOf(context));
        return const SizedBox.expand();
      },
    );
    final Widget scope = StudyKeyboardScope(
      child: Column(
        children: <Widget>[
          Expanded(
            key: desk,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: StudyKeyboardLift(
                child: SizedBox(key: lifted, height: 10, child: below),
              ),
            ),
          ),
        ],
      ),
    );

    await tester.pumpWidget(window(0, scope));
    final Size resting = tester.getSize(find.byKey(desk));
    expect(builds, 1);

    // Each frame of the slide, up past the safe area and on.
    for (final double keyboard in <double>[10, 60, 150, 300, 336]) {
      await tester.pumpWidget(window(keyboard, scope));
      expect(
        tester.getSize(find.byKey(desk)),
        resting,
        reason: 'the desk keeps its size at $keyboard',
      );
    }
    expect(builds, 1, reason: 'nothing below the scope is built for it');
    // It saw a window with no keyboard, and all of its safe area, throughout.
    expect(seenInsets.single, EdgeInsets.zero);
    expect(seenPadding.single, const EdgeInsets.only(bottom: 20));

    // The lift is what the keyboard covers past the safe area, and it goes
    // when the keyboard does.
    final double lift =
        tester.getBottomLeft(find.byKey(desk)).dy -
        tester.getBottomLeft(find.byKey(lifted)).dy;
    expect(lift, closeTo(336 - 20, .01));
    await tester.pumpWidget(window(0, scope));
    expect(
      tester.getBottomLeft(find.byKey(desk)).dy -
          tester.getBottomLeft(find.byKey(lifted)).dy,
      closeTo(0, .01),
    );
    expect(builds, 1);
  });

  testWidgets('without the scope the lift is nothing', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      window(
        300,
        const Align(
          alignment: Alignment.bottomCenter,
          child: StudyKeyboardLift(child: SizedBox(height: 10, width: 10)),
        ),
      ),
    );
    expect(tester.getBottomLeft(find.byType(SizedBox).last).dy, 800);
  });
}
