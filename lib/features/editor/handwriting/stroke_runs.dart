import 'dart:math' as math;

import '../ink/ink_sample.dart';
import 'stroke_profile.dart';

/// Lines and curves in strokes: shared by calibration, which measures a
/// writer's, and the handwriting style, which draws the font's the same
/// way, so the two always mean the same thing.

/// How far the pen turns at [b], coming from [a] and going on to [c], in
/// radians: positive turns clockwise on the page, as y grows downwards.
double signedTurn(InkVector a, InkVector b, InkVector c) {
  final InkVector u = b - a;
  final InkVector v = c - b;
  if (u.length < 1e-9 || v.length < 1e-9) return 0;
  return math.atan2(u.x * v.y - u.y * v.x, u.x * v.x + u.y * v.y);
}

/// [stroke] with points added so none is more than [spacing] from the
/// next; every point it had stays where it was.
List<InkVector> densified(List<InkVector> stroke, double spacing) {
  if (stroke.length < 2) return stroke;
  final List<InkVector> out = <InkVector>[stroke.first];
  for (int i = 1; i < stroke.length; i++) {
    final InkVector from = stroke[i - 1];
    final InkVector step = stroke[i] - from;
    final int pieces = (step.length / spacing).ceil();
    for (int k = 1; k < pieces; k++) {
      out.add(from + step * (k / pieces));
    }
    out.add(stroke[i]);
  }
  return out;
}

/// [stroke] with points every [spacing] along it, its ends kept.
List<InkVector> resampled(List<InkVector> stroke, double spacing) {
  if (stroke.length < 3 || spacing <= 0) return stroke;
  final List<InkVector> out = <InkVector>[stroke.first];
  double carried = 0;
  for (int i = 1; i < stroke.length; i++) {
    InkVector from = stroke[i - 1];
    final InkVector to = stroke[i];
    double length = (to - from).length;
    while (carried + length >= spacing && length > 0) {
      final double t = (spacing - carried) / length;
      from = from + (to - from) * t;
      out.add(from);
      length = (to - from).length;
      carried = 0;
    }
    carried += length;
  }
  if ((out.last - stroke.last).length > spacing * 0.25) {
    out.add(stroke.last);
  } else {
    out[out.length - 1] = stroke.last;
  }
  return out;
}

/// Two passes of a [1, 2, 1] filter, ends fixed: the jitter of a pen gone,
/// its shape kept.
List<InkVector> smoothedPoints(List<InkVector> stroke) {
  if (stroke.length < 3) return stroke;
  List<InkVector> points = stroke;
  for (int pass = 0; pass < 2; pass++) {
    points = <InkVector>[
      points.first,
      for (int i = 1; i < points.length - 1; i++)
        (points[i - 1] + points[i] * 2 + points[i + 1]) * 0.25,
      points.last,
    ];
  }
  return points;
}

double pathLength(List<InkVector> points) {
  double sum = 0;
  for (int i = 1; i < points.length; i++) {
    sum += (points[i] - points[i - 1]).length;
  }
  return sum;
}

/// The straight lines in [points], a stroke sampled finely and about
/// evenly, as index ranges, ends included: runs between corners at least
/// [minLength] long that, smoothed, are straight give or take a hand's
/// bow. The gentle curves of round letters are not lines.
List<(int, int)> straightRuns(
  List<InkVector> points, {
  required double minLength,
}) {
  final List<(int, int)> runs = <(int, int)>[];
  int start = 0;
  for (int i = 2; i <= points.length; i++) {
    final bool corner =
        i < points.length - 2 &&
        signedTurn(points[i - 2], points[i], points[i + 2]).abs() > math.pi / 6;
    if (!corner && i < points.length) continue;
    final int from = start;
    final int to = math.min(i, points.length - 1);
    start = i;
    if (to - from < 4) continue;
    final List<InkVector> run = points.sublist(from, to + 1);
    final double length = (run.last - run.first).length;
    if (length < minLength) continue;
    if (pathLength(smoothedPoints(run)) / length > 1.025) continue;
    runs.add((from, to));
  }
  return runs;
}

