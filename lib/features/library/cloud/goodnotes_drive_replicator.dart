import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../editor/document_io/document_importer.dart';
import '../../editor/document_io/document_platform.dart';
import '../../editor/document_io/goodnotes_archive_extractor.dart';
import '../library_models.dart';
import '../note_repository.dart';
import 'cloud_sync_state.dart';
import 'google_drive_client.dart';

/// Shown when Drive has no folder to replicate.
const String noGoodnotesFolderMessage =
    'No Goodnotes folder was found in your Google Drive';

class GoodnotesFolderNotFoundException implements Exception {
  const GoodnotesFolderNotFoundException();

  @override
  String toString() => noGoodnotesFolderMessage;
}

/// A Goodnotes folder found in Drive, with the names of the folders it is
/// in, from My Drive down.
@immutable
class GoodnotesDriveRoot {
  const GoodnotesDriveRoot({required this.folder, required this.path});

  final GoogleDriveItem folder;
  final List<String> path;

  /// Where it is, as `My Drive/Backups/GoodNotes`.
  String get location => <String>['My Drive', ...path, folder.name].join('/');
}

/// A file that was not imported, and why.
@immutable
class ReplicationIssue {
  const ReplicationIssue(this.path, this.reason);

  /// The file's place under the replicated folder, as `MGY377/Labs/x.txt`.
  final String path;
  final String reason;
}

@immutable
class ReplicationSummary {
  const ReplicationSummary({
    required this.localRootId,
    required this.foldersCreated,
    required this.foldersReused,
    required this.imported,
    required this.unchanged,
    required this.skipped,
    required this.failed,
    required this.cancelled,
  });

  /// The library folder the Drive folder's contents were replicated into;
  /// null means the library root.
  final String? localRootId;
  final int foldersCreated;
  final int foldersReused;

  /// The paths of the files imported as notes.
  final List<String> imported;

  /// Files imported by an earlier run and not changed since.
  final int unchanged;

  /// Files of a kind that is not imported.
  final List<ReplicationIssue> skipped;

  /// Files that could not be downloaded or imported.
  final List<ReplicationIssue> failed;

  /// Whether the user stopped it; what was finished is kept.
  final bool cancelled;
}

/// Finds the Goodnotes folder in Google Drive and replicates it into the
/// library: the same folders nested directly under the chosen destination,
/// with every `.goodnotes` notebook and PDF imported as a note in its folder.
/// A PDF that is only the export of a notebook beside it is left out.
///
/// Running it again reuses the folders already made, matched by name and
/// place, and leaves out files imported before that have not changed since;
/// a changed file is imported again and its old note moved to Recently
/// Deleted.
class GoodnotesDriveReplicator {
  GoodnotesDriveReplicator({
    required this.client,
    required this.repository,
    required this.importer,
    CloudStateStore? state,
  }) : state = state ?? InMemoryCloudStateStore();

  /// The names searched for; case is ignored.
  static const String folderName = 'GoodNotes';

  static const String _importsKey = 'goodnotesImports';

  final GoogleDriveClient client;
  final NoteRepository repository;
  final DocumentImporter importer;
  final CloudStateStore state;

