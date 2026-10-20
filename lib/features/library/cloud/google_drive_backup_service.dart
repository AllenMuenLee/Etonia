import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../editor/document_io/document_importer.dart';
import '../library_models.dart';
import '../note_content.dart';
import '../note_repository.dart';
import 'cloud_sync_state.dart';
import 'google_drive_client.dart';

Map<String, Object> _encodeAndHashJson(Map<String, Object?> json) {
  final Uint8List bytes = Uint8List.fromList(utf8.encode(jsonEncode(json)));
  return <String, Object>{
    'bytes': bytes,
    'hash': sha256.convert(bytes).toString(),
  };
}

String _hashBytes(Uint8List bytes) => sha256.convert(bytes).toString();

bool _largeBackupJson(Object? root) {
  const int threshold = 512 * 1024;
  int estimate = 0;
  final List<Object?> pending = <Object?>[root];
  while (pending.isNotEmpty && estimate < threshold) {
    final Object? value = pending.removeLast();
    switch (value) {
      case final String text:
        estimate += text.length * 2 + 2;
      case num _ || bool _ || null:
        estimate += 16;
      case final List<Object?> values:
        estimate += values.length;
        pending.addAll(values);
      case final Map<Object?, Object?> values:
        estimate += values.length * 2;
        for (final MapEntry<Object?, Object?> entry in values.entries) {
          pending
            ..add(entry.key)
            ..add(entry.value);
        }
      default:
        estimate += 32;
    }
  }
  return estimate >= threshold;
}

/// A backup cannot be made or read back as asked.
class GoogleDriveBackupException implements Exception {
  const GoogleDriveBackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// How a restore treats the library already on this device.
enum RestoreMode {
  /// Adds what the backup has beside what is here. Folders with the same
  /// name in the same place are shared; a note whose title is already in
  /// its folder is left out.
  merge,

  /// Puts the backup in place of the library. What was here goes to
  /// Recently Deleted, from where it can still be restored.
  replace,
}

@immutable
class BackupSummary {
  const BackupSummary({
    required this.exportedAt,
    required this.folderCount,
    required this.noteCount,
    required this.uploadedFiles,
    required this.unchangedFiles,
    this.deletedCount = 0,
    this.movedToDeleted = 0,
  });

  final DateTime exportedAt;
  final int folderCount;
  final int noteCount;

  /// Notes backed up from Recently Deleted.
  final int deletedCount;

  /// Notes in the backup that were not on this device, now kept in its
  /// Recently Deleted, and so in the backup's.
  final int movedToDeleted;

  /// Note contents and assets sent this time.
  final int uploadedFiles;

  /// Note contents and assets already in Drive as they are, so not sent.
  final int unchangedFiles;
}

@immutable
class RestoreSummary {
  const RestoreSummary({
    required this.exportedAt,
    required this.foldersCreated,
    required this.notesRestored,
    required this.notesSkipped,
    this.deletedRestored = 0,
  });

  /// When the restored backup was made.
  final DateTime exportedAt;
  final int foldersCreated;
  final int notesRestored;

  /// Notes left out by a merge, as their title was already in the folder.
  final int notesSkipped;

  /// Notes from the backup's Recently Deleted put in this device's.
  final int deletedRestored;
}

/// Backs the library up to, and restores it from, an `Etonia` folder in
/// Google Drive.
///
/// The folder holds `manifest.json` and a `notes` folder. The manifest is
/// the whole index: every folder and note entry, and for each note the
/// SHA-256 and Drive file of its content and of each of its assets. Files
/// in `notes` are named by their hash and never overwritten, and the
/// manifest is replaced last, so a backup that stops part way leaves the
/// previous one whole. A file whose hash is in the previous manifest is
/// not sent again.
///
/// Recently Deleted is backed up too, as the manifest's `trash`. A note in
/// the backup that is not on this device is not dropped from it: it is
/// brought into Recently Deleted here, and so stays in the backup's, until
/// it is deleted for good from Recently Deleted. Only a note this device
/// backed up or restored before and no longer has anywhere leaves the
/// backup.
class GoogleDriveBackupService {
  GoogleDriveBackupService({
    required this.client,
    required this.repository,
    CloudStateStore? state,
    this.flushPendingSaves,
    DateTime Function()? clock,
  }) : state = state ?? InMemoryCloudStateStore(),
       _clock = clock ?? DateTime.now;

