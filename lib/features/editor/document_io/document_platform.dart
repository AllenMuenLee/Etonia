import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart' as image_picker;
import 'package:pdfrx/pdfrx.dart' as pdfrx;
import 'package:share_plus/share_plus.dart';

import 'pdf_paper.dart';

@pragma('vm:immutable')
class PickedDocument {
  const PickedDocument({required this.name, required this.bytes});
  final String name;
  final Uint8List bytes;
}

enum DocumentImageSource { gallery, camera }

abstract interface class DocumentPicker {
  Future<PickedDocument?> pickPdf();
  Future<PickedDocument?> pickImage(DocumentImageSource source);
}

class SystemDocumentPicker implements DocumentPicker {
  const SystemDocumentPicker();

  @override
  Future<PickedDocument?> pickPdf() =>
      _pick(FileType.custom, const <String>['pdf']);

  @override
  Future<PickedDocument?> pickImage(DocumentImageSource source) async {
    final image_picker.XFile? file = await image_picker.ImagePicker().pickImage(
      source: switch (source) {
        DocumentImageSource.gallery => image_picker.ImageSource.gallery,
        DocumentImageSource.camera => image_picker.ImageSource.camera,
      },
    );
    if (file == null) {
      return null;
    }
    return PickedDocument(name: file.name, bytes: await file.readAsBytes());
  }

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

/// A run of a PDF page's own text, and where it lies: each side a share of the
/// page's width or height, from its top left corner, as the page is shown.
@immutable
class PdfTextRun {
  const PdfTextRun(this.text, this.bounds);

  final String text;
  final ui.Rect bounds;
}

/// Reads the text a PDF holds, for a [PdfRasterizer] that can. A scanned page
/// holds none, and is given as an empty list.
abstract interface class PdfTextExtractor {
  /// Each of [pageIndices], from zero, with its lines top to bottom as the PDF
  /// orders them. Throws when the PDF cannot be opened.
  Future<Map<int, List<PdfTextRun>>> extractText(
    Uint8List bytes,
    Set<int> pageIndices,
  );
}

/// [runs], as a PDF gives them, joined into whole lines: a run on the same line
/// as the one before it, and near it, continues it.
List<PdfTextRun> joinPdfTextRuns(Iterable<PdfTextRun> runs) {
  final List<PdfTextRun> lines = <PdfTextRun>[];
  for (final PdfTextRun run in runs) {
    final String text = run.text.trim();
    if (text.isEmpty) continue;
    final PdfTextRun? last = lines.lastOrNull;
    if (last != null) {
      final double height = math.max(last.bounds.height, run.bounds.height);
      final double gap = run.bounds.left - last.bounds.right;
      final bool sameLine =
          (run.bounds.center.dy - last.bounds.center.dy).abs() < height * 0.5;
      // Far enough apart on the page is another column, or a table's next cell.
      if (sameLine && gap > -height && gap < height * 3) {
        // A word space is about a quarter of the type's height, and writing
        // with no spaces, like Chinese, has no gap at all.
        final String joint = gap > height * 0.15 ? ' ' : '';
        lines[lines.length - 1] = PdfTextRun(
          '${last.text}$joint$text',
          last.bounds.expandToInclude(run.bounds),
        );
        continue;
      }
    }
    lines.add(PdfTextRun(text, run.bounds));
  }
  return lines;
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

/// An [OpenPdf] that can hand a big page to the engine in bands, so that no
/// single copy keeps the UI isolate from running a frame. See [PdfPaper].
abstract interface class PdfBandRenderer {
  Future<PdfPaper> renderPaper(
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  });
}

/// An [OpenPdf] that can render part of a page: [region], in the pixels of
/// the page rendered whole at [fullWidth] by [fullHeight]. A page zoomed in
/// is sharpened where it is seen, without rendering all of it that big.
abstract interface class PdfRegionRenderer {
  Future<PdfPaper> renderRegion(
    int pageIndex, {
    required int fullWidth,
    required int fullHeight,
    required PdfPixelRegion region,
  });
}

/// A rectangle of whole pixels.
typedef PdfPixelRegion = ({int x, int y, int width, int height});

/// An entry of a PDF's outline, its table of contents: a chapter, or a
/// section of one in [children].
@pragma('vm:immutable')
class PdfOutlineEntry {
  const PdfOutlineEntry({
    required this.title,
    this.pageIndex,
    this.children = const <PdfOutlineEntry>[],
  });

  final String title;

  /// The PDF page the entry opens, from zero. Null when it points nowhere.
  final int? pageIndex;

