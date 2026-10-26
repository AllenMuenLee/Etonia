// Scrolling through a long PDF note while its pages render, on a textbook
// and on a scan: frame times, and how long the UI isolate is kept from
// running at all (gaps between ticks of a 1 ms timer).
//
//   flutter build apk --profile --target=integration_test/pdf_scroll_performance_test.dart
//   adb install -r -t build/app/outputs/flutter-apk/app-profile.apk
//   adb shell am start -n com.etonia.app/.MainActivity
//   adb logcat -s flutter | grep PDF_SCROLL
//
// The result is printed as one `PDF_SCROLL_RESULT` line of JSON.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/document_io/document_models.dart';
import 'package:greatnote/features/editor/document_io/document_platform.dart';
import 'package:greatnote/features/editor/document_io/pdf_paper.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/page/page_viewport.dart';
import 'package:greatnote/features/library/file_note_repository.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_editor_page.dart';
import 'package:greatnote/features/library/note_tabs_page.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/open_notes.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

const int _pages = 24;

/// The note to copy for the user-note scenario, in the app's library.
const String _userLibrary = '/data/data/com.etonia.app/app_flutter/greatnote';
const String _userNote = 'hng7fg8pv312ssspu';

/// The real rasterizer, timing each page it renders.
class _TimedRasterizer
    implements PdfRasterizer, PdfImageRasterizer, PdfDocumentRasterizer {
  _TimedRasterizer();

  final PdfrxRasterizer _inner = const PdfrxRasterizer();
  final List<double> renderMs = <double>[];
  final List<int> renderPixels = <int>[];

  void reset() {
    renderMs.clear();
    renderPixels.clear();
  }

  @override
  Future<OpenPdf> open(Uint8List bytes) async =>
      _TimedOpenPdf(this, await _inner.open(bytes));

  @override
  Future<PdfInspection> inspect(Uint8List bytes) => _inner.inspect(bytes);

  @override
  Future<RasterizedPdfPage> render(
    Uint8List bytes,
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  }) => _inner.render(
    bytes,
    pageIndex,
    pixelWidth: pixelWidth,
    pixelHeight: pixelHeight,
  );

  @override
  Future<ui.Image> renderImage(
    Uint8List bytes,
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  }) => _inner.renderImage(
    bytes,
    pageIndex,
    pixelWidth: pixelWidth,
    pixelHeight: pixelHeight,
  );
}

class _TimedOpenPdf implements OpenPdf, PdfBandRenderer {
  _TimedOpenPdf(this._owner, this._inner);

  final _TimedRasterizer _owner;
  final OpenPdf _inner;

  @override
  Future<PdfPaper> renderPaper(
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  }) async {
    final clock = Stopwatch()..start();
    final paper = await (_inner as PdfBandRenderer).renderPaper(
      pageIndex,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    );
    _owner.renderMs.add(clock.elapsedMicroseconds / 1000);
    _owner.renderPixels.add(pixelWidth * pixelHeight);
    return paper;
  }

  @override
  Future<ui.Image> renderImage(
    int pageIndex, {
    required int pixelWidth,
    required int pixelHeight,
  }) async {
    final clock = Stopwatch()..start();
    final image = await _inner.renderImage(
      pageIndex,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    );
    _owner.renderMs.add(clock.elapsedMicroseconds / 1000);
    _owner.renderPixels.add(pixelWidth * pixelHeight);
    return image;
  }

  @override
  Future<void> dispose() => _inner.dispose();
}

/// Longest gaps between ticks of a 1 ms timer: how long the UI isolate was
/// unable to run anything else.
class _StallMonitor {
  final List<double> gaps = <double>[];
  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  int _last = 0;

