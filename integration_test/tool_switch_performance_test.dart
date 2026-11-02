// Switching tools on a PDF note with handwriting, at the opening zoom and
// zoomed all the way in: frame times, and how long the UI isolate is kept
// from running at all (gaps between ticks of a 1 ms timer).
//
//   flutter build apk --profile --target=integration_test/tool_switch_performance_test.dart
//   adb install -r -t build/app/outputs/flutter-apk/app-profile.apk
//   adb shell am start -n com.etonia.app/.MainActivity
//   adb logcat -s flutter | grep TOOL_SWITCH
//
// Each scenario prints one `TOOL_SWITCH_RESULT` line of JSON.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/document_io/document_models.dart';
import 'package:greatnote/features/editor/document_io/pdf_preview_store.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/page/page_viewport.dart';
import 'package:greatnote/features/editor/widgets/tool_palette.dart';
import 'package:greatnote/features/library/file_note_repository.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_editor_page.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/note_tabs_page.dart';
import 'package:greatnote/features/library/open_notes.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

const int _pages = 6;

/// A note from the app's own library to measure instead of the generated
/// one: `--dart-define=USER_NOTE=<id>`, or `latest` for the one last saved.
/// It is copied, so the original is only ever read.
const String _userNote = String.fromEnvironment('USER_NOTE');
const String _userLibrary = '/data/data/com.etonia.app/app_flutter/greatnote';

Future<NoteEntry> _copyUserNote(Directory directory, String id) async {
  final source = Directory('$_userLibrary/notes');
  if (id == 'latest') {
    final files = [
      for (final entity in source.listSync())
        if (entity is File && entity.path.endsWith('.json')) entity,
    ]..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    id = files.first.uri.pathSegments.last.replaceAll('.json', '');
  }
  await Directory('${directory.path}/notes/$id.assets').create(recursive: true);
  await File(
    '${directory.path}/library.json',
  ).writeAsBytes(await File('$_userLibrary/library.json').readAsBytes());
  await File(
    '${directory.path}/notes/$id.json',
  ).writeAsBytes(await File('${source.path}/$id.json').readAsBytes());
  final assets = Directory('${source.path}/$id.assets');
  if (assets.existsSync()) {
    await for (final entity in assets.list()) {
      if (entity is File) {
        await File(
          '${directory.path}/notes/$id.assets/${entity.uri.pathSegments.last}',
        ).writeAsBytes(await entity.readAsBytes());
      }
    }
  }
  final notes = await (await FileNoteRepository.open(directory)).allNotes();
  return notes.firstWhere((note) => note.id == id);
}

double _pct(List<double> v, double q) {
  if (v.isEmpty) return 0;
  final sorted = [...v]..sort();
  return sorted[((sorted.length - 1) * q).round()];
}

/// Handwriting: lines of wavy words down the page.
List<Stroke> _handwriting(int page) => [
  for (var line = 0; line < 30; line++)
    for (var word = 0; word < 6; word++)
      Stroke.fromPoints(
        style: StrokeStyle(
          ink: word.isEven ? InkPalette.ink : InkPalette.blue,
          width: 2.5,
        ),
        points: [
          for (var point = 0; point < 36; point++)
            InkVector(
              40 + word * 120 + point * 2.8,
              60 + line * 34 + 7 * math.sin(point / 1.7 + line + page),
            ),
        ],
      ),
];

