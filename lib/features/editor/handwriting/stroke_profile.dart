import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// How something develops along a stroke: a smooth polynomial of degree
/// [degree] over the stroke's length, from s = 0 where it starts to s = 1
/// where it ends, and zero at both ends.
///
/// It is s(1 − s) times a Chebyshev series of degree [degree] − 2, so the
/// stroke's ends stay where they are whatever the coefficients. Fitted to a
/// writer's strokes with a penalty on the higher terms, and held to a
/// limited number of swings, so it follows how the hand moves without
/// copying the pen's tremor or ringing between samples.
@immutable
class StrokeProfile {
  const StrokeProfile(this.coefficients);

  /// The Chebyshev coefficients, lowest first; fewer than [terms] means the
  /// rest are zero.
  final List<double> coefficients;

  /// No change anywhere along the stroke.
  static const StrokeProfile zero = StrokeProfile(<double>[]);

  /// The polynomial's degree.
  static const int degree = 10;

  /// How many coefficients a profile can have.
  static const int terms = degree - 1;

  bool get isZero => coefficients.every((double c) => c == 0);

  /// The profile at [s], from 0 to 1.
  double at(double s) {
    if (coefficients.isEmpty) return 0;
    return s * (1 - s) * _series(coefficients, 2 * s - 1);
  }

  /// The largest size the profile reaches along the stroke.
  double get peak {
    double most = 0;
    for (int i = 0; i <= _grid; i++) {
      most = math.max(most, at(i / _grid).abs());
    }
    return most;
  }

  /// How far the profile travels up and down along the stroke, in all.
  double get travel {
    double sum = 0;
    double last = 0;
    for (int i = 1; i <= _grid; i++) {
      final double here = at(i / _grid);
      sum += (here - last).abs();
      last = here;
    }
    return sum;
  }

  StrokeProfile operator +(StrokeProfile other) => _combined(other, 1);

  StrokeProfile operator -(StrokeProfile other) => _combined(other, -1);

  StrokeProfile scaled(double factor) =>
      StrokeProfile(<double>[for (final double c in coefficients) c * factor]);

  /// This profile moved [amount] of the way towards [other].
  StrokeProfile mix(StrokeProfile other, double amount) =>
      scaled(1 - amount) + other.scaled(amount);

  /// This profile no larger than [maxPeak], and smooth: one that swings
  /// back and forth more than a hand does loses its highest terms until it
  /// does not.
  StrokeProfile limited(double maxPeak) {
    List<double> kept = List<double>.of(coefficients);
    while (kept.length > 2) {
      final StrokeProfile candidate = StrokeProfile(kept);
      final double size = candidate.peak;
      // Up and back down, twice: as much as a hand's line or curve swings.
      if (size == 0 || candidate.travel <= size * 4.5) break;
      kept = kept.sublist(0, kept.length - 1);
    }
    final StrokeProfile smooth = StrokeProfile(kept);
    final double size = smooth.peak;
    return size > maxPeak ? smooth.scaled(maxPeak / size) : smooth;
  }

  /// The profile closest to [samples], each a place along a stroke, the
  /// value there, and how much it counts, or null with too few to tell.
  ///
  /// Least squares, with a penalty growing as the fourth power of each
  /// term's order, [smoothing] strong against the samples' own weight.
  static StrokeProfile? fit(
    List<({double s, double value, double weight})> samples, {
    double smoothing = 0.02,
  }) {
    if (samples.length < terms * 3) return null;
    final List<List<double>> normal = <List<double>>[
      for (int i = 0; i < terms; i++) List<double>.filled(terms, 0),
    ];
    final List<double> right = List<double>.filled(terms, 0);
    final List<double> basis = List<double>.filled(terms, 0);
    for (final ({double s, double value, double weight}) sample in samples) {
      if (sample.weight <= 0 || !sample.value.isFinite) continue;
      final double s = sample.s.clamp(0.0, 1.0);
      final double pinned = s * (1 - s);
      _chebyshev(2 * s - 1, basis);
      for (int i = 0; i < terms; i++) {
        final double bi = basis[i] * pinned;
        right[i] += sample.weight * bi * sample.value;
        for (int j = 0; j < terms; j++) {
          normal[i][j] += sample.weight * bi * basis[j] * pinned;
        }
      }
    }
    double trace = 0;
    for (int i = 0; i < terms; i++) {
      trace += normal[i][i];
    }
    if (trace <= 0) return null;
    final double lambda = smoothing * trace / terms;
    for (int i = 0; i < terms; i++) {
      normal[i][i] += lambda * (1 + math.pow(i, 4).toDouble());
    }
    final List<double>? solved = _solve(normal, right);
    return solved == null ? null : StrokeProfile(solved);
  }

  List<double> toJson() => coefficients;

