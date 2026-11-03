import 'package:flutter/gestures.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_icons.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/page/note_document.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/widgets/page_controls.dart';
import 'package:greatnote/features/editor/document_io/document_platform.dart';
import 'package:greatnote/features/library/cloud/cloud_sync_state.dart';
import 'package:greatnote/features/library/cloud/google_drive_backup_service.dart';
import 'package:greatnote/features/library/library_dialogs.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/editor/widgets/tool_palette.dart';
import 'package:greatnote/features/library/library_screen.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/payment/billing_backend.dart';
import 'package:greatnote/features/payment/subscription_controller.dart';
import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';

import '../../helpers/ai_fakes.dart';
import '../../helpers/document_io_fakes.dart';
import '../../helpers/google_drive_fakes.dart';
import '../../helpers/payment_fakes.dart';
import '../../helpers/pump_app.dart';

final DateTime _now = DateTime(2026, 10, 14, 15, 30);

class _RefreshProbeRepository extends InMemoryNoteRepository {
  final Completer<void> gate = Completer<void>();
  final Set<String> started = <String>{};

  Future<T> _probe<T>(String name, Future<T> Function() read) async {
    started.add(name);
    await gate.future;
    return read();
  }

  @override
  Future<List<NoteEntry>> trash() =>
      _probe<List<NoteEntry>>('trash', super.trash);

  @override
  Future<FolderListing> list(String? folderId) =>
      _probe<FolderListing>('list', () => super.list(folderId));

  @override
  Future<List<Folder>> pathTo(String? folderId) =>
      _probe<List<Folder>>('path', () => super.pathTo(folderId));

  @override
  Future<List<Folder>> allFolders() =>
      _probe<List<Folder>>('folders', super.allFolders);

  @override
  Future<Map<String, int>> itemCounts() =>
      _probe<Map<String, int>>('counts', super.itemCounts);
}

/// Holds every folder read back while [held] is not completed.
class _HeldReadsRepository extends InMemoryNoteRepository {
  _HeldReadsRepository() : super(newId: _ids());

  static String Function() _ids() {
    int ids = 0;
    return () => 'held${ids++}';
  }

  Completer<void>? held;

  @override
  Future<FolderListing> list(String? folderId) async {
    await held?.future;
    return super.list(folderId);
  }
}

class _SearchProbeRepository extends InMemoryNoteRepository {
  int searches = 0;

  @override
  Future<FolderListing> search(String query) {
    searches++;
    return super.search(query);
  }
}

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

/// [finder], among the folders and notes in the main area.
Finder _items(Finder finder) => find.descendant(
  of: find.byKey(const ValueKey<String>('library-items')),
  matching: finder,
);

/// [finder], in the folder sidebar.
Finder _sidebar(Finder finder) => find.descendant(
  of: find.byKey(const ValueKey<String>('library-sidebar')),
  matching: finder,
);

