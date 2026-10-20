import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:greatnote/features/editor/document_io/document_platform.dart';

class FakeDocumentPicker implements DocumentPicker {
  PickedDocument? pdf;
  PickedDocument? goodnotes;
  PickedDocument? image;
  final List<DocumentImageSource> imageSources = <DocumentImageSource>[];

  @override
  Future<PickedDocument?> pickPdf() async => pdf;

  @override
  Future<PickedDocument?> pickGoodnotes() async => goodnotes ?? pdf;

  @override
  Future<PickedDocument?> pickImage(DocumentImageSource source) async {
    imageSources.add(source);
    return image;
  }
}

class FakeSharedDocumentSource implements SharedDocumentSource {
  FakeSharedDocumentSource({List<PickedDocument>? initial})
    : _initial = List<PickedDocument>.of(initial ?? const <PickedDocument>[]);

  final List<PickedDocument> _initial;
  final StreamController<PickedDocument> _controller =
      StreamController<PickedDocument>.broadcast();

  void share(PickedDocument document) {
    _controller.add(document);
  }

  Future<void> dispose() => _controller.close();

  @override
  Stream<PickedDocument> get incomingDocuments => _controller.stream;

  @override
  Future<List<PickedDocument>> takeInitialDocuments() async {
    final List<PickedDocument> taken = List<PickedDocument>.of(_initial);
    _initial.clear();
    return taken;
  }
}

class FakePdfRasterizer implements PdfRasterizer {
  FakePdfRasterizer({
    this.inspection = const PdfInspection(pageSizes: <Size>[Size(612, 792)]),
    Uint8List? renderedPng,
  }) : renderedPng = renderedPng ?? Uint8List(0);

  PdfInspection inspection;
  Uint8List renderedPng;
  int renderCalls = 0;

  @override
  Future<PdfInspection> inspect(Uint8List bytes) async => inspection;

  @override
  Future<RasterizedPdfPage> render(
    Uint8List bytes,
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  }) async {
    renderCalls++;
    return RasterizedPdfPage(
      png: renderedPng,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    );
  }
}

class FakeExportSink implements ExportSink {
  File? file;

  @override
  Future<void> share(File file, {Rect? sharePositionOrigin}) async {
    this.file = file;
  }
}
