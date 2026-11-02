import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'ink_palette.dart';
import 'smoothing_config.dart';
import 'stroke.dart';

/// Limits for the single pen. Widths are logical canvas pixels, so a stroke
/// looks the same at any device pixel ratio.
class PenConfig {
  const PenConfig({
    this.minWidth = 1,
    this.maxWidth = 20,
    this.defaultWidth = 3,
    this.highlighterMinWidth = 4,
    this.highlighterMaxWidth = 40,
    this.highlighterDefaultWidth = 12,
    this.highlighterOpacity = StrokeStyle.defaultHighlighterOpacity,
    this.strokeWidthScale = defaultStrokeWidthScale,
  }) : assert(minWidth > 0),
       assert(maxWidth >= minWidth),
       assert(defaultWidth >= minWidth && defaultWidth <= maxWidth),
       assert(highlighterMinWidth > 0),
       assert(highlighterMaxWidth >= highlighterMinWidth),
       assert(
         highlighterDefaultWidth >= highlighterMinWidth &&
             highlighterDefaultWidth <= highlighterMaxWidth,
       ),
       assert(highlighterOpacity > 0 && highlighterOpacity <= 1),
       assert(strokeWidthScale > 0);

  /// The factor by which configured stroke width levels are scaled to
  /// logical canvas pixels (1 level = 0.5 px).
  static const double defaultStrokeWidthScale = 0.5;

  final double minWidth;
  final double maxWidth;
  final double defaultWidth;

  final double highlighterMinWidth;
  final double highlighterMaxWidth;
  final double highlighterDefaultWidth;

  /// How opaque one highlighter mark is; overlapping marks darken.
  final double highlighterOpacity;

  /// How stroke width levels are scaled to canvas pixels.
  final double strokeWidthScale;

  double minWidthFor(WritingStyle style) =>
      style == WritingStyle.highlighter ? highlighterMinWidth : minWidth;

  double maxWidthFor(WritingStyle style) =>
      style == WritingStyle.highlighter ? highlighterMaxWidth : maxWidth;
}

/// What the next stroke will look like, and how the pen behaves while it
/// is drawn.
///
/// The style, ink, and width are the basic settings. The rest are advanced: how
/// sharp the ends of a stroke are, how much stylus pressure changes the
/// width, and how much the line is stabilized, each off at 0; whether
/// holding the pen still at the end of a stroke turns it into a shape, on
/// by default; and whether scribbling over ink erases it, on by default.
@immutable
class PenSettings {
  const PenSettings({
    required this.ink,
    required this.width,
    this.style = WritingStyle.pen,
    this.highlighterInk = InkPalette.highlighterYellow,
    this.highlighterWidth = 12,
    this.tipSharpness = defaultTipSharpness,
    this.pressureSensitivity = defaultPressureSensitivity,
    this.stabilization = defaultStabilization,
    this.holdToShape = true,
    this.scribbleToErase = true,
    this.swatches = defaultSwatches,
    this.highlighterSwatches = defaultHighlighterSwatches,
  }) : assert(tipSharpness >= 0 && tipSharpness <= 1),
       assert(pressureSensitivity >= 0 && pressureSensitivity <= 1),
       assert(stabilization >= 0 && stabilization <= 1),
       assert(swatches.length == swatchCount),
       assert(highlighterSwatches.length == swatchCount);

  PenSettings.defaults([PenConfig config = const PenConfig()])
    : this(
        ink: InkPalette.ink,
        width: config.defaultWidth,
        highlighterWidth: config.highlighterDefaultWidth,
      );

  /// How many inks the pen, and the highlighter, keep at hand.
  static const int swatchCount = 3;

  /// The pen's inks at hand until the user changes them: black, blue, red.
  static const List<InkColor> defaultSwatches = <InkColor>[
    InkPalette.ink,
    InkPalette.blue,
    InkPalette.red,
  ];

