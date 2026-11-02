import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../app/theme/app_tokens.dart';
import '../feedback/app_haptics.dart';
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
        type: PressableType.icon,
        child: AnimatedContainer(
          duration: AppMotion.resolve(context, AppMotion.fadeIn),
          curve: AppMotion.fadeInCurve,
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

/// A toolbar glyph on the shared icon-button behavior: a round highlight on
/// touch-down that relaxes on release, the glyph scaled to 0.92 while held,
/// and a fade (not a color swap) between enabled and disabled. The touch
/// target stays 48 points.
class ToolbarIconButton extends StatelessWidget {
  const ToolbarIconButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.icon,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      // The Pressable below dims a disabled button, so the glyph is not
      // dimmed twice.
      color: colors.textPrimary,
      disabledColor: colors.textPrimary,
      icon: Pressable(
        enabled: onPressed != null,
        type: PressableType.icon,
        child: SizedBox.square(dimension: 40, child: Center(child: Icon(icon))),
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
    final Widget titled = text;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: trailing == null
          ? titled
          : Row(
              children: <Widget>[
                Expanded(child: titled),
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
      duration: AppMotion.resolve(context, AppMotion.fadeIn),
      curve: AppMotion.fadeInCurve,
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
class AppSlider extends StatefulWidget {
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
  State<AppSlider> createState() => _AppSliderState();
}

class _AppSliderState extends State<AppSlider> {
  int? _detent;

  void _changed(double value) {
    final int? divisions = widget.divisions;
    if (divisions != null && divisions > 0) {
      final int detent =
          (((value - widget.min) / (widget.max - widget.min)) * divisions)
              .round();
      if (_detent != null && detent != _detent) AppHaptics.selectionClick();
      _detent = detent;
    }
    widget.onChanged?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final bool enabled = widget.onChanged != null;
    final Color ring = enabled ? colors.accent : colors.divider;
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        thumbShape: RingThumbShape(
          fill: colors.surface,
          ring: ring,
          shadow: colors.shadow,
        ),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
        showValueIndicator: ShowValueIndicator.onDrag,
      ),
      child: Slider(
        value: widget.value,
        min: widget.min,
        max: widget.max,
        divisions: widget.divisions,
        label:
            widget.semanticFormatterCallback?.call(widget.value) ??
            widget.value.toStringAsFixed(1),
        semanticFormatterCallback: widget.semanticFormatterCallback,
        onChangeStart: (_) => _detent = null,
        onChangeEnd: (_) => _detent = null,
        onChanged: enabled ? _changed : null,
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
    final double radius = _radius + 1.5 * activationAnimation.value;
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
  const ToggleTrack({super.key, required this.value, this.pressed = false});

  final bool value;

  /// Whether a finger is down on it: the thumb widens a little.
  final bool pressed;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final Duration duration = AppMotion.resolve(
      context,
      AppMotion.snappy.duration,
    );
    return AnimatedContainer(
      duration: duration,
      curve: AppMotion.fadeInCurve,
      width: 51,
      height: 31,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: value ? colors.accent : colors.divider,
        borderRadius: BorderRadius.circular(999),
      ),
      child: AnimatedAlign(
        duration: duration,
        curve: AppMotion.fadeInCurve,
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
          child: AnimatedContainer(
            duration: AppMotion.resolve(context, AppMotion.fadeIn),
            curve: AppMotion.fadeInCurve,
            width: pressed ? 37 : 31,
            height: 25,
          ),
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
class ToggleSetting extends StatefulWidget {
  const ToggleSetting({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.hint,
    this.icon,
    this.padding = const EdgeInsets.symmetric(vertical: AppSpacing.xs),
  });

  final String label;
  final String? hint;
  final bool value;
  final ValueChanged<bool> onChanged;

  /// Leads the row, in the secondary text color.
  final IconData? icon;

  /// Inside the row's touch highlight, for a row that fills a grouped list.
  final EdgeInsetsGeometry padding;

  @override
  State<ToggleSetting> createState() => _ToggleSettingState();
}

class _ToggleSettingState extends State<ToggleSetting> {
  bool _pressed = false;

  void _hold(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final bool value = widget.value;
    final String label = widget.label;
    final String? hint = widget.hint;
    final IconData? icon = widget.icon;
    final ValueChanged<bool> onChanged = widget.onChanged;
    return Semantics(
      toggled: value,
      button: true,
      label: label,
      hint: hint,
      excludeSemantics: true,
      onTap: () {
        AppHaptics.tap();
        onChanged(!value);
      },
      child: Listener(
        onPointerDown: (_) => _hold(true),
        onPointerUp: (_) => _hold(false),
        onPointerCancel: (_) => _hold(false),
        child: InkWell(
          onTap: () {
            AppHaptics.tap();
            onChanged(!value);
          },
          borderRadius: AppBorderRadius.medium,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: AppSizes.minTouchTarget + AppSpacing.xs,
            ),
            child: Padding(
              padding: widget.padding,
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
                  ToggleTrack(value: value, pressed: _pressed),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One choice of a few, as segments of a quiet capsule track. A single thumb
/// slides under the chosen one; labels change color only, never weight, so
/// the text does not jitter.
class SegmentedChoice<T> extends StatelessWidget {
  const SegmentedChoice({
    super.key,
    required this.options,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
    this.iconOf,
    this.visualOf,
    this.iconOnly = false,
    this.keyOf,
  }) : assert(!iconOnly || iconOf != null || visualOf != null);

  final List<T> options;
  final T selected;
  final String Function(T option) labelOf;
  final IconData? Function(T option)? iconOf;
  final Widget Function(T option, Color color)? visualOf;

  /// Shows only each option's icon while retaining [labelOf] for semantics.
  final bool iconOnly;
  final Key? Function(T option)? keyOf;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final Duration duration = AppMotion.resolve(context, AppMotion.fadeIn);
    const double inset = 3;
    final int index = math.max(0, options.indexOf(selected));
    return Container(
      height: AppSizes.minTouchTarget - 4,
      padding: const EdgeInsets.all(inset),
      decoration: ShapeDecoration(
        color: AppGlass.muted(colors),
        shape: const StadiumBorder(),
      ),
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: IgnorePointer(
              child: SelectionCapsule(
                index: index,
                count: options.length,
                decoration: ShapeDecoration(
                  color: colors.surface,
                  shape: const StadiumBorder(),
                  shadows: <BoxShadow>[
                    BoxShadow(
                      color: colors.shadow.withValues(alpha: 0.10),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Row(
            children: <Widget>[
              for (final T option in options)
                Expanded(
                  child: Builder(
                    builder: (BuildContext context) {
                      final bool on = option == selected;
                      final IconData? icon = iconOf?.call(option);
                      final Color foreground = on
                          ? colors.textPrimary
                          : colors.textSecondary;
                      final Widget? visual =
                          visualOf?.call(option, foreground) ??
                          (icon == null
                              ? null
                              : Icon(icon, size: 16, color: foreground));
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
                            type: PressableType.chip,
                            borderRadius: BorderRadius.circular(999),
                            child: Center(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  if (visual != null) ...<Widget>[
                                    visual,
                                    if (!iconOnly)
                                      const SizedBox(width: AppSpacing.xxs),
                                  ],
                                  if (!iconOnly)
                                    // A long label in a narrow panel fades
                                    // out rather than overflowing.
                                    Flexible(
                                      child: AnimatedDefaultTextStyle(
                                        duration: duration,
                                        curve: AppMotion.fadeInCurve,
                                        maxLines: 1,
                                        softWrap: false,
                                        overflow: TextOverflow.fade,
                                        style: text.labelLarge!.copyWith(
                                          color: foreground,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        child: Text(labelOf(option)),
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
              duration: AppMotion.resolve(context, AppMotion.snappy.duration),
              curve: AppMotion.fadeInCurve,
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

/// A single capsule that springs between equally spaced destinations.
///
/// By default it fills one of [count] equal slots along [axis]. With [size] it
/// is a fixed capsule that sits [origin] points into the track, [slotExtent]
/// apart, for controls that are not spread over their whole extent.
class SelectionCapsule extends StatefulWidget {
  const SelectionCapsule({
    super.key,
    required this.index,
    required this.count,
    this.color,
    this.margin = EdgeInsets.zero,
    this.axis = Axis.horizontal,
    this.slotExtent,
    this.size,
    this.origin = 0,
    this.decoration,
  }) : assert(count > 0),
       assert(index >= 0 && index < count);

  final int index;
  final int count;
  final Color? color;
  final EdgeInsets margin;
  final Axis axis;

  /// The distance between slots; the track's extent over [count] when null.
  final double? slotExtent;

  /// A fixed capsule diameter, centered across the track.
  final double? size;

  /// Where the first slot's capsule begins along the track.
  final double origin;

  /// Replaces the plain stadium fill, such as one with a shadow.
  final Decoration? decoration;

  @override
  State<SelectionCapsule> createState() => _SelectionCapsuleState();
}

class _SelectionCapsuleState extends State<SelectionCapsule>
    with SingleTickerProviderStateMixin {
  late final AnimationController _position = AnimationController.unbounded(
    vsync: this,
    value: widget.index.toDouble(),
  );

  @override
  void didUpdateWidget(SelectionCapsule oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index == oldWidget.index && widget.count == oldWidget.count) {
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _position.value = widget.index.toDouble();
      return;
    }
    final double velocity = _position.velocity;
    _position.stop();
    _position.animateWith(
      SpringSimulation(
        AppMotion.spring(context, AppMotion.snappy),
        _position.value,
        widget.index.toDouble(),
        velocity,
      ),
    );
  }

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color fill = widget.color ?? AppColors.of(context).accent;
    final bool horizontal = widget.axis == Axis.horizontal;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double track = horizontal
            ? constraints.maxWidth
            : constraints.maxHeight;
        final double cross = horizontal
            ? constraints.maxHeight
            : constraints.maxWidth;
        final double slot = widget.slotExtent ?? track / widget.count;
        final double along = widget.size ?? slot;
        final double across = widget.size ?? cross;
        return AnimatedBuilder(
          animation: _position,
          child: Padding(
            padding: widget.margin,
            child: DecoratedBox(
              decoration:
                  widget.decoration ??
                  ShapeDecoration(color: fill, shape: const StadiumBorder()),
            ),
          ),
          builder: (BuildContext context, Widget? child) {
            final double shift = widget.origin + slot * _position.value;
            return Align(
              alignment: horizontal
                  ? AlignmentDirectional.centerStart
                  : AlignmentDirectional.topCenter,
              child: Transform.translate(
                offset: horizontal ? Offset(shift, 0) : Offset(0, shift),
                child: SizedBox(
                  width: horizontal ? along : across,
                  height: horizontal ? across : along,
                  child: child,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Plays a small scale pop on [child] each time [active] turns true: 1.0 to
/// [peak] and back, for a choice landing. Reduced motion skips the pop.
class PopOnSelect extends StatefulWidget {
  const PopOnSelect({
    super.key,
    required this.active,
    required this.child,
    this.peak = 1.08,
  });

  final bool active;
  final double peak;
  final Widget child;

  @override
  State<PopOnSelect> createState() => _PopOnSelectState();
}

class _PopOnSelectState extends State<PopOnSelect>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: AppMotion.snappy.duration,
  );

  Animatable<double> get _scale =>
      TweenSequence<double>(<TweenSequenceItem<double>>[
        TweenSequenceItem<double>(
          tween: Tween<double>(begin: 1, end: widget.peak),
          weight: 1,
        ),
        TweenSequenceItem<double>(
          tween: Tween<double>(begin: widget.peak, end: 1),
          weight: 1,
        ),
      ]);

  @override
  void didUpdateWidget(PopOnSelect oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active &&
        !oldWidget.active &&
        !MediaQuery.disableAnimationsOf(context)) {
      _pop.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ScaleTransition(scale: _pop.drive(_scale), child: widget.child);
}

/// A checkmark whose stroke is revealed from start to finish.
class StrokeDrawCheck extends StatelessWidget {
  const StrokeDrawCheck({
    super.key,
    required this.selected,
    this.color,
    this.strokeWidth = 2.5,
  });

  final bool selected;
  final Color? color;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: selected ? 1 : 0),
      duration: reduced ? AppMotion.reduced : AppMotion.checkDraw,
      curve: reduced ? AppMotion.reducedCurve : AppMotion.fadeInCurve,
      builder: (BuildContext context, double value, Widget? child) => Opacity(
        opacity: reduced ? value : 1,
        child: CustomPaint(
          painter: _CheckPainter(
            progress: reduced && selected ? 1 : value,
            color: color ?? AppColors.of(context).onAccent,
            strokeWidth: strokeWidth,
          ),
        ),
      ),
    );
  }
}

class _CheckPainter extends CustomPainter {
  const _CheckPainter({
    required this.progress,
    required this.color,
    required this.strokeWidth,
  });

  final double progress;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final Path check = Path()
      ..moveTo(size.width * 0.18, size.height * 0.52)
      ..lineTo(size.width * 0.42, size.height * 0.76)
      ..lineTo(size.width * 0.84, size.height * 0.25);
    final PathMetric metric = check.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * progress.clamp(0, 1)),
      Paint()
        ..color = color
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth;
}

/// Cross-fades a number while the replacement rolls eight points vertically.
class RollingNumber extends StatelessWidget {
  const RollingNumber(this.value, {super.key, this.style, this.semanticLabel});

  final Object value;
  final TextStyle? style;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      label: semanticLabel,
      value: '$value',
      excludeSemantics: true,
      child: AnimatedSwitcher(
        duration: reduced ? AppMotion.reduced : AppMotion.snappy.duration,
        reverseDuration: reduced ? AppMotion.reduced : AppMotion.fadeOut,
        transitionBuilder: (Widget child, Animation<double> animation) {
          final Widget faded = FadeTransition(opacity: animation, child: child);
          if (reduced) return faded;
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.25),
              end: Offset.zero,
            ).animate(animation),
            child: faded,
          );
        },
        child: Text('$value', key: ValueKey<Object>(value), style: style),
      ),
    );
  }
}

/// Runs the shared six-point error shake whenever [errorToken] changes.
class Shake extends StatefulWidget {
  const Shake({
    super.key,
    required this.errorToken,
    required this.child,
    this.playHaptic = true,
  });

  final Object? errorToken;
  final Widget child;
  final bool playHaptic;

  @override
  State<Shake> createState() => _ShakeState();
}

class _ShakeState extends State<Shake> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.errorShake,
  );

  @override
  void didUpdateWidget(Shake oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.errorToken == null ||
        widget.errorToken == oldWidget.errorToken) {
      return;
    }
    if (widget.playHaptic) AppHaptics.error();
    if (!MediaQuery.disableAnimationsOf(context)) _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    child: widget.child,
    builder: (BuildContext context, Widget? child) {
      final double t = _controller.value;
      final double wave = t < 0.2
          ? t / 0.2
          : t < 0.4
          ? -1 + (t - 0.2) / 0.2
          : t < 0.6
          ? (t - 0.4) / 0.2
          : t < 0.8
          ? -1 + (t - 0.6) / 0.2
          : 1 - (t - 0.8) / 0.2;
      return Transform.translate(offset: Offset(6 * wave, 0), child: child);
    },
  );
}
