import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import '../motion/motion_memory.dart';

/// An iOS-style alert: a restrained scale from 1.08 with a short fade.
///
/// [motionKey] names the dialog for [MotionMemory]: shown for the first
/// time it grows in slowly and smoothly; shown again it only fades in
/// slightly, without growing ([AppMotion.glance]). Without a key,
/// the route's [RouteSettings.name] is used, and without either the dialog
/// keeps the standard timing.
class AppDialogRoute<T> extends DialogRoute<T> {
  AppDialogRoute({
    required super.context,
    required super.builder,
    super.themes,
    super.barrierColor,
    super.barrierDismissible,
    super.barrierLabel,
    super.useSafeArea,
    super.settings,
    super.anchorPoint,
    super.traversalEdgeBehavior,
    super.requestFocus,
    Object? motionKey,
  }) : _pace = _paceOf(motionKey ?? settings?.name);

  final MotionPace _pace;

  static MotionPace _paceOf(Object? key) => key == null
      ? MotionPace.standard
      : MotionMemory.instance.recall(('dialog', key));

  @override
  Duration get transitionDuration =>
      AppMotion.paced(AppMotion.snappy.duration, _pace);

  @override
  Duration get reverseTransitionDuration => AppMotion.fadeOut;

  static final Animatable<double> _grow = Tween<double>(
    begin: 1.08,
    end: 1,
  ).chain(CurveTween(curve: AppMotion.fadeInCurve));
  static final Animatable<double> _fade = CurveTween(
    curve: AppMotion.fadeInCurve,
  );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return FadeTransition(opacity: animation, child: child);
    }
    if (!AppMotion.travels(_pace)) {
      return FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: AppMotion.glanceCurve,
          reverseCurve: AppMotion.fadeOutCurve,
        ),
        child: child,
      );
    }
    return FadeTransition(
      opacity: animation.drive(_fade),
      child: ScaleTransition(scale: animation.drive(_grow), child: child),
    );
  }
}

/// [showDialog], arriving with [AppDialogRoute]'s calm transition.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  TraversalEdgeBehavior? traversalEdgeBehavior,
  Object? motionKey,
}) {
  final NavigatorState navigator = Navigator.of(
    context,
    rootNavigator: useRootNavigator,
  );
  return navigator.push<T>(
    AppDialogRoute<T>(
      context: context,
      builder: builder,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierColor:
          barrierColor ?? AppColors.of(context).shadow.withValues(alpha: 0.35),
      barrierDismissible: barrierDismissible,
      barrierLabel: barrierLabel,
      useSafeArea: useSafeArea,
      settings: routeSettings,
      anchorPoint: anchorPoint,
      traversalEdgeBehavior:
          traversalEdgeBehavior ?? TraversalEdgeBehavior.closedLoop,
      motionKey: motionKey,
    ),
  );
}
