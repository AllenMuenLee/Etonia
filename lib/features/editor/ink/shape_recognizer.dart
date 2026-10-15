// Pure Dart: no Flutter imports, like the smoother and the erase geometry.
import 'dart:math' as math;

import 'ink_sample.dart';
import 'shape_config.dart';

/// What a stroke was recognized as.
enum ShapeKind {
  line,
  arrow,
  circle,
  ellipse,
  triangle,
  rectangle,
  square,

  /// A diamond: four equal sides, not a rectangle.
  rhombus,

  /// An n-gon with equal sides and angles, other than a square.
  regularPolygon,

  /// A regular star: a closed zig-zag between two radii, or a star polygon
  /// such as a pentagram.
  star,

  /// Any other polygon, with straight edges between the drawn corners.
  polygon,

  /// An open run of a few straight segments.
  polyline,

  arc,
  sineWave,
  spiral,
}

/// A recognized shape: what it is, and the clean polyline that replaces
/// the stroke. Closed shapes end where they start.
class RecognizedShape {
  const RecognizedShape({required this.kind, required this.points, this.sides});

  final ShapeKind kind;

  /// Generated geometry, in the stroke's coordinates. Never the input
  /// points.
  final List<InkVector> points;

  /// Corners of a polygon, or points of a star.
  final int? sides;

  /// A short name for announcing the shape, such as "Circle".
  String get label {
    switch (kind) {
      case ShapeKind.line:
        return 'Line';
      case ShapeKind.arrow:
        return 'Arrow';
      case ShapeKind.circle:
        return 'Circle';
      case ShapeKind.ellipse:
        return 'Ellipse';
      case ShapeKind.triangle:
        return 'Triangle';
      case ShapeKind.rectangle:
        return 'Rectangle';
      case ShapeKind.square:
        return 'Square';
      case ShapeKind.rhombus:
        return 'Diamond';
      case ShapeKind.regularPolygon:
        return 'Regular ${_polygonName(sides ?? 0).toLowerCase()}';
      case ShapeKind.star:
        return '${sides ?? 5}-point star';
      case ShapeKind.polygon:
        return _polygonName(sides ?? 0);
      case ShapeKind.polyline:
        return 'Polyline';
      case ShapeKind.arc:
        return 'Arc';
      case ShapeKind.sineWave:
        return 'Sine wave';
      case ShapeKind.spiral:
        return 'Spiral';
    }
  }

  static String _polygonName(int sides) {
    return switch (sides) {
      3 => 'Triangle',
      4 => 'Quadrilateral',
      5 => 'Pentagon',
      6 => 'Hexagon',
      7 => 'Heptagon',
      8 => 'Octagon',
      9 => 'Nonagon',
      10 => 'Decagon',
      _ => '$sides-sided polygon',
    };
  }
}

/// Turns a hand-drawn polyline into the shape it was meant to be, or says
/// it is none.
///
/// The stroke is resampled to [ShapeConfig.resampleCount] evenly spaced
/// points. A nearly straight stroke is a line. Otherwise corners are found
/// where the stroke turns sharply over a short stretch:
///
/// - a closed stroke with three or more corners is a polygon, beautified to
///   the most specific of star, rectangle, square, rhombus, regular n-gon,
///   or plain polygon that still fits; one with fewer is an ellipse or a
///   circle;
/// - an open stroke whose long first segment ends in a short head that
///   turns back is an arrow;
/// - any other open stroke is whichever of polyline, arc, sine wave, and
///   spiral fits best.
///
/// Every candidate is measured the same way: the root-mean-square distance
/// between stroke and shape, taken both ways and divided by the stroke's
/// size. A candidate is accepted only within [ShapeConfig.fitTolerance], so
/// a scribble or a word is not recognized at all.
class ShapeRecognizer {
  const ShapeRecognizer({this.config = const ShapeConfig()});

  final ShapeConfig config;

  /// Spirals and waves are harder to draw evenly, so they get a little more
  /// room.
  static const double _curveToleranceFactor = 1.5;

  RecognizedShape? recognize(List<InkVector> input) {
    final List<InkVector> points = <InkVector>[
      for (final InkVector point in input)
        if (point.isFinite) point,
    ];
    if (points.length < 2) {
      return null;
    }
    final double length = _length(points);
    if (!(length > 0) || !length.isFinite) {
      return null;
    }
    List<InkVector> resampled = _resample(points, config.resampleCount);
    final double size = _diagonal(resampled);
    if (!(size > 0)) {
      return null;
    }
    final RecognizedShape? line = _line(resampled, length);
    if (line != null) {
      return line;
    }
    final double gap = (resampled.last - resampled.first).length;
    final bool closed = gap <= config.closedGapFraction * length;
    if (closed) {
      resampled = _resample(_trimOverlap(resampled), config.resampleCount);
      return _closed(resampled, size);
    }
    return _open(resampled, size);
  }

  // ---------------------------------------------------------------------
  // Lines.

  RecognizedShape? _line(List<InkVector> p, double length) {
    final InkVector a = p.first;
    final InkVector b = p.last;
    final double chord = (b - a).length;
    if (chord < 0.9 * length || chord <= 0) {
      return null;
    }
    final InkVector direction = (b - a) * (1 / chord);
    double worst = 0;
    for (final InkVector point in p) {
      worst = math.max(worst, ((point - a).dot(direction.perpendicular)).abs());
    }
    if (worst > config.lineTolerance * chord) {
      return null;
    }
    final InkVector snapped = _snapDirection(direction);
    final InkVector middle = (a + b) * 0.5;
    final InkVector half = snapped * (chord / 2);
    return RecognizedShape(
      kind: ShapeKind.line,
      points: <InkVector>[middle - half, middle + half],
    );
  }

  // ---------------------------------------------------------------------
  // Closed shapes.

