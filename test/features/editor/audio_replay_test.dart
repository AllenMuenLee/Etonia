import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/features/editor/audio/note_audio.dart';
import 'package:greatnote/features/editor/audio/stroke_replay_controller.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/ink_selection.dart';
import 'package:greatnote/features/editor/ink/pen_settings.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/page/note_document.dart';
import 'package:greatnote/features/editor/widgets/editor_app_bar.dart';
import 'package:greatnote/features/editor/widgets/recording_options.dart';
import 'package:greatnote/features/editor/widgets/tool_palette.dart';
import 'package:greatnote/features/library/note_recording_track.dart';

import '../../helpers/pump_app.dart';

RawInkSample _sample(double x, int milliseconds) => RawInkSample(
  position: InkVector(x, 20),
  timestamp: Duration(milliseconds: milliseconds),
);

class _FakeRecorder extends NoteAudioRecorder {
  NoteAudioRecorderState _state = NoteAudioRecorderState.idle;
  int elapsed = 0;

  @override
  String? get activeRecordingId =>
      _state == NoteAudioRecorderState.idle ? null : 'rec-1';
  @override
  int get currentElapsedMs => elapsed;
  @override
  NoteAudioRecorderState get state => _state;

  @override
  Future<bool> start() async {
    _state = NoteAudioRecorderState.recording;
    notifyListeners();
    return true;
  }

  @override
  Future<void> pause() async {
    _state = NoteAudioRecorderState.paused;
    notifyListeners();
  }

  @override
  Future<void> resume() async {
    _state = NoteAudioRecorderState.recording;
    notifyListeners();
  }

  @override
  Future<RecordedNoteAudio?> stop() async {
    _state = NoteAudioRecorderState.idle;
    notifyListeners();
    return null;
  }
}

class _FakePlayer extends NoteAudioPlayer {
  Duration _position = Duration.zero;
  final Duration _duration = const Duration(seconds: 10);
  bool _playing = false;
  double _speed = 1;

  @override
  Duration get duration => _duration;
  @override
  bool get isPlaying => _playing;
  @override
  Duration get position => _position;
  @override
  double get speed => _speed;

  @override
  Future<void> loadBytes(String recordingId, Uint8List bytes) async {}
  @override
  Future<void> pause() async {
    _playing = false;
    notifyListeners();
  }

  @override
  Future<void> play() async {
    _playing = true;
    notifyListeners();
  }

  @override
  Future<void> seek(Duration position) async {
    _position = position;
    notifyListeners();
  }

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    _playing = false;
    notifyListeners();
  }
}

