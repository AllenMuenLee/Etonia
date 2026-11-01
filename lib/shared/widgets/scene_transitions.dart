import 'package:flutter/widgets.dart';

import '../../app/theme/app_tokens.dart';

/// Replaces a library detail scene. Going [direction] 1 into a folder zooms
/// into it: the scene left grows past the viewer as it fades and the folder's
/// rises from a little smaller. -1 is the same move reversed, out of a folder.
/// Between folders side by side (0) it is a cross-fade with a small vertical
/// drift. There is intentionally no horizontal slide or per-item stagger.
///
/// [pace] says whether the scene arriving was shown before: a first visit
/// plays the move slowly and smoothly while it is read; a revisit from
/// memory has no zoom or drift, only a slight cross-fade
/// ([AppMotion.glance]). One controller drives both scenes, inside the
/// frame update.
class SceneCrossfade extends StatefulWidget {
  const SceneCrossfade({
    super.key,
    required this.scope,
    required this.child,
    this.direction = 0,
    this.pace = MotionPace.standard,
  });

  final Object? scope;
  final int direction;
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

  /// The scene leaving, as it was last built, and how far it had come in
  /// when it began to leave: one cut short on its way in leaves from there.
  Widget? _leaving;
  Object? _leavingScope;
  double _leavingFrom = 1;

  /// How the switch under way is timed, fixed as it starts.
  bool _reduced = false;

  /// Only fading: motion is reduced, or the scene is a revisit.
  bool _still = false;
  bool _zoom = false;
  int _direction = 0;
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
    _direction = widget.direction;
    _still = _reduced || !AppMotion.travels(widget.pace);
    _zoom = !_still && _direction != 0;
    if (_reduced) {
      _inFor = _outFor = AppMotion.reduced;
    } else if (_still) {
      _inFor = AppMotion.glance;
      _outFor = AppMotion.fadeOut;
    } else {
      _inFor = AppMotion.paced(
        _zoom ? AppMotion.zoom : AppMotion.fadeIn,
        widget.pace,
      );
      _outFor = AppMotion.paced(
        _zoom ? AppMotion.zoom : AppMotion.fadeOut,
        widget.pace,
      );
    }
    _switch.duration = _inFor > _outFor ? _inFor : _outFor;
    _switch.forward(from: 0);
  }

  @override
  void dispose() {
    _switch.dispose();
    super.dispose();
  }

  void _settled(AnimationStatus status) {
    if (status == AnimationStatus.completed && _leaving != null && mounted) {
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
        : _zoom
        ? AppMotion.zoomInCurve
        : _still
        ? AppMotion.glanceCurve
        : AppMotion.fadeInCurve,
  );

  /// How much of the leaving scene is still there.
  double get _departure =>
      _leavingFrom *
      (1 -
          _along(
            _outFor,
            _reduced
                ? AppMotion.reducedCurve
                : _zoom
                ? AppMotion.zoomOutCurve
                : AppMotion.fadeOutCurve,
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
    double scale = 1;
    double rise = 0;
    if (_zoom) {
      // Into a folder the arrival starts small and the departure ends
      // large; out of one, the other way round.
      final bool smallAtRest = arriving == (_direction > 0);
      final double far = smallAtRest ? AppMotion.zoomFar : AppMotion.zoomNear;
      scale = far + (1 - far) * level;
    } else if (!_still && arriving) {
      // A small rise, as a fraction of the scene's height.
      rise = 0.02 * (1 - level);
    }
    return KeyedSubtree(
      key: ValueKey<Object?>(scope),
      child: IgnorePointer(
        ignoring: !arriving,
        child: Opacity(
          opacity: level,
          child: FractionalTranslation(
            translation: Offset(0, rise),
            child: Transform.scale(
              scale: scale,
              child: RepaintBoundary(child: child),
            ),
          ),
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
