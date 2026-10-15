import 'dart:math' as math;

/// Tuning for hold-to-shape: when holding the pen still converts a stroke,
/// and how closely a stroke must match a shape to be converted.
///
/// Distances are logical canvas pixels. Fit tolerances are fractions of the
/// stroke's size (the diagonal of its bounding box), so they do not depend
/// on how large the shape was drawn.
class ShapeConfig {
  const ShapeConfig({
    this.holdDuration = const Duration(milliseconds: 550),
    this.holdSlop = 6,
    this.minStrokeLength = 24,
    this.resampleCount = 64,
    this.closedGapFraction = 0.15,
    this.cornerAngle = 34 * math.pi / 180,
    this.lineTolerance = 0.045,
    this.fitTolerance = 0.028,
    this.maxPolygonSides = 12,
    this.maxPolylineSegments = 8,
    this.axisSnapAngle = 7 * math.pi / 180,
    this.circleRoundness = 0.85,
    this.rightAngleTolerance = 14 * math.pi / 180,
    this.equalSideTolerance = 0.18,
    this.regularAngleTolerance = 18 * math.pi / 180,
    this.minSpiralTurns = 1.25,
    this.minSineCrossings = 2,
    this.arrowHeadAngle = 30 * math.pi / 180,
    this.maxPoints = 200,
  }) : assert(holdSlop >= 0),
       assert(minStrokeLength >= 0),
       assert(resampleCount >= 16),
       assert(maxPolygonSides >= 3),
       assert(maxPolylineSegments >= 2),
       assert(maxPoints >= 16);

  /// How long the pointer must stay within [holdSlop] before the stroke is
  /// converted.
  final Duration holdDuration;

  /// Moving further than this from where the hold began restarts it.
  final double holdSlop;

  /// A hold converts nothing until the stroke's path is at least this long,
  /// so pausing at the start of a stroke, or a tap, never converts.
  final double minStrokeLength;

  /// The stroke is resampled to this many evenly spaced points before it is
  /// analyzed, so results do not depend on sample density or speed.
  final int resampleCount;

  /// A stroke is closed when the gap between its ends is at most this
  /// fraction of its length.
  final double closedGapFraction;

  /// A turn at least this sharp, in radians, measured over a short stretch
  /// of the resampled stroke, is a corner.
  final double cornerAngle;

  /// A line's points stray at most this fraction of its length from it.
  final double lineTolerance;

  /// Every other shape is accepted when the root-mean-square distance
  /// between the stroke and the shape, both ways, is at most this fraction
  /// of the stroke's size.
  final double fitTolerance;

  final int maxPolygonSides;
  final int maxPolylineSegments;

  /// Lines, rectangles, ellipse axes, and wave axes this close to
  /// horizontal or vertical, in radians, are made exactly so.
  final double axisSnapAngle;

  /// An ellipse whose minor radius is at least this fraction of its major
  /// radius becomes a circle.
  final double circleRoundness;

  /// A quadrilateral with every angle this close to a right angle, in
  /// radians, becomes a rectangle.
  final double rightAngleTolerance;

  /// Sides within this fraction of their mean length count as equal.
  final double equalSideTolerance;

  /// Angles within this many radians of a regular polygon's count as equal.
  final double regularAngleTolerance;

  /// A spiral winds at least this many turns around its center.
  final double minSpiralTurns;

  /// A sine wave crosses its axis at least this many times.
  final int minSineCrossings;

  /// Angle between an arrow's shaft and each barb, in radians.
  final double arrowHeadAngle;

  /// No shape has more points than this.
  final int maxPoints;
}
