import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../shared/widgets/pressable.dart';

/// A square palette control with a 48-pixel touch target and a smaller
/// painted body. Disabled when [onPressed] is null.
class PaletteButton extends StatefulWidget {
  const PaletteButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.child,
    this.semanticLabel,
    this.selected = false,
    this.toggled,
    this.dense = false,
    this.hostsSelection = false,
  });

  final String tooltip;

  /// Announced by screen readers; defaults to [tooltip].
  final String? semanticLabel;

  final VoidCallback? onPressed;
  final bool selected;

  /// For a control that switches a mode on and off: announced as a toggle,
  /// on or off, rather than as a selected tool.
  final bool? toggled;

  /// Shrinks the painted body, never the touch target.
  final bool dense;

  /// Whether a shared [SelectionCapsule] behind the buttons draws the selected
  /// fill. The button then only recolors its glyph.
  final bool hostsSelection;

  final Widget child;

  @override
  State<PaletteButton> createState() => _PaletteButtonState();
}

class _PaletteButtonState extends State<PaletteButton>
    with SingleTickerProviderStateMixin {
  bool _focused = false;

  /// The glyph's 1.0 to 1.12 to 1.0 pop as it becomes the chosen tool.
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: AppMotion.snappy.duration,
  );

  static final Animatable<double> _popScale =
      TweenSequence<double>(<TweenSequenceItem<double>>[
        TweenSequenceItem<double>(
          tween: Tween<double>(begin: 1, end: 1.12),
          weight: 1,
        ),
        TweenSequenceItem<double>(
          tween: Tween<double>(begin: 1.12, end: 1),
          weight: 1,
        ),
      ]);

  @override
  void didUpdateWidget(PaletteButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected &&
        !oldWidget.selected &&
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
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final bool enabled = widget.onPressed != null;
    final double visual = widget.dense
        ? AppSizes.paletteButtonVisualDense
        : AppSizes.paletteButtonVisual;
    final bool showFocusRing =
        _focused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    const BorderRadius radius = AppBorderRadius.medium;

    return Tooltip(
      message: widget.tooltip,
      excludeFromSemantics: true,
      child: Semantics(
        container: true,
        button: true,
        enabled: enabled,
        selected: widget.toggled == null ? widget.selected : null,
        toggled: widget.toggled,
        label: widget.semanticLabel ?? widget.tooltip,
        child: InkWell(
          onTap: widget.onPressed,
          onFocusChange: (bool focused) => setState(() => _focused = focused),
          borderRadius: radius,
          hoverColor: colors.textPrimary.withValues(alpha: 0.06),
          focusColor: colors.textPrimary.withValues(alpha: 0.10),
          highlightColor: colors.textPrimary.withValues(alpha: 0.12),
          child: SizedBox.square(
            dimension: AppSizes.minTouchTarget,
            child: Center(
              child: Pressable(
                enabled: enabled,
                type: PressableType.icon,
                child: AnimatedContainer(
                  duration: AppMotion.resolve(
                    context,
                    AppMotion.snappy.duration,
                  ),
                  curve: AppMotion.fadeInCurve,
                  width: visual,
                  height: visual,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: widget.selected && !widget.hostsSelection
                        ? colors.selected
                        : colors.selected.withValues(alpha: 0),
                    borderRadius: AppBorderRadius.medium,
                    border: Border.all(
                      color: showFocusRing
                          ? colors.focus
                          : colors.focus.withValues(alpha: 0),
                      width: AppSizes.focusRingWidth,
                    ),
                  ),
                  // Dimmed by its color, not an Opacity: a translucent layer
                  // would be drawn offscreen on every frame it is shown.
                  child: TweenAnimationBuilder<Color?>(
                    tween: ColorTween(
                      end: colors.textPrimary.withValues(
                        alpha: enabled ? 1 : 0.38,
                      ),
                    ),
                    duration: AppMotion.resolve(context, AppMotion.fadeIn),
                    curve: AppMotion.fadeInCurve,
                    builder: (BuildContext context, Color? tone, Widget? _) {
                      return IconTheme.merge(
                        data: IconThemeData(color: tone, size: AppSizes.icon),
                        child: ScaleTransition(
                          scale: _pop.drive(_popScale),
                          child: ExcludeSemantics(child: widget.child),
                        ),
                      );
                    },
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
