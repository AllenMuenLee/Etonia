import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:greatnote/features/editor/document_io/document_platform.dart';

class FakeDocumentPicker implements DocumentPicker {
  PickedDocument? pdf;
  PickedDocument? goodnotes;
  PickedDocument? image;

  @override
  Future<PickedDocument?> pickPdf() async => pdf;

  @override
  Future<PickedDocument?> pickGoodnotes() async => goodnotes ?? pdf;

  @override
  Future<PickedDocument?> pickImage() async => image;
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
