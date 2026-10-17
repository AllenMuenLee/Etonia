import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

import '../../app/theme/app_tokens.dart';

/// Shrinks [child] a little while a pointer is down on it and springs it
/// back on release, so a control answers the finger before it acts.
///
/// It only listens to raw pointers, so it never competes with the
/// [InkWell], [GestureDetector], or button inside it for the gesture.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.enabled = true,
    this.pressedScale = AppMotion.pressedScale,
  });

  final Widget child;

  /// Off, a press leaves the child still, as for a disabled control.
  final bool enabled;

  final double pressedScale;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scale = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );

  bool get _animate =>
      widget.enabled && !MediaQuery.disableAnimationsOf(context);

  @override
  void didUpdateWidget(Pressable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _scale.value != 1) _release();
  }

  @override
  void dispose() {
    _scale.dispose();
    super.dispose();
  }

  void _press(PointerDownEvent event) {
    if (!_animate) return;
    _scale.animateTo(
      widget.pressedScale,
      duration: AppMotion.press,
      curve: AppMotion.standard,
    );
  }

  void _release([PointerEvent? event]) {
    if (_scale.value == 1 && !_scale.isAnimating) return;
    if (!mounted || MediaQuery.disableAnimationsOf(context)) {
      _scale.value = 1;
      return;
    }
    _scale
        .animateWith(
          SpringSimulation(AppMotion.spring, _scale.value, 1, _scale.velocity),
        )
        // The spring stops within a tolerance of rest; land exactly on it.
        .then((_) {
          if (mounted) _scale.value = 1;
        });
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _press,
      onPointerUp: _release,
      onPointerCancel: _release,
      child: AnimatedBuilder(
        animation: _scale,
        // Always a Transform, so the child keeps its state when it moves.
        builder: (BuildContext context, Widget? child) =>
            Transform.scale(scale: _scale.value, child: child),
        child: widget.child,
      ),
    );
  }
}
