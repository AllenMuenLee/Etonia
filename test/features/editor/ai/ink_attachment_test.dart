import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/ai/ink_attachment.dart';
import 'package:greatnote/features/editor/ai/notation_layout.dart';
import 'package:greatnote/features/editor/ink/ink_notation.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';

/// A hand-drawn triangle pointing right, in one stroke: (100, 100) down to
/// (100, 220), across to the tip at (200, 160), and back, with a wobble
/// along each side.
List<InkVector> _triangle() {
  const List<InkVector> corners = <InkVector>[
    InkVector(100, 100),
    InkVector(100, 220),
    InkVector(200, 160),
    InkVector(100, 100),
  ];
  final List<InkVector> points = <InkVector>[];
  for (int side = 0; side < 3; side++) {
    final InkVector from = corners[side];
    final InkVector to = corners[side + 1];
    for (int i = 0; i < 20; i++) {
      final InkVector along = from + (to - from) * (i / 20);
      points.add(along + InkVector(i.isEven ? 0.4 : -0.4, 0));
    }
  }
  points.add(corners.last);
  return points;
}

void main() {
  group('simplifyPolyline', () {
    test('keeps a hand-drawn triangle\'s corners and nothing else', () {
      final List<InkVector> outline = simplifyPolyline(_triangle(), 2);
      expect(outline, hasLength(4));
      expect(outline[0], const InkVector(100.4, 100));
      expect((outline[1] - const InkVector(100, 220)).length, lessThan(1));
      expect((outline[2] - const InkVector(200, 160)).length, lessThan(1));
      expect(outline[3], const InkVector(100, 100));
    });

    test('leaves short lines as they are', () {
      const List<InkVector> line = <InkVector>[
        InkVector(0, 0),
        InkVector(5, 5),
      ];
      expect(simplifyPolyline(line, 2), line);
    });
  });

  test('inkOutlines keeps ink reaching the region, longest first', () {
    final List<List<InkVector>> outlines = inkOutlines(
      <List<InkVector>>[
        const <InkVector>[InkVector(120, 230), InkVector(150, 230)],
        _triangle(),
        const <InkVector>[InkVector(500, 500), InkVector(600, 500)],
        const <InkVector>[InkVector(130, 130)],
      ],
      const Rect.fromLTRB(90, 90, 210, 240),
      tolerance: 2,
      maxPoints: 100,
    );
    expect(outlines, hasLength(2));
    expect(outlines[0], hasLength(4));
    expect(outlines[1], const <InkVector>[
      InkVector(120, 230),
      InkVector(150, 230),
    ]);

    expect(
      inkOutlines(
        <List<InkVector>>[_triangle()],
        const Rect.fromLTRB(90, 90, 210, 240),
        tolerance: 2,
        maxPoints: 3,
      ),
      isEmpty,
    );
  });

  group('InkSnapper', () {
    final InkSnapper snapper = InkSnapper(<List<InkVector>>[
      const <InkVector>[
        InkVector(100, 100),
        InkVector(100, 220),
        InkVector(200, 160),
        InkVector(100, 100),
      ],
      const <InkVector>[InkVector(300, 100), InkVector(400, 100)],
    ], reach: 16);

    test('moves a point that nearly reaches ink onto it', () {
      // Just short of the triangle's left side, and just past it.
      expect(snapper.snap(const InkVector(90, 140)), const InkVector(100, 140));
      expect(
        snapper.snap(const InkVector(108, 180)),
        const InkVector(100, 180),
      );
    });

    test('prefers a nearby end of a stroke, so lines join end to end', () {
      expect(
        snapper.snap(const InkVector(296, 104)),
        const InkVector(300, 100),
      );
    });

    test('leaves a point out of reach alone', () {
      expect(snapper.snap(const InkVector(60, 140)), const InkVector(60, 140));
    });

    test('snapEnds moves only the ends, and never to no length', () {
      expect(
        snapper.snapEnds(const <InkVector>[
          InkVector(40, 140),
          InkVector(60, 140),
          InkVector(92, 140),
        ]),
        const <InkVector>[
          InkVector(40, 140),
          InkVector(60, 140),
          InkVector(100, 140),
        ],
      );
      // Both ends would land on the same point of the side.
      final List<InkVector> stub = <InkVector>[
        const InkVector(95, 150),
        const InkVector(96, 150),
      ];
      final List<InkVector> snapped = snapper.snapEnds(stub);
      expect(snapped.first, isNot(snapped.last));
    });
  });

  test('layout joins a lead to the ink, and never moves text', () {
    final InkSnapper snapper = InkSnapper(<List<InkVector>>[
      const <InkVector>[InkVector(100, 100), InkVector(100, 220)],
    ], reach: 16);
    const Size size = Size(400, 400);
    final AiNotation notation = AiNotation(
      label: 'Op amp inputs',
      items: <AiNotationItem>[
        // From x = 0.15 to 0.24: 4 logical units short of the side.
        const AiNotationLine(
          ink: 'ink',
          width: 2,
          from: AiNotationPoint(0.15, 0.35),
          to: AiNotationPoint(0.24, 0.35),
          lineStyle: AiLineStyle.solid,
          arrow: AiArrow.none,
        ),
        const AiNotationText(
          ink: 'ink',
          width: 2,
          text: '-',
          x: 0.24,
          y: 0.4,
          size: 18,
        ),
      ],
    );

    final List<GeneratedInkTrace> snapped = layoutNotation(
      notation,
      size,
      snapper: snapper,
    );
    expect(snapped.first.points, const <InkVector>[
      InkVector(60, 140),
      InkVector(100, 140),
    ]);
    final List<GeneratedInkTrace> plain = layoutNotation(notation, size);
    expect(plain.first.points.last, const InkVector(96, 140));
    for (int i = 1; i < plain.length; i++) {
      expect(snapped[i].points, plain[i].points);
    }
  });
}
