import 'package:flutter/cupertino.dart';

import '../../app/theme/app_tokens.dart';

/// Cupertino's full-width push/pop transition on every supported platform.
///
/// Keeping Flutter's implementation preserves the interactive leading-edge
/// pop gesture, interruption, RTL geometry, secondary-route parallax and
/// velocity hand-off instead of approximating them in a custom slide.
class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  static const CupertinoPageTransitionsBuilder _cupertino =
      CupertinoPageTransitionsBuilder();

  @override
  Duration get transitionDuration => AppMotion.smooth.duration;

  @override
  Duration get reverseTransitionDuration => AppMotion.smooth.duration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final Widget grounded = ColoredBox(
      color: AppColors.of(context).background,
      child: child,
    );
    if (MediaQuery.disableAnimationsOf(context)) {
      return FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: AppMotion.reducedCurve,
        ),
        child: grounded,
      );
    }
    return _cupertino.buildTransitions<T>(
      route,
      context,
      animation,
      secondaryAnimation,
      grounded,
    );
  }
}

/// A route with native Cupertino gesture ownership on every platform.
class AppPageRoute<T> extends CupertinoPageRoute<T> {
  AppPageRoute({
    required super.builder,
    super.settings,
    super.fullscreenDialog,
    super.maintainState,
    super.allowSnapshotting,
    super.barrierDismissible,
  });

  @override
  Duration get transitionDuration => AppMotion.smooth.duration;

  @override
  Duration get reverseTransitionDuration => AppMotion.smooth.duration;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => const AppPageTransitionsBuilder().buildTransitions<T>(
    this,
    context,
    animation,
    secondaryAnimation,
    child,
  );
}
