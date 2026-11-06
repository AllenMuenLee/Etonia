// flutter drive --no-dds --no-pub --profile \
//   --driver=test_driver/perf_driver.dart \
//   --target=integration_test/study_desk_resources_performance_test.dart -d DEVICE
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:greatnote/features/library/study_desk/study_desk_models.dart';
import 'package:greatnote/features/library/study_desk/study_desk_store.dart';

// The previous persistence algorithm, retained only as a benchmark control.
class _MainIsolateStore implements StudyDeskStore {
  _MainIsolateStore(this.file);
  final File file;
  Future<void> _writes = Future.value();

  @override
  Future<StudyDeskState?> read() async => StudyDeskState.fromJson(
    jsonDecode(await file.readAsString()) as Map<String, Object?>,
  );

  @override
  Future<void> write(StudyDeskState state) {
    final encoded = jsonEncode(state.toJson());
    return _writes = _writes.then((_) async {
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(encoded, flush: true);
      await temporary.rename(file.path);
    });
  }
}

Future<Map<String, Object?>> _measure(
  StudyDeskStore store,
  StudyDeskState state,
) async {
  // Warm up file access, isolate startup and compiled code equally before
  // sampling. Wall-clock storage latency and root-isolate stalls are separate.
  await store.write(state);
  await store.read();
  final synchronousCalls = <int>[];
  final elapsed = <int>[];
  final heartbeatGaps = <int>[];
  final clock = Stopwatch()..start();
  var lastBeat = clock.elapsedMicroseconds;
  final heartbeat = Timer.periodic(const Duration(milliseconds: 4), (_) {
    final now = clock.elapsedMicroseconds;
    heartbeatGaps.add(now - lastBeat);
    lastBeat = now;
  });
  try {
    for (var sample = 0; sample < 5; sample++) {
      await Future<void>.delayed(const Duration(milliseconds: 8));
      final total = Stopwatch()..start();
      final writes = <Future<void>>[];
      // A burst models source selection and history changes while a save is
      // already running. Each snapshot is a complete replacement of the desk.
      for (var snapshot = 0; snapshot < 8; snapshot++) {
        final call = Stopwatch()..start();
        writes.add(store.write(state));
        synchronousCalls.add(call.elapsedMicroseconds);
      }
      await Future.wait(writes);
      final restored = await store.read();
      expect(restored!.currentSessionId, state.currentSessionId);
      expect(restored.sessions.length, state.sessions.length);
      expect(
        restored.sessions.last.messages.last.text,
        state.sessions.last.messages.last.text,
      );
      elapsed.add(total.elapsedMicroseconds);
    }
    await Future<void>.delayed(const Duration(milliseconds: 8));
  } finally {
    heartbeat.cancel();
  }
  Map<String, double> stats(List<int> values) {
    values.sort();
    return {
      'p50Ms': values[((values.length - 1) * .5).round()] / 1000,
      'p90Ms': values[((values.length - 1) * .9).round()] / 1000,
      'maxMs': values.last / 1000,
    };
  }

  return {
    'writeCallBlocking': stats(synchronousCalls),
    'burstSaveAndReload': stats(elapsed),
    'eventLoopHeartbeatGap': stats(heartbeatGaps),
    'heartbeatSamples': heartbeatGaps.length,
  };
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('study desk persistence keeps large history off the UI isolate', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final result = await tester.runAsync(() async {
      final temporary = await getTemporaryDirectory();
      await temporary.create(recursive: true);
      final directory = await temporary.createTemp('study_profile_');
      try {
        final state = StudyDeskState(
          sources: const [StudySourceItem(noteId: 'benchmark')],
          sessions: [
            for (var i = 0; i < 24; i++)
              StudySession(
                id: '$i',
                created: DateTime(2026, 11, 4),
                messages: [
                  for (var message = 0; message < 12; message++)
                    StudyMessage.answer(
                      'Mechanics: momentum and torque. ' * 80,
                    ),
                ],
              ),
          ],
          currentSessionId: '23',
        );
        final control = await _measure(
          _MainIsolateStore(File('${directory.path}/control.json')),
          state,
        );
        final optimized = await _measure(
          FileStudyDeskStore(File('${directory.path}/optimized.json')),
          state,
        );
        return {
          'payloadCharacters': jsonEncode(state.toJson()).length,
          'samples': 5,
          'writesPerBurst': 8,
          'control': control,
          'optimized': optimized,
        };
      } finally {
        await directory.delete(recursive: true);
      }
    });
    binding.reportData = {'study_desk_resource_stats': result};
    // ignore: avoid_print
    print('STUDY_DESK_RESOURCES ${jsonEncode(result)}');
  });
}
