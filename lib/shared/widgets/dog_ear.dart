import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import 'pressable.dart';

/// A document surface with Etonia's single folded top-trailing corner.
class DogEar extends StatelessWidget {
  const DogEar({
    super.key,
    required this.child,
    this.flapColor,
    this.backgroundColor,
    this.pressed = false,
    this.radius = AppRadii.large,
  });

  final Widget child;
  final Color? flapColor;
  final Color? backgroundColor;
  final bool pressed;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextDirection direction = Directionality.of(context);
    final bool held = pressed || Pressable.isPressed(context);
    final Color flap = held
        ? Color.lerp(flapColor ?? colors.surfaceMuted, colors.shadow, 0.12)!
        : flapColor ?? colors.surfaceMuted;
    return CustomPaint(
      foregroundPainter: DogEarPainter(
        flapColor: flap,
        gapColor: backgroundColor ?? colors.background,
        textDirection: direction,
      ),
      child: ClipPath(
        clipper: DogEarClipper(textDirection: direction, radius: radius),
        child: ColoredBox(
          color: backgroundColor ?? colors.surface,
          child: child,
        ),
      ),
    );
  }
}

class DogEarClipper extends CustomClipper<Path> {
  const DogEarClipper({
    required this.textDirection,
    this.radius = AppRadii.large,
  });

  final TextDirection textDirection;
  final double radius;

  @override
  Path getClip(Size size) {
    final double fold = math.min(size.shortestSide * 0.22, size.width * 0.34);
    final bool rtl = textDirection == TextDirection.rtl;
    final RRect base = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(math.min(radius, size.shortestSide / 2)),
    );
    final Path cut = Path()
      ..moveTo(rtl ? 0 : size.width - fold, 0)
      ..lineTo(rtl ? fold : size.width, fold)
      ..lineTo(rtl ? 0 : size.width, 0)
      ..close();
    return Path.combine(PathOperation.difference, Path()..addRRect(base), cut);
  }

  @override
  bool shouldReclip(DogEarClipper oldClipper) =>
      oldClipper.textDirection != textDirection || oldClipper.radius != radius;
}

class DogEarPainter extends CustomPainter {
  const DogEarPainter({
    required this.flapColor,
    required this.gapColor,
    required this.textDirection,
  });

  final Color flapColor;
  final Color gapColor;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    final double fold = math.min(size.shortestSide * 0.22, size.width * 0.34);
    final bool rtl = textDirection == TextDirection.rtl;
    final double edge = rtl ? 0 : size.width;
    final double inner = rtl ? fold : size.width - fold;
    final double gap = math.min(1.5, fold * 0.08);
    final Path flap = Path()
      ..moveTo(inner + (rtl ? gap : -gap), gap)
      ..lineTo(edge + (rtl ? fold - gap : -fold + gap), fold - gap)
      ..lineTo(edge, fold - gap)
      ..close();
    canvas.drawPath(flap, Paint()..color = flapColor);
    canvas.drawLine(
      Offset(inner, 0),
      Offset(edge, fold),
      Paint()
        ..color = gapColor
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(DogEarPainter oldDelegate) =>
      oldDelegate.flapColor != flapColor ||
      oldDelegate.gapColor != gapColor ||
      oldDelegate.textDirection != textDirection;
}
