import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

/// The MIME type Google Drive gives folders.
const String googleDriveFolderMimeType = 'application/vnd.google-apps.folder';

/// The Google account Drive is reached through.
@immutable
class GoogleDriveAccount {
  const GoogleDriveAccount({required this.email, this.displayName});

  final String email;
  final String? displayName;

  /// The name to show, or the email when there is none.
  String get label {
    final String? name = displayName?.trim();
    return name == null || name.isEmpty ? email : name;
  }
}

/// A file or folder in Google Drive.
@immutable
class GoogleDriveItem {
  const GoogleDriveItem({
    required this.id,
    required this.name,
    required this.mimeType,
    this.parentIds = const <String>[],
    this.modifiedTime,
    this.sizeBytes,
  });

  /// From a Drive v3 `File` resource.
  factory GoogleDriveItem.fromJson(Map<String, Object?> json) {
    final Object? size = json['size'];
    final Object? modified = json['modifiedTime'];
    return GoogleDriveItem(
      id: json['id']! as String,
      name: (json['name'] as String?) ?? '',
      mimeType: (json['mimeType'] as String?) ?? 'application/octet-stream',
      parentIds: <String>[
        for (final Object? parent in (json['parents'] as List?) ?? <Object?>[])
          parent! as String,
      ],
      modifiedTime: modified is String ? DateTime.tryParse(modified) : null,
      sizeBytes: size is String
          ? int.tryParse(size)
          : (size is int ? size : null),
    );
  }

  final String id;
  final String name;
  final String mimeType;
  final List<String> parentIds;
  final DateTime? modifiedTime;

  /// Null for folders and Google Docs, which have no stored size.
  final int? sizeBytes;

  bool get isFolder => mimeType == googleDriveFolderMimeType;
}

/// Why a Drive operation failed, so it can be explained.
enum GoogleDriveErrorKind {
  /// No connection to Google.
  offline,

  /// Not signed in, or access was revoked or refused.
  unauthorized,

  /// The file or folder is gone.
  notFound,

  /// The app is not set up with an OAuth client for this platform.
  configuration,

  /// Google answered with an error.
  server,
}

class GoogleDriveException implements Exception {
  const GoogleDriveException(this.kind, this.message);

  final GoogleDriveErrorKind kind;
  final String message;

  @override
  String toString() => message;
}

/// Google sign-in and the Drive operations Greatnote needs, behind one
/// interface, so tests never reach the network or the platform's sign-in.
abstract class GoogleDriveClient {
  /// The signed-in account, or null.
  GoogleDriveAccount? get currentAccount;

  /// Signs back in without asking, when the platform remembers the user.
  /// Null when it cannot.
  Future<GoogleDriveAccount?> restoreSession();

  /// Asks the user to sign in and allow Drive access. Null when they
  /// cancel.
  Future<GoogleDriveAccount?> signIn();

  Future<void> signOut();

  /// Folders not in the trash named [name], ignoring case.
  Future<List<GoogleDriveItem>> searchFoldersByName(String name);

  /// The file or folder [id], with its parents.
  Future<GoogleDriveItem> getItem(String id);

  /// Everything directly in [folderId] that is not in the trash, every
  /// page of it.
  Future<List<GoogleDriveItem>> listChildren(String folderId);

  /// The folder [name] in [parentId], or in My Drive for null, created if
  /// there is none.
  Future<GoogleDriveItem> ensureFolder({
    required String name,
    String? parentId,
  });

  /// Uploads [bytes] as a new file, or as a new version of
  /// [existingFileId].
  Future<GoogleDriveItem> uploadFile({
    required String parentId,
    required String name,
    required Uint8List bytes,
    required String mimeType,
    String? existingFileId,
  });

  Future<Uint8List> downloadFile(String fileId);

  /// Moves a file to the trash.
  Future<void> deleteFile(String fileId);
}

/// The OAuth clients sign-in uses, from `--dart-define`s. iOS needs its
/// own client id (and its reversed id as a URL scheme in Info.plist);
/// Android needs the web client id as the server client id, and the app's
/// package name and signing certificate registered with Google.
@immutable
class GoogleDriveConfig {
  const GoogleDriveConfig({this.clientId = '', this.serverClientId = ''});

  const GoogleDriveConfig.fromEnvironment()
    : clientId = const String.fromEnvironment(clientIdKey),
      serverClientId = const String.fromEnvironment(serverClientIdKey);

  static const String clientIdKey = 'GOOGLE_OAUTH_CLIENT_ID';
  static const String serverClientIdKey = 'GOOGLE_OAUTH_SERVER_CLIENT_ID';

  final String clientId;
  final String serverClientId;
}

