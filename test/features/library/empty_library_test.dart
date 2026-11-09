import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/library/library_screen.dart';
import 'package:greatnote/features/library/note_repository.dart';

import '../../helpers/google_drive_fakes.dart';
import '../../helpers/pump_app.dart';

final DateTime _now = DateTime(2026, 10, 14, 15, 30);

Future<void> _pump(WidgetTester tester, FakeGoogleDriveClient drive) async {
  final InMemoryNoteRepository repository = InMemoryNoteRepository(
    clock: () => _now,
  );
  addTearDown(repository.dispose);
  setViewportSize(tester, TestViewport.tabletLandscape.size);
  await tester.pumpWidget(
    GreatnoteApp(
      themeMode: ThemeMode.light,
      home: LibraryScreen(
        repository: repository,
        clock: () => _now,
        googleDriveClient: drive,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an empty library centers Etonia with both ways to start', (
    WidgetTester tester,
  ) async {
    await _pump(tester, FakeGoogleDriveClient(signedIn: true));

    expect(find.text('Nothing here yet'), findsOneWidget);
    final Finder etonia = find.byKey(const ValueKey<String>('etonia-empty'));
    final Finder newNote = find.widgetWithText(FilledButton, 'New note');
    final Finder import = find.byKey(
      const ValueKey<String>('import-goodnotes'),
    );
    expect(etonia, findsOneWidget);
    expect(newNote, findsOneWidget);
    expect(import, findsOneWidget);
    expect(find.text('Import from Goodnotes'), findsOneWidget);

    // All three sit on one vertical axis.
    final double axis = tester.getCenter(etonia).dx;
    expect(tester.getCenter(etonia).dx, closeTo(axis, 1));
    expect(tester.getCenter(newNote).dx, closeTo(axis, 1));
    expect(tester.getCenter(import).dx, closeTo(axis, 1));
  });

  testWidgets('importing with no Goodnotes folder in Drive says to sync '
      'Goodnotes to Google Drive first', (WidgetTester tester) async {
    await _pump(tester, FakeGoogleDriveClient(signedIn: true));

    await tester.tap(find.byKey(const ValueKey<String>('import-goodnotes')));
    await tester.pumpAndSettle();

    expect(find.text('No Goodnotes folder in Google Drive'), findsOneWidget);
    expect(
      find.textContaining('sync your notebooks to Google Drive'),
      findsOneWidget,
    );
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('No Goodnotes folder in Google Drive'), findsNothing);
  });
}
