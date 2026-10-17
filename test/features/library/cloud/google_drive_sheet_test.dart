import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/app/theme/app_icons.dart';
import 'package:greatnote/features/editor/document_io/document_importer.dart';
import 'package:greatnote/features/library/cloud/cloud_sync_state.dart';
import 'package:greatnote/features/library/cloud/goodnotes_drive_replicator.dart';
import 'package:greatnote/features/library/cloud/google_drive_backup_service.dart';
import 'package:greatnote/features/library/cloud/google_drive_client.dart';
import 'package:greatnote/features/library/cloud/google_drive_sheet.dart';
import 'package:greatnote/features/library/library_screen.dart';
import 'package:greatnote/features/library/note_repository.dart';

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
    testDrive('connects and shows the account', (WidgetTester tester) async {
      await pumpSheet(tester);
      expect(find.text('Not connected'), findsOneWidget);
      expect(enabled(tester, 'Back up library now'), isFalse);
      expect(enabled(tester, 'Import Goodnotes folder from Drive'), isFalse);

      await tester.tap(button('Connect'));
      await tester.pumpAndSettle();

      expect(find.text('Ada Lovelace'), findsOneWidget);
      expect(find.text('ada@example.com'), findsOneWidget);
      expect(button('Disconnect'), findsOneWidget);
      expect(enabled(tester, 'Back up library now'), isTrue);
      expect(
        find.bySemanticsLabel('Connected to Google Drive as ada@example.com'),
        findsOneWidget,
      );
    });

    testDrive('a cancelled sign-in stays disconnected', (
      WidgetTester tester,
    ) async {
      drive.account = null;
      await pumpSheet(tester);
      await tester.tap(button('Connect'));
      await tester.pumpAndSettle();
      expect(find.text('Not connected'), findsOneWidget);
      expect(find.text('Sign-in was cancelled'), findsOneWidget);
    });

    testDrive('disconnects', (WidgetTester tester) async {
      await drive.signIn();
      await pumpSheet(tester);
      expect(find.text('Ada Lovelace'), findsOneWidget);
      await tester.tap(button('Disconnect'));
      await tester.pumpAndSettle();
      expect(find.text('Not connected'), findsOneWidget);
      expect(drive.currentAccount, isNull);
    });

    testDrive('a sign-in error is explained', (WidgetTester tester) async {
      drive.signInError = const GoogleDriveException(
        GoogleDriveErrorKind.unauthorized,
        "Couldn't sign in to Google",
      );
      await pumpSheet(tester);
      await tester.tap(button('Connect'));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't sign in to Google"), findsOneWidget);
      expect(find.text('Not connected'), findsOneWidget);
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
      final LinearProgressIndicator bar = tester.widget(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, isNotNull);
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
      expect(find.byType(LinearProgressIndicator), findsNothing);
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

      await tester.tap(button('Restore from backup'));
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

    testDrive('replicates, summarizes, and shows the folder', (
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
        find.text('Imported 1 file into GoodNotes. 1 not imported.'),
        findsOneWidget,
      );
      expect(find.text('cover.jpg — Not a notebook or PDF'), findsOneWidget);
      await tester.tap(button('Show folder'));
      await tester.pumpAndSettle();
      expect(opened, isNotNull);
      expect((await repository.pathTo(opened)).single.name, 'GoodNotes');
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
      expect(find.text('Imported 0 files into Goodnotes.'), findsOneWidget);
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
          await tester.tap(button('Back up library now'));
          await tester.pump();
          await tester.pump();
          expect(find.byType(LinearProgressIndicator), findsOneWidget);
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
      await tester.tap(button('Connect'));
      await tester.pumpAndSettle();
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      for (final String label in <String>[
        'Disconnect',
        'Back up library now',
        'Restore from backup',
        'Import Goodnotes folder from Drive',
      ]) {
        expect(tester.getSize(button(label)).height, greaterThanOrEqualTo(48));
      }
      semantics.dispose();
    });
  });

  group('library button', () {
    testDrive('opens the sheet from a labeled 48 x 48 button', (
      WidgetTester tester,
    ) async {
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
          of: find.byTooltip('Google Drive'),
          matching: find.byType(IconButton),
        );
        expect(driveButton, findsOneWidget);
        final Size size = tester.getSize(driveButton);
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
        expect(tester.getSemantics(driveButton).tooltip, 'Google Drive');

        await tester.tap(driveButton);
        await tester.pumpAndSettle();
        expect(find.byType(GoogleDriveSheet), findsOneWidget);
        expect(find.text('Not connected'), findsOneWidget);
        expect(tester.takeException(), isNull);
        Navigator.of(tester.element(find.byType(GoogleDriveSheet))).pop();
        await tester.pumpAndSettle();
      }
    });

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
        tester.element(find.byIcon(AppIcons.cloud)),
      );
      expect(focus.canRequestFocus, isTrue);
      focus.requestFocus();
      await tester.pumpAndSettle();
      expect(focus.hasPrimaryFocus, isTrue);
    });
  });
}
