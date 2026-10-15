import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/library/file_note_repository.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';

Stroke _stroke(InkColor ink, double width, List<InkVector> points) {
  return Stroke.fromPoints(
    style: StrokeStyle(ink: ink, width: width),
    points: points,
  );
}

NoteContent _sample() {
  return NoteContent(<StoredPage>[
    StoredPage(
      setup: const PageSetup(
        size: PageSize.a4Portrait,
        background: PageBackground.lined,
      ),
      strokes: <Stroke>[
        _stroke(InkPalette.ink, 3, const <InkVector>[
          InkVector(1.25, 2.5),
          InkVector(100.123456789, 0.1),
        ]),
        _stroke(InkPalette.colors[2], 12, const <InkVector>[InkVector(40, 40)]),
      ],
    ),
    StoredPage(
      setup: const PageSetup(
        size: PageSize.infinite,
        background: PageBackground.dotted,
      ),
      extent: const Size(2400.5, 1800),
      strokes: <Stroke>[
        _stroke(InkPalette.colors.last, 1.5, const <InkVector>[
          InkVector(2000, 1700),
          InkVector(2100, 1750),
        ]),
      ],
    ),
    for (final PageSize size in PageSize.values)
      for (final PageBackground background in PageBackground.values)
        StoredPage(
          setup: PageSetup(size: size, background: background),
          strokes: const <Stroke>[],
        ),
  ]);
}

void _expectSameContent(NoteContent actual, NoteContent expected) {
  expect(actual.pages, hasLength(expected.pages.length));
  for (int p = 0; p < expected.pages.length; p++) {
    final StoredPage a = actual.pages[p];
    final StoredPage e = expected.pages[p];
    expect(a.setup, e.setup);
    expect(a.extent, e.extent);
    expect(a.strokes, hasLength(e.strokes.length));
    for (int s = 0; s < e.strokes.length; s++) {
      expect(a.strokes[s].style.ink, same(e.strokes[s].style.ink));
      expect(a.strokes[s].style.width, e.strokes[s].style.width);
      expect(a.strokes[s].points, e.strokes[s].points);
      expect(a.strokes[s].source, StrokeSource.derived);
    }
  }
}

