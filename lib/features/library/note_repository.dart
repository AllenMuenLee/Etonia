import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../editor/page/page_setup.dart';
import 'library_models.dart';
import 'note_content.dart';

enum NoteAssetKind { pdf, image, audio }

@immutable
class NoteAsset {
  const NoteAsset({
    required this.id,
    required this.kind,
    required this.extension,
    this.fileName,
  });

  final String id;
  final NoteAssetKind kind;
  final String extension;
  final String? fileName;
}

@immutable
class NoteAssetData {
  const NoteAssetData({required this.asset, required this.bytes});

  final NoteAsset asset;
  final Uint8List bytes;
}

/// Optional persistent thumbnail storage implemented by file-backed
/// repositories. Thumbnail rendering remains usable without it.
abstract interface class ThumbnailDiskStore {
  Future<Uint8List?> readThumbnail(String noteId, String key);
  Future<void> writeThumbnail(String noteId, String key, Uint8List png);
  Future<void> deleteThumbnails(String noteId);
  Future<void> retainThumbnailNotes(Set<String> noteIds);
}

/// Thrown when a library operation cannot be done as asked: a missing item,
/// an empty name, or a folder moved into itself.
class LibraryException implements Exception {
  const LibraryException(this.message);

  final String message;

  @override
  String toString() => 'LibraryException: $message';
}

/// The notes and folders on this device.
///
/// Every mutation is one call and notifies listeners once it is done.
/// Listing reads only the index; a note's pages and ink are read by
/// [loadNote].
abstract class NoteRepository extends ChangeNotifier {
  /// The folders and notes directly in [folderId], or at the top level for
  /// null, unsorted.
  Future<FolderListing> list(String? folderId);

  /// Every folder, for choosing where to move something.
  Future<List<Folder>> allFolders();

  /// Every note in every folder, not counting Recently Deleted.
  Future<List<NoteEntry>> allNotes();

  /// How many folders and notes each folder holds directly, by folder id.
  Future<Map<String, int>> itemCounts();

  /// The folders from the top level down to [folderId], inclusive. Empty
  /// for the top level.
  Future<List<Folder>> pathTo(String? folderId);

  /// Notes and folders whose names contain [query], ignoring case, in any
  /// folder.
  Future<FolderListing> search(String query);

  /// [id] keeps the id the note has elsewhere, as in a backup; it must
  /// not be in use.
  Future<NoteEntry> createNote({
    String title = 'Untitled note',
    String? folderId,
    PageSetup setup = const PageSetup(),
    String? id,
  });

  /// Like [createNote], for a caller that must not wait on the disk: the
  /// entry is returned at once and can be opened, since [loadNote] reads only
  /// after the writes queued here. [saved] completes when the note is stored;
  /// if that fails the entry is withdrawn and [saved] completes with the error.
  ({NoteEntry note, Future<void> saved}) startNote({
    String title = 'Untitled note',
    String? folderId,
    PageSetup setup = const PageSetup(),
  });

  Future<Folder> createFolder(
    String name, {
    String? parentId,
    FolderColor color = FolderColor.accent,
  });

  Future<void> renameNote(String id, String title);

  Future<void> renameFolder(String id, String name);

  Future<void> recolorFolder(String id, FolderColor color);

  Future<void> moveNote(String id, String? folderId);

  /// Rejects moving a folder into itself or below itself.
  Future<void> moveFolder(String id, String? parentId);

  /// A copy of the note, ink and all, beside it.
  Future<NoteEntry> duplicateNote(String id);

  /// Moves the note to Recently Deleted, where its pages and assets are
  /// kept until it is restored or deleted for good. [at] is when it was
  /// deleted, now by default; earlier for one deleted on another device.
  Future<void> deleteNote(String id, {DateTime? at});

  /// The notes in Recently Deleted, most recently deleted first.
  Future<List<NoteEntry>> trash();

  /// Puts a note from Recently Deleted back where it was, or at the top
  /// level when its folder is gone.
  Future<void> restoreNote(String id);

  /// Deletes a note in Recently Deleted, with its pages and assets, for
  /// good.
  Future<void> deleteForever(String id);

  /// Deletes everything in Recently Deleted for good.
  Future<void> emptyTrash();

