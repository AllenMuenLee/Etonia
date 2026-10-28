import 'dart:convert';

import 'package:http/http.dart' as http;

const Set<String> postZenPlatforms = <String>{
  'x',
  'twitter',
  'instagram',
  'tiktok',
  'linkedin',
  'facebook',
  'youtube',
  'threads',
  'pinterest',
  'bluesky',
  'telegram',
};

final class PostZenException implements Exception {
  const PostZenException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

final class PostZenAccount {
  const PostZenAccount({
    required this.id,
    required this.platform,
    required this.username,
    required this.displayName,
    required this.status,
  });

  factory PostZenAccount.fromJson(Map<String, Object?> json) {
    return PostZenAccount(
      id: _requiredString(json, '_id'),
      platform: _requiredString(json, 'platform'),
      username: _optionalString(json, 'username'),
      displayName: _optionalString(json, 'displayName'),
      status: _optionalString(json, 'status'),
    );
  }

  final String id;
  final String platform;
  final String username;
  final String displayName;
  final String status;

  Map<String, Object?> toJson() => <String, Object?>{
    '_id': id,
    'platform': platform,
    'username': username,
    'displayName': displayName,
    'status': status,
  };
}

final class PostZenTarget {
  const PostZenTarget({
    required this.platform,
    required this.accountId,
    this.customContent,
  });

  final String platform;
  final String accountId;
  final String? customContent;

  Map<String, Object?> toJson() => <String, Object?>{
    'platform': platform,
    'accountId': accountId,
    if (customContent != null) 'customContent': customContent,
  };
}

final class PostZenPost {
  const PostZenPost({required this.id, required this.status});

  factory PostZenPost.fromJson(Map<String, Object?> json) {
    return PostZenPost(
      id: _requiredString(json, '_id'),
      status: _optionalString(json, 'status'),
    );
  }

  final String id;
  final String status;

  Map<String, Object?> toJson() => <String, Object?>{
    '_id': id,
    'status': status,
  };
}

final class PostZenClient {
  factory PostZenClient({
    required String apiKey,
    http.Client? httpClient,
    Uri? baseUrl,
  }) => PostZenClient._(
    apiKey,
    httpClient ?? http.Client(),
    httpClient == null,
    baseUrl ?? Uri.parse('https://api.postzen.dev'),
  );

  PostZenClient._(
    this._apiKey,
    this._http,
    this._ownsHttpClient,
    this._baseUrl,
  );

  final String _apiKey;
  final http.Client _http;
  final bool _ownsHttpClient;
  final Uri _baseUrl;

  Future<List<PostZenAccount>> listAccounts() async {
    final Map<String, Object?> body = await _request('GET', '/v1/accounts');
    final Object? accounts = body['accounts'];
    if (accounts is! List<Object?>) {
      throw const PostZenException(
        'PostZen returned an invalid accounts response.',
      );
    }
    return accounts
        .map((Object? value) {
          if (value is! Map<String, Object?>) {
            throw const PostZenException(
              'PostZen returned an invalid account.',
            );
          }
          return PostZenAccount.fromJson(value);
        })
        .toList(growable: false);
  }

  Future<PostZenPost> createPost({
    required String content,
    List<PostZenTarget> platforms = const <PostZenTarget>[],
    bool publishNow = false,
    DateTime? scheduledFor,
    bool isDraft = false,
    String? requestId,
  }) async {
    final int modes =
        (publishNow ? 1 : 0) +
        (scheduledFor == null ? 0 : 1) +
        (isDraft ? 1 : 0);
    if (modes != 1) {
      throw const FormatException(
        'Choose exactly one of draft, publish now, or scheduled time.',
      );
    }
    if (!isDraft && platforms.isEmpty) {
      throw const FormatException(
        'At least one target account is required unless creating a draft.',
      );
    }
    if (content.trim().isEmpty) {
      throw const FormatException('Post content cannot be empty.');
    }
    for (final PostZenTarget target in platforms) {
      if (!postZenPlatforms.contains(target.platform)) {
        throw FormatException(
          'Unsupported PostZen platform: ${target.platform}',
        );
      }
      if (target.accountId.isEmpty) {
        throw const FormatException('A target account ID cannot be empty.');
      }
    }

    final Map<String, Object?> body = await _request(
      'POST',
      '/v1/posts',
      headers: requestId == null
          ? const <String, String>{}
          : <String, String>{'x-request-id': requestId},
      body: <String, Object?>{
        'content': content,
        if (platforms.isNotEmpty)
          'platforms': platforms
              .map((PostZenTarget target) => target.toJson())
              .toList(growable: false),
        if (publishNow) 'publishNow': true,
        if (scheduledFor != null)
          'scheduledFor': scheduledFor.toUtc().toIso8601String(),
        if (isDraft) 'isDraft': true,
      },
    );
    final Object? post = body['post'] ?? body['existingPost'];
    if (post is! Map<String, Object?>) {
      throw const PostZenException(
        'PostZen returned an invalid post response.',
      );
    }
    return PostZenPost.fromJson(post);
  }

  Future<Map<String, Object?>> _request(
    String method,
    String path, {
    Map<String, String> headers = const <String, String>{},
    Map<String, Object?>? body,
  }) async {
    final Uri url = _baseUrl.resolve(path);
    final Map<String, String> requestHeaders = <String, String>{
      'Authorization': 'Bearer $_apiKey',
      'Accept': 'application/json',
      ...headers,
      if (body != null) 'Content-Type': 'application/json',
    };
    final http.Response response;
    try {
      response = switch (method) {
        'GET' => await _http.get(url, headers: requestHeaders),
        'POST' => await _http.post(
          url,
          headers: requestHeaders,
          body: jsonEncode(body),
        ),
        _ => throw ArgumentError.value(method, 'method'),
      };
    } on http.ClientException catch (error) {
      throw PostZenException('Could not reach PostZen: ${error.message}');
    }

    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw PostZenException(
        'PostZen returned a non-JSON response (HTTP ${response.statusCode}).',
        statusCode: response.statusCode,
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw PostZenException(
        'PostZen returned an invalid response (HTTP ${response.statusCode}).',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final Object? error = decoded['error'] ?? decoded['message'];
      throw PostZenException(
        error is String && error.isNotEmpty
            ? 'PostZen request failed: $error'
            : 'PostZen request failed (HTTP ${response.statusCode}).',
        statusCode: response.statusCode,
      );
    }
    return decoded;
  }

  void close() {
    if (_ownsHttpClient) _http.close();
  }
}

String _requiredString(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! String || value.isEmpty) {
    throw PostZenException('PostZen response is missing $key.');
  }
  return value;
}

String _optionalString(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  return value is String ? value : '';
}
