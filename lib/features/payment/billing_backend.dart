import 'package:flutter/foundation.dart';

import 'in_app_purchase_gateway.dart';
import 'payment_models.dart';

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
  Future<void> signOut();
}
