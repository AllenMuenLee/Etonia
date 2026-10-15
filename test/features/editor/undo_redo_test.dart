import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

import '../../helpers/editor_harness.dart';

const StrokeStyle _style = StrokeStyle(ink: InkPalette.ink, width: 3);

Stroke _line(double y) => Stroke.fromPoints(
  style: _style,
  points: <InkVector>[InkVector(100, y), InkVector(300, y)],
);

/// Draws a horizontal stroke at [y] through the controller.
void _write(InkController controller, double y) {
  controller.startStroke(
    pointer: 1,
    sample: RawInkSample(position: InkVector(100, y), timestamp: Duration.zero),
    style: _style,
  );
  controller.addSamples(1, <RawInkSample>[
    RawInkSample(
      position: InkVector(300, y),
      timestamp: const Duration(milliseconds: 16),
    ),
  ]);
  controller.endStroke(1);
}

void main() {
  group('history', () {
    test('a new page has nothing to undo or redo', () {
      final InkController controller = InkController(
        strokes: <Stroke>[_line(100)],
      );
      addTearDown(controller.dispose);
      expect(controller.canUndo, isFalse);
      expect(controller.canRedo, isFalse);
      expect(controller.undo(), isFalse);
      expect(controller.redo(), isFalse);
      expect(controller.strokes, hasLength(1));
    });

    test('undo and redo step through each committed stroke', () {
      final InkController controller = InkController();
      addTearDown(controller.dispose);
      _write(controller, 100);
      _write(controller, 200);
      final List<Stroke> both = List<Stroke>.of(controller.strokes);

      expect(controller.undo(), isTrue);
      expect(controller.strokes, <Stroke>[both[0]]);
      expect(controller.canRedo, isTrue);
      expect(controller.undo(), isTrue);
      expect(controller.strokes, isEmpty);
      expect(controller.canUndo, isFalse);

      expect(controller.redo(), isTrue);
      expect(controller.redo(), isTrue);
      expect(controller.strokes, both);
      expect(controller.canRedo, isFalse);
    });

    test('a whole erase gesture is one step', () {
      final InkController controller = InkController(
        strokes: <Stroke>[_line(100), _line(200)],
      );
      addTearDown(controller.dispose);
      final List<Stroke> before = List<Stroke>.of(controller.strokes);
      const EraserSettings settings = EraserSettings(
        mode: EraserMode.stroke,
        size: 20,
      );
      controller.startErase(
        pointer: 2,
        position: const InkVector(200, 100),
        settings: settings,
      );
      controller.eraseTo(2, const InkVector(200, 200));
      controller.endErase(2);
      expect(controller.strokes, isEmpty);

      expect(controller.undo(), isTrue);
      expect(controller.strokes, before);
      expect(controller.canUndo, isFalse);
    });

    test('a new change drops what could have been redone', () {
      final InkController controller = InkController();
      addTearDown(controller.dispose);
      _write(controller, 100);
      controller.undo();
      expect(controller.canRedo, isTrue);
      _write(controller, 200);
      expect(controller.canRedo, isFalse);
      expect(controller.strokes.single.points.first.y, 200);
    });

    test('undo bumps the revision, drops the selection, and waits on a '
        'gesture in progress', () {
      final InkController controller = InkController();
      addTearDown(controller.dispose);
      _write(controller, 100);
      controller.beginLasso(pointer: 3, position: const InkVector(50, 50));
      expect(controller.undo(), isFalse);
      controller.cancelLasso(3);
      controller
        ..beginLasso(pointer: 3, position: const InkVector(50, 50))
        ..updateLasso(3, const InkVector(350, 50))
        ..updateLasso(3, const InkVector(350, 150))
        ..updateLasso(3, const InkVector(50, 150))
        ..endLasso(3, const InkVector(50, 50));
      expect(controller.selection, isNotNull);

      final int revision = controller.documentRevision;
      expect(controller.undo(), isTrue);
      expect(controller.documentRevision, greaterThan(revision));
      expect(controller.selection, isNull);
    });

    test('history is bounded', () {
      final InkController controller = InkController(historyLimit: 3);
      addTearDown(controller.dispose);
      for (int i = 0; i < 5; i++) {
        _write(controller, 100 + 20.0 * i);
      }
      int undone = 0;
      while (controller.undo()) {
        undone++;
      }
      expect(undone, 3);
      expect(controller.strokes, hasLength(2));
    });
  });

  group('editor', () {
    testWidgets('the top bar offers Undo and Redo, enabled only when they '
        'can act', (WidgetTester tester) async {
      final InkController controller = await pumpEditor(tester);
      Finder button(String tooltip) => find.byTooltip(tooltip);

      bool enabled(String tooltip) {
        return tester
                .widget<IconButton>(
                  find.ancestor(
                    of: button(tooltip),
                    matching: find.byType(IconButton),
                  ),
                )
                .onPressed !=
            null;
      }

      expect(enabled('Undo'), isFalse);
      expect(enabled('Redo'), isFalse);

      _write(controller, 300);
      await tester.pump();
      expect(enabled('Undo'), isTrue);

      await tester.tap(button('Undo'));
      await tester.pump();
      expect(controller.strokes, isEmpty);
      expect(enabled('Undo'), isFalse);
      expect(enabled('Redo'), isTrue);

      await tester.tap(button('Redo'));
      await tester.pump();
      expect(controller.strokes, hasLength(1));
      expect(tester.getSize(button('Undo')).width, greaterThanOrEqualTo(48));
    });

    testWidgets('Ctrl+Z undoes and Ctrl+Shift+Z or Ctrl+Y redoes', (
      WidgetTester tester,
    ) async {
      final InkController controller = await pumpEditor(tester);
      _write(controller, 300);
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      expect(controller.strokes, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyY);
      expect(controller.strokes, hasLength(1));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(controller.strokes, hasLength(1));
    });
  });
}
