import 'package:flutter/foundation.dart';

@immutable
class NoteRecordingTrack {
  const NoteRecordingTrack({
    required this.id,
    required this.title,
    required this.assetPath,
    required this.durationMs,
    required this.createdAt,
    this.transcript,
  });

  final String id;
  final String title;

  /// The first-class note asset id holding the M4A file.
  final String assetPath;
  final int durationMs;
  final DateTime createdAt;

  /// What was said, once the user has asked for it. Never made while
  /// recording.
  final RecordingTranscript? transcript;

  NoteRecordingTrack withTranscript(RecordingTranscript? transcript) {
    return NoteRecordingTrack(
      id: id,
      title: title,
      assetPath: assetPath,
      durationMs: durationMs,
      createdAt: createdAt,
      transcript: transcript,
    );
  }

  static NoteRecordingTrack? fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final Object? id = raw['id'];
    final Object? title = raw['title'];
    final Object? assetPath = raw['assetPath'];
    final Object? duration = raw['durationMs'];
    final DateTime? createdAt = DateTime.tryParse(
      raw['createdAt'] as String? ?? '',
    );
    if (id is! String ||
        id.isEmpty ||
        title is! String ||
        assetPath is! String ||
        assetPath.isEmpty ||
        duration is! int ||
        duration < 0 ||
        createdAt == null) {
      return null;
    }
    return NoteRecordingTrack(
      id: id,
      title: title,
      assetPath: assetPath,
      durationMs: duration,
      createdAt: createdAt.toUtc(),
      transcript: RecordingTranscript.fromJson(raw['transcript']),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'assetPath': assetPath,
    'durationMs': durationMs,
    'createdAt': createdAt.toUtc().toIso8601String(),
    if (transcript != null) 'transcript': transcript!.toJson(),
  };
}

/// One stretch of speech in a transcript, and where in the recording it
/// starts, when the recognizer said.
@immutable
class TranscriptSegment {
  const TranscriptSegment(this.text, {this.startMs});

  final String text;
  final int? startMs;

  static TranscriptSegment? fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final Object? text = raw['text'];
    final Object? start = raw['startMs'];
    if (text is! String || text.trim().isEmpty) return null;
    return TranscriptSegment(
      text,
      startMs: start is int && start >= 0 ? start : null,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'text': text,
    'startMs': ?startMs,
  };
}

/// A recording's speech as text, made on the device.
@immutable
class RecordingTranscript {
  RecordingTranscript({
    required List<TranscriptSegment> segments,
    required this.createdAt,
    this.locale,
  }) : segments = List<TranscriptSegment>.unmodifiable(segments);

  final List<TranscriptSegment> segments;
  final DateTime createdAt;

  /// The language it was heard in, such as `en-US`.
  final String? locale;

  String get text =>
      segments.map((TranscriptSegment segment) => segment.text.trim()).join(' ');

  bool get isEmpty => segments.isEmpty;

  static RecordingTranscript? fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final DateTime? createdAt = DateTime.tryParse(
      raw['createdAt'] as String? ?? '',
    );
    final Object? segments = raw['segments'];
    final Object? locale = raw['locale'];
    if (createdAt == null || segments is! List<Object?>) return null;
    return RecordingTranscript(
      segments: <TranscriptSegment>[
        for (final Object? segment in segments)
          ?TranscriptSegment.fromJson(segment),
      ],
      createdAt: createdAt.toUtc(),
      locale: locale is String && locale.isNotEmpty ? locale : null,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'segments': <Object?>[
      for (final TranscriptSegment segment in segments) segment.toJson(),
    ],
    'createdAt': createdAt.toUtc().toIso8601String(),
    'locale': ?locale,
  };
}
