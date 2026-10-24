import 'package:flutter/foundation.dart';

@immutable
class NoteRecordingTrack {
  const NoteRecordingTrack({
    required this.id,
    required this.title,
    required this.assetPath,
    required this.durationMs,
    required this.createdAt,
  });

  final String id;
  final String title;

  /// The first-class note asset id holding the M4A file.
  final String assetPath;
  final int durationMs;
  final DateTime createdAt;

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
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'assetPath': assetPath,
    'durationMs': durationMs,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };
}
