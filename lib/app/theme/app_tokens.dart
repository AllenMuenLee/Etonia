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
  static const double small = 8;
  static const double medium = 14;
  static const double large = 22;
  static const double glass = 24;
  static const double xl = 28;
}

/// Symmetric fallback radii for widgets that do not accept a continuous
/// [RoundedSuperellipseBorder].
abstract final class AppBorderRadius {
  static const BorderRadius medium = BorderRadius.all(
    Radius.circular(AppRadii.medium),
  );
  static const BorderRadius large = BorderRadius.all(
    Radius.circular(AppRadii.large),
  );
  static const BorderRadius glass = BorderRadius.all(
    Radius.circular(AppRadii.glass),
  );
  static const BorderRadius xl = BorderRadius.all(Radius.circular(AppRadii.xl));

  static BorderRadius circular(double radius) => BorderRadius.circular(radius);
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

/// How fast a transition plays, from whether what it shows has been shown
/// before. See `MotionMemory`.
enum MotionPace {
  /// Shown for the first time, or since its cache was let go: it is still
  /// being read, so it arrives slowly and smoothly.
  first,

  /// Shown before and still in memory: it arrives with a slight fade
  /// ([AppMotion.glance]) in place of its movement. Never abrupt.
  revisit,

  /// Not tracked: the token's own timing.
  standard,
}

/// The shared motion vocabulary. Movement uses a spring; durations and curves
/// are reserved for opacity and colour.
abstract final class AppMotion {
  static final SpringDescription snappy =
      SpringDescription.withDurationAndBounce(
        duration: const Duration(milliseconds: 300),
      );
  static final SpringDescription smooth =
      SpringDescription.withDurationAndBounce(
        duration: const Duration(milliseconds: 400),
      );
  static final SpringDescription bouncy =
      SpringDescription.withDurationAndBounce(
        duration: const Duration(milliseconds: 450),
        bounce: 0.25,
      );
  static final SpringDescription sheet =
      SpringDescription.withDurationAndBounce(
        duration: const Duration(milliseconds: 450),
        bounce: 0.05,
      );
  static final SpringDescription _reducedSpring =
      SpringDescription.withDurationAndBounce(duration: reduced);

  static const Duration fadeIn = Duration(milliseconds: 160);
  static const Duration fadeOut = Duration(milliseconds: 110);
  static const Duration zoom = Duration(milliseconds: 280);
  static const Duration press = Duration(milliseconds: 220);
  static const Duration reduced = Duration(milliseconds: 120);
  static const Duration shimmer = Duration(milliseconds: 1600);
  static const Duration bars = Duration(milliseconds: 1200);
  static const Duration pulse = Duration(milliseconds: 2400);
  static const Duration toast = Duration(milliseconds: 2500);
  static const Duration checkDraw = Duration(milliseconds: 180);
  static const Duration errorShake = Duration(milliseconds: 240);
  static const Duration stateFade = Duration(milliseconds: 150);
  static const Duration streamChunk = Duration(milliseconds: 120);

  static const Curve fadeInCurve = Curves.easeOut;
  static const Curve fadeOutCurve = Curves.easeIn;
  static const Curve reducedCurve = Curves.linear;
  static const Curve zoomInCurve = Curves.easeOutCubic;
  static const Curve zoomOutCurve = Curves.easeInCubic;

  /// Scale of a scene at the far edge of a zoom: smaller than rest for what
  /// is arriving from deeper in, larger for what has passed the viewer.
  static const double zoomFar = 0.9;
  static const double zoomNear = 1.1;

  /// A small overshoot for badges and lifts that pop into place.
  static const Curve popCurve = Curves.easeOutBack;

  static const double buttonPressedScale = 0.97;
  static const double iconPressedScale = 0.92;
  static const double cardPressedScale = 0.98;
  static const double pressedScale = buttonPressedScale;

  /// How much longer than its token something runs the first time it is
  /// shown, while it is still being loaded and read: slow and smooth.
  static const double firstLookScale = 1.5;

  /// What something shown again from memory does in place of its movement:
  /// a slight, short fade in where it is. Not a sped-up zoom or slide, which
  /// would read as sudden.
  static const Duration glance = Duration(milliseconds: 180);
  static const Curve glanceCurve = Curves.easeOut;

  /// Loaded items come into view one after another (`StaggeredReveal`):
  /// each fades in where it is, [staggerStep] after the one before, once
  /// [staggerLead] has let the scene before them fade out. A revisit uses
  /// [staggerRevisitStep]. Items past [staggerCount] arrive with the last.
  static const Duration staggerLead = Duration(milliseconds: 60);
  static const Duration staggerStep = Duration(milliseconds: 35);
  static const Duration staggerRevisitStep = Duration(milliseconds: 20);
  static const int staggerCount = 12;

