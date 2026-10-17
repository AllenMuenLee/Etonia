import 'package:flutter/widgets.dart';

import '../../app/theme/app_tokens.dart';

/// A full-screen page that fades in while drifting a little from the
/// trailing edge, over the one below, which eases back behind it.
///
/// The motion starts softly and settles slowly, so a page arrives instead
/// of landing. Only the pages move, so a transition costs little to draw.
/// There is no edge swipe to go back: on a page of paper, a stroke begun
/// at the edge is writing.
class AppPageRoute<T> extends PageRouteBuilder<T> {
  AppPageRoute({required WidgetBuilder builder, super.settings})
    : super(
        transitionDuration: const Duration(milliseconds: 520),
        reverseTransitionDuration: const Duration(milliseconds: 400),
        pageBuilder:
            (
              BuildContext context,
              Animation<double> animation,
              Animation<double> secondaryAnimation,
            ) => builder(context),
        transitionsBuilder:
            (
              BuildContext context,
              Animation<double> animation,
              Animation<double> secondaryAnimation,
              Widget child,
            ) {
              if (MediaQuery.disableAnimationsOf(context)) {
                return child;
              }
              final Animation<double> enter = CurvedAnimation(
                parent: animation,
                curve: AppMotion.gentleCurve,
              );
              // The page is opaque well before it stops moving.
              final Animation<double> fade = CurvedAnimation(
                parent: animation,
                curve: const Interval(0, 0.6, curve: Curves.easeOut),
              );
              final Animation<double> recede = CurvedAnimation(
                parent: secondaryAnimation,
                curve: AppMotion.gentleCurve,
              );
              return SlideTransition(
                position: Tween<Offset>(
                  begin: Offset.zero,
                  end: const Offset(-0.04, 0),
                ).animate(recede),
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.08, 0),
                    end: Offset.zero,
                  ).animate(enter),
                  child: FadeTransition(
                    opacity: fade,
                    child: ColoredBox(
                      color: AppColors.of(context).background,
                      child: child,
                    ),
                  ),
                ),
              );
            },
      );
}
