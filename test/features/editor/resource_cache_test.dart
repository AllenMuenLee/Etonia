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
import 'package:greatnote/features/editor/document_io/pdf_preview_store.dart';
import 'package:greatnote/shared/memory/note_cache_pool.dart';

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

/// Keeps [calls], a record of what is asked of the PDF, and can read its own outline.
class _OutlineRasterizer extends _DocumentRasterizer
    implements PdfOutlineReader {
  _OutlineRasterizer(this.calls);

  final List<String> calls;

  @override
  Future<OpenPdf> open(Uint8List bytes) async {
    opens++;
    calls.add('open');
    return _OutlineOpenPdf(this);
  }

  @override
  Future<List<PdfOutlineEntry>> readOutline(Uint8List bytes) async {
    calls.add('separate outline');
    return const <PdfOutlineEntry>[
      PdfOutlineEntry(title: 'Separate', pageIndex: 0),
    ];
  }
}

class _OutlineOpenPdf extends _OpenPdf implements OpenPdfOutline {
  _OutlineOpenPdf(_OutlineRasterizer super.pages);

  List<String> get _log => (pages as _OutlineRasterizer).calls;

  @override
  Future<List<PdfOutlineEntry>> readOutline() async {
    _log.add('outline');
    return const <PdfOutlineEntry>[
      PdfOutlineEntry(title: 'Chapter', pageIndex: 0),
    ];
  }

