import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../ink/eraser_settings.dart';
import 'tool_options_bar.dart';

/// The eraser's options, along a [ToolOptionsBar]: its mode, and for area
/// mode its size, between dots of the smallest and largest.
class EraserOptions extends StatelessWidget {
  const EraserOptions({
    super.key,
    required this.settings,
    required this.onChanged,
    this.config = const EraserConfig(),
    this.axis = Axis.horizontal,
  });

  final EraserSettings settings;
  final ValueChanged<EraserSettings> onChanged;
  final EraserConfig config;
  final Axis axis;

  static String describeSize(double size) => '${size.round()} px';

  /// The mode, and the size where it applies.
  static String describe(EraserSettings settings) {
    return switch (settings.mode) {
      EraserMode.area =>
        '${settings.mode.label}, ${describeSize(settings.size)}',
      EraserMode.stroke => settings.mode.label,
    };
  }

  @override
  Widget build(BuildContext context) {
    final bool sizeApplies = settings.mode == EraserMode.area;
    return ToolOptionsBar(
      key: const ValueKey<String>('eraser-options-bar'),
      axis: axis,
      children: <Widget>[
        for (final EraserMode mode in EraserMode.values)
          OptionsButton(
            key: ValueKey<String>('eraser-mode-${mode.name}'),
            tooltip: switch (mode) {
              EraserMode.area => 'Erase area',
              EraserMode.stroke => 'Erase whole strokes',
            },
            semanticLabel: mode.label,
            selected: settings.mode == mode,
            onPressed: () => onChanged(settings.copyWith(mode: mode)),
            child: Icon(switch (mode) {
              EraserMode.area => AppIcons.eraseArea,
              EraserMode.stroke => AppIcons.eraseStroke,
            }),
          ),
        OptionsDivider(axis: axis),
        // The size is kept, but has no effect, in stroke mode.
        OptionsSlider(
          key: const ValueKey<String>('eraser-size-slider'),
          axis: axis,
          value: settings.size,
          min: config.minSize,
          max: config.maxSize,
          divisions: math.max(1, (config.maxSize - config.minSize).round()),
          semanticFormatterCallback: describeSize,
          start: const OptionsDot(diameter: 4),
          end: const OptionsDot(diameter: 14),
          onChanged: sizeApplies
              ? (double size) => onChanged(settings.copyWith(size: size))
              : null,
        ),
      ],
    );
  }
}

/// An eraser glyph, sized and colored by the ambient [IconTheme]. The
/// Material icon font has none.
class EraserIcon extends StatelessWidget {
  const EraserIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final IconThemeData theme = IconTheme.of(context);
    return SizedBox.square(
      dimension: theme.size,
      child: CustomPaint(
        painter: _EraserIconPainter(theme.color ?? const Color(0xFF000000)),
      ),
    );
  }
}

class _EraserIconPainter extends CustomPainter {
  const _EraserIconPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double unit = size.shortestSide / 24;
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 * unit
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    // The surface being erased.
    canvas.drawLine(
      Offset(5 * unit, 20.5 * unit),
      Offset(20 * unit, 20.5 * unit),
      paint,
    );
    // A tilted block with a band where the sleeve meets the rubber.
    canvas
      ..save()
      ..translate(12 * unit, 10.5 * unit)
      ..rotate(-math.pi / 4)
      ..drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset.zero,
            width: 17 * unit,
            height: 9.5 * unit,
          ),
          Radius.circular(2 * unit),
        ),
        paint,
      )
      ..drawLine(
        Offset(-2.5 * unit, -4.75 * unit),
        Offset(-2.5 * unit, 4.75 * unit),
        paint,
      )
      ..restore();
  }

  @override
  bool shouldRepaint(_EraserIconPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