  /// Deletes for good what has been in Recently Deleted longer than
  /// [age].
  Future<void> purgeTrash(Duration age);

  /// What deleting [id] would remove besides the folder itself.
  Future<FolderTotals> totals(String id);

  /// Deletes the folder and everything below it.
  /// Deletes the folder and the folders inside it; the notes inside move
  /// to Recently Deleted.
  Future<void> deleteFolder(String id);

  Future<NoteContent> loadNote(String id);

  /// The first page of [id], as its picture in the library shows it, or
  /// null when it has none. Only that page is made into ink, however long
  /// the note.
  Future<StoredPage?> loadFirstPage(String id) async {
    final NoteContent content = await loadNote(id);
    return content.pages.isEmpty ? null : content.pages.first;
  }

  /// Whoever asked for [id] with [loadNote] has moved on before it
  /// arrived. Once no one else waits on it, the rest of the reading is
  /// dropped rather than finished for no one.
  void abandonLoad(String id) {}

  /// Stores [content] and updates the entry's modified time and page count.
  /// Completes with the entry as updated.
  Future<NoteEntry> saveNote(String id, NoteContent content);

  /// Writes bytes atomically before callers save content referring to them.
  Future<String> storeAsset(
    String noteId,
    Uint8List bytes, {
    required NoteAssetKind kind,
    required String extension,
    String? fileName,
  });

  Future<NoteAssetData> readAsset(String noteId, String assetId);

  Future<List<NoteAsset>> listAssets(String noteId);

  Future<void> removeAsset(String noteId, String assetId);

  /// Removes assets not reachable from saved pages or the session clipboard.
  Future<void> cleanupAssets(String noteId, Set<String> referencedAssetIds);
}

/// A repository that keeps the index in memory and leaves storing it, and
/// each note's content, to a subclass.
abstract class IndexedNoteRepository extends NoteRepository {
  IndexedNoteRepository({
    DateTime Function()? clock,
    String Function()? newId,
    Iterable<Folder> folders = const <Folder>[],
    Iterable<NoteEntry> notes = const <NoteEntry>[],
    Iterable<NoteEntry> trash = const <NoteEntry>[],
  }) : _clock = clock ?? DateTime.now,
       _newId = newId ?? _randomId {
    for (final Folder folder in folders) {
      _folders[folder.id] = folder;
    }
    for (final NoteEntry note in notes) {
      _notes[note.id] = note;
    }
    for (final NoteEntry note in trash) {
      _trash[note.id] = note;
    }
  }

  final DateTime Function() _clock;
  final String Function() _newId;
  final Map<String, Folder> _folders = <String, Folder>{};
  final Map<String, NoteEntry> _notes = <String, NoteEntry>{};

  /// Recently Deleted: kept apart, so nothing that lists the library can
  /// show them by mistake.
  final Map<String, NoteEntry> _trash = <String, NoteEntry>{};

  /// Mutations run one at a time, in order.
  Future<void> _queue = Future<void>.value();

  // Only in-flight reads are retained. A write barrier is part of the key:
  // a request made after a save must not join an older read.
  final Map<String, (Future<void>, Future<NoteContent>)> _loads = {};

  /// How many callers wait on each read in flight, and the reads no one
  /// waits on any more.
  final Map<String, int> _waiting = <String, int>{};
  final Set<String> _abandoned = <String>{};

  static final math.Random _random = math.Random();

  static String _randomId() {
    final String time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final String salt = _random.nextInt(1 << 32).toRadixString(36);
    return '$time$salt';
  }

  @protected
  Iterable<Folder> get folderIndex => _folders.values;

  @protected
  Iterable<NoteEntry> get noteIndex => _notes.values;

  @protected
  Iterable<NoteEntry> get trashIndex => _trash.values;

  /// Stores the index after a change.
  @protected
  Future<void> writeIndex();

  @protected
  Future<NoteContent> readContent(String id);

  /// The first page of [id]'s content, or null when it has none. A
  /// subclass may read less of the note than [readContent] does.
  @protected
  Future<StoredPage?> readFirstPage(String id) async {
    final NoteContent content = await readContent(id);
    return content.pages.isEmpty ? null : content.pages.first;
  }