  /// Whether a transition at [pace] moves (zoom, slide, scale) or only
  /// fades in where it is.
  static bool travels(MotionPace pace) => pace != MotionPace.revisit;

  /// How long an entrance with token [duration] lasts at [pace]. Before
  /// playing, ask `MotionMemory` for the pace of what is about to be shown;
  /// [MotionPace.standard] keeps the token. A revisit is a [glance], which
  /// also drops any movement (see [travels]).
  static Duration paced(Duration duration, MotionPace pace) => switch (pace) {
    MotionPace.standard => duration,
    MotionPace.first => duration * firstLookScale,
    MotionPace.revisit => glance,
  };

  /// [token] for a first look, slower with the same bounce. A revisit does
  /// not spring at all: it is a [glance] fade, so [token] is kept for the
  /// movement that cannot be swapped for one.
  static SpringDescription pacedSpring(
    SpringDescription token,
    MotionPace pace,
  ) => pace != MotionPace.first
      ? token
      : SpringDescription.withDurationAndBounce(
          duration: paced(token.duration, pace),
          bounce: token.bounce,
        );

  /// [duration] at [pace], or the reduced cross-fade when motion is reduced.
  static Duration resolvePaced(
    BuildContext context,
    Duration duration,
    MotionPace pace,
  ) => resolve(context, paced(duration, pace));

  static SpringDescription spring(
    BuildContext context,
    SpringDescription token,
  ) => MediaQuery.disableAnimationsOf(context) ? _reducedSpring : token;

  static Duration springDuration(
    BuildContext context,
    SpringDescription token,
  ) => MediaQuery.disableAnimationsOf(context) ? reduced : token.duration;

  static Duration resolve(BuildContext context, Duration duration) {
    return MediaQuery.disableAnimationsOf(context) ? reduced : duration;
  }

  static final AnimationStyle popupStyle = AnimationStyle(
    duration: snappy.duration,
    reverseDuration: fadeOut,
    curve: fadeInCurve,
    reverseCurve: fadeOutCurve,
  );
  static final AnimationStyle sheetStyle = AnimationStyle(
    duration: sheet.duration,
    reverseDuration: smooth.duration,
    curve: fadeInCurve,
    reverseCurve: fadeOutCurve,
  );

  /// [popupStyle] for a popover shown at [pace]: slower the first time.
  /// A menu unfolds rather than fades, so a revisit keeps the standard
  /// timing rather than being rushed.
  static AnimationStyle pacedPopupStyle(MotionPace pace) =>
      pace != MotionPace.first
      ? popupStyle
      : AnimationStyle(
          duration: paced(snappy.duration, pace),
          reverseDuration: fadeOut,
          curve: fadeInCurve,
          reverseCurve: fadeOutCurve,
        );

  /// [sheetStyle] for a sheet shown at [pace]: slower the first time. A
  /// sheet must rise, so a revisit keeps the standard timing rather than
  /// being rushed.
  static AnimationStyle pacedSheetStyle(MotionPace pace) =>
      pace != MotionPace.first
      ? sheetStyle
      : AnimationStyle(
          duration: paced(sheet.duration, pace),
          reverseDuration: smooth.duration,
          curve: fadeInCurve,
          reverseCurve: fadeOutCurve,
        );
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
    required this.success,
    required this.selected,
    required this.focus,
    required this.shadow,
    required this.pageRule,
    required this.pageMarginRule,
    required this.ambientShadow,
    required this.glassEdge,
    required this.canvasDot,
    required this.recordingSurface,
    required this.recordingForeground,
    required this.scrubberTrack,
    required this.highlighters,
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

  /// Positive status only; never a brand or selection colour.
  final Color success;

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

  /// High-contrast audio chrome, independent of translucent page content.
  final Color recordingSurface;
  final Color recordingForeground;
  final Color scrubberTrack;

  /// Colour belongs to user content. These are the only non-status hues in
  /// app chrome.
  final List<Color> highlighters;

