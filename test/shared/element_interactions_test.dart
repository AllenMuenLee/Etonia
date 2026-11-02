import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/shared/widgets/app_controls.dart';
import 'package:greatnote/shared/widgets/pressable.dart';

import '../helpers/pump_app.dart';

Widget _themed(Widget child, {bool reduceMotion = false}) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Scaffold(body: Center(child: child)),
    ),
  );
}

double _pressedScale(WidgetTester tester) {
  return tester
      .widget<Transform>(
        find
            .descendant(
              of: find.byType(Pressable),
              matching: find.byType(Transform),
            )
            .first,
      )
      .transform
      .storage[0];
}

void main() {
  group('press feedback', () {
    testWidgets('is visible on the very next frame after touch-down', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _themed(
          const Pressable(
            type: PressableType.icon,
            child: SizedBox.square(dimension: 48),
          ),
        ),
      );
      expect(_pressedScale(tester), 1);
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.byType(Pressable)),
      );
      // One frame, not an animation: the control already looks pressed.
      await tester.pump();
      expect(
        _pressedScale(tester),
        moreOrLessEquals(AppMotion.iconPressedScale),
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(_pressedScale(tester), moreOrLessEquals(1));
    });

    testWidgets('a disabled control neither scales nor responds', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _themed(
          const Pressable(
            enabled: false,
            child: SizedBox.square(dimension: 48),
          ),
        ),
      );
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.byType(Pressable)),
      );
      await tester.pump();
      expect(_pressedScale(tester), 1);
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('release after the control has gone is harmless', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _themed(const Pressable(child: SizedBox.square(dimension: 48))),
      );
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.byType(Pressable)),
      );
      await tester.pump();
      await tester.pumpWidget(_themed(const SizedBox()));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('selection capsule', () {
    testWidgets('lands on the segment that was tapped', (
      WidgetTester tester,
    ) async {
      String choice = 'a';
      await tester.pumpWidget(
        _themed(
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              return SizedBox(
                width: 300,
                child: SegmentedChoice<String>(
                  options: const <String>['a', 'b', 'c'],
                  selected: choice,
                  labelOf: (String o) => o,
                  onSelected: (String o) => setState(() => choice = o),
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('c'));
      await tester.pump();
      await tester.pump(AppMotion.snappy.duration);
      await tester.pumpAndSettle();
      final Rect capsule = tester.getRect(
        find.descendant(
          of: find.byType(SelectionCapsule),
          matching: find.byType(DecoratedBox),
        ),
      );
      final Rect segment = tester.getRect(find.text('c'));
      expect(capsule.center.dx, closeTo(segment.center.dx, 2));
    });

    testWidgets('moves in one frame under reduced motion', (
      WidgetTester tester,
    ) async {
      Widget build(int index) => _themed(
        SizedBox(
          width: 300,
          height: 40,
          child: SelectionCapsule(index: index, count: 3),
        ),
        reduceMotion: true,
      );
      await tester.pumpWidget(build(0));
      await tester.pumpWidget(build(2));
      final Rect capsule = tester.getRect(find.byType(DecoratedBox).last);
      final Rect track = tester.getRect(find.byType(SelectionCapsule));
      expect(capsule.left - track.left, closeTo(200, 1));
    });
  });

  group('slider', () {
    testWidgets('takes the value straight from the finger', (
      WidgetTester tester,
    ) async {
      double value = 0;
      await tester.pumpWidget(
        _themed(
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              return SizedBox(
                width: 320,
                child: AppSlider(
                  value: value,
                  onChanged: (double v) => setState(() => value = v),
                ),
              );
            },
          ),
        ),
      );
      final Rect track = tester.getRect(find.byType(Slider));
      // Tapping three quarters along the usable track sets that value at
      // once, with no easing in between.
      await tester.tapAt(
        Offset(track.left + track.width * 0.75, track.center.dy),
      );
      expect(value, closeTo(0.75, 0.08));
    });
  });

  group('error and rolling number', () {
    testWidgets('Shake nudges six points sideways and settles', (
      WidgetTester tester,
    ) async {
      Widget build(Object? token) => _themed(
        Shake(
          errorToken: token,
          playHaptic: false,
          child: const SizedBox.square(dimension: 40, key: Key('field')),
        ),
      );
      await tester.pumpWidget(build(null));
      final double rest = tester.getTopLeft(find.byKey(const Key('field'))).dx;
      await tester.pumpWidget(build(1));
      await tester.pump();
      await tester.pump(AppMotion.errorShake * 0.1);
      final double moved = tester.getTopLeft(find.byKey(const Key('field'))).dx;
      expect((moved - rest).abs(), greaterThan(0.5));
      expect((moved - rest).abs(), lessThanOrEqualTo(6));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byKey(const Key('field'))).dx, rest);
    });

    testWidgets('a changing number rolls, but only fades when reduced', (
      WidgetTester tester,
    ) async {
      Widget build(int n, bool reduced) =>
          _themed(RollingNumber(n), reduceMotion: reduced);
      await tester.pumpWidget(build(1, false));
      await tester.pumpWidget(build(2, false));
      await tester.pump(AppMotion.snappy.duration ~/ 3);
      expect(
        find.descendant(
          of: find.byType(RollingNumber),
          matching: find.byType(SlideTransition),
        ),
        findsWidgets,
      );
      await tester.pumpAndSettle();

      await tester.pumpWidget(build(3, true));
      await tester.pump(AppMotion.reduced ~/ 3);
      expect(
        find.descendant(
          of: find.byType(RollingNumber),
          matching: find.byType(SlideTransition),
        ),
        findsNothing,
      );
      await tester.pumpAndSettle();
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('the check draws on from nothing', (WidgetTester tester) async {
      Widget build(bool selected) => _themed(
        SizedBox.square(
          dimension: 24,
          child: StrokeDrawCheck(selected: selected),
        ),
      );
      await tester.pumpWidget(build(false));
      await tester.pumpWidget(build(true));
      await tester.pump();
      await tester.pump(AppMotion.checkDraw ~/ 2);
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('tool palette', () {
    testWidgets(
      'the capsule fades across to the tapped tool, without sliding',
      (WidgetTester tester) async {
        await pumpApp(tester);
        Finder capsule(int index) => find.byType(SelectionCapsule).at(index);
        double center(int index) => tester
            .getRect(
              find.descendant(
                of: capsule(index),
                matching: find.byType(DecoratedBox),
              ),
            )
            .center
            .dx;
        double opacity(int index) => tester
            .widget<FadeTransition>(
              find
                  .ancestor(
                    of: capsule(index),
                    matching: find.byType(FadeTransition),
                  )
                  .first,
            )
            .opacity
            .value;

        final Rect pen = tester.getRect(find.byTooltip('Pen'));
        await tester.tap(find.byTooltip('Eraser'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        final Rect eraser = tester.getRect(find.byTooltip('Eraser'));

        // The last tool's capsule leaves where it was as the new one arrives.
        expect(find.byType(SelectionCapsule), findsNWidgets(2));
        expect(center(0), closeTo(pen.center.dx, 1));
        expect(center(1), closeTo(eraser.center.dx, 1));
        expect(opacity(0), greaterThan(0));
        expect(opacity(0), lessThan(1));
        expect(opacity(1), greaterThan(0));
        expect(opacity(1), lessThan(1));
        expect(
          tester.widget<SelectionCapsule>(capsule(1)).decoration,
          isNull,
          reason: 'the chosen tool sits on the plain accent fill',
        );

        await tester.pumpAndSettle();
        expect(find.byType(SelectionCapsule), findsOneWidget);
        expect(center(0), closeTo(eraser.center.dx, 1));
        expect(opacity(0), 1);
      },
    );
  });
}
