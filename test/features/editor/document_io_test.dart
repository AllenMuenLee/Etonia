import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/document_io/document_importer.dart';
import 'package:greatnote/features/editor/document_io/document_io_config.dart';
import 'package:greatnote/features/editor/document_io/document_models.dart';
import 'package:greatnote/features/editor/document_io/document_platform.dart';
import 'package:greatnote/features/editor/document_io/pdf_exporter.dart';
import 'package:greatnote/features/editor/document_io/pdf_page_layer.dart';
import 'package:greatnote/features/editor/document_io/pdf_selection_image.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/selection_geometry.dart';
import 'package:greatnote/features/editor/ink/ink_selection.dart';
import 'package:greatnote/features/editor/ink/selection_transform.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/page/note_document.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/features/editor/widgets/tool_palette.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/shared_note_clipboard.dart';

import '../../helpers/document_io_fakes.dart';
import '../../helpers/pump_app.dart';

/// Counts how often the exporter parses the PDF and which pages it renders
/// through the open document.
class _OpenOnceRasterizer extends FakePdfRasterizer
    implements PdfDocumentRasterizer {
  int opens = 0;
  bool disposed = false;
  final List<int> renderedPages = <int>[];

  @override
  Future<OpenPdf> open(Uint8List bytes) async {
    opens++;
    return _CountingOpenPdf(this);
  }
}

class _CountingOpenPdf implements OpenPdf {
  _CountingOpenPdf(this.owner);

  final _OpenOnceRasterizer owner;

  @override
  Future<Image> renderImage(
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  }) {
    owner.renderedPages.add(pageIndex);
    final PictureRecorder recorder = PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 4, 4),
      Paint()..color = const Color(0xFF336699),
    );
    final Picture picture = recorder.endRecording();
    return picture.toImage(4, 4).whenComplete(picture.dispose);
  }

  @override
  Future<void> dispose() async {
    owner.disposed = true;
  }
}

