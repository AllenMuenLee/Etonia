import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

/// A subscription the store offers, with its localized price.
@immutable
class StoreProduct {
  const StoreProduct({
    required this.id,
    required this.title,
    required this.price,
  });

  final String id;
  final String title;

  /// As the store formats it for the user, such as `$4.99` or `4,99 €`.
  final String price;
}

/// Where a purchase is.
enum StorePurchaseStatus { pending, purchased, restored, error, canceled }

/// One update from the store about a purchase.
@immutable
class StorePurchaseUpdate {
  const StorePurchaseUpdate({
    required this.productId,
    required this.status,
    this.purchaseId,
    this.pendingCompletePurchase = false,
    this.errorMessage,
    this.verificationData,
    this.verificationSource,
  });

  final String productId;
  final StorePurchaseStatus status;

  /// The store's ID for this transaction; a renewal gets a new one.
  final String? purchaseId;

  /// Whether the store waits for [InAppPurchaseGateway.completePurchase]
  /// before it stops delivering this update.
  final bool pendingCompletePurchase;
  final String? errorMessage;

  /// Sent only to the verification endpoint; never persisted on device.
  final String? verificationData;
  final String? verificationSource;
}

/// Every interaction with Google Play Billing or the App Store, so tests
/// and other builds can supply their own.
abstract class InAppPurchaseGateway {
  /// Stable account UUID supplied to Apple/Google to bind ownership.
  set accountId(String? value) {}
  Future<bool> isAvailable();

  Future<List<StoreProduct>> queryProducts(Set<String> productIds);

  /// Purchases as they change, including those restored or left
  /// unfinished by an earlier launch.
  Stream<List<StorePurchaseUpdate>> get purchaseUpdates;

  /// Starts buying [product]; the outcome arrives on [purchaseUpdates].
  Future<void> buySubscription(StoreProduct product);

  /// Asks the store to deliver past purchases again, as restored.
  Future<void> restorePurchases();

  /// Tells the store [purchase] has been delivered.
  Future<void> completePurchase(StorePurchaseUpdate purchase);
}

/// [InAppPurchaseGateway] on [InAppPurchase.instance]: Google Play Billing
/// on Android, StoreKit on iOS and iPadOS. Nothing reaches the platform
/// until a method is called, and no call throws.
class PlatformInAppPurchaseGateway implements InAppPurchaseGateway {
  PlatformInAppPurchaseGateway({InAppPurchase? store}) : _given = store;

  final InAppPurchase? _given;
  String? _accountId;
  @override
  set accountId(String? value) => _accountId = value;
  InAppPurchase get _store => _given ?? InAppPurchase.instance;

  final Map<String, ProductDetails> _products = <String, ProductDetails>{};

  /// The store's own records, kept to complete them.
  final Map<String, PurchaseDetails> _pending = <String, PurchaseDetails>{};

  @override
  Future<bool> isAvailable() async {
    try {
      return await _store.isAvailable();
    } on Object {
      return false;
    }
  }

  @override
  Future<List<StoreProduct>> queryProducts(Set<String> productIds) async {
    try {
      final ProductDetailsResponse response = await _store.queryProductDetails(
        productIds,
      );
      return <StoreProduct>[
        for (final ProductDetails details in response.productDetails)
          StoreProduct(
            id: (_products[details.id] = details).id,
            title: details.title,
            price: details.price,
          ),
      ];
    } on Object {
      return const <StoreProduct>[];
    }
  }

  @override
  Stream<List<StorePurchaseUpdate>> get purchaseUpdates {
    final Stream<List<PurchaseDetails>> source;
    try {
      source = _store.purchaseStream;
    } on Object {
      return const Stream<List<StorePurchaseUpdate>>.empty();
    }
    return source.map((List<PurchaseDetails> purchases) {
      return <StorePurchaseUpdate>[
        for (final PurchaseDetails purchase in purchases) _update(purchase),
      ];
    });
  }

  StorePurchaseUpdate _update(PurchaseDetails purchase) {
    final String key = purchase.purchaseID ?? purchase.productID;
    if (purchase.pendingCompletePurchase) {
      _pending[key] = purchase;
    }
    return StorePurchaseUpdate(
      productId: purchase.productID,
      purchaseId: purchase.purchaseID,
      verificationData: purchase.verificationData.serverVerificationData,
      verificationSource: purchase.verificationData.source,
      pendingCompletePurchase: purchase.pendingCompletePurchase,
      status: switch (purchase.status) {
        PurchaseStatus.pending => StorePurchaseStatus.pending,
        PurchaseStatus.purchased => StorePurchaseStatus.purchased,
        PurchaseStatus.restored => StorePurchaseStatus.restored,
        PurchaseStatus.error => StorePurchaseStatus.error,
        PurchaseStatus.canceled => StorePurchaseStatus.canceled,
      },
      // The store's message, never anything of the user's.
      errorMessage: purchase.error?.message,
    );
  }

  @override
  Future<void> buySubscription(StoreProduct product) async {
    final ProductDetails? details = _products[product.id];
    if (details == null) {
      throw StateError('Product not loaded');
    }
    // Subscriptions are bought as non-consumables on both stores.
    await _store.buyNonConsumable(
      purchaseParam: PurchaseParam(
        productDetails: details,
        applicationUserName: _accountId,
      ),
    );
  }

  @override
  Future<void> restorePurchases() =>
      _store.restorePurchases(applicationUserName: _accountId);

  @override
  Future<void> completePurchase(StorePurchaseUpdate purchase) async {
    final PurchaseDetails? details = _pending.remove(
      purchase.purchaseId ?? purchase.productId,
    );
    if (details != null) {
      await _store.completePurchase(details);
    }
  }
}
