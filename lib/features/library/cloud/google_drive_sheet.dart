import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../shared/widgets/processing.dart';
import '../library_screen.dart' show formatModified;
import 'auto_backup_scheduler.dart';
import 'backup_destinations.dart';
import 'cloud_sync_state.dart';
import 'cloud_task_controller.dart';
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
  CloudTaskController? tasks,
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
      tasks: tasks,
      onOpenFolder: onOpenFolder,
      clock: clock,
    ),
  );
}

class GoogleDriveSheet extends StatefulWidget {
  const GoogleDriveSheet({
    super.key,
    required this.client,
    required this.backup,
    required this.replicator,
    this.autoBackup,
    this.destinations,
    this.tasks,
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

  /// Where backups go. Offers the choice where there is one; [client] stays
  /// the Google account, which Goodnotes import needs whichever is chosen.
  final BackupDestinations? destinations;

  /// What runs the backup, restore and import. Kept by the library, so the
  /// work goes on when this is closed; without one, the work belongs to this
  /// and stops with it.
  final CloudTaskController? tasks;
  final ValueChanged<String>? onOpenFolder;
  final DateTime Function() clock;

  @override
  State<GoogleDriveSheet> createState() => _GoogleDriveSheetState();
}

class _GoogleDriveSheetState extends State<GoogleDriveSheet> {
  GoogleDriveAccount? _account;
  DateTime? _lastBackup;

  late final CloudTaskController _tasks =
      widget.tasks ?? CloudTaskController(clock: widget.clock);

  /// Whether the work is this sheet's own, and so ends with it.
  bool get _ownsTasks => widget.tasks == null;

  /// The outcome of what the sheet itself did, such as signing in; the
  /// outcome of the work is [_tasks]'s.
  String? _message;
  bool _messageIsError = false;

  bool get _busy => _tasks.busy;

  BackupTarget? get _target => widget.destinations?.current;
  GoogleDriveBackupService get _backupService =>
      _target?.backup ?? widget.backup;
  AutoBackupScheduler? get _scheduler =>
      _target?.scheduler ?? widget.autoBackup;
  String get _destinationName =>
      _target?.destination.label ?? BackupDestination.googleDrive.label;

  /// Whether there is somewhere to back up to right now.
  bool get _canBackUp {
    final BackupDestinations? destinations = widget.destinations;
    if (destinations == null || !destinations.offersChoice) {
      return _account != null;
    }
    return switch (destinations.current?.destination) {
      BackupDestination.iCloud => true,
      BackupDestination.googleDrive => _account != null,
      null => false,
    };
  }

  void _onDestinationChanged() {
    if (mounted) setState(() {});
    _loadLastBackup();
  }

  void _loadLastBackup() {
    final GoogleDriveBackupService backup = _backupService;
    backup.lastBackupAt().then((DateTime? time) {
      if (mounted && identical(backup, _backupService)) {
        setState(() => _lastBackup = time);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _tasks.addListener(_onTasksChanged);
    widget.destinations?.addListener(_onDestinationChanged);
    _account = widget.client.currentAccount;
    if (_account == null) {
      _restoreSession();
    } else {
      // Signed in from the Account button: let automatic backup run.
      _link(true);
    }
    _loadLastBackup();
  }

  @override
  void dispose() {
    widget.destinations?.removeListener(_onDestinationChanged);
    _tasks.removeListener(_onTasksChanged);
    // Work the library is running goes on without the sheet. Work of the
    // sheet's own stops with it; a note being imported is rolled back.
    if (_ownsTasks) _tasks.dispose();
    super.dispose();
  }

  void _onTasksChanged() {
    if (!mounted) return;
    if (_tasks.signInLost) _account = widget.client.currentAccount;
    setState(() {});
  }

  Future<void> _restoreSession() async {
    final GoogleDriveAccount? account = await widget.client.restoreSession();
    if (mounted && account != null && _account == null) {
      setState(() => _account = account);
      await _link(true);
    }
  }

  /// Records whether Drive is connected, so automatic backup knows whether
  /// it may run. Where there is a choice of destination, connecting never
  /// changes the one already chosen.
  Future<void> _link(bool linked) async {
    final BackupDestinations? destinations = widget.destinations;
    if (destinations != null) {
      if (linked) await destinations.googleConnected();
      return;
    }
    await widget.backup.setLinked(linked);
    await widget.autoBackup?.reschedule();
  }

  /// Asks the person to sign into Google, true once they have.
  Future<bool> _signInToGoogle() async {
    try {
      final GoogleDriveAccount? account = await widget.client.signIn();
      if (!mounted || account == null) return false;
      setState(() {
        _account = account;
        _message = null;
      });
      await _link(true);
      return mounted;
    } on GoogleDriveException catch (error) {
      if (mounted) _show(error.message, error: true);
      return false;
    } on Object {
      if (mounted) _show("Couldn't sign in to Google", error: true);
      return false;
    }
  }

  Future<void> _chooseDestination(BackupDestination destination) async {
    final BackupDestinations destinations = widget.destinations!;
    switch (destination) {
      case BackupDestination.googleDrive:
        if (_account == null && !await _signInToGoogle()) return;
      case BackupDestination.iCloud:
        try {
          await destinations.iCloud!.client.signIn();
        } on GoogleDriveException catch (error) {
          if (mounted) _show(error.message, error: true);
          return;
        }
    }
    await destinations.choose(destination);
    if (mounted) {
      _show(
        'Your library now backs up to ${destination.label}. Any backup '
        'already in the other place stays there.',
      );
    }
  }

  void _show(String message, {bool error = false}) {
    setState(() {
      _message = message;
      _messageIsError = error;
    });
  }

  Future<void> _backUp() async {
    setState(() => _message = null);
    final GoogleDriveBackupService service = _backupService;
    await _tasks.backUp(service);
    if (mounted && identical(service, _backupService)) _loadLastBackup();
  }

  Future<void> _restore() async {
    final RestoreMode? mode = await showAppDialog<RestoreMode>(
      context: context,
      motionKey: 'drive-restore',
      builder: (BuildContext context) => AlertDialog(
        title: Text('Restore from $_destinationName?'),
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
    setState(() => _message = null);
    await _tasks.restore(_backupService, mode);
  }

  Future<void> _importGoodnotes() async {
    // Goodnotes is read from Google Drive, whichever way the person signed
    // into Etonia and wherever they back up to.
    if (_account == null && !await _signInToGoogle()) return;
    setState(() => _message = null);
    await _tasks.importGoodnotes(
      widget.replicator,
      // With the sheet closed there is no one to ask: the folder that is
      // listed first is the one used by default.
      pickRoot: (List<GoodnotesDriveRoot> roots) async =>
          mounted ? await _pickRoot(roots) : roots.first,
    );
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

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final GoogleDriveAccount? account = _account;
    final bool canAct = _canBackUp && !_busy;
    final bool offersChoice = widget.destinations?.offersChoice ?? false;
    final Widget connection = _ConnectionCard(
      account: account,
      onSignIn: _busy ? null : _signInToGoogle,
    );
    final List<Widget> cards = <Widget>[
      if (offersChoice) ...<Widget>[
        _DestinationPicker(
          selected: _target?.destination,
          enabled: !_busy,
          onChanged: _chooseDestination,
        ),
        const SizedBox(height: AppSpacing.md),
      ] else ...<Widget>[connection, const SizedBox(height: AppSpacing.md)],
      _BackupCard(
        lastBackup: _lastBackup,
        now: widget.clock(),
        scheduler: _scheduler,
        enabled: canAct,
        onBackUp: _backUp,
        onRestore: _restore,
      ),
      const SizedBox(height: AppSpacing.md),
      if (offersChoice) ...<Widget>[
        connection,
        const SizedBox(height: AppSpacing.md),
      ],
      _GoodnotesCard(
        enabled: !_busy,
        signedIn: account != null,
        onImport: _importGoodnotes,
      ),
      if (_busy) ...<Widget>[
        const SizedBox(height: AppSpacing.lg),
        _ProgressPanel(
          progress: _tasks.progress,
          destinationName: _tasks.task == CloudTask.replicate
              ? BackupDestination.googleDrive.label
              : _destinationName,
          onCancel: _tasks.canCancel ? _tasks.cancel : null,
          cancelling: _tasks.cancelling,
          keepsGoing: !_ownsTasks,
        ),
      ],
      if (!_busy && (_tasks.message ?? _message) != null) ...<Widget>[
        const SizedBox(height: AppSpacing.lg),
        _ResultPanel(
          message: (_tasks.message ?? _message)!,
          error: _tasks.message != null
              ? _tasks.messageIsError
              : _messageIsError,
          issues: _tasks.issues,
          onOpenFolder:
              _tasks.replicatedFolderId == null || widget.onOpenFolder == null
              ? null
              : () {
                  final String id = _tasks.replicatedFolderId!;
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

/// Where backups go: one or the other, on the device's iCloud account or a
/// Google account, however the person signed into Etonia.
class _DestinationPicker extends StatelessWidget {
  const _DestinationPicker({
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  final BackupDestination? selected;
  final bool enabled;
  final ValueChanged<BackupDestination> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return _DriveCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('Back up to', style: text.titleMedium),
          const SizedBox(height: AppSpacing.xxs),
          Text(switch (selected) {
            BackupDestination.iCloud =>
              'Uses the iCloud account on this device.',
            BackupDestination.googleDrive => 'Uses your Google account.',
            null => 'Choose where your library is backed up.',
          }, style: text.bodySmall!.copyWith(color: colors.textSecondary)),
          const SizedBox(height: AppSpacing.sm),
          SegmentedButton<BackupDestination>(
            emptySelectionAllowed: true,
            showSelectedIcon: false,
            segments: <ButtonSegment<BackupDestination>>[
              for (final BackupDestination destination
                  in BackupDestination.values)
                ButtonSegment<BackupDestination>(
                  value: destination,
                  label: Text(destination.label),
                ),
            ],
            selected: <BackupDestination>{?selected},
            onSelectionChanged: enabled
                ? (Set<BackupDestination> chosen) {
                    // Tapping the one chosen leaves it chosen.
                    if (chosen.isNotEmpty) onChanged(chosen.first);
                  }
                : null,
          ),
        ],
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
  const _GoodnotesCard({
    required this.enabled,
    required this.signedIn,
    required this.onImport,
  });

  final bool enabled;
  final bool signedIn;
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
                      signedIn
                          ? 'Bring in every notebook and PDF while keeping your '
                                'folder structure.'
                          : 'Bring in every notebook and PDF while keeping your '
                                'folder structure. You will be asked to sign in '
                                'with Google.',
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
  const _ConnectionCard({required this.account, required this.onSignIn});

  final GoogleDriveAccount? account;

  /// Null while it cannot be done.
  final VoidCallback? onSignIn;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final GoogleDriveAccount? account = this.account;
    final String title = account == null ? 'Not connected' : account.label;
    final String detail = account == null
        ? 'Sign in with Google to import from Goodnotes and to back up to Google Drive.'
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
            if (account == null) ...<Widget>[
              const SizedBox(width: AppSpacing.sm),
              OutlinedButton(
                key: const ValueKey<String>('drive-sign-in-google'),
                onPressed: onSignIn,
                child: const Text('Sign in'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProgressPanel extends StatelessWidget {
  const _ProgressPanel({
    required this.progress,
    required this.destinationName,
    required this.onCancel,
    required this.cancelling,
    required this.keepsGoing,
  });

  final CloudProgress? progress;
  final String destinationName;

  /// Whether the work carries on if this is closed, which it says.
  final bool keepsGoing;

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
                semanticsLabel: '$destinationName progress',
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
          if (keepsGoing) ...<Widget>[
            const SizedBox(height: AppSpacing.xxs),
            Text(
              'This keeps going if you leave this page.',
              style: text.bodySmall!.copyWith(color: colors.textSecondary),
            ),
          ],
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