  /// The highlighter's: yellow, green, pink.
  static const List<InkColor> defaultHighlighterSwatches = <InkColor>[
    InkPalette.highlighterYellow,
    InkPalette.highlighterGreen,
    InkPalette.highlighterPink,
  ];

  static const double defaultTipSharpness = 0;
  static const double defaultPressureSensitivity = 0;
  static const double defaultStabilization = 0.25;

  /// The stabilization that gives the smoother exactly its configured
  /// tuning; more smooths harder, less follows the pen more closely, and 0
  /// does not smooth at all.
  static const double _configuredStabilization = 0.5;

  /// How far the minimum cutoff moves, as a power of this, from the
  /// configured tuning up to full stabilization.
  static const double _stabilizationRange = 6;

  /// The cutoff multiplier at 0: high enough that the filter follows the
  /// pen with no visible lag or smoothing.
  static const double _unstabilizedCutoff = 60;

  /// The pen's ink and width. The highlighter remembers its own.
  final InkColor ink;
  final double width;

  /// Which style the writing tool draws in now.
  final WritingStyle style;

  final InkColor highlighterInk;

  /// Logical canvas pixels.
  final double highlighterWidth;

  bool get isHighlighter => style == WritingStyle.highlighter;

  bool get isPencil => style == WritingStyle.pencil;

  /// The ink of the current [style].
  InkColor get activeInk => isHighlighter ? highlighterInk : ink;

  /// The width of the current [style].
  double get activeWidth => isHighlighter ? highlighterWidth : width;

  /// The pen's [swatchCount] inks at hand, shared by the pen and pencil.
  final List<InkColor> swatches;

  /// The highlighter's.
  final List<InkColor> highlighterSwatches;

  /// The inks at hand for the current [style].
  List<InkColor> get activeSwatches =>
      isHighlighter ? highlighterSwatches : swatches;

  /// These settings with the current [style]'s swatch at [index] made
  /// [value], and that ink chosen.
  PenSettings withActiveSwatch(int index, InkColor value) {
    final List<InkColor> next = List<InkColor>.of(activeSwatches)
      ..[index] = value;
    final List<InkColor> fixed = List<InkColor>.unmodifiable(next);
    return isHighlighter
        ? copyWith(highlighterInk: value, highlighterSwatches: fixed)
        : copyWith(ink: value, swatches: fixed);
  }

  /// These settings with the current [style]'s ink changed.
  PenSettings withActiveInk(InkColor value) {
    return isHighlighter
        ? copyWith(highlighterInk: value)
        : copyWith(ink: value);
  }

  /// These settings with the current [style]'s width changed.
  PenSettings withActiveWidth(double value) {
    return isHighlighter
        ? copyWith(highlighterWidth: value)
        : copyWith(width: value);
  }

  /// The look of the next stroke, captured at pointer-down.
  StrokeStyle strokeStyle([PenConfig config = const PenConfig()]) {
    return isHighlighter
        ? StrokeStyle(
            ink: highlighterInk,
            width: highlighterWidth * config.strokeWidthScale,
            writing: WritingStyle.highlighter,
            opacity: config.highlighterOpacity,
          )
        : StrokeStyle(
            ink: ink,
            width: width * config.strokeWidthScale,
            writing: style,
          );
  }

  /// Whether holding still at the end of the next stroke may turn it into
  /// a shape: only for the pen.
  bool get armsHoldToShape => holdToShape && !isHighlighter;

  /// Whether scribbling over ink with the next stroke may erase that ink:
  /// only for the pen.
  bool get armsScribbleToErase => scribbleToErase && !isHighlighter;

  /// How sharply the ends of a stroke narrow, from 0 (round) to 1 (a fine
  /// point).
  final double tipSharpness;

  /// How much pressure changes the width, from 0 (not at all) to 1.
  final double pressureSensitivity;

  /// How strongly the line is smoothed, from 0 (not at all) to 1.
  final double stabilization;

  /// Whether holding the pen still at the end of a stroke turns it into
  /// the shape it was meant to be.
  final bool holdToShape;

