import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../shared/widgets/processing.dart';
import '../../editor/document_io/document_importer.dart';
import '../library_screen.dart' show formatModified;
import 'auto_backup_scheduler.dart';
import 'cloud_sync_state.dart';
import 'goodnotes_drive_replicator.dart';
import 'google_drive_backup_service.dart';
import 'google_drive_client.dart';
import '../../../shared/navigation/app_dialogs.dart';
import '../../../shared/navigation/app_sheets.dart';

/// Shows the Google Drive sheet: the connection, backup and restore, and
/// importing the Goodnotes folder. [onOpenFolder] shows a non-root library
/// destination when one is used.
Future<void> showGoogleDriveSheet(
  BuildContext context, {
  required GoogleDriveClient client,
  required GoogleDriveBackupService backup,
  required GoodnotesDriveReplicator replicator,
  AutoBackupScheduler? autoBackup,
  ValueChanged<String>? onOpenFolder,
  DateTime Function() clock = DateTime.now,
}) {
  return showAppSheet<void>(
    context: context,
    motionKey: 'google-drive',
    builder: (BuildContext context) => GoogleDriveSheet(
      client: client,
      backup: backup,
      replicator: replicator,
      autoBackup: autoBackup,
      onOpenFolder: onOpenFolder,
      clock: clock,
    ),
  );
}

enum _Task { backUp, restore, replicate }

class GoogleDriveSheet extends StatefulWidget {
  const GoogleDriveSheet({
    super.key,
    required this.client,
    required this.backup,
    required this.replicator,
    this.autoBackup,
    this.onOpenFolder,
    this.clock = DateTime.now,
    this.embedded = false,
  });

  /// Shown inside another page, as a section: just the cards, with no
  /// header, scrolling or width of its own.
  final bool embedded;

  final GoogleDriveClient client;
  final GoogleDriveBackupService backup;
  final GoodnotesDriveReplicator replicator;

  /// Offers the choice of how often to back up on its own; without one
  /// the choice is not shown.
  final AutoBackupScheduler? autoBackup;
  final ValueChanged<String>? onOpenFolder;
  final DateTime Function() clock;

  @override
  State<GoogleDriveSheet> createState() => _GoogleDriveSheetState();
}

class _GoogleDriveSheetState extends State<GoogleDriveSheet> {
  GoogleDriveAccount? _account;
  DateTime? _lastBackup;
  _Task? _task;
  CloudProgress? _progress;
  ImportCancellationToken? _cancellation;

  /// The outcome of the last action, and whether it was a failure.
  String? _message;
  bool _messageIsError = false;
  List<ReplicationIssue> _issues = const <ReplicationIssue>[];
  String? _replicatedFolderId;

  bool get _busy => _task != null;

  @override
  void initState() {
    super.initState();
    _account = widget.client.currentAccount;
    if (_account == null) {
      _restoreSession();
    } else {
      // Signed in from the Account button: let automatic backup run.
      _link(true);
    }
    widget.backup.lastBackupAt().then((DateTime? time) {
      if (mounted) setState(() => _lastBackup = time);
    });
  }

  @override
  void dispose() {
    // A closed sheet stops what it started; a note being imported is
    // rolled back.
    _cancellation?.cancel();
    super.dispose();
  }

  Future<void> _restoreSession() async {
    final GoogleDriveAccount? account = await widget.client.restoreSession();
    if (mounted && account != null && _account == null) {
      setState(() => _account = account);
      await _link(true);
    }
  }

  /// Records whether Drive is connected, so automatic backup knows whether
  /// it may run.
  Future<void> _link(bool linked) async {
    await widget.backup.setLinked(linked);
    await widget.autoBackup?.reschedule();
  }

  void _show(String message, {bool error = false}) {
    setState(() {
      _message = message;
      _messageIsError = error;
    });
  }