  RecognizedShape? _closed(List<InkVector> p, double size) {
    // The ring leaves out the last point, which comes back near the first.
    final List<InkVector> ring = p.sublist(0, p.length - 1);
    final List<double> turns = _turns(ring, cyclic: true);
    final List<int> corners = _corners(turns, cyclic: true);
    if (corners.length >= 3 && corners.length <= config.maxPolygonSides * 2) {
      final List<InkVector>? vertices = _refineClosed(ring, corners, size);
      if (vertices != null) {
        final RecognizedShape? polygon = _polygon(p, vertices, size);
        if (polygon != null) {
          return polygon;
        }
      }
    }
    final RecognizedShape? ellipse = _ellipse(p, ring, size);
    if (ellipse != null) {
      return ellipse;
    }
    return _accept(p, true, size, _spiral(p), _curveToleranceFactor);
  }

  RecognizedShape? _ellipse(
    List<InkVector> p,
    List<InkVector> ring,
    double size,
  ) {
    final _Frame frame = _Frame.of(ring);
    // Fit u²/a² + v²/b² = 1 in the principal frame, by least squares.
    double s40 = 0, s22 = 0, s04 = 0, s20 = 0, s02 = 0;
    for (final InkVector point in ring) {
      final InkVector d = point - frame.center;
      final double u = d.dot(frame.major);
      final double v = d.dot(frame.minor);
      final double u2 = u * u;
      final double v2 = v * v;
      s40 += u2 * u2;
      s22 += u2 * v2;
      s04 += v2 * v2;
      s20 += u2;
      s02 += v2;
    }
    final double det = s40 * s04 - s22 * s22;
    if (det.abs() < 1e-12) {
      return null;
    }
    final double ia = (s20 * s04 - s02 * s22) / det;
    final double ib = (s40 * s02 - s22 * s20) / det;
    if (!(ia > 0) || !(ib > 0)) {
      return null;
    }
    double a = 1 / math.sqrt(ia);
    double b = 1 / math.sqrt(ib);
    if (b > a) {
      final double swap = a;
      a = b;
      b = swap;
    }
    final InkVector center = frame.center;
    final RecognizedShape shape;
    if (b >= config.circleRoundness * a) {
      double radius = 0;
      for (final InkVector point in ring) {
        radius += (point - center).length;
      }
      radius /= ring.length;
      shape = RecognizedShape(
        kind: ShapeKind.circle,
        points: _ellipsePoints(center, radius, radius, const InkVector(1, 0)),
      );
    } else {
      // The axis of the larger radius, which the fit may have swapped.
      final InkVector axis = 1 / math.sqrt(ia) >= 1 / math.sqrt(ib)
          ? frame.major
          : frame.minor;
      shape = RecognizedShape(
        kind: ShapeKind.ellipse,
        points: _ellipsePoints(center, a, b, _snapDirection(axis)),
      );
    }
    return _accept(p, true, size, shape, 1);
  }

  List<InkVector> _ellipsePoints(
    InkVector center,
    double a,
    double b,
    InkVector axis,
  ) {
    final int count = math.min(72, config.maxPoints - 1);
    final InkVector minor = axis.perpendicular;
    return <InkVector>[
      for (int i = 0; i <= count; i++)
        center +
            axis * (a * math.cos(2 * math.pi * (i % count) / count)) +
            minor * (b * math.sin(2 * math.pi * (i % count) / count)),
    ];
  }

  /// The most specific polygon that fits [vertices] and the stroke [p].
  RecognizedShape? _polygon(
    List<InkVector> p,
    List<InkVector> vertices,
    double size,
  ) {
    final int n = vertices.length;
    final List<RecognizedShape?> candidates = <RecognizedShape?>[
      if (n == 5) _starPolygon(vertices),
      if (n >= 8 && n.isEven) _starOutline(vertices),
      if (n == 4) _rectangle(vertices),
      if (n == 4) _rhombus(vertices),
      if (n != 4) _regular(vertices),
      if (n <= config.maxPolygonSides)
        RecognizedShape(
          kind: n == 3 ? ShapeKind.triangle : ShapeKind.polygon,
          points: <InkVector>[...vertices, vertices.first],
          sides: n,
        ),
    ];
    for (final RecognizedShape? candidate in candidates) {
      final RecognizedShape? accepted = _accept(p, true, size, candidate, 1);
      if (accepted != null) {
        return accepted;
      }
    }
    return null;
  }

  RecognizedShape? _rectangle(List<InkVector> v) {
    for (int i = 0; i < 4; i++) {
      final double angle = _cornerAngle(v[(i + 3) % 4], v[i], v[(i + 1) % 4]);
      if ((angle - math.pi / 2).abs() > config.rightAngleTolerance) {
        return null;
      }
    }
    // The edges' common direction, folded to a quarter turn.
    double sin4 = 0, cos4 = 0;
    for (int i = 0; i < 4; i++) {
      final InkVector edge = v[(i + 1) % 4] - v[i];
      final double angle = math.atan2(edge.y, edge.x);
      final double weight = edge.length;
      sin4 += math.sin(4 * angle) * weight;
      cos4 += math.cos(4 * angle) * weight;
    }
    final double theta = math.atan2(sin4, cos4) / 4;
    final InkVector e1 = _snapDirection(
      InkVector(math.cos(theta), math.sin(theta)),
    );
    final InkVector e2 = e1.perpendicular;
    final InkVector center = _mean(v);
    double halfU = 0, halfV = 0;
    for (final InkVector corner in v) {
      halfU += (corner - center).dot(e1).abs() / 4;
      halfV += (corner - center).dot(e2).abs() / 4;
    }
    final bool square =
        (halfU - halfV).abs() <=
        config.equalSideTolerance * math.max(halfU, halfV);
    if (square) {
      halfU = halfV = (halfU + halfV) / 2;
    }
    final List<InkVector> corners = <InkVector>[
      center - e1 * halfU - e2 * halfV,
      center + e1 * halfU - e2 * halfV,
      center + e1 * halfU + e2 * halfV,
      center - e1 * halfU + e2 * halfV,
    ];
    return RecognizedShape(
      kind: square ? ShapeKind.square : ShapeKind.rectangle,
      points: <InkVector>[...corners, corners.first],
      sides: 4,
    );
  }

