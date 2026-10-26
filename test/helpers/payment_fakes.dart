import 'dart:async';

import 'package:greatnote/features/payment/in_app_purchase_gateway.dart';
import 'package:greatnote/features/payment/payment_models.dart';
import 'package:greatnote/features/payment/subscription_controller.dart';

/// A store that offers the three plans and does what the test says. It
/// never touches a platform channel.
class FakeInAppPurchaseGateway implements InAppPurchaseGateway {
  @override
  set accountId(String? value) => boundAccountId = value;
  String? boundAccountId;
  FakeInAppPurchaseGateway({
    this.available = true,
    Map<SubscriptionPlan, String>? prices,
    Map<SubscriptionPlan, String>? yearlyPrices,
  }) : prices =
           prices ??
           const <SubscriptionPlan, String>{
             SubscriptionPlan.starter699: '\$6.99',
             SubscriptionPlan.pro1499: '\$14.99',
             SubscriptionPlan.max2499: '\$24.99',
           },
       yearlyPrices =
           yearlyPrices ??
           const <SubscriptionPlan, String>{
             SubscriptionPlan.starter699: '\$69.99',
             SubscriptionPlan.pro1499: '\$149.99',
             SubscriptionPlan.max2499: '\$249.99',
           };

  bool available;
  final Map<SubscriptionPlan, String> prices;
  final Map<SubscriptionPlan, String> yearlyPrices;

  /// The product IDs the store answers to; Android's by default.
  Map<SubscriptionPlan, String> productIds =
      PaymentConfig.defaultAndroidProductIds;
  Map<SubscriptionPlan, String> yearlyProductIds =
      PaymentConfig.defaultAndroidYearlyProductIds;

  final StreamController<List<StorePurchaseUpdate>> _updates =
      StreamController<List<StorePurchaseUpdate>>.broadcast();

  final List<StoreProduct> bought = <StoreProduct>[];
  final List<StorePurchaseUpdate> completed = <StorePurchaseUpdate>[];
  int restores = 0;

  /// What a restore delivers.
  List<StorePurchaseUpdate> restorable = const <StorePurchaseUpdate>[];

  /// When set, purchases are delivered as pending, then purchased, by
  /// themselves. Otherwise the test calls [deliver].
  bool autoComplete = true;

  int _purchases = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<List<StoreProduct>> queryProducts(Set<String> ids) async {
    return <StoreProduct>[
      for (final MapEntry<SubscriptionPlan, String> entry in productIds.entries)
        if (ids.contains(entry.value))
          StoreProduct(
            id: entry.value,
            title: entry.key.title,
            price: prices[entry.key]!,
          ),
      for (final MapEntry<SubscriptionPlan, String> entry
          in yearlyProductIds.entries)
        if (ids.contains(entry.value))
          StoreProduct(
            id: entry.value,
            title: '${entry.key.title} Annual',
            price: yearlyPrices[entry.key]!,
          ),
    ];
  }

  @override
  Stream<List<StorePurchaseUpdate>> get purchaseUpdates => _updates.stream;

  @override
  Future<void> buySubscription(StoreProduct product) async {
    bought.add(product);
    if (!autoComplete) {
      return;
    }
    final String id = 'order-${++_purchases}';
    deliver(<StorePurchaseUpdate>[
      StorePurchaseUpdate(
        productId: product.id,
        purchaseId: id,
        status: StorePurchaseStatus.pending,
      ),
    ]);
    await Future<void>.delayed(Duration.zero);
    deliver(<StorePurchaseUpdate>[
      StorePurchaseUpdate(
        productId: product.id,
        purchaseId: id,
        status: StorePurchaseStatus.purchased,
        pendingCompletePurchase: true,
      ),
    ]);
  }

  /// Sends [updates] down [purchaseUpdates].
  void deliver(List<StorePurchaseUpdate> updates) => _updates.add(updates);

  @override
  Future<void> restorePurchases() async {
    restores++;
    if (restorable.isNotEmpty) {
      deliver(restorable);
    }
  }

  @override
  Future<void> completePurchase(StorePurchaseUpdate purchase) async {
    completed.add(purchase);
  }

  Future<void> close() => _updates.close();
}

/// A loaded controller on [store], with [gateway] when given.
Future<SubscriptionController> loadedSubscription({
  InMemorySubscriptionStore? store,
  InAppPurchaseGateway? gateway,
  SubscriptionPlan? plan,
}) async {
  final SubscriptionController controller = SubscriptionController(
    store: store ?? InMemorySubscriptionStore(),
    gateway: gateway,
  );
  await controller.load();
  if (plan != null) {
    controller.activate(plan);
  }
  return controller;
}
