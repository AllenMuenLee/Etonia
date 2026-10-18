import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/note_image_renderer.dart';
import 'package:greatnote/features/editor/ai/selection_image_renderer.dart';
import 'package:greatnote/features/editor/document_io/pdf_exporter.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/ink_selection.dart';
import 'package:greatnote/features/editor/ink/selection_transform.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/sticky/sticky_note.dart';
import 'package:greatnote/features/editor/sticky/sticky_note_painter.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/note_thumbnails.dart';

import '../../../helpers/document_io_fakes.dart';

final Stroke _marker = Stroke.fromPoints(
  style: const StrokeStyle(
    ink: InkPalette.highlighterYellow,
    width: 30,
    writing: WritingStyle.highlighter,
    opacity: 0.35,
  ),
  points: const <InkVector>[InkVector(10, 60), InkVector(110, 60)],
);

StickyNoteElement _note({
  StickyPaperStyle paper = StickyPaperStyle.blank,
  String colorId = 'blue',
  double rotation = 0,
  List<Stroke> strokes = const <Stroke>[],
}) {
  return StickyNoteElement(
    id: 'n',
    center: const InkVector(100, 100),
    size: const Size(160, 120),
    rotation: rotation,
    colorId: colorId,
    paper: paper,
    strokes: strokes,
  );
}

/// The RGBA pixels of [png].
Future<(ByteData, int)> _pixels(Uint8List png) async {
  final ui.Codec codec = await ui.instantiateImageCodec(png);
  final ui.FrameInfo frame = await codec.getNextFrame();
  final ByteData bytes = (await frame.image.toByteData())!;
  final int width = frame.image.width;
  frame.image.dispose();
  codec.dispose();
  return (bytes, width);
}

Color _at((ByteData, int) image, int x, int y) {
  final int offset = (y * image.$2 + x) * 4;
  return Color.fromARGB(
    image.$1.getUint8(offset + 3),
    image.$1.getUint8(offset),
    image.$1.getUint8(offset + 1),
    image.$1.getUint8(offset + 2),
  );
}

