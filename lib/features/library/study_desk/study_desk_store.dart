import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../file_note_repository.dart';
import '../note_repository.dart';
import 'study_desk_models.dart';
import 'study_vectors.dart';

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
  late final _SnapshotWriter<StudyDeskState> _writer = _SnapshotWriter(
    _writeSnapshot,
  );

  @override
  Future<StudyDeskState?> read() async {
    try {
      if (!await file.exists()) return null;
      final String encoded = await file.readAsString();
      return encoded.length >= _offMainCharacters
          ? await compute(_decodeDesk, encoded, debugLabel: 'study.readDesk')
          : _decodeDesk(encoded);
    } on Object {
      // A damaged desk costs the chats, never the notes: it starts over.
      return null;
    }
  }

  @override
  Future<void> write(StudyDeskState state) => _writer.write(state);

  Future<void> _writeSnapshot(StudyDeskState state) async {
    // Estimate directly from the immutable models: toJson itself allocates a
    // full object graph, so that conversion belongs in the worker too.
    int size = state.sources.length * 64 + state.courses.length * 256;
    for (final session in state.sessions) {
      size += 256 + (session.sources?.length ?? 0) * 64;
      for (final message in session.messages) {
        size += 128 + message.text.length;
        for (final link in message.links) {
          for (final citation in link.citations) {
            size +=
                128 +
                citation.strokeKeys.length * 64 +
                citation.strokeIndices.length * 8 +
                citation.rings.length * 64;
          }
        }
        if (size >= _offMainCharacters) break;
      }
      if (size >= _offMainCharacters) break;
    }
    final String encoded = size >= _offMainCharacters
        ? await compute(_encodeDesk, state, debugLabel: 'study.writeDesk')
        : _encodeDesk(state);
    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsString(encoded, flush: true);
    await temporary.rename(file.path);
  }
}

const int _offMainCharacters = 8 * 1024;

StudyDeskState? _decodeDesk(String encoded) {
  final Object? json = jsonDecode(encoded);
  return json is Map<String, Object?> ? StudyDeskState.fromJson(json) : null;
}

String _encodeDesk(StudyDeskState state) => jsonEncode(state.toJson());

// Full snapshots supersede each other. Keep one active write and only the
// newest pending snapshot, so bursts cannot retain a queue of encoded history.
// Every caller completes after the latest snapshot in its batch is durable.
class _SnapshotWriter<T extends Object> {
  _SnapshotWriter(this.persist);

  final Future<void> Function(T) persist;
  T? _pending;
  Future<void>? _writing;

  bool get isIdle => _writing == null;
  Future<void> get settled => _writing ?? Future<void>.value();

  Future<void> write(T snapshot) {
    _pending = snapshot;
    if (_writing case final Future<void> writing) return writing;
    final done = Completer<void>();
    _writing = done.future;
    unawaited(_drain(done));
    return done.future;
  }

  Future<void> _drain(Completer<void> done) async {
    try {
      while (_pending != null) {
        final T snapshot = _pending!;
        _pending = null;
        await persist(snapshot);
      }
      _writing = null;
      done.complete();
    } on Object catch (error, stack) {
      _pending = null;
      _writing = null;
      done.completeError(error, stack);
    }
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
  final Map<String, _SnapshotWriter<(int, List<StudyChunk>)>> _writers = {};

  /// Moves on whenever the chunks of the same revision would come out
  /// differently, so that older ones are not used.
  static const int version = 3;

  File _file(String noteId) => File('${directory.path}/$noteId.json');

  @override
  Future<List<StudyChunk>?> read(String noteId, int revision) async {
    try {
      final File file = _file(noteId);
      if (!await file.exists()) return null;
      final String encoded = await file.readAsString();
      return encoded.length >= _offMainCharacters
          ? await compute(_decodeChunks, (
              encoded,
              revision,
            ), debugLabel: 'study.readChunks')
          : _decodeChunks((encoded, revision));
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(
    String noteId,
    int revision,
    List<StudyChunk> chunks,
  ) async {
    final writer = _writers.putIfAbsent(
      noteId,
      () => _SnapshotWriter((snapshot) => _writeSnapshot(noteId, snapshot)),
    );
    try {
      await writer.write((revision, chunks));
    } on Object {
      // Worked out again next time.
    } finally {
      if (writer.isIdle && identical(_writers[noteId], writer)) {
        _writers.remove(noteId);
      }
    }
  }

  Future<void> _writeSnapshot(
    String noteId,
    (int, List<StudyChunk>) snapshot,
  ) async {
    final String encoded =
        estimatedStudyChunkBytes(snapshot.$2) >= _offMainCharacters
        ? await compute(
            _encodeChunks,
            snapshot,
            debugLabel: 'study.writeChunks',
          )
        : _encodeChunks(snapshot);
    await directory.create(recursive: true);
    final File file = _file(noteId);
    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsString(encoded);
    await temporary.rename(file.path);
  }

  @override
  Future<void> retain(Set<String> noteIds) async {
    try {
      // An already active rename must finish before pruning its destination.
      // The index invalidates builds before calling retain, preventing their
      // later completion from scheduling another write for a removed note.
      final removed = [
        for (final entry in _writers.entries)
          if (!noteIds.contains(entry.key)) entry.value,
      ];
      for (final writer in removed) {
        await writer.settled;
      }
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

List<StudyChunk>? _decodeChunks((String, int) input) {
  final json = jsonDecode(input.$1) as Map<String, Object?>;
  if (json['version'] != FileStudyChunkCache.version ||
      json['revision'] != input.$2) {
    return null;
  }
  return [
    for (final chunk in json['chunks']! as List)
      StudyChunk.fromJson(chunk! as Map<String, Object?>),
  ];
}

String _encodeChunks((int, List<StudyChunk>) snapshot) => jsonEncode({
  'version': FileStudyChunkCache.version,
  'revision': snapshot.$1,
  'chunks': [for (final chunk in snapshot.$2) chunk.toJson()],
});

// A conservative accounting estimate, not an exact VM heap measurement. Include
// strings, list slots, lines and stroke references without allocating JSON.
int estimatedStudyChunkBytes(List<StudyChunk> chunks) {
  int bytes = 64;
  for (final chunk in chunks) {
    bytes +=
        256 +
        chunk.noteId.length * 2 +
        chunk.strokeIndices.length * 8 +
        (chunk.sourceSection?.title.length ?? 0) * 2;
    bytes +=
        128 +
        2 *
            (chunk.handwriting.length +
                chunk.alternatives.length +
                chunk.typed.length +
                chunk.svgText.length);
    for (final strings in [
      chunk.stickyIds,
      chunk.imageIds,
      chunk.anchors,
      chunk.tags,
    ]) {
      for (final text in strings) {
        bytes += 40 + text.length * 2;
      }
    }
    for (final line in chunk.lines) {
      bytes += 64 + line.text.length * 2;
    }
  }
  return bytes;
}

/// The chunk cache of [repository], or null for a library with no disk.
StudyChunkDiskCache? studyChunkCacheFor(NoteRepository repository) =>
    switch (repository) {
      final FileNoteRepository files => FileStudyChunkCache(
        Directory('${files.directory.path}/study_index'),
      ),
      _ => null,
    };

/// The vectors cache of [repository], or null for a library with no disk.
StudyVectorDiskCache? studyVectorCacheFor(NoteRepository repository) =>
    switch (repository) {
      final FileNoteRepository files => FileStudyVectorCache(
        Directory('${files.directory.path}/study_vectors'),
      ),
      _ => null,
    };
