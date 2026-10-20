import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../ink/ink_sample.dart';

/// A Bézier curve of the third degree: four control points, enough to
/// follow a stroke that bows, hooks, or loops once, while smoothing away
/// the tremor of a pen.
@immutable
class CubicBezier {
  CubicBezier(List<InkVector> points)
    : assert(points.length == degree + 1),
      points = List<InkVector>.unmodifiable(points);

  /// Every control point at [at]: a dot.
  factory CubicBezier.point(InkVector at) =>
      CubicBezier(List<InkVector>.filled(degree + 1, at));

  /// A straight line from [from] to [to], its control points spread evenly.
  factory CubicBezier.line(InkVector from, InkVector to) =>
      CubicBezier(<InkVector>[
        for (int i = 0; i <= degree; i++) from + (to - from) * (i / degree),
      ]);

  static const int degree = 3;

  final List<InkVector> points;

  /// The Bernstein weights of degree [n] at [t].
  static List<double> _bernstein(int n, double t) {
    final double u = 1 - t;
    double choose = 1;
    final List<double> out = <double>[];
    for (int i = 0; i <= n; i++) {
      out.add(choose * math.pow(u, n - i) * math.pow(t, i));
      choose = choose * (n - i) / (i + 1);
    }
    return out;
  }

  /// The four Bernstein weights at [t].
  static List<double> basis(double t) => _bernstein(degree, t);

  InkVector at(double t) {
    final List<double> b = basis(t);
    double x = 0;
    double y = 0;
    for (int i = 0; i <= degree; i++) {
      x += points[i].x * b[i];
      y += points[i].y * b[i];
    }
    return InkVector(x, y);
  }

  /// The curve's velocity at [t].
  InkVector derivative(double t) {
    final List<double> b = _bernstein(degree - 1, t);
    double x = 0;
    double y = 0;
    for (int i = 0; i < degree; i++) {
      x += (points[i + 1].x - points[i].x) * degree * b[i];
      y += (points[i + 1].y - points[i].y) * degree * b[i];
    }
    return InkVector(x, y);
  }

  InkVector _second(double t) {
    final List<double> b = _bernstein(degree - 2, t);
    double x = 0;
    double y = 0;
    for (int i = 0; i < degree - 1; i++) {
      final double w = degree * (degree - 1) * b[i];
      x += (points[i + 2].x - 2 * points[i + 1].x + points[i].x) * w;
      y += (points[i + 2].y - 2 * points[i + 1].y + points[i].y) * w;
    }
    return InkVector(x, y);
  }

  /// [segments] + 1 points along the curve, evenly in t.
  List<InkVector> sampled(int segments) => <InkVector>[
    for (int i = 0; i <= segments; i++) at(i / segments),
  ];

  /// How far the control points reach from the first: a curve this small
  /// is a dot.
  double get extent {
    double reach = 0;
    for (final InkVector p in points) {
      reach = math.max(reach, (p - points.first).length);
    }
    return reach;
  }

  /// This curve with every control point moved by [map]; an affine map
  /// moves the curve exactly as it moves the points.
  CubicBezier mapped(InkVector Function(InkVector point) map) =>
      CubicBezier(<InkVector>[for (final InkVector p in points) map(p)]);

  /// This curve moved [amount] of the way towards [other].
  CubicBezier lerp(CubicBezier other, double amount) => CubicBezier(<InkVector>[
    for (int i = 0; i <= degree; i++)
      points[i] + (other.points[i] - points[i]) * amount,
  ]);

  /// The curve that best follows [runs], each a sequence of points in the
  /// order the pen drew them, by least squares. Every run is laid along
  /// the curve from t = 0 to 1 by its length, or by [parameters] when
  /// given, and then each point's t is moved to the nearest point of the
  /// curve, a few times over, so that the fit follows the shape rather
  /// than the pace of the pen.
  ///
  /// [start] and [end] pin the curve's ends. Null with fewer points than
  /// the curve has free control points.
  static CubicBezier? fit(
    List<List<InkVector>> runs, {
    InkVector? start,
    InkVector? end,
    List<List<double>>? parameters,
    int refinements = 16,
  }) {
    final List<InkVector> samples = <InkVector>[];
    final List<double> ts = <double>[];
    for (int r = 0; r < runs.length; r++) {
      final List<InkVector> run = runs[r];
      if (run.isEmpty) continue;
      final List<double> along = parameters?[r] ?? _byLength(run);
      samples.addAll(run);
      ts.addAll(along);
    }
    final List<int> free = <int>[
      if (start == null) 0,
      for (int i = 1; i < degree; i++) i,
      if (end == null) degree,
    ];
    if (samples.length < free.length) return null;

    // Where the free points start: on the line between the pinned ends,
    // or the samples' own ends.
    final InkVector first = start ?? samples.first;
    final InkVector last = end ?? samples.last;
    CubicBezier curve = CubicBezier.line(first, last);
    for (int pass = 0; pass <= refinements; pass++) {
      final CubicBezier? next = _solve(
        samples,
        ts,
        free,
        start: start,
        end: end,
        prior: curve,
      );
      if (next == null) return pass == 0 ? null : curve;
      curve = next;
      if (pass == refinements) break;
      // Each sample's t moved to where the curve passes nearest it.
      for (int i = 0; i < ts.length; i++) {
        double t = ts[i];
        for (int step = 0; step < 2; step++) {
          final InkVector miss = curve.at(t) - samples[i];
          final InkVector d1 = curve.derivative(t);
          final InkVector d2 = curve._second(t);
          final double slope = miss.x * d1.x + miss.y * d1.y;
          final double bend =
              d1.x * d1.x + d1.y * d1.y + miss.x * d2.x + miss.y * d2.y;
          if (bend.abs() < 1e-9) break;
          t = (t - slope / bend).clamp(0.0, 1.0);
        }
        ts[i] = t;
      }
    }
    return curve;
  }

