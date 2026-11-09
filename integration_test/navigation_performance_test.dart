// Page navigation in the library, cold and warm: into a folder and back,
// into a PDF note and an ink note and back, and the account page pushed
// over the library and closed. Frame timings are reported for the UI
// (build) and raster threads separately, with frames the display missed
// and how long the UI isolate was blocked.
//
//   flutter drive --profile --no-dds --driver=test_driver/perf_driver.dart \
//     --target=integration_test/navigation_performance_test.dart -d <device>
//
// Each scenario is printed as one `NAV_PERF_RESULT` line of JSON and the
// whole run is written to `build/navigation_metrics.json`.
//
// With `--dart-define=TRACE_BUILDS=true` the run instead records which
// widgets were rebuilt during each move (`NAV_PERF_BUILDS` lines). Build
// profiling slows every frame, so its frame timings are not comparable.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show debugProfileLayoutsEnabled;
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/document_io/document_models.dart';
import 'package:greatnote/features/editor/document_io/pdf_preview_store.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/library/file_note_repository.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/library_screen.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

const bool _traceBuilds = bool.fromEnvironment('TRACE_BUILDS');

/// How long after a tap its move is counted as running: the longest move,
/// a first-visit zoom, with room for a late first frame.
const Duration _move = Duration(milliseconds: 600);

/// Longest gaps between ticks of a 1 ms timer: how long the UI isolate was
/// unable to run anything else.
class _StallMonitor {
  final List<double> gaps = <double>[];
  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  int _last = 0;