  RecognizedShape? _rhombus(List<InkVector> v) {
    if (!_equalSides(v)) {
      return null;
    }
    final InkVector d1 = v[2] - v[0];
    final InkVector d2 = v[3] - v[1];
    if (d1.length <= 0 || d2.length <= 0) {
      return null;
    }
    final InkVector axis = _snapDirection(d1 * (1 / d1.length));
    final InkVector across = axis.perpendicular;
    final InkVector center = _mean(v);
    final double p = d1.length / 2;
    final double q = d2.length / 2;
    final List<InkVector> corners = <InkVector>[
      center - axis * p,
      center - across * q,
      center + axis * p,
      center + across * q,
    ];
    return RecognizedShape(
      kind: ShapeKind.rhombus,
      points: <InkVector>[...corners, corners.first],
      sides: 4,
    );
  }

  RecognizedShape? _regular(List<InkVector> v) {
    final int n = v.length;
    if (!_equalSides(v)) {
      return null;
    }
    final double interior = (n - 2) * math.pi / n;
    for (int i = 0; i < n; i++) {
      final double angle = _cornerAngle(
        v[(i + n - 1) % n],
        v[i],
        v[(i + 1) % n],
      );
      if ((angle - interior).abs() > config.regularAngleTolerance) {
        return null;
      }
    }
    final InkVector center = _mean(v);
    final double radius = _meanDistance(v, center);
    final double phase = _snapPhase(_phase(v, center, n), n);
    final double turn = _orientation(v) >= 0 ? 1 : -1;
    final List<InkVector> corners = <InkVector>[
      for (int i = 0; i < n; i++)
        _polar(center, radius, phase + turn * 2 * math.pi * i / n),
    ];
    return RecognizedShape(
      kind: n == 3 ? ShapeKind.triangle : ShapeKind.regularPolygon,
      points: <InkVector>[...corners, corners.first],
      sides: n,
    );
  }

  /// A pentagram: five tips visited every other one.
  RecognizedShape? _starPolygon(List<InkVector> v) {
    final InkVector center = _mean(v);
    const double step = 4 * math.pi / 5;
    double sign = 0;
    for (int i = 0; i < 5; i++) {
      final double delta = _angleBetween(
        v[i] - center,
        v[(i + 1) % 5] - center,
      );
      if ((delta.abs() - step).abs() > config.regularAngleTolerance * 1.5) {
        return null;
      }
      if (sign != 0 && delta.sign != sign) {
        return null;
      }
      sign = delta.sign;
    }
    if (!_equalSides(v)) {
      return null;
    }
    final double radius = _meanDistance(v, center);
    final double phase = _snapPhase(_phase(v, center, 5), 5);
    final List<InkVector> tips = <InkVector>[
      for (int i = 0; i < 5; i++)
        _polar(center, radius, phase + sign * step * i),
    ];
    return RecognizedShape(
      kind: ShapeKind.star,
      points: <InkVector>[...tips, tips.first],
      sides: 5,
    );
  }

  /// A star outline: corners alternating between an outer and an inner
  /// radius.
  RecognizedShape? _starOutline(List<InkVector> v) {
    final int n = v.length;
    final int k = n ~/ 2;
    final InkVector center = _mean(v);
    final List<double> even = <double>[
      for (int i = 0; i < n; i += 2) (v[i] - center).length,
    ];
    final List<double> odd = <double>[
      for (int i = 1; i < n; i += 2) (v[i] - center).length,
    ];
    final double meanEven = even.reduce((double a, double b) => a + b) / k;
    final double meanOdd = odd.reduce((double a, double b) => a + b) / k;
    final bool evenOuter = meanEven >= meanOdd;
    final double outer = evenOuter ? meanEven : meanOdd;
    final double inner = evenOuter ? meanOdd : meanEven;
    if (!(outer > 0) || inner > 0.8 * outer) {
      return null;
    }
    const double spread = 0.3;
    for (final double r in even) {
      if ((r - meanEven).abs() > spread * meanEven) {
        return null;
      }
    }
    for (final double r in odd) {
      if ((r - meanOdd).abs() > spread * meanOdd) {
        return null;
      }
    }
    final List<InkVector> tips = <InkVector>[
      for (int i = evenOuter ? 0 : 1; i < n; i += 2) v[i],
    ];
    final double phase = _snapPhase(_phase(tips, center, k), k);
    final double turn = _orientation(v) >= 0 ? 1 : -1;
    final List<InkVector> corners = <InkVector>[
      for (int i = 0; i < n; i++)
        _polar(
          center,
          i.isEven ? outer : inner,
          phase + turn * math.pi * i / k,
        ),
    ];
    return RecognizedShape(
      kind: ShapeKind.star,
      points: <InkVector>[...corners, corners.first],
      sides: k,
    );
  }

  bool _equalSides(List<InkVector> v) {
    final int n = v.length;
    double mean = 0;
    for (int i = 0; i < n; i++) {
      mean += (v[(i + 1) % n] - v[i]).length / n;
    }
    for (int i = 0; i < n; i++) {
      final double side = (v[(i + 1) % n] - v[i]).length;
      if ((side - mean).abs() > config.equalSideTolerance * mean) {
        return false;
      }
    }
    return mean > 0;
  }

  /// Phase of an [n]-fold pattern of [points] around [center]: the angle of
  /// one of its points.
  static double _phase(List<InkVector> points, InkVector center, int n) {
    double s = 0, c = 0;
    for (final InkVector point in points) {
      final InkVector d = point - center;
      final double angle = math.atan2(d.y, d.x);
      s += math.sin(n * angle);
      c += math.cos(n * angle);
    }
    return math.atan2(s, c) / n;
  }

