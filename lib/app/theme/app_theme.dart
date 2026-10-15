import 'package:flutter/material.dart';

import 'app_tokens.dart';

abstract final class AppTheme {
  static ThemeData light() => _build(Brightness.light, AppColors.light);

  static ThemeData dark() => _build(Brightness.dark, AppColors.dark);

  static ThemeData _build(Brightness brightness, AppColors colors) {
    final ColorScheme scheme =
        ColorScheme.fromSeed(
          seedColor: colors.accent,
          brightness: brightness,
        ).copyWith(
          primary: colors.accent,
          onPrimary: colors.onAccent,
          surface: colors.surface,
          onSurface: colors.textPrimary,
          onSurfaceVariant: colors.textSecondary,
          outline: colors.textSecondary,
          outlineVariant: colors.divider,
          shadow: colors.shadow,
        );

    final WidgetStateProperty<Color?> overlay = WidgetStateProperty.resolveWith(
      (Set<WidgetState> states) {
        if (states.contains(WidgetState.pressed)) {
          return colors.textPrimary.withValues(alpha: 0.12);
        }
        if (states.contains(WidgetState.focused)) {
          return colors.textPrimary.withValues(alpha: 0.10);
        }
        if (states.contains(WidgetState.hovered)) {
          return colors.textPrimary.withValues(alpha: 0.06);
        }
        return null;
      },
    );

    final RoundedRectangleBorder controlShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadii.medium),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: colors.background,
      extensions: <ThemeExtension<dynamic>>[colors],
      textTheme: _textTheme(colors),
      dividerTheme: DividerThemeData(
        color: colors.divider,
        thickness: AppSizes.hairline,
        space: AppSizes.hairline,
      ),
      iconTheme: IconThemeData(color: colors.textPrimary, size: AppSizes.icon),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith((
            Set<WidgetState> states,
          ) {
            return states.contains(WidgetState.disabled)
                ? colors.textSecondary.withValues(alpha: 0.5)
                : colors.textPrimary;
          }),
          overlayColor: overlay,
          iconSize: const WidgetStatePropertyAll<double>(AppSizes.icon),
          minimumSize: const WidgetStatePropertyAll<Size>(
            Size.square(AppSizes.minTouchTarget),
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(controlShape),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 500),
        decoration: BoxDecoration(
          color: colors.textPrimary,
          borderRadius: BorderRadius.circular(AppRadii.small),
        ),
        textStyle: TextStyle(color: colors.background, fontSize: 12),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll<Color>(colors.surface),
          surfaceTintColor: const WidgetStatePropertyAll<Color>(
            Colors.transparent,
          ),
          shadowColor: WidgetStatePropertyAll<Color>(
            colors.shadow.withValues(alpha: 0.4),
          ),
          elevation: const WidgetStatePropertyAll<double>(3),
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
            EdgeInsets.zero,
          ),
          side: WidgetStatePropertyAll<BorderSide>(
            BorderSide(color: colors.divider, width: AppSizes.hairline),
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.large),
            ),
          ),
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: colors.accent,
        inactiveTrackColor: colors.divider,
        thumbColor: colors.accent,
        overlayColor: colors.accent.withValues(alpha: 0.12),
        trackHeight: 4,
      ),
    );
  }

  /// A compact scale on the platform's system font; no font is bundled.
  static TextTheme _textTheme(AppColors colors) {
    return TextTheme(
      titleMedium: TextStyle(
        fontSize: 16,
        height: 1.25,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
        color: colors.textPrimary,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        height: 1.4,
        fontWeight: FontWeight.w400,
        letterSpacing: 0,
        color: colors.textPrimary,
      ),
      labelLarge: TextStyle(
        fontSize: 14,
        height: 1.3,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
        color: colors.textPrimary,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        height: 1.3,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.2,
        color: colors.textSecondary,
      ),
    );
  }
}
