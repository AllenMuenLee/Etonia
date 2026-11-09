import 'package:flutter/material.dart';

import '../../shared/navigation/app_page_route.dart';
import 'app_tokens.dart';

abstract final class AppTheme {
  /// The UI face. Inter carries navigation, controls, body text, and the AI
  /// and study surfaces.
  static const String uiFont = 'Inter';

  /// The editorial face, reserved for large, low-density titles.
  static const String displayFont = 'Newsreader';

  /// Fonts tried, in order, for glyphs Inter and Newsreader do not carry:
  /// Chinese, Japanese, Korean, and the symbols of mathematical notation.
  static const List<String> fontFallback = <String>[
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'PingFang SC',
    'Hiragino Sans',
    'Apple SD Gothic Neo',
    'Microsoft YaHei',
    'Noto Sans Math',
    'Noto Sans Symbols 2',
    'Noto Sans',
    'sans-serif',
  ];

  static ThemeData light() => _build(Brightness.light, AppColors.light);

  static ThemeData dark() => _build(Brightness.dark, AppColors.dark);

  static ThemeData _build(Brightness brightness, AppColors colors) {
    final bool isDark = brightness == Brightness.dark;
    // Text and accents set on an inverted surface, such as a snack bar.
    final AppColors inverse = isDark ? AppColors.light : AppColors.dark;
    // Every role is pinned to a token, so no Material default tints a
    // surface with a seed's hue.
    final ColorScheme scheme =
        ColorScheme(
          brightness: brightness,
          primary: colors.accent,
          onPrimary: colors.onAccent,
          secondary: colors.accent,
          onSecondary: colors.onAccent,
          error: colors.danger,
          onError: colors.onAccent,
          surface: colors.surface,
          onSurface: colors.textPrimary,
        ).copyWith(
          primaryContainer: colors.selected,
          onPrimaryContainer: colors.textPrimary,
          secondaryContainer: colors.selected,
          onSecondaryContainer: colors.textPrimary,
          onSurfaceVariant: colors.textSecondary,
          surfaceTint: Colors.transparent,
          surfaceDim: colors.background,
          surfaceBright: colors.surface,
          surfaceContainerLowest: colors.writingSurface,
          surfaceContainerLow: colors.surface,
          surfaceContainer: colors.surface,
          surfaceContainerHigh: colors.surfaceElevated,
          surfaceContainerHighest: colors.surfaceMuted,
          inverseSurface: colors.textPrimary,
          onInverseSurface: colors.background,
          inversePrimary: inverse.accent,
          outline: colors.borderStrong,
          outlineVariant: colors.divider,
          shadow: colors.shadow,
          scrim: colors.shadow,
        );

    // Built first so its text theme is merged with the platform's
    // typography; every component style below derives from that.
    final ThemeData base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: uiFont,
      fontFamilyFallback: fontFallback,
      textTheme: _textTheme(colors),
    );
    final TextTheme text = base.textTheme;

    // A quiet tint under a hovering pointer, a touch deeper when pressed.
    final WidgetStateProperty<Color?> overlay = WidgetStateProperty.resolveWith(
      (Set<WidgetState> states) {
        if (states.contains(WidgetState.pressed)) {
          return colors.textPrimary.withValues(alpha: 0.08);
        }
        if (states.contains(WidgetState.focused)) {
          return colors.textPrimary.withValues(alpha: 0.06);
        }
        if (states.contains(WidgetState.hovered)) {
          return colors.textPrimary.withValues(alpha: 0.04);
        }
        return null;
      },
    );

    // Standard buttons and inputs, compact controls, and floating panels.
    const RoundedRectangleBorder controlShape = RoundedRectangleBorder(
      borderRadius: AppBorderRadius.medium,
    );
    const RoundedRectangleBorder compactShape = RoundedRectangleBorder(
      borderRadius: AppBorderRadius.small,
    );
    final RoundedSuperellipseBorder floatingShape = RoundedSuperellipseBorder(
      borderRadius: AppBorderRadius.large,
      side: AppGlass.border(colors),
    );
    final Color disabledText = colors.textTertiary;
    final Color disabledIcon = colors.textTertiary.withValues(alpha: 0.7);
    const Size buttonSize = Size(64, 44);
    const EdgeInsets buttonPadding = EdgeInsets.symmetric(
      horizontal: AppSpacing.md,
    );
    final TextStyle buttonText = text.labelLarge!.copyWith(
      fontWeight: FontWeight.w500,
    );

