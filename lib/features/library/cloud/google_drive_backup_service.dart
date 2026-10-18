import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../editor/document_io/document_importer.dart';
import '../library_models.dart';
import '../note_content.dart';
import '../note_repository.dart';
import 'cloud_sync_state.dart';
import 'google_drive_client.dart';

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
  });

  final DateTime exportedAt;
  final int folderCount;
  final int noteCount;

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
  });

  /// When the restored backup was made.
  final DateTime exportedAt;
  final int foldersCreated;
  final int notesRestored;

  /// Notes left out by a merge, as their title was already in the folder.
  final int notesSkipped;
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
    final List<NoteEntry> notes = await _allNotes(folders);
    final Map<String, List<NoteAsset>> assets = <String, List<NoteAsset>>{
      for (final NoteEntry note in notes)
        note.id: await repository.listAssets(note.id),
    };
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

    final int total =
        notes.length +
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

    final List<Map<String, Object?>> noteRecords = <Map<String, Object?>>[];
    for (final NoteEntry note in notes) {
      check();
      report(note.title);
      final NoteContent content = await repository.loadNote(note.id);
      final Uint8List contentBytes = Uint8List.fromList(
        utf8.encode(jsonEncode(content.toJson())),
      );
      final String contentHash = sha256.convert(contentBytes).toString();
      final _NoteRecord? before = previous?.notes[note.id];
      String contentFileId;
      if (before != null && before.contentHash == contentHash) {
        contentFileId = before.contentFileId;
        unchanged++;
      } else {
        contentFileId = (await client.uploadFile(
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
        final String hash = sha256.convert(data.bytes).toString();
        final _AssetRecord? old = before?.assets[asset.id];
        String fileId;
        if (old != null && old.hash == hash) {
          fileId = old.fileId;
          unchanged++;
        } else {
          fileId = (await client.uploadFile(
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
      noteRecords.add(<String, Object?>{
        'entry': note.toJson(),
        'contentHash': contentHash,
        'contentSize': contentBytes.length,
        'contentFileId': contentFileId,
        'assets': assetRecords,
      });
    }
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
      for (final Map<String, Object?> note in noteRecords) ...<String>[
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
    });
    return BackupSummary(
      exportedAt: exportedAt,
      folderCount: folders.length,
      noteCount: notes.length,
      uploadedFiles: uploaded,
      unchangedFiles: unchanged,
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

    final int total =
        manifest.notes.length +
        manifest.notes.values.fold<int>(0, (int sum, _NoteRecord note) {
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

    final List<_DownloadedNote> downloaded = <_DownloadedNote>[];
    for (final _NoteRecord record in manifest.notes.values) {
      check();
      report('Downloading backup', record.entry.title);
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
      done++;
      final Map<String, Uint8List> assetBytes = <String, Uint8List>{};
      for (final _AssetRecord asset in record.assets.values) {
        check();
        report('Downloading backup', asset.fileName ?? record.entry.title);
        assetBytes[asset.id] = await _download(
          asset.fileId,
          asset.hash,
          record.entry.title,
        );
        done++;
      }
      downloaded.add(_DownloadedNote(record, json, assetBytes));
    }
    check();

    report('Restoring library', null);
    final RestoreSummary summary = await _apply(
      manifest,
      downloaded,
      mode: mode,
    );
    done++;
    report('Restoring library', null);
    return summary;
  }

  Future<RestoreSummary> _apply(
    _Manifest manifest,
    List<_DownloadedNote> notes, {
    required RestoreMode mode,
  }) async {
    final bool merge = mode == RestoreMode.merge;
    final List<Folder> existingFolders = await repository.allFolders();
    final FolderListing previousTop = await repository.list(null);
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

      for (final _DownloadedNote note in notes) {
        final NoteEntry entry = note.record.entry;
        final String? folderId = entry.folderId == null
            ? null
            : folderIds[entry.folderId];
        if (merge && (titles[folderId]?.contains(entry.title) ?? false)) {
          skipped++;
          continue;
        }
        final NoteEntry created = await repository.createNote(
          title: entry.title,
          folderId: folderId,
        );
        createdNotes.add(created.id);
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
        restored++;
      }
    } on Object {
      for (final String id in createdNotes.reversed) {
        try {
          await repository.deleteNote(id);
          await repository.deleteForever(id);
        } on Object {
          // Already gone.
        }
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
  });

  factory _Manifest.fromJson(String fileId, Map<String, Object?> json) {
    return _Manifest(
      fileId: fileId,
      exportedAt: DateTime.parse(json['exportedAt']! as String).toLocal(),
      folders: <Folder>[
        for (final Object? folder in (json['folders'] as List?) ?? <Object?>[])
          Folder.fromJson(folder! as Map<String, Object?>),
      ],
      notes: <String, _NoteRecord>{
        for (final Object? raw in (json['notes'] as List?) ?? <Object?>[])
          if (_NoteRecord.fromJson(raw! as Map<String, Object?>)
              case final _NoteRecord note)
            note.entry.id: note,
      },
    );
  }

  final String fileId;
  final DateTime exportedAt;
  final List<Folder> folders;
  final Map<String, _NoteRecord> notes;
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