  @override
  Future<ui.Image> renderImage(
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  }) {
    _log.add('render');
    return super.renderImage(
      pageIndex,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    );
  }
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
  group('PDF outlines', () {
    testWidgets('are read from the open PDF, before any of its pages', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final List<String> calls = <String>[];
        final cache = PdfPageRenderCache(
          readAsset: (String _) async => Uint8List(4),
          rasterizer: _OutlineRasterizer(calls),
        );
        cache.warm(_source(0));
        final Future<ui.Image> page = cache.renderImage(
          _source(0),
          const ui.Size(10, 10),
          1,
        );
        final List<PdfOutlineEntry> outline = await cache.outline('pdf');
        (await page).dispose();
        cache.clear();

        expect(outline.single.title, 'Chapter');
        expect(calls.take(3), <String>['open', 'outline', 'render']);
      });
    });

    test('of a PDF not open do not open it for its pages', () async {
      final List<String> log = <String>[];
      final cache = PdfPageRenderCache(
        readAsset: (String _) async => Uint8List(4),
        rasterizer: _OutlineRasterizer(log),
      );
      addTearDown(cache.clear);

      final List<PdfOutlineEntry> outline = await cache.outline('pdf');

      expect(outline.single.title, 'Separate');
      expect(log, <String>['separate outline']);
      // Known from then on, without reading it again.
      await cache.outline('pdf');
      expect(log, <String>['separate outline']);
    });
  });

  testWidgets('PDF pages in view render in preview while the view moves, '
      'then sharp nearest first once it settles', (tester) async {
    await tester.runAsync(() async {
      final rasterizer = _Rasterizer();
      final cache = PdfPageRenderCache(
        readAsset: (_) async => Uint8List(1),
        rasterizer: rasterizer,
        config: const DocumentIoConfig(
          pdfSettleDelay: Duration(milliseconds: 300),
          pdfScrollSettleDelay: Duration(milliseconds: 300),
        ),
      );
      cache.focus([_focus(2), _focus(3), _focus(1)], 1, sharpPages: 3);
      await _until(() => rasterizer.log.length >= 3);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      cache.viewMoved();
      // The original settle deadline passes, but movement postponed sharp
      // rendering until the view has stayed still for a full delay again.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(rasterizer.log, ['2:457', '3:457', '1:457']);
      await _until(() => rasterizer.log.length >= 6);
      expect(rasterizer.log.sublist(3), ['2:1000', '3:1000', '1:1000']);
      cache.clear();
    });
  });

  testWidgets('a scroll slowed to a fraction of its fastest renders sharp '
      'before it stops, and waits again should it speed up', (tester) async {
    await tester.runAsync(() async {
      final rasterizer = _Rasterizer();
      final cache = PdfPageRenderCache(
        readAsset: (_) async => Uint8List(1),
        rasterizer: rasterizer,
        config: const DocumentIoConfig(
          pdfSettleDelay: Duration(seconds: 5),
          pdfScrollSettleDelay: Duration(seconds: 5),
        ),
      );
      cache.scrollSpeed(4000);
      cache.focus([_focus(2), _focus(3)], 1, sharpPages: 2);
      cache.viewMoved();
      await _until(() => rasterizer.log.length >= 2);
      // Still at 40% of its fastest: only previews.
      cache.scrollSpeed(1600);
      cache.viewMoved();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(rasterizer.log, ['2:457', '3:457']);
      // At 30%, sharp renders start while the view still moves.
      cache.scrollSpeed(1200);
      cache.viewMoved();
      await _until(() => rasterizer.log.length >= 4);
      expect(rasterizer.log.sublist(2), ['2:1000', '3:1000']);
      // Sped up again, to another page: sharp renders wait once more.
      cache.scrollSpeed(3000);
      cache.focus([_focus(5), _focus(6)], 1, sharpPages: 2);
      cache.viewMoved();
      await _until(() => rasterizer.log.length >= 6);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(rasterizer.log.sublist(4), ['5:457', '6:457']);
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
        config: const DocumentIoConfig(pdfSourceCacheBytes: 0),
        cacheScope: NoteCachePool(maxBytes: 800).scope(),
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

  testWidgets('PDF diagnostics report cache reuse and bounded queue samples', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final rasterizer = _Rasterizer();
      final cache = PdfPageRenderCache(
        readAsset: (_) async => Uint8List(1),
        rasterizer: rasterizer,
      );
      final first = await cache.renderImage(
        _source(0),
        const ui.Size(20, 20),
        1,
      );
      first.dispose();
      final second = await cache.renderImage(
        _source(0),
        const ui.Size(20, 20),
        1,
      );
      second.dispose();

      final PdfRenderDiagnostics diagnostics = cache.diagnostics;
      expect(diagnostics.requests, 2);
      expect(diagnostics.cacheHits, 1);
      expect(diagnostics.cacheHitRate, 0.5);
      expect(diagnostics.completedJobs, 1);
      expect(diagnostics.peakQueueLength, 1);
      expect(diagnostics.renderLatencyP50Ms, greaterThanOrEqualTo(0));
      cache.clear();
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
          cacheScope: NoteCachePool(maxBytes: 1).scope(),
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
        cacheScope: NoteCachePool(maxBytes: 400).scope(),
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

  testWidgets('open notes share one pool: the note used longest ago gives up '
      'its pages first, each with its PDF paper and its pictures', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final original = await _Rasterizer().renderImage(
        Uint8List(0),
        0,
        pixelWidth: 10,
        pixelHeight: 10,
      );
      final data = (await original.toByteData(format: ui.ImageByteFormat.png))!;
      original.dispose();
      final png = data.buffer.asUint8List();

      // Room for three pages of 400 bytes of paper and one 100 byte picture,
      // with none left over for the bytes read to make them.
      final pool = NoteCachePool(maxBytes: 1300);
      final scope1 = pool.scope();
      final scope2 = pool.scope();
      final rasterizer = _Rasterizer();
      PdfPageRenderCache pdf(NoteCacheScope scope) => PdfPageRenderCache(
        readAsset: (_) async => Uint8List(0),
        rasterizer: rasterizer,
        config: const DocumentIoConfig(pdfSourceCacheBytes: 0),
        cacheScope: scope,
      );
      final note1 = pdf(scope1);
      final note2 = pdf(scope2);
      final pictures = PageImageCache(
        cacheScope: scope2,
        sourceMaxBytes: 0,
        readAsset: (_) async => png,
      );

      Future<void> use(
        PdfPageRenderCache cache,
        NoteCacheScope scope,
        int page,
      ) async {
        scope.touch(_source(page));
        (await cache.renderImage(
          _source(page),
          const ui.Size(10, 10),
          1,
        )).dispose();
      }

      await use(note1, scope1, 4);
      await use(note2, scope2, 5);
      // Kept with note 2's page 5, to go with it.
      (await pictures.image('a', 5, 5, page: _source(5))).dispose();
      await use(note1, scope1, 5);
      expect(note1.entryCount, 2);
      expect(note2.entryCount, 1);
      expect(pictures.retainedBytes, 100);
      expect(pool.usedBytes, 1300);

      await use(note1, scope1, 6);
      await Future<void>.delayed(Duration.zero);
      expect(note2.entryCount, 0, reason: 'note 2 was used longest ago');
      expect(pictures.retainedBytes, 0, reason: 'the whole page goes');
      expect(note1.entryCount, 3, reason: 'note 1 keeps even its oldest page');
      expect(pool.usedBytes, 1200);

      // With note 2 empty, note 1's own oldest page goes.
      await use(note1, scope1, 7);
      await Future<void>.delayed(Duration.zero);
      expect(note1.entryCount, 3);
      final rendersBefore = rasterizer.renders;
      await use(note1, scope1, 5);
      expect(rasterizer.renders, rendersBefore, reason: 'page 5 stayed');
      await use(note1, scope1, 4);
      expect(rasterizer.renders, rendersBefore + 1, reason: 'page 4 went');

      note1.clear();
      note2.clear();
      pictures.clear();
      expect(pool.usedBytes, 0);
    });
  });

  testWidgets('zoomed out, PDF pages render sharp only as big as they are '
      'seen, in tenths', (tester) async {
    await tester.runAsync(() async {
      final rasterizer = _Rasterizer();
      final cache = PdfPageRenderCache(
        readAsset: (_) async => Uint8List(1),
        rasterizer: rasterizer,
        config: const DocumentIoConfig(pdfSettleDelay: Duration.zero),
      );
      cache.showAtZoom(0.7);
      expect(cache.renderScale.value, 0.7);
      cache.focus([_focus(0)], 1, sharpPages: 1);
      await _until(() => rasterizer.log.length >= 2);
      expect(rasterizer.log, ['0:457', '0:700']);
      // A pinch to a little more than that renders at the next tenth...
      cache.showAtZoom(0.73);
      await _until(() => rasterizer.log.length >= 3);
      expect(rasterizer.log.last, '0:800');
      // ...and zoomed in, at the displayed size.
      cache.showAtZoom(2.5);
      await _until(() => rasterizer.log.length >= 4);
      expect(rasterizer.log.last, '0:1000');
      cache.clear();
    });
  });

  testWidgets('deep PDF zoom keeps only the current sharp base page', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final rasterizer = _Rasterizer();
      final cache = PdfPageRenderCache(
        readAsset: (_) async => Uint8List(1),
        rasterizer: rasterizer,
        config: const DocumentIoConfig(
          pdfSettleDelay: Duration.zero,
          // These test pages are small enough not to need previews.
          pdfPreviewDimension: 2000,
        ),
      );
      cache.showAtZoom(0.7);
      cache.focus(
        <PdfFocusPage>[_focus(0), _focus(1), _focus(2)],
        1,
        sharpPages: 3,
      );
      await _until(() => rasterizer.log.length >= 3);
      expect(cache.entryCount, 3);

      cache.showAtZoom(4);
      await _until(() => rasterizer.log.length >= 4);
      expect(rasterizer.log.last, '0:1000');
      expect(cache.entryCount, 1);
      expect(cache.retainedBytes, 1000 * 1400 * 4);
      cache.clear();
    });
  });

  testWidgets('kept previews are shown without rendering, rendered ones are '
      'kept, and the rest of the note is kept ahead once the view settles', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final store = _PreviewStore();
      final rasterizer = _Rasterizer();
      final cache = PdfPageRenderCache(
        readAsset: (_) async => Uint8List(1),
        rasterizer: rasterizer,
        config: const DocumentIoConfig(pdfSettleDelay: Duration.zero),
        previewStore: store,
      );
      // Page 1's preview is kept already, from an earlier visit.
      final kept = await rasterizer.renderImage(
        Uint8List(0),
        1,
        pixelWidth: 457,
        pixelHeight: 640,
      );
      store.kept['pdf-1-640'] = (await kept.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      kept.dispose();
      rasterizer.log.clear();
      // The sharp render takes its time.
      rasterizer.gate = Completer<void>();

      final shown = <String>[];
      final images = <PdfPaper>[];
      final ticket = cache.show(
        _source(1),
        _page,
        1,
        onImage: (image, sharp) {
          shown.add('${image.width}:$sharp');
          images.add(image);
        },
        onError: (_) {},
      );
      await _until(() => shown.isNotEmpty);
      rasterizer.gate!.complete();
      await _until(() => shown.length >= 2);
      expect(shown, ['457:false', '1000:true']);
      // Only the sharp paper was rendered.
      expect(rasterizer.log, ['1:1000']);
      ticket.cancel();

      cache.focus([_focus(0)], 1, sharpPages: 0);
      await _until(() => store.kept.containsKey('pdf-0-640'));
      expect(rasterizer.log.last, '0:457');

      cache.keepPreviews([_source(0), _source(1), _source(2), _source(3)]);
      await _until(() => store.kept.length >= 4);
      expect(store.kept.keys, containsAll(['pdf-2-640', 'pdf-3-640']));
      // Pages 0 and 1 were kept already: not rendered again.
      expect(rasterizer.log.sublist(rasterizer.log.length - 2), [
        '2:640',
        '3:640',
      ]);
      for (final image in images) {
        image.dispose();
      }
      cache.clear();
    });
  });

  testWidgets('the part of a page zoomed in on renders on its own, and a '
      'part no longer wanted does not', (tester) async {
    await tester.runAsync(() async {
      final rasterizer = _RegionRasterizer();
      final cache = PdfPageRenderCache(
        readAsset: (_) async => Uint8List(1),
        rasterizer: rasterizer,
        config: const DocumentIoConfig(pdfSettleDelay: Duration.zero),
      );
      final details = <PdfPaper>[];
      // Another page's preview holds the renderer meanwhile.
      rasterizer.gate = Completer<void>();
      cache.focus([_focus(1)], 1, sharpPages: 0);
      cache
          .showDetail(
            _source(0),
            fullWidth: 4000,
            fullHeight: 5600,
            region: (x: 0, y: 0, width: 10, height: 10),
            onImage: details.add,
          )
          .cancel();
      cache.showDetail(
        _source(0),
        fullWidth: 4000,
        fullHeight: 5600,
        region: (x: 1000, y: 2000, width: 300, height: 200),
        onImage: details.add,
      );
      rasterizer.gate!.complete();
      await _until(() => details.isNotEmpty);
      expect(rasterizer.regions, ['0:1000,2000 300x200 of 4000']);
      expect(details.single.width, 300);
      expect(details.single.height, 200);
      details.single.dispose();
      cache.clear();
    });
  });
}

