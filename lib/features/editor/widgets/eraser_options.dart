import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../shared/widgets/app_controls.dart';
import '../ink/eraser_settings.dart';

/// The eraser's mode switch and, for area mode, a size slider with a live
/// preview of the eraser at true size.
class EraserOptions extends StatelessWidget {
  const EraserOptions({
    super.key,
    required this.settings,
    required this.onChanged,
    this.config = const EraserConfig(),
  });

  final EraserSettings settings;
  final ValueChanged<EraserSettings> onChanged;
  final EraserConfig config;

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
    final AppColors colors = AppColors.of(context);
    final bool sizeApplies = settings.mode == EraserMode.area;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionLabel('Eraser'),
        SegmentedChoice<EraserMode>(
          options: EraserMode.values,
          selected: settings.mode,
          labelOf: (EraserMode mode) => mode.label,
          keyOf: (EraserMode mode) =>
              ValueKey<String>('eraser-mode-${mode.name}'),
          onSelected: (EraserMode mode) =>
              onChanged(settings.copyWith(mode: mode)),
        ),
        const SizedBox(height: AppSpacing.md),
        // The size is kept, but has no effect, in stroke mode.
        Opacity(
          opacity: sizeApplies ? 1 : 0.38,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SectionLabel(
                'Size',
                trailing: ValuePill(
                  describeSize(settings.size),
                  muted: !sizeApplies,
                ),
              ),
              ExcludeSemantics(
                child: SizedBox(
                  height: config.maxSize + AppSpacing.xs,
                  child: CustomPaint(
                    key: const ValueKey<String>('eraser-size-preview'),
                    painter: EraserPreviewPainter(
                      color: colors.textSecondary,
                      fill: colors.surfaceMuted,
                      size: settings.size,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        AppSlider(
          value: settings.size.clamp(config.minSize, config.maxSize),
          min: config.minSize,
          max: config.maxSize,
          divisions: math.max(1, (config.maxSize - config.minSize).round()),
          semanticFormatterCallback: describeSize,
          onChanged: sizeApplies
              ? (double size) => onChanged(settings.copyWith(size: size))
              : null,
        ),
      ],
    );
  }
}

/// Draws the eraser at its true size, centered: a light disc, outlined.
class EraserPreviewPainter extends CustomPainter {
  const EraserPreviewPainter({
    required this.color,
    required this.size,
    this.fill,
  });

  final Color color;
  final Color? fill;

  /// Eraser diameter in logical pixels.
  final double size;

  @override
  void paint(Canvas canvas, Size canvasSize) {
    if (fill != null) {
      canvas.drawCircle(
        canvasSize.center(Offset.zero),
        size / 2,
        Paint()..color = fill!,
      );
    }
    canvas.drawCircle(
      canvasSize.center(Offset.zero),
      size / 2,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = AppSizes.hairline
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(EraserPreviewPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.fill != fill ||
        oldDelegate.size != size;
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
