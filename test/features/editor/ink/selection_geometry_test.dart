import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/ink_selection.dart';
import 'package:greatnote/features/editor/ink/selection_geometry.dart';
import 'package:greatnote/features/editor/ink/selection_transform.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

InkVector _v(double x, double y) => InkVector(x, y);

/// A square lasso from (0, 0) to (100, 100).
LassoRegion _square({double tolerance = 1e-3}) {
  return LassoRegion(<InkVector>[
    _v(0, 0),
    _v(100, 0),
    _v(100, 100),
    _v(0, 100),
  ], tolerance: tolerance);
}

Stroke _stroke(List<InkVector> points, {double width = 2}) {
  return Stroke.fromPoints(
    style: StrokeStyle(ink: InkPalette.ink, width: width),
    points: points,
  );
}

/// A horizontal stroke at height [y].
Stroke _line(double y, {double from = 20, double to = 80, double width = 2}) {
  return _stroke(<InkVector>[_v(from, y), _v(to, y)], width: width);
}

Stroke _dot(double x, double y, {double width = 2}) {
  return _stroke(<InkVector>[_v(x, y)], width: width);
}

List<int> _select(List<Stroke> strokes, LassoRegion region) {
  return selectStrokes(strokes, region).indices;
}

bool _selects(Stroke stroke, [LassoRegion? region]) {
  return _select(<Stroke>[stroke], region ?? _square()).isNotEmpty;
}