  /// The Goodnotes folders in Drive, the one to use by default first: a
  /// folder in My Drive itself before any nested deeper, then the most
  /// recently changed. A Goodnotes folder inside another is part of that
  /// one, not a root of its own.
  ///
  /// Throws [GoodnotesFolderNotFoundException] when there is none.
  Future<List<GoodnotesDriveRoot>> findRoots() async {
    final List<GoogleDriveItem> found = await client.searchFoldersByName(
      folderName,
    );
    final Set<String> foundIds = <String>{
      for (final GoogleDriveItem item in found) item.id,
    };
    final Map<String, GoogleDriveItem> parents = <String, GoogleDriveItem>{};
    final List<(GoodnotesDriveRoot, bool)> roots =
        <(GoodnotesDriveRoot, bool)>[];
    for (final GoogleDriveItem folder in found) {
      final List<String> path = <String>[];
      bool nested = false;
      bool shared = false;
      String? at = folder.parentIds.isEmpty ? null : folder.parentIds.first;
      // Up to My Drive, whose root has no parents of its own.
      for (int depth = 0; at != null && depth < 32; depth++) {
        if (foundIds.contains(at)) {
          nested = true;
          break;
        }
        GoogleDriveItem? parent = parents[at];
        if (parent == null) {
          try {
            parent = parents[at] = await client.getItem(at);
          } on GoogleDriveException {
            shared = true;
            break;
          }
        }
        if (parent.parentIds.isEmpty) break;
        path.insert(0, parent.name);
        at = parent.parentIds.first;
      }
      if (!nested) {
        roots.add((
          GoodnotesDriveRoot(folder: folder, path: path),
          shared || folder.parentIds.isEmpty,
        ));
      }
    }
    if (roots.isEmpty) throw const GoodnotesFolderNotFoundException();
    roots.sort(((GoodnotesDriveRoot, bool) a, (GoodnotesDriveRoot, bool) b) {
      // Folders in My Drive before shared ones, shallow before deep.
      if (a.$2 != b.$2) return a.$2 ? 1 : -1;
      final int depth = a.$1.path.length.compareTo(b.$1.path.length);
      if (depth != 0) return depth;
      final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
      return (b.$1.folder.modifiedTime ?? epoch).compareTo(
        a.$1.folder.modifiedTime ?? epoch,
      );
    });
    return <GoodnotesDriveRoot>[
      for (final (GoodnotesDriveRoot, bool) root in roots) root.$1,
    ];
  }

