import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

/// What the ruler counts in.
enum RulerUnit {
  centimeters('cm'),
  inches('in');

  const RulerUnit(this.symbol);

  final String symbol;
}

/// Sizes, tolerances, and detents of the ruler. Lengths are page pixels.
class RulerConfig {
  const RulerConfig({
    this.length = 360,
    this.thickness = 64,
    this.snapThreshold = 22,
    this.releaseFactor = 1.5,
    this.endCapTolerance = 12,
    this.detentRadiusDegrees = 1.8,
    this.detentDegrees = const <double>[0, 30, 45, 60, 90, 120, 135, 150, 180],
    this.pixelsPerCentimeter = 37.8,
    this.pixelsPerInch = 96,
    this.dialRadius = 22,
  }) : assert(length > 0),
       assert(thickness > 0),
       assert(snapThreshold > 0),
       assert(releaseFactor >= 1),
       assert(endCapTolerance >= 0),
       assert(detentRadiusDegrees >= 0),
       assert(pixelsPerCentimeter > 0),
       assert(pixelsPerInch > 0),
       assert(dialRadius > 0);

  final double length;
  final double thickness;

  /// How near an edge a stroke begins to be drawn along it.
  final double snapThreshold;

  /// A snapped stroke lets go of the edge once it is this many thresholds
  /// away from it, fading out over the distance between.
  final double releaseFactor;

  /// How far past either end of the edge a stroke is still caught.
  final double endCapTolerance;

  /// How near a detent, in degrees, the ruler's angle is pulled to it.
  final double detentRadiusDegrees;

  /// The angles the ruler clicks into. A ruler turned half way round lies
  /// along the same line, so each also holds half a turn on.
  final List<double> detentDegrees;

  /// 96 dpi: 2.54 cm are 96 px.
  final double pixelsPerCentimeter;
  final double pixelsPerInch;

  /// The radius of the angle dial at the ruler's middle.
  final double dialRadius;

  double pixelsPerUnit(RulerUnit unit) => switch (unit) {
    RulerUnit.centimeters => pixelsPerCentimeter,
    RulerUnit.inches => pixelsPerInch,
  };
}

/// Where the ruler lies on a page and how it looks.
@immutable
class RulerState {
  const RulerState({
    required this.center,
    required this.rotationRadians,
    this.length = 360.0,
    this.thickness = 64.0,
    this.unit = RulerUnit.centimeters,
    this.isVisible = false,
    this.isLocked = false,
  });

  /// In page coordinates, so the ruler stays on its spot as the page is
  /// zoomed and panned.
  final Offset center;

  /// Normalized to [-pi, pi].
  final double rotationRadians;
  final double length;
  final double thickness;
  final RulerUnit unit;
  final bool isVisible;
  final bool isLocked;

  double get degrees => (rotationRadians * 180 / math.pi) % 360;

  RulerState copyWith({
    Offset? center,
    double? rotationRadians,
    double? length,
    double? thickness,
    RulerUnit? unit,
    bool? isVisible,
    bool? isLocked,
  }) {
    return RulerState(
      center: center ?? this.center,
      rotationRadians: RulerGeometry.normalize(
        rotationRadians ?? this.rotationRadians,
      ),
      length: length ?? this.length,
      thickness: thickness ?? this.thickness,
      unit: unit ?? this.unit,
      isVisible: isVisible ?? this.isVisible,
      isLocked: isLocked ?? this.isLocked,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is RulerState &&
        other.center == center &&
        other.rotationRadians == rotationRadians &&
        other.length == length &&
        other.thickness == thickness &&
        other.unit == unit &&
        other.isVisible == isVisible &&
        other.isLocked == isLocked;
  }

  @override
  int get hashCode => Object.hash(
    center,
    rotationRadians,
    length,
    thickness,
    unit,
    isVisible,
    isLocked,
  );
}

/// The ruler's long edges: the top one is at negative local y.
enum RulerEdge { top, bottom }

/// A projected sample: where it fell on the edge and how far from it the
/// pointer was.
@immutable
class RulerProjection {
  const RulerProjection({
    required this.point,
    required this.along,
    required this.distance,
  });

  /// The sample dropped onto the edge, in page coordinates.
  final Offset point;

  /// Distance from the edge's start (its left end) along it.
  final double along;

  /// How far the sample was from the edge, perpendicular to it.
  final double distance;
}

/// The ruler's geometry: moving between page and ruler coordinates, testing
/// where a point lies, and dropping points onto an edge.
@immutable
class RulerGeometry {
  RulerGeometry(this.state)
    : _cos = math.cos(state.rotationRadians),
      _sin = math.sin(state.rotationRadians);

  final RulerState state;
  final double _cos;
  final double _sin;

