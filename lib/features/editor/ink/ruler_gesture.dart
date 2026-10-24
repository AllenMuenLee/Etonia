import 'dart:math' as math;
import 'dart:ui';

import 'ruler.dart';

/// What a touch took hold of.
enum RulerGrab {
  /// The ruler's body: one finger moves it.
  body,

  /// The dial at its middle: one finger turns it about its center.
  dial,
}

/// Turns the touches on the ruler into where the ruler goes: one finger on
/// the body moves it, one on the dial turns it, and two fingers move and
/// turn it together, like a ruler on a desk.
///
/// The turn is kept as the fingers made it and pulled to a detent only as
/// shown, so passing a detent never robs the fingers of the angle between.
class RulerGestureTracker {
  RulerGestureTracker(this.config);

  final RulerConfig config;

  final Map<int, Offset> _touches = <int, Offset>{};
  RulerState? _state;
  RulerGrab _grab = RulerGrab.body;
  double _rawRotation = 0;
  double _dialStart = 0;
  double _dialRotation = 0;
  double? _detent;

  /// Whether a gesture is under way.
  bool get isActive => _touches.isNotEmpty;

  bool owns(int pointer) => _touches.containsKey(pointer);

  int get touchCount => _touches.length;

  /// Whether the last [move] pulled the ruler into a new detent: the moment
  /// for a click.
  bool didSnap = false;

  /// The ruler as the gesture has it.
  RulerState? get state => _state;

  /// Where [position] would take hold of [state]'s ruler, or null if it
  /// misses.
  RulerGrab? grabAt(RulerState state, Offset position) {
    final RulerGeometry geometry = RulerGeometry(state);
    if (geometry.containsDial(position, config.dialRadius)) {
      return RulerGrab.dial;
    }
    return geometry.containsBody(position) ? RulerGrab.body : null;
  }

  /// A first touch takes hold of [state]'s ruler at [position].
  void begin(int pointer, Offset position, RulerState state, RulerGrab grab) {
    _touches
      ..clear()
      ..[pointer] = position;
    _state = state;
    _grab = grab;
    _rawRotation = state.rotationRadians;
    _detent = null;
    didSnap = false;
    if (grab == RulerGrab.dial) {
      _dialStart = _angleAround(state.center, position);
      _dialRotation = _rawRotation;
    }
  }

  /// A second finger joins, anywhere: the two now move and turn the ruler.
  bool join(int pointer, Offset position) {
    if (_state == null || _touches.length != 1 || owns(pointer)) {
      return false;
    }
    _touches[pointer] = position;
    return true;
  }

  /// [pointer] moved to [position]. Returns the ruler's new state.
  RulerState? move(int pointer, Offset position) {
    final RulerState? state = _state;
    final Offset? before = _touches[pointer];
    if (state == null || before == null) {
      return null;
    }
    didSnap = false;
    final Offset oldCentroid = _centroid;
    final double oldSpan = _spanAngle;
    _touches[pointer] = position;

    Offset center = state.center;
    if (_touches.length >= 2) {
      center += _centroid - oldCentroid;
      _rawRotation += RulerGeometry.normalize(_spanAngle - oldSpan);
    } else if (_grab == RulerGrab.dial) {
      _rawRotation =
          _dialRotation +
          RulerGeometry.normalize(_angleAround(center, position) - _dialStart);
    } else {
      center += position - before;
    }

    final ({double radians, double? detent}) snapped = RulerGeometry.snapAngle(
      _rawRotation,
      config,
    );
    if (snapped.detent != null && snapped.detent != _detent) {
      didSnap = true;
    }
    _detent = snapped.detent;
    return _state = state.copyWith(
      center: center,
      rotationRadians: snapped.radians,
    );
  }

  /// [pointer] lifted. The touch left, if any, goes on moving the ruler.
  void end(int pointer) {
    if (_touches.remove(pointer) == null) {
      return;
    }
    if (_touches.length == 1) {
      _grab = RulerGrab.body;
    }
    if (_touches.isEmpty) {
      _state = null;
    }
  }

  void cancel() {
    _touches.clear();
    _state = null;
  }

  Offset get _centroid {
    Offset sum = Offset.zero;
    for (final Offset touch in _touches.values) {
      sum += touch;
    }
    return sum / _touches.length.toDouble();
  }

  /// The angle of the line through the first two touches.
  double get _spanAngle {
    if (_touches.length < 2) {
      return 0;
    }
    final Iterator<Offset> it = _touches.values.iterator..moveNext();
    final Offset a = it.current;
    it.moveNext();
    final Offset d = it.current - a;
    return math.atan2(d.dy, d.dx);
  }

  static double _angleAround(Offset center, Offset point) {
    final Offset d = point - center;
    return math.atan2(d.dy, d.dx);
  }
}
