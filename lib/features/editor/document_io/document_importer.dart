import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:image/image.dart' as image;

import '../../library/library_models.dart';
import '../../library/note_content.dart';
import '../../library/note_repository.dart';
import '../ink/ink_controller.dart';
import '../ink/ink_sample.dart';
import '../ink/stroke.dart';
import '../page/note_document.dart';
import '../page/page_setup.dart';
import 'document_io_config.dart';
import 'document_models.dart';
import 'document_platform.dart';
import 'goodnotes_archive_extractor.dart';
import 'goodnotes_pdf_recovery.dart';

class DocumentImportException implements Exception {
  const DocumentImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ImportCancellationToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
  void throwIfCancelled() {
    if (_cancelled) {
      throw const DocumentImportException('Import cancelled');
    }
  }
}

class PdfImportPlan {
  const PdfImportPlan({
    required this.name,
    required this.bytes,
    required this.pageSizes,
  });
  final String name;
  final Uint8List bytes;
  final List<Size> pageSizes;
}

class DocumentImporter {
  const DocumentImporter({
    required this.rasterizer,
    this.config = const DocumentIoConfig(),
    this.goodnotesRecoverer = const GoodnotesPdfRecoverer(),
    this.goodnotesExtractor = const GoodnotesArchiveExtractor(),
  });

  final PdfRasterizer rasterizer;
  final DocumentIoConfig config;
  final GoodnotesPdfRecoverer goodnotesRecoverer;
  final GoodnotesArchiveExtractor goodnotesExtractor;

  Future<PdfImportPlan> validatePdf(PickedDocument picked) async {
    return PdfImportPlan(
      name: picked.name,
      bytes: Uint8List.fromList(picked.bytes),
      pageSizes: await _pdfPageSizes(picked.bytes),
    );
  }

  /// The size of each page of [bytes] in page units, once it is known to
  /// be a PDF that can be imported.
  Future<List<Size>> _pdfPageSizes(Uint8List bytes) async {
    if (bytes.lengthInBytes > config.maxImportPdfBytes) {
      throw DocumentImportException(
        'This PDF is larger than ${_megabytes(config.maxImportPdfBytes)} MB',
      );
    }
    late final PdfInspection inspection;
    try {
      inspection = await rasterizer.inspect(bytes);
    } on Object {
      throw const DocumentImportException('This PDF could not be opened');
    }
    if (inspection.isEncrypted) {
      throw const DocumentImportException('This PDF is password-protected');
    }
    if (inspection.pageSizes.isEmpty) {
      throw const DocumentImportException('This PDF has no pages');
    }
    if (inspection.pageSizes.length > config.maxImportPdfPages) {
      throw DocumentImportException(
        'This PDF has more than ${config.maxImportPdfPages} pages',
      );
    }
    final List<Size> pageUnits = <Size>[];
    for (final Size points in inspection.pageSizes) {
      if (!points.isFinite || points.width <= 0 || points.height <= 0) {
        throw const DocumentImportException('This PDF could not be opened');
      }
      pageUnits.add(points * DocumentUnits.pageUnitsPerPdfPoint);
    }
    return List<Size>.unmodifiable(pageUnits);
  }

