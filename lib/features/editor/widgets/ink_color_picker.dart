import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../ink/ink_palette.dart';

/// A grid of the curated inks. The current one is marked with a checkmark
/// and a ring, not by color alone.
class InkColorPicker extends StatelessWidget {
  const InkColorPicker({
    super.key,
    required this.selected,
    required this.onSelected,
    this.colors = InkPalette.colors,
  });

  final InkColor selected;
  final ValueChanged<InkColor> onSelected;
  final List<InkColor> colors;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Ink color', style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          spacing: AppSpacing.xxs,
          runSpacing: AppSpacing.xxs,
          children: <Widget>[
            for (final InkColor ink in colors)
              _InkSwatch(
                key: ValueKey<String>('ink-swatch-${ink.id}'),
                ink: ink,
                selected: ink == selected,
                onTap: () => onSelected(ink),
              ),
          ],
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
      message: ink.label,
      excludeFromSemantics: true,
      child: Semantics(
        container: true,
        button: true,
        inMutuallyExclusiveGroup: true,
        selected: selected,
        label: ink.label,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox.square(
            dimension: AppSizes.minTouchTarget,
            child: Center(
              child: AnimatedContainer(
                duration: AppMotion.resolve(context, AppMotion.fast),
                curve: AppMotion.standard,
                width: AppSizes.colorSwatch + AppSpacing.xs,
                height: AppSizes.colorSwatch + AppSpacing.xs,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected
                        ? colors.accent
                        : colors.accent.withValues(alpha: 0),
                    width: AppSizes.focusRingWidth,
                  ),
                ),
                child: Container(
                  width: AppSizes.colorSwatch,
                  height: AppSizes.colorSwatch,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                  child: selected
                      ? ExcludeSemantics(
                          child: Icon(Icons.check, size: 18, color: onColor),
                        )
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
