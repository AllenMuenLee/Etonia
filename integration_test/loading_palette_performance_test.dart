// flutter drive --profile --no-dds --driver=test_driver/perf_driver.dart
//   --target=integration_test/loading_palette_performance_test.dart -d <device>
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/document_io/document_models.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/widgets/tool_palette.dart';
import 'package:greatnote/features/library/file_note_repository.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_editor_page.dart';
import 'package:greatnote/features/library/note_tabs_page.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/open_notes.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdf/widgets.dart' as pw;

Object? _decodeJson(String encoded) => jsonDecode(encoded);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('loading, warm switching, eviction and mixed-page palette drag', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp(
      'greatnote-latency-',
    );
    final repository = await FileNoteRepository.open(directory);
    final tabs = OpenNotes();
    final notes = <NoteEntry>[];
    // An actual PDF, image and 64,000 ink points per note. No network services.
    final pdf = pw.Document()
      ..addPage(pw.Page(build: (_) => pw.Text('Latency benchmark PDF')));
    final pdfBytes = await pdf.save();
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(128, 128);
    picture.dispose();
    final imageData = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    final imageBytes = imageData.buffer.asUint8List();
    image.dispose();
    for (var noteIndex = 0; noteIndex < 6; noteIndex++) {
      debugPrint('Preparing generated performance note ${noteIndex + 1}/6');
      final note = await repository.createNote(title: 'Performance $noteIndex');
      final pdfId = await repository.storeAsset(
        note.id,
        pdfBytes,
        kind: NoteAssetKind.pdf,
        extension: 'pdf',
      );
      final imageId = await repository.storeAsset(
        note.id,
        imageBytes,
        kind: NoteAssetKind.image,
        extension: 'png',
      );
      await repository.saveNote(
        note.id,
        NoteContent([
          for (var page = 0; page < 20; page++)
            StoredPage(
              setup: const PageSetup(size: PageSize.a4Portrait),
              pdfSource: PdfPageSource(
                assetId: pdfId,
                pageIndex: 0,
                pageSize: const Size(794, 1123),
              ),
              images: [
                NoteImageElement(
                  id: 'image',
                  assetId: imageId,
                  pixelSize: const Size(128, 128),
                  center: const InkVector(200, 200),
                  size: const Size(128, 128),
                  rotation: 0,
                ),
              ],
              strokes: [
                for (var stroke = 0; stroke < 80; stroke++)
                  Stroke.fromPoints(
                    style: const StrokeStyle(ink: InkPalette.ink, width: 2),
                    points: [
                      for (var point = 0; point < 40; point++)
                        InkVector(
                          30 + point * 12,
                          30 + stroke * 12 + 4 * math.sin(point / 2),
                        ),
                    ],
                  ),
              ],
            ),
        ]),
      );
      notes.add(note);
    }
    final metrics = <String, Object?>{
      'mode': const bool.fromEnvironment('dart.vm.product')
          ? 'release'
          : const bool.fromEnvironment('dart.vm.profile')
          ? 'profile'
          : 'debug',
      'platform': Platform.operatingSystem,
      'points_per_note': 64000,
      'pages_per_note': 20,
      'note_count': notes.length,
      'refresh_hz': tester.view.display.refreshRate,
    };

    Future<void> until(bool Function() ready) async {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!ready()) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('Timed out waiting for page');
        }
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    bool currentEditorShown() => find
        .byType(EditorScreen)
        .evaluate()
        .any(
          (element) =>
              (element.widget as EditorScreen).noteId == tabs.active?.id,
        );

    Future<void> measure(String name, Future<void> Function() action) async {
      debugPrint('Profiling $name');
      final frames = <FrameTiming>[];
      void record(List<FrameTiming> batch) => frames.addAll(batch);
      SchedulerBinding.instance.addTimingsCallback(record);
      final rssBefore = ProcessInfo.currentRss;
      await binding.traceAction(action, reportKey: '${name}_timeline');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      SchedulerBinding.instance.removeTimingsCallback(record);
      double percentile(List<double> values, double quantile) {
        values.sort();
        return values.isEmpty
            ? 0
            : values[((values.length - 1) * quantile).round()];
      }

      final uiMs = frames
          .map((f) => f.buildDuration.inMicroseconds / 1000)
          .toList();
      final rasterMs = frames
          .map((f) => f.rasterDuration.inMicroseconds / 1000)
          .toList();
      final budget = 1000 / tester.view.display.refreshRate;
      metrics[name] = {
        'frames': frames.length,
        'ui_p50_ms': percentile(uiMs, .5),
        'ui_p95_ms': percentile(uiMs, .95),
        'raster_p50_ms': percentile(rasterMs, .5),
        'raster_p95_ms': percentile(rasterMs, .95),
        'jank_frames': frames
            .where(
              (f) =>
                  f.buildDuration.inMicroseconds / 1000 > budget ||
                  f.rasterDuration.inMicroseconds / 1000 > budget,
            )
            .length,
        'rss_before_bytes': rssBefore,
        'rss_after_bytes': ProcessInfo.currentRss,
      };
      debugPrint('Finished $name: ${metrics[name]}');
    }

    await measure('note_cold_open', () async {
      final clock = Stopwatch()..start();
      tabs.open(notes.first);
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
            ),
          ),
        ),
      );
      metrics['cold_first_page_shell_ms'] = clock.elapsedMicroseconds / 1000;
      await until(currentEditorShown);
      metrics['cold_hydrated_editor_ms'] = clock.elapsedMicroseconds / 1000;
      await until(() => find.byType(RawImage).evaluate().length >= 2);
      metrics['cold_pdf_and_image_ms'] = clock.elapsedMicroseconds / 1000;
    });
    await measure('note_second_open', () async {
      final clock = Stopwatch()..start();
      tabs.open(notes[1]);
      await tester.pump();
      metrics['second_first_page_shell_ms'] = clock.elapsedMicroseconds / 1000;
      await tester.pumpAndSettle();
      await until(currentEditorShown);
    });
    await measure('note_warm_switch', () async {
      final times = <double>[];
      for (var i = 0; i < 30; i++) {
        final clock = Stopwatch()..start();
        tabs.open(notes[i % 2]);
        await tester.pump();
        times.add(clock.elapsedMicroseconds / 1000);
        await tester.pumpAndSettle();
      }
      metrics['warm_switch_first_frame_ms'] = times;
    });
    await measure('note_cache_pressure', () async {
      for (var i = 0; i < 18; i++) {
        tabs.open(notes[i % notes.length]);
        await tester.pumpAndSettle();
        await until(currentEditorShown);
      }
      metrics['retained_editors'] = find
          .byType(EditorScreen, skipOffstage: false)
          .evaluate()
          .length;
    });
    await until(() => find.byType(RawImage).evaluate().length >= 2);
    await measure('palette_drag', () async {
      final surface = find.byKey(const ValueKey('palette-surface'));
      final start = tester.getTopLeft(surface) + const Offset(16, 24);
      final gesture = await tester.startGesture(start);
      await tester.pump(
        ToolPalette.liftDelay + const Duration(milliseconds: 50),
      );
      for (var i = 0; i < 360; i++) {
        await gesture.moveTo(
          start + Offset(40 * math.sin(i / 30), 80 + 40 * math.cos(i / 30)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
    });
    // Measure worker startup plus result transfer separately, after the cold
    // scenario so this does not warm its isolate path before timing it.
    final encoded = await File(
      '${directory.path}/notes/${notes.first.id}.json',
    ).readAsString();
    final syncTimes = <double>[];
    final workerTimes = <double>[];
    for (var i = 0; i < 5; i++) {
      final clock = Stopwatch()..start();
      final syncResult = _decodeJson(encoded);
      syncTimes.add(clock.elapsedMicroseconds / 1000);
      expect((syncResult! as Map)['pages'], hasLength(20));
      clock.reset();
      final workerResult = await compute(_decodeJson, encoded);
      workerTimes.add(clock.elapsedMicroseconds / 1000);
      expect((workerResult! as Map)['pages'], hasLength(20));
    }
    metrics['json_decode_comparison'] = {
      'encoded_chars': encoded.length,
      'sync_ms': syncTimes,
      'worker_roundtrip_ms': workerTimes,
    };
    binding.reportData ??= {};
    binding.reportData!['loading_palette_metrics'] = metrics;
    await tester.pumpWidget(const SizedBox());
    await Future<void>.delayed(const Duration(milliseconds: 200));
    repository.dispose();
    tabs.dispose();
    // This exact directory was created above for the generated fixture only.
    await directory.delete(recursive: true);
  });
}
