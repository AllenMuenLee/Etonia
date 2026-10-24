import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/widgets/editor_app_bar.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/note_tabs_page.dart';
import 'package:greatnote/features/library/open_notes.dart';

/// Counts how often its state is made, to tell an editor that moved from
/// one that was built again.
class _Editor extends StatefulWidget {
  const _Editor({super.key, required this.note, required this.built});

  final NoteEntry note;
  final List<String> built;

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  @override
  void initState() {
    super.initState();
    widget.built.add(widget.note.id);
  }

  @override
  Widget build(BuildContext context) {
    return Center(child: Text('Editor for ${widget.note.title}'));
  }
}

void main() {
  NoteEntry makeNote(String id, String title) {
    return NoteEntry(
      id: id,
      title: title,
      folderId: 'root',
      created: DateTime(2026, 10, 20),
      modified: DateTime(2026, 10, 20),
      pageCount: 1,
    );
  }

  final NoteEntry a = makeNote('a', 'Note A');
  final NoteEntry b = makeNote('b', 'Note B');
  final NoteEntry c = makeNote('c', 'Note C');

  Widget host(OpenNotes notes, [List<String>? built]) {
    return GreatnoteApp(
      home: Scaffold(
        body: NoteTabsPage(
          notes: notes,
          builder: (note, tabs, onBack, onRenamed) {
            tabs(() {});
            return _Editor(
              key: ValueKey<String>('editor-${note.id}'),
              note: note,
              built: built ?? <String>[],
            );
          },
        ),
      ),
    );
  }

  Future<OpenNotes> pumpTabs(
    WidgetTester tester,
    List<NoteEntry> open, {
    List<String>? built,
  }) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final OpenNotes notes = OpenNotes();
    addTearDown(notes.dispose);
    open.forEach(notes.open);
    await tester.pumpWidget(host(notes, built));
    await tester.pumpAndSettle();
    return notes;
  }

  /// Holds [tab] and drags it to [to], releasing it there.
  Future<void> dragTab(WidgetTester tester, Finder tab, Offset to) async {
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(tab),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.moveTo(to);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  Finder tabOf(NoteEntry note) =>
      find.byKey(ValueKey<String>('note-tab-${note.id}'));

  testWidgets('one window has one bar, and no split button', (tester) async {
    await pumpTabs(tester, <NoteEntry>[a, b]);

    expect(find.byType(EditorAppBar), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('split-screen-button')),
      findsNothing,
    );
    expect(find.byTooltip('Settings'), findsOneWidget);
    expect(find.text('Editor for Note B'), findsOneWidget);
  });

  testWidgets('dragging a tab to the right shows it beside the other', (
    tester,
  ) async {
    final OpenNotes notes = await pumpTabs(tester, <NoteEntry>[a, b]);
    // Opening b made it the shown one; a is the other.
    await dragTab(tester, tabOf(a), const Offset(1100, 400));

    expect(notes.splitCount, 2);
    expect(notes.paneNoteIds, <String?>['b', 'a']);
    expect(notes.focusedPane, 1);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey<String>('editor-a'))).dx,
      greaterThan(
        tester.getTopLeft(find.byKey(const ValueKey<String>('editor-b'))).dx,
      ),
    );
  });

  testWidgets('dragging a tab to the left puts it first', (tester) async {
    final OpenNotes notes = await pumpTabs(tester, <NoteEntry>[a, b]);
    await dragTab(tester, tabOf(a), const Offset(100, 400));

    expect(notes.paneNoteIds, <String?>['a', 'b']);
    expect(notes.focusedPane, 0);
  });

  testWidgets('each half of a split has a bar of its own, floating with it', (
    tester,
  ) async {
    await pumpTabs(tester, <NoteEntry>[a, b]);
    await dragTab(tester, tabOf(a), const Offset(1100, 400));

    expect(find.byType(EditorAppBar), findsNWidgets(2));
    expect(find.byTooltip('Settings'), findsNWidgets(2));
    final Finder left = find.byKey(const ValueKey<String>('note-strip-0'));
    final Finder right = find.byKey(const ValueKey<String>('note-strip-1'));
    expect(tester.getRect(left).right, lessThanOrEqualTo(600));
    expect(tester.getRect(right).left, greaterThanOrEqualTo(600));
    // The bar is inside the half that lifts, not above both.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('floating-pane-b')),
        matching: left,
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('floating-pane-a')),
        matching: right,
      ),
      findsOneWidget,
    );
    final Rect bar = tester.getRect(find.byType(EditorAppBar).first);
    expect(bar.top, 0);
    expect(bar.width, lessThan(1200));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey<String>('editor-b'))).dy,
      bar.bottom,
    );
  });

  testWidgets('each pane has its own tabs, and the other tabs stay apart', (
    tester,
  ) async {
    await pumpTabs(tester, <NoteEntry>[a, b, c]);
    await dragTab(tester, tabOf(a), const Offset(1100, 400));
    // c was shown; a was dropped alone on the right, b and c stayed left.
    final Finder left = find.byKey(const ValueKey<String>('note-strip-0'));
    final Finder right = find.byKey(const ValueKey<String>('note-strip-1'));

    expect(
      find.descendant(
        of: left,
        matching: find.byType(LongPressDraggable<String>),
      ),
      findsNWidgets(2),
    );
    expect(find.descendant(of: left, matching: tabOf(b)), findsOneWidget);
    expect(find.descendant(of: left, matching: tabOf(c)), findsOneWidget);
    expect(find.descendant(of: right, matching: tabOf(a)), findsOneWidget);
    expect(find.descendant(of: right, matching: tabOf(b)), findsNothing);
    expect(find.descendant(of: right, matching: tabOf(c)), findsNothing);
  });

  testWidgets(
    'a tab moves from one pane to the other, and an empty pane goes',
    (tester) async {
      final OpenNotes notes = await pumpTabs(tester, <NoteEntry>[a, b, c]);
      await dragTab(tester, tabOf(a), const Offset(1100, 400));
      expect(notes.tabsOf(0).map((NoteEntry n) => n.id), <String>['b', 'c']);

      await dragTab(tester, tabOf(b), const Offset(1100, 400));
      expect(notes.tabsOf(1).map((NoteEntry n) => n.id), <String>['a', 'b']);
      expect(notes.paneNoteIds, <String?>['c', 'b']);

      await dragTab(tester, tabOf(c), const Offset(1100, 400));
      expect(notes.isSplit, isFalse);
      expect(notes.active?.id, 'c');
    },
  );

  testWidgets('splitting moves the editors without building them again', (
    tester,
  ) async {
    final List<String> built = <String>[];
    await pumpTabs(tester, <NoteEntry>[a, b], built: built);
    // Only the shown note is up; the other is cold until it is shown.
    expect(built, <String>['b']);

    await dragTab(tester, tabOf(a), const Offset(1100, 400));

    expect(built, <String>['b', 'a']);
    expect(find.text('Editor for Note A'), findsOneWidget);
    expect(find.text('Editor for Note B'), findsOneWidget);
  });

  testWidgets('dropping the shown note on a side pairs it with another', (
    tester,
  ) async {
    final OpenNotes notes = await pumpTabs(tester, <NoteEntry>[a, b]);
    await dragTab(tester, tabOf(b), const Offset(1100, 400));

    expect(notes.paneNoteIds, <String?>['a', 'b']);
  });

  testWidgets('letting a tab go away from the sides changes nothing', (
    tester,
  ) async {
    final OpenNotes notes = await pumpTabs(tester, <NoteEntry>[a, b]);
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(tabOf(a)),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.moveTo(const Offset(600, 5));
    await tester.pump();
    // The sides are offered while the tab is held.
    expect(find.text('Open on the right'), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(notes.isSplit, isFalse);
    expect(find.text('Open on the right'), findsNothing);
  });

  testWidgets('pulling the handle to an edge puts that pane away', (
    tester,
  ) async {
    final OpenNotes notes = await pumpTabs(tester, <NoteEntry>[a, b]);
    notes.splitWith('a', right: true);
    await tester.pumpAndSettle();
    expect(notes.isSplit, isTrue);

    await tester.drag(
      find.byKey(const ValueKey<String>('split-handle')),
      const Offset(-560, 0),
    );
    await tester.pumpAndSettle();

    expect(notes.splitCount, 1);
    expect(notes.active?.id, 'a');
  });

  testWidgets('pressing a pane focuses it', (tester) async {
    final OpenNotes notes = await pumpTabs(tester, <NoteEntry>[a, b]);
    notes.splitWith('a', right: true);
    await tester.pumpAndSettle();
    expect(notes.focusedPane, 1);

    await tester.tapAt(const Offset(100, 400));
    await tester.pumpAndSettle();

    expect(notes.focusedPane, 0);
    expect(notes.active?.id, 'b');
  });

  group('OpenNotes.splitWith', () {
    test(
      'moving the only note of a pane to the other side leaves one pane',
      () {
        final OpenNotes notes = OpenNotes()
          ..open(a)
          ..open(b)
          ..splitWith('a', right: true);
        addTearDown(notes.dispose);
        expect(notes.paneNoteIds, <String?>['b', 'a']);

        notes.splitWith('a', right: false);

        // b is left alone on the right, so the window is a single pane again.
        expect(notes.isSplit, isFalse);
        expect(notes.active?.id, 'a');
        expect(notes.paneNoteIds, <String?>['a']);
      },
    );

    test('replaces the note on the side it is dropped on', () {
      final OpenNotes notes = OpenNotes()
        ..open(a)
        ..open(b)
        ..open(c)
        ..splitWith('a', right: true);
      addTearDown(notes.dispose);
      expect(notes.paneNoteIds, <String?>['c', 'a']);

      notes.splitWith('b', right: true);

      expect(notes.paneNoteIds, <String?>['c', 'b']);
      expect(notes.splitCount, 2);
    });

    test('has nothing to pair a lone note with', () {
      final OpenNotes notes = OpenNotes()..open(a);
      addTearDown(notes.dispose);

      notes.splitWith('a', right: true);

      expect(notes.isSplit, isFalse);
    });

    test('never shows more than two panes', () {
      final OpenNotes notes = OpenNotes()
        ..open(a)
        ..open(b)
        ..open(c)
        ..setSplitCount(4);
      addTearDown(notes.dispose);

      expect(notes.splitCount, OpenNotes.maxPanes);
    });
  });
}