  void start() {
    gaps.clear();
    _clock
      ..reset()
      ..start();
    _last = _clock.elapsedMicroseconds;
    _timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      final int now = _clock.elapsedMicroseconds;
      gaps.add((now - _last) / 1000);
      _last = now;
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}

double _pct(List<double> values, double q) {
  if (values.isEmpty) return 0;
  final List<double> sorted = <double>[...values]..sort();
  return sorted[((sorted.length - 1) * q).round()];
}

double _round(double value) => (value * 100).round() / 100;

class _Span {
  _Span(this.name, this.start, this.end);
  final String name;
  final int start;
  final int end;
  final List<_Span> children = <_Span>[];
  double get ms => (end - start) / 1000;
}

/// The slow frames of [timeline]: each UI phase (build, layout, paint...)
/// or raster frame over its limit, with the path down to where its time
/// went and the largest spans at that point. One `NAV_PERF_SLOW` line each.
List<String> _slowFrames(
  String scenario,
  Map<String, dynamic>? timeline,
  int tappedAt,
) {
  final List<Object?> events =
      timeline?['traceEvents'] as List<Object?>? ?? const <Object?>[];
  final Map<Object?, String> threads = <Object?, String>{};
  final Map<Object?, List<_Span>> spans = <Object?, List<_Span>>{};
  final Map<Object?, List<Map<String, Object?>>> open =
      <Object?, List<Map<String, Object?>>>{};
  for (final Object? raw in events) {
    if (raw is! Map<String, Object?>) continue;
    final Object? tid = raw['tid'];
    final String ph = '${raw['ph']}';
    if (ph == 'M' && raw['name'] == 'thread_name') {
      threads[tid] = '${(raw['args'] as Map<String, Object?>?)?['name']}';
      continue;
    }
    final int? ts = (raw['ts'] as num?)?.toInt();
    if (ts == null) continue;
    final String name = '${raw['name']}';
    switch (ph) {
      case 'X':
        final int dur = (raw['dur'] as num?)?.toInt() ?? 0;
        (spans[tid] ??= <_Span>[]).add(_Span(name, ts, ts + dur));
      case 'B':
        (open[tid] ??= <Map<String, Object?>>[]).add(raw);
      case 'E':
        final List<Map<String, Object?>>? stack = open[tid];
        if (stack == null || stack.isEmpty) continue;
        final Map<String, Object?> begin = stack.removeLast();
        (spans[tid] ??= <_Span>[]).add(
          _Span('${begin['name']}', (begin['ts']! as num).toInt(), ts),
        );
    }
  }
  final List<String> lines = <String>[];
  const Set<String> phases = <String>{
    'BUILD',
    'LAYOUT',
    'PAINT',
    'SEMANTICS',
    'COMPOSITING',
    'FINALIZE TREE',
    'Animate',
  };
  for (final MapEntry<Object?, List<_Span>> thread in spans.entries) {
    final String threadName = threads[thread.key] ?? '${thread.key}';
    final bool ui = threadName.contains('ui');
    final bool raster = threadName.contains('raster');
    if (!ui && !raster) continue;
    // Nest by containment.
    final List<_Span> sorted = thread.value
      ..sort((a, b) {
        final int byStart = a.start.compareTo(b.start);
        return byStart != 0 ? byStart : b.end.compareTo(a.end);
      });
    final List<_Span> roots = <_Span>[];
    final List<_Span> stack = <_Span>[];
    for (final _Span span in sorted) {
      while (stack.isNotEmpty && stack.last.end <= span.start) {
        stack.removeLast();
      }
      if (stack.isEmpty) {
        roots.add(span);
      } else {
        stack.last.children.add(span);
      }
      stack.add(span);
    }
    if (raster) {
      // Skia programs compiled for this move, as with Impeller off: none
      // once the engine's program cache on disk has them.
      final List<_Span> compiles = <_Span>[
        for (final _Span span in thread.value)
          if (span.name == 'shader_compile') span,
      ];
      lines.add(
        'NAV_PERF_SHADERS ${jsonEncode(<String, Object?>{'scenario': scenario, 'compiles': compiles.length, 'compile_ms': _round(compiles.fold<double>(0, (double t, _Span s) => t + s.ms)), 'cache_misses': thread.value.where((_Span s) => s.name == 'cache_miss').length, 'during_move': compiles.where((_Span s) => s.start - tappedAt <= _move.inMicroseconds).length})}',
      );
    }
    final List<_Span> slow = <_Span>[];
    void find(_Span span) {
      if (ui && phases.contains(span.name) && span.ms > 6) {
        slow.add(span);
        return;
      }
      if (raster && span.children.isNotEmpty && span.ms > 16) {
        // The outermost long span of a raster frame.
        slow.add(span);
        return;
      }
      span.children.forEach(find);
    }

    roots.forEach(find);
    if (ui) {
      // Long work outside any frame phase: microtasks, timers, GC.
      bool holdsPhase(_Span span) =>
          phases.contains(span.name) || span.children.any(holdsPhase);
      for (final _Span root in roots) {
        if (root.ms > 12 && !holdsPhase(root)) slow.add(root);
      }
    }
    for (final _Span span in slow) {
      final List<String> path = <String>[];
      _Span at = span;
      while (at.children.isNotEmpty) {
        final _Span biggest = at.children.reduce(
          (a, b) => a.ms >= b.ms ? a : b,
        );
        if (biggest.ms < at.ms * 0.6) break;
        path.add('${biggest.name} ${_round(biggest.ms)}');
        at = biggest;
      }
      final List<_Span> top = <_Span>[...at.children]
        ..sort((a, b) => b.ms.compareTo(a.ms));
      lines.add(
        'NAV_PERF_SLOW ${jsonEncode(<String, Object?>{
          'scenario': scenario,
          // Milliseconds after the tap; under [_move] it held up the move.
          'at_ms': ((span.start - tappedAt) / 1000).round(),
          'thread': threadName.split(' ').first,
          'span': span.name,
          'ms': _round(span.ms),
          'path': path.take(14).toList(),
          'split': <String>[for (final _Span s in top.take(8)) '${s.name} ${_round(s.ms)}'],
        })}',
      );
    }
  }
  return lines;
}

