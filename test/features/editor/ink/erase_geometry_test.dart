import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/erase_geometry.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';

/// How far a computed cut point may be from its exact position.
const double _tolerance = 1e-9;

const InkVector _origin = InkVector(0, 0);

InkVector _v(double x, double y) => InkVector(x, y);

/// A horizontal line along y = 0 with a vertex every [step] pixels.
List<InkVector> _line(double from, double to, {double step = 10}) {
  return <InkVector>[
    for (double x = from; x < to; x += step) _v(x, 0),
    _v(to, 0),
  ];
}

double _length(List<InkVector> points) {
  double length = 0;
  for (int i = 0; i < points.length - 1; i++) {
    length += (points[i + 1] - points[i]).length;
  }
  return length;
}

void _expectFinite(List<List<InkVector>> pieces) {
  for (final List<InkVector> piece in pieces) {
    for (final InkVector point in piece) {
      expect(point.isFinite, isTrue, reason: '$point');
    }
  }
}

void main() {
  group('distances', () {
    test('point to segment: interior, beyond an end, zero-length', () {
      expect(
        EraseGeometry.pointSegmentDistance(_v(5, 3), _origin, _v(10, 0)),
        closeTo(3, _tolerance),
      );
      expect(
        EraseGeometry.pointSegmentDistance(_v(13, 4), _origin, _v(10, 0)),
        closeTo(5, _tolerance),
      );
      expect(
        EraseGeometry.pointSegmentDistance(_v(3, 4), _origin, _origin),
        closeTo(5, _tolerance),
      );
    });

    test('segment to segment: crossing, apart, parallel, degenerate', () {
      expect(
        EraseGeometry.segmentSegmentDistance(
          _v(0, -5),
          _v(0, 5),
          _v(-5, 0),
          _v(5, 0),
        ),
        0,
      );
      // A T shape: one end stops 2 px short of the other segment.
      expect(
        EraseGeometry.segmentSegmentDistance(
          _v(0, 2),
          _v(0, 9),
          _v(-5, 0),
          _v(5, 0),
        ),
        closeTo(2, _tolerance),
      );
      expect(
        EraseGeometry.segmentSegmentDistance(
          _v(0, 0),
          _v(10, 0),
          _v(3, 4),
          _v(20, 4),
        ),
        closeTo(4, _tolerance),
      );
      // Collinear and overlapping.
      expect(
        EraseGeometry.segmentSegmentDistance(
          _v(0, 0),
          _v(10, 0),
          _v(5, 0),
          _v(20, 0),
        ),
        0,
      );
      expect(
        EraseGeometry.segmentSegmentDistance(
          _v(3, 4),
          _v(3, 4),
          _origin,
          _origin,
        ),
        closeTo(5, _tolerance),
      );
    });
  });

  group('area erase', () {
    test('crossing the middle leaves two pieces cut at the radius', () {
      final List<InkVector> stroke = _line(0, 100);
      final InkVector from = _v(52, -30);
      final InkVector to = _v(52, 30);
      const double radius = 7.5;

      final List<List<InkVector>> pieces = EraseGeometry.cutPolyline(
        stroke,
        from,
        to,
        radius,
      )!;

      expect(pieces.length, 2);
      expect(pieces[0].first, _v(0, 0));
      expect(pieces[1].last, _v(100, 0));
      // The inner ends lie exactly `radius` from the eraser's path.
      expect(pieces[0].last.x, closeTo(44.5, _tolerance));
      expect(pieces[1].first.x, closeTo(59.5, _tolerance));
      for (final InkVector end in <InkVector>[
        pieces[0].last,
        pieces[1].first,
      ]) {
        expect(end.y, 0);
        expect(
          EraseGeometry.pointSegmentDistance(end, from, to),
          closeTo(radius, _tolerance),
        );
      }
      // Original vertices are kept untouched on either side of the cut.
      expect(pieces[0], <InkVector>[...stroke.sublist(0, 5), pieces[0].last]);
      expect(pieces[1], <InkVector>[pieces[1].first, ...stroke.sublist(6)]);
    });

    test('an eraser over one end leaves one shortened piece', () {
      final List<List<InkVector>> pieces = EraseGeometry.cutPolyline(
        _line(0, 100),
        _v(100, 0),
        _v(100, 0),
        12,
      )!;

      expect(pieces.length, 1);
      expect(pieces.single.first, _v(0, 0));
      expect(pieces.single.last.x, closeTo(88, _tolerance));
      expect(_length(pieces.single), closeTo(88, _tolerance));
    });

    test('an eraser covering the whole stroke leaves nothing', () {
      // Once as a disc that contains the stroke, once as a sweep along it.
      expect(
        EraseGeometry.cutPolyline(_line(40, 60), _v(50, 0), _v(50, 0), 15),
        isEmpty,
      );
      expect(
        EraseGeometry.cutPolyline(_line(0, 100), _v(-5, 1), _v(105, 1), 4),
        isEmpty,
      );
    });

    test('a miss leaves the stroke untouched', () {
      final List<InkVector> stroke = _line(0, 100);

      // Null means "unchanged": the caller keeps the same stroke instance.
      expect(
        EraseGeometry.cutPolyline(stroke, _v(50, 10.01), _v(50, 40), 10),
        isNull,
      );
      expect(
        EraseGeometry.cutPolyline(stroke, _v(-30, -20), _v(130, -10.5), 10),
        isNull,
      );
      // Inside the stroke's bounding box, but not near the stroke itself.
      final List<InkVector> corner = <InkVector>[
        _v(0, 0),
        _v(100, 0),
        _v(100, 100),
      ];
      expect(
        EraseGeometry.cutPolyline(corner, _v(40, 60), _v(40, 60), 10),
        isNull,
      );
    });

    test('a fast move cuts ink that lies between its two samples', () {
      final InkVector from = _v(50, -200);
      final InkVector to = _v(50, 300);
      final List<InkVector> stroke = _line(0, 100);
      // Neither sample position is anywhere near the stroke.
      expect(EraseGeometry.cutPolyline(stroke, from, from, 5), isNull);
      expect(EraseGeometry.cutPolyline(stroke, to, to, 5), isNull);

      final List<List<InkVector>> pieces = EraseGeometry.cutPolyline(
        stroke,
        from,
        to,
        5,
      )!;

      expect(pieces.length, 2);
      expect(pieces[0].last.x, closeTo(45, _tolerance));
      expect(pieces[1].first.x, closeTo(55, _tolerance));
    });

    test('a diagonal move cuts along the capsule, not its bounding box', () {
      final InkVector from = _v(40, -10);
      final InkVector to = _v(60, 10);
      const double radius = 5;

      final List<List<InkVector>> pieces = EraseGeometry.cutPolyline(
        _line(0, 100),
        from,
        to,
        radius,
      )!;

      expect(pieces.length, 2);
      const double half = radius * math.sqrt2;
      expect(pieces[0].last.x, closeTo(50 - half, _tolerance));
      expect(pieces[1].first.x, closeTo(50 + half, _tolerance));
    });

    test('a stroke crossed twice yields three pieces in original order', () {
      // A "U": down the left side, across the bottom, up the right side.
      final List<InkVector> stroke = <InkVector>[
        for (double y = 0; y < 100; y += 10) _v(0, y),
        for (double x = 0; x < 80; x += 10) _v(x, 100),
        for (double y = 100; y >= 0; y -= 10) _v(80, y),
      ];

      final List<List<InkVector>> pieces = EraseGeometry.cutPolyline(
        stroke,
        _v(-40, 43),
        _v(120, 43),
        6,
      )!;

      expect(pieces.length, 3);
      expect(pieces[0].first, stroke.first);
      expect(pieces[0].last, _v(0, 37));
      expect(pieces[1].first, _v(0, 49));
      expect(pieces[1].last, _v(80, 49));
      expect(pieces[2].first, _v(80, 37));
      expect(pieces[2].last, stroke.last);
      expect(pieces[1], contains(_v(40, 100)));
    });

    test('cut points are computed on the segment, not snapped to vertices', () {
      // Two points only: the nearest vertices are 500 px from the cut.
      final List<InkVector> stroke = <InkVector>[_v(0, 0), _v(1000, 0)];

      final List<List<InkVector>> pieces = EraseGeometry.cutPolyline(
        stroke,
        _v(437, 0),
        _v(437, 0),
        20,
      )!;

      expect(pieces.length, 2);
      expect(pieces[0].length, 2);
      expect(pieces[1].length, 2);
      expect(pieces[0].first, _v(0, 0));
      expect(pieces[0].last.x, closeTo(417, _tolerance));
      expect(pieces[1].first.x, closeTo(457, _tolerance));
      expect(pieces[1].last, _v(1000, 0));
    });

    test('a sloped single segment is cut where it meets the disc', () {
      final InkVector center = _v(30, 40);
      const double radius = 10;

      final List<List<InkVector>> pieces = EraseGeometry.cutPolyline(
        <InkVector>[_v(0, 0), _v(60, 80)],
        center,
        center,
        radius,
      )!;

      expect(pieces.length, 2);
      // Along a 3-4-5 direction, 10 px either side of the center.
      expect(pieces[0].last.x, closeTo(24, _tolerance));
      expect(pieces[0].last.y, closeTo(32, _tolerance));
      expect(pieces[1].first.x, closeTo(36, _tolerance));
      expect(pieces[1].first.y, closeTo(48, _tolerance));
    });

    test('pieces shorter than the minimum length are discarded', () {
      final List<InkVector> stroke = _line(0, 100);
      final InkVector at = _v(8, 0);

      // The eraser leaves [0, 3] and [13, 100].
      expect(
        EraseGeometry.cutPolyline(stroke, at, at, 5, minPieceLength: 2)!.length,
        2,
      );
      final List<List<InkVector>> pieces = EraseGeometry.cutPolyline(
        stroke,
        at,
        at,
        5,
        minPieceLength: 3.5,
      )!;
      expect(pieces.length, 1);
      expect(pieces.single.first.x, closeTo(13, _tolerance));
      // Both leftovers too short: the stroke is gone.
      expect(
        EraseGeometry.cutPolyline(
          <InkVector>[_v(0, 0), _v(16, 0)],
          at,
          at,
          5,
          minPieceLength: 3.5,
        ),
        isEmpty,
      );
    });

    test('erasing twice at the same place changes nothing', () {
      final List<InkVector> wavy = <InkVector>[
        for (int i = 0; i <= 200; i++) _v(i * 1.7, 30 * math.sin(i / 9)),
      ];
      for (final (InkVector from, InkVector to, double radius)
          in <(InkVector, InkVector, double)>[
            (_v(52, -30), _v(52, 30), 7.5),
            (_v(100, 5), _v(100, 5), 12),
            (_v(20, -40), _v(310, 35), 3.3),
            (_v(0, 0), _v(340, 0), 9),
          ]) {
        final List<List<InkVector>> pieces = EraseGeometry.cutPolyline(
          wavy,
          from,
          to,
          radius,
        )!;
        expect(pieces, isNotEmpty);
        for (final List<InkVector> piece in pieces) {
          expect(
            EraseGeometry.cutPolyline(piece, from, to, radius),
            isNull,
            reason: 'eraser $from -> $to',
          );
        }
      }
    });

    test('repeated erasing adds no duplicate or degenerate vertices', () {
      List<List<InkVector>> pieces = <List<InkVector>>[
        <InkVector>[_v(0, 0), _v(1000, 0)],
      ];
      // Overlapping passes, as a real gesture makes them.
      for (double x = 100; x <= 400; x += 0.75) {
        final InkVector from = _v(x, -3);
        final InkVector to = _v(x + 0.75, 3);
        pieces = <List<InkVector>>[
          for (final List<InkVector> piece in pieces)
            ...EraseGeometry.cutPolyline(piece, from, to, 10) ??
                <List<InkVector>>[piece],
        ];
      }

      expect(pieces.length, 2);
      // One straight segment each: nothing but the two ends.
      expect(pieces[0].length, 2);
      expect(pieces[1].length, 2);
      for (final List<InkVector> piece in pieces) {
        expect(
          (piece.last - piece.first).length,
          greaterThan(EraseGeometry.cutTolerance),
        );
      }
    });

    test('degenerate input stays finite and never throws', () {
      final List<InkVector> stroke = <InkVector>[
        _v(0, 0),
        _v(0, 0),
        _v(1e-7, 0),
        _v(10, 0),
        _v(10, 0),
        _v(10, 1e-5),
        _v(20, 0),
      ];
      for (final (InkVector from, InkVector to, double radius)
          in <(InkVector, InkVector, double)>[
            (_v(5, 0), _v(5, 0), 2),
            (_v(5, 0), _v(5, 0), 0),
            (_v(0, 0), _v(0, 0), 1e-9),
            (_v(10, 0), _v(10, 0), 1e-6),
            (_v(-1e6, -1e6), _v(1e6, 1e6), 4),
            (_v(0, 0), _v(20, 0), 1),
            (_v(0, 1), _v(20, 1), 1),
          ]) {
        final List<List<InkVector>>? pieces = EraseGeometry.cutPolyline(
          stroke,
          from,
          to,
          radius,
          minPieceLength: 0.01,
        );
        _expectFinite(pieces ?? const <List<InkVector>>[]);
        for (final List<InkVector> piece in pieces ?? const []) {
          expect(piece.length, greaterThanOrEqualTo(2));
        }
        expect(
          EraseGeometry.polylineTouchesCapsule(stroke, from, to, radius),
          anyOf(isTrue, isFalse),
        );
      }
      // Fewer than two points cannot be cut.
      expect(
        EraseGeometry.cutPolyline(const <InkVector>[], _origin, _origin, 5),
        isNull,
      );
      expect(
        EraseGeometry.cutPolyline(<InkVector>[_origin], _origin, _origin, 5),
        isNull,
      );
      expect(
        EraseGeometry.polylineTouchesCapsule(
          const <InkVector>[],
          _origin,
          _origin,
          5,
        ),
        isFalse,
      );
    });

    test('identical input produces identical output', () {
      final math.Random random = math.Random(7);
      final List<InkVector> stroke = <InkVector>[
        for (int i = 0; i < 300; i++)
          _v(i * 2 + random.nextDouble(), 40 * math.sin(i / 11)),
      ];
      List<List<InkVector>>? run() {
        return EraseGeometry.cutPolyline(
          stroke,
          _v(10, -50),
          _v(590, 45),
          6,
          minPieceLength: 0.01,
        );
      }

      final List<List<InkVector>> first = run()!;
      expect(first.length, greaterThan(2));
      expect(run(), first);
    });
  });

  group('dots', () {
    test('are hit by the distance rule alone', () {
      final InkVector dot = _v(50, 50);

      expect(
        EraseGeometry.pointTouchesCapsule(dot, _v(50, 40), _v(50, 40), 10.01),
        isTrue,
      );
      expect(
        EraseGeometry.pointTouchesCapsule(dot, _v(50, 40), _v(50, 40), 9.99),
        isFalse,
      );
      // A sweep that passes beside the dot, far from both samples.
      expect(
        EraseGeometry.pointTouchesCapsule(dot, _v(0, 47), _v(200, 47), 3.01),
        isTrue,
      );
      expect(
        EraseGeometry.pointTouchesCapsule(dot, _v(0, 47), _v(200, 47), 2.99),
        isFalse,
      );
    });
  });

  group('stroke-mode hit test', () {
    const double hitRadius = 6;

    for (final double width in <double>[1, 20]) {
      test('honors rHit + w / 2 for a $width px stroke', () {
        final List<InkVector> stroke = _line(0, 100);
        final double reach = hitRadius + width / 2;

        // Beside the stroke.
        for (final (double offset, bool hit) in <(double, bool)>[
          (reach - 0.01, true),
          (reach + 0.01, false),
        ]) {
          expect(
            EraseGeometry.polylineTouchesCapsule(
              stroke,
              _v(50, offset),
              _v(50, offset),
              reach,
            ),
            hit,
            reason: 'beside, $offset px away',
          );
          // Past its end, where only the end vertex is near.
          expect(
            EraseGeometry.polylineTouchesCapsule(
              stroke,
              _v(100 + offset, 0),
              _v(100 + offset, 0),
              reach,
            ),
            hit,
            reason: 'past the end, $offset px away',
          );
          // A sweep parallel to the stroke.
          expect(
            EraseGeometry.polylineTouchesCapsule(
              stroke,
              _v(20, -offset),
              _v(80, -offset),
              reach,
            ),
            hit,
            reason: 'parallel, $offset px away',
          );
        }
      });
    }

    test('a sweep that crosses the stroke hits it', () {
      expect(
        EraseGeometry.polylineTouchesCapsule(
          _line(0, 100),
          _v(50, -300),
          _v(50, 300),
          hitRadius,
        ),
        isTrue,
      );
    });
  });
}
