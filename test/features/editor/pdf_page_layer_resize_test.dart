import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/document_io/document_io_config.dart';
import 'package:greatnote/features/editor/document_io/document_models.dart';
import 'package:greatnote/features/editor/document_io/document_platform.dart';
import 'package:greatnote/features/editor/document_io/pdf_page_layer.dart';
import 'package:greatnote/features/editor/document_io/pdf_paper.dart';

/// Renders a small PNG, and holds every render after the first until
/// [release] is called.
class _GatedRasterizer implements PdfRasterizer {
  _GatedRasterizer(this.png);

  final Uint8List png;
  final Completer<void> _gate = Completer<void>();
  int renders = 0;

  void release() => _gate.complete();

  @override
  Future<PdfInspection> inspect(Uint8List bytes) async {
    return const PdfInspection(pageSizes: <Size>[Size(612, 792)]);
  }

  @override
  Future<RasterizedPdfPage> render(
    Uint8List bytes,
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  }) async {
    if (renders++ > 0) {
      await _gate.future;
    }
    return RasterizedPdfPage(
      png: png,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    );
  }
}

class _DirectImageRasterizer implements PdfRasterizer, PdfImageRasterizer {
  int byteRenders = 0;
  int imageRenders = 0;

  @override
  Future<PdfInspection> inspect(Uint8List bytes) async {
    return const PdfInspection(pageSizes: <Size>[Size(612, 792)]);
  }

  @override
  Future<RasterizedPdfPage> render(
    Uint8List bytes,
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  }) async {
    byteRenders++;
    throw StateError('The encoded path should not be used for display.');
  }

  @override
  Future<ui.Image> renderImage(
    Uint8List bytes,
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  }) async {
    imageRenders++;
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(const Color(0xFF336699), BlendMode.src);
    return recorder.endRecording().toImage(pixelWidth, pixelHeight);
  }
}

/// Renders whole pages, and parts of them, logging each part.
class _RegionRasterizer extends _DirectImageRasterizer
    implements PdfDocumentRasterizer {
  final List<String> regions = <String>[];

  @override
  Future<OpenPdf> open(Uint8List bytes) async => _RegionOpenPdf(this);
}

class _RegionOpenPdf implements OpenPdf, PdfRegionRenderer {
  _RegionOpenPdf(this._rasterizer);

  final _RegionRasterizer _rasterizer;

  @override
  Future<ui.Image> renderImage(
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  }) => _rasterizer.renderImage(
    Uint8List(0),
    pageIndex,
    pixelWidth: pixelWidth,
    pixelHeight: pixelHeight,
  );

  @override
  Future<PdfPaper> renderRegion(
    int pageIndex, {
    required int fullWidth,
    required int fullHeight,
    required PdfPixelRegion region,
  }) async {
    _rasterizer.regions.add(
      '${region.x},${region.y} ${region.width}x${region.height} '
      'of ${fullWidth}x$fullHeight',
    );
    return PdfPaper.single(
      await renderImage(
        pageIndex,
        pixelWidth: region.width,
        pixelHeight: region.height,
      ),
    );
  }

  @override
  Future<void> dispose() async {}
}

Future<Uint8List> _png() async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 4, 4),
    Paint()..color = const Color(0xFF336699),
  );
  final ui.Image image = await recorder.endRecording().toImage(4, 4);
  final ByteData data = (await image.toByteData(
    format: ui.ImageByteFormat.png,
  ))!;
  image.dispose();
  return data.buffer.asUint8List();
}

