import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/theme/app_icons.dart';
import '../../../shared/widgets/app_controls.dart';
import '../ink/ink_palette.dart';
import 'color_palette_dialog.dart';

/// The writing tool's few inks at hand, along a tool options bar. A tap
/// picks one; a tap on the one already picked opens the palette to put
/// another ink in its place. The current one is marked with a checkmark
/// and a ring, not by color alone.
class InkSwatches extends StatelessWidget {
  const InkSwatches({
    super.key,
    required this.swatches,
    required this.selected,
    required this.onSelected,
    required this.onReplaced,
    this.axis = Axis.horizontal,
  });

  final List<InkColor> swatches;
  final InkColor selected;

  /// Called with the index of the swatch picked.
  final ValueChanged<int> onSelected;

  /// Called with the index of the swatch whose ink was changed, and the ink
  /// put there.
  final void Function(int index, InkColor ink) onReplaced;
  final Axis axis;

  Future<void> _replace(BuildContext context, int index) async {
    final Color? picked = await showColorPaletteDialog(
      context,
      initialColor: swatches[index].resolve(Theme.of(context).brightness),
      title: 'Ink color',
    );
    if (picked != null) onReplaced(index, InkPalette.custom(picked));
  }

  @override
  Widget build(BuildContext context) {
    return Flex(
      direction: axis,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < swatches.length; i++)
          _InkSwatch(
            // By place: two swatches may hold the same ink.
            key: ValueKey<String>('ink-swatch-$i'),
            ink: swatches[i],
            selected: swatches[i] == selected,
            onTap: swatches[i] == selected
                ? () => _replace(context, i)
                : () => onSelected(i),
          ),
      ],
    );
  }
}

class _InkSwatch extends StatelessWidget {
  const _InkSwatch({
    super.key,
    required this.ink,
    required this.selected,
    required this.onTap,
  });

  final InkColor ink;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final Color color = ink.resolve(Theme.of(context).brightness);
    final Color onColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black;

    return Tooltip(
      message: selected ? 'Change ${ink.label}' : ink.label,
      excludeFromSemantics: true,
      child: Semantics(
        container: true,
        button: true,
        inMutuallyExclusiveGroup: true,
        selected: selected,
        label: ink.label,
        hint: selected ? 'Double tap to change this ink' : null,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox.square(
            dimension: AppSizes.minTouchTarget,
            child: Center(
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  // The ring grows from the swatch's center and fades with it.
                  AnimatedScale(
                    scale: selected ? 1 : 0.6,
                    duration: AppMotion.resolve(
                      context,
                      AppMotion.snappy.duration,
                    ),
                    curve: AppMotion.popCurve,
                    child: AnimatedOpacity(
                      opacity: selected ? 1 : 0,
                      duration: AppMotion.resolve(context, AppMotion.fadeIn),
                      curve: AppMotion.fadeInCurve,
                      child: Container(
                        width: AppSizes.colorSwatch + AppSpacing.xs,
                        height: AppSizes.colorSwatch + AppSpacing.xs,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: colors.accent,
                            width: AppSizes.focusRingWidth,
                          ),
                        ),
                      ),
                    ),
                  ),
                  PopOnSelect(
                    active: selected,
                    child: Container(
                      width: AppSizes.colorSwatch - AppSpacing.xxs,
                      height: AppSizes.colorSwatch - AppSpacing.xxs,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        // Keeps an ink as dark as the bar distinct from it.
                        border: Border.all(
                          color: colors.textPrimary.withValues(alpha: 0.08),
                          width: AppSizes.hairline,
                        ),
                      ),
                      child: selected
                          ? ExcludeSemantics(
                              child: AppIcon(
                                AppIcons.check,
                                size: 14,
                                color: onColor,
                              ),
                            )
                          : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
