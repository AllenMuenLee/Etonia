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
import '../page/note_document.dart';
import '../page/page_setup.dart';
import 'document_io_config.dart';
import 'document_models.dart';
import 'document_platform.dart';

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
  });

  final PdfRasterizer rasterizer;
  final DocumentIoConfig config;

  Future<PdfImportPlan> validatePdf(PickedDocument picked) async {
    if (picked.bytes.lengthInBytes > config.maxImportPdfBytes) {
      throw DocumentImportException(
        'This PDF is larger than ${_megabytes(config.maxImportPdfBytes)} MB',
      );
    }
    late final PdfInspection inspection;
    try {
      inspection = await rasterizer.inspect(picked.bytes);
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
    return PdfImportPlan(
      name: picked.name,
      bytes: Uint8List.fromList(picked.bytes),
      pageSizes: List<Size>.unmodifiable(pageUnits),
    );
  }

  Future<NoteEntry> importPdfAsNote({
    required NoteRepository repository,
    required PickedDocument picked,
    String? folderId,
    ImportCancellationToken? cancellation,
  }) async {
    final PdfImportPlan plan = await validatePdf(picked);
    cancellation?.throwIfCancelled();
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
        plan.bytes,
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
              strokes: const [],
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
      if (note != null) {
        await repository.deleteNote(note.id);
      }
      rethrow;
    }
  }

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
