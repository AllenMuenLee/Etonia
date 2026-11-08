import 'dart:async';
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

/// Where one file of a Goodnotes import is.
enum ImportStatus {
  /// Listed, not yet downloaded.
  waiting,

  /// Being downloaded and turned into a note now.
  loading,

  /// Now a note in the library.
  imported,

  /// Imported by an earlier run and not changed since.
  unchanged,

  /// Could not be downloaded or imported.
  failed,

  /// Of a kind that is not imported.
  skipped,

  /// A PDF that is only the export of a notebook that came in.
  covered,
}

/// One file in Drive that an import brings in, with how far it has come.
class ImportItem {
  ImportItem._(this._file, this._kind);

  final _RemoteFile _file;
  final _FileKind? _kind;

  ImportStatus status = ImportStatus.waiting;

  /// The note it became, once [status] is imported or unchanged.
  String? noteId;

  /// Why it failed or was left out.
  String? reason;

  /// Whether it is a PDF beside a notebook of the same name: the notebook's
  /// printed export, imported only if the notebook cannot be.
  bool isExport = false;

  /// Whether the person asked for it, so it loads ahead of the others.
  bool requested = false;

  final Completer<void> _finished = Completer<void>();

  /// Completes when the file is done with, one way or another.
  Future<void> get finished => _finished.future;

  String get driveId => _file.item.id;
  String get name => _file.item.name;
  String get path => _file.path;
  String? get localFolderId => _file.localFolderId;

  /// The name without `.goodnotes` or `.pdf`, as a note is titled.
  String get title {
    final String lower = name.toLowerCase();
    for (final String extension in const <String>['.goodnotes', '.pdf']) {
      if (lower.endsWith(extension)) {
        return name.substring(0, name.length - extension.length);
      }
    }
    return name;
  }

  /// Whether it is still to be brought in.
  bool get isPending =>
      status == ImportStatus.waiting || status == ImportStatus.loading;

  void _settle(ImportStatus to, {String? reason, String? noteId}) {
    status = to;
    this.reason = reason;
    this.noteId = noteId ?? this.noteId;
    if (!_finished.isCompleted) _finished.complete();
  }
}

/// A Goodnotes import under way: every folder made in the library and every
/// file listed before any is downloaded, then the files loaded one at a
/// time. A file asked for with [prioritize] is loaded next.
///
/// It notifies as files change, so the library can show the files still to
/// come beside the notes already in.
class GoodnotesImportSession extends ChangeNotifier {
  GoodnotesImportSession._({
    required this.localRootId,
    required this.foldersCreated,
    required this.foldersReused,
    required this.items,
    required this.scanCancelled,
    required Map<String, Object?> imports,
    required Map<String, NoteEntry> liveNotes,
    // ignore: prefer_initializing_formals
  }) : _imports = imports,
       // ignore: prefer_initializing_formals
       _liveNotes = liveNotes;

  /// The library folder the files go into; null is the library root.
  final String? localRootId;
  final int foldersCreated;
  final int foldersReused;

  /// Every file found, in the order they are loaded.
  final List<ImportItem> items;

  /// Whether the person stopped it before every folder was read.
  final bool scanCancelled;

  final Map<String, Object?> _imports;
  final Map<String, NoteEntry> _liveNotes;
  final List<ImportItem> _asked = <ImportItem>[];
  bool _ended = false;

  /// Whether it has ended, loaded or stopped.
  bool get isFinished => _ended;

  /// The files in [folderId] still to come, for the library to show; none
  /// once the import has ended.
  List<ImportItem> pendingIn(String? folderId) {
    if (_ended) return const <ImportItem>[];
    if (_pendingByFolder == null) {
      final Map<String?, List<ImportItem>> byFolder =
          <String?, List<ImportItem>>{};
      for (final ImportItem item in items) {
        if (!item.isExport && item.isPending) {
          (byFolder[item.localFolderId] ??= <ImportItem>[]).add(item);
        }
      }
      _pendingByFolder = byFolder;
    }
    return _pendingByFolder![folderId] ?? const <ImportItem>[];
  }