  /// Whether no one waits any more on the read of [id] in flight. A
  /// reader that reads in steps stops at its next one.
  @protected
  bool isLoadAbandoned(String id) => _abandoned.contains(id);

  @protected
  Future<void> writeContent(String id, NoteContent content);

  @protected
  Future<void> deleteContent(String id);

  @protected
  Future<void> copyAssets(String fromNoteId, String toNoteId);

  Future<T> _mutate<T>(Future<T> Function() change) {
    final Completer<T> done = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        final T result = await change();
        done.complete(result);
        notifyListeners();
      } catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    return done.future;
  }

  /// Whether [id] is taken, by a folder or a note here or in Recently
  /// Deleted.
  bool _inUse(String id) =>
      _folders.containsKey(id) ||
      _notes.containsKey(id) ||
      _trash.containsKey(id);

  String _id() {
    String id;
    do {
      id = _newId();
    } while (_inUse(id));
    return id;
  }

  String _name(String name) {
    final String? clean = cleanName(name);
    if (clean == null) {
      throw const LibraryException('A name cannot be empty.');
    }
    return clean;
  }

  NoteEntry _note(String id) {
    final NoteEntry? note = _notes[id];
    if (note == null) {
      throw LibraryException('No note $id.');
    }
    return note;
  }

  Folder _folder(String id) {
    final Folder? folder = _folders[id];
    if (folder == null) {
      throw LibraryException('No folder $id.');
    }
    return folder;
  }

  void _checkFolder(String? id) {
    if (id != null) {
      _folder(id);
    }
  }

  @override
  Future<FolderListing> list(String? folderId) async {
    await _queue;
    return FolderListing(
      folders: <Folder>[
        for (final Folder folder in _folders.values)
          if (folder.parentId == folderId) folder,
      ],
      notes: <NoteEntry>[
        for (final NoteEntry note in _notes.values)
          if (note.folderId == folderId) note,
      ],
    );
  }

  @override
  Future<List<Folder>> allFolders() async {
    await _queue;
    return List<Folder>.of(_folders.values);
  }

  @override
  Future<List<NoteEntry>> allNotes() async {
    await _queue;
    return List<NoteEntry>.of(_notes.values);
  }

  @override
  Future<Map<String, int>> itemCounts() async {
    await _queue;
    final Map<String, int> counts = <String, int>{};
    for (final Folder folder in _folders.values) {
      final String? parent = folder.parentId;
      if (parent != null) {
        counts[parent] = (counts[parent] ?? 0) + 1;
      }
    }
    for (final NoteEntry note in _notes.values) {
      final String? folder = note.folderId;
      if (folder != null) {
        counts[folder] = (counts[folder] ?? 0) + 1;
      }
    }
    return counts;
  }

  @override
  Future<List<Folder>> pathTo(String? folderId) async {
    await _queue;
    final List<Folder> path = <Folder>[];
    String? id = folderId;
    while (id != null && path.length <= _folders.length) {
      final Folder? folder = _folders[id];
      if (folder == null) {
        break;
      }
      path.insert(0, folder);
      id = folder.parentId;
    }
    return path;
  }

  @override
  Future<FolderListing> search(String query) async {
    await _queue;
    final String needle = query.trim().toLowerCase();
    if (needle.isEmpty) {
      return const FolderListing(folders: <Folder>[], notes: <NoteEntry>[]);
    }
    return FolderListing(
      folders: <Folder>[
        for (final Folder folder in _folders.values)
          if (folder.name.toLowerCase().contains(needle)) folder,
      ],
      notes: <NoteEntry>[
        for (final NoteEntry note in _notes.values)
          if (note.title.toLowerCase().contains(needle) ||
              note.searchText.toLowerCase().contains(needle))
            note,
      ],
    );
  }

  @override
  Future<NoteEntry> createNote({
    String title = 'Untitled note',
    String? folderId,
    PageSetup setup = const PageSetup(),
    String? id,
  }) {
    return _mutate(() async {
      _checkFolder(folderId);
      if (id != null && _inUse(id)) {
        throw LibraryException('The id $id is in use.');
      }
      final DateTime now = _clock();
      final NoteEntry note = NoteEntry(
        id: id ?? _id(),
        title: _name(title),
        folderId: folderId,
        created: now,
        modified: now,
        pageCount: 1,
      );
      await writeContent(note.id, NoteContent.blank(setup));
      _notes[note.id] = note;
      await writeIndex();
      return note;
    });
  }

  @override
  ({NoteEntry note, Future<void> saved}) startNote({
    String title = 'Untitled note',
    String? folderId,
    PageSetup setup = const PageSetup(),
  }) {
    _checkFolder(folderId);
    final DateTime now = _clock();
    final NoteEntry note = NoteEntry(
      id: _id(),
      title: _name(title),
      folderId: folderId,
      created: now,
      modified: now,
      pageCount: 1,
    );
    _notes[note.id] = note;
    final Future<void> saved = _mutate(() async {
      try {
        await writeContent(note.id, NoteContent.blank(setup));
        await writeIndex();
      } on Object {
        _notes.remove(note.id);
        rethrow;
      }
    });
    return (note: note, saved: saved);
  }

  @override
  Future<Folder> createFolder(
    String name, {
    String? parentId,
    FolderColor color = FolderColor.accent,
  }) {
    return _mutate(() async {
      _checkFolder(parentId);
      final DateTime now = _clock();
      final Folder folder = Folder(
        id: _id(),
        name: _name(name),
        parentId: parentId,
        created: now,
        modified: now,
        color: color,
      );
      _folders[folder.id] = folder;
      await writeIndex();
      return folder;
    });
  }

  @override
  Future<void> renameNote(String id, String title) {
    return _mutate(() async {
      _notes[id] = _note(id).copyWith(title: _name(title), modified: _clock());
      await writeIndex();
    });
  }

  @override
  Future<void> renameFolder(String id, String name) {
    return _mutate(() async {
      _folders[id] = _folder(
        id,
      ).copyWith(name: _name(name), modified: _clock());
      await writeIndex();
    });
  }

  @override
  Future<void> recolorFolder(String id, FolderColor color) {
    return _mutate(() async {
      _folders[id] = _folder(id).copyWith(color: color, modified: _clock());
      await writeIndex();
    });
  }

  @override
  Future<void> moveNote(String id, String? folderId) {
    return _mutate(() async {
      _checkFolder(folderId);
      _notes[id] = _note(id).copyWith(folderId: () => folderId);
      await writeIndex();
    });
  }

  @override
  Future<void> moveFolder(String id, String? parentId) {
    return _mutate(() async {
      final Folder folder = _folder(id);
      _checkFolder(parentId);
      for (String? at = parentId; at != null; at = _folders[at]?.parentId) {
        if (at == id) {
          throw const LibraryException('A folder cannot be moved into itself.');
        }
      }
      _folders[id] = folder.copyWith(parentId: () => parentId);
      await writeIndex();
    });
  }

  @override
  Future<NoteEntry> duplicateNote(String id) {
    return _mutate(() async {
      final NoteEntry original = _note(id);
      final NoteContent content = await readContent(id);
      final DateTime now = _clock();
      final NoteEntry copy = NoteEntry(
        id: _id(),
        title: cleanName('${original.title} copy') ?? original.title,
        folderId: original.folderId,
        created: now,
        modified: now,
        pageCount: original.pageCount,
        searchText: original.searchText,
      );
      try {
        // Assets land first, so persisted content never points at files that
        // have not yet been copied.
        await copyAssets(id, copy.id);
        await writeContent(copy.id, content);
        _notes[copy.id] = copy;
        await writeIndex();
        return copy;
      } on Object {
        _notes.remove(copy.id);
        await deleteContent(copy.id);
        rethrow;
      }
    });
  }

  @override
  Future<void> deleteNote(String id, {DateTime? at}) {
    return _mutate(() async {
      final NoteEntry note = _note(id);
      _notes.remove(id);
      _trash[id] = note.copyWith(deleted: () => at ?? _clock());
      await writeIndex();
    });
  }

  @override
  Future<List<NoteEntry>> trash() async {
    await _queue;
    return List<NoteEntry>.of(_trash.values)
      ..sort((NoteEntry a, NoteEntry b) => b.deleted!.compareTo(a.deleted!));
  }

  NoteEntry _trashed(String id) {
    final NoteEntry? note = _trash[id];
    if (note == null) {
      throw LibraryException('No deleted note $id.');
    }
    return note;
  }

  @override
  Future<void> restoreNote(String id) {
    return _mutate(() async {
      final NoteEntry note = _trashed(id);
      final String? folderId = _folders.containsKey(note.folderId)
          ? note.folderId
          : null;
      _trash.remove(id);
      _notes[id] = note.copyWith(folderId: () => folderId, deleted: () => null);
      await writeIndex();
    });
  }

  @override
  Future<void> deleteForever(String id) {
    return _mutate(() async {
      _trashed(id);
      _trash.remove(id);
      await writeIndex();
      await deleteContent(id);
    });
  }

  @override
  Future<void> emptyTrash() => _purgeWhere((NoteEntry _) => true);

  @override
  Future<void> purgeTrash(Duration age) {
    final DateTime before = _clock().subtract(age);
    return _purgeWhere((NoteEntry note) => note.deleted!.isBefore(before));
  }

  Future<void> _purgeWhere(bool Function(NoteEntry note) test) {
    return _mutate(() async {
      final List<String> gone = <String>[
        for (final NoteEntry note in _trash.values)
          if (test(note)) note.id,
      ];
      if (gone.isEmpty) return;
      gone.forEach(_trash.remove);
      await writeIndex();
      for (final String id in gone) {
        await deleteContent(id);
      }
    });
  }

  /// [id] and every folder below it.
  Set<String> _subtree(String id) {
    final Set<String> found = <String>{id};
    bool grew = true;
    while (grew) {
      grew = false;
      for (final Folder folder in _folders.values) {
        if (folder.parentId != null &&
            found.contains(folder.parentId) &&
            found.add(folder.id)) {
          grew = true;
        }
      }
    }
    return found;
  }

  @override
  Future<FolderTotals> totals(String id) async {
    await _queue;
    _folder(id);
    final Set<String> subtree = _subtree(id);
    return FolderTotals(
      folders: subtree.length - 1,
      notes: _notes.values
          .where((NoteEntry note) => subtree.contains(note.folderId))
          .length,
    );
  }

  @override
  Future<void> deleteFolder(String id) {
    return _mutate(() async {
      _folder(id);
      final Set<String> subtree = _subtree(id);
      final List<String> notes = <String>[
        for (final NoteEntry note in _notes.values)
          if (subtree.contains(note.folderId)) note.id,
      ];
      subtree.forEach(_folders.remove);
      final DateTime now = _clock();
      for (final String id in notes) {
        _trash[id] = _notes.remove(id)!.copyWith(deleted: () => now);
      }
      await writeIndex();
    });
  }

  @override
  Future<NoteContent> loadNote(String id) {
    final barrier = _queue;
    final pending = _loads[id];
    // An abandoned read may already be stopping: start afresh instead.
    if (pending != null &&
        identical(pending.$1, barrier) &&
        !_abandoned.contains(id)) {
      _waiting[id] = (_waiting[id] ?? 0) + 1;
      return pending.$2;
    }
    _abandoned.remove(id);
    _waiting[id] = 1;
    final loading = _loadNoteAfter(id, barrier);
    _loads[id] = (barrier, loading);
    void release() {
      if (identical(_loads[id]?.$2, loading)) {
        _loads.remove(id);
        _waiting.remove(id);
        _abandoned.remove(id);
      }
    }

    loading.then<void>((_) => release(), onError: (Object _) => release());
    return loading;
  }

  @override
  void abandonLoad(String id) {
    final int? waiting = _waiting[id];
    if (waiting == null) return;
    if (waiting > 1) {
      _waiting[id] = waiting - 1;
      return;
    }
    _waiting.remove(id);
    _abandoned.add(id);
  }

  @override
  Future<StoredPage?> loadFirstPage(String id) async {
    await _queue;
    if (!_trash.containsKey(id)) _note(id);
    return readFirstPage(id);
  }

  Future<NoteContent> _loadNoteAfter(String id, Future<void> barrier) async {
    await barrier;
    // A deleted note can still be read, for its picture in Recently
    // Deleted.
    if (!_trash.containsKey(id)) _note(id);
    return readContent(id);
  }

  @override
  Future<NoteEntry> saveNote(String id, NoteContent content) {
    return _mutate(() async {
      final NoteEntry note = _note(id);
      await writeContent(id, content);
      final NoteEntry saved = _notes[id] = note.copyWith(
        modified: _clock(),
        pageCount: content.pages.length,
        searchText: content.searchableText,
        revision: note.revision + 1,
      );
      await writeIndex();
      return saved;
    });
  }

  /// The index as stored.
  @protected
  Map<String, Object?> indexToJson() {
    return <String, Object?>{
      'schema': storageSchema,
      'folders': <Object?>[for (final Folder f in _folders.values) f.toJson()],
      'notes': <Object?>[for (final NoteEntry n in _notes.values) n.toJson()],
      'trash': <Object?>[for (final NoteEntry n in _trash.values) n.toJson()],
    };
  }
}

