import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../shared/widgets/app_controls.dart';
import '../ink/pen_settings.dart';
import '../ink/stroke.dart';

/// A slider with a live preview of the line the writing tool will draw, in
/// its current style. A highlighter is previewed over light and dark paper
/// samples, at its true opacity.
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

  /// The paper the highlighter preview is shown over: as light and as dark
  /// as the writing surface gets.
  static const Color lightSample = Color(0xFFFFFFFF);
  static const Color darkSample = Color(0xFF1E1E22);

  static String describe(double width) => '${width.round()} px';

  @override
  Widget build(BuildContext context) {
    final StrokeStyle style = settings.strokeStyle(config);
    final Color inkColor = style.resolve(Theme.of(context).brightness);
    final double min = config.minWidthFor(settings.style);
    final double max = config.maxWidthFor(settings.style);
    final double width = settings.activeWidth;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SectionLabel('Stroke width', trailing: ValuePill(describe(width))),
        ExcludeSemantics(
          child: SizedBox(
            height: max + AppSpacing.md,
            child: CustomPaint(
              key: const ValueKey<String>('stroke-width-preview'),
              painter: StrokePreviewPainter(
                color: inkColor,
                width: width,
                samples: style.isHighlighter
                    ? const <Color>[lightSample, darkSample]
                    : const <Color>[],
              ),
            ),
          ),
        ),
        AppSlider(
          value: width.clamp(min, max),
          min: min,
          max: max,
          divisions: (max - min).round(),
          semanticFormatterCallback: describe,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

/// Draws one horizontal line the way the ink renderer would: [color]
/// already carries the stroke's opacity. With [samples], the panel is split
/// into side-by-side swatches of those paper colors under the line, so a
/// translucent ink shows how it looks on each.
class StrokePreviewPainter extends CustomPainter {
  const StrokePreviewPainter({
    required this.color,
    required this.width,
    this.samples = const <Color>[],
  });

  final Color color;
  final double width;
  final List<Color> samples;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isNotEmpty) {
      final double part = size.width / samples.length;
      final RRect clip = RRect.fromRectAndRadius(
        Offset.zero & size,
        const Radius.circular(AppRadii.medium),
      );
      canvas
        ..save()
        ..clipRRect(clip);
      for (int i = 0; i < samples.length; i++) {
        canvas.drawRect(
          Rect.fromLTWH(part * i, 0, part, size.height),
          Paint()..color = samples[i],
        );
      }
      canvas.restore();
    }
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
    return oldDelegate.color != color ||
        oldDelegate.width != width ||
        oldDelegate.samples.length != samples.length;
  }
}