  /// Turns a nearly upright [n]-fold pattern exactly upright: a point
  /// straight up, or a flat edge at the bottom.
  double _snapPhase(double phase, int n) {
    final double period = 2 * math.pi / n;
    for (final double target in <double>[
      -math.pi / 2,
      -math.pi / 2 + period / 2,
    ]) {
      double delta = (phase - target) % period;
      if (delta > period / 2) {
        delta -= period;
      }
      if (delta.abs() <= config.axisSnapAngle) {
        return phase - delta;
      }
    }
    return phase;
  }

  // ---------------------------------------------------------------------
  // Open shapes.

  RecognizedShape? _open(List<InkVector> p, double size) {
    final List<double> turns = _turns(p, cyclic: false);
    final List<int> corners = _corners(turns, cyclic: false);
    List<InkVector>? vertices;
    if (corners.isNotEmpty && corners.length < config.maxPolylineSegments * 2) {
      vertices = _refineOpen(p, corners, size);
    }
    if (vertices != null) {
      final RecognizedShape? arrow = _arrow(p, corners, vertices);
      if (arrow != null) {
        return arrow;
      }
    }
    final List<_Fit> fits = <_Fit>[
      if (vertices != null && vertices.length - 1 <= config.maxPolylineSegments)
        ?_fit(
          p,
          size,
          RecognizedShape(
            kind: ShapeKind.polyline,
            points: vertices,
            sides: vertices.length - 1,
          ),
          1,
        ),
      ?_fit(p, size, _arc(p, size), 1),
      ?_fit(p, size, _sine(p), _curveToleranceFactor),
      ?_fit(p, size, _spiral(p), _curveToleranceFactor),
    ];
    if (fits.isEmpty) {
      return null;
    }
    fits.sort((_Fit a, _Fit b) => a.score.compareTo(b.score));
    return fits.first.shape;
  }

  RecognizedShape? _arrow(
    List<InkVector> p,
    List<int> corners,
    List<InkVector> v,
  ) {
    if (v.length < 3) {
      return null;
    }
    final InkVector start = v[0];
    final InkVector tip = v[1];
    final double shaft = (tip - start).length;
    if (shaft < 0.45 * _length(p) || shaft <= 0) {
      return null;
    }
    final InkVector direction = (tip - start) * (1 / shaft);
    double head = 0;
    bool turnsBack = false;
    for (int i = 2; i < v.length; i++) {
      final InkVector offset = v[i] - tip;
      final double distance = offset.length;
      if (distance > 0.5 * shaft) {
        return null;
      }
      head = math.max(head, distance);
      if (offset.dot(direction) < -0.2 * distance) {
        turnsBack = true;
      }
    }
    if (!turnsBack) {
      return null;
    }
    // The shaft itself must be straight.
    for (int i = 0; i <= corners.first; i++) {
      final double off = (p[i] - start).dot(direction.perpendicular).abs();
      if (off > 0.06 * shaft) {
        return null;
      }
    }
    final InkVector axis = _snapDirection(direction);
    final InkVector end = start + axis * shaft;
    final double barb = head.clamp(0.12 * shaft, 0.4 * shaft);
    final InkVector back = -axis;
    return RecognizedShape(
      kind: ShapeKind.arrow,
      points: <InkVector>[
        start,
        end,
        end + _rotate(back, config.arrowHeadAngle) * barb,
        end,
        end + _rotate(back, -config.arrowHeadAngle) * barb,
      ],
    );
  }

  /// A circular arc, by an algebraic least-squares circle fit.
  RecognizedShape? _arc(List<InkVector> p, double size) {
    final _Circle? circle = _fitCircle(p);
    if (circle == null || circle.radius > 5 * size) {
      return null;
    }
    final List<double> angles = _unwrappedAngles(p, circle.center, 0);
    if (angles.isEmpty) {
      return null;
    }
    final double start = angles.first;
    final double span = angles.last - start;
    if (span.abs() < 25 * math.pi / 180 || span.abs() > 340 * math.pi / 180) {
      return null;
    }
    final int count = (span.abs() / (5 * math.pi / 180)).ceil().clamp(
      12,
      math.min(72, config.maxPoints - 1),
    );
    return RecognizedShape(
      kind: ShapeKind.arc,
      points: <InkVector>[
        for (int i = 0; i <= count; i++)
          _polar(circle.center, circle.radius, start + span * i / count),
      ],
    );
  }

  /// A sine wave along the stroke's principal axis.
  RecognizedShape? _sine(List<InkVector> p) {
    final _Frame frame = _Frame.of(p);
    InkVector axis = _snapDirection(frame.major);
    if ((p.last - p.first).dot(axis) < 0) {
      axis = -axis;
    }
    final InkVector across = axis.perpendicular;
    final List<double> u = <double>[];
    final List<double> w = <double>[];
    for (final InkVector point in p) {
      final InkVector d = point - frame.center;
      u.add(d.dot(axis));
      w.add(d.dot(across));
    }
    final double uMin = u.reduce(math.min);
    final double uMax = u.reduce(math.max);
    final double range = uMax - uMin;
    if (!(range > 0)) {
      return null;
    }
    double backwards = 0;
    for (int i = 1; i < u.length; i++) {
      backwards += math.max(0, u[i - 1] - u[i]);
    }
    if (backwards > 0.1 * range) {
      return null;
    }
    final double mean = w.reduce((double a, double b) => a + b) / w.length;
    double peak = 0;
    for (int i = 0; i < w.length; i++) {
      w[i] -= mean;
      peak = math.max(peak, w[i].abs());
    }
    if (peak < 0.06 * range) {
      return null;
    }
    // Axis crossings, with hysteresis so wobble near the axis is not one.
    final double hysteresis = 0.3 * peak;
    final List<double> crossings = <double>[];
    int state = 0;
    int lastSignChange = 0;
    for (int i = 0; i < w.length; i++) {
      if (i > 0 && (w[i] >= 0) != (w[i - 1] >= 0)) {
        lastSignChange = i;
      }
      final int now = w[i] > hysteresis
          ? 1
          : w[i] < -hysteresis
          ? -1
          : 0;
      if (now != 0 && now != state) {
        if (state != 0) {
          crossings.add(u[lastSignChange]);
        }
        state = now;
      }
    }
    if (crossings.length < config.minSineCrossings) {
      return null;
    }
    final double spacing =
        (crossings.last - crossings.first) / (crossings.length - 1);
    if (!(spacing > 0)) {
      return null;
    }
    final double k0 = math.pi / spacing;
    _SineFit? best;
    for (int step = 0; step <= 24; step++) {
      final double k = k0 * (0.75 + 0.5 * step / 24);
      final _SineFit? fit = _SineFit.of(u, w, k);
      if (fit != null && (best == null || fit.residual < best.residual)) {
        best = fit;
      }
    }
    if (best == null) {
      return null;
    }
    final double halfWaves = range * best.k / math.pi;
    final int count = (halfWaves * 12).ceil().clamp(24, config.maxPoints - 1);
    final InkVector origin = frame.center + across * mean;
    return RecognizedShape(
      kind: ShapeKind.sineWave,
      points: <InkVector>[
        for (int i = 0; i <= count; i++)
          origin +
              axis * (uMin + range * i / count) +
              across * best.at(uMin + range * i / count),
      ],
    );
  }

