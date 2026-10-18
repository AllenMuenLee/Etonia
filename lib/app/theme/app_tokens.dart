import 'dart:typed_data' show Float32List;
import 'dart:ui' show ImageFilter, PointMode;

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

  /// Floating chrome: palette, popovers, menus, and cards.
  static const double large = 16;

  /// Dialogs and sheets: the largest surfaces get the softest corners.
  static const double xl = 20;
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

  /// For whole surfaces arriving: a page, a panel. Slower than [medium],
  /// and eased in as well as out, so it starts softly instead of landing.
  static const Duration gentle = Duration(milliseconds: 210);
  static const Curve gentleCurve = Cubic(0.3, 0, 0, 1);

  /// A released palette settling into its dock: brief, so it never trails
  /// the finger that let it go.
  static const Duration dock = Duration(milliseconds: 100);

  /// How far a control sinks under the finger, and how quickly.
  static const double pressedScale = 0.95;
  static const Duration press = Duration(milliseconds: 100);

  /// Brings a pressed control back: quick, with a slight overshoot, and
  /// settled in about [medium].
  static const SpringDescription spring = SpringDescription(
    mass: 1,
    stiffness: 600,
    damping: 32,
  );

  /// One pass of the light through a progress track or placeholder.
  static const Duration shimmer = Duration(milliseconds: 1600);

  /// One breath of the glow around a busy panel.
  static const Duration pulse = Duration(milliseconds: 2400);

  /// Handwritten words flying from the page into the chat's composer:
  /// long enough to follow with the eye, short enough not to wait on.
  static const Duration flight = Duration(milliseconds: 620);
  static const Curve flightCurve = Cubic(0.45, 0, 0.2, 1);

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
    required this.surfaceMuted,
    required this.writingSurface,
    required this.textPrimary,
    required this.textSecondary,
    required this.divider,
    required this.accent,
    required this.onAccent,
    required this.danger,
    required this.selected,
    required this.focus,
    required this.shadow,
    required this.pageRule,
    required this.pageMarginRule,
    required this.ambientShadow,
    required this.glassEdge,
    required this.canvasDot,
  });

  /// App chrome behind everything else.
  final Color background;

  /// Floating chrome such as the palette and popovers.
  final Color surface;

  /// A quiet fill set into [surface] or [background]: text fields, slider
  /// tracks, unselected chips, and tonal buttons.
  final Color surfaceMuted;

  /// The page the user writes on.
  final Color writingSurface;

  final Color textPrimary;
  final Color textSecondary;
  final Color divider;
  final Color accent;
  final Color onAccent;

  /// Destructive actions, such as Delete, and errors.
  final Color danger;

  /// Fill behind a selected control.
  final Color selected;

  /// Keyboard focus ring.
  final Color focus;

  final Color shadow;

  /// Lines, grid, and dots printed on the page, under the ink.
  final Color pageRule;

  /// The margin rule of lined paper.
  final Color pageMarginRule;

  /// The soft, tinted color of the wide ambient layer of a shadow.
  final Color ambientShadow;

  /// The near-invisible edge of frosted glass.
  final Color glassEdge;

  /// The dots of the grid the app's chrome floats over.
  final Color canvasDot;

  // Cool grays and slate, with a single indigo accent. No large surface is
  // pure white or pure black.
  static const AppColors light = AppColors(
    background: Color(0xFFF9FAFB),
    surface: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFF1F5F9),
    writingSurface: Color(0xFFFDFDFD),
    textPrimary: Color(0xFF0F172A),
    textSecondary: Color(0xFF64748B),
    divider: Color(0xFFE5E7EB),
    // Indigo 500, a hair deeper so white labels on it meet AA.
    accent: Color(0xFF6164F1),
    onAccent: Color(0xFFFFFFFF),
    danger: Color(0xFFDC2626),
    selected: Color(0xFFEEF2FF),
    focus: Color(0xFF6164F1),
    shadow: Color(0xFF0F172A),
    pageRule: Color(0xFFE2E8F0),
    pageMarginRule: Color(0xFFF0CFCB),
    ambientShadow: Color(0xFFE2E8F0),
    glassEdge: Color(0x66FFFFFF),
    canvasDot: Color(0xFFE5E7EB),
  );

  static const AppColors dark = AppColors(
    background: Color(0xFF0E1424),
    surface: Color(0xFF1E293B),
    surfaceMuted: Color(0xFF273449),
    writingSurface: Color(0xFF182133),
    textPrimary: Color(0xFFF1F5F9),
    textSecondary: Color(0xFF94A3B8),
    divider: Color(0xFF334155),
    accent: Color(0xFF818CF8),
    onAccent: Color(0xFF0F172A),
    danger: Color(0xFFF87171),
    selected: Color(0xFF2A2F5E),
    focus: Color(0xFF818CF8),
    shadow: Color(0xFF020617),
    pageRule: Color(0xFF2C3648),
    pageMarginRule: Color(0xFF4F3A3A),
    ambientShadow: Color(0xFF020617),
    glassEdge: Color(0x14FFFFFF),
    canvasDot: Color(0xFF334155),
  );

  static AppColors of(BuildContext context) {
    return Theme.of(context).extension<AppColors>()!;
  }

  /// [of], or the default for the theme's brightness when no app theme is
  /// installed, as for a widget shown on its own.
  static AppColors resolve(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return theme.extension<AppColors>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  @override
  AppColors copyWith({
    Color? background,
    Color? surface,
    Color? surfaceMuted,
    Color? writingSurface,
    Color? textPrimary,
    Color? textSecondary,
    Color? divider,
    Color? accent,
    Color? onAccent,
    Color? danger,
    Color? selected,
    Color? focus,
    Color? shadow,
    Color? pageRule,
    Color? pageMarginRule,
    Color? ambientShadow,
    Color? glassEdge,
    Color? canvasDot,
  }) {
    return AppColors(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surfaceMuted: surfaceMuted ?? this.surfaceMuted,
      writingSurface: writingSurface ?? this.writingSurface,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      divider: divider ?? this.divider,
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      danger: danger ?? this.danger,
      selected: selected ?? this.selected,
      focus: focus ?? this.focus,
      shadow: shadow ?? this.shadow,
      pageRule: pageRule ?? this.pageRule,
      pageMarginRule: pageMarginRule ?? this.pageMarginRule,
      ambientShadow: ambientShadow ?? this.ambientShadow,
      glassEdge: glassEdge ?? this.glassEdge,
      canvasDot: canvasDot ?? this.canvasDot,
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
      surfaceMuted: Color.lerp(surfaceMuted, other.surfaceMuted, t)!,
      writingSurface: Color.lerp(writingSurface, other.writingSurface, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      selected: Color.lerp(selected, other.selected, t)!,
      focus: Color.lerp(focus, other.focus, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
      pageRule: Color.lerp(pageRule, other.pageRule, t)!,
      pageMarginRule: Color.lerp(pageMarginRule, other.pageMarginRule, t)!,
      ambientShadow: Color.lerp(ambientShadow, other.ambientShadow, t)!,
      glassEdge: Color.lerp(glassEdge, other.glassEdge, t)!,
      canvasDot: Color.lerp(canvasDot, other.canvasDot, t)!,
    );
  }
}

/// The app's shadows. None is a single hard drop: each pairs a tight
/// contact shadow that defines the edge with wide, tinted ambient layers
/// that give depth, as light falls in a room.
abstract final class AppShadows {
  /// Lifts the page and cards slightly off the background.
  static List<BoxShadow> paper(AppColors colors) {
    return <BoxShadow>[
      _contact(colors),
      BoxShadow(
        color: colors.ambientShadow.withValues(alpha: 0.5),
        blurRadius: 6,
        spreadRadius: -1,
        offset: const Offset(0, 4),
      ),
      BoxShadow(
        color: colors.ambientShadow.withValues(alpha: 0.5),
        blurRadius: 4,
        spreadRadius: -2,
        offset: const Offset(0, 2),
      ),
    ];
  }

  /// Floating chrome above the page: toolbars, menus, and panels.
  static List<BoxShadow> floating(AppColors colors) {
    return <BoxShadow>[
      _contact(colors),
      BoxShadow(
        color: colors.ambientShadow.withValues(alpha: 0.5),
        blurRadius: 25,
        spreadRadius: -5,
        offset: const Offset(0, 20),
      ),
      BoxShadow(
        color: colors.ambientShadow.withValues(alpha: 0.5),
        blurRadius: 10,
        spreadRadius: -6,
        offset: const Offset(0, 8),
      ),
    ];
  }

  /// [floating], reaching a little further: for a control under a hovering
  /// pointer, or a surface picked up to be moved.
  static List<BoxShadow> raised(AppColors colors) {
    return <BoxShadow>[
      _contact(colors),
      BoxShadow(
        color: colors.ambientShadow.withValues(alpha: 0.6),
        blurRadius: 50,
        spreadRadius: -12,
        offset: const Offset(0, 25),
      ),
      BoxShadow(
        color: colors.ambientShadow.withValues(alpha: 0.5),
        blurRadius: 16,
        spreadRadius: -6,
        offset: const Offset(0, 10),
      ),
    ];
  }

  /// The glow around a surface whose work runs in the background. [breath]
  /// runs from 0 to 1 and back as it pulses.
  static List<BoxShadow> processing(Color accent, double breath) {
    return <BoxShadow>[
      BoxShadow(
        color: accent.withValues(alpha: 0.10 + 0.10 * breath),
        blurRadius: 12 + 4 * breath,
      ),
    ];
  }

  static BoxShadow _contact(AppColors colors) => BoxShadow(
    color: colors.shadow.withValues(alpha: 0.05),
    blurRadius: 2,
    offset: const Offset(0, 1),
  );
}

/// Shared treatments for the frosted chrome. Keeping the opacity, blur, and
/// edge in one place makes menus, panels, and controls read as one system.
abstract final class AppGlass {
  /// How much of the surface's own color covers what is behind it.
  static const double opacity = 0.88;

  /// A deliberately heavy frost: content and ink remain recognizable as
  /// color, but no longer stay legible through translucent chrome.
  static const double blurSigma = 48;

  /// Colors behind the glass come through richer, as through real frosted
  /// glass, rather than washed out by the blur.
  static const double saturation = 1.8;

  static Color surface(AppColors colors) =>
      colors.surface.withValues(alpha: colors.surface.a * opacity);

  static Color muted(AppColors colors) =>
      colors.surfaceMuted.withValues(alpha: colors.surfaceMuted.a * 0.90);

  static Color background(AppColors colors) =>
      colors.background.withValues(alpha: colors.background.a * 0.96);

  static BorderSide border(AppColors colors) =>
      BorderSide(color: colors.glassEdge, width: AppSizes.hairline);

  /// Blurs and saturates whatever is behind a glass surface.
  static final ImageFilter filter = ImageFilter.compose(
    outer: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
    inner: ColorFilter.matrix(_saturate(saturation)),
  );

  /// The CSS `saturate()` matrix.
  static List<double> _saturate(double s) {
    const double r = 0.213, g = 0.715, b = 0.072;
    return <double>[
      r + (1 - r) * s, g - g * s, b - b * s, 0, 0, //
      r - r * s, g + (1 - g) * s, b - b * s, 0, 0, //
      r - r * s, g - g * s, b + (1 - b) * s, 0, 0, //
      0, 0, 0, 1, 0, //
    ];
  }
}

/// Clips and heavily frosts the backdrop behind translucent chrome.
///
/// Use this around surfaces that provide their own translucent decoration.
/// [GlassSurface] already includes it.
class GlassBlur extends StatelessWidget {
  const GlassBlur({
    super.key,
    required this.child,
    this.borderRadius = BorderRadius.zero,
  });

  final Widget child;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(filter: AppGlass.filter, child: child),
    );
  }
}

