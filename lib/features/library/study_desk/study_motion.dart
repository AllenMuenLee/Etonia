import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../shared/memory/memory_pressure.dart';
import '../../../shared/motion/motion_memory.dart';

/// What the Study Desk has already played an entrance for, so that rows
/// scrolled back into view, or rebuilt, do not play it again.
///
/// Bounded: past [capacity] the longest-unused keys go, and a row of those
/// would only fade in once more. All of it is let go when the system runs low
/// on memory, as `MotionMemory` is.
class StudyMotionLedger {
  StudyMotionLedger._();

  static final StudyMotionLedger instance = StudyMotionLedger._();

  static const int capacity = 256;

  final LinkedHashSet<Object> _played = LinkedHashSet<Object>();
  bool _listening = false;

  /// True the first time [key] is claimed, and false while it is remembered.
  bool claim(Object key) {
    _listen();
    final bool seen = _played.remove(key);
    _played.add(key);
    if (_played.length > capacity) _played.remove(_played.first);
    return !seen;
  }

  bool hasPlayed(Object key) => _played.contains(key);

  void forgetWhere(bool Function(Object key) test) => _played.removeWhere(test);

  int get length => _played.length;

  void _listen() {
    if (_listening) return;
    _listening = true;
    MemoryPressure.instance.addListener(_played.clear);
  }

  @visibleForTesting
  void reset() => _played.clear();
}

/// A simulation that waits [delay] seconds, then runs [inner]: a staggered
/// spring without a timer to cancel.
class _Delayed extends Simulation {
  _Delayed(this.inner, this.delay) : super(tolerance: inner.tolerance);

  final Simulation inner;
  final double delay;

  @override
  double x(double time) => inner.x(math.max(0, time - delay));

  @override
  double dx(double time) => inner.dx(math.max(0, time - delay));

  @override
  bool isDone(double time) => time >= delay && inner.isDone(time - delay);
}

class _Mapped<T> extends Animatable<T> {
  const _Mapped(this._map);

  final T Function(double t) _map;

  @override
  T transform(double t) => _map(t);
}

/// Brings [child] into view where it is: it fades in and rises a few pixels
/// on a spring, or, for a revisit, only fades ([AppMotion.glance]).
///
/// One controller drives one paint-only transform and one opacity, and the
/// child sits in its own repaint boundary while it moves, so it is not laid
/// out or painted again for each frame. A widget that does not play (see
/// [once] and [enabled]) is just its child, with nothing around it.
class StudyAppear extends StatefulWidget {
  const StudyAppear({
    super.key,
    required this.child,
    this.once,
    this.enabled = true,
    this.playOnMount = true,
    this.replayKey,
    this.memoryKey,
    this.pace = MotionPace.standard,
    this.delay = Duration.zero,
    this.rise = 10,
  });

  final Widget child;

  /// When set, plays only if this is the first time it is claimed in the
  /// [StudyMotionLedger].
  final Object? once;
  final bool enabled;

  /// False for what is already in view as its parent arrives: it plays only
  /// when [replayKey] changes.
  final bool playOnMount;

  /// Plays again, in place, whenever this changes.
  final Object? replayKey;

  /// Asked of `MotionMemory` at each play for the pace: slow the first time,
  /// a glance after. Without it [pace] is used.
  final Object? memoryKey;
  final MotionPace pace;

  /// Wait this long before starting, for an item behind others.
  final Duration delay;

  /// How far below its place it starts, in logical pixels.
  final double rise;

  @override
  State<StudyAppear> createState() => _StudyAppearState();
}

