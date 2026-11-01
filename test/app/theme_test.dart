import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';

import '../helpers/pump_app.dart';

void main() {
  const double aaText = 4.5;
  const double aaControl = 3;

  test('modal surfaces are opaque, so nothing behind shows through', () {
    for (final ThemeData theme in <ThemeData>[
      AppTheme.light(),
      AppTheme.dark(),
    ]) {
      expect(theme.dialogTheme.backgroundColor!.a, 1);
      expect(theme.bottomSheetTheme.modalBackgroundColor!.a, 1);
      expect(theme.bottomSheetTheme.backgroundColor!.a, 1);
      expect(theme.drawerTheme.backgroundColor!.a, 1);
    }
  });

  for (final (String name, AppColors colors) in <(String, AppColors)>[
    ('light', AppColors.light),
    ('dark', AppColors.dark),
  ]) {
    group('$name theme contrast (WCAG AA)', () {
      test('text on every surface it sits on', () {
        for (final Color surface in <Color>[
          colors.background,
          colors.surface,
          colors.writingSurface,
        ]) {
          expect(
            contrastRatio(colors.textPrimary, surface),
            greaterThanOrEqualTo(aaText),
          );
          expect(
            contrastRatio(colors.textSecondary, surface),
            greaterThanOrEqualTo(aaText),
          );
        }
        expect(
          contrastRatio(colors.onAccent, colors.accent),
          greaterThanOrEqualTo(aaText),
        );
      });

      test('controls, selection, and focus', () {
        // `selected` is a translucent tint; judge it as painted on a card.
        expect(
          contrastRatio(
            colors.accent,
            Color.alphaBlend(colors.selected, colors.surface),
          ),
          greaterThanOrEqualTo(aaControl),
        );
        expect(
          contrastRatio(colors.accent, colors.surface),
          greaterThanOrEqualTo(aaControl),
        );
        expect(
          contrastRatio(colors.focus, colors.surface),
          greaterThanOrEqualTo(aaControl),
        );
        expect(
          contrastRatio(colors.focus, colors.background),
          greaterThanOrEqualTo(aaControl),
        );
      });

      test('every ink is legible on the page', () {
        final Brightness brightness = name == 'dark'
            ? Brightness.dark
            : Brightness.light;
        for (final InkColor ink in InkPalette.colors) {
          expect(
            contrastRatio(ink.resolve(brightness), colors.writingSurface),
            greaterThanOrEqualTo(aaControl),
            reason: ink.label,
          );
        }
      });
    });
  }

  test('the page is distinct from the chrome', () {
    expect(AppColors.light.writingSurface, isNot(AppColors.light.background));
    expect(AppColors.dark.writingSurface, isNot(AppColors.dark.background));
    // Dark is the logo as drawn: true black ground, lifted surfaces.
    expect(AppColors.dark.background, const Color(0xFF000000));
    expect(AppColors.dark.surface, isNot(AppColors.dark.background));
    expect(AppColors.dark.writingSurface, isNot(AppColors.dark.background));
  });

  test('themes use Material 3 and expose the color tokens', () {
    for (final ThemeData theme in <ThemeData>[
      AppTheme.light(),
      AppTheme.dark(),
    ]) {
      expect(theme.useMaterial3, isTrue);
      expect(theme.extension<AppColors>(), isNotNull);
    }
  });

  testWidgets('a tooltip goes away when the pencil stops hovering', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: IconButton(
              tooltip: 'Undo',
              onPressed: () {},
              icon: const Icon(Icons.undo),
            ),
          ),
        ),
      ),
    );

    // iPadOS reports Pencil hover as a mouse, and removes that pointer when
    // the pencil leaves hover range, even straight up from over a button.
    // (Android drops that exit; MainActivity stands in for it.)
    final TestGesture pencil = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await pencil.addPointer(
      location: tester.getCenter(find.byType(IconButton)),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Undo'), findsOneWidget);

    await pencil.removePointer();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Undo'), findsNothing);
  });

  test('there are at least six inks with unique names', () {
    expect(InkPalette.colors.length, greaterThanOrEqualTo(6));
    expect(
      InkPalette.colors.map((InkColor ink) => ink.label).toSet().length,
      InkPalette.colors.length,
    );
  });
}
