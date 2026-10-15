import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/document_io/document_models.dart';
import 'package:greatnote/features/editor/document_io/document_platform.dart';
import 'package:greatnote/features/editor/document_io/pdf_page_layer.dart';

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
    expect(find.byType(CircularProgressIndicator), findsNothing);

    rasterizer.release();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(find.byType(RawImage), findsOneWidget);
  });
}