  /// The files still to come, by folder; made when asked for, and made again
  /// after any change.
  Map<String?, List<ImportItem>>? _pendingByFolder;

  /// How many files are done with, and how many there are to do.
  ({int done, int total}) get counts {
    int done = 0;
    int total = 0;
    for (final ImportItem item in items) {
      if (item._kind == null || item.status == ImportStatus.covered) continue;
      total++;
      if (!item.isPending) done++;
    }
    return (done: done, total: total);
  }

  /// Has [item] loaded next, ahead of the others. A notebook's printed
  /// export stands for the notebook. Completes when the file is done with,
  /// or the import ends.
  Future<void> prioritize(ImportItem item) {
    final ImportItem wanted = item.isExport
        ? (_notebookOf(item) ?? item)
        : item;
    if (_ended || !wanted.isPending) return wanted.finished;
    wanted.requested = true;
    _asked
      ..remove(wanted)
      ..insert(0, wanted);
    _changed();
    return wanted.finished;
  }

  ImportItem? _notebookOf(ImportItem export) {
    for (final ImportItem item in items) {
      if (item._kind == _FileKind.goodnotes &&
          item._file.notebookKey == export._file.notebookKey) {
        return item;
      }
    }
    return null;
  }

  /// The next file to load: one asked for, else the next in order.
  ImportItem? _next() {
    ImportItem? pick;
    while (_asked.isNotEmpty && pick == null) {
      final ImportItem asked = _asked.removeAt(0);
      if (asked.status == ImportStatus.waiting) pick = asked;
    }
    if (pick == null) {
      for (final ImportItem item in items) {
        if (item.status == ImportStatus.waiting) {
          pick = item;
          break;
        }
      }
    }
    if (pick != null && pick.isExport) {
      // An export waits for its notebook to be tried.
      final ImportItem? notebook = _notebookOf(pick);
      if (notebook != null && notebook.status == ImportStatus.waiting) {
        return notebook;
      }
    }
    return pick;
  }

  void _changed() {
    _pendingByFolder = null;
    notifyListeners();
  }

  void _end() {
    _ended = true;
    _pendingByFolder = null;
    for (final ImportItem item in items) {
      if (!item._finished.isCompleted) item._finished.complete();
    }
    notifyListeners();
  }
}