Future<Uint8List> _textbookPdf() async {
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
            pw.Text(paragraph * 6),
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

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('switching tools at the opening zoom and zoomed in', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp('greatnote-tool-');
    final tabs = OpenNotes();
    final FileNoteRepository repository;
    final NoteEntry note;
    if (_userNote.isNotEmpty) {
      note = await _copyUserNote(directory, _userNote);
      repository = await FileNoteRepository.open(directory);
    } else {
      repository = await FileNoteRepository.open(directory);
      note = await repository.createNote(title: 'Tool switch');
      final pdfId = await repository.storeAsset(
        note.id,
        await _textbookPdf(),
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
                assetId: pdfId,
                pageIndex: page,
                pageSize: const Size(794, 1123),
              ),
              strokes: _handwriting(page),
            ),
        ]),
      );
    }
    debugPrint('TOOL_SWITCH_NOTE ${note.id} ${note.title}');

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
            pdfPreviewStore: FilePdfPreviewStore(
              Future<Directory>.value(Directory('${directory.path}/previews')),
            ),
          ),
        ),
      ),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (find.byType(ToolPalette).evaluate().isEmpty) {
      if (DateTime.now().isAfter(deadline)) throw StateError('no page');
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(seconds: 6));

    final viewport = tester.state<PageViewportState>(find.byType(PageViewport));
    final ValueNotifier<EditorTool> tool = tester
        .widget<ToolPalette>(find.byType(ToolPalette))
        .tool;
    final monitor = _StallMonitor();
    final budgetMs = 1000 / tester.view.display.refreshRate;

    Future<void> pumpFor(Duration duration) async {
      final clock = Stopwatch()..start();
      while (clock.elapsed < duration) {
        await tester.pump();
      }
    }

    Future<void> switching(String name) async {
      final frames = <FrameTiming>[];
      void record(List<FrameTiming> batch) => frames.addAll(batch);
      SchedulerBinding.instance.addTimingsCallback(record);
      monitor.start();
      final switchMs = <double>[];
      const cycle = <EditorTool>[
        EditorTool.eraser,
        EditorTool.select,
        EditorTool.pen,
      ];
      for (var round = 0; round < 4; round++) {
        for (final EditorTool next in cycle) {
          final clock = Stopwatch()..start();
          // Idle: the same frames, with no tool chosen.
          debugPrint('TSDBG switch $name $next');
          if (!name.contains('idle')) tool.value = next;
          switchMs.add(clock.elapsedMicroseconds / 1000);
          await pumpFor(const Duration(milliseconds: 450));
        }
      }
      await pumpFor(const Duration(milliseconds: 500));
      monitor.stop();
      SchedulerBinding.instance.removeTimingsCallback(record);
      final build = [
        for (final f in frames) f.buildDuration.inMicroseconds / 1000,
      ];
      final raster = [
        for (final f in frames) f.rasterDuration.inMicroseconds / 1000,
      ];
      debugPrint(
        'TOOL_SWITCH_RESULT ${jsonEncode(<String, Object?>{'name': name, 'zoom': viewport.zoom, 'budget_ms': budgetMs.toStringAsFixed(1), 'frames': frames.length, 'switch_sync_ms_max': _pct(switchMs, 1), 'switch_sync_ms_p50': _pct(switchMs, .5), 'build_p50': _pct(build, .5), 'build_p95': _pct(build, .95), 'build_max': _pct(build, 1), 'raster_p50': _pct(raster, .5), 'raster_p95': _pct(raster, .95), 'raster_max': _pct(raster, 1), 'over_8ms': frames.where((f) => f.buildDuration.inMicroseconds > 8333 || f.rasterDuration.inMicroseconds > 8333).length, 'over_16ms': frames.where((f) => f.buildDuration.inMicroseconds > 16667 || f.rasterDuration.inMicroseconds > 16667).length, 'stall_gaps_over_20ms': monitor.gaps.where((g) => g > 20).length, 'stall_gap_max': _pct(monitor.gaps, 1)})}',
      );
    }

    Future<void> zoomTo(
      double factor, {
      Duration settle = const Duration(seconds: 4),
    }) async {
      final Offset center = tester.getCenter(find.byType(PageViewport));
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      await gesture.panZoomStart(center);
      await tester.pump();
      for (var step = 1; step <= 10; step++) {
        await gesture.panZoomUpdate(
          center,
          scale: math.pow(factor, step / 10).toDouble(),
        );
        await tester.pump();
      }
      await gesture.panZoomEnd();
      // Give sharp PDF renders time to settle when the caller wants a
      // steady-state measurement. The immediate-after-pinch scenario leaves
      // this at zero to catch rendering that overlaps a tool transition.
      await pumpFor(settle);
    }

    /// The longest events on each thread of the timeline traced as
    /// [reportKey], summed by name.
    void summarizeTimeline(String reportKey) {
      final Map<String, Object?> timeline =
          binding.reportData![reportKey]! as Map<String, Object?>;
      final List<Object?> events = timeline['traceEvents']! as List<Object?>;
      final Map<String, String> threadNames = <String, String>{};
      final Map<String, List<Map<String, Object?>>> open =
          <String, List<Map<String, Object?>>>{};
      final Map<String, List<double>> durations = <String, List<double>>{};
      for (final Object? raw in events) {
        final Map<String, Object?> event = raw! as Map<String, Object?>;
        final String tid = '${event['tid']}';
        if (event['ph'] == 'M' && event['name'] == 'thread_name') {
          threadNames[tid] =
              '${(event['args']! as Map<String, Object?>)['name']}';
          continue;
        }
        void add(String name, double ms) =>
            durations.putIfAbsent('$tid|$name', () => <double>[]).add(ms);
        switch (event['ph']) {
          case 'X':
            add('${event['name']}', ((event['dur'] as num?) ?? 0) / 1000);
          case 'B':
            open.putIfAbsent(tid, () => <Map<String, Object?>>[]).add(event);
          case 'E':
            final List<Map<String, Object?>>? stack = open[tid];
            if (stack == null || stack.isEmpty) break;
            final Map<String, Object?> begin = stack.removeLast();
            add(
              '${begin['name']}',
              ((event['ts']! as num) - (begin['ts']! as num)) / 1000,
            );
        }
      }
      final List<MapEntry<String, List<double>>> slow =
          durations.entries
              .where((MapEntry<String, List<double>> e) => _pct(e.value, 1) > 8)
              .toList()
            ..sort((a, b) => _pct(b.value, 1).compareTo(_pct(a.value, 1)));
      for (final MapEntry<String, List<double>> entry in slow.take(40)) {
        final List<String> key = entry.key.split('|');
        debugPrint(
          'TOOL_SWITCH_TRACE ${threadNames[key[0]] ?? key[0]} | ${key[1]} | '
          'count ${entry.value.length} | over8 '
          '${entry.value.where((double ms) => ms > 8).length} | max '
          '${_pct(entry.value, 1).toStringAsFixed(1)} | p50 '
          '${_pct(entry.value, .5).toStringAsFixed(2)}',
        );
      }
    }

    final NoteContent content = await repository.loadNote(note.id);
    final StoredPage first = content.pages.first;
    debugPrint(
      'TOOL_SWITCH_CONTENT pages ${content.pages.length} | first page: '
      'size ${first.setup.size} ${first.extent} | pdf ${first.pdfSource?.pageSize} '
      '| strokes ${first.strokes.length} points '
      '${first.strokes.fold<int>(0, (int n, Stroke s) => n + s.points.length)} '
      '| styles ${first.strokes.map((Stroke s) => '${s.style.writing.name}/${s.style.width}').toSet()} '
      '| images ${first.images.length} | stickies ${first.stickyNotes.length} '
      '| texts ${first.textElements.length} | masks ${first.pdfMasks.length}',
    );

    await switching('opening_idle');
    await switching('opening_zoom');
    await zoomTo(4 / viewport.zoom, settle: Duration.zero);
    await switching('zoomed_in_rendering');
    await pumpFor(const Duration(seconds: 4));
    await switching('zoomed_in');
    await binding.traceAction(
      () => switching('zoomed_idle_traced'),
      reportKey: 'zoomed_idle_traced',
    );
    summarizeTimeline('zoomed_idle_traced');
    await binding.traceAction(
      () => switching('zoomed_in_traced'),
      reportKey: 'zoomed_in_traced',
    );
    summarizeTimeline('zoomed_in_traced');
    await zoomTo(1 / viewport.zoom);
    await switching('zoom_1');

    await tester.pumpWidget(const SizedBox());
    await Future<void>.delayed(const Duration(milliseconds: 300));
    repository.dispose();
    tabs.dispose();
    await directory.delete(recursive: true);
  });
}