  /// Wraps [radians] into [-pi, pi].
  static double normalize(double radians) {
    const double turn = 2 * math.pi;
    double wrapped = (radians + math.pi) % turn;
    if (wrapped < 0) {
      wrapped += turn;
    }
    return wrapped - math.pi;
  }

  /// The edge's unit direction, from its start to its end.
  Offset get direction => Offset(_cos, _sin);

  /// The unit normal pointing out of the body across [edge].
  Offset outward(RulerEdge edge) {
    final double sign = edge == RulerEdge.top ? -1 : 1;
    return Offset(-_sin * sign, _cos * sign);
  }

  /// [page] in the ruler's frame: R(-theta) * (p - c). The x axis runs along
  /// the ruler, the y axis across it.
  Offset toLocal(Offset page) {
    final Offset d = page - state.center;
    return Offset(d.dx * _cos + d.dy * _sin, -d.dx * _sin + d.dy * _cos);
  }

  /// A point of the ruler's frame on the page.
  Offset toPage(Offset local) {
    return state.center +
        Offset(
          local.dx * _cos - local.dy * _sin,
          local.dx * _sin + local.dy * _cos,
        );
  }

  /// Whether [page] lies on the ruler's body.
  bool containsBody(Offset page, {double slop = 0}) {
    final Offset p = toLocal(page);
    return p.dx.abs() <= state.length / 2 + slop &&
        p.dy.abs() <= state.thickness / 2 + slop;
  }

  /// Whether [page] lies on the dial at the ruler's middle.
  bool containsDial(Offset page, double radius) {
    return (page - state.center).distance <= radius;
  }

  /// The start of [edge], at its left end, in page coordinates.
  Offset edgeStart(RulerEdge edge) =>
      toPage(_edgePoint(edge, -state.length / 2));

  Offset edgeEnd(RulerEdge edge) => toPage(_edgePoint(edge, state.length / 2));

  Offset _edgePoint(RulerEdge edge, double x) {
    final double y = state.thickness / 2 * (edge == RulerEdge.top ? -1 : 1);
    return Offset(x, y);
  }

  /// Drops [page] onto [edge]: where it falls, how far along, and how far
  /// off it was. The point is not limited to the edge's length.
  RulerProjection project(Offset page, RulerEdge edge) {
    final Offset local = toLocal(page);
    final double edgeY = state.thickness / 2 * (edge == RulerEdge.top ? -1 : 1);
    return RulerProjection(
      point: toPage(Offset(local.dx, edgeY)),
      along: local.dx + state.length / 2,
      distance: (local.dy - edgeY).abs(),
    );
  }

  /// The edge nearest [page] within [threshold] of it and no further than
  /// [endCap] past its ends, or null.
  RulerEdge? edgeNear(Offset page, double threshold, double endCap) {
    final Offset local = toLocal(page);
    if (local.dx.abs() > state.length / 2 + endCap) {
      return null;
    }
    final double toTop = (local.dy + state.thickness / 2).abs();
    final double toBottom = (local.dy - state.thickness / 2).abs();
    final RulerEdge nearer = toTop <= toBottom
        ? RulerEdge.top
        : RulerEdge.bottom;
    return math.min(toTop, toBottom) <= threshold ? nearer : null;
  }

  /// [pixels] along the ruler, in [state]'s unit.
  double measure(double pixels, RulerConfig config) {
    return pixels / config.pixelsPerUnit(state.unit);
  }

  /// [radians] pulled to the nearest detent within the config's radius, with
  /// that detent's angle, or [radians] unchanged and null.
  static ({double radians, double? detent}) snapAngle(
    double radians,
    RulerConfig config,
  ) {
    final double target = normalize(radians);
    double best = double.infinity;
    double? snapped;
    for (final double degrees in config.detentDegrees) {
      for (final double candidate in <double>[degrees, degrees + 180]) {
        final double detent = normalize(candidate * math.pi / 180);
        final double gap = normalize(target - detent).abs() * 180 / math.pi;
        if (gap < best) {
          best = gap;
          snapped = detent;
        }
      }
    }
    if (snapped != null && best <= config.detentRadiusDegrees) {
      return (radians: snapped, detent: snapped);
    }
    return (radians: target, detent: null);
  }
}

/// Everything the ruler needs to know about a stroke being drawn along it,
/// for the live distance readout.
@immutable
class RulerReadout {
  const RulerReadout({
    required this.edge,
    required this.tip,
    required this.distance,
    required this.engaged,
  });

  final RulerEdge edge;

  /// Where the pen is, on the edge, in page coordinates.
  final Offset tip;

  /// How far the stroke has run along the edge, in page pixels.
  final double distance;

