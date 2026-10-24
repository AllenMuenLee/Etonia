import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart' as record;

enum NoteAudioRecorderState { idle, recording, paused, stopping }

@immutable
class RecordedNoteAudio {
  const RecordedNoteAudio({
    required this.id,
    required this.path,
    required this.duration,
    required this.createdAt,
  });

  final String id;
  final String path;
  final Duration duration;
  final DateTime createdAt;
}

/// Injectable microphone boundary used by the editor and its tests.
abstract class NoteAudioRecorder extends ChangeNotifier {
  NoteAudioRecorderState get state;
  String? get activeRecordingId;
  int get currentElapsedMs;
  bool get isRecording => state == NoteAudioRecorderState.recording;
  bool get isPaused => state == NoteAudioRecorderState.paused;

  Future<bool> start();
  Future<void> pause();
  Future<void> resume();
  Future<RecordedNoteAudio?> stop();
}

/// Records voice as 64 kbps mono AAC in an MPEG-4 container.
class PlatformNoteAudioRecorder extends NoteAudioRecorder {
  PlatformNoteAudioRecorder({record.AudioRecorder? recorder})
    : this._(recorder);

  PlatformNoteAudioRecorder._(this._recorder);

  record.AudioRecorder? _recorder;
  record.AudioRecorder get _platformRecorder =>
      _recorder ??= record.AudioRecorder();
  final Stopwatch _elapsed = Stopwatch();
  Timer? _ticker;
  NoteAudioRecorderState _state = NoteAudioRecorderState.idle;
  String? _id;
  String? _path;
  DateTime? _createdAt;

  @override
  NoteAudioRecorderState get state => _state;

  @override
  String? get activeRecordingId => _id;

  @override
  int get currentElapsedMs => _elapsed.elapsedMilliseconds;

  @override
  Future<bool> start() async {
    if (_state != NoteAudioRecorderState.idle) return false;
    final record.AudioRecorder recorder = _platformRecorder;
    if (!await recorder.hasPermission()) return false;
    final Directory root = Directory(
      '${(await getTemporaryDirectory()).path}/greatnote-recordings',
    );
    await root.create(recursive: true);
    final DateTime now = DateTime.now().toUtc();
    final String id = 'rec-${now.microsecondsSinceEpoch.toRadixString(36)}';
    final String path = '${root.path}/$id.m4a';
    await recorder.start(
      const record.RecordConfig(
        encoder: record.AudioEncoder.aacLc,
        bitRate: 64000,
        sampleRate: 44100,
        numChannels: 1,
        autoGain: true,
        echoCancel: true,
        noiseSuppress: true,
      ),
      path: path,
    );
    _id = id;
    _path = path;
    _createdAt = now;
    _elapsed
      ..reset()
      ..start();
    _state = NoteAudioRecorderState.recording;
    _startTicker();
    notifyListeners();
    return true;
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_state == NoteAudioRecorderState.recording) notifyListeners();
    });
  }

  @override
  Future<void> pause() async {
    if (_state != NoteAudioRecorderState.recording) return;
    await _platformRecorder.pause();
    _elapsed.stop();
    _state = NoteAudioRecorderState.paused;
    notifyListeners();
  }

  @override
  Future<void> resume() async {
    if (_state != NoteAudioRecorderState.paused) return;
    await _platformRecorder.resume();
    _elapsed.start();
    _state = NoteAudioRecorderState.recording;
    notifyListeners();
  }

  @override
  Future<RecordedNoteAudio?> stop() async {
    if (_state == NoteAudioRecorderState.idle ||
        _state == NoteAudioRecorderState.stopping) {
      return null;
    }
    _state = NoteAudioRecorderState.stopping;
    _elapsed.stop();
    _ticker?.cancel();
    notifyListeners();
    final String? actualPath = await _platformRecorder.stop();
    final String? id = _id;
    final String? path = actualPath ?? _path;
    final DateTime? createdAt = _createdAt;
    final Duration duration = _elapsed.elapsed;
    _id = null;
    _path = null;
    _createdAt = null;
    _elapsed.reset();
    _state = NoteAudioRecorderState.idle;
    notifyListeners();
    if (id == null || path == null || createdAt == null) return null;
    return RecordedNoteAudio(
      id: id,
      path: path,
      duration: duration,
      createdAt: createdAt,
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    final record.AudioRecorder? recorder = _recorder;
    if (recorder != null) unawaited(recorder.dispose());
    super.dispose();
  }
}

/// Injectable local playback boundary with millisecond position updates.
abstract class NoteAudioPlayer extends ChangeNotifier {
  Duration get position;
  Duration get duration;
  bool get isPlaying;
  double get speed;

  Future<void> loadBytes(String recordingId, Uint8List bytes);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setSpeed(double speed);
  Future<void> stop();
}

class PlatformNoteAudioPlayer extends NoteAudioPlayer {
  PlatformNoteAudioPlayer({just_audio.AudioPlayer? player}) : _created = player;

  /// The platform player is made on first use, so a note that is never
  /// replayed never opens one.
  final just_audio.AudioPlayer? _created;
  late final just_audio.AudioPlayer _player = _open();
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];
  bool _opened = false;
  File? _materialized;

  just_audio.AudioPlayer _open() {
    _opened = true;
    final just_audio.AudioPlayer player = _created ?? just_audio.AudioPlayer();
    _subscriptions.addAll(<StreamSubscription<Object?>>[
      player.positionStream.listen((Duration _) => notifyListeners()),
      player.durationStream.listen((Duration? _) => notifyListeners()),
      player.playerStateStream.listen((just_audio.PlayerState _) {
        notifyListeners();
      }),
      player.speedStream.listen((double _) => notifyListeners()),
    ]);
    return player;
  }

  @override
  Duration get position => _opened ? _player.position : Duration.zero;
  @override
  Duration get duration =>
      _opened ? _player.duration ?? Duration.zero : Duration.zero;
  @override
  bool get isPlaying => _opened && _player.playing;
  @override
  double get speed => _opened ? _player.speed : 1;

  @override
  Future<void> loadBytes(String recordingId, Uint8List bytes) async {
    await _player.stop();
    final File? before = _materialized;
    final Directory root = Directory(
      '${(await getTemporaryDirectory()).path}/greatnote-playback',
    );
    await root.create(recursive: true);
    final File file = File('${root.path}/$recordingId.m4a');
    await file.writeAsBytes(bytes, flush: true);
    _materialized = file;
    if (before != null && before.path != file.path && await before.exists()) {
      await before.delete();
    }
    await _player.setFilePath(file.path);
    notifyListeners();
  }

  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() async {
    if (_opened) await _player.pause();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);
  @override
  Future<void> stop() async {
    if (_opened) await _player.stop();
  }

  @override
  void dispose() {
    for (final StreamSubscription<Object?> subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    if (_opened) unawaited(_player.dispose());
    final File? file = _materialized;
    if (file != null) {
      unawaited(() async {
        try {
          await file.delete();
        } on FileSystemException {
          // A temporary playback file may already have been reclaimed.
        }
      }());
    }
    super.dispose();
  }
}
