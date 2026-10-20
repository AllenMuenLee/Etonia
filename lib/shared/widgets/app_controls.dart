import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import '../../app/theme/app_icons.dart';
import 'pressable.dart';

// The small controls every panel is built from, so the pen's options, the
// eraser's, the page panel, and the settings all look and behave alike.

/// A quiet round button, smaller to the eye than its 48-pixel touch
/// target: for closing a panel, or sending from a field.
class CompactIconButton extends StatelessWidget {
  const CompactIconButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    this.background,
    this.foreground,
    this.size = 32,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final IconData icon;

  /// The circle's fill and the glyph's color while enabled; quiet by
  /// default.
  final Color? background;
  final Color? foreground;

  /// The circle's diameter.
  final double size;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final bool enabled = onPressed != null;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        shape: const CircleBorder(),
        padding: EdgeInsets.zero,
      ),
      icon: Pressable(
        enabled: enabled,
        child: AnimatedContainer(
          duration: AppMotion.resolve(context, AppMotion.fast),
          curve: AppMotion.standard,
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: enabled
                ? background ?? colors.surfaceMuted
                : colors.surfaceMuted,
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            size: 18,
            color: enabled
                ? foreground ?? colors.textSecondary
                : colors.textSecondary.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}

/// Names a group of controls: small, secondary, in sentence case.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.label, {super.key, this.trailing});

  final String label;

  /// Sits at the end of the line, such as a [ValuePill].
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final Text text = Text(
      label,
      style: Theme.of(context).textTheme.labelMedium,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: trailing == null
          ? text
          : Row(
              children: <Widget>[
                Expanded(child: text),
                trailing!,
              ],
            ),
    );
  }
}

/// A setting's current value, in a small pill: tinted in the accent while
/// it is in effect, quiet while [muted], such as when it is off.
class ValuePill extends StatelessWidget {
  const ValuePill(this.text, {super.key, this.muted = false});

  final String text;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return AnimatedContainer(
      duration: AppMotion.resolve(context, AppMotion.fast),
      curve: AppMotion.standard,
      constraints: const BoxConstraints(minWidth: 48),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: AppSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: muted ? colors.surfaceMuted : colors.selected,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.labelMedium!.copyWith(
          color: muted ? colors.textSecondary : colors.accent,
          fontWeight: FontWeight.w600,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// A [Slider] on a slim track with a ringed thumb.
class AppSlider extends StatelessWidget {
  const AppSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.semanticFormatterCallback,
  });

  final double value;
  final double min;
  final double max;
  final int? divisions;
  final SemanticFormatterCallback? semanticFormatterCallback;

  /// Null disables the slider.
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final bool enabled = onChanged != null;
    final Color ring = enabled ? colors.accent : colors.divider;
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        thumbShape: RingThumbShape(
          fill: colors.surface,
          ring: ring,
          shadow: colors.shadow,
        ),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
      ),
      child: Slider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        semanticFormatterCallback: semanticFormatterCallback,
        onChanged: onChanged,
      ),
    );
  }
}

/// A white thumb with a colored ring that grows a touch while dragged.
class RingThumbShape extends SliderComponentShape {
  const RingThumbShape({
    required this.fill,
    required this.ring,
    required this.shadow,
  });

  static const double _radius = 10;

  final Color fill;
  final Color ring;
  final Color shadow;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    return const Size.fromRadius(_radius);
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final Canvas canvas = context.canvas;
    final double radius = _radius + 2 * activationAnimation.value;
    canvas
      ..drawCircle(
        center.translate(0, 1.5),
        radius,
        Paint()
          ..color = shadow.withValues(alpha: 0.16)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      )
      ..drawCircle(center, radius, Paint()..color = fill)
      ..drawCircle(
        center,
        radius - 1.25,
        Paint()
          ..color = ring
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
  }
}

/// A slim on/off track. It only shows the state; the row it sits in takes
/// the tap.
class ToggleTrack extends StatelessWidget {
  const ToggleTrack({super.key, required this.value});

