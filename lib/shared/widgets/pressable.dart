import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../app/theme/app_tokens.dart';

enum PressableType { button, icon, glass, card, chip }

/// Shared touch-down feedback for app controls.
///
/// This listens to raw pointers so it does not compete with the control's own
/// gesture recognizer. The visual state changes synchronously on pointer-down;
/// the child remains responsible for firing its action on release.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.enabled = true,
    this.type = PressableType.button,
    this.pressedScale,
    this.borderRadius,
  });

  final Widget child;
  final bool enabled;
  final PressableType type;
  final double? pressedScale;
  final BorderRadius? borderRadius;

  /// Whether the nearest shared press interaction is currently held down.
  static bool isPressed(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_PressableStateScope>()
          ?.pressed ??
      false;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> with TickerProviderStateMixin {
  late final AnimationController _scale = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );
  late final AnimationController _highlight = AnimationController(
    vsync: this,
    duration: AppMotion.press,
    value: 0,
  );
  bool _reduceMotion = false;
  int _motionGeneration = 0;

  double get _pressedScale =>
      widget.pressedScale ??
      switch (widget.type) {
        PressableType.icon => AppMotion.iconPressedScale,
        PressableType.card => AppMotion.cardPressedScale,
        PressableType.chip => 0.96,
        PressableType.button ||
        PressableType.glass => AppMotion.buttonPressedScale,
      };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced && !_reduceMotion) {
      _scale
        ..stop()
        ..value = 1;
    }
    _reduceMotion = reduced;
  }

  @override
  void didUpdateWidget(Pressable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && oldWidget.enabled) _release();
  }

  @override
  void dispose() {
    _scale.dispose();
    _highlight.dispose();
    super.dispose();
  }

  void _press(PointerDownEvent event) {
    if (!widget.enabled) return;
    _motionGeneration++;
    _highlight
      ..stop()
      ..value = 1;
    if (_reduceMotion) return;
    _scale
      ..stop()
      ..value = _pressedScale;
  }

  void _release([PointerEvent? event]) {
    // A drop or navigation can remove the control before its pointer-up.
    if (!mounted) return;
    final int generation = ++_motionGeneration;
    _highlight.animateBack(
      0,
      duration: _reduceMotion ? AppMotion.reduced : AppMotion.press,
      curve: _reduceMotion ? AppMotion.reducedCurve : AppMotion.fadeOutCurve,
    );
    if (_scale.value == 1 && !_scale.isAnimating) return;
    if (!mounted || _reduceMotion || !widget.enabled) {
      _scale
        ..stop()
        ..value = 1;
      return;
    }
    final double velocity = _scale.velocity;
    _scale.stop();
    _scale
        .animateWith(
          SpringSimulation(
            AppMotion.spring(context, AppMotion.snappy),
            _scale.value,
            1,
            velocity,
          ),
        )
        .whenCompleteOrCancel(() {
          if (mounted && generation == _motionGeneration) _scale.value = 1;
        });
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.resolve(context);
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return Listener(
      // Transparent areas inside the bounds press too.
      behavior: HitTestBehavior.translucent,
      onPointerDown: _press,
      onPointerUp: _release,
      onPointerCancel: _release,
      child: AnimatedOpacity(
        opacity: widget.enabled ? 1 : 0.38,
        duration: _reduceMotion ? AppMotion.reduced : AppMotion.fadeIn,
        curve: _reduceMotion ? AppMotion.reducedCurve : AppMotion.fadeInCurve,
        child: AnimatedBuilder(
          animation: Listenable.merge(<Listenable>[_scale, _highlight]),
          child: widget.child,
          builder: (BuildContext context, Widget? child) {
            final Widget highlighted = Stack(
              fit: StackFit.passthrough,
              children: <Widget>[
                _PressableStateScope(
                  pressed: _highlight.value > 0,
                  child: child!,
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: (dark ? colors.surface : colors.shadow)
                            .withValues(alpha: 0.10 * _highlight.value),
                        borderRadius: widget.borderRadius,
                        shape:
                            widget.type == PressableType.icon &&
                                widget.borderRadius == null
                            ? BoxShape.circle
                            : BoxShape.rectangle,
                      ),
                    ),
                  ),
                ),
              ],
            );
            return Transform.scale(
              scale: _reduceMotion ? 1 : _scale.value,
              child: highlighted,
            );
          },
        ),
      ),
    );
  }
}

class _PressableStateScope extends InheritedWidget {
  const _PressableStateScope({required this.pressed, required super.child});

  final bool pressed;

  @override
  bool updateShouldNotify(_PressableStateScope oldWidget) =>
      oldWidget.pressed != pressed;
}
