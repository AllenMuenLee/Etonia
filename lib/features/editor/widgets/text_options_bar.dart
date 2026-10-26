import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_theme.dart';
import '../../../app/theme/app_tokens.dart';
import '../ink/ink_palette.dart';
import '../text/note_text.dart';

/// The contextual controls shown beneath the toolbar while Text is active,
/// in groups: size, color and emphasis, alignment, and lists. The bar is as
/// wide as its controls and scrolls when the window is narrower.
class TextOptionsBar extends StatelessWidget {
  const TextOptionsBar({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  final TextSettings settings;
  final ValueChanged<TextSettings> onChanged;

  static const List<double> fontSizes = <double>[12, 16, 20, 24, 32, 40, 56];

  /// As thick as the tool palette above it.
  static const double height = AppSizes.minTouchTarget + 2 * AppSpacing.xxs;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final double maxWidth =
        MediaQuery.sizeOf(context).width - 2 * AppSpacing.xs;
    return Material(
      key: const ValueKey<String>('text-options-bar'),
      type: MaterialType.transparency,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: AppGlass.surface(colors),
            borderRadius: AppBorderRadius.large,
            border: Border.fromBorderSide(AppGlass.border(colors)),
            boxShadow: AppShadows.floating(colors),
          ),
          child: ClipRRect(
            borderRadius: AppBorderRadius.large,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxs),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _FontSizeControl(settings: settings, onChanged: onChanged),
                  const _GroupDivider(),
                  _ColorControl(settings: settings, onChanged: onChanged),
                  _FormatButton(
                    key: const ValueKey<String>('text-bold'),
                    tooltip: 'Bold',
                    selected: settings.bold,
                    onPressed: () =>
                        onChanged(settings.copyWith(bold: !settings.bold)),
                    child: const Text(
                      'B',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 17,
                      ),
                    ),
                  ),
                  _FormatButton(
                    key: const ValueKey<String>('text-italic'),
                    tooltip: 'Italic',
                    selected: settings.italic,
                    onPressed: () =>
                        onChanged(settings.copyWith(italic: !settings.italic)),
                    child: const Text(
                      'I',
                      style: TextStyle(
                        fontStyle: FontStyle.italic,
                        fontWeight: FontWeight.w600,
                        fontSize: 17,
                      ),
                    ),
                  ),
                  _FormatButton(
                    key: const ValueKey<String>('text-underline'),
                    tooltip: 'Underline',
                    selected: settings.underline,
                    onPressed: () => onChanged(
                      settings.copyWith(underline: !settings.underline),
                    ),
                    child: const Text(
                      'U',
                      style: TextStyle(
                        decoration: TextDecoration.underline,
                        fontWeight: FontWeight.w600,
                        fontSize: 17,
                      ),
                    ),
                  ),
                  const _GroupDivider(),
                  _AlignmentControl(settings: settings, onChanged: onChanged),
                  const _GroupDivider(),
                  _FormatButton(
                    key: const ValueKey<String>('text-bullets'),
                    tooltip: 'Bulleted list',
                    selected: settings.listStyle == TextListStyle.bullets,
                    onPressed: () => onChanged(
                      settings.copyWith(
                        listStyle: settings.listStyle == TextListStyle.bullets
                            ? TextListStyle.none
                            : TextListStyle.bullets,
                      ),
                    ),
                    child: const Icon(Icons.format_list_bulleted_rounded),
                  ),
                  _FormatButton(
                    key: const ValueKey<String>('text-numbers'),
                    tooltip: 'Numbered list',
                    selected: settings.listStyle == TextListStyle.numbers,
                    onPressed: () => onChanged(
                      settings.copyWith(
                        listStyle: settings.listStyle == TextListStyle.numbers
                            ? TextListStyle.none
                            : TextListStyle.numbers,
                      ),
                    ),
                    child: const Icon(Icons.format_list_numbered_rounded),
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

/// The gap between groups: a short rule with room on both sides, so each
/// group reads as one.
class _GroupDivider extends StatelessWidget {
  const _GroupDivider();

  @override
  Widget build(BuildContext context) => Container(
    width: AppSizes.hairline,
    height: AppSpacing.lg,
    margin: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
    color: AppColors.of(context).divider,
  );
}

/// Smaller and larger step through the preset sizes; the size between them
/// opens the full list.
class _FontSizeControl extends StatelessWidget {
  const _FontSizeControl({required this.settings, required this.onChanged});

  final TextSettings settings;
  final ValueChanged<TextSettings> onChanged;

  static const List<double> _sizes = TextOptionsBar.fontSizes;

  double? get _smaller {
    final Iterable<double> below = _sizes.where(
      (double size) => size < settings.fontSize,
    );
    return below.isEmpty ? null : below.last;
  }

  double? get _larger {
    final Iterable<double> above = _sizes.where(
      (double size) => size > settings.fontSize,
    );
    return above.isEmpty ? null : above.first;
  }

  void _set(double size) => onChanged(settings.copyWith(fontSize: size));

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final double? smaller = _smaller;
    final double? larger = _larger;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _FormatButton(
          tooltip: 'Smaller text',
          selected: false,
          onPressed: smaller == null ? null : () => _set(smaller),
          child: const Icon(AppIcons.remove),
        ),
        MenuAnchor(
          animated: !MediaQuery.disableAnimationsOf(context),
          alignmentOffset: const Offset(0, AppSpacing.xxs),
          menuChildren: <Widget>[
            for (final double size in _sizes)
              MenuItemButton(
                onPressed: () => _set(size),
                trailingIcon: size == settings.fontSize
                    ? Icon(Icons.check_rounded, size: 18, color: colors.accent)
                    : null,
                child: SizedBox(
                  width: AppSpacing.xxl,
                  child: Text(
                    '${size.round()} pt',
                    style: TextStyle(
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                      color: size == settings.fontSize ? colors.accent : null,
                    ),
                  ),
                ),
              ),
          ],
          builder: (BuildContext context, MenuController menu, Widget? _) {
            return Tooltip(
              message: 'Text size',
              excludeFromSemantics: true,
              child: Semantics(
                button: true,
                label: 'Text size, ${settings.fontSize.round()} points',
                excludeSemantics: true,
                child: InkWell(
                  key: const ValueKey<String>('text-font-size'),
                  onTap: () => menu.isOpen ? menu.close() : menu.open(),
                  borderRadius: AppBorderRadius.medium,
                  child: SizedBox(
                    width: 52,
                    height: AppSizes.minTouchTarget,
                    child: Center(
                      child: Container(
                        height: AppSizes.paletteButtonVisualDense,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.xs,
                        ),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: colors.background,
                          borderRadius: BorderRadius.circular(AppRadii.small),
                          border: Border.all(
                            color: colors.divider,
                            width: AppSizes.hairline,
                          ),
                        ),
                        child: Text(
                          '${settings.fontSize.round()}',
                          style: text.labelLarge?.copyWith(
                            color: colors.textPrimary,
                            fontFeatures: const <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        _FormatButton(
          tooltip: 'Larger text',
          selected: false,
          onPressed: larger == null ? null : () => _set(larger),
          child: const Icon(AppIcons.add),
        ),
      ],
    );
  }
}

class _ColorControl extends StatelessWidget {
  const _ColorControl({required this.settings, required this.onChanged});

  final TextSettings settings;
  final ValueChanged<TextSettings> onChanged;

  @override
  Widget build(BuildContext context) {
    final Brightness brightness = Theme.of(context).brightness;
    return PopupMenuButton<InkColor>(
      key: const ValueKey<String>('text-color'),
      tooltip: 'Text color',
      initialValue: settings.ink,
      position: PopupMenuPosition.under,
      borderRadius: AppBorderRadius.medium,
      onSelected: (InkColor ink) => onChanged(settings.copyWith(ink: ink)),
      itemBuilder: (BuildContext context) => <PopupMenuEntry<InkColor>>[
        for (final InkColor ink in InkPalette.colors)
          PopupMenuItem<InkColor>(
            value: ink,
            child: Row(
              children: <Widget>[
                _ColorDot(color: ink.resolve(brightness)),
                const SizedBox(width: AppSpacing.sm),
                Text(ink.label),
              ],
            ),
          ),
      ],
      child: Semantics(
        button: true,
        label: 'Text color, ${settings.ink.label}',
        child: SizedBox(
          width: _FormatButton.slot,
          height: AppSizes.minTouchTarget,
          child: Center(
            child: _ColorDot(
              color: settings.ink.resolve(brightness),
              ring: true,
            ),
          ),
        ),
      ),
    );
  }
}

/// A swatch; with [ring], set in a thin outline so it reads as the current
/// choice rather than one of many.
class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color, this.ring = false});

  final Color color;
  final bool ring;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final Widget dot = Container(
      width: AppSizes.colorIndicator,
      height: AppSizes.colorIndicator,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: colors.divider),
      ),
    );
    if (!ring) return dot;
    return Container(
      width: AppSizes.colorSwatch,
      height: AppSizes.colorSwatch,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: colors.textSecondary, width: 1.5),
      ),
      child: dot,
    );
  }
}