void main() {
  group('polyline strokes', () {
    test('a stroke fully inside the lasso is selected', () {
      expect(_selects(_line(50)), isTrue);
    });

    test('a stroke fully outside is rejected by the bounds check', () {
      final StrokeSelectionResult result = selectStrokes(<Stroke>[
        _line(300),
        _line(50, from: 400, to: 500),
      ], _square());

      expect(result.indices, isEmpty);
      // Neither stroke had its points read.
      expect(result.candidates, 0);
    });

    test('bounds that overlap do not select a stroke that stays outside', () {
      // An L around the square's corner: its box covers the square, its ink
      // does not come near.
      final Stroke around = _stroke(<InkVector>[
        _v(-50, -50),
        _v(150, -50),
        _v(150, 150),
      ]);

      final StrokeSelectionResult result = selectStrokes(<Stroke>[
        around,
      ], _square());

      expect(result.candidates, 1);
      expect(result.indices, isEmpty);
    });

    test('a segment crossing the region is selected with both ends out', () {
      final Stroke crossing = _stroke(<InkVector>[_v(-50, 50), _v(150, 50)]);

      expect(_square().containsPoint(crossing.points.first), isFalse);
      expect(_square().containsPoint(crossing.points.last), isFalse);
      expect(_selects(crossing), isTrue);
    });

    test('a wide stroke is selected up to half its width from the edge', () {
      // 20 px wide, so its ink reaches 10 px from the centerline.
      Stroke beside(double y) => _line(y, from: -50, to: 150, width: 20);

      expect(_selects(beside(109)), isTrue);
      expect(_selects(beside(110)), isTrue);
      // Within the 0.001 px tolerance.
      expect(_selects(beside(110.0005)), isTrue);
      // Beyond half the width plus the tolerance.
      expect(_selects(beside(110.002)), isFalse);
      expect(_selects(beside(111)), isFalse);
    });

    test('the tolerance is the one given to the region', () {
      final Stroke beside = _line(110.4, from: -50, to: 150, width: 20);

      expect(_selects(beside, _square()), isFalse);
      expect(_selects(beside, _square(tolerance: 0.5)), isTrue);
    });

    test('a round cap that reaches the region is selected', () {
      // Ends 5 px short of the left edge; the cap is 5 px.
      expect(_selects(_line(50, from: -60, to: -5, width: 10)), isTrue);
      expect(_selects(_line(50, from: -60, to: -5.1, width: 10)), isFalse);
    });

    test('a lasso drawn inside a very wide stroke selects it', () {
      // 400 px wide: the whole square is inside its ink, and its centerline
      // never enters the square.
      final Stroke wide = _stroke(<InkVector>[
        _v(-200, 150),
        _v(300, 150),
      ], width: 400);

      expect(_square().containsPoint(wide.points.first), isFalse);
      expect(_selects(wide), isTrue);
    });

    test('ink on the outline, or through a vertex, is selected', () {
      expect(_selects(_stroke(<InkVector>[_v(100, 20), _v(100, 80)])), isTrue);
      expect(
        _selects(_stroke(<InkVector>[_v(90, 110), _v(110, 90)], width: 0.5)),
        isTrue,
      );
      expect(_selects(_stroke(<InkVector>[_v(-20, 0), _v(120, 0)])), isTrue);
    });

    test('a one-segment stroke and coincident points are handled', () {
      expect(_selects(_stroke(<InkVector>[_v(40, 40), _v(41, 40)])), isTrue);
      expect(
        _selects(_stroke(<InkVector>[_v(40, 40), _v(40, 40), _v(60, 40)])),
        isTrue,
      );
      expect(
        _selects(_stroke(<InkVector>[_v(240, 40), _v(240, 40), _v(260, 40)])),
        isFalse,
      );
    });
  });

  group('dots', () {
    test('a dot is selected when its disc overlaps the region', () {
      expect(_selects(_dot(50, 50, width: 4)), isTrue);
      // Centered outside, 5 px from the edge, with a 5 px radius.
      expect(_selects(_dot(105, 50, width: 10)), isTrue);
      expect(_selects(_dot(105.5, 50, width: 10)), isFalse);
      // 5 px from the corner: a 3-4-5 triangle.
      expect(_selects(_dot(103, 104, width: 10)), isTrue);
      expect(_selects(_dot(103.1, 104, width: 10)), isFalse);
    });

    test('a lasso inside a wide dot selects it', () {
      final LassoRegion small = LassoRegion(<InkVector>[
        _v(40, 40),
        _v(60, 40),
        _v(60, 60),
        _v(40, 60),
      ]);

      // The lasso holds the dot's center.
      expect(_selects(_dot(50, 50, width: 400), small), isTrue);
      // The lasso is inside the disc, away from its center.
      expect(_selects(_dot(0, 0, width: 400), small), isTrue);
      expect(_selects(_dot(0, 0, width: 100), small), isFalse);
    });

    test('a stroke flagged as a dot is tested as its first point', () {
      // Shorter than the dot extent, so it renders as a disc.
      final Stroke speck = _stroke(<InkVector>[
        _v(105, 50),
        _v(105.001, 50),
      ], width: 10);

      expect(speck.isDot, isTrue);
      expect(_selects(speck), isTrue);
    });
  });

  group('even-odd rule', () {
    // The outline goes around the outer square, then around an inner square
    // in the same direction. The middle is wrapped twice.
    final LassoRegion twice = LassoRegion(<InkVector>[
      _v(0, 0),
      _v(100, 0),
      _v(100, 100),
      _v(0, 100),
      _v(0, 0),
      _v(25, 25),
      _v(75, 25),
      _v(75, 75),
      _v(25, 75),
    ]);

    test('an area wrapped twice is outside', () {
      expect(twice.containsPoint(_v(50, 50)), isFalse);
      expect(twice.containsPoint(_v(90, 50)), isTrue);
      expect(twice.containsPoint(_v(50, 10)), isTrue);
      expect(twice.containsPoint(_v(150, 50)), isFalse);
    });

    test('ink in the doubly wrapped area is not selected', () {
      expect(_selects(_dot(50, 50), twice), isFalse);
      expect(_selects(_line(50, from: 40, to: 60), twice), isFalse);
      expect(_selects(_dot(90, 50), twice), isTrue);
      // It still counts once it reaches the inner outline.
      expect(_selects(_line(50, from: 40, to: 80), twice), isTrue);
    });

    test('a figure of eight selects inside both loops', () {
      final LassoRegion eight = LassoRegion(<InkVector>[
        _v(0, 0),
        _v(100, 100),
        _v(100, 0),
        _v(0, 100),
      ]);

      expect(eight.isEmpty, isFalse);
      expect(_selects(_dot(10, 50), eight), isTrue);
      expect(_selects(_dot(90, 50), eight), isTrue);
      expect(_selects(_dot(50, 10), eight), isFalse);
      expect(_selects(_dot(50, 90), eight), isFalse);
    });
  });

  group('degenerate lassos', () {
    test('fewer than three distinct points select nothing', () {
      for (final List<InkVector> points in <List<InkVector>>[
        <InkVector>[],
        <InkVector>[_v(50, 50)],
        <InkVector>[_v(50, 50), _v(50, 50), _v(50, 50)],
        <InkVector>[_v(0, 50), _v(100, 50)],
        <InkVector>[_v(0, 50), _v(100, 50), _v(0, 50)],
      ]) {
        final LassoRegion region = LassoRegion(points);

        expect(region.isEmpty, isTrue, reason: '$points');
        expect(_selects(_line(50), region), isFalse, reason: '$points');
        expect(_selects(_dot(50, 50), region), isFalse, reason: '$points');
      }
    });

    test('a lasso with no area selects nothing, even ink it lies on', () {
      final LassoRegion flat = LassoRegion(<InkVector>[
        _v(0, 50),
        _v(40, 50),
        _v(100, 50),
        _v(60, 50.0005),
      ]);

      expect(flat.isEmpty, isTrue);
      expect(_selects(_line(50), flat), isFalse);
      expect(flat.overlapsBounds(0, 0, 100, 100), isFalse);
    });

    test('duplicate and closing points do not change the result', () {
      final LassoRegion repeated = LassoRegion(<InkVector>[
        _v(0, 0),
        _v(0, 0),
        _v(100, 0),
        _v(100, 0),
        _v(100, 0),
        _v(100, 100),
        _v(0, 100),
        _v(0, 100),
        _v(0, 0),
      ]);
      final List<Stroke> strokes = <Stroke>[
        _line(50),
        _line(300),
        _dot(105, 50, width: 10),
        _line(110.002, from: -50, to: 150, width: 20),
      ];

      expect(repeated.vertexCount, 4);
      expect(_select(strokes, repeated), _select(strokes, _square()));
      expect(_select(strokes, repeated), <int>[0, 2]);
    });

    test('non-finite lasso points are dropped', () {
      final LassoRegion region = LassoRegion(<InkVector>[
        _v(0, 0),
        _v(double.nan, 5),
        _v(100, 0),
        _v(100, 100),
        _v(double.infinity, 0),
        _v(0, 100),
        _v(3, double.negativeInfinity),
      ]);

      expect(region.vertexCount, 4);
      expect(region.left, 0);
      expect(region.right, 100);
      expect(region.bottom.isFinite, isTrue);
      expect(_selects(_line(50), region), isTrue);
      expect(_selects(_line(300), region), isFalse);
    });

    test('an empty page and an empty stroke list select nothing', () {
      expect(_select(const <Stroke>[], _square()), isEmpty);
      expect(_square().overlapsInk(const <InkVector>[], width: 4), isFalse);
    });
  });

  group('result', () {
    final List<Stroke> strokes = <Stroke>[
      _line(300),
      _line(50),
      _stroke(<InkVector>[_v(-50, 20), _v(150, 20)]),
      _dot(500, 500),
      _dot(50, 80),
      // Crosses the lasso several times; still listed once.
      _stroke(<InkVector>[
        _v(-10, 10),
        _v(110, 30),
        _v(-10, 50),
        _v(110, 70),
        _v(-10, 90),
      ]),
    ];

    test('indices are returned once each, in document order', () {
      expect(_select(strokes, _square()), <int>[1, 2, 4, 5]);
    });

    test('selecting changes neither the strokes nor their order', () {
      final List<Stroke> before = List<Stroke>.of(strokes);

      _select(strokes, _square());

      expect(strokes, before);
    });

    test('two runs over the same data give the same result', () {
      final StrokeSelectionResult first = selectStrokes(strokes, _square());
      final StrokeSelectionResult second = selectStrokes(strokes, _square());

      expect(second.indices, first.indices);
      expect(second.candidates, first.candidates);
    });

    test('a lasso that crosses a stroke only between its points', () {
      // A thin sliver across the middle of a long two-point stroke.
      final LassoRegion sliver = LassoRegion(<InkVector>[
        _v(48, -10),
        _v(52, -10),
        _v(52, 10),
        _v(48, 10),
      ]);
      final Stroke long = _stroke(<InkVector>[_v(0, 0), _v(100, 0)]);

      expect(sliver.containsPoint(long.points.first), isFalse);
      expect(_selects(long, sliver), isTrue);
    });
  });

  test('the frame around strokes is the union of their rendered bounds', () {
    final SelectionFrame frame = frameAround(<Stroke>[
      _line(50, width: 4),
      _dot(10, 90, width: 10),
    ]);

    expect(frame.center, _v(43.5, 71.5));
    expect(frame.halfWidth, 38.5);
    expect(frame.halfHeight, 23.5);
    expect(frame.angle, 0);
  });
}
