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

    test('a note in the backup but not here moves to Recently Deleted, '
        'here and in the backup', () async {
      final InMemoryNoteRepository original = _repository();
      await _seed(original);
      await service(original).backUp();
      final GoogleDriveItem files = drive.itemAt('Etonia/notes')!;
      final Set<String> assetFiles = <String>{
        for (final GoogleDriveItem item in drive.childrenOf(files.id))
          if (!item.name.endsWith('.json')) item.id,
      };
      drive.uploads.clear();

      // Another device, which never had them.
      final InMemoryNoteRepository other = _repository();
      final BackupSummary summary = await service(
        other,
        state: InMemoryCloudStateStore(),
      ).backUp();

      expect(summary.movedToDeleted, 2);
      expect(summary.noteCount, 0);
      expect(summary.deletedCount, 2);
      expect((await other.list(null)).notes, isEmpty);
      final List<NoteEntry> trash = await other.trash();
      expect(
        trash.map((NoteEntry n) => n.title),
        unorderedEquals(<String>['Groceries', 'Lecture 1']),
      );
      for (final NoteEntry note in trash) {
        expect(note.deleted, DateTime(2026, 10, 16, 9, 30));
      }
      // Ink and assets came with them.
      await other.restoreNote(trash.first.id);
      await other.restoreNote(trash.last.id);
      final Map<String, Object?> restored = await _describe(other);
      final Map<String, Object?> expected = await _describe(original);
      expect(
        (restored['notes']! as Map<String, Object?>).values,
        unorderedEquals((expected['notes']! as Map<String, Object?>).values),
      );
      expect(titlesIn('notes'), isEmpty);
      expect(titlesIn('trash'), <String>['Groceries', 'Lecture 1']);
      // The assets were already in Drive, so they were not sent again.
      expect(
        drive.uploads.where((String name) => !name.endsWith('.json')),
        isEmpty,
      );
      expect(
        drive.childrenOf(files.id).map((GoogleDriveItem item) => item.id),
        containsAll(assetFiles),
      );
    });

    test('a note deleted for good leaves the backup', () async {
      final InMemoryNoteRepository repository = _repository();
      await _seed(repository);
      final GoogleDriveBackupService backup = service(repository);
      await backup.backUp();
      final NoteEntry groceries = (await repository.search(
        'Groceries',
      )).notes.single;
      await repository.deleteNote(groceries.id);
      await backup.backUp();
      expect(titlesIn('trash'), <String>['Groceries']);

      await repository.deleteForever(groceries.id);
      final BackupSummary summary = await backup.backUp();

      expect(summary.movedToDeleted, 0);
      expect(await repository.trash(), isEmpty);
      expect(titlesIn('notes'), <String>['Lecture 1']);
      expect(titlesIn('trash'), isEmpty);
      // Its content went to the Drive trash; Lecture 1's three files stay.
      expect(drive.childrenOf(drive.itemAt('Etonia/notes')!.id), hasLength(3));
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
      expect(backup.movedToDeleted, 0);
      expect(titlesIn('notes'), <String>['Lecture 1']);
      expect(titlesIn('trash'), <String>['Groceries']);
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
