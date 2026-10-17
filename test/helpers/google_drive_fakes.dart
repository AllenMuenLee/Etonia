import 'dart:async';
import 'dart:typed_data';

import 'package:greatnote/features/library/cloud/google_drive_client.dart';

/// Google Drive in memory: a My Drive tree of folders and files, and a
/// sign-in that does what the test says.
class FakeGoogleDriveClient implements GoogleDriveClient {
  FakeGoogleDriveClient({
    this.account = const GoogleDriveAccount(
      email: 'ada@example.com',
      displayName: 'Ada Lovelace',
    ),
    bool signedIn = false,
    DateTime? now,
  }) : now = now ?? DateTime.utc(2026, 10, 1) {
    _items[rootId] = _Node(
      const GoogleDriveItem(
        id: rootId,
        name: 'My Drive',
        mimeType: googleDriveFolderMimeType,
      ),
    );
    if (signedIn) _current = account;
  }

  static const String rootId = 'root';

  /// What [signIn] answers with; null as if the user cancelled.
  GoogleDriveAccount? account;

  /// Thrown by [signIn] instead, when set.
  GoogleDriveException? signInError;

  /// Thrown by every Drive operation while set, as when offline.
  GoogleDriveException? failure;

  /// Called before each download, with the file's name.
  void Function(String name)? onDownload;

  /// Uploads wait for this while it is set, so a test can look at work in
  /// progress.
  Completer<void>? uploadGate;

  /// The time given to new files.
  DateTime now;

  GoogleDriveAccount? _current;
  final Map<String, _Node> _items = <String, _Node>{};
  int _ids = 0;

  /// The names of the files uploaded, new files and new versions alike.
  final List<String> uploads = <String>[];
  final List<String> downloads = <String>[];

  @override
  GoogleDriveAccount? get currentAccount => _current;

  @override
  Future<GoogleDriveAccount?> restoreSession() async => _current;

  @override
  Future<GoogleDriveAccount?> signIn() async {
    if (signInError != null) throw signInError!;
    return _current = account;
  }

  @override
  Future<void> signOut() async => _current = null;

  void _check() {
    if (failure != null) throw failure!;
    if (_current == null) {
      throw const GoogleDriveException(
        GoogleDriveErrorKind.unauthorized,
        'Connect Google Drive first',
      );
    }
  }

  _Node _node(String id) {
    final _Node? node = _items[id];
    if (node == null || node.trashed) {
      throw const GoogleDriveException(
        GoogleDriveErrorKind.notFound,
        'The file is no longer in Google Drive',
      );
    }
    return node;
  }

  GoogleDriveItem _add(
    String name,
    String mimeType, {
    required String parentId,
    Uint8List? bytes,
    DateTime? modified,
  }) {
    final GoogleDriveItem item = GoogleDriveItem(
      id: 'f${++_ids}',
      name: name,
      mimeType: mimeType,
      parentIds: <String>[parentId],
      modifiedTime: modified ?? now,
      sizeBytes: bytes?.length,
    );
    _items[item.id] = _Node(item, bytes);
    return item;
  }

  /// Puts a folder in Drive, in My Drive unless [parentId] says otherwise.
  GoogleDriveItem addFolder(
    String name, {
    String parentId = rootId,
    DateTime? modified,
  }) {
    return _add(
      name,
      googleDriveFolderMimeType,
      parentId: parentId,
      modified: modified,
    );
  }

  /// Puts a file in Drive.
  GoogleDriveItem addFile(
    String name,
    List<int> bytes, {
    required String parentId,
    String mimeType = 'application/octet-stream',
    DateTime? modified,
  }) {
    return _add(
      name,
      mimeType,
      parentId: parentId,
      bytes: Uint8List.fromList(bytes),
      modified: modified,
    );
  }

  /// Replaces a file's bytes, as when it is edited elsewhere.
  void replaceFile(String id, List<int> bytes, {required DateTime modified}) {
    final _Node node = _items[id]!;
    _items[id] = _Node(
      GoogleDriveItem(
        id: id,
        name: node.item.name,
        mimeType: node.item.mimeType,
        parentIds: node.item.parentIds,
        modifiedTime: modified,
        sizeBytes: bytes.length,
      ),
      Uint8List.fromList(bytes),
    );
  }

  /// The item at [path] below My Drive, as `Greatnote Backup/notes`, or
  /// null.
  GoogleDriveItem? itemAt(String path) {
    String parent = rootId;
    GoogleDriveItem? found;
    for (final String name in path.split('/')) {
      found = null;
      for (final _Node node in _items.values) {
        if (!node.trashed &&
            node.item.parentIds.contains(parent) &&
            node.item.name == name) {
          found = node.item;
          break;
        }
      }
      if (found == null) return null;
      parent = found.id;
    }
    return found;
  }

  Uint8List bytesOf(String id) => _items[id]!.bytes!;

  /// What is in [folderId] and not in the trash, without signing in.
  List<GoogleDriveItem> childrenOf(String folderId) => <GoogleDriveItem>[
    for (final _Node node in _items.values)
      if (!node.trashed && node.item.parentIds.contains(folderId)) node.item,
  ];

  @override
  Future<List<GoogleDriveItem>> searchFoldersByName(String name) async {
    _check();
    return <GoogleDriveItem>[
      for (final _Node node in _items.values)
        if (!node.trashed &&
            node.item.isFolder &&
            node.item.id != rootId &&
            node.item.name.toLowerCase() == name.toLowerCase())
          node.item,
    ];
  }

  @override
  Future<GoogleDriveItem> getItem(String id) async {
    _check();
    return _node(id).item;
  }

  @override
  Future<List<GoogleDriveItem>> listChildren(String folderId) async {
    _check();
    _node(folderId);
    return childrenOf(folderId);
  }

  @override
  Future<GoogleDriveItem> ensureFolder({
    required String name,
    String? parentId,
  }) async {
    _check();
    final String parent = parentId ?? rootId;
    for (final GoogleDriveItem item in childrenOf(parent)) {
      if (item.isFolder && item.name == name) return item;
    }
    return addFolder(name, parentId: parent);
  }

  @override
  Future<GoogleDriveItem> uploadFile({
    required String parentId,
    required String name,
    required Uint8List bytes,
    required String mimeType,
    String? existingFileId,
  }) async {
    _check();
    await uploadGate?.future;
    uploads.add(name);
    if (existingFileId != null) {
      final _Node node = _node(existingFileId);
      replaceFile(existingFileId, bytes, modified: now);
      return _items[node.item.id]!.item;
    }
    _node(parentId);
    return addFile(name, bytes, parentId: parentId, mimeType: mimeType);
  }

  @override
  Future<Uint8List> downloadFile(String fileId) async {
    _check();
    final _Node node = _node(fileId);
    downloads.add(node.item.name);
    onDownload?.call(node.item.name);
    return Uint8List.fromList(node.bytes!);
  }

  @override
  Future<void> deleteFile(String fileId) async {
    _check();
    _node(fileId).trashed = true;
  }
}

class _Node {
  _Node(this.item, [this.bytes]);

  final GoogleDriveItem item;
  final Uint8List? bytes;
  bool trashed = false;
}