  /// Whether a stroke scribbled back and forth over ink erases that ink,
  /// and is not kept itself.
  final bool scribbleToErase;

  /// How the width of the next stroke changes along it. A highlighter is
  /// even from end to end: no taper, no pressure.
  StrokeDynamics get dynamics {
    if (isHighlighter) {
      return StrokeDynamics.none;
    }
    return StrokeDynamics(taper: tipSharpness, pressure: pressureSensitivity);
  }

  /// [base] tuned for this pen's stabilization: unsmoothed at 0, [base]
  /// itself at 50%, and smoothing harder on up to 100%. The cutoff moves
  /// geometrically, so each step of the slider feels alike. The extra
  /// steadiness [base] asks for when drawing slowly fades out with the
  /// slider: full from 50% up, none at 0.
  SmoothingConfig smoothing(SmoothingConfig base) {
    if (stabilization == _configuredStabilization) {
      return base;
    }
    final double factor = stabilization < _configuredStabilization
        ? math
              .pow(
                _unstabilizedCutoff,
                1 - stabilization / _configuredStabilization,
              )
              .toDouble()
        : math
              .pow(
                _stabilizationRange,
                (_configuredStabilization - stabilization) * 2,
              )
              .toDouble();
    return SmoothingConfig(
      minCutoff: base.minCutoff * factor,
      beta: base.beta * factor,
      derivativeCutoff: base.derivativeCutoff,
      minDtSeconds: base.minDtSeconds,
      maxDtSeconds: base.maxDtSeconds,
      maxFinalizationPoints: base.maxFinalizationPoints,
      finalizationSpacing: base.finalizationSpacing,
      endpointTolerance: base.endpointTolerance,
      slowSpeed: base.slowSpeed,
      fastSpeed: base.fastSpeed,
      slowCutoffScale:
          1 -
          (1 - base.slowCutoffScale) *
              math.min(1, stabilization / _configuredStabilization),
    );
  }

  PenSettings copyWith({
    InkColor? ink,
    double? width,
    WritingStyle? style,
    InkColor? highlighterInk,
    double? highlighterWidth,
    double? tipSharpness,
    double? pressureSensitivity,
    double? stabilization,
    bool? holdToShape,
    bool? scribbleToErase,
    List<InkColor>? swatches,
    List<InkColor>? highlighterSwatches,
  }) {
    return PenSettings(
      ink: ink ?? this.ink,
      width: width ?? this.width,
      style: style ?? this.style,
      highlighterInk: highlighterInk ?? this.highlighterInk,
      highlighterWidth: highlighterWidth ?? this.highlighterWidth,
      tipSharpness: tipSharpness ?? this.tipSharpness,
      pressureSensitivity: pressureSensitivity ?? this.pressureSensitivity,
      stabilization: stabilization ?? this.stabilization,
      holdToShape: holdToShape ?? this.holdToShape,
      scribbleToErase: scribbleToErase ?? this.scribbleToErase,
      swatches: swatches ?? this.swatches,
      highlighterSwatches: highlighterSwatches ?? this.highlighterSwatches,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is PenSettings &&
        other.ink == ink &&
        other.width == width &&
        other.style == style &&
        other.highlighterInk == highlighterInk &&
        other.highlighterWidth == highlighterWidth &&
        other.tipSharpness == tipSharpness &&
        other.pressureSensitivity == pressureSensitivity &&
        other.stabilization == stabilization &&
        other.holdToShape == holdToShape &&
        other.scribbleToErase == scribbleToErase &&
        listEquals(other.swatches, swatches) &&
        listEquals(other.highlighterSwatches, highlighterSwatches);
  }

  @override
  int get hashCode => Object.hash(
    ink,
    width,
    style,
    highlighterInk,
    highlighterWidth,
    tipSharpness,
    pressureSensitivity,
    stabilization,
    holdToShape,
    scribbleToErase,
    Object.hashAll(swatches),
    Object.hashAll(highlighterSwatches),
  );
}
