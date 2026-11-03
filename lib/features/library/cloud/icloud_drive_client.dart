import 'package:flutter/services.dart';

import 'google_drive_client.dart';

/// The app's iCloud container, reached through the same operations as Google
/// Drive, so [GoogleDriveBackupService] backs up to either.
///
/// There is no sign-in: the container belongs to the iCloud account on the
/// device, whether or not the person has signed into Etonia with Apple. An
/// item's id is its path in the container.
class ICloudDriveClient implements GoogleDriveClient {
  ICloudDriveClient({
    this._channel = const MethodChannel('com.etonia.app/icloud_drive'),
  });

  /// Shown as the account, there being no address to show.
  static const GoogleDriveAccount account = GoogleDriveAccount(
    email: 'The iCloud account on this device',
    displayName: 'iCloud',
  );

  static const String _unavailable =
      'iCloud is not available. Sign in to iCloud in Settings and turn on '
      'iCloud Drive.';

  final MethodChannel _channel;
  GoogleDriveAccount? _current;

  @override
  GoogleDriveAccount? get currentAccount => _current;

  @override
  Future<GoogleDriveAccount?> restoreSession() async {
    bool available = false;
    try {
      available = await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on PlatformException {
      // Counts as not available.
    } on MissingPluginException {
      // Counts as not available.
    }
    return _current = available ? account : null;
  }

  @override
  Future<GoogleDriveAccount?> signIn() async {
    final GoogleDriveAccount? restored = await restoreSession();
    if (restored == null) {
      throw const GoogleDriveException(
        GoogleDriveErrorKind.unauthorized,
        _unavailable,
      );
    }
    return restored;
  }

  /// Nothing to leave: the iCloud account is the device's.
  @override
  Future<void> signOut() async {}

  @override
  Future<List<GoogleDriveItem>> searchFoldersByName(String name) async {
    final String wanted = name.toLowerCase();
    return <GoogleDriveItem>[
      for (final GoogleDriveItem item in await listChildren(''))
        if (item.isFolder && item.name.toLowerCase() == wanted) item,
    ];
  }

  @override
  Future<GoogleDriveItem> getItem(String id) async {
    for (final GoogleDriveItem item in await listChildren(_parentOf(id))) {
      if (item.id == id) return item;
    }
    throw const GoogleDriveException(
      GoogleDriveErrorKind.notFound,
      'The file is no longer in iCloud',
    );
  }

  @override
  Future<List<GoogleDriveItem>> listChildren(String folderId) async {
    final List<Object?> items = await _call<List<Object?>>(
      'list',
      <String, Object?>{'path': folderId},
    );
    return <GoogleDriveItem>[
      for (final Object? item in items)
        _item(
          folderId,
          (item! as Map<Object?, Object?>).cast<String, Object?>(),
        ),
    ];
  }

  @override
  Future<GoogleDriveItem> ensureFolder({
    required String name,
    String? parentId,
  }) async {
    final String parent = parentId ?? '';
    final String path = _join(parent, name);
    await _call<void>('createFolder', <String, Object?>{'path': path});
    return GoogleDriveItem(
      id: path,
      name: name,
      mimeType: googleDriveFolderMimeType,
      parentIds: <String>[parent],
    );
  }

  @override
  Future<GoogleDriveItem> uploadFile({
    required String parentId,
    required String name,
    required Uint8List bytes,
    required String mimeType,
    String? existingFileId,
  }) async {
    final String path = existingFileId ?? _join(parentId, name);
    await _call<void>('write', <String, Object?>{'path': path, 'bytes': bytes});
    return GoogleDriveItem(
      id: path,
      name: name,
      mimeType: mimeType,
      parentIds: <String>[parentId],
      sizeBytes: bytes.length,
    );
  }

  @override
  Future<Uint8List> downloadFile(String fileId) =>
      _call<Uint8List>('read', <String, Object?>{'path': fileId});

  @override
  Future<void> deleteFile(String fileId) =>
      _call<void>('delete', <String, Object?>{'path': fileId});

  static String _join(String parent, String name) =>
      parent.isEmpty ? name : '$parent/$name';

  static String _parentOf(String path) {
    final int slash = path.lastIndexOf('/');
    return slash < 0 ? '' : path.substring(0, slash);
  }

  static GoogleDriveItem _item(String parent, Map<String, Object?> json) {
    final String name = json['name']! as String;
    final Object? modified = json['modifiedMillis'];
    return GoogleDriveItem(
      id: _join(parent, name),
      name: name,
      mimeType: json['isFolder'] == true
          ? googleDriveFolderMimeType
          : 'application/octet-stream',
      parentIds: <String>[parent],
      modifiedTime: modified is int
          ? DateTime.fromMillisecondsSinceEpoch(modified, isUtc: true)
          : null,
      sizeBytes: json['size'] as int?,
    );
  }

  Future<T> _call<T>(String method, Map<String, Object?> arguments) async {
    try {
      return (await _channel.invokeMethod<Object?>(method, arguments)) as T;
    } on PlatformException catch (error) {
      throw _describe(error);
    } on MissingPluginException {
      throw const GoogleDriveException(
        GoogleDriveErrorKind.unauthorized,
        _unavailable,
      );
    }
  }

  static GoogleDriveException _describe(PlatformException error) {
    return switch (error.code) {
      'unavailable' => const GoogleDriveException(
        GoogleDriveErrorKind.unauthorized,
        _unavailable,
      ),
      'notFound' => const GoogleDriveException(
        GoogleDriveErrorKind.notFound,
        'The file is no longer in iCloud',
      ),
      'offline' => const GoogleDriveException(
        GoogleDriveErrorKind.offline,
        "Couldn't reach iCloud. Check your connection and try again.",
      ),
      _ => GoogleDriveException(
        GoogleDriveErrorKind.server,
        error.message ?? "iCloud couldn't finish this. Try again.",
      ),
    };
  }
}
