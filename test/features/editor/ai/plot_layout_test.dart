import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/ai/notation_formula.dart';
import 'package:greatnote/features/editor/ai/notation_layout.dart';
import 'package:greatnote/features/editor/ink/ink_notation.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';

const Size _note = Size(800, 600);

/// A plot of x from -4 to 4 and y from -2 to 6, in the box from (400, 60)
/// to (720, 300) on the note: 40 pixels a unit across, 30 a unit down.
AiNotationPlot _plot(
  List<AiPlotChild> children, {
  bool axes = false,
  bool ticks = false,
  double? yFrom = -2,
  double? yTo = 6,
}) {
  return AiNotationPlot(
    left: 0.5,
    top: 0.1,
    right: 0.9,
    bottom: 0.5,
    xFrom: -4,
    xTo: 4,
    yFrom: yFrom,
    yTo: yTo,
    axes: axes,
    ticks: ticks,
    children: children,
    ink: 'graphite',
    width: 2,
  );
}

/// Where the plot's (x, y) lands on the note.
InkVector _page(double x, double y) {
  return InkVector(400 + (x + 4) * 40, 300 - (y + 2) * 30);
}

List<GeneratedInkTrace> _layout(AiNotationItem item) {
  return layoutNotation(
    AiNotation(label: 'L', items: <AiNotationItem>[item]),
    _note,
  );
}

/// The one-point traces: dots.
List<InkVector> _dots(List<GeneratedInkTrace> traces) {
  return <InkVector>[
    for (final GeneratedInkTrace trace in traces)
      if (trace.points.length == 1) trace.points.single,
  ];
}

Matcher _at(InkVector expected) {
  return predicate<InkVector>(
    (InkVector point) => (point - expected).length < 1e-6,
    'at $expected',
  );
}

NotationFormula _formula(String source) => NotationFormula.parse(source);

