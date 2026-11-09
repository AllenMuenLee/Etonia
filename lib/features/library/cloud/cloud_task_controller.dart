import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../editor/document_io/document_importer.dart';
import '../library_screen.dart' show formatModified;
import 'cloud_sync_state.dart';
import 'goodnotes_drive_replicator.dart';
import 'google_drive_backup_service.dart';
import 'google_drive_client.dart';

/// What the person asked the cloud to do.
enum CloudTask { backUp, restore, replicate }

/// Runs a backup, a restore or a Goodnotes import, and keeps what it is
/// doing and how it ended.
///
/// It belongs to the library, not to the page that asked for the work, so
/// leaving that page, or closing the sheet, does not stop it: only
/// [cancel], or the library going away, does. Pages show it by listening.
///
/// Only one task runs at a time.
class CloudTaskController extends ChangeNotifier {
  CloudTaskController({DateTime Function() clock = DateTime.now})
    // ignore: prefer_initializing_formals
    : _clock = clock;

  final DateTime Function() _clock;

  CloudTask? _task;
  CloudProgress? _progress;
  ImportCancellationToken? _cancellation;
  String? _message;
  bool _messageIsError = false;
  List<ReplicationIssue> _issues = const <ReplicationIssue>[];
  String? _replicatedFolderId;
  GoodnotesImportSession? _session;
  DateTime? _lastBackup;
  bool _signInLost = false;
  bool _goodnotesMissing = false;
  bool _disposed = false;

  /// What is running, or null.
  CloudTask? get task => _task;
  bool get busy => _task != null;

  CloudProgress? get progress => _progress;

  /// How the last task ended, and whether that was a failure.
  String? get message => _message;
  bool get messageIsError => _messageIsError;

  /// Files the last Goodnotes import left out, and why.
  List<ReplicationIssue> get issues => _issues;

  /// The library folder the last Goodnotes import went into; null is the
  /// library root, or no import has finished.
  String? get replicatedFolderId => _replicatedFolderId;

  /// The Goodnotes import under way, listing every folder and file in it; null
  /// when there is none.
  GoodnotesImportSession? get session => _session;

  /// When the last backup this controller made finished.
  DateTime? get lastBackup => _lastBackup;

  /// The last task failed because Google no longer accepts the sign-in.
  bool get signInLost => _signInLost;

  /// The last Goodnotes import found no Goodnotes folder in Drive: it has not
  /// been synced there yet.
  bool get goodnotesFolderMissing => _goodnotesMissing;

  bool get cancelling => _cancellation?.isCancelled ?? false;

  /// A restore past the point of downloading is not stopped part way: it
  /// would leave the library half changed.
  bool get canCancel =>
      busy &&
      !cancelling &&
      !(_task == CloudTask.restore && _progress?.phase == 'Restoring library');

  /// Asks the running task to stop; what it has finished is kept.
  void cancel() {
    if (!canCancel) return;
    _cancellation?.cancel();
    _notify();
  }

  /// Forgets how the last task ended, once it has been seen.
  void dismissMessage() {
    if (_message == null || busy) return;
    _message = null;
    _issues = const <ReplicationIssue>[];
    _replicatedFolderId = null;
    _notify();
  }

  /// Backs up, true if it completed. With [quiet], as for an automatic backup,
  /// the progress shows but how it ended is not kept: there is no summary to
  /// read and no error left in the sheet, and a message already waiting to be
  /// seen stays. False too if another task was running and this one did not.
  Future<bool> backUp(GoogleDriveBackupService service, {bool quiet = false}) {
    return _run(CloudTask.backUp, quiet: quiet, (
      ImportCancellationToken cancellation,
      ValueChanged<CloudProgress> onProgress,
    ) async {
      final BackupSummary summary = await service.backUp(
        onProgress: onProgress,
        cancellation: cancellation,
      );
      _lastBackup = summary.exportedAt;
      if (quiet) return;
      _show(
        <String>[
          'Backed up ${_count(summary.noteCount, 'note')} and '
              '${_count(summary.folderCount, 'folder')}. '
              '${summary.uploadedFiles} uploaded, '
              '${summary.unchangedFiles} already up to date.',
          if (summary.addedHere > 0)
            '${_count(summary.addedHere, 'note')} from other devices added.',
          if (summary.movedToDeleted > 0)
            '${_count(summary.movedToDeleted, 'note')} deleted elsewhere '
                'moved to Recently Deleted.',
          if (summary.deletedForGood > 0)
            '${_count(summary.deletedForGood, 'note')} deleted for good '
                'elsewhere removed.',
        ].join(' '),
      );
    });
  }