/// A scan: one full-page picture on each of [pages] pages.
Future<Uint8List> _scanPdf(int pages) async {
  const int width = 1240;
  const int height = 1754;
  final pw.Document pdf = pw.Document();
  for (int page = 0; page < pages; page++) {
    final Uint8List pixels = Uint8List(width * height * 4);
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int i = (y * width + x) * 4;
        final int line = (y ~/ 38 + page) % 3 == 0 && (y % 38) < 22 ? 1 : 0;
        final int grain = (x * 31 + y * 17 + page * 7) & 15;
        final int v = line == 1 && (x ~/ 11) % 5 != 0
            ? 40 + grain
            : 236 + grain;
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

List<Stroke> _handwriting(int lines) => <Stroke>[
  for (int stroke = 0; stroke < lines; stroke++)
    Stroke.fromPoints(
      style: const StrokeStyle(ink: InkPalette.ink, width: 2),
      points: <InkVector>[
        for (int point = 0; point < 40; point++)
          InkVector(
            40 + point * 14,
            60 + stroke * 14 + 4 * math.sin(point / 2),
          ),
      ],
    ),
];

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('library navigation, cold and warm', (WidgetTester tester) async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'greatnote-nav-',
    );
    final FileNoteRepository repository = await FileNoteRepository.open(
      directory,
    );

    // A library as a student has it: folders, a scanned PDF, notes of
    // handwriting, and enough cards to fill the grid.
    final Folder biology = await repository.createFolder('Biology');
    final Folder history = await repository.createFolder('History');
    for (int i = 0; i < 8; i++) {
      final NoteEntry note = await repository.createNote(
        title: 'Biology $i',
        folderId: biology.id,
      );
      await repository.saveNote(
        note.id,
        NoteContent(<StoredPage>[
          StoredPage(
            setup: const PageSetup(size: PageSize.a4Portrait),
            strokes: _handwriting(24),
          ),
        ]),
      );
    }
    for (int i = 0; i < 4; i++) {
      await repository.createNote(title: 'History $i', folderId: history.id);
    }
    // Older notes first: the newest come first in the grid, so the two
    // notes opened below are on screen.
    for (int i = 0; i < 14; i++) {
      final NoteEntry note = await repository.createNote(title: 'Note $i');
      await repository.saveNote(
        note.id,
        NoteContent(<StoredPage>[
          StoredPage(
            setup: const PageSetup(size: PageSize.a4Portrait),
            strokes: _handwriting(8 + i),
          ),
        ]),
      );
    }
    final Uint8List scan = await _scanPdf(6);
    final NoteEntry pdfNote = await repository.createNote(title: 'Scanned PDF');
    final String pdfAsset = await repository.storeAsset(
      pdfNote.id,
      scan,
      kind: NoteAssetKind.pdf,
      extension: 'pdf',
    );
    await repository.saveNote(
      pdfNote.id,
      NoteContent(<StoredPage>[
        for (int page = 0; page < 6; page++)
          StoredPage(
            setup: const PageSetup(size: PageSize.a4Portrait),
            pdfSource: PdfPageSource(
              assetId: pdfAsset,
              pageIndex: page,
              pageSize: const Size(794, 1123),
            ),
            strokes: _handwriting(12),
          ),
      ]),
    );
    final NoteEntry inkNote = await repository.createNote(title: 'Lecture ink');
    await repository.saveNote(
      inkNote.id,
      NoteContent(<StoredPage>[
        for (int page = 0; page < 8; page++)
          StoredPage(
            setup: const PageSetup(size: PageSize.a4Portrait),
            strokes: _handwriting(70),
          ),
      ]),
    );

    final double refreshHz = tester.view.display.refreshRate;
    final double budgetMs = 1000 / refreshHz;
    final List<Map<String, Object?>> results = <Map<String, Object?>>[];
    final _StallMonitor monitor = _StallMonitor();

    await tester.pumpWidget(
      GreatnoteApp(
        themeMode: ThemeMode.light,
        home: LibraryScreen(
          repository: repository,
          pdfPreviewStore: FilePdfPreviewStore(
            Future<Directory>.value(Directory('${directory.path}/previews')),
          ),
        ),
      ),
    );

    Future<void> pumpFor(Duration duration) async {
      final Stopwatch clock = Stopwatch()..start();
      while (clock.elapsed < duration) {
        await tester.pump();
      }
    }

    Future<void> waitFor(Finder finder, {String? what}) async {
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 60));
      while (finder.evaluate().isEmpty) {
        if (DateTime.now().isAfter(deadline)) {
          final List<String> shown = <String>[
            for (final Element e
                in find
                    .byWidgetPredicate(
                      (Widget w) =>
                          w.key is ValueKey<String> &&
                          RegExp(
                            r'^(note|folder|library)-',
                          ).hasMatch((w.key! as ValueKey<String>).value),
                    )
                    .evaluate())
              (e.widget.key! as ValueKey<String>).value,
          ];
          throw StateError('Never found ${what ?? finder}; shown: $shown');
        }
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    Finder card(String key) => find.descendant(
      of: find.byKey(const ValueKey<String>('library-items')),
      matching: find.byKey(ValueKey<String>(key)),
    );

    await waitFor(card('note-${pdfNote.id}'), what: 'the library');
    // Card pictures and the first-run warm-up settle before measuring.
    await pumpFor(const Duration(seconds: 4));

    /// Taps [target] and records every frame for [settle] afterwards.
    Future<void> measure(
      String name,
      Finder target, {
      Duration settle = const Duration(milliseconds: 1400),
    }) async {
      await waitFor(target, what: name);
      final String startedAt = DateTime.now().toIso8601String().substring(11);
      final List<FrameTiming> frames = <FrameTiming>[];
      void record(List<FrameTiming> batch) => frames.addAll(batch);
      SchedulerBinding.instance.addTimingsCallback(record);
      monitor.start();

      // When the tap landed, on the clock frame timings and the timeline
      // share: frames from then until [_move] later are the move itself.
      int tappedAt = 0;
      Future<void> drive() async {
        tappedAt = Timeline.now;
        await tester.tap(target, warnIfMissed: false);
        await pumpFor(settle);
      }

      if (_traceBuilds) {
        debugProfileBuildsEnabled = true;
        debugProfileLayoutsEnabled = true;
        final Map<String, dynamic>? timeline;
        final String key = '${name}_timeline';
        try {
          await binding.traceAction(
            drive,
            streams: const <String>['Dart', 'Embedder', 'GC'],
            reportKey: key,
          );
          // Read here and dropped: all of them at once are too much to send.
          timeline = binding.reportData?.remove(key) as Map<String, dynamic>?;
        } finally {
          debugProfileBuildsEnabled = false;
          debugProfileLayoutsEnabled = false;
        }
        for (final String line in _slowFrames(name, timeline, tappedAt)) {
          debugPrint(line);
        }
      } else {
        await drive();
      }
      // Timings arrive in batches; let the last one in.
      await tester.pump(const Duration(milliseconds: 200));
      monitor.stop();
      SchedulerBinding.instance.removeTimingsCallback(record);

      final List<double> build = <double>[
        for (final FrameTiming f in frames)
          f.buildDuration.inMicroseconds / 1000,
      ];
      final List<double> raster = <double>[
        for (final FrameTiming f in frames)
          f.rasterDuration.inMicroseconds / 1000,
      ];
      // Frames the display had to repeat: the gaps between one frame's
      // vsync and the next's, past one refresh, while the move was on.
      int missed = 0;
      double longestGap = 0;
      final List<double> intervals = <double>[];
      for (int i = 1; i < frames.length; i++) {
        final double gap =
            (frames[i].timestampInMicroseconds(ui.FramePhase.vsyncStart) -
                frames[i - 1].timestampInMicroseconds(
                  ui.FramePhase.vsyncStart,
                )) /
            1000;
        intervals.add(gap);
        longestGap = math.max(longestGap, gap);
        if (gap > budgetMs * 1.5) missed += (gap / budgetMs).round() - 1;
      }
      // The same, for the move alone: from the tap, through [_move].
      final int moveEnd = tappedAt + _move.inMicroseconds;
      final List<FrameTiming> moving = <FrameTiming>[
        for (final FrameTiming f in frames)
          if (f.timestampInMicroseconds(ui.FramePhase.vsyncStart) <= moveEnd) f,
      ];
      int moveMissed = 0;
      double moveGap = 0;
      int previous = tappedAt;
      for (final FrameTiming f in moving) {
        final int vsync = f.timestampInMicroseconds(ui.FramePhase.vsyncStart);
        final double gap = (vsync - previous) / 1000;
        previous = vsync;
        moveGap = math.max(moveGap, gap);
        if (gap > budgetMs * 1.5) moveMissed += (gap / budgetMs).round() - 1;
      }
      final Map<String, Object?> result = <String, Object?>{
        'name': name,
        'at': startedAt,
        'refresh_hz': _round(refreshHz),
        'budget_ms': _round(budgetMs),
        'frames': frames.length,
        // The move: the first [_move] after the tap.
        'move_frames': moving.length,
        'move_missed_vsyncs': moveMissed,
        'move_longest_gap_ms': _round(moveGap),
        'move_ui_max': _round(
          moving.fold<double>(
            0,
            (double m, FrameTiming f) =>
                math.max(m, f.buildDuration.inMicroseconds / 1000),
          ),
        ),
        'move_raster_max': _round(
          moving.fold<double>(
            0,
            (double m, FrameTiming f) =>
                math.max(m, f.rasterDuration.inMicroseconds / 1000),
          ),
        ),
        // Everything from here on: the move and what follows it.
        'ui_p50': _round(_pct(build, .5)),
        'ui_p90': _round(_pct(build, .9)),
        'ui_p99': _round(_pct(build, .99)),
        'ui_max': _round(_pct(build, 1)),
        'ui_over_budget': build.where((double v) => v > budgetMs).length,
        'raster_p50': _round(_pct(raster, .5)),
        'raster_p90': _round(_pct(raster, .9)),
        'raster_p99': _round(_pct(raster, .99)),
        'raster_max': _round(_pct(raster, 1)),
        'raster_over_budget': raster.where((double v) => v > budgetMs).length,
        // The rate frames actually came at: under continuous pumping it is
        // the display's own rate unless frames were late.
        'frame_interval_p50': _round(_pct(intervals, .5)),
        'missed_vsyncs': missed,
        'longest_frame_gap_ms': _round(longestGap),
        'stall_gaps_over_16ms': monitor.gaps.where((double g) => g > 16).length,
        'stall_gap_max': _round(_pct(monitor.gaps, 1)),
        'rss_mb': (ProcessInfo.currentRss / (1024 * 1024)).round(),
      };
      results.add(result);
      debugPrint('NAV_PERF_RESULT ${jsonEncode(result)}');
      // Rest between moves, as a person does.
      await pumpFor(const Duration(milliseconds: 600));
    }

    final Finder up = find.byTooltip('Up one folder');
    final Finder back = find.byTooltip('Back to library');
    final Finder account = find.byKey(
      const ValueKey<String>('library-account-button'),
    );
    final Finder close = find.byTooltip('Close');

    for (final String pass in <String>['cold', 'warm']) {
      await measure('folder_open_$pass', card('folder-${biology.id}'));
      await measure('folder_up_$pass', up);
      await measure(
        'pdf_note_open_$pass',
        card('note-${pdfNote.id}'),
        settle: const Duration(milliseconds: 2000),
      );
      await measure('pdf_note_back_$pass', back);
      await measure(
        'ink_note_open_$pass',
        card('note-${inkNote.id}'),
        settle: const Duration(milliseconds: 2000),
      );
      await measure('ink_note_back_$pass', back);
      await measure('account_push_$pass', account);
      await measure('account_pop_$pass', close);
    }

    binding.reportData = <String, dynamic>{
      ...?binding.reportData,
      'navigation_metrics': <String, Object?>{
        'mode': const bool.fromEnvironment('dart.vm.product')
            ? 'release'
            : const bool.fromEnvironment('dart.vm.profile')
            ? 'profile'
            : 'debug',
        'platform': Platform.operatingSystem,
        'refresh_hz': refreshHz,
        'trace_builds': _traceBuilds,
        'results': results,
      },
    };

    await tester.pumpWidget(const SizedBox());
    await Future<void>.delayed(const Duration(milliseconds: 300));
    repository.dispose();
    await directory.delete(recursive: true);
  });
}
