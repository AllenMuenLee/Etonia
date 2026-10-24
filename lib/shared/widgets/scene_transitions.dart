import 'package:flutter/widgets.dart';

import '../../app/theme/app_tokens.dart';

/// Replaces a library detail scene. Going [direction] 1 into a folder zooms
/// into it: the scene left grows past the viewer as it fades and the folder's
/// rises from a little smaller. -1 is the same move reversed, out of a folder.
/// Between folders side by side (0) it is a cross-fade with a small vertical
/// drift. There is intentionally no horizontal slide or per-item stagger.
class SceneCrossfade extends StatelessWidget {
  const SceneCrossfade({
    super.key,
    required this.scope,
    required this.child,
    this.direction = 0,
  });

  final Object? scope;
  final int direction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    final bool zoom = !reduced && direction != 0;
    final ValueKey<Object?> sceneKey = ValueKey<Object?>(scope);
    return AnimatedSwitcher(
      duration: reduced
          ? AppMotion.reduced
          : zoom
          ? AppMotion.zoom
          : AppMotion.fadeIn,
      reverseDuration: reduced
          ? AppMotion.reduced
          : zoom
          ? AppMotion.zoom
          : AppMotion.fadeOut,
      switchInCurve: reduced
          ? AppMotion.reducedCurve
          : zoom
          ? AppMotion.zoomInCurve
          : AppMotion.fadeInCurve,
      switchOutCurve: reduced
          ? AppMotion.reducedCurve
          : zoom
          ? AppMotion.zoomOutCurve
          : AppMotion.fadeOutCurve,
      transitionBuilder: (Widget current, Animation<double> animation) {
        final Widget faded = FadeTransition(opacity: animation, child: current);
        if (reduced) return faded;
        if (!zoom) {
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.02),
              end: Offset.zero,
            ).animate(animation),
            child: faded,
          );
        }
        // The animation runs 0 to 1 for the scene arriving and 1 to 0 for the
        // one leaving, so both are at full size at 1. Into a folder the
        // arrival starts small and the departure ends large; out of one, the
        // other way round.
        final bool arriving = current.key == sceneKey;
        final bool smallAtRest = arriving == (direction > 0);
        return ScaleTransition(
          scale: Tween<double>(
            begin: smallAtRest ? AppMotion.zoomFar : AppMotion.zoomNear,
            end: 1,
          ).animate(animation),
          child: faded,
        );
      },
      child: RepaintBoundary(key: sceneKey, child: child),
    );
  }
}
