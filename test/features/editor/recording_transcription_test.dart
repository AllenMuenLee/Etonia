import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/audio/note_audio.dart';
import 'package:greatnote/features/editor/audio/recording_transcriber.dart';
import 'package:greatnote/features/editor/audio/stroke_replay_controller.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/page/note_document.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/widgets/recording_options.dart';
import 'package:greatnote/features/editor/widgets/recording_transcript_sheet.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_recording_track.dart';

import '../../helpers/pump_app.dart';

class _FakeTranscriber implements RecordingTranscriber {
  Completer<RecordingTranscript>? _answer;
  ValueChanged<double>? _onProgress;
  final Completer<String> started = Completer<String>();
  final List<String> cancelled = <String>[];
  String? audioPath;

  @override
  Future<RecordingTranscript> transcribe({
    required String recordingId,
    required String audioPath,
    required int durationMs,
    ValueChanged<double>? onProgress,
  }) {
    this.audioPath = audioPath;
    _onProgress = onProgress;
    _answer = Completer<RecordingTranscript>();
    started.complete(recordingId);
    return _answer!.future;
  }

  void progress(double fraction) => _onProgress?.call(fraction);
  void answer(RecordingTranscript transcript) => _answer!.complete(transcript);

  @override
  Future<void> cancel(String recordingId) async {
    cancelled.add(recordingId);
    _answer?.completeError(
      const TranscriptionFailure(TranscriptionFailureKind.cancelled),
    );
  }
}

class _IdleRecorder extends NoteAudioRecorder {
  NoteAudioRecorderState value = NoteAudioRecorderState.idle;

  @override
  NoteAudioRecorderState get state => value;
  @override
  String? get activeRecordingId => null;
  @override
  int get currentElapsedMs => 0;
  @override
  Future<bool> start() async => false;
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<RecordedNoteAudio?> stop() async => null;
}

NoteRecordingTrack _track({RecordingTranscript? transcript}) =>
    NoteRecordingTrack(
      id: 'rec-1',
      title: 'Lecture',
      assetPath: 'asset-1',
      durationMs: 120000,
      createdAt: DateTime.utc(2026, 10, 28),
      transcript: transcript,
    );