  /// An Archimedean spiral, r = a + b·θ, around a fitted center.
  RecognizedShape? _spiral(List<InkVector> p) {
    final InkVector centroid = _mean(p);
    final InkVector inner =
        (p.first - centroid).length <= (p.last - centroid).length
        ? p.first
        : p.last;
    _SpiralFit? best;
    for (final InkVector center in <InkVector>[
      inner,
      centroid,
      (inner + centroid) * 0.5,
    ]) {
      final _SpiralFit? fit = _SpiralFit.of(p, center);
      if (fit != null && (best == null || fit.score < best.score)) {
        best = fit;
      }
    }
    if (best == null) {
      return null;
    }
    // Walk the center downhill on a shrinking grid.
    double step = 0.1 * best.maxRadius;
    for (int round = 0; round < 4; round++) {
      final _SpiralFit around = best!;
      for (int i = -2; i <= 2; i++) {
        for (int j = -2; j <= 2; j++) {
          if (i == 0 && j == 0) {
            continue;
          }
          final _SpiralFit? fit = _SpiralFit.of(
            p,
            around.center + InkVector(i * step, j * step),
          );
          if (fit != null && fit.score < best!.score) {
            best = fit;
          }
        }
      }
      step /= 2;
    }
    final _SpiralFit fit = best!;
    final double turns = fit.span.abs() / (2 * math.pi);
    if (turns < config.minSpiralTurns ||
        (fit.b * fit.span).abs() < 0.4 * fit.maxRadius) {
      return null;
    }
    final int count = (turns * 48).ceil().clamp(48, config.maxPoints - 1);
    return RecognizedShape(
      kind: ShapeKind.spiral,
      points: <InkVector>[
        for (int i = 0; i <= count; i++)
          _polar(
            fit.center,
            math.max(0, fit.a + fit.b * (fit.start + fit.span * i / count)),
            fit.start + fit.span * i / count,
          ),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Acceptance.

  RecognizedShape? _accept(
    List<InkVector> stroke,
    bool closed,
    double size,
    RecognizedShape? shape,
    double toleranceFactor,
  ) {
    final _Fit? fit = _fit(stroke, size, shape, toleranceFactor, closed);
    return fit?.shape;
  }

  _Fit? _fit(
    List<InkVector> stroke,
    double size,
    RecognizedShape? shape,
    double toleranceFactor, [
    bool closed = false,
  ]) {
    if (shape == null ||
        shape.points.length < 2 ||
        shape.points.length > config.maxPoints) {
      return null;
    }
    for (final InkVector point in shape.points) {
      if (!point.isFinite) {
        return null;
      }
    }
    final double error = _symmetricError(stroke, closed, shape.points) / size;
    if (!error.isFinite || error > config.fitTolerance * toleranceFactor) {
      return null;
    }
    return _Fit(shape, error / toleranceFactor);
  }

  /// Root-mean-square distance from the stroke to the shape, and from the
  /// shape, evenly resampled, to the stroke; whichever is larger.
  double _symmetricError(
    List<InkVector> stroke,
    bool closed,
    List<InkVector> shape,
  ) {
    final List<InkVector> strokeLine = closed
        ? <InkVector>[...stroke, stroke.first]
        : stroke;
    double there = 0;
    for (final InkVector point in stroke) {
      final double d = _distanceToPolyline(point, shape);
      there += d * d;
    }
    there = math.sqrt(there / stroke.length);
    final List<InkVector> samples = _length(shape) > 0
        ? _resample(shape, config.resampleCount)
        : shape;
    double back = 0;
    for (final InkVector point in samples) {
      final double d = _distanceToPolyline(point, strokeLine);
      back += d * d;
    }
    back = math.sqrt(back / samples.length);
    return math.max(there, back);
  }

  // ---------------------------------------------------------------------
  // Corners.

  /// The turn at each point, in radians, between the chords to the points
  /// two steps behind and two steps ahead. Zero where the chords are not
  /// defined.
  static List<double> _turns(List<InkVector> p, {required bool cyclic}) {
    const int k = 2;
    final int n = p.length;
    return <double>[
      for (int i = 0; i < n; i++)
        if (!cyclic && (i < k || i >= n - k))
          0
        else
          _turn(p[(i - k + n) % n], p[i], p[(i + k) % n]),
    ];
  }

  static double _turn(InkVector a, InkVector b, InkVector c) {
    final InkVector before = b - a;
    final InkVector after = c - b;
    final double lengths = before.length * after.length;
    if (!(lengths > 0)) {
      return 0;
    }
    return math.acos((before.dot(after) / lengths).clamp(-1.0, 1.0));
  }

  /// Indices whose turn reaches [ShapeConfig.cornerAngle] and is the
  /// sharpest within three steps either side.
  List<int> _corners(List<double> turns, {required bool cyclic}) {
    const int suppress = 3;
    final int n = turns.length;
    final List<int> corners = <int>[];
    for (int i = 0; i < n; i++) {
      final double turn = turns[i];
      if (turn < config.cornerAngle) {
        continue;
      }
      bool sharpest = true;
      for (int j = 1; j <= suppress && sharpest; j++) {
        for (final int other in <int>[i - j, i + j]) {
          if (!cyclic && (other < 0 || other >= n)) {
            continue;
          }
          final double neighbor = turns[(other + n) % n];
          // Ties go to the earlier index.
          if (neighbor > turn || (neighbor == turn && other < i)) {
            sharpest = false;
          }
        }
      }
      if (sharpest) {
        corners.add(i);
      }
    }
    return corners;
  }

  /// Polygon vertices: where the lines fitted to consecutive edges meet.
  List<InkVector>? _refineClosed(
    List<InkVector> ring,
    List<int> corners,
    double size,
  ) {
    final int n = ring.length;
    final int count = corners.length;
    final List<_Line> edges = <_Line>[
      for (int i = 0; i < count; i++)
        _Line.fit(
          ring,
          corners[i],
          corners[(i + 1) % count] + (i + 1 == count ? n : 0),
          n,
        ),
    ];
    final List<InkVector> vertices = <InkVector>[];
    for (int i = 0; i < count; i++) {
      final InkVector fallback = ring[corners[i]];
      final InkVector? meet = edges[(i + count - 1) % count].intersect(
        edges[i],
      );
      vertices.add(
        meet != null && (meet - fallback).length <= 0.15 * size
            ? meet
            : fallback,
      );
    }
    return _dropCollinear(vertices, closed: true);
  }

  /// Polyline vertices: the stroke's ends projected onto the first and last
  /// fitted segments, and where consecutive segments meet.
  List<InkVector>? _refineOpen(
    List<InkVector> p,
    List<int> corners,
    double size,
  ) {
    final List<int> breaks = <int>[0, ...corners, p.length - 1];
    final List<_Line> segments = <_Line>[
      for (int i = 0; i + 1 < breaks.length; i++)
        _Line.fit(p, breaks[i], breaks[i + 1], p.length),
    ];
    final List<InkVector> vertices = <InkVector>[
      segments.first.project(p.first),
    ];
    for (int i = 1; i < segments.length; i++) {
      final InkVector fallback = p[breaks[i]];
      final InkVector? meet = segments[i - 1].intersect(segments[i]);
      vertices.add(
        meet != null && (meet - fallback).length <= 0.15 * size
            ? meet
            : fallback,
      );
    }
    vertices.add(segments.last.project(p.last));
    return _dropCollinear(vertices, closed: false);
  }

  /// Removes vertices where the outline hardly turns, or that sit on top of
  /// their neighbor.
  List<InkVector>? _dropCollinear(
    List<InkVector> vertices, {
    required bool closed,
  }) {
    final List<InkVector> kept = List<InkVector>.of(vertices);
    bool changed = true;
    while (changed && kept.length > (closed ? 3 : 2)) {
      changed = false;
      final int n = kept.length;
      for (int i = closed ? 0 : 1; i < (closed ? n : n - 1); i++) {
        final InkVector before = kept[(i + n - 1) % n];
        final InkVector after = kept[(i + 1) % n];
        final bool tooClose = (kept[i] - before).length < 1e-6;
        if (tooClose ||
            _turn(before, kept[i], after) < config.cornerAngle * 0.5) {
          kept.removeAt(i);
          changed = true;
          break;
        }
      }
    }
    return kept.length >= (closed ? 3 : 2) ? kept : null;
  }

  // ---------------------------------------------------------------------
  // Geometry helpers.

  InkVector _snapDirection(InkVector direction) {
    final double angle = math.atan2(direction.y, direction.x);
    const double quarter = math.pi / 2;
    final double nearest = (angle / quarter).roundToDouble() * quarter;
    if ((angle - nearest).abs() <= config.axisSnapAngle) {
      return InkVector(
        math.cos(nearest).roundToDouble(),
        math.sin(nearest).roundToDouble(),
      );
    }
    return direction * (1 / direction.length);
  }

  /// Cuts a closed stroke where it runs back past its start.
  static List<InkVector> _trimOverlap(List<InkVector> p) {
    final int n = p.length;
    double best = (p.last - p.first).length;
    int cut = n - 1;
    for (int j = (n * 2) ~/ 3; j < n - 1; j++) {
      final double d = (p[j] - p.first).length;
      if (d < best) {
        best = d;
        cut = j;
      }
    }
    return cut >= 3 ? p.sublist(0, cut + 1) : p;
  }

  static List<InkVector> _resample(List<InkVector> points, int count) {
    final double length = _length(points);
    if (!(length > 0)) {
      return List<InkVector>.filled(count, points.first);
    }
    final double step = length / (count - 1);
    final List<InkVector> out = <InkVector>[points.first];
    double carried = 0;
    InkVector previous = points.first;
    int i = 1;
    while (i < points.length && out.length < count - 1) {
      final InkVector next = points[i];
      final double segment = (next - previous).length;
      if (segment > 0 && carried + segment >= step) {
        final InkVector point =
            previous + (next - previous) * ((step - carried) / segment);
        out.add(point);
        previous = point;
        carried = 0;
      } else {
        carried += segment;
        previous = next;
        i++;
      }
    }
    while (out.length < count) {
      out.add(points.last);
    }
    out[count - 1] = points.last;
    return out;
  }

  static double _length(List<InkVector> p) {
    double length = 0;
    for (int i = 1; i < p.length; i++) {
      length += (p[i] - p[i - 1]).length;
    }
    return length;
  }

  static double _diagonal(List<InkVector> p) {
    double minX = p.first.x, maxX = p.first.x;
    double minY = p.first.y, maxY = p.first.y;
    for (final InkVector point in p) {
      minX = math.min(minX, point.x);
      maxX = math.max(maxX, point.x);
      minY = math.min(minY, point.y);
      maxY = math.max(maxY, point.y);
    }
    return InkVector(maxX - minX, maxY - minY).length;
  }

  static InkVector _mean(List<InkVector> p) {
    double x = 0, y = 0;
    for (final InkVector point in p) {
      x += point.x;
      y += point.y;
    }
    return InkVector(x / p.length, y / p.length);
  }

  static double _meanDistance(List<InkVector> p, InkVector center) {
    double total = 0;
    for (final InkVector point in p) {
      total += (point - center).length;
    }
    return total / p.length;
  }

  /// Twice the signed area: positive when the points turn the way the
  /// y-down screen calls clockwise.
  static double _orientation(List<InkVector> p) {
    double area = 0;
    for (int i = 0; i < p.length; i++) {
      final InkVector a = p[i];
      final InkVector b = p[(i + 1) % p.length];
      area += a.x * b.y - b.x * a.y;
    }
    return area;
  }

  /// The angle at [b] between the edges to [a] and to [c].
  static double _cornerAngle(InkVector a, InkVector b, InkVector c) {
    return math.pi - _turn(a, b, c);
  }

  /// Signed angle from [a] to [b], in (-π, π].
  static double _angleBetween(InkVector a, InkVector b) {
    return math.atan2(a.x * b.y - a.y * b.x, a.dot(b));
  }

  static InkVector _rotate(InkVector v, double angle) {
    final double c = math.cos(angle);
    final double s = math.sin(angle);
    return InkVector(v.x * c - v.y * s, v.x * s + v.y * c);
  }

  static InkVector _polar(InkVector center, double radius, double angle) {
    return center + InkVector(math.cos(angle), math.sin(angle)) * radius;
  }

  /// Angles of [p] around [center], unwrapped into one continuous run.
  /// Points closer than [minRadius] are skipped; they say little about the
  /// direction.
  static List<double> _unwrappedAngles(
    List<InkVector> p,
    InkVector center,
    double minRadius,
  ) {
    final List<double> angles = <double>[];
    InkVector? previous;
    for (final InkVector point in p) {
      final InkVector d = point - center;
      if (d.length <= minRadius || d.length == 0) {
        continue;
      }
      if (previous == null) {
        angles.add(math.atan2(d.y, d.x));
      } else {
        angles.add(angles.last + _angleBetween(previous, d));
      }
      previous = d;
    }
    return angles;
  }

  static double _distanceToPolyline(InkVector point, List<InkVector> line) {
    if (line.length == 1) {
      return (point - line.first).length;
    }
    double best = double.infinity;
    for (int i = 1; i < line.length; i++) {
      best = math.min(best, _distanceToSegment(point, line[i - 1], line[i]));
    }
    return best;
  }

  static double _distanceToSegment(InkVector p, InkVector a, InkVector b) {
    final InkVector ab = b - a;
    final double lengthSquared = ab.dot(ab);
    if (lengthSquared == 0) {
      return (p - a).length;
    }
    final double t = ((p - a).dot(ab) / lengthSquared).clamp(0.0, 1.0);
    return (p - (a + ab * t)).length;
  }

  static _Circle? _fitCircle(List<InkVector> p) {
    final InkVector g = _mean(p);
    double sxx = 0, sxy = 0, syy = 0, sx = 0, sy = 0;
    double sxz = 0, syz = 0, sz = 0;
    for (final InkVector point in p) {
      final double x = point.x - g.x;
      final double y = point.y - g.y;
      final double z = x * x + y * y;
      sxx += x * x;
      sxy += x * y;
      syy += y * y;
      sx += x;
      sy += y;
      sxz += x * z;
      syz += y * z;
      sz += z;
    }
    final List<double>? solution = _solve3(
      <List<double>>[
        <double>[sxx, sxy, sx],
        <double>[sxy, syy, sy],
        <double>[sx, sy, p.length.toDouble()],
      ],
      <double>[-sxz, -syz, -sz],
    );
    if (solution == null) {
      return null;
    }
    final double cx = -solution[0] / 2;
    final double cy = -solution[1] / 2;
    final double r2 = cx * cx + cy * cy - solution[2];
    if (!(r2 > 0) || !r2.isFinite) {
      return null;
    }
    return _Circle(g + InkVector(cx, cy), math.sqrt(r2));
  }
}

/// Gaussian elimination with partial pivoting. Null when singular.
List<double>? _solve3(List<List<double>> m, List<double> rhs) {
  final List<List<double>> a = <List<double>>[
    for (int i = 0; i < 3; i++) <double>[...m[i], rhs[i]],
  ];
  for (int col = 0; col < 3; col++) {
    int pivot = col;
    for (int row = col + 1; row < 3; row++) {
      if (a[row][col].abs() > a[pivot][col].abs()) {
        pivot = row;
      }
    }
    if (a[pivot][col].abs() < 1e-12) {
      return null;
    }
    final List<double> swap = a[col];
    a[col] = a[pivot];
    a[pivot] = swap;
    for (int row = 0; row < 3; row++) {
      if (row == col) {
        continue;
      }
      final double factor = a[row][col] / a[col][col];
      for (int k = col; k < 4; k++) {
        a[row][k] -= factor * a[col][k];
      }
    }
  }
  final List<double> x = <double>[
    for (int i = 0; i < 3; i++) a[i][3] / a[i][i],
  ];
  return x.every((double v) => v.isFinite) ? x : null;
}

class _Fit {
  const _Fit(this.shape, this.score);

  final RecognizedShape shape;

  /// Fit error relative to the shape's tolerance; lower is better.
  final double score;
}

class _Circle {
  const _Circle(this.center, this.radius);

  final InkVector center;
  final double radius;
}

/// The centroid of a point set and its principal axes.
class _Frame {
  const _Frame(this.center, this.major);

  factory _Frame.of(List<InkVector> p) {
    final InkVector center = ShapeRecognizer._mean(p);
    double sxx = 0, syy = 0, sxy = 0;
    for (final InkVector point in p) {
      final InkVector d = point - center;
      sxx += d.x * d.x;
      syy += d.y * d.y;
      sxy += d.x * d.y;
    }
    final double angle = 0.5 * math.atan2(2 * sxy, sxx - syy);
    return _Frame(center, InkVector(math.cos(angle), math.sin(angle)));
  }

  final InkVector center;

  /// Unit direction of greatest spread.
  final InkVector major;

  InkVector get minor => major.perpendicular;
}

/// A line through a point, fitted to a run of points.
class _Line {
  const _Line(this.origin, this.direction);

  /// Fits the points from [from] to [to] (indices taken modulo [n]),
  /// leaving out the rounded ends next to the corners when there are
  /// enough points.
  factory _Line.fit(List<InkVector> p, int from, int to, int n) {
    final int span = to - from;
    final int trim = span > 6 ? 2 : (span > 3 ? 1 : 0);
    final List<InkVector> run = <InkVector>[
      for (int i = from + trim; i <= to - trim; i++) p[i % n],
    ];
    if (run.length < 2) {
      final InkVector a = p[from % n];
      final InkVector b = p[to % n];
      final InkVector d = b - a;
      return _Line(
        a,
        d.length > 0 ? d * (1 / d.length) : const InkVector(1, 0),
      );
    }
    final _Frame frame = _Frame.of(run);
    return _Line(frame.center, frame.major);
  }

  final InkVector origin;
  final InkVector direction;

  InkVector project(InkVector point) {
    return origin + direction * (point - origin).dot(direction);
  }

  /// Where the two lines meet; null when they are close to parallel.
  InkVector? intersect(_Line other) {
    final double cross =
        direction.x * other.direction.y - direction.y * other.direction.x;
    if (cross.abs() < math.sin(8 * math.pi / 180)) {
      return null;
    }
    final InkVector between = other.origin - origin;
    final double t =
        (between.x * other.direction.y - between.y * other.direction.x) / cross;
    final InkVector point = origin + direction * t;
    return point.isFinite ? point : null;
  }
}

/// v ≈ α·sin(k·u) + β·cos(k·u) + γ, by least squares for a fixed k.
class _SineFit {
  const _SineFit(this.k, this.alpha, this.beta, this.gamma, this.residual);

  static _SineFit? of(List<double> u, List<double> v, double k) {
    final List<List<double>> m = <List<double>>[
      <double>[0, 0, 0],
      <double>[0, 0, 0],
      <double>[0, 0, 0],
    ];
    final List<double> rhs = <double>[0, 0, 0];
    for (int i = 0; i < u.length; i++) {
      final List<double> f = <double>[
        math.sin(k * u[i]),
        math.cos(k * u[i]),
        1,
      ];
      for (int r = 0; r < 3; r++) {
        for (int c = 0; c < 3; c++) {
          m[r][c] += f[r] * f[c];
        }
        rhs[r] += f[r] * v[i];
      }
    }
    final List<double>? x = _solve3(m, rhs);
    if (x == null) {
      return null;
    }
    double residual = 0;
    for (int i = 0; i < u.length; i++) {
      final double e =
          x[0] * math.sin(k * u[i]) + x[1] * math.cos(k * u[i]) + x[2] - v[i];
      residual += e * e;
    }
    return _SineFit(k, x[0], x[1], x[2], residual);
  }

  final double k;
  final double alpha;
  final double beta;
  final double gamma;
  final double residual;

  double at(double u) {
    return alpha * math.sin(k * u) + beta * math.cos(k * u) + gamma;
  }
}

/// r = a + b·θ around [center], by least squares over the unwrapped angle.
class _SpiralFit {
  const _SpiralFit({
    required this.center,
    required this.a,
    required this.b,
    required this.start,
    required this.span,
    required this.maxRadius,
    required this.score,
  });

  static _SpiralFit? of(List<InkVector> p, InkVector center) {
    double maxRadius = 0;
    for (final InkVector point in p) {
      maxRadius = math.max(maxRadius, (point - center).length);
    }
    if (!(maxRadius > 0)) {
      return null;
    }
    final double minRadius = 0.03 * maxRadius;
    final List<double> angles = <double>[];
    final List<double> radii = <double>[];
    InkVector? previous;
    double reverse = 0;
    double travel = 0;
    for (final InkVector point in p) {
      final InkVector d = point - center;
      if (d.length <= minRadius) {
        continue;
      }
      if (previous == null) {
        angles.add(math.atan2(d.y, d.x));
      } else {
        final double delta = ShapeRecognizer._angleBetween(previous, d);
        angles.add(angles.last + delta);
        travel += delta;
        reverse += delta.abs();
      }
      radii.add(d.length);
      previous = d;
    }
    if (angles.length < 8 || travel == 0) {
      return null;
    }
    // reverse now holds the total turning; what did not go the main way
    // went backwards.
    final double backwards = (reverse - travel.abs()) / 2;
    if (backwards > 0.1 * travel.abs()) {
      return null;
    }
    double st = 0, sr = 0, stt = 0, str = 0;
    final int n = angles.length;
    for (int i = 0; i < n; i++) {
      st += angles[i];
      sr += radii[i];
      stt += angles[i] * angles[i];
      str += angles[i] * radii[i];
    }
    final double det = n * stt - st * st;
    if (det.abs() < 1e-12) {
      return null;
    }
    final double b = (n * str - st * sr) / det;
    final double a = (sr - b * st) / n;
    double residual = 0;
    for (int i = 0; i < n; i++) {
      final double e = a + b * angles[i] - radii[i];
      residual += e * e;
    }
    final double score = math.sqrt(residual / n) / maxRadius;
    if (!score.isFinite) {
      return null;
    }
    return _SpiralFit(
      center: center,
      a: a,
      b: b,
      start: angles.first,
      span: angles.last - angles.first,
      maxRadius: maxRadius,
      score: score,
    );
  }

  final InkVector center;
  final double a;
  final double b;
  final double start;
  final double span;
  final double maxRadius;
  final double score;
}