  /// A new note with one page per page of [picked].
  ///
  /// With [recoverGoodnotesInk], the PDF is taken to be a Goodnotes export
  /// and its handwriting is extracted into editable strokes. When none can
  /// be found, [onNoInkRecovered] is called. A recognized Goodnotes badge
  /// can still be removed even when the page has no recoverable handwriting.
  ///
  /// A native `.goodnotes` notebook is recognized by its contents and
  /// imported by [importGoodnotesAsNote].
  Future<NoteEntry> importPdfAsNote({
    required NoteRepository repository,
    required PickedDocument picked,
    String? folderId,
    ImportCancellationToken? cancellation,
    bool recoverGoodnotesInk = false,
    void Function()? onNoInkRecovered,
  }) async {
    if (GoodnotesArchiveExtractor.isGoodnotesArchive(picked.bytes)) {
      return importGoodnotesAsNote(
        repository: repository,
        picked: picked,
        folderId: folderId,
        cancellation: cancellation,
      );
    }
    final PdfImportPlan plan = await validatePdf(picked);
    cancellation?.throwIfCancelled();
    final GoodnotesPdfRecovery? recovery = recoverGoodnotesInk
        ? await goodnotesRecoverer.recover(
            bytes: plan.bytes,
            pageSizes: plan.pageSizes,
            config: config,
            isCancelled: () => cancellation?.isCancelled ?? false,
          )
        : null;
    cancellation?.throwIfCancelled();
    if (recoverGoodnotesInk &&
        (recovery == null ||
            !recovery.pageStrokes.any(
              (List<Stroke> page) => page.isNotEmpty,
            ))) {
      onNoInkRecovered?.call();
    }
    final String base = plan.name.replaceFirst(
      RegExp(r'\.pdf$', caseSensitive: false),
      '',
    );
    final String title = cleanName(base) ?? 'Imported PDF';
    NoteEntry? note;
    try {
      note = await repository.createNote(title: title, folderId: folderId);
      cancellation?.throwIfCancelled();
      final String assetId = await repository.storeAsset(
        note.id,
        recovery?.backgroundPdf ?? plan.bytes,
        kind: NoteAssetKind.pdf,
        extension: 'pdf',
        fileName: plan.name,
      );
      cancellation?.throwIfCancelled();
      await repository.saveNote(
        note.id,
        NoteContent(<StoredPage>[
          for (int i = 0; i < plan.pageSizes.length; i++)
            StoredPage(
              setup: PageSetup(
                size: PageSize.custom,
                customSize: plan.pageSizes[i],
                background: PageBackground.blank,
              ),
              strokes: recovery?.pageStrokes[i] ?? const <Stroke>[],
              pdfSource: PdfPageSource(
                assetId: assetId,
                pageIndex: i,
                pageSize: plan.pageSizes[i],
              ),
            ),
        ]),
      );
      cancellation?.throwIfCancelled();
      return note;
    } on Object {
      // A half-made note is not something to restore: it goes for good.
      if (note != null) {
        await repository.deleteNote(note.id);
        await repository.deleteForever(note.id);
      }
      rethrow;
    }
  }