RecordingTranscript _transcript() => RecordingTranscript(
  segments: const <TranscriptSegment>[
    TranscriptSegment('Today we cover entropy.', startMs: 0),
    TranscriptSegment('It always increases.', startMs: 65000),
  ],
  createdAt: DateTime.utc(2026, 10, 28, 12),
  locale: 'en-US',
);

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('etonia-transcribe');
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('transcripts round-trip with the note, and old notes have none', () {
    final NoteContent content = NoteContent(
      const <StoredPage>[StoredPage(setup: PageSetup(), strokes: <Stroke>[])],
      recordings: <NoteRecordingTrack>[_track(transcript: _transcript())],
    );
    final NoteContent restored = NoteContent.fromJson(
      jsonDecode(jsonEncode(content.toJson())) as Map<String, Object?>,
    );
    final RecordingTranscript transcript =
        restored.recordings.single.transcript!;
    expect(transcript.locale, 'en-US');
    expect(transcript.segments.last.startMs, 65000);
    expect(transcript.text, 'Today we cover entropy. It always increases.');

    final Map<String, Object?> old = _track().toJson();
    expect(old.containsKey('transcript'), isFalse);
    expect(NoteRecordingTrack.fromJson(old)!.transcript, isNull);
  });

  test('a transcript is saved on the recording it belongs to', () {
    final NoteDocument document = NoteDocument(
      recordings: <NoteRecordingTrack>[_track()],
    );
    addTearDown(document.dispose);
    final int before = document.structureRevision;
    expect(document.setRecordingTranscript('rec-1', _transcript()), isTrue);
    expect(document.recordings.single.transcript!.segments, hasLength(2));
    expect(document.structureRevision, greaterThan(before));
    expect(document.setRecordingTranscript('gone', _transcript()), isFalse);
  });

  test('platform answers are read, and empty ones are no speech', () {
    final RecordingTranscript parsed =
        PlatformRecordingTranscriber.parseTranscript(<Object?, Object?>{
          'segments': <Object?>[
            <Object?, Object?>{'text': ' Hello there. ', 'startMs': 1200},
            <Object?, Object?>{'text': '   '},
            <Object?, Object?>{'text': 'Untimed line'},
          ],
          'locale': 'zh-TW',
        }, createdAt: DateTime.utc(2026));
    expect(parsed.segments.map((TranscriptSegment s) => s.text), <String>[
      'Hello there.',
      'Untimed line',
    ]);
    expect(parsed.segments.first.startMs, 1200);
    expect(parsed.segments.last.startMs, isNull);
    expect(parsed.locale, 'zh-TW');

    expect(
      () => PlatformRecordingTranscriber.parseTranscript(<Object?, Object?>{
        'segments': <Object?>[],
      }, createdAt: DateTime.utc(2026)),
      throwsA(
        isA<TranscriptionFailure>().having(
          (TranscriptionFailure f) => f.kind,
          'kind',
          TranscriptionFailureKind.noSpeech,
        ),
      ),
    );
    expect(
      PlatformRecordingTranscriber.failureKindOf('language'),
      TranscriptionFailureKind.language,
    );
    expect(
      PlatformRecordingTranscriber.failureKindOf('busy'),
      TranscriptionFailureKind.failed,
    );
  });

  test('the channel reports a platform without a transcriber', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PlatformRecordingTranscriber.channel, (
          MethodCall call,
        ) async {
          throw PlatformException(code: 'unavailable');
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(PlatformRecordingTranscriber.channel, null),
    );
    await expectLater(
      PlatformRecordingTranscriber().transcribe(
        recordingId: 'rec-1',
        audioPath: '/tmp/rec-1.m4a',
        durationMs: 1000,
      ),
      throwsA(
        isA<TranscriptionFailure>().having(
          (TranscriptionFailure f) => f.kind,
          'kind',
          TranscriptionFailureKind.unavailable,
        ),
      ),
    );
  });

  test('the controller hands the recognizer a copy and removes it', () async {
    final _FakeTranscriber transcriber = _FakeTranscriber();
    final RecordingTranscriptionController controller =
        RecordingTranscriptionController(
          transcriber: transcriber,
          temporaryDirectory: () async => temporary,
        );
    addTearDown(controller.dispose);
    final List<double?> progress = <double?>[];
    controller.addListener(() => progress.add(controller.progress));

    final Future<RecordingTranscript> result = controller.transcribe(
      _track(),
      readAudio: () async => Uint8List.fromList(<int>[1, 2, 3]),
    );
    expect(controller.activeId, 'rec-1');
    await transcriber.started.future;
    final File copy = File(transcriber.audioPath!);
    expect(await copy.readAsBytes(), <int>[1, 2, 3]);

    transcriber.progress(0.4);
    expect(controller.progress, 0.4);
    transcriber.answer(_transcript());
    expect((await result).segments, hasLength(2));
    expect(controller.isBusy, isFalse);
    expect(await copy.exists(), isFalse);
    expect(progress, contains(0.4));
  });

  test('cancelling stops the recognizer and reports it', () async {
    final _FakeTranscriber transcriber = _FakeTranscriber();
    final RecordingTranscriptionController controller =
        RecordingTranscriptionController(
          transcriber: transcriber,
          temporaryDirectory: () async => temporary,
        );
    addTearDown(controller.dispose);
    final Future<RecordingTranscript> result = controller.transcribe(
      _track(),
      readAudio: () async => Uint8List(4),
    );
    await transcriber.started.future;
    controller.cancel();
    expect(controller.isBusy, isFalse);
    await expectLater(
      result,
      throwsA(
        isA<TranscriptionFailure>().having(
          (TranscriptionFailure f) => f.kind,
          'kind',
          TranscriptionFailureKind.cancelled,
        ),
      ),
    );
    expect(transcriber.cancelled, <String>['rec-1']);
  });

  group('recording panel', () {
    late _IdleRecorder recorder;
    late NoteDocument document;
    late StrokeReplayController replay;
    late _FakeTranscriber transcriber;
    late RecordingTranscriptionController controller;
    Future<void>? pending;

    setUp(() {
      recorder = _IdleRecorder();
      document = NoteDocument(recordings: <NoteRecordingTrack>[_track()]);
      replay = StrokeReplayController();
      transcriber = _FakeTranscriber();
      controller = RecordingTranscriptionController(
        transcriber: transcriber,
        temporaryDirectory: () async => temporary,
      );
      pending = null;
    });

    tearDown(() {
      controller.dispose();
      replay.dispose();
      document.dispose();
      recorder.dispose();
    });

    Future<void> pumpPanel(
      WidgetTester tester, {
      ValueChanged<NoteRecordingTrack>? onShowTranscript,
    }) {
      return pumpApp(
        tester,
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: RecordingOptions(
              data: RecordingToolData(
                recorder: recorder,
                document: document,
                replay: replay,
                onStart: () {},
                onPause: () {},
                onResume: () {},
                onStop: () {},
                onOpen: (_) {},
                transcription: controller,
                onTranscribe: (NoteRecordingTrack track) {
                  pending = controller
                      .transcribe(track, readAudio: () async => Uint8List(8))
                      .then((RecordingTranscript transcript) {
                        document.setRecordingTranscript(track.id, transcript);
                      });
                },
                onShowTranscript: onShowTranscript ?? (_) {},
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('transcribes only when asked, showing its progress', (
      WidgetTester tester,
    ) async {
      final List<String> shown = <String>[];
      await pumpPanel(
        tester,
        onShowTranscript: (NoteRecordingTrack track) => shown.add(track.id),
      );
      // Nothing runs until the user asks.
      expect(transcriber.started.isCompleted, isFalse);

      await tester.runAsync(() async {
        await tester.tap(
          find.byKey(const ValueKey<String>('transcribe-rec-1')),
        );
        await transcriber.started.future;
      });
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('transcribing-rec-1')),
        findsOneWidget,
      );
      transcriber.progress(0.5);
      await tester.pump();
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byKey(const ValueKey<String>('transcribing-rec-1')),
            )
            .value,
        0.5,
      );

      await tester.runAsync(() async {
        transcriber.answer(_transcript());
        await pending;
      });
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('transcribing-rec-1')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('show-transcript-rec-1')),
      );
      expect(shown, <String>['rec-1']);
    });

    testWidgets('cannot transcribe while recording', (
      WidgetTester tester,
    ) async {
      // Paused is still mid-recording, and its pulse is still, so the
      // panel settles.
      recorder.value = NoteAudioRecorderState.paused;
      await pumpPanel(tester);
      final IconButton button = tester.widget<IconButton>(
        find.byKey(const ValueKey<String>('transcribe-rec-1')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('stop cancels a transcription', (WidgetTester tester) async {
      await pumpPanel(tester);
      await tester.runAsync(() async {
        await tester.tap(
          find.byKey(const ValueKey<String>('transcribe-rec-1')),
        );
        await transcriber.started.future;
      });
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('stop-transcribing-rec-1')),
      );
      await tester.runAsync(() async {
        await pending?.catchError((Object _) {});
      });
      await tester.pump();
      expect(transcriber.cancelled, <String>['rec-1']);
      expect(document.recordings.single.transcript, isNull);
      expect(
        find.byKey(const ValueKey<String>('transcribe-rec-1')),
        findsOneWidget,
      );
    });
  });

  testWidgets('a timed transcript line plays the recording from there', (
    WidgetTester tester,
  ) async {
    final List<Duration> seeks = <Duration>[];
    await pumpApp(
      tester,
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showRecordingTranscript(
                context,
                track: _track(transcript: _transcript()),
                onSeek: seeks.add,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Today we cover entropy.'), findsOneWidget);
    expect(find.text('01:05'), findsOneWidget);

    await tester.tap(find.text('It always increases.'));
    await tester.pumpAndSettle();
    expect(seeks, <Duration>[const Duration(milliseconds: 65000)]);
    expect(find.text('It always increases.'), findsNothing);
  });
}