  static const AppColors light = AppColors(
    background: Color(0xFFF2F2F4),
    surface: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFE9E9EC),
    writingSurface: Color(0xFFFFFFFF),
    textPrimary: Color(0xFF0A0A0B),
    textSecondary: Color(0xFF6B6B70),
    divider: Color(0x1A0A0A0B),
    accent: Color(0xFF0A0A0B),
    onAccent: Color(0xFFFFFFFF),
    danger: Color(0xFFE5362B),
    success: Color(0xFF1E9E4A),
    selected: Color(0x140A0A0B),
    focus: Color(0xFF0A0A0B),
    shadow: Color(0xFF000000),
    pageRule: Color(0xFFE1E1E4),
    pageMarginRule: Color(0xFFE8C8C8),
    ambientShadow: Color(0xFFB8B8BD),
    glassEdge: Color(0xB3FFFFFF),
    canvasDot: Color(0xFFD8D8DC),
    recordingSurface: Color(0xFFFFFFFF),
    recordingForeground: Color(0xFF0A0A0B),
    scrubberTrack: Color(0xFFC7C7CC),
    highlighters: <Color>[
      Color(0xFFFFE66D),
      Color(0xFFFFB48A),
      Color(0xFFFF9DB8),
      Color(0xFFC9B8FF),
      Color(0xFF8FD3FF),
      Color(0xFF8FE8C4),
    ],
  );

