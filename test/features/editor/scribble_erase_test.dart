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

/// Points zigzagging up and down [swings] times over the box from
/// (left, top) to (right, bottom), moving right as they go.
List<InkVector> _zigzag(
  double left,
  double top,
  double right,
  double bottom, {
  int swings = 16,
}) {
  final List<InkVector> points = <InkVector>[];
  for (int i = 0; i <= swings; i++) {
    final double x = left + (right - left) * i / swings;
    final double y = i.isEven ? top : bottom;
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

/// [points] as raw samples taken every [interval]. At the default, a swing
/// of [_zigzag] takes 64 ms.
List<RawInkSample> _samples(
  List<InkVector> points, {
  Duration interval = const Duration(milliseconds: 8),
}) => <RawInkSample>[
  for (int i = 0; i < points.length; i++)
    RawInkSample(position: points[i], timestamp: interval * i),
];

/// Draws [points] as one stroke through [controller].
int _draw(
  InkController controller,
  List<InkVector> points, {
  ScribbleConfig? scribble = const ScribbleConfig(),
  Duration interval = const Duration(milliseconds: 8),
}) {
  controller.startStroke(
    pointer: 1,
    sample: RawInkSample(position: points.first, timestamp: Duration.zero),
    style: _style,
    scribbleErase: scribble,
  );
  for (int i = 1; i < points.length; i++) {
    controller.addSamples(1, <RawInkSample>[
      RawInkSample(position: points[i], timestamp: interval * i),
    ]);
  }
  return controller.endStroke(1);
}

void main() {
  group('ScribbleErase.isScribble', () {
    test('a rushed, dense up-and-down stroke is a scribble', () {
      expect(ScribbleErase.isScribble(_samples(_zigzag(0, 0, 80, 20))), isTrue);
    });

    test('a slow one is not', () {
      expect(
        ScribbleErase.isScribble(
          _samples(
            _zigzag(0, 0, 80, 20),
            interval: const Duration(milliseconds: 40),
          ),
        ),
        isFalse,
      );
    });

    test('a rushed one with its swings far apart is not', () {
      expect(
        ScribbleErase.isScribble(_samples(_zigzag(0, 0, 320, 20))),
        isFalse,
      );
    });

    test('a rushed, dense side-to-side one is not', () {
      final List<InkVector> sideways = <InkVector>[
        for (final InkVector p in _zigzag(0, 0, 80, 20)) InkVector(p.y, p.x),
      ];
      expect(ScribbleErase.isScribble(_samples(sideways)), isFalse);
    });

    test('too few swings are not', () {
      expect(
        ScribbleErase.isScribble(_samples(_zigzag(0, 0, 10, 20, swings: 6))),
        isFalse,
      );
    });

    test('a straight line is not', () {
      expect(
        ScribbleErase.isScribble(
          _samples(<InkVector>[
            for (int i = 0; i <= 20; i++) InkVector(0, i * 5.0),
          ]),
        ),
        isFalse,
      );
    });

    test('resting the pen before and after does not slow it down', () {
      final List<RawInkSample> rush = _samples(_zigzag(0, 0, 80, 20));
      const Duration rest = Duration(seconds: 5);
      expect(
        ScribbleErase.isScribble(<RawInkSample>[
          RawInkSample(position: rush.first.position, timestamp: Duration.zero),
          for (final RawInkSample sample in rush)
            RawInkSample(
              position: sample.position,
              timestamp: sample.timestamp + rest,
            ),
          RawInkSample(
            position: rush.last.position,
            timestamp: rush.last.timestamp + rest * 2,
          ),
        ]),
        isTrue,
      );
    });

    test('samples without timing are not a rush', () {
      expect(
        ScribbleErase.isScribble(
          _samples(_zigzag(0, 0, 80, 20), interval: Duration.zero),
        ),
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

    test('a slow zigzag over a word is kept as ink', () {
      final Stroke word = _word(100, 100);
      final InkController controller = InkController(strokes: <Stroke>[word]);
      addTearDown(controller.dispose);

      expect(
        _draw(
          controller,
          _zigzag(90, 95, 170, 115),
          interval: const Duration(milliseconds: 40),
        ),
        0,
      );
      expect(controller.strokes, hasLength(2));
    });

    test('a sparse zigzag over a word is kept as ink', () {
      final Stroke word = _word(100, 100);
      final InkController controller = InkController(strokes: <Stroke>[word]);
      addTearDown(controller.dispose);

      expect(_draw(controller, _zigzag(90, 95, 170, 115, swings: 6)), 0);
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
