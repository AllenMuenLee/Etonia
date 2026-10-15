import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../ink/eraser_settings.dart';
import '../ink/ink_palette.dart';
import '../ink/pen_settings.dart';
import 'eraser_options.dart';
import 'ink_color_picker.dart';
import 'palette_button.dart';
import 'palette_popover.dart';
import 'select_options.dart';
import 'stroke_width_picker.dart';

/// Handles to the palette's popovers, for code outside the palette that
/// needs to know whether one is open.
class ToolPaletteController {
  final MenuController penMenu = MenuController();
  final MenuController eraserMenu = MenuController();
  final MenuController selectMenu = MenuController();

  bool get hasOpenPopover {
    return penMenu.isOpen || eraserMenu.isOpen || selectMenu.isOpen;
  }
}

/// The floating tool palette: the pen, the eraser, and Select. Each one,
/// pressed while selected, opens its options: the pen's ink color and
/// width, the eraser's mode and size, and Select's Paste.
///
/// It listens to [tool], [penSettings], and [eraserSettings] itself, so
/// changing any of them rebuilds only the palette.
class ToolPalette extends StatelessWidget {
  const ToolPalette({
    super.key,
    required this.axis,
    required this.tool,
    required this.penSettings,
    required this.eraserSettings,
    required this.clipboardListenable,
    required this.canPaste,
    required this.onPaste,
    this.penConfig = const PenConfig(),
    this.eraserConfig = const EraserConfig(),
    this.dense = false,
    this.controller,
  });

  static const double _padding = AppSpacing.xxs;
  static const int _buttonCount = 3;

  final Axis axis;
  final ValueNotifier<EditorTool> tool;
  final ValueNotifier<PenSettings> penSettings;
  final ValueNotifier<EraserSettings> eraserSettings;

  /// Fires when [canPaste] may have changed.
  final Listenable clipboardListenable;

  /// Whether there is anything to paste.
  final ValueGetter<bool> canPaste;

  final VoidCallback onPaste;
  final PenConfig penConfig;
  final EraserConfig eraserConfig;
  final bool dense;
  final ToolPaletteController? controller;