  static const String rootFolderName = 'Etonia';

  /// Where older versions kept the backup; a restore still looks there
  /// when there is none in [rootFolderName].
  static const List<String> legacyRootFolderNames = <String>[
    'Greatnote Backup',
  ];
  static const String manifestName = 'manifest.json';
  static const String notesFolderName = 'notes';

  /// The manifest's own format.
  static const int schema = 1;

  static const String _lastBackupKey = 'lastBackupAt';
  static const String _linkedKey = 'driveLinked';

  /// The ids of the notes, in the library or Recently Deleted, that the
  /// last backup from here or restore to here had. One of them gone since
  /// was deleted for good.
  static const String _knownNotesKey = 'backedUpNoteIds';

  /// Backups and restores run one at a time, in the order asked for.
  Future<void> _queue = Future<void>.value();

  Future<T> _exclusive<T>(Future<T> Function() work) {
    final Future<T> result = _queue.then((_) => work());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  final GoogleDriveClient client;
  final NoteRepository repository;
  final CloudStateStore state;

  /// Saves edits still waiting for their autosave, before anything is
  /// read.
  final Future<void> Function()? flushPendingSaves;
  final DateTime Function() _clock;

  /// When this device last finished a backup.
  Future<DateTime?> lastBackupAt() async {
    final Object? millis = (await state.read())[_lastBackupKey];
    return millis is int ? DateTime.fromMillisecondsSinceEpoch(millis) : null;
  }

  /// Whether the user has connected Google Drive on this device and not
  /// disconnected since, so backing up on a schedule may sign back in
  /// without asking. A device that has backed up before counts.
  Future<bool> isLinked() async {
    final Map<String, Object?> values = await state.read();
    final Object? linked = values[_linkedKey];
    return linked is bool ? linked : values[_lastBackupKey] is int;
  }

  Future<void> setLinked(bool linked) {
    return state.update((Map<String, Object?> values) {
      values[_linkedKey] = linked;
    });
  }

  Future<BackupSummary> backUp({
    ValueChanged<CloudProgress>? onProgress,
    ImportCancellationToken? cancellation,
  }) {
    return _exclusive(
      () => _backUp(onProgress: onProgress, cancellation: cancellation),
    );
  }

  Future<BackupSummary> _backUp({
    ValueChanged<CloudProgress>? onProgress,
    ImportCancellationToken? cancellation,
  }) async {
    void check() {
      if (cancellation?.isCancelled ?? false) {
        throw const CloudCancelledException();
      }
    }

    onProgress?.call(
      const CloudProgress(
        phase: 'Preparing backup',
        completedItems: 0,
        totalItems: 0,
      ),
    );
    await flushPendingSaves?.call();
    // Reads wait for queued saves, so what is read is what was written.
    final List<Folder> folders = await repository.allFolders();
    List<NoteEntry> notes = await _allNotes(folders);
    List<NoteEntry> deleted = await repository.trash();
    check();

    final GoogleDriveItem root = await client.ensureFolder(
      name: rootFolderName,
    );
    final GoogleDriveItem notesFolder = await client.ensureFolder(
      name: notesFolderName,
      parentId: root.id,
    );
    final _Manifest? previous = await _readManifest(root.id);
    check();

    // Notes in the backup that are not here go to Recently Deleted rather
    // than out of the backup, unless this device had them and has since
    // deleted them for good.
    int moved = 0;
    if (previous != null) {
      final Set<String> known = await _knownNotes();
      final Set<String> here = <String>{
        for (final NoteEntry note in notes) note.id,
        for (final NoteEntry note in deleted) note.id,
      };
      for (final _NoteRecord record in previous.allNotes) {
        if (here.contains(record.entry.id) || known.contains(record.entry.id)) {
          continue;
        }
        check();
        onProgress?.call(
          CloudProgress(
            phase: 'Preparing backup',
            completedItems: 0,
            totalItems: 0,
            currentName: record.entry.title,
          ),
        );
        final _DownloadedNote note;
        try {
          note = await _downloadNote(record);
        } on GoogleDriveBackupException {
          // Missing or damaged in Drive: there is nothing left to keep.
          continue;
        }
        final bool folderHere = folders.any(
          (Folder folder) => folder.id == record.entry.folderId,
        );
        await _createNote(
          note,
          folderId: folderHere ? record.entry.folderId : null,
          deleted: record.entry.deleted ?? _clock(),
        );
        moved++;
      }
      if (moved > 0) {
        notes = await _allNotes(folders);
        deleted = await repository.trash();
      }
    }
    final Map<String, List<NoteAsset>> assets = <String, List<NoteAsset>>{
      for (final NoteEntry note in <NoteEntry>[...notes, ...deleted])
        note.id: await repository.listAssets(note.id),
    };
    check();

    // Files already in Drive, by hash, whichever note they were sent for.
    final Map<String, String> sent = <String, String>{
      for (final _NoteRecord record
          in previous?.allNotes ?? const <_NoteRecord>[]) ...<String, String>{
        record.contentHash: record.contentFileId,
        for (final _AssetRecord asset in record.assets.values)
          asset.hash: asset.fileId,
      },
    };

    final int total =
        notes.length +
        deleted.length +
        assets.values.fold<int>(0, (int sum, List<NoteAsset> list) {
          return sum + list.length;
        }) +
        1;
    int done = 0;
    int uploaded = 0;
    int unchanged = 0;
    void report(String? name) => onProgress?.call(
      CloudProgress(
        phase: 'Backing up',
        completedItems: done,
        totalItems: total,
        currentName: name,
      ),
    );

    Future<Map<String, Object?>> backUpNote(NoteEntry note) async {
      check();
      report(note.title);
      final NoteContent content = await repository.loadNote(note.id);
      final Map<String, Object?> json = content.toJson();
      final Map<String, Object> encoded = _largeBackupJson(json)
          ? await compute(
              _encodeAndHashJson,
              json,
              debugLabel: 'backup.encodeAndHash',
            )
          : _encodeAndHashJson(json);
      final Uint8List contentBytes = encoded['bytes']! as Uint8List;
      final String contentHash = encoded['hash']! as String;
      String? contentFileId = sent[contentHash];
      if (contentFileId != null) {
        unchanged++;
      } else {
        contentFileId = sent[contentHash] = (await client.uploadFile(
          parentId: notesFolder.id,
          name: '${note.id}-${contentHash.substring(0, 16)}.json',
          bytes: contentBytes,
          mimeType: 'application/json',
        )).id;
        uploaded++;
      }
      done++;

      final List<Map<String, Object?>> assetRecords = <Map<String, Object?>>[];
      for (final NoteAsset asset in assets[note.id]!) {
        check();
        report(asset.fileName ?? note.title);
        final NoteAssetData data = await repository.readAsset(
          note.id,
          asset.id,
        );
        final String hash = data.bytes.length >= 512 * 1024
            ? await compute(
                _hashBytes,
                data.bytes,
                debugLabel: 'backup.assetHash',
              )
            : sha256.convert(data.bytes).toString();
        String? fileId = sent[hash];
        if (fileId != null) {
          unchanged++;
        } else {
          fileId = sent[hash] = (await client.uploadFile(
            parentId: notesFolder.id,
            name:
                '${note.id}-${asset.id}-${hash.substring(0, 16)}'
                '.${asset.extension}',
            bytes: data.bytes,
            mimeType: _mimeTypeOf(asset),
          )).id;
          uploaded++;
        }
        assetRecords.add(<String, Object?>{
          'id': asset.id,
          'kind': asset.kind.name,
          'extension': asset.extension,
          'fileName': asset.fileName,
          'hash': hash,
          'size': data.bytes.length,
          'fileId': fileId,
        });
        done++;
      }
      return <String, Object?>{
        'entry': note.toJson(),
        'contentHash': contentHash,
        'contentSize': contentBytes.length,
        'contentFileId': contentFileId,
        'assets': assetRecords,
      };
    }

    final List<Map<String, Object?>> noteRecords = <Map<String, Object?>>[
      for (final NoteEntry note in notes) await backUpNote(note),
    ];
    final List<Map<String, Object?>> trashRecords = <Map<String, Object?>>[
      for (final NoteEntry note in deleted) await backUpNote(note),
    ];
    check();

    report(manifestName);
    final DateTime exportedAt = _clock();
    final Map<String, Object?> manifest = <String, Object?>{
      'schema': schema,
      'storageSchema': storageSchema,
      'exportedAt': exportedAt.toUtc().toIso8601String(),
      'folderCount': folders.length,
      'noteCount': notes.length,
      'folders': <Object?>[
        for (final Folder folder in folders) folder.toJson(),
      ],
      'notes': noteRecords,
      'trash': trashRecords,
    };
    await client.uploadFile(
      parentId: root.id,
      name: manifestName,
      bytes: Uint8List.fromList(utf8.encode(jsonEncode(manifest))),
      mimeType: 'application/json',
      existingFileId: previous?.fileId,
    );
    done++;
    report(null);

    // What no snapshot refers to any more, left by an older backup or by
    // one that was stopped, goes to the trash.
    final Set<String> keep = <String>{
      for (final Map<String, Object?> note in <Map<String, Object?>>[
        ...noteRecords,
        ...trashRecords,
      ]) ...<String>[
        note['contentFileId']! as String,
        for (final Object? asset in note['assets']! as List)
          (asset! as Map<String, Object?>)['fileId']! as String,
      ],
    };
    try {
      for (final GoogleDriveItem item in await client.listChildren(
        notesFolder.id,
      )) {
        if (!keep.contains(item.id)) {
          await client.deleteFile(item.id);
        }
      }
    } on GoogleDriveException {
      // Left for the next backup to tidy.
    }

    await state.update((Map<String, Object?> values) {
      values[_lastBackupKey] = exportedAt.millisecondsSinceEpoch;
      values[_knownNotesKey] = <String>[
        for (final NoteEntry note in notes) note.id,
        for (final NoteEntry note in deleted) note.id,
      ];
    });
    return BackupSummary(
      exportedAt: exportedAt,
      folderCount: folders.length,
      noteCount: notes.length,
      uploadedFiles: uploaded,
      unchangedFiles: unchanged,
      deletedCount: deleted.length,
      movedToDeleted: moved,
    );
  }

  /// Restores the library from the backup. Everything is downloaded and
  /// checked against its hash first; only then is the library changed,
  /// and a failure part way removes what was added.
  Future<RestoreSummary> restore({
    RestoreMode mode = RestoreMode.merge,
    ValueChanged<CloudProgress>? onProgress,
    ImportCancellationToken? cancellation,
  }) {
    return _exclusive(
      () => _restore(
        mode: mode,
        onProgress: onProgress,
        cancellation: cancellation,
      ),
    );
  }

  Future<RestoreSummary> _restore({
    required RestoreMode mode,
    ValueChanged<CloudProgress>? onProgress,
    ImportCancellationToken? cancellation,
  }) async {
    void check() {
      if (cancellation?.isCancelled ?? false) {
        throw const CloudCancelledException();
      }
    }

    onProgress?.call(
      const CloudProgress(
        phase: 'Looking for a backup',
        completedItems: 0,
        totalItems: 0,
      ),
    );
    await flushPendingSaves?.call();
    const GoogleDriveBackupException missing = GoogleDriveBackupException(
      'No Etonia backup was found in your Google Drive',
    );
    _Manifest? manifest;
    search:
    for (final String name in <String>[
      rootFolderName,
      ...legacyRootFolderNames,
    ]) {
      for (final GoogleDriveItem folder in await client.searchFoldersByName(
        name,
      )) {
        manifest = await _readManifest(folder.id);
        if (manifest != null) break search;
      }
    }
    if (manifest == null) throw missing;
    check();

    final List<_NoteRecord> records = manifest.allNotes;
    final int total =
        records.length +
        records.fold<int>(0, (int sum, _NoteRecord note) {
          return sum + note.assets.length;
        }) +
        1;
    int done = 0;
    void report(String phase, String? name) => onProgress?.call(
      CloudProgress(
        phase: phase,
        completedItems: done,
        totalItems: total,
        currentName: name,
      ),
    );

    final Map<String, _DownloadedNote> downloaded = <String, _DownloadedNote>{};
    for (final _NoteRecord record in records) {
      downloaded[record.entry.id] = await _downloadNote(
        record,
        onFile: (String name) {
          check();
          report('Downloading backup', name);
        },
        onFileDone: () => done++,
      );
    }
    check();

    report('Restoring library', null);
    final RestoreSummary summary = await _apply(
      manifest,
      downloaded,
      mode: mode,
    );
    // Restored under new ids: the backup's are not to be brought back as
    // missing from here.
    final Set<String> known = await _knownNotes();
    await state.update((Map<String, Object?> values) {
      values[_knownNotesKey] = <String>[
        ...known,
        for (final _NoteRecord record in records)
          if (!known.contains(record.entry.id)) record.entry.id,
      ];
    });
    done++;
    report('Restoring library', null);
    return summary;
  }

  /// The ids under [_knownNotesKey].
  Future<Set<String>> _knownNotes() async {
    final Object? ids = (await state.read())[_knownNotesKey];
    return <String>{
      if (ids is List)
        for (final Object? id in ids)
          if (id is String) id,
    };
  }

  /// Downloads the content and assets of [record], checked against their
  /// hashes. [onFile] is told the name of each file before it is
  /// downloaded, and [onFileDone] after.
  Future<_DownloadedNote> _downloadNote(
    _NoteRecord record, {
    ValueChanged<String>? onFile,
    VoidCallback? onFileDone,
  }) async {
    onFile?.call(record.entry.title);
    final Uint8List contentBytes = await _download(
      record.contentFileId,
      record.contentHash,
      record.entry.title,
    );
    final Map<String, Object?> json;
    try {
      json = jsonDecode(utf8.decode(contentBytes)) as Map<String, Object?>;
      NoteContent.fromJson(json);
    } on Object {
      throw GoogleDriveBackupException(
        'The backup of "${record.entry.title}" could not be read',
      );
    }
    onFileDone?.call();
    final Map<String, Uint8List> assetBytes = <String, Uint8List>{};
    for (final _AssetRecord asset in record.assets.values) {
      onFile?.call(asset.fileName ?? record.entry.title);
      assetBytes[asset.id] = await _download(
        asset.fileId,
        asset.hash,
        record.entry.title,
      );
      onFileDone?.call();
    }
    return _DownloadedNote(record, json, assetBytes);
  }

  /// Makes a note in the library from [note], in [folderId], and moves it
  /// to Recently Deleted when it was [deleted] then. Nothing is left of it
  /// if that fails part way.
  Future<NoteEntry> _createNote(
    _DownloadedNote note, {
    required String? folderId,
    DateTime? deleted,
  }) async {
    final NoteEntry created = await repository.createNote(
      title: note.record.entry.title,
      folderId: folderId,
    );
    try {
      final Map<String, String> assetIds = <String, String>{};
      for (final _AssetRecord asset in note.record.assets.values) {
        assetIds[asset.id] = await repository.storeAsset(
          created.id,
          note.assets[asset.id]!,
          kind: asset.kind,
          extension: asset.extension,
          fileName: asset.fileName,
        );
      }
      await repository.saveNote(
        created.id,
        NoteContent.fromJson(remapAssetIds(note.content, assetIds)),
      );
      if (deleted != null) {
        await repository.deleteNote(created.id, at: deleted);
      }
    } on Object {
      await _removeNote(created.id);
      rethrow;
    }
    return created;
  }

  /// Deletes the note [id] for good, wherever it is.
  Future<void> _removeNote(String id) async {
    try {
      await repository.deleteNote(id);
    } on Object {
      // Already in Recently Deleted.
    }
    try {
      await repository.deleteForever(id);
    } on Object {
      // Already gone.
    }
  }

  Future<RestoreSummary> _apply(
    _Manifest manifest,
    Map<String, _DownloadedNote> notes, {
    required RestoreMode mode,
  }) async {
    final bool merge = mode == RestoreMode.merge;
    final List<Folder> existingFolders = await repository.allFolders();
    final FolderListing previousTop = await repository.list(null);
    final List<NoteEntry> previousTrash = merge
        ? await repository.trash()
        : const <NoteEntry>[];
    // The titles already in each folder, before anything is added.
    final Map<String?, Set<String>> titles = <String?, Set<String>>{};
    if (merge) {
      for (final String? id in <String?>[
        null,
        for (final Folder folder in existingFolders) folder.id,
      ]) {
        titles[id] = <String>{
          for (final NoteEntry note in (await repository.list(id)).notes)
            note.title,
        };
      }
    }

    final Map<String, String> folderIds = <String, String>{};
    final List<String> createdFolders = <String>[];
    final List<String> createdNotes = <String>[];
    int restored = 0;
    int skipped = 0;
    int deletedRestored = 0;
    try {
      for (final Folder folder in _parentsFirst(manifest.folders)) {
        // A folder whose parent is not in the backup goes at the top.
        final String? parent = folder.parentId == null
            ? null
            : folderIds[folder.parentId];
        Folder? match;
        if (merge) {
          for (final Folder candidate in existingFolders) {
            if (candidate.name == folder.name && candidate.parentId == parent) {
              match = candidate;
              break;
            }
          }
        }
        if (match != null) {
          folderIds[folder.id] = match.id;
          continue;
        }
        final Folder created = await repository.createFolder(
          folder.name,
          parentId: parent,
          color: folder.color,
        );
        createdFolders.add(created.id);
        folderIds[folder.id] = created.id;
      }

      for (final _NoteRecord record in manifest.notes.values) {
        final NoteEntry entry = record.entry;
        final String? folderId = entry.folderId == null
            ? null
            : folderIds[entry.folderId];
        if (merge && (titles[folderId]?.contains(entry.title) ?? false)) {
          skipped++;
          continue;
        }
        createdNotes.add(
          (await _createNote(notes[entry.id]!, folderId: folderId)).id,
        );
        restored++;
      }

      // Recently Deleted, leaving out what is already in this device's.
      for (final _NoteRecord record in manifest.trash.values) {
        final NoteEntry entry = record.entry;
        if (merge &&
            previousTrash.any(
              (NoteEntry note) =>
                  note.id == entry.id ||
                  (note.title == entry.title && note.deleted == entry.deleted),
            )) {
          continue;
        }
        createdNotes.add(
          (await _createNote(
            notes[entry.id]!,
            folderId: folderIds[entry.folderId],
            deleted: entry.deleted ?? _clock(),
          )).id,
        );
        deletedRestored++;
      }
    } on Object {
      for (final String id in createdNotes.reversed) {
        await _removeNote(id);
      }
      for (final String id in createdFolders.reversed) {
        try {
          await repository.deleteFolder(id);
        } on Object {
          // Went with its parent.
        }
      }
      rethrow;
    }

    if (!merge) {
      for (final Folder folder in previousTop.folders) {
        await repository.deleteFolder(folder.id);
      }
      for (final NoteEntry note in previousTop.notes) {
        await repository.deleteNote(note.id);
      }
    }
    return RestoreSummary(
      exportedAt: manifest.exportedAt,
      foldersCreated: createdFolders.length,
      notesRestored: restored,
      notesSkipped: skipped,
      deletedRestored: deletedRestored,
    );
  }

  Future<Uint8List> _download(String fileId, String hash, String title) async {
    final Uint8List bytes;
    try {
      bytes = await client.downloadFile(fileId);
    } on GoogleDriveException catch (error) {
      if (error.kind != GoogleDriveErrorKind.notFound) rethrow;
      throw GoogleDriveBackupException(
        'Part of the backup of "$title" is missing',
      );
    }
    if (sha256.convert(bytes).toString() != hash) {
      throw GoogleDriveBackupException('The backup of "$title" is damaged');
    }
    return bytes;
  }

  /// Every note in the library, outside Recently Deleted.
  Future<List<NoteEntry>> _allNotes(List<Folder> folders) async {
    return <NoteEntry>[
      ...(await repository.list(null)).notes,
      for (final Folder folder in folders)
        ...(await repository.list(folder.id)).notes,
    ];
  }

  Future<_Manifest?> _readManifest(String rootId) async {
    GoogleDriveItem? file;
    for (final GoogleDriveItem item in await client.listChildren(rootId)) {
      if (!item.isFolder && item.name == manifestName) {
        file = item;
        break;
      }
    }
    if (file == null) return null;
    final Map<String, Object?> json;
    try {
      json =
          jsonDecode(utf8.decode(await client.downloadFile(file.id)))
              as Map<String, Object?>;
    } on GoogleDriveException {
      rethrow;
    } on Object {
      throw const GoogleDriveBackupException(
        'The backup in Google Drive could not be read',
      );
    }
    final Object? version = json['schema'];
    if (version is! int || version > schema) {
      throw const GoogleDriveBackupException(
        'The backup was made by a newer version of Etonia',
      );
    }
    try {
      return _Manifest.fromJson(file.id, json);
    } on Object {
      throw const GoogleDriveBackupException(
        'The backup in Google Drive could not be read',
      );
    }
  }

  static String _mimeTypeOf(NoteAsset asset) {
    return switch (asset.extension) {
      'pdf' => 'application/pdf',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      _ => 'application/octet-stream',
    };
  }

  /// [folders] ordered so each comes after its parent.
  static List<Folder> _parentsFirst(List<Folder> folders) {
    final Map<String, Folder> byId = <String, Folder>{
      for (final Folder folder in folders) folder.id: folder,
    };
    int depth(Folder folder) {
      int depth = 0;
      for (
        String? at = folder.parentId;
        at != null && byId.containsKey(at) && depth <= folders.length;
        at = byId[at]!.parentId
      ) {
        depth++;
      }
      return depth;
    }

    return List<Folder>.of(folders)
      ..sort((Folder a, Folder b) => depth(a).compareTo(depth(b)));
  }
}

/// [content] with the asset ids its pages refer to replaced by those in
/// [ids]; ids not in it are kept.
@visibleForTesting
Map<String, Object?> remapAssetIds(
  Map<String, Object?> content,
  Map<String, String> ids,
) {
  final Map<String, Object?> copy =
      jsonDecode(jsonEncode(content)) as Map<String, Object?>;
  for (final Object? page in (copy['pages'] as List?) ?? <Object?>[]) {
    if (page is! Map<String, Object?>) continue;
    final Object? pdf = page['pdfSource'];
    if (pdf is Map<String, Object?>) {
      pdf['assetId'] = ids[pdf['assetId']] ?? pdf['assetId'];
    }
    for (final Object? image in (page['images'] as List?) ?? <Object?>[]) {
      if (image is Map<String, Object?>) {
        image['assetId'] = ids[image['assetId']] ?? image['assetId'];
      }
    }
  }
  return copy;
}

class _Manifest {
  _Manifest({
    required this.fileId,
    required this.exportedAt,
    required this.folders,
    required this.notes,
    required this.trash,
  });

