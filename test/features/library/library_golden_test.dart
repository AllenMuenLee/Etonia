@Tags(<String>['golden'])
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/library_screen.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';

import '../../helpers/pump_app.dart';

final DateTime _now = DateTime(2026, 10, 14, 15, 30);

List<Stroke> _scribbles(double top, InkColor ink) {
  return <Stroke>[
    for (int line = 0; line < 4; line++)
      Stroke.fromPoints(
        style: StrokeStyle(ink: ink, width: 4),
        points: <InkVector>[
          for (int i = 0; i <= 50; i++)
            InkVector(80 + i * 8.0, top + line * 64 + 14 * math.sin(i / 3)),
        ],
      ),
  ];
}

Future<InMemoryNoteRepository> _library() async {
  int tick = 0;
  int id = 0;
  final InMemoryNoteRepository repository = InMemoryNoteRepository(
    clock: () => _now.subtract(Duration(hours: 30 - tick++)),
    newId: () => 'id${id++}',
  );
  addTearDown(repository.dispose);
  await repository.createFolder('Physics');
  await repository.createFolder('Recipes');
  final InkColor blue = InkPalette.colors.firstWhere(
    (InkColor ink) => ink.id == 'blue',
  );
  for (final (String title, PageSetup setup, InkColor ink)
      in <(String, PageSetup, InkColor)>[
        (
          'Lecture 4: waves',
          const PageSetup(
            size: PageSize.a4Portrait,
            background: PageBackground.lined,
          ),
          InkPalette.ink,
        ),
        ('Sketches', const PageSetup(background: PageBackground.dotted), blue),
        (
          'Graph practice',
          const PageSetup(
            size: PageSize.square,
            background: PageBackground.grid,
          ),
          InkPalette.ink,
        ),
        ('Untitled note', const PageSetup(), InkPalette.ink),
      ]) {
    final NoteEntry note = await repository.createNote(title: title);
    await repository.saveNote(
      note.id,
      NoteContent(<StoredPage>[
        StoredPage(
          setup: setup,
          strokes: title == 'Untitled note'
              ? const <Stroke>[]
              : _scribbles(120, ink),
        ),
      ]),
    );
  }
  return repository;
}

Future<void> _pump(
  WidgetTester tester,
  NoteRepository repository,
  TestViewport viewport,
  ThemeMode themeMode,
) async {
  setViewportSize(tester, viewport.size);
  await tester.pumpWidget(
    GreatnoteApp(
      themeMode: themeMode,
      home: LibraryScreen(repository: repository, clock: () => _now),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final (String name, TestViewport viewport, ThemeMode themeMode)
      in <(String, TestViewport, ThemeMode)>[
        (
          'grid_tablet_landscape_light',
          TestViewport.tabletLandscape,
          ThemeMode.light,
        ),
        (
          'grid_tablet_landscape_dark',
          TestViewport.tabletLandscape,
          ThemeMode.dark,
        ),
        ('grid_compact_light', TestViewport.compact, ThemeMode.light),
      ]) {
    testWidgets('library: $name', (WidgetTester tester) async {
      await _pump(tester, await _library(), viewport, themeMode);
      await expectLater(
        find.byType(GreatnoteApp),
        matchesGoldenFile('goldens/library_$name.png'),
      );
    });
  }

  testWidgets('library: list_tablet_portrait_light', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      await _library(),
      TestViewport.tabletPortrait,
      ThemeMode.light,
    );
    await tester.tap(find.byTooltip('Show as list'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(GreatnoteApp),
      matchesGoldenFile('goldens/library_list_tablet_portrait_light.png'),
    );
  });

  testWidgets('note tabs: tablet_landscape_light', (WidgetTester tester) async {
    await _pump(
      tester,
      await _library(),
      TestViewport.tabletLandscape,
      ThemeMode.light,
    );
    for (final String title in <String>['Lecture 4: waves', 'Sketches']) {
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Open another note'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Graph practice'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(GreatnoteApp),
      matchesGoldenFile('goldens/note_tabs_tablet_landscape_light.png'),
    );
  });
}
