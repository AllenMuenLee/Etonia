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
        // Drawn with a tapered tip and pressure: a width factor per point.
        Stroke.fromPoints(
          style: const StrokeStyle(ink: InkPalette.ink, width: 4),
          points: const <InkVector>[
            InkVector(10, 10),
            InkVector(20, 12),
            InkVector(30, 15),
          ],
          widths: const <double>[0.25, 1.375, 0.5],
        ),
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
      expect(a.strokes[s].widths, e.strokes[s].widths);
      expect(a.strokes[s].source, StrokeSource.derived);
    }
  }
}

void main() {
  test(
    'incremental hydration preserves the same storage representation',
    () async {
      final expected = _sample();
      final json = expected.toJson();
      final actual = await NoteContent.fromJsonIncrementally(json);
      expect(actual.toJson(), NoteContent.fromJson(json).toJson());
      await expectLater(
        NoteContent.fromJsonIncrementally({'schema': storageSchema + 1}),
        throwsA(isA<StorageFormatException>()),
      );
    },
  );
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

    test('a stroke whose widths do not fit its points is drawn even', () {
      final Map<String, Object?> json = _sample().toJson();
      final List<Object?> pages = json['pages']! as List<Object?>;
      final Map<String, Object?> page = pages.first! as Map<String, Object?>;
      final List<Object?> strokes = page['strokes']! as List<Object?>;
      (strokes.last! as Map<String, Object?>)['widths'] = <double>[1, 2];
      final NoteContent back = NoteContent.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, Object?>,
      );
      expect(back.pages.first.strokes.last.widths, isNull);
      expect(back.pages.first.strokes.last.points, hasLength(3));
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

      test('folders keep their color, and can be recolored', () async {
        final Folder plain = await repository.createFolder('Plain');
        expect(plain.color, FolderColor.accent);
        final Folder green = await repository.createFolder(
          'Green',
          parentId: plain.id,
          color: FolderColor.green,
        );
        expect(green.color, FolderColor.green);

        await repository.recolorFolder(plain.id, FolderColor.pink);
        final Map<String, Folder> folders = <String, Folder>{
          for (final Folder f in await repository.allFolders()) f.id: f,
        };
        expect(folders[plain.id]!.color, FolderColor.pink);
        expect(folders[green.id]!.color, FolderColor.green);
        expect(folders[green.id]!.parentId, plain.id);
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
        // Deleted, the note keeps its assets until it is deleted for good.
        await repository.deleteNote(copy.id);
        expect((await repository.readAsset(copy.id, assetId)).bytes, <int>[
          2,
          4,
          6,
          8,
        ]);
        await repository.deleteForever(copy.id);
        await expectLater(
          repository.readAsset(copy.id, assetId),
          throwsA(anything),
        );
        await repository.deleteFolder(folder.id);
        await repository.emptyTrash();
        await expectLater(
          repository.readAsset(note.id, assetId),
          throwsA(anything),
        );
      });

      test('deleted notes wait in Recently Deleted until restored', () async {
        final Folder folder = await repository.createFolder('Kept');
        final NoteEntry note = await repository.createNote(
          title: 'Draft',
          folderId: folder.id,
        );
        await repository.saveNote(note.id, _sample());
        await repository.deleteNote(note.id);

        expect((await repository.list(folder.id)).notes, isEmpty);
        expect((await repository.search('draft')).notes, isEmpty);
        expect(await repository.itemCounts(), isNot(contains(folder.id)));
        final NoteEntry trashed = (await repository.trash()).single;
        expect(trashed.id, note.id);
        expect(trashed.deleted, isNotNull);
        // Its pages are still there.
        expect(
          (await repository.loadNote(note.id)).toJson(),
          _sample().toJson(),
        );

        await repository.restoreNote(note.id);
        expect(await repository.trash(), isEmpty);
        final NoteEntry back = (await repository.list(folder.id)).notes.single;
        expect(back.id, note.id);
        expect(back.deleted, isNull);
      });

      test(
        'a note whose folder is gone is restored to the top level',
        () async {
          final Folder folder = await repository.createFolder('Gone');
          final NoteEntry note = await repository.createNote(
            title: 'Orphan',
            folderId: folder.id,
          );
          await repository.deleteFolder(folder.id);
          expect((await repository.trash()).single.id, note.id);

          await repository.restoreNote(note.id);
          expect(
            (await repository.list(null)).notes.map((NoteEntry n) => n.id),
            <String>[note.id],
          );
        },
      );

      test('deleting for good, emptying, and purging old notes', () async {
        final NoteEntry a = await repository.createNote(title: 'a');
        final NoteEntry b = await repository.createNote(title: 'b');
        final NoteEntry c = await repository.createNote(title: 'c');
        for (final NoteEntry note in <NoteEntry>[a, b, c]) {
          await repository.deleteNote(note.id);
        }
        await repository.deleteForever(a.id);
        expect(
          (await repository.trash()).map((NoteEntry n) => n.id),
          unorderedEquals(<String>[b.id, c.id]),
        );
        await expectLater(
          repository.loadNote(a.id),
          throwsA(isA<LibraryException>()),
        );
        // Nothing is old enough yet.
        await repository.purgeTrash(const Duration(days: 30));
        expect(await repository.trash(), hasLength(2));
        await repository.purgeTrash(Duration.zero);
        expect(await repository.trash(), isEmpty);
        await repository.emptyTrash();
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
        // The notes inside went to Recently Deleted, then go for good.
        expect(await repository.trash(), hasLength(2));
        await repository.emptyTrash();
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

  test('a folder stored before colors existed reads as the accent', () {
    final Folder folder = Folder.fromJson(<String, Object?>{
      'id': 'f',
      'name': 'Old',
      'parentId': null,
      'created': 0,
      'modified': 0,
    });
    expect(folder.color, FolderColor.accent);
    expect(Folder.fromJson(folder.toJson()).color, FolderColor.accent);
    expect(
      Folder.fromJson(<String, Object?>{
        ...folder.toJson(),
        'color': 'teal',
      }).color,
      FolderColor.teal,
    );
    expect(
      Folder.fromJson(<String, Object?>{
        ...folder.toJson(),
        'color': 'ultraviolet',
      }).color,
      FolderColor.accent,
    );
  });

  group('file repository', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('greatnote_test');
      addTearDown(() => directory.delete(recursive: true));
    });

    test('reopens from disk with identical content', () async {
      final FileNoteRepository first = await FileNoteRepository.open(directory);
      final Folder folder = await first.createFolder(
        'Kept',
        color: FolderColor.orange,
      );
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
      expect((await second.allFolders()).single.color, FolderColor.orange);
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

    test('Recently Deleted survives reopening, pages and all', () async {
      final FileNoteRepository first = await FileNoteRepository.open(directory);
      final NoteEntry note = await first.createNote(title: 'Binned');
      await first.saveNote(note.id, _sample());
      await first.deleteNote(note.id);
      first.dispose();

      final FileNoteRepository second = await FileNoteRepository.open(
        directory,
      );
      addTearDown(second.dispose);
      expect((await second.list(null)).notes, isEmpty);
      final NoteEntry trashed = (await second.trash()).single;
      expect(trashed.title, 'Binned');
      expect(trashed.deleted, isNotNull);
      await second.restoreNote(note.id);
      _expectSameContent(await second.loadNote(note.id), _sample());
    });

    test('overlapping large and small writes land in call order', () async {
      final FileNoteRepository repository = await FileNoteRepository.open(
        directory,
      );
      addTearDown(repository.dispose);
      final NoteEntry note = await repository.createNote(title: 'Busy');
      // Large enough to be encoded on a background isolate.
      final NoteContent large = NoteContent(<StoredPage>[
        StoredPage(
          setup: const PageSetup(
            size: PageSize.a4Portrait,
            background: PageBackground.blank,
          ),
          strokes: <Stroke>[
            for (int i = 0; i < 20000; i++)
              _stroke(InkPalette.ink, 2, <InkVector>[
                InkVector(i % 500, i / 40),
                InkVector(i % 500 + 3, i / 40 + 1),
              ]),
          ],
        ),
      ]);
      final NoteContent small = _sample();

      // The slow write is still encoding when the fast one is asked for;
      // the newer content must still be what ends up on disk. writeContent
      // is called directly, bypassing saveNote's own queue, on purpose.
      // ignore: invalid_use_of_protected_member
      final Future<void> first = repository.writeContent(note.id, large);
      // ignore: invalid_use_of_protected_member
      final Future<void> second = repository.writeContent(note.id, small);
      await Future.wait(<Future<void>>[first, second]);
      _expectSameContent(await repository.loadNote(note.id), small);

      await repository.saveNote(note.id, large);
      final NoteContent reread = await repository.loadNote(note.id);
      expect(reread.pages.single.strokes, hasLength(20000));
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
