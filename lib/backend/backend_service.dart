import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/library/cloud/google_drive_client.dart';
import '../features/payment/billing_backend.dart';
import '../features/payment/in_app_purchase_gateway.dart';
import '../features/payment/payment_models.dart';

class BackendFailure implements Exception {
  const BackendFailure(this.code);
  final String code;
  @override
  String toString() => 'BackendFailure($code)';
}

/// Only authentication, billing metadata and transient AI requests use this
/// service. It has no note, PDF, conversation or Storage upload API.
class BackendService extends BillingBackend with WidgetsBindingObserver {
  BackendService({SupabaseClient? client, this.deviceId}) : _client = client {
    if (client != null) {
      WidgetsBinding.instance.addObserver(this);
      HttpGoogleDriveClient.onSharedSignIn = signInWithGoogleAccount;
      HttpGoogleDriveClient.onSharedSignOut = () =>
          signOut(includeGoogleDrive: false);
    }
    _authChanges = client?.auth.onAuthStateChange.listen((_) {
      notifyListeners();
    }, onError: (Object _) {});
  }

  static BackendService instance = BackendService();
  static const url = String.fromEnvironment('SUPABASE_URL');
  static const publishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
  );
  final SupabaseClient? _client;
  StreamSubscription<AuthState>? _authChanges;
  String? _analyticsSessionId;
  DateTime? _analyticsBackgroundedAt;

  /// Supplied by release builds so launch metrics can be split by version.
  static const String _appVersion = String.fromEnvironment('APP_VERSION');

  /// A random ID made on first launch and kept in secure storage, so the
  /// server remembers this device before, and after, Google sign-in. It is
  /// not derived from any hardware identifier.
  final String? deviceId;
  static const _deviceIdKey = 'etonia.device_id';

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      notifyListeners();
      _startAnalyticsSessionIfNeeded();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _analyticsBackgroundedAt = DateTime.now();
    }
  }

  static bool _isPublicClientKey(String key) {
    if (key.startsWith('sb_publishable_')) return true;
    final parts = key.split('.');
    if (parts.length != 3) return false;
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      return payload is Map && payload['role'] == 'anon';
    } on Object {
      return false;
    }
  }

  static Future<void> initialize() async {
    if (url.isEmpty || publishableKey.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        !_isPublicClientKey(publishableKey)) {
      return;
    }
    try {
      await Supabase.initialize(
        url: url,
        publishableKey: publishableKey,
        debug: false,
        authOptions: FlutterAuthClientOptions(
          localStorage: _SecureSessionStorage(uri.host),
          detectSessionInUri: false,
        ),
      );
      instance = BackendService(
        client: Supabase.instance.client,
        deviceId: await _loadDeviceId(),
      );
      unawaited(instance._ensureDeviceAccount());
    } on Object {
      // Local notes remain usable if secure session initialization fails.
      // Never fall back to provider keys or locally granted entitlements.
    }
  }

  static Future<String?> _loadDeviceId() async {
    const storage = FlutterSecureStorage();
    try {
      final existing = await storage.read(key: _deviceIdKey);
      if (existing != null && existing.isNotEmpty) return existing;
      final created = _randomUuid();
      await storage.write(key: _deviceIdKey, value: created);
      return created;
    } on Object {
      return null;
    }
  }

  /// A version 4 UUID from a secure random source.
  static String _randomUuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// Gives a device without Google sign-in an anonymous account on the free
  /// plan, then registers the device with the server.
  Future<void> _ensureDeviceAccount() async {
    final client = _client;
    if (client == null) return;
    try {
      if (client.auth.currentUser == null) {
        await client.auth.signInAnonymously();
      }
      _startAnalyticsSessionIfNeeded();
      if (_isAnonymous) await _anonymousStatus();
    } on Object {
      // Anonymous sign-in may be disabled or offline; retried on next launch.
    }
  }

  bool get _isAnonymous => _client?.auth.currentUser?.isAnonymous ?? false;

  /// Starts a new analytics session after 30 minutes away. This is kept
  /// separate from billing refreshes so DAU/MAU means actual app use.
  void _startAnalyticsSessionIfNeeded() {
    if (_client?.auth.currentUser == null) return;
    final DateTime now = DateTime.now();
    final DateTime? backgrounded = _analyticsBackgroundedAt;
    if (_analyticsSessionId != null &&
        (backgrounded == null ||
            now.difference(backgrounded) < const Duration(minutes: 30))) {
      return;
    }
    _analyticsBackgroundedAt = null;
    _analyticsSessionId = _randomUuid();
    unawaited(trackProductEvent('app_open'));
  }

  /// Records one approved, content-free product event. Analytics must never
  /// delay or break local note-taking, so delivery is best effort.
  @override
  Future<void> trackProductEvent(String name, {String? detail}) async {
    final SupabaseClient? client = _client;
    final String? owner = client?.auth.currentUser?.id;
    if (client == null || owner == null) return;
    _analyticsSessionId ??= _randomUuid();
    try {
      final Map<String, Object?> body = <String, Object?>{
        'eventId': _randomUuid(),
        'sessionId': _analyticsSessionId,
        'name': name,
        'platform': defaultTargetPlatform.name,
        'deviceId': deviceId,
        if (_appVersion.isNotEmpty) 'appVersion': _appVersion,
        'detail': ?detail,
      };
      await client.functions
          .invoke('analytics', body: body)
          .timeout(const Duration(seconds: 8));
    } on Object {
      // Product analytics is non-critical; later events still capture activity.
    }
  }

  Future<SubscriptionState> _anonymousStatus() async {
    try {
      return SubscriptionState.fromJson(
        await invoke('billing', {
          'action': 'status',
          'deviceId': deviceId,
        }, allowAnonymous: true),
      );
    } on Object {
      return const SubscriptionState();
    }
  }

  @override
  bool get isConfigured => _client != null;

  /// The Google-signed-in account; null for an anonymous device account.
  @override
  String? get userId => _isAnonymous ? null : _client?.auth.currentUser?.id;
  @override
  String? get email => _isAnonymous ? null : _client?.auth.currentUser?.email;

  /// Refresh display balances after any AI outcome, including a billed answer
  /// that the client could not parse. This never performs a client-side debit.
  void billingChanged() => notifyListeners();

  Future<Map<String, dynamic>> invoke(
    String name,
    Map<String, Object?> body, {
    bool allowAnonymous = false,
  }) async {
    final client = _client;
    String? owner() => allowAnonymous ? client?.auth.currentUser?.id : userId;
    final before = owner();
    if (client == null) throw const BackendFailure('not_configured');
    if (before == null) throw const BackendFailure('unauthorized');
    try {
      final response = await client.functions
          .invoke(name, body: body)
          .timeout(const Duration(seconds: 115));
      if (before != owner()) throw const BackendFailure('unauthorized');
      if (response.data is! Map<String, dynamic>) {
        throw const BackendFailure('server');
      }
      return response.data as Map<String, dynamic>;
    } on FunctionException catch (error) {
      final details = error.details;
      const allowed = {
        'unauthorized',
        'plan_required',
        'insufficient_credits',
        'rate_limited',
        'purchase_owner',
        'verification_failed',
        'not_configured',
        'request_in_progress',
        'invalid_code',
        'code_redeemed',
        'code_exhausted',
        'rejected',
        'server',
      };
      final code = details is Map ? details['error'] : null;
      throw BackendFailure(allowed.contains(code) ? code as String : 'server');
    }
  }

  /// Invokes an Edge Function that may answer with server-sent JSON events.
  /// A normal JSON response is exposed as a one-event stream too, so callers
  /// can use this during a gradual server rollout.
  Future<Stream<Map<String, dynamic>>> invokeStream(
    String name,
    Map<String, Object?> body, {
    bool allowAnonymous = false,
  }) async {
    final client = _client;
    String? owner() => allowAnonymous ? client?.auth.currentUser?.id : userId;
    final before = owner();
    if (client == null) throw const BackendFailure('not_configured');
    if (before == null) throw const BackendFailure('unauthorized');
    try {
      final response = await client.functions.invoke(
        name,
        headers: const <String, String>{'Accept': 'text/event-stream'},
        body: body,
        abortSignal: Future<void>.delayed(const Duration(seconds: 115)),
      );
      if (before != owner()) throw const BackendFailure('unauthorized');
      final Object? data = response.data;
      if (data is Map<String, dynamic>) {
        return Stream<Map<String, dynamic>>.value(data);
      }
      if (data is! Stream) {
        throw const BackendFailure('server');
      }
      final Stream<List<int>> bytes = data.map<List<int>>((Object? chunk) {
        if (chunk is! List<int>) throw const BackendFailure('server');
        return chunk;
      });
      return _decodeEvents(bytes, owner: owner, expectedOwner: before);
    } on FunctionException catch (error) {
      throw _functionFailure(error);
    }
  }

  static Stream<Map<String, dynamic>> _decodeEvents(
    Stream<List<int>> bytes, {
    required String? Function() owner,
    required String? expectedOwner,
  }) async* {
    try {
      await for (final String line
          in bytes
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .timeout(const Duration(seconds: 115))) {
        if (owner() != expectedOwner) {
          throw const BackendFailure('unauthorized');
        }
        if (!line.startsWith('data:')) continue;
        final Object? event = jsonDecode(line.substring(5).trimLeft());
        if (event is! Map<String, dynamic>) {
          throw const BackendFailure('server');
        }
        yield event;
      }
    } on BackendFailure {
      rethrow;
    } on Object {
      throw const BackendFailure('server');
    }
  }

  static BackendFailure _functionFailure(FunctionException error) {
    final details = error.details;
    const allowed = {
      'unauthorized',
      'plan_required',
      'insufficient_credits',
      'rate_limited',
      'purchase_owner',
      'verification_failed',
      'not_configured',
      'request_in_progress',
      'invalid_code',
      'code_redeemed',
      'code_exhausted',
      'rejected',
      'server',
    };
    final code = details is Map ? details['error'] : null;
    return BackendFailure(allowed.contains(code) ? code as String : 'server');
  }

  @override
  Future<SubscriptionState> fetchSubscription() async {
    if (userId == null) {
      // A device account is always on the free plan; this only records it.
      return _isAnonymous ? _anonymousStatus() : const SubscriptionState();
    }
    return SubscriptionState.fromJson(
      await invoke('billing', {'action': 'status', 'deviceId': deviceId}),
    );
  }

  @override
  Future<SubscriptionState> verifyPurchase(StorePurchaseUpdate purchase) async {
    return SubscriptionState.fromJson(
      await invoke('billing', {
        'action': 'verify',
        'deviceId': deviceId,
        'platform': purchase.verificationSource,
        'productId': purchase.productId,
        'purchaseId': purchase.purchaseId,
        'verificationData': purchase.verificationData,
      }),
    );
  }

  @override
  Future<SubscriptionState> redeemGiftCode(String code) async {
    return SubscriptionState.fromJson(
      await invoke('billing', {
        'action': 'redeem',
        'deviceId': deviceId,
        'code': code,
      }),
    );
  }

  /// Signs into Supabase using an already-authenticated [GoogleSignInAccount]
  /// (for example when the user connects Google Drive backup first).
  Future<void> signInWithGoogleAccount(GoogleSignInAccount account) async {
    final client = _client;
    if (client == null) throw const BackendFailure('not_configured');
    if (userId != null && email == account.email) return;
    final idToken = account.authentication.idToken;
    if (idToken == null || idToken.isEmpty) {
      throw const BackendFailure('unauthorized');
    }
    if (_isAnonymous) {
      // Upgrade this device's free account in place, keeping its user ID.
      // A Google account already used elsewhere cannot be linked; sign into
      // that account instead, and the device is re-registered under it.
      try {
        await client.auth.linkIdentityWithIdToken(
          provider: OAuthProvider.google,
          idToken: idToken,
        );
        _analyticsSessionId = _randomUuid();
        unawaited(trackProductEvent('sign_in'));
        return;
      } on AuthException {
        // Fall through to a normal sign-in.
      }
    }
    await client.auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: idToken,
    );
    _analyticsSessionId = _randomUuid();
    unawaited(trackProductEvent('sign_in'));
  }

  @override
  Future<void> signInWithGoogle() async {
    final client = _client;
    if (client == null) throw const BackendFailure('not_configured');
    final existing = HttpGoogleDriveClient.sharedUser;
    if (existing != null &&
        (existing.authentication.idToken?.isNotEmpty ?? false)) {
      await signInWithGoogleAccount(existing);
      return;
    }
    final account = await HttpGoogleDriveClient.authenticateShared();
    if (account == null) return;
    await signInWithGoogleAccount(account);
  }

  @override
  Future<void> signOut({bool includeGoogleDrive = true}) async {
    if (includeGoogleDrive) {
      await HttpGoogleDriveClient.signOutShared();
    }
    await _client?.auth.signOut(scope: SignOutScope.local);
    _analyticsSessionId = null;
    _analyticsBackgroundedAt = null;
    unawaited(_ensureDeviceAccount());
  }

  @override
  void dispose() {
    if (_client != null) WidgetsBinding.instance.removeObserver(this);
    if (HttpGoogleDriveClient.onSharedSignIn == signInWithGoogleAccount) {
      HttpGoogleDriveClient.onSharedSignIn = null;
      HttpGoogleDriveClient.onSharedSignOut = null;
    }
    unawaited(_authChanges?.cancel());
    super.dispose();
  }
}

class _SecureSessionStorage extends LocalStorage {
  _SecureSessionStorage(String project) : _key = 'etonia.auth.$project';
  final String _key;
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  @override
  Future<void> initialize() async {}
  @override
  Future<String?> accessToken() => _storage.read(key: _key);
  @override
  Future<bool> hasAccessToken() async => await accessToken() != null;
  @override
  Future<void> persistSession(String persistSessionString) =>
      _storage.write(key: _key, value: persistSessionString);
  @override
  Future<void> removePersistedSession() => _storage.delete(key: _key);
}