/// Where [p] lies along the line from [from] to [to], from 0 to 1, read
/// along [canonicalLine] so a line drawn either way reads alike, and how
/// far it lies to that direction's right.
({double t, double offset}) alongLine(
  InkVector p,
  InkVector from,
  InkVector to,
) {
  final InkVector chord = to - from;
  final double length = chord.length;
  final InkVector direction = canonicalLine(chord * (1 / length));
  final InkVector v = p - from;
  double t = (v.x * direction.x + v.y * direction.y) / length;
  if (chord.x * direction.x + chord.y * direction.y < 0) t += 1;
  return (t: t, offset: direction.x * v.y - direction.y * v.x);
}

/// [direction] or its reverse: whichever runs down the page, for a line
/// nearer vertical, or rightwards, for one nearer horizontal. Lines are
/// measured and drawn against it, so that a line drawn up develops the
/// same way as one drawn down.
InkVector canonicalLine(InkVector direction) {
  final bool flip = direction.y.abs() > direction.x.abs()
      ? direction.y < 0
      : direction.x < 0;
  return flip ? direction * -1 : direction;
}

/// How [points], a stroke sampled finely and evenly, bends at each point:
/// the way the bend faces (its outward normal, in radians, 0 facing right
/// and π/2 down the page) and its radius, in [size]s; null where the
/// stroke runs straight or turns a corner rather than a curve.
List<({double direction, double radius})?> bends(
  List<InkVector> points,
  double size,
) {
  return <({double direction, double radius})?>[
    for (int i = 0; i < points.length; i++)
      if (i == 0 || i == points.length - 1)
        null
      else
        () {
          final InkVector before = points[i] - points[i - 1];
          final InkVector after = points[i + 1] - points[i];
          final double step = (before.length + after.length) / 2;
          final double turn = signedTurn(
            points[i - 1],
            points[i],
            points[i + 1],
          );
          if (step <= 0) return null;
          // In sizes: a curve of radius 1 is as round as a capital is
          // tall; straighter than 2/3 of one or sharper than 1/40, it is
          // a line or a corner.
          final double curvature = turn.abs() / step * size;
          if (curvature < 1.5 || curvature > 40) return null;
          final InkVector chord = points[i + 1] - points[i - 1];
          final double heading = math.atan2(chord.y, chord.x);
          // The centre of a clockwise bend lies to the right of the pen's
          // way; the bend faces away from it.
          double facing = heading + (turn > 0 ? -math.pi / 2 : math.pi / 2);
          facing = math.atan2(math.sin(facing), math.cos(facing));
          return (direction: facing, radius: 1 / curvature);
        }(),
  ];
}

/// [stroke], sampled every [spacing] or closer, drawn again bending as
/// [profile] says, where it curves: each curved step lengthened or
/// shortened by the profile's ratio for the way it faces, while every turn
/// stays as it was. So curves tighten and loosen without a single new
/// corner, lines stay straight, and the stroke still ends where it did,
/// the difference taken up along its curves.
List<InkVector> withCurves(
  List<InkVector> stroke,
  CurveProfile profile, {
  required double size,
  required double spacing,
}) {
  if (stroke.length < 4 || profile.isZero) return stroke;
  final List<InkVector> points = densified(stroke, spacing);
  // Read from the stroke smoothed, so the font's corners of a few degrees
  // read as the curves they draw; drawn from it as it is.
  final List<({double direction, double radius})?> bent = bends(
    smoothedPoints(points),
    size,
  );
  final int n = points.length - 1;
  final List<double> factors = <double>[
    for (int i = 0; i <= n; i++)
      bent[i] == null ? 1 : math.exp(profile.at(bent[i]!.direction)),
  ];
  final List<InkVector> drawn = <InkVector>[points.first];
  final List<double> curved = <double>[0];
  for (int i = 1; i <= n; i++) {
    final InkVector step = points[i] - points[i - 1];
    final bool isCurved = bent[i - 1] != null || bent[i] != null;
    final double factor = (factors[i - 1] + factors[i]) / 2;
    drawn.add(drawn.last + step * factor);
    curved.add(curved.last + (isCurved ? (step * factor).length : 0));
  }
  if (curved.last <= 0) return stroke;
  final InkVector miss = points.last - drawn.last;
  return <InkVector>[
    for (int i = 0; i <= n; i++) drawn[i] + miss * (curved[i] / curved.last),
  ];
}