class _AlignmentControl extends StatelessWidget {
  const _AlignmentControl({required this.settings, required this.onChanged});

  final TextSettings settings;
  final ValueChanged<TextSettings> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      for (final (TextAlign alignment, IconData icon, String label)
          in <(TextAlign, IconData, String)>[
            (TextAlign.left, Icons.format_align_left_rounded, 'Align left'),
            (
              TextAlign.center,
              Icons.format_align_center_rounded,
              'Align center',
            ),
            (TextAlign.right, Icons.format_align_right_rounded, 'Align right'),
          ])
        _FormatButton(
          tooltip: label,
          selected: settings.alignment == alignment,
          onPressed: () => onChanged(settings.copyWith(alignment: alignment)),
          child: Icon(icon),
        ),
    ],
  );
}

/// A control in a full-height touch slot, its visible capsule narrower so
/// neighbours sit a small, even gap apart.
class _FormatButton extends StatelessWidget {
  const _FormatButton({
    super.key,
    required this.tooltip,
    required this.selected,
    required this.onPressed,
    required this.child,
  });

  /// The width each control takes in the bar.
  static const double slot = 44;

  final String tooltip;
  final bool selected;

  /// Null disables the control.
  final VoidCallback? onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final bool enabled = onPressed != null;
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
        selected: selected,
        label: tooltip,
        excludeSemantics: true,
        child: InkWell(
          onTap: onPressed,
          borderRadius: AppBorderRadius.medium,
          child: SizedBox(
            width: slot,
            height: AppSizes.minTouchTarget,
            child: Center(
              child: AnimatedContainer(
                duration: AppMotion.resolve(context, AppMotion.stateFade),
                width: AppSizes.paletteButtonVisual,
                height: AppSizes.paletteButtonVisual,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? colors.selected : Colors.transparent,
                  borderRadius: AppBorderRadius.medium,
                ),
                child: IconTheme(
                  data: IconThemeData(size: 20, color: foreground),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(color: foreground),
                    child: child,
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

@Preview(name: 'Text formatting bar', size: Size(700, 90))
Widget textOptionsBarPreview() => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: AppTheme.light(),
  home: Scaffold(
    body: Center(
      child: TextOptionsBar(settings: const TextSettings(), onChanged: (_) {}),
    ),
  ),
);
