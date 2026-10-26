import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/document_io/asset_byte_cache.dart';
import 'package:greatnote/features/editor/document_io/document_io_config.dart';
import 'package:greatnote/features/editor/document_io/document_models.dart';
import 'package:greatnote/features/editor/document_io/document_platform.dart';
import 'package:greatnote/features/editor/document_io/page_image_cache.dart';
import 'package:greatnote/features/editor/document_io/pdf_page_layer.dart';
import 'package:greatnote/features/editor/document_io/pdf_paper.dart';

class _Rasterizer implements PdfRasterizer, PdfImageRasterizer {
  int renders = 0;
  bool fail = false;
  Completer<void>? gate;
  final List<ui.Image> owned = [];

  /// `<page>:<width>` for each render, in the order they started.
  final List<String> log = [];

  @override
  Future<PdfInspection> inspect(Uint8List bytes) async =>
      const PdfInspection(pageSizes: [ui.Size(10, 10)]);

  @override
  Future<RasterizedPdfPage> render(
    Uint8List bytes,
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  }) => throw UnimplementedError();

  @override
  Future<ui.Image> renderImage(
    Uint8List bytes,
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  }) async {
    renders++;
    log.add('$pageIndex:$pixelWidth');
    await gate?.future;
    if (fail) throw StateError('render failed');
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xffabcdef), ui.BlendMode.src);
    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(pixelWidth, pixelHeight);
      owned.add(image);
      return image;
    } finally {
      picture.dispose();
    }
  }
}

PdfPageSource _source(int page) => PdfPageSource(
  assetId: 'pdf',
  pageIndex: page,
  pageSize: const ui.Size(10, 10),
);

/// Opens each PDF once and renders its pages through [pages].
class _DocumentRasterizer extends _Rasterizer implements PdfDocumentRasterizer {
  int opens = 0;
  int disposals = 0;

  @override
  Future<OpenPdf> open(Uint8List bytes) async {
    opens++;
    return _OpenPdf(this);
  }
}

class _OpenPdf implements OpenPdf {
  _OpenPdf(this.pages);

  final _DocumentRasterizer pages;

  @override
  Future<ui.Image> renderImage(
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  }) => pages.renderImage(
    Uint8List(0),
    pageIndex,
    pixelWidth: pixelWidth,
    pixelHeight: pixelHeight,
  );

  @override
  Future<void> dispose() async => pages.disposals++;
}

/// Large enough to be shown from a preview first.
const ui.Size _page = ui.Size(1000, 1400);

PdfFocusPage _focus(int page) => (source: _source(page), displayedSize: _page);