  void start() {
    gaps.clear();
    _clock.start();
    _last = _clock.elapsedMicroseconds;
    _timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      final now = _clock.elapsedMicroseconds;
      gaps.add((now - _last) / 1000);
      _last = now;
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}

/// Scanned pages: one full-page picture each, as a 200 dpi scan has.
Future<Uint8List> _scanPdf() async {
  const width = 1654;
  const height = 2339;
  final pdf = pw.Document();
  for (var page = 0; page < _pages; page++) {
    final pixels = Uint8List(width * height * 4);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = (y * width + x) * 4;
        // Paper grain and lines of "text".
        final line = (y ~/ 38 + page) % 3 == 0 && (y % 38) < 22 ? 1 : 0;
        final grain = (x * 31 + y * 17 + page * 7) & 15;
        final v = line == 1 && (x ~/ 11) % 5 != 0 ? 40 + grain : 236 + grain;
        pixels[i] = v;
        pixels[i + 1] = v;
        pixels[i + 2] = v;
        pixels[i + 3] = 255;
      }
    }
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.FullPage(
          ignoreMargins: true,
          child: pw.Image(
            pw.RawImage(bytes: pixels, width: width, height: height),
            fit: pw.BoxFit.fill,
          ),
        ),
      ),
    );
  }
  return pdf.save();
}

/// A textbook: a figure, a table and a few paragraphs on every page.
Future<Uint8List> _textbookPdf() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 1240, 900),
    Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        const Offset(1240, 900),
        const [Color(0xFF2E5AAC), Color(0xFFE8A33D), Color(0xFF2F8F6B)],
        const [0, 0.5, 1],
      ),
  );
  for (var i = 0; i < 80; i++) {
    canvas.drawCircle(
      Offset(60.0 + (i * 97) % 1100, 40.0 + (i * 53) % 800),
      14.0 + i % 40,
      Paint()..color = Color(0x33000000 | (i * 2654435761 & 0xFFFFFF)),
    );
  }
  final figure = await recorder.endRecording().toImage(1240, 900);
  final figureBytes = (await figure.toByteData(
    format: ui.ImageByteFormat.png,
  ))!.buffer.asUint8List();
  figure.dispose();
  final image = pw.MemoryImage(figureBytes);
  const paragraph =
      'The derivative of a function measures how its output changes as its '
      'input changes. Where the slope is zero the function is momentarily '
      'flat, which is why maxima and minima are found by setting the '
      'derivative to zero and solving. ';
  final pdf = pw.Document();
  for (var page = 0; page < _pages; page++) {
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              'Chapter ${page + 1}',
              style: const pw.TextStyle(
                fontSize: 26,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 10),
            pw.Text(paragraph * 3),
            pw.SizedBox(height: 10),
            pw.Image(image, height: 220),
            pw.SizedBox(height: 10),
            pw.TableHelper.fromTextArray(
              data: [
                for (var row = 0; row < 8; row++)
                  [for (var col = 0; col < 5; col++) '${row * col + page}'],
              ],
            ),
            pw.SizedBox(height: 10),
            pw.Text(paragraph * 4),
          ],
        ),
      ),
    );
  }
  return pdf.save();
}

