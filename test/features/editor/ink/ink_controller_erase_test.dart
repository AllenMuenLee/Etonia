import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

const EraserSettings _area = EraserSettings(mode: EraserMode.area, size: 10);
const EraserSettings _whole = EraserSettings(mode: EraserMode.stroke, size: 10);

final InkColor _blue = InkPalette.colors.firstWhere(
  (InkColor ink) => ink.id == 'blue',
);

InkVector _v(double x, double y) => InkVector(x, y);

/// A horizontal 2 px stroke at height [y] with a vertex every 10 px.
Stroke _line(double y, {double from = 0, double to = 100, StrokeStyle? style}) {
  return Stroke.fromPoints(
    style: style ?? const StrokeStyle(ink: InkPalette.ink, width: 2),
    points: <InkVector>[
      for (double x = from; x < to; x += 10) _v(x, y),
      _v(to, y),
    ],
  );
}

Stroke _dot(double x, double y, {double width = 2}) {
  return Stroke.fromPoints(
    style: StrokeStyle(ink: InkPalette.ink, width: width),
    points: <InkVector>[_v(x, y)],
  );
}

RawInkSample _sample(double x, double y, int milliseconds) {
  return RawInkSample(
    position: _v(x, y),
    timestamp: Duration(milliseconds: milliseconds),
  );
}

/// A controller holding [strokes], with a count of completed-layer
/// notifications.
({InkController controller, List<int> repaints}) _controller(
  List<Stroke> strokes,
) {
  final InkController controller = InkController(strokes: strokes);
  addTearDown(controller.dispose);
  final List<int> repaints = <int>[0];
  controller.completedStrokesListenable.addListener(() => repaints[0]++);
  return (controller: controller, repaints: repaints);
}

/// One whole gesture: down at [from], a move to [to], up.
void _erase(
  InkController controller,
  InkVector from,
  InkVector to, {
  EraserSettings settings = _area,
}) {
  expect(
    controller.startErase(pointer: 1, position: from, settings: settings),
    isTrue,
  );
  controller
    ..eraseTo(1, to)
    ..endErase(1);
}