Future<void> _until(bool Function() done) async {
  for (int i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  testWidgets('PDF pages in view render in preview while the view moves, '
      'then sharp nearest first once it settles', (tester) async {
    await tester.runAsync(() async {
      final rasterizer = _Rasterizer();
      final cache = PdfPageRenderCache(
        readAsset: (_) async => Uint8List(1),
        rasterizer: rasterizer,
        config: const DocumentIoConfig(
          pdfSettleDelay: Duration(milliseconds: 300),
        ),
      );
      cache.focus([_focus(2), _focus(3), _focus(1)], 1, sharpPages: 3);
      await _until(() => rasterizer.log.length >= 3);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(rasterizer.log, ['2:457', '3:457', '1:457']);
      await _until(() => rasterizer.log.length >= 6);
      expect(rasterizer.log.sublist(3), ['2:1000', '3:1000', '1:1000']);
      cache.clear();
    });
  });

  testWidgets('a shown PDF page gets its preview, then its sharp paper, and '
      'a page cancelled before its turn is never rendered', (tester) async {
    await tester.runAsync(() async {
      final rasterizer = _Rasterizer()..gate = Completer<void>();
      final cache = PdfPageRenderCache(
        readAsset: (_) async => Uint8List(1),
        rasterizer: rasterizer,
      );
      final shown = <String>[];
      final images = <PdfPaper>[];
      cache.show(
        _source(0),
        _page,
        1,
        onImage: (image, sharp) {
          shown.add('${image.width}:$sharp');
          images.add(image);
        },
        onError: (_) {},
      );
      cache
          .show(
            _source(7),
            _page,
            1,
            onImage: (image, _) => image.dispose(),
            onError: (_) {},
          )
          .cancel();
      rasterizer.gate!.complete();
      await _until(() => shown.length >= 2);
      expect(shown, ['457:false', '1000:true']);
      expect(rasterizer.log, ['0:457', '0:1000']);
      for (final image in images) {
        image.dispose();
      }
      cache.clear();
    });
  });

  testWidgets('a PDF is opened once for all its pages and closed on clear', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final rasterizer = _DocumentRasterizer();
      final cache = PdfPageRenderCache(
        readAsset: (_) async => Uint8List(1),
        rasterizer: rasterizer,
      );
      for (int page = 0; page < 3; page++) {
        (await cache.renderImage(
          _source(page),
          const ui.Size(10, 10),
          1,
        )).dispose();
      }
      expect(rasterizer.opens, 1);
      expect(rasterizer.renders, 3);
      cache.clear();
      await Future<void>.delayed(Duration.zero);
      expect(rasterizer.disposals, 1);
    });
  });

  testWidgets('low memory releases finished PDF renders and open PDFs, '
      'leaving pages already shown intact', (tester) async {
    await tester.runAsync(() async {
      final rasterizer = _DocumentRasterizer();
      final cache = PdfPageRenderCache(
        readAsset: (_) async => Uint8List(1),
        rasterizer: rasterizer,
      );
      final shown = await cache.renderImage(
        _source(0),
        const ui.Size(10, 10),
        1,
      );
      (await cache.renderImage(_source(1), const ui.Size(10, 10), 1)).dispose();
      expect(cache.entryCount, 2);
      expect(cache.retainedBytes, greaterThan(0));

      cache.releaseMemory();
      await Future<void>.delayed(Duration.zero);
      expect(cache.entryCount, 0);
      expect(cache.retainedBytes, 0);
      expect(cache.sourceBytes, 0);
      expect(rasterizer.disposals, 1);
      // What was handed out is the holder's own.
      expect(shown.debugDisposed, isFalse);
      expect(shown.width, 10);

      // Shown again, the page is rendered again.
      (await cache.renderImage(_source(0), const ui.Size(10, 10), 1)).dispose();
      expect(rasterizer.opens, 2);
      shown.dispose();
      cache.clear();
    });
  });

  testWidgets('low memory releases decoded page images but not clones', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final rasterizer = _Rasterizer();
      final original = await rasterizer.renderImage(
        Uint8List(0),
        0,
        pixelWidth: 10,
        pixelHeight: 10,
      );
      final data = (await original.toByteData(format: ui.ImageByteFormat.png))!;
      original.dispose();
      final png = data.buffer.asUint8List();
      var reads = 0;
      final cache = PageImageCache(
        readAsset: (_) async {
          reads++;
          return png;
        },
      );
      final image = await cache.image('a', 10, 10);
      expect(cache.retainedBytes, 400);
      expect(cache.sourceBytes, png.length);

      cache.releaseMemory();
      expect(cache.retainedBytes, 0);
      expect(cache.sourceBytes, 0);
      expect(image.debugDisposed, isFalse);
      image.dispose();

      (await cache.image('a', 10, 10)).dispose();
      expect(reads, 2);
      cache.clear();
    });
  });

  test(
    'asset LRU is byte bounded, coalesces, and clears stale results',
    () async {
      final reads = <String>[];
      final gate = Completer<Uint8List?>();
      final cache = AssetByteCache(
        maxBytes: 8,
        read: (id) async {
          reads.add(id);
          return id == 'pending' ? gate.future : Uint8List(4);
        },
      );
      await cache.load('a');
      await cache.load('b');
      await cache.load('a');
      await cache.load('c');
      expect(cache.retainedBytes, 8);
      await cache.load('b');
      expect(reads, ['a', 'b', 'c', 'b']);
      final pending = cache.load('pending');
      expect(cache.load('pending'), same(pending));
      cache.clear();
      gate.complete(Uint8List(4));
      await pending;
      expect(cache.retainedBytes, 0);
    },
  );

  testWidgets('PDF byte LRU disposes owners but borrowed clones remain valid', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final rasterizer = _Rasterizer();
      final cache = PdfPageRenderCache(
        readAsset: (_) async => Uint8List(5),
        rasterizer: rasterizer,
        config: const DocumentIoConfig(pdfRenderCacheBytes: 800),
      );
      final a = await cache.renderImage(_source(0), const ui.Size(10, 10), 1);
      final b = await cache.renderImage(_source(1), const ui.Size(10, 10), 1);
      (await cache.renderImage(_source(0), const ui.Size(10, 10), 1)).dispose();
      final c = await cache.renderImage(_source(2), const ui.Size(10, 10), 1);
      await Future<void>.delayed(Duration.zero);
      expect(cache.retainedBytes, 800);
      expect(rasterizer.owned[1].debugDisposed, isTrue);
      expect(rasterizer.owned[0].debugDisposed, isFalse);
      expect(await b.toByteData(), isNotNull);
      cache.clear();
      await Future<void>.delayed(Duration.zero);
      expect(rasterizer.owned.every((image) => image.debugDisposed), isTrue);
      expect(cache.sourceBytes, 0);
      a.dispose();
      b.dispose();
      c.dispose();
    });
  });

  testWidgets(
    'PDF eviction during render and PNG encoding keeps borrows alive',
    (tester) async {
      await tester.runAsync(() async {
        final rasterizer = _Rasterizer()..gate = Completer<void>();
        final cache = PdfPageRenderCache(
          readAsset: (_) async => Uint8List(1),
          rasterizer: rasterizer,
          config: const DocumentIoConfig(pdfRenderCacheBytes: 1),
        );
        final first = cache.renderImage(_source(0), const ui.Size(20, 20), 1);
        final second = cache.renderImage(_source(0), const ui.Size(20, 20), 1);
        final png = cache.render(_source(0), const ui.Size(20, 20), 1);
        await Future<void>.delayed(Duration.zero);
        expect(rasterizer.renders, 1);
        cache.clear();
        rasterizer.gate!.complete();
        final images = await Future.wait([first, second]);
        expect(await png, isNotEmpty);
        for (final image in images) {
          expect(await image.toByteData(), isNotNull);
          image.dispose();
        }
        await Future<void>.delayed(Duration.zero);
        expect(rasterizer.owned.single.debugDisposed, isTrue);
        expect(cache.retainedBytes, 0);
      });
    },
  );

  testWidgets(
    'failed PDF renders retry and old failures cannot remove new entries',
    (tester) async {
      await tester.runAsync(() async {
        final rasterizer = _Rasterizer()..fail = true;
        final cache = PdfPageRenderCache(
          readAsset: (_) async => Uint8List(1),
          rasterizer: rasterizer,
        );
        await expectLater(
          cache.renderImage(_source(0), const ui.Size(10, 10), 1),
          throwsStateError,
        );
        rasterizer.fail = false;
        final image = await cache.renderImage(
          _source(0),
          const ui.Size(10, 10),
          1,
        );
        expect(rasterizer.renders, 2);
        image.dispose();
        cache.clear();
      });
    },
  );

  testWidgets('page images coalesce decodes and retain only budgeted pixels', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final rasterizer = _Rasterizer();
      final original = await rasterizer.renderImage(
        Uint8List(0),
        0,
        pixelWidth: 10,
        pixelHeight: 10,
      );
      final data = (await original.toByteData(format: ui.ImageByteFormat.png))!;
      original.dispose();
      final png = data.buffer.asUint8List();
      var reads = 0;
      final gate = Completer<Uint8List?>();
      final cache = PageImageCache(
        maxBytes: 400,
        sourceMaxBytes: 0,
        readAsset: (_) {
          reads++;
          return gate.future;
        },
      );
      final first = cache.image('a', 10, 10);
      final duplicate = cache.image('a', 10, 10);
      cache.clear();
      gate.complete(png);
      final a = await first;
      final b = await duplicate;
      expect(reads, 1);
      expect(a.isCloneOf(b), isTrue);
      expect(cache.retainedBytes, 0);
      expect(cache.sourceBytes, 0);
      a.dispose();
      b.dispose();
      final c = await cache.image('c', 10, 10);
      final d = await cache.image('d', 20, 20);
      expect(cache.retainedBytes, 0);
      expect(await c.toByteData(), isNotNull);
      expect(await d.toByteData(), isNotNull);
      c.dispose();
      d.dispose();
      cache.clear();
    });
  });
}