  static StrokeProfile? fromJson(Object? json) {
    if (json is! List || json.length > terms) return null;
    final List<double> coefficients = <double>[];
    for (final Object? value in json) {
      if (value is! num || !value.isFinite) return null;
      coefficients.add(value.toDouble());
    }
    return StrokeProfile(coefficients);
  }

  StrokeProfile _combined(StrokeProfile other, double sign) {
    final int length = math.max(coefficients.length, other.coefficients.length);
    double get(List<double> list, int i) => i < list.length ? list[i] : 0;
    return StrokeProfile(<double>[
      for (int i = 0; i < length; i++)
        get(coefficients, i) + sign * get(other.coefficients, i),
    ]);
  }

  static const int _grid = 100;

  static double _series(List<double> coefficients, double x) {
    // Clenshaw's recurrence.
    double b1 = 0;
    double b2 = 0;
    for (int k = coefficients.length - 1; k >= 1; k--) {
      final double b0 = coefficients[k] + 2 * x * b1 - b2;
      b2 = b1;
      b1 = b0;
    }
    return coefficients[0] + x * b1 - b2;
  }

  static void _chebyshev(double x, List<double> out) {
    out[0] = 1;
    if (out.length > 1) out[1] = x;
    for (int k = 2; k < out.length; k++) {
      out[k] = 2 * x * out[k - 1] - out[k - 2];
    }
  }

  /// Gaussian elimination with partial pivoting; null when singular.
  static List<double>? _solve(List<List<double>> a, List<double> b) {
    final int n = b.length;
    final List<List<double>> m = <List<double>>[
      for (int i = 0; i < n; i++) <double>[...a[i], b[i]],
    ];
    for (int col = 0; col < n; col++) {
      int pivot = col;
      for (int row = col + 1; row < n; row++) {
        if (m[row][col].abs() > m[pivot][col].abs()) pivot = row;
      }
      if (m[pivot][col].abs() < 1e-14) return null;
      final List<double> swap = m[col];
      m[col] = m[pivot];
      m[pivot] = swap;
      for (int row = col + 1; row < n; row++) {
        final double factor = m[row][col] / m[col][col];
        for (int k = col; k <= n; k++) {
          m[row][k] -= factor * m[col][k];
        }
      }
    }
    final List<double> x = List<double>.filled(n, 0);
    for (int row = n - 1; row >= 0; row--) {
      double sum = m[row][n];
      for (int k = row + 1; k < n; k++) {
        sum -= m[row][k] * x[k];
      }
      x[row] = sum / m[row][row];
    }
    return x;
  }

  @override
  bool operator ==(Object other) =>
      other is StrokeProfile && listEquals(other._trimmed, _trimmed);

  List<double> get _trimmed {
    int end = coefficients.length;
    while (end > 0 && coefficients[end - 1] == 0) {
      end--;
    }
    return coefficients.sublist(0, end);
  }

  @override
  int get hashCode => Object.hashAll(_trimmed);

  @override
  String toString() =>
      'StrokeProfile(${coefficients.map((double c) => c.toStringAsFixed(4)).join(', ')})';
}

/// How tightly a hand curves, by which way the curve bends: a polynomial
/// of degree [degree] in the direction a bend faces, (cos θ, sin θ) for
/// its outward normal θ (0 facing right, π/2 facing down the page), giving
/// the natural log of how much larger the bend's radius is than the
/// font's.
///
/// A polynomial in the direction rather than the angle, so it goes round
/// without a seam: written out, a0 + Σ ak cos kθ + bk sin kθ for k up to
/// [degree]. −0.3 facing down, say, is a hand that turns about 26% tighter
/// than the font at the bottoms of its bowls. It reads the same whichever
/// way the pen went round, and needs no curve cut out of a stroke to be
/// measured: every curved point says something.
@immutable
class CurveProfile {
  const CurveProfile(this.coefficients);

  /// a0, a1, b1, a2, b2, … lowest first; missing ones are zero.
  final List<double> coefficients;

  static const CurveProfile zero = CurveProfile(<double>[]);

  static const int degree = 10;

  static const int terms = 2 * degree + 1;

  bool get isZero => coefficients.every((double c) => c == 0);

  /// The log ratio of radii for a bend facing [direction], in radians.
  double at(double direction) {
    double sum = 0;
    for (int i = 0; i < coefficients.length; i++) {
      sum += coefficients[i] * _basis(i, direction);
    }
    return sum;
  }

  /// The [i]th term's value facing [direction]: 1, cos θ, sin θ, cos 2θ, …
  static double _basis(int i, double direction) {
    if (i == 0) return 1;
    final int k = (i + 1) ~/ 2;
    return i.isOdd ? math.cos(k * direction) : math.sin(k * direction);
  }

