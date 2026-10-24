import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/library/library_screen.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/main.dart';

import '../helpers/pump_app.dart';

void main() {
  testWidgets('starting page strictly uses the logo provided in assets', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: StartupWordmark(),
      ),
    );

    final Scaffold scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, Colors.black);

    final Image image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<AssetImage>());
    final AssetImage asset = image.image as AssetImage;
    expect(asset.assetName, 'assets/icon/etonia.png');
  });
  testWidgets('launches into the library', (WidgetTester tester) async {
    setViewportSize(tester, TestViewport.tabletLandscape.size);
    final InMemoryNoteRepository repository = InMemoryNoteRepository();
    addTearDown(repository.dispose);
    await tester.pumpWidget(GreatnoteApp(repository: repository));
    await tester.pumpAndSettle();

    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).title,
      'Etonia',
    );
    expect(find.byType(LibraryScreen), findsOneWidget);
    // In the breadcrumb, and at the top of the folder sidebar.
    expect(find.text('Library'), findsNWidgets(2));
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
