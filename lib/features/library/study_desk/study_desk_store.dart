import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../file_note_repository.dart';
import '../note_repository.dart';
import 'study_desk_models.dart';

/// Where the desk's sources and chats are kept between launches.
abstract interface class StudyDeskStore {
  /// What was last written; null when nothing was, or it cannot be read.
  Future<StudyDeskState?> read();
  Future<void> write(StudyDeskState state);
}

/// Keeps the desk for as long as the app runs, for a library in memory.
class InMemoryStudyDeskStore implements StudyDeskStore {
  StudyDeskState? _state;

  @override
  Future<StudyDeskState?> read() async => _state;

  @override
  Future<void> write(StudyDeskState state) async => _state = state;
}

/// Keeps the desk in `<libraryDir>/study_desk.json`. Written to a temporary
/// file and renamed over the old one, so a crash leaves one or the other whole.
class FileStudyDeskStore implements StudyDeskStore {
  FileStudyDeskStore(this.file);

  final File file;
  Future<void> _writes = Future<void>.value();

  @override
  Future<StudyDeskState?> read() async {
    try {
      if (!await file.exists()) return null;
      final Object? json = jsonDecode(await file.readAsString());
      return json is Map<String, Object?>
          ? StudyDeskState.fromJson(json)
          : null;
    } on Object {
      // A damaged desk costs the chats, never the notes: it starts over.
      return null;
    }
  }

  @override
  Future<void> write(StudyDeskState state) {
    final String encoded = jsonEncode(state.toJson());
    return _writes = _writes.catchError((Object _) {}).then((void _) async {
      final File temporary = File('${file.path}.tmp');
      await temporary.writeAsString(encoded, flush: true);
      await temporary.rename(file.path);
    });
  }
}

/// Where the desk of [repository] is kept: beside the device's library, or in
/// memory for any other.
StudyDeskStore studyDeskStoreFor(NoteRepository repository) =>
    switch (repository) {
      final FileNoteRepository files => FileStudyDeskStore(
        File('${files.directory.path}/study_desk.json'),
      ),
      _ => InMemoryStudyDeskStore(),
    };

/// Keeps worked-out chunks on disk between launches. A cache only: whatever
/// goes wrong here means a note is read again.
abstract interface class StudyChunkDiskCache {
  Future<List<StudyChunk>?> read(String noteId, int revision);
  Future<void> write(String noteId, int revision, List<StudyChunk> chunks);

  /// Lets go of every note but [noteIds].
  Future<void> retain(Set<String> noteIds);
}

/// One file per note, under `<libraryDir>/study_index/`.
class FileStudyChunkCache implements StudyChunkDiskCache {
  FileStudyChunkCache(this.directory);

  final Directory directory;

  /// Moves on whenever the chunks of the same revision would come out
  /// differently, so that older ones are not used.
  static const int version = 2;

  File _file(String noteId) => File('${directory.path}/$noteId.json');

  @override
  Future<List<StudyChunk>?> read(String noteId, int revision) async {
    try {
      final File file = _file(noteId);
      if (!await file.exists()) return null;
      final String encoded = await file.readAsString();
      final Map<String, Object?> json = encoded.length >= _offMainCharacters
          ? await compute(_decode, encoded, debugLabel: 'study.readChunks')
          : _decode(encoded);
      if (json['version'] != version || json['revision'] != revision) {
        return null;
      }
      return <StudyChunk>[
        for (final Object? chunk in json['chunks']! as List)
          StudyChunk.fromJson(chunk! as Map<String, Object?>),
      ];
    } on Object {
      return null;
    }
  }

  static const int _offMainCharacters = 8 * 1024;

  static Map<String, Object?> _decode(String encoded) =>
      jsonDecode(encoded) as Map<String, Object?>;

  @override
  Future<void> write(
    String noteId,
    int revision,
    List<StudyChunk> chunks,
  ) async {
    try {
      await directory.create(recursive: true);
      final File file = _file(noteId);
      final File temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode(<String, Object?>{
          'version': version,
          'revision': revision,
          'chunks': <Object?>[
            for (final StudyChunk chunk in chunks) chunk.toJson(),
          ],
        }),
      );
      await temporary.rename(file.path);
    } on Object {
      // Worked out again next time.
    }
  }

  @override
  Future<void> retain(Set<String> noteIds) async {
    try {
      if (!await directory.exists()) return;
      await for (final FileSystemEntity entity in directory.list()) {
        final String name = entity.uri.pathSegments.last;
        if (entity is! File || !name.endsWith('.json')) continue;
        final String id = name.substring(0, name.length - '.json'.length);
        if (!noteIds.contains(id)) await entity.delete();
      }
    } on Object {
      // Tried again on the next launch.
    }
  }
}

/// The chunk cache of [repository], or null for a library with no disk.
StudyChunkDiskCache? studyChunkCacheFor(NoteRepository repository) =>
    switch (repository) {
      final FileNoteRepository files => FileStudyChunkCache(
        Directory('${files.directory.path}/study_index'),
      ),
      _ => null,
    };
