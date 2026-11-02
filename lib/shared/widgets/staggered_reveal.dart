import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../app/theme/app_tokens.dart';
import '../motion/motion_memory.dart';

/// Brings loaded items into view one after another, each fading in where
/// it is: no zoom, slide or scale. Wrap each item in a [StaggerItem] with
/// its place in the list.
///
/// While [child] is null nothing is shown; the items start fading in once
/// it arrives, or at once when it is there from the start, and never again
/// for this widget, so a list read again in place does not replay. One
/// controller drives every item, inside the frame update, and only opacity
/// changes, so an item is not laid out or painted again while it fades.
/// Items past [AppMotion.staggerCount] arrive with the last of those, and
/// items built after the run (scrolled into view later) are simply there.
class StaggeredReveal extends StatefulWidget {
  const StaggeredReveal({
    super.key,
    required this.child,
    this.pace = MotionPace.standard,
    this.memoryKey,
    this.semanticsLabel,
  });

  /// What was loaded, or null while it is still on its way.
  final Widget? child;

  /// A revisit ([MotionPace.revisit]) runs tighter and with the
  /// [AppMotion.glance] fade.
  final MotionPace pace;

  /// Remembered in [MotionMemory] as shown once [child] arrives.
  final Object? memoryKey;

  /// Read out while [child] is still on its way.
  final String? semanticsLabel;

  @override
  State<StaggeredReveal> createState() => _StaggeredRevealState();
}

class _StaggeredRevealState extends State<StaggeredReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _run = AnimationController(vsync: this);

  /// How the run is timed, fixed as it starts; null until then.
  _StaggerTimeline? _timeline;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_timeline == null && widget.child != null) _start();
  }

  @override
  void didUpdateWidget(StaggeredReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_timeline == null && widget.child != null) _start();
  }

  @override
  void dispose() {
    _run.dispose();
    super.dispose();
  }

  void _start() {
    final Object? key = widget.memoryKey;
    if (key != null) MotionMemory.instance.remember(key);
    final bool revisit = widget.pace == MotionPace.revisit;
    final _StaggerTimeline timeline = MediaQuery.disableAnimationsOf(context)
        ? const _StaggerTimeline(
            lead: Duration.zero,
            step: Duration.zero,
            fade: AppMotion.reduced,
          )
        : _StaggerTimeline(
            lead: AppMotion.staggerLead,
            step: revisit
                ? AppMotion.staggerRevisitStep
                : AppMotion.staggerStep,
            fade: revisit ? AppMotion.glance : AppMotion.fadeIn,
          );
    _timeline = timeline;
    _run.duration = timeline.total;
    _run.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final Widget? child = widget.child;
    final _StaggerTimeline? timeline = _timeline;
    if (child == null || timeline == null) {
      return Semantics(
        label: widget.semanticsLabel,
        child: const SizedBox.shrink(),
      );
    }
    return _StaggerScope(run: _run, timeline: timeline, child: child);
  }
}

/// One item of a [StaggeredReveal], fading in at its [index]'s turn.
/// Outside one it is shown as it is.
class StaggerItem extends StatelessWidget {
  const StaggerItem({super.key, required this.index, required this.child});

  /// Its place in the list, from 0.
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final _StaggerScope? scope = context
        .dependOnInheritedWidgetOfExactType<_StaggerScope>();
    if (scope == null) return child;
    return FadeTransition(opacity: scope.opacityOf(index), child: child);
  }
}

@immutable
class _StaggerTimeline {
  const _StaggerTimeline({
    required this.lead,
    required this.step,
    required this.fade,
  });

  final Duration lead;
  final Duration step;
  final Duration fade;

  Duration get total => lead + step * (AppMotion.staggerCount - 1) + fade;

  /// When item [index] starts and ends fading in, as fractions of [total].
  Interval intervalOf(int index) {
    final double whole = total.inMicroseconds.toDouble();
    final Duration start =
        lead + step * math.min(index, AppMotion.staggerCount - 1);
    return Interval(
      start.inMicroseconds / whole,
      (start + fade).inMicroseconds / whole,
      curve: AppMotion.fadeInCurve,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is _StaggerTimeline &&
      other.lead == lead &&
      other.step == step &&
      other.fade == fade;

  @override
  int get hashCode => Object.hash(lead, step, fade);
}

class _StaggerScope extends InheritedWidget {
  const _StaggerScope({
    required this.run,
    required this.timeline,
    required super.child,
  });

  final AnimationController run;
  final _StaggerTimeline timeline;

  Animation<double> opacityOf(int index) =>
      run.drive(CurveTween(curve: timeline.intervalOf(index)));

  @override
  bool updateShouldNotify(_StaggerScope oldWidget) =>
      run != oldWidget.run || timeline != oldWidget.timeline;
}