void main() {
  test('the assistant is told a sticky note is not blank paper', () async {
    final StickyNoteElement note = _note(strokes: <Stroke>[_marker]);
    final NoteImage image = await const NoteImageRenderer().render(
      NoteInkSnapshot.of(
        const <Stroke>[],
        logicalSize: const Size(300, 300),
        revision: 0,
        brightness: Brightness.dark,
        background: Colors.black,
        stickies: <StickyNoteElement>[note],
      ),
    );

    expect(image.space!.hasRoom, isTrue);
    for (final area in image.space!.areas) {
      for (final Rect part in area.parts) {
        final Rect overlap = part.intersect(note.bounds);
        expect(overlap.width <= 0 || overlap.height <= 0, isTrue);
      }
    }
  });

  test('a selected note is captured for the assistant', () async {
    final StickyNoteElement note = _note(rotation: 0.4);
    final InkSelection selection = InkSelection(
      indices: const <int>[],
      strokes: const <Stroke>[],
      stickyIndices: const <int>[0],
      stickies: <StickyNoteElement>[note],
      frame: frameAroundContent(
        const <Stroke>[],
        const [],
        stickies: <StickyNoteElement>[note],
      ),
    );
    final SelectionInkSnapshot snapshot = SelectionInkSnapshot.of(
      selection,
      brightness: Brightness.light,
      background: Colors.white,
    );
    expect(snapshot.isOf(selection), isTrue);
    final SelectionImage image = await const SelectionImageRenderer().render(
      snapshot,
    );
    expect(image.logicalBounds.contains(const Offset(100, 100)), isTrue);
    final (ByteData, int) pixels = await _pixels(image.png);
    final Offset center =
        (const Offset(100, 100) - image.logicalBounds.topLeft) * image.scale;
    expect(
      _at(pixels, center.dx.round(), center.dy.round()),
      isSameColorAs(note.color.paper),
    );
  });

  testWidgets('library thumbnails show the note under page ink', (
    WidgetTester tester,
  ) async {
    final StoredPage page = StoredPage(
      setup: const PageSetup(size: PageSize.custom, customSize: Size(200, 200)),
      strokes: const <Stroke>[],
      stickyNotes: <StickyNoteElement>[_note(colorId: 'green')],
    );
    final Color? center = await tester.runAsync(() async {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      NoteThumbnailPainter(
        page: page,
        brightness: Brightness.dark,
        rule: Colors.grey,
        marginRule: Colors.red,
      ).paint(Canvas(recorder), const Size(200, 200));
      final ui.Image image = await recorder.endRecording().toImage(200, 200);
      final ByteData bytes = (await image.toByteData())!;
      image.dispose();
      return _at((bytes, 200), 100, 100);
    });
    expect(center, isSameColorAs(StickyPalette.byId('green')!.paper));
  });

  test('the PDF draws sticky notes with the same pattern geometry', () async {
    final InMemoryNoteRepository repository = InMemoryNoteRepository();
    addTearDown(repository.dispose);
    final note = await repository.createNote();
    Future<Uint8List> export(List<StickyNoteElement> notes) {
      return PdfExporter(rasterizer: FakePdfRasterizer()).buildPdf(
        noteId: note.id,
        title: 'Sticky',
        content: NoteContent(<StoredPage>[
          StoredPage(
            setup: const PageSetup(size: PageSize.letterPortrait),
            strokes: <Stroke>[_marker],
            stickyNotes: notes,
          ),
        ]),
        repository: repository,
      );
    }

    final Uint8List plain = await export(const <StickyNoteElement>[]);
    final Uint8List withNotes = await export(<StickyNoteElement>[
      for (final StickyPaperStyle paper in StickyPaperStyle.values)
        _note(paper: paper, rotation: 0.3, strokes: <Stroke>[_marker]),
    ]);
    expect(utf8.decode(withNotes.sublist(0, 4)), '%PDF');
    expect(withNotes.length, greaterThan(plain.length));
    // The same saved document gives the same pattern, every time.
    final StickyPattern a = StickyPattern.of(
      StickyPaperStyle.grid,
      const Size(160, 120),
      const StickyNoteConfig(),
    );
    final StickyPattern b = StickyPattern.of(
      StickyPaperStyle.grid,
      const Size(160, 120),
      const StickyNoteConfig(),
    );
    expect(a.lines, b.lines);
  });

  testWidgets('every paper style, in light and dark chrome alike', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(720, 180));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Widget board(Brightness brightness) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(brightness: brightness),
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey<String>('board'),
            child: CustomPaint(
              size: const Size(720, 180),
              painter: _BoardPainter(),
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(board(Brightness.light));
    await expectLater(
      find.byKey(const ValueKey<String>('board')),
      matchesGoldenFile('goldens/sticky_paper_styles.png'),
    );
    // Paper is part of the document: a dark editor draws it the same.
    await tester.pumpWidget(board(Brightness.dark));
    await expectLater(
      find.byKey(const ValueKey<String>('board')),
      matchesGoldenFile('goldens/sticky_paper_styles.png'),
    );
  });
}

class _BoardPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    const List<StickyPaperStyle> papers = StickyPaperStyle.values;
    for (int i = 0; i < papers.length; i++) {
      final StickyNoteElement note = StickyNoteElement(
        id: '$i',
        center: InkVector(90 + i * 180.0, 90),
        size: const Size(160, 120),
        rotation: i.isOdd ? 0.08 : -0.05,
        colorId: StickyPalette.colors[i].id,
        paper: papers[i],
        strokes: <Stroke>[
          Stroke.fromPoints(
            style: const StrokeStyle(ink: InkPalette.ink, width: 3),
            points: const <InkVector>[
              InkVector(20, 40),
              InkVector(70, 70),
              InkVector(200, 60),
            ],
          ),
          _marker,
        ],
      );
      paintStickyNote(canvas, note.transformed(InkTransform.identity));
    }
  }

  @override
  bool shouldRepaint(_BoardPainter oldDelegate) => false;
}
