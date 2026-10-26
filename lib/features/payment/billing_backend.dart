import 'package:flutter/foundation.dart';

import 'in_app_purchase_gateway.dart';
import 'payment_models.dart';

enum SignInMethod { google, apple }

/// Entitlements can only come from a verified server response.
abstract class BillingBackend extends ChangeNotifier {
  bool get isConfigured;
  String? get userId;
  String? get email;
  Future<SubscriptionState> fetchSubscription();
  Future<SubscriptionState> verifyPurchase(StorePurchaseUpdate purchase);

  /// Adds a gift code's free credit to the signed-in account. Throws a
  /// failure coded `invalid_code`, `code_redeemed` or `code_exhausted`.
  Future<SubscriptionState> redeemGiftCode(String code);
  Future<void> signInWithGoogle();

  /// Whether Sign in with Apple is offered beside Google: on Apple devices,
  /// where App Review requires it.
  bool get canSignInWithApple => false;
  Future<void> signInWithApple();

  /// How the signed-in account signed in, for the account panel.
  SignInMethod? get signInMethod => null;
  Future<void> signOut();

  /// Deletes the signed-in account and everything the server keeps for it,
  /// then leaves the device signed out. Notes on the device are untouched,
  /// and store subscriptions are cancelled with the store.
  Future<void> deleteAccount();

  /// Best-effort, content-free product analytics. Test and offline backends
  /// inherit the no-op implementation.
  Future<void> trackProductEvent(String name, {String? detail}) async {}
}