  static const AppColors dark = AppColors(
    background: Color(0xFF000000),
    surface: Color(0xFF151517),
    surfaceMuted: Color(0xFF232326),
    writingSurface: Color(0xFF161618),
    textPrimary: Color(0xFFF5F5F7),
    textSecondary: Color(0xFF9A9AA0),
    divider: Color(0x24FFFFFF),
    accent: Color(0xFFFFFFFF),
    onAccent: Color(0xFF000000),
    danger: Color(0xFFFF6B61),
    success: Color(0xFF4CD27A),
    selected: Color(0x24FFFFFF),
    focus: Color(0xFFFFFFFF),
    shadow: Color(0xFF000000),
    pageRule: Color(0xFF303034),
    pageMarginRule: Color(0xFF4A3436),
    ambientShadow: Color(0xFF000000),
    glassEdge: Color(0x6BFFFFFF),
    canvasDot: Color(0xFF303034),
    recordingSurface: Color(0xFF1E1E1E),
    recordingForeground: Color(0xFFFFFFFF),
    scrubberTrack: Color(0xFF48484A),
    highlighters: <Color>[
      Color(0xFFD9C45D),
      Color(0xFFD99975),
      Color(0xFFD9869C),
      Color(0xFFAB9CD9),
      Color(0xFF7AB3D9),
      Color(0xFF7AC5A7),
    ],
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
    Color? success,
    Color? selected,
    Color? focus,
    Color? shadow,
    Color? pageRule,
    Color? pageMarginRule,
    Color? ambientShadow,
    Color? glassEdge,
    Color? canvasDot,
    Color? recordingSurface,
    Color? recordingForeground,
    Color? scrubberTrack,
    List<Color>? highlighters,
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
      success: success ?? this.success,
      selected: selected ?? this.selected,
      focus: focus ?? this.focus,
      shadow: shadow ?? this.shadow,
      pageRule: pageRule ?? this.pageRule,
      pageMarginRule: pageMarginRule ?? this.pageMarginRule,
      ambientShadow: ambientShadow ?? this.ambientShadow,
      glassEdge: glassEdge ?? this.glassEdge,
      canvasDot: canvasDot ?? this.canvasDot,
      recordingSurface: recordingSurface ?? this.recordingSurface,
      recordingForeground: recordingForeground ?? this.recordingForeground,
      scrubberTrack: scrubberTrack ?? this.scrubberTrack,
      highlighters: highlighters ?? this.highlighters,
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
      success: Color.lerp(success, other.success, t)!,
      selected: Color.lerp(selected, other.selected, t)!,
      focus: Color.lerp(focus, other.focus, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
      pageRule: Color.lerp(pageRule, other.pageRule, t)!,
      pageMarginRule: Color.lerp(pageMarginRule, other.pageMarginRule, t)!,
      ambientShadow: Color.lerp(ambientShadow, other.ambientShadow, t)!,
      glassEdge: Color.lerp(glassEdge, other.glassEdge, t)!,
      canvasDot: Color.lerp(canvasDot, other.canvasDot, t)!,
      recordingSurface: Color.lerp(
        recordingSurface,
        other.recordingSurface,
        t,
      )!,
      recordingForeground: Color.lerp(
        recordingForeground,
        other.recordingForeground,
        t,
      )!,
      scrubberTrack: Color.lerp(scrubberTrack, other.scrubberTrack, t)!,
      highlighters: <Color>[
        for (int i = 0; i < highlighters.length; i++)
          Color.lerp(highlighters[i], other.highlighters[i], t)!,
      ],
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

/// Shared treatments for the tinted chrome. Keeping opacity and edge treatment
/// in one place makes menus, panels, and controls read as one system.
abstract final class AppGlass {
  static const double blurSigma = 24;
  static const double saturation = 1.6;
  static const double fullOpacityLight = 0.60;
  static const double fullOpacityDark = 0.50;
  static const double tintedOpacity = 0.86;

  static Color surface(AppColors colors) =>
      colors.surface.withValues(alpha: colors.surface.a * tintedOpacity);

  static Color muted(AppColors colors) =>
      colors.surfaceMuted.withValues(alpha: colors.surfaceMuted.a * 0.90);

  static Color background(AppColors colors) =>
      colors.background.withValues(alpha: colors.background.a * 0.96);

  static BorderSide border(AppColors colors) =>
      BorderSide(color: colors.glassEdge, width: AppSizes.hairline);

  static final ImageFilter filter = ImageFilter.compose(
    outer: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
    inner: ColorFilter.matrix(_saturate(saturation)),
  );

  static List<double> _saturate(double value) {
    const double r = 0.213, g = 0.715, b = 0.072;
    return <double>[
      r + (1 - r) * value,
      g - g * value,
      b - b * value,
      0,
      0,
      r - r * value,
      g + (1 - g) * value,
      b - b * value,
      0,
      0,
      r - r * value,
      g - g * value,
      b + (1 - b) * value,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ];
  }
}

enum GlassQuality { full, tinted }

/// Clips the tinted surface used by floating chrome.
///
/// This intentionally does not live-filter the backdrop. On a tablet-sized
/// editor, several simultaneous backdrop filters dominate raster time while a
/// page, palette, or sheet moves. [GlassSurface] already includes this clip.
class GlassBlur extends StatelessWidget {
  const GlassBlur({
    super.key,
    required this.child,
    this.borderRadius = BorderRadius.zero,
    this.quality = GlassQuality.tinted,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final GlassQuality quality;

  @override
  Widget build(BuildContext context) {
    final Widget filtered = quality == GlassQuality.full
        ? BackdropFilter.grouped(filter: AppGlass.filter, child: child)
        : child;
    if (borderRadius == BorderRadius.zero) return filtered;
    return ClipRSuperellipse(borderRadius: borderRadius, child: filtered);
  }
}

/// A Material surface with the app's high-opacity glass tint.
class GlassMaterial extends StatelessWidget {
  const GlassMaterial({
    super.key,
    required this.child,
    this.color,
    this.borderRadius = BorderRadius.zero,
    this.quality = GlassQuality.tinted,
  });

  final Widget child;
  final Color? color;
  final BorderRadius borderRadius;
  final GlassQuality quality;

  @override
  Widget build(BuildContext context) {
    return GlassBlur(
      borderRadius: borderRadius,
      quality: quality,
      child: Material(
        color: color ?? AppGlass.surface(AppColors.of(context)),
        borderRadius: borderRadius,
        child: child,
      ),
    );
  }
}

/// A softly tinted surface for the app's floating chrome.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = BorderRadius.zero,
    this.color,
    this.boxShadow,
    this.quality = GlassQuality.tinted,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final Color? color;
  final List<BoxShadow>? boxShadow;
  final GlassQuality quality;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color rimLight = dark ? colors.accent : colors.onAccent;
    final Color tint =
        color ??
        colors.surface.withValues(
          alpha: quality == GlassQuality.tinted
              ? AppGlass.tintedOpacity
              : dark
              ? AppGlass.fullOpacityDark
              : AppGlass.fullOpacityLight,
        );
    // The shadow sits outside the clip, so it is not cut off by it.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: boxShadow,
      ),
      child: GlassBlur(
        borderRadius: borderRadius,
        quality: quality,
        child: DecoratedBox(
          decoration: BoxDecoration(color: tint, borderRadius: borderRadius),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.fromBorderSide(AppGlass.border(colors)),
              borderRadius: borderRadius,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  rimLight.withValues(alpha: dark ? 0.08 : 0.14),
                  rimLight.withValues(alpha: 0),
                ],
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// The canvas behind every route: the background color, with a faint dot
/// grid that gives the app's chrome a sense of depth. The writing page stays
/// opaque.
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key, required this.child, this.showDots = false});

  /// The distance between dots.
  static const double spacing = 20;

  final Widget child;
  final bool showDots;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final Widget ground = ColoredBox(color: colors.background, child: child);
    if (!showDots) return ground;
    return CustomPaint(
      painter: _DotGridPainter(color: colors.canvasDot.withValues(alpha: 0.4)),
      isComplex: true,
      child: ground,
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