/// Opens [title]'s menu in the main area and picks [action].
Future<void> _menuAction(
  WidgetTester tester,
  String title,
  String action,
) async {
  await tester.tap(_items(find.byTooltip('More actions for $title')));
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
  testWidgets('with large system text the cards widen to keep their captions', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    final NoteEntry note = await repository.createNote(title: 'Plan');
    final Finder card = find.byKey(ValueKey<String>('note-${note.id}'));
    await _pumpLibrary(tester, repository);
    final double width = tester.getSize(card).width;

    // Otherwise the title and date are cut short and the page shrinks.
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(tester.getSize(card).width, greaterThan(width * 1.3));
  });

  testWidgets('library refresh starts independent reads together', (
    WidgetTester tester,
  ) async {
    final _RefreshProbeRepository repository = _RefreshProbeRepository();
    addTearDown(() {
      if (!repository.gate.isCompleted) repository.gate.complete();
      repository.dispose();
    });

    await tester.pumpWidget(
      GreatnoteApp(
        home: LibraryScreen(repository: repository, clock: () => _now),
      ),
    );
    await tester.pump();

    expect(
      repository.started,
      containsAll(<String>{'trash', 'list', 'path', 'folders', 'counts'}),
    );
    repository.gate.complete();
    await tester.pumpAndSettle();
  }, experimentalLeakTesting: LeakTesting.settings.withTrackedAll());

  testWidgets('library search coalesces rapid typing', (
    WidgetTester tester,
  ) async {
    final _SearchProbeRepository repository = _SearchProbeRepository();
    addTearDown(repository.dispose);
    await _pumpLibrary(tester, repository);

    final Finder search = find.byType(TextField);
    await tester.enterText(search, 'a');
    await tester.enterText(search, 'ab');
    await tester.enterText(search, 'abc');
    expect(repository.searches, 0);

    await tester.pump(const Duration(milliseconds: 119));
    expect(repository.searches, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(repository.searches, 1);
    await tester.pumpAndSettle();
  }, experimentalLeakTesting: LeakTesting.settings.withTrackedAll());

  testWidgets('notes open side by side in tabs', (WidgetTester tester) async {
    final InMemoryNoteRepository repository = _repository();
    final NoteEntry alpha = await repository.createNote(title: 'Alpha');
    final NoteEntry beta = await repository.createNote(title: 'Beta');
    await _pumpLibrary(tester, repository);
    final Finder editors = find.byType(EditorScreen, skipOffstage: false);

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey<String>('note-tab-${alpha.id}')), findsOne);

    // Back in the library, Alpha stays open; Beta opens beside it.
    await tester.tap(find.byTooltip('Open another note'));
    await tester.pumpAndSettle();
    expect(editors, findsOneWidget);
    expect(find.byType(EditorScreen), findsNothing);
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(editors, findsNWidgets(2));
    expect(find.byType(EditorScreen), findsOneWidget);
    expect(find.byKey(ValueKey<String>('note-tab-${alpha.id}')), findsOne);
    expect(find.byKey(ValueKey<String>('note-tab-${beta.id}')), findsOne);
    expect(
      tester.widget<EditorScreen>(find.byType(EditorScreen)).noteId,
      beta.id,
    );

    // One toolbar for the window, held by the note in front.
    final Finder toolbar = find.byType(ToolPalette, skipOffstage: false);
    expect(toolbar, findsOneWidget);
    final Element betaToolbar = tester.element(toolbar);

    // Another tab shows its note, and keeps the other's editor.
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    // The same toolbar moved over to it, not one built anew.
    expect(toolbar, findsOneWidget);
    expect(tester.element(toolbar), same(betaToolbar));
    expect(
      find.ancestor(
        of: toolbar,
        matching: find.byWidgetPredicate(
          (Widget widget) =>
              widget is EditorScreen && widget.noteId == alpha.id,
        ),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<EditorScreen>(find.byType(EditorScreen)).noteId,
      alpha.id,
    );
    expect(editors, findsNWidgets(2));

    await tester.tap(find.byTooltip('Close Alpha'));
    await tester.pumpAndSettle();
    expect(editors, findsOneWidget);
    expect(
      tester.widget<EditorScreen>(find.byType(EditorScreen)).noteId,
      beta.id,
    );

    // Closing the last tab returns to the library.
    await tester.tap(find.byTooltip('Close Beta'));
    await tester.pumpAndSettle();
    expect(editors, findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
  });

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
    expect(_items(find.byType(ListView)), findsOneWidget);
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
    await tester.tap(find.text('Template…'));
    await tester.pumpAndSettle();
    // Name and paper are configured together before the editor opens.
    expect(find.text('File name'), findsOneWidget);
    expect(find.text('Page size'), findsOneWidget);
    expect(find.text('Fit to screen'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey<String>('new-note-name')),
      'Calculus notes',
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsOneWidget);
    expect(find.byTooltip('Back to library'), findsOneWidget);

    final Offset origin = tester.getRect(find.byType(InkCanvas)).topLeft;
    await _drawLine(
      tester,
      origin + const Offset(100, 100),
      origin + const Offset(300, 120),
    );
    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add blank page'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back to library'));
    await tester.pumpAndSettle();

    expect(find.byType(LibraryScreen), findsOneWidget);
    final NoteEntry entry = (await repository.list(null)).notes.single;
    expect(entry.title, 'Calculus notes');
    expect(entry.pageCount, 2);
    expect(entry.modified.isAfter(entry.created), isTrue);
    final NoteContent content = await repository.loadNote(entry.id);
    expect(content.pages.first.strokes, hasLength(1));
    expect(find.text('Calculus notes'), findsOneWidget);
  });

  testWidgets('a new note is made from the template chosen for it', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    await _pumpLibrary(tester, repository);

    await tester.tap(find.byTooltip('New note'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Template…'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('template-paper-grid')));
    await tester.tap(
      find.byKey(const ValueKey<String>('template-size-a4Portrait')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.byType(EditorScreen), findsOneWidget);
    expect(tester.getSize(find.byType(InkCanvas)), const Size(794, 1123));
    final NoteEntry entry = (await repository.list(null)).notes.single;
    final PageSetup setup = (await repository.loadNote(
      entry.id,
    )).pages.single.setup;
    expect(setup.size, PageSize.a4Portrait);
    expect(setup.background, PageBackground.grid);

    // The next note offers the same template first.
    await tester.tap(find.byTooltip('Back to library'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New note'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Template…'));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(
        find.byKey(const ValueKey<String>('template-size-a4Portrait')),
      ),
      isSemantics(isSelected: true),
    );
  });

  testWidgets('cancelling the template makes no note', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    await _pumpLibrary(tester, repository);

    await tester.tap(find.byTooltip('New note'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Template…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.byType(EditorScreen), findsNothing);
    expect((await repository.list(null)).notes, isEmpty);
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

    expect(
      find.byKey(const ValueKey<String>('page-background')),
      findsOneWidget,
    );
    // The overview shows both pages, on the first.
    await tester.tap(find.byTooltip('Page overview'));
    await tester.pumpAndSettle();
    final NoteDocument opened = tester
        .widget<PageOverviewPanel>(find.byType(PageOverviewPanel))
        .document;
    expect(opened.pageCount, 2);
    expect(opened.currentIndex, 0);
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
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
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

  testWidgets('New note offers a PDF import, a template, and quick start', (
    WidgetTester tester,
  ) async {
    await _pumpLibrary(tester, _repository());
    expect(find.byTooltip('Import PDF'), findsNothing);

    final Rect button = tester.getRect(find.byTooltip('New note'));

    await tester.tap(find.byTooltip('New note'));
    await tester.pumpAndSettle();
    expect(find.text('Import editable PDF'), findsNothing);
    // Top to bottom, with the quickest last, nearest the button.
    final List<double> rows = <String>['Import PDF', 'Template…', 'Quick start']
        .map(
          (String label) =>
              tester.getCenter(find.widgetWithText(MenuItemButton, label)).dy,
        )
        .toList();
    expect(rows[0], lessThan(rows[1]));
    expect(rows[1], lessThan(rows[2]));
    final Finder menu = find
        .ancestor(
          of: find.widgetWithText(MenuItemButton, 'Quick start'),
          matching: find.byType(Material),
        )
        .first;
    expect(tester.getRect(menu).right, moreOrLessEquals(button.right));
  });

  testWidgets('the template dialog moves with the keyboard, frame by frame', (
    WidgetTester tester,
  ) async {
    addTearDown(tester.view.resetViewInsets);
    await _pumpLibrary(tester, _repository());
    await tester.tap(find.byTooltip('New note'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Template…'));
    await tester.pumpAndSettle();
    final Finder dialog = find.byType(AlertDialog);
    final double resting = tester.getRect(dialog).bottom;
    // Beneath the dialog, it would rise with the library were it resized.
    final Rect button = tester.getRect(find.byTooltip('New note'));

    // A keyboard partway up its slide: the dialog keeps clear of it on the
    // same frame, not easing after it, and the library beneath ignores it.
    final double keyboard = 120 * tester.view.devicePixelRatio;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    await tester.pump();
    final double raised = tester.getRect(dialog).bottom;
    expect(raised, lessThan(resting));
    await tester.pumpAndSettle();
    expect(tester.getRect(dialog).bottom, raised);
    expect(tester.getRect(find.byTooltip('New note')), button);
  });

  testWidgets('the new note menu does not stay over the note it opened', (
    WidgetTester tester,
  ) async {
    await _pumpLibrary(tester, _repository());
    await tester.tap(find.byTooltip('New note'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quick start'));
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsOneWidget);
    // The library is offstage now, but its menu floats in the navigator's
    // overlay and would still be painted, so offstage has to count here.
    expect(find.text('Quick start', skipOffstage: false), findsNothing);

    // Back in the library, it opens and closes as ever.
    await tester.tap(find.byTooltip('Back to library'));
    await tester.pumpAndSettle();
    expect(find.text('Quick start'), findsNothing);
    await tester.tap(find.byTooltip('New note'));
    await tester.pumpAndSettle();
    expect(find.text('Quick start'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    expect(find.text('Quick start'), findsNothing);
  });

  testWidgets('quick start makes a blank A4 note, then the last template', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    await _pumpLibrary(tester, repository);

    final Set<String> seen = <String>{};
    Future<PageSetup> quickStart() async {
      await tester.tap(find.byTooltip('New note'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Quick start'));
      await tester.pumpAndSettle();
      // Straight into the editor, with nothing asked.
      expect(find.text('File name'), findsNothing);
      expect(find.byType(EditorScreen), findsOneWidget);
      await tester.tap(find.byTooltip('Back to library'));
      await tester.pumpAndSettle();
      final NoteEntry newest = (await repository.list(
        null,
      )).notes.singleWhere((NoteEntry note) => !seen.contains(note.id));
      seen.addAll((await repository.list(null)).notes.map((n) => n.id));
      expect(newest.title, startsWith(untitledNoteName));
      return (await repository.loadNote(newest.id)).pages.single.setup;
    }

    expect(await quickStart(), const PageSetup());

    await tester.tap(find.byTooltip('New note'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Template…'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('template-paper-grid')));
    await tester.tap(
      find.byKey(const ValueKey<String>('template-size-letterLandscape')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back to library'));
    await tester.pumpAndSettle();
    seen.addAll((await repository.list(null)).notes.map((n) => n.id));

    expect(
      await quickStart(),
      const PageSetup(
        size: PageSize.letterLandscape,
        background: PageBackground.grid,
      ),
    );
  });

  group('dragging', () {
    /// Holds [from] until it lifts, then drags it onto [to] and lets go.
    Future<void> dragOnto(WidgetTester tester, Finder from, Finder to) async {
      final TestGesture drag = await tester.startGesture(
        tester.getCenter(from),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await drag.moveTo(tester.getCenter(to));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
    }

    testWidgets('a held note dropped on a folder moves into it', (
      WidgetTester tester,
    ) async {
      final InMemoryNoteRepository repository = _repository();
      final Folder archive = await repository.createFolder('Archive');
      await repository.createNote(title: 'Old');
      await _pumpLibrary(tester, repository);

      await dragOnto(
        tester,
        _items(find.text('Old')),
        _items(find.text('Archive')),
      );

      expect(_items(find.text('Old')), findsNothing);
      expect((await repository.list(archive.id)).notes.single.title, 'Old');
      expect(find.text('Moved "Old" to Archive'), findsOneWidget);
    });

    testWidgets('a held folder dropped on another folder nests in it', (
      WidgetTester tester,
    ) async {
      final InMemoryNoteRepository repository = _repository();
      final Folder school = await repository.createFolder('School');
      await repository.createFolder('Math');
      await _pumpLibrary(tester, repository);

      await dragOnto(
        tester,
        _items(find.text('Math')),
        _items(find.text('School')),
      );

      expect((await repository.list(school.id)).folders.single.name, 'Math');
    });

    testWidgets('dropped on the sidebar Library, it moves to the top', (
      WidgetTester tester,
    ) async {
      final InMemoryNoteRepository repository = _repository();
      final Folder archive = await repository.createFolder('Archive');
      await repository.createNote(title: 'Old', folderId: archive.id);
      await _pumpLibrary(tester, repository);
      await tester.tap(_items(find.text('Archive')));
      await tester.pumpAndSettle();

      await dragOnto(
        tester,
        _items(find.text('Old')),
        find.byKey(const ValueKey<String>('sidebar-library')),
      );

      expect((await repository.list(null)).notes.single.title, 'Old');
      expect((await repository.list(archive.id)).notes, isEmpty);
    });

    testWidgets('the feedback icon, not the stylus, selects a destination', (
      WidgetTester tester,
    ) async {
      final InMemoryNoteRepository repository = _repository();
      final Folder archive = await repository.createFolder('Archive');
      await repository.createNote(title: 'Old');
      await _pumpLibrary(tester, repository);

      final Finder sidebarFolder = find.byKey(
        ValueKey<String>('sidebar-folder-${archive.id}'),
      );
      final Rect destination = tester.getRect(sidebarFolder);
      final TestGesture drag = await tester.startGesture(
        tester.getCenter(_items(find.text('Old'))),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      // The stylus stays below the row while the feedback icon, which rides
      // 16 px above it, is visibly inside the destination.
      await drag.moveTo(Offset(destination.center.dx, destination.bottom + 8));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();

      expect((await repository.list(archive.id)).notes.single.title, 'Old');
      expect((await repository.list(null)).notes, isEmpty);
    });

    testWidgets('a searched folder drops into the active breadcrumb', (
      WidgetTester tester,
    ) async {
      final InMemoryNoteRepository repository = _repository();
      final Folder destination = await repository.createFolder('Destination');
      final Folder source = await repository.createFolder('Source');
      await _pumpLibrary(tester, repository);
      await tester.tap(_items(find.text('Destination')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Source');
      await tester.pumpAndSettle();

      await dragOnto(
        tester,
        _items(find.text('Source')),
        find.byKey(ValueKey<String>('breadcrumb-${destination.id}')),
      );

      expect(
        (await repository.list(destination.id)).folders.single.id,
        source.id,
      );
      expect((await repository.list(null)).folders, <Folder>[destination]);
    });

    testWidgets('a quick tap still opens, and a short drag moves nothing', (
      WidgetTester tester,
    ) async {
      final InMemoryNoteRepository repository = _repository();
      final Folder archive = await repository.createFolder('Archive');
      await repository.createNote(title: 'Old');
      await _pumpLibrary(tester, repository);

      final TestGesture drag = await tester.startGesture(
        tester.getCenter(_items(find.text('Old'))),
      );
      await drag.moveTo(tester.getCenter(_items(find.text('Archive'))));
      await drag.up();
      await tester.pumpAndSettle();

      expect((await repository.list(archive.id)).notes, isEmpty);
    });
  });

  testWidgets('moves, duplicates, and deletes from the menu', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    await repository.createFolder('Archive');
    await repository.createNote(title: 'Old');
    await _pumpLibrary(tester, repository);

    await _menuAction(tester, 'Old', 'Duplicate');
    expect(find.text('Old copy'), findsOneWidget);

    await _menuAction(tester, 'Old copy', 'Move to…');
    await tester.tap(find.text('Archive').last);
    await tester.pumpAndSettle();
    expect(find.text('Old copy'), findsNothing);
    expect(find.textContaining('1 item'), findsOneWidget);

    // A note goes to Recently Deleted at once, and Undo brings it back.
    await _menuAction(tester, 'Old', 'Delete');
    expect(find.text('Moved "Old" to Recently Deleted'), findsOneWidget);
    expect(_items(find.text('Old')), findsNothing);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(_items(find.text('Old')), findsOneWidget);
    expect(await repository.trash(), isEmpty);

    // A folder is asked about first: it is not kept, its notes are.
    await _menuAction(tester, 'Archive', 'Delete');
    expect(
      find.textContaining('the 1 note inside it will move to Recently Deleted'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Archive'), findsNothing);
    expect(await repository.allFolders(), isEmpty);
    expect((await repository.search('copy')).notes, isEmpty);
    expect((await repository.trash()).single.title, 'Old copy');
  });

  group('the hint that a note was deleted', () {
    const String hint = 'Moved "Old" to Recently Deleted';

    testWidgets('goes by itself after five seconds', (
      WidgetTester tester,
    ) async {
      final InMemoryNoteRepository repository = _repository();
      await repository.createNote(title: 'Old');
      await _pumpLibrary(tester, repository);

      await _menuAction(tester, 'Old', 'Delete');
      expect(find.text(hint), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 4900));
      expect(find.text(hint), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.text(hint), findsNothing);
    });

    testWidgets('goes with the next action', (WidgetTester tester) async {
      final InMemoryNoteRepository repository = _repository();
      await repository.createNote(title: 'Old');
      await repository.createNote(title: 'Next');
      await _pumpLibrary(tester, repository);

      await _menuAction(tester, 'Old', 'Delete');
      expect(find.text(hint), findsOneWidget);

      await tester.tap(_items(find.byTooltip('More actions for Next')));
      await tester.pumpAndSettle();
      expect(find.text(hint), findsNothing);
    });

    testWidgets('leaves Undo working, even held down', (
      WidgetTester tester,
    ) async {
      final InMemoryNoteRepository repository = _repository();
      await repository.createNote(title: 'Old');
      await _pumpLibrary(tester, repository);

      await _menuAction(tester, 'Old', 'Delete');
      final TestGesture press = await tester.startGesture(
        tester.getCenter(find.text('Undo')),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(hint), findsOneWidget);
      await press.up();
      await tester.pumpAndSettle();

      expect(find.text(hint), findsNothing);
      expect(_items(find.text('Old')), findsOneWidget);
      expect(await repository.trash(), isEmpty);
    });
  });

  testWidgets('Recently Deleted restores notes and deletes them for good', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    final NoteEntry kept = await repository.createNote(title: 'Kept');
    final NoteEntry gone = await repository.createNote(title: 'Gone');
    await repository.deleteNote(kept.id);
    await repository.deleteNote(gone.id);
    await _pumpLibrary(tester, repository);
    expect(find.text('Nothing here yet'), findsOneWidget);

    await tester.tap(_sidebar(find.text('Recently Deleted')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('New note'), findsNothing);
    expect(find.textContaining('days left'), findsNWidgets(2));

    // A tap offers what can be done with a deleted note; it does not open.
    await tester.tap(_items(find.text('Kept')));
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsNothing);
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(_items(find.text('Kept')), findsNothing);
    expect((await repository.list(null)).notes.single.title, 'Kept');

    await tester.tap(find.text('Empty'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(await repository.trash(), isEmpty);
    expect(find.text('No recently deleted notes'), findsOneWidget);

    await tester.tap(find.byTooltip('Back to library'));
    await tester.pumpAndSettle();
    expect(_items(find.text('Kept')), findsOneWidget);
  });

  testWidgets('selects several items to move or delete them together', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    final Folder archive = await repository.createFolder('Archive');
    await repository.createNote(title: 'First');
    await repository.createNote(title: 'Second');
    await repository.createNote(title: 'Third');
    await _pumpLibrary(tester, repository);

    await tester.tap(find.byTooltip('Select'));
    await tester.pumpAndSettle();
    expect(find.text('Select items'), findsOneWidget);
    expect(find.byTooltip('New note'), findsNothing);
    expect(find.byTooltip('More actions for First'), findsNothing);

    // A tap now selects instead of opening.
    await tester.tap(_items(find.text('First')));
    await tester.tap(_items(find.text('Second')));
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsNothing);
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Move selected'));
    await tester.pumpAndSettle();
    expect(find.text('Move 2 notes to'), findsOneWidget);
    await tester.tap(find.text('Archive').last);
    await tester.pumpAndSettle();
    expect(find.text('Moved 2 notes to Archive'), findsOneWidget);
    expect(find.byTooltip('Select'), findsOneWidget);
    expect((await repository.list(archive.id)).notes, hasLength(2));

    await tester.tap(find.byTooltip('Select'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Select all'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.byTooltip('Delete selected'));
    await tester.pumpAndSettle();
    expect(find.text('Delete 1 note and 1 folder?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(await repository.allFolders(), isEmpty);
    // The notes moved into Archive went with it.
    expect((await repository.search('i')).notes, isEmpty);
    expect(find.text('Nothing here yet'), findsOneWidget);
  });

  testWidgets('back and Done leave selection without acting', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    await repository.createNote(title: 'Kept');
    await _pumpLibrary(tester, repository);

    await tester.tap(find.byTooltip('Select'));
    await tester.pumpAndSettle();
    await tester.tap(_items(find.text('Kept')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Select'), findsOneWidget);
    expect(find.byTooltip('New note'), findsOneWidget);

    await tester.tap(find.byTooltip('Select'));
    await tester.pumpAndSettle();
    expect(find.text('Select items'), findsOneWidget);
    await tester.tap(find.byTooltip('Done selecting'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Select'), findsOneWidget);
    expect((await repository.list(null)).notes, hasLength(1));
  });

  testWidgets('folders open, and breadcrumbs lead back up', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    final Folder outer = await repository.createFolder('Physics');
    await repository.createFolder('Lab', parentId: outer.id);
    await _pumpLibrary(tester, repository);

    await tester.tap(_items(find.text('Physics')));
    await tester.pumpAndSettle();
    await tester.tap(_items(find.text('Lab')));
    await tester.pumpAndSettle();
    expect(find.text('Nothing here yet'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Physics'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Physics'));
    await tester.pumpAndSettle();
    expect(_items(find.text('Lab')), findsOneWidget);
    await tester.tap(find.byTooltip('Up one folder'));
    await tester.pumpAndSettle();
    expect(_items(find.text('Physics')), findsOneWidget);
    expect(find.byTooltip('Up one folder'), findsNothing);
  });

  testWidgets('leaving a note goes back to the folder it was opened from', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    final Folder outer = await repository.createFolder('Physics');
    final Folder lab = await repository.createFolder('Lab', parentId: outer.id);
    await repository.createNote(title: 'Optics', folderId: lab.id);
    await _pumpLibrary(tester, repository);

    await tester.tap(_items(find.text('Physics')));
    await tester.pumpAndSettle();
    await tester.tap(_items(find.text('Lab')));
    await tester.pumpAndSettle();
    await tester.tap(_items(find.text('Optics')));
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsOneWidget);

    await tester.tap(find.byTooltip('Back to library'));
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsNothing);
    expect(_items(find.text('Optics')), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Physics'), findsOneWidget);

    // The system back gesture leaves the same way.
    await tester.tap(_items(find.text('Optics')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsNothing);
    expect(_items(find.text('Optics')), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Physics'), findsOneWidget);
  });

  testWidgets('new folder asks for a name and a color', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    await _pumpLibrary(tester, repository);
    await tester.tap(find.byTooltip('New folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Ideas');
    await tester.tap(find.byKey(const ValueKey<String>('folder-color-green')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(_items(find.text('Ideas')), findsOneWidget);
    expect(_sidebar(find.text('Ideas')), findsOneWidget);
    expect((await repository.allFolders()).single.color, FolderColor.green);
  });

  testWidgets('the sidebar shows the folder tree and opens folders', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    final Folder physics = await repository.createFolder(
      'Physics',
      color: FolderColor.purple,
    );
    final Folder lab = await repository.createFolder(
      'Lab',
      parentId: physics.id,
    );
    await repository.createNote(title: 'Optics', folderId: lab.id);
    await _pumpLibrary(tester, repository);

    // Folded: only the top level.
    expect(_sidebar(find.text('Physics')), findsOneWidget);
    expect(_sidebar(find.text('Lab')), findsNothing);
    final Icon icon = tester.widget<Icon>(
      _sidebar(find.byIcon(AppIcons.folder)).first,
    );
    // Folder colors are deepened a little on the pale desk.
    expect(
      icon.color,
      Color.lerp(AppColors.light.highlighters[3], Colors.black, 0.18),
    );

    await tester.tap(find.byTooltip('Expand Physics'));
    await tester.pumpAndSettle();
    expect(_sidebar(find.text('Lab')), findsOneWidget);

    // Opening a folder from the sidebar shows what is in it.
    await tester.tap(_sidebar(find.text('Lab')));
    await tester.pumpAndSettle();
    expect(_items(find.text('Optics')), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Physics'), findsOneWidget);

    await tester.tap(find.byTooltip('Collapse Physics'));
    await tester.pumpAndSettle();
    expect(_sidebar(find.text('Lab')), findsNothing);

    await tester.tap(_sidebar(find.text('Library')));
    await tester.pumpAndSettle();
    expect(_items(find.text('Physics')), findsOneWidget);
  });

  testWidgets('subfolders are made in the open folder', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    final Folder physics = await repository.createFolder('Physics');
    await repository.createFolder('Lab', parentId: physics.id);
    await _pumpLibrary(tester, repository);

    // Folders no longer offer a New subfolder action of their own.
    await tester.tap(find.byTooltip('More actions for Physics').first);
    await tester.pumpAndSettle();
    expect(find.text('New subfolder'), findsNothing);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await tester.tap(_items(find.text('Physics')));
    await tester.pumpAndSettle();
    await tester.tap(_sidebar(find.byTooltip('New folder')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Theory');
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(
      (await repository.list(physics.id)).folders.map((Folder f) => f.name),
      containsAll(<String>['Lab', 'Theory']),
    );
  });

  testWidgets('a folder can be recolored', (WidgetTester tester) async {
    final InMemoryNoteRepository repository = _repository();
    await repository.createFolder('Physics');
    await _pumpLibrary(tester, repository);

    await _menuAction(tester, 'Physics', 'Color…');
    await tester.tap(find.byKey(const ValueKey<String>('folder-color-red')));
    await tester.pumpAndSettle();
    expect((await repository.allFolders()).single.color, FolderColor.red);
  });

  testWidgets('on compact widths the folders are a drawer', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    await repository.createFolder('Physics');
    await _pumpLibrary(tester, repository, viewport: TestViewport.compact);
    expect(find.byKey(const ValueKey<String>('library-sidebar')), findsNothing);

    await tester.tap(find.byTooltip('Folders'));
    await tester.pumpAndSettle();
    await tester.tap(_sidebar(find.text('Physics')));
    await tester.pumpAndSettle();
    // The drawer closes on the folder it opened.
    expect(find.byType(Drawer), findsNothing);
    expect(find.text('Nothing here yet'), findsOneWidget);
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
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pumpAndSettle();
    expect(find.text('Calculus'), findsOneWidget);
    expect(find.textContaining('In Maths'), findsOneWidget);
    expect(find.text('History'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump(const Duration(milliseconds: 120));
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
        'Select',
        'New folder',
        'New note',
        'More actions for Note one',
        'More actions for Folder one',
      ]) {
        for (final Element control in find.byTooltip(tooltip).evaluate()) {
          final Size size = control.size!;
          expect(size.width, greaterThanOrEqualTo(AppSizes.minTouchTarget));
          expect(size.height, greaterThanOrEqualTo(AppSizes.minTouchTarget));
        }
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
      find.byTooltip('Account'),
      find.byTooltip('Sort'),
      find.byTooltip('Show as list'),
      find.byTooltip('Select'),
      _sidebar(find.byTooltip('New folder')),
      find.descendant(
        of: find.byKey(const ValueKey<String>('sidebar-library')),
        matching: find.byType(InkWell),
      ),
      find.byTooltip('Plans & Credits'),
      find.descendant(
        of: find.byKey(const ValueKey<String>('sidebar-trash')),
        matching: find.byType(InkWell),
      ),
      _items(find.byType(InkWell)).first,
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

  testWidgets('shared PDFs from other apps are imported and opened', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    final FakeSharedDocumentSource shared = FakeSharedDocumentSource(
      initial: <PickedDocument>[
        PickedDocument(
          name: 'Lecture 1.pdf',
          bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
        ),
      ],
    );
    addTearDown(shared.dispose);

    setViewportSize(tester, TestViewport.tabletLandscape.size);
    await tester.pumpWidget(
      GreatnoteApp(
        themeMode: ThemeMode.light,
        home: LibraryScreen(
          repository: repository,
          clock: () => _now,
          sharedDocuments: shared,
          pdfRasterizer: FakePdfRasterizer(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(EditorScreen), findsOneWidget);
    expect(find.text('Lecture 1'), findsWidgets);
    expect((await repository.list(null)).notes.single.title, 'Lecture 1');

    shared.share(
      PickedDocument(
        name: 'Handout.pdf',
        bytes: Uint8List.fromList(<int>[5, 6, 7, 8]),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(AppMotion.smooth.duration);
    await tester.pumpAndSettle();

    expect(find.byType(EditorScreen), findsOneWidget);
    expect(find.text('Handout'), findsWidgets);
    expect(
      (await repository.list(null)).notes.map((NoteEntry n) => n.title).toSet(),
      <String>{'Lecture 1', 'Handout'},
    );
  });

  testWidgets('opening signed out asks for Google first, then calibration', (
    WidgetTester tester,
  ) async {
    final FakeGoogleDriveClient drive = FakeGoogleDriveClient();
    setViewportSize(tester, TestViewport.tabletLandscape.size);
    await tester.pumpWidget(
      GreatnoteApp(
        home: LibraryScreen(
          repository: _repository(),
          clock: () => _now,
          googleDriveClient: drive,
          onboard: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sign in to Etonia'), findsOneWidget);
    expect(find.text("Choose the AI's handwriting"), findsNothing);
    await tester.tap(find.text('Sign in with Google'));
    await tester.pumpAndSettle();

    expect(drive.currentAccount, isNotNull);
    expect(find.text('Sign in to Etonia'), findsNothing);
    expect(find.text("Choose the AI's handwriting"), findsOneWidget);
  });

  testWidgets('on Apple devices the first sign-in also offers Apple', (
    WidgetTester tester,
  ) async {
    final TestBillingBackend backend = TestBillingBackend()
      ..userId = null
      ..canSignInWithApple = true;
    final SubscriptionController subscription = SubscriptionController(
      store: InMemorySubscriptionStore(),
      backend: backend,
    );
    setViewportSize(tester, TestViewport.tabletLandscape.size);
    await tester.pumpWidget(
      GreatnoteApp(
        home: LibraryScreen(
          repository: _repository(),
          clock: () => _now,
          googleDriveClient: FakeGoogleDriveClient(),
          subscription: subscription,
          onboard: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('apple-sign-in')));
    await tester.pumpAndSettle();
    expect(backend.appleSignIns, 1);
    expect(find.text('Sign in to Etonia'), findsNothing);
    expect(find.text("Choose the AI's handwriting"), findsOneWidget);
    // Signing in scheduled the plan's expiry refresh; stop it with the test.
    subscription.dispose();
  });

  testWidgets('opening signed in with Apple is not asked to sign in again', (
    WidgetTester tester,
  ) async {
    final TestBillingBackend backend = TestBillingBackend()
      ..canSignInWithApple = true
      ..signInMethod = SignInMethod.apple;
    final SubscriptionController subscription = SubscriptionController(
      store: InMemorySubscriptionStore(),
      backend: backend,
    );
    addTearDown(subscription.dispose);
    setViewportSize(tester, TestViewport.tabletLandscape.size);
    await tester.pumpWidget(
      GreatnoteApp(
        home: LibraryScreen(
          repository: _repository(),
          clock: () => _now,
          googleDriveClient: FakeGoogleDriveClient(),
          subscription: subscription,
          onboard: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sign in to Etonia'), findsNothing);
    expect(find.text("Choose the AI's handwriting"), findsOneWidget);
  });

  testWidgets('opening brings what another device backed up to Drive', (
    WidgetTester tester,
  ) async {
    final FakeGoogleDriveClient drive = FakeGoogleDriveClient(signedIn: true);
    final InMemoryNoteRepository elsewhere = InMemoryNoteRepository();
    addTearDown(elsewhere.dispose);
    await elsewhere.createNote(title: 'Written on the iPad');
    await GoogleDriveBackupService(
      client: drive,
      repository: elsewhere,
    ).backUp();

    setViewportSize(tester, TestViewport.tabletLandscape.size);
    final InMemoryNoteRepository here = _repository();
    await tester.pumpWidget(
      GreatnoteApp(
        home: LibraryScreen(
          repository: here,
          clock: () => _now,
          googleDriveClient: drive,
          onboard: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Updated 1 note from Google Drive'), findsOneWidget);
    expect(
      (await here.list(null)).notes.map((NoteEntry note) => note.title),
      <String>['Written on the iPad'],
    );
    // In the library, behind the handwriting choice that opens on first
    // launch.
    expect(
      find.text('Written on the iPad', skipOffstage: false),
      findsOneWidget,
    );
  });

  group('backing up on leaving a note', () {
    late FakeGoogleDriveClient drive;
    late InMemoryNoteRepository repository;

    /// A library backing up to Drive, with one note in it, the note open.
    Future<void> openNote(WidgetTester tester) async {
      setViewportSize(tester, TestViewport.tabletLandscape.size);
      drive = FakeGoogleDriveClient(signedIn: true);
      repository = _repository();
      await repository.createNote(title: 'Lecture');
      final InMemoryCloudStateStore state = InMemoryCloudStateStore();
      await state.write(<String, Object?>{'driveLinked': true});
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
      await tester.tap(find.text('Lecture'));
      await tester.pumpAndSettle();
    }

    Future<void> draw(WidgetTester tester) {
      final Offset origin = tester.getRect(find.byType(InkCanvas)).topLeft;
      return _drawLine(
        tester,
        origin + const Offset(100, 100),
        origin + const Offset(300, 120),
      );
    }

    Future<void> leave(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Back to library'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    }

    testWidgets('an edited note is backed up when it is left', (
      WidgetTester tester,
    ) async {
      await openNote(tester);
      await draw(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(drive.uploads, isEmpty);

      await leave(tester);
      expect(drive.itemAt('Etonia/manifest.json'), isNotNull);
    });

    testWidgets('a note only looked at is not', (WidgetTester tester) async {
      await openNote(tester);
      await leave(tester);
      expect(drive.uploads, isEmpty);
    });
  });

  testWidgets('opening signed in goes straight on', (
    WidgetTester tester,
  ) async {
    setViewportSize(tester, TestViewport.tabletLandscape.size);
    await tester.pumpWidget(
      GreatnoteApp(
        home: LibraryScreen(
          repository: _repository(),
          clock: () => _now,
          googleDriveClient: FakeGoogleDriveClient(signedIn: true),
          onboard: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sign in to Etonia'), findsNothing);
    expect(find.text("Choose the AI's handwriting"), findsOneWidget);
  });
  group('folders visited before', () {
    testWidgets('open at once, the first visit too, with nothing to wait for', (
      WidgetTester tester,
    ) async {
      final _HeldReadsRepository repository = _HeldReadsRepository();
      addTearDown(repository.dispose);
      final Folder archive = await repository.createFolder('Archive');
      await repository.createNote(title: 'Old', folderId: archive.id);
      await _pumpLibrary(tester, repository);

      // Not visited yet, and its read held back: already there on the
      // frame it is opened, read with the library.
      repository.held = Completer<void>();
      await tester.tap(_items(find.text('Archive')));
      await tester.pump();
      expect(_items(find.text('Old')), findsOneWidget);
      repository.held!.complete();
      await tester.pumpAndSettle();
      expect(_items(find.text('Old')), findsOneWidget);
      repository.held = null;
      await tester.tap(find.byKey(const ValueKey<String>('sidebar-library')));
      await tester.pumpAndSettle();

      // And again on the way back.
      repository.held = Completer<void>();
      await tester.tap(_items(find.text('Archive')));
      await tester.pumpAndSettle();
      expect(_items(find.text('Old')), findsOneWidget);
      repository.held!.complete();
      await tester.pumpAndSettle();
      expect(_items(find.text('Old')), findsOneWidget);
    });

    testWidgets('show what changed in them since', (WidgetTester tester) async {
      final _HeldReadsRepository repository = _HeldReadsRepository();
      addTearDown(repository.dispose);
      final Folder archive = await repository.createFolder('Archive');
      await repository.createNote(title: 'Old', folderId: archive.id);
      final NoteEntry fresh = await repository.createNote(title: 'Fresh');
      await _pumpLibrary(tester, repository);
      await tester.tap(_items(find.text('Archive')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('sidebar-library')));
      await tester.pumpAndSettle();

      await repository.moveNote(fresh.id, archive.id);
      await tester.pumpAndSettle();
      repository.held = Completer<void>();
      await tester.tap(_items(find.text('Archive')));
      await tester.pumpAndSettle();
      expect(_items(find.text('Fresh')), findsOneWidget);
      expect(_items(find.text('Old')), findsOneWidget);
      repository.held!.complete();
      await tester.pumpAndSettle();
    });
  });
}
