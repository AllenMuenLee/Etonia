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

  group('OpenNotes basic operations', () {
    test('initial state has 0 notes, active is null', () {
      final OpenNotes notes = OpenNotes();
      expect(notes.isEmpty, isTrue);
      expect(notes.notes, isEmpty);
      expect(notes.active, isNull);
      expect(notes.visibleNoteIds, isEmpty);
    });

    test('opening single note makes it active', () {
      final OpenNotes notes = OpenNotes();
      final NoteEntry a = makeNote('a', 'Note A');
      notes.open(a);

      expect(notes.notes.length, 1);
      expect(notes.active, a);
      expect(notes.activeIndex, 0);
      expect(notes.visibleNoteIds, ['a']);
    });

    test(
      'opening multiple notes adds tabs and activates newly opened note',
      () {
        final OpenNotes notes = OpenNotes();
        final NoteEntry a = makeNote('a', 'Note A');
        final NoteEntry b = makeNote('b', 'Note B');
        final NoteEntry c = makeNote('c', 'Note C');

        notes.open(a);
        notes.open(b);
        notes.open(c);

        expect(notes.notes.length, 3);
        expect(notes.active, c);
        expect(notes.activeIndex, 2);
      },
    );

    test('opening an existing note activates it without duplicating', () {
      final OpenNotes notes = OpenNotes();
      final NoteEntry a = makeNote('a', 'Note A');
      final NoteEntry b = makeNote('b', 'Note B');

      notes.open(a);
      notes.open(b);
      expect(notes.active, b);

      notes.open(a);
      expect(notes.notes.length, 2);
      expect(notes.active, a);
      expect(notes.activeIndex, 0);
    });

    test('switching active tab with activate', () {
      final OpenNotes notes = OpenNotes();
      final NoteEntry a = makeNote('a', 'Note A');
      final NoteEntry b = makeNote('b', 'Note B');
      final NoteEntry c = makeNote('c', 'Note C');

      notes.open(a);
      notes.open(b);
      notes.open(c);

      notes.activate(0);
      expect(notes.active, a);
      expect(notes.activeIndex, 0);

      notes.activate(1);
      expect(notes.active, b);
      expect(notes.activeIndex, 1);
    });

    test('closing a note updates active tab correctly', () {
      final OpenNotes notes = OpenNotes();
      final NoteEntry a = makeNote('a', 'Note A');
      final NoteEntry b = makeNote('b', 'Note B');
      final NoteEntry c = makeNote('c', 'Note C');

      notes.open(a);
      notes.open(b);
      notes.open(c);

      // Close the currently active note (c)
      notes.close('c');
      expect(notes.notes.length, 2);
      expect(notes.active, b);
      expect(notes.visibleNoteIds, ['b']);

      // Close non-active note (a)
      notes.close('a');
      expect(notes.notes.length, 1);
      expect(notes.active, b);

      // Close the remaining note
      notes.close('b');
      expect(notes.isEmpty, isTrue);
      expect(notes.active, isNull);
      expect(notes.visibleNoteIds, isEmpty);
    });

    test('update replaces matching note entry', () {
      final OpenNotes notes = OpenNotes();
      final NoteEntry a = makeNote('a', 'Note A');
      notes.open(a);

      final NoteEntry updated = makeNote('a', 'Renamed Note');
      notes.update(updated);

      expect(notes.active?.title, 'Renamed Note');
    });

    test(
      'retainWhere removes notes not matching predicate and clamps active',
      () {
        final OpenNotes notes = OpenNotes();
        final NoteEntry a = makeNote('a', 'Note A');
        final NoteEntry b = makeNote('b', 'Note B');
        final NoteEntry c = makeNote('c', 'Note C');

        notes.open(a);
        notes.open(b);
        notes.open(c);
        expect(notes.activeIndex, 2);

        notes.retainWhere((n) => n.id == 'a');
        expect(notes.notes.length, 1);
        expect(notes.active, a);
        expect(notes.activeIndex, 0);
      },
    );
  });
}