  factory _Manifest.fromJson(String fileId, Map<String, Object?> json) {
    Map<String, _NoteRecord> records(Object? list) => <String, _NoteRecord>{
      for (final Object? raw in (list as List?) ?? <Object?>[])
        if (_NoteRecord.fromJson(raw! as Map<String, Object?>)
            case final _NoteRecord note)
          note.entry.id: note,
    };

    return _Manifest(
      fileId: fileId,
      exportedAt: DateTime.parse(json['exportedAt']! as String).toLocal(),
      folders: <Folder>[
        for (final Object? folder in (json['folders'] as List?) ?? <Object?>[])
          Folder.fromJson(folder! as Map<String, Object?>),
      ],
      notes: records(json['notes']),
      // Older backups have none.
      trash: records(json['trash']),
    );
  }

  final String fileId;
  final DateTime exportedAt;
  final List<Folder> folders;
  final Map<String, _NoteRecord> notes;

  /// Recently Deleted.
  final Map<String, _NoteRecord> trash;

  /// [notes], then [trash].
  List<_NoteRecord> get allNotes => <_NoteRecord>[
    ...notes.values,
    ...trash.values,
  ];
}

class _NoteRecord {
  _NoteRecord({
    required this.entry,
    required this.contentHash,
    required this.contentFileId,
    required this.assets,
  });