  /// The order of the [i]th term.
  static int _order(int i) => (i + 1) ~/ 2;

  /// The largest ratio, either way, over every direction.
  double get peak {
    double most = 0;
    for (int i = 0; i < _grid; i++) {
      most = math.max(most, at(-math.pi + 2 * math.pi * i / _grid).abs());
    }
    return most;
  }

  /// How far it travels up and down going once round.
  double get travel {
    double sum = 0;
    double last = at(-math.pi);
    for (int i = 1; i <= _grid; i++) {
      final double here = at(-math.pi + 2 * math.pi * i / _grid);
      sum += (here - last).abs();
      last = here;
    }
    return sum;
  }

  CurveProfile operator +(CurveProfile other) => _combined(other, 1);

  CurveProfile operator -(CurveProfile other) => _combined(other, -1);

  CurveProfile scaled(double factor) =>
      CurveProfile(<double>[for (final double c in coefficients) c * factor]);

  CurveProfile mix(CurveProfile other, double amount) =>
      scaled(1 - amount) + other.scaled(amount);

  /// No larger than [maxPeak] either way, and with no more swings than a
  /// hand has: highest terms go until it has.
  CurveProfile limited(double maxPeak) {
    List<double> kept = List<double>.of(coefficients);
    while (kept.length > 3) {
      final CurveProfile candidate = CurveProfile(kept);
      final double size = candidate.peak;
      // Round a letter, a hand tightens and loosens a few times at most.
      if (size == 0 || candidate.travel <= size * 8.5) break;
      // The highest order goes, both its terms.
      kept = kept.sublist(
        0,
        kept.length.isOdd ? kept.length - 2 : kept.length - 1,
      );
    }
    final CurveProfile smooth = CurveProfile(kept);
    final double size = smooth.peak;
    return size > maxPeak ? smooth.scaled(maxPeak / size) : smooth;
  }

  /// The profile closest to [samples], each a bend's direction, its log
  /// radius, and how much it counts, or null with too few to tell. Least
  /// squares, as [StrokeProfile.fit], with a penalty growing as the fourth
  /// power of each term's order, [smoothing] strong.
  static CurveProfile? fit(
    List<({double direction, double value, double weight})> samples, {
    double smoothing = 0.005,
  }) {
    if (samples.length < terms * 3) return null;
    final List<List<double>> normal = <List<double>>[
      for (int i = 0; i < terms; i++) List<double>.filled(terms, 0),
    ];
    final List<double> right = List<double>.filled(terms, 0);
    final List<double> basis = List<double>.filled(terms, 0);
    for (final ({double direction, double value, double weight}) sample
        in samples) {
      if (sample.weight <= 0 || !sample.value.isFinite) continue;
      for (int i = 0; i < terms; i++) {
        basis[i] = _basis(i, sample.direction);
      }
      for (int i = 0; i < terms; i++) {
        right[i] += sample.weight * basis[i] * sample.value;
        for (int j = 0; j < terms; j++) {
          normal[i][j] += sample.weight * basis[i] * basis[j];
        }
      }
    }
    double trace = 0;
    for (int i = 0; i < terms; i++) {
      trace += normal[i][i];
    }
    if (trace <= 0) return null;
    final double lambda = smoothing * trace / terms;
    for (int i = 0; i < terms; i++) {
      normal[i][i] += lambda * (1 + math.pow(_order(i), 4).toDouble());
    }
    final List<double>? solved = StrokeProfile._solve(normal, right);
    return solved == null ? null : CurveProfile(solved);
  }

  List<double> toJson() => coefficients;

  static CurveProfile? fromJson(Object? json) {
    if (json is! List || json.length > terms) return null;
    final List<double> coefficients = <double>[];
    for (final Object? value in json) {
      if (value is! num || !value.isFinite) return null;
      coefficients.add(value.toDouble());
    }
    return CurveProfile(coefficients);
  }

  CurveProfile _combined(CurveProfile other, double sign) {
    final int length = math.max(coefficients.length, other.coefficients.length);
    double get(List<double> list, int i) => i < list.length ? list[i] : 0;
    return CurveProfile(<double>[
      for (int i = 0; i < length; i++)
        get(coefficients, i) + sign * get(other.coefficients, i),
    ]);
  }

  static const int _grid = 120;

  List<double> get _trimmed {
    int end = coefficients.length;
    while (end > 0 && coefficients[end - 1] == 0) {
      end--;
    }
    return coefficients.sublist(0, end);
  }

  @override
  bool operator ==(Object other) =>
      other is CurveProfile && listEquals(other._trimmed, _trimmed);

  @override
  int get hashCode => Object.hashAll(_trimmed);

  @override
  String toString() =>
      'CurveProfile(${coefficients.map((double c) => c.toStringAsFixed(4)).join(', ')})';
}
