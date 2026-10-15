import 'dart:math' as math;
import 'dart:ui' show PointMode;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../app/theme/app_tokens.dart';
import 'page_setup.dart';

/// The paper's printed rules, under the ink, in page coordinates. Never
/// part of the ink and never in semantics.
///
/// Only the rules inside [visible], the part of the page on screen, are
/// painted, so a large infinite page costs no more than a small one.
class PageBackgroundLayer extends StatelessWidget {
  const PageBackgroundLayer({
    super.key,
    required this.background,
    this.visible,
    this.config = const PageConfig(),
  });

  final PageBackground background;
  final ValueListenable<Rect>? visible;
  final PageConfig config;

  @override
  Widget build(BuildContext context) {
    if (background == PageBackground.blank) {
      return const SizedBox.expand();
    }
    final AppColors colors = AppColors.of(context);
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: CustomPaint(
          key: const ValueKey<String>('page-background'),
          painter: PageBackgroundPainter(
            background: background,
            rule: colors.pageRule,
            marginRule: colors.pageMarginRule,
            visible: visible,
            config: config,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class PageBackgroundPainter extends CustomPainter {
  PageBackgroundPainter({
    required this.background,
    required this.rule,
    required this.marginRule,
    this.visible,
    this.config = const PageConfig(),
  }) : super(repaint: visible);

  final PageBackground background;
  final Color rule;
  final Color marginRule;
  final ValueListenable<Rect>? visible;
  final PageConfig config;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect area = (visible?.value ?? Offset.zero & size).intersect(
      Offset.zero & size,
    );
    if (area.isEmpty) {
      return;
    }
    // The first rule at or after [from], on a lattice of [spacing] that
    // starts at [first].
    double start(double from, double first, double spacing) {
      return first + math.max(0, ((from - first) / spacing).ceil()) * spacing;
    }

    final Paint paint = Paint()
      ..color = rule
      ..strokeWidth = 1
      ..isAntiAlias = true;
    switch (background) {
      case PageBackground.blank:
        return;
      case PageBackground.lined:
        final double spacing = config.lineSpacing;
        for (
          double y = start(area.top, spacing * 2, spacing);
          y <= area.bottom;
          y += spacing
        ) {
          canvas.drawLine(Offset(area.left, y), Offset(area.right, y), paint);
        }
        final double x = config.marginRuleInset;
        if (x >= area.left && x <= area.right) {
          canvas.drawLine(
            Offset(x, area.top),
            Offset(x, area.bottom),
            Paint()
              ..color = marginRule
              ..strokeWidth = 1,
          );
        }
      case PageBackground.grid:
        final double spacing = config.gridSpacing;
        for (
          double y = start(area.top, spacing, spacing);
          y <= area.bottom;
          y += spacing
        ) {
          canvas.drawLine(Offset(area.left, y), Offset(area.right, y), paint);
        }
        for (
          double x = start(area.left, spacing, spacing);
          x <= area.right;
          x += spacing
        ) {
          canvas.drawLine(Offset(x, area.top), Offset(x, area.bottom), paint);
        }
      case PageBackground.dotted:
        final double spacing = config.dotSpacing;
        final List<Offset> dots = <Offset>[
          for (
            double y = start(area.top, spacing, spacing);
            y <= area.bottom;
            y += spacing
          )
            for (
              double x = start(area.left, spacing, spacing);
              x <= area.right;
              x += spacing
            )
              Offset(x, y),
        ];
        canvas.drawPoints(
          PointMode.points,
          dots,
          Paint()
            ..color = rule
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round,
        );
    }
  }

  @override
  bool shouldRepaint(PageBackgroundPainter oldDelegate) {
    return oldDelegate.background != background ||
        oldDelegate.rule != rule ||
        oldDelegate.marginRule != marginRule ||
        oldDelegate.visible != visible ||
        oldDelegate.config != config;
  }
}
