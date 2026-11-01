import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/document_io/document_models.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/ink_selection.dart';
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

    test('without selectable paper, a loop takes the ink alone', () {
      final InkController controller = withMark();
      controller.selectWithOutline(const <InkVector>[
        InkVector(200, 200),
        InkVector(500, 200),
        InkVector(500, 450),
        InkVector(200, 450),
      ]);
      expect(controller.selection!.count, 1);
      expect(controller.selection!.includesPdf, isFalse);
    });

    test('with selectable paper, even a loop hugging the ink takes it', () {
      final InkController controller = withMark();
      controller.selectWithOutline(const <InkVector>[
        InkVector(290, 290),
        InkVector(410, 290),
        InkVector(410, 330),
        InkVector(290, 330),
      ], selectablePdfBounds: paper);
      expect(controller.selection!.count, 1);
      expect(
        controller.selection!.pdfBounds,
        const Rect.fromLTRB(290, 290, 410, 330),
      );
    });

    test('Delete leaves the selected paper blank, as one undoable step', () {
      final InkController controller = withMark();
      controller.selectWithOutline(const <InkVector>[
        InkVector(200, 200),
        InkVector(500, 200),
        InkVector(500, 450),
        InkVector(200, 450),
      ], selectablePdfBounds: paper);
      expect(controller.deleteSelection(), isTrue);
      expect(controller.strokes, isEmpty);
      expect(controller.pdfMasks, const <Rect>[
        Rect.fromLTRB(200, 200, 500, 450),
      ]);
      expect(controller.undo(), isTrue);
      expect(controller.strokes, hasLength(1));
      expect(controller.pdfMasks, isEmpty);
    });

    test('paper alone can be deleted', () {
      final InkController controller = InkController();
      controller.selectWithOutline(const <InkVector>[
        InkVector(10, 10),
        InkVector(60, 10),
        InkVector(60, 40),
        InkVector(10, 40),
      ], selectablePdfBounds: paper);
      expect(controller.deleteSelection(), isTrue);
      expect(controller.pdfMasks, const <Rect>[Rect.fromLTRB(10, 10, 60, 40)]);
    });

    group('moving paper', () {
      const Rect excerpt = Rect.fromLTRB(200, 200, 500, 450);
      final NoteImageElement image = NoteImageElement(
        id: 'pdf-excerpt',
        assetId: 'excerpt-asset',
        pixelSize: const Size(300, 250),
        center: InkVector(excerpt.center.dx, excerpt.center.dy),
        size: excerpt.size,
      );

      InkController selectedWithLift() {
        final InkController controller = withMark();
        controller.selectWithOutline(const <InkVector>[
          InkVector(200, 200),
          InkVector(500, 200),
          InkVector(500, 450),
          InkVector(200, 450),
        ], selectablePdfBounds: paper);
        controller.preparePdfLift(controller.selection!, image);
        return controller;
      }

      test('a drag lifts it off the page and moves it with the ink', () {
        final InkController controller = selectedWithLift();
        final InkVector start = controller.strokes.single.points.first;
        expect(
          controller.beginSelectionGesture(
            pointer: 1,
            position: const InkVector(350, 400),
          ),
          isTrue,
        );
        controller.updateSelectionGesture(1, const InkVector(450, 500));
        controller.endSelectionGesture(1, const InkVector(450, 500));

        expect(controller.pdfMasks, const <Rect>[excerpt]);
        expect(controller.images.single.assetId, 'excerpt-asset');
        expect(controller.images.single.center, const InkVector(450, 425));
        expect(
          controller.strokes.single.points.first,
          start + const InkVector(100, 100),
        );
        expect(controller.selection!.includesPdf, isFalse);
        expect(controller.pendingPdfLift, isNull);

        // The lift and the move are one step.
        expect(controller.undo(), isTrue);
        expect(controller.pdfMasks, isEmpty);
        expect(controller.images, isEmpty);
        expect(controller.strokes.single.points.first, start);
      });

      test('a press that moves nothing puts the paper back', () {
        final InkController controller = selectedWithLift();
        final InkSelection selection = controller.selection!;
        expect(
          controller.beginSelectionGesture(
            pointer: 1,
            position: const InkVector(350, 400),
          ),
          isTrue,
        );
        controller.endSelectionGesture(1, const InkVector(350, 400));

        expect(controller.pdfMasks, isEmpty);
        expect(controller.images, isEmpty);
        expect(controller.selection, same(selection));
        expect(controller.pendingPdfLift, same(image));
        // Nothing is left in the history: the last step is the mark drawn.
        expect(controller.undo(), isTrue);
        expect(controller.strokes, isEmpty);
      });

      test('without a readied image, a press draws a lasso instead', () {
        final InkController controller = withMark();
        controller.selectWithOutline(const <InkVector>[
          InkVector(200, 200),
          InkVector(500, 200),
          InkVector(500, 450),
          InkVector(200, 450),
        ], selectablePdfBounds: paper);
        expect(
          controller.beginSelectionGesture(
            pointer: 1,
            position: const InkVector(350, 400),
          ),
          isTrue,
        );
        expect(controller.activeTransform, isNull);
        expect(controller.activeLasso, isNotNull);
      });
    });
  });
}