void main() {
  testWidgets('PDF display uses direct images instead of a PNG round trip', (
    WidgetTester tester,
  ) async {
    final _DirectImageRasterizer rasterizer = _DirectImageRasterizer();
    final PdfPageRenderCache cache = PdfPageRenderCache(
      readAsset: (String _) async => Uint8List(1),
      rasterizer: rasterizer,
    );
    addTearDown(cache.clear);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 20,
          height: 20,
          child: PdfPageLayer(
            source: const PdfPageSource(
              assetId: 'pdf',
              pageIndex: 0,
              pageSize: Size(20, 20),
            ),
            displayedSize: const Size(20, 20),
            cache: cache,
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(find.byType(RawImage), findsOneWidget);
    expect(rasterizer.imageRenders, 1);
    expect(rasterizer.byteRenders, 0);
  });

  testWidgets('a resized PDF page keeps showing its paper while the sharper '
      'render loads', (WidgetTester tester) async {
    final Uint8List png = (await tester.runAsync(_png))!;
    final _GatedRasterizer rasterizer = _GatedRasterizer(png);
    final PdfPageRenderCache cache = PdfPageRenderCache(
      readAsset: (String _) async => Uint8List(1),
      rasterizer: rasterizer,
    );
    addTearDown(cache.clear);
    const PdfPageSource source = PdfPageSource(
      assetId: 'pdf',
      pageIndex: 0,
      pageSize: Size(612, 792),
    );

    Widget layer(Size size) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox.fromSize(
            size: size,
            child: PdfPageLayer(
              source: source,
              displayedSize: size,
              cache: cache,
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(layer(const Size(612, 792)));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    for (int i = 0; i < 5 && find.byType(RawImage).evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(find.byType(RawImage), findsOneWidget);

    // As when the AI panel narrows the writing area.
    await tester.pumpWidget(layer(const Size(400, 517)));
    await tester.pump();
    expect(rasterizer.renders, 2);
    expect(find.byType(RawImage), findsOneWidget);
    expect(find.bySemanticsLabel('Loading PDF page'), findsNothing);

    rasterizer.release();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(find.byType(RawImage), findsOneWidget);
  });

  testWidgets('a PDF page zoomed in past its paper has the part on screen '
      'rendered as sharp as it is seen, until zoomed out again', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    final _RegionRasterizer rasterizer = _RegionRasterizer();
    final PdfPageRenderCache cache = PdfPageRenderCache(
      readAsset: (String _) async => Uint8List(1),
      rasterizer: rasterizer,
      config: const DocumentIoConfig(
        pdfSettleDelay: Duration(milliseconds: 10),
        pdfScrollSettleDelay: Duration(milliseconds: 10),
      ),
    );
    addTearDown(cache.clear);
    final ValueNotifier<Rect> visible = ValueNotifier<Rect>(
      const Rect.fromLTRB(10, 20, 50, 60),
    );
    addTearDown(visible.dispose);

    Widget layer(double zoom) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: Transform.scale(
            scale: zoom,
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 100,
              height: 140,
              child: PdfPageLayer(
                source: const PdfPageSource(
                  assetId: 'pdf',
                  pageIndex: 0,
                  pageSize: Size(100, 140),
                ),
                displayedSize: const Size(100, 140),
                cache: cache,
                visible: visible,
              ),
            ),
          ),
        ),
      );
    }

    Future<void> settle() async {
      for (int i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      await tester.pump();
    }

    await tester.pumpWidget(layer(3));
    await settle();
    expect(rasterizer.imageRenders, greaterThanOrEqualTo(1));
    // The part on screen, with a margin, at three logical pixels, so six
    // device pixels, to a unit.
    expect(rasterizer.regions, <String>['45,105 270x270 of 600x840']);
    expect(find.byType(Positioned), findsOneWidget);

    await tester.pumpWidget(layer(1));
    visible.value = const Rect.fromLTRB(0, 0, 100, 140);
    await settle();
    expect(find.byType(Positioned), findsNothing);
    expect(rasterizer.regions, hasLength(1));
    expect(cache.renderScale.value, 1);

    // Zoomed out, the page is rendered no bigger than it is seen.
    await tester.pumpWidget(layer(0.7));
    visible.value = const Rect.fromLTRB(0, 0, 99, 140);
    await settle();
    expect(cache.renderScale.value, 0.7);
  });
}
