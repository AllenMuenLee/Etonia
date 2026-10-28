import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../library/note_recording_track.dart';

/// Why a recording produced no transcript.
enum TranscriptionFailureKind {
  /// This device has no speech recognizer that can read a file.
  unavailable,

  /// Speech recognition was not allowed.
  permission,

  /// The recognizer has no model for this language yet.
  language,

  /// Nothing in the recording was heard as speech.
  noSpeech,

  /// The user stopped it.
  cancelled,

  /// Anything else.
  failed,
}

class TranscriptionFailure implements Exception {
  const TranscriptionFailure(this.kind);

  final TranscriptionFailureKind kind;

  /// What the user is told.
  String get message {
    return switch (kind) {
      TranscriptionFailureKind.unavailable =>
        'On-device transcription is not available on this device.',
      TranscriptionFailureKind.permission =>
        'Transcription needs speech recognition access in Settings.',
      TranscriptionFailureKind.language =>
        "This language's speech model isn't on the device yet. It may be "
            'downloading; try again later.',
      TranscriptionFailureKind.noSpeech => 'No speech was heard.',
      TranscriptionFailureKind.cancelled => 'Transcription stopped.',
      TranscriptionFailureKind.failed => "Couldn't transcribe the recording.",
    };
  }

  @override
  String toString() => 'TranscriptionFailure(${kind.name})';
}

/// Turns a saved recording into text with the platform's own speech
/// recognizer, on the device.
///
/// It only ever reads a finished file, and only when asked: nothing listens
/// while a note is being written.
abstract class RecordingTranscriber {
  /// Throws [TranscriptionFailure]. [onProgress] is told, from 0 to 1, how
  /// far through the audio the recognizer is.
  Future<RecordingTranscript> transcribe({
    required String recordingId,
    required String audioPath,
    required int durationMs,
    ValueChanged<double>? onProgress,
  });

  Future<void> cancel(String recordingId);
}

class PlatformRecordingTranscriber implements RecordingTranscriber {
  PlatformRecordingTranscriber() {
    channel.setMethodCallHandler(_onCall);
  }

  static const MethodChannel channel = MethodChannel(
    'com.etonia.app/recording_transcriber',
  );

  /// Shared by every editor pane, as the channel is.
  static final Map<String, ValueChanged<double>> _progress =
      <String, ValueChanged<double>>{};

  static Future<Object?> _onCall(MethodCall call) async {
    if (call.method != 'onProgress') return null;
    final Object? arguments = call.arguments;
    if (arguments is! Map<Object?, Object?>) return null;
    final Object? id = arguments['id'];
    final Object? fraction = arguments['fraction'];
    if (id is String && fraction is num) {
      _progress[id]?.call(fraction.toDouble().clamp(0.0, 1.0));
    }
    return null;
  }

  @override
  Future<RecordingTranscript> transcribe({
    required String recordingId,
    required String audioPath,
    required int durationMs,
    ValueChanged<double>? onProgress,
  }) async {
    if (onProgress != null) _progress[recordingId] = onProgress;
    try {
      final Object? response = await channel.invokeMethod<Object?>(
        'transcribe',
        <String, Object?>{
          'id': recordingId,
          'path': audioPath,
          'durationMs': durationMs,
        },
      );
      return parseTranscript(response, createdAt: DateTime.now().toUtc());
    } on PlatformException catch (error) {
      throw TranscriptionFailure(failureKindOf(error.code));
    } on MissingPluginException {
      throw const TranscriptionFailure(TranscriptionFailureKind.unavailable);
    } finally {
      _progress.remove(recordingId);
    }
  }

  @override
  Future<void> cancel(String recordingId) async {
    try {
      await channel.invokeMethod<void>('cancel', <String, Object?>{
        'id': recordingId,
      });
    } on Object {
      // Nothing is running, or the platform has no transcriber.
    }
  }

  @visibleForTesting
  static TranscriptionFailureKind failureKindOf(String code) {
    return switch (code) {
      'unavailable' => TranscriptionFailureKind.unavailable,
      'permission' => TranscriptionFailureKind.permission,
      'language' => TranscriptionFailureKind.language,
      'no_speech' => TranscriptionFailureKind.noSpeech,
      'cancelled' => TranscriptionFailureKind.cancelled,
      _ => TranscriptionFailureKind.failed,
    };
  }