  final List<PdfOutlineEntry> children;
}

/// Optional capability: reading a PDF's outline, to go to its chapters.
abstract interface class PdfOutlineReader {
  /// The outline of [bytes], empty when the PDF has none.
  Future<List<PdfOutlineEntry>> readOutline(Uint8List bytes);
}

/// An [OpenPdf] that can read its own outline, without parsing the PDF again.
abstract interface class OpenPdfOutline {
  Future<List<PdfOutlineEntry>> readOutline();
}

/// PDFium-backed implementation. Every one-off operation owns and closes
/// its PDF; [open] hands the PDF to its caller.
class PdfrxRasterizer
    implements
        PdfRasterizer,
        PdfImageRasterizer,
        PdfDocumentRasterizer,
        PdfOutlineReader,
        PdfTextExtractor {
  const PdfrxRasterizer();

  @override
  Future<Map<int, List<PdfTextRun>>> extractText(
    Uint8List bytes,
    Set<int> pageIndices,
  ) async {
    final pdfrx.PdfDocument document = await _openForRendering(
      bytes,
      'greatnote-text-${bytes.length}-${identityHashCode(bytes)}',
    );
    try {
      final Map<int, List<PdfTextRun>> text = <int, List<PdfTextRun>>{};
      for (final int index in pageIndices) {
        if (index < 0 || index >= document.pages.length) continue;
        final pdfrx.PdfPage page = document.pages[index];
        final pdfrx.PdfPageText read = await page.loadStructuredText();
        text[index] = joinPdfTextRuns(<PdfTextRun>[
          for (final pdfrx.PdfPageTextFragment fragment in read.fragments)
            PdfTextRun(fragment.text, _shareOf(fragment, page)),
        ]);
      }
      return text;
    } finally {
      await document.dispose();
    }
  }

  /// Where [fragment] lies as a share of [page] as shown. Rotation and the
  /// flipped axis are the engine's to undo.
  static ui.Rect _shareOf(
    pdfrx.PdfPageTextFragment fragment,
    pdfrx.PdfPage page,
  ) {
    final ui.Rect rect = fragment.bounds.toRect(page: page);
    return ui.Rect.fromLTRB(
      rect.left / page.width,
      rect.top / page.height,
      rect.right / page.width,
      rect.bottom / page.height,
    );
  }

  @override
  Future<List<PdfOutlineEntry>> readOutline(Uint8List bytes) async {
    pdfrx.PdfDocument? document;
    try {
      document = await _openForRendering(
        bytes,
        'greatnote-outline-${bytes.length}-${identityHashCode(bytes)}',
      );
      return _outlineEntries(await document.loadOutline());
    } on pdfrx.PdfPasswordException {
      return const <PdfOutlineEntry>[];
    } finally {
      await document?.dispose();
    }
  }

  static List<PdfOutlineEntry> _outlineEntries(
    List<pdfrx.PdfOutlineNode> nodes,
  ) => <PdfOutlineEntry>[
    for (final pdfrx.PdfOutlineNode node in nodes)
      PdfOutlineEntry(
        title: node.title.trim(),
        // pdfrx counts pages from one.
        pageIndex: node.dest == null ? null : node.dest!.pageNumber - 1,
        children: _outlineEntries(node.children),
      ),
  ];

  @override
  Future<OpenPdf> open(Uint8List bytes) async {
    return _PdfrxOpenPdf(
      await _openForRendering(
        bytes,
        'greatnote-view-${bytes.length}-${identityHashCode(bytes)}',
      ),
    );
  }

  /// Opens [bytes] to render from. Only the first page is read up front:
  /// reading every page first keeps a long PDF's first page, and its
  /// thumbnail, waiting on the last. Any page still renders by its number.
  static Future<pdfrx.PdfDocument> _openForRendering(
    Uint8List bytes,
    String sourceName,
  ) => pdfrx.PdfDocument.openData(
    bytes,
    sourceName: sourceName,
    passwordProvider: () => null,
    useProgressiveLoading: true,
  );

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
    final pdfrx.PdfDocument document = await _openForRendering(
      bytes,
      'greatnote-render-${bytes.length}-$pageIndex',
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
      final ui.Image engineImage = await rendered.createImage();
      try {
        final ByteData? png = await engineImage.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (png == null) {
          throw StateError('The PDF page could not be encoded.');
        }
        return RasterizedPdfPage(
          png: png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
          pixelWidth: rendered.width,
          pixelHeight: rendered.height,
        );
      } finally {
        engineImage.dispose();
      }
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
    final pdfrx.PdfDocument document = await _openForRendering(
      bytes,
      'greatnote-display-${bytes.length}-$pageIndex',
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

class _PdfrxOpenPdf
    implements OpenPdf, PdfBandRenderer, PdfRegionRenderer, OpenPdfOutline {
  _PdfrxOpenPdf(this._document);

  final pdfrx.PdfDocument _document;

  @override
  Future<List<PdfOutlineEntry>> readOutline() async =>
      PdfrxRasterizer._outlineEntries(await _document.loadOutline());

  @override
  Future<ui.Image> renderImage(
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  }) => _renderPdfrxImage(_document, pageIndex, pixelWidth, pixelHeight);

  @override
  Future<PdfPaper> renderPaper(
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  }) => _renderPdfrxPaper(_document, pageIndex, pixelWidth, pixelHeight);

  @override
  Future<PdfPaper> renderRegion(
    int pageIndex, {
    required int fullWidth,
    required int fullHeight,
    required PdfPixelRegion region,
  }) => _renderPdfrxPaper(
    _document,
    pageIndex,
    fullWidth,
    fullHeight,
    region: region,
  );

  @override
  Future<void> dispose() => _document.dispose();
}

Future<pdfrx.PdfImage> _renderPdfrxBitmap(
  pdfrx.PdfDocument document,
  int pageIndex,
  int pixelWidth,
  int pixelHeight, {
  PdfPixelRegion? region,
}) async {
  if (pageIndex < 0 || pageIndex >= document.pages.length) {
    throw RangeError.index(pageIndex, document.pages, 'pageIndex');
  }
  final pdfrx.PdfImage? rendered = await document.pages[pageIndex].render(
    x: region?.x ?? 0,
    y: region?.y ?? 0,
    fullWidth: pixelWidth.toDouble(),
    fullHeight: pixelHeight.toDouble(),
    width: region?.width ?? pixelWidth,
    height: region?.height ?? pixelHeight,
    annotationRenderingMode: pdfrx.PdfAnnotationRenderingMode.none,
  );
  if (rendered == null) {
    throw StateError('The PDF page could not be rendered.');
  }
  return rendered;
}

Future<ui.Image> _renderPdfrxImage(
  pdfrx.PdfDocument document,
  int pageIndex,
  int pixelWidth,
  int pixelHeight,
) async {
  final pdfrx.PdfImage rendered = await _renderPdfrxBitmap(
    document,
    pageIndex,
    pixelWidth,
    pixelHeight,
  );
  try {
    return await rendered.createImage();
  } finally {
    rendered.dispose();
  }
}

/// Pixels handed to the engine at a time. The copy blocks the UI isolate at
/// about a millisecond per megapixel on a tablet, and a frame at 120 Hz is
/// eight; half a megapixel leaves room for the frame itself.
const int _bandPixels = 1 << 19;

Future<PdfPaper> _renderPdfrxPaper(
  pdfrx.PdfDocument document,
  int pageIndex,
  int pixelWidth,
  int pixelHeight, {
  PdfPixelRegion? region,
}) async {
  final pdfrx.PdfImage rendered = await _renderPdfrxBitmap(
    document,
    pageIndex,
    pixelWidth,
    pixelHeight,
    region: region,
  );
  try {
    final int width = rendered.width;
    final int height = rendered.height;
    if (width * height <= _bandPixels * 3 ~/ 2) {
      return PdfPaper.single(await rendered.createImage());
    }
    final int count = (width * height / _bandPixels).ceil();
    final int rows = (height / count).ceil();
    final List<ui.Image> bands = <ui.Image>[];
    try {
      for (int top = 0; top < height; top += rows) {
        final int bandRows = math.min(rows, height - top);
        bands.add(
          await _imageFromBgra(
            Uint8List.sublistView(
              rendered.pixels,
              top * width * 4,
              (top + bandRows) * width * 4,
            ),
            width,
            bandRows,
          ),
        );
      }
    } on Object {
      for (final ui.Image band in bands) {
        band.dispose();
      }
      rethrow;
    }
    return PdfPaper(bands);
  } finally {
    rendered.dispose();
  }
}

/// What pdfrx's `createImage` does, for [pixels] of a bitmap [width] wide:
/// the copy into the engine's buffer is the part that blocks.
Future<ui.Image> _imageFromBgra(Uint8List pixels, int width, int height) async {
  final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
    pixels,
  );
  ui.ImageDescriptor? descriptor;
  try {
    descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: width,
      height: height,
      pixelFormat: ui.PixelFormat.bgra8888,
    );
    final ui.Codec codec = await descriptor.instantiateCodec();
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  } finally {
    descriptor?.dispose();
    buffer.dispose();
  }
}

abstract interface class ExportSink {
  Future<void> share(File file, {ui.Rect? sharePositionOrigin});
}

class SystemExportSink implements ExportSink {
  const SystemExportSink();

  @override
  Future<void> share(File file, {ui.Rect? sharePositionOrigin}) async {
    final bool svg = file.path.toLowerCase().endsWith('.svg');
    await SharePlus.instance.share(
      ShareParams(
        files: <XFile>[
          XFile(file.path, mimeType: svg ? 'image/svg+xml' : 'application/pdf'),
        ],
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