void main() {
  group('NoteContent', () {
    test('round-trips through JSON text exactly', () {
      final NoteContent content = _sample();
      final NoteContent back = NoteContent.fromJson(
        jsonDecode(jsonEncode(content.toJson())) as Map<String, Object?>,
      );
      _expectSameContent(back, content);
    });

    test('refuses a newer schema and ignores unknown fields', () {
      final Map<String, Object?> json = _sample().toJson();
      expect(
        () => NoteContent.fromJson(<String, Object?>{...json, 'schema': 99}),
        throwsA(isA<StorageFormatException>()),
      );
      final Map<String, Object?> extra = <String, Object?>{
        ...json,
        'futureField': <String, Object?>{'a': 1},
      };
      _expectSameContent(NoteContent.fromJson(extra), _sample());
    });

    test('becomes a document and back', () {
      final NoteContent content = _sample();
      final document = content.toDocument();
      addTearDown(document.dispose);
      expect(document.pageCount, content.pages.length);
      _expectSameContent(NoteContent.fromDocument(document), content);
    });
  });

  for (final (String name, Future<IndexedNoteRepository> Function() open)
      in <(String, Future<IndexedNoteRepository> Function())>[
        ('in memory', () async => InMemoryNoteRepository()),
        (
          'on disk',
          () async {
            final Directory directory = await Directory.systemTemp.createTemp(
              'greatnote_test',
            );
            addTearDown(() => directory.delete(recursive: true));
            return FileNoteRepository.open(directory);
          },
        ),
      ]) {
    group('repository $name', () {
      late IndexedNoteRepository repository;

      setUp(() async {
        repository = await open();
        addTearDown(repository.dispose);
      });

      test('creates, lists, and renames notes and folders', () async {
        final Folder physics = await repository.createFolder('  Physics  ');
        expect(physics.name, 'Physics');
        final NoteEntry top = await repository.createNote(title: 'Plan');
        final NoteEntry inner = await repository.createNote(
          title: 'Lab',
          folderId: physics.id,
        );
        final FolderListing root = await repository.list(null);
        expect(root.folders.map((Folder f) => f.id), <String>[physics.id]);
        expect(root.notes.map((NoteEntry n) => n.id), <String>[top.id]);
        expect((await repository.list(physics.id)).notes.single.id, inner.id);

        await repository.renameNote(inner.id, 'Lab 2');
        await repository.renameFolder(physics.id, 'Science');
        expect((await repository.list(physics.id)).notes.single.title, 'Lab 2');
        expect((await repository.pathTo(physics.id)).single.name, 'Science');
        expect(
          () => repository.renameNote(inner.id, '   '),
          throwsA(isA<LibraryException>()),
        );
      });

      test('moves notes and folders, never into themselves', () async {
        final Folder a = await repository.createFolder('A');
        final Folder b = await repository.createFolder('B', parentId: a.id);
        final Folder c = await repository.createFolder('C', parentId: b.id);
        final NoteEntry note = await repository.createNote(title: 'N');

        await repository.moveNote(note.id, c.id);
        expect((await repository.list(c.id)).notes.single.id, note.id);
        expect(
          (await repository.pathTo(c.id)).map((Folder f) => f.name),
          <String>['A', 'B', 'C'],
        );
        await expectLater(
          repository.moveFolder(a.id, c.id),
          throwsA(isA<LibraryException>()),
        );
        await expectLater(
          repository.moveFolder(a.id, a.id),
          throwsA(isA<LibraryException>()),
        );
        await repository.moveFolder(c.id, null);
        expect(
          (await repository.list(null)).folders.map((Folder f) => f.name),
          containsAll(<String>['A', 'C']),
        );
      });

      test('duplicates a note with its content', () async {
        final NoteEntry note = await repository.createNote(title: 'Orig');
        await repository.saveNote(note.id, _sample());
        final NoteEntry copy = await repository.duplicateNote(note.id);
        expect(copy.id, isNot(note.id));
        expect(copy.title, 'Orig copy');
        _expectSameContent(await repository.loadNote(copy.id), _sample());
      });

      test('stores, duplicates, and deletes note assets', () async {
        final Folder folder = await repository.createFolder('Assets');
        final NoteEntry note = await repository.createNote(
          title: 'Illustrated',
          folderId: folder.id,
        );
        final String assetId = await repository.storeAsset(
          note.id,
          Uint8List.fromList(<int>[2, 4, 6, 8]),
          kind: NoteAssetKind.image,
          extension: 'png',
          fileName: 'figure.png',
        );
        expect((await repository.readAsset(note.id, assetId)).bytes, <int>[
          2,
          4,
          6,
          8,
        ]);
        final NoteEntry copy = await repository.duplicateNote(note.id);
        expect((await repository.readAsset(copy.id, assetId)).bytes, <int>[
          2,
          4,
          6,
          8,
        ]);
        await repository.deleteNote(copy.id);
        await expectLater(
          repository.readAsset(copy.id, assetId),
          throwsA(anything),
        );
        await repository.deleteFolder(folder.id);
        await expectLater(
          repository.readAsset(note.id, assetId),
          throwsA(anything),
        );
      });

      test('deleting a folder removes everything below it', () async {
        final Folder a = await repository.createFolder('A');
        final Folder b = await repository.createFolder('B', parentId: a.id);
        await repository.createNote(title: 'in a', folderId: a.id);
        final NoteEntry deep = await repository.createNote(
          title: 'in b',
          folderId: b.id,
        );
        final NoteEntry kept = await repository.createNote(title: 'kept');
        final FolderTotals totals = await repository.totals(a.id);
        expect(totals.folders, 1);
        expect(totals.notes, 2);

        await repository.deleteFolder(a.id);
        expect(await repository.allFolders(), isEmpty);
        expect(
          (await repository.list(null)).notes.map((NoteEntry n) => n.id),
          <String>[kept.id],
        );
        await expectLater(
          repository.loadNote(deep.id),
          throwsA(isA<LibraryException>()),
        );
      });

      test('searches titles across folders, ignoring case', () async {
        final Folder f = await repository.createFolder('Maths');
        await repository.createNote(title: 'Calculus notes', folderId: f.id);
        await repository.createNote(title: 'calc homework');
        await repository.createNote(title: 'History');
        final FolderListing found = await repository.search('CALC');
        expect(found.notes, hasLength(2));
        expect((await repository.search('math')).folders.single.id, f.id);
        expect((await repository.search('  ')).isEmpty, isTrue);
      });

      test('saving updates the modified time and page count', () async {
        final NoteEntry note = await repository.createNote();
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await repository.saveNote(note.id, _sample());
        final NoteEntry saved = (await repository.list(null)).notes.single;
        expect(saved.modified.isAfter(note.modified), isTrue);
        expect(saved.pageCount, _sample().pages.length);
        _expectSameContent(await repository.loadNote(note.id), _sample());
      });

      test('notifies listeners after each change', () async {
        int heard = 0;
        repository.addListener(() => heard++);
        final NoteEntry note = await repository.createNote();
        await repository.renameNote(note.id, 'x');
        await repository.deleteNote(note.id);
        expect(heard, 3);
      });
    });
  }

  group('file repository', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('greatnote_test');
      addTearDown(() => directory.delete(recursive: true));
    });

    test('reopens from disk with identical content', () async {
      final FileNoteRepository first = await FileNoteRepository.open(directory);
      final Folder folder = await first.createFolder('Kept');
      final NoteEntry note = await first.createNote(
        title: 'Saved',
        folderId: folder.id,
      );
      await first.saveNote(note.id, _sample());
      first.dispose();

      final FileNoteRepository second = await FileNoteRepository.open(
        directory,
      );
      addTearDown(second.dispose);
      final FolderListing listing = await second.list(folder.id);
      expect(listing.notes.single.title, 'Saved');
      _expectSameContent(await second.loadNote(note.id), _sample());
      // Every write went through a temporary file that is gone now.
      final List<String> leftovers = <String>[
        await for (final FileSystemEntity entity in directory.list(
          recursive: true,
        ))
          if (entity.path.endsWith('.tmp')) entity.path,
      ];
      expect(leftovers, isEmpty);
    });

    test('a corrupt note fails alone', () async {
      final FileNoteRepository repository = await FileNoteRepository.open(
        directory,
      );
      addTearDown(repository.dispose);
      final NoteEntry broken = await repository.createNote(title: 'Broken');
      final NoteEntry fine = await repository.createNote(title: 'Fine');
      await File(
        '${directory.path}/notes/${broken.id}.json',
      ).writeAsString('{not json');

      await expectLater(
        repository.loadNote(broken.id),
        throwsA(isA<StorageFormatException>()),
      );
      expect((await repository.loadNote(fine.id)).pages, hasLength(1));
      expect((await repository.list(null)).notes, hasLength(2));
    });

    test('refuses a library written by a newer version', () async {
      await File(
        '${directory.path}/library.json',
      ).writeAsString('{"schema": 42, "folders": [], "notes": []}');
      await expectLater(
        FileNoteRepository.open(directory),
        throwsA(isA<StorageFormatException>()),
      );
    });
  });
}