/// Finds the Goodnotes folder in Google Drive and replicates it into the
/// library: the same folders nested directly under the chosen destination,
/// with every `.goodnotes` notebook and PDF imported as a note in its folder.
/// A PDF that is only the export of a notebook beside it is left out.
///
/// It goes in two steps. [scan] reads every folder and file in Drive and
/// makes every folder in the library, so the whole structure can be shown at
/// once; [load] then brings the files in one at a time, a file asked for
/// first. [replicate] does both.
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

  /// Replicates [root] into [targetFolderId], or at the top of the library:
  /// [scan], then [load] every file.
  Future<ReplicationSummary> replicate(
    GoogleDriveItem root, {
    String? targetFolderId,
    ValueChanged<CloudProgress>? onProgress,
    ImportCancellationToken? cancellation,
  }) async {
    final ImportCancellationToken token =
        cancellation ?? ImportCancellationToken();
    final GoodnotesImportSession session = await scan(
      root,
      targetFolderId: targetFolderId,
      onProgress: onProgress,
      cancellation: token,
    );
    return load(session, onProgress: onProgress, cancellation: token);
  }

  /// Reads every folder under [root] and every file in them, and makes each
  /// folder in the library, under [targetFolderId] or at the top. Nothing is
  /// downloaded: the session returned lists every file, for the library to
  /// show, and is passed to [load] to bring them in.
  ///
  /// The folder tree is walked breadth first. Files imported by an earlier
  /// run and not changed since are already done in the session.
  Future<GoodnotesImportSession> scan(
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

    GoodnotesImportSession cancelled() => GoodnotesImportSession._(
      localRootId: targetFolderId,
      foldersCreated: created,
      foldersReused: reused,
      items: <ImportItem>[],
      scanCancelled: true,
      imports: <String, Object?>{},
      liveNotes: <String, NoteEntry>{},
    );

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
      if (token.isCancelled) return cancelled();
      final _RemoteFolder folder = queue.removeFirst();
      visited++;
      onProgress?.call(
        CloudProgress(
          phase: 'Reading folder $visited / ${visited + queue.length}',
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
    // notebook could not.
    final Set<String> notebookKeys = <String>{
      for (final _RemoteFile file in files)
        if (_kindOf(file.item) == _FileKind.goodnotes) file.notebookKey,
    };
    final Map<String, Object?> imports = _importsFrom(await state.read());
    final Map<String, NoteEntry> liveNotes = await _liveNotes();
    final List<ImportItem> items = <ImportItem>[];
    for (final _RemoteFile file in files) {
      final _FileKind? kind = _kindOf(file.item);
      final ImportItem item = ImportItem._(file, kind);
      items.add(item);
      if (kind == null) {
        item._settle(ImportStatus.skipped, reason: 'Not a notebook or PDF');
      } else if (kind == _FileKind.pdf &&
          notebookKeys.contains(file.notebookKey)) {
        item.isExport = true;
      } else {
        final NoteEntry? existing = _unchangedNote(imports, liveNotes, item);
        if (existing != null) {
          if (existing.folderId != file.localFolderId) {
            await repository.moveNote(existing.id, file.localFolderId);
          }
          item._settle(ImportStatus.unchanged, noteId: existing.id);
        }
      }
    }
    return GoodnotesImportSession._(
      localRootId: localRoot,
      foldersCreated: created,
      foldersReused: reused,
      items: items,
      scanCancelled: false,
      imports: imports,
      liveNotes: liveNotes,
    );
  }

  /// Brings in the files of [session], one at a time: one asked for with
  /// [GoodnotesImportSession.prioritize] before the rest, then the others in
  /// order. Cancelling stops before the next file, or rolls back the one
  /// being imported; the summary then says so, and notes already imported
  /// stay.
  Future<ReplicationSummary> load(
    GoodnotesImportSession session, {
    ValueChanged<CloudProgress>? onProgress,
    ImportCancellationToken? cancellation,
  }) async {
    final ImportCancellationToken token =
        cancellation ?? ImportCancellationToken();
    try {
      if (session.scanCancelled) return _summaryOf(session, cancelled: true);
      while (!token.isCancelled) {
        final ImportItem? item = session._next();
        if (item == null) break;
        final ({int done, int total}) counts = session.counts;
        onProgress?.call(
          CloudProgress(
            phase: 'Importing file ${counts.done + 1} of ${counts.total}',
            completedItems: counts.done,
            totalItems: counts.total,
            currentName: item.name,
          ),
        );
        item.status = ImportStatus.loading;
        session._changed();
        await _loadOne(session, item, token);
        session._changed();
      }
      if (token.isCancelled) return _summaryOf(session, cancelled: true);
      final ReplicationSummary summary = _summaryOf(session, cancelled: false);
      final int total = session.counts.total;
      onProgress?.call(
        CloudProgress(
          phase: 'Imported ${summary.imported.length} of $total files',
          completedItems: total,
          totalItems: total,
        ),
      );
      return summary;
    } finally {
      session._end();
    }
  }

  /// The live note an earlier run made from [item], if the file has not
  /// changed since.
  NoteEntry? _unchangedNote(
    Map<String, Object?> imports,
    Map<String, NoteEntry> liveNotes,
    ImportItem item,
  ) {
    final Object? previous = imports[item.driveId];
    if (previous is! Map<String, Object?>) return null;
    final String? noteId = previous['noteId'] as String?;
    final NoteEntry? entry = noteId == null ? null : liveNotes[noteId];
    final String modified =
        item._file.item.modifiedTime?.toUtc().toIso8601String() ?? '';
    return entry != null && previous['modified'] == modified ? entry : null;
  }

  Future<void> _loadOne(
    GoodnotesImportSession session,
    ImportItem item,
    ImportCancellationToken token,
  ) async {
    final _RemoteFile file = item._file;
    final _FileKind kind = item._kind!;
    final String modified =
        file.item.modifiedTime?.toUtc().toIso8601String() ?? '';
    final Object? previous = session._imports[item.driveId];
    final String? previousNote = previous is Map<String, Object?>
        ? previous['noteId'] as String?
        : null;
    final NoteEntry? previousEntry = previousNote == null
        ? null
        : session._liveNotes[previousNote];

    if (item.isExport) {
      final ImportItem? notebook = session._notebookOf(item);
      final bool notebookIn =
          notebook != null &&
          (notebook.status == ImportStatus.imported ||
              notebook.status == ImportStatus.unchanged);
      if (notebookIn) {
        // An export an earlier run imported goes to Recently Deleted.
        if (previousEntry != null) {
          await repository.deleteNote(previousEntry.id);
        }
        if (session._imports.remove(item.driveId) != null) {
          await state.update((Map<String, Object?> values) {
            values[_importsKey] = session._imports;
          });
        }
        item._settle(ImportStatus.covered);
        return;
      }
    }
    final NoteEntry? existing = _unchangedNote(
      session._imports,
      session._liveNotes,
      item,
    );
    if (existing != null) {
      if (existing.folderId != file.localFolderId) {
        await repository.moveNote(existing.id, file.localFolderId);
      }
      item._settle(ImportStatus.unchanged, noteId: existing.id);
      return;
    }

    final NoteEntry note;
    try {
      final PickedDocument picked = PickedDocument(
        name: file.item.name,
        bytes: await client.downloadFile(file.item.id),
      );
      if (token.isCancelled) {
        item.status = ImportStatus.waiting;
        return;
      }
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
      // A cancelled import has rolled its note back.
      if (token.isCancelled) {
        item.status = ImportStatus.waiting;
      } else {
        item._settle(ImportStatus.failed, reason: _reasonFor(error));
      }
      return;
    }
    if (previousEntry != null && previousEntry.id != note.id) {
      await repository.deleteNote(previousEntry.id);
    }
    session._imports[item.driveId] = <String, Object?>{
      'noteId': note.id,
      'modified': modified,
    };
    await state.update((Map<String, Object?> values) {
      values[_importsKey] = session._imports;
    });
    item._settle(ImportStatus.imported, noteId: note.id);
  }

  ReplicationSummary _summaryOf(
    GoodnotesImportSession session, {
    required bool cancelled,
  }) {
    return ReplicationSummary(
      localRootId: session.localRootId,
      foldersCreated: session.foldersCreated,
      foldersReused: session.foldersReused,
      imported: List<String>.unmodifiable(<String>[
        for (final ImportItem item in session.items)
          if (item.status == ImportStatus.imported) item.path,
      ]),
      unchanged: session.items
          .where((ImportItem item) => item.status == ImportStatus.unchanged)
          .length,
      skipped: List<ReplicationIssue>.unmodifiable(<ReplicationIssue>[
        for (final ImportItem item in session.items)
          if (item.status == ImportStatus.skipped)
            ReplicationIssue(item.path, item.reason ?? 'Not imported'),
      ]),
      failed: List<ReplicationIssue>.unmodifiable(<ReplicationIssue>[
        for (final ImportItem item in session.items)
          if (item.status == ImportStatus.failed)
            ReplicationIssue(item.path, item.reason ?? 'Could not be imported'),
      ]),
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
