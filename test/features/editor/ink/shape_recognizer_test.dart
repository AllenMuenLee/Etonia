import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/shape_recognizer.dart';

/// Points every [spacing] px along the polyline through [vertices], each
/// nudged by up to [noise] px, deterministically.
List<InkVector> traced(
  List<InkVector> vertices, {
  double spacing = 3,
  double noise = 0.8,
  int seed = 1,
}) {
  final math.Random random = math.Random(seed);
  final List<InkVector> out = <InkVector>[];
  for (int i = 1; i < vertices.length; i++) {
    final InkVector a = vertices[i - 1];
    final InkVector b = vertices[i];
    final int steps = math.max(1, ((b - a).length / spacing).ceil());
    for (int s = 0; s < steps; s++) {
      out.add(a + (b - a) * (s / steps));
    }
  }
  out.add(vertices.last);
  return <InkVector>[
    for (final InkVector p in out)
      p +
          InkVector(
            (random.nextDouble() * 2 - 1) * noise,
            (random.nextDouble() * 2 - 1) * noise,
          ),
  ];
}

/// A curve sampled at [count] parameter steps.
List<InkVector> curve(
  InkVector Function(double t) at, {
  int count = 160,
  double noise = 0.8,
  int seed = 2,
}) {
  final math.Random random = math.Random(seed);
  return <InkVector>[
    for (int i = 0; i <= count; i++)
      at(i / count) +
          InkVector(
            (random.nextDouble() * 2 - 1) * noise,
            (random.nextDouble() * 2 - 1) * noise,
          ),
  ];
}

List<InkVector> regular(
  int n,
  double radius, {
  InkVector center = const InkVector(300, 300),
  double phase = -math.pi / 2,
  int step = 1,
}) {
  return <InkVector>[
    for (int i = 0; i <= n; i++)
      center +
          InkVector(
                math.cos(phase + 2 * math.pi * step * i / n),
                math.sin(phase + 2 * math.pi * step * i / n),
              ) *
              radius,
  ];
}

const ShapeRecognizer recognizer = ShapeRecognizer();

RecognizedShape? recognize(List<InkVector> points) {
  return recognizer.recognize(points);
}

void expectClosed(RecognizedShape shape) {
  expect(shape.points.first.x, closeTo(shape.points.last.x, 1e-9));
  expect(shape.points.first.y, closeTo(shape.points.last.y, 1e-9));
}

