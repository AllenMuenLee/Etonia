import 'package:flutter/material.dart';

import '../../shared/navigation/app_page_route.dart';
import 'app_tokens.dart';

abstract final class AppTheme {
  static ThemeData light() => _build(Brightness.light, AppColors.light);

  static ThemeData dark() => _build(Brightness.dark, AppColors.dark);

  static ThemeData _build(Brightness brightness, AppColors colors) {
    // Text and accents set on an inverted surface, such as a snack bar.
    final AppColors inverse = brightness == Brightness.light
        ? AppColors.dark
        : AppColors.light;
    // Every role is pinned to a token, so no Material default tints a
    // surface with the seed's hue.
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
          onPrimaryContainer: colors.accent,
          secondaryContainer: colors.selected,
          onSecondaryContainer: colors.accent,
          onSurfaceVariant: colors.textSecondary,
          surfaceTint: Colors.transparent,
          surfaceDim: AppGlass.background(colors),
          surfaceBright: AppGlass.surface(colors),
          surfaceContainerLowest: colors.writingSurface,
          surfaceContainerLow: AppGlass.surface(colors),
          surfaceContainer: AppGlass.surface(colors),
          surfaceContainerHigh: AppGlass.surface(colors),
          surfaceContainerHighest: AppGlass.muted(colors),
          inverseSurface: colors.textPrimary,
          onInverseSurface: colors.background,
          inversePrimary: inverse.accent,
          outline: colors.textSecondary,
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
      textTheme: _textTheme(colors),
    );
    final TextTheme text = base.textTheme;

    final WidgetStateProperty<Color?> overlay = WidgetStateProperty.resolveWith(
      (Set<WidgetState> states) {
        if (states.contains(WidgetState.pressed)) {
          return colors.textPrimary.withValues(alpha: 0.10);
        }
        if (states.contains(WidgetState.focused)) {
          return colors.textPrimary.withValues(alpha: 0.10);
        }
        if (states.contains(WidgetState.hovered)) {
          return colors.textPrimary.withValues(alpha: 0.05);
        }
        return null;
      },
    );

    const StadiumBorder controlShape = StadiumBorder();
    final RoundedSuperellipseBorder floatingShape = RoundedSuperellipseBorder(
      borderRadius: AppBorderRadius.large,
      side: AppGlass.border(colors),
    );
    final Color disabledText = colors.textSecondary.withValues(alpha: 0.55);
    const Size buttonSize = Size(64, 44);
    const EdgeInsets buttonPadding = EdgeInsets.symmetric(
      horizontal: AppSpacing.md,
    );
    final TextStyle buttonText = text.labelLarge!.copyWith(
      fontWeight: FontWeight.w600,
    );

    final OutlineInputBorder fieldBorder = OutlineInputBorder(
      borderRadius: AppBorderRadius.medium,
      borderSide: BorderSide(color: colors.divider, width: AppSizes.hairline),
    );

