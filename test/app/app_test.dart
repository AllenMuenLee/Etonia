import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/library/library_screen.dart';
import 'package:greatnote/features/library/note_repository.dart';

import '../helpers/pump_app.dart';

void main() {
  testWidgets('launches into the library', (WidgetTester tester) async {
    setViewportSize(tester, TestViewport.tabletLandscape.size);
    final InMemoryNoteRepository repository = InMemoryNoteRepository();
    addTearDown(repository.dispose);
    await tester.pumpWidget(GreatnoteApp(repository: repository));
    await tester.pumpAndSettle();

    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).title,
      'Greatnote',
    );
    expect(find.byType(LibraryScreen), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a home replaces the library', (WidgetTester tester) async {
    await pumpApp(tester);
    expect(find.byType(EditorScreen), findsOneWidget);
    expect(find.text('Untitled note'), findsOneWidget);
  });

  testWidgets('follows the requested theme mode', (WidgetTester tester) async {
    await pumpApp(tester, themeMode: ThemeMode.dark);
    expect(
      Theme.of(tester.element(find.byType(EditorScreen))).brightness,
      Brightness.dark,
    );

    await tester.pumpWidget(
      const GreatnoteApp(themeMode: ThemeMode.light, home: EditorScreen()),
    );
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(EditorScreen))).brightness,
      Brightness.light,
    );
  });
}
