import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
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

  /// A PDF exported from Goodnotes or a native `.goodnotes` notebook.
  Future<PickedDocument?> pickGoodnotes();
  Future<PickedDocument?> pickImage();
}

class SystemDocumentPicker implements DocumentPicker {
  const SystemDocumentPicker();

  @override
  Future<PickedDocument?> pickPdf() =>
      _pick(FileType.custom, const <String>['pdf']);

  /// Any file: `.goodnotes` is not a type every platform's picker can
  /// filter by, so what is picked is told apart by its contents.
  @override
  Future<PickedDocument?> pickGoodnotes() => _pick(FileType.any, null);

  @override
  Future<PickedDocument?> pickImage() => _pick(FileType.image, null);

  Future<PickedDocument?> _pick(FileType type, List<String>? extensions) async {
    final PlatformFile? file = await FilePicker.pickFile(
      type: type,
      allowedExtensions: extensions,
    );
    if (file == null) {
      return null;
    }
    final PickedDocument picked = PickedDocument(
      name: file.name,
      bytes: await file.readAsBytes(),
    );
    // The picker copies each file it is given into the app's cache; once
    // read, that copy is only taking space.
    try {
      await FilePicker.clearTemporaryFiles();
    } on Object {
      // Left for the system to clear.
    }
    return picked;
  }
}

@pragma('vm:immutable')
class PdfInspection {
  const PdfInspection({required this.pageSizes, this.isEncrypted = false});
  final List<ui.Size> pageSizes;
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

/// Optional fast path for consumers that display a rasterized page directly.
///
/// [PdfRasterizer.render] returns PNG bytes because exports and clipboard
/// operations need an encoded image. Screen rendering does not: turning the
/// PDF's raw pixels into PNG and decoding them again is avoidable work.
abstract interface class PdfImageRasterizer {
  Future<ui.Image> renderImage(
    Uint8List bytes,
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  });
}

/// Optional fast path for paging through one PDF: it is parsed once and
/// then rendered page by page, instead of parsed again for every page.
abstract interface class PdfDocumentRasterizer {
  Future<OpenPdf> open(Uint8List bytes);
}

/// A PDF kept open by a [PdfDocumentRasterizer]. Its owner disposes it, and
/// never while one of its renders is still in progress.
abstract interface class OpenPdf {
  Future<ui.Image> renderImage(
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  });

  Future<void> dispose();
}

/// PDFium-backed implementation. Every one-off operation owns and closes
/// its PDF; [open] hands the PDF to its caller.
class PdfrxRasterizer
    implements PdfRasterizer, PdfImageRasterizer, PdfDocumentRasterizer {
  const PdfrxRasterizer();

  @override
  Future<OpenPdf> open(Uint8List bytes) async {
    return _PdfrxOpenPdf(
      await pdfrx.PdfDocument.openData(
        bytes,
        sourceName: 'greatnote-view-${bytes.length}-${identityHashCode(bytes)}',
        passwordProvider: () => null,
      ),
    );
  }

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
        pageSizes: <ui.Size>[
          for (final pdfrx.PdfPage page in document.pages)
            ui.Size(page.width, page.height),
        ],
      );
    } on pdfrx.PdfPasswordException {
      return const PdfInspection(pageSizes: <ui.Size>[], isEncrypted: true);
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

  @override
  Future<ui.Image> renderImage(
    Uint8List bytes,
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  }) async {
    final pdfrx.PdfDocument document = await pdfrx.PdfDocument.openData(
      bytes,
      sourceName: 'greatnote-display-${bytes.length}-$pageIndex',
      passwordProvider: () => null,
    );
    try {
      return await _renderPdfrxImage(
        document,
        pageIndex,
        pixelWidth,
        pixelHeight,
      );
    } finally {
      await document.dispose();
    }
  }
}

class _PdfrxOpenPdf implements OpenPdf {
  _PdfrxOpenPdf(this._document);

  final pdfrx.PdfDocument _document;

  @override
  Future<ui.Image> renderImage(
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  }) => _renderPdfrxImage(_document, pageIndex, pixelWidth, pixelHeight);

  @override
  Future<void> dispose() => _document.dispose();
}

Future<ui.Image> _renderPdfrxImage(
  pdfrx.PdfDocument document,
  int pageIndex,
  int pixelWidth,
  int pixelHeight,
) async {
  if (pageIndex < 0 || pageIndex >= document.pages.length) {
    throw RangeError.index(pageIndex, document.pages, 'pageIndex');
  }
  final pdfrx.PdfImage? rendered = await document.pages[pageIndex].render(
    fullWidth: pixelWidth.toDouble(),
    fullHeight: pixelHeight.toDouble(),
    width: pixelWidth,
    height: pixelHeight,
    annotationRenderingMode: pdfrx.PdfAnnotationRenderingMode.none,
  );
  if (rendered == null) {
    throw StateError('The PDF page could not be rendered.');
  }
  try {
    return await rendered.createImage();
  } finally {
    rendered.dispose();
  }
}

abstract interface class ExportSink {
  Future<void> share(File file, {ui.Rect? sharePositionOrigin});
}

class SystemExportSink implements ExportSink {
  const SystemExportSink();

  @override
  Future<void> share(File file, {ui.Rect? sharePositionOrigin}) async {
    await SharePlus.instance.share(
      ShareParams(
        files: <XFile>[XFile(file.path, mimeType: 'application/pdf')],
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }
}

/// PDFs and notebooks shared into the app from another app's share sheet
/// or "Open with" menu.
abstract interface class SharedDocumentSource {
  /// Any documents that launched the app and have not yet been taken.
  Future<List<PickedDocument>> takeInitialDocuments();

  /// Documents shared into the app while it is already running.
  Stream<PickedDocument> get incomingDocuments;
}

class SystemSharedDocumentSource implements SharedDocumentSource {
  const SystemSharedDocumentSource();

  static const MethodChannel _channel = MethodChannel(
    'com.etonia.app/shared_documents',
  );

  static final StreamController<PickedDocument> _incoming =
      StreamController<PickedDocument>.broadcast();
  static bool _listening = false;

  static void _ensureListening() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'onDocumentShared') {
        final PickedDocument? doc = _decodeDocument(call.arguments);
        if (doc != null) {
          _incoming.add(doc);
        }
      }
    });
  }

  static PickedDocument? _decodeDocument(Object? raw) {
    if (raw is! Map<Object?, Object?>) return null;
    final Object? name = raw['name'];
    final Object? bytes = raw['bytes'];
    if (name is! String || bytes is! Uint8List || bytes.isEmpty) {
      return null;
    }
    return PickedDocument(name: name, bytes: bytes);
  }

  @override
  Stream<PickedDocument> get incomingDocuments {
    _ensureListening();
    return _incoming.stream;
  }

  @override
  Future<List<PickedDocument>> takeInitialDocuments() async {
    _ensureListening();
    try {
      final List<Object?>? raw = await _channel.invokeListMethod<Object?>(
        'takeInitialDocuments',
      );
      if (raw == null || raw.isEmpty) {
        return const <PickedDocument>[];
      }
      return <PickedDocument>[
        for (final Object? entry in raw)
          if (_decodeDocument(entry) case final PickedDocument doc) doc,
      ];
    } on MissingPluginException {
      return const <PickedDocument>[];
    } on PlatformException {
      return const <PickedDocument>[];
    }
  }
}
