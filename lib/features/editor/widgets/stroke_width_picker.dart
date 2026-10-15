import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../ink/pen_settings.dart';

/// A slider with a live preview of the line the pen will draw.
class StrokeWidthPicker extends StatelessWidget {
  const StrokeWidthPicker({
    super.key,
    required this.settings,
    required this.onChanged,
    this.config = const PenConfig(),
  });

  final PenSettings settings;
  final ValueChanged<double> onChanged;
  final PenConfig config;

  static String describe(double width) => '${width.round()} px';

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final Color inkColor = settings.ink.resolve(Theme.of(context).brightness);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text('Stroke width', style: text.labelMedium),
            Text(describe(settings.width), style: text.labelLarge),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        ExcludeSemantics(
          child: SizedBox(
            height: config.maxWidth + AppSpacing.md,
            child: CustomPaint(
              key: const ValueKey<String>('stroke-width-preview'),
              painter: StrokePreviewPainter(
                color: inkColor,
                width: settings.width,
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xxs),
        Slider(
          value: settings.width.clamp(config.minWidth, config.maxWidth),
          min: config.minWidth,
          max: config.maxWidth,
          divisions: (config.maxWidth - config.minWidth).round(),
          semanticFormatterCallback: describe,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

/// Draws one horizontal line the way the ink renderer would.
class StrokePreviewPainter extends CustomPainter {
  const StrokePreviewPainter({required this.color, required this.width});

  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final double inset = AppSpacing.md + width / 2;
    final double y = size.height / 2;
    canvas.drawLine(
      Offset(inset, y),
      Offset(size.width - inset, y),
      Paint()
        ..color = color
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(StrokePreviewPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.width != width;
  }
}
