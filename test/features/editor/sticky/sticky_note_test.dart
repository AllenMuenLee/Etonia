import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/selection_transform.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/sticky/sticky_note.dart';
import 'package:greatnote/features/editor/sticky/sticky_note_painter.dart';
import 'package:greatnote/features/library/note_content.dart';

const StickyNoteConfig _config = StickyNoteConfig();

StickyNoteElement _note({
  String id = 'a',
  InkVector center = const InkVector(300, 300),
  Size size = const Size(240, 180),
  double rotation = 0,
  double scale = 1,
  String colorId = 'yellow',
  StickyPaperStyle paper = StickyPaperStyle.lined,
  List<Stroke> strokes = const <Stroke>[],
}) {
  return StickyNoteElement(
    id: id,
    center: center,
    size: size,
    rotation: rotation,
    scale: scale,
    colorId: colorId,
    paper: paper,
    strokes: strokes,
  );
}

Stroke _line(InkVector from, InkVector to, {double width = 3}) {
  return Stroke.fromPoints(
    style: StrokeStyle(ink: InkPalette.ink, width: width),
    points: <InkVector>[from, to],
  );
}

RawInkSample _sample(InkVector at, int ms) {
  return RawInkSample(
    position: at,
    timestamp: Duration(milliseconds: ms),
  );
}

/// Draws a straight stroke from [from] to [to] on [controller], in page
/// coordinates, into [sticky] when given.
void _draw(
  InkController controller,
  InkVector from,
  InkVector to, {
  StickyNoteElement? sticky,
  int steps = 10,
}) {
  controller.startStroke(
    pointer: 1,
    sample: _sample(from, 0),
    style: const StrokeStyle(ink: InkPalette.ink, width: 3),
    intoSticky: sticky,
  );
  for (int i = 1; i <= steps; i++) {
    final double t = i / steps;
    controller.addSamples(1, <RawInkSample>[
      _sample(from + (to - from) * t, i * 8),
    ]);
  }
  controller.endStroke(1);
}

/// Selects the note under [at] with a tap of the Select tool and drags it
/// [dx] to the right, as one gesture.
bool _moveSticky(InkController controller, InkVector at, double dx) {
  final bool began = controller.beginSelectionGesture(pointer: 9, position: at);
  controller.updateSelectionGesture(9, at + InkVector(dx, 0));
  controller.endSelectionGesture(9, at + InkVector(dx, 0));
  return began;
}

Matcher _near(InkVector expected, [double tolerance = 1e-6]) {
  return isA<InkVector>()
      .having((InkVector v) => v.x, 'x', closeTo(expected.x, tolerance))
      .having((InkVector v) => v.y, 'y', closeTo(expected.y, tolerance));
}

