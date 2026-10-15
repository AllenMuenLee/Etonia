import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/notation_formula.dart';
import 'package:greatnote/features/editor/ai/plot_features.dart';

PlotFunction _f(String formula) => NotationFormula.parse(formula).evaluate;

Matcher _near(List<double> expected) {
  return pairwiseCompare<double, double>(
    expected,
    (double want, double got) => (want - got).abs() < 1e-6,
    'within 1e-6 of',
  );
}

void main() {
  group('roots', () {
    test('finds where a curve crosses y = 0', () {
      expect(findRoots(_f('x^2 - 4'), -5, 5), _near(<double>[-2, 2]));
      expect(findRoots(_f('x^3 - x'), -2, 2), _near(<double>[-1, 0, 1]));
      expect(
        findRoots(_f('sin(x)'), -0.5, 7),
        _near(<double>[0, math.pi, 2 * math.pi]),
      );
    });

    test('finds where a curve only touches y = 0', () {
      expect(findRoots(_f('x^2'), -3, 3), _near(<double>[0]));
      expect(findRoots(_f('(x - 1)^2'), -3, 3), _near(<double>[1]));
    });

    test('ignores a sign change across a break in the curve', () {
      expect(findRoots(_f('1/x'), -3, 3), isEmpty);
      expect(findRoots(_f('tan(x)'), 1, 2), isEmpty);
    });

    test('finds none in a range that has none', () {
      expect(findRoots(_f('x^2 + 1'), -3, 3), isEmpty);
      expect(findRoots(_f('x - 10'), -3, 3), isEmpty);
    });
  });

  group('extrema', () {
    test('finds local maxima and minima', () {
      expect(findExtrema(_f('x^2 - 2*x'), -3, 3), _near(<double>[1]));
      expect(findExtrema(_f('x^3 - 3*x'), -3, 3), _near(<double>[-1, 1]));
      expect(
        findExtrema(_f('sin(x)'), 0, 2 * math.pi),
        _near(<double>[math.pi / 2, 3 * math.pi / 2]),
      );
    });

    test('ignores a spike at a break, and a straight line', () {
      expect(findExtrema(_f('1/x^2'), -3, 3), isEmpty);
      expect(findExtrema(_f('2*x + 1'), -3, 3), isEmpty);
      expect(findExtrema(_f('5'), -3, 3), isEmpty);
    });
  });

  test('intersections are where two curves meet', () {
    expect(
      findIntersections(_f('x^2'), _f('2*x + 3'), -5, 5),
      _near(<double>[-1, 3]),
    );
    expect(findIntersections(_f('x'), _f('x + 1'), -5, 5), isEmpty);
  });

  test('numbers are written short', () {
    expect(formatPlotNumber(3), '3');
    expect(formatPlotNumber(-2.0000000001), '-2');
    expect(formatPlotNumber(1.5), '1.5');
    expect(formatPlotNumber(math.pi), '3.14');
    expect(formatPlotNumber(-0.0001), '0');
    expect(formatPlotNumber(0.1 + 0.2), '0.3');
    expect(formatPlotPoint(1, -4), '(1, -4)');
  });

  test('ticks fall on round values', () {
    expect(niceTicks(-3, 3, target: 6), <double>[-3, -2, -1, 0, 1, 2, 3]);
    expect(niceTicks(0, 10), <double>[0, 2, 4, 6, 8, 10]);
    expect(niceTicks(-0.95, 9.45), <double>[0, 2, 4, 6, 8]);
    expect(niceTicks(0, 1, target: 5), <double>[0, 0.2, 0.4, 0.6, 0.8, 1]);
    expect(niceTicks(0, 1000, target: 4), <double>[
      0,
      200,
      400,
      600,
      800,
      1000,
    ]);
    expect(niceTicks(2, 2), isEmpty);
  });
}