/// Signs in with `google_sign_in` and talks to the Drive v3 REST API.
///
/// Nothing touches the platform until sign-in is first needed.
class HttpGoogleDriveClient implements GoogleDriveClient {
  HttpGoogleDriveClient({
    this.config = const GoogleDriveConfig.fromEnvironment(),
    http.Client? httpClient,
    GoogleSignIn? signIn,
    this.timeout = const Duration(seconds: 60),
  }) : _http = httpClient ?? http.Client(),
       _signInOverride = signIn;

  /// Reading every file is needed to find an existing Goodnotes folder;
  /// writing is only to files this app made, its backup.
  static const List<String> scopes = <String>[
    'https://www.googleapis.com/auth/drive.readonly',
    'https://www.googleapis.com/auth/drive.file',
  ];

  static const String _api = 'https://www.googleapis.com/drive/v3';
  static const String _upload = 'https://www.googleapis.com/upload/drive/v3';
  static const String _fields = 'id,name,mimeType,parents,modifiedTime,size';

  /// Larger files go up in a resumable session rather than one request.
  static const int _multipartLimit = 5 * 1024 * 1024;

  final GoogleDriveConfig config;
  final Duration timeout;
  final http.Client _http;
  final GoogleSignIn? _signInOverride;

  GoogleSignIn get _google => _signInOverride ?? GoogleSignIn.instance;

  Future<void>? _initialized;
  GoogleSignInAccount? _user;
  GoogleDriveAccount? _account;

  @override
  GoogleDriveAccount? get currentAccount => _account;

  Future<void> _initialize() {
    return _initialized ??= _google
        .initialize(
          clientId: config.clientId.isEmpty ? null : config.clientId,
          serverClientId: config.serverClientId.isEmpty
              ? null
              : config.serverClientId,
        )
        .catchError((Object error) {
          _initialized = null;
          throw _signInError(error);
        });
  }

  GoogleDriveAccount _remember(GoogleSignInAccount user) {
    _user = user;
    return _account = GoogleDriveAccount(
      email: user.email,
      displayName: user.displayName,
    );
  }

  @override
  Future<GoogleDriveAccount?> restoreSession() async {
    try {
      await _initialize();
      final GoogleSignInAccount? user = await _google
          .attemptLightweightAuthentication();
      if (user == null) return null;
      // Only a session that still has Drive access counts.
      final GoogleSignInClientAuthorization? authorization = await user
          .authorizationClient
          .authorizationForScopes(scopes);
      return authorization == null ? null : _remember(user);
    } on Object {
      return null;
    }
  }