  /// Runs [work] as [task], with progress and a way to cancel it, and
  /// shows what went wrong if it fails.
  Future<void> _run(
    _Task task,
    Future<void> Function(
      ImportCancellationToken cancellation,
      ValueChanged<CloudProgress> onProgress,
    )
    work,
  ) async {
    final ImportCancellationToken cancellation = ImportCancellationToken();
    setState(() {
      _task = task;
      _progress = null;
      _message = null;
      _issues = const <ReplicationIssue>[];
      _replicatedFolderId = null;
      _cancellation = cancellation;
    });
    try {
      await work(cancellation, (CloudProgress progress) {
        if (mounted) setState(() => _progress = progress);
      });
    } on Object catch (error) {
      if (!mounted) return;
      if (error is GoogleDriveException &&
          error.kind == GoogleDriveErrorKind.unauthorized) {
        _account = widget.client.currentAccount;
      }
      _show(_describe(error), error: error is! CloudCancelledException);
    } finally {
      if (mounted) {
        setState(() {
          _task = null;
          _progress = null;
          _cancellation = null;
        });
      }
    }
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

  Future<void> _backUp() async {
    await _run(_Task.backUp, (
      ImportCancellationToken cancellation,
      ValueChanged<CloudProgress> onProgress,
    ) async {
      final BackupSummary summary = await widget.backup.backUp(
        onProgress: onProgress,
        cancellation: cancellation,
      );
      if (!mounted) return;
      setState(() => _lastBackup = summary.exportedAt);
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

  Future<void> _restore() async {
    final RestoreMode? mode = await showAppDialog<RestoreMode>(
      context: context,
      motionKey: 'drive-restore',
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Restore from Google Drive?'),
        content: const Text(
          'Add the backup to this library, keeping what is here, or replace '
          'the library with it. Replaced notes go to Recently Deleted.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(RestoreMode.replace),
            child: const Text('Replace library'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(RestoreMode.merge),
            child: const Text('Add to library'),
          ),
        ],
      ),
    );
    if (mode == null || !mounted) return;
    await _run(_Task.restore, (
      ImportCancellationToken cancellation,
      ValueChanged<CloudProgress> onProgress,
    ) async {
      final RestoreSummary summary = await widget.backup.restore(
        mode: mode,
        onProgress: onProgress,
        cancellation: cancellation,
      );
      if (!mounted) return;
      _show(
        <String>[
          'Restored ${_count(summary.notesRestored, 'note')} from the backup '
              'of ${formatModified(summary.exportedAt, widget.clock())}.',
          if (summary.notesSkipped > 0)
            'Skipped ${_count(summary.notesSkipped, 'note')} already here.',
          if (summary.deletedRestored > 0)
            '${_count(summary.deletedRestored, 'note')} put back in Recently '
                'Deleted.',
        ].join(' '),
      );
    });
  }

  Future<void> _importGoodnotes() async {
    await _run(_Task.replicate, (
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
      final List<GoodnotesDriveRoot> roots = await widget.replicator
          .findRoots();
      if (!mounted || cancellation.isCancelled) return;
      final GoodnotesDriveRoot? root = roots.length == 1
          ? roots.single
          : await _pickRoot(roots);
      if (root == null || !mounted) return;
      final ReplicationSummary summary = await widget.replicator.replicate(
        root.folder,
        onProgress: onProgress,
        cancellation: cancellation,
      );
      if (!mounted) return;
      final int notImported = summary.skipped.length + summary.failed.length;
      setState(() {
        _issues = <ReplicationIssue>[...summary.failed, ...summary.skipped];
        _replicatedFolderId = summary.localRootId;
      });
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

  Future<GoodnotesDriveRoot?> _pickRoot(List<GoodnotesDriveRoot> roots) {
    return showAppDialog<GoodnotesDriveRoot>(
      context: context,
      motionKey: 'drive-root',
      builder: (BuildContext context) {
        final DateTime now = widget.clock();
        return SimpleDialog(
          title: const Text('Choose a Goodnotes folder'),
          children: <Widget>[
            for (final GoodnotesDriveRoot root in roots)
              SimpleDialogOption(
                onPressed: () => Navigator.of(context).pop(root),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AppSizes.minTouchTarget,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Text(root.location),
                      if (root.folder.modifiedTime != null)
                        Text(
                          'Modified '
                          '${formatModified(root.folder.modifiedTime!.toLocal(), now)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  static String _count(int count, String noun) =>
      '$count $noun${count == 1 ? '' : 's'}';

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final GoogleDriveAccount? account = _account;
    final bool connected = account != null;
    final bool canAct = connected && !_busy;
    final List<Widget> cards = <Widget>[
      _ConnectionCard(account: account),
      const SizedBox(height: AppSpacing.md),
      _BackupCard(
        lastBackup: _lastBackup,
        now: widget.clock(),
        scheduler: widget.autoBackup,
        enabled: canAct,
        onBackUp: _backUp,
        onRestore: _restore,
      ),
      const SizedBox(height: AppSpacing.md),
      _GoodnotesCard(enabled: canAct, onImport: _importGoodnotes),
      if (_busy) ...<Widget>[
        const SizedBox(height: AppSpacing.lg),
        _ProgressPanel(
          progress: _progress,
          onCancel:
              _task == _Task.restore && _progress?.phase == 'Restoring library'
              ? null
              : () {
                  _cancellation?.cancel();
                  setState(() {});
                },
          cancelling: _cancellation?.isCancelled ?? false,
        ),
      ],
      if (_message != null) ...<Widget>[
        const SizedBox(height: AppSpacing.lg),
        _ResultPanel(
          message: _message!,
          error: _messageIsError,
          issues: _issues,
          onOpenFolder:
              _replicatedFolderId == null || widget.onOpenFolder == null
              ? null
              : () {
                  final String id = _replicatedFolderId!;
                  // Back to the library, which then shows the folder.
                  Navigator.of(context).pop();
                  widget.onOpenFolder!(id);
                },
        ),
      ],
    ];
    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: cards,
      );
    }
    return SafeArea(
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              0,
              AppSpacing.lg,
              AppSpacing.lg,
            ),
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(AppIcons.cloud, size: 20, color: colors.textSecondary),
                  const SizedBox(width: AppSpacing.sm),
                  Semantics(
                    header: true,
                    child: Text('Google Drive', style: text.titleLarge),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              ...cards,
            ],
          ),
        ),
      ),
    );
  }
}

class _BackupCard extends StatelessWidget {
  const _BackupCard({
    required this.lastBackup,
    required this.now,
    required this.scheduler,
    required this.enabled,
    required this.onBackUp,
    required this.onRestore,
  });

  final DateTime? lastBackup;
  final DateTime now;
  final AutoBackupScheduler? scheduler;
  final bool enabled;
  final VoidCallback onBackUp;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return _DriveCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const _CardIcon(icon: AppIcons.cloudUpload),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('Library backup', style: text.titleMedium),
                    const SizedBox(height: AppSpacing.xxs),
                    Text(
                      lastBackup == null
                          ? 'Not backed up yet'
                          : 'Last backed up ${formatModified(lastBackup!, now)}',
                      style: text.bodySmall!.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              _BackupMenu(enabled: enabled, onRestore: onRestore),
            ],
          ),
          if (scheduler case final AutoBackupScheduler scheduler) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            _AutoBackupControl(scheduler: scheduler),
          ],
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
            onPressed: enabled ? onBackUp : null,
            icon: const Icon(AppIcons.cloudUpload),
            label: const Text('Back up library now'),
          ),
        ],
      ),
    );
  }
}

