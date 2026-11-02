import 'dart:math' as math;
import 'dart:ui' show PointMode;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../app/theme/app_tokens.dart';
import 'page_setup.dart';
import 'page_viewport.dart';

/// The paper's printed rules, under the ink, in page coordinates. Never
/// part of the ink and never in semantics.
///
/// Only the rules inside [visible], the part of the page on screen, are
/// painted, so a whiteboard costs no more than a small page. Zoomed far
/// out, rules are thinned to stay [PageConfig.minRuleGap] apart on screen.
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
            scale: PageViewport.scaleOf(context),
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
    this.scale,
    this.config = const PageConfig(),
  }) : super(repaint: Listenable.merge(<Listenable?>[visible, scale]));

  final PageBackground background;
  final Color rule;
  final Color marginRule;
  final ValueListenable<Rect>? visible;

  /// Screen pixels per page unit; without it, one.
  final ValueListenable<double>? scale;
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

    final double screen = scale?.value ?? 1;
    // Every second rule left out, as often as it takes to keep them apart
    // on screen: what is kept is always on the full lattice.
    double thinned(double spacing) {
      if (!screen.isFinite || screen <= 0) return spacing;
      double kept = spacing;
      while (kept * screen < config.minRuleGap) {
        kept *= 2;
      }
      return kept;
    }

    // Never thinner than half a pixel on screen, however far out; as before
    // at any zoom a paper page is shown at.
    final double hairline = math.max(1, 0.5 / screen);
    final Paint paint = Paint()
      ..color = rule
      ..strokeWidth = hairline
      ..isAntiAlias = true;
    switch (background) {
      case PageBackground.blank:
        return;
      case PageBackground.lined:
        final double spacing = thinned(config.lineSpacing);
        for (
          double y = start(area.top, config.lineSpacing * 2, spacing);
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
              ..strokeWidth = hairline,
          );
        }
      case PageBackground.grid:
        final double spacing = thinned(config.gridSpacing);
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
        final double spacing = thinned(config.dotSpacing);
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
            ..strokeWidth = math.max(3, 1.5 / screen)
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
        oldDelegate.scale != scale ||
        oldDelegate.config != config;
  }
}