/// A Material surface whose translucent color always frosts its backdrop.
class GlassMaterial extends StatelessWidget {
  const GlassMaterial({
    super.key,
    required this.child,
    this.color,
    this.borderRadius = BorderRadius.zero,
  });

  final Widget child;
  final Color? color;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    return GlassBlur(
      borderRadius: borderRadius,
      child: Material(
        color: color ?? AppGlass.surface(AppColors.of(context)),
        borderRadius: borderRadius,
        child: child,
      ),
    );
  }
}

/// A frosted, translucent surface for the app's floating chrome.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = BorderRadius.zero,
    this.color,
    this.boxShadow,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final Color? color;
  final List<BoxShadow>? boxShadow;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    // The shadow sits outside the clip, so it is not cut off by it.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: boxShadow,
      ),
      child: GlassBlur(
        borderRadius: borderRadius,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color ?? AppGlass.surface(colors),
            border: Border.fromBorderSide(AppGlass.border(colors)),
            borderRadius: borderRadius,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// The canvas behind every route: the background color, with a faint dot
/// grid for the frosted chrome to blur. The writing page stays opaque.
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key, required this.child});

  /// The distance between dots.
  static const double spacing = 20;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return ColoredBox(
      color: colors.background,
      child: CustomPaint(
        painter: _DotGridPainter(
          color: colors.canvasDot.withValues(alpha: 0.4),
        ),
        isComplex: true,
        child: child,
      ),
    );
  }
}

class _DotGridPainter extends CustomPainter {
  const _DotGridPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const double spacing = GlassBackdrop.spacing;
    final int columns = (size.width / spacing).ceil();
    final int rows = (size.height / spacing).ceil();
    final Float32List points = Float32List(columns * rows * 2);
    int i = 0;
    for (int row = 0; row < rows; row++) {
      for (int column = 0; column < columns; column++) {
        points[i++] = spacing / 2 + column * spacing;
        points[i++] = spacing / 2 + row * spacing;
      }
    }
    canvas.drawRawPoints(
      PointMode.points,
      points,
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_DotGridPainter old) => old.color != color;
}
