import 'dart:typed_data' show Float32List;
import 'dart:ui' show FontFeature, ImageFilter, PointMode;

import 'package:flutter/material.dart';

/// Spacing on a 4-logical-pixel grid.
abstract final class AppSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double mdPlus = 20;
  static const double lg = 24;
  static const double xl = 32;
  static const double xlPlus = 40;
  static const double xxl = 48;
}

/// Typography helpers that sit beside the [TextTheme].
abstract final class AppText {
  /// Fixed-width digits for timers, scores, dates, and statistics, so they do
  /// not jiggle as they change.
  static const List<FontFeature> tabular = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  static TextStyle tabularFigures(TextStyle? style) => (style ?? const TextStyle())
      .copyWith(fontFeatures: tabular);
}

/// The only corner radii used by the app. Compact controls use [small];
/// buttons and inputs [medium]; cards and floating panels [large]; dialogs
/// [xl]. Avoid anything larger on ordinary surfaces.
abstract final class AppRadii {
  static const double xs = 4;
  static const double small = 8;
  static const double medium = 12;
  static const double large = 16;
  static const double glass = 16;
  static const double xl = 22;
  static const double xxl = 28;
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
  static const BorderRadius small = BorderRadius.all(
    Radius.circular(AppRadii.small),
  );

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

