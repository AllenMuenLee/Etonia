import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../shared/navigation/app_dialogs.dart';

/// Shows the interactive color palette dialog (色盤) to let the user select any
/// custom color via an HSV spectrum box, hue slider, quick presets, and hex code.
Future<Color?> showColorPaletteDialog(
  BuildContext context, {
  required Color initialColor,
  String title = 'Color palette',
}) async {
  return showAppDialog<Color>(
    context: context,
    motionKey: 'color-palette',
    builder: (BuildContext context) =>
        ColorPaletteDialog(initialColor: initialColor, title: title),
  );
}

/// A circular swatch button with a rainbow gradient that triggers the
/// color palette dialog (色盤).
class ColorPaletteButton extends StatelessWidget {
  const ColorPaletteButton({
    super.key,
    required this.onTap,
    this.tooltip = 'Color palette',
    this.size = AppSizes.colorSwatch,
  });

  final VoidCallback onTap;
  final String tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Semantics(
      button: true,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: InkResponse(
          key: const ValueKey<String>('color-palette-button'),
          onTap: onTap,
          radius: AppSizes.minTouchTarget / 2,
          child: SizedBox.square(
            dimension: AppSizes.minTouchTarget,
            child: Center(
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const SweepGradient(
                    colors: <Color>[
                      Color(0xFFFF3B30),
                      Color(0xFFFF9500),
                      Color(0xFFFFCC00),
                      Color(0xFF34C759),
                      Color(0xFF00C7BE),
                      Color(0xFF30B0C7),
                      Color(0xFF007AFF),
                      Color(0xFF5856D6),
                      Color(0xFFAF52DE),
                      Color(0xFFFF2D55),
                      Color(0xFFFF3B30),
                    ],
                  ),
                  border: Border.all(
                    color: colors.textPrimary.withValues(alpha: 0.15),
                    width: AppSizes.hairline,
                  ),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: colors.shadow.withValues(alpha: 0.1),
                      blurRadius: 2,
                    ),
                  ],
                ),
                child: Center(
                  child: Container(
                    width: size * 0.44,
                    height: size * 0.44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: colors.surface,
                      border: Border.all(
                        color: colors.textPrimary.withValues(alpha: 0.2),
                        width: AppSizes.hairline,
                      ),
                    ),
                    child: AppIcon(
                      AppIcons.add,
                      size: size * 0.32,
                      color: colors.textPrimary,
                    ),
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

/// The full color picker dialog (色盤) featuring an interactive HSV saturation-value
/// spectrum area, hue slider, quick palette swatches, current vs. new preview,
/// and live hex input field.
class ColorPaletteDialog extends StatefulWidget {
  const ColorPaletteDialog({
    super.key,
    required this.initialColor,
    this.title = 'Color palette',
  });

  final Color initialColor;
  final String title;

  @override
  State<ColorPaletteDialog> createState() => _ColorPaletteDialogState();
}

class _ColorPaletteDialogState extends State<ColorPaletteDialog> {
  late HSVColor _hsv;
  late final TextEditingController _hexController;
  bool _updatingText = false;

  static const List<Color> _presetSwatches = <Color>[
    Color(0xFF000000),
    Color(0xFF475569),
    Color(0xFF94A3B8),
    Color(0xFFFFFFFF),
    Color(0xFFEF4444),
    Color(0xFFF97316),
    Color(0xFFF59E0B),
    Color(0xFFEAB308),
    Color(0xFF84CC16),
    Color(0xFF10B981),
    Color(0xFF06B6D4),
    Color(0xFF3B82F6),
    Color(0xFF6366F1),
    Color(0xFF8B5CF6),
    Color(0xFFD946EF),
    Color(0xFFEC4899),
  ];

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initialColor.withValues(alpha: 1.0));
    _hexController = TextEditingController(text: _colorToHex(_hsv.toColor()));
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  String _colorToHex(Color color) {
    return color
        .toARGB32()
        .toRadixString(16)
        .padLeft(8, '0')
        .substring(2)
        .toUpperCase();
  }

  void _onHsvChanged(HSVColor nextHsv) {
    setState(() {
      _hsv = nextHsv;
      if (!_updatingText) {
        _updatingText = true;
        _hexController.text = _colorToHex(_hsv.toColor());
        _updatingText = false;
      }
    });
  }

  void _onHexChanged(String text) {
    if (_updatingText) return;
    final String clean = text.replaceAll('#', '').trim();
    if (RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(clean)) {
      final Color parsed = Color(int.parse('FF$clean', radix: 16));
      _updatingText = true;
      setState(() {
        _hsv = HSVColor.fromColor(parsed);
      });
      _updatingText = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final Color currentColor = _hsv.toColor();
    const double contentWidth = 264;

    return AlertDialog(
      title: Text(
        widget.title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: colors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
      contentPadding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.xs,
      ),
      content: SingleChildScrollView(
        child: SizedBox(
          width: contentWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // Saturation / Value interactive gradient box.
              ClipRRect(
                borderRadius: AppBorderRadius.medium,
                child: SizedBox(
                  height: 150,
                  width: contentWidth,
                  child: _HsvAreaPicker(hsv: _hsv, onChanged: _onHsvChanged),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),

              // Hue rainbow slider.
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadii.small),
                child: SizedBox(
                  height: 22,
                  width: contentWidth,
                  child: _HueSlider(
                    hue: _hsv.hue,
                    onChanged: (double hue) => _onHsvChanged(_hsv.withHue(hue)),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),

              // Quick presets grid.
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                runSpacing: AppSpacing.xs,
                children: <Widget>[
                  for (final Color preset in _presetSwatches)
                    _PresetSwatch(
                      color: preset,
                      selected: currentColor.toARGB32() == preset.toARGB32(),
                      onTap: () => _onHsvChanged(HSVColor.fromColor(preset)),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),

              // Preview & Hex Input row.
              Row(
                children: <Widget>[
                  // Current vs New preview.
                  Container(
                    width: 68,
                    height: 36,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(AppRadii.small),
                      border: Border.all(
                        color: colors.textPrimary.withValues(alpha: 0.15),
                        width: AppSizes.hairline,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Tooltip(
                            message: 'Original',
                            child: ColoredBox(color: widget.initialColor),
                          ),
                        ),
                        Expanded(
                          child: Tooltip(
                            message: 'New',
                            child: ColoredBox(color: currentColor),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),

                  // Hex input field with high contrast text.
                  Expanded(
                    child: TextField(
                      key: const ValueKey<String>('color-hex-input'),
                      controller: _hexController,
                      maxLength: 6,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'monospace',
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        prefixText: '# ',
                        prefixStyle: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(
                              color: colors.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                        counterText: '',
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.xs,
                          vertical: AppSpacing.xs,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadii.small),
                        ),
                      ),
                      onChanged: _onHexChanged,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancel', style: TextStyle(color: colors.textPrimary)),
        ),
        FilledButton(
          key: const ValueKey<String>('color-select-button'),
          onPressed: () => Navigator.of(context).pop(currentColor),
          child: const Text('Select'),
        ),
      ],
    );
  }
}

/// Interactive 2D HSV Saturation and Value box.
class _HsvAreaPicker extends StatelessWidget {
  const _HsvAreaPicker({required this.hsv, required this.onChanged});

  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  void _handlePan(Offset localPosition, Size size) {
    final double s = (localPosition.dx / size.width).clamp(0.0, 1.0);
    final double v = (1.0 - (localPosition.dy / size.height)).clamp(0.0, 1.0);
    onChanged(hsv.withSaturation(s).withValue(v));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = Size(constraints.maxWidth, constraints.maxHeight);
        final double cursorX = (hsv.saturation * size.width).clamp(
          0.0,
          size.width,
        );
        final double cursorY = ((1.0 - hsv.value) * size.height).clamp(
          0.0,
          size.height,
        );

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanDown: (DragDownDetails d) => _handlePan(d.localPosition, size),
          onPanUpdate: (DragUpdateDetails d) =>
              _handlePan(d.localPosition, size),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              CustomPaint(painter: _HsvAreaPainter(hue: hsv.hue)),
              Positioned(
                left: cursorX - 9,
                top: cursorY - 9,
                child: IgnorePointer(
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: const <BoxShadow>[
                        BoxShadow(color: Colors.black45, blurRadius: 2),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HsvAreaPainter extends CustomPainter {
  const _HsvAreaPainter({required this.hue});

  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;

    // Base hue color.
    final Paint huePaint = Paint()
      ..color = HSVColor.fromAHSV(1.0, hue, 1.0, 1.0).toColor();
    canvas.drawRect(rect, huePaint);

    // Saturation gradient (white on left -> transparent on right).
    final Paint satPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: <Color>[Color(0xFFFFFFFF), Color(0x00FFFFFF)],
      ).createShader(rect);
    canvas.drawRect(rect, satPaint);

    // Value gradient (transparent on top -> black on bottom).
    final Paint valPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[Color(0x00000000), Color(0xFF000000)],
      ).createShader(rect);
    canvas.drawRect(rect, valPaint);
  }

  @override
  bool shouldRepaint(_HsvAreaPainter oldDelegate) => oldDelegate.hue != hue;
}

/// Interactive 1D rainbow Hue slider.
class _HueSlider extends StatelessWidget {
  const _HueSlider({required this.hue, required this.onChanged});

  final double hue;
  final ValueChanged<double> onChanged;

  void _handlePan(Offset localPosition, Size size) {
    final double h = ((localPosition.dx / size.width).clamp(0.0, 1.0)) * 360.0;
    onChanged(h.clamp(0.0, 360.0));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = Size(constraints.maxWidth, constraints.maxHeight);
        final double cursorX = ((hue / 360.0) * size.width).clamp(
          0.0,
          size.width,
        );

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanDown: (DragDownDetails d) => _handlePan(d.localPosition, size),
          onPanUpdate: (DragUpdateDetails d) =>
              _handlePan(d.localPosition, size),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: <Color>[
                      Color(0xFFFF0000),
                      Color(0xFFFFFF00),
                      Color(0xFF00FF00),
                      Color(0xFF00FFFF),
                      Color(0xFF0000FF),
                      Color(0xFFFF00FF),
                      Color(0xFFFF0000),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: math.max(0, cursorX - 5),
                top: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: Container(
                    width: 10,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(AppRadii.small),
                      border: Border.all(color: Colors.black45, width: 1.5),
                      boxShadow: const <BoxShadow>[
                        BoxShadow(color: Colors.black26, blurRadius: 2),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PresetSwatch extends StatelessWidget {
  const _PresetSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(
              color: selected
                  ? colors.accent
                  : colors.textPrimary.withValues(alpha: 0.18),
              width: selected ? 2.5 : 1,
            ),
          ),
        ),
      ),
    );
  }
}