void main() {
  group('area erase', () {
    test('replaces a stroke with its pieces at the same index', () {
      final Stroke above = _line(0);
      final Stroke target = _line(50);
      final Stroke below = _line(100);
      final InkController controller = _controller(<Stroke>[
        above,
        target,
        below,
      ]).controller;

      // Radius 5 plus half the 2 px width: cut 6 px either side of x = 50.
      _erase(controller, _v(50, 40), _v(50, 60));

      final List<Stroke> strokes = controller.strokes;
      expect(strokes.length, 4);
      expect(strokes[0], same(above));
      expect(strokes[3], same(below));
      // In order along the original direction of travel.
      expect(strokes[1].points.first, _v(0, 50));
      expect(strokes[1].points.last.x, closeTo(44, 1e-9));
      expect(strokes[2].points.first.x, closeTo(56, 1e-9));
      expect(strokes[2].points.last, _v(100, 50));
    });

    test('pieces keep the style and are marked as derived', () {
      final StrokeStyle style = StrokeStyle(ink: _blue, width: 8);
      final InkController controller = InkController();
      addTearDown(controller.dispose);
      controller.startStroke(
        pointer: 7,
        sample: _sample(0, 50, 0),
        style: style,
      );
      for (int i = 1; i <= 10; i++) {
        controller.addSamples(7, <RawInkSample>[_sample(i * 10, 50, i * 8)]);
      }
      controller.endStroke(7);
      final Stroke drawn = controller.strokes.single;
      expect(drawn.source, StrokeSource.input);
      expect(drawn.rawSamples, isNotEmpty);

      _erase(controller, _v(50, 30), _v(50, 70));

      expect(controller.strokes.length, 2);
      for (final Stroke piece in controller.strokes) {
        expect(piece.style, same(style));
        expect(piece.source, StrokeSource.derived);
        // A piece does not claim raw input it cannot identify.
        expect(piece.rawSamples, isEmpty);
        expect(piece.isDot, isFalse);
        expect(piece.points.length, greaterThanOrEqualTo(2));
      }
      // Radius 5 plus half of 8: the gap is 9 px either side of x = 50.
      expect(controller.strokes[0].points.last.x, closeTo(41, 1e-9));
      expect(controller.strokes[1].points.first.x, closeTo(59, 1e-9));
      // The cached box follows the new geometry, grown by half the width.
      expect(controller.strokes[0].bounds.right, closeTo(45, 1e-9));
      expect(controller.strokes[0].bounds.top, closeTo(46, 1e-9));
      expect(controller.strokes[1].bounds.left, closeTo(55, 1e-9));
    });

    test('removes a stroke that lies entirely inside the eraser', () {
      final Stroke short = _line(50, from: 48, to: 52);
      final Stroke far = _line(90);
      final InkController controller = _controller(<Stroke>[
        short,
        far,
      ]).controller;

      controller.startErase(pointer: 1, position: _v(50, 50), settings: _area);

      expect(controller.strokes, <Stroke>[far]);
      controller.endErase(1);
    });

    test('erases dots by distance and leaves the others unchanged', () {
      final Stroke near = _dot(50, 55.9);
      final Stroke justOutside = _dot(50, 43.9);
      final InkController controller = _controller(<Stroke>[
        near,
        justOutside,
      ]).controller;

      // Reach is radius 5 plus half the 2 px width.
      controller.startErase(pointer: 1, position: _v(50, 50), settings: _area);
      controller.endErase(1);

      expect(controller.strokes, <Stroke>[justOutside]);
    });

    test('crossing a stroke many times in one gesture keeps it consistent', () {
      final InkController controller = _controller(<Stroke>[
        _line(50, to: 400),
      ]).controller;

      controller.startErase(pointer: 1, position: _v(20, 20), settings: _area);
      // A zigzag that crosses the stroke nine times.
      for (int i = 1; i <= 9; i++) {
        controller.eraseTo(1, _v(20 + i * 40, i.isOdd ? 80 : 20));
      }
      controller.endErase(1);

      expect(controller.strokes.length, 10);
      double previousEnd = double.negativeInfinity;
      for (final Stroke piece in controller.strokes) {
        expect(piece.points.first.x, greaterThan(previousEnd));
        for (final InkVector point in piece.points) {
          expect(point.isFinite, isTrue);
          expect(point.y, 50);
        }
        previousEnd = piece.points.last.x;
      }
    });
  });

  group('stroke erase', () {
    test('removes exactly the touched strokes', () {
      final Stroke first = _line(0);
      final Stroke second = _line(50);
      final Stroke third = _line(100);
      final Stroke dot = _dot(50, 75);
      final InkController controller = _controller(<Stroke>[
        first,
        second,
        third,
        dot,
      ]).controller;

      // Sweeps from between the first two strokes down through the dot. The
      // default hit radius is 6, so reach is 7: `first` and `third` are out.
      _erase(controller, _v(50, 7.5), _v(50, 92.5), settings: _whole);

      expect(controller.strokes, <Stroke>[first, third]);
    });

    test('uses the fixed hit radius, not the area size', () {
      final Stroke stroke = _line(50);
      final InkController controller = _controller(<Stroke>[stroke]).controller;
      const EraserSettings huge = EraserSettings(
        mode: EraserMode.stroke,
        size: 80,
      );

      controller.startErase(pointer: 1, position: _v(50, 60), settings: huge);
      expect(
        controller.activeErase!.radius,
        const EraserConfig().strokeHitRadius,
      );
      expect(controller.strokes.single, same(stroke));
      controller.eraseTo(1, _v(50, 56.5));

      expect(controller.strokes, isEmpty);
      controller.endErase(1);
    });
  });

  group('notifications', () {
    test('the completed layer repaints only when ink changed', () {
      final (:InkController controller, :List<int> repaints) = _controller(
        <Stroke>[_line(50)],
      );
      int eraserMoves = 0;
      controller.eraserListenable.addListener(() => eraserMoves++);

      controller.startErase(pointer: 1, position: _v(50, 200), settings: _area);
      controller
        ..eraseTo(1, _v(60, 190))
        ..eraseTo(1, _v(70, 180));
      // Empty paper: the indicator moved, the ink layer did not repaint.
      expect(repaints.single, 0);
      expect(eraserMoves, 3);
      expect(controller.activeErase!.changedInk, isFalse);

      controller.eraseTo(1, _v(70, 40));
      expect(repaints.single, 1);
      expect(controller.activeErase!.changedInk, isTrue);

      // Back over the gap that was just made: nothing left to remove.
      controller
        ..eraseTo(1, _v(70, 60))
        ..eraseTo(1, _v(70, 40));
      expect(repaints.single, 1);
      // A repeated position is not even a move.
      final int movesBefore = eraserMoves;
      controller.eraseTo(1, _v(70, 40));
      expect(eraserMoves, movesBefore);

      controller.endErase(1);
      expect(repaints.single, 1);
    });

    test('erasing the same place twice changes nothing the second time', () {
      for (final EraserSettings settings in <EraserSettings>[_area, _whole]) {
        final (:InkController controller, :List<int> repaints) = _controller(
          <Stroke>[_line(50), _line(54), _dot(30, 52)],
        );

        _erase(controller, _v(20, 45), _v(60, 58), settings: settings);
        final List<Stroke> after = controller.strokes.toList();
        final int repaintsAfter = repaints.single;
        expect(repaintsAfter, greaterThan(0));

        _erase(controller, _v(20, 45), _v(60, 58), settings: settings);

        expect(controller.strokes.length, after.length);
        for (int i = 0; i < after.length; i++) {
          expect(controller.strokes[i], same(after[i]));
        }
        expect(repaints.single, repaintsAfter);
      }
    });

    test('an empty page and unusable positions are harmless', () {
      final (:InkController controller, :List<int> repaints) = _controller(
        const <Stroke>[],
      );

      expect(
        controller.startErase(
          pointer: 1,
          position: _v(double.nan, 0),
          settings: _area,
        ),
        isFalse,
      );
      expect(controller.activeErase, isNull);

      controller.startErase(pointer: 1, position: _v(10, 10), settings: _area);
      controller
        ..eraseTo(1, _v(double.infinity, 10))
        ..eraseTo(1, _v(-5000, 12000))
        ..eraseTo(1, _v(10, 10));
      expect(controller.activeErase!.position, _v(10, 10));
      controller.endErase(1, _v(double.nan, double.nan));

      expect(controller.activeErase, isNull);
      expect(controller.strokes, isEmpty);
      expect(repaints.single, 0);
    });
  });

  group('gesture lifecycle', () {
    test('a pointer cannot write and erase at once', () {
      final InkController controller = _controller(<Stroke>[
        _line(50),
      ]).controller;
      const StrokeStyle style = StrokeStyle(ink: InkPalette.ink, width: 3);

      // Erasing blocks writing, from the same pointer or another.
      controller.startErase(pointer: 1, position: _v(0, 200), settings: _area);
      for (final int pointer in <int>[1, 2]) {
        expect(
          controller.startStroke(
            pointer: pointer,
            sample: _sample(10, 10, 0),
            style: style,
          ),
          isFalse,
        );
      }
      expect(controller.activeStroke, isNull);
      expect(controller.activePointer, 1);
      // A second eraser is refused too, and stray pointers do nothing.
      expect(
        controller.startErase(
          pointer: 2,
          position: _v(50, 50),
          settings: _area,
        ),
        isFalse,
      );
      controller
        ..eraseTo(2, _v(50, 50))
        ..endErase(2)
        ..cancelErase(2);
      expect(controller.activeErase!.pointer, 1);
      expect(controller.strokes.single.points.length, 11);
      controller.endErase(1);
      expect(controller.activePointer, isNull);

      // Writing blocks erasing.
      expect(
        controller.startStroke(
          pointer: 3,
          sample: _sample(10, 10, 0),
          style: style,
        ),
        isTrue,
      );
      expect(
        controller.startErase(
          pointer: 4,
          position: _v(50, 50),
          settings: _area,
        ),
        isFalse,
      );
      expect(controller.activeErase, isNull);
      expect(controller.strokes.single.points.length, 11);
      controller.endStroke(3);
      expect(controller.strokes.length, 2);
    });

    test('each gesture is one identifiable unit', () {
      final InkController controller = _controller(<Stroke>[
        _line(50),
      ]).controller;

      controller.startErase(pointer: 1, position: _v(0, 200), settings: _area);
      final EraseGesture first = controller.activeErase!;
      controller.eraseTo(1, _v(10, 200));
      expect(controller.activeErase, same(first));
      controller.endErase(1);

      controller.startErase(pointer: 1, position: _v(50, 50), settings: _area);
      final EraseGesture second = controller.activeErase!;
      expect(second.id, greaterThan(first.id));
      expect(first.changedInk, isFalse);
      expect(second.changedInk, isTrue);
      controller.endErase(1);
    });

    test('settings are captured when the gesture starts', () {
      final InkController controller = _controller(<Stroke>[
        _line(50),
      ]).controller;

      controller.startErase(
        pointer: 1,
        position: _v(50, 200),
        settings: const EraserSettings(mode: EraserMode.area, size: 40),
        config: const EraserConfig(strokeHitRadius: 3, minPieceLength: 60),
      );
      final EraseGesture erase = controller.activeErase!;
      expect(erase.mode, EraserMode.area);
      expect(erase.radius, 20);
      // Reach is 21: the pieces are 29 px long, under the 60 px minimum.
      controller.eraseTo(1, _v(50, 50));

      expect(controller.strokes, isEmpty);
      controller.endErase(1);
    });

    test('pointer-up erases up to its own position', () {
      final InkController controller = _controller(<Stroke>[
        _line(50),
      ]).controller;

      controller
        ..startErase(pointer: 1, position: _v(50, 200), settings: _area)
        ..endErase(1, _v(50, 0));

      expect(controller.strokes.length, 2);
      expect(controller.activeErase, isNull);
    });

    for (final (String name, void Function(InkController) end)
        in <(String, void Function(InkController))>[
          ('cancel', (InkController controller) => controller.cancelErase(1)),
          (
            'a metrics change',
            (InkController controller) => controller.finalizeActiveGesture(),
          ),
        ]) {
      test('$name ends the gesture and keeps what was erased', () {
        final (:InkController controller, :List<int> repaints) = _controller(
          <Stroke>[_line(50), _line(150)],
        );
        controller
          ..startErase(pointer: 1, position: _v(50, 30), settings: _area)
          ..eraseTo(1, _v(50, 70));
        expect(controller.strokes.length, 3);

        end(controller);

        expect(controller.activeErase, isNull);
        expect(controller.activePointer, isNull);
        expect(controller.strokes.length, 3);
        // The pointer that was down no longer erases.
        final List<Stroke> after = controller.strokes.toList();
        controller
          ..eraseTo(1, _v(50, 170))
          ..endErase(1, _v(50, 170));
        expect(controller.strokes, after);
        expect(repaints.single, 1);
        // A new gesture starts cleanly.
        expect(
          controller.startErase(
            pointer: 2,
            position: _v(50, 150),
            settings: _area,
          ),
          isTrue,
        );
        expect(controller.strokes.length, 4);
      });
    }

    test('finalizing ends a stroke in progress as well', () {
      final InkController controller = InkController();
      addTearDown(controller.dispose);
      controller
        ..startStroke(
          pointer: 1,
          sample: _sample(0, 0, 0),
          style: const StrokeStyle(ink: InkPalette.ink, width: 3),
        )
        ..addSamples(1, <RawInkSample>[_sample(40, 0, 8)])
        ..finalizeActiveGesture();

      expect(controller.activeStroke, isNull);
      expect(controller.strokes.single.source, StrokeSource.input);
    });
  });

  group('Stroke.fromPoints', () {
    test('builds the path and bounds once and treats one point as a dot', () {
      final Stroke line = _line(50, style: StrokeStyle(ink: _blue, width: 6));
      expect(line.isDot, isFalse);
      expect(line.bounds.left, -3);
      expect(line.bounds.top, 47);
      expect(line.bounds.right, 103);
      expect(line.bounds.bottom, 53);
      expect(line.path.getBounds().width, 100);
      expect(line.path, same(line.path));
      expect(() => line.points.add(_v(0, 0)), throwsUnsupportedError);

      final Stroke dot = _dot(5, 5, width: 4);
      expect(dot.isDot, isTrue);
      expect(dot.bounds.width, 4);
      expect(dot.bounds.center.dx, 5);
    });
  });
}
