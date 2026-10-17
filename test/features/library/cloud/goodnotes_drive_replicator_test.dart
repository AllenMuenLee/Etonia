import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/document_io/document_importer.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/library/cloud/cloud_sync_state.dart';
import 'package:greatnote/features/library/cloud/goodnotes_drive_replicator.dart';
import 'package:greatnote/features/library/cloud/google_drive_client.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';

import '../../../helpers/document_io_fakes.dart';
import '../../../helpers/goodnotes_fixtures.dart';
import '../../../helpers/google_drive_fakes.dart';

/// Calls [onStoreAsset] as each asset is stored, so a test can cancel in
/// the middle of an import.
class _WatchedRepository extends InMemoryNoteRepository {
  void Function()? onStoreAsset;

  @override
  Future<String> storeAsset(
    String noteId,
    Uint8List bytes, {
    required NoteAssetKind kind,
    required String extension,
    String? fileName,
  }) {
    onStoreAsset?.call();
    return super.storeAsset(
      noteId,
      bytes,
      kind: kind,
      extension: extension,
      fileName: fileName,
    );
  }
}

List<int> _pdf(String text) => utf8.encode('%PDF-1.7 $text');

void main() {
  late FakeGoogleDriveClient drive;
  late _WatchedRepository repository;
  late InMemoryCloudStateStore state;

  setUp(() {
    drive = FakeGoogleDriveClient(signedIn: true);
    repository = _WatchedRepository();
    addTearDown(repository.dispose);
    state = InMemoryCloudStateStore();
  });

  GoodnotesDriveReplicator replicator() => GoodnotesDriveReplicator(
    client: drive,
    repository: repository,
    importer: DocumentImporter(rasterizer: FakePdfRasterizer()),
    state: state,
  );

  /// GoodNotes/
  ///   Inbox.goodnotes
  ///   MGY377/
  ///     Labs/      Lab 1.pdf, notes.txt
  ///     Lectures/  Lecture 1.goodnotes, Lecture 2.pdf
  ({GoogleDriveItem root, GoogleDriveItem lecture2}) driveTree() {
    final GoogleDriveItem root = drive.addFolder('GoodNotes');
    drive.addFile(
      'Inbox.goodnotes',
      syntheticGoodnotesNotebook(),
      parentId: root.id,
    );
    final GoogleDriveItem course = drive.addFolder('MGY377', parentId: root.id);
    final GoogleDriveItem lectures = drive.addFolder(
      'Lectures',
      parentId: course.id,
    );
    final GoogleDriveItem labs = drive.addFolder('Labs', parentId: course.id);
    drive.addFile(
      'Lecture 1.goodnotes',
      syntheticGoodnotesNotebook(),
      parentId: lectures.id,
    );
    final GoogleDriveItem lecture2 = drive.addFile(
      'Lecture 2.pdf',
      _pdf('lecture 2'),
      parentId: lectures.id,
      mimeType: 'application/pdf',
    );
    drive.addFile(
      'Lab 1.pdf',
      _pdf('lab 1'),
      parentId: labs.id,
      mimeType: 'application/pdf',
    );
    drive.addFile('notes.txt', utf8.encode('hello'), parentId: labs.id);
    return (root: root, lecture2: lecture2);
  }

  /// The library as `path/to/folder: [note titles]`, folders included even
  /// when empty.
  Future<Map<String, List<String>>> library() async {
    final List<Folder> folders = await repository.allFolders();
    final Map<String, Folder> byId = <String, Folder>{
      for (final Folder f in folders) f.id: f,
    };
    String pathOf(String? id) {
      final List<String> names = <String>[];
      for (String? at = id; at != null; at = byId[at]!.parentId) {
        names.insert(0, byId[at]!.name);
      }
      return names.join('/');
    }

    return <String, List<String>>{
      for (final String? id in <String?>[null, ...byId.keys])
        pathOf(id): <String>[
          for (final NoteEntry note in (await repository.list(id)).notes)
            note.title,
        ]..sort(),
    };
  }

  Future<NoteEntry> noteTitled(String title) async => (await repository.search(
    title,
  )).notes.singleWhere((NoteEntry n) => n.title == title);

  group('finding the Goodnotes folder', () {
    test('matches GoodNotes and Goodnotes, ignoring case', () async {
      drive.addFolder('goodnotes');
      final List<GoodnotesDriveRoot> roots = await replicator().findRoots();
      expect(roots.single.folder.name, 'goodnotes');
      expect(roots.single.location, 'My Drive/goodnotes');
    });

    test('says so clearly when there is none', () async {
      drive.addFolder('Notes');
      await expectLater(
        replicator().findRoots(),
        throwsA(
          isA<GoodnotesFolderNotFoundException>().having(
            (GoodnotesFolderNotFoundException e) => e.toString(),
            'message',
            'No Goodnotes folder was found in your Google Drive',
          ),
        ),
      );
    });

    test('offers each root, the one in My Drive first', () async {
      final GoogleDriveItem backups = drive.addFolder('Backups');
      drive.addFolder(
        'Goodnotes',
        parentId: backups.id,
        modified: DateTime.utc(2026, 9, 30),
      );
      final GoogleDriveItem primary = drive.addFolder(
        'GoodNotes',
        modified: DateTime.utc(2025, 1, 1),
      );
      // Inside the primary one: part of it, not a root.
      drive.addFolder('GoodNotes', parentId: primary.id);

      final List<GoodnotesDriveRoot> roots = await replicator().findRoots();

      expect(roots.map((GoodnotesDriveRoot r) => r.location), <String>[
        'My Drive/GoodNotes',
        'My Drive/Backups/Goodnotes',
      ]);
    });
  });

  group('replicating', () {
    test('rebuilds the exact folder tree and imports every file', () async {
      final GoogleDriveItem root = driveTree().root;
      final List<CloudProgress> progress = <CloudProgress>[];

      final ReplicationSummary summary = await replicator().replicate(
        root,
        onProgress: progress.add,
      );

      expect(await library(), <String, List<String>>{
        '': <String>[],
        'GoodNotes': <String>['Inbox'],
        'GoodNotes/MGY377': <String>[],
        'GoodNotes/MGY377/Lectures': <String>['Lecture 1', 'Lecture 2'],
        'GoodNotes/MGY377/Labs': <String>['Lab 1'],
      });
      expect(summary.foldersCreated, 4);
      expect(summary.foldersReused, 0);
      expect(summary.imported, <String>[
        'Inbox.goodnotes',
        'MGY377/Labs/Lab 1.pdf',
        'MGY377/Lectures/Lecture 1.goodnotes',
        'MGY377/Lectures/Lecture 2.pdf',
      ]);
      expect(summary.skipped.single.path, 'MGY377/Labs/notes.txt');
      expect(summary.failed, isEmpty);
      expect(summary.cancelled, isFalse);
      expect(
        (await repository.pathTo(summary.localRootId)).single.name,
        'GoodNotes',
      );

      // A notebook keeps its editable strokes.
      final NoteContent notebook = await repository.loadNote(
        (await noteTitled('Lecture 1')).id,
      );
      final List<InkVector> points =
          notebook.pages.single.strokes.single.points;
      expect(points.first.x, closeTo(80, 1e-6));
      expect(points.last.x, closeTo(160, 1e-6));

      // A PDF keeps its page as its background, byte for byte.
      final NoteEntry pdfNote = await noteTitled('Lecture 2');
      final NoteContent pdf = await repository.loadNote(pdfNote.id);
      final String assetId = pdf.pages.single.pdfSource!.assetId;
      expect(
        (await repository.readAsset(pdfNote.id, assetId)).bytes,
        _pdf('lecture 2'),
      );

      // Folders first, then each file, counted.
      expect(
        progress.map((CloudProgress p) => p.phase),
        containsAllInOrder(<String>[
          'Replicating folder 1 / 1',
          'Replicating folder 2 / 2',
          'Importing file 1 of 5',
          'Importing file 5 of 5',
        ]),
      );
    });

    test('into a chosen folder', () async {
      final GoogleDriveItem root = driveTree().root;
      final Folder imports = await repository.createFolder('Imports');
      await replicator().replicate(root, targetFolderId: imports.id);
      expect(
        (await library()).keys,
        containsAll(<String>[
          'Imports/GoodNotes',
          'Imports/GoodNotes/MGY377/Labs',
        ]),
      );
    });

    test('running again reuses the folders and the unchanged notes', () async {
      final ({GoogleDriveItem root, GoogleDriveItem lecture2}) tree =
          driveTree();
      await replicator().replicate(tree.root);
      final Map<String, List<String>> first = await library();
      final NoteEntry oldLecture2 = await noteTitled('Lecture 2');

      final ReplicationSummary again = await replicator().replicate(tree.root);

      expect(again.foldersCreated, 0);
      expect(again.foldersReused, 4);
      expect(again.imported, isEmpty);
      expect(again.unchanged, 4);
      expect(await library(), first);

      // A file changed in Drive comes in again; its old note is kept in
      // Recently Deleted.
      drive.replaceFile(
        tree.lecture2.id,
        _pdf('lecture 2, revised'),
        modified: DateTime.utc(2026, 10, 2),
      );
      final ReplicationSummary third = await replicator().replicate(tree.root);
      expect(third.imported, <String>['MGY377/Lectures/Lecture 2.pdf']);
      expect(third.unchanged, 3);
      expect(await library(), first);
      expect((await repository.trash()).single.id, oldLecture2.id);
      final NoteEntry newLecture2 = await noteTitled('Lecture 2');
      final NoteContent content = await repository.loadNote(newLecture2.id);
      expect(
        (await repository.readAsset(
          newLecture2.id,
          content.pages.single.pdfSource!.assetId,
        )).bytes,
        _pdf('lecture 2, revised'),
      );
    });

    test(
      'cancelling keeps finished notes and rolls back the one in flight',
      () async {
        final GoogleDriveItem root = driveTree().root;
        final ImportCancellationToken cancellation = ImportCancellationToken();
        // Lab 1.pdf is the first file with an asset: cancel as it is stored.
        repository.onStoreAsset = cancellation.cancel;

        final ReplicationSummary summary = await replicator().replicate(
          root,
          cancellation: cancellation,
        );

        expect(summary.cancelled, isTrue);
        expect(summary.imported, <String>['Inbox.goodnotes']);
        expect(summary.failed, isEmpty);
        final Map<String, List<String>> after = await library();
        expect(after['GoodNotes'], <String>['Inbox']);
        expect(after['GoodNotes/MGY377/Labs'], isEmpty);
        expect(after['GoodNotes/MGY377/Lectures'], isEmpty);
        // Gone for good, not left in Recently Deleted.
        expect(await repository.trash(), isEmpty);
      },
    );

    test(
      'a file that cannot be read is listed, and the rest still come in',
      () async {
        final GoogleDriveItem root = drive.addFolder('GoodNotes');
        drive.addFile('Broken.goodnotes', <int>[
          0x50,
          0x4B,
          0x03,
          0x04,
          1,
          2,
          3,
        ], parentId: root.id);
        drive.addFile('Fine.pdf', _pdf('fine'), parentId: root.id);

        final ReplicationSummary summary = await replicator().replicate(root);

        expect(summary.failed.single.path, 'Broken.goodnotes');
        expect(summary.imported, <String>['Fine.pdf']);
      },
    );
  });
}