class _StudyAppearState extends State<StudyAppear>
    with SingleTickerProviderStateMixin {
  AnimationController? _run;
  Animation<double>? _opacity;
  bool _decided = false;
  bool _travels = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_decided) return;
    _decided = true;
    if (!widget.enabled) return;
    final Object? once = widget.once;
    // Already played: nothing wraps the child, now or later.
    if (once != null && !StudyMotionLedger.instance.claim(once)) return;
    final AnimationController run = _run = AnimationController(
      vsync: this,
      value: 1,
    );
    _opacity = run;
    if (widget.playOnMount) _begin();
  }

  @override
  void didUpdateWidget(StudyAppear oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_run != null && oldWidget.replayKey != widget.replayKey) _begin();
  }

  @override
  void dispose() {
    _run?.dispose();
    super.dispose();
  }

  void _begin() {
    final AnimationController run = _run!;
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    final Object? memory = widget.memoryKey;
    final MotionPace pace = memory == null
        ? widget.pace
        : MotionMemory.instance.recall(memory);
    _travels = !reduced && AppMotion.travels(pace);
    final double delay = reduced ? 0 : widget.delay.inMicroseconds / 1e6;
    run.stop();
    run.value = 0;
    if (_travels) {
      _opacity = run.drive(
        CurveTween(curve: const Interval(0, 0.55, curve: Curves.easeOut)),
      );
      final SpringDescription spring = AppMotion.pacedSpring(
        AppMotion.smooth,
        pace,
      );
      final SpringSimulation spring0 = SpringSimulation(spring, 0, 1, 0);
      unawaited(
        run
            .animateWith(delay > 0 ? _Delayed(spring0, delay) : spring0)
            .orCancel
            .catchError((Object _) {}),
      );
    } else {
      _opacity = run;
      final Duration fade = reduced ? AppMotion.reduced : AppMotion.glance;
      final Duration total = fade + widget.delay;
      final double lead = total == fade
          ? 0
          : widget.delay.inMicroseconds / total.inMicroseconds;
      unawaited(
        run
            .animateTo(
              1,
              duration: total,
              curve: Interval(lead, 1, curve: AppMotion.glanceCurve),
            )
            .orCancel
            .catchError((Object _) {}),
      );
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final AnimationController? run = _run;
    if (run == null) return widget.child;
    // The same few widgets whichever way it plays, so a replay, slow or as a
    // glance, never moves the child from one place in the tree to another.
    final Widget child = AnimatedBuilder(
      animation: run,
      child: RepaintBoundary(child: widget.child),
      builder: (BuildContext context, Widget? child) => Transform.translate(
        offset: Offset(0, _travels ? widget.rise * (1 - run.value) : 0),
        child: child,
      ),
    );
    return FadeTransition(opacity: _opacity!, child: child);
  }
}

/// [child] arriving and leaving: while it is non-null it is shown; when it
/// goes, the last one is kept in place while it fades and slides away, then
/// let go, so nothing that left stays built.
///
/// Both moves are paint-only: it is laid out once, at its own size.
class StudyPresence extends StatefulWidget {
  const StudyPresence({
    super.key,
    required this.child,
    this.offset = Offset.zero,
  });

  final Widget? child;

  /// Where it comes from and goes to, in its own widths and heights.
  final Offset offset;

  @override
  State<StudyPresence> createState() => _StudyPresenceState();
}

