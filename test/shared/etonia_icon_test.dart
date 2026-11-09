import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_icons.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/shared/widgets/line_icon_map.dart';

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.light(),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  test('every glyph names an SVG that exists, drawn on a 24 grid', () {
    for (final String asset in EtoniaGlyphs.assets) {
      final File file = File('assets/icons/$asset.svg');
      expect(file.existsSync(), isTrue, reason: asset);
      final String svg = file.readAsStringSync();
      expect(svg, contains('viewBox="0 0 24 24"'), reason: asset);
      expect(svg, contains('stroke="currentColor"'), reason: asset);
      expect(svg, contains('stroke-linecap="round"'), reason: asset);
      expect(svg, contains('stroke-linejoin="round"'), reason: asset);
      expect(svg, isNot(contains('#000')), reason: asset);
      // Rounded geometry: a path that closes into a shape, or that bends
      // part-way along (an L after an L that turns), has curved corners.
      for (final RegExpMatch path in RegExp(r' d="([^"]*)"').allMatches(svg)) {
        final String d = path.group(1)!;
        final bool closed = d.contains('Z');
        final int segments = RegExp('L').allMatches(d).length;
        if (closed || segments > 1) {
          expect(d, contains('Q'), reason: '$asset has a sharp corner: $d');
        }
      }
    }
  });

  test('app icons resolve to their SVG', () {
    expect(EtoniaGlyphs.assetOf(AppIcons.back), 'navigation/back');
    expect(EtoniaGlyphs.assetOf(AppIcons.trash), 'library/trash');
    expect(LineIcons.assetOf(AppIcons.microphone), 'system/mic');
    expect(LineIcons.assetOf(Icons.zoom_in_rounded), 'system/zoom_in');
    expect(LineIcons.assetOf(Icons.abc), isNull);
  });

  test('every line drawing of a font glyph exists, at the one line weight', () {
    for (final String asset in <String>[
      ...LineIcons.assets,
      ...EtoniaGlyphs.assets,
    ]) {
      final File file = File('assets/icons/$asset.svg');
      expect(file.existsSync(), isTrue, reason: asset);
      final String svg = file.readAsStringSync();
      expect(svg, contains('viewBox="0 0 24 24"'), reason: asset);
      expect(svg, contains('stroke="currentColor"'), reason: asset);
      expect(svg, contains('stroke-width="1.3"'), reason: asset);
      expect(svg, contains('stroke-linecap="round"'), reason: asset);
      expect(svg, contains('stroke-linejoin="round"'), reason: asset);
      expect(svg, isNot(contains('#000')), reason: asset);
    }
  });

  test('every icon is drawn with the same 1.3px line', () {
    expect(kIconStrokeWidth, 1.3);
  });

  testWidgets('AppIcon draws an SVG tinted by the icon theme', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const IconTheme(
          data: IconThemeData(color: Color(0xFF123456), size: 30),
          child: AppIcon(AppIcons.check),
        ),
      ),
    );
    expect(find.byIcon(AppIcons.check), findsOneWidget);
    final SvgPicture picture = tester.widget<SvgPicture>(
      find.byType(SvgPicture),
    );
    expect(picture.width, 30);
    expect(
      picture.colorFilter,
      const ColorFilter.mode(Color(0xFF123456), BlendMode.srcIn),
    );
  });

  testWidgets('every AppIcon is one size and the quiet color, whatever it asks', (
    WidgetTester tester,
  ) async {
    final AppColors colors = AppColors.light;
    await tester.pumpWidget(
      _app(
        Column(
          children: <Widget>[
            AppIcon(AppIcons.check, size: 14, color: colors.accent),
            AppIcon(AppIcons.trash, size: 18, color: colors.danger),
            const AppIcon(AppIcons.search),
            // A color the user picked stays.
            const AppIcon(AppIcons.folder, size: 16, color: Color(0xFF123456)),
            // The tab's close button keeps its own size and color.
            AppIcon(
              AppIcons.close,
              size: 16,
              color: colors.accent,
              uniform: false,
            ),
            // The chat glyph has a line drawing like the rest.
            const AppIcon(AppIcons.chat),
          ],
        ),
      ),
    );
    final List<SvgPicture> pictures = tester
        .widgetList<SvgPicture>(find.byType(SvgPicture))
        .toList();
    expect(pictures, hasLength(6));
    for (final int i in <int>[0, 1, 2, 5]) {
      expect(pictures[i].width, kIconSize, reason: 'icon $i');
      expect(
        pictures[i].colorFilter,
        ColorFilter.mode(colors.textSecondary, BlendMode.srcIn),
        reason: 'icon $i',
      );
    }
    expect(pictures[3].width, kIconSize);
    expect(
      pictures[3].colorFilter,
      const ColorFilter.mode(Color(0xFF123456), BlendMode.srcIn),
    );
    expect(pictures[4].width, 16);
    expect(
      pictures[4].colorFilter,
      ColorFilter.mode(colors.accent, BlendMode.srcIn),
    );
  });

  testWidgets('AppIcon draws font glyphs that have a line drawing as SVGs', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app(const AppIcon(AppIcons.microphone)));
    expect(find.byType(SvgPicture), findsOneWidget);
  });

  testWidgets('AppIcon draws other font icons as an ordinary Icon', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app(const AppIcon(Icons.abc)));
    expect(find.byType(SvgPicture), findsNothing);
    expect(find.byIcon(Icons.abc), findsOneWidget);
  });

  testWidgets('EtoniaIcon defaults to the secondary text color', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app(const EtoniaIcon('tools/pen')));
    final SvgPicture picture = tester.widget<SvgPicture>(
      find.byType(SvgPicture),
    );
    expect(
      picture.colorFilter,
      const ColorFilter.mode(Color(0xFF706D76), BlendMode.srcIn),
    );
    expect(tester.takeException(), isNull);
  });

  group('pencil texture', () {
    testWidgets('is off by default, so icons stay crisp', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_app(const EtoniaIcon('tools/ruler', size: 24)));
      expect(tester.getSize(find.byType(SvgPicture)), const Size(24, 24));
      expect(find.byType(ShaderMask), findsNothing);
    });

    testWidgets('can lay grain over an icon without moving it', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const EtoniaIcon('tools/ruler', size: 24, applyPencilTexture: true),
        ),
      );
      expect(tester.getSize(find.byType(SvgPicture)), const Size(24, 24));
      expect(find.byType(ShaderMask), findsOneWidget);
    });
  });
}