void main() {
  group('recognizes', () {
    test('a line, snapped horizontal', () {
      final RecognizedShape? shape = recognize(
        traced(const <InkVector>[InkVector(100, 200), InkVector(400, 212)]),
      );
      expect(shape?.kind, ShapeKind.line);
      expect(shape!.points, hasLength(2));
      expect(shape.points.first.y, closeTo(shape.points.last.y, 1e-9));
    });

    test('a diagonal line, not snapped', () {
      final RecognizedShape? shape = recognize(
        traced(const <InkVector>[InkVector(100, 100), InkVector(300, 300)]),
      );
      expect(shape?.kind, ShapeKind.line);
      final InkVector d = shape!.points.last - shape.points.first;
      expect(d.x, closeTo(d.y, 3));
    });

    test('an arrow', () {
      final RecognizedShape? shape = recognize(
        traced(const <InkVector>[
          InkVector(100, 300),
          InkVector(350, 304),
          InkVector(315, 280),
          InkVector(350, 304),
          InkVector(318, 330),
        ]),
      );
      expect(shape?.kind, ShapeKind.arrow);
      expect(shape!.points, hasLength(5));
      // Shaft snapped horizontal; barbs symmetric about it.
      expect(shape.points[0].y, closeTo(shape.points[1].y, 1e-9));
      final double tipY = shape.points[1].y;
      expect(shape.points[2].y - tipY, closeTo(tipY - shape.points[4].y, 1e-6));
    });

    test('an arrow with one barb drawn', () {
      final RecognizedShape? shape = recognize(
        traced(const <InkVector>[
          InkVector(100, 100),
          InkVector(300, 300),
          InkVector(300, 255),
        ]),
      );
      expect(shape?.kind, ShapeKind.arrow);
    });

    test('a circle, every point on the fitted radius', () {
      final RecognizedShape? shape = recognize(
        curve(
          (double t) =>
              const InkVector(300, 300) +
              InkVector(
                    math.cos(0.4 + 2 * math.pi * 1.04 * t),
                    math.sin(0.4 + 2 * math.pi * 1.04 * t),
                  ) *
                  (90 + 3 * math.sin(5 * t)),
        ),
      );
      expect(shape?.kind, ShapeKind.circle);
      expectClosed(shape!);
      final InkVector center =
          shape.points
              .take(shape.points.length - 1)
              .fold(InkVector.zero, (InkVector a, InkVector b) => a + b) *
          (1 / (shape.points.length - 1));
      final double r = (shape.points.first - center).length;
      for (final InkVector p in shape.points) {
        expect((p - center).length, closeTo(r, 1e-6));
      }
      expect(r, closeTo(91, 4));
    });

    test('an ellipse, its axis snapped', () {
      final RecognizedShape? shape = recognize(
        curve((double t) {
          const double tilt = 0.06;
          final double a = 2 * math.pi * t;
          final InkVector local = InkVector(
            150 * math.cos(a),
            70 * math.sin(a),
          );
          return const InkVector(300, 300) +
              InkVector(
                local.x * math.cos(tilt) - local.y * math.sin(tilt),
                local.x * math.sin(tilt) + local.y * math.cos(tilt),
              );
        }),
      );
      expect(shape?.kind, ShapeKind.ellipse);
      expectClosed(shape!);
      final double top = shape.points
          .map((InkVector p) => p.y)
          .reduce(math.min);
      final double bottom = shape.points
          .map((InkVector p) => p.y)
          .reduce(math.max);
      expect(bottom - top, closeTo(140, 8));
    });

    test('an equilateral triangle', () {
      final RecognizedShape? shape = recognize(traced(regular(3, 120)));
      expect(shape?.kind, ShapeKind.triangle);
      expect(shape!.sides, 3);
      expectClosed(shape);
    });

    test('an irregular triangle', () {
      final RecognizedShape? shape = recognize(
        traced(const <InkVector>[
          InkVector(100, 400),
          InkVector(420, 380),
          InkVector(180, 160),
          InkVector(100, 400),
        ]),
      );
      expect(shape?.kind, ShapeKind.triangle);
    });

    test('a rectangle, axis-aligned', () {
      final RecognizedShape? shape = recognize(
        traced(const <InkVector>[
          InkVector(100, 100),
          InkVector(400, 106),
          InkVector(396, 260),
          InkVector(103, 255),
          InkVector(100, 100),
        ]),
      );
      expect(shape?.kind, ShapeKind.rectangle);
      expectClosed(shape!);
      for (int i = 0; i < 4; i++) {
        final InkVector edge = shape.points[i + 1] - shape.points[i];
        expect(math.min(edge.x.abs(), edge.y.abs()), lessThan(1e-9));
      }
    });

    test('a square', () {
      final RecognizedShape? shape = recognize(
        traced(const <InkVector>[
          InkVector(150, 100),
          InkVector(300, 104),
          InkVector(298, 252),
          InkVector(149, 246),
          InkVector(150, 100),
        ]),
      );
      expect(shape?.kind, ShapeKind.square);
      final InkVector a = shape!.points[1] - shape.points[0];
      final InkVector b = shape.points[2] - shape.points[1];
      expect(a.length, closeTo(b.length, 1e-6));
    });

    test('a rhombus', () {
      final RecognizedShape? shape = recognize(
        traced(const <InkVector>[
          InkVector(300, 100),
          InkVector(380, 300),
          InkVector(300, 500),
          InkVector(220, 300),
          InkVector(300, 100),
        ]),
      );
      expect(shape?.kind, ShapeKind.rhombus);
    });

    test('a regular pentagon and hexagon', () {
      final RecognizedShape? pentagon = recognize(traced(regular(5, 140)));
      expect(pentagon?.kind, ShapeKind.regularPolygon);
      expect(pentagon!.sides, 5);
      final RecognizedShape? hexagon = recognize(
        traced(regular(6, 140, phase: 0.05)),
      );
      expect(hexagon?.kind, ShapeKind.regularPolygon);
      expect(hexagon!.sides, 6);
    });

    test('a star outline', () {
      final List<InkVector> vertices = <InkVector>[
        for (int i = 0; i <= 10; i++)
          const InkVector(300, 300) +
              InkVector(
                    math.cos(-math.pi / 2 + math.pi * i / 5),
                    math.sin(-math.pi / 2 + math.pi * i / 5),
                  ) *
                  (i.isEven ? 150.0 : 60.0),
      ];
      final RecognizedShape? shape = recognize(traced(vertices));
      expect(shape?.kind, ShapeKind.star);
      expect(shape!.sides, 5);
    });

    test('a pentagram', () {
      final RecognizedShape? shape = recognize(
        traced(regular(5, 150, step: 2)),
      );
      expect(shape?.kind, ShapeKind.star);
      expect(shape!.points, hasLength(6));
    });

    test('an irregular, concave polygon', () {
      final RecognizedShape? shape = recognize(
        traced(const <InkVector>[
          InkVector(100, 100),
          InkVector(300, 100),
          InkVector(300, 200),
          InkVector(200, 200),
          InkVector(200, 350),
          InkVector(100, 350),
          InkVector(100, 100),
        ]),
      );
      expect(shape?.kind, ShapeKind.polygon);
      expect(shape!.sides, 6);
    });

    test('an open zig-zag', () {
      final RecognizedShape? shape = recognize(
        traced(const <InkVector>[
          InkVector(100, 300),
          InkVector(180, 150),
          InkVector(260, 300),
          InkVector(340, 150),
        ]),
      );
      expect(shape?.kind, ShapeKind.polyline);
      expect(shape!.points, hasLength(4));
    });

    test('an arc', () {
      final RecognizedShape? shape = recognize(
        curve(
          (double t) =>
              const InkVector(300, 300) +
              InkVector(
                    math.cos(math.pi + 2.2 * t),
                    math.sin(math.pi + 2.2 * t),
                  ) *
                  150,
        ),
      );
      expect(shape?.kind, ShapeKind.arc);
    });

    test('a sine wave', () {
      final List<InkVector> points = curve(
        (double t) => InkVector(
          100 + 400 * t,
          300 + 50 * math.sin(2 * math.pi * 2.5 * t),
        ),
        count: 240,
      );
      final RecognizedShape? shape = recognize(points);
      expect(shape?.kind, ShapeKind.sineWave);
      expect(shape!.points.first, points.first);
      expect(shape.points.last, points.last);
    });

    test('a spiral', () {
      final RecognizedShape? shape = recognize(
        curve((double t) {
          final double theta = 2 * math.pi * 2.5 * t;
          return const InkVector(300, 300) +
              InkVector(math.cos(theta), math.sin(theta)) * (8 + 18 * theta);
        }, count: 300),
      );
      expect(shape?.kind, ShapeKind.spiral);
    });
  });

  group('rejects', () {
    test('a scribble', () {
      final math.Random random = math.Random(7);
      InkVector at = const InkVector(300, 300);
      final List<InkVector> points = <InkVector>[at];
      for (int i = 0; i < 120; i++) {
        at += InkVector(
          (random.nextDouble() * 2 - 1) * 25,
          (random.nextDouble() * 2 - 1) * 25,
        );
        points.add(at);
      }
      expect(recognize(points), isNull);
    });

    test('cursive loops', () {
      expect(
        recognize(
          curve(
            (double t) => InkVector(
              100 + 300 * t + 30 * math.cos(2 * math.pi * 4 * t),
              300 - 40 * math.sin(2 * math.pi * 4 * t).abs(),
            ),
            count: 300,
          ),
        ),
        isNull,
      );
    });

    test('a dot and repeated points', () {
      expect(recognize(const <InkVector>[InkVector(1, 1)]), isNull);
      expect(
        recognize(List<InkVector>.filled(20, const InkVector(5, 5))),
        isNull,
      );
      expect(recognize(const <InkVector>[]), isNull);
    });
  });

  test('does not depend on sample density', () {
    const List<InkVector> square = <InkVector>[
      InkVector(150, 100),
      InkVector(300, 104),
      InkVector(298, 252),
      InkVector(149, 246),
      InkVector(150, 100),
    ];
    final RecognizedShape? sparse = recognize(
      traced(square, spacing: 9, noise: 0),
    );
    final RecognizedShape? dense = recognize(
      traced(square, spacing: 1, noise: 0),
    );
    expect(sparse?.kind, ShapeKind.square);
    expect(dense?.kind, ShapeKind.square);
    for (int i = 0; i < sparse!.points.length; i++) {
      expect((sparse.points[i] - dense!.points[i]).length, lessThan(3));
    }
  });

  test('degenerate input gives no shape or a finite one, the same twice', () {
    final List<List<InkVector>> inputs = <List<InkVector>>[
      const <InkVector>[InkVector(0, 0), InkVector(10, 0)],
      const <InkVector>[InkVector(0, 0), InkVector(10, 0), InkVector(0, 0)],
      const <InkVector>[
        InkVector(0, 0),
        InkVector(double.nan, 3),
        InkVector(50, 0),
      ],
      <InkVector>[for (int i = 0; i < 50; i++) InkVector(i * 2.0, 0)],
      <InkVector>[
        for (int i = 0; i < 50; i++) InkVector(i.isEven ? 0 : 1e-9, 0),
      ],
    ];
    for (final List<InkVector> input in inputs) {
      final RecognizedShape? first = recognize(input);
      final RecognizedShape? second = recognize(input);
      expect(first?.kind, second?.kind);
      if (first != null) {
        expect(first.points.every((InkVector p) => p.isFinite), isTrue);
        expect(first.points, second!.points);
      }
    }
  });
}