class _BackupMenu extends StatelessWidget {
  const _BackupMenu({required this.enabled, required this.onRestore});

  final bool enabled;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      animated: !MediaQuery.disableAnimationsOf(context),
      alignmentOffset: const Offset(0, AppSpacing.xxs),
      menuChildren: <Widget>[
        MenuItemButton(
          leadingIcon: const Icon(AppIcons.restore),
          onPressed: enabled ? onRestore : null,
          child: const Text('Restore from backup'),
        ),
      ],
      builder: (BuildContext context, MenuController menu, Widget? child) {
        return IconButton(
          tooltip: 'Backup options',
          onPressed: enabled
              ? () => menu.isOpen ? menu.close() : menu.open()
              : null,
          icon: const Icon(AppIcons.more),
        );
      },
    );
  }
}

/// A calm two-level control: the switch answers whether automatic backups
/// happen, and the schedule only appears when it is relevant.
class _AutoBackupControl extends StatelessWidget {
  const _AutoBackupControl({required this.scheduler});

  final AutoBackupScheduler scheduler;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return ValueListenableBuilder<Duration>(
      valueListenable: scheduler.interval,
      builder: (BuildContext context, Duration interval, _) {
        final bool automatic = interval != AutoBackupScheduler.off;
        return AnimatedContainer(
          duration: AppMotion.resolve(context, AppMotion.fadeIn),
          curve: AppMotion.fadeInCurve,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.xs,
            AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: automatic ? colors.selected : colors.surface,
            borderRadius: AppBorderRadius.medium,
          ),
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('Automatic backup', style: text.titleSmall),
                        const SizedBox(height: AppSpacing.xxs),
                        Text(
                          automatic
                              ? 'Keeps your library protected in the background'
                              : 'Turn on scheduled cloud backups',
                          style: text.bodySmall!.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Semantics(
                    label: 'Automatic backup',
                    child: Switch(
                      value: automatic,
                      onChanged: (bool value) {
                        scheduler.setInterval(
                          value
                              ? AutoBackupScheduler.defaultInterval
                              : AutoBackupScheduler.off,
                        );
                      },
                    ),
                  ),
                ],
              ),
              if (automatic) ...<Widget>[
                const SizedBox(height: AppSpacing.xs),
                Divider(color: colors.divider),
                Padding(
                  padding: const EdgeInsets.only(left: AppSpacing.xxs),
                  child: Row(
                    children: <Widget>[
                      Text('Frequency', style: text.bodyMedium),
                      const SizedBox(width: AppSpacing.sm),
                      Flexible(
                        child: Semantics(
                          label: 'Automatic backup frequency',
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<Duration>(
                              isExpanded: true,
                              alignment: AlignmentDirectional.centerEnd,
                              value:
                                  AutoBackupScheduler.choices.contains(interval)
                                  ? interval
                                  : null,
                              hint: Text(
                                AutoBackupScheduler.describe(interval),
                              ),
                              borderRadius: AppBorderRadius.medium,
                              onChanged: (Duration? every) {
                                if (every != null) {
                                  scheduler.setInterval(every);
                                }
                              },
                              items: <DropdownMenuItem<Duration>>[
                                for (final Duration every
                                    in AutoBackupScheduler.choices)
                                  if (every != AutoBackupScheduler.off)
                                    DropdownMenuItem<Duration>(
                                      value: every,
                                      child: Text(
                                        AutoBackupScheduler.describe(every),
                                      ),
                                    ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _GoodnotesCard extends StatelessWidget {
  const _GoodnotesCard({required this.enabled, required this.onImport});

  final bool enabled;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return _DriveCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const _CardIcon(icon: AppIcons.goodnotes),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('Import from Goodnotes', style: text.titleMedium),
                    const SizedBox(height: AppSpacing.xxs),
                    Text(
                      'Bring in every notebook and PDF while keeping your '
                      'folder structure.',
                      style: text.bodySmall!.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          OutlinedButton.icon(
            onPressed: enabled ? onImport : null,
            icon: const Icon(AppIcons.cloudDownload),
            label: const Text('Import Goodnotes folder from Drive'),
          ),
        ],
      ),
    );
  }
}

class _DriveCard extends StatelessWidget {
  const _DriveCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: AppBorderRadius.large,
        border: Border.all(color: colors.divider, width: AppSizes.hairline),
      ),
      child: child,
    );
  }
}

class _CardIcon extends StatelessWidget {
  const _CardIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: colors.selected,
        borderRadius: AppBorderRadius.medium,
      ),
      child: Icon(icon, size: 20, color: colors.accent),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.account});

  final GoogleDriveAccount? account;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final GoogleDriveAccount? account = this.account;
    final String title = account == null ? 'Not connected' : account.label;
    final String detail = account == null
        ? 'Sign in from the Account button to back up your library and import from Goodnotes.'
        : account.email;
    return Semantics(
      container: true,
      label: account == null
          ? 'Google Drive is not connected'
          : 'Connected to Google Drive as ${account.email}',
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: AppBorderRadius.large,
        ),
        child: Row(
          children: <Widget>[
            Icon(
              AppIcons.account,
              size: 28,
              color: account == null ? colors.textSecondary : colors.accent,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: text.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      detail,
                      style: text.bodySmall!.copyWith(
                        color: colors.textSecondary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressPanel extends StatelessWidget {
  const _ProgressPanel({
    required this.progress,
    required this.onCancel,
    required this.cancelling,
  });

  final CloudProgress? progress;

  /// Null while the work can no longer be stopped.
  final VoidCallback? onCancel;
  final bool cancelling;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final CloudProgress? progress = this.progress;
    final double? fraction = progress?.fraction;
    final String phase = cancelling
        ? 'Stopping…'
        : progress?.phase ?? 'Starting…';
    return Semantics(
      container: true,
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // The phase and the figure rise into place as they change, and
          // the file being worked on breathes while it is.
          Row(
            children: <Widget>[
              Expanded(
                child: GentleSwitcher(
                  value: phase,
                  child: Text(phase, style: text.titleSmall),
                ),
              ),
              ProgressCount(
                value: fraction,
                semanticsLabel: 'Google Drive progress',
                style: text.titleSmall!.copyWith(color: colors.textSecondary),
              ),
            ],
          ),
          if (progress?.currentName != null)
            Breathe(
              active: !cancelling,
              child: Text(
                progress!.currentName!,
                style: text.bodySmall!.copyWith(color: colors.textSecondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          const SizedBox(height: AppSpacing.xs),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, AppSizes.minTouchTarget),
              ),
              onPressed: cancelling ? null : onCancel,
              child: const Text('Cancel'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultPanel extends StatelessWidget {
  const _ResultPanel({
    required this.message,
    required this.error,
    required this.issues,
    required this.onOpenFolder,
  });

  final String message;
  final bool error;
  final List<ReplicationIssue> issues;
  final VoidCallback? onOpenFolder;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: AppBorderRadius.large,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Semantics(
            liveRegion: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (error) ...<Widget>[
                  Icon(AppIcons.warning, size: 18, color: colors.danger),
                  const SizedBox(width: AppSpacing.xs),
                ],
                Expanded(
                  child: Text(
                    message,
                    style: text.bodyMedium!.copyWith(
                      color: error ? colors.danger : colors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (issues.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            for (final ReplicationIssue issue in issues.take(20))
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xxs),
                child: Text(
                  '${issue.path} — ${issue.reason}',
                  style: text.bodySmall!.copyWith(color: colors.textSecondary),
                ),
              ),
            if (issues.length > 20)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xxs),
                child: Text(
                  'and ${issues.length - 20} more',
                  style: text.bodySmall!.copyWith(color: colors.textSecondary),
                ),
              ),
          ],
          if (onOpenFolder != null) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, AppSizes.minTouchTarget),
                ),
                onPressed: onOpenFolder,
                child: const Text('Show folder'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