  /// Whether the stroke is held on the edge right now.
  final bool engaged;
}

/// Draws one stroke along the ruler. It decides at the stroke's first
/// sample whether the stroke is guided at all: begun within the snap
/// threshold of an edge, it is dropped onto that edge until the pen moves
/// decisively away, fading free over the distance between the threshold and
/// [RulerConfig.releaseFactor] times it. A stroke begun elsewhere is never
/// touched, however near the ruler it later passes.
class RulerGuide {
  RulerGuide._(this.geometry, this.config, this.edge, this._startAlong)
    : _along = _startAlong;

  /// The guide for a stroke beginning at [start], or null when the stroke
  /// starts too far from either edge to be guided.
  static RulerGuide? begin(
    RulerGeometry geometry,
    RulerConfig config,
    Offset start,
  ) {
    final RulerEdge? edge = geometry.edgeNear(
      start,
      config.snapThreshold,
      config.endCapTolerance,
    );
    if (edge == null) {
      return null;
    }
    final double along = geometry.project(start, edge).along;
    return RulerGuide._(geometry, config, edge, along);
  }

  final RulerGeometry geometry;
  final RulerConfig config;
  final RulerEdge edge;
  final double _startAlong;
  bool _released = false;
  double _along;

  bool get isEngaged => !_released;

  /// How far along the edge the stroke has run since it began.
  double get distance => (_along - _startAlong).abs();

  /// Where on the edge the pen is.
  Offset? _tip;

  RulerReadout get readout => RulerReadout(
    edge: edge,
    tip: _tip ?? geometry.edgeStart(edge),
    distance: distance,
    engaged: !_released,
  );

  /// [page] as the stroke should have it.
  Offset apply(Offset page) {
    if (_released) {
      return page;
    }
    final RulerProjection projection = geometry.project(page, edge);
    final double threshold = config.snapThreshold;
    final double release = threshold * config.releaseFactor;
    if (projection.distance > release) {
      _released = true;
      return page;
    }
    // Past the ends, the stroke stays on the edge but runs no further.
    final double cap = config.endCapTolerance;
    final double along = projection.along.clamp(
      -cap,
      geometry.state.length + cap,
    );
    final Offset snapped = geometry.toPage(
      Offset(
        along - geometry.state.length / 2,
        geometry.state.thickness / 2 * (edge == RulerEdge.top ? -1 : 1),
      ),
    );
    _along = along;
    _tip = snapped;
    if (projection.distance <= threshold) {
      return snapped;
    }
    final double weight =
        1 - (projection.distance - threshold) / (release - threshold);
    return Offset.lerp(page, snapped, weight)!;
  }
}

/// The ruler for a whole note: whether it is showing, its unit, and where it
/// lies on each page. A page keeps its ruler as the view turns, so it
/// survives rotating the device and pages coming and going on screen.
class RulerController extends ChangeNotifier {
  RulerController({this.config = const RulerConfig()});

  final RulerConfig config;

  bool _visible = false;
  bool _locked = false;
  RulerUnit _unit = RulerUnit.centimeters;
  final Expando<_Pose> _poses = Expando<_Pose>('ruler poses');

  bool get isVisible => _visible;
  bool get isLocked => _locked;
  RulerUnit get unit => _unit;

  set isVisible(bool value) {
    if (value != _visible) {
      _visible = value;
      notifyListeners();
    }
  }

  set isLocked(bool value) {
    if (value != _locked) {
      _locked = value;
      notifyListeners();
    }
  }

  set unit(RulerUnit value) {
    if (value != _unit) {
      _unit = value;
      notifyListeners();
    }
  }

  void toggle() => isVisible = !_visible;

  /// The ruler as it lies on [page], at [fallbackCenter] and level until it
  /// has been moved there.
  RulerState stateFor(Object page, Offset fallbackCenter, {double? length}) {
    final _Pose? pose = _poses[page];
    return RulerState(
      center: pose?.center ?? fallbackCenter,
      rotationRadians: pose?.rotation ?? 0,
      length: length ?? config.length,
      thickness: config.thickness,
      unit: _unit,
      isVisible: _visible,
      isLocked: _locked,
    );
  }

  /// Whether the ruler has been placed on [page].
  bool hasPose(Object page) => _poses[page] != null;

  /// Puts the ruler down on [page] as [state] has it.
  void place(Object page, RulerState state) {
    final _Pose pose = _Pose(
      state.center,
      RulerGeometry.normalize(state.rotationRadians),
    );
    final _Pose? old = _poses[page];
    if (old != null &&
        old.center == pose.center &&
        old.rotation == pose.rotation) {
      return;
    }
    _poses[page] = pose;
    notifyListeners();
  }
}

class _Pose {
  const _Pose(this.center, this.rotation);

  final Offset center;
  final double rotation;
}
