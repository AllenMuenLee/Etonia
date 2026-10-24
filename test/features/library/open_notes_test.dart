import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/open_notes.dart';

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

  group('OpenNotes basic and split screen tests', () {
    test('initial state has 0 notes, splitCount = 1, focusedPane = 0', () {
      final OpenNotes notes = OpenNotes();
      expect(notes.isEmpty, isTrue);
      expect(notes.notes, isEmpty);
      expect(notes.splitCount, 1);
      expect(notes.isSplit, isFalse);
      expect(notes.focusedPane, 0);
      expect(notes.active, isNull);
      expect(notes.paneNotes, [isNull]);
      expect(notes.visibleNoteIds, isEmpty);
    });

    test('opening single note assigns to pane 0', () {
      final OpenNotes notes = OpenNotes();
      final NoteEntry a = makeNote('a', 'Note A');
      notes.open(a);

      expect(notes.notes.length, 1);
      expect(notes.active, a);
      expect(notes.activeIndex, 0);
      expect(notes.splitCount, 1);
      expect(notes.paneNotes, [a]);
      expect(notes.visibleNoteIds, ['a']);
      expect(notes.isNoteInPane('a'), isTrue);
      expect(notes.paneOf('a'), 0);
    });

    test('split screen for up to 4 tabs', () {
      final OpenNotes notes = OpenNotes();
      final NoteEntry a = makeNote('a', 'Note A');
      final NoteEntry b = makeNote('b', 'Note B');
      final NoteEntry c = makeNote('c', 'Note C');
      final NoteEntry d = makeNote('d', 'Note D');
      final NoteEntry e = makeNote('e', 'Note E');

      notes.open(a);
      notes.open(b);
      notes.open(c);
      notes.open(d);
      notes.open(e);

      expect(notes.notes.length, 5);
      expect(notes.splitCount, 1);

      // Split into 2 panes
      notes.setSplitCount(2);
      expect(notes.splitCount, 2);
      expect(notes.isSplit, isTrue);
      expect(notes.paneNotes.length, 2);
      expect(notes.visibleNoteIds.length, 2);
      expect(notes.visibleNoteIds.toSet().length, 2);

      // Clamping: max 2 panes, min 1 pane
      notes.setSplitCount(10);
      expect(notes.splitCount, 2);

      notes.setSplitCount(0);
      expect(notes.splitCount, 1);
      expect(notes.isSplit, isFalse);
    });

    test('switching focus and active tab in split view', () {
      final OpenNotes notes = OpenNotes();
      final NoteEntry a = makeNote('a', 'Note A');
      final NoteEntry b = makeNote('b', 'Note B');
      final NoteEntry c = makeNote('c', 'Note C');

      notes.open(a);
      notes.open(b);
      notes.open(c);

      notes.setSplitCount(2);
      expect(notes.focusedPane, 0);

      // Focus pane 1
      notes.focusPane(1);
      expect(notes.focusedPane, 1);
      expect(notes.active?.id, notes.paneNotes[1]?.id);

      // Tapping note already in pane 0 switches focus to pane 0
      final int pane0NoteIndex = notes.notes.indexWhere(
        (n) => n.id == notes.paneNotes[0]!.id,
      );
      notes.activate(pane0NoteIndex);
      expect(notes.focusedPane, 0);

      // Tapping note C (not visible in any pane) replaces note in focused pane 0
      final int noteCIndex = notes.notes.indexWhere((n) => n.id == 'c');
      notes.activate(noteCIndex);
      expect(notes.focusedPane, 0);
      expect(notes.paneNotes[0]?.id, 'c');
      expect(notes.active?.id, 'c');
    });

    test('closing a pane shifts remaining panes and decreases splitCount', () {
      final OpenNotes notes = OpenNotes();
      final NoteEntry a = makeNote('a', 'Note A');
      final NoteEntry b = makeNote('b', 'Note B');
      final NoteEntry c = makeNote('c', 'Note C');

      notes.open(a);
      notes.open(b);
      notes.open(c);

      notes.setSplitCount(2);
      expect(notes.splitCount, 2);

      final String firstPaneNoteId = notes.paneNotes[0]!.id;
      final String secondPaneNoteId = notes.paneNotes[1]!.id;

      // Close pane 0
      notes.closePane(0);
      expect(notes.splitCount, 1);
      expect(notes.paneNotes[0]?.id, secondPaneNoteId);
      expect(notes.notes.any((n) => n.id == firstPaneNoteId), isTrue);

      // Notes are still open in tab strip
      expect(notes.notes.any((n) => n.id == secondPaneNoteId), isTrue);
    });

    test(
      'a lone note cannot be split, and a note opened later joins the focused pane',
      () {
        final OpenNotes notes = OpenNotes();
        final NoteEntry a = makeNote('a', 'Note A');
        notes.open(a);

        notes.setSplitCount(2);
        expect(notes.splitCount, 1);

        final NoteEntry b = makeNote('b', 'Note B');
        notes.open(b);
        notes.setSplitCount(2);
        expect(notes.paneNotes, <NoteEntry?>[b, a]);

        final NoteEntry c = makeNote('c', 'Note C');
        notes.open(c);
        expect(notes.tabsOf(0), <NoteEntry>[b, c]);
        expect(notes.tabsOf(1), <NoteEntry>[a]);
      },
    );

    test('closing a note updates split panes correctly', () {
      final OpenNotes notes = OpenNotes();
      final NoteEntry a = makeNote('a', 'Note A');
      final NoteEntry b = makeNote('b', 'Note B');
      final NoteEntry c = makeNote('c', 'Note C');

      notes.open(a);
      notes.open(b);
      notes.open(c);
      notes.setSplitCount(2);

      final String closedId = notes.paneNotes[0]!.id;
      notes.close(closedId);

      expect(notes.notes.any((n) => n.id == closedId), isFalse);
      expect(notes.visibleNoteIds, isNot(contains(closedId)));
      expect(notes.splitCount, 2);
    });
  });
}