void main() {
  group('model', () {
    test('defaults: 240 x 180, yellow lined, and the configured limits', () {
      expect(_config.defaultSize, const Size(240, 180));
      expect(_config.minSize, const Size(120, 90));
      expect(_config.maxSize, const Size(640, 480));
      expect(_config.cornerRadius, 12);
      expect(_config.contentPadding, 16);
      expect(_config.patternSpacing, 20);
      expect(_config.ruleWidth, 1);
      const StickyNoteSettings settings = StickyNoteSettings();
      expect(settings.color, StickyPalette.yellow);
      expect(settings.paper, StickyPaperStyle.lined);
    });

    test('the palette has yellow, pink, blue, green, and neutral paper', () {
      expect(
        StickyPalette.colors.map((StickyPaperColor c) => c.id),
        containsAll(<String>['yellow', 'pink', 'blue', 'green', 'neutral']),
      );
      for (final StickyPaperColor color in StickyPalette.colors) {
        // The pattern is darker than the paper but stays subtle.
        expect(
          color.pattern.computeLuminance(),
          lessThan(color.paper.computeLuminance()),
        );
      }
      expect(
        StickyPalette.resolve('mauve-from-the-future'),
        StickyPalette.yellow,
      );
    });

    test('labels name the color and the paper', () {
      expect(_note().label, 'Yellow lined sticky note');
      expect(
        _note(colorId: 'blue', paper: StickyPaperStyle.grid).label,
        'Blue grid sticky note',
      );
    });

    test('new ids are unique', () {
      final Set<String> ids = <String>{
        for (int i = 0; i < 200; i++) StickyNoteElement.newId(),
      };
      expect(ids, hasLength(200));
    });

    test('local and page coordinates round-trip through a turned, scaled '
        'note', () {
      final StickyNoteElement note = _note(rotation: 0.7, scale: 1.5);
      for (final InkVector local in <InkVector>[
        InkVector.zero,
        const InkVector(80, 40),
        const InkVector(160, 120),
      ]) {
        expect(note.toLocal(note.toPage(local)), _near(local, 1e-9));
      }
      // The local middle is the center on the page.
      expect(
        note.toPage(
          InkVector(note.localSize.width / 2, note.localSize.height / 2),
        ),
        _near(note.center, 1e-9),
      );
    });

    test('hit testing undoes the rotation and respects round corners', () {
      final StickyNoteElement note = _note(rotation: math.pi / 2);
      // Turned a quarter, it is 180 wide and 240 tall.
      expect(note.contains(const InkVector(300, 410)), isTrue);
      expect(note.contains(const InkVector(410, 300)), isFalse);
      final StickyNoteElement upright = _note();
      final InkVector corner = upright.corners.first;
      expect(upright.contains(corner, cornerRadius: 12), isFalse);
      expect(
        upright.contains(corner + const InkVector(12, 12), cornerRadius: 12),
        isTrue,
      );
    });

    test('a similarity transform moves the frame, never the ink', () {
      final Stroke ink = _line(
        const InkVector(10, 10),
        const InkVector(50, 10),
      );
      final StickyNoteElement note = _note(strokes: <Stroke>[ink]);
      final StickyNoteElement moved = note.transformed(
        InkTransform.scaling(note.center, 2),
      );
      expect(moved.size, const Size(480, 360));
      expect(moved.scale, 2);
      expect(moved.localSize, note.localSize);
      expect(identical(moved.strokes.single, ink), isTrue);
      final StickyNoteElement turned = note.transformed(
        InkTransform.rotation(note.center, 0.5),
      );
      expect(turned.rotation, closeTo(0.5, 1e-12));
      expect(identical(turned.strokes.single, ink), isTrue);
    });
  });

  group('pattern', () {
    test('every paper style', () {
      const Size local = Size(240, 180);
      expect(
        StickyPattern.of(StickyPaperStyle.blank, local, _config).lines,
        isEmpty,
      );
      final StickyPattern lined = StickyPattern.of(
        StickyPaperStyle.lined,
        local,
        _config,
      );
      expect(lined.dots, isEmpty);
      // A rule every 20, the last whole one inside the paper.
      expect(lined.lines, hasLength(8));
      for (final (InkVector a, InkVector b) in lined.lines) {
        expect(a.y, b.y);
        expect(a.x, _config.contentPadding);
      }
      final StickyPattern grid = StickyPattern.of(
        StickyPaperStyle.grid,
        local,
        _config,
      );
      expect(grid.lines, hasLength(8 + 11));
      final StickyPattern dotted = StickyPattern.of(
        StickyPaperStyle.dotted,
        local,
        _config,
      );
      expect(dotted.dots, hasLength(8 * 11));
      expect(dotted.dots.first, _near(const InkVector(20, 20)));
    });

    test('is anchored to the paper: moving, turning, resizing, or zooming '
        'never changes it in local units', () {
      final StickyNoteElement note = _note(paper: StickyPaperStyle.dotted);
      final StickyPattern before = StickyPattern.of(
        note.paper,
        note.localSize,
        _config,
      );
      final StickyNoteElement changed = note
          .transformed(InkTransform.translation(const InkVector(37, -12)))
          .transformed(InkTransform.rotation(const InkVector(0, 0), 1.1))
          .transformed(InkTransform.scaling(const InkVector(5, 5), 1.7));
      final StickyPattern after = StickyPattern.of(
        changed.paper,
        changed.localSize,
        _config,
      );
      expect(after.dots.length, before.dots.length);
      for (int i = 0; i < before.dots.length; i++) {
        expect(after.dots[i], _near(before.dots[i], 1e-6));
      }
    });

    test('a partial last row is left out, not shifted', () {
      final StickyPattern lined = StickyPattern.of(
        StickyPaperStyle.lined,
        const Size(240, 185),
        _config,
      );
      expect(lined.lines.last.$1.y, 180);
      expect(lined.lines.first.$1.y, 20);
    });

    test('malformed sizes and huge notes are bounded', () {
      expect(
        StickyPattern.of(
          StickyPaperStyle.grid,
          const Size(double.infinity, 10),
          _config,
        ).lines,
        isEmpty,
      );
      final StickyPattern huge = StickyPattern.of(
        StickyPaperStyle.dotted,
        const Size(1e7, 1e7),
        _config,
      );
      expect(huge.dots.length, lessThanOrEqualTo(_config.maxPatternMarks));
    });
  });

  group('controller', () {
    late InkController controller;
    setUp(() {
      controller = InkController();
    });
    tearDown(() => controller.dispose());

    test('placing a note centers it on the tap, kept on a finite page', () {
      expect(
        controller.beginStickyPlacement(
          pointer: 1,
          position: const InkVector(400, 300),
          pageBounds: const Rect.fromLTWH(0, 0, 800, 600),
        ),
        isTrue,
      );
      // A preview, not yet a change.
      expect(controller.documentRevision, 0);
      expect(controller.stickyNotes, isEmpty);
      final StickyNoteElement? note = controller.endStickyPlacement(1);
      expect(note!.center, const InkVector(400, 300));
      expect(note.size, const Size(240, 180));
      expect(controller.stickyNotes.single, note);
      expect(controller.editingSticky, note);
      expect(controller.canUndo, isTrue);

      controller.beginStickyPlacement(
        pointer: 2,
        position: const InkVector(790, 5),
        pageBounds: const Rect.fromLTWH(0, 0, 800, 600),
      );
      final StickyNoteElement corner = controller.endStickyPlacement(2)!;
      expect(corner.center, const InkVector(680, 90));
    });

    test('on a page that grows, only the top and left hold it in', () {
      controller.beginStickyPlacement(
        pointer: 1,
        position: const InkVector(790, 5),
        pageBounds: const Rect.fromLTWH(0, 0, 800, 600),
        growsDown: true,
      );
      expect(
        controller.endStickyPlacement(1)!.center,
        const InkVector(790, 90),
      );
    });

    test('a cancelled placement inserts nothing', () {
      controller.beginStickyPlacement(
        pointer: 1,
        position: const InkVector(400, 300),
        pageBounds: const Rect.fromLTWH(0, 0, 800, 600),
      );
      controller.cancelStickyPlacement(1);
      expect(controller.stickyNotes, isEmpty);
      expect(controller.canUndo, isFalse);
      controller.beginStickyPlacement(
        pointer: 1,
        position: const InkVector(400, 300),
        pageBounds: const Rect.fromLTWH(0, 0, 800, 600),
      );
      controller.finalizeActiveGesture();
      expect(controller.stickyNotes, isEmpty);
      expect(controller.documentRevision, 0);
    });

    test('a stroke into a note is stored in its own coordinates', () {
      final StickyNoteElement note = _note(rotation: math.pi / 2, scale: 2);
      controller.insertStickyNote(note);
      _draw(
        controller,
        note.toPage(const InkVector(10, 20)),
        note.toPage(const InkVector(100, 20)),
        sticky: note,
      );
      expect(controller.strokes, isEmpty);
      final Stroke child = controller.stickyNotes.single.strokes.single;
      expect(child.points.first, _near(const InkVector(10, 20), 1e-6));
      expect(child.points.last, _near(const InkVector(100, 20), 0.5));
      // As wide on the page as a page stroke.
      expect(child.style.width, 1.5);
    });

    test('a stroke that leaves the note is still received', () {
      final StickyNoteElement note = _note();
      controller.insertStickyNote(note);
      _draw(
        controller,
        note.toPage(const InkVector(200, 90)),
        note.toPage(const InkVector(400, 90)),
        sticky: note,
      );
      final Stroke child = controller.stickyNotes.single.strokes.single;
      expect(child.points.last.x, greaterThan(note.localSize.width));
    });

    test('erasing in a note touches only its ink; page ink stays', () {
      final StickyNoteElement note = _note();
      controller.insertStickyNote(note);
      _draw(
        controller,
        note.toPage(const InkVector(20, 90)),
        note.toPage(const InkVector(220, 90)),
        sticky: note,
      );
      // Page ink right over the note.
      _draw(controller, const InkVector(180, 300), const InkVector(420, 300));
      controller.startErase(
        pointer: 2,
        position: const InkVector(300, 300),
        settings: const EraserSettings(mode: EraserMode.stroke, size: 20),
        inSticky: controller.stickyNotes.single,
      );
      controller.endErase(2);
      expect(controller.stickyNotes.single.strokes, isEmpty);
      expect(controller.strokes, hasLength(1));

      // A page erase never takes sticky paper.
      controller.startErase(
        pointer: 3,
        position: const InkVector(300, 300),
        settings: const EraserSettings(mode: EraserMode.area, size: 400),
      );
      controller.endErase(3);
      expect(controller.strokes, isEmpty);
      expect(controller.stickyNotes, hasLength(1));
    });

    test('undo and redo walk sticky changes and page ink in one order', () {
      final StickyNoteElement note = _note();
      controller.insertStickyNote(note); // 1
      _draw(
        controller,
        note.toPage(const InkVector(20, 20)),
        note.toPage(const InkVector(120, 20)),
        sticky: note,
      ); // 2
      controller.setStickyAppearance(
        note.id,
        color: StickyPalette.colors[2],
      ); // 3
      _draw(controller, const InkVector(0, 0), const InkVector(50, 50)); // 4
      expect(_moveSticky(controller, const InkVector(300, 300), 40), isTrue);
      // 5: moved.
      controller.deleteStickyNote(note.id); // 6
      expect(controller.stickyNotes, isEmpty);

      bool undo() => controller.undo();
      expect(undo(), isTrue); // back before delete
      expect(controller.stickyNotes.single.center, const InkVector(340, 300));
      expect(undo(), isTrue); // before move
      expect(controller.stickyNotes.single.center, const InkVector(300, 300));
      expect(undo(), isTrue); // before page ink
      expect(controller.strokes, isEmpty);
      expect(undo(), isTrue); // before color
      expect(controller.stickyNotes.single.colorId, 'yellow');
      expect(undo(), isTrue); // before child stroke
      expect(controller.stickyNotes.single.strokes, isEmpty);
      expect(undo(), isTrue); // before insert
      expect(controller.stickyNotes, isEmpty);
      expect(controller.editingSticky, isNull);
      for (int i = 0; i < 6; i++) {
        expect(controller.redo(), isTrue);
      }
      expect(controller.stickyNotes, isEmpty);
      expect(controller.strokes, hasLength(1));
    });

    test('appearance changes never recolor the ink', () {
      final StickyNoteElement note = _note(
        strokes: <Stroke>[_line(const InkVector(5, 5), const InkVector(9, 9))],
      );
      controller.insertStickyNote(note);
      controller.setStickyAppearance(
        note.id,
        color: StickyPalette.colors[1],
        paper: StickyPaperStyle.grid,
      );
      final StickyNoteElement after = controller.stickyNotes.single;
      expect(after.colorId, StickyPalette.colors[1].id);
      expect(after.paper, StickyPaperStyle.grid);
      expect(identical(after.strokes.single, note.strokes.single), isTrue);
      // Choosing what it already is changes nothing.
      final int revision = controller.documentRevision;
      expect(
        controller.setStickyAppearance(note.id, paper: StickyPaperStyle.grid),
        isFalse,
      );
      expect(controller.documentRevision, revision);
    });

    test('a tap selects the note; scaling is clamped to its size limits', () {
      final StickyNoteElement note = _note();
      controller.insertStickyNote(note);
      expect(
        controller.beginSelectionGesture(
          pointer: 1,
          position: const InkVector(300, 300),
        ),
        isTrue,
      );
      controller.endSelectionGesture(1, const InkVector(300, 300));
      expect(controller.selection!.stickyIndices, <int>[0]);
      // One note gets a frame that turns with it.
      expect(controller.selection!.frame.halfWidth, 120);

      // Drag the bottom-right corner far out: no larger than 640 x 480.
      final InkVector corner = controller.selection!.frame.corners[2];
      controller.beginTransform(
        pointer: 2,
        position: corner,
        hit: const SelectionHit.scale(2),
      );
      controller.updateTransform(2, corner + const InkVector(3000, 2250));
      controller.endTransform(2);
      final Size grown = controller.stickyNotes.single.size;
      expect(grown.width, lessThanOrEqualTo(640 + 1e-6));
      expect(grown.height, lessThanOrEqualTo(480 + 1e-6));
      // The aspect ratio is kept.
      expect(grown.width / grown.height, closeTo(240 / 180, 1e-9));

      final InkVector big = controller.selection!.frame.corners[2];
      controller.beginTransform(
        pointer: 3,
        position: big,
        hit: const SelectionHit.scale(2),
      );
      controller.updateTransform(
        3,
        controller.selection!.frame.corners[0] + const InkVector(1, 1),
      );
      controller.endTransform(3);
      final Size shrunk = controller.stickyNotes.single.size;
      expect(shrunk.width, greaterThanOrEqualTo(120 - 1e-6));
      expect(shrunk.height, greaterThanOrEqualTo(90 - 1e-6));
    });

    test('copy, paste, and duplicate make fresh ids with the ink; cut and '
        'delete remove the whole note', () {
      final StickyNoteElement note = _note(
        strokes: <Stroke>[_line(const InkVector(5, 5), const InkVector(50, 9))],
      );
      controller.insertStickyNote(note);
      controller.beginSelectionGesture(
        pointer: 1,
        position: const InkVector(300, 300),
      );
      controller.endSelectionGesture(1);
      expect(controller.copySelection(), isTrue);
      expect(controller.paste(), isTrue);
      expect(controller.stickyNotes, hasLength(2));
      final StickyNoteElement pasted = controller.stickyNotes.last;
      expect(pasted.id, isNot(note.id));
      expect(pasted.strokes.single.points, note.strokes.single.points);
      expect(controller.selection!.stickyIndices, <int>[1]);

      expect(controller.duplicateSelection(), isTrue);
      expect(controller.stickyNotes, hasLength(3));
      expect(
        controller.stickyNotes.map((StickyNoteElement n) => n.id).toSet(),
        hasLength(3),
      );

      expect(controller.cutSelection(), isTrue);
      expect(controller.stickyNotes, hasLength(2));
      expect(controller.deleteStickyNote(note.id), isTrue);
      expect(controller.stickyNotes, hasLength(1));
    });

    test('a lasso picks notes it overlaps, rotated ones included', () {
      controller.insertStickyNote(_note(id: 'a', rotation: 0.6));
      controller.insertStickyNote(
        _note(id: 'b', center: const InkVector(900, 900)),
      );
      controller.beginLasso(pointer: 1, position: const InkVector(250, 250));
      controller.updateLasso(1, const InkVector(350, 350));
      controller.endLasso(1);
      expect(controller.selection!.stickies.single.id, 'a');
    });

    test('a double tap takes back the first tap\'s dot and opens the note', () {
      final StickyNoteElement note = _note();
      controller.insertStickyNote(note);
      controller.exitStickyEditing();
      _draw(
        controller,
        const InkVector(300, 300),
        const InkVector(300, 300),
        steps: 0,
      );
      final Stroke dot = controller.strokes.single;
      expect(dot.isDot, isTrue);
      final int before = controller.documentRevision;
      expect(controller.enterStickyEditing(note.id, removingTap: dot), isTrue);
      expect(controller.strokes, isEmpty);
      expect(controller.editingSticky?.id, note.id);
      expect(controller.documentRevision, greaterThan(before));
      // Undo goes back past the insert, not to a phantom dot.
      controller.undo();
      expect(controller.stickyNotes, isEmpty);
      expect(controller.strokes, isEmpty);
    });
  });

  group('storage', () {
    StoredPage roundTrip(StoredPage page) {
      return StoredPage.fromJson(page.toJson());
    }

    test('every color, paper, transform, and child stroke round-trips', () {
      final List<StickyNoteElement> notes = <StickyNoteElement>[
        for (final StickyPaperColor color in StickyPalette.colors)
          for (final StickyPaperStyle paper in StickyPaperStyle.values)
            _note(
              id: '${color.id}-${paper.name}',
              colorId: color.id,
              paper: paper,
              rotation: 0.3,
              scale: 1.25,
              size: const Size(300, 225),
              center: const InkVector(123.5, 456.25),
              strokes: <Stroke>[
                _line(const InkVector(1, 2), const InkVector(30, 40)),
                Stroke.fromPoints(
                  style: const StrokeStyle(
                    ink: InkPalette.highlighterYellow,
                    width: 12,
                    writing: WritingStyle.highlighter,
                    opacity: 0.35,
                  ),
                  points: const <InkVector>[InkVector(5, 5), InkVector(80, 5)],
                ),
                Stroke.fromPoints(
                  style: const StrokeStyle(ink: InkPalette.ink, width: 3),
                  points: const <InkVector>[InkVector(0, 0), InkVector(10, 0)],
                  widths: const <double>[0.5, 1.2],
                ),
              ],
            ),
      ];
      final StoredPage page = StoredPage(
        setup: const PageSetup(),
        strokes: const <Stroke>[],
        stickyNotes: notes,
      );
      final StoredPage back = roundTrip(page);
      expect(back.stickyNotes, hasLength(notes.length));
      for (int i = 0; i < notes.length; i++) {
        final StickyNoteElement a = notes[i];
        final StickyNoteElement b = back.stickyNotes[i];
        expect(b.id, a.id);
        expect(b.colorId, a.colorId);
        expect(b.paper, a.paper);
        expect(b.center, a.center);
        expect(b.size, a.size);
        expect(b.rotation, a.rotation);
        expect(b.scale, a.scale);
        expect(b.strokes, hasLength(3));
        expect(b.strokes[1].style.isHighlighter, isTrue);
        expect(b.strokes[1].style.opacity, 0.35);
        expect(b.strokes[2].widths, <double>[0.5, 1.2]);
        expect(b.strokes[0].points, a.strokes[0].points);
      }
    });

    test('an older page has no sticky notes, and loads unchanged', () {
      final StoredPage page = StoredPage.fromJson(<String, Object?>{
        'size': 'fit',
        'background': 'lined',
        'strokes': <Object?>[
          <String, Object?>{
            'ink': 'ink',
            'width': 3,
            'points': <double>[0, 0, 10, 10],
          },
        ],
      });
      expect(page.stickyNotes, isEmpty);
      expect(page.strokes, hasLength(1));
      expect(page.toJson().containsKey('stickyNotes'), isFalse);
    });

    test('schema 3 notes still open; the schema is now 4', () {
      expect(storageSchema, 4);
      final NoteContent content = NoteContent.fromJson(<String, Object?>{
        'schema': 3,
        'pages': <Object?>[
          <String, Object?>{'size': 'fit', 'strokes': <Object?>[]},
        ],
      });
      expect(content.pages.single.stickyNotes, isEmpty);
    });

    test('malformed notes are skipped or repaired, never fatal', () {
      final StoredPage page = StoredPage.fromJson(<String, Object?>{
        'size': 'fit',
        'strokes': <Object?>[],
        'stickyNotes': <Object?>[
          'not a note',
          <String, Object?>{
            'id': 'nan',
            'center': <Object?>[double.nan, 0],
            'size': <double>[240, 180],
          },
          <String, Object?>{
            'id': 'zero',
            'center': <double>[0, 0],
            'size': <double>[0, 180],
          },
          <String, Object?>{
            'id': 'neg',
            'center': <double>[0, 0],
            'size': <double>[240, 180],
            'scale': -1,
          },
          <String, Object?>{
            'id': 'dup',
            'center': <double>[10, 10],
            'size': <double>[10, 10],
            'color': 'mauve',
            'paper': 'hexagonal',
            'strokes': <Object?>[
              'junk',
              <String, Object?>{
                'ink': 'ink',
                'width': 3,
                'points': <Object?>['x', 1],
              },
              <String, Object?>{
                'ink': 'ink',
                'width': 3,
                'points': <double>[1, 1, 2, 2],
              },
            ],
          },
          <String, Object?>{
            'id': 'dup',
            'center': <double>[0, 0],
            'size': <double>[240, 180],
          },
        ],
      });
      expect(page.stickyNotes, hasLength(2));
      final StickyNoteElement repaired = page.stickyNotes.first;
      // Too small: grown to the minimum, ink scaled along.
      expect(repaired.size.width, greaterThanOrEqualTo(120));
      expect(repaired.size.height, greaterThanOrEqualTo(90));
      expect(repaired.localSize.width, closeTo(10, 1e-9));
      // Unknown color keeps its id but draws yellow; unknown paper is lined.
      expect(repaired.colorId, 'mauve');
      expect(repaired.color, StickyPalette.yellow);
      expect(repaired.paper, StickyPaperStyle.lined);
      expect(repaired.strokes, hasLength(1));
      expect(page.stickyNotes.last.id, isNot('dup'));
    });

    test('file limits bound the work', () {
      final StoredPage page = StoredPage.fromJson(<String, Object?>{
        'size': 'fit',
        'strokes': <Object?>[],
        'stickyNotes': <Object?>[
          for (int i = 0; i < _config.maxStickyNotesPerPage + 20; i++)
            <String, Object?>{
              'id': 'n$i',
              'center': <double>[0, 0],
              'size': <double>[240, 180],
            },
        ],
      });
      expect(page.stickyNotes, hasLength(_config.maxStickyNotesPerPage));
    });

    test('a document round trip keeps notes on their page, in order', () {
      final InkController ink = InkController(
        stickyNotes: <StickyNoteElement>[
          _note(id: 'one'),
          _note(id: 'two', colorId: 'green'),
        ],
      );
      final NoteContent content = NoteContent(<StoredPage>[
        StoredPage(
          setup: const PageSetup(),
          strokes: const <Stroke>[],
          stickyNotes: ink.stickyNotes,
        ),
      ]);
      ink.dispose();
      final NoteContent back = NoteContent.fromJson(content.toJson());
      final InkController restored = back.toDocument().pages.single.ink;
      addTearDown(restored.dispose);
      expect(restored.stickyNotes.map((StickyNoteElement n) => n.id), <String>[
        'one',
        'two',
      ]);
    });
  });
}
