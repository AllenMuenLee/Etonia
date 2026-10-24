import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_editor_page.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/note_tabs_page.dart';
import 'package:greatnote/features/library/open_notes.dart';
import 'package:greatnote/features/library/note_thumbnails.dart';

class _Repository extends InMemoryNoteRepository {
  final Map<String, Completer<NoteContent>> gates = {};
  final Map<String, int> reads = {};
  bool failSaves = false;

  @override
  Future<NoteContent> readContent(String id) {
    reads[id] = (reads[id] ?? 0) + 1;
    return gates[id]?.future ?? super.readContent(id);
  }

  @override
  Future<NoteEntry> saveNote(String id, NoteContent content) {
    if (failSaves) return Future.error(StateError('disk unavailable'));
    return super.saveNote(id, content);
  }
}

void main() {
  testWidgets(
    'available preview is visible on the first cold frame and owned by the page',
    (tester) async {
      final repo = _Repository();
      addTearDown(repo.dispose);
      final note = await repo.createNote();
      final gate = repo.gates[note.id] = Completer<NoteContent>();
      final original = (await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
        final picture = recorder.endRecording();
        try {
          return await picture.toImage(20, 30);
        } finally {
          picture.dispose();
        }
      }))!;
      final preview = NoteThumbnailImage(original);
      await tester.pumpWidget(
        GreatnoteApp(
          home: NoteEditorPage(repository: repo, note: note, preview: preview),
        ),
      );
      final shown =
          (tester
                      .widget<CustomPaint>(
                        find.descendant(
                          of: find.byKey(const ValueKey('note-opening-page')),
                          matching: find.byType(CustomPaint),
                        ),
                      )
                      .painter!
                  as PagePicturePainter)
              .image;
      expect(shown.isCloneOf(original), isTrue);
      preview.dispose();
      expect(shown.debugDisposed, isFalse);
      gate.complete(NoteContent.blank());
      await _settle(tester);
      // Once the editor's own page shows, the picture over it is let go.
      expect(find.byKey(const ValueKey('note-opening-page')), findsNothing);
      expect(shown.debugDisposed, isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test(
    'concurrent loads share a read; completion and failures release it',
    () async {
      final repo = _Repository();
      addTearDown(repo.dispose);
      final note = await repo.createNote();
      final gate = repo.gates[note.id] = Completer<NoteContent>();
      final first = repo.loadNote(note.id);
      expect(repo.loadNote(note.id), same(first));
      await Future<void>.delayed(Duration.zero);
      expect(repo.reads[note.id], 1);
      gate.completeError(StateError('read failed'));
      await expectLater(first, throwsStateError);
      repo.gates.remove(note.id);
      await repo.loadNote(note.id);
      expect(repo.reads[note.id], 2);
    },
  );

  test('a load after a save cannot join an older read', () async {
    final repo = _Repository();
    addTearDown(repo.dispose);
    final note = await repo.createNote();
    final gate = repo.gates[note.id] = Completer<NoteContent>();
    final old = repo.loadNote(note.id);
    await Future<void>.delayed(Duration.zero);
    repo.gates.remove(note.id);
    final changed = NoteContent.blank(
      const PageSetup(background: PageBackground.grid),
    );
    final saving = repo.saveNote(note.id, changed);
    final fresh = repo.loadNote(note.id);
    expect(fresh, isNot(same(old)));
    gate.complete(NoteContent.blank());
    await saving;
    expect((await fresh).pages.first.setup.background, PageBackground.grid);
    await old;
  });

  testWidgets(
    'cold shell is immediate; late completion cannot select its tab',
    (tester) async {
      final repo = _Repository();
      final tabs = OpenNotes();
      addTearDown(repo.dispose);
      addTearDown(tabs.dispose);
      final a = await repo.createNote(title: 'A');
      final b = await repo.createNote(title: 'B');
      final gate = repo.gates[a.id] = Completer<NoteContent>();
      tabs.open(a);
      await tester.pumpWidget(_host(repo, tabs));
      expect(find.byKey(const ValueKey('note-opening-page')), findsOneWidget);
      tabs.open(a);
      await tester.pump();
      expect(repo.reads[a.id], 1);
      tabs.open(b);
      await _settle(tester);
      expect(_shown(tester).noteId, b.id);
      gate.complete(NoteContent.blank());
      await _settle(tester);
      expect(_shown(tester).noteId, b.id);
      final document = tester
          .widgetList<EditorScreen>(
            find.byType(EditorScreen, skipOffstage: false),
          )
          .firstWhere((editor) => editor.noteId == a.id)
          .document;
      final previous = debugOnRebuildDirtyWidget;
      var editorBuilds = 0;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        if (element.widget is EditorScreen) editorBuilds++;
        previous?.call(element, builtOnce);
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previous);
      tabs.open(a);
      await tester.pump();
      expect(find.byKey(const ValueKey('note-opening-page')), findsNothing);
      expect(repo.reads[a.id], 1);
      await _settle(tester);
      expect(_shown(tester).document, same(document));
      expect(editorBuilds, 0);
      debugOnRebuildDirtyWidget = previous;
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'LRU keeps three editors, restores page and content after eviction',
    (tester) async {
      final repo = _Repository();
      final tabs = OpenNotes();
      addTearDown(repo.dispose);
      addTearDown(tabs.dispose);
      final notes = <NoteEntry>[];
      for (var i = 0; i < 5; i++) {
        notes.add(await repo.createNote(title: 'Note $i'));
      }
      await repo.saveNote(
        notes.first.id,
        NoteContent([
          ...NoteContent.blank().pages,
          ...NoteContent.blank().pages,
        ]),
      );
      tabs.open(notes.first);
      await tester.pumpWidget(_host(repo, tabs));
      await _settle(tester);
      _shown(tester).document!.goTo(1);
      for (final note in notes.skip(1)) {
        tabs.open(note);
        await _settle(tester);
      }
      expect(find.byType(EditorScreen, skipOffstage: false), findsNWidgets(3));
      tabs.open(notes.first);
      await _settle(tester);
      expect(_shown(tester).document!.currentIndex, 1);
      expect(_shown(tester).document!.pageCount, 2);
      expect(repo.reads[notes.first.id], 2);
      expect(find.byType(EditorScreen, skipOffstage: false), findsNWidgets(3));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'low memory puts away the editors out of view and reopens them intact',
    (tester) async {
      final repo = _Repository();
      final tabs = OpenNotes();
      addTearDown(repo.dispose);
      addTearDown(tabs.dispose);
      final notes = <NoteEntry>[
        for (var i = 0; i < 3; i++) await repo.createNote(title: 'Note $i'),
      ];
      for (final note in notes) {
        tabs.open(note);
        if (note == notes.first) {
          await tester.pumpWidget(_host(repo, tabs));
        }
        await _settle(tester);
      }
      expect(find.byType(EditorScreen, skipOffstage: false), findsNWidgets(3));

      tester.binding.handleMemoryPressure();
      await _settle(tester);
      // Only the note in view keeps its editor.
      expect(find.byType(EditorScreen, skipOffstage: false), findsOneWidget);
      expect(_shown(tester).noteId, notes.last.id);

      tabs.open(notes.first);
      await _settle(tester);
      expect(_shown(tester).noteId, notes.first.id);
      expect(repo.reads[notes.first.id], 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('failed saves pin a tab and prevent close until retry succeeds', (
    tester,
  ) async {
    final repo = _Repository();
    final tabs = OpenNotes();
    addTearDown(repo.dispose);
    addTearDown(tabs.dispose);
    final a = await repo.createNote(title: 'A');
    final b = await repo.createNote(title: 'B');
    tabs.open(a);
    await tester.pumpWidget(_host(repo, tabs, capacity: 1));
    await _settle(tester);
    final document = _shown(tester).document!;
    document.addPage();
    repo.failSaves = true;
    tabs.open(b);
    await _settle(tester);
    expect(find.byType(EditorScreen, skipOffstage: false), findsNWidgets(2));
    await tester.tap(find.byTooltip('Close A'));
    await _settle(tester);
    expect(tabs.notes.any((note) => note.id == a.id), isTrue);
    repo.failSaves = false;
    await tester.tap(find.byTooltip('Close A'));
    await _settle(tester);
    expect(tabs.notes.any((note) => note.id == a.id), isFalse);
    expect((await repo.loadNote(a.id)).pages.length, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('closing a loading tab ignores its eventual completion', (
    tester,
  ) async {
    final repo = _Repository();
    final tabs = OpenNotes();
    addTearDown(repo.dispose);
    addTearDown(tabs.dispose);
    final a = await repo.createNote();
    final b = await repo.createNote();
    final gate = repo.gates[a.id] = Completer<NoteContent>();
    tabs.open(a);
    await tester.pumpWidget(_host(repo, tabs));
    tabs.open(b);
    tabs.close(a.id);
    await _settle(tester);
    gate.complete(NoteContent.blank());
    await _settle(tester);
    expect(_shown(tester).noteId, b.id);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

/// Lets a note opened slide in, and its editor, built after, settle.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(AppMotion.smooth.duration);
  await tester.pumpAndSettle();
}

EditorScreen _shown(WidgetTester tester) =>
    tester.widget<EditorScreen>(find.byType(EditorScreen));

Widget _host(_Repository repo, OpenNotes tabs, {int capacity = 3}) =>
    GreatnoteApp(
      home: NoteTabsPage(
        notes: tabs,
        warmCapacity: capacity,
        builder: (note, bar, back, rename) => NoteEditorPage(
          repository: repo,
          note: note,
          tabsBuilder: bar,
          onBack: back,
          onRenamed: rename,
        ),
      ),
    );
