import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'ruler.dart';

/// Paints the ruler over a page's ink, in a layer of its own so that moving
/// it never repaints the strokes beneath. It is a guide only: it is never
/// part of the page's ink, so exports and thumbnails, which draw the ink,
/// never show it.
class RulerLayer extends StatelessWidget {
  const RulerLayer({
    super.key,
    required this.controller,
    required this.stateOf,
    required this.readout,
    required this.accent,
    required this.brightness,
  });

  final RulerController controller;

  /// The ruler as it lies on this page right now.
  final ValueGetter<RulerState> stateOf;

  /// The distance of the stroke being drawn along it, if any.
  final ValueListenable<RulerReadout?> readout;

  final Color accent;
  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: CustomPaint(
            key: const ValueKey<String>('ruler-layer'),
            size: Size.infinite,
            painter: RulerPainter(
              controller: controller,
              stateOf: stateOf,
              readout: readout,
              accent: accent,
              brightness: brightness,
            ),
          ),
        ),
      ),
    );
  }
}

/// Draws the ruler: a frosted straightedge with millimeter or sixteenth
/// ticks and numbered marks along its top edge, a dial at its middle that
/// reads its angle.
class RulerPainter extends CustomPainter {
  RulerPainter({
    required this.controller,
    required this.stateOf,
    required this.readout,
    required this.accent,
    required this.brightness,
  }) : super(repaint: Listenable.merge(<Listenable>[controller, readout]));

  final RulerController controller;
  final ValueGetter<RulerState> stateOf;
  final ValueListenable<RulerReadout?> readout;
  final Color accent;
  final Brightness brightness;

  /// Where the zero mark sits in from the ruler's left end.
  static const double _origin = 14;

  /// Tick colors by paper: deep charcoal on light, near white on dark.
  static const Color lightInk = Color(0xFF212121);
  static const Color darkInk = Color(0xFFF5F5F5);

  static final Map<String, TextPainter> _labels = <String, TextPainter>{};

  bool get _dark => brightness == Brightness.dark;
  Color get _ink => _dark ? darkInk : lightInk;

  /// The numeral [text] laid out, cached: the marks are the same on every
  /// frame the ruler is dragged.
  static TextPainter _label(String text, Color color, double size) {
    final String key = '$text|${color.toARGB32()}|$size';
    final TextPainter? cached = _labels[key];
    if (cached != null) {
      return cached;
    }
    if (_labels.length > 96) {
      _labels.clear();
    }
    return _labels[key] = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          height: 1,
          fontWeight: FontWeight.w600,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final RulerState state = stateOf();
    if (!controller.isVisible) {
      return;
    }
    final RulerGeometry geometry = RulerGeometry(state);
    final RulerConfig config = controller.config;
    final RulerReadout? reading = readout.value;
    final Rect body = Rect.fromCenter(
      center: Offset.zero,
      width: state.length,
      height: state.thickness,
    );
    final RRect rrect = RRect.fromRectAndRadius(body, const Radius.circular(8));

    canvas
      ..save()
      ..translate(state.center.dx, state.center.dy)
      ..rotate(state.rotationRadians);

    _paintBody(canvas, rrect);
    _paintTicks(canvas, state, config);
    canvas.restore();

    _paintDial(canvas, state, config);
    if (reading != null && reading.engaged && reading.distance > 0.5) {
      _paintDistance(canvas, geometry, config, reading, size);
    }
  }

