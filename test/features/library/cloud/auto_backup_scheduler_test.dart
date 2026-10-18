import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/library/cloud/auto_backup_scheduler.dart';
import 'package:greatnote/features/library/cloud/cloud_sync_state.dart';
import 'package:greatnote/features/library/cloud/google_drive_backup_service.dart';
import 'package:greatnote/features/library/note_repository.dart';

import '../../../helpers/google_drive_fakes.dart';

void main() {
  late FakeGoogleDriveClient drive;
  late InMemoryNoteRepository repository;
  late InMemoryCloudStateStore state;
  late DateTime now;
  late GoogleDriveBackupService backup;
  late AutoBackupScheduler scheduler;

  /// [testWidgets] with the fakes made inside, and a clock that moves with
  /// [WidgetTester.pump].
  void testScheduler(
    String description,
    Future<void> Function(WidgetTester tester) body, {
    bool signedIn = true,
  }) {
    testWidgets(description, (WidgetTester tester) async {
      drive = FakeGoogleDriveClient(signedIn: signedIn);
      repository = InMemoryNoteRepository();
      addTearDown(repository.dispose);
      state = InMemoryCloudStateStore();
      now = DateTime(2026, 10, 17, 9);
      backup = GoogleDriveBackupService(
        client: drive,
        repository: repository,
        state: state,
        clock: () => now,
      );
      scheduler = AutoBackupScheduler(
        backup: backup,
        client: drive,
        library: repository,
        clock: () => now,
      );
      await body(tester);
      // Before the test's check for pending timers.
      scheduler.dispose();
    });
  }

  /// Moves the clock and the timers on by [time].
  Future<void> advance(WidgetTester tester, Duration time) async {
    now = now.add(time);
    await tester.pump(time);
    await tester.pump();
  }

  testScheduler('backs up every 15 minutes by default', (
    WidgetTester tester,
  ) async {
    await backup.setLinked(true);
    await repository.createNote(title: 'First');
    await scheduler.start();
    expect(scheduler.interval.value, const Duration(minutes: 15));

    await advance(tester, const Duration(minutes: 1));
    expect(await backup.lastBackupAt(), isNotNull);
    expect(drive.itemAt('Etonia/manifest.json'), isNotNull);
    final DateTime first = (await backup.lastBackupAt())!;

    await repository.createNote(title: 'Second');
    await advance(tester, const Duration(minutes: 10));
    expect(await backup.lastBackupAt(), first);
    await advance(tester, const Duration(minutes: 6));
    expect((await backup.lastBackupAt())!.isAfter(first), isTrue);
  });

  testScheduler('skips a turn when nothing changed', (
    WidgetTester tester,
  ) async {
    await backup.setLinked(true);
    await scheduler.start();
    await advance(tester, const Duration(minutes: 1));
    drive.uploads.clear();
    await advance(tester, const Duration(minutes: 16));
    expect(drive.uploads, isEmpty);
  });

  testScheduler('the chosen interval is kept and used', (
    WidgetTester tester,
  ) async {
    await backup.setLinked(true);
    await scheduler.start();
    await scheduler.setInterval(const Duration(hours: 1));
    expect((await state.read())['autoBackupMinutes'], 60);
    await advance(tester, const Duration(minutes: 1));
    final DateTime first = (await backup.lastBackupAt())!;

    await repository.createNote(title: 'Later');
    await advance(tester, const Duration(minutes: 30));
    expect(await backup.lastBackupAt(), first);
    await advance(tester, const Duration(minutes: 31));
    expect((await backup.lastBackupAt())!.isAfter(first), isTrue);

    final AutoBackupScheduler again = AutoBackupScheduler(
      backup: backup,
      client: drive,
      library: repository,
      clock: () => now,
    );
    await again.start();
    expect(again.interval.value, const Duration(hours: 1));
    again.dispose();
  });

  testScheduler('off backs nothing up', (WidgetTester tester) async {
    await backup.setLinked(true);
    await scheduler.start();
    await scheduler.setInterval(AutoBackupScheduler.off);
    await advance(tester, const Duration(hours: 2));
    expect(await backup.lastBackupAt(), isNull);
  });

  testScheduler('waits until Drive has been connected', (
    WidgetTester tester,
  ) async {
    await scheduler.start();
    await advance(tester, const Duration(minutes: 20));
    expect(await backup.lastBackupAt(), isNull);
  });

  testScheduler('a session that cannot be restored skips the turn', (
    WidgetTester tester,
  ) async {
    await backup.setLinked(true);
    await scheduler.start();
    await advance(tester, const Duration(minutes: 20));
    expect(await backup.lastBackupAt(), isNull);
  }, signedIn: false);

  test('describes each choice', () {
    expect(
      AutoBackupScheduler.choices.map(AutoBackupScheduler.describe),
      <String>[
        'Every 5 minutes',
        'Every 15 minutes',
        'Every 30 minutes',
        'Every hour',
        'Every 4 hours',
        'Once a day',
        'Off',
      ],
    );
  });
}