  /// The palette's outer size; fixed so the screen can lay out around it.
  static Size sizeFor(Axis axis) {
    const double thickness = AppSizes.minTouchTarget + 2 * _padding;
    const double length = _buttonCount * AppSizes.minTouchTarget + 2 * _padding;
    return axis == Axis.vertical
        ? const Size(thickness, length)
        : const Size(length, thickness);
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadii.large),
        border: Border.all(color: colors.divider, width: AppSizes.hairline),
        boxShadow: AppShadows.floating(colors),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.all(_padding),
          child: Semantics(
            container: true,
            explicitChildNodes: true,
            label: 'Tools',
            child: FocusTraversalGroup(
              child: ListenableBuilder(
                listenable: Listenable.merge(<Listenable>[
                  tool,
                  penSettings,
                  eraserSettings,
                ]),
                builder: (BuildContext context, Widget? _) {
                  return Flex(
                    direction: axis,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _penControl(),
                      _eraserControl(),
                      _selectControl(),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Selects the pen; pressed again, opens its ink color and width.
  Widget _penControl() {
    return PalettePopover(
      paletteAxis: axis,
      controller: controller?.penMenu,
      anchorBuilder: (BuildContext context, VoidCallback toggle) {
        final bool selected = tool.value == EditorTool.pen;
        final PenSettings pen = penSettings.value;
        return PaletteButton(
          tooltip: 'Pen',
          semanticLabel: 'Pen, ${PenOptions.describe(pen)}',
          selected: selected,
          dense: dense,
          onPressed: selected ? toggle : () => tool.value = EditorTool.pen,
          child: _PenIcon(ink: pen.ink),
        );
      },
      panelBuilder: (BuildContext context, VoidCallback close) {
        return ValueListenableBuilder<PenSettings>(
          valueListenable: penSettings,
          builder: (BuildContext context, PenSettings current, Widget? _) {
            return PenOptions(
              settings: current,
              config: penConfig,
              onChanged: (PenSettings next) => penSettings.value = next,
            );
          },
        );
      },
    );
  }

  /// Selects the eraser; pressed again, opens its options.
  Widget _eraserControl() {
    return PalettePopover(
      paletteAxis: axis,
      controller: controller?.eraserMenu,
      anchorBuilder: (BuildContext context, VoidCallback toggle) {
        final bool selected = tool.value == EditorTool.eraser;
        return PaletteButton(
          tooltip: 'Eraser',
          semanticLabel:
              'Eraser, ${EraserOptions.describe(eraserSettings.value)}',
          selected: selected,
          dense: dense,
          onPressed: selected ? toggle : () => tool.value = EditorTool.eraser,
          child: const EraserIcon(),
        );
      },
      panelBuilder: (BuildContext context, VoidCallback close) {
        return ValueListenableBuilder<EraserSettings>(
          valueListenable: eraserSettings,
          builder: (BuildContext context, EraserSettings current, Widget? _) {
            return EraserOptions(
              settings: current,
              config: eraserConfig,
              onChanged: (EraserSettings next) => eraserSettings.value = next,
            );
          },
        );
      },
    );
  }

  /// Selects the Select tool; pressed again, opens its options.
  Widget _selectControl() {
    return PalettePopover(
      paletteAxis: axis,
      controller: controller?.selectMenu,
      anchorBuilder: (BuildContext context, VoidCallback toggle) {
        final bool selected = tool.value == EditorTool.select;
        return PaletteButton(
          tooltip: 'Select',
          selected: selected,
          dense: dense,
          onPressed: selected ? toggle : () => tool.value = EditorTool.select,
          child: const Icon(Icons.highlight_alt),
        );
      },
      panelBuilder: (BuildContext context, VoidCallback close) {
        return ListenableBuilder(
          listenable: clipboardListenable,
          builder: (BuildContext context, Widget? _) {
            return SelectOptions(
              onPaste: canPaste()
                  ? () {
                      close();
                      onPaste();
                    }
                  : null,
            );
          },
        );
      },
    );
  }
}

/// The pen glyph with a dot of the current ink at its corner.
class _PenIcon extends StatelessWidget {
  const _PenIcon({required this.ink});

  static const double _dot = 9;

  final InkColor ink;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return SizedBox.square(
      dimension: AppSizes.icon + AppSpacing.xxs,
      child: Stack(
        children: <Widget>[
          const Align(
            alignment: Alignment.topLeft,
            child: Icon(Icons.draw_outlined),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              key: const ValueKey<String>('pen-ink-dot'),
              width: _dot,
              height: _dot,
              decoration: BoxDecoration(
                color: ink.resolve(Theme.of(context).brightness),
                shape: BoxShape.circle,
                border: Border.all(color: colors.surface, width: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The pen's options: its ink color and its width, in one panel.
class PenOptions extends StatelessWidget {
  const PenOptions({
    super.key,
    required this.settings,
    required this.onChanged,
    this.config = const PenConfig(),
  });

  final PenSettings settings;
  final ValueChanged<PenSettings> onChanged;
  final PenConfig config;

  /// The ink and the width, as screen readers announce them.
  static String describe(PenSettings settings) {
    return '${settings.ink.label}, ${StrokeWidthPicker.describe(settings.width)}';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InkColorPicker(
          selected: settings.ink,
          onSelected: (InkColor ink) => onChanged(settings.copyWith(ink: ink)),
        ),
        const SizedBox(height: AppSpacing.md),
        StrokeWidthPicker(
          settings: settings,
          config: config,
          onChanged: (double width) =>
              onChanged(settings.copyWith(width: width)),
        ),
      ],
    );
  }
}