  /// Replicates [root] into [targetFolderId], or at the top of the library.
  ///
  /// The folder tree is walked breadth first and made in the library, then
  /// the files are imported one at a time. Cancelling stops before the next
  /// file, or rolls back the one being imported; the summary then says so,
  /// and notes already imported stay.
  Future<ReplicationSummary> replicate(
    GoogleDriveItem root, {
    String? targetFolderId,
    ValueChanged<CloudProgress>? onProgress,
    ImportCancellationToken? cancellation,
  }) async {
    final ImportCancellationToken token =
        cancellation ?? ImportCancellationToken();
    int created = 0;
    int reused = 0;

    Future<String> folderIn(String? parentId, String name) async {
      final String clean = cleanName(name) ?? 'Untitled folder';
      for (final Folder folder in (await repository.list(parentId)).folders) {
        if (folder.name == clean) {
          reused++;
          return folder.id;
        }
      }
      created++;
      return (await repository.createFolder(clean, parentId: parentId)).id;
    }

    // The Drive folder is only the source boundary. Its contents go directly
    // into the chosen destination (the library root by default), without an
    // extra local `GoodNotes` wrapper folder.
    final String? localRoot = targetFolderId;
    final List<_RemoteFile> files = <_RemoteFile>[];
    final Queue<_RemoteFolder> queue = Queue<_RemoteFolder>()
      ..add(_RemoteFolder(root, localRoot, ''));
    int visited = 0;
    final Set<String> seen = <String>{root.id};
    while (queue.isNotEmpty) {
      if (token.isCancelled) {
        return _summary(localRoot, created, reused, cancelled: true);
      }
      final _RemoteFolder folder = queue.removeFirst();
      visited++;
      onProgress?.call(
        CloudProgress(
          phase: 'Replicating folder $visited / ${visited + queue.length}',
          completedItems: visited - 1,
          totalItems: visited + queue.length,
          currentName: folder.item.name,
        ),
      );
      final List<GoogleDriveItem> children = await client.listChildren(
        folder.item.id,
      );
      children.sort(
        (GoogleDriveItem a, GoogleDriveItem b) =>
            a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
      for (final GoogleDriveItem child in children) {
        final String path = folder.path.isEmpty
            ? child.name
            : '${folder.path}/${child.name}';
        if (child.isFolder) {
          // A folder reached twice, through a shortcut or a second
          // parent, is replicated once.
          if (!seen.add(child.id)) continue;
          queue.add(
            _RemoteFolder(
              child,
              await folderIn(folder.localId, child.name),
              path,
            ),
          );
        } else {
          files.add(_RemoteFile(child, folder.item.id, folder.localId, path));
        }
      }
    }

    // Goodnotes backs each notebook up twice: as its `.goodnotes` file and,
    // beside it, as a PDF export with the ink printed on the pages. The
    // export of a notebook that came in is left out, so the notebook's ink
    // is the only copy and stays editable; it comes in only when the
    // notebook could not. Files are in name order, so a notebook comes
    // before its export.
    final Set<String> notebooksIn = <String>{};

    final Map<String, Object?> imports = _importsFrom(await state.read());
    final Map<String, NoteEntry> liveNotes = await _liveNotes();
    final List<String> imported = <String>[];
    final List<ReplicationIssue> skipped = <ReplicationIssue>[];
    final List<ReplicationIssue> failed = <ReplicationIssue>[];
    int unchanged = 0;
    for (int i = 0; i < files.length; i++) {
      final _RemoteFile file = files[i];
      if (token.isCancelled) {
        return _summary(
          localRoot,
          created,
          reused,
          imported: imported,
          unchanged: unchanged,
          skipped: skipped,
          failed: failed,
          cancelled: true,
        );
      }
      onProgress?.call(
        CloudProgress(
          phase: 'Importing file ${i + 1} of ${files.length}',
          completedItems: i,
          totalItems: files.length,
          currentName: file.item.name,
        ),
      );
      final _FileKind? kind = _kindOf(file.item);
      if (kind == null) {
        skipped.add(ReplicationIssue(file.path, 'Not a notebook or PDF'));
        continue;
      }
      final String modified =
          file.item.modifiedTime?.toUtc().toIso8601String() ?? '';
      final Object? previous = imports[file.item.id];
      final String? previousNote = previous is Map<String, Object?>
          ? previous['noteId'] as String?
          : null;
      final NoteEntry? previousEntry = previousNote == null
          ? null
          : liveNotes[previousNote];
      if (kind == _FileKind.pdf && notebooksIn.contains(file.notebookKey)) {
        // An export an earlier run imported goes to Recently Deleted.
        if (previousEntry != null) {
          await repository.deleteNote(previousEntry.id);
        }
        if (imports.remove(file.item.id) != null) {
          await state.update((Map<String, Object?> values) {
            values[_importsKey] = imports;
          });
        }
        continue;
      }
      final bool previousExists = previousEntry != null;
      if (previousExists &&
          (previous! as Map<String, Object?>)['modified'] == modified) {
        final NoteEntry existing = previousEntry;
        if (existing.folderId != file.localFolderId) {
          await repository.moveNote(existing.id, file.localFolderId);
        }
        if (kind == _FileKind.goodnotes) notebooksIn.add(file.notebookKey);
        unchanged++;
        continue;
      }

      final NoteEntry note;
      try {
        final PickedDocument picked = PickedDocument(
          name: file.item.name,
          bytes: await client.downloadFile(file.item.id),
        );
        if (token.isCancelled) continue;
        note =
            kind == _FileKind.goodnotes ||
                GoodnotesArchiveExtractor.isGoodnotesArchive(picked.bytes)
            ? await importer.importGoodnotesAsNote(
                repository: repository,
                picked: picked,
                folderId: file.localFolderId,
                cancellation: token,
              )
            : await importer.importPdfAsNote(
                repository: repository,
                picked: picked,
                folderId: file.localFolderId,
                cancellation: token,
                recoverGoodnotesInk: true,
              );
      } on Object catch (error) {
        // A cancelled import has rolled its note back; the loop stops at
        // its top.
        if (!token.isCancelled) {
          failed.add(ReplicationIssue(file.path, _reasonFor(error)));
        }
        continue;
      }
      imported.add(file.path);
      if (kind == _FileKind.goodnotes) notebooksIn.add(file.notebookKey);
      if (previousEntry != null && previousEntry.id != note.id) {
        await repository.deleteNote(previousEntry.id);
      }
      imports[file.item.id] = <String, Object?>{
        'noteId': note.id,
        'modified': modified,
      };
      await state.update((Map<String, Object?> values) {
        values[_importsKey] = imports;
      });
    }
    if (token.isCancelled) {
      return _summary(
        localRoot,
        created,
        reused,
        imported: imported,
        unchanged: unchanged,
        skipped: skipped,
        failed: failed,
        cancelled: true,
      );
    }
    onProgress?.call(
      CloudProgress(
        phase: 'Imported ${imported.length} of ${files.length} files',
        completedItems: files.length,
        totalItems: files.length,
      ),
    );
    return _summary(
      localRoot,
      created,
      reused,
      imported: imported,
      unchanged: unchanged,
      skipped: skipped,
      failed: failed,
      cancelled: false,
    );
  }

  ReplicationSummary _summary(
    String? localRoot,
    int created,
    int reused, {
    List<String> imported = const <String>[],
    int unchanged = 0,
    List<ReplicationIssue> skipped = const <ReplicationIssue>[],
    List<ReplicationIssue> failed = const <ReplicationIssue>[],
    required bool cancelled,
  }) {
    return ReplicationSummary(
      localRootId: localRoot,
      foldersCreated: created,
      foldersReused: reused,
      imported: List<String>.unmodifiable(imported),
      unchanged: unchanged,
      skipped: List<ReplicationIssue>.unmodifiable(skipped),
      failed: List<ReplicationIssue>.unmodifiable(failed),
      cancelled: cancelled,
    );
  }

  static Map<String, Object?> _importsFrom(Map<String, Object?> state) {
    final Object? imports = state[_importsKey];
    return imports is Map<String, Object?>
        ? Map<String, Object?>.of(imports)
        : <String, Object?>{};
  }

  /// The notes in the library, outside Recently Deleted.
  Future<Map<String, NoteEntry>> _liveNotes() async {
    return <String, NoteEntry>{
      for (final String? folder in <String?>[
        null,
        for (final Folder folder in await repository.allFolders()) folder.id,
      ])
        for (final NoteEntry note in (await repository.list(folder)).notes)
          note.id: note,
    };
  }

  static _FileKind? _kindOf(GoogleDriveItem item) {
    final String name = item.name.toLowerCase();
    if (name.endsWith('.goodnotes')) return _FileKind.goodnotes;
    if (name.endsWith('.pdf') || item.mimeType == 'application/pdf') {
      return _FileKind.pdf;
    }
    return null;
  }

  static String _reasonFor(Object error) {
    return switch (error) {
      DocumentImportException(:final String message) => message,
      GoogleDriveException(:final String message) => message,
      _ => 'Could not be imported',
    };
  }
}

enum _FileKind { goodnotes, pdf }

class _RemoteFolder {
  _RemoteFolder(this.item, this.localId, this.path);

  final GoogleDriveItem item;
  final String? localId;
  final String path;
}

class _RemoteFile {
  _RemoteFile(this.item, this.folderId, this.localFolderId, this.path);

  final GoogleDriveItem item;

  /// The Drive folder it is in.
  final String folderId;
  final String? localFolderId;
  final String path;

  /// The same for a notebook and its PDF export: `X.goodnotes` and `X.pdf`
  /// in the same folder.
  String get notebookKey {
    final String name = item.name.toLowerCase();
    final String base = name.endsWith('.goodnotes')
        ? name.substring(0, name.length - '.goodnotes'.length)
        : name.endsWith('.pdf')
        ? name.substring(0, name.length - '.pdf'.length)
        : name;
    return '$folderId/$base';
  }
}
