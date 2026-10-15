import 'dart:math' as math;

/// A function of x the features of whose curve are found: undefined where
/// it gives NaN or infinity.
typedef PlotFunction = double Function(double x);

/// How many samples a search makes across its range before refining what
/// it finds between them.
const int _samples = 480;

/// The x in [from]..[to] where [f] is 0: where its curve crosses y = 0, and
/// where it only touches it, as x² does. A sign change across a break in
/// the curve, as 1/x makes at 0, is not one. In ascending order.
List<double> findRoots(PlotFunction f, double from, double to) {
  final List<double> xs = _sampleXs(from, to);
  final List<double> ys = <double>[for (final double x in xs) f(x)];
  final double tolerance = 1e-6 * math.max(1, _scale(ys));
  final List<double> roots = <double>[];
  for (int i = 0; i < xs.length; i++) {
    if (ys[i] == 0) {
      roots.add(xs[i]);
      continue;
    }
    if (i == 0 ||
        !ys[i - 1].isFinite ||
        !ys[i].isFinite ||
        ys[i - 1] == 0 ||
        ys[i - 1].sign == ys[i].sign) {
      continue;
    }
    final double root = _bisect(f, xs[i - 1], xs[i], ys[i - 1]);
    final double value = f(root);
    if (value.isFinite && value.abs() <= tolerance) {
      roots.add(root);
    }
  }
  // Touching roots: an extremum on y = 0.
  for (final double x in findExtrema(f, from, to)) {
    final double value = f(x);
    if (value.isFinite && value.abs() <= tolerance) {
      roots.add(x);
    }
  }
  return _distinct(roots, to - from);
}

/// The x of [f]'s local maxima and minima strictly inside [from]..[to]. A
/// spike at a break in the curve, as 1/x² makes at 0, is not one. In
/// ascending order.
List<double> findExtrema(PlotFunction f, double from, double to) {
  final List<double> xs = _sampleXs(from, to);
  final List<double> ys = <double>[for (final double x in xs) f(x)];
  final List<double> extrema = <double>[];
  for (int i = 1; i < xs.length - 1; i++) {
    final double before = ys[i - 1];
    final double here = ys[i];
    final double after = ys[i + 1];
    if (!before.isFinite || !here.isFinite || !after.isFinite) {
      continue;
    }
    final double rise = here - before;
    final double next = after - here;
    final bool peak = rise > 0 && next <= 0;
    final bool trough = rise < 0 && next >= 0;
    if (!peak && !trough) {
      continue;
    }
    final double x = _goldenSection(
      peak ? f : (double x) => -f(x),
      xs[i - 1],
      xs[i + 1],
    );
    final double value = f(x);
    // Near a smooth turn the refined value differs from the sample's by
    // less than a step does; near a break it runs away.
    if (value.isFinite &&
        (value - here).abs() <= rise.abs() + next.abs() + 1e-12) {
      extrema.add(x);
    }
  }
  return _distinct(extrema, to - from);
}

/// The x in [from]..[to] where the curves of [f] and [g] meet.
List<double> findIntersections(
  PlotFunction f,
  PlotFunction g,
  double from,
  double to,
) {
  return findRoots((double x) => f(x) - g(x), from, to);
}

/// [value] written short for a label: a whole number as one, anything else
/// to at most two decimals, and never "-0".
String formatPlotNumber(double value) {
  final double rounded = (value * 100).round() / 100;
  if (rounded == 0) {
    return '0';
  }
  if (rounded == rounded.roundToDouble()) {
    return rounded.toInt().toString();
  }
  String text = rounded.toStringAsFixed(2);
  while (text.endsWith('0')) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}

/// "(x, y)", each [formatPlotNumber].
String formatPlotPoint(double x, double y) {
  return '(${formatPlotNumber(x)}, ${formatPlotNumber(y)})';
}

/// Round values from [low] to [high], about [target] of them, a step of 1,
/// 2, or 5 times a power of ten apart.
List<double> niceTicks(double low, double high, {int target = 5}) {
  final double span = high - low;
  if (!(span > 0) || !span.isFinite) {
    return const <double>[];
  }
  final double rough = span / target;
  final double power = math
      .pow(10, (math.log(rough) / math.ln10).floor())
      .toDouble();
  final double fraction = rough / power;
  final double step =
      (fraction < 1.5
          ? 1
          : fraction < 3.5
          ? 2
          : fraction < 7.5
          ? 5
          : 10) *
      power;
  final List<double> ticks = <double>[];
  for (
    double tick = (low / step).ceil() * step;
    tick <= high + step * 1e-9;
    tick += step
  ) {
    // Clears the rounding error of repeated addition, so 0.30000000000000004
    // is 0.3.
    ticks.add(double.parse(tick.toStringAsPrecision(12)));
  }
  return ticks;
}

List<double> _sampleXs(double from, double to) {
  return <double>[
    for (int i = 0; i < _samples; i++) from + (to - from) * i / (_samples - 1),
  ];
}

/// The largest finite magnitude among [ys], or 0.
double _scale(List<double> ys) {
  double scale = 0;
  for (final double y in ys) {
    if (y.isFinite && y.abs() > scale) {
      scale = y.abs();
    }
  }
  return scale;
}

/// Where [f] changes sign between [a] and [b], given its value [fa] at
/// [a].
double _bisect(PlotFunction f, double a, double b, double fa) {
  double low = a;
  double high = b;
  double lowValue = fa;
  for (int i = 0; i < 80; i++) {
    final double middle = (low + high) / 2;
    final double value = f(middle);
    if (value == 0) {
      return middle;
    }
    if (value.sign == lowValue.sign) {
      low = middle;
      lowValue = value;
    } else {
      high = middle;
    }
  }
  return (low + high) / 2;
}

/// The x in [a]..[b] where [f] is greatest, for an [f] with one peak there.
double _goldenSection(PlotFunction f, double a, double b) {
  const double ratio = 0.6180339887498949;
  double low = a;
  double high = b;
  double c = high - ratio * (high - low);
  double d = low + ratio * (high - low);
  double fc = f(c);
  double fd = f(d);
  for (int i = 0; i < 80; i++) {
    if (fc >= fd || fd.isNaN) {
      high = d;
      d = c;
      fd = fc;
      c = high - ratio * (high - low);
      fc = f(c);
    } else {
      low = c;
      c = d;
      fc = fd;
      d = low + ratio * (high - low);
      fd = f(d);
    }
  }
  return (low + high) / 2;
}

/// [xs], sorted, with any closer than a ten-thousandth of [span] to the
/// one before left out.
List<double> _distinct(List<double> xs, double span) {
  xs.sort();
  final List<double> distinct = <double>[];
  for (final double x in xs) {
    if (distinct.isEmpty || x - distinct.last > span * 1e-4) {
      distinct.add(x);
    }
  }
  return distinct;
}
