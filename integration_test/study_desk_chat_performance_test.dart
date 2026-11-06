// Run on a physical tablet in profile mode. Fixtures stay entirely in memory.
// flutter drive --no-dds --profile --driver=test_driver/perf_driver.dart \
//   --target=integration_test/study_desk_chat_performance_test.dart -d DEVICE
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/study_desk/study_desk_controller.dart';
import 'package:greatnote/features/library/study_desk/study_desk_models.dart';
import 'package:greatnote/features/library/study_desk/study_desk_screen.dart';
import 'package:greatnote/features/library/study_desk/study_desk_store.dart';

class _OfflineClient extends AiClient {
  @override
  bool get isConfigured => false;
  @override
  String get modelLabel => 'Offline performance fixture';
  @override
  Future<AiResult> send(
    AiRequest request, {
    AiPartialCallback? onPartial,
    AiNotationPartialCallback? onNotation,
  }) async => const AiError(AiFailure(AiFailureKind.notConfigured));
  @override
  void close() {}
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('study transcript scrolling and citation transitions', (
    tester,
  ) async {
    final repository = InMemoryNoteRepository();
    final note = await repository.createNote(title: 'Mechanics lecture');
    final strokes = [
      for (var i = 0; i < 1200; i++)
        Stroke.fromPoints(
          style: const StrokeStyle(ink: InkPalette.ink, width: 2),
          points: [
            for (var p = 0; p < 12; p++)
              InkVector(
                30 + (i % 20) * 34 + p * 1.8,
                40.0 + (i ~/ 20) * 16 + (p.isEven ? 3 : -3),
              ),
          ],
        ),
    ];
    await repository.saveNote(
      note.id,
      NoteContent([
        StoredPage(setup: const PageSetup(), strokes: strokes),
        StoredPage(setup: const PageSetup(), strokes: strokes),
      ]),
    );
    final citations = [
      for (var i = 0; i < 16; i++)
        StudyCitation(
          noteId: note.id,
          pageIndex: i ~/ 8,
          revision: 1,
          rings: [Rect.fromLTWH(50, 50 + (i % 8) * 100, 360, 80)],
        ),
    ];
    const vector =
        '```svg\n<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 80">'
        '<path d="M10 40H190" stroke="black"/><circle cx="100" cy="40" r="25" fill="teal"/>'
        '</svg>\n```';
    final explanation =
        'Momentum is conserved when external forces sum to zero. ' * 4;
    final messages = <StudyMessage>[
      for (var i = 0; i < 32; i++) ...[
        StudyMessage.user('Explain momentum and torque, example $i'),
        StudyMessage.answer(
          '$explanation\n\n'
          r'$$\tau = I\alpha \quad L = I\omega$$'
          '\n\n$vector\n\n> [!THEOREM]\n> Angular momentum changes with external torque.\n\n'
          '```python\nangular_momentum = inertia * velocity\n```',
          links: [
            StudyParagraphLinks(
              paragraph: 1,
              citations: [citations[i % citations.length]],
            ),
          ],
        ),
      ],
    ];
    final store = InMemoryStudyDeskStore();
    await store.write(
      StudyDeskState(
        sources: [StudySourceItem(noteId: note.id)],
        sessions: [
          StudySession(
            id: 'profile',
            created: DateTime(2026, 11, 4),
            messages: messages,
          ),
        ],
        currentSessionId: 'profile',
      ),
    );
    final desk = StudyDeskController(
      repository: repository,
      client: _OfflineClient(),
      store: store,
    );
    await desk.load();
    desk.setMode(StudyDeskMode.chat);
    await tester.pumpWidget(
      GreatnoteApp(
        home: Scaffold(
          body: StudyDeskScreen(
            controller: desk,
            thumbnail: (_) => const SizedBox(),
            onAddSources: () {},
            onEditCitation: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Warm the citation surface and renderer before measuring repeated reading.
    desk.focusCitation(citations.first, message: 1, paragraph: 1);
    await tester.pumpAndSettle();
    final transcript = find.byType(ListView).last;
    final frames = <FrameTiming>[];
    final refresh = PlatformDispatcher.instance.views.first.display.refreshRate;
    void record(List<FrameTiming> batch) => frames.addAll(batch);
    SchedulerBinding.instance.addTimingsCallback(record);
    var broadcasts = 0;
    void changed() => broadcasts++;
    desk.addListener(changed);
    try {
      await binding.traceAction(() async {
        for (var i = 0; i < 10; i++) {
          await tester.fling(
            transcript,
            Offset(0, i.isEven ? 1300 : -1300),
            2600,
          );
          await tester.pumpAndSettle();
          await tester.pump(const Duration(milliseconds: 200));
        }
        for (var i = 0; i < citations.length; i++) {
          desk.focusCitation(citations[i], message: i * 2 + 1, paragraph: 1);
          await tester.pumpAndSettle();
        }
      }, reportKey: 'study_desk_chat_timeline');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)),
      );
    } finally {
      desk.removeListener(changed);
      SchedulerBinding.instance.removeTimingsCallback(record);
    }
    Map<String, Object> stats(List<double> samples) {
      samples.sort();
      double at(double percentile) =>
          samples[((samples.length - 1) * percentile).round()];
      return {
        'p50Ms': at(0.5),
        'p90Ms': at(0.9),
        'p99Ms': at(0.99),
        'worstMs': samples.last,
        'over60Hz': samples.where((v) => v > 1000 / 60).length,
        'over120Hz': samples.where((v) => v > 1000 / 120).length,
      };
    }

    expect(frames, isNotEmpty);
    final result = {
      'refreshHz': refresh,
      'frameCount': frames.length,
      'transcriptBroadcasts': broadcasts,
      'build': stats([
        for (final f in frames) f.buildDuration.inMicroseconds / 1000,
      ]),
      'raster': stats([
        for (final f in frames) f.rasterDuration.inMicroseconds / 1000,
      ]),
    };
    binding.reportData!['study_desk_frame_stats'] = result;
    // ignore: avoid_print
    print('STUDY_DESK_RESULT ${jsonEncode(result)}');
    expect(broadcasts, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    desk.dispose();
    repository.dispose();
  });
}
