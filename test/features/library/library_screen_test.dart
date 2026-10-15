import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/library_screen.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';

import '../../helpers/ai_fakes.dart';
import '../../helpers/pump_app.dart';

final DateTime _now = DateTime(2026, 10, 14, 15, 30);

/// A repository whose clock moves on a minute per change, so modified
/// times are distinct and ordered.
InMemoryNoteRepository _repository() {
  int ticks = 0;
  int ids = 0;
  final InMemoryNoteRepository repository = InMemoryNoteRepository(
    clock: () =>
        _now.subtract(const Duration(hours: 1)).add(Duration(minutes: ticks++)),
    newId: () => 'id${ids++}',
  );
  addTearDown(repository.dispose);
  return repository;
}

Future<void> _pumpLibrary(
  WidgetTester tester,
  NoteRepository repository, {
  TestViewport viewport = TestViewport.tabletLandscape,
  ThemeMode themeMode = ThemeMode.light,
}) async {
  setViewportSize(tester, viewport.size);
  await tester.pumpWidget(
    GreatnoteApp(
      themeMode: themeMode,
      home: LibraryScreen(repository: repository, clock: () => _now),
    ),
  );
  await tester.pumpAndSettle();
}

/// The titles of the visible items, in order: each item's first text.
List<String> _titles(WidgetTester tester) {
  final Finder items = find.byWidgetPredicate((Widget widget) {
    final Key? key = widget.key;
    return key is ValueKey<String> &&
        (key.value.startsWith('note-') || key.value.startsWith('folder-'));
  });
  return <String>[
    for (final Element item in items.evaluate())
      (find
                  .descendant(
                    of: find.byWidget(item.widget),
                    matching: find.byType(Text),
                  )
                  .evaluate()
                  .first
                  .widget
              as Text)
          .data!,
  ];
}

/// Whether keyboard focus is on, or inside, the widget found by [finder].
bool _hasFocus(WidgetTester tester, Finder finder) {
  final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) {
    return false;
  }
  final Element target = tester.element(finder);
  bool found = focused == target;
  focused.visitAncestorElements((Element ancestor) {
    found = found || ancestor == target;
    return !found;
  });
  return found;
}