  /// Duration tokens for colour and opacity changes: fast controls, standard
  /// interface transitions, and large panels.
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration standard = Duration(milliseconds: 220);
  static const Duration panel = Duration(milliseconds: 280);

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
///
/// The palette is warm-neutral with a single lavender brand accent. The
/// legacy mascot names ([pencil], [sprout], [lilac], [fold]) are kept so that
/// call sites need not change, but they now alias the brand and status tokens.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.background,
    required this.backgroundSecondary,
    required this.surface,
    required this.surfaceMuted,
    required this.surfaceElevated,
    required this.writingSurface,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.divider,
    required this.borderStrong,
    required this.accent,
    required this.brandHover,
    required this.brandPressed,
    required this.brandSubtle,
    required this.accentText,
    required this.onAccent,
    required this.danger,
    required this.success,
    required this.warning,
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
    required this.pencil,
    required this.sprout,
    required this.lilac,
    required this.fold,
    required this.highlighters,
  });

  /// backgroundPrimary: the app chrome behind everything else.
  final Color background;

  /// backgroundSecondary: sidebars and other secondary navigation surfaces.
  final Color backgroundSecondary;

  /// surfacePrimary: cards, panels, and floating chrome.
  final Color surface;

  /// surfaceSecondary: a quiet fill set into [surface] or [background]: text
  /// fields, slider tracks, unselected chips, and tonal buttons.
  final Color surfaceMuted;

  /// surfaceElevated: dialogs and popovers.
  final Color surfaceElevated;

  /// The page the user writes on. Independent of the app theme's chrome.
  final Color writingSurface;

  final Color textPrimary;
  final Color textSecondary;

  /// Muted labels and placeholders.
  final Color textTertiary;

  /// borderSubtle: dividers and delicate borders.
  final Color divider;

  /// borderStrong: a more prominent border.
  final Color borderStrong;

  /// brandPrimary: the interactive accent. Fills primary buttons and marks
  /// active controls. Contrast against [onAccent] is for medium-weight labels;
  /// use [accentText] when the accent is the colour of body-size text.
  final Color accent;
  final Color brandHover;
  final Color brandPressed;

  /// A faint brand tint for subtle surfaces.
  final Color brandSubtle;

  /// The accent as the colour of small text: dark enough for AA on [surface].
  final Color accentText;
  final Color onAccent;

  /// Destructive actions, such as Delete, and errors.
  final Color danger;

  /// Positive status only; never a brand or selection colour.
  final Color success;
  final Color warning;

  /// selectedSurface: fill behind a selected control.
  final Color selected;

  /// Keyboard focus ring.
  final Color focus;

  /// A dark neutral: the colour of every shadow and scrim.
  final Color shadow;

  /// Lines, grid, and dots printed on the page, under the ink.
  final Color pageRule;

  /// The margin rule of lined paper.
  final Color pageMarginRule;

  /// The colour of the wide layer of a shadow (a dark neutral, never tinted).
  final Color ambientShadow;

  /// The hairline edge of floating surfaces.
  final Color glassEdge;

  /// The dots of the grid the app's chrome floats over.
  final Color canvasDot;

  /// High-contrast audio chrome, independent of translucent page content.
  final Color recordingSurface;
  final Color recordingForeground;
  final Color scrubberTrack;

  /// A soft lavender wash for text selection and ink ripples.
  final Color pencil;

  /// Alias of the positive status colour.
  final Color sprout;

  /// Alias of the faint brand tint.
  final Color lilac;

  /// The shade of a folded corner: a warm neutral.
  final Color fold;

  /// Colour belongs to user content. These six are the marks users make.
  final List<Color> highlighters;

  static const AppColors light = AppColors(
    background: Color(0xFFFAF9F7),
    backgroundSecondary: Color(0xFFF3F2F0),
    surface: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFF7F6F4),
    surfaceElevated: Color(0xFFFFFFFF),
    writingSurface: Color(0xFFFFFFFF),
    textPrimary: Color(0xFF343239),
    textSecondary: Color(0xFF706D76),
    textTertiary: Color(0xFF96919C),
    divider: Color(0xFFE9E6E9),
    borderStrong: Color(0xFFD4CFD8),
    // The light brand ramp sits one step darker than the design table's
    // #8873B4 / #7761A5 / #66518F so that white on the brand fill reaches AA
    // (5.2:1 rather than 4.1:1); see docs/design_language.md.
    accent: Color(0xFF7761A5),
    brandHover: Color(0xFF66518F),
    brandPressed: Color(0xFF574479),
    brandSubtle: Color(0xFFF0EBF8),
    accentText: Color(0xFF66518F),
    onAccent: Color(0xFFFFFFFF),
    danger: Color(0xFFC45757),
    success: Color(0xFF408B75),
    warning: Color(0xFFB68036),
    selected: Color(0xFFEEE8F7),
    focus: Color(0xFF7761A5),
    shadow: Color(0xFF1B1A1F),
    pageRule: Color(0xFFE9E5EE),
    pageMarginRule: Color(0xFFEFC9CC),
    ambientShadow: Color(0xFF1B1A1F),
    glassEdge: Color(0xFFE9E6E9),
    canvasDot: Color(0xFFE9E6E9),
    recordingSurface: Color(0xFFFFFFFF),
    recordingForeground: Color(0xFF343239),
    scrubberTrack: Color(0xFFD4CFD8),
    pencil: Color(0xFFDDD3EF),
    sprout: Color(0xFF408B75),
    lilac: Color(0xFFF0EBF8),
    fold: Color(0xFFEFEDEA),
    highlighters: <Color>[
      Color(0xFFFFF09E),
      Color(0xFFFFD7BE),
      Color(0xFFFFAEC5),
      Color(0xFFE1CCFF),
      Color(0xFFBDE4FF),
      Color(0xFFB8EDB1),
    ],
  );

  /// Layered charcoal, never pure black; not an inversion of [light].
  static const AppColors dark = AppColors(
    background: Color(0xFF1C1B20),
    backgroundSecondary: Color(0xFF24232A),
    surface: Color(0xFF2B2A31),
    surfaceMuted: Color(0xFF333139),
    surfaceElevated: Color(0xFF393740),
    writingSurface: Color(0xFF1E1A24),
    textPrimary: Color(0xFFF5F2F6),
    textSecondary: Color(0xFFB7B1BD),
    textTertiary: Color(0xFF8E8795),
    divider: Color(0xFF3C3842),
    borderStrong: Color(0xFF56505D),
    accent: Color(0xFFB8A2DF),
    brandHover: Color(0xFFC5B3E7),
    brandPressed: Color(0xFFA48CD4),
    brandSubtle: Color(0xFF332A40),
    accentText: Color(0xFFB8A2DF),
    onAccent: Color(0xFF1C1B20),
    danger: Color(0xFFDF898B),
    success: Color(0xFF79BFA6),
    warning: Color(0xFFDDB16C),
    selected: Color(0xFF40344E),
    focus: Color(0xFFB8A2DF),
    shadow: Color(0xFF000000),
    pageRule: Color(0xFF332C3B),
    pageMarginRule: Color(0xFF5A3E48),
    ambientShadow: Color(0xFF000000),
    glassEdge: Color(0xFF3C3842),
    canvasDot: Color(0xFF3C3842),
    recordingSurface: Color(0xFF333139),
    recordingForeground: Color(0xFFF5F2F6),
    scrubberTrack: Color(0xFF56505D),
    pencil: Color(0xFF55456F),
    sprout: Color(0xFF79BFA6),
    lilac: Color(0xFF332A40),
    fold: Color(0xFF3C3842),
    highlighters: <Color>[
      Color(0xFFD9C97A),
      Color(0xFFD9A98A),
      Color(0xFFD98CA8),
      Color(0xFFB79CD9),
      Color(0xFF8AB9D9),
      Color(0xFF7CC07A),
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
    Color? backgroundSecondary,
    Color? surface,
    Color? surfaceMuted,
    Color? surfaceElevated,
    Color? writingSurface,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? divider,
    Color? borderStrong,
    Color? accent,
    Color? brandHover,
    Color? brandPressed,
    Color? brandSubtle,
    Color? accentText,
    Color? onAccent,
    Color? danger,
    Color? success,
    Color? warning,
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
    Color? pencil,
    Color? sprout,
    Color? lilac,
    Color? fold,
    List<Color>? highlighters,
  }) {
    return AppColors(
      background: background ?? this.background,
      backgroundSecondary: backgroundSecondary ?? this.backgroundSecondary,
      surface: surface ?? this.surface,
      surfaceMuted: surfaceMuted ?? this.surfaceMuted,
      surfaceElevated: surfaceElevated ?? this.surfaceElevated,
      writingSurface: writingSurface ?? this.writingSurface,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      divider: divider ?? this.divider,
      borderStrong: borderStrong ?? this.borderStrong,
      accent: accent ?? this.accent,
      brandHover: brandHover ?? this.brandHover,
      brandPressed: brandPressed ?? this.brandPressed,
      brandSubtle: brandSubtle ?? this.brandSubtle,
      accentText: accentText ?? this.accentText,
      onAccent: onAccent ?? this.onAccent,
      danger: danger ?? this.danger,
      success: success ?? this.success,
      warning: warning ?? this.warning,
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
      pencil: pencil ?? this.pencil,
      sprout: sprout ?? this.sprout,
      lilac: lilac ?? this.lilac,
      fold: fold ?? this.fold,
      highlighters: highlighters ?? this.highlighters,
    );
  }

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) {
      return this;
    }
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      background: mix(background, other.background),
      backgroundSecondary: mix(backgroundSecondary, other.backgroundSecondary),
      surface: mix(surface, other.surface),
      surfaceMuted: mix(surfaceMuted, other.surfaceMuted),
      surfaceElevated: mix(surfaceElevated, other.surfaceElevated),
      writingSurface: mix(writingSurface, other.writingSurface),
      textPrimary: mix(textPrimary, other.textPrimary),
      textSecondary: mix(textSecondary, other.textSecondary),
      textTertiary: mix(textTertiary, other.textTertiary),
      divider: mix(divider, other.divider),
      borderStrong: mix(borderStrong, other.borderStrong),
      accent: mix(accent, other.accent),
      brandHover: mix(brandHover, other.brandHover),
      brandPressed: mix(brandPressed, other.brandPressed),
      brandSubtle: mix(brandSubtle, other.brandSubtle),
      accentText: mix(accentText, other.accentText),
      onAccent: mix(onAccent, other.onAccent),
      danger: mix(danger, other.danger),
      success: mix(success, other.success),
      warning: mix(warning, other.warning),
      selected: mix(selected, other.selected),
      focus: mix(focus, other.focus),
      shadow: mix(shadow, other.shadow),
      pageRule: mix(pageRule, other.pageRule),
      pageMarginRule: mix(pageMarginRule, other.pageMarginRule),
      ambientShadow: mix(ambientShadow, other.ambientShadow),
      glassEdge: mix(glassEdge, other.glassEdge),
      canvasDot: mix(canvasDot, other.canvasDot),
      recordingSurface: mix(recordingSurface, other.recordingSurface),
      recordingForeground: mix(recordingForeground, other.recordingForeground),
      scrubberTrack: mix(scrubberTrack, other.scrubberTrack),
      pencil: mix(pencil, other.pencil),
      sprout: mix(sprout, other.sprout),
      lilac: mix(lilac, other.lilac),
      fold: mix(fold, other.fold),
      highlighters: <Color>[
        for (int i = 0; i < highlighters.length; i++)
          mix(highlighters[i], other.highlighters[i]),
      ],
    );
  }
}

