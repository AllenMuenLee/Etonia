import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/app/theme/app_icons.dart';
import 'package:greatnote/features/editor/document_io/document_importer.dart';
import 'package:greatnote/features/library/cloud/auto_backup_scheduler.dart';
import 'package:greatnote/features/library/cloud/backup_destinations.dart';
import 'package:greatnote/features/library/cloud/cloud_sync_state.dart';
import 'package:greatnote/features/library/cloud/cloud_task_controller.dart';
import 'package:greatnote/features/library/cloud/goodnotes_drive_replicator.dart';
import 'package:greatnote/features/library/cloud/google_drive_backup_service.dart';
import 'package:greatnote/features/library/cloud/google_drive_client.dart';
import 'package:greatnote/features/library/cloud/google_drive_sheet.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/library_screen.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/payment/account_page.dart';
import 'package:greatnote/shared/widgets/processing.dart';

import '../../../helpers/document_io_fakes.dart';
import '../../../helpers/goodnotes_fixtures.dart';
import '../../../helpers/google_drive_fakes.dart';
import '../../../helpers/pump_app.dart';

final DateTime _now = DateTime(2026, 10, 16, 9, 30);

/// A Drive whose downloads wait for [gate], so a test can look at an import
/// part way.
class _GatedDrive extends FakeGoogleDriveClient {
  _GatedDrive(this.gate) : super(signedIn: true);

  final Completer<void> gate;

  @override
  Future<Uint8List> downloadFile(String fileId) async {
    await gate.future;
    return super.downloadFile(fileId);
  }
}

