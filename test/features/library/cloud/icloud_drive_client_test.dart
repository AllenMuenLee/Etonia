import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/library/cloud/cloud_sync_state.dart';
import 'package:greatnote/features/library/cloud/google_drive_backup_service.dart';
import 'package:greatnote/features/library/cloud/google_drive_client.dart';
import 'package:greatnote/features/library/cloud/icloud_drive_client.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/note_repository.dart';

/// The native side of the channel, over folders and files in memory.
class _FakeContainer {
  bool available = true;
  final Set<String> folders = <String>{};
  final Map<String, Uint8List> files = <String, Uint8List>{};
  PlatformException? failure;
  final Map<String, DateTime> modified = <String, DateTime>{};

  Future<Object?> handle(MethodCall call) async {
    if (call.method == 'isAvailable') return available;
    if (failure != null) throw failure!;
    final Map<Object?, Object?> arguments =
        call.arguments as Map<Object?, Object?>;
    final String path = arguments['path']! as String;
    switch (call.method) {
      case 'list':
        final String prefix = path.isEmpty ? '' : '$path/';
        bool direct(String item) =>
            item.startsWith(prefix) &&
            !item.substring(prefix.length).contains('/');
        return <Map<String, Object?>>[
          for (final String folder in folders.where(direct))
            <String, Object?>{
              'name': folder.substring(prefix.length),
              'isFolder': true,
            },
          for (final String file in files.keys.where(direct))
            <String, Object?>{
              'name': file.substring(prefix.length),
              'isFolder': false,
              'size': files[file]!.length,
              if (modified[file] != null)
                'modifiedMillis': modified[file]!.millisecondsSinceEpoch,
            },
        ];
      case 'createFolder':
        folders.add(path);
      case 'write':
        files[path] = arguments['bytes']! as Uint8List;
      case 'read':
        final Uint8List? bytes = files[path];
        if (bytes == null) throw PlatformException(code: 'notFound');
        return bytes;
      case 'delete':
        files.remove(path);
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('test/icloud');
  late _FakeContainer container;
  late ICloudDriveClient client;

  setUp(() {
    container = _FakeContainer();
    client = ICloudDriveClient(channel: channel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, container.handle);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('availability', () {
    test('with iCloud on the device, there is an account', () async {
      expect(await client.restoreSession(), ICloudDriveClient.account);
      expect(client.currentAccount, ICloudDriveClient.account);
    });

    test(
      'without iCloud, restoring finds nothing and signing in says why',
      () async {
        container.available = false;
        expect(await client.restoreSession(), isNull);
        await expectLater(
          client.signIn(),
          throwsA(
            isA<GoogleDriveException>()
                .having(
                  (GoogleDriveException e) => e.kind,
                  'kind',
                  GoogleDriveErrorKind.unauthorized,
                )
                .having(
                  (GoogleDriveException e) => e.message,
                  'message',
                  contains('Settings'),
                ),
          ),
        );
      },
    );

    test('a build without the native side counts as no iCloud', () async {
      final ICloudDriveClient missing = ICloudDriveClient(
        channel: const MethodChannel('test/not-registered'),
      );
      expect(await missing.restoreSession(), isNull);
    });
  });

  group('errors', () {
    Future<void> expectKind(String code, GoogleDriveErrorKind kind) async {
      container.failure = PlatformException(code: code, message: 'Disk full');
      await expectLater(
        client.listChildren(''),
        throwsA(
          isA<GoogleDriveException>().having(
            (GoogleDriveException e) => e.kind,
            'kind',
            kind,
          ),
        ),
      );
    }

    test('are told apart', () async {
      await expectKind('notFound', GoogleDriveErrorKind.notFound);
      await expectKind('offline', GoogleDriveErrorKind.offline);
      await expectKind('unavailable', GoogleDriveErrorKind.unauthorized);
      await expectKind('failed', GoogleDriveErrorKind.server);
    });
  });

  test('items are named by their paths', () async {
    final GoogleDriveItem root = await client.ensureFolder(name: 'Etonia');
    final GoogleDriveItem notes = await client.ensureFolder(
      name: 'notes',
      parentId: root.id,
    );
    expect(notes.id, 'Etonia/notes');
    final GoogleDriveItem file = await client.uploadFile(
      parentId: notes.id,
      name: 'a.json',
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
      mimeType: 'application/json',
    );
    expect(file.id, 'Etonia/notes/a.json');
    expect(await client.downloadFile(file.id), <int>[1, 2, 3]);
    expect((await client.getItem(file.id)).sizeBytes, 3);
    expect(
      (await client.searchFoldersByName('ETONIA')).single.isFolder,
      isTrue,
    );
    await client.deleteFile(file.id);
    expect(await client.listChildren(notes.id), isEmpty);
  });

  test('the backup service backs up to iCloud and restores from it', () async {
    final InMemoryNoteRepository here = InMemoryNoteRepository();
    addTearDown(here.dispose);
    await here.createNote(title: 'Lecture 1');
    await GoogleDriveBackupService(
      client: client,
      repository: here,
      destinationName: 'iCloud',
    ).backUp();
    expect(container.files.keys, contains('Etonia/manifest.json'));

    final InMemoryNoteRepository elsewhere = InMemoryNoteRepository();
    addTearDown(elsewhere.dispose);
    await GoogleDriveBackupService(
      client: client,
      repository: elsewhere,
      state: InMemoryCloudStateStore(),
      destinationName: 'iCloud',
    ).restore(mode: RestoreMode.merge);
    expect(
      (await elsewhere.list(null)).notes.map((NoteEntry note) => note.title),
      <String>['Lecture 1'],
    );
  });

  test('a restore with no backup names iCloud', () async {
    final InMemoryNoteRepository here = InMemoryNoteRepository();
    addTearDown(here.dispose);
    await expectLater(
      GoogleDriveBackupService(
        client: client,
        repository: here,
        destinationName: 'iCloud',
      ).restore(mode: RestoreMode.merge),
      throwsA(
        isA<GoogleDriveBackupException>().having(
          (GoogleDriveBackupException e) => e.message,
          'message',
          'No Etonia backup was found in your iCloud',
        ),
      ),
    );
  });

  test('new files no manifest refers to are kept until the grace ends, as '
      "another device's may be arriving ahead of its manifest", () async {
    final DateTime now = DateTime.utc(2026, 11, 2);
    final InMemoryNoteRepository here = InMemoryNoteRepository();
    addTearDown(here.dispose);
    final GoogleDriveBackupService backup = GoogleDriveBackupService(
      client: client,
      repository: here,
      orphanGrace: const Duration(days: 7),
      clock: () => now,
    );
    await backup.backUp();
    const String recent = 'Etonia/notes/recent.json';
    const String old = 'Etonia/notes/old.json';
    const String undated = 'Etonia/notes/undated.json';
    for (final String file in <String>[recent, old, undated]) {
      container.files[file] = Uint8List(1);
    }
    container.modified[recent] = now.subtract(const Duration(days: 1));
    container.modified[old] = now.subtract(const Duration(days: 8));

    await backup.backUp();

    expect(container.files.keys, containsAll(<String>[recent, undated]));
    expect(container.files.keys, isNot(contains(old)));
  });
}