/// Keeps everything in memory: for tests, previews, and harnesses. Content
/// is stored as JSON maps, so it goes through the same encoding as files.
class InMemoryNoteRepository extends IndexedNoteRepository {
  InMemoryNoteRepository({
    super.clock,
    super.newId,
    super.folders,
    super.notes,
    super.trash,
  });

  final Map<String, Map<String, Object?>> _content =
      <String, Map<String, Object?>>{};
  final Map<String, Map<String, NoteAssetData>> _assets =
      <String, Map<String, NoteAssetData>>{};
  int _assetSequence = 0;

  /// How many times the index has been stored.
  int indexWrites = 0;

  @override
  Future<void> writeIndex() async {
    indexWrites++;
  }

  @override
  Future<NoteContent> readContent(String id) async {
    final Map<String, Object?>? json = _content[id];
    return json == null ? NoteContent.blank() : NoteContent.fromJson(json);
  }

  @override
  Future<void> writeContent(String id, NoteContent content) async {
    // Through text, like a file, so nothing is shared with the caller.
    _content[id] =
        jsonDecode(jsonEncode(content.toJson())) as Map<String, Object?>;
  }

  @override
  Future<void> deleteContent(String id) async {
    _content.remove(id);
    _assets.remove(id);
  }

  @override
  Future<void> copyAssets(String fromNoteId, String toNoteId) async {
    final Map<String, NoteAssetData>? source = _assets[fromNoteId];
    if (source == null) {
      return;
    }
    _assets[toNoteId] = <String, NoteAssetData>{
      for (final MapEntry<String, NoteAssetData> entry in source.entries)
        entry.key: NoteAssetData(
          asset: entry.value.asset,
          bytes: Uint8List.fromList(entry.value.bytes),
        ),
    };
  }