  /// Each point's share of the way along [run], 0 at its first and 1 at
  /// its last.
  static List<double> _byLength(List<InkVector> run) {
    final List<double> lengths = <double>[0];
    for (int i = 1; i < run.length; i++) {
      lengths.add(lengths.last + (run[i] - run[i - 1]).length);
    }
    final double total = lengths.last;
    return <double>[
      for (int i = 0; i < run.length; i++)
        total == 0 ? i / math.max(1, run.length - 1) : lengths[i] / total,
    ];
  }

  /// The least-squares control points for [samples] at [ts], the [free]
  /// ones solved for and the rest pinned. A faint pull towards [prior]
  /// keeps a point the samples say nothing about where it was.
  static CubicBezier? _solve(
    List<InkVector> samples,
    List<double> ts,
    List<int> free, {
    required InkVector? start,
    required InkVector? end,
    required CubicBezier prior,
  }) {
    final int n = free.length;
    final List<List<double>> normal = <List<double>>[
      for (int i = 0; i < n; i++) List<double>.filled(n, 0),
    ];
    final List<double> rightX = List<double>.filled(n, 0);
    final List<double> rightY = List<double>.filled(n, 0);
    for (int k = 0; k < samples.length; k++) {
      final List<double> b = basis(ts[k]);
      // What the pinned ends already account for.
      double x = samples[k].x;
      double y = samples[k].y;
      if (start != null) {
        x -= start.x * b[0];
        y -= start.y * b[0];
      }
      if (end != null) {
        x -= end.x * b[degree];
        y -= end.y * b[degree];
      }
      for (int i = 0; i < n; i++) {
        final double bi = b[free[i]];
        rightX[i] += bi * x;
        rightY[i] += bi * y;
        for (int j = 0; j < n; j++) {
          normal[i][j] += bi * b[free[j]];
        }
      }
    }
    final double ridge = 1e-4 * samples.length;
    for (int i = 0; i < n; i++) {
      normal[i][i] += ridge;
      rightX[i] += ridge * prior.points[free[i]].x;
      rightY[i] += ridge * prior.points[free[i]].y;
    }
    final List<double>? xs = _gauss(normal, rightX);
    final List<double>? ys = _gauss(normal, rightY);
    if (xs == null || ys == null) return null;
    final List<InkVector> points = List<InkVector>.of(prior.points);
    if (start != null) points[0] = start;
    if (end != null) points[degree] = end;
    for (int i = 0; i < n; i++) {
      points[free[i]] = InkVector(xs[i], ys[i]);
    }
    for (final InkVector p in points) {
      if (!p.x.isFinite || !p.y.isFinite) return null;
    }
    return CubicBezier(points);
  }

  /// [a] x = [b] by elimination with partial pivoting; null when singular.
  static List<double>? _gauss(List<List<double>> a, List<double> b) {
    final int n = b.length;
    final List<List<double>> m = <List<double>>[
      for (int i = 0; i < n; i++) <double>[...a[i], b[i]],
    ];
    for (int col = 0; col < n; col++) {
      int pivot = col;
      for (int row = col + 1; row < n; row++) {
        if (m[row][col].abs() > m[pivot][col].abs()) pivot = row;
      }
      if (m[pivot][col].abs() < 1e-12) return null;
      final List<double> swap = m[col];
      m[col] = m[pivot];
      m[pivot] = swap;
      for (int row = 0; row < n; row++) {
        if (row == col) continue;
        final double factor = m[row][col] / m[col][col];
        if (factor == 0) continue;
        for (int k = col; k <= n; k++) {
          m[row][k] -= factor * m[col][k];
        }
      }
    }
    return <double>[for (int i = 0; i < n; i++) m[i][n] / m[i][i]];
  }

  List<double> toJson() => <double>[
    for (final InkVector p in points) ...<double>[p.x, p.y],
  ];

  /// A saved curve, or null for anything that is not eight finite numbers.
  static CubicBezier? fromJson(Object? json) {
    if (json is! List || json.length != 2 * (degree + 1)) return null;
    final List<double> values = <double>[];
    for (final Object? value in json) {
      if (value is! num || !value.isFinite) return null;
      values.add(value.toDouble());
    }
    return CubicBezier(<InkVector>[
      for (int i = 0; i < values.length; i += 2)
        InkVector(values[i], values[i + 1]),
    ]);
  }

  @override
  bool operator ==(Object other) =>
      other is CubicBezier && listEquals(other.points, points);

  @override
  int get hashCode => Object.hashAll(points);

  @override
  String toString() =>
      'CubicBezier(${points.map((InkVector p) => '(${p.x.toStringAsFixed(3)}, ${p.y.toStringAsFixed(3)})').join(', ')})';
}
