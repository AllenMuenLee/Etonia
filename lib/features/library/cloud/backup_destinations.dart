import 'package:flutter/foundation.dart';

import 'auto_backup_scheduler.dart';
import 'google_drive_backup_service.dart';
import 'google_drive_client.dart';

/// Where the library can be backed up.
enum BackupDestination {
  iCloud('iCloud'),
  googleDrive('Google Drive');

  const BackupDestination(this.label);

  final String label;
}

/// One place to back up to, with what backs up to it.
@immutable
class BackupTarget {
  const BackupTarget({
    required this.destination,
    required this.client,
    required this.backup,
    required this.scheduler,
  });

  final BackupDestination destination;
  final GoogleDriveClient client;
  final GoogleDriveBackupService backup;
  final AutoBackupScheduler scheduler;
}

/// The one place the library is backed up to, which the person chooses.
///
/// Being signed into Google is not the same as backing up to Drive: someone
/// backing up to iCloud can sign into Google to import from Goodnotes and
/// their backups stay where they are. Only the chosen target is linked, so
/// only it backs up on its own or brings changes from other devices. Each
/// keeps its own record of what it has synced, and what is already in the
/// other place stays there.
class BackupDestinations extends ChangeNotifier {
  BackupDestinations({required this.googleDrive, this.iCloud});

  final BackupTarget googleDrive;

  /// Null where there is no iCloud.
  final BackupTarget? iCloud;

  List<BackupTarget> get targets => <BackupTarget>[?iCloud, googleDrive];

  /// Whether there is a choice to make.
  bool get offersChoice => iCloud != null;

  BackupTarget? _current;
  bool _disposed = false;

  /// The target chosen, or null until one is.
  BackupTarget? get current => _current;

  Future<void>? _started;

  /// Learns what was chosen and starts each schedule.
  Future<void> start() => _started ??= _start();

  Future<void> _start() async {
    for (final BackupTarget target in targets) {
      if (await target.backup.isLinked()) {
        _current = target;
        break;
      }
    }
    if (_disposed) return;
    notifyListeners();
    await Future.wait(
      targets.map((BackupTarget target) => target.scheduler.start()),
    );
  }

  /// Backs up to [destination] from now on.
  Future<void> choose(BackupDestination destination) async {
    await start();
    final BackupTarget chosen = targets.firstWhere(
      (BackupTarget target) => target.destination == destination,
    );
    for (final BackupTarget target in targets) {
      await target.backup.setLinked(identical(target, chosen));
    }
    if (_disposed) return;
    _current = chosen;
    notifyListeners();
    for (final BackupTarget target in targets) {
      await target.scheduler.reschedule();
    }
  }

  /// Google was signed into: Drive becomes the destination only if none has
  /// been chosen, so importing from Goodnotes never moves someone's backups.
  Future<void> googleConnected() async {
    await start();
    if (_current == null) await choose(BackupDestination.googleDrive);
  }

  /// Backs up to the chosen target shortly, if it has changes to send.
  Future<void> backUpSoon() async {
    await start();
    if (!_disposed) _current?.scheduler.backUpSoon();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final BackupTarget target in targets) {
      target.scheduler.dispose();
    }
    super.dispose();
  }
}
