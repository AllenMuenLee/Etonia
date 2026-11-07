import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/library/study_desk/study_motion.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int taps = 0;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => taps++),
    child: Text('taps $taps'),
  );
}

void main() {
  setUp(() => StudyMotionLedger.instance.reset());

  test('the ledger plays a key once and forgets the longest unused', () {
    final StudyMotionLedger ledger = StudyMotionLedger.instance;
    expect(ledger.claim('a'), isTrue);
    expect(ledger.claim('a'), isFalse);
    for (int i = 0; i < StudyMotionLedger.capacity; i++) {
      ledger.claim('k$i');
    }
    expect(ledger.length, StudyMotionLedger.capacity);
    expect(ledger.hasPlayed('a'), isFalse);
    expect(ledger.claim('a'), isTrue);
  });

  testWidgets('an arrival fades in, settles, and is not wrapped again', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const StudyAppear(once: 'x', child: Text('hello'))),
    );
    final Finder fade = find.descendant(
      of: find.byType(StudyAppear),
      matching: find.byType(FadeTransition),
    );
    expect(fade, findsOneWidget);
    expect(tester.widget<FadeTransition>(fade).opacity.value, 0);
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.widget<FadeTransition>(fade).opacity.value, greaterThan(0));
    await tester.pumpAndSettle();
    expect(tester.widget<FadeTransition>(fade).opacity.value, 1);

    // Seen already: nothing around it, so nothing to composite.
    await tester.pumpWidget(
      _host(const StudyAppear(key: Key('again'), once: 'x', child: Text('hi'))),
    );
    expect(
      find.descendant(
        of: find.byType(StudyAppear),
        matching: find.byType(FadeTransition),
      ),
      findsNothing,
    );
  });

  testWidgets('a replay plays the same widget in again, in place', (
    tester,
  ) async {
    Widget build(Object key) => _host(
      StudyAppear(
        playOnMount: false,
        replayKey: key,
        child: const Text('page'),
      ),
    );
    await tester.pumpWidget(build('a'));
    final Finder fade = find.descendant(
      of: find.byType(StudyAppear),
      matching: find.byType(FadeTransition),
    );
    expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
    await tester.pumpWidget(build('b'));
    expect(tester.widget<FadeTransition>(fade).opacity.value, 0);
    await tester.pumpAndSettle();
    expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
  });

  testWidgets('reduced motion fades without moving', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: const Scaffold(body: StudyAppear(child: Text('hello'))),
        ),
      ),
    );
    final Finder moved = find.descendant(
      of: find.byType(StudyAppear),
      matching: find.byType(Transform),
    );
    expect(
      tester.widget<Transform>(moved).transform.getTranslation().y,
      0,
      reason: 'it only fades',
    );
    await tester.pumpAndSettle();
  });

  testWidgets('a presence keeps what left until it has gone, then lets go', (
    tester,
  ) async {
    Widget build(Widget? child) => _host(StudyPresence(child: child));
    await tester.pumpWidget(build(const Text('pane')));
    expect(find.text('pane'), findsOneWidget);
    await tester.pumpWidget(build(null));
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.text('pane'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('pane'), findsNothing);
    await tester.pumpWidget(build(const Text('pane')));
    await tester.pumpAndSettle();
    expect(find.text('pane'), findsOneWidget);
  });

  testWidgets('scenes keep their state and only the one in view is live', (
    tester,
  ) async {
    Widget build(int index) => _host(
      StudyScenes(
        index: index,
        children: const <Widget>[_Counter(), Text('other')],
      ),
    );
    await tester.pumpWidget(build(0));
    await tester.tap(find.text('taps 0'));
    await tester.pump();
    expect(find.text('taps 1'), findsOneWidget);

    await tester.pumpWidget(build(1));
    await tester.pumpAndSettle();
    expect(find.text('taps 1'), findsNothing);
    expect(find.text('taps 1', skipOffstage: false), findsOneWidget);
    expect(find.text('other'), findsOneWidget);

    await tester.pumpWidget(build(0));
    await tester.pumpAndSettle();
    expect(find.text('taps 1'), findsOneWidget);
  });

  testWidgets('a throttled builder follows at once, then coalesces', (
    tester,
  ) async {
    final ValueNotifier<int> value = ValueNotifier<int>(0);
    int builds = 0;
    await tester.pumpWidget(
      _host(
        StudyThrottledBuilder(
          listenable: value,
          coalesce: () => true,
          builder: (BuildContext context) {
            builds++;
            return Text('v${value.value}');
          },
        ),
      ),
    );
    expect(builds, 1);
    value.value = 1;
    await tester.pump();
    expect(find.text('v1'), findsOneWidget);
    expect(builds, 2);
    for (int i = 2; i < 12; i++) {
      value.value = i;
    }
    await tester.pump();
    expect(builds, 2, reason: 'held back inside the gap');
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('v11'), findsOneWidget);
    expect(builds, 3, reason: 'the last change is never lost');
  });
}
