import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../shared/widgets/app_controls.dart';

/// The bar a tool's options lie in, beside the tool palette and parallel to
/// it: a row beside a palette across the top or bottom, a column beside one
/// down a side, its controls running the way the palette's tools do. It is
/// as thick as the palette, as long as its controls, and scrolls when the
/// window, or its parent, is shorter. Like the palette's tools, its
/// controls run from left to right whatever the reading order.
class ToolOptionsBar extends StatelessWidget {
  const ToolOptionsBar({super.key, required this.axis, required this.children});

  /// As thick as the tool palette beside it.
  static const double thickness = AppSizes.minTouchTarget + 2 * AppSpacing.xxs;

  final Axis axis;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final bool across = axis == Axis.horizontal;
    final Size window = MediaQuery.sizeOf(context);
    final double maxLength =
        (across ? window.width : window.height) - 2 * AppSpacing.xs;
    return Material(
      type: MaterialType.transparency,
      child: ConstrainedBox(
        constraints: across
            ? BoxConstraints(maxWidth: maxLength)
            : BoxConstraints(maxHeight: maxLength),
        child: Container(
          width: across ? null : thickness,
          height: across ? thickness : null,
          decoration: BoxDecoration(
            color: AppGlass.surface(colors),
            borderRadius: AppBorderRadius.large,
            border: Border.fromBorderSide(AppGlass.border(colors)),
            boxShadow: AppShadows.floating(colors),
          ),
          child: ClipRRect(
            borderRadius: AppBorderRadius.large,
            // Left to right, as the palette's tools run, scrolling too.
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: SingleChildScrollView(
                scrollDirection: axis,
                padding: across
                    ? const EdgeInsets.symmetric(horizontal: AppSpacing.xxs)
                    : const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
                child: _BarAxis(
                  axis: axis,
                  child: Flex(
                    direction: axis,
                    mainAxisSize: MainAxisSize.min,
                    children: children,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Which way the [ToolOptionsBar] around its controls runs, for a
/// labelled [OptionsButton] to set its word beside or below its icon.
class _BarAxis extends InheritedWidget {
  const _BarAxis({required this.axis, required super.child});

  final Axis axis;

  static Axis of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_BarAxis>()?.axis ??
      Axis.horizontal;

  @override
  bool updateShouldNotify(_BarAxis oldWidget) => axis != oldWidget.axis;
}

/// The gap between groups in a [ToolOptionsBar]: a short rule across the
/// bar with room on both sides, so each group reads as one.
class OptionsDivider extends StatelessWidget {
  const OptionsDivider({super.key, required this.axis});

  final Axis axis;

  @override
  Widget build(BuildContext context) {
    final bool across = axis == Axis.horizontal;
    return Container(
      width: across ? AppSizes.hairline : AppSpacing.lg,
      height: across ? AppSpacing.lg : AppSizes.hairline,
      margin: across
          ? const EdgeInsets.symmetric(horizontal: AppSpacing.xs)
          : const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      color: AppColors.of(context).divider,
    );
  }
}

/// A control in a [ToolOptionsBar], in a full touch slot, its visible
/// capsule smaller so neighbours sit a small, even gap apart. Framed while
/// [selected].
///
/// With a [label], a word or two naming it shows with its icon: beside it
/// in a bar across the page, below it in a bar down a side.
class OptionsButton extends StatelessWidget {
  const OptionsButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.child,
    this.selected = false,
    this.toggled,
    this.semanticLabel,
    this.label,
  });

  /// The length each control takes along the bar.
  static const double slot = 44;

  final String tooltip;

  /// Announced by screen readers; defaults to [tooltip].
  final String? semanticLabel;
  final bool selected;

  /// For a switch: announced as on or off rather than as a selected choice.
  final bool? toggled;

  /// Null disables the control.
  final VoidCallback? onPressed;
  final Widget child;

  /// Shown with [child], to say what the control is.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final bool enabled = onPressed != null;
    final String? label = this.label;
    final bool across = _BarAxis.of(context) == Axis.horizontal;
    final Color foreground = selected
        ? colors.accent
        : enabled
        ? colors.textPrimary
        : colors.textSecondary.withValues(alpha: 0.5);
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        enabled: enabled,
        focusable: enabled,
        selected: toggled == null ? selected : null,
        toggled: toggled,
        label: semanticLabel ?? tooltip,
        onTap: onPressed,
        excludeSemantics: true,
        child: InkWell(
          onTap: onPressed,
          borderRadius: AppBorderRadius.medium,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: AppSizes.minTouchTarget,
              minHeight: AppSizes.minTouchTarget,
            ),
            child: Padding(
              padding: label == null
                  ? EdgeInsets.zero
                  : const EdgeInsets.all(AppSpacing.xxs),
              child: AnimatedContainer(
                duration: AppMotion.resolve(context, AppMotion.stateFade),
                width: label == null
                    ? AppSizes.paletteButtonVisual
                    : across
                    ? null
                    : AppSizes.minTouchTarget - AppSpacing.xxs,
                height: label == null || across
                    ? AppSizes.paletteButtonVisual
                    : null,
                margin: label == null
                    ? const EdgeInsets.all(
                        (AppSizes.minTouchTarget -
                                AppSizes.paletteButtonVisual) /
                            2,
                      )
                    : EdgeInsets.zero,
                padding: label == null
                    ? EdgeInsets.zero
                    : across
                    ? const EdgeInsets.symmetric(horizontal: AppSpacing.xs)
                    : const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
                alignment: Alignment.center,
                // The frame is always there, clear until selected, so that
                // choosing a control does not shift what is inside it.
                decoration: BoxDecoration(
                  borderRadius: AppBorderRadius.medium,
                  border: Border.all(
                    color: selected
                        ? colors.accent
                        : colors.accent.withValues(alpha: 0),
                    width: AppSizes.hairline,
                  ),
                ),
                child: IconTheme(
                  data: IconThemeData(
                    size: label == null || across ? 20 : 18,
                    color: foreground,
                  ),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(color: foreground),
                    child: label == null
                        ? child
                        : _Labelled(label: label, across: across, icon: child),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An [OptionsButton]'s icon with its word: beside it, or below it in
/// small type, shrunk if need be to the bar's width.
class _Labelled extends StatelessWidget {
  const _Labelled({
    required this.label,
    required this.across,
    required this.icon,
  });

  final String label;
  final bool across;
  final Widget icon;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    // The button's color, selected or not, over the theme's.
    final Color? color = DefaultTextStyle.of(context).style.color;
    if (across) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          icon,
          const SizedBox(width: AppSpacing.xs - 2),
          Text(
            label,
            maxLines: 1,
            style: text.labelMedium?.copyWith(color: color),
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        icon,
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label,
            maxLines: 1,
            style: text.labelSmall?.copyWith(
              color: color,
              fontSize: 10,
              height: 1.1,
            ),
          ),
        ),
      ],
    );
  }
}

/// A slider lying along a [ToolOptionsBar], its least value at the bar's
/// start, between [start] and [end] glyphs that show what the ends mean.
class OptionsSlider extends StatelessWidget {
  const OptionsSlider({
    super.key,
    required this.axis,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.semanticFormatterCallback,
    this.start,
    this.end,
  });

  /// How long the track is.
  static const double length = 132;

  final Axis axis;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final SemanticFormatterCallback? semanticFormatterCallback;

  /// Null disables the slider.
  final ValueChanged<double>? onChanged;
  final Widget? start;
  final Widget? end;

  @override
  Widget build(BuildContext context) {
    final bool across = axis == Axis.horizontal;
    final Widget slider = SizedBox(
      width: length,
      height: AppSizes.minTouchTarget,
      child: AppSlider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        divisions: divisions,
        semanticFormatterCallback: semanticFormatterCallback,
        onChanged: onChanged,
      ),
    );
    Widget glyph(Widget child) => ExcludeSemantics(
      child: SizedBox.square(
        dimension: AppSpacing.lg,
        child: Center(child: child),
      ),
    );
    return Opacity(
      opacity: onChanged == null ? 0.38 : 1,
      child: Flex(
        direction: axis,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (start != null) glyph(start!),
          // A column's slider runs down it: turned a quarter clockwise, its
          // least end is at the top.
          if (across) slider else RotatedBox(quarterTurns: 1, child: slider),
          if (end != null) glyph(end!),
        ],
      ),
    );
  }
}

/// A filled dot [diameter] across, for the ends of a size slider.
class OptionsDot extends StatelessWidget {
  const OptionsDot({super.key, required this.diameter, this.color});

  final double diameter;

  /// Defaults to the secondary text color.
  final Color? color;

  @override
  Widget build(BuildContext context) => Container(
    width: diameter,
    height: diameter,
    decoration: BoxDecoration(
      color: color ?? AppColors.of(context).textSecondary,
      shape: BoxShape.circle,
    ),
  );
}
