import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as image;
import 'package:pdfrx/pdfrx.dart' as pdfrx;
import 'package:share_plus/share_plus.dart';

@pragma('vm:immutable')
class PickedDocument {
  const PickedDocument({required this.name, required this.bytes});
  final String name;
  final Uint8List bytes;
}

abstract interface class DocumentPicker {
  Future<PickedDocument?> pickPdf();
  Future<PickedDocument?> pickImage();
}

class SystemDocumentPicker implements DocumentPicker {
  const SystemDocumentPicker();

  @override
  Future<PickedDocument?> pickPdf() =>
      _pick(FileType.custom, const <String>['pdf']);

  @override
  Future<PickedDocument?> pickImage() => _pick(FileType.image, null);

  Future<PickedDocument?> _pick(FileType type, List<String>? extensions) async {
    final PlatformFile? file = await FilePicker.pickFile(
      type: type,
      allowedExtensions: extensions,
    );
    return file == null
        ? null
        : PickedDocument(name: file.name, bytes: await file.readAsBytes());
  }
}

@pragma('vm:immutable')
class PdfInspection {
  const PdfInspection({required this.pageSizes, this.isEncrypted = false});
  final List<Size> pageSizes;
  final bool isEncrypted;
}

@pragma('vm:immutable')
class RasterizedPdfPage {
  const RasterizedPdfPage({
    required this.png,
    required this.pixelWidth,
    required this.pixelHeight,
  });
  final Uint8List png;
  final int pixelWidth;
  final int pixelHeight;
}

abstract interface class PdfRasterizer {
  Future<PdfInspection> inspect(Uint8List bytes);
  Future<RasterizedPdfPage> render(
    Uint8List bytes,
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  });
}

/// PDFium-backed implementation. Every operation owns and closes its PDF.
class PdfrxRasterizer implements PdfRasterizer {
  const PdfrxRasterizer();

  @override
  Future<PdfInspection> inspect(Uint8List bytes) async {
    pdfrx.PdfDocument? document;
    try {
      document = await pdfrx.PdfDocument.openData(
        bytes,
        sourceName: 'greatnote-import-${bytes.length}',
        passwordProvider: () => null,
      );
      return PdfInspection(
        isEncrypted: document.isEncrypted,
        pageSizes: <Size>[
          for (final pdfrx.PdfPage page in document.pages)
            Size(page.width, page.height),
        ],
      );
    } on pdfrx.PdfPasswordException {
      return const PdfInspection(pageSizes: <Size>[], isEncrypted: true);
    } finally {
      await document?.dispose();
    }
  }

  @override
  Future<RasterizedPdfPage> render(
    Uint8List bytes,
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  }) async {
    final pdfrx.PdfDocument document = await pdfrx.PdfDocument.openData(
      bytes,
      sourceName: 'greatnote-render-${bytes.length}-$pageIndex',
      passwordProvider: () => null,
    );
    pdfrx.PdfImage? rendered;
    try {
      if (pageIndex < 0 || pageIndex >= document.pages.length) {
        throw RangeError.index(pageIndex, document.pages, 'pageIndex');
      }
      rendered = await document.pages[pageIndex].render(
        fullWidth: pixelWidth.toDouble(),
        fullHeight: pixelHeight.toDouble(),
        width: pixelWidth,
        height: pixelHeight,
        annotationRenderingMode: pdfrx.PdfAnnotationRenderingMode.none,
      );
      if (rendered == null) {
        throw StateError('The PDF page could not be rendered.');
      }
      final image.Image decoded = image.Image.fromBytes(
        width: rendered.width,
        height: rendered.height,
        bytes: rendered.pixels.buffer,
        bytesOffset: rendered.pixels.offsetInBytes,
        order: image.ChannelOrder.bgra,
      );
      return RasterizedPdfPage(
        png: Uint8List.fromList(image.encodePng(decoded)),
        pixelWidth: rendered.width,
        pixelHeight: rendered.height,
      );
    } finally {
      rendered?.dispose();
      await document.dispose();
    }
  }
}

abstract interface class ExportSink {
  Future<void> share(File file, {Rect? sharePositionOrigin});
}

class SystemExportSink implements ExportSink {
  const SystemExportSink();

  @override
  Future<void> share(File file, {Rect? sharePositionOrigin}) async {
    await SharePlus.instance.share(
      ShareParams(
        files: <XFile>[XFile(file.path, mimeType: 'application/pdf')],
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }
}