    return base.copyWith(
      scaffoldBackgroundColor: AppGlass.background(colors),
      canvasColor: AppGlass.surface(colors),
      extensions: <ThemeExtension<dynamic>>[colors],
      // A soft ripple that spreads and fades, like ink taken up by paper.
      // It needs no shader, so its first use does not stall a frame.
      splashFactory: InkRipple.splashFactory,
      splashColor: colors.accent.withValues(alpha: 0.10),
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
      dividerTheme: DividerThemeData(
        color: colors.divider,
        thickness: AppSizes.hairline,
        space: AppSizes.hairline,
      ),
      iconTheme: IconThemeData(color: colors.textPrimary, size: AppSizes.icon),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          animationDuration: AppMotion.fadeIn,
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
          shape: const WidgetStatePropertyAll<OutlinedBorder>(controlShape),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colors.accent,
          foregroundColor: colors.onAccent,
          disabledBackgroundColor: colors.surfaceMuted,
          disabledForegroundColor: disabledText,
          minimumSize: buttonSize,
          padding: buttonPadding,
          textStyle: buttonText,
          shape: controlShape,
          elevation: 0,
          animationDuration: AppMotion.fadeIn,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colors.textPrimary,
          disabledForegroundColor: disabledText,
          minimumSize: buttonSize,
          padding: buttonPadding,
          textStyle: buttonText,
          shape: controlShape,
          animationDuration: AppMotion.fadeIn,
        ).copyWith(overlayColor: overlay),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.textPrimary,
          disabledForegroundColor: disabledText,
          minimumSize: buttonSize,
          padding: buttonPadding,
          textStyle: buttonText,
          shape: controlShape,
          side: BorderSide(color: colors.divider, width: AppSizes.hairline),
          animationDuration: AppMotion.fadeIn,
        ).copyWith(overlayColor: overlay),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          animationDuration: AppMotion.snappy.duration,
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
            return states.contains(WidgetState.selected)
                ? colors.accent
                : colors.textPrimary;
          }),
          overlayColor: overlay,
          side: WidgetStatePropertyAll<BorderSide>(
            BorderSide(color: colors.divider, width: AppSizes.hairline),
          ),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(controlShape),
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
        shape: const StadiumBorder(),
        extendedTextStyle: buttonText,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppGlass.muted(colors),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        hintStyle: text.bodyMedium!.copyWith(color: colors.textSecondary),
        labelStyle: text.bodyMedium!.copyWith(color: colors.textSecondary),
        floatingLabelStyle: text.labelMedium!.copyWith(color: colors.accent),
        prefixIconColor: colors.textSecondary,
        suffixIconColor: colors.textSecondary,
        border: fieldBorder.copyWith(borderSide: BorderSide.none),
        enabledBorder: fieldBorder.copyWith(
          borderSide: const BorderSide(color: Colors.transparent),
        ),
        disabledBorder: fieldBorder.copyWith(
          borderSide: const BorderSide(color: Colors.transparent),
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
        selectionColor: colors.accent.withValues(alpha: 0.24),
        selectionHandleColor: colors.accent,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          if (states.contains(WidgetState.disabled)) {
            return colors.surface.withValues(alpha: 0.7);
          }
          return states.contains(WidgetState.selected)
              ? colors.onAccent
              : colors.surface;
        }),
        trackColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          final Color track = states.contains(WidgetState.selected)
              ? colors.accent
              : colors.divider;
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
        side: BorderSide(color: colors.textSecondary, width: 1.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.small),
        ),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          return states.contains(WidgetState.selected)
              ? colors.accent
              : colors.textSecondary;
        }),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: colors.accent,
        inactiveTrackColor: colors.surfaceMuted,
        thumbColor: colors.accent,
        overlayColor: colors.accent.withValues(alpha: 0.12),
        disabledActiveTrackColor: colors.divider,
        disabledInactiveTrackColor: colors.surfaceMuted,
        disabledThumbColor: colors.divider,
        trackHeight: 8,
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
        linearTrackColor: colors.surfaceMuted,
        circularTrackColor: Colors.transparent,
        linearMinHeight: 8,
        borderRadius: BorderRadius.circular(4),
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
          color: colors.textPrimary.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(AppRadii.medium),
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
          minimumSize: const Size(180, 44),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          shape: const StadiumBorder(),
          animationDuration: AppMotion.fadeIn,
        ).copyWith(overlayColor: overlay),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: AppGlass.surface(colors),
        surfaceTintColor: Colors.transparent,
        shadowColor: colors.ambientShadow.withValues(alpha: 0.9),
        elevation: 6,
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
      dialogTheme: DialogThemeData(
        backgroundColor: AppGlass.surface(colors),
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shadowColor: colors.shadow.withValues(alpha: 0.4),
        shape: const RoundedSuperellipseBorder(
          borderRadius: AppBorderRadius.xl,
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
        barrierColor: colors.shadow.withValues(alpha: 0.32),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: AppGlass.surface(colors),
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: AppGlass.surface(colors),
        modalBarrierColor: colors.shadow.withValues(alpha: 0.32),
        elevation: 0,
        modalElevation: 0,
        showDragHandle: false,
        dragHandleColor: colors.divider,
        dragHandleSize: const Size(36, 4),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadii.xl),
          ),
        ),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: AppGlass.surface(colors),
        surfaceTintColor: Colors.transparent,
        scrimColor: colors.shadow.withValues(alpha: 0.32),
        elevation: 0,
        width: 300,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(
            right: Radius.circular(AppRadii.xl),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: colors.textPrimary,
        contentTextStyle: text.bodyMedium!.copyWith(color: colors.background),
        actionTextColor: inverse.accent,
        elevation: 4,
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
        selectedColor: colors.accent,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppGlass.muted(colors),
        selectedColor: colors.selected,
        side: BorderSide.none,
        labelStyle: text.labelLarge,
        shape: controlShape,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      ),
      cardTheme: CardThemeData(
        color: AppGlass.surface(colors),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: floatingShape,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll<double>(4),
        radius: const Radius.circular(2),
        thumbColor: WidgetStatePropertyAll<Color>(
          colors.textSecondary.withValues(alpha: 0.35),
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
    return MenuStyle(
      backgroundColor: WidgetStatePropertyAll<Color>(AppGlass.surface(colors)),
      surfaceTintColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      shadowColor: WidgetStatePropertyAll<Color>(
        colors.ambientShadow.withValues(alpha: 0.9),
      ),
      elevation: const WidgetStatePropertyAll<double>(6),
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.all(AppSpacing.xxs),
      ),
      side: WidgetStatePropertyAll<BorderSide>(AppGlass.border(colors)),
      shape: const WidgetStatePropertyAll<OutlinedBorder>(
        RoundedSuperellipseBorder(borderRadius: AppBorderRadius.large),
      ),
    );
  }

  /// System typography for controls and reading, with rounded heavy titles
  /// that echo the mass and pill ends of the Etonia mark.
  static TextTheme _textTheme(AppColors colors) {
    TextStyle style(
      double size,
      double height,
      FontWeight weight, {
      double letterSpacing = 0,
      Color? color,
    }) {
      return TextStyle(
        fontSize: size,
        height: height,
        fontWeight: weight,
        letterSpacing: letterSpacing,
        color: color ?? colors.textPrimary,
      );
    }

    TextStyle title(
      double size,
      double height,
      FontWeight weight, {
      double letterSpacing = 0,
    }) => style(
      size,
      height,
      weight,
      letterSpacing: letterSpacing,
    ).copyWith(fontFamily: '.SF Pro Rounded');

    return TextTheme(
      displaySmall: title(34, 1.15, FontWeight.w800, letterSpacing: -1),
      headlineMedium: title(28, 1.18, FontWeight.w800, letterSpacing: -0.6),
      headlineSmall: title(22, 1.2, FontWeight.w700, letterSpacing: -0.3),
      titleLarge: title(22, 1.2, FontWeight.w700, letterSpacing: -0.3),
      titleMedium: title(17, 1.25, FontWeight.w600),
      titleSmall: title(17, 1.25, FontWeight.w600),
      bodyLarge: style(17, 1.4, FontWeight.w400),
      bodyMedium: style(16, 1.4, FontWeight.w400),
      bodySmall: style(15, 1.4, FontWeight.w400, color: colors.textSecondary),
      labelLarge: style(16, 1.3, FontWeight.w600),
      labelMedium: style(
        13,
        1.3,
        FontWeight.w500,
        letterSpacing: 0.1,
        color: colors.textSecondary,
      ),
      labelSmall: style(12, 1.3, FontWeight.w600, color: colors.textSecondary),
    );
  }
}