void main() {
  late FakeGoogleDriveClient drive;
  late InMemoryNoteRepository repository;
  late InMemoryCloudStateStore state;

  /// [testWidgets], with the fakes made inside the test, so the
  /// repository's futures belong to the test's clock.
  void testDrive(String description, WidgetTesterCallback body) {
    testWidgets(description, (WidgetTester tester) async {
      drive = FakeGoogleDriveClient();
      repository = InMemoryNoteRepository();
      addTearDown(repository.dispose);
      state = InMemoryCloudStateStore();
      await body(tester);
    });
  }

  Future<void> pumpSheet(
    WidgetTester tester, {
    TestViewport viewport = TestViewport.tabletLandscape,
    ThemeMode themeMode = ThemeMode.light,
    ValueChanged<String>? onOpenFolder,
    CloudTaskController? tasks,
  }) async {
    setViewportSize(tester, viewport.size);
    final AutoBackupScheduler autoBackup = AutoBackupScheduler(
      backup: GoogleDriveBackupService(
        client: drive,
        repository: repository,
        state: state,
        clock: () => _now,
      ),
      client: drive,
      library: repository,
      clock: () => _now,
    );
    addTearDown(autoBackup.dispose);
    await tester.pumpWidget(
      GreatnoteApp(
        themeMode: themeMode,
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: GoogleDriveSheet(
              client: drive,
              backup: GoogleDriveBackupService(
                client: drive,
                repository: repository,
                state: state,
                clock: () => _now,
              ),
              replicator: GoodnotesDriveReplicator(
                client: drive,
                repository: repository,
                importer: DocumentImporter(rasterizer: FakePdfRasterizer()),
                state: state,
              ),
              autoBackup: autoBackup,
              tasks: tasks,
              onOpenFolder: onOpenFolder,
              clock: () => _now,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Moves time on frame by frame, for a screen that never settles because
  /// something on it is always moving, as a progress indicator.
  Future<void> advance(WidgetTester tester) async {
    for (int i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Finder button(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((Widget w) => w is ButtonStyleButton),
  );

  bool enabled(WidgetTester tester, String label) =>
      tester.widget<ButtonStyleButton>(button(label)).onPressed != null;

  group('choosing where to back up', () {
    late FakeGoogleDriveClient iCloud;
    late BackupDestinations destinations;

    BackupTarget target(
      BackupDestination destination,
      FakeGoogleDriveClient client,
    ) {
      final GoogleDriveBackupService backup = GoogleDriveBackupService(
        client: client,
        repository: repository,
        state: InMemoryCloudStateStore(),
        destinationName: destination.label,
        clock: () => _now,
      );
      return BackupTarget(
        destination: destination,
        client: client,
        backup: backup,
        scheduler: AutoBackupScheduler(
          backup: backup,
          client: client,
          library: repository,
          clock: () => _now,
        ),
      );
    }

    Future<void> pumpChoice(WidgetTester tester) async {
      iCloud = FakeGoogleDriveClient(
        account: const GoogleDriveAccount(
          email: 'The iCloud account on this device',
          displayName: 'iCloud',
        ),
        signedIn: true,
      );
      destinations = BackupDestinations(
        googleDrive: target(BackupDestination.googleDrive, drive),
        iCloud: target(BackupDestination.iCloud, iCloud),
      );
      addTearDown(destinations.dispose);
      setViewportSize(tester, TestViewport.tabletLandscape.size);
      await destinations.start();
      await tester.pumpWidget(
        GreatnoteApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: GoogleDriveSheet(
                client: drive,
                backup: destinations.googleDrive.backup,
                autoBackup: destinations.googleDrive.scheduler,
                destinations: destinations,
                replicator: GoodnotesDriveReplicator(
                  client: drive,
                  repository: repository,
                  importer: DocumentImporter(rasterizer: FakePdfRasterizer()),
                  state: state,
                ),
                clock: () => _now,
                embedded: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Finder segment(String label) => find.descendant(
      of: find.byType(SegmentedButton<BackupDestination>),
      matching: find.text(label),
    );

    testDrive('with nothing chosen, backing up waits for a choice', (
      WidgetTester tester,
    ) async {
      await pumpChoice(tester);
      expect(
        find.text('Choose where your library is backed up.'),
        findsOneWidget,
      );
      expect(enabled(tester, 'Back up library now'), isFalse);
    });

    testDrive('iCloud needs no Google account', (WidgetTester tester) async {
      await repository.createNote(title: 'Lecture');
      await pumpChoice(tester);
      await tester.tap(segment('iCloud'));
      await tester.pumpAndSettle();
      expect(drive.currentAccount, isNull);
      expect(destinations.current?.destination, BackupDestination.iCloud);

      await tester.tap(button('Back up library now'));
      await tester.pumpAndSettle();
      expect(iCloud.itemAt('Etonia/manifest.json'), isNotNull);
      expect(drive.uploads, isEmpty);
    });

    testDrive('iCloud being off is explained, and nothing is chosen', (
      WidgetTester tester,
    ) async {
      await pumpChoice(tester);
      iCloud.signInError = const GoogleDriveException(
        GoogleDriveErrorKind.unauthorized,
        'iCloud is not available.',
      );
      await tester.tap(segment('iCloud'));
      await tester.pumpAndSettle();
      expect(find.text('iCloud is not available.'), findsOneWidget);
      expect(destinations.current, isNull);
    });

    testDrive('Google Drive asks for Google, and cancelling chooses nothing', (
      WidgetTester tester,
    ) async {
      await pumpChoice(tester);
      final GoogleDriveAccount? ada = drive.account;
      drive.account = null;
      await tester.tap(segment('Google Drive'));
      await tester.pumpAndSettle();
      expect(destinations.current, isNull);

      drive.account = ada;
      await tester.tap(segment('Google Drive'));
      await tester.pumpAndSettle();
      expect(drive.currentAccount, isNotNull);
      expect(destinations.current?.destination, BackupDestination.googleDrive);
    });

    testDrive('signing into Google for Goodnotes leaves backups on iCloud', (
      WidgetTester tester,
    ) async {
      await pumpChoice(tester);
      await tester.tap(segment('iCloud'));
      await tester.pumpAndSettle();
      expect(find.text('Not connected'), findsOneWidget);

      await tester.tap(button('Import Goodnotes folder from Drive'));
      await tester.pumpAndSettle();
      expect(drive.currentAccount, isNotNull);
      expect(destinations.current?.destination, BackupDestination.iCloud);
    });

    testDrive('cancelling Google for Goodnotes does not start the import', (
      WidgetTester tester,
    ) async {
      await pumpChoice(tester);
      drive.account = null;
      await tester.tap(button('Import Goodnotes folder from Drive'));
      await tester.pumpAndSettle();
      expect(find.text(noGoodnotesFolderMessage), findsNothing);
      expect(find.text('Not connected'), findsOneWidget);
    });
  });

  group('connection', () {
    testDrive('signed out, points to the Account button', (
      WidgetTester tester,
    ) async {
      await pumpSheet(tester);
      expect(find.text('Not connected'), findsOneWidget);
      expect(button('Connect'), findsNothing);
      expect(button('Disconnect'), findsNothing);
      expect(enabled(tester, 'Back up library now'), isFalse);
      // Importing asks for Google when it is pressed.
      expect(enabled(tester, 'Import Goodnotes folder from Drive'), isTrue);
    });

    testDrive('shows the signed-in account', (WidgetTester tester) async {
      await drive.signIn();
      await pumpSheet(tester);
      expect(find.text('Ada Lovelace'), findsOneWidget);
      expect(find.text('ada@example.com'), findsOneWidget);
      expect(button('Disconnect'), findsNothing);
      expect(enabled(tester, 'Back up library now'), isTrue);
      expect(
        find.bySemanticsLabel('Connected to Google Drive as ada@example.com'),
        findsOneWidget,
      );
    });

    testDrive('being offline is explained', (WidgetTester tester) async {
      await drive.signIn();
      drive.failure = const GoogleDriveException(
        GoogleDriveErrorKind.offline,
        "Couldn't reach Google Drive. Check your connection.",
      );
      await pumpSheet(tester);
      await tester.tap(button('Back up library now'));
      await tester.pumpAndSettle();
      expect(
        find.text("Couldn't reach Google Drive. Check your connection."),
        findsOneWidget,
      );
    });
  });

  group('backup', () {
    testDrive('shows determinate progress, can be cancelled', (
      WidgetTester tester,
    ) async {
      await drive.signIn();
      await repository.createNote(title: 'First');
      await repository.createNote(title: 'Second');
      drive.uploadGate = Completer<void>();
      await pumpSheet(tester);
      expect(find.text('Not backed up yet'), findsOneWidget);

      await tester.tap(button('Back up library now'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Backing up'), findsOneWidget);
      final ProgressCount count = tester.widget(find.byType(ProgressCount));
      expect(count.value, isNotNull);
      expect(
        find.bySemanticsLabel(RegExp('Google Drive progress')),
        findsOneWidget,
      );
      expect(enabled(tester, 'Back up library now'), isFalse);

      await tester.tap(button('Cancel'));
      await tester.pump();
      expect(find.text('Stopping…'), findsOneWidget);
      drive.uploadGate!.complete();
      drive.uploadGate = null;
      await tester.pumpAndSettle();

      expect(find.text('Cancelled'), findsOneWidget);
      expect(find.byType(ProgressCount), findsNothing);
      expect(find.text('Not backed up yet'), findsOneWidget);
    });

    testDrive('a finished backup shows when it was made', (
      WidgetTester tester,
    ) async {
      await drive.signIn();
      await repository.createNote(title: 'First');
      await pumpSheet(tester);
      await tester.tap(button('Back up library now'));
      await tester.pumpAndSettle();
      expect(find.text('Last backed up Today, 09:30'), findsOneWidget);
      expect(find.textContaining('Backed up 1 note'), findsOneWidget);
    });

    testDrive('restore asks how, then restores', (WidgetTester tester) async {
      await drive.signIn();
      await repository.createNote(title: 'First');
      await GoogleDriveBackupService(
        client: drive,
        repository: repository,
        clock: () => _now,
      ).backUp();
      await pumpSheet(tester);

      await tester.tap(find.byTooltip('Backup options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore from backup'));
      await tester.pumpAndSettle();
      expect(find.text('Restore from Google Drive?'), findsOneWidget);
      await tester.tap(find.text('Add to library'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Restored 0 notes'), findsOneWidget);
      expect(
        find.textContaining('Skipped 1 note already here'),
        findsOneWidget,
      );
    });

    testDrive('automatic backup separates on-off from frequency', (
      WidgetTester tester,
    ) async {
      await drive.signIn();
      await pumpSheet(tester);

      expect(find.text('Automatic backup'), findsOneWidget);
      expect(find.text('Frequency'), findsOneWidget);
      expect(find.text('Every 15 minutes'), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(find.text('Frequency'), findsNothing);
      expect(find.text('Turn on scheduled cloud backups'), findsOneWidget);
      expect((await state.read())['autoBackupMinutes'], 0);
    });
  });

  group('Goodnotes', () {
    testDrive('no folder in Drive is said plainly', (
      WidgetTester tester,
    ) async {
      await drive.signIn();
      await pumpSheet(tester);
      await tester.tap(button('Import Goodnotes folder from Drive'));
      await tester.pumpAndSettle();
      expect(find.text(noGoodnotesFolderMessage), findsOneWidget);
    });

    testDrive('replicates and summarizes at the library root', (
      WidgetTester tester,
    ) async {
      await drive.signIn();
      final GoogleDriveItem root = drive.addFolder('GoodNotes');
      drive.addFile(
        'Inbox.goodnotes',
        syntheticGoodnotesNotebook(),
        parentId: root.id,
      );
      drive.addFile('cover.jpg', <int>[1, 2, 3], parentId: root.id);
      String? opened;
      await pumpSheet(tester, onOpenFolder: (String id) => opened = id);

      await tester.tap(button('Import Goodnotes folder from Drive'));
      // The notebook is read in an isolate, on real time.
      for (int i = 0; i < 200 && find.text('Cancel').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      for (
        int i = 0;
        i < 200 && find.text('Cancel').evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();

      expect(
        find.text('Imported 1 file into Library. 1 not imported.'),
        findsOneWidget,
      );
      expect(find.text('cover.jpg — Not a notebook or PDF'), findsOneWidget);
      expect(find.text('Show folder'), findsNothing);
      expect(opened, isNull);
      expect((await repository.list(null)).notes.single.title, 'Inbox');
    });

    testDrive('keeps importing after the sheet is closed', (
      WidgetTester tester,
    ) async {
      final Completer<void> gate = Completer<void>();
      drive = _GatedDrive(gate);
      final GoogleDriveItem root = drive.addFolder('GoodNotes');
      final GoogleDriveItem course = drive.addFolder('Bio', parentId: root.id);
      for (final String name in <String>['One', 'Two']) {
        drive.addFile(
          '$name.pdf',
          utf8.encode('%PDF-1.7 $name'),
          parentId: course.id,
          mimeType: 'application/pdf',
        );
      }
      final CloudTaskController tasks = CloudTaskController(clock: () => _now);
      addTearDown(tasks.dispose);
      await pumpSheet(tester, tasks: tasks);

      await tester.tap(button('Import Goodnotes folder from Drive'));
      for (int i = 0; i < 50 && tasks.session == null; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }

      // The whole tree is known, and shown, before any file is fetched.
      expect(tasks.session, isNotNull);
      final Folder bio = (await repository.allFolders()).single;
      expect(
        tasks.session!.pendingIn(bio.id).map((ImportItem i) => i.title),
        <String>['One', 'Two'],
      );
      expect((await repository.allNotes()), isEmpty);
      expect(
        find.text('This keeps going if you leave this page.'),
        findsOneWidget,
      );

      // Leaving the page does not stop it.
      await tester.pumpWidget(
        const GreatnoteApp(home: Scaffold(body: SizedBox())),
      );
      expect(tasks.busy, isTrue);
      expect(tasks.cancelling, isFalse);

      gate.complete();
      // Importing reads files on real time, as in the test above.
      for (int i = 0; i < 200 && tasks.busy; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(tasks.busy, isFalse);
      expect(tasks.message, 'Imported 2 files into Library.');
      expect((await repository.list(bio.id)).notes, hasLength(2));
    });

    testDrive('shows the files still to come, and a tap loads one first', (
      WidgetTester tester,
    ) async {
      final Completer<void> gate = Completer<void>();
      drive = _GatedDrive(gate);
      final GoogleDriveItem root = drive.addFolder('GoodNotes');
      final GoogleDriveItem course = drive.addFolder('Bio', parentId: root.id);
      for (final String name in <String>['One', 'Three', 'Two']) {
        drive.addFile(
          '$name.pdf',
          utf8.encode('%PDF-1.7 $name'),
          parentId: course.id,
          mimeType: 'application/pdf',
        );
      }
      setViewportSize(tester, TestViewport.tabletLandscape.size);
      await tester.pumpWidget(
        GreatnoteApp(
          home: LibraryScreen(
            repository: repository,
            clock: () => _now,
            googleDriveClient: drive,
            cloudStateStore: state,
            pdfRasterizer: FakePdfRasterizer(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.ancestor(
          of: find.byTooltip('Account'),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('account-tab-backup')),
      );
      await tester.pumpAndSettle();
      await tester.tap(button('Import Goodnotes folder from Drive'));
      for (int i = 0; i < 50 && find.text('Cancel').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }

      // Back in the library, the import goes on in view, and the folder is
      // there with every file in it, none fetched yet.
      Navigator.of(
        tester.element(find.byType(AccountPage)),
        rootNavigator: true,
      ).pop();
      await advance(tester);
      expect(find.text('Importing from Goodnotes'), findsOneWidget);
      expect(find.text('Bio'), findsWidgets);
      await tester.tap(find.text('Bio').first);
      await advance(tester);
      expect(find.text('One'), findsOneWidget);
      expect(find.text('Two'), findsOneWidget);
      expect(find.text('Three'), findsOneWidget);
      expect(find.text('Waiting to import'), findsWidgets);

      // Asking for Three puts it ahead of Two.
      await tester.tap(find.text('Three'));
      await tester.pump();
      expect(find.text('Up next'), findsOneWidget);
      gate.complete();
      for (
        int i = 0;
        i < 200 && (await repository.allNotes()).length < 3;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect((drive as _GatedDrive).downloads, <String>[
        'One.pdf',
        'Three.pdf',
        'Two.pdf',
      ]);
      // Let the library settle: the note that was asked for opens.
      await advance(tester);
    });

    testDrive('with several folders, asks which', (WidgetTester tester) async {
      await drive.signIn();
      drive.addFolder('GoodNotes');
      final GoogleDriveItem old = drive.addFolder('Old');
      drive.addFolder('Goodnotes', parentId: old.id);
      await pumpSheet(tester);

      await tester.tap(button('Import Goodnotes folder from Drive'));
      // The search's progress runs on under the dialog; no settling.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Choose a Goodnotes folder'), findsOneWidget);
      expect(find.text('My Drive/GoodNotes'), findsOneWidget);
      await tester.tap(find.text('My Drive/Old/Goodnotes'));
      await tester.pumpAndSettle();
      expect(find.text('Imported 0 files into Library.'), findsOneWidget);
    });
  });

  group('layout and accessibility', () {
    for (final TestViewport viewport in TestViewport.values) {
      for (final ThemeMode theme in <ThemeMode>[
        ThemeMode.light,
        ThemeMode.dark,
      ]) {
        testDrive('fits at ${viewport.name}, ${theme.name}', (
          WidgetTester tester,
        ) async {
          await drive.signIn();
          await repository.createNote(title: 'First');
          drive.uploadGate = Completer<void>();
          await pumpSheet(tester, viewport: viewport, themeMode: theme);
          expect(tester.takeException(), isNull);

          // With progress showing too, the tallest it gets.
          await tester.ensureVisible(button('Back up library now'));
          await tester.pumpAndSettle();
          await tester.tap(button('Back up library now'));
          await tester.pump();
          await tester.pump();
          await tester.drag(find.byType(ListView), const Offset(0, -600));
          await tester.pump();
          expect(find.byType(ProgressCount), findsOneWidget);
          expect(tester.takeException(), isNull);
          drive.uploadGate!.complete();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        });
      }
    }

    testDrive('every control is a labeled 48 x 48 target', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await pumpSheet(tester, viewport: TestViewport.compact);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await tester.pumpWidget(const SizedBox());
      await drive.signIn();
      await pumpSheet(tester, viewport: TestViewport.compact);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      for (final String label in <String>[
        'Back up library now',
        'Import Goodnotes folder from Drive',
      ]) {
        expect(tester.getSize(button(label)).height, greaterThanOrEqualTo(48));
      }
      final Finder backupOptions = find.ancestor(
        of: find.byTooltip('Backup options'),
        matching: find.byType(IconButton),
      );
      expect(tester.getSize(backupOptions).height, greaterThanOrEqualTo(48));
      await tester.tap(backupOptions);
      await tester.pumpAndSettle();
      final Finder restore = find.ancestor(
        of: find.text('Restore from backup'),
        matching: find.byType(MenuItemButton),
      );
      expect(tester.getSize(restore).height, greaterThanOrEqualTo(48));
      semantics.dispose();
    });
  });

  group('library button', () {
    testDrive(
      'opens the account page, with backup in it, from a labeled 48 x 48 button',
      (WidgetTester tester) async {
        for (final TestViewport viewport in <TestViewport>[
          TestViewport.compact,
          TestViewport.tabletLandscape,
        ]) {
          setViewportSize(tester, viewport.size);
          await tester.pumpWidget(
            GreatnoteApp(
              home: LibraryScreen(
                key: ValueKey<TestViewport>(viewport),
                repository: repository,
                clock: () => _now,
                googleDriveClient: drive,
                cloudStateStore: state,
              ),
            ),
          );
          await tester.pumpAndSettle();

          final Finder driveButton = find.ancestor(
            of: find.byTooltip('Account'),
            matching: find.byType(IconButton),
          );
          expect(driveButton, findsOneWidget);
          final Size size = tester.getSize(driveButton);
          expect(size.width, greaterThanOrEqualTo(48));
          expect(size.height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(driveButton).tooltip, 'Account');

          await tester.tap(driveButton);
          await tester.pumpAndSettle();
          expect(find.byType(AccountPage), findsOneWidget);
          // Backup is its own tab of the account page.
          await tester.tap(
            find.byKey(const ValueKey<String>('account-tab-backup')),
          );
          await tester.pumpAndSettle();
          expect(find.byType(GoogleDriveSheet), findsOneWidget);
          expect(find.text('Not connected'), findsOneWidget);
          expect(tester.takeException(), isNull);
          Navigator.of(tester.element(find.byType(GoogleDriveSheet))).pop();
          await tester.pumpAndSettle();
        }
      },
    );

    testDrive('takes keyboard focus', (WidgetTester tester) async {
      setViewportSize(tester, TestViewport.tabletLandscape.size);
      await tester.pumpWidget(
        GreatnoteApp(
          home: LibraryScreen(
            repository: repository,
            clock: () => _now,
            googleDriveClient: drive,
            cloudStateStore: state,
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The button's own focus, the nearest above its icon.
      final FocusNode focus = Focus.of(
        tester.element(find.byIcon(AppIcons.account)),
      );
      expect(focus.canRequestFocus, isTrue);
      focus.requestFocus();
      await tester.pumpAndSettle();
      expect(focus.hasPrimaryFocus, isTrue);
    });
  });
}
