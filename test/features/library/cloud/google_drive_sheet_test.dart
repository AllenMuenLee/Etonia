import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/app/theme/app_icons.dart';
import 'package:greatnote/features/editor/document_io/document_importer.dart';
import 'package:greatnote/features/library/cloud/auto_backup_scheduler.dart';
import 'package:greatnote/features/library/cloud/cloud_sync_state.dart';
import 'package:greatnote/features/library/cloud/goodnotes_drive_replicator.dart';
import 'package:greatnote/features/library/cloud/google_drive_backup_service.dart';
import 'package:greatnote/features/library/cloud/google_drive_client.dart';
import 'package:greatnote/features/library/cloud/google_drive_sheet.dart';
import 'package:greatnote/features/library/library_screen.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/payment/account_page.dart';
import 'package:greatnote/shared/widgets/processing.dart';

import '../../../helpers/document_io_fakes.dart';
import '../../../helpers/goodnotes_fixtures.dart';
import '../../../helpers/google_drive_fakes.dart';
import '../../../helpers/pump_app.dart';

final DateTime _now = DateTime(2026, 10, 16, 9, 30);

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
              onOpenFolder: onOpenFolder,
              clock: () => _now,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder button(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((Widget w) => w is ButtonStyleButton),
  );

  bool enabled(WidgetTester tester, String label) =>
      tester.widget<ButtonStyleButton>(button(label)).onPressed != null;

  group('connection', () {
    testDrive('signed out, points to the Account button', (
      WidgetTester tester,
    ) async {
      await pumpSheet(tester);
      expect(find.text('Not connected'), findsOneWidget);
      expect(button('Connect'), findsNothing);
      expect(button('Disconnect'), findsNothing);
      expect(enabled(tester, 'Back up library now'), isFalse);
      expect(enabled(tester, 'Import Goodnotes folder from Drive'), isFalse);
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