  void _paintBody(Canvas canvas, RRect rrect) {
    final Path outside = Path.combine(
      PathOperation.difference,
      Path()..addRect(rrect.outerRect.inflate(40)),
      Path()..addRRect(rrect),
    );
    canvas
      ..save()
      ..clipPath(outside)
      ..drawRRect(
        rrect.shift(const Offset(0, 2)),
        Paint()
          ..color = const Color(0xFF000000).withValues(alpha: 0.22)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      )
      ..restore();
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = _dark
            ? const Color(0xFF2B303B).withValues(alpha: 0.66)
            : const Color(0xFFFFFFFF).withValues(alpha: 0.62),
    );
    canvas
      ..drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = _ink.withValues(alpha: 0.35),
      )
      ..drawRRect(
        rrect.deflate(1.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = (_dark ? Colors.white : Colors.white).withValues(
            alpha: _dark ? 0.16 : 0.85,
          ),
      );
  }

  void _paintTicks(Canvas canvas, RulerState state, RulerConfig config) {
    final bool metric = state.unit == RulerUnit.centimeters;
    final double perUnit = config.pixelsPerUnit(state.unit);
    final int subdivisions = metric ? 10 : 16;
    final double step = perUnit / subdivisions;
    final double left = -state.length / 2 + _origin;
    final double right = state.length / 2 - 4;
    final double top = -state.thickness / 2;
    final Path ticks = Path();
    final int count = ((right - left) / step).floor();
    for (int i = 0; i <= count; i++) {
      final double x = left + i * step;
      final double length = metric
          ? (i % 10 == 0 ? 18.0 : (i % 5 == 0 ? 13.0 : 8.0))
          : (i % 16 == 0
                ? 18.0
                : i % 8 == 0
                ? 14.0
                : i % 4 == 0
                ? 11.0
                : i % 2 == 0
                ? 8.0
                : 5.0);
      ticks
        ..moveTo(x, top)
        ..lineTo(x, top + length);
    }
    canvas.drawPath(
      ticks,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = _ink,
    );
    for (int i = 0; i <= count; i += subdivisions) {
      final TextPainter label = _label('${i ~/ subdivisions}', _ink, 11);
      label.paint(canvas, Offset(left + i * step - label.width / 2, top + 21));
    }
  }

  /// The angle badge, upright whatever the ruler's turn. It is also the
  /// handle a single finger turns the ruler by.
  void _paintDial(Canvas canvas, RulerState state, RulerConfig config) {
    final double radius = config.dialRadius;
    final Offset c = state.center;
    canvas
      ..drawCircle(
        c,
        radius,
        Paint()
          ..color = _dark
              ? const Color(0xFF14171D).withValues(alpha: 0.82)
              : const Color(0xFFFFFFFF).withValues(alpha: 0.9),
      )
      ..drawCircle(
        c,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = _ink.withValues(alpha: 0.5),
      );
    // The ruler's direction through the dial.
    final Offset d = Offset(
      math.cos(state.rotationRadians),
      math.sin(state.rotationRadians),
    );
    canvas.drawLine(
      c - d * (radius - 3),
      c + d * (radius - 3),
      Paint()
        ..strokeWidth = 1
        ..color = accent.withValues(alpha: 0.7),
    );
    final TextPainter text = TextPainter(
      text: TextSpan(
        text: '${state.degrees.toStringAsFixed(1)}°',
        style: TextStyle(
          color: _ink,
          fontSize: 10,
          height: 1,
          fontWeight: FontWeight.w700,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, c - Offset(text.width / 2, text.height / 2));
    text.dispose();
  }

  void _paintDistance(
    Canvas canvas,
    RulerGeometry geometry,
    RulerConfig config,
    RulerReadout reading,
    Size size,
  ) {
    final double value = geometry.measure(reading.distance, config);
    final String unit = geometry.state.unit.symbol;
    final TextPainter text = TextPainter(
      text: TextSpan(
        text: '${value.toStringAsFixed(1)} $unit',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          height: 1,
          fontWeight: FontWeight.w700,
          fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // Beside the pen, on the side away from the ruler's body.
    final Offset away = geometry.outward(reading.edge);
    final Offset anchor = reading.tip + away * 30;
    final Rect pill = Rect.fromCenter(
      center: anchor,
      width: text.width + 16,
      height: text.height + 10,
    );
    final Rect inside = Offset.zero & size;
    final Offset shift = Offset(
      pill.left < 0
          ? -pill.left
          : pill.right > inside.right
          ? inside.right - pill.right
          : 0,
      pill.top < 0
          ? -pill.top
          : pill.bottom > inside.bottom
          ? inside.bottom - pill.bottom
          : 0,
    );
    final RRect shape = RRect.fromRectAndRadius(
      pill.shift(shift),
      Radius.circular(pill.height / 2),
    );
    canvas.drawRRect(
      shape,
      Paint()..color = const Color(0xFF111418).withValues(alpha: 0.88),
    );
    text.paint(canvas, shape.center - Offset(text.width / 2, text.height / 2));
    text.dispose();
  }

  @override
  bool shouldRepaint(RulerPainter oldDelegate) {
    return oldDelegate.controller != controller ||
        oldDelegate.accent != accent ||
        oldDelegate.brightness != brightness ||
        oldDelegate.readout != readout;
  }
}
