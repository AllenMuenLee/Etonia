import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/document_io/document_io_config.dart';
import 'package:greatnote/features/editor/document_io/document_models.dart';
import 'package:greatnote/features/editor/document_io/document_platform.dart';
import 'package:greatnote/features/editor/document_io/pdf_page_layer.dart';
import 'package:greatnote/features/editor/document_io/pdf_paper.dart';

Future<ui.Image> _solid(int width, int height, ui.Color color) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(color, ui.BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

Future<ui.Image> _rows(int width, List<ui.Color> colors) async {
  final recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  for (int y = 0; y < colors.length; y++) {
    canvas.drawRect(
      ui.Rect.fromLTWH(0, y.toDouble(), width.toDouble(), 1),
      ui.Paint()..color = colors[y],
    );
  }
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, colors.length);
  } finally {
    picture.dispose();
  }
}

Future<int> _pixel(ui.Image image, int x, int y) async {
  final data = (await image.toByteData())!;
  return data.getUint32((y * image.width + x) * 4);
}

const ui.Color _red = ui.Color(0xffff0000);
const ui.Color _green = ui.Color(0xff00ff00);
const ui.Color _blue = ui.Color(0xff0000ff);

/// Renders each page in three bands, as the pdfrx rasterizer does for a page
/// too big to hand to the engine at once.
class _BandedRasterizer implements PdfRasterizer, PdfDocumentRasterizer {
  int bandRenders = 0;

  @override
  Future<PdfInspection> inspect(Uint8List bytes) => throw UnimplementedError();

  @override
  Future<RasterizedPdfPage> render(
    Uint8List bytes,
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  }) => throw UnimplementedError();

  @override
  Future<OpenPdf> open(Uint8List bytes) async => _BandedOpenPdf(this);
}

class _BandedOpenPdf implements OpenPdf, PdfBandRenderer {
  _BandedOpenPdf(this._owner);

  final _BandedRasterizer _owner;

  @override
  Future<ui.Image> renderImage(
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  }) => throw StateError('A banded PDF is shown band by band.');

  @override
  Future<PdfPaper> renderPaper(
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  }) async {
    _owner.bandRenders++;
    final int rows = pixelHeight ~/ 3;
    return PdfPaper(<ui.Image>[
      await _solid(pixelWidth, rows, _red),
      await _solid(pixelWidth, rows, _green),
      await _solid(pixelWidth, pixelHeight - 2 * rows, _blue),
    ]);
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  testWidgets('bands add up to one page, and draw into a single image', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final paper = PdfPaper(<ui.Image>[
        await _solid(4, 3, _red),
        await _solid(4, 3, _green),
        await _solid(4, 2, _blue),
      ]);
      expect(paper.isSingle, isFalse);
      expect([paper.width, paper.height], [4, 8]);

      final whole = await paper.toImage();
      expect([whole.width, whole.height], [4, 8]);
      expect(await _pixel(whole, 1, 0), 0xff0000ff);
      expect(await _pixel(whole, 1, 2), 0xff0000ff);
      expect(await _pixel(whole, 1, 3), 0x00ff00ff);
      expect(await _pixel(whole, 1, 5), 0x00ff00ff);
      expect(await _pixel(whole, 1, 6), 0x0000ffff);
      expect(await _pixel(whole, 1, 7), 0x0000ffff);

      // A clone outlives the original, and each handle goes on its own.
      final clone = paper.clone();
      paper.dispose();
      expect([clone.width, clone.height], [4, 8]);
      clone.dispose();
      whole.dispose();
    });
  });

  testWidgets('a single image is not copied to draw it whole', (tester) async {
    await tester.runAsync(() async {
      final paper = PdfPaper.single(await _solid(5, 7, _red));
      expect(paper.isSingle, isTrue);
      final whole = await paper.toImage();
      expect([whole.width, whole.height], [5, 7]);
      whole.dispose();
      paper.dispose();
    });
  });

  testWidgets('band boundaries preserve every source row without squishing', (
    tester,
  ) async {
    await tester.runAsync(() async {
      const colors = <ui.Color>[
        ui.Color(0xff100000),
        ui.Color(0xff200000),
        ui.Color(0xff300000),
        ui.Color(0xff400000),
        ui.Color(0xff500000),
        ui.Color(0xff600000),
        ui.Color(0xff700000),
        ui.Color(0xff800000),
      ];
      final paper = PdfPaper(<ui.Image>[
        await _rows(4, colors.sublist(0, 4)),
        await _rows(4, colors.sublist(4)),
      ]);
      final recorder = ui.PictureRecorder();
      paper.paint(
        ui.Canvas(recorder),
        const ui.Rect.fromLTWH(0, 0, 4, 8),
        ui.Paint()
          ..filterQuality = ui.FilterQuality.none
          ..isAntiAlias = false,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(4, 8);
      for (int y = 0; y < colors.length; y++) {
        final int argb = colors[y].toARGB32();
        final int rgba = ((argb & 0x00ffffff) << 8) | (argb >>> 24);
        expect(await _pixel(image, 1, y), rgba, reason: 'row $y');
      }
      image.dispose();
      picture.dispose();
      paper.dispose();
    });
  });

  testWidgets('a banded page is shown, drawn as one page, and exported as one '
      'image', (tester) async {
    await tester.runAsync(() async {
      final rasterizer = _BandedRasterizer();
      final cache = PdfPageRenderCache(
        readAsset: (_) async => Uint8List(1),
        rasterizer: rasterizer,
        config: const DocumentIoConfig(),
      );
      const source = PdfPageSource(
        assetId: 'pdf',
        pageIndex: 0,
        pageSize: ui.Size(10, 12),
      );
      final shown = Completer<PdfPaper>();
      final ticket = cache.show(
        source,
        const ui.Size(10, 12),
        1,
        onImage: (paper, sharp) {
          if (sharp) shown.complete(paper);
        },
        onError: shown.completeError,
      );
      final paper = await shown.future.timeout(const Duration(seconds: 5));
      expect(paper.isSingle, isFalse);
      expect([paper.width, paper.height], [10, 12]);
      paper.dispose();
      ticket.cancel();

      // Export and the clipboard get a whole image, and the page is not
      // rendered a second time for it.
      final whole = await cache.renderImage(source, const ui.Size(10, 12), 1);
      expect([whole.width, whole.height], [10, 12]);
      expect(await _pixel(whole, 0, 0), 0xff0000ff);
      expect(await _pixel(whole, 0, 11), 0x0000ffff);
      expect(rasterizer.bandRenders, 1);
      whole.dispose();

      final png = await cache.render(source, const ui.Size(10, 12), 1);
      expect(png.length, greaterThan(8));
      expect(rasterizer.bandRenders, 1);
      cache.clear();
    });
  });

  testWidgets('a banded page paints its bands over the whole layer', (
    tester,
  ) async {
    late PdfPaper paper;
    await tester.runAsync(() async {
      paper = PdfPaper(<ui.Image>[
        await _solid(8, 4, _red),
        await _solid(8, 4, _blue),
      ]);
    });
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 80,
            height: 80,
            child: CustomPaint(painter: PdfPaperPainter(paper)),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter is PdfPaperPainter,
      ),
      findsOneWidget,
    );
    paper.dispose();
  });
}
