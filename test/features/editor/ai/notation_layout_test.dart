import 'dart:math' as math;
import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/ai/notation_font.dart';
import 'package:greatnote/features/editor/ai/notation_formula.dart';
import 'package:greatnote/features/editor/ai/notation_layout.dart';
import 'package:greatnote/features/editor/handwriting/handwriting_style.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_notation.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';

const Size _note = Size(800, 600);

List<GeneratedInkTrace> _layout(List<AiNotationItem> items) {
  return layoutNotation(AiNotation(label: 'L', items: items), _note);
}

AiNotationGraph _graph(
  String formula, {
  double xFrom = -2,
  double xTo = 2,
  double? yFrom,
  double? yTo,
  bool axes = false,
}) {
  return AiNotationGraph(
    formula: NotationFormula.parse(formula),
    xFrom: xFrom,
    xTo: xTo,
    yFrom: yFrom,
    yTo: yTo,
    left: 0.25,
    top: 0.25,
    right: 0.75,
    bottom: 0.75,
    axes: axes,
    ink: 'blue',
    width: 2,
  );
}

Rect _boundsOf(Iterable<GeneratedInkTrace> traces) {
  double left = double.infinity;
  double top = double.infinity;
  double right = double.negativeInfinity;
  double bottom = double.negativeInfinity;
  for (final GeneratedInkTrace trace in traces) {
    for (final InkVector p in trace.points) {
      left = math.min(left, p.x);
      top = math.min(top, p.y);
      right = math.max(right, p.x);
      bottom = math.max(bottom, p.y);
    }
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

void main() {
  group('formula', () {
    double at(String formula, double x) {
      return NotationFormula.parse(formula).evaluate(x);
    }

    test('follows the usual order of operations', () {
      expect(at('1 + 2 * 3', 0), 7);
      expect(at('(1 + 2) * 3', 0), 9);
      expect(at('2 ^ 3 ^ 2', 0), 512);
      expect(at('-x^2', 3), -9);
      expect(at('(-x)^2', 3), 9);
      expect(at('x - 1 - 1', 5), 3);
      expect(at('8 / 2 / 2', 0), 2);
      expect(at('2**3', 0), 8);
      expect(at('x^-1', 4), 0.25);
    });

    test('multiplies what is written side by side', () {
      expect(at('2x', 3), 6);
      expect(at('3(x + 1)', 1), 6);
      expect(at('(x + 1)(x - 1)', 3), 8);
      expect(at('2x^2', 3), 18);
      expect(at('x sin(x)', math.pi / 2), closeTo(math.pi / 2, 1e-12));
      expect(at('2pi', 0), closeTo(2 * math.pi, 1e-12));
    });

    test('knows its functions and constants', () {
      expect(at('sin(x)^2 + cos(x)^2', 0.7), closeTo(1, 1e-12));
      // Without parentheses a function takes the power after it.
      expect(at('sin x^2', 2), closeTo(math.sin(4), 1e-12));
      expect(at('sqrt(x)', 9), 3);
      expect(at('abs(x)', -2.5), 2.5);
      expect(at('ln(e)', 0), closeTo(1, 1e-12));
      expect(at('log(1000)', 0), closeTo(3, 1e-12));
      expect(at('exp(0) + floor(2.7) + ceil(2.2)', 0), 6);
      expect(at('tanh(0) + sinh(0) + cosh(0)', 0), 1);
      expect(at('atan(1)', 0), closeTo(math.pi / 4, 1e-12));
      expect(at('π', 0), math.pi);
      expect(at('SIN(X)', 0), 0);
      expect(at('2 × x ÷ 4 − 1', 6), 2);
      expect(at('1.5e2 + .5', 0), 150.5);
    });

    test('is undefined, not wrong, outside its domain', () {
      expect(at('sqrt(x)', -1).isNaN, isTrue);
      expect(at('1/x', 0).isFinite, isFalse);
      expect(at('ln(x)', 0).isFinite, isFalse);
    });

    test('refuses anything that is not a formula', () {
      for (final String source in <String>[
        '',
        '   ',
        'x +',
        '(x + 1',
        'x + 1)',
        'x^^2',
        '* x',
        'y + 1',
        'print(x)',
        'x; 1',
        'x = 2',
        'sin',
        '1e999',
        'a' * 3,
        '${'(' * 50}x${')' * 50}',
        'x + ${'1' * 200}',
      ]) {
        expect(
          () => NotationFormula.parse(source),
          throwsFormatException,
          reason: source,
        );
      }
    });
  });

  group('font', () {
    test('writes every character inside its cell', () {
      for (final String char in NotationFont.characters) {
        final List<List<InkVector>> strokes = NotationFont.write(
          char,
          origin: InkVector.zero,
          size: NotationFont.capHeight,
        );
        final double width = NotationFont.width(char, NotationFont.capHeight);
        for (final List<InkVector> line in strokes) {
          expect(line, isNotEmpty, reason: char);
          for (final InkVector p in line) {
            expect(p.isFinite, isTrue, reason: char);
            expect(p.x, inInclusiveRange(-1.1, width + 1.1), reason: char);
            expect(p.y, inInclusiveRange(-1.1, 13.6), reason: char);
          }
        }
        if (char != ' ') {
          expect(strokes, isNotEmpty, reason: char);
        }
      }
      expect(
        NotationFont.characters,
        containsAll(<String>[
          for (int c = 0x30; c <= 0x39; c++) String.fromCharCode(c),
          for (int c = 0x41; c <= 0x5A; c++) String.fromCharCode(c),
          for (int c = 0x61; c <= 0x7A; c++) String.fromCharCode(c),
          '+',
          '-',
          '=',
          '×',
          '÷',
          '√',
          'π',
          '²',
          '≤',
          '→',
          '✓',
        ]),
      );
    });

    test('lays out size, position, width, and lines', () {
      expect(NotationFont.canWrite('x² + 1 = 5\nso x = 2'), isTrue);
      expect(NotationFont.canWrite('café'), isFalse);
      expect(NotationFont.canWrite('日本'), isFalse);

      // "I" at size 20 from (100, 50): its stem runs the full cap height,
      // leaning forward, with the slight drift of the handwriting
      // treatment.
      final List<List<InkVector>> i = NotationFont.write(
        'I',
        origin: const InkVector(100, 50),
        size: 20,
      );
      final InkVector top = i.single.reduce(
        (InkVector a, InkVector b) => a.y < b.y ? a : b,
      );
      final InkVector foot = i.single.reduce(
        (InkVector a, InkVector b) => a.y > b.y ? a : b,
      );
      expect(top.y, closeTo(50, 0.6));
      expect(foot.y, closeTo(70, 0.6));
      expect(foot.x, inInclusiveRange(99.5, 101));
      // Leaning forward by the standard slant.
      expect(top.x - foot.x, closeTo(20 * 0.12, 0.6));

      // Wider with more letters, and lines stacked 1.6 sizes apart.
      expect(
        NotationFont.width('ab', 20),
        greaterThan(NotationFont.width('a', 20)),
      );
      expect(
        NotationFont.width('long line\nx', 20),
        NotationFont.width('long line', 20),
      );
      final double two = NotationFont.height('a\nb', 20);
      expect(two, closeTo(20 * 1.6 + 20 * 1.3, 1e-9));
      final List<List<InkVector>> lines = NotationFont.write(
        'l\nl',
        origin: InkVector.zero,
        size: 20,
      );
      expect(lines[1].first.y - lines[0].first.y, closeTo(32, 1));
      expect(
        () => NotationFont.write('é', origin: InkVector.zero, size: 20),
        throwsArgumentError,
      );
    });

    test('g is a single storey with a tail curled left, not a q', () {
      List<InkVector> ink(String char) => NotationFont.write(
        char,
        origin: InkVector.zero,
        size: 20,
      ).expand((List<InkVector> stroke) => stroke).toList();
      double lowestX(List<InkVector> points) =>
          points.reduce((InkVector a, InkVector b) => a.y > b.y ? a : b).x;
      final List<InkVector> g = ink('g');
      final List<InkVector> q = ink('q');
      expect(
        NotationFont.write('g', origin: InkVector.zero, size: 20),
        hasLength(1),
      );
      // Both hang below the baseline, but only the g's tail curls back.
      expect(g.map((InkVector p) => p.y).reduce(math.max), greaterThan(22));
      final double gRight = g.map((InkVector p) => p.x).reduce(math.max);
      expect(gRight - lowestX(g), greaterThan(3.5));
      final double qRight = q.map((InkVector p) => p.x).reduce(math.max);
      expect(qRight - lowestX(q), lessThan(3));
    });

    test('a writer\'s style changes the ink but not the font\'s metrics', () {
      const HandwritingStyle wide = HandwritingStyle(
        slant: 0.4,
        widthScale: 1.4,
        xHeight: 0.5,
      );
      double right(List<List<InkVector>> strokes) => strokes
          .expand((List<InkVector> stroke) => stroke)
          .map((InkVector p) => p.x)
          .reduce(math.max);
      final List<List<InkVector>> standard = NotationFont.write(
        'quiet notes',
        origin: InkVector.zero,
        size: 20,
      );
      final List<List<InkVector>> styled = NotationFont.write(
        'quiet notes',
        origin: InkVector.zero,
        size: 20,
        style: wide,
      );
      expect(styled, hasLength(standard.length));
      expect(right(styled), greaterThan(right(standard) * 1.3));
      // The assistant plans with the font's own measure.
      expect(
        right(standard),
        lessThanOrEqualTo(NotationFont.width('quiet notes', 20) + 0.5),
      );
    });

    test('a line is about 0.7 sizes per character, as the prompt says', () {
      const String sample = 'x = 3 so the answer is 42';
      final double perCharacter = NotationFont.width(sample, 1) / sample.length;
      expect(perCharacter, inInclusiveRange(0.5, 0.8));
    });
  });

  group('layout', () {
    test('text is written where and as big as asked', () {
      final List<GeneratedInkTrace> traces = _layout(<AiNotationItem>[
        const AiNotationText(
          text: 'x = 3',
          x: 0.5,
          y: 0.25,
          size: 30,
          ink: 'red',
          width: 2.5,
        ),
      ]);

      final Rect bounds = _boundsOf(traces);
      expect(bounds.left, closeTo(400, 1));
      // The 3 reaches capital height.
      expect(bounds.top, closeTo(150, 1));
      expect(bounds.bottom, closeTo(150 + 30, 1));
      expect(bounds.right, closeTo(400 + NotationFont.width('x = 3', 30), 2));
      expect(
        traces.every((GeneratedInkTrace t) => t.style.ink.id == 'red'),
        isTrue,
      );
      expect(
        traces.every((GeneratedInkTrace t) => t.style.width == 2.5),
        isTrue,
      );
      expect(
        traces
            .where((GeneratedInkTrace t) => t.points.length > 1)
            .every(
              (GeneratedInkTrace t) =>
                  t.widths != null && t.widths!.length == t.points.length,
            ),
        isTrue,
      );
    });

    test('a graph follows its formula, mapped into its box', () {
      final List<GeneratedInkTrace> traces = _layout(<AiNotationItem>[
        _graph('x', yFrom: -2, yTo: 2),
      ]);

      // y = x from (-2, -2) to (2, 2): the box's bottom-left to top-right.
      final List<InkVector> curve = traces
          .expand((GeneratedInkTrace t) => t.points)
          .toList();
      expect(curve.first.x, closeTo(200, 1e-9));
      expect(curve.first.y, closeTo(450, 1e-9));
      expect(curve.last.x, closeTo(600, 1e-9));
      expect(curve.last.y, closeTo(150, 1e-9));
      for (final InkVector p in curve) {
        // On the diagonal of the 400 by 300 box.
        expect((p.x - 200) / 400, closeTo((450 - p.y) / 300, 1e-9));
      }
    });

    test('a fitted graph fills its box, with a little room', () {
      final Rect bounds = _boundsOf(
        _layout(<AiNotationItem>[_graph('x^2 - 2')]),
      );

      expect(bounds.left, closeTo(200, 1e-9));
      expect(bounds.right, closeTo(600, 1e-9));
      // 5% of the 300 px box's height is left above and below.
      expect(bounds.top, closeTo(150 + 300 / 1.1 * 0.05, 0.5));
      expect(bounds.bottom, closeTo(450 - 300 / 1.1 * 0.05, 0.5));
    });

    test('a graph breaks at an asymptote and where it is undefined', () {
      final List<GeneratedInkTrace> hyperbola = _layout(<AiNotationItem>[
        _graph('1/x', yFrom: -5, yTo: 5),
      ]);
      expect(hyperbola, hasLength(2));
      expect(hyperbola[0].points.last.x, lessThan(400));
      expect(hyperbola[1].points.first.x, greaterThan(400));

      final List<GeneratedInkTrace> root = _layout(<AiNotationItem>[
        _graph('sqrt(x)'),
      ]);
      expect(root, hasLength(1));
      expect(root.single.points.first.x, greaterThanOrEqualTo(400));

      // A steep curve that does not break is kept whole.
      expect(_layout(<AiNotationItem>[_graph('x^9')]), hasLength(2));
    });

    test('a graph with nowhere defined cannot be drawn', () {
      expect(
        () => _layout(<AiNotationItem>[_graph('sqrt(-1 - x^2)')]),
        throwsFormatException,
      );
    });

    test('axes are drawn where they cross the box, in graphite', () {
      final List<GeneratedInkTrace> traces = _layout(<AiNotationItem>[
        _graph('x', yFrom: -2, yTo: 2, axes: true),
      ]);
      final List<GeneratedInkTrace> axes = traces
          .where((GeneratedInkTrace t) => t.style.ink.id == 'graphite')
          .toList();

      // Each axis and its arrowhead.
      expect(axes, hasLength(4));
      expect(axes[0].points, const <InkVector>[
        InkVector(200, 300),
        InkVector(600, 300),
      ]);
      expect(axes[2].points, const <InkVector>[
        InkVector(400, 450),
        InkVector(400, 150),
      ]);

      // Away from 0, there is no axis to draw.
      final List<GeneratedInkTrace> shifted = _layout(<AiNotationItem>[
        _graph('x', xFrom: 1, xTo: 3, yFrom: 1, yTo: 3, axes: true),
      ]);
      expect(
        shifted.where((GeneratedInkTrace t) => t.style.ink.id == 'graphite'),
        isEmpty,
      );
    });

    test('a path goes through its key points, straight or curved', () {
      const List<AiNotationPoint> keys = <AiNotationPoint>[
        AiNotationPoint(0.1, 0.5),
        AiNotationPoint(0.3, 0.2),
        AiNotationPoint(0.5, 0.5),
        AiNotationPoint(0.7, 0.2),
      ];
      List<InkVector> drawn(
        List<AiPathSegment> segments, {
        bool closed = false,
      }) {
        return _layout(<AiNotationItem>[
          AiNotationPath(
            points: closed ? keys.sublist(0, 3) : keys,
            segments: segments,
            closed: closed,
            ink: 'green',
            width: 3,
          ),
        ]).single.points;
      }

      InkVector page(AiNotationPoint p) {
        return InkVector(p.x * _note.width, p.y * _note.height);
      }

      // All straight: exactly the key points.
      expect(
        drawn(List<AiPathSegment>.filled(3, AiPathSegment.straight)),
        keys.map(page).toList(),
      );

      // Curved: still through every key point, with more in between.
      final List<InkVector> curved = drawn(
        List<AiPathSegment>.filled(3, AiPathSegment.curve),
      );
      expect(curved.length, greaterThan(keys.length * 3));
      for (final AiNotationPoint key in keys) {
        expect(
          curved.any((InkVector p) => (p - page(key)).length < 1e-6),
          isTrue,
        );
      }
      // A straight part is just its two ends; a curved part leaves the
      // straight line between its ends.
      final List<InkVector> mixed = drawn(<AiPathSegment>[
        AiPathSegment.straight,
        AiPathSegment.curve,
        AiPathSegment.straight,
      ]);
      expect(mixed.sublist(0, 2), <InkVector>[page(keys[0]), page(keys[1])]);
      expect(mixed.sublist(mixed.length - 2), <InkVector>[
        page(keys[2]),
        page(keys[3]),
      ]);
      final InkVector a = page(keys[1]);
      final InkVector b = page(keys[2]);
      final InkVector across = (b - a).perpendicular * (1 / (b - a).length);
      final double furthest = mixed
          .sublist(1, mixed.length - 1)
          .map((InkVector p) => (p - a).dot(across).abs())
          .reduce(math.max);
      expect(furthest, greaterThan(5));

      // Closed: back to the start.
      final List<InkVector> loop = drawn(
        List<AiPathSegment>.filled(3, AiPathSegment.curve),
        closed: true,
      );
      expect(loop.first, page(keys[0]));
      expect((loop.last - loop.first).length, lessThan(1e-6));
    });

    test('a long line is split into strokes that meet end to end', () {
      final List<GeneratedInkTrace> traces = _layout(<AiNotationItem>[
        AiNotationPath(
          points: <AiNotationPoint>[
            for (int i = 0; i < 64; i++)
              AiNotationPoint(0.05 + 0.9 * i / 63, i.isEven ? 0.3 : 0.7),
          ],
          segments: List<AiPathSegment>.filled(63, AiPathSegment.curve),
          closed: false,
          ink: 'ink',
          width: 2,
        ),
      ]);

      expect(traces.length, greaterThan(1));
      for (int i = 0; i < traces.length; i++) {
        expect(traces[i].points.length, lessThanOrEqualTo(128));
        if (i > 0) {
          expect(traces[i].points.first, traces[i - 1].points.last);
        }
      }
    });

    // From (200, 300) to (600, 300) on the 800 by 600 note.
    AiNotationLine line({
      AiLineStyle style = AiLineStyle.solid,
      AiArrow arrow = AiArrow.none,
      double width = 2,
    }) {
      return AiNotationLine(
        from: const AiNotationPoint(0.25, 0.5),
        to: const AiNotationPoint(0.75, 0.5),
        lineStyle: style,
        arrow: arrow,
        ink: 'blue',
        width: width,
      );
    }

    test('a solid line is one stroke between its ends', () {
      expect(_layout(<AiNotationItem>[line()]).single.points, const <InkVector>[
        InkVector(200, 300),
        InkVector(600, 300),
      ]);
    });

    test('a dashed line is evenly cut into dashes along it', () {
      final List<GeneratedInkTrace> dashes = _layout(<AiNotationItem>[
        line(style: AiLineStyle.dashed),
      ]);

      // A dash every 12 px over 400 px, each 60% of that.
      expect(dashes, hasLength(34));
      for (int i = 0; i < dashes.length; i++) {
        final List<InkVector> dash = dashes[i].points;
        expect(dash.first, InkVector(200 + i * 12.0, 300));
        expect(dash.every((InkVector p) => p.y == 300), isTrue);
        expect((dash.last - dash.first).length, lessThanOrEqualTo(7.2 + 1e-9));
      }
      expect(dashes.last.points.last.x, lessThanOrEqualTo(600));
    });

    test('a dotted line is dots along it, and never too many', () {
      final List<GeneratedInkTrace> dots = _layout(<AiNotationItem>[
        line(style: AiLineStyle.dotted),
      ]);
      // A dot every 6 px over 400 px, both ends included.
      expect(dots, hasLength(67));
      expect(dots.every((GeneratedInkTrace d) => d.points.length == 1), isTrue);
      expect(dots.first.points.single, const InkVector(200, 300));
      expect(dots.last.points.single, const InkVector(596, 300));

      // A long, fine dotted line is spaced out to at most 300 dots.
      final List<GeneratedInkTrace> long = layoutNotation(
        AiNotation(
          label: 'L',
          items: <AiNotationItem>[
            const AiNotationLine(
              from: AiNotationPoint(0.01, 0.01),
              to: AiNotationPoint(0.99, 0.99),
              lineStyle: AiLineStyle.dotted,
              arrow: AiArrow.none,
              ink: 'ink',
              width: 1,
            ),
          ],
        ),
        const Size(4000, 3000),
      );
      expect(long.length, lessThanOrEqualTo(301));
    });

    test('arrowheads point the way the line ends, at either end', () {
      final List<GeneratedInkTrace> end = _layout(<AiNotationItem>[
        line(arrow: AiArrow.end),
      ]);
      expect(end, hasLength(2));
      final List<InkVector> head = end.last.points;
      expect(head[1], const InkVector(600, 300));
      // Both wings sit behind the tip, mirrored about the line.
      expect(head[0].x, lessThan(600));
      expect(head[2].x, closeTo(head[0].x, 1e-9));
      expect(head[0].y - 300, closeTo(300 - head[2].y, 1e-9));
      // Sized to the pen: 10 px at most widths, 4 widths for thick pens.
      expect((head[0] - head[1]).length, closeTo(10, 1e-9));
      expect(
        (_layout(<AiNotationItem>[
                  line(arrow: AiArrow.end, width: 5),
                ]).last.points[0] -
                const InkVector(600, 300))
            .length,
        closeTo(20, 1e-9),
      );

      final List<GeneratedInkTrace> start = _layout(<AiNotationItem>[
        line(arrow: AiArrow.start),
      ]);
      expect(start.last.points[1], const InkVector(200, 300));
      expect(start.last.points[0].x, greaterThan(200));

      expect(
        _layout(<AiNotationItem>[line(arrow: AiArrow.both)]),
        hasLength(3),
      );
      // A dotted arrow still has a solid head.
      final List<GeneratedInkTrace> dotted = _layout(<AiNotationItem>[
        line(style: AiLineStyle.dotted, arrow: AiArrow.end),
      ]);
      expect(dotted.last.points, hasLength(3));
      expect(dotted.last.points[1], const InkVector(600, 300));
    });

    test('a curved arrow points along the curve at its end', () {
      final List<GeneratedInkTrace> traces = _layout(<AiNotationItem>[
        AiNotationPath(
          points: const <AiNotationPoint>[
            AiNotationPoint(0.2, 0.5),
            AiNotationPoint(0.4, 0.3),
            AiNotationPoint(0.6, 0.5),
          ],
          segments: const <AiPathSegment>[
            AiPathSegment.curve,
            AiPathSegment.curve,
          ],
          closed: false,
          arrow: AiArrow.end,
          ink: 'red',
          width: 2,
        ),
      ]);
      final List<InkVector> head = traces.last.points;
      expect(head[1], const InkVector(480, 300));
      // The curve comes down into its end, so the wings sit above the tip.
      expect(head[0].y, lessThan(300));
      expect(head[2].y, lessThan(300));
    });

    group('shapes', () {
      // The box from (200, 150) to (600, 450).
      List<InkVector> outline(
        AiShapeKind kind, {
        AiLineStyle style = AiLineStyle.solid,
      }) {
        final List<GeneratedInkTrace> traces = _layout(<AiNotationItem>[
          AiNotationShape(
            shape: kind,
            left: 0.25,
            top: 0.25,
            right: 0.75,
            bottom: 0.75,
            lineStyle: style,
            ink: 'purple',
            width: 3,
          ),
        ]);
        return traces.single.points;
      }

      test('each is closed and stays inside its box', () {
        for (final AiShapeKind kind in AiShapeKind.values) {
          final List<InkVector> points = outline(kind);
          expect(
            (points.last - points.first).length,
            lessThan(1e-9),
            reason: kind.name,
          );
          final Rect bounds = _boundsOf(<GeneratedInkTrace>[
            GeneratedInkTrace(
              style: _layout(<AiNotationItem>[line()]).single.style,
              points: points,
            ),
          ]);
          expect(
            bounds.left,
            greaterThanOrEqualTo(200 - 1e-9),
            reason: kind.name,
          );
          expect(
            bounds.right,
            lessThanOrEqualTo(600 + 1e-9),
            reason: kind.name,
          );
          expect(
            bounds.top,
            greaterThanOrEqualTo(150 - 1e-9),
            reason: kind.name,
          );
          expect(
            bounds.bottom,
            lessThanOrEqualTo(450 + 1e-9),
            reason: kind.name,
          );
        }
      });

      test('each has its own geometry', () {
        // The ellipse fills the box; the circle is as big as fits.
        final Rect ellipse = _boundsOf(<GeneratedInkTrace>[
          GeneratedInkTrace(
            style: _layout(<AiNotationItem>[line()]).single.style,
            points: outline(AiShapeKind.ellipse),
          ),
        ]);
        expect(ellipse.left, closeTo(200, 1e-6));
        expect(ellipse.right, closeTo(600, 1e-6));
        expect(ellipse.top, closeTo(150, 1e-6));
        expect(ellipse.bottom, closeTo(450, 1e-6));
        for (final InkVector p in outline(AiShapeKind.circle)) {
          expect((p - const InkVector(400, 300)).length, closeTo(150, 1e-9));
        }

        expect(outline(AiShapeKind.rectangle), const <InkVector>[
          InkVector(200, 150),
          InkVector(600, 150),
          InkVector(600, 450),
          InkVector(200, 450),
          InkVector(200, 150),
        ]);
        expect(outline(AiShapeKind.triangle).first, const InkVector(400, 150));
        expect(outline(AiShapeKind.triangleDown), const <InkVector>[
          InkVector(400, 450),
          InkVector(200, 150),
          InkVector(600, 150),
          InkVector(400, 450),
        ]);
        expect(outline(AiShapeKind.triangleLeft), const <InkVector>[
          InkVector(200, 300),
          InkVector(600, 450),
          InkVector(600, 150),
          InkVector(200, 300),
        ]);
        expect(outline(AiShapeKind.triangleRight), const <InkVector>[
          InkVector(600, 300),
          InkVector(200, 150),
          InkVector(200, 450),
          InkVector(600, 300),
        ]);
        expect(
          outline(AiShapeKind.rightTriangle),
          contains(const InkVector(200, 450)),
        );
        expect(outline(AiShapeKind.diamond), hasLength(5));
        expect(outline(AiShapeKind.pentagon), hasLength(6));
        expect(outline(AiShapeKind.hexagon), hasLength(7));
        final List<InkVector> star = outline(AiShapeKind.star);
        expect(star, hasLength(11));
        // Its points reach the box; its inner corners are well inside.
        expect(star.first.y, closeTo(150, 1e-9));
        expect((star[1] - const InkVector(400, 300)).length, lessThan(100));
      });

      test('a dashed shape is cut into dashes', () {
        final List<GeneratedInkTrace> traces = _layout(<AiNotationItem>[
          const AiNotationShape(
            shape: AiShapeKind.ellipse,
            left: 0.25,
            top: 0.25,
            right: 0.75,
            bottom: 0.75,
            lineStyle: AiLineStyle.dashed,
            ink: 'purple',
            width: 3,
          ),
        ]);
        expect(traces.length, greaterThan(20));
      });
    });

    test('a full notation is added to the note in one change', () {
      final InkController controller = InkController();
      addTearDown(controller.dispose);
      final List<GeneratedInkTrace> traces = _layout(<AiNotationItem>[
        const AiNotationText(
          text:
              'ABCDEFGHIJKLMNOPQRSTUVWXYZ\nabcdefghijklmnopqrstuvwxyz\n'
              'The vertex is at (1, -4). Roots: x = -1 and x = 3',
          x: 0.05,
          y: 0.05,
          size: 14,
          ink: 'blue',
          width: 2,
        ),
        _graph('x^2 - 2x - 3', xFrom: -2, xTo: 4, axes: true),
      ]);
      // Far more than the 96 strokes a model could send by hand.
      expect(traces.length, greaterThan(96));
      int changes = 0;
      controller.completedStrokesListenable.addListener(() => changes++);

      expect(
        controller.addAiNotation(
          traces: traces,
          expectedRevision: controller.documentRevision,
          surfaceSize: _note,
        ),
        AddNotationResult.added,
      );
      expect(controller.strokes, hasLength(traces.length));
      expect(changes, 1);
      expect(controller.documentRevision, 1);
    });

    test('text running off the paper is refused whole', () {
      final InkController controller = InkController();
      addTearDown(controller.dispose);

      expect(
        controller.addAiNotation(
          traces: _layout(<AiNotationItem>[
            const AiNotationText(
              text: 'This line is far too long for the space left',
              x: 0.8,
              y: 0.5,
              size: 30,
              ink: 'red',
              width: 2,
            ),
          ]),
          expectedRevision: 0,
          surfaceSize: _note,
        ),
        AddNotationResult.invalid,
      );
      expect(controller.strokes, isEmpty);
    });
  });
}
