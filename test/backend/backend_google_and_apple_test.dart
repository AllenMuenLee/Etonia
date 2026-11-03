import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/backend/backend_service.dart';
import 'package:greatnote/features/library/cloud/google_drive_client.dart';
import 'package:greatnote/features/payment/billing_backend.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A session as the server would have given it, for an account that signed
/// in with [provider]. Nothing here reaches the network.
String _session(String provider) {
  String part(Map<String, Object?> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final int expires =
      DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
      1000;
  final String token =
      '${part(<String, Object?>{'alg': 'none'})}.'
      '${part(<String, Object?>{'sub': 'person', 'exp': expires})}.signature';
  return jsonEncode(<String, Object?>{
    'access_token': token,
    'token_type': 'bearer',
    'refresh_token': 'refresh',
    'expires_in': 3600,
    'expires_at': expires,
    'user': <String, Object?>{
      'id': 'person',
      'aud': 'authenticated',
      'email': 'ada@example.com',
      'created_at': '2026-11-02T00:00:00Z',
      'is_anonymous': false,
      'app_metadata': <String, Object?>{
        'provider': provider,
        'providers': <String>[provider],
      },
      'user_metadata': <String, Object?>{},
    },
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(BackendService, SupabaseClient)> signedInWith(String provider) async {
    final SupabaseClient client = SupabaseClient(
      'http://127.0.0.1:9',
      'key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );
    await client.auth.recoverSession(_session(provider));
    final BackendService backend = BackendService(client: client);
    addTearDown(backend.dispose);
    return (backend, client);
  }

  test('disconnecting Google leaves an Apple account signed in', () async {
    final (BackendService backend, _) = await signedInWith('apple');
    expect(backend.signInMethod, SignInMethod.apple);

    await HttpGoogleDriveClient.onSharedSignOut!();

    expect(backend.userId, 'person');
    expect(backend.signInMethod, SignInMethod.apple);
  });

  test('disconnecting Google ends a Google account, as before', () async {
    final (BackendService backend, SupabaseClient client) = await signedInWith(
      'google',
    );
    expect(backend.signInMethod, SignInMethod.google);

    await HttpGoogleDriveClient.onSharedSignOut!();

    expect(client.auth.currentSession, isNull);
    expect(backend.signInMethod, isNull);
  });
}