void main() {
  test('schema 2 round-trips PDF, image rotation, and Fit history', () {
    const NoteContent content = NoteContent(<StoredPage>[
      StoredPage(
        setup: PageSetup(),
        lastFitSize: Size(700, 900),
        pdfSource: PdfPageSource(
          assetId: 'pdf',
          pageIndex: 2,
          pageSize: Size(816, 1056),
        ),
        images: <NoteImageElement>[
          NoteImageElement(
            id: 'image',
            assetId: 'asset',
            pixelSize: Size(640, 480),
            center: InkVector(20.25, 30.5),
            size: Size(320, 240),
            rotation: 0.375,
          ),
        ],
        strokes: [],
      ),
    ]);
    final NoteContent copy = NoteContent.fromJson(
      jsonDecode(jsonEncode(content.toJson())) as Map<String, Object?>,
    );
    expect(copy.pages.single.lastFitSize, const Size(700, 900));
    expect(copy.pages.single.pdfSource, content.pages.single.pdfSource);
    expect(copy.pages.single.images, content.pages.single.images);
  });

  test('schema 1 still loads', () {
    final NoteContent content = NoteContent.fromJson(<String, Object?>{
      'schema': 1,
      'pages': <Object?>[
        <String, Object?>{
          'size': 'fit',
          'background': 'blank',
          'strokes': <Object?>[],
        },
      ],
    });
    expect(content.pages, hasLength(1));
    expect(content.pages.single.setup.size, PageSize.a4Portrait);
    expect(content.pages.single.images, isEmpty);
  });

  test('point conversion and PDF-backed geometry are exact', () {
    expect(DocumentUnits.pageUnitsPerPdfPoint, closeTo(4 / 3, 1e-12));
    final geometry = PageGeometry.of(
      const PageSetup(),
      null,
      const Size(400, 1000),
      pdfPageSize: const Size(800, 1000),
    );
    expect(geometry.pageSize, const Size(800, 1000));
    expect(geometry.scale, 0.5);
  });

  test('rotated images overlap a crossing lasso', () {
    const NoteImageElement image = NoteImageElement(
      id: 'i',
      assetId: 'a',
      pixelSize: Size(100, 40),
      center: InkVector(50, 50),
      size: Size(100, 40),
      rotation: 0.7,
    );
    final LassoRegion lasso = LassoRegion(const <InkVector>[
      InkVector(45, 0),
      InkVector(55, 0),
      InkVector(55, 100),
      InkVector(45, 100),
    ]);
    expect(selectImages(const <NoteImageElement>[image], lasso), <int>[0]);
  });

  test('a lasso can select clipped PDF paper and copy it as an image', () {
    final InkController controller = InkController();
    addTearDown(controller.dispose);
    controller
      ..beginLasso(pointer: 1, position: const InkVector(-10, 20))
      ..endLasso(
        1,
        const InkVector(60, 70),
        const Rect.fromLTWH(0, 0, 100, 100),
      );

    final selection = controller.selection!;
    expect(selection.indices, isEmpty);
    expect(selection.imageIndices, isEmpty);
    expect(selection.pdfBounds, const Rect.fromLTRB(0, 20, 60, 70));
    const NoteImageElement excerpt = NoteImageElement(
      id: 'pdf-excerpt',
      assetId: 'excerpt-asset',
      pixelSize: Size(120, 100),
      center: InkVector(30, 45),
      size: Size(60, 50),
    );
    expect(
      controller.copySelection(
        expectedSelection: selection,
        additionalImages: const <NoteImageElement>[excerpt],
      ),
      isTrue,
    );
    expect(controller.clipboard!.images, const <NoteImageElement>[excerpt]);
    expect(controller.paste(at: const InkVector(200, 200)), isTrue);
    expect(controller.images.single.center, const InkVector(200, 200));
  });

  test('without its paper, a lasso selects the editable ink alone', () {
    final Stroke stroke = Stroke.fromPoints(
      style: const StrokeStyle(ink: InkPalette.ink, width: 4),
      points: const <InkVector>[InkVector(20, 20), InkVector(40, 40)],
    );
    final InkController controller = InkController(strokes: <Stroke>[stroke]);
    addTearDown(controller.dispose);
    controller
      ..beginLasso(pointer: 1, position: const InkVector(10, 10))
      ..endLasso(1, const InkVector(50, 50));

    final InkSelection selection = controller.selection!;
    expect(selection.strokes, <Stroke>[stroke]);
    expect(selection.includesPdf, isFalse);
    expect(
      controller.beginTransform(
        pointer: 2,
        position: selection.frame.center,
        hit: const SelectionHit.move(),
      ),
      isTrue,
    );
  });

  test('a rendered PDF selection is cropped at page coordinates', () {
    final image.Image page = image.Image(width: 200, height: 100);
    final PdfSelectionImage selection = cropPdfSelection(
      Uint8List.fromList(image.encodePng(page)),
      const Size(100, 50),
      const Rect.fromLTWH(25, 10, 50, 20),
    );
    final image.Image cropped = image.decodePng(selection.png)!;

    expect(selection.logicalBounds, const Rect.fromLTWH(25, 10, 50, 20));
    expect(selection.pixelSize, const Size(100, 40));
    expect(cropped.width, 100);
    expect(cropped.height, 40);
  });

  test('blank areas of the paper come out blank in a crop', () {
    final image.Image page = image.Image(width: 100, height: 100)
      ..clear(image.ColorRgb8(0, 0, 0));
    final PdfSelectionImage selection = cropPdfSelection(
      Uint8List.fromList(image.encodePng(page)),
      const Size(100, 100),
      const Rect.fromLTWH(0, 0, 50, 50),
      blanks: const <Rect>[Rect.fromLTWH(20, 20, 50, 50)],
    );
    final image.Image cropped = image.decodePng(selection.png)!;

    expect(cropped.getPixel(10, 10).r, 0);
    expect(cropped.getPixel(30, 30).r, 255);
    expect(cropped.getPixel(49, 49).r, 255);
  });

  testWidgets('Copy turns a selected PDF region into a pasteable image', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = InMemoryNoteRepository();
    addTearDown(repository.dispose);
    final note = await repository.createNote();
    final String pdfAsset = await repository.storeAsset(
      note.id,
      Uint8List.fromList(<int>[1, 2, 3]),
      kind: NoteAssetKind.pdf,
      extension: 'pdf',
    );
    final image.Image rendered = image.Image(width: 100, height: 100);
    final InkController controller = InkController();
    final NoteDocument document = NoteDocument(
      pages: <NotePage>[
        NotePage(
          ink: controller,
          pdfSource: PdfPageSource(
            assetId: pdfAsset,
            pageIndex: 0,
            pageSize: const Size(100, 100),
          ),
        ),
      ],
    );
    addTearDown(document.dispose);
    InkClipboard? copied;
    setViewportSize(tester, TestViewport.tabletLandscape.size);
    await tester.pumpWidget(
      GreatnoteApp(
        home: EditorScreen(
          document: document,
          repository: repository,
          noteId: note.id,
          pdfRasterizer: FakePdfRasterizer(
            renderedPng: Uint8List.fromList(image.encodePng(rendered)),
          ),
          assetReader: (String id) async {
            return (await repository.readAsset(note.id, id)).bytes;
          },
          onClipboardChanged: (InkClipboard value) => copied = value,
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Select'));
    await tester.pumpAndSettle();
    tester.widget<ToolPalette>(find.byType(ToolPalette)).selectPdf.value = true;
    final Rect canvas = tester.getRect(find.byType(InkCanvas));
    final double pageScale = canvas.width / 100;
    await tester.dragFrom(
      canvas.topLeft + const Offset(10, 20) * pageScale,
      const Offset(50, 50) * pageScale,
    );
    await tester.pumpAndSettle();
    final Rect selected = controller.selection!.pdfBounds!;
    expect(selected.left, closeTo(10, 1e-6));
    expect(selected.top, closeTo(20, 1e-6));
    expect(selected.right, closeTo(60, 1e-6));
    expect(selected.bottom, closeTo(70, 1e-6));

    await tester.tap(find.byTooltip('Copy'));
    // PDF renders run one at a time; the copy's may wait on the page's own.
    for (int i = 0; i < 5 && copied == null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();
    }
    final InkClipboard clipboard = copied!;
    expect(clipboard.images, hasLength(1));
    expect(clipboard.images.single.size.width, closeTo(50, 1e-6));
    expect(clipboard.images.single.size.height, closeTo(50, 1e-6));
    expect(controller.paste(at: const InkVector(80, 80)), isTrue);
    expect(controller.images.single.center, const InkVector(80, 80));
  });

  testWidgets('with Select PDF, PDF paper moves, cuts, and deletes, leaving '
      'its place blank', (WidgetTester tester) async {
    final InMemoryNoteRepository repository = InMemoryNoteRepository();
    addTearDown(repository.dispose);
    final note = await repository.createNote();
    final String pdfAsset = await repository.storeAsset(
      note.id,
      Uint8List.fromList(<int>[1, 2, 3]),
      kind: NoteAssetKind.pdf,
      extension: 'pdf',
    );
    final image.Image rendered = image.Image(width: 100, height: 100);
    final InkController controller = InkController();
    final NoteDocument document = NoteDocument(
      pages: <NotePage>[
        NotePage(
          ink: controller,
          pdfSource: PdfPageSource(
            assetId: pdfAsset,
            pageIndex: 0,
            pageSize: const Size(100, 100),
          ),
        ),
      ],
    );
    addTearDown(document.dispose);
    InkClipboard? copied;
    setViewportSize(tester, TestViewport.tabletLandscape.size);
    await tester.pumpWidget(
      GreatnoteApp(
        home: EditorScreen(
          document: document,
          repository: repository,
          noteId: note.id,
          pdfRasterizer: FakePdfRasterizer(
            renderedPng: Uint8List.fromList(image.encodePng(rendered)),
          ),
          assetReader: (String id) async {
            return (await repository.readAsset(note.id, id)).bytes;
          },
          onClipboardChanged: (InkClipboard value) => copied = value,
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    Future<void> settle(bool Function() done) async {
      for (int i = 0; i < 10 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)),
        );
        await tester.pumpAndSettle();
      }
    }

    await tester.tap(find.byTooltip('Select'));
    await tester.pumpAndSettle();
    tester.widget<ToolPalette>(find.byType(ToolPalette)).selectPdf.value = true;
    final Rect canvas = tester.getRect(find.byType(InkCanvas));
    final double pageScale = canvas.width / 100;
    Future<void> select(Rect area) async {
      await tester.dragFrom(
        canvas.topLeft + area.topLeft * pageScale,
        area.size.bottomRight(Offset.zero) * pageScale,
      );
      await tester.pumpAndSettle();
    }

    expect(find.byType(PdfMaskLayer), findsOneWidget);

    // Moved: the paper is readied in the background, then lifted by a drag.
    await select(const Rect.fromLTWH(10, 20, 50, 50));
    await settle(() => controller.canLiftPdfSelection);
    expect(controller.canLiftPdfSelection, isTrue);
    await tester.dragFrom(
      canvas.topLeft + const Offset(35, 45) * pageScale,
      const Offset(20, 10) * pageScale,
    );
    await tester.pumpAndSettle();
    expect(
      controller.pdfMasks.single,
      rectMoreOrLessEquals(const Rect.fromLTRB(10, 20, 60, 70)),
    );
    expect(controller.images.single.center.x, closeTo(55, 1e-6));
    expect(controller.images.single.center.y, closeTo(55, 1e-6));
    expect(controller.selection!.includesPdf, isFalse);
    // The lift and the move are taken back together.
    expect(controller.undo(), isTrue);
    await tester.pumpAndSettle();
    expect(controller.pdfMasks, isEmpty);
    expect(controller.images, isEmpty);

    // Cut: copied as an image, its place left blank.
    const Rect cutArea = Rect.fromLTWH(60, 0, 30, 30);
    await select(cutArea);
    await tester.tap(find.byTooltip('Cut'));
    await settle(() => copied != null);
    expect(copied!.images, hasLength(1));
    expect(controller.pdfMasks.single, rectMoreOrLessEquals(cutArea));
    expect(controller.selection, isNull);

    // Deleted: just left blank.
    const Rect deletedArea = Rect.fromLTWH(10, 75, 20, 20);
    await select(deletedArea);
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(controller.pdfMasks, hasLength(2));
    expect(controller.pdfMasks.last, rectMoreOrLessEquals(deletedArea));
    expect(controller.images, isEmpty);
    expect(tester.takeException(), isNull);
  });

  test('blank PDF areas are saved with the page', () {
    final InkController ink = InkController(
      pdfMasks: const <Rect>[Rect.fromLTRB(10, 20, 60, 70)],
    );
    final NoteDocument document = NoteDocument(
      pages: <NotePage>[
        NotePage(
          ink: ink,
          pdfSource: const PdfPageSource(
            assetId: 'pdf',
            pageIndex: 0,
            pageSize: Size(100, 100),
          ),
        ),
      ],
    );
    addTearDown(document.dispose);
    final Map<String, Object?> json =
        jsonDecode(jsonEncode(NoteContent.fromDocument(document).toJson()))
            as Map<String, Object?>;
    final NoteDocument restored = NoteContent.fromJson(json).toDocument();
    addTearDown(restored.dispose);
    expect(restored.pages.single.ink.pdfMasks, const <Rect>[
      Rect.fromLTRB(10, 20, 60, 70),
    ]);
  });

  test('image insert, transform, cut, and paste are single mutations', () {
    final InkController controller = InkController();
    addTearDown(controller.dispose);
    const NoteImageElement image = NoteImageElement(
      id: 'i',
      assetId: 'a',
      pixelSize: Size(100, 50),
      center: InkVector(50, 50),
      size: Size(100, 50),
    );
    expect(controller.insertImage(image), isTrue);
    expect(controller.documentRevision, 1);
    expect(controller.cutSelection(), isTrue);
    expect(controller.documentRevision, 2);
    expect(controller.images, isEmpty);
    expect(controller.paste(at: const InkVector(200, 200)), isTrue);
    expect(controller.documentRevision, 3);
    expect(controller.images.single.center, const InkVector(200, 200));
  });

  test('PDF import creates one asset and one page per source page', () async {
    final InMemoryNoteRepository repository = InMemoryNoteRepository();
    addTearDown(repository.dispose);
    final DocumentImporter importer = DocumentImporter(
      rasterizer: FakePdfRasterizer(
        inspection: const PdfInspection(
          pageSizes: <Size>[Size(612, 792), Size(792, 612)],
        ),
      ),
    );
    final note = await importer.importPdfAsNote(
      repository: repository,
      picked: PickedDocument(
        name: '  Slides.pdf',
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
      ),
    );
    expect(note.title, 'Slides');
    final NoteContent content = await repository.loadNote(note.id);
    expect(content.pages, hasLength(2));
    expect(content.pages.first.pdfSource!.pageSize.width, 816);
    expect(await repository.listAssets(note.id), hasLength(1));
  });

  test(
    'PDF validation rejects encryption and limits before mutation',
    () async {
      final InMemoryNoteRepository repository = InMemoryNoteRepository();
      addTearDown(repository.dispose);
      final PickedDocument picked = PickedDocument(
        name: 'locked.pdf',
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
      );
      await expectLater(
        DocumentImporter(
          rasterizer: FakePdfRasterizer(
            inspection: const PdfInspection(
              pageSizes: <Size>[],
              isEncrypted: true,
            ),
          ),
        ).importPdfAsNote(repository: repository, picked: picked),
        throwsA(
          isA<DocumentImportException>().having(
            (DocumentImportException error) => error.message,
            'message',
            'This PDF is password-protected',
          ),
        ),
      );
      expect((await repository.list(null)).notes, isEmpty);
    },
  );

  test('image import normalizes, downscales, places, and selects', () async {
    final InMemoryNoteRepository repository = InMemoryNoteRepository();
    addTearDown(repository.dispose);
    final note = await repository.createNote();
    final InkController controller = InkController();
    addTearDown(controller.dispose);
    final image.Image fixture = image.Image(
      width: 20,
      height: 10,
      numChannels: 4,
    )..setPixelRgba(0, 0, 255, 0, 0, 100);
    final NoteImageElement element =
        await DocumentImporter(
          rasterizer: FakePdfRasterizer(),
          config: const DocumentIoConfig(maxStoredImageDimension: 10),
        ).insertImage(
          repository: repository,
          noteId: note.id,
          controller: controller,
          picked: PickedDocument(
            name: 'transparent.png',
            bytes: Uint8List.fromList(image.encodePng(fixture)),
          ),
          visiblePage: const Rect.fromLTWH(20, 30, 100, 80),
        );
    expect(element.pixelSize, const Size(10, 5));
    expect(element.size, const Size(10, 5));
    expect(element.center, const InkVector(70, 70));
    expect(controller.selection!.images.single, element);
    final NoteAssetData stored = await repository.readAsset(
      note.id,
      element.assetId,
    );
    expect(stored.asset.extension, 'png');
    expect(image.decodeImage(stored.bytes)!.width, 10);
  });

  testWidgets('the image tool offers gallery and camera, outside Add', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = InMemoryNoteRepository();
    addTearDown(repository.dispose);
    final note = await repository.createNote();
    final FakeDocumentPicker picker = FakeDocumentPicker();
    await pumpApp(
      tester,
      home: EditorScreen(
        repository: repository,
        noteId: note.id,
        documentPicker: picker,
      ),
    );

    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Insert PDF'), findsOneWidget);
    expect(find.text('Insert image'), findsNothing);
    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Insert image'));
    await tester.pumpAndSettle();
    expect(find.text('Choose from gallery'), findsOneWidget);
    expect(find.text('Take photo'), findsOneWidget);

    await tester.tap(find.text('Choose from gallery'));
    await tester.pumpAndSettle();
    expect(picker.imageSources, <DocumentImageSource>[
      DocumentImageSource.gallery,
    ]);

    await tester.tap(find.byTooltip('Insert image'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Take photo'));
    await tester.pumpAndSettle();
    expect(picker.imageSources, <DocumentImageSource>[
      DocumentImageSource.gallery,
      DocumentImageSource.camera,
    ]);
  });

  test('asset lifecycle copies and deletes with an in-memory note', () async {
    final InMemoryNoteRepository repository = InMemoryNoteRepository();
    addTearDown(repository.dispose);
    final note = await repository.createNote();
    final String asset = await repository.storeAsset(
      note.id,
      Uint8List.fromList(<int>[9, 8, 7]),
      kind: NoteAssetKind.image,
      extension: 'png',
    );
    final copy = await repository.duplicateNote(note.id);
    expect((await repository.readAsset(copy.id, asset)).bytes, <int>[9, 8, 7]);
    // Kept while the note is in Recently Deleted; gone once deleted for good.
    await repository.deleteNote(copy.id);
    expect((await repository.readAsset(copy.id, asset)).bytes, <int>[9, 8, 7]);
    await repository.deleteForever(copy.id);
    expect(() => repository.readAsset(copy.id, asset), throwsA(anything));
  });

  test('an image clipboard copies asset bytes into another note', () async {
    final InMemoryNoteRepository repository = InMemoryNoteRepository();
    addTearDown(repository.dispose);
    final source = await repository.createNote(title: 'Source');
    final destination = await repository.createNote(title: 'Destination');
    final String sourceAsset = await repository.storeAsset(
      source.id,
      Uint8List.fromList(<int>[1, 3, 5, 7]),
      kind: NoteAssetKind.image,
      extension: 'png',
      fileName: 'diagram.png',
    );
    final InkController sourceInk = InkController();
    final InkController destinationInk = InkController();
    addTearDown(sourceInk.dispose);
    addTearDown(destinationInk.dispose);
    sourceInk.insertImage(
      NoteImageElement(
        id: 'diagram',
        assetId: sourceAsset,
        pixelSize: const Size(40, 20),
        center: const InkVector(40, 30),
        size: const Size(40, 20),
      ),
    );
    sourceInk.cutSelection();

    final SharedNoteClipboard shared = SharedNoteClipboard();
    shared.capture(repository, source.id, sourceInk.clipboard!);
    destinationInk.takeClipboard(
      await shared.materialize(repository, destination.id),
    );
    expect(destinationInk.paste(), isTrue);
    final String destinationAsset = destinationInk.images.single.assetId;
    expect(destinationAsset, isNot(sourceAsset));
    expect(
      (await repository.readAsset(destination.id, destinationAsset)).bytes,
      <int>[1, 3, 5, 7],
    );
  });

  test('export page sizing includes exact Letter and the 14400 cap', () {
    final ExportPageGeometry letter = exportPageGeometry(
      const StoredPage(
        setup: PageSetup(size: PageSize.letterPortrait),
        strokes: [],
      ),
    );
    expect(letter.pointSize, const Size(612, 792));
    final ExportPageGeometry capped = exportPageGeometry(
      const StoredPage(
        setup: PageSetup(size: PageSize.custom, customSize: Size(40000, 20000)),
        strokes: [],
      ),
    );
    expect(capped.pointSize.width, 14400);
    expect(capped.pointSize.height, 7200);
  });

  test('a note exports vector ink to a PDF', () async {
    final InMemoryNoteRepository repository = InMemoryNoteRepository();
    addTearDown(repository.dispose);
    final note = await repository.createNote();
    final Uint8List bytes = await PdfExporter(rasterizer: FakePdfRasterizer())
        .buildPdf(
          noteId: note.id,
          title: 'Vector note',
          content: NoteContent.blank(
            const PageSetup(size: PageSize.letterPortrait),
          ),
          repository: repository,
        );
    expect(utf8.decode(bytes.sublist(0, 4)), '%PDF');
  });

  test('export parses each source PDF once for all of its pages', () async {
    final InMemoryNoteRepository repository = InMemoryNoteRepository();
    addTearDown(repository.dispose);
    final note = await repository.createNote();
    final String pdfAsset = await repository.storeAsset(
      note.id,
      Uint8List.fromList(<int>[1, 2, 3]),
      kind: NoteAssetKind.pdf,
      extension: 'pdf',
    );
    final _OpenOnceRasterizer rasterizer = _OpenOnceRasterizer();
    final Uint8List bytes = await PdfExporter(rasterizer: rasterizer).buildPdf(
      noteId: note.id,
      title: 'Imported',
      content: NoteContent(<StoredPage>[
        for (int i = 0; i < 3; i++)
          StoredPage(
            setup: const PageSetup(size: PageSize.letterPortrait),
            pdfSource: PdfPageSource(
              assetId: pdfAsset,
              pageIndex: i,
              pageSize: const Size(40, 50),
            ),
            strokes: const <Stroke>[],
          ),
      ]),
      repository: repository,
    );
    expect(utf8.decode(bytes.sublist(0, 4)), '%PDF');
    expect(rasterizer.opens, 1);
    expect(rasterizer.renderedPages, <int>[0, 1, 2]);
    expect(rasterizer.renderCalls, 0);
    expect(rasterizer.disposed, isTrue);
  });

  test('a note with strokes exports, though a stroke holds a Path', () async {
    final InMemoryNoteRepository repository = InMemoryNoteRepository();
    addTearDown(repository.dispose);
    final note = await repository.createNote();
    const StrokeStyle style = StrokeStyle(ink: InkPalette.ink, width: 3);
    final Uint8List bytes = await PdfExporter(rasterizer: FakePdfRasterizer())
        .buildPdf(
          noteId: note.id,
          title: 'Inked note',
          content: NoteContent(<StoredPage>[
            StoredPage(
              setup: const PageSetup(size: PageSize.letterPortrait),
              strokes: <Stroke>[
                Stroke.fromPoints(
                  style: style,
                  points: const <InkVector>[
                    InkVector(10, 10),
                    InkVector(60, 40),
                    InkVector(120, 20),
                  ],
                ),
                Stroke.fromPoints(
                  style: style,
                  points: const <InkVector>[InkVector(200, 200)],
                ),
              ],
            ),
          ]),
          repository: repository,
        );
    expect(utf8.decode(bytes.sublist(0, 4)), '%PDF');
  });
}