  @override
  Future<String> storeAsset(
    String noteId,
    Uint8List bytes, {
    required NoteAssetKind kind,
    required String extension,
    String? fileName,
  }) async {
    if (!noteIndex.any((NoteEntry note) => note.id == noteId)) {
      throw LibraryException('No note $noteId.');
    }
    final String id = 'asset-${++_assetSequence}';
    final NoteAsset asset = NoteAsset(
      id: id,
      kind: kind,
      extension: extension.toLowerCase().replaceAll('.', ''),
      fileName: fileName,
    );
    (_assets[noteId] ??= <String, NoteAssetData>{})[id] = NoteAssetData(
      asset: asset,
      bytes: Uint8List.fromList(bytes),
    );
    return id;
  }

  @override
  Future<NoteAssetData> readAsset(String noteId, String assetId) async {
    final NoteAssetData? data = _assets[noteId]?[assetId];
    if (data == null) {
      throw LibraryException('No asset $assetId.');
    }
    return NoteAssetData(
      asset: data.asset,
      bytes: Uint8List.fromList(data.bytes),
    );
  }

  @override
  Future<List<NoteAsset>> listAssets(String noteId) async {
    return List<NoteAsset>.unmodifiable(
      (_assets[noteId]?.values ?? const <NoteAssetData>[]).map(
        (NoteAssetData data) => data.asset,
      ),
    );
  }

  @override
  Future<void> removeAsset(String noteId, String assetId) async {
    _assets[noteId]?.remove(assetId);
  }

  @override
  Future<void> cleanupAssets(
    String noteId,
    Set<String> referencedAssetIds,
  ) async {
    _assets[noteId]?.removeWhere(
      (String id, NoteAssetData _) => !referencedAssetIds.contains(id),
    );
  }

  bool hasContent(String id) => _content.containsKey(id);
}