Future<void> _menuAction(
  WidgetTester tester,
  String title,
  String action,
) async {
  await tester.tap(find.byTooltip('More actions for $title'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(action).last);
  await tester.pumpAndSettle();
}

Future<void> _drawLine(WidgetTester tester, Offset from, Offset to) async {
  final TestGesture gesture = await tester.startGesture(
    from,
    kind: PointerDeviceKind.stylus,
  );
  for (int i = 1; i <= 10; i++) {
    await gesture.moveTo(
      Offset.lerp(from, to, i / 10)!,
      timeStamp: Duration(milliseconds: 8 * i),
    );
  }
  await gesture.up(timeStamp: const Duration(milliseconds: 88));
  await tester.pump();
}

void main() {
  testWidgets('folders come first, then notes, in the chosen order', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    await repository.createNote(title: 'beta');
    await repository.createFolder('Zoology');
    await repository.createNote(title: 'Alpha');
    await repository.createFolder('art');
    await _pumpLibrary(tester, repository);

    // Newest first by default.
    expect(_titles(tester), <String>['art', 'Zoology', 'Alpha', 'beta']);

    await tester.tap(find.byTooltip('Sort'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Title'));
    await tester.pumpAndSettle();
    expect(_titles(tester), <String>['art', 'Zoology', 'Alpha', 'beta']);

    await tester.tap(find.byTooltip('Sort'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Date created'));
    await tester.pumpAndSettle();
    expect(_titles(tester), <String>['art', 'Zoology', 'Alpha', 'beta']);

    await repository.renameNote(
      (await repository.search('beta')).notes.single.id,
      'aardvark',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Sort'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Title'));
    await tester.pumpAndSettle();
    expect(_titles(tester), <String>['art', 'Zoology', 'aardvark', 'Alpha']);
  });

  testWidgets('switches between grid and list', (WidgetTester tester) async {
    final InMemoryNoteRepository repository = _repository();
    await repository.createNote(title: 'One');
    await _pumpLibrary(tester, repository);
    expect(find.byType(GridView), findsOneWidget);

    await tester.tap(find.byTooltip('Show as list'));
    await tester.pumpAndSettle();
    expect(find.byType(GridView), findsNothing);
    expect(find.byType(ListView), findsOneWidget);
    expect(find.byTooltip('Show as grid'), findsOneWidget);
  });

  testWidgets('a new note opens in the editor and is saved on the way back', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    await _pumpLibrary(tester, repository);
    expect(find.text('Nothing here yet'), findsOneWidget);

    await tester.tap(find.byTooltip('New note'));
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsOneWidget);
    expect(find.byTooltip('Back to library'), findsOneWidget);

    final Offset origin = tester.getRect(find.byType(InkCanvas)).topLeft;
    await _drawLine(
      tester,
      origin + const Offset(100, 100),
      origin + const Offset(300, 120),
    );
    await tester.tap(find.byTooltip('Add page'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back to library'));
    await tester.pumpAndSettle();

    expect(find.byType(LibraryScreen), findsOneWidget);
    final NoteEntry entry = (await repository.list(null)).notes.single;
    expect(entry.pageCount, 2);
    expect(entry.modified.isAfter(entry.created), isTrue);
    final NoteContent content = await repository.loadNote(entry.id);
    expect(content.pages.first.strokes, hasLength(1));
    expect(find.text('Untitled note'), findsOneWidget);
  });

  testWidgets('reopening a note restores its pages, setups, and ink', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    final NoteEntry note = await repository.createNote(title: 'Kept');
    await repository.saveNote(
      note.id,
      NoteContent(<StoredPage>[
        StoredPage(
          setup: const PageSetup(background: PageBackground.grid),
          strokes: <Stroke>[
            Stroke.fromPoints(
              style: const StrokeStyle(ink: InkPalette.ink, width: 3),
              points: const <InkVector>[InkVector(10, 10), InkVector(90, 40)],
            ),
          ],
        ),
        const StoredPage(
          setup: PageSetup(size: PageSize.a4Portrait),
          strokes: <Stroke>[],
        ),
      ]),
    );
    await _pumpLibrary(tester, repository);
    await tester.tap(find.text('Kept'));
    await tester.pumpAndSettle();

    expect(find.text('1 / 2'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('page-background')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Next page'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(InkCanvas).at(1)), const Size(794, 1123));
  });

  testWidgets('reopening a note brings back its AI conversation', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    final NoteEntry note = await repository.createNote(title: 'Chat');
    await repository.saveNote(
      note.id,
      NoteContent(<StoredPage>[
        StoredPage(
          setup: const PageSetup(),
          strokes: <Stroke>[
            Stroke.fromPoints(
              style: const StrokeStyle(ink: InkPalette.ink, width: 3),
              points: const <InkVector>[
                InkVector(100, 100),
                InkVector(300, 120),
              ],
            ),
          ],
        ),
      ]),
    );
    final FakeAiClient client = FakeAiClient();
    setViewportSize(tester, TestViewport.tabletLandscape.size);
    await tester.pumpWidget(
      GreatnoteApp(
        themeMode: ThemeMode.light,
        home: LibraryScreen(
          repository: repository,
          clock: () => _now,
          aiClient: client,
          initialNotationEnabled: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    InkController pageInk() => tester
        .widget<EditorScreen>(find.byType(EditorScreen))
        .document!
        .current
        .ink;

    Future<void> openAiOnTheLine() async {
      await tester.tap(find.byTooltip('Select'));
      await tester.pumpAndSettle();
      selectInk(pageInk(), const Rect.fromLTRB(50, 50, 350, 170));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('AI assistant'));
      await tester.pumpAndSettle();
      await settleAi(tester);
    }

    await tester.tap(find.text('Chat'));
    await tester.pumpAndSettle();
    await openAiOnTheLine();
    await tester.enterText(find.byType(TextField), 'What is this?');
    await settleAi(tester);
    await tester.tap(find.byTooltip('Send'));
    // Not settled: the answer is awaited with a spinner.
    await tester.pump();
    client.answer('A line.');
    await tester.pumpAndSettle();
    expect(find.text('A line.'), findsOneWidget);

    await tester.tap(find.byTooltip('Back to library'));
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsNothing);
    expect((await repository.loadNote(note.id)).aiSession, isNotNull);

    await tester.tap(find.text('Chat'));
    await tester.pumpAndSettle();
    await openAiOnTheLine();
    expect(find.text('What is this?'), findsOneWidget);
    expect(find.text('A line.'), findsOneWidget);
    expect(client.requests, hasLength(1));
  });

  testWidgets('autosaves while writing, after a pause', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    final NoteEntry note = await repository.createNote();
    await _pumpLibrary(tester, repository);
    await tester.tap(find.text('Untitled note'));
    await tester.pumpAndSettle();
    final Offset origin = tester.getRect(find.byType(InkCanvas)).topLeft;
    await _drawLine(
      tester,
      origin + const Offset(100, 100),
      origin + const Offset(300, 120),
    );
    expect((await repository.loadNote(note.id)).pages.first.strokes, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(
      (await repository.loadNote(note.id)).pages.first.strokes,
      hasLength(1),
    );
  });

  testWidgets('renames from the library and from the editor title', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    await repository.createNote(title: 'Draft');
    await _pumpLibrary(tester, repository);

    await _menuAction(tester, 'Draft', 'Rename');
    await tester.enterText(find.byType(TextField).last, 'Essay');
    await tester.tap(find.widgetWithText(TextButton, 'Rename'));
    await tester.pumpAndSettle();
    expect(find.text('Essay'), findsOneWidget);

    await tester.tap(find.text('Essay'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Note title, Essay'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Final essay');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Final essay'), findsOneWidget);
    expect((await repository.list(null)).notes.single.title, 'Final essay');
  });

  testWidgets('moves, duplicates, and deletes from the menu and long press', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    await repository.createFolder('Archive');
    await repository.createNote(title: 'Old');
    await _pumpLibrary(tester, repository);

    await _menuAction(tester, 'Old', 'Duplicate');
    expect(find.text('Old copy'), findsOneWidget);

    // A long press opens the same menu.
    await tester.longPress(find.text('Old copy'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive').last);
    await tester.pumpAndSettle();
    expect(find.text('Old copy'), findsNothing);
    expect(find.textContaining('1 item'), findsOneWidget);

    await _menuAction(tester, 'Old', 'Delete');
    expect(find.text('Delete note?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Old'), findsOneWidget);

    await _menuAction(tester, 'Archive', 'Delete');
    expect(
      find.textContaining('the 1 note inside it will be deleted'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Archive'), findsNothing);
    expect(await repository.allFolders(), isEmpty);
    expect((await repository.search('copy')).notes, isEmpty);
  });

  testWidgets('folders open, and breadcrumbs lead back up', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    final Folder outer = await repository.createFolder('Physics');
    await repository.createFolder('Lab', parentId: outer.id);
    await _pumpLibrary(tester, repository);

    await tester.tap(find.text('Physics'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lab'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing here yet'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Physics'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Physics'));
    await tester.pumpAndSettle();
    expect(find.text('Lab'), findsOneWidget);
    await tester.tap(find.byTooltip('Up one folder'));
    await tester.pumpAndSettle();
    expect(find.text('Physics'), findsOneWidget);
    expect(find.byTooltip('Up one folder'), findsNothing);
  });

  testWidgets('new folder asks for a name', (WidgetTester tester) async {
    final InMemoryNoteRepository repository = _repository();
    await _pumpLibrary(tester, repository);
    await tester.tap(find.byTooltip('New folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Ideas');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.text('Ideas'), findsOneWidget);
  });

  testWidgets('search finds notes in any folder, or says nothing matched', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    final Folder folder = await repository.createFolder('Maths');
    await repository.createNote(title: 'Calculus', folderId: folder.id);
    await repository.createNote(title: 'History');
    await _pumpLibrary(tester, repository);

    await tester.enterText(find.byType(TextField), 'calc');
    await tester.pumpAndSettle();
    expect(find.text('Calculus'), findsOneWidget);
    expect(find.textContaining('In Maths'), findsOneWidget);
    expect(find.text('History'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No notes match "zzz"'), findsOneWidget);
  });

  for (final TestViewport viewport in TestViewport.values) {
    testWidgets('controls have labels and 48 px targets: ${viewport.name}', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final InMemoryNoteRepository repository = _repository();
      await repository.createFolder('Folder one');
      await repository.createNote(title: 'Note one');
      await _pumpLibrary(tester, repository, viewport: viewport);

      for (final String tooltip in <String>[
        'Sort',
        'Show as list',
        'New folder',
        'New note',
        'More actions for Note one',
        'More actions for Folder one',
      ]) {
        final Size size = tester.getSize(find.byTooltip(tooltip));
        expect(size.width, greaterThanOrEqualTo(AppSizes.minTouchTarget));
        expect(size.height, greaterThanOrEqualTo(AppSizes.minTouchTarget));
      }
      expect(
        find.bySemanticsLabel(RegExp(r'^Note, Note one, modified Today')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^Folder, Folder one, modified')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      handle.dispose();
    });
  }

  testWidgets('Tab moves through the bar, then the items', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    await repository.createNote(title: 'Only');
    await _pumpLibrary(tester, repository);
    for (final Finder target in <Finder>[
      find.byType(TextField),
      find.byTooltip('Sort'),
      find.byTooltip('Show as list'),
      find.byTooltip('Import PDF'),
      find.byTooltip('New folder'),
      find.byType(InkWell).first,
      find.byTooltip('More actions for Only'),
      find.byTooltip('New note'),
    ]) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_hasFocus(tester, target), isTrue, reason: '$target');
    }
  });

  test('dates read naturally', () {
    expect(formatModified(DateTime(2026, 10, 14, 9, 5), _now), 'Today, 09:05');
    expect(formatModified(DateTime(2026, 10, 13, 23), _now), 'Yesterday');
    expect(formatModified(DateTime(2026, 3, 2), _now), 'Mar 2');
    expect(formatModified(DateTime(2024, 3, 2), _now), 'Mar 2, 2024');
  });
}