void main() {
  test('audio chrome meets high contrast in light and dark themes', () {
    for (final AppColors colors in <AppColors>[
      AppColors.light,
      AppColors.dark,
    ]) {
      expect(
        contrastRatio(colors.recordingForeground, colors.recordingSurface),
        greaterThanOrEqualTo(7),
      );
      expect(
        contrastRatio(colors.accent, colors.recordingSurface),
        greaterThanOrEqualTo(3),
      );
    }
  });

  test('completed strokes and erasures use the active audio clock', () {
    final InkController ink = InkController();
    addTearDown(ink.dispose);
    InkRecordingContext? timeline = const InkRecordingContext(
      recordingId: 'rec-1',
      elapsedMs: 1250,
    );
    ink.recordingContext = () => timeline;
    expect(
      ink.startStroke(
        pointer: 1,
        sample: _sample(10, 0),
        style: const StrokeStyle(ink: InkPalette.ink, width: 3),
      ),
      isTrue,
    );
    ink.endStroke(1, <RawInkSample>[_sample(60, 250)]);
    final Stroke timed = ink.strokes.single;
    expect(timed.completedAtMs, 1250);
    expect(timed.recordingId, 'rec-1');
    expect(timed.sampleDeltasMs, isNotEmpty);

    timeline = const InkRecordingContext(recordingId: 'rec-1', elapsedMs: 1800);
    ink.startErase(
      pointer: 2,
      position: const InkVector(30, 20),
      settings: const EraserSettings(mode: EraserMode.stroke, size: 24),
    );
    ink.endErase(2);
    expect(ink.strokes, isEmpty);
    expect(ink.erasedStrokeRecords.single.stroke, same(timed));
    expect(ink.erasedStrokeRecords.single.erasedAtMs, 1800);

    timeline = null;
    ink.startStroke(
      pointer: 3,
      sample: _sample(10, 0),
      style: const StrokeStyle(ink: InkPalette.ink, width: 3),
    );
    ink.endStroke(3, <RawInkSample>[_sample(20, 20)]);
    expect(ink.strokes.single.completedAtMs, isNull);
  });

  test('replay reconstructs forward and backward visual state', () {
    final Stroke stroke = Stroke.fromPoints(
      style: const StrokeStyle(ink: InkPalette.ink, width: 3),
      points: const <InkVector>[InkVector(0, 0), InkVector(10, 0)],
      recordingId: 'rec-1',
      completedAtMs: 1000,
      sampleDeltasMs: const <int>[0, 400],
    );
    final StrokeReplayController replay = StrokeReplayController();
    addTearDown(replay.dispose);
    replay.open(
      NoteRecordingTrack(
        id: 'rec-1',
        title: 'Lecture',
        assetPath: 'asset-1',
        durationMs: 2000,
        createdAt: DateTime.utc(2026, 10, 23),
      ),
    );
    replay.updatePosition(const Duration(milliseconds: 500));
    expect(replay.revealProgress(stroke), 0);
    expect(replay.isUnwritten(stroke), isTrue);
    replay.updatePosition(const Duration(milliseconds: 800));
    expect(replay.revealProgress(stroke), closeTo(0.5, 0.001));
    replay.updatePosition(const Duration(milliseconds: 1200));
    expect(replay.isUnwritten(stroke), isFalse);
    replay.updatePosition(const Duration(milliseconds: 700));
    expect(replay.revealProgress(stroke), closeTo(0.25, 0.001));
  });

  test('tap hit testing chooses the topmost nearby stroke', () {
    final Stroke bottom = Stroke.fromPoints(
      style: const StrokeStyle(ink: InkPalette.ink, width: 2),
      points: const <InkVector>[InkVector(0, 0), InkVector(100, 0)],
    );
    final Stroke top = Stroke.fromPoints(
      style: const StrokeStyle(ink: InkPalette.ink, width: 2),
      points: const <InkVector>[InkVector(0, 4), InkVector(100, 4)],
    );
    expect(
      hitTestStroke(<Stroke>[bottom, top], const InkVector(50, 2)),
      same(top),
    );
    expect(
      hitTestStroke(
        <Stroke>[bottom, top],
        const InkVector(50, 30),
        tolerance: 4,
      ),
      isNull,
    );
  });

  testWidgets('recording controls live in the tool palette', (
    WidgetTester tester,
  ) async {
    final _FakeRecorder recorder = _FakeRecorder();
    final _FakePlayer player = _FakePlayer();
    addTearDown(recorder.dispose);
    addTearDown(player.dispose);
    await pumpApp(
      tester,
      home: EditorScreen(
        title: 'Recorded note',
        audioRecorder: recorder,
        audioPlayer: player,
        enableNativeInk: false,
      ),
    );

    await tester.tap(find.byTooltip('Expand toolbar'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Recordings'));
    await tester.pumpAndSettle();

    final Finder microphone = find.byKey(
      const ValueKey<String>('start-audio-recording'),
    );
    expect(
      find.descendant(of: find.byType(EditorAppBar), matching: microphone),
      findsNothing,
    );
    expect(find.byKey(const ValueKey<String>('no-recordings')), findsOneWidget);

    await tester.tap(microphone);
    // The panel goes as the recording starts. Not settled: the recording's
    // pulse never stops, so it is pumped past the panel's closing instead.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.byKey(const ValueKey<String>('recording-elapsed')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('pause-resume-recording')),
    );
    await tester.pump();
    expect(recorder.state, NoteAudioRecorderState.paused);
    await tester.tap(
      find.byKey(const ValueKey<String>('pause-resume-recording')),
    );
    await tester.pump();
    expect(recorder.state, NoteAudioRecorderState.recording);
    await tester.tap(
      find.byKey(const ValueKey<String>('stop-audio-recording')),
    );
    await tester.pump();
    expect(recorder.state, NoteAudioRecorderState.idle);
  });

  testWidgets('pressing Record again stops the recording', (
    WidgetTester tester,
  ) async {
    final _FakeRecorder recorder = _FakeRecorder();
    final _FakePlayer player = _FakePlayer();
    addTearDown(recorder.dispose);
    addTearDown(player.dispose);
    await pumpApp(
      tester,
      home: EditorScreen(
        title: 'Recorded note',
        audioRecorder: recorder,
        audioPlayer: player,
        enableNativeInk: false,
      ),
    );

    await tester.tap(find.byTooltip('Expand toolbar'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Recordings'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('start-audio-recording')),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(recorder.state, NoteAudioRecorderState.recording);
    // The panel is put away; the sub toolbar holds the recording's controls.
    expect(
      find.byKey(const ValueKey<String>('start-audio-recording')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey<String>('recording-bar')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('recording-tool')));
    await tester.pump(const Duration(seconds: 1));
    expect(recorder.state, NoteAudioRecorderState.idle);
    expect(find.byKey(const ValueKey<String>('recording-bar')), findsNothing);
  });

  testWidgets('the replay bar takes the place of the tool options', (
    WidgetTester tester,
  ) async {
    final _FakeRecorder recorder = _FakeRecorder();
    final _FakePlayer player = _FakePlayer();
    final StrokeReplayController replay = StrokeReplayController()
      ..open(
        NoteRecordingTrack(
          id: 'rec-1',
          title: 'Lecture',
          assetPath: 'asset-1',
          durationMs: 10000,
          createdAt: DateTime.utc(2026, 10, 23),
        ),
      );
    addTearDown(recorder.dispose);
    addTearDown(player.dispose);
    addTearDown(replay.dispose);
    final NoteDocument document = NoteDocument();
    addTearDown(document.dispose);
    final ValueNotifier<EditorTool> tool = ValueNotifier<EditorTool>(
      EditorTool.pen,
    );
    final ValueNotifier<PenSettings> pen = ValueNotifier<PenSettings>(
      PenSettings.defaults(),
    );
    final ValueNotifier<EraserSettings> eraser = ValueNotifier<EraserSettings>(
      EraserSettings.defaults(const EraserConfig()),
    );
    final ValueNotifier<bool> aiActive = ValueNotifier<bool>(false);
    addTearDown(tool.dispose);
    addTearDown(pen.dispose);
    addTearDown(eraser.dispose);
    addTearDown(aiActive.dispose);
    await pumpApp(
      tester,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: ToolPalette(
            tool: tool,
            penSettings: pen,
            eraserSettings: eraser,
            selectPdf: ValueNotifier<bool>(false),
            aiActive: aiActive,
            onTurnOnAi: () {},
            recording: RecordingToolData(
              recorder: recorder,
              document: document,
              replay: replay,
              player: player,
              onCloseReplay: replay.close,
              onStart: () {},
              onPause: () {},
              onResume: () {},
              onStop: () {},
              onOpen: (_) {},
            ),
          ),
        ),
      ),
    );

    final Finder bar = find.byKey(const ValueKey<String>('audio-replay-bar'));
    expect(bar, findsOneWidget);
    // The tool's own options give way to the playback bar.
    expect(find.byKey(const ValueKey<String>('pen-options-bar')), findsNothing);

    final Slider slider = tester.widget<Slider>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('audio-replay-slider')),
        matching: find.byType(Slider),
      ),
    );
    slider.onChanged!(5000);
    await tester.pump();
    expect(player.position, const Duration(seconds: 5));

    await tester.tap(find.byKey(const ValueKey<String>('audio-replay-speed')));
    await tester.pump();
    expect(player.speed, 1.25);

    await tester.tap(find.byKey(const ValueKey<String>('close-audio-replay')));
    await tester.pumpAndSettle();
    expect(bar, findsNothing);
    expect(
      find.byKey(const ValueKey<String>('pen-options-bar')),
      findsOneWidget,
    );
  });
}