  /// A new note from a native `.goodnotes` notebook: every page at its
  /// size and in its order, on its PDF paper where it has some, with its
  /// handwriting, highlighting, and shapes as editable strokes.
  ///
  /// [picked] may come from the file picker or straight from memory, as
  /// from a cloud import.
  Future<NoteEntry> importGoodnotesAsNote({
    required NoteRepository repository,
    required PickedDocument picked,
    String? folderId,
    ImportCancellationToken? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final GoodnotesArchiveExtraction extraction = await goodnotesExtractor
        .extract(
          picked.bytes,
          fileName: picked.name,
          config: config,
          pdfPageSizes: _pdfPageSizes,
          isCancelled: () => cancellation?.isCancelled ?? false,
        );
    cancellation?.throwIfCancelled();
    final String title = cleanName(extraction.title) ?? 'Imported Goodnotes';
    NoteEntry? note;
    try {
      note = await repository.createNote(title: title, folderId: folderId);
      final List<String> assetIds = <String>[];
      for (final Uint8List pdf in extraction.pdfAttachments) {
        cancellation?.throwIfCancelled();
        assetIds.add(
          await repository.storeAsset(
            note.id,
            pdf,
            kind: NoteAssetKind.pdf,
            extension: 'pdf',
            fileName: extraction.pdfAttachments.length == 1
                ? '$title.pdf'
                : '$title ${assetIds.length + 1}.pdf',
          ),
        );
      }
      cancellation?.throwIfCancelled();
      await repository.saveNote(
        note.id,
        NoteContent(<StoredPage>[
          for (int i = 0; i < extraction.pageCount; i++)
            StoredPage(
              setup: PageSetup(
                size: PageSize.custom,
                customSize: extraction.pageSizes[i],
                background: PageBackground.blank,
              ),
              strokes: extraction.pageStrokes[i],
              pdfSource: extraction.pdfAttachmentIndices[i] == null
                  ? null
                  : PdfPageSource(
                      assetId: assetIds[extraction.pdfAttachmentIndices[i]!],
                      pageIndex: extraction.pdfPageIndices[i]!,
                      pageSize: extraction.pageSizes[i],
                    ),
            ),
        ]),
      );
      cancellation?.throwIfCancelled();
      return note;
    } on Object {
      if (note != null) {
        await repository.deleteNote(note.id);
        await repository.deleteForever(note.id);
      }
      rethrow;
    }
  }

  /// Inserts the pages of [picked] after the current page, as they are:
  /// Goodnotes handwriting is extracted only when importing a new note.
  Future<void> insertPdfPages({
    required NoteRepository repository,
    required String noteId,
    required NoteDocument document,
    required PickedDocument picked,
    ImportCancellationToken? cancellation,
  }) async {
    final PdfImportPlan plan = await validatePdf(picked);
    cancellation?.throwIfCancelled();
    String? assetId;
    try {
      assetId = await repository.storeAsset(
        noteId,
        plan.bytes,
        kind: NoteAssetKind.pdf,
        extension: 'pdf',
        fileName: plan.name,
      );
      cancellation?.throwIfCancelled();
      document.insertPagesAfterCurrent(<NotePage>[
        for (int i = 0; i < plan.pageSizes.length; i++)
          NotePage(
            ink: InkController(),
            setup: PageSetup(
              size: PageSize.custom,
              customSize: plan.pageSizes[i],
              background: PageBackground.blank,
            ),
            pdfSource: PdfPageSource(
              assetId: assetId,
              pageIndex: i,
              pageSize: plan.pageSizes[i],
            ),
          ),
      ]);
    } on Object {
      if (assetId != null) {
        await repository.removeAsset(noteId, assetId);
      }
      rethrow;
    }
  }

  Future<NoteImageElement> insertImage({
    required NoteRepository repository,
    required String noteId,
    required InkController controller,
    required PickedDocument picked,
    required Rect visiblePage,
  }) async {
    if (picked.bytes.lengthInBytes > config.maxImageImportBytes) {
      throw DocumentImportException(
        'This image is larger than ${_megabytes(config.maxImageImportBytes)} MB',
      );
    }
    final _NormalizedImage normalized;
    try {
      normalized = await Isolate.run(
        () => _normalizeImage(picked.bytes, config.maxStoredImageDimension),
      );
    } on Object {
      throw const DocumentImportException('This image could not be opened');
    }
    final String assetId = await repository.storeAsset(
      noteId,
      normalized.bytes,
      kind: NoteAssetKind.image,
      extension: normalized.extension,
      fileName: picked.name,
    );
    final double scale = math.min(
      1,
      math.min(
        visiblePage.width * config.insertedImageMaxFraction / normalized.width,
        visiblePage.height *
            config.insertedImageMaxFraction /
            normalized.height,
      ),
    );
    final NoteImageElement element = NoteImageElement(
      id: 'image-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      assetId: assetId,
      pixelSize: Size(
        normalized.width.toDouble(),
        normalized.height.toDouble(),
      ),
      center: InkVector(visiblePage.center.dx, visiblePage.center.dy),
      size: Size(normalized.width * scale, normalized.height * scale),
      fileName: picked.name,
    );
    if (!controller.insertImage(element)) {
      await repository.removeAsset(noteId, assetId);
      throw const DocumentImportException('This image could not be inserted');
    }
    return element;
  }
}

int _megabytes(int bytes) => (bytes / (1024 * 1024)).ceil();

class _NormalizedImage {
  const _NormalizedImage({
    required this.bytes,
    required this.extension,
    required this.width,
    required this.height,
  });
  final Uint8List bytes;
  final String extension;
  final int width;
  final int height;
}

_NormalizedImage _normalizeImage(Uint8List bytes, int maxDimension) {
  image.Image? decoded = image.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException('Unsupported image');
  }
  decoded = image.bakeOrientation(decoded);
  final int longest = math.max(decoded.width, decoded.height);
  if (longest > maxDimension) {
    final double scale = maxDimension / longest;
    decoded = image.copyResize(
      decoded,
      width: math.max(1, (decoded.width * scale).round()),
      height: math.max(1, (decoded.height * scale).round()),
      interpolation: image.Interpolation.cubic,
    );
  }
  final bool alpha = decoded.hasAlpha;
  return _NormalizedImage(
    bytes: Uint8List.fromList(
      alpha ? image.encodePng(decoded) : image.encodeJpg(decoded, quality: 92),
    ),
    extension: alpha ? 'png' : 'jpg',
    width: decoded.width,
    height: decoded.height,
  );
}
