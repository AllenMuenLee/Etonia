import 'package:flutter/material.dart';

/// Spacing on a 4-logical-pixel grid.
abstract final class AppSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
}

/// The only corner radii used by the app.
abstract final class AppRadii {
  /// Paper corners and small indicators.
  static const double small = 4;

  /// Buttons and inline fields.
  static const double medium = 10;

  /// Floating chrome: palette and popovers.
  static const double large = 16;
}

abstract final class AppSizes {
  /// Minimum interactive area, regardless of the visible glyph size.
  static const double minTouchTarget = 48;

  static const double appBarHeight = 52;
  static const double icon = 22;

  /// Visible (painted) extent of a palette button inside its touch target.
  static const double paletteButtonVisual = 40;
  static const double paletteButtonVisualDense = 36;

  static const double colorSwatch = 28;
  static const double colorIndicator = 20;
  static const double popoverWidth = 264;
  static const double focusRingWidth = 2;
  static const double hairline = 1;

  /// Content stops growing here so controls stay close to the page.
  static const double maxContentWidth = 1280;
}

abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration medium = Duration(milliseconds: 200);
  static const Curve standard = Curves.easeOutCubic;

  /// Collapses [duration] to zero when the platform requests reduced motion.
  static Duration resolve(BuildContext context, Duration duration) {
    return MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration;
  }
}

/// Semantic colors. Feature widgets read these instead of color literals.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.background,
    required this.surface,
    required this.writingSurface,
    required this.textPrimary,
    required this.textSecondary,
    required this.divider,
    required this.accent,
    required this.onAccent,
    required this.selected,
    required this.focus,
    required this.shadow,
    required this.pageRule,
    required this.pageMarginRule,
  });

  /// App chrome behind everything else.
  final Color background;

  /// Floating chrome such as the palette and popovers.
  final Color surface;

  /// The page the user writes on.
  final Color writingSurface;

  final Color textPrimary;
  final Color textSecondary;
  final Color divider;
  final Color accent;
  final Color onAccent;

  /// Fill behind a selected control.
  final Color selected;

  /// Keyboard focus ring.
  final Color focus;

  final Color shadow;

  /// Lines, grid, and dots printed on the page, under the ink.
  final Color pageRule;

  /// The margin rule of lined paper.
  final Color pageMarginRule;

  static const AppColors light = AppColors(
    background: Color(0xFFF6F4EF),
    surface: Color(0xFFFDFCFA),
    writingSurface: Color(0xFFFFFFFF),
    textPrimary: Color(0xFF1F1E1C),
    textSecondary: Color(0xFF5E5B55),
    divider: Color(0xFFE2DED5),
    accent: Color(0xFF3B5BDB),
    onAccent: Color(0xFFFFFFFF),
    selected: Color(0xFFE4E8F8),
    focus: Color(0xFF3B5BDB),
    shadow: Color(0xFF2A2620),
    pageRule: Color(0xFFDDE3EC),
    pageMarginRule: Color(0xFFF0CFCB),
  );

  static const AppColors dark = AppColors(
    background: Color(0xFF161719),
    surface: Color(0xFF1F2023),
    writingSurface: Color(0xFF26272B),
    textPrimary: Color(0xFFECEAE6),
    textSecondary: Color(0xFFA9A6A0),
    divider: Color(0xFF3A3C42),
    accent: Color(0xFF8FA5F5),
    onAccent: Color(0xFF10131F),
    selected: Color(0xFF2D3550),
    focus: Color(0xFF8FA5F5),
    shadow: Color(0xFF000000),
    pageRule: Color(0xFF363940),
    pageMarginRule: Color(0xFF4F3A3A),
  );

  static AppColors of(BuildContext context) {
    return Theme.of(context).extension<AppColors>()!;
  }

  @override
  AppColors copyWith({
    Color? background,
    Color? surface,
    Color? writingSurface,
    Color? textPrimary,
    Color? textSecondary,
    Color? divider,
    Color? accent,
    Color? onAccent,
    Color? selected,
    Color? focus,
    Color? shadow,
    Color? pageRule,
    Color? pageMarginRule,
  }) {
    return AppColors(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      writingSurface: writingSurface ?? this.writingSurface,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      divider: divider ?? this.divider,
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      selected: selected ?? this.selected,
      focus: focus ?? this.focus,
      shadow: shadow ?? this.shadow,
      pageRule: pageRule ?? this.pageRule,
      pageMarginRule: pageMarginRule ?? this.pageMarginRule,
    );
  }

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) {
      return this;
    }
    return AppColors(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      writingSurface: Color.lerp(writingSurface, other.writingSurface, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      selected: Color.lerp(selected, other.selected, t)!,
      focus: Color.lerp(focus, other.focus, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
      pageRule: Color.lerp(pageRule, other.pageRule, t)!,
      pageMarginRule: Color.lerp(pageMarginRule, other.pageMarginRule, t)!,
    );
  }
}

/// The two shadow styles used by the app. Both are intentionally faint.
abstract final class AppShadows {
  /// Lifts the page slightly off the background.
  static List<BoxShadow> paper(AppColors colors) {
    return <BoxShadow>[
      BoxShadow(
        color: colors.shadow.withValues(alpha: 0.05),
        blurRadius: 12,
        offset: const Offset(0, 2),
      ),
    ];
  }

  /// Floating chrome above the page.
  static List<BoxShadow> floating(AppColors colors) {
    return <BoxShadow>[
      BoxShadow(
        color: colors.shadow.withValues(alpha: 0.10),
        blurRadius: 16,
        offset: const Offset(0, 4),
      ),
    ];
  }
}
