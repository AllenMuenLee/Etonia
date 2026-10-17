import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/ink_selection.dart';
import 'package:greatnote/features/editor/ink/selection_config.dart';
import 'package:greatnote/features/editor/ink/selection_transform.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

final InkColor _blue = InkPalette.colors.firstWhere(
  (InkColor ink) => ink.id == 'blue',
);

InkVector _v(double x, double y) => InkVector(x, y);

Matcher _near(InkVector expected, [double tolerance = 1e-9]) {
  return isA<InkVector>()
      .having((InkVector v) => v.x, 'x', closeTo(expected.x, tolerance))
      .having((InkVector v) => v.y, 'y', closeTo(expected.y, tolerance));
}

/// A horizontal stroke at height [y], from 0 to 100, with a point every
/// 10 px.
Stroke _line(double y, {double width = 2, InkColor ink = InkPalette.ink}) {
  return Stroke.fromPoints(
    style: StrokeStyle(ink: ink, width: width),
    points: <InkVector>[for (double x = 0; x <= 100; x += 10) _v(x, y)],
  );
}

Stroke _dot(double x, double y, {double width = 6}) {
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

/// A page whose strokes 1, 2, and 4 sit together and get selected by
/// [_selectGroup]: a thin line, a dot, and a wide blue line. Strokes 0 and 3
/// are far below.
class _Page {
  _Page({SelectionConfig config = const SelectionConfig()})
    : controller = InkController(
        selectionConfig: config,
        strokes: <Stroke>[
          _line(300),
          _line(50),
          _dot(50, 60),
          _line(400),
          _line(70, width: 4, ink: _blue),
        ],
      ) {
    addTearDown(controller.dispose);
    controller.completedStrokesListenable.addListener(() => completed++);
    controller.selectionListenable.addListener(() => selection++);
  }

  final InkController controller;

  /// Notifications from the completed-strokes and the selection listenable.
  int completed = 0;
  int selection = 0;

  void resetCounts() {
    completed = 0;
    selection = 0;
  }
}

/// One whole lasso gesture around a box, back to where it began.
void _lasso(
  InkController controller,
  double left,
  double top,
  double right,
  double bottom,
) {
  expect(controller.beginLasso(pointer: 1, position: _v(left, top)), isTrue);
  controller
    ..updateLasso(1, _v(right, top))
    ..updateLasso(1, _v(right, bottom))
    ..updateLasso(1, _v(left, bottom))
    ..endLasso(1, _v(left, top));
}

/// Selects strokes 1, 2, and 4 of a [_Page]. Their frame runs from (-2, 49)
/// to (102, 72).
void _selectGroup(_Page page) {
  _lasso(page.controller, -20, 30, 120, 90);
  expect(page.controller.selection!.indices, <int>[1, 2, 4]);
  page.resetCounts();
}

/// One whole transform gesture: down at [from], through [via], up at [to].
void _transform(
  InkController controller,
  InkVector from,
  InkVector to, {
  List<InkVector> via = const <InkVector>[],
}) {
  expect(controller.beginSelectionGesture(pointer: 1, position: from), isTrue);
  for (final InkVector position in via) {
    controller.updateSelectionGesture(1, position);
  }
  controller.endSelectionGesture(1, to);
}

List<List<InkVector>> _points(InkController controller) {
  return <List<InkVector>>[
    for (final Stroke stroke in controller.strokes) stroke.points,
  ];
}

void main() {
  group('lasso', () {
    test(
      'selects overlapping strokes by index, leaving the document alone',
      () {
        final _Page page = _Page();
        final InkController controller = page.controller;
        final List<Stroke> before = List<Stroke>.of(controller.strokes);

        _lasso(controller, -20, 30, 120, 90);

        final InkSelection selection = controller.selection!;
        expect(selection.indices, <int>[1, 2, 4]);
        expect(selection.count, 3);
        expect(selection.strokes[0], same(before[1]));
        expect(selection.strokes[1], same(before[2]));
        expect(selection.strokes[2], same(before[4]));
        expect(controller.strokes, before);
        // The union of the rendered bounds, upright.
        expect(selection.frame.center, _v(50, 60.5));
        expect(selection.frame.halfWidth, 52);
        expect(selection.frame.halfHeight, 11.5);
        expect(selection.frame.angle, 0);
        expect(controller.activeLasso, isNull);
        expect(controller.activeStroke, isNull);
        expect(controller.activePointer, isNull);
        // Once, for the selected strokes changing layers.
        expect(page.completed, 1);
      },
    );

    test('moves notify the selection layer only', () {
      final _Page page = _Page();
      final InkController controller = page.controller;

      controller.beginLasso(pointer: 1, position: _v(-20, 30));
      for (int i = 1; i <= 50; i++) {
        controller.updateLasso(1, _v(-20 + i * 3, 30));
      }

      expect(page.selection, 51);
      expect(page.completed, 0);
      expect(controller.activePointer, 1);
      expect(controller.selectionPointer, 1);
    });

    test('stores a point only at the minimum spacing, and tracks the tip', () {
      final InkController controller = _Page().controller;

      controller.beginLasso(pointer: 1, position: _v(0, 0));
      controller.updateLasso(1, _v(1, 0));
      expect(controller.activeLasso!.points, <InkVector>[_v(0, 0)]);
      expect(controller.activeLasso!.tip, _v(1, 0));

      controller.updateLasso(1, _v(1.9, 0));
      expect(controller.activeLasso!.points.length, 1);

      controller.updateLasso(1, _v(2, 0));
      expect(controller.activeLasso!.points, <InkVector>[_v(0, 0), _v(2, 0)]);

      // Duplicates of the tip are not stored, however many arrive.
      for (int i = 0; i < 10; i++) {
        controller.updateLasso(1, _v(2, 0));
      }
      expect(controller.activeLasso!.points.length, 2);
      expect(
        () => controller.activeLasso!.points.add(_v(9, 9)),
        throwsA(anything),
      );
    });

    test('keeps the final point even inside the minimum spacing', () {
      final InkController controller = InkController(
        strokes: <Stroke>[
          Stroke.fromPoints(
            style: const StrokeStyle(ink: InkPalette.ink, width: 0.1),
            points: <InkVector>[_v(150, 0.5), _v(190, 0.5)],
          ),
        ],
      );
      addTearDown(controller.dispose);

      // A straight drag with a last sample 1 px down: a thin rectangle
      // only if that last point counts.
      controller
        ..beginLasso(pointer: 1, position: _v(0, 0))
        ..updateLasso(1, _v(200, 0))
        ..endLasso(1, _v(200, 1));

      expect(controller.selection?.indices, <int>[0]);
    });

    test('a tap selects nothing, clears the selection, and adds no ink', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      _selectGroup(page);
      final List<Stroke> before = List<Stroke>.of(controller.strokes);

      // Away from the frame, so it starts a lasso.
      expect(
        controller.beginSelectionGesture(pointer: 1, position: _v(500, 500)),
        isTrue,
      );
      expect(controller.activeLasso, isNotNull);
      controller.endSelectionGesture(1, _v(500, 500));

      expect(controller.selection, isNull);
      expect(controller.strokes, before);
      expect(page.completed, 1);
    });

    test('a lasso with no area, or around nothing, selects nothing', () {
      final _Page page = _Page();
      final InkController controller = page.controller;

      // Straight across the group.
      controller
        ..beginLasso(pointer: 1, position: _v(-20, 50))
        ..updateLasso(1, _v(50, 50))
        ..endLasso(1, _v(120, 50));
      expect(controller.selection, isNull);

      _lasso(controller, 500, 500, 600, 600);
      expect(controller.selection, isNull);
      // Nothing changed layers.
      expect(page.completed, 0);
    });

    test('a new lasso replaces the selection', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      _selectGroup(page);

      _lasso(controller, -20, 280, 120, 320);

      expect(controller.selection!.indices, <int>[0]);
      expect(page.completed, 1);
    });

    test('a cancelled lasso leaves the previous selection as it was', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      _selectGroup(page);
      final InkSelection before = controller.selection!;

      controller
        ..beginLasso(pointer: 1, position: _v(-20, 280))
        ..updateLasso(1, _v(120, 280))
        ..updateLasso(1, _v(120, 320));
      // The old selection is still there while the new lasso is drawn.
      expect(controller.selection, same(before));
      controller.cancelSelectionGesture(1);

      expect(controller.activeLasso, isNull);
      expect(controller.selection, same(before));
      expect(page.completed, 0);
    });
  });

  group('lasso shape', () {
    test('a straight drag selects the rectangle between its ends', () {
      // Every diagonal, each from either end.
      for (final (InkVector from, InkVector to) in <(InkVector, InkVector)>[
        (_v(-20, 30), _v(120, 90)),
        (_v(120, 90), _v(-20, 30)),
        (_v(120, 30), _v(-20, 90)),
        (_v(-20, 90), _v(120, 30)),
      ]) {
        final InkController controller = _Page().controller;

        controller.beginLasso(pointer: 1, position: from);
        for (int i = 1; i < 10; i++) {
          // A hand's wobble, not a ruler's line.
          controller.updateLasso(
            1,
            from + (to - from) * (i / 10) + _v(0, 3 * math.sin(i.toDouble())),
          );
        }
        controller.updateLasso(1, to);
        final LassoGesture lasso = controller.activeLasso!;
        expect(lasso.shape, LassoShape.rectangle, reason: '$from');
        expect(lasso.outline, <InkVector>[
          from,
          _v(to.x, from.y),
          to,
          _v(from.x, to.y),
        ]);
        controller.endLasso(1);

        expect(controller.selection?.indices, <int>[1, 2, 4], reason: '$from');
      }
    });

    test('a rectangle selects what it touches, not what its path crossed', () {
      final InkController controller = _Page().controller;

      // The diagonal passes far from the dot; the rectangle holds it.
      controller
        ..beginLasso(pointer: 1, position: _v(40, 55))
        ..endLasso(1, _v(60, 65));

      expect(controller.selection?.indices, <int>[2]);
    });

    test('a freeform loop selects only once it nearly closes', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      _selectGroup(page);

      // Three sides of a box around stroke 0: the gap is its long top
      // side.
      controller
        ..beginLasso(pointer: 1, position: _v(-20, 280))
        ..updateLasso(1, _v(-20, 320))
        ..updateLasso(1, _v(120, 320))
        ..updateLasso(1, _v(120, 280));
      final LassoGesture lasso = controller.activeLasso!;
      expect(lasso.shape, LassoShape.freeform);
      expect(lasso.length, 220);
      expect(lasso.isClosed, isFalse);
      expect(lasso.outline, isEmpty);

      // Most of the way back along the top: the gap is now within a fifth
      // of the length drawn.
      controller.updateLasso(1, _v(0, 280));
      expect(lasso.isClosed, isTrue);
      expect(lasso.outline.length, 5);
      controller.endLasso(1);

      expect(controller.selection!.indices, <int>[0]);
    });

    test('a loop left open selects nothing and clears the selection', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      final List<Stroke> before = List<Stroke>.of(controller.strokes);
      _selectGroup(page);

      controller
        ..beginLasso(pointer: 1, position: _v(-20, 280))
        ..updateLasso(1, _v(-20, 320))
        ..updateLasso(1, _v(120, 320))
        ..endLasso(1, _v(120, 280));

      expect(controller.selection, isNull);
      expect(controller.strokes, before);
      expect(page.completed, 1);
    });

    test('the thresholds come from the config', () {
      final InkController controller = InkController(
        selectionConfig: const SelectionConfig(
          rectangleMaxDetour: 1,
          lassoClosingFraction: 0.5,
        ),
        strokes: <Stroke>[_line(300)],
      );
      addTearDown(controller.dispose);

      // Any wobble at all now makes it freeform, and three sides of a box
      // now count as closed.
      controller
        ..beginLasso(pointer: 1, position: _v(-20, 280))
        ..updateLasso(1, _v(50, 281))
        ..updateLasso(1, _v(120, 280));
      expect(controller.activeLasso!.shape, LassoShape.freeform);
      controller
        ..updateLasso(1, _v(120, 320))
        ..endLasso(1, _v(-20, 320));

      expect(controller.selection?.indices, <int>[0]);
    });
  });

  group('pointer ownership', () {
    test('selection cannot start while writing or erasing', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      const StrokeStyle style = StrokeStyle(ink: InkPalette.ink, width: 2);

      controller.startStroke(
        pointer: 1,
        sample: _sample(0, 200, 0),
        style: style,
      );
      expect(
        controller.beginSelectionGesture(pointer: 2, position: _v(0, 0)),
        isFalse,
      );
      expect(controller.beginLasso(pointer: 2, position: _v(0, 0)), isFalse);
      controller.endStroke(1);

      controller.startErase(
        pointer: 1,
        position: _v(500, 500),
        settings: EraserSettings.defaults(),
      );
      expect(
        controller.beginSelectionGesture(pointer: 2, position: _v(0, 0)),
        isFalse,
      );
      controller.endErase(1);

      expect(controller.activeLasso, isNull);
      expect(controller.selection, isNull);
    });

    test('writing and erasing cannot start during a lasso or a transform', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      const StrokeStyle style = StrokeStyle(ink: InkPalette.ink, width: 2);
      bool startsOther() {
        return controller.startStroke(
              pointer: 2,
              sample: _sample(0, 200, 0),
              style: style,
            ) ||
            controller.startErase(
              pointer: 2,
              position: _v(50, 50),
              settings: EraserSettings.defaults(),
            ) ||
            controller.beginSelectionGesture(pointer: 2, position: _v(50, 60));
      }

      controller.beginLasso(pointer: 1, position: _v(-20, 30));
      expect(startsOther(), isFalse);
      controller.cancelLasso(1);

      _selectGroup(page);
      controller.beginSelectionGesture(pointer: 1, position: _v(50, 60));
      expect(controller.activeTransform, isNotNull);
      expect(startsOther(), isFalse);
      controller.endSelectionGesture(1);

      expect(controller.strokes.length, 5);
      expect(controller.activeStroke, isNull);
      expect(controller.activeErase, isNull);
    });

    test('events from another pointer do not touch the gesture', () {
      final _Page page = _Page();
      final InkController controller = page.controller;

      controller.beginLasso(pointer: 1, position: _v(-20, 30));
      controller
        ..updateSelectionGesture(2, _v(300, 300))
        ..endSelectionGesture(2, _v(300, 300))
        ..cancelSelectionGesture(2);
      expect(controller.activeLasso!.tip, _v(-20, 30));
      controller.cancelLasso(1);

      _selectGroup(page);
      controller.beginSelectionGesture(pointer: 1, position: _v(50, 60));
      controller
        ..updateSelectionGesture(2, _v(300, 300))
        ..endSelectionGesture(2, _v(300, 300))
        ..cancelSelectionGesture(2);
      expect(controller.activeTransform!.transform, InkTransform.identity);
      expect(page.completed, 0);
    });

    test('non-finite positions change nothing', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      final InkVector bad = _v(double.nan, 10);
      final InkVector far = _v(10, double.infinity);

      expect(controller.beginLasso(pointer: 1, position: bad), isFalse);
      expect(
        controller.beginSelectionGesture(pointer: 1, position: far),
        isFalse,
      );
      expect(page.selection, 0);

      controller.beginLasso(pointer: 1, position: _v(-20, 30));
      page.resetCounts();
      controller
        ..updateLasso(1, bad)
        ..updateLasso(1, far);
      expect(controller.activeLasso!.tip, _v(-20, 30));
      expect(page.selection, 0);
      controller
        ..updateLasso(1, _v(120, 30))
        ..updateLasso(1, _v(120, 90))
        ..updateLasso(1, _v(-20, 90))
        ..updateLasso(1, _v(-20, 30))
        // A bad final position is ignored; the lasso still ends.
        ..endLasso(1, bad);
      expect(controller.selection!.indices, <int>[1, 2, 4]);

      page.resetCounts();
      expect(
        controller.beginTransform(
          pointer: 1,
          position: bad,
          hit: const SelectionHit.move(),
        ),
        isFalse,
      );
      controller.beginSelectionGesture(pointer: 1, position: _v(50, 60));
      controller.updateTransform(1, _v(60, 60));
      page.resetCounts();
      controller
        ..updateTransform(1, bad)
        ..updateTransform(1, far);
      expect(page.selection, 0);
      expect(
        controller.activeTransform!.transform,
        InkTransform.translation(_v(10, 0)),
      );
      controller.endTransform(1, bad);

      // Committed at the last finite position.
      expect(controller.strokes[1].points.first, _v(10, 50));
      for (final Stroke stroke in controller.strokes) {
        expect(stroke.points.every((InkVector p) => p.isFinite), isTrue);
        expect(stroke.bounds.isFinite, isTrue);
      }
    });
  });

  group('which gesture a pointer starts', () {
    test('rotation handle, corner, interior, then a new lasso', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      _selectGroup(page);
      SelectionTransformGesture? startAt(InkVector position) {
        controller.beginSelectionGesture(pointer: 1, position: position);
        final SelectionTransformGesture? gesture = controller.activeTransform;
        controller.cancelSelectionGesture(1);
        return gesture;
      }

      // 32 px above the middle of the top edge.
      expect(startAt(_v(50, 17))!.operation, SelectionOperation.rotate);
      expect(startAt(_v(-2, 49))!.operation, SelectionOperation.scale);
      expect(startAt(_v(-2, 49))!.corner, 0);
      expect(startAt(_v(102, 49))!.corner, 1);
      expect(startAt(_v(102, 72))!.corner, 2);
      expect(startAt(_v(-2, 72))!.corner, 3);
      // On the dot, well inside the frame: ink does not block a move.
      expect(startAt(_v(50, 60))!.operation, SelectionOperation.move);
      expect(startAt(_v(50, 60))!.corner, isNull);
      // Outside: a lasso, and the selection is still there afterwards.
      expect(startAt(_v(50, 200)), isNull);
      expect(controller.selection!.indices, <int>[1, 2, 4]);
    });

    test('a transform needs a selection', () {
      final InkController controller = _Page().controller;

      expect(
        controller.beginTransform(
          pointer: 1,
          position: _v(50, 60),
          hit: const SelectionHit.move(),
        ),
        isFalse,
      );
      expect(controller.activeTransform, isNull);
    });
  });

  group('move', () {
    test('shifts every selected point by the pointer delta, once', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      final List<Stroke> before = List<Stroke>.of(controller.strokes);
      _selectGroup(page);

      controller.beginSelectionGesture(pointer: 1, position: _v(50, 60));
      controller
        ..updateSelectionGesture(1, _v(55, 70))
        ..updateSelectionGesture(1, _v(70, 90));

      // Still a preview: the document is untouched and unrepainted.
      expect(controller.strokes, before);
      expect(page.completed, 0);
      expect(page.selection, 3);
      expect(
        controller.activeTransform!.transform,
        InkTransform.translation(_v(20, 30)),
      );
      expect(controller.activeTransform!.frame.center, _v(70, 90.5));

      controller.endSelectionGesture(1, _v(80, 100));

      expect(page.completed, 1);
      expect(controller.activeTransform, isNull);
      final List<Stroke> after = controller.strokes;
      expect(after.length, 5);
      // Neighbors keep their place and their identity.
      expect(after[0], same(before[0]));
      expect(after[3], same(before[3]));
      for (final int index in <int>[1, 2, 4]) {
        final Stroke moved = after[index];
        expect(moved.points.length, before[index].points.length);
        for (int i = 0; i < moved.points.length; i++) {
          expect(moved.points[i], before[index].points[i] + _v(30, 40));
        }
        // Width and color are untouched; so is the style object.
        expect(moved.style, same(before[index].style));
        expect(moved.source, StrokeSource.derived);
        expect(moved.rawSamples, isEmpty);
        expect(moved.isDot, before[index].isDot);
        expect(moved.bounds, before[index].bounds.shift(const Offset(30, 40)));
        if (!moved.isDot) {
          // The cached path was rebuilt from the moved points.
          expect(
            moved.path.getBounds(),
            before[index].path.getBounds().shift(const Offset(30, 40)),
          );
        }
      }
    });

    test('keeps the moved strokes selected, with the frame moved too', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      _selectGroup(page);

      _transform(controller, _v(50, 60), _v(80, 100));

      final InkSelection selection = controller.selection!;
      expect(selection.indices, <int>[1, 2, 4]);
      expect(selection.strokes[0], same(controller.strokes[1]));
      expect(selection.strokes[1], same(controller.strokes[2]));
      expect(selection.strokes[2], same(controller.strokes[4]));
      expect(selection.frame.center, _v(80, 100.5));
      expect(selection.frame.halfWidth, 52);
      expect(selection.frame.angle, 0);
    });

    test('an input stroke becomes derived, without raw samples', () {
      final InkController controller = InkController();
      addTearDown(controller.dispose);
      const StrokeStyle style = StrokeStyle(ink: InkPalette.ink, width: 2);
      controller.startStroke(
        pointer: 1,
        sample: _sample(0, 50, 0),
        style: style,
      );
      controller
        ..addSamples(1, <RawInkSample>[
          _sample(50, 50, 8),
          _sample(100, 50, 16),
        ])
        ..endStroke(1);
      final Stroke drawn = controller.strokes.single;
      expect(drawn.source, StrokeSource.input);
      expect(drawn.rawSamples, isNotEmpty);
      _lasso(controller, -20, 30, 120, 70);

      _transform(controller, _v(50, 50), _v(60, 80));

      final Stroke moved = controller.strokes.single;
      expect(moved.source, StrokeSource.derived);
      expect(moved.rawSamples, isEmpty);
      // The filtered points are moved as they are: none added, none
      // smoothed again.
      expect(moved.points.length, drawn.points.length);
      for (int i = 0; i < moved.points.length; i++) {
        expect(moved.points[i], drawn.points[i] + _v(10, 30));
      }
    });

    test('an identity move keeps the stroke instances and repaints no ink', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      final List<Stroke> before = List<Stroke>.of(controller.strokes);
      _selectGroup(page);
      final InkSelection selection = controller.selection!;

      // A press and release, then a trip away and exactly back.
      _transform(controller, _v(50, 60), _v(50, 60));
      _transform(
        controller,
        _v(50, 60),
        _v(50, 60),
        via: <InkVector>[_v(90, 10), _v(10, 90)],
      );
      // And one that ends within the tolerance of where it began.
      _transform(controller, _v(50, 60), _v(50.0005, 60));

      for (int i = 0; i < before.length; i++) {
        expect(controller.strokes[i], same(before[i]));
      }
      expect(controller.selection, same(selection));
      expect(page.completed, 0);
      expect(controller.activeTransform, isNull);
    });

    test('a cancelled move commits where it had got to', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      _selectGroup(page);

      controller.beginSelectionGesture(pointer: 1, position: _v(50, 60));
      controller
        ..updateSelectionGesture(1, _v(60, 65))
        ..cancelSelectionGesture(1);

      expect(controller.activeTransform, isNull);
      expect(controller.activePointer, isNull);
      expect(controller.strokes[1].points.first, _v(10, 55));
      expect(controller.selection!.indices, <int>[1, 2, 4]);
      expect(page.completed, 1);
    });

    test(
      'ending the active gesture commits a move and keeps the selection',
      () {
        final _Page page = _Page();
        final InkController controller = page.controller;
        _selectGroup(page);

        controller.beginSelectionGesture(pointer: 1, position: _v(50, 60));
        controller
          ..updateSelectionGesture(1, _v(60, 65))
          // As a rotation of the device does.
          ..finalizeActiveGesture();

        expect(controller.activeTransform, isNull);
        expect(controller.strokes[1].points.first, _v(10, 55));
        expect(controller.selection!.indices, <int>[1, 2, 4]);
        expect(controller.selection!.frame.center, _v(60, 65.5));
        // The pointer that was down no longer moves anything.
        controller
          ..updateSelectionGesture(1, _v(200, 200))
          ..endSelectionGesture(1, _v(200, 200));
        expect(controller.strokes[1].points.first, _v(10, 55));
        expect(page.completed, 1);
      },
    );

    test('ending the active gesture drops a lasso in progress', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      _selectGroup(page);
      final InkSelection before = controller.selection!;

      controller
        ..beginLasso(pointer: 1, position: _v(-20, 280))
        ..updateLasso(1, _v(120, 320))
        ..finalizeActiveGesture();

      expect(controller.activeLasso, isNull);
      expect(controller.selection, same(before));
    });

    test('may leave the page; nothing is clamped', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      _selectGroup(page);

      _transform(controller, _v(50, 60), _v(-450, -940));

      expect(controller.strokes[1].points.first, _v(-500, -950));
      expect(controller.selection!.frame.center, _v(-450, -939.5));
    });
  });

  group('scale', () {
    test('doubles points and widths about the opposite corner', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      final List<Stroke> before = List<Stroke>.of(controller.strokes);
      _selectGroup(page);

      // The bottom-right corner, dragged to twice its distance from the
      // top-left one at (-2, 49).
      controller.beginSelectionGesture(pointer: 1, position: _v(102, 72));
      expect(controller.activeTransform!.operation, SelectionOperation.scale);
      expect(controller.activeTransform!.corner, 2);
      controller.endSelectionGesture(1, _v(206, 95));

      InkVector scaled(InkVector p) =>
          _v(-2 + 2 * (p.x + 2), 49 + 2 * (p.y - 49));
      for (final int index in <int>[1, 2, 4]) {
        final Stroke stroke = controller.strokes[index];
        for (int i = 0; i < stroke.points.length; i++) {
          expect(stroke.points[i], _near(scaled(before[index].points[i])));
        }
        expect(
          stroke.style.width,
          closeTo(before[index].style.width * 2, 1e-12),
        );
        expect(stroke.style.ink, before[index].style.ink);
        expect(stroke.source, StrokeSource.derived);
        expect(stroke.rawSamples, isEmpty);
      }
      // The dot moved its center and grew; it is still a dot.
      expect(controller.strokes[2].isDot, isTrue);
      expect(controller.strokes[2].points.single, _near(_v(102, 71)));
      expect(controller.strokes[2].style.width, closeTo(12, 1e-12));
      expect(controller.strokes[0], same(before[0]));
      expect(controller.strokes[3], same(before[3]));
      expect(page.completed, 1);

      // The fixed corner did not move; the frame is the new rendered bounds.
      final SelectionFrame frame = controller.selection!.frame;
      expect(frame.corners[0], _near(_v(-2, 49)));
      expect(frame.corners[2], _near(_v(206, 95)));
      final SelectionFrame around = frameAround(controller.selection!.strokes);
      expect(frame.center, _near(around.center));
      expect(frame.halfWidth, closeTo(around.halfWidth, 1e-9));
      expect(frame.halfHeight, closeTo(around.halfHeight, 1e-9));
    });

    test('each corner scales about the one opposite it', () {
      for (int corner = 0; corner < 4; corner++) {
        final _Page page = _Page();
        final InkController controller = page.controller;
        _selectGroup(page);
        final SelectionFrame frame = controller.selection!.frame;
        final InkVector grabbed = frame.corners[corner];
        final InkVector fixed = frame.corners[(corner + 2) % 4];

        _transform(controller, grabbed, fixed + (grabbed - fixed) * 0.5);

        final SelectionFrame after = controller.selection!.frame;
        expect(
          after.corners[(corner + 2) % 4],
          _near(fixed),
          reason: '$corner',
        );
        expect(after.halfWidth, closeTo(26, 1e-9), reason: '$corner');
        expect(controller.strokes[1].style.width, closeTo(1, 1e-12));
        expect(controller.strokes[4].style.width, closeTo(2, 1e-12));
      }
    });

    test('clamps at the configured limits and never mirrors', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      _selectGroup(page);

      // Onto the fixed corner, then past it: the smallest scale, not zero
      // and not a flip.
      controller.beginSelectionGesture(pointer: 1, position: _v(102, 72));
      controller.updateSelectionGesture(1, _v(-2, 49));
      expect(controller.activeTransform!.transform.scale, 0.1);
      controller.updateSelectionGesture(1, _v(-3, 48.5));
      expect(controller.activeTransform!.transform.scale, 0.1);
      controller.updateSelectionGesture(1, _v(1e5, 1e5));
      expect(controller.activeTransform!.transform.scale, 10);
      controller.endSelectionGesture(1, _v(-2, 49));

      expect(controller.strokes[1].style.width, closeTo(0.2, 1e-12));
      expect(controller.strokes[4].style.width, closeTo(0.4, 1e-12));
      // Left to right is still left to right.
      expect(
        controller.strokes[1].points.last.x,
        greaterThan(controller.strokes[1].points.first.x),
      );
      expect(controller.selection!.frame.halfWidth, closeTo(5.2, 1e-9));
    });

    test('stops shrinking at the smallest stroke width', () {
      final InkController controller = InkController(
        strokes: <Stroke>[_line(50, width: 0.05), _line(60, width: 1)],
      );
      addTearDown(controller.dispose);
      _lasso(controller, -20, 30, 120, 80);
      final SelectionFrame frame = controller.selection!.frame;

      for (int i = 0; i < 5; i++) {
        final SelectionFrame now = controller.selection!.frame;
        _transform(controller, now.corners[2], now.corners[0]);
      }

      // 0.05 px can shrink five-fold to the 0.01 px floor, and no further.
      expect(controller.strokes[0].style.width, closeTo(0.01, 1e-12));
      expect(controller.strokes[1].style.width, closeTo(0.2, 1e-12));
      expect(
        controller.selection!.frame.halfWidth,
        closeTo(frame.halfWidth / 5, 1e-9),
      );
    });

    test('a scale that would leave the coordinate range is refused', () {
      final _Page page = _Page(
        config: const SelectionConfig(maxCoordinate: 500),
      );
      final InkController controller = page.controller;
      _selectGroup(page);

      controller.beginSelectionGesture(pointer: 1, position: _v(102, 72));
      controller.updateSelectionGesture(1, _v(206, 95));
      page.resetCounts();
      // Ten-fold would reach x = 1038.
      controller.updateSelectionGesture(1, _v(5000, 5000));
      expect(page.selection, 0);
      expect(controller.activeTransform!.transform.scale, closeTo(2, 1e-12));
      controller.endSelectionGesture(1, _v(5000, 5000));

      expect(controller.strokes[1].style.width, closeTo(4, 1e-12));

      // A move is held to the same range.
      _transform(controller, _v(100, 70), _v(100, 5000));
      expect(controller.selection!.frame.isWithin(500), isTrue);
    });
  });

  group('rotate', () {
    test('turns points and frame about the frame center; widths stay', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      final List<Stroke> before = List<Stroke>.of(controller.strokes);
      _selectGroup(page);
      final InkVector center = _v(50, 60.5);

      // From the handle, straight above the center, round to its right.
      controller.beginSelectionGesture(pointer: 1, position: _v(50, 17));
      expect(controller.activeTransform!.operation, SelectionOperation.rotate);
      controller.endSelectionGesture(1, _v(120, 60.5));

      InkVector turned(InkVector p) {
        final InkVector offset = p - center;
        return center + _v(-offset.y, offset.x);
      }

      for (final int index in <int>[1, 2, 4]) {
        final Stroke stroke = controller.strokes[index];
        for (int i = 0; i < stroke.points.length; i++) {
          expect(stroke.points[i], _near(turned(before[index].points[i])));
        }
        expect(stroke.style, same(before[index].style));
        expect(stroke.source, StrokeSource.derived);
      }
      expect(controller.strokes[1].points.first, _near(_v(60.5, 10.5)));
      expect(page.completed, 1);

      // The frame turned with the ink instead of growing a new upright box.
      final SelectionFrame frame = controller.selection!.frame;
      expect(frame.angle, closeTo(math.pi / 2, 1e-12));
      expect(frame.center, _near(center));
      expect(frame.halfWidth, 52);
      expect(frame.halfHeight, 11.5);
    });

    test('the orientation lasts through later moves and scales', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      _selectGroup(page);
      _transform(controller, _v(50, 17), _v(120, 60.5));

      _transform(controller, _v(50, 60.5), _v(250, 260.5));
      expect(controller.selection!.frame.angle, closeTo(math.pi / 2, 1e-12));
      expect(controller.selection!.frame.center, _near(_v(250, 260.5)));

      // Grab a corner of the turned frame; its opposite stays put.
      final SelectionFrame turned = controller.selection!.frame;
      final InkVector fixed = turned.corners[3];
      controller.beginSelectionGesture(pointer: 1, position: turned.corners[1]);
      expect(controller.activeTransform!.corner, 1);
      controller.endSelectionGesture(
        1,
        fixed + (turned.corners[1] - fixed) * 2,
      );

      final SelectionFrame scaled = controller.selection!.frame;
      expect(scaled.angle, closeTo(math.pi / 2, 1e-12));
      expect(scaled.corners[3], _near(fixed));
      expect(scaled.halfWidth, closeTo(104, 1e-9));
      expect(scaled.halfHeight, closeTo(23, 1e-9));
      expect(controller.strokes[4].style.width, closeTo(8, 1e-12));
    });

    test('four quarter turns come back without adding points', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      final List<List<InkVector>> before = _points(controller);
      _selectGroup(page);

      for (int i = 0; i < 4; i++) {
        final SelectionFrame frame = controller.selection!.frame;
        final InkVector handle = frame.rotationHandle(32);
        final InkVector offset = handle - frame.center;
        _transform(controller, handle, frame.center + _v(-offset.y, offset.x));
      }

      final List<List<InkVector>> after = _points(controller);
      for (int s = 0; s < before.length; s++) {
        expect(after[s].length, before[s].length);
        for (int i = 0; i < before[s].length; i++) {
          expect(after[s][i], _near(before[s][i], 1e-9));
        }
      }
      expect(controller.selection!.frame.angle, closeTo(0, 1e-9));
      expect(controller.selection!.frame.halfWidth, 52);
    });

    test('a pointer over the center keeps the last valid rotation', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      _selectGroup(page);

      controller.beginSelectionGesture(pointer: 1, position: _v(50, 17));
      controller.updateSelectionGesture(1, _v(120, 60.5));
      final InkTransform quarter = controller.activeTransform!.transform;
      controller.updateSelectionGesture(1, _v(50, 60.5));

      expect(controller.activeTransform!.transform, quarter);
      controller.endSelectionGesture(1, _v(50, 60.5));
      expect(controller.selection!.frame.angle, closeTo(math.pi / 2, 1e-12));
    });
  });

  test('the result does not depend on how many samples the gesture had', () {
    List<List<InkVector>> run(InkVector from, InkVector to, int samples) {
      final _Page page = _Page();
      _selectGroup(page);
      _transform(
        page.controller,
        from,
        to,
        via: <InkVector>[
          for (int i = 1; i < samples; i++)
            from +
                (to - from) * (i / samples) +
                _v(7 * math.sin(i), 5 * math.cos(i)),
        ],
      );
      return _points(page.controller);
    }

    for (final (InkVector from, InkVector to) in <(InkVector, InkVector)>[
      // A move, a scale from the bottom-right corner, and a rotation.
      (_v(50, 60), _v(-130, 240)),
      (_v(102, 72), _v(260, 30)),
      (_v(50, 17), _v(-40, 130)),
    ]) {
      final List<List<InkVector>> direct = run(from, to, 1);
      for (final int samples in <int>[2, 17, 400]) {
        expect(run(from, to, samples), direct, reason: '$from, $samples');
      }
    }
  });

  group('copy', () {
    test('snapshots the selection and changes nothing else', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      final List<Stroke> before = List<Stroke>.of(controller.strokes);
      _selectGroup(page);
      final InkSelection selection = controller.selection!;
      expect(controller.canPaste, isFalse);

      expect(controller.copySelection(), isTrue);

      expect(controller.strokes, before);
      expect(controller.selection, same(selection));
      expect(page.completed, 0);
      // Paste just became available.
      expect(page.selection, 1);
      expect(controller.canPaste, isTrue);
      final InkClipboard clipboard = controller.clipboard!;
      expect(clipboard.strokes.length, 3);
      // Document order, with each stroke's own look.
      expect(clipboard.strokes[0].points, before[1].points);
      expect(clipboard.strokes[1].points, before[2].points);
      expect(clipboard.strokes[2].points, before[4].points);
      expect(clipboard.strokes[2].style.ink, _blue);
      expect(clipboard.strokes[2].style.width, 4);
      expect(clipboard.frame.center, selection.frame.center);
      expect(
        () => clipboard.strokes[0].points.add(_v(0, 0)),
        throwsUnsupportedError,
      );
    });

    test('does nothing without a selection', () {
      final _Page page = _Page();

      expect(page.controller.copySelection(), isFalse);
      expect(page.controller.cutSelection(), isFalse);
      expect(page.controller.paste(), isFalse);

      expect(page.controller.canPaste, isFalse);
      expect(page.controller.strokes.length, 5);
      expect(page.completed, 0);
      expect(page.selection, 0);
    });

    test('commits a transform in progress first, and copies the result', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      _selectGroup(page);

      controller.beginSelectionGesture(pointer: 1, position: _v(50, 60));
      controller.updateSelectionGesture(1, _v(80, 100));
      controller.copySelection();

      expect(controller.activeTransform, isNull);
      expect(controller.strokes[1].points.first, _v(30, 90));
      expect(controller.clipboard!.strokes[0].points.first, _v(30, 90));
      expect(controller.clipboard!.frame.center, _v(80, 100.5));
    });

    test('is not changed by what happens to the document afterwards', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      _selectGroup(page);
      controller.copySelection();
      final InkClipboard clipboard = controller.clipboard!;
      final List<List<InkVector>> copied = <List<InkVector>>[
        for (final ClipboardStroke stroke in clipboard.strokes)
          List<InkVector>.of(stroke.points),
      ];

      // Scale, rotate, then rub out everything that was copied.
      _transform(controller, _v(102, 72), _v(206, 95));
      final SelectionFrame frame = controller.selection!.frame;
      _transform(
        controller,
        frame.rotationHandle(32),
        frame.center + _v(90, 0),
      );
      controller
        ..startErase(
          pointer: 1,
          position: _v(-100, -100),
          settings: const EraserSettings(mode: EraserMode.area, size: 80),
        )
        ..eraseTo(1, _v(400, 250))
        ..endErase(1);

      expect(controller.clipboard, same(clipboard));
      for (int i = 0; i < copied.length; i++) {
        expect(clipboard.strokes[i].points, copied[i]);
      }
      expect(clipboard.strokes[0].style.width, 2);
      expect(clipboard.strokes[2].style.width, 4);
      expect(clipboard.frame.halfWidth, 52);
      expect(clipboard.frame.angle, 0);
    });
  });

  group('cut', () {
    test('copies, then removes exactly the selection in one change', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      final List<Stroke> before = List<Stroke>.of(controller.strokes);
      _selectGroup(page);

      expect(controller.cutSelection(), isTrue);

      // The unselected strokes, in order, as the same objects.
      expect(controller.strokes.length, 2);
      expect(controller.strokes[0], same(before[0]));
      expect(controller.strokes[1], same(before[3]));
      expect(controller.selection, isNull);
      expect(page.completed, 1);
      expect(controller.canPaste, isTrue);
      expect(controller.clipboard!.strokes.length, 3);
      expect(controller.clipboard!.strokes[0].points, before[1].points);
      expect(controller.clipboard!.strokes[2].style.ink, _blue);
    });

    test('what was cut can be pasted back', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      final List<Stroke> before = List<Stroke>.of(controller.strokes);
      _selectGroup(page);
      controller.cutSelection();

      expect(controller.paste(), isTrue);

      expect(controller.strokes.length, 5);
      expect(controller.selection!.indices, <int>[2, 3, 4]);
      expect(
        controller.strokes[2].points.first,
        before[1].points.first + _v(24, 24),
      );
      expect(controller.strokes[4].style.width, 4);
    });
  });

  group('paste', () {
    test('appends independent derived copies and selects them', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      final List<Stroke> before = List<Stroke>.of(controller.strokes);
      _selectGroup(page);
      controller.copySelection();
      page.resetCounts();

      expect(controller.paste(), isTrue);

      final List<Stroke> after = controller.strokes;
      expect(after.length, 8);
      // Everything that was there is still there, untouched, underneath.
      for (int i = 0; i < before.length; i++) {
        expect(after[i], same(before[i]));
      }
      expect(page.completed, 1);
      // Clipboard order is document order, so stacking within the group is
      // kept.
      final List<int> sources = <int>[1, 2, 4];
      for (int i = 0; i < 3; i++) {
        final Stroke pasted = after[5 + i];
        final Stroke source = before[sources[i]];
        expect(pasted, isNot(same(source)));
        expect(pasted.source, StrokeSource.derived);
        expect(pasted.rawSamples, isEmpty);
        expect(pasted.style.ink, source.style.ink);
        expect(pasted.style.width, source.style.width);
        expect(pasted.isDot, source.isDot);
        expect(pasted.points.length, source.points.length);
        for (int p = 0; p < pasted.points.length; p++) {
          expect(pasted.points[p], source.points[p] + _v(24, 24));
        }
        expect(pasted.bounds, source.bounds.shift(const Offset(24, 24)));
      }
      final InkSelection selection = controller.selection!;
      expect(selection.indices, <int>[5, 6, 7]);
      expect(selection.strokes[0], same(after[5]));
      expect(selection.frame.center, _v(74, 84.5));
      expect(selection.frame.halfWidth, 52);
    });

    test('each paste lands one more offset away; a new copy starts over', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      _selectGroup(page);
      controller.copySelection();

      controller
        ..paste()
        ..paste()
        ..paste();

      expect(controller.strokes.length, 14);
      expect(controller.strokes[5].points.first, _v(24, 74));
      expect(controller.strokes[8].points.first, _v(48, 98));
      expect(controller.strokes[11].points.first, _v(72, 122));
      expect(controller.selection!.indices, <int>[11, 12, 13]);

      // Moving a pasted copy does not disturb the cascade.
      _transform(controller, _v(122, 132.5), _v(322, 132.5));
      controller.paste();
      expect(controller.strokes[14].points.first, _v(96, 146));

      // Copying the newest paste restarts it from that ink.
      controller
        ..copySelection()
        ..paste();
      expect(controller.strokes[17].points.first, _v(120, 170));

      // So does a cut.
      controller
        ..cutSelection()
        ..paste();
      expect(controller.strokes.length, 20);
      expect(controller.strokes[17].points.first, _v(144, 194));
    });

    test('keeps a rotated frame, and the cascade offset is configurable', () {
      final _Page page = _Page(
        config: const SelectionConfig(pasteOffset: InkVector(-10, 5)),
      );
      final InkController controller = page.controller;
      _selectGroup(page);
      _transform(controller, _v(50, 17), _v(120, 60.5));
      final InkVector first = controller.strokes[1].points.first;
      controller.copySelection();

      controller.paste();

      expect(controller.strokes[5].points.first, _near(first + _v(-10, 5)));
      expect(controller.selection!.frame.angle, closeTo(math.pi / 2, 1e-12));
      expect(controller.selection!.frame.center, _near(_v(40, 65.5)));
    });

    test('pasted ink is separate from the clipboard and from its source', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      final List<Stroke> before = List<Stroke>.of(controller.strokes);
      _selectGroup(page);
      controller
        ..copySelection()
        ..paste();

      // Move the paste, then erase part of it.
      _transform(controller, _v(74, 84.5), _v(74, 184.5));
      controller
        ..startErase(
          pointer: 1,
          position: _v(74, 150),
          settings: const EraserSettings(mode: EraserMode.area, size: 20),
        )
        ..eraseTo(1, _v(74, 220))
        ..endErase(1);

      // The moved lines were cut in two, like any other strokes.
      expect(controller.strokes.length, greaterThan(8));
      for (int i = 0; i < before.length; i++) {
        expect(controller.strokes[i], same(before[i]));
      }
      expect(controller.clipboard!.strokes[0].points, before[1].points);
      controller.paste();
      expect(controller.strokes.last.points.first, _v(48, 118));
      expect(controller.strokes.last.points.length, 11);
    });

    test('ends a gesture in progress before pasting', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      _selectGroup(page);
      controller.copySelection();
      controller.beginSelectionGesture(pointer: 1, position: _v(50, 60));
      controller.updateSelectionGesture(1, _v(50, 160));

      controller.paste();

      expect(controller.activeTransform, isNull);
      expect(controller.activePointer, isNull);
      // The move was committed; the paste comes from the copy made before.
      expect(controller.strokes[1].points.first, _v(0, 150));
      expect(controller.strokes[5].points.first, _v(24, 74));
      expect(controller.selection!.indices, <int>[5, 6, 7]);
    });

    test('with a position, centers the copies there, outside the cascade', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      final List<Stroke> before = List<Stroke>.of(controller.strokes);
      _selectGroup(page);
      controller.copySelection();
      page.resetCounts();

      // The copied frame is centered on (50, 60.5).
      expect(controller.paste(at: _v(450, 360.5)), isTrue);

      expect(controller.strokes.length, 8);
      expect(page.completed, 1);
      expect(controller.selection!.indices, <int>[5, 6, 7]);
      expect(controller.selection!.frame.center, _v(450, 360.5));
      expect(controller.strokes[5].points.first, _v(400, 350));
      expect(controller.strokes[7].style.ink, _blue);
      expect(controller.strokes[5].source, StrokeSource.derived);
      for (int i = 0; i < before.length; i++) {
        expect(controller.strokes[i], same(before[i]));
      }

      // The next plain paste is still the first step of the cascade.
      controller.paste();
      expect(controller.strokes[8].points.first, _v(24, 74));

      expect(controller.paste(at: _v(double.nan, 0)), isFalse);
      expect(controller.strokes.length, 11);
    });

    test('a paste that cannot be placed is refused', () {
      for (final SelectionConfig config in const <SelectionConfig>[
        SelectionConfig(pasteOffset: InkVector(double.nan, 0)),
        SelectionConfig(pasteOffset: InkVector(double.infinity, 24)),
        SelectionConfig(maxCoordinate: 110),
      ]) {
        final _Page page = _Page(config: config);
        final InkController controller = page.controller;
        _selectGroup(page);
        controller.copySelection();
        page.resetCounts();

        expect(controller.paste(), isFalse);

        expect(controller.strokes.length, 5);
        expect(controller.selection!.indices, <int>[1, 2, 4]);
        expect(page.completed, 0);
      }
    });
  });

  group('selection and other tools', () {
    test('clearing the selection leaves the ink and the clipboard', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      final List<Stroke> before = List<Stroke>.of(controller.strokes);
      _selectGroup(page);
      controller.copySelection();
      page.resetCounts();

      controller.clearSelection();

      expect(controller.selection, isNull);
      expect(controller.strokes, before);
      expect(controller.canPaste, isTrue);
      expect(page.completed, 1);
      expect(page.selection, 1);

      // Nothing left to clear: nothing to announce.
      controller.clearSelection();
      expect(page.completed, 1);
      expect(page.selection, 1);
    });

    test('clearing commits a transform in progress', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      _selectGroup(page);
      controller.beginSelectionGesture(pointer: 1, position: _v(50, 60));
      controller.updateSelectionGesture(1, _v(60, 65));

      controller.clearSelection();

      expect(controller.activeTransform, isNull);
      expect(controller.selection, isNull);
      expect(controller.strokes[1].points.first, _v(10, 55));
    });

    test('erasing drops the selection and cuts transformed ink as usual', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      _selectGroup(page);
      _transform(controller, _v(50, 60), _v(50, 160));

      // Down through the moved thin line at y = 150.
      controller
        ..startErase(
          pointer: 1,
          position: _v(50, 140),
          settings: const EraserSettings(mode: EraserMode.area, size: 10),
        )
        ..eraseTo(1, _v(50, 151))
        ..endErase(1);

      expect(controller.selection, isNull);
      expect(controller.strokes.length, 6);
      // Radius 5 plus half the 2 px width.
      expect(controller.strokes[1].points.last.x, closeTo(44, 1e-9));
      expect(controller.strokes[2].points.first.x, closeTo(56, 1e-9));
      expect(controller.strokes[1].source, StrokeSource.derived);
    });

    test('a stroke drawn while ink is selected leaves the selection valid', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      _selectGroup(page);

      controller.startStroke(
        pointer: 1,
        sample: _sample(0, 200, 0),
        style: const StrokeStyle(ink: InkPalette.ink, width: 2),
      );
      controller.endStroke(1, <RawInkSample>[_sample(100, 200, 8)]);

      expect(controller.strokes.length, 6);
      final InkSelection selection = controller.selection!;
      for (int i = 0; i < selection.count; i++) {
        expect(
          controller.strokes[selection.indices[i]],
          same(selection.strokes[i]),
        );
      }
    });
  });

  group('hidden strokes', () {
    test('hiding is presentation only, and announced once', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      final List<Stroke> before = List<Stroke>.of(controller.strokes);
      final int revision = controller.documentRevision;
      int hidden = 0;
      controller.hiddenStrokesListenable.addListener(() => hidden++);

      controller.setStrokesHidden(<Stroke>[before[1], before[4]], true);

      expect(controller.isStrokeHidden(before[1]), isTrue);
      expect(controller.isStrokeHidden(before[4]), isTrue);
      expect(controller.isStrokeHidden(before[2]), isFalse);
      expect(controller.strokes, before);
      expect(controller.documentRevision, revision);
      expect(controller.canUndo, isFalse);
      expect(hidden, 1);
      expect(page.completed, 1);

      // Already hidden: nothing to announce.
      controller.setStrokesHidden(<Stroke>[before[1]], true);
      expect(hidden, 1);

      controller.setStrokesHidden(<Stroke>[before[1], before[4]], false);
      expect(controller.isStrokeHidden(before[1]), isFalse);
      expect(hidden, 2);
    });

    test('the lasso and the eraser pass over hidden strokes', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      final Stroke thin = controller.strokes[1];
      controller.setStrokesHidden(<Stroke>[thin], true);

      _lasso(controller, -20, 30, 120, 90);
      expect(controller.selection!.indices, <int>[2, 4]);

      controller.clearSelection();
      controller
        ..startErase(
          pointer: 1,
          position: _v(50, 40),
          settings: const EraserSettings(mode: EraserMode.stroke, size: 10),
        )
        ..eraseTo(1, _v(50, 52))
        ..endErase(1);
      expect(controller.strokes, contains(same(thin)));
    });

    test('hidden ink moved with the selection stays hidden', () {
      final _Page page = _Page();
      final InkController controller = page.controller;
      _selectGroup(page);
      final Stroke thin = controller.strokes[1];
      controller.setStrokesHidden(<Stroke>[thin], true);
      final List<Map<Stroke, Stroke>> replacements = <Map<Stroke, Stroke>>[];
      controller.addStrokeReplacementListener(replacements.add);

      _transform(controller, _v(50, 60), _v(50, 160));

      final Stroke moved = controller.strokes[1];
      expect(moved, isNot(same(thin)));
      expect(controller.isStrokeHidden(moved), isTrue);
      expect(replacements.single[thin], same(moved));

      // An undo brings back the stroke it replaced, still hidden.
      controller.undo();
      expect(controller.strokes[1], same(thin));
      expect(controller.isStrokeHidden(thin), isTrue);
    });
  });
}