/// The app's elevation tokens. Light themes get very soft neutral shadows;
/// dark themes rely on tonal surfaces and borders, so their shadows are only a
/// whisper. Never stack more than one.
abstract final class AppShadows {
  static List<BoxShadow> _elevation(
    AppColors colors, {
    required double dy,
    required double blur,
    required double opacity,
  }) {
    final bool dark = colors.background.computeLuminance() < 0.5;
    return <BoxShadow>[
      BoxShadow(
        color: colors.shadow.withValues(alpha: dark ? opacity * 2.5 : opacity),
        blurRadius: blur,
        offset: Offset(0, dy),
      ),
    ];
  }

  /// Low elevation: cards and the page lifted slightly off the background.
  static List<BoxShadow> paper(AppColors colors) =>
      _elevation(colors, dy: 2, blur: 8, opacity: 0.04);

  /// Medium elevation: toolbars, menus, and panels floating over the page.
  static List<BoxShadow> floating(AppColors colors) =>
      _elevation(colors, dy: 6, blur: 18, opacity: 0.07);

  /// High elevation: dialogs, or a surface picked up to be moved.
  static List<BoxShadow> raised(AppColors colors) =>
      _elevation(colors, dy: 12, blur: 32, opacity: 0.10);

  /// The glow around a surface whose work runs in the background. [breath]
  /// runs from 0 to 1 and back as it pulses.
  static List<BoxShadow> processing(Color accent, double breath) {
    return <BoxShadow>[
      BoxShadow(
        color: accent.withValues(alpha: 0.08 + 0.08 * breath),
        blurRadius: 12 + 4 * breath,
      ),
    ];
  }
}

/// Shared treatments for the chrome. Keeping opacity and edge treatment in
/// one place makes menus, panels, and controls read as one system. The name
/// is historical: surfaces are plain, opaque, and bordered, not frosted.
abstract final class AppGlass {
  static const double blurSigma = 24;
  static const double saturation = 1.25;
  static const double fullOpacityLight = 1.0;
  static const double fullOpacityDark = 1.0;
  static const double tintedOpacity = 1.0;

  static Color surface(AppColors colors) => colors.surface;

  static Color muted(AppColors colors) => colors.surfaceMuted;

  static Color background(AppColors colors) => colors.background;

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
    // Surfaces are opaque, so there is nothing to blur behind them.
    if (borderRadius == BorderRadius.zero) return child;
    return ClipRSuperellipse(borderRadius: borderRadius, child: child);
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
    final Color tint = color ?? colors.surface;
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
          decoration: BoxDecoration(
            color: tint,
            borderRadius: borderRadius,
            border: Border.fromBorderSide(AppGlass.border(colors)),
          ),
          child: child,
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