void main() {
  test('places a point in the plot\'s own units', () {
    final List<GeneratedInkTrace> traces = _layout(
      _plot(<AiPlotChild>[const AiPlotDot(at: AiPlotPoint(2, 4), ink: 'red')]),
    );
    expect(_dots(traces), <Matcher>[_at(_page(2, 4))]);
    expect(traces.single.style.ink.id, 'red');
  });

  test('a labelled point writes its label beside the dot', () {
    final List<GeneratedInkTrace> traces = _layout(
      _plot(<AiPlotChild>[
        const AiPlotDot(at: AiPlotPoint(0, 0), label: 'O', ink: 'red'),
      ]),
    );
    expect(traces.length, greaterThan(1));
    final InkVector dot = _page(0, 0);
    // The label is written above and to the right.
    for (final GeneratedInkTrace trace in traces.skip(1)) {
      for (final InkVector point in trace.points) {
        expect(point.x, greaterThan(dot.x));
        expect(point.y, lessThan(dot.y));
      }
    }
  });

  test('a function is drawn through the plot\'s points', () {
    final List<GeneratedInkTrace> traces = _layout(
      _plot(<AiPlotChild>[
        AiPlotFunction(formula: _formula('x/2'), ink: 'blue'),
      ]),
    );
    // One curve, in strokes that meet end to end.
    for (int i = 1; i < traces.length; i++) {
      expect(traces[i].points.first, _at(traces[i - 1].points.last));
    }
    expect(traces.first.points.first, _at(_page(-4, -2)));
    expect(traces.last.points.last, _at(_page(4, 2)));
  });

  test('marks put a dot at each root, extremum, and the y intercept', () {
    final List<GeneratedInkTrace> traces = _layout(
      _plot(<AiPlotChild>[
        AiPlotFunction(
          formula: _formula('x^2 - 1'),
          marks: const <AiPlotMark>[
            AiPlotMark.roots,
            AiPlotMark.extrema,
            AiPlotMark.yIntercept,
          ],
          ink: 'blue',
        ),
      ]),
    );
    expect(_dots(traces), <Matcher>[
      _at(_page(-1, 0)),
      _at(_page(1, 0)),
      _at(_page(0, -1)),
      // The vertex is the y intercept as well.
      _at(_page(0, -1)),
    ]);
  });

  test('a mark outside the plot\'s ranges is left out', () {
    final List<GeneratedInkTrace> traces = _layout(
      _plot(<AiPlotChild>[
        AiPlotFunction(
          formula: _formula('x^2 - 100'),
          marks: const <AiPlotMark>[AiPlotMark.roots, AiPlotMark.extrema],
          ink: 'blue',
        ),
      ]),
    );
    expect(_dots(traces), isEmpty);
  });

  test('intersections are dotted where the curves meet', () {
    final List<GeneratedInkTrace> traces = _layout(
      _plot(<AiPlotChild>[
        AiPlotIntersections(
          first: _formula('x^2'),
          second: _formula('x + 2'),
          ink: 'purple',
        ),
      ]),
    );
    expect(_dots(traces), <Matcher>[_at(_page(-1, 1)), _at(_page(2, 4))]);
  });

  test('a segment is cut off at the box', () {
    final List<GeneratedInkTrace> traces = _layout(
      _plot(<AiPlotChild>[
        const AiPlotSegment(
          from: AiPlotPoint(-10, 0),
          to: AiPlotPoint(10, 0),
          ink: 'red',
        ),
        const AiPlotSegment(
          from: AiPlotPoint(10, 10),
          to: AiPlotPoint(20, 20),
          ink: 'red',
        ),
      ]),
    );
    expect(traces, hasLength(1));
    expect(traces.single.points, <Matcher>[
      _at(_page(-4, 0)),
      _at(_page(4, 0)),
    ]);
  });

  test('shading hatches between the curve and its base', () {
    final List<GeneratedInkTrace> traces = _layout(
      _plot(<AiPlotChild>[
        AiPlotShade(formula: _formula('x'), from: 1, to: 3, ink: 'teal'),
      ]),
    );
    expect(traces.length, greaterThan(5));
    for (final GeneratedInkTrace trace in traces) {
      final InkVector bottom = trace.points.first;
      final InkVector top = trace.points.last;
      expect(bottom.x, top.x);
      expect(bottom.y, closeTo(_page(0, 0).y, 1e-9));
      final double x = (bottom.x - 400) / 40 - 4;
      expect(top.y, closeTo(_page(x, x).y, 1e-9));
      expect(x, inInclusiveRange(1, 3));
    }
  });

  test('axes cross at the origin, and ticks are numbered', () {
    final List<GeneratedInkTrace> bare = _layout(
      _plot(const <AiPlotChild>[], axes: true),
    );
    // Two axes, each with an arrowhead.
    expect(bare, hasLength(4));
    expect(bare[0].points.first.y, _page(0, 0).y);
    expect(bare[2].points.first.x, _page(0, 0).x);
    final List<GeneratedInkTrace> ticked = _layout(
      _plot(const <AiPlotChild>[], axes: true, ticks: true),
    );
    expect(ticked.length, greaterThan(bare.length + 10));
  });

  test('axes run along the box edge when it does not reach 0', () {
    final AiNotationPlot plot = AiNotationPlot(
      left: 0.5,
      top: 0.1,
      right: 0.9,
      bottom: 0.5,
      xFrom: 1,
      xTo: 5,
      yFrom: 10,
      yTo: 20,
      axes: true,
      ticks: false,
      children: const <AiPlotChild>[],
      ink: 'graphite',
      width: 2,
    );
    final List<GeneratedInkTrace> traces = _layout(plot);
    expect(traces[0].points.first.y, 300);
    expect(traces[2].points.first.x, 400);
  });

  test('without a y range the plot fits its contents', () {
    final List<GeneratedInkTrace> traces = _layout(
      _plot(
        <AiPlotChild>[AiPlotFunction(formula: _formula('x^2'), ink: 'blue')],
        yFrom: null,
        yTo: null,
      ),
    );
    double top = double.infinity;
    double bottom = double.negativeInfinity;
    for (final InkVector point in <InkVector>[
      for (final GeneratedInkTrace trace in traces) ...trace.points,
    ]) {
      top = point.y < top ? point.y : top;
      bottom = point.y > bottom ? point.y : bottom;
    }
    // 0 to 16, with 5% room each way, in a box 240 pixels tall.
    expect(bottom, closeTo(300 - 240 * 0.05 / 1.1, 1e-6));
    expect(top, closeTo(60 + 240 * 0.05 / 1.1, 1e-6));
  });

  test('a plot with nothing to fit cannot be drawn', () {
    expect(
      () => _layout(_plot(const <AiPlotChild>[], yFrom: null, yTo: null)),
      throwsFormatException,
    );
  });

  test('its labels stay on the paper, even at its edge', () {
    // A box only just inside the paper: the numbers along its axes, and
    // a long label by its corner, would run off it.
    final AiNotationPlot plot = AiNotationPlot(
      left: 0.02,
      top: 0.02,
      right: 0.3,
      bottom: 0.3,
      xFrom: -1000,
      xTo: -900,
      yFrom: -1000,
      yTo: -900,
      axes: true,
      ticks: true,
      children: <AiPlotChild>[
        AiPlotFunction(
          formula: _formula('x'),
          marks: const <AiPlotMark>[AiPlotMark.roots],
          ink: 'blue',
        ),
        const AiPlotDot(
          at: AiPlotPoint(-999, -901),
          label: 'a long label at the corner',
          ink: 'red',
        ),
      ],
      ink: 'graphite',
      width: 2,
    );
    for (final GeneratedInkTrace trace in _layout(plot)) {
      final double half = trace.style.width / 2;
      for (final InkVector point in trace.points) {
        expect(point.x - half, greaterThanOrEqualTo(0));
        expect(point.y - half, greaterThanOrEqualTo(0));
        expect(point.x + half, lessThanOrEqualTo(_note.width));
        expect(point.y + half, lessThanOrEqualTo(_note.height));
      }
    }
  });

  test('a stepped plot is drawn over its share of the animation', () {
    final AiNotation notation = AiNotation(
      label: 'L',
      items: <AiNotationItem>[
        _plot(<AiPlotChild>[
          AiPlotFunction(formula: _formula('x'), ink: 'blue'),
        ], axes: true),
      ],
      timeline: AiNotationTimeline(
        durationMs: 1500,
        items: const <AiItemTiming>[AiItemTiming(0, 1000)],
      ),
    );
    final List<GeneratedInkTrace> traces = layoutTimedNotation(notation, _note);
    expect(traces.first.timesMs!.first, 0);
    expect(traces.last.timesMs!.last, 1000);
  });
}