class _PreviewStore implements PdfPreviewStore {
  final Map<String, Uint8List> kept = {};

  @override
  Future<Uint8List?> read(String key) async => kept[key];

  @override
  Future<bool> contains(String key) async => kept.containsKey(key);

  @override
  Future<void> write(String key, Uint8List encoded) async =>
      kept[key] = encoded;
}

/// Renders parts of pages, as the real rasterizer does.
class _RegionRasterizer extends _DocumentRasterizer {
  final List<String> regions = [];

  @override
  Future<OpenPdf> open(Uint8List bytes) async => _RegionOpenPdf(this);
}

class _RegionOpenPdf extends _OpenPdf implements PdfRegionRenderer {
  _RegionOpenPdf(_RegionRasterizer super.pages);

  @override
  Future<PdfPaper> renderRegion(
    int pageIndex, {
    required int fullWidth,
    required int fullHeight,
    required PdfPixelRegion region,
  }) async {
    (pages as _RegionRasterizer).regions.add(
      '$pageIndex:${region.x},${region.y} '
      '${region.width}x${region.height} of $fullWidth',
    );
    return PdfPaper.single(
      await pages.renderImage(
        Uint8List(0),
        pageIndex,
        pixelWidth: region.width,
        pixelHeight: region.height,
      ),
    );
  }
}