class _StudyPresenceState extends State<StudyPresence>
    with SingleTickerProviderStateMixin {
  late final AnimationController _run = AnimationController(
    vsync: this,
    value: widget.child == null ? 0 : 1,
  )..addStatusListener(_settled);
  late Widget? _shown = widget.child;

  @override
  void didUpdateWidget(StudyPresence oldWidget) {
    super.didUpdateWidget(oldWidget);
    final Widget? next = widget.child;
    if (next != null) {
      _shown = next;
      if (oldWidget.child == null && !_run.isAnimating ||
          _run.status == AnimationStatus.reverse) {
        _enter();
      }
    } else if (_shown != null && oldWidget.child != null) {
      _exit();
    }
  }

  @override
  void dispose() {
    _run.dispose();
    super.dispose();
  }

  void _enter() {
    if (MediaQuery.disableAnimationsOf(context)) {
      _run.animateTo(1, duration: AppMotion.reduced);
      return;
    }
    unawaited(
      _run
          .animateWith(SpringSimulation(AppMotion.snappy, _run.value, 1, 0))
          .orCancel
          .catchError((Object _) {}),
    );
  }

  void _exit() {
    unawaited(
      _run
          .animateBack(
            0,
            duration: MediaQuery.disableAnimationsOf(context)
                ? AppMotion.reduced
                : AppMotion.glance,
            curve: AppMotion.fadeOutCurve,
          )
          .orCancel
          .catchError((Object _) {}),
    );
  }

  void _settled(AnimationStatus status) {
    if (status == AnimationStatus.dismissed &&
        widget.child == null &&
        _shown != null &&
        mounted) {
      setState(() => _shown = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget? shown = _shown;
    if (shown == null) return const SizedBox.shrink();
    final bool leaving = widget.child == null;
    final Offset from = MediaQuery.disableAnimationsOf(context)
        ? Offset.zero
        : widget.offset;
    return ExcludeSemantics(
      excluding: leaving,
      child: IgnorePointer(
        ignoring: leaving,
        child: FadeTransition(
          opacity: _run,
          child: SlideTransition(
            position: _run.drive(
              _Mapped<Offset>((double t) => from * (1 - t.clamp(0.0, 1.2))),
            ),
            child: shown,
          ),
        ),
      ),
    );
  }
}

/// Keeps every scene built, as an `IndexedStack` does, and moves between them
/// with a fade and a slight slide: the leaving scene goes quickly, the
/// arriving one settles on a spring.
///
/// A scene not in view is not painted, not ticking, and not in the semantics
/// tree; one in view is drawn as a single picture while it moves, so the move
/// costs a composited fade, not another layout.
class StudyScenes extends StatefulWidget {
  const StudyScenes({super.key, required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  State<StudyScenes> createState() => _StudyScenesState();
}

class _StudyScenesState extends State<StudyScenes>
    with SingleTickerProviderStateMixin {
  late final AnimationController _run = AnimationController(
    vsync: this,
    value: 1,
  )..addStatusListener(_status);
  late int _from = widget.index;
  late int _to = widget.index;
  bool _moving = false;
  bool _travels = true;

  List<Animation<double>> _opacities = const <Animation<double>>[];
  List<Animation<Offset>> _offsets = const <Animation<Offset>>[];

  @override
  void didUpdateWidget(StudyScenes oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index == widget.index) return;
    _from = _moving ? _to : oldWidget.index;
    _to = widget.index;
    _moving = true;
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    _travels = !reduced;
    _run.value = 0;
    if (reduced) {
      unawaited(
        _run
            .animateTo(1, duration: AppMotion.reduced)
            .orCancel
            .catchError((Object _) {}),
      );
    } else {
      unawaited(
        _run
            .animateWith(SpringSimulation(AppMotion.snappy, 0, 1, 0))
            .orCancel
            .catchError((Object _) {}),
      );
    }
  }

  @override
  void dispose() {
    _run.dispose();
    super.dispose();
  }

  void _status(AnimationStatus status) {
    if (status == AnimationStatus.completed && _moving && mounted) {
      setState(() => _moving = false);
    }
  }

  void _prepare(int count) {
    if (_opacities.length == count) return;
    _opacities = <Animation<double>>[
      for (int i = 0; i < count; i++)
        _run.drive(
          _Mapped<double>((double t) {
            if (!_moving) return i == widget.index ? 1 : 0;
            if (i == _to) return Curves.easeOut.transform(t.clamp(0.0, 1.0));
            if (i == _from) {
              return 1 - Curves.easeIn.transform((t * 2.2).clamp(0.0, 1.0));
            }
            return 0;
          }),
        ),
    ];
    _offsets = <Animation<Offset>>[
      for (int i = 0; i < count; i++)
        _run.drive(
          _Mapped<Offset>((double t) {
            if (!_moving || !_travels) return Offset.zero;
            final double direction = _to >= _from ? 1 : -1;
            if (i == _to) return Offset(direction * 0.03 * (1 - t), 0);
            if (i == _from) return Offset(-direction * 0.015 * t, 0);
            return Offset.zero;
          }),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    _prepare(widget.children.length);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        for (int i = 0; i < widget.children.length; i++)
          KeyedSubtree(
            key: ValueKey<int>(i),
            child: _scene(i, widget.children[i]),
          ),
      ],
    );
  }

  Widget _scene(int i, Widget child) {
    final bool active = i == widget.index;
    final bool visible = active || (_moving && i == _from);
    return Offstage(
      offstage: !visible,
      child: TickerMode(
        enabled: visible,
        child: IgnorePointer(
          ignoring: !active,
          child: ExcludeSemantics(
            excluding: !active,
            child: FadeTransition(
              opacity: _opacities[i],
              child: SlideTransition(
                position: _offsets[i],
                // Always in its own layer: it is the same widget, in the
                // same place, whether it moves or not, so it keeps its state.
                child: RepaintBoundary(child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows [child] when there is one, easing the room it takes open and shut and
/// cross-fading what it shows. Give each thing it may show its own key.
class StudyDisclose extends StatelessWidget {
  const StudyDisclose({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) => AnimatedSize(
    duration: AppMotion.springDuration(context, AppMotion.smooth),
    curve: AppMotion.zoomInCurve,
    alignment: Alignment.topCenter,
    child: AnimatedSwitcher(
      duration: AppMotion.resolve(context, AppMotion.fadeIn),
      reverseDuration: AppMotion.resolve(context, AppMotion.fadeOut),
      switchInCurve: AppMotion.fadeInCurve,
      switchOutCurve: AppMotion.fadeOutCurve,
      layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
        alignment: Alignment.topCenter,
        children: <Widget>[...previous, ?current],
      ),
      child:
          child ??
          const SizedBox(key: ValueKey<String>('none'), width: double.infinity),
    ),
  );
}

/// Rebuilds [builder] when [listenable] changes, and while [coalesce] says so,
/// at most once in [gap]: the change that comes last is never lost, and the
/// first one is shown at once.
///
/// For what listens to a controller that notifies for each chunk of a streamed
/// answer: a sidebar of history has no need to sort its rows ten times a
/// second.
class StudyThrottledBuilder extends StatefulWidget {
  const StudyThrottledBuilder({
    super.key,
    required this.listenable,
    required this.builder,
    this.coalesce,
    this.gap = const Duration(milliseconds: 160),
  });

  final Listenable listenable;
  final WidgetBuilder builder;
  final bool Function()? coalesce;
  final Duration gap;

  @override
  State<StudyThrottledBuilder> createState() => _StudyThrottledBuilderState();
}

class _StudyThrottledBuilderState extends State<StudyThrottledBuilder> {
  final Stopwatch _since = Stopwatch();
  Timer? _trailing;

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(StudyThrottledBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.listenable, widget.listenable)) {
      oldWidget.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _trailing?.cancel();
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted || _trailing != null) return;
    final bool throttled = widget.coalesce?.call() ?? false;
    final Duration elapsed = _since.elapsed;
    if (!throttled || !_since.isRunning || elapsed >= widget.gap) {
      _rebuild();
      return;
    }
    _trailing = Timer(widget.gap - elapsed, () {
      _trailing = null;
      if (mounted) _rebuild();
    });
  }

  void _rebuild() {
    _since
      ..reset()
      ..start();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// Runs [run] at most once in [gap], the last call always: a trailing edge.
class StudyThrottle {
  StudyThrottle(this.gap, this.run);

  final Duration gap;
  final VoidCallback run;
  final Stopwatch _since = Stopwatch();
  Timer? _trailing;

  void call() {
    if (_trailing != null) return;
    final Duration elapsed = _since.elapsed;
    if (!_since.isRunning || elapsed >= gap) {
      _fire();
      return;
    }
    _trailing = Timer(gap - elapsed, () {
      _trailing = null;
      _fire();
    });
  }

  void _fire() {
    _since
      ..reset()
      ..start();
    run();
  }

  void dispose() {
    _trailing?.cancel();
    _trailing = null;
  }
}
