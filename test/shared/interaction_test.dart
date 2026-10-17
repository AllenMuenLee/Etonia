import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/shared/feedback/app_haptics.dart';
import 'package:greatnote/shared/widgets/pressable.dart';
import 'package:greatnote/shared/widgets/processing.dart';

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

double _scaleOf(WidgetTester tester) {
  final Transform transform = tester.widget<Transform>(
    find
        .descendant(
          of: find.byType(Pressable),
          matching: find.byType(Transform),
        )
        .first,
  );
  // The x scale; z stays 1.
  return transform.transform.storage[0];
}

void main() {
  final List<AppHaptic> played = <AppHaptic>[];

  setUp(() {
    played.clear();
    AppHaptics.performer = (AppHaptic haptic) async => played.add(haptic);
  });
  tearDown(AppHaptics.reset);

  group('haptics', () {
    test('play through the performer, unless turned off', () {
      AppHaptics.toolSwitch();
      AppHaptics.success();
      AppHaptics.enabled = false;
      AppHaptics.error();
      expect(played, <AppHaptic>[AppHaptic.toolSwitch, AppHaptic.success]);
    });

    test('a failing platform is not an error', () async {
      AppHaptics.performer = (AppHaptic haptic) async => throw StateError('x');
      AppHaptics.tap();
      await Future<void>.delayed(Duration.zero);
    });

    testWidgets('switching tools ticks once per switch', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);
      await tester.tap(find.byTooltip('Eraser'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Select'));
      await tester.pumpAndSettle();
      expect(played, <AppHaptic>[AppHaptic.toolSwitch, AppHaptic.toolSwitch]);
    });
  });

  group('Pressable', () {
    testWidgets('sinks while pressed and springs back on release', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _themed(
          const Pressable(
            child: ColoredBox(
              color: Color(0xFF6164F1),
              child: SizedBox.square(dimension: 48),
            ),
          ),
        ),
      );
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.byType(Pressable)),
      );
      await tester.pumpAndSettle();
      expect(_scaleOf(tester), moreOrLessEquals(AppMotion.pressedScale));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(_scaleOf(tester), moreOrLessEquals(1));
    });

    testWidgets('holds still under reduced motion, or when disabled', (
      WidgetTester tester,
    ) async {
      for (final (bool reduce, bool enabled) in <(bool, bool)>[
        (true, true),
        (false, false),
      ]) {
        await tester.pumpWidget(
          _themed(
            Pressable(
              enabled: enabled,
              child: const ColoredBox(
                color: Color(0xFF6164F1),
                child: SizedBox.square(dimension: 48),
              ),
            ),
            reduceMotion: reduce,
          ),
        );
        final TestGesture gesture = await tester.startGesture(
          tester.getCenter(find.byType(Pressable)),
        );
        await tester.pump(AppMotion.press);
        expect(_scaleOf(tester), 1);
        await gesture.up();
        await tester.pumpAndSettle();
      }
    });
  });

  group('processing', () {
    testWidgets('the track reports progress to screen readers', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _themed(
          const SizedBox(
            width: 200,
            child: ShimmerTrack(value: 0.25, semanticsLabel: 'Exporting'),
          ),
        ),
      );
      await tester.pump(AppMotion.shimmer);
      expect(
        tester.getSemantics(find.byType(ShimmerTrack)),
        matchesSemantics(label: 'Exporting', value: '25%'),
      );
    });

    testWidgets('indicators settle under reduced motion', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _themed(
          const Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(width: 200, child: ShimmerTrack()),
              SizedBox.square(dimension: 80, child: ShimmerPlaceholder()),
              AmbientGlow(active: true, child: SizedBox.square(dimension: 40)),
            ],
          ),
          reduceMotion: true,
        ),
      );
      // Nothing loops, so the frame settles.
      await tester.pumpAndSettle();
    });

    testWidgets('the glow keeps its child when it turns off', (
      WidgetTester tester,
    ) async {
      final GlobalKey key = GlobalKey();
      Widget glow(bool active) => _themed(
        AmbientGlow(
          active: active,
          child: SizedBox.square(key: key, dimension: 40),
        ),
      );
      await tester.pumpWidget(glow(true));
      await tester.pump(AppMotion.pulse);
      final Element before = key.currentContext! as Element;
      await tester.pumpWidget(glow(false));
      await tester.pumpAndSettle();
      expect(key.currentContext, same(before));
    });
  });

  test('glass and canvas tokens follow the style guide', () {
    const AppColors light = AppColors.light;
    expect(light.background, const Color(0xFFF9FAFB));
    expect(light.textPrimary, const Color(0xFF0F172A));
    expect(AppGlass.surface(light).a, moreOrLessEquals(0.70));
    expect(light.glassEdge.a, moreOrLessEquals(0.40, epsilon: 0.01));
    expect(GlassBackdrop.spacing, 20);
    for (final double space in <double>[
      AppSpacing.xxs,
      AppSpacing.xs,
      AppSpacing.sm,
      AppSpacing.md,
      AppSpacing.lg,
      AppSpacing.xl,
      AppSpacing.xxl,
    ]) {
      expect(space % 4, 0);
    }
  });
}