  final bool value;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final Duration duration = AppMotion.resolve(context, AppMotion.medium);
    return AnimatedContainer(
      duration: duration,
      curve: AppMotion.standard,
      width: 40,
      height: 24,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: value ? colors.accent : colors.divider,
        borderRadius: BorderRadius.circular(999),
      ),
      child: AnimatedAlign(
        duration: duration,
        curve: AppMotion.standard,
        alignment: value
            ? AlignmentDirectional.centerEnd
            : AlignmentDirectional.centerStart,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: value ? colors.onAccent : colors.surface,
            shape: BoxShape.circle,
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: colors.shadow.withValues(alpha: 0.18),
                blurRadius: 2,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: const SizedBox.square(dimension: 18),
        ),
      ),
    );
  }
}

/// A setting's name over a one-line hint, with [trailing] at the end.
class SettingText extends StatelessWidget {
  const SettingText({super.key, required this.label, this.hint});

  final String label;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: text.bodyMedium!.copyWith(fontWeight: FontWeight.w500),
        ),
        if (hint != null) ...<Widget>[
          const SizedBox(height: AppSpacing.xxs),
          Text(hint!, style: text.bodySmall),
        ],
      ],
    );
  }
}

/// A labelled on/off setting. The whole row toggles it.
class ToggleSetting extends StatelessWidget {
  const ToggleSetting({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.hint,
    this.icon,
  });

  final String label;
  final String? hint;
  final bool value;
  final ValueChanged<bool> onChanged;

