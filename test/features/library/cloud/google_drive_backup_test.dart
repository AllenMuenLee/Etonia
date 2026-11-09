import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/document_io/document_importer.dart';
import 'package:greatnote/features/editor/document_io/document_models.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/sticky/sticky_note.dart';
import 'package:greatnote/features/library/cloud/cloud_sync_state.dart';
import 'package:greatnote/features/library/cloud/google_drive_backup_service.dart';
import 'package:greatnote/features/library/cloud/google_drive_client.dart';
import 'package:greatnote/features/library/file_note_repository.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';

import '../../../helpers/google_drive_fakes.dart';

final Uint8List _pdf = Uint8List.fromList(utf8.encode('%PDF-1.7 slides'));
final Uint8List _png = Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 1, 2]);

Stroke _stroke(double y, {bool highlighter = false}) => Stroke.fromPoints(
  style: StrokeStyle(
    ink: InkPalette.ink,
    width: highlighter ? 12 : 2,
    writing: highlighter ? WritingStyle.highlighter : WritingStyle.pen,
    opacity: highlighter ? 0.4 : 1,
  ),
  points: <InkVector>[
    InkVector(10, y),
    InkVector(60, y + 5),
    InkVector(120, y),
  ],
  widths: highlighter ? null : <double>[0.8, 1, 1.2],
);

/// Nested and colored folders, an empty folder, a two-page note with a
/// PDF page, an image, pens, a highlighter and a sticky note, and a note at
/// the top level.
Future<void> _seed(NoteRepository repository) async {
  final Folder school = await repository.createFolder(
    'School',
    color: FolderColor.red,
  );
  final Folder math = await repository.createFolder(
    'Math',
    parentId: school.id,
    color: FolderColor.green,
  );
  await repository.createFolder('Empty', parentId: math.id);
  final NoteEntry lecture = await repository.createNote(
    title: 'Lecture 1',
    folderId: math.id,
  );
  final String pdf = await repository.storeAsset(
    lecture.id,
    _pdf,
    kind: NoteAssetKind.pdf,
    extension: 'pdf',
    fileName: 'slides.pdf',
  );
  final String image = await repository.storeAsset(
    lecture.id,
    _png,
    kind: NoteAssetKind.image,
    extension: 'png',
    fileName: 'diagram.png',
  );
  await repository.saveNote(
    lecture.id,
    NoteContent(<StoredPage>[
      StoredPage(
        setup: const PageSetup(
          size: PageSize.custom,
          customSize: Size(612, 792),
        ),
        strokes: <Stroke>[_stroke(40), _stroke(80, highlighter: true)],
        pdfSource: PdfPageSource(
          assetId: pdf,
          pageIndex: 0,
          pageSize: const Size(612, 792),
        ),
        images: <NoteImageElement>[
          NoteImageElement(
            id: 'image-1',
            assetId: image,
            pixelSize: const Size(6, 4),
            center: const InkVector(300, 400),
            size: const Size(120, 80),
            rotation: 0.25,
            fileName: 'diagram.png',
          ),
        ],
      ),
      StoredPage(
        setup: const PageSetup(background: PageBackground.lined),
        strokes: <Stroke>[_stroke(200)],
        stickyNotes: <StickyNoteElement>[
          StickyNoteElement(
            id: 'sticky-1',
            center: const InkVector(200, 200),
            size: const Size(240, 180),
            rotation: 0.1,
            colorId: StickyPalette.yellow.id,
            paper: StickyPaperStyle.grid,
            strokes: <Stroke>[_stroke(20)],
          ),
        ],
      ),
    ]),
  );
  final NoteEntry groceries = await repository.createNote(title: 'Groceries');
  await repository.saveNote(
    groceries.id,
    NoteContent(<StoredPage>[
      StoredPage(setup: const PageSetup(), strokes: <Stroke>[_stroke(10)]),
    ]),
  );
}

