import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/shared/widgets/dog_ear.dart';
import 'package:greatnote/shared/widgets/etonia_mark.dart';
import 'package:greatnote/shared/widgets/scene_transitions.dart';

double _luminance(Color color) {
  double channel(double value) => value <= 0.03928
      ? value / 12.92
      : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

double _contrast(Color a, Color b) {
  final double light = math.max(_luminance(a), _luminance(b));
  final double dark = math.min(_luminance(a), _luminance(b));
  return (light + 0.05) / (dark + 0.05);
}

/// How opaque the scene holding [text] is drawn.
double _opacityOf(WidgetTester tester, String text) => tester
    .widget<Opacity>(
      find.ancestor(of: find.text(text), matching: find.byType(Opacity)).first,
    )
    .opacity;

/// Nothing in a scene switch moves or grows: it only fades.
void _expectStill() {
  for (final Type moving in <Type>[Transform, FractionalTranslation]) {
    expect(
      find.descendant(
        of: find.byType(SceneCrossfade),
        matching: find.byType(moving),
      ),
      findsNothing,
    );
  }
}

/// Counts taps, to tell a kept state from a new one.
class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int _taps = 0;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => setState(() => _taps++),
    child: Text('$_taps'),
  );
}

Widget _app(Widget child, {bool reduced = false, bool dark = false}) {
  return MaterialApp(
    theme: dark ? AppTheme.dark() : AppTheme.light(),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  group('design palette', () {
    test('pins the light and dark brand and neutral roles', () {
      expect(AppColors.light.background, const Color(0xFFFAF9F7));
      expect(AppColors.light.backgroundSecondary, const Color(0xFFF3F2F0));
      expect(AppColors.light.surface, const Color(0xFFFFFFFF));
      expect(AppColors.light.writingSurface, const Color(0xFFFFFFFF));
      expect(AppColors.light.textPrimary, const Color(0xFF343239));
      expect(AppColors.light.divider, const Color(0xFFE9E6E9));
      expect(AppColors.light.borderStrong, const Color(0xFFD4CFD8));
      expect(AppColors.light.brandSubtle, const Color(0xFFF0EBF8));
      expect(AppColors.light.selected, const Color(0xFFEEE8F7));
      expect(AppColors.light.success, const Color(0xFF408B75));
      expect(AppColors.light.warning, const Color(0xFFB68036));
      expect(AppColors.light.danger, const Color(0xFFC45757));
      expect(AppColors.dark.background, const Color(0xFF1C1B20));
      expect(AppColors.dark.surface, const Color(0xFF2B2A31));
      expect(AppColors.dark.surfaceElevated, const Color(0xFF393740));
      expect(AppColors.dark.accent, const Color(0xFFB8A2DF));
      expect(AppColors.dark.focus, const Color(0xFFB8A2DF));
      // Layered charcoal, never pure black.
      expect(AppColors.dark.background, isNot(const Color(0xFF000000)));
      expect(AppColors.light.highlighters, hasLength(6));
      expect(AppColors.dark.highlighters, hasLength(6));
    });

    test('body and action pairs meet WCAG AA', () {
      for (final AppColors colors in <AppColors>[
        AppColors.light,
        AppColors.dark,
      ]) {
        expect(
          _contrast(colors.textPrimary, colors.background),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          _contrast(colors.textSecondary, colors.surface),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          _contrast(colors.accentText, colors.surface),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          _contrast(colors.onAccent, colors.accent),
          greaterThanOrEqualTo(4.5),
        );
        for (final Color ground in <Color>[
          colors.surface,
          colors.writingSurface,
        ]) {
          expect(
            _contrast(colors.textPrimary, ground),
            greaterThanOrEqualTo(4.5),
          );
        }
        for (final Color ring in <Color>[colors.accent, colors.focus]) {
          expect(_contrast(ring, colors.surface), greaterThanOrEqualTo(3));
        }
      }
    });

    test('selection and status colours stay readable', () {
      for (final AppColors colors in <AppColors>[
        AppColors.light,
        AppColors.dark,
      ]) {
        expect(
          _contrast(colors.textPrimary, colors.selected),
          greaterThanOrEqualTo(4.5),
          reason: 'text on a selected row',
        );
        expect(
          _contrast(colors.success, colors.surface),
          greaterThanOrEqualTo(3),
          reason: 'success status',
        );
        expect(
          _contrast(colors.danger, colors.surface),
          greaterThanOrEqualTo(3),
          reason: 'error status',
        );
      }
    });

    test('chrome stays in the warm neutral family', () {
      for (final AppColors colors in <AppColors>[
        AppColors.light,
        AppColors.dark,
      ]) {
        for (final Color neutral in <Color>[
          colors.background,
          colors.backgroundSecondary,
          colors.surface,
          colors.surfaceMuted,
          colors.surfaceElevated,
          colors.textSecondary,
          colors.divider,
        ]) {
          final HSVColor hsv = HSVColor.fromColor(neutral);
          // Warm paper and faintly violet charcoal: never a saturated hue.
          expect(hsv.saturation, lessThan(0.30));
          if (hsv.saturation > 0.04) {
            final double hue = hsv.hue;
            final bool cream = hue >= 20 && hue <= 60;
            final bool violet = hue >= 230 && hue <= 300;
            expect(cream || violet, isTrue, reason: 'hue $hue');
          }
        }
      }
    });
  });

  test('motion exposes the four springs and asymmetric fades', () {
    expect(AppMotion.snappy.duration, const Duration(milliseconds: 300));
    expect(AppMotion.smooth.duration, const Duration(milliseconds: 400));
    expect(AppMotion.bouncy.duration, const Duration(milliseconds: 450));
    expect(AppMotion.bouncy.bounce, closeTo(0.25, 0.001));
    expect(AppMotion.sheet.bounce, closeTo(0.05, 0.001));
    expect(AppMotion.fadeOut, lessThan(AppMotion.fadeIn));
    expect(AppMotion.reduced, const Duration(milliseconds: 120));
  });

  test('theme uses restrained corners and continuous floating shapes', () {
    final ThemeData theme = AppTheme.light();
    final ShapeBorder button = theme.filledButtonTheme.style!.shape!.resolve(
      <WidgetState>{},
    )!;
    expect(button, isNot(isA<StadiumBorder>()));
    expect(button, isA<RoundedRectangleBorder>());
    expect(theme.dialogTheme.shape, isA<RoundedSuperellipseBorder>());
    expect(theme.cardTheme.shape, isA<RoundedSuperellipseBorder>());
    expect(AppRadii.small, 8);
    expect(AppRadii.medium, 12);
    expect(AppRadii.large, 16);
    expect(AppRadii.xl, 22);
  });

  testWidgets('tinted glass never creates a live backdrop filter', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const GlassSurface(
          quality: GlassQuality.tinted,
          borderRadius: AppBorderRadius.glass,
          child: SizedBox.square(dimension: 80),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(ClipRSuperellipse), findsOneWidget);
  });

  testWidgets('even full-quality surfaces are opaque and never blur', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const GlassSurface(
          quality: GlassQuality.full,
          child: SizedBox.square(dimension: 40),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('dog-ear cuts only the trailing top and uses the flap color', (
    WidgetTester tester,
  ) async {
    const Color flap = Color(0xFFFFE45C);
    await tester.pumpWidget(
      _app(
        const SizedBox(
          width: 100,
          height: 120,
          child: DogEar(flapColor: flap, child: SizedBox.expand()),
        ),
      ),
    );
    final DogEarPainter painter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((CustomPaint paint) => paint.foregroundPainter)
        .whereType<DogEarPainter>()
        .single;
    expect(painter.flapColor, flap);
    final Path clip = const DogEarClipper(
      textDirection: TextDirection.ltr,
    ).getClip(const Size(100, 120));
    expect(clip.contains(const Offset(30, 30)), isTrue);
    expect(clip.contains(const Offset(98, 2)), isFalse);
    expect(clip.contains(const Offset(90, 100)), isTrue);
    expect(clip.contains(const Offset(10, 60)), isTrue);
  });

  testWidgets('reduced scene changes use opacity without travel', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(const SceneCrossfade(scope: 1, child: Text('one')), reduced: true),
    );
    await tester.pumpWidget(
      _app(const SceneCrossfade(scope: 2, child: Text('two')), reduced: true),
    );
    await tester.pump(AppMotion.reduced ~/ 2);
    // Both scenes are part faded, and neither moves or grows.
    for (final String text in <String>['one', 'two']) {
      expect(_opacityOf(tester, text), inExclusiveRange(0, 1));
    }
    _expectStill();
    await tester.pump(AppMotion.reduced);
    expect(find.text('one'), findsNothing);
    expect(find.text('two'), findsOneWidget);
  });

  testWidgets('a folder switch is a quick fade, without zoom or drift', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const SceneCrossfade(scope: 1, child: Text('library')),
        reduced: false,
      ),
    );
    await tester.pumpWidget(
      _app(
        const SceneCrossfade(
          scope: 2,
          pace: MotionPace.first,
          child: Text('folder'),
        ),
        reduced: false,
      ),
    );
    await tester.pump(AppMotion.fadeOut ~/ 2);
    expect(_opacityOf(tester, 'library'), inExclusiveRange(0, 1));
    expect(_opacityOf(tester, 'folder'), inExclusiveRange(0, 1));
    _expectStill();
    // Quick: over within the content fade, even on a first visit.
    await tester.pump(AppMotion.fadeIn);
    expect(find.text('library'), findsNothing);
    expect(_opacityOf(tester, 'folder'), 1);
  });

  testWidgets('a scene keeps its state as it leaves', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(const SceneCrossfade(scope: 1, child: _Counter()), reduced: false),
    );
    await tester.tap(find.byType(_Counter));
    await tester.pump();
    expect(find.text('1'), findsOneWidget);
    await tester.pumpWidget(
      _app(const SceneCrossfade(scope: 2, child: Text('next')), reduced: false),
    );
    await tester.pump(AppMotion.fadeOut ~/ 4);
    // Still the same counter, leaving, not a new one.
    expect(find.text('1'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('a revisit fades in with a glance', (WidgetTester tester) async {
    await tester.pumpWidget(
      _app(const SceneCrossfade(scope: 1, child: Text('scene 1'))),
    );
    await tester.pumpWidget(
      _app(
        const SceneCrossfade(
          scope: 2,
          pace: MotionPace.revisit,
          child: Text('scene 2'),
        ),
        reduced: false,
      ),
    );
    await tester.pump(AppMotion.glance ~/ 3);
    expect(_opacityOf(tester, 'scene 2'), inExclusiveRange(0, 1));
    _expectStill();
    await tester.pump(AppMotion.glance);
    expect(find.text('scene 1'), findsNothing);
  });

  testWidgets('mark and branded loader are vector widgets', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[EtoniaMark(size: 48), EtoniaBarsLoader(size: 48)],
        ),
        reduced: true,
      ),
    );
    expect(find.byType(CustomPaint), findsAtLeastNWidgets(2));
    expect(tester.hasRunningAnimations, isFalse);
  });
}
