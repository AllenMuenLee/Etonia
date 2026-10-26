import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/theme/app_icons.dart';
import '../../../shared/widgets/app_controls.dart';
import '../ink/ink_palette.dart';
import 'color_palette_dialog.dart';

/// A grid of the curated inks. The current one is marked with a checkmark
/// and a ring, not by color alone. Includes a color palette button (色盤)
/// to select custom colors.
class InkColorPicker extends StatelessWidget {
  const InkColorPicker({
    super.key,
    required this.selected,
    required this.onSelected,
    this.colors = InkPalette.colors,
    this.allowPalette = true,
  });

  final InkColor selected;
  final ValueChanged<InkColor> onSelected;
  final List<InkColor> colors;
  final bool allowPalette;

  Future<void> _openPalette(BuildContext context, InkColor from) async {
    final Color? picked = await showColorPaletteDialog(
      context,
      initialColor: from.resolve(Theme.of(context).brightness),
      title: 'Ink color',
    );
    if (picked != null) {
      onSelected(InkPalette.custom(picked));
    }
  }

  /// A first tap picks the ink; a second, on the one already picked, opens
  /// the palette to customize it.
  VoidCallback _tapOf(BuildContext context, InkColor ink) {
    return () {
      if (ink == selected && allowPalette) {
        _openPalette(context, ink);
      } else {
        onSelected(ink);
      }
    };
  }

  @override
  Widget build(BuildContext context) {
    final bool hasCustomSelected = !colors.any(
      (InkColor c) => c.id == selected.id,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionLabel('Ink color'),
        // Spread across the panel's width, so each row ends flush with it.
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          runSpacing: AppSpacing.xxs,
          children: <Widget>[
            for (final InkColor ink in colors)
              _InkSwatch(
                key: ValueKey<String>('ink-swatch-${ink.id}'),
                ink: ink,
                selected: ink == selected,
                onTap: _tapOf(context, ink),
              ),
            if (hasCustomSelected)
              _InkSwatch(
                key: ValueKey<String>('ink-swatch-${selected.id}'),
                ink: selected,
                selected: true,
                onTap: _tapOf(context, selected),
              ),
            if (allowPalette)
              ColorPaletteButton(
                onTap: () => _openPalette(context, selected),
                tooltip: 'Ink palette',
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
                        width: AppSizes.colorSwatch + AppSpacing.xs + 2,
                        height: AppSizes.colorSwatch + AppSpacing.xs + 2,
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
                      width: AppSizes.colorSwatch,
                      height: AppSizes.colorSwatch,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        // Keeps an ink as dark as the panel distinct from it.
                        border: Border.all(
                          color: colors.textPrimary.withValues(alpha: 0.08),
                          width: AppSizes.hairline,
                        ),
                      ),
                      child: selected
                          ? ExcludeSemantics(
                              child: Icon(
                                AppIcons.check,
                                size: 16,
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
