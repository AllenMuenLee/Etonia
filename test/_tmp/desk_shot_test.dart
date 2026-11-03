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

import '../helpers/ai_fakes.dart';
import '../helpers/pump_app.dart';

Stroke _line(double x0, double y0, double x1, double y1) => Stroke.fromPoints(
  style: const StrokeStyle(ink: InkPalette.ink, width: 2),
  points: <InkVector>[InkVector(x0, y0), InkVector(x1, y1)],
);

void main() {
  for (final (String name, Size size, ThemeMode mode) in <(String, Size, ThemeMode)>[
    ('landscape_light', const Size(1194, 834), ThemeMode.light),
    ('landscape_dark', const Size(1194, 834), ThemeMode.dark),
    ('phone_light', const Size(390, 844), ThemeMode.light),
  ]) {
    testWidgets(name, (WidgetTester tester) async {
      final InMemoryNoteRepository repository = InMemoryNoteRepository();
      addTearDown(repository.dispose);
      final FakeAiClient client = FakeAiClient();
      final NoteEntry created = await repository.createNote(title: 'Cell Biology');
      final List<Stroke> strokes = <Stroke>[
        for (int i = 0; i < 8; i++) _line(80, 120.0 + i * 30, 500, 120.0 + i * 30),
      ];
      final NoteEntry note = await repository.saveNote(
        created.id,
        NoteContent(<StoredPage>[
          StoredPage(setup: const PageSetup(), strokes: <Stroke>[_line(50, 50, 200, 50)]),
          StoredPage(
            setup: const PageSetup(),
            strokes: strokes,
            recognizedWords: <StoredRecognizedInkWord>[
              for (int i = 0; i < 8; i++)
                StoredRecognizedInkWord(
                  text: 'mitosis$i',
                  confidence: 0.9,
                  strokeIndices: <int>[i],
                  normalizedStrokes: const <List<InkVector>>[],
                  aspectRatio: 2,
                ),
            ],
          ),
        ]),
      );
      setViewportSize(tester, size);
      await tester.pumpWidget(
        GreatnoteApp(
          themeMode: mode,
          home: LibraryScreen(repository: repository, aiClient: client),
        ),
      );
      await tester.pumpAndSettle();
      if (size.width < 600) {
        await tester.tap(find.byTooltip('Folders'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const ValueKey<String>('sidebar-study-desk')));
      await tester.pumpAndSettle();
      await expectLater(find.byType(GreatnoteApp), matchesGoldenFile('shots/${name}_empty.png'));
      await tester.tap(find.byKey(const ValueKey<String>('study-empty-add-sources')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey<String>('study-pick-note-${note.id}')));
      await tester.pump();
      await expectLater(find.byType(GreatnoteApp), matchesGoldenFile('shots/${name}_picker.png'));
      await tester.tap(find.byKey(const ValueKey<String>('study-source-done')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey<String>('study-composer')), 'Explain mitosis3');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      client.answer(
        'Mitosis proceeds in **phases**, each with its own role. [[N1:P2:L4-L7]]\n\n'
        'A detail worth circling. [[N1:P2:C 100 200 300 400]]',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cell Biology · p.2').first);
      await tester.pumpAndSettle();
      await expectLater(find.byType(GreatnoteApp), matchesGoldenFile('shots/${name}_pane.png'));
    });
  }
}