  Future<bool> restore(GoogleDriveBackupService service, RestoreMode mode) {
    return _run(CloudTask.restore, (
      ImportCancellationToken cancellation,
      ValueChanged<CloudProgress> onProgress,
    ) async {
      final RestoreSummary summary = await service.restore(
        mode: mode,
        onProgress: onProgress,
        cancellation: cancellation,
      );
      _show(
        <String>[
          'Restored ${_count(summary.notesRestored, 'note')} from the backup '
              'of ${formatModified(summary.exportedAt, _clock())}.',
          if (summary.notesSkipped > 0)
            'Skipped ${_count(summary.notesSkipped, 'note')} already here.',
          if (summary.deletedRestored > 0)
            '${_count(summary.deletedRestored, 'note')} put back in Recently '
                'Deleted.',
        ].join(' '),
      );
    });
  }

  /// Imports the Goodnotes folder in Drive: first the whole tree is read and
  /// every folder and file listed, which the library shows through
  /// [session], then the files come in one at a time, [prioritize] moving one
  /// to the front. [pickRoot] chooses between several Goodnotes folders; null
  /// ends the import.
  Future<bool> importGoodnotes(
    GoodnotesDriveReplicator replicator, {
    required Future<GoodnotesDriveRoot?> Function(List<GoodnotesDriveRoot>)
    pickRoot,
  }) {
    return _run(CloudTask.replicate, (
      ImportCancellationToken cancellation,
      ValueChanged<CloudProgress> onProgress,
    ) async {
      onProgress(
        const CloudProgress(
          phase: 'Looking for your Goodnotes folder',
          completedItems: 0,
          totalItems: 0,
        ),
      );
      final List<GoodnotesDriveRoot> roots = await replicator.findRoots();
      if (_disposed || cancellation.isCancelled) return;
      final GoodnotesDriveRoot? root = roots.length == 1
          ? roots.single
          : await pickRoot(roots);
      if (root == null || _disposed) return;
      final GoodnotesImportSession session = await replicator.scan(
        root.folder,
        onProgress: onProgress,
        cancellation: cancellation,
      );
      // Every folder is in the library and every file is listed: the library
      // shows them now, and each as it arrives.
      _session = session..addListener(_notify);
      _notify();
      final ReplicationSummary summary;
      try {
        summary = await replicator.load(
          session,
          onProgress: onProgress,
          cancellation: cancellation,
        );
      } finally {
        session.removeListener(_notify);
        _session = null;
      }
      final int notImported = summary.skipped.length + summary.failed.length;
      _issues = <ReplicationIssue>[...summary.failed, ...summary.skipped];
      _replicatedFolderId = summary.localRootId;
      _show(
        <String>[
          if (summary.cancelled) 'Stopped.',
          'Imported ${_count(summary.imported.length, 'file')} into '
              '${summary.localRootId == null ? 'Library' : root.folder.name}.',
          if (summary.unchanged > 0) '${summary.unchanged} already up to date.',
          if (notImported > 0) '$notImported not imported.',
        ].join(' '),
      );
    });
  }

  /// Has [item] of the Goodnotes import loaded next, and completes when it is
  /// in the library, or the import has ended.
  Future<void> prioritize(ImportItem item) {
    final GoodnotesImportSession? session = _session;
    if (session == null) return item.finished;
    return session.prioritize(item);
  }

  /// Runs [work], true if it finished without an error or a cancel.
  Future<bool> _run(
    CloudTask task,
    Future<void> Function(
      ImportCancellationToken cancellation,
      ValueChanged<CloudProgress> onProgress,
    )
    work, {
    bool quiet = false,
  }) async {
    if (busy || _disposed) return false;
    final ImportCancellationToken cancellation = ImportCancellationToken();
    _task = task;
    _progress = null;
    if (!quiet) {
      _message = null;
      _messageIsError = false;
      _issues = const <ReplicationIssue>[];
      _replicatedFolderId = null;
      _signInLost = false;
      _goodnotesMissing = false;
    }
    _cancellation = cancellation;
    _notify();
    var completed = false;
    try {
      await work(cancellation, (CloudProgress progress) {
        _progress = progress;
        _notify();
      });
      completed = !cancellation.isCancelled;
    } on Object catch (error) {
      if (!quiet) {
        if (error is GoogleDriveException &&
            error.kind == GoogleDriveErrorKind.unauthorized) {
          _signInLost = true;
        }
        _goodnotesMissing = error is GoodnotesFolderNotFoundException;
        _message = _describe(error);
        _messageIsError = error is! CloudCancelledException;
      }
    } finally {
      _task = null;
      _progress = null;
      _cancellation = null;
      _session = null;
      _notify();
    }
    return completed;
  }

  void _show(String message) {
    _message = message;
    _messageIsError = false;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static String _describe(Object error) {
    return switch (error) {
      CloudCancelledException() => 'Cancelled',
      GoogleDriveException(:final String message) => message,
      GoogleDriveBackupException(:final String message) => message,
      GoodnotesFolderNotFoundException() => noGoodnotesFolderMessage,
      _ => 'Something went wrong. Try again.',
    };
  }

  static String _count(int count, String noun) =>
      '$count $noun${count == 1 ? '' : 's'}';

  @override
  void dispose() {
    // The library is going away, and takes what it was doing with it; a note
    // being imported is rolled back.
    _cancellation?.cancel();
    _disposed = true;
    super.dispose();
  }
}
