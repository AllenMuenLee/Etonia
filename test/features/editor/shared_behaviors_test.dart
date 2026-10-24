import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/page/note_document.dart';

RawInkSample _sample(InkVector at, int ms) => RawInkSample(
  position: at,
  timestamp: Duration(milliseconds: ms),
);

void _draw(InkController controller, InkVector from, InkVector to) {
  controller.startStroke(
    pointer: 1,
    sample: _sample(from, 0),
    style: const StrokeStyle(ink: InkPalette.ink, width: 3),
  );
  for (int i = 1; i <= 10; i++) {
    controller.addSamples(1, <RawInkSample>[
      _sample(from + (to - from) * (i / 10), i * 8),
    ]);
  }
  controller.endStroke(1);
}

void main() {
  group('history shared by the pages', () {
    test('undo and redo follow the order of changes across pages', () {
      final NoteDocument document = NoteDocument();
      document.addPage();
      final InkController first = document.pages[0].ink;
      final InkController second = document.pages[1].ink;
      expect(identical(first.history, second.history), isTrue);

      _draw(first, const InkVector(10, 10), const InkVector(100, 10));
      _draw(second, const InkVector(10, 20), const InkVector(100, 20));
      expect(document.currentIndex, 1);
      document.goTo(0);

      // The page not shown is undone first, and comes into view.
      expect(document.undo(), isTrue);
      expect(second.strokes, isEmpty);
      expect(first.strokes, hasLength(1));
      expect(document.currentIndex, 1);
      expect(first.canUndo, isTrue);
      expect(second.canRedo, isTrue);

      expect(document.undo(), isTrue);
      expect(first.strokes, isEmpty);
      expect(document.currentIndex, 0);
      expect(document.undo(), isFalse);

      expect(document.redo(), isTrue);
      expect(first.strokes, hasLength(1));
      expect(document.redo(), isTrue);
      expect(second.strokes, hasLength(1));
      expect(document.currentIndex, 1);
      document.dispose();
    });

    test('a deleted page leaves no steps behind', () {
      final NoteDocument document = NoteDocument();
      document.addPage();
      final InkController second = document.pages[1].ink;
      _draw(
        document.pages[0].ink,
        const InkVector(10, 10),
        const InkVector(90, 10),
      );
      _draw(second, const InkVector(10, 20), const InkVector(90, 20));

      expect(document.deletePage(1), isTrue);
      expect(document.undo(), isTrue);
      expect(document.pages.single.ink.strokes, isEmpty);
      expect(document.undo(), isFalse);
      document.dispose();
    });
  });

  group('selecting paper with ink', () {
    const Rect paper = Rect.fromLTWH(0, 0, 800, 1000);

    InkController withMark() {
      final InkController controller = InkController();
      _draw(controller, const InkVector(300, 300), const InkVector(400, 320));
      return controller;
    }

    test('a loop hugging the ink takes the ink alone', () {
      final InkController controller = withMark();
      controller.selectWithOutline(const <InkVector>[
        InkVector(290, 290),
        InkVector(410, 290),
        InkVector(410, 330),
        InkVector(290, 330),
      ], selectablePdfBounds: paper);
      expect(controller.selection!.count, 1);
      expect(controller.selection!.includesPdf, isFalse);
    });

    test('a loop drawn well clear of the ink takes the paper too', () {
      final InkController controller = withMark();
      controller.selectWithOutline(const <InkVector>[
        InkVector(200, 200),
        InkVector(500, 200),
        InkVector(500, 450),
        InkVector(200, 450),
      ], selectablePdfBounds: paper);
      expect(controller.selection!.count, 1);
      expect(controller.selection!.includesPdf, isTrue);
    });
  });
}