  factory _NoteRecord.fromJson(Map<String, Object?> json) {
    return _NoteRecord(
      entry: NoteEntry.fromJson(json['entry']! as Map<String, Object?>),
      contentHash: json['contentHash']! as String,
      contentFileId: json['contentFileId']! as String,
      assets: <String, _AssetRecord>{
        for (final Object? raw in (json['assets'] as List?) ?? <Object?>[])
          if (_AssetRecord.fromJson(raw! as Map<String, Object?>)
              case final _AssetRecord asset)
            asset.id: asset,
      },
    );
  }

  final NoteEntry entry;
  final String contentHash;
  final String contentFileId;
  final Map<String, _AssetRecord> assets;
}

class _AssetRecord {
  _AssetRecord({
    required this.id,
    required this.kind,
    required this.extension,
    required this.fileName,
    required this.hash,
    required this.fileId,
  });

  factory _AssetRecord.fromJson(Map<String, Object?> json) {
    return _AssetRecord(
      id: json['id']! as String,
      kind: NoteAssetKind.values.byName(json['kind']! as String),
      extension: json['extension']! as String,
      fileName: json['fileName'] as String?,
      hash: json['hash']! as String,
      fileId: json['fileId']! as String,
    );
  }

  final String id;
  final NoteAssetKind kind;
  final String extension;
  final String? fileName;
  final String hash;
  final String fileId;
}

class _DownloadedNote {
  _DownloadedNote(this.record, this.content, this.assets);

  final _NoteRecord record;
  final Map<String, Object?> content;
  final Map<String, Uint8List> assets;
}
