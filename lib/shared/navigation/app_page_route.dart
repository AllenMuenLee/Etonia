import 'package:flutter/cupertino.dart';

import '../../app/theme/app_tokens.dart';
import '../motion/motion_memory.dart';

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
///
/// [motionKey] names the page for [MotionMemory]: the first time it is
/// pushed it slides in slowly and smoothly; when it has been shown before
/// it only fades in slightly where it is ([AppMotion.glance]). Without a
/// key, the route's [RouteSettings.name] is used, and without either the
/// route keeps the standard transition.
class AppPageRoute<T> extends CupertinoPageRoute<T> {
  AppPageRoute({
    required super.builder,
    super.settings,
    super.fullscreenDialog,
    super.maintainState,
    super.allowSnapshotting,
    super.barrierDismissible,
    Object? motionKey,
  }) : _pace = _paceOf(motionKey ?? settings?.name);

  final MotionPace _pace;

  static MotionPace _paceOf(Object? key) => key == null
      ? MotionPace.standard
      : MotionMemory.instance.recall(('page', key));

  @override
  Duration get transitionDuration =>
      AppMotion.paced(AppMotion.smooth.duration, _pace);

  /// A page that faded in fades out as briefly; one that slid, slides back.
  @override
  Duration get reverseTransitionDuration =>
      AppMotion.travels(_pace) ? AppMotion.smooth.duration : AppMotion.fadeOut;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (!AppMotion.travels(_pace) && !MediaQuery.disableAnimationsOf(context)) {
      return FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: AppMotion.glanceCurve,
          reverseCurve: AppMotion.fadeOutCurve,
        ),
        child: ColoredBox(
          color: AppColors.of(context).background,
          child: child,
        ),
      );
    }
    return const AppPageTransitionsBuilder().buildTransitions<T>(
      this,
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }
}
