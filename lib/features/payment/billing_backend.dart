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
  Future<void> signInWithGoogle();
  Future<void> signOut();
}