    final OutlineInputBorder fieldBorder = OutlineInputBorder(
      borderRadius: AppBorderRadius.medium,
      borderSide: BorderSide(color: colors.divider, width: AppSizes.hairline),
    );

    return base.copyWith(
      scaffoldBackgroundColor: colors.background,
      canvasColor: colors.surface,
      extensions: <ThemeExtension<dynamic>>[colors],
      // A quiet ripple, never a flash.
      splashFactory: InkRipple.splashFactory,
      splashColor: colors.accent.withValues(alpha: 0.10),
      hoverColor: colors.textPrimary.withValues(alpha: 0.04),
      focusColor: colors.textPrimary.withValues(alpha: 0.06),
      highlightColor: Colors.transparent,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: AppPageTransitionsBuilder(),
          TargetPlatform.iOS: AppPageTransitionsBuilder(),
          TargetPlatform.windows: AppPageTransitionsBuilder(),
          TargetPlatform.macOS: AppPageTransitionsBuilder(),
          TargetPlatform.linux: AppPageTransitionsBuilder(),
          TargetPlatform.fuchsia: AppPageTransitionsBuilder(),
        },
      ),
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        backgroundColor: colors.background,
        foregroundColor: colors.textPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: text.titleMedium,
        iconTheme: IconThemeData(color: colors.textSecondary),
      ),
      dividerTheme: DividerThemeData(
        color: colors.divider,
        thickness: AppSizes.hairline,
        space: AppSizes.hairline,
      ),
      // Default icons are quiet; active ones take the brand accent.
      iconTheme: IconThemeData(
        color: colors.textSecondary,
        size: AppSizes.icon,
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          animationDuration: AppMotion.fast,
          foregroundColor: WidgetStateProperty.resolveWith((
            Set<WidgetState> states,
          ) {
            if (states.contains(WidgetState.disabled)) return disabledIcon;
            if (states.contains(WidgetState.selected)) return colors.accent;
            return colors.textSecondary;
          }),
          backgroundColor: WidgetStateProperty.resolveWith((
            Set<WidgetState> states,
          ) {
            return states.contains(WidgetState.selected)
                ? colors.selected
                : Colors.transparent;
          }),
          overlayColor: overlay,
          iconSize: const WidgetStatePropertyAll<double>(AppSizes.icon),
          minimumSize: const WidgetStatePropertyAll<Size>(
            Size.square(AppSizes.minTouchTarget),
          ),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(borderRadius: AppBorderRadius.medium),
          ),
        ),
      ),
      // Primary: the brand fill, tonal on hover and press, never a shadow.
      filledButtonTheme: FilledButtonThemeData(
        style:
            FilledButton.styleFrom(
              foregroundColor: colors.onAccent,
              disabledBackgroundColor: colors.surfaceMuted,
              disabledForegroundColor: disabledText,
              minimumSize: buttonSize,
              padding: buttonPadding,
              textStyle: buttonText,
              shape: controlShape,
              elevation: 0,
              animationDuration: AppMotion.fast,
            ).copyWith(
              backgroundColor: WidgetStateProperty.resolveWith((
                Set<WidgetState> states,
              ) {
                if (states.contains(WidgetState.disabled)) {
                  return colors.surfaceMuted;
                }
                if (states.contains(WidgetState.pressed)) {
                  return colors.brandPressed;
                }
                if (states.contains(WidgetState.hovered)) {
                  return colors.brandHover;
                }
                return colors.accent;
              }),
              overlayColor: const WidgetStatePropertyAll<Color>(
                Colors.transparent,
              ),
            ),
      ),
      // Tertiary: transparent, with a faint surface under the pointer.
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colors.textPrimary,
          disabledForegroundColor: disabledText,
          minimumSize: buttonSize,
          padding: buttonPadding,
          textStyle: buttonText,
          shape: controlShape,
          animationDuration: AppMotion.fast,
        ).copyWith(overlayColor: overlay),
      ),
      // Secondary: a neutral surface with a thin border.
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.textPrimary,
          disabledForegroundColor: disabledText,
          minimumSize: buttonSize,
          padding: buttonPadding,
          textStyle: buttonText,
          backgroundColor: colors.surface,
          shape: controlShape,
          side: BorderSide(color: colors.borderStrong),
          animationDuration: AppMotion.fast,
        ).copyWith(overlayColor: overlay),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          animationDuration: AppMotion.fast,
          backgroundColor: WidgetStateProperty.resolveWith((
            Set<WidgetState> states,
          ) {
            return states.contains(WidgetState.selected)
                ? colors.selected
                : Colors.transparent;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((
            Set<WidgetState> states,
          ) {
            if (states.contains(WidgetState.disabled)) return disabledText;
            if (states.contains(WidgetState.selected)) {
              return colors.accentText;
            }
            return colors.textSecondary;
          }),
          overlayColor: overlay,
          side: WidgetStatePropertyAll<BorderSide>(
            BorderSide(color: colors.divider, width: AppSizes.hairline),
          ),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(compactShape),
          minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 40)),
          textStyle: WidgetStatePropertyAll<TextStyle>(buttonText),
          iconSize: const WidgetStatePropertyAll<double>(18),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colors.accent,
        foregroundColor: colors.onAccent,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: AppBorderRadius.large,
        ),
        extendedTextStyle: buttonText,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceMuted,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        hintStyle: text.bodyMedium!.copyWith(color: colors.textTertiary),
        labelStyle: text.bodyMedium!.copyWith(color: colors.textSecondary),
        floatingLabelStyle: text.labelMedium!.copyWith(
          color: colors.accentText,
        ),
        prefixIconColor: colors.textSecondary,
        suffixIconColor: colors.textSecondary,
        border: fieldBorder,
        enabledBorder: fieldBorder,
        disabledBorder: fieldBorder.copyWith(
          borderSide: BorderSide(
            color: colors.divider.withValues(alpha: 0.6),
            width: AppSizes.hairline,
          ),
        ),
        focusedBorder: fieldBorder.copyWith(
          borderSide: BorderSide(
            color: colors.focus,
            width: AppSizes.focusRingWidth,
          ),
        ),
        errorBorder: fieldBorder.copyWith(
          borderSide: BorderSide(color: colors.danger),
        ),
        focusedErrorBorder: fieldBorder.copyWith(
          borderSide: BorderSide(
            color: colors.danger,
            width: AppSizes.focusRingWidth,
          ),
        ),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: colors.accent,
        selectionColor: colors.pencil.withValues(alpha: isDark ? 0.7 : 0.8),
        selectionHandleColor: colors.accent,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          if (states.contains(WidgetState.disabled)) {
            return colors.surface.withValues(alpha: 0.7);
          }
          // Always light, so it reads on the brand track in either theme.
          return AppColors.light.writingSurface;
        }),
        trackColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          // On is the brand accent; off is a firm neutral.
          final Color track = states.contains(WidgetState.selected)
              ? (isDark ? colors.brandPressed : colors.accent)
              : colors.borderStrong;
          return states.contains(WidgetState.disabled)
              ? track.withValues(alpha: 0.5)
              : track;
        }),
        trackOutlineColor: const WidgetStatePropertyAll<Color>(
          Colors.transparent,
        ),
        thumbIcon: const WidgetStatePropertyAll<Icon?>(null),
        overlayColor: overlay,
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          return states.contains(WidgetState.selected) ? colors.accent : null;
        }),
        checkColor: WidgetStatePropertyAll<Color>(colors.onAccent),
        side: BorderSide(color: colors.textTertiary, width: 1.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.xs + 1),
        ),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          return states.contains(WidgetState.selected)
              ? colors.accent
              : colors.textTertiary;
        }),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: colors.accent,
        inactiveTrackColor: colors.borderStrong,
        thumbColor: colors.accent,
        overlayColor: colors.accent.withValues(alpha: 0.12),
        disabledActiveTrackColor: colors.divider,
        disabledInactiveTrackColor: colors.surfaceMuted,
        disabledThumbColor: colors.divider,
        trackHeight: 4,
        trackShape: const RoundedRectSliderTrackShape(),
        thumbShape: const RoundSliderThumbShape(
          enabledThumbRadius: 9,
          elevation: 1,
          pressedElevation: 2,
        ),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
        tickMarkShape: SliderTickMarkShape.noTickMark,
        showValueIndicator: ShowValueIndicator.never,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colors.accent,
        linearTrackColor: colors.divider,
        circularTrackColor: Colors.transparent,
        linearMinHeight: 6,
        borderRadius: BorderRadius.circular(3),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: colors.textPrimary,
        unselectedLabelColor: colors.textSecondary,
        labelStyle: text.labelLarge,
        unselectedLabelStyle: text.labelLarge,
        indicatorColor: colors.accent,
        dividerColor: colors.divider,
        overlayColor: overlay,
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 500),
        // Fades out slowly, so it never blinks away.
        exitDuration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xs,
          vertical: AppSpacing.xxs,
        ),
        decoration: BoxDecoration(
          color: colors.textPrimary.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(AppRadii.small),
        ),
        textStyle: text.labelMedium!.copyWith(
          color: colors.background,
          letterSpacing: 0,
        ),
      ),
      menuTheme: MenuThemeData(style: _menuStyle(colors)),
      menuButtonTheme: MenuButtonThemeData(
        style: MenuItemButton.styleFrom(
          foregroundColor: colors.textPrimary,
          iconColor: colors.textSecondary,
          disabledForegroundColor: disabledText,
          disabledIconColor: disabledText,
          textStyle: text.bodyMedium,
          minimumSize: const Size(180, 40),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          shape: compactShape,
          animationDuration: AppMotion.fast,
        ).copyWith(overlayColor: overlay),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: colors.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        shadowColor: colors.shadow.withValues(alpha: isDark ? 0.5 : 0.25),
        elevation: isDark ? 0 : 4,
        shape: floatingShape,
        menuPadding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
        textStyle: text.bodyMedium,
        labelTextStyle: WidgetStatePropertyAll<TextStyle>(text.bodyMedium!),
        iconColor: colors.textSecondary,
        iconSize: 20,
        position: PopupMenuPosition.under,
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: text.bodyMedium,
        menuStyle: _menuStyle(colors),
      ),
      // Modal surfaces are opaque and softly rounded; the scrim already sets
      // them apart from what is behind.
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        elevation: isDark ? 0 : 6,
        shadowColor: colors.shadow.withValues(alpha: 0.3),
        shape: RoundedSuperellipseBorder(
          borderRadius: AppBorderRadius.xl,
          side: AppGlass.border(colors),
        ),
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyMedium!.copyWith(
          color: colors.textSecondary,
        ),
        insetPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.lg,
        ),
        actionsPadding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          0,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        barrierColor: colors.shadow.withValues(alpha: isDark ? 0.5 : 0.28),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: colors.surfaceElevated,
        modalBarrierColor: colors.shadow.withValues(alpha: isDark ? 0.5 : 0.28),
        elevation: 0,
        modalElevation: 0,
        showDragHandle: false,
        dragHandleColor: colors.borderStrong,
        dragHandleSize: const Size(36, 4),
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadii.xl),
          ),
          side: AppGlass.border(colors),
        ),
      ),
      // Sidebars sit on the secondary background, gently set off from the
      // content by a hairline rather than a heavy border.
      drawerTheme: DrawerThemeData(
        backgroundColor: colors.backgroundSecondary,
        surfaceTintColor: Colors.transparent,
        scrimColor: colors.shadow.withValues(alpha: isDark ? 0.5 : 0.28),
        elevation: 0,
        width: 300,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.horizontal(
            right: Radius.circular(AppRadii.xl),
          ),
          side: AppGlass.border(colors),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: colors.textPrimary,
        contentTextStyle: text.bodyMedium!.copyWith(color: colors.background),
        actionTextColor: inverse.accentText,
        elevation: 0,
        width: 420,
        shape: controlShape,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: colors.textSecondary,
        textColor: colors.textPrimary,
        titleTextStyle: text.bodyLarge,
        subtitleTextStyle: text.bodySmall,
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        minVerticalPadding: AppSpacing.xs,
        horizontalTitleGap: AppSpacing.sm,
        shape: controlShape,
        selectedColor: colors.accentText,
        selectedTileColor: colors.selected,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colors.surfaceMuted,
        selectedColor: colors.selected,
        side: BorderSide(color: colors.divider, width: AppSizes.hairline),
        labelStyle: text.labelLarge,
        shape: compactShape,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      ),
      cardTheme: CardThemeData(
        color: colors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: floatingShape,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll<double>(4),
        radius: const Radius.circular(2),
        thumbColor: WidgetStatePropertyAll<Color>(
          colors.textTertiary.withValues(alpha: 0.5),
        ),
        crossAxisMargin: 2,
      ),
      badgeTheme: BadgeThemeData(
        backgroundColor: colors.accent,
        textColor: colors.onAccent,
      ),
    );
  }

  static MenuStyle _menuStyle(AppColors colors) {
    final bool isDark = colors.background.computeLuminance() < 0.5;
    return MenuStyle(
      backgroundColor: WidgetStatePropertyAll<Color>(colors.surfaceElevated),
      surfaceTintColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      shadowColor: WidgetStatePropertyAll<Color>(
        colors.shadow.withValues(alpha: isDark ? 0.5 : 0.25),
      ),
      elevation: WidgetStatePropertyAll<double>(isDark ? 0 : 4),
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.all(AppSpacing.xxs),
      ),
      side: WidgetStatePropertyAll<BorderSide>(AppGlass.border(colors)),
      shape: const WidgetStatePropertyAll<OutlinedBorder>(
        RoundedSuperellipseBorder(borderRadius: AppBorderRadius.large),
      ),
    );
  }

  /// Inter for everything except [TextTheme.displaySmall], the one editorial
  /// style, set in Newsreader for large, low-density titles. Sizes, weights,
  /// and line heights follow the design tokens; headings are medium-weight
  /// and only the largest sizes are tightened.
  static TextTheme _textTheme(AppColors colors) {
    TextStyle style(
      double size,
      double height,
      FontWeight weight, {
      double letterSpacing = 0,
      Color? color,
      String family = uiFont,
    }) {
      return TextStyle(
        fontFamily: family,
        fontFamilyFallback: fontFallback,
        fontSize: size,
        height: height,
        fontWeight: weight,
        letterSpacing: letterSpacing,
        color: color ?? colors.textPrimary,
      );
    }

    return TextTheme(
      // display
      displaySmall: style(
        34,
        1.15,
        FontWeight.w500,
        letterSpacing: -0.5,
        family: displayFont,
      ),
      // Numerals at display size (prices, totals) stay in the UI face.
      displayMedium: style(
        34,
        1.15,
        FontWeight.w500,
        letterSpacing: -0.5,
      ).copyWith(fontFeatures: AppText.tabular),
      // headingLarge
      headlineMedium: style(28, 1.2, FontWeight.w600, letterSpacing: -0.4),
      // headingMedium
      headlineSmall: style(22, 1.25, FontWeight.w600, letterSpacing: -0.2),
      titleLarge: style(22, 1.25, FontWeight.w600, letterSpacing: -0.2),
      // headingSmall
      titleMedium: style(18, 1.3, FontWeight.w600),
      titleSmall: style(16, 1.35, FontWeight.w600),
      bodyLarge: style(16, 1.5, FontWeight.w400),
      bodyMedium: style(14, 1.45, FontWeight.w400),
      bodySmall: style(13, 1.4, FontWeight.w400, color: colors.textSecondary),
      // label
      labelLarge: style(14, 1.35, FontWeight.w500),
      labelMedium: style(13, 1.35, FontWeight.w500, color: colors.textSecondary),
      // micro
      labelSmall: style(11, 1.3, FontWeight.w500, color: colors.textSecondary),
    );
  }
}
