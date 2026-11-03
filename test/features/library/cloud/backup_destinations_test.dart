import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/library/cloud/auto_backup_scheduler.dart';
import 'package:greatnote/features/library/cloud/backup_destinations.dart';
import 'package:greatnote/features/library/cloud/cloud_sync_state.dart';
import 'package:greatnote/features/library/cloud/google_drive_backup_service.dart';
import 'package:greatnote/features/library/note_repository.dart';

import '../../../helpers/google_drive_fakes.dart';

void main() {
  late FakeGoogleDriveClient drive;
  late FakeGoogleDriveClient iCloud;
  late InMemoryNoteRepository repository;
  late BackupDestinations destinations;
  late InMemoryCloudStateStore driveState;
  late InMemoryCloudStateStore iCloudState;

  BackupTarget target(
    BackupDestination destination,
    FakeGoogleDriveClient client,
    CloudStateStore state,
  ) {
    final GoogleDriveBackupService backup = GoogleDriveBackupService(
      client: client,
      repository: repository,
      state: state,
    );
    return BackupTarget(
      destination: destination,
      client: client,
      backup: backup,
      scheduler: AutoBackupScheduler(
        backup: backup,
        client: client,
        library: repository,
      ),
    );
  }

  BackupDestinations make() => destinations = BackupDestinations(
    googleDrive: target(BackupDestination.googleDrive, drive, driveState),
    iCloud: target(BackupDestination.iCloud, iCloud, iCloudState),
  );

  void testDestinations(
    String description,
    Future<void> Function(WidgetTester tester) body,
  ) {
    testWidgets(description, (WidgetTester tester) async {
      drive = FakeGoogleDriveClient(signedIn: true);
      iCloud = FakeGoogleDriveClient(signedIn: true);
      repository = InMemoryNoteRepository();
      addTearDown(repository.dispose);
      driveState = InMemoryCloudStateStore();
      iCloudState = InMemoryCloudStateStore();
      make();
      await body(tester);
      destinations.dispose();
    });
  }

  testDestinations('nothing is chosen at first, and nothing backs up', (
    WidgetTester tester,
  ) async {
    await destinations.start();
    expect(destinations.current, isNull);
    await repository.createNote(title: 'Lecture');
    await destinations.backUpSoon();
    await tester.pump(const Duration(minutes: 20));
    await tester.pump();
    expect(drive.uploads, isEmpty);
    expect(iCloud.uploads, isEmpty);
  });

  testDestinations('only the destination chosen backs up', (
    WidgetTester tester,
  ) async {
    await destinations.choose(BackupDestination.iCloud);
    await repository.createNote(title: 'Lecture');
    await destinations.backUpSoon();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(iCloud.uploads, isNotEmpty);
    expect(drive.uploads, isEmpty);
  });

  testDestinations('choosing again moves backups, and leaves the other alone', (
    WidgetTester tester,
  ) async {
    await destinations.choose(BackupDestination.iCloud);
    await destinations.choose(BackupDestination.googleDrive);
    expect(destinations.current?.destination, BackupDestination.googleDrive);
    expect(await destinations.iCloud!.backup.isLinked(), isFalse);
    expect(await destinations.googleDrive.backup.isLinked(), isTrue);
  });

  testDestinations(
    'signing into Google picks Drive only if nothing is chosen',
    (WidgetTester tester) async {
      await destinations.googleConnected();
      expect(destinations.current?.destination, BackupDestination.googleDrive);

      await destinations.choose(BackupDestination.iCloud);
      await destinations.googleConnected();
      expect(destinations.current?.destination, BackupDestination.iCloud);
      expect(await destinations.googleDrive.backup.isLinked(), isFalse);
    },
  );

  testDestinations('the choice is remembered across launches', (
    WidgetTester tester,
  ) async {
    await destinations.choose(BackupDestination.iCloud);
    destinations.dispose();
    make();
    await destinations.start();
    expect(destinations.current?.destination, BackupDestination.iCloud);
  });

  testDestinations('someone already backing up to Drive stays on it', (
    WidgetTester tester,
  ) async {
    await destinations.googleDrive.backup.setLinked(true);
    destinations.dispose();
    make();
    await destinations.start();
    expect(destinations.current?.destination, BackupDestination.googleDrive);
  });

  testWidgets('without iCloud there is no choice to offer', (
    WidgetTester tester,
  ) async {
    drive = FakeGoogleDriveClient(signedIn: true);
    repository = InMemoryNoteRepository();
    addTearDown(repository.dispose);
    final BackupDestinations only = BackupDestinations(
      googleDrive: target(
        BackupDestination.googleDrive,
        drive,
        InMemoryCloudStateStore(),
      ),
    );
    expect(only.offersChoice, isFalse);
    only.dispose();
  });
}