  /// Leads the row, in the secondary text color.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Semantics(
      toggled: value,
      button: true,
      label: label,
      hint: hint,
      excludeSemantics: true,
      onTap: () => onChanged(!value),
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(AppRadii.medium),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: AppSizes.minTouchTarget + AppSpacing.xs,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Row(
              children: <Widget>[
                if (icon != null) ...<Widget>[
                  Icon(icon, size: 20, color: colors.textSecondary),
                  const SizedBox(width: AppSpacing.sm),
                ],
                Expanded(
                  child: SettingText(label: label, hint: hint),
                ),
                const SizedBox(width: AppSpacing.md),
                ToggleTrack(value: value),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One choice of a few, as a segment of a quiet track; the chosen one is
/// raised on a card and marked with a check, not by color alone.
class SegmentedChoice<T> extends StatelessWidget {
  const SegmentedChoice({
    super.key,
    required this.options,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
    this.iconOf,
    this.keyOf,
  });

  final List<T> options;
  final T selected;
  final String Function(T option) labelOf;
  final IconData? Function(T option)? iconOf;
  final Key? Function(T option)? keyOf;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final Duration duration = AppMotion.resolve(context, AppMotion.fast);
    const double inset = 3;
    final BorderRadius outer = BorderRadius.circular(AppRadii.medium);
    final BorderRadius inner = BorderRadius.circular(AppRadii.medium - inset);
    return Container(
      height: AppSizes.minTouchTarget - 4,
      padding: const EdgeInsets.all(inset),
      decoration: BoxDecoration(
        color: AppGlass.muted(colors),
        borderRadius: outer,
      ),
      child: Row(
        children: <Widget>[
          for (final T option in options)
            Expanded(
              child: Builder(
                builder: (BuildContext context) {
                  final bool on = option == selected;
                  final IconData? icon = on
                      ? AppIcons.check
                      : iconOf?.call(option);
                  final Color foreground = on
                      ? colors.textPrimary
                      : colors.textSecondary;
                  return Semantics(
                    key: keyOf?.call(option),
                    container: true,
                    button: true,
                    inMutuallyExclusiveGroup: true,
                    selected: on,
                    label: labelOf(option),
                    excludeSemantics: true,
                    onTap: () => onSelected(option),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onSelected(option),
                      child: Pressable(
                        child: AnimatedContainer(
                          duration: duration,
                          curve: AppMotion.standard,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: on
                                ? colors.surface
                                : colors.surface.withValues(alpha: 0),
                            borderRadius: inner,
                            boxShadow: on
                                ? <BoxShadow>[
                                    BoxShadow(
                                      color: colors.shadow.withValues(
                                        alpha: 0.10,
                                      ),
                                      blurRadius: 3,
                                      offset: const Offset(0, 1),
                                    ),
                                  ]
                                : const <BoxShadow>[],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              if (icon != null) ...<Widget>[
                                Icon(icon, size: 16, color: foreground),
                                const SizedBox(width: AppSpacing.xxs),
                              ],
                              // A long label in a narrow panel fades out
                              // rather than overflowing.
                              Flexible(
                                child: Text(
                                  labelOf(option),
                                  maxLines: 1,
                                  softWrap: false,
                                  overflow: TextOverflow.fade,
                                  style: text.labelLarge!.copyWith(
                                    color: foreground,
                                    fontWeight: on
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// A recessed, shaded capsule gauge with a lit, glowing fill bar for
/// showing remaining AI token allowance.
class TokenMeterBar extends StatelessWidget {
  const TokenMeterBar({
    super.key,
    required this.fraction,
    this.height = 10,
    this.width,
    this.semanticsLabel,
    this.semanticsValue,
  });

  /// Fill ratio from `0.0` (empty) to `1.0` (full).
  final double fraction;
  final double height;
  final double? width;
  final String? semanticsLabel;
  final String? semanticsValue;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final double clamped = fraction.clamp(0.0, 1.0);
    final BorderRadius radius = BorderRadius.circular(height);

    // Recessed trough: shaded at the top edge, softly catching light at the bottom.
    final Color troughTop = Color.alphaBlend(
      colors.shadow.withValues(alpha: dark ? 0.42 : 0.10),
      colors.surfaceMuted,
    );
    final Color troughBottom = Color.alphaBlend(
      Colors.white.withValues(alpha: dark ? 0.05 : 0.65),
      colors.surfaceMuted,
    );

    // Lit fill: deep base -> rich accent -> luminous tip.
    final Color fillStart = Color.alphaBlend(
      colors.shadow.withValues(alpha: dark ? 0.22 : 0.16),
      colors.accent,
    );
    final Color fillEnd = Color.lerp(
      colors.accent,
      Colors.white,
      dark ? 0.28 : 0.22,
    )!;

    Widget bar = SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[troughTop, colors.surfaceMuted, troughBottom],
            stops: const <double>[0.0, 0.55, 1.0],
          ),
          border: Border.all(
            color: colors.divider.withValues(alpha: dark ? 0.75 : 0.85),
            width: AppSizes.hairline,
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.white.withValues(alpha: dark ? 0.04 : 0.55),
              blurRadius: 1,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: AnimatedFractionallySizedBox(
              duration: AppMotion.resolve(context, AppMotion.medium),
              curve: AppMotion.standard,
              widthFactor: clamped,
              heightFactor: 1,
              child: clamped <= 0
                  ? const SizedBox.expand()
                  : DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: radius,
                        gradient: LinearGradient(
                          begin: AlignmentDirectional.centerStart,
                          end: AlignmentDirectional.centerEnd,
                          colors: <Color>[fillStart, colors.accent, fillEnd],
                          stops: const <double>[0.0, 0.68, 1.0],
                        ),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: colors.accent.withValues(
                              alpha: dark ? 0.50 : 0.32,
                            ),
                            blurRadius: height * 0.9,
                            spreadRadius: 0.5,
                          ),
                        ],
                      ),
                      // Specular top highlight and bottom cylindrical shade.
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: radius,
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: <Color>[
                              Colors.white.withValues(
                                alpha: dark ? 0.34 : 0.42,
                              ),
                              Colors.white.withValues(alpha: 0.0),
                              colors.shadow.withValues(
                                alpha: dark ? 0.24 : 0.14,
                              ),
                            ],
                            stops: const <double>[0.0, 0.48, 1.0],
                          ),
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );

    if (semanticsLabel != null || semanticsValue != null) {
      bar = Semantics(label: semanticsLabel, value: semanticsValue, child: bar);
    }
    return bar;
  }
}
