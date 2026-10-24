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
  group('ink and paper palette', () {
    test('pins the logo-derived light and dark roles', () {
      expect(AppColors.light.background, const Color(0xFFF2F2F4));
      expect(AppColors.light.accent, const Color(0xFF0A0A0B));
      expect(AppColors.dark.background, const Color(0xFF000000));
      expect(AppColors.dark.accent, const Color(0xFFFFFFFF));
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
          _contrast(colors.onAccent, colors.accent),
          greaterThanOrEqualTo(4.5),
        );
      }
    });

    test('neutral chrome has no meaningful hue', () {
      for (final AppColors colors in <AppColors>[
        AppColors.light,
        AppColors.dark,
      ]) {
        for (final Color neutral in <Color>[
          colors.background,
          colors.surface,
          colors.surfaceMuted,
          colors.writingSurface,
          colors.textPrimary,
          colors.textSecondary,
          colors.accent,
          colors.onAccent,
        ]) {
          expect(HSLColor.fromColor(neutral).saturation, lessThan(0.12));
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

  test('theme uses capsules and continuous floating corners', () {
    final ThemeData theme = AppTheme.light();
    expect(
      theme.filledButtonTheme.style!.shape!.resolve(<WidgetState>{}),
      isA<StadiumBorder>(),
    );
    expect(theme.dialogTheme.shape, isA<RoundedSuperellipseBorder>());
    expect(theme.cardTheme.shape, isA<RoundedSuperellipseBorder>());
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

  testWidgets('full glass shares a grouped backdrop and stays under budget', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(
        BackdropGroup(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (int i = 0; i < 3; i++)
                const GlassSurface(
                  quality: GlassQuality.full,
                  child: SizedBox.square(dimension: 40),
                ),
            ],
          ),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNWidgets(3));
  });

  testWidgets('dog-ear cuts only the trailing top and uses the flap color', (
    WidgetTester tester,
  ) async {
    const Color flap = Color(0xFFFFE66D);
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
    final Finder scene = find.byType(SceneCrossfade);
    expect(
      find.descendant(of: scene, matching: find.byType(FadeTransition)),
      findsWidgets,
    );
    expect(
      find.descendant(of: scene, matching: find.byType(SlideTransition)),
      findsNothing,
    );
    await tester.pump(AppMotion.reduced);
    expect(find.text('two'), findsOneWidget);
  });

  testWidgets('entering a folder zooms in, leaving it zooms back out', (
    WidgetTester tester,
  ) async {
    double scaleOf(String text) {
      final Finder scale = find.ancestor(
        of: find.text(text),
        matching: find.byType(ScaleTransition),
      );
      return tester.widget<ScaleTransition>(scale.first).scale.value;
    }

    await tester.pumpWidget(
      _app(
        const SceneCrossfade(scope: 1, child: Text('library')),
        reduced: false,
      ),
    );
    await tester.pumpWidget(
      _app(
        const SceneCrossfade(scope: 2, direction: 1, child: Text('folder')),
        reduced: false,
      ),
    );
    await tester.pump(AppMotion.zoom ~/ 4);
    // The folder grows toward full size while the library passes the viewer.
    expect(scaleOf('folder'), inInclusiveRange(AppMotion.zoomFar, 1));
    expect(scaleOf('library'), inInclusiveRange(1, AppMotion.zoomNear));
    await tester.pumpAndSettle();
    expect(find.text('library'), findsNothing);
    expect(scaleOf('folder'), 1);

    await tester.pumpWidget(
      _app(
        const SceneCrossfade(scope: 3, direction: -1, child: Text('library')),
        reduced: false,
      ),
    );
    await tester.pump(AppMotion.zoom ~/ 4);
    expect(scaleOf('library'), inInclusiveRange(1, AppMotion.zoomNear));
    expect(scaleOf('folder'), inInclusiveRange(AppMotion.zoomFar, 1));
    await tester.pumpAndSettle();
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
