import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';

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
    this.dense = false,
  });

  final String tooltip;

  /// Announced by screen readers; defaults to [tooltip].
  final String? semanticLabel;

  final VoidCallback? onPressed;
  final bool selected;

  /// Shrinks the painted body, never the touch target.
  final bool dense;

  final Widget child;

  @override
  State<PaletteButton> createState() => _PaletteButtonState();
}

class _PaletteButtonState extends State<PaletteButton> {
  bool _focused = false;

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
    final BorderRadius radius = BorderRadius.circular(AppRadii.medium);

    return Tooltip(
      message: widget.tooltip,
      excludeFromSemantics: true,
      child: Semantics(
        container: true,
        button: true,
        enabled: enabled,
        selected: widget.selected,
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
              child: AnimatedContainer(
                duration: AppMotion.resolve(context, AppMotion.fast),
                curve: AppMotion.standard,
                width: visual,
                height: visual,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: widget.selected
                      ? colors.selected
                      : colors.selected.withValues(alpha: 0),
                  borderRadius: radius,
                  border: Border.all(
                    color: showFocusRing
                        ? colors.focus
                        : colors.focus.withValues(alpha: 0),
                    width: AppSizes.focusRingWidth,
                  ),
                ),
                child: Opacity(
                  opacity: enabled ? 1 : 0.38,
                  child: IconTheme.merge(
                    data: IconThemeData(
                      color: widget.selected
                          ? colors.accent
                          : colors.textPrimary,
                      size: AppSizes.icon,
                    ),
                    child: ExcludeSemantics(child: widget.child),
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