  /// Reads the platform's `{segments: [{text, startMs?}], locale?}`.
  @visibleForTesting
  static RecordingTranscript parseTranscript(
    Object? response, {
    required DateTime createdAt,
  }) {
    if (response is! Map<Object?, Object?> ||
        response['segments'] is! List<Object?>) {
      throw const TranscriptionFailure(TranscriptionFailureKind.failed);
    }
    final List<TranscriptSegment> segments = <TranscriptSegment>[
      for (final Object? raw in response['segments'] as List<Object?>)
        if (raw is Map<Object?, Object?> &&
            raw['text'] is String &&
            (raw['text'] as String).trim().isNotEmpty)
          TranscriptSegment(
            (raw['text'] as String).trim(),
            startMs: raw['startMs'] is num
                ? (raw['startMs'] as num).round()
                : null,
          ),
    ];
    if (segments.isEmpty) {
      throw const TranscriptionFailure(TranscriptionFailureKind.noSpeech);
    }
    final Object? locale = response['locale'];
    return RecordingTranscript(
      segments: segments,
      createdAt: createdAt,
      locale: locale is String && locale.isNotEmpty ? locale : null,
    );
  }
}

/// Which recording is being transcribed, how far along it is, and the
/// result. One at a time: a recognizer reading a long lecture is work
/// enough for a tablet.
class RecordingTranscriptionController extends ChangeNotifier {
  RecordingTranscriptionController({
    required this._transcriber,
    Future<Directory> Function()? temporaryDirectory,
  }) : _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  final RecordingTranscriber _transcriber;

  /// Where the audio is copied for the recognizer to read.
  final Future<Directory> Function() _temporaryDirectory;
  String? _activeId;
  double? _progress;
  bool _disposed = false;

  /// The recording being transcribed, if any.
  String? get activeId => _activeId;

  /// How far along [activeId] is, once the recognizer has said.
  double? get progress => _progress;

  bool get isBusy => _activeId != null;

  /// Transcribes [track], whose audio is [readAudio]. Returns its
  /// transcript; throws [TranscriptionFailure].
  Future<RecordingTranscript> transcribe(
    NoteRecordingTrack track, {
    required Future<Uint8List> Function() readAudio,
  }) async {
    if (_activeId != null) {
      throw const TranscriptionFailure(TranscriptionFailureKind.failed);
    }
    _activeId = track.id;
    _progress = null;
    notifyListeners();
    File? file;
    try {
      final Uint8List bytes = await readAudio();
      final Directory root = Directory(
        '${(await _temporaryDirectory()).path}/greatnote-transcription',
      );
      await root.create(recursive: true);
      file = File('${root.path}/${track.id}.m4a');
      await file.writeAsBytes(bytes, flush: true);
      if (_activeId != track.id) {
        throw const TranscriptionFailure(TranscriptionFailureKind.cancelled);
      }
      final RecordingTranscript transcript = await _transcriber.transcribe(
        recordingId: track.id,
        audioPath: file.path,
        durationMs: track.durationMs,
        onProgress: (double fraction) {
          if (_activeId != track.id) return;
          _progress = fraction;
          notifyListeners();
        },
      );
      if (_activeId != track.id) {
        throw const TranscriptionFailure(TranscriptionFailureKind.cancelled);
      }
      return transcript;
    } on TranscriptionFailure {
      rethrow;
    } on Object {
      throw const TranscriptionFailure(TranscriptionFailureKind.failed);
    } finally {
      if (_activeId == track.id) {
        _activeId = null;
        _progress = null;
        notifyListeners();
      }
      try {
        await file?.delete();
      } on FileSystemException {
        // A temporary copy may already have been reclaimed.
      }
    }
  }

  /// Stops the transcription running, if any.
  void cancel() {
    final String? id = _activeId;
    if (id == null) return;
    _activeId = null;
    _progress = null;
    notifyListeners();
    unawaited(_transcriber.cancel(id));
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    cancel();
    _disposed = true;
    super.dispose();
  }
}