/// Everything that should survive a round trip, without ids: each folder
/// by its path and color, and each note by its path, with its content and
/// its assets' bytes.
Future<Map<String, Object?>> _describe(NoteRepository repository) async {
  final List<Folder> folders = await repository.allFolders();
  final Map<String, Folder> byId = <String, Folder>{
    for (final Folder folder in folders) folder.id: folder,
  };
  String pathOf(String? id) {
    final List<String> names = <String>[];
    for (String? at = id; at != null; at = byId[at]!.parentId) {
      names.insert(0, byId[at]!.name);
    }
    return names.join('/');
  }

  final Map<String, Object?> notes = <String, Object?>{};
  for (final String? folder in <String?>[
    null,
    for (final Folder f in folders) f.id,
  ]) {
    for (final NoteEntry note in (await repository.list(folder)).notes) {
      final List<NoteAsset> assets = await repository.listAssets(note.id);
      final Map<String, String> hashes = <String, String>{};
      final List<Object?> assetDescriptions = <Object?>[];
      for (final NoteAsset asset in assets) {
        final Uint8List bytes = (await repository.readAsset(
          note.id,
          asset.id,
        )).bytes;
        final String hash = sha256.convert(bytes).toString();
        hashes[asset.id] = hash;
        assetDescriptions.add(<String, Object?>{
          'kind': asset.kind.name,
          'extension': asset.extension,
          'fileName': asset.fileName,
          'bytes': base64.encode(bytes),
        });
      }
      assetDescriptions.sort(
        (Object? a, Object? b) => jsonEncode(a).compareTo(jsonEncode(b)),
      );
      notes['${pathOf(folder)}:${note.title}'] = <String, Object?>{
        'pageCount': note.pageCount,
        'content': remapAssetIds(
          (await repository.loadNote(note.id)).toJson(),
          hashes,
        ),
        'assets': assetDescriptions,
      };
    }
  }
  return <String, Object?>{
    'folders': <String>[
      for (final Folder folder in folders)
        '${pathOf(folder.id)} (${folder.color.name})',
    ]..sort(),
    'notes': notes,
  };
}

Future<NoteEntry> _entryOf(NoteRepository repository, String id) async {
  for (final String? folder in <String?>[
    null,
    for (final Folder f in await repository.allFolders()) f.id,
  ]) {
    for (final NoteEntry note in (await repository.list(folder)).notes) {
      if (note.id == id) return note;
    }
  }
  throw StateError('No note $id in the library');
}

InMemoryNoteRepository _repository() {
  final InMemoryNoteRepository repository = InMemoryNoteRepository();
  addTearDown(repository.dispose);
  return repository;
}

