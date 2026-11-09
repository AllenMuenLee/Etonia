import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/library/etonia_rest.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/library_screen.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/shared/widgets/etonia_mascot.dart';

import '../../helpers/pump_app.dart';

final DateTime _now = DateTime(2026, 10, 14, 15, 30);

/// Chooses the given indexes in turn: first a spot (0 is the library, then each
/// folder in turn), then a clip of [EtoniaRest.clips], and so on for each time
/// she is put somewhere.
class _Chooses implements math.Random {
  _Chooses(this.picks);

  final List<int> picks;
  int _next = 0;

  @override
  int nextInt(int max) => picks[math.min(_next++, picks.length - 1)] % max;

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;
}

InMemoryNoteRepository _repository() {
  int ids = 0;
  final InMemoryNoteRepository repository = InMemoryNoteRepository(
    clock: () => _now,
    newId: () => 'id${ids++}',
  );
  addTearDown(repository.dispose);
  return repository;
}

Future<void> _pumpLibrary(
  WidgetTester tester,
  NoteRepository repository, {
  required List<int> rests,
}) async {
  EtoniaRest.enabled = true;
  EtoniaRest.random = _Chooses(rests);
  addTearDown(() => EtoniaRest.random = math.Random());
  setViewportSize(tester, TestViewport.tabletLandscape.size);
  await tester.pumpWidget(
    GreatnoteApp(
      themeMode: ThemeMode.light,
      home: LibraryScreen(repository: repository, clock: () => _now),
    ),
  );
  await tester.pumpAndSettle();
}

final Finder _etonia = find.byKey(const ValueKey<String>('etonia-resting'));
final Finder _peeking = find.byKey(const ValueKey<String>('etonia-peeking'));
final Finder _items = find.byKey(const ValueKey<String>('library-items'));

void main() {
  testWidgets('rests in the bottom left corner of the screen when the items '
      'stop short of it', (WidgetTester tester) async {
    final InMemoryNoteRepository repository = _repository();
    await repository.createNote(title: 'One');
    await _pumpLibrary(tester, repository, rests: <int>[0, 0]);

    expect(_etonia, findsOneWidget);
    final Rect items = tester.getRect(_items);
    final Rect etonia = tester.getRect(_etonia);
    expect(etonia.bottom, closeTo(items.bottom, 0.5));
    // Flush in the corner: no margin to the left or the bottom edge.
    expect(etonia.left, closeTo(items.left, 0.5));
    // All of her is there, not cut off by the screen's edge.
    expect(etonia.height, 96);
  });

  testWidgets('rests at the end of the items when they run past the screen', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    for (int i = 0; i < 60; i++) {
      await repository.createNote(title: 'Note $i');
    }
    await _pumpLibrary(tester, repository, rests: <int>[0, 0]);

    // Out of sight, at the foot of the folder, until it is scrolled to.
    expect(_etonia, findsNothing);
    await tester.drag(_items, const Offset(0, -100000));
    await tester.pumpAndSettle();
    expect(_etonia, findsOneWidget);
    final Rect items = tester.getRect(_items);
    final Rect etonia = tester.getRect(_etonia);
    expect(etonia.bottom, closeTo(items.bottom, 0.5));
    expect(etonia.left, closeTo(items.left, 0.5));
  });

  testWidgets('peeks over her folder, and is inside it', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    final Folder archive = await repository.createFolder('Archive');
    await repository.createNote(title: 'Old', folderId: archive.id);
    await repository.createNote(title: 'Top');
    // The spots are the library, then Archive: she is put in Archive.
    await _pumpLibrary(tester, repository, rests: <int>[1, 0]);

    // Her head is over the folder's card, and she is not in the library.
    expect(_etonia, findsNothing);
    expect(_peeking, findsOneWidget);
    await tester.tap(
      find.descendant(of: _items, matching: find.text('Archive')),
    );
    await tester.pumpAndSettle();
    expect(_etonia, findsOneWidget);
    expect(_peeking, findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('sidebar-library')));
    await tester.pumpAndSettle();
    expect(_etonia, findsNothing);
    expect(_peeking, findsOneWidget);
  });

  testWidgets('plays the animation chosen with her folder', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    await repository.createNote(title: 'One');
    // The library, and the third of the clips she may play.
    await _pumpLibrary(tester, repository, rests: <int>[0, 2]);

    expect(tester.widget<EtoniaMascot>(_etonia).clip, EtoniaRest.clips[2]);
    expect(EtoniaRest.clips, isNot(contains(EtoniaClip.run)));
  });

  testWidgets('does not peek over folders in search results', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    await repository.createFolder('Archive');
    await _pumpLibrary(tester, repository, rests: <int>[1, 0]);
    expect(_peeking, findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Arch');
    await tester.pumpAndSettle();
    expect(_peeking, findsNothing);
    expect(_etonia, findsNothing);
  });

  testWidgets('is not in the way of an empty folder', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    await _pumpLibrary(tester, repository, rests: <int>[0, 0]);

    expect(find.text('Nothing here yet'), findsOneWidget);
    expect(_etonia, findsNothing);
  });

  testWidgets('moves to another folder each time the library is entered', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = _repository();
    final Folder archive = await repository.createFolder('Archive');
    await repository.createNote(title: 'Old', folderId: archive.id);
    await repository.createNote(title: 'Top');
    // First in the library, then, after a note is left, in Archive.
    await _pumpLibrary(tester, repository, rests: <int>[0, 0, 1, 0]);
    expect(_etonia, findsOneWidget);

    await tester.tap(find.descendant(of: _items, matching: find.text('Top')));
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsOneWidget);
    await tester.tap(find.byTooltip('Back to library'));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryScreen), findsOneWidget);

    expect(_etonia, findsNothing);
    expect(_peeking, findsOneWidget);
    await tester.tap(
      find.descendant(of: _items, matching: find.text('Archive')),
    );
    await tester.pumpAndSettle();
    expect(_etonia, findsOneWidget);
  });
}
