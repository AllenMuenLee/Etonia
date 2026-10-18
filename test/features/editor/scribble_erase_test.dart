import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/scribble_erase.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

const StrokeStyle _style = StrokeStyle(ink: InkPalette.ink, width: 3);

/// A short word-like stroke from (x, y) to (x + 60, y + 10).
Stroke _word(double x, double y) => Stroke.fromPoints(
  style: _style,
  points: <InkVector>[
    InkVector(x, y),
    InkVector(x + 20, y + 10),
    InkVector(x + 40, y),
    InkVector(x + 60, y + 10),
  ],
);

/// Points zigzagging left and right [swings] times over the box from
/// (left, top) to (right, bottom), moving down as they go.
List<InkVector> _zigzag(
  double left,
  double top,
  double right,
  double bottom, {
  int swings = 6,
}) {
  final List<InkVector> points = <InkVector>[];
  for (int i = 0; i <= swings; i++) {
    final double y = top + (bottom - top) * i / swings;
    final double x = i.isEven ? left : right;
    // Several samples along each swing, as a pen would report.
    if (points.isNotEmpty) {
      final InkVector from = points.last;
      for (int j = 1; j < 8; j++) {
        points.add(from + (InkVector(x, y) - from) * (j / 8));
      }
    }
    points.add(InkVector(x, y));
  }
  return points;
}

/// Draws [points] as one stroke through [controller].
int _draw(
  InkController controller,
  List<InkVector> points, {
  ScribbleConfig? scribble = const ScribbleConfig(),
}) {
  controller.startStroke(
    pointer: 1,
    sample: RawInkSample(position: points.first, timestamp: Duration.zero),
    style: _style,
    scribbleErase: scribble,
  );
  for (int i = 1; i < points.length; i++) {
    controller.addSamples(1, <RawInkSample>[
      RawInkSample(
        position: points[i],
        timestamp: Duration(milliseconds: 8 * i),
      ),
    ]);
  }
  return controller.endStroke(1);
}

void main() {
  group('ScribbleErase.isZigzag', () {
    test('a back-and-forth stroke is a zigzag', () {
      expect(ScribbleErase.isZigzag(_zigzag(0, 0, 100, 40)), isTrue);
    });

    test('an up-and-down zigzag moving sideways is one too', () {
      final List<InkVector> points = <InkVector>[
        for (final InkVector p in _zigzag(0, 0, 40, 120)) InkVector(p.y, p.x),
      ];
      expect(ScribbleErase.isZigzag(points), isTrue);
    });

    test('a line or a single turn is not', () {
      expect(
        ScribbleErase.isZigzag(<InkVector>[
          for (int i = 0; i <= 20; i++) InkVector(i * 5.0, 0),
        ]),
        isFalse,
      );
      expect(
        ScribbleErase.isZigzag(_zigzag(0, 0, 100, 40, swings: 2)),
        isFalse,
      );
    });
  });

  group('scribble to erase', () {
    test('scribbling over a word erases it and leaves no scribble', () {
      final Stroke word = _word(100, 100);
      final Stroke other = _word(100, 300);
      final InkController controller = InkController(
        strokes: <Stroke>[word, other],
      );
      addTearDown(controller.dispose);

      final int erased = _draw(controller, _zigzag(90, 95, 170, 115));

      expect(erased, 1);
      expect(controller.strokes, <Stroke>[other]);
      expect(controller.canUndo, isTrue);
      controller.undo();
      expect(controller.strokes, <Stroke>[word, other]);
    });

    test('a zigzag over empty paper is kept as ink', () {
      final InkController controller = InkController(
        strokes: <Stroke>[_word(100, 300)],
      );
      addTearDown(controller.dispose);

      expect(_draw(controller, _zigzag(90, 95, 170, 115)), 0);
      expect(controller.strokes, hasLength(2));
    });

    test('a stroke only partly under the scribble stays', () {
      final Stroke long = Stroke.fromPoints(
        style: _style,
        points: const <InkVector>[InkVector(0, 105), InkVector(600, 105)],
      );
      final InkController controller = InkController(strokes: <Stroke>[long]);
      addTearDown(controller.dispose);

      expect(_draw(controller, _zigzag(90, 95, 170, 115)), 0);
      expect(controller.strokes.first, same(long));
      expect(controller.strokes, hasLength(2));
    });

    test('without a scribble config the scribble is ordinary ink', () {
      final Stroke word = _word(100, 100);
      final InkController controller = InkController(strokes: <Stroke>[word]);
      addTearDown(controller.dispose);

      expect(_draw(controller, _zigzag(90, 95, 170, 115), scribble: null), 0);
      expect(controller.strokes, hasLength(2));
    });
  });
}