  @override
  Future<GoogleDriveAccount?> signIn() async {
    await _initialize();
    try {
      final GoogleSignInAccount user = await _google.authenticate(
        scopeHint: scopes,
      );
      await user.authorizationClient.authorizeScopes(scopes);
      return _remember(user);
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled ||
          error.code == GoogleSignInExceptionCode.interrupted) {
        return null;
      }
      throw _signInError(error);
    }
  }

  @override
  Future<void> signOut() async {
    _user = null;
    _account = null;
    if (_initialized == null) return;
    try {
      await _google.disconnect();
    } on Object {
      await _google.signOut();
    }
  }

  static GoogleDriveException _signInError(Object error) {
    if (error is GoogleDriveException) return error;
    if (error is GoogleSignInException &&
        (error.code == GoogleSignInExceptionCode.clientConfigurationError ||
            error.code ==
                GoogleSignInExceptionCode.providerConfigurationError)) {
      return const GoogleDriveException(
        GoogleDriveErrorKind.configuration,
        'Google sign-in is not set up for this app',
      );
    }
    return const GoogleDriveException(
      GoogleDriveErrorKind.unauthorized,
      "Couldn't sign in to Google",
    );
  }

  Future<Map<String, String>> _headers({bool prompt = false}) async {
    final GoogleSignInAccount? user = _user;
    if (user == null) {
      throw const GoogleDriveException(
        GoogleDriveErrorKind.unauthorized,
        'Connect Google Drive first',
      );
    }
    try {
      final Map<String, String>? headers = await user.authorizationClient
          .authorizationHeaders(scopes, promptIfNecessary: prompt);
      if (headers == null) {
        throw const GoogleDriveException(
          GoogleDriveErrorKind.unauthorized,
          'Google Drive access has expired. Connect again.',
        );
      }
      return headers;
    } on GoogleSignInException catch (error) {
      throw _signInError(error);
    }
  }

  /// Sends a request built with fresh authorization headers; on a 401 the
  /// token is dropped and the request is tried once more.
  Future<http.Response> _send(
    Future<http.Response> Function(Map<String, String> headers) request,
  ) async {
    for (int attempt = 0; ; attempt++) {
      final Map<String, String> headers = await _headers(prompt: attempt > 0);
      final http.Response response;
      try {
        response = await request(headers).timeout(timeout);
      } on TimeoutException {
        throw const GoogleDriveException(
          GoogleDriveErrorKind.offline,
          'Google Drive is not responding',
        );
      } on http.ClientException {
        throw const GoogleDriveException(
          GoogleDriveErrorKind.offline,
          "Couldn't reach Google Drive. Check your connection.",
        );
      }
      if (response.statusCode == 401 && attempt == 0) {
        final String? token = headers['Authorization']?.replaceFirst(
          'Bearer ',
          '',
        );
        if (token != null) {
          await _user?.authorizationClient.clearAuthorizationToken(
            accessToken: token,
          );
        }
        continue;
      }
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return response;
      }
      throw _responseError(response);
    }
  }

  static GoogleDriveException _responseError(http.Response response) {
    return switch (response.statusCode) {
      401 => const GoogleDriveException(
        GoogleDriveErrorKind.unauthorized,
        'Google Drive access has expired. Connect again.',
      ),
      403 => const GoogleDriveException(
        GoogleDriveErrorKind.unauthorized,
        'Google Drive refused access',
      ),
      404 => const GoogleDriveException(
        GoogleDriveErrorKind.notFound,
        'The file is no longer in Google Drive',
      ),
      _ => GoogleDriveException(
        GoogleDriveErrorKind.server,
        'Google Drive answered with an error (${response.statusCode})',
      ),
    };
  }

  static String _quote(String value) =>
      "'${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";

  Future<List<GoogleDriveItem>> _query(String q) async {
    final List<GoogleDriveItem> items = <GoogleDriveItem>[];
    String? pageToken;
    do {
      final Uri uri = Uri.parse('$_api/files').replace(
        queryParameters: <String, String>{
          'q': q,
          'fields': 'nextPageToken,files($_fields)',
          'pageSize': '1000',
          'spaces': 'drive',
          'pageToken': ?pageToken,
        },
      );
      final http.Response response = await _send(
        (Map<String, String> headers) => _http.get(uri, headers: headers),
      );
      final Map<String, Object?> json =
          jsonDecode(response.body) as Map<String, Object?>;
      for (final Object? file in (json['files'] as List?) ?? <Object?>[]) {
        items.add(GoogleDriveItem.fromJson(file! as Map<String, Object?>));
      }
      pageToken = json['nextPageToken'] as String?;
    } while (pageToken != null);
    return items;
  }

  @override
  Future<List<GoogleDriveItem>> searchFoldersByName(String name) async {
    // Drive matches `=` exactly; the likely spellings are asked for, and
    // `contains` catches the rest, then the case is ignored here.
    final Set<String> spellings = <String>{
      name,
      name.toLowerCase(),
      name.toUpperCase(),
      if (name.isNotEmpty)
        name[0].toUpperCase() + name.substring(1).toLowerCase(),
    };
    final String names = <String>[
      for (final String spelling in spellings) 'name = ${_quote(spelling)}',
      'name contains ${_quote(name)}',
    ].join(' or ');
    final List<GoogleDriveItem> found = await _query(
      "mimeType = '$googleDriveFolderMimeType' and trashed = false and "
      '($names)',
    );
    final String wanted = name.toLowerCase();
    return <GoogleDriveItem>[
      for (final GoogleDriveItem item in found)
        if (item.name.toLowerCase() == wanted) item,
    ];
  }

  @override
  Future<GoogleDriveItem> getItem(String id) async {
    final Uri uri = Uri.parse(
      '$_api/files/${Uri.encodeComponent(id)}',
    ).replace(queryParameters: <String, String>{'fields': _fields});
    final http.Response response = await _send(
      (Map<String, String> headers) => _http.get(uri, headers: headers),
    );
    return GoogleDriveItem.fromJson(
      jsonDecode(response.body) as Map<String, Object?>,
    );
  }

  @override
  Future<List<GoogleDriveItem>> listChildren(String folderId) {
    return _query('${_quote(folderId)} in parents and trashed = false');
  }

  @override
  Future<GoogleDriveItem> ensureFolder({
    required String name,
    String? parentId,
  }) async {
    final List<GoogleDriveItem> existing = await _query(
      "mimeType = '$googleDriveFolderMimeType' and trashed = false and "
      'name = ${_quote(name)} and ${_quote(parentId ?? 'root')} in parents',
    );
    if (existing.isNotEmpty) return existing.first;
    final Uri uri = Uri.parse(
      '$_api/files',
    ).replace(queryParameters: <String, String>{'fields': _fields});
    final http.Response response = await _send(
      (Map<String, String> headers) => _http.post(
        uri,
        headers: <String, String>{
          ...headers,
          'Content-Type': 'application/json; charset=UTF-8',
        },
        body: jsonEncode(<String, Object?>{
          'name': name,
          'mimeType': googleDriveFolderMimeType,
          if (parentId != null) 'parents': <String>[parentId],
        }),
      ),
    );
    return GoogleDriveItem.fromJson(
      jsonDecode(response.body) as Map<String, Object?>,
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
    final bool update = existingFileId != null;
    // A new version keeps its parents; only a new file is placed.
    final Map<String, Object?> metadata = <String, Object?>{
      'name': name,
      if (!update) 'parents': <String>[parentId],
    };
    final String path = update
        ? '$_upload/files/${Uri.encodeComponent(existingFileId)}'
        : '$_upload/files';
    final http.Response response = bytes.length <= _multipartLimit
        ? await _multipartUpload(path, update, metadata, bytes, mimeType)
        : await _resumableUpload(path, update, metadata, bytes, mimeType);
    return GoogleDriveItem.fromJson(
      jsonDecode(response.body) as Map<String, Object?>,
    );
  }

  Future<http.Response> _multipartUpload(
    String path,
    bool update,
    Map<String, Object?> metadata,
    Uint8List bytes,
    String mimeType,
  ) {
    const String boundary = 'greatnote-drive-upload-boundary';
    final BytesBuilder body = BytesBuilder(copy: false)
      ..add(
        utf8.encode(
          '--$boundary\r\n'
          'Content-Type: application/json; charset=UTF-8\r\n\r\n'
          '${jsonEncode(metadata)}\r\n'
          '--$boundary\r\n'
          'Content-Type: $mimeType\r\n\r\n',
        ),
      )
      ..add(bytes)
      ..add(utf8.encode('\r\n--$boundary--\r\n'));
    final Uint8List payload = body.takeBytes();
    final Uri uri = Uri.parse(path).replace(
      queryParameters: <String, String>{
        'uploadType': 'multipart',
        'fields': _fields,
      },
    );
    return _send((Map<String, String> headers) {
      final http.Request request = http.Request(update ? 'PATCH' : 'POST', uri)
        ..headers.addAll(headers)
        ..headers['Content-Type'] = 'multipart/related; boundary=$boundary'
        ..bodyBytes = payload;
      return _http.send(request).then(http.Response.fromStream);
    });
  }

  Future<http.Response> _resumableUpload(
    String path,
    bool update,
    Map<String, Object?> metadata,
    Uint8List bytes,
    String mimeType,
  ) async {
    final Uri uri = Uri.parse(path).replace(
      queryParameters: <String, String>{
        'uploadType': 'resumable',
        'fields': _fields,
      },
    );
    final http.Response session = await _send((Map<String, String> headers) {
      final http.Request request = http.Request(update ? 'PATCH' : 'POST', uri)
        ..headers.addAll(headers)
        ..headers['Content-Type'] = 'application/json; charset=UTF-8'
        ..headers['X-Upload-Content-Type'] = mimeType
        ..headers['X-Upload-Content-Length'] = '${bytes.length}'
        ..body = jsonEncode(metadata);
      return _http.send(request).then(http.Response.fromStream);
    });
    final String? location = session.headers['location'];
    if (location == null) {
      throw const GoogleDriveException(
        GoogleDriveErrorKind.server,
        "Google Drive didn't start the upload",
      );
    }
    return _send(
      (Map<String, String> headers) => _http.put(
        Uri.parse(location),
        headers: <String, String>{...headers, 'Content-Type': mimeType},
        body: bytes,
      ),
    );
  }

  @override
  Future<Uint8List> downloadFile(String fileId) async {
    final Uri uri = Uri.parse(
      '$_api/files/${Uri.encodeComponent(fileId)}',
    ).replace(queryParameters: <String, String>{'alt': 'media'});
    final http.Response response = await _send(
      (Map<String, String> headers) => _http.get(uri, headers: headers),
    );
    return response.bodyBytes;
  }

  @override
  Future<void> deleteFile(String fileId) async {
    final Uri uri = Uri.parse('$_api/files/${Uri.encodeComponent(fileId)}');
    await _send(
      (Map<String, String> headers) => _http.patch(
        uri,
        headers: <String, String>{
          ...headers,
          'Content-Type': 'application/json; charset=UTF-8',
        },
        body: jsonEncode(<String, Object?>{'trashed': true}),
      ),
    );
  }
}