void main() {
  late FakeGoogleDriveClient drive;

  setUp(() {
    drive = FakeGoogleDriveClient(signedIn: true);
  });

  GoogleDriveBackupService service(
    NoteRepository repository, {
    CloudStateStore? state,
  }) => GoogleDriveBackupService(
    client: drive,
    repository: repository,
    state: state,
    clock: () => DateTime(2026, 10, 16, 9, 30),
  );

  Map<String, Object?> manifest() =>
      jsonDecode(
            utf8.decode(
              drive.bytesOf(drive.itemAt('Etonia/manifest.json')!.id),
            ),
          )
          as Map<String, Object?>;

  /// The manifest's log of note statuses, by id.
  Map<String, Map<String, Object?>> log() => <String, Map<String, Object?>>{
    for (final MapEntry<String, Object?> entry
        in (manifest()['log']! as Map<String, Object?>).entries)
      entry.key: entry.value! as Map<String, Object?>,
  };

  /// The titles of the notes in the manifest's [list].
  List<String> titlesIn(String list) => <String>[
    for (final Object? record in manifest()[list]! as List<Object?>)
      ((record! as Map<String, Object?>)['entry']!
              as Map<String, Object?>)['title']!
          as String,
  ]..sort();

  group('backup', () {
    test('uploads every folder, note, page, stroke, and asset', () async {
      final InMemoryNoteRepository repository = _repository();
      await _seed(repository);
      final List<CloudProgress> progress = <CloudProgress>[];

      final BackupSummary summary = await service(
        repository,
      ).backUp(onProgress: progress.add);

      expect(summary.folderCount, 3);
      expect(summary.noteCount, 2);
      // Two note contents, a PDF, and an image.
      expect(summary.uploadedFiles, 4);
      expect(summary.unchangedFiles, 0);
      final GoogleDriveItem notes = drive.itemAt('Etonia/notes')!;
      expect(drive.childrenOf(notes.id), hasLength(4));
      final Map<String, Object?> json = manifest();
      expect(json['schema'], GoogleDriveBackupService.schema);
      expect(json['folderCount'], 3);
      expect(json['noteCount'], 2);
      expect(json['exportedAt'], isA<String>());
      final List<Object?> records = json['notes']! as List<Object?>;
      final Map<String, Object?> lecture =
          records.firstWhere(
                (Object? r) =>
                    ((r! as Map<String, Object?>)['entry']!
                        as Map<String, Object?>)['title'] ==
                    'Lecture 1',
              )!
              as Map<String, Object?>;
      expect(lecture['contentHash'], hasLength(64));
      expect(
        <Object?>[
          for (final Object? asset in lecture['assets']! as List<Object?>)
            (asset! as Map<String, Object?>)['hash'],
        ],
        unorderedEquals(<String>[
          sha256.convert(_pdf).toString(),
          sha256.convert(_png).toString(),
        ]),
      );
      // Determinate, ending complete.
      expect(progress.last.completedItems, progress.last.totalItems);
      expect(progress.last.totalItems, 5);
      expect(
        progress.map((CloudProgress p) => p.currentName),
        containsAll(<String>['Lecture 1', 'slides.pdf', 'diagram.png']),
      );
    });

    test('records when it last succeeded', () async {
      final InMemoryNoteRepository repository = _repository();
      final InMemoryCloudStateStore state = InMemoryCloudStateStore();
      final GoogleDriveBackupService backup = service(repository, state: state);
      expect(await backup.lastBackupAt(), isNull);
      await backup.backUp();
      expect(await backup.lastBackupAt(), DateTime(2026, 10, 16, 9, 30));
    });

    test('flushes pending saves before reading', () async {
      final InMemoryNoteRepository repository = _repository();
      bool flushed = false;
      await GoogleDriveBackupService(
        client: drive,
        repository: repository,
        flushPendingSaves: () async {
          flushed = true;
          await repository.createNote(title: 'Saved just now');
        },
      ).backUp();
      expect(flushed, isTrue);
      expect(manifest()['noteCount'], 1);
    });

    test('an unchanged library sends only the manifest again', () async {
      final InMemoryNoteRepository repository = _repository();
      await _seed(repository);
      final GoogleDriveBackupService backup = service(repository);
      await backup.backUp();
      drive.uploads.clear();

      final BackupSummary again = await backup.backUp();

      expect(drive.uploads, <String>[GoogleDriveBackupService.manifestName]);
      expect(again.uploadedFiles, 0);
      expect(again.unchangedFiles, 4);
    });

    test('a changed note sends its content, not its assets', () async {
      final InMemoryNoteRepository repository = _repository();
      await _seed(repository);
      final GoogleDriveBackupService backup = service(repository);
      await backup.backUp();
      drive.uploads.clear();
      final NoteEntry lecture = (await repository.search(
        'Lecture',
      )).notes.single;
      final NoteContent content = await repository.loadNote(lecture.id);
      await repository.saveNote(
        lecture.id,
        NoteContent(<StoredPage>[
          ...content.pages,
          StoredPage(setup: const PageSetup(), strokes: <Stroke>[_stroke(5)]),
        ]),
      );

      final BackupSummary summary = await backup.backUp();

      expect(summary.uploadedFiles, 1);
      expect(summary.unchangedFiles, 3);
      expect(drive.uploads, hasLength(2));
      expect(drive.uploads.first, startsWith('${lecture.id}-'));
      expect(drive.uploads.first, endsWith('.json'));
      expect(drive.uploads.last, GoogleDriveBackupService.manifestName);
      // The old content went to the trash; four files are still referred to.
      final GoogleDriveItem notes = drive.itemAt('Etonia/notes')!;
      expect(drive.childrenOf(notes.id), hasLength(4));
    });

    test('backs up Recently Deleted apart from the library', () async {
      final InMemoryNoteRepository repository = _repository();
      await _seed(repository);
      final NoteEntry groceries = (await repository.search(
        'Groceries',
      )).notes.single;
      await repository.deleteNote(groceries.id);

      final BackupSummary summary = await service(repository).backUp();

      expect(summary.noteCount, 1);
      expect(summary.deletedCount, 1);
      expect(titlesIn('notes'), <String>['Lecture 1']);
      expect(titlesIn('trash'), <String>['Groceries']);
    });

    test('logs the latest status of every note', () async {
      final InMemoryNoteRepository repository = _repository();
      await _seed(repository);
      final GoogleDriveBackupService backup = service(repository);
      await backup.backUp();
      final NoteEntry lecture = (await repository.search(
        'Lecture',
      )).notes.single;
      final NoteEntry groceries = (await repository.search(
        'Groceries',
      )).notes.single;
      expect(log()[lecture.id]!['status'], 'live');
      expect(log()[groceries.id]!['status'], 'live');

      await repository.deleteNote(groceries.id, at: DateTime(2026, 10, 2));
      await backup.backUp();
      expect(log()[groceries.id], <String, Object?>{
        'status': 'deleted',
        'at': DateTime(2026, 10, 2).toUtc().toIso8601String(),
        'title': 'Groceries',
      });

      await repository.deleteForever(groceries.id);
      await backup.backUp();
      expect(log()[groceries.id]!['status'], 'purged');
      expect(log()[groceries.id]!['title'], 'Groceries');
      expect(log()[lecture.id]!['status'], 'live');
      expect(titlesIn('notes'), <String>['Lecture 1']);
      expect(titlesIn('trash'), isEmpty);
      // Its content went to the Drive trash; Lecture 1's three files stay.
      expect(drive.childrenOf(drive.itemAt('Etonia/notes')!.id), hasLength(3));
    });

    group('with another device', () {
      late InMemoryNoteRepository first;
      late InMemoryNoteRepository second;
      late GoogleDriveBackupService firstSync;
      late GoogleDriveBackupService secondSync;
      late String groceries;

      setUp(() async {
        first = _repository();
        second = _repository();
        firstSync = service(first, state: InMemoryCloudStateStore());
        secondSync = service(second, state: InMemoryCloudStateStore());
        await _seed(first);
        groceries = (await first.search('Groceries')).notes.single.id;
        await firstSync.backUp();
      });

      test('a note only in the backup comes here as it is there', () async {
        drive.uploads.clear();

        final BackupSummary summary = await secondSync.backUp();

        expect(summary.addedHere, 2);
        final Map<String, Object?> here = await _describe(second);
        final Map<String, Object?> there = await _describe(first);
        // In the same folders; the empty one is not brought.
        expect(here['notes'], there['notes']);
        expect(here['folders'], <String>[
          'School (red)',
          'School/Math (green)',
        ]);
        // Under the same ids, so the log names the same notes.
        expect(
          (await second.list(null)).notes.map((NoteEntry n) => n.id),
          contains(groceries),
        );
        // The assets were already in Drive, so they were not sent again.
        expect(
          drive.uploads.where((String name) => !name.endsWith('.json')),
          isEmpty,
        );
      });

      test('a note deleted there moves to Recently Deleted here, and is '
          'deleted for good only once it is there', () async {
        await secondSync.backUp();
        await first.deleteNote(groceries, at: DateTime(2026, 10, 3));
        await firstSync.backUp();

        final BackupSummary moved = await secondSync.backUp();

        expect(moved.movedToDeleted, 1);
        expect(moved.deletedForGood, 0);
        final NoteEntry trashed = (await second.trash()).single;
        expect(trashed.id, groceries);
        expect(trashed.deleted, DateTime(2026, 10, 3));
        expect(log()[groceries]!['status'], 'deleted');

        // Synced again, still only deleted.
        expect((await secondSync.backUp()).deletedForGood, 0);
        expect(await second.trash(), hasLength(1));

        await first.deleteForever(groceries);
        await firstSync.backUp();
        final BackupSummary purged = await secondSync.backUp();

        expect(purged.deletedForGood, 1);
        expect(await second.trash(), isEmpty);
        expect(log()[groceries]!['status'], 'purged');
      });

      test('a later change here wins over the log', () async {
        await secondSync.backUp();
        await first.deleteNote(groceries);
        await firstSync.backUp();
        await secondSync.backUp();
        expect(await second.trash(), hasLength(1));

        // Taken back out of Recently Deleted here...
        await second.restoreNote(groceries);
        final BackupSummary kept = await secondSync.backUp();
        expect(kept.movedToDeleted, 0);
        expect(log()[groceries]!['status'], 'live');

        // ...and so there too.
        final BackupSummary back = await firstSync.backUp();
        expect(back.addedHere, 1);
        expect(await first.trash(), isEmpty);
        expect(
          (await first.list(null)).notes.map((NoteEntry n) => n.id),
          contains(groceries),
        );
      });

      test('deleting for good here is logged for there', () async {
        await secondSync.backUp();
        await second.deleteNote(groceries);
        await second.deleteForever(groceries);
        await secondSync.backUp();
        expect(log()[groceries]!['status'], 'purged');

        final BackupSummary summary = await firstSync.backUp();

        expect(summary.deletedForGood, 1);
        expect((await first.search('Groceries')).notes, isEmpty);
        expect(await first.trash(), isEmpty);
      });

      test(
        'the same content with a later time there takes only the time',
        () async {
          await secondSync.backUp();
          final DateTime later = DateTime(2032, 5, 6);
          await first.setNoteModified(groceries, later);
          await firstSync.backUp();
          drive.uploads.clear();

          final BackupSummary summary = await secondSync.backUp();

          expect(summary.updatedHere, 0);
          expect(summary.keptBoth, 0);
          expect(
            (await _entryOf(
              second,
              groceries,
            )).modified.isAtSameMomentAs(later),
            isTrue,
          );
          // Nothing but the manifest went to Drive.
          expect(drive.uploads, <String>[
            GoogleDriveBackupService.manifestName,
          ]);
        },
      );

      test(
        'a note never synced here, the same there, takes only the time',
        () async {
          // Here by restoring, so this device has no record of syncing it.
          await secondSync.restore();
          final DateTime later = DateTime(2032, 5, 6);
          await first.setNoteModified(groceries, later);
          await firstSync.backUp();

          final BackupSummary summary = await secondSync.backUp();

          expect(summary.updatedHere, 0);
          expect(summary.keptBoth, 0);
          expect(
            (await _entryOf(
              second,
              groceries,
            )).modified.isAtSameMomentAs(later),
            isTrue,
          );
        },
      );

      test(
        'a later time here is sent without sending the content again',
        () async {
          await secondSync.backUp();
          final DateTime later = DateTime(2032, 5, 6);
          await second.setNoteModified(groceries, later);
          drive.uploads.clear();

          await secondSync.backUp();

          expect(drive.uploads, <String>[
            GoogleDriveBackupService.manifestName,
          ]);
          final Iterable<Object?> entries =
              (manifest()['notes']! as List<Object?>).map(
                (Object? r) => (r! as Map<String, Object?>)['entry'],
              );
          final Map<String, Object?> sent = entries
              .cast<Map<String, Object?>>()
              .firstWhere((Map<String, Object?> e) => e['id'] == groceries);
          expect(
            DateTime.fromMillisecondsSinceEpoch(
              sent['modified']! as int,
            ).isAtSameMomentAs(later),
            isTrue,
          );
        },
      );
    });

    group('opening the app on another device', () {
      late InMemoryNoteRepository first;
      late InMemoryNoteRepository second;
      late GoogleDriveBackupService firstSync;
      late GoogleDriveBackupService secondSync;
      late String groceries;
      String? openThere;

      /// A device whose clock moves on a second at every reading, so each
      /// change is later than the one before.
      (InMemoryNoteRepository, GoogleDriveBackupService) device({
        bool Function(String id)? isNoteOpen,
      }) {
        DateTime now = DateTime(2026, 10, 1);
        DateTime tick() => now = now.add(const Duration(seconds: 1));
        final InMemoryNoteRepository repository = InMemoryNoteRepository(
          clock: tick,
        );
        addTearDown(repository.dispose);
        return (
          repository,
          GoogleDriveBackupService(
            client: drive,
            repository: repository,
            state: InMemoryCloudStateStore(),
            isNoteOpen: isNoteOpen,
            clock: tick,
          ),
        );
      }

      /// Replaces the note's pages with one holding a stroke at [y].
      Future<NoteContent> scribble(
        NoteRepository repository,
        String id,
        double y,
      ) async {
        final NoteContent content = NoteContent(<StoredPage>[
          StoredPage(setup: const PageSetup(), strokes: <Stroke>[_stroke(y)]),
        ]);
        await repository.saveNote(id, content);
        return content;
      }

      setUp(() async {
        openThere = null;
        (first, firstSync) = device();
        (second, secondSync) = device(
          isNoteOpen: (String id) => id == openThere,
        );
        await _seed(first);
        groceries = (await first.search('Groceries')).notes.single.id;
        await firstSync.backUp();
      });

      test('brings what was made, changed, renamed and moved there', () async {
        final SyncSummary? brought = await secondSync.pullIfChangedElsewhere();
        expect(brought!.added, 2);
        expect(
          (await _describe(second))['notes'],
          (await _describe(first))['notes'],
        );

        final Folder school = (await first.allFolders()).firstWhere(
          (Folder folder) => folder.name == 'School',
        );
        await scribble(first, groceries, 300);
        await first.renameNote(groceries, 'Shopping');
        await first.moveNote(groceries, school.id);
        await firstSync.backUp();
        drive.uploads.clear();

        final SyncSummary? updated = await secondSync.pullIfChangedElsewhere();

        expect(updated!.updated, 1);
        expect(updated.added, 0);
        expect(updated.keptBoth, 0);
        expect(
          (await _describe(second))['notes'],
          (await _describe(first))['notes'],
        );
        // Bringing a backup only reads it.
        expect(drive.uploads, isEmpty);
      });

      test('a backup made here, or one already brought, is not brought '
          'again', () async {
        expect(await firstSync.pullIfChangedElsewhere(), isNull);
        expect(await secondSync.pullIfChangedElsewhere(), isNotNull);
        expect(await secondSync.pullIfChangedElsewhere(), isNull);
      });

      test('a note changed on both devices keeps both versions', () async {
        await secondSync.pullIfChangedElsewhere();
        final NoteContent theirs = await scribble(first, groceries, 300);
        await firstSync.backUp();
        final NoteContent mine = await scribble(second, groceries, 500);

        final SyncSummary? summary = await secondSync.pullIfChangedElsewhere();

        expect(summary!.keptBoth, 1);
        expect(summary.updated, 0);
        expect((await second.loadNote(groceries)).toJson(), mine.toJson());
        final NoteEntry copy = (await second.list(null)).notes.singleWhere(
          (NoteEntry note) => note.title == 'Groceries (from another device)',
        );
        expect((await second.loadNote(copy.id)).toJson(), theirs.toJson());

        // Backed up from here, both are in Drive, and this version stays.
        await secondSync.backUp();
        expect(
          titlesIn('notes'),
          containsAll(<String>['Groceries', 'Groceries (from another device)']),
        );
        await firstSync.pullIfChangedElsewhere();
        expect((await first.loadNote(groceries)).toJson(), mine.toJson());
      });

      test('a backup here brings edits made there before sending, so an '
          'older copy does not replace them', () async {
        await secondSync.pullIfChangedElsewhere();
        final NoteContent theirs = await scribble(first, groceries, 300);
        await firstSync.backUp();

        final BackupSummary summary = await secondSync.backUp();

        expect(summary.updatedHere, 1);
        expect((await second.loadNote(groceries)).toJson(), theirs.toJson());
        final SyncSummary? back = await firstSync.pullIfChangedElsewhere();
        expect(back?.updated ?? 0, 0);
        expect((await first.loadNote(groceries)).toJson(), theirs.toJson());
      });

      test('a note open in the editor is left for the next launch', () async {
        await secondSync.pullIfChangedElsewhere();
        final NoteContent before = await second.loadNote(groceries);
        final NoteContent theirs = await scribble(first, groceries, 300);
        await firstSync.backUp();

        openThere = groceries;
        final SyncSummary? whileOpen = await secondSync
            .pullIfChangedElsewhere();
        expect(whileOpen!.updated, 0);
        expect((await second.loadNote(groceries)).toJson(), before.toJson());

        openThere = null;
        final SyncSummary? later = await secondSync.pullIfChangedElsewhere();
        expect(later!.updated, 1);
        expect((await second.loadNote(groceries)).toJson(), theirs.toJson());
      });
    });

    test('cancelling leaves no manifest pointing at half a backup', () async {
      final InMemoryNoteRepository repository = _repository();
      await _seed(repository);
      final ImportCancellationToken cancellation = ImportCancellationToken();

      await expectLater(
        service(repository).backUp(
          cancellation: cancellation,
          onProgress: (CloudProgress progress) {
            if (progress.completedItems == 2) cancellation.cancel();
          },
        ),
        throwsA(isA<CloudCancelledException>()),
      );
      expect(drive.itemAt('Etonia/manifest.json'), isNull);
    });

    test('offline and unauthorized errors come through as they are', () async {
      final InMemoryNoteRepository repository = _repository();
      drive.failure = const GoogleDriveException(
        GoogleDriveErrorKind.offline,
        'Offline',
      );
      await expectLater(
        service(repository).backUp(),
        throwsA(
          isA<GoogleDriveException>().having(
            (GoogleDriveException e) => e.kind,
            'kind',
            GoogleDriveErrorKind.offline,
          ),
        ),
      );
      drive.failure = null;
      await drive.signOut();
      await expectLater(
        service(repository).backUp(),
        throwsA(
          isA<GoogleDriveException>().having(
            (GoogleDriveException e) => e.kind,
            'kind',
            GoogleDriveErrorKind.unauthorized,
          ),
        ),
      );
    });
  });

  group('restore', () {
    test('into a fresh in-memory library reproduces it exactly', () async {
      final InMemoryNoteRepository original = _repository();
      await _seed(original);
      await service(original).backUp();

      final InMemoryNoteRepository fresh = _repository();
      final RestoreSummary summary = await service(fresh).restore();

      expect(summary.foldersCreated, 3);
      expect(summary.notesRestored, 2);
      expect(summary.notesSkipped, 0);
      expect(await _describe(fresh), await _describe(original));
    });

    test('finds a backup in the older Greatnote Backup folder', () async {
      final InMemoryNoteRepository original = _repository();
      await _seed(original);
      await service(original).backUp();
      // Moved to where older versions kept it.
      final GoogleDriveItem current = drive.itemAt('Etonia/manifest.json')!;
      final GoogleDriveItem legacy = drive.addFolder('Greatnote Backup');
      drive.addFile(
        GoogleDriveBackupService.manifestName,
        drive.bytesOf(current.id),
        parentId: legacy.id,
      );
      await drive.deleteFile(current.id);

      final InMemoryNoteRepository fresh = _repository();
      final RestoreSummary summary = await service(fresh).restore();

      expect(summary.notesRestored, 2);
      expect(await _describe(fresh), await _describe(original));
    });

    test('into a fresh file library reproduces it exactly', () async {
      final InMemoryNoteRepository original = _repository();
      await _seed(original);
      await service(original).backUp();
      final Directory directory = await Directory.systemTemp.createTemp(
        'greatnote-restore',
      );
      addTearDown(() => directory.delete(recursive: true));
      final FileNoteRepository files = await FileNoteRepository.open(directory);
      addTearDown(files.dispose);

      await service(files).restore();

      expect(await _describe(files), await _describe(original));
      // And it is on disk: a library opened again reads the same.
      final FileNoteRepository reopened = await FileNoteRepository.open(
        directory,
      );
      addTearDown(reopened.dispose);
      expect(await _describe(reopened), await _describe(original));
    });

    test('merging shares folders and skips notes already there', () async {
      final InMemoryNoteRepository repository = _repository();
      await _seed(repository);
      await service(repository).backUp();
      final Map<String, Object?> before = await _describe(repository);

      final RestoreSummary summary = await service(repository).restore();

      expect(summary.foldersCreated, 0);
      expect(summary.notesRestored, 0);
      expect(summary.notesSkipped, 2);
      expect(await _describe(repository), before);
    });

    test('replacing moves what was here to Recently Deleted', () async {
      final InMemoryNoteRepository original = _repository();
      await _seed(original);
      await service(original).backUp();
      final InMemoryNoteRepository other = _repository();
      await other.createFolder('Old folder');
      await other.createNote(title: 'Old note');

      await service(other).restore(mode: RestoreMode.replace);

      expect(await _describe(other), await _describe(original));
      expect((await other.trash()).map((NoteEntry n) => n.title), <String>[
        'Old note',
      ]);
    });

    test('puts Recently Deleted back in Recently Deleted', () async {
      final InMemoryNoteRepository original = _repository();
      await _seed(original);
      final NoteEntry groceries = (await original.search(
        'Groceries',
      )).notes.single;
      await original.deleteNote(groceries.id, at: DateTime(2026, 10, 1));
      await service(original).backUp();

      final InMemoryNoteRepository fresh = _repository();
      final InMemoryCloudStateStore state = InMemoryCloudStateStore();
      final RestoreSummary summary = await service(
        fresh,
        state: state,
      ).restore();

      expect(summary.notesRestored, 1);
      expect(summary.deletedRestored, 1);
      final NoteEntry deleted = (await fresh.trash()).single;
      expect(deleted.title, 'Groceries');
      expect(deleted.deleted, DateTime(2026, 10, 1));

      // Merging again adds no second copy.
      final RestoreSummary again = await service(fresh, state: state).restore();
      expect(again.deletedRestored, 0);
      expect(await fresh.trash(), hasLength(1));

      // What was restored is what is here: the next backup moves nothing.
      final BackupSummary backup = await service(fresh, state: state).backUp();
      expect(backup.addedHere, 0);
      expect(backup.movedToDeleted, 0);
      expect(backup.deletedForGood, 0);
      expect(titlesIn('notes'), <String>['Lecture 1']);
      expect(titlesIn('trash'), <String>['Groceries']);
    });

    group('over notes brought here already', () {
      late InMemoryNoteRepository original;
      late InMemoryNoteRepository other;
      late GoogleDriveBackupService originalSync;
      late GoogleDriveBackupService sync;
      late NoteEntry groceries;

      Future<Set<String>> idsOf(NoteRepository repository) async => <String>{
        ...(await repository.list(null)).notes.map((NoteEntry n) => n.id),
        for (final Folder folder in await repository.allFolders())
          ...(await repository.list(
            folder.id,
          )).notes.map((NoteEntry n) => n.id),
      };

      setUp(() async {
        original = _repository();
        await _seed(original);
        groceries = (await original.search('Groceries')).notes.single;
        // Keeps its record between backups, as a device does.
        originalSync = service(original, state: InMemoryCloudStateStore());
        await originalSync.backUp();
        // This device has it all from the backup, as on opening the app.
        other = _repository();
        sync = service(other, state: InMemoryCloudStateStore());
        await sync.backUp();
      });

      test('makes no copies, whichever way it restores', () async {
        final Set<String> ids = await idsOf(other);
        final Map<String, Object?> before = await _describe(other);
        expect(ids, hasLength(2));

        for (final RestoreMode mode in RestoreMode.values) {
          await sync.restore(mode: mode);

          expect(await idsOf(other), ids, reason: '$mode');
          expect(await other.trash(), isEmpty, reason: '$mode');
          expect(await _describe(other), before, reason: '$mode');
        }
        // And nothing is logged as deleted for the other devices to see.
        await sync.backUp();
        expect(
          log().values.where((Map<String, Object?> e) => e['status'] != 'live'),
          isEmpty,
        );
      });

      test(
        'keeps a note deleted in the backup once, in Recently Deleted',
        () async {
          await original.deleteNote(groceries.id, at: DateTime(2026, 10, 1));
          await originalSync.backUp();
          await sync.backUp();
          expect((await other.trash()).single.id, groceries.id);

          for (final RestoreMode mode in RestoreMode.values) {
            await sync.restore(mode: mode);

            final NoteEntry deleted = (await other.trash()).single;
            expect(deleted.id, groceries.id, reason: '$mode');
            expect(deleted.deleted, DateTime(2026, 10, 1), reason: '$mode');
            expect(await idsOf(other), hasLength(1), reason: '$mode');
          }
        },
      );

      test(
        'replacing moves a note deleted in the backup, not a copy',
        () async {
          await original.deleteNote(groceries.id, at: DateTime(2026, 10, 1));
          await originalSync.backUp();

          // Restored without syncing first, so it is still in the library here.
          await sync.restore(mode: RestoreMode.replace);

          final NoteEntry deleted = (await other.trash()).single;
          expect(deleted.id, groceries.id);
          expect(deleted.deleted, DateTime(2026, 10, 1));
          expect(await idsOf(other), hasLength(1));
        },
      );

      test(
        'merging brings back a note deleted here, as the same note',
        () async {
          await other.deleteNote(groceries.id);

          final RestoreSummary summary = await sync.restore();

          expect(summary.notesRestored, 1);
          expect(await other.trash(), isEmpty);
          expect(await idsOf(other), contains(groceries.id));
          expect(await idsOf(other), hasLength(2));
        },
      );

      test(
        'replacing keeps what is in the backup and trashes the rest',
        () async {
          final NoteEntry extra = await other.createNote(
            title: 'Not in backup',
          );
          final Set<String> before = await idsOf(other);

          await sync.restore(mode: RestoreMode.replace);

          expect((await other.trash()).single.id, extra.id);
          expect(await idsOf(other), before..remove(extra.id));
        },
      );

      test(
        'a different note takes the later edit, not just the later time',
        () async {
          NoteContent edited(double y) => NoteContent(<StoredPage>[
            StoredPage(setup: const PageSetup(), strokes: <Stroke>[_stroke(y)]),
          ]);

          // Edited here after the backup: replacing keeps this.
          await other.saveNote(groceries.id, edited(500));
          await other.setNoteModified(groceries.id, DateTime(2031));
          await sync.restore(mode: RestoreMode.replace);
          expect(
            (await other.loadNote(groceries.id)).toJson(),
            edited(500).toJson(),
          );

          // Edited there later: merging keeps this, replacing takes that.
          await original.saveNote(groceries.id, edited(700));
          await original.setNoteModified(groceries.id, DateTime(2032));
          await originalSync.backUp();
          await sync.restore();
          expect(
            (await other.loadNote(groceries.id)).toJson(),
            edited(500).toJson(),
          );
          await sync.restore(mode: RestoreMode.replace);
          expect(
            (await other.loadNote(groceries.id)).toJson(),
            edited(700).toJson(),
          );
          expect(
            (await _entryOf(
              other,
              groceries.id,
            )).modified.isAtSameMomentAs(DateTime(2032)),
            isTrue,
          );
          expect(await other.trash(), isEmpty);
        },
      );

      test('the same content only takes the later time', () async {
        await original.setNoteModified(groceries.id, DateTime(2032));
        await originalSync.backUp();

        await sync.restore();

        final NoteEntry here = await _entryOf(other, groceries.id);
        expect(here.modified.isAtSameMomentAs(DateTime(2032)), isTrue);
        expect(await other.trash(), isEmpty);
      });
    });

    test('a restored note keeps the time it was last edited', () async {
      final InMemoryNoteRepository original = _repository();
      await _seed(original);
      final NoteEntry groceries = (await original.search(
        'Groceries',
      )).notes.single;
      await original.setNoteModified(groceries.id, DateTime(2026, 3, 4, 5, 6));
      await original.deleteNote(groceries.id, at: DateTime(2026, 10, 1));
      await service(original).backUp();

      final InMemoryNoteRepository fresh = _repository();
      await service(fresh).restore();

      final NoteEntry lecture = (await fresh.search('Lecture')).notes.single;
      final NoteEntry lectureThere = (await original.search(
        'Lecture',
      )).notes.single;
      // A backup keeps times to the millisecond.
      expect(
        lecture.modified.millisecondsSinceEpoch,
        lectureThere.modified.millisecondsSinceEpoch,
      );
      final NoteEntry deleted = (await fresh.trash()).single;
      expect(
        deleted.modified.isAtSameMomentAs(DateTime(2026, 3, 4, 5, 6)),
        isTrue,
      );
    });

    test('a damaged file stops the restore before anything changes', () async {
      final InMemoryNoteRepository original = _repository();
      await _seed(original);
      await service(original).backUp();
      final GoogleDriveItem notes = drive.itemAt('Etonia/notes')!;
      final GoogleDriveItem pdf = drive
          .childrenOf(notes.id)
          .firstWhere((GoogleDriveItem item) => item.name.endsWith('.pdf'));
      drive.replaceFile(pdf.id, utf8.encode('tampered'), modified: drive.now);
      final InMemoryNoteRepository fresh = _repository();
      await fresh.createNote(title: 'Kept');

      await expectLater(
        service(fresh).restore(mode: RestoreMode.replace),
        throwsA(
          isA<GoogleDriveBackupException>().having(
            (GoogleDriveBackupException e) => e.message,
            'message',
            contains('damaged'),
          ),
        ),
      );
      expect(
        (await fresh.list(null)).notes.map((NoteEntry n) => n.title),
        <String>['Kept'],
      );
      expect(await fresh.allFolders(), isEmpty);
    });

    test('says so when there is no backup', () async {
      await expectLater(
        service(_repository()).restore(),
        throwsA(
          isA<GoogleDriveBackupException>().having(
            (GoogleDriveBackupException e) => e.message,
            'message',
            'No Etonia backup was found in your Google Drive',
          ),
        ),
      );
    });
  });
}