double _pct(List<double> v, double q) {
  if (v.isEmpty) return 0;
  final sorted = [...v]..sort();
  return sorted[((sorted.length - 1) * q).round()];
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  /// A generated note of [_pages] pages of [makePdf].
  Future<NoteEntry> generatedNote(
    FileNoteRepository repository,
    Directory directory,
    String label,
    Future<Uint8List> Function() makePdf,
  ) async {
    final pdfBytes = await makePdf();
    final note = await repository.createNote(title: 'PDF scroll $label');
    final noteAsset = await repository.storeAsset(
      note.id,
      pdfBytes,
      kind: NoteAssetKind.pdf,
      extension: 'pdf',
    );
    await repository.saveNote(
      note.id,
      NoteContent([
        for (var page = 0; page < _pages; page++)
          StoredPage(
            setup: const PageSetup(size: PageSize.a4Portrait),
            pdfSource: PdfPageSource(
              assetId: noteAsset,
              pageIndex: page,
              pageSize: const Size(794, 1123),
            ),
            strokes: const [],
          ),
      ]),
    );
    return note;
  }

  /// A copy of a note from the app's own library: the note file and its
  /// assets, copied so the original is only ever read.
  Future<NoteEntry> copiedNote(
    FileNoteRepository repository,
    Directory directory,
    String label,
    Future<Uint8List> Function() unused,
  ) async {
    final source = Directory(_userLibrary);
    final index = File('${source.path}/library.json');
    await File(
      '${directory.path}/library.json',
    ).writeAsBytes(await index.readAsBytes());
    for (final name in ['$_userNote.json']) {
      await File(
        '${directory.path}/notes/$name',
      ).writeAsBytes(await File('${source.path}/notes/$name').readAsBytes());
    }
    final assets = Directory('${directory.path}/notes/$_userNote.assets');
    await assets.create(recursive: true);
    await for (final entity in Directory(
      '${source.path}/notes/$_userNote.assets',
    ).list()) {
      if (entity is File) {
        await File(
          '${assets.path}/${entity.uri.pathSegments.last}',
        ).writeAsBytes(await entity.readAsBytes());
      }
    }
    final reopened = await FileNoteRepository.open(directory);
    final notes = await reopened.allNotes();
    return notes.firstWhere((note) => note.id == _userNote);
  }

  Future<void> scenario(
    WidgetTester tester,
    String label,
    Future<NoteEntry> Function(
      FileNoteRepository,
      Directory,
      String,
      Future<Uint8List> Function(),
    )
    prepare, [
    Future<Uint8List> Function()? makePdf,
  ]) async {
    final directory = await Directory.systemTemp.createTemp('greatnote-pdf-');
    final tabs = OpenNotes();
    final rasterizer = _TimedRasterizer();
    final monitor = _StallMonitor();

    final FileNoteRepository repository;
    final NoteEntry note;
    if (label == 'user_note') {
      await Directory('${directory.path}/notes').create(recursive: true);
      note = await prepare(
        await FileNoteRepository.open(directory),
        directory,
        label,
        makePdf ?? _scanPdf,
      );
      repository = await FileNoteRepository.open(directory);
    } else {
      repository = await FileNoteRepository.open(directory);
      note = await prepare(repository, directory, label, makePdf ?? _scanPdf);
    }

    tabs.open(note);
    await tester.pumpWidget(
      GreatnoteApp(
        home: NoteTabsPage(
          notes: tabs,
          builder: (note, bar, back, rename) => NoteEditorPage(
            repository: repository,
            note: note,
            tabsBuilder: bar,
            onBack: back,
            onRenamed: rename,
            pdfRasterizer: rasterizer,
          ),
        ),
      ),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (find.byType(RawImage).evaluate().isEmpty) {
      if (DateTime.now().isAfter(deadline)) throw StateError('no PDF page');
      await tester.pump(const Duration(milliseconds: 16));
    }

    final viewport = tester.state<PageViewportState>(find.byType(PageViewport));
    final budgetMs = 1000 / tester.view.display.refreshRate;

    Future<void> scroll(
      String name, {
      required double pxPerSecond,
      required double seconds,
      double pauseEverySeconds = 0,
      double pauseSeconds = 0,
    }) async {
      final frames = <FrameTiming>[];
      void record(List<FrameTiming> batch) => frames.addAll(batch);
      SchedulerBinding.instance.addTimingsCallback(record);
      rasterizer.reset();
      monitor.start();
      final clock = Stopwatch()..start();
      var last = clock.elapsedMicroseconds;
      var sincePause = 0.0;
      final startOffset = viewport.scrollOffset.dy;
      while (clock.elapsedMicroseconds < seconds * 1e6) {
        await tester.pump();
        final now = clock.elapsedMicroseconds;
        final dt = (now - last) / 1e6;
        last = now;
        viewport.scrollBy(Offset(0, pxPerSecond * dt));
        sincePause += dt;
        if (pauseEverySeconds > 0 && sincePause >= pauseEverySeconds) {
          sincePause = 0;
          final until = clock.elapsedMicroseconds + pauseSeconds * 1e6;
          while (clock.elapsedMicroseconds < until) {
            await tester.pump(const Duration(milliseconds: 8));
          }
          last = clock.elapsedMicroseconds;
        }
      }
      await tester.pump(const Duration(milliseconds: 800));
      monitor.stop();
      SchedulerBinding.instance.removeTimingsCallback(record);

      final build = [
        for (final f in frames) f.buildDuration.inMicroseconds / 1000,
      ];
      final raster = [
        for (final f in frames) f.rasterDuration.inMicroseconds / 1000,
      ];
      final result = <String, Object?>{
        'pdf': label,
        'name': name,
        'scrolled_px': (viewport.scrollOffset.dy - startOffset).round(),
        'frames': frames.length,
        'budget_ms': budgetMs.toStringAsFixed(1),
        'build_p95': _pct(build, .95),
        'build_max': _pct(build, 1),
        'raster_p50': _pct(raster, .5),
        'raster_p95': _pct(raster, .95),
        'raster_p99': _pct(raster, .99),
        'raster_max': _pct(raster, 1),
        'jank_over_budget': frames
            .where(
              (f) =>
                  f.buildDuration.inMicroseconds / 1000 > budgetMs ||
                  f.rasterDuration.inMicroseconds / 1000 > budgetMs,
            )
            .length,
        'jank_over_2x': frames
            .where(
              (f) =>
                  f.buildDuration.inMicroseconds / 1000 > 2 * budgetMs ||
                  f.rasterDuration.inMicroseconds / 1000 > 2 * budgetMs,
            )
            .length,
        // UI-isolate stalls, in ms between ticks of a 1 ms timer.
        'stall_gaps_over_20ms': monitor.gaps.where((g) => g > 20).length,
        'stall_gap_p99': _pct(monitor.gaps, .99),
        'stall_gap_max': _pct(monitor.gaps, 1),
        'renders': rasterizer.renderMs.length,
        'render_ms_mean': rasterizer.renderMs.isEmpty
            ? 0
            : rasterizer.renderMs.reduce((a, b) => a + b) /
                  rasterizer.renderMs.length,
        'render_ms_max': _pct(rasterizer.renderMs, 1),
        'render_mpx_max': rasterizer.renderPixels.isEmpty
            ? 0
            : rasterizer.renderPixels.reduce(math.max) / 1e6,
        'rss_mb': (ProcessInfo.currentRss / (1024 * 1024)).round(),
      };
      debugPrint('PDF_SCROLL_RESULT ${jsonEncode(result)}');
    }

    // From the first page on screen, while the rest is still loading.
    await scroll('cold_drag_down', pxPerSecond: 900, seconds: 5);
    await tester.pump(const Duration(seconds: 3));
    await scroll('back_to_top', pxPerSecond: -3000, seconds: 4);
    await tester.pump(const Duration(seconds: 2));
    await scroll('drag_down', pxPerSecond: 900, seconds: 6);
    await scroll('flick_down', pxPerSecond: 3200, seconds: 3);
    await scroll(
      'read_with_pauses',
      pxPerSecond: 500,
      seconds: 6,
      pauseEverySeconds: 1.5,
      pauseSeconds: 0.5,
    );
    await scroll('drag_up', pxPerSecond: -1200, seconds: 8);

    await tester.pumpWidget(const SizedBox());
    await Future<void>.delayed(const Duration(milliseconds: 300));
    repository.dispose();
    tabs.dispose();
    await directory.delete(recursive: true);
  }

  testWidgets('scrolling the 24 page note from the app library', (
    tester,
  ) async {
    await scenario(tester, 'user_note', copiedNote);
  });
  if (!const bool.fromEnvironment('USER_NOTE_ONLY')) {
    testWidgets('scrolling a $_pages page textbook PDF', (tester) async {
      await scenario(tester, 'textbook', generatedNote, _textbookPdf);
    });
    testWidgets('scrolling a $_pages page scanned PDF', (tester) async {
      await scenario(tester, 'scan', generatedNote, _scanPdf);
    });
  }
}
