import 'package:flutter/widgets.dart';

import '../../app/theme/app_tokens.dart';

/// [child], drawn as one picture whenever [controller] allows: the form a
/// scene takes while it moves or leaves, the library's folders and the
/// note editor alike. The note editor opens with a move drawn this way, so
/// it shares one set of drawing operations, warmed up by `MotionWarmUp`.
Widget scenePicture(SnapshotController controller, Widget child) =>
    SnapshotWidget(
      controller: controller,
      mode: SnapshotMode.permissive,
      child: RepaintBoundary(child: child),
    );

/// Replaces a library detail scene with a quick cross-fade where it is:
/// no zoom, slide or drift, whichever way the move goes. The scene
/// arriving brings its items in one after another (`StaggeredReveal`), so
/// it stays live; the scene leaving is drawn once into a picture and only
/// that picture fades, so nothing inside it is laid out, painted or
/// rasterized again on its way out.
///
/// [pace] says whether the scene arriving was shown before: a revisit
/// fades in with [AppMotion.glance], anything else with [AppMotion.fadeIn].
/// One controller drives both scenes, inside the frame update.
class SceneCrossfade extends StatefulWidget {
  const SceneCrossfade({
    super.key,
    required this.scope,
    required this.child,
    this.pace = MotionPace.standard,
  });

  final Object? scope;
  final MotionPace pace;
  final Widget child;

  @override
  State<SceneCrossfade> createState() => _SceneCrossfadeState();
}

class _SceneCrossfadeState extends State<SceneCrossfade>
    with SingleTickerProviderStateMixin {
  /// 0 as a switch starts, 1 once the arriving scene is at rest and the
  /// leaving one gone.
  late final AnimationController _switch = AnimationController(
    vsync: this,
    value: 1,
  )..addStatusListener(_settled);

  /// Draws the leaving scene as a picture; the arriving one stays live.
  final SnapshotController _pictures = SnapshotController(
    allowSnapshotting: true,
  );
  final SnapshotController _live = SnapshotController();

  /// The scene leaving, as it was last built, and how far it had come in
  /// when it began to leave: one cut short on its way in leaves from there.
  Widget? _leaving;
  Object? _leavingScope;
  double _leavingFrom = 1;

  /// How the switch under way is timed, fixed as it starts.
  bool _reduced = false;
  bool _revisit = false;
  Duration _inFor = AppMotion.fadeIn;
  Duration _outFor = AppMotion.fadeOut;

  @override
  void didUpdateWidget(SceneCrossfade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope == widget.scope) return;
    _leavingFrom = _arrival;
    _leaving = oldWidget.child;
    _leavingScope = oldWidget.scope;
    _reduced = MediaQuery.disableAnimationsOf(context);
    _revisit = !AppMotion.travels(widget.pace);
    if (_reduced) {
      _inFor = _outFor = AppMotion.reduced;
    } else {
      _inFor = _revisit ? AppMotion.glance : AppMotion.fadeIn;
      _outFor = AppMotion.fadeOut;
    }
    _switch.duration = _inFor > _outFor ? _inFor : _outFor;
    _switch.forward(from: 0);
  }

  @override
  void dispose() {
    _switch.dispose();
    _pictures.dispose();
    _live.dispose();
    super.dispose();
  }

  void _settled(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    if (_leaving != null) {
      setState(() {
        _leaving = null;
        _leavingScope = null;
      });
    }
  }

  /// How far [part] of the switch, lasting [length], has come along [curve].
  double _along(Duration length, Curve curve) {
    final int total = _switch.duration?.inMicroseconds ?? 0;
    if (total == 0) return 1;
    final double t = (_switch.value * total / length.inMicroseconds).clamp(
      0.0,
      1.0,
    );
    return curve.transform(t);
  }

  /// How far the arriving scene has come in.
  double get _arrival => _along(
    _inFor,
    _reduced
        ? AppMotion.reducedCurve
        : _revisit
        ? AppMotion.glanceCurve
        : AppMotion.fadeInCurve,
  );

  /// How much of the leaving scene is still there.
  double get _departure =>
      _leavingFrom *
      (1 -
          _along(
            _outFor,
            _reduced ? AppMotion.reducedCurve : AppMotion.fadeOutCurve,
          ));

  /// [child] at [level] of the way to rest: 0 out of view, 1 at rest.
  /// Every scene is wrapped the same way, under its own key, so a scene
  /// keeps its state as it goes from arriving to leaving.
  Widget _scene(
    Object? scope,
    Widget child,
    double level, {
    required bool arriving,
  }) {
    return KeyedSubtree(
      key: ValueKey<Object?>(scope),
      child: IgnorePointer(
        ignoring: !arriving,
        child: Opacity(
          opacity: level,
          child: scenePicture(arriving ? _live : _pictures, child),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget current = widget.child;
    final Object? scope = widget.scope;
    return AnimatedBuilder(
      animation: _switch,
      builder: (BuildContext context, Widget? _) {
        final Widget? leaving = _leaving;
        return Stack(
          fit: StackFit.passthrough,
          children: <Widget>[
            if (leaving != null)
              _scene(_leavingScope, leaving, _departure, arriving: false),
            _scene(scope, current, _arrival, arriving: true),
          ],
        );
      },
    );
  }
}
