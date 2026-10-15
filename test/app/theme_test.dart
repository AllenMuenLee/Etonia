import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';

import '../helpers/pump_app.dart';

void main() {
  const double aaText = 4.5;
  const double aaControl = 3;

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
        expect(
          contrastRatio(colors.accent, colors.selected),
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

  test('the page is distinct from the chrome and dark is never pure black', () {
    expect(AppColors.light.writingSurface, isNot(AppColors.light.background));
    expect(AppColors.dark.writingSurface, isNot(AppColors.dark.background));
    for (final Color color in <Color>[
      AppColors.dark.background,
      AppColors.dark.surface,
      AppColors.dark.writingSurface,
    ]) {
      expect(color, isNot(const Color(0xFF000000)));
    }
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

  test('there are at least six inks with unique names', () {
    expect(InkPalette.colors.length, greaterThanOrEqualTo(6));
    expect(
      InkPalette.colors.map((InkColor ink) => ink.label).toSet().length,
      InkPalette.colors.length,
    );
  });
}
