import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../editor/ai/ai_client.dart';
import '../editor/ai/ai_usage_gate.dart';
import '../../backend/backend_service.dart' show BackendFailure;
import 'in_app_purchase_gateway.dart';
import 'payment_models.dart';
import 'billing_backend.dart';

/// Where [SubscriptionState] is kept between launches.
abstract class SubscriptionStore {
  Future<Map<String, Object?>?> read();

  Future<void> write(Map<String, Object?> json);
}

/// Keeps the subscription in one JSON file beside the library.
class FileSubscriptionStore implements SubscriptionStore {
  FileSubscriptionStore(this.file);

  final File file;

  @override
  Future<Map<String, Object?>?> read() async {
    try {
      if (!await file.exists()) {
        return null;
      }
      final Object? json = jsonDecode(await file.readAsString());
      return json is Map<String, Object?> ? json : null;
    } on Object {
      // A damaged file is read as no subscription; the store restores it.
      return null;
    }
  }

  @override
  Future<void> write(Map<String, Object?> json) async {
    await file.parent.create(recursive: true);
    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(json), flush: true);
    await temporary.rename(file.path);
  }
}

/// Keeps the subscription in memory, for tests and harnesses.
class InMemorySubscriptionStore implements SubscriptionStore {
  InMemorySubscriptionStore([this.json]);

  Map<String, Object?>? json;

  @override
  Future<Map<String, Object?>?> read() async => json;

  @override
  Future<void> write(Map<String, Object?> json) async {
    this.json = Map<String, Object?>.of(json);
  }
}

/// What the store is busy with, if anything.
enum StoreActivity { idle, loading, purchasing, restoring }

/// The user's plan and AI credits: which models the assistant may use, what
/// each answer costs, and buying and restoring plans through
/// [InAppPurchaseGateway].
///
/// Balances are whole micro-dollars. Credits are granted in full when a
/// purchase or renewal is delivered, and charged after each answer from a
/// metered model, never below zero.
class SubscriptionController extends ChangeNotifier with AiUsageGate {
  SubscriptionController({
    required this.store,
    this.gateway,
    this.backend,
    this.config = const PaymentConfig(),
    TargetPlatform? platform,
  }) : platform = platform ?? defaultTargetPlatform {
    _accountId = backend?.userId;
    backend?.addListener(_accountChanged);
  }

  final SubscriptionStore store;
  final BillingBackend? backend;
  int _refreshVersion = 0;
  Future<void> _processing = Future<void>.value();
  Timer? _expiryRefresh;
  String? _accountId;

  /// Null where there is no store, such as in tests of other features.
  final InAppPurchaseGateway? gateway;
  final PaymentConfig config;
  final TargetPlatform platform;

  SubscriptionState _state = const SubscriptionState();
  AiRoutingPreferences _routing = const AiRoutingPreferences();
  bool _loaded = false;
  bool _disposed = false;
  StreamSubscription<List<StorePurchaseUpdate>>? _updates;
  Future<void> _saving = Future<void>.value();

  bool? _storeAvailable;
  final Map<String, StoreProduct> _products = <String, StoreProduct>{};
  StoreActivity _activity = StoreActivity.idle;
  SubscriptionPlan? _pendingPlan;
  String? _errorMessage;
  String? _notice;

  SubscriptionState get state => _state;
  bool get isLoaded => _loaded;

  SubscriptionPlan? get activePlan {
    if (backend != null &&
        (_state.expiresAt == null ||
            !_state.expiresAt!.isAfter(DateTime.now()))) {
      return null;
    }
    return _state.activePlan;
  }

  /// Free credit lasts a month; the server counts it as none after that, and
  /// so does this, before the next refresh arrives.
  bool get _freeCreditExpired {
    final DateTime? ends = _state.freeCreditExpiresAt;
    return activePlan == null && ends != null && !ends.isAfter(DateTime.now());
  }

  int get remainingCreditsMicroUsd =>
      _freeCreditExpired ? 0 : _state.remainingCreditsMicroUsd;

  /// When the free credit ends, while it is the credit in use.
  DateTime? get freeCreditExpiresAt =>
      hasFreeCredit ? _state.freeCreditExpiresAt : null;

  /// Whether this is a free account the server granted the one-time
  /// credit, spent or not, with no paid plan active.
  bool get hasFreeCredit =>
      backend != null && activePlan == null && _state.freeCreditMicroUsd > 0;

  /// The active plan's full allowance, or the free credit's; 0 otherwise.
  int get includedCreditsMicroUsd =>
      activePlan?.includedCreditsMicroUsd ??
      (hasFreeCredit ? _state.freeCreditMicroUsd : 0);

  /// Null until [connectStore] has asked.
  bool? get storeAvailable => _storeAvailable;
  StoreActivity get activity => _activity;

  /// The plan being bought, while the store has not finished.
  SubscriptionPlan? get pendingPlan => _pendingPlan;

  /// Why the last purchase or restore did not go through.
  String? get errorMessage => _errorMessage;

  /// What the last purchase or restore did.
  String? get notice => _notice;

  /// The store's product for [plan], with its localized price, once
  /// loaded.
  StoreProduct? productFor(
    SubscriptionPlan plan, {
    BillingCycle cycle = BillingCycle.monthly,
  }) {
    final String? productId = config.productIdsFor(
      platform,
      cycle: cycle,
    )[plan];
    return productId == null ? null : _products[productId];
  }

  /// The price to show for [plan]: the store's, or the configured one.
  String priceFor(
    SubscriptionPlan plan, {
    BillingCycle cycle = BillingCycle.monthly,
  }) {
    final StoreProduct? product = productFor(plan, cycle: cycle);
    if (product == null) {
      return cycle == BillingCycle.yearly
          ? plan.yearlyPriceLabel
          : plan.priceLabel;
    }
    return cycle == BillingCycle.yearly
        ? '${product.price} / year'
        : '${product.price} / month';
  }

  SubscriptionPlan? planForProduct(String productId) {
    for (final BillingCycle cycle in BillingCycle.values) {
      final Map<SubscriptionPlan, String> ids = config.productIdsFor(
        platform,
        cycle: cycle,
      );
      for (final MapEntry<SubscriptionPlan, String> entry in ids.entries) {
        if (entry.value == productId) {
          return entry.key;
        }
      }
    }
    return null;
  }

  bool isYearlyProduct(String productId) {
    return config
        .productIdsFor(platform, cycle: BillingCycle.yearly)
        .containsValue(productId);
  }

  /// Reads what was saved. A debug grant from [PaymentConfig.debugPlan]
  /// applies when no plan is active.
  Future<void> load() async {
    final Map<String, Object?>? json = await store.read();
    if (_disposed) {
      return;
    }
    _routing = AiRoutingPreferences.fromJson(json?['routing']);
    if (backend != null) {
      // Only a UI preference is trusted from disk. Never migrate local credits.
      _state = SubscriptionState(
        preferredModel: json == null
            ? null
            : SubscriptionState.fromJson({
                'preferredModel': json['preferredModel'],
              }).preferredModel,
      );
      await refresh();
      _save();
      _loaded = true;
      _notify();
      return;
    }
    if (json != null) {
      _state = SubscriptionState.fromJson(json);
    }
    final SubscriptionPlan? debug = config.debugGrant;
    if (_state.activePlan == null && debug != null) {
      _grant(debug);
    }
    _loaded = true;
    _notify();
  }

  void _accountChanged() {
    if (_accountId != backend?.userId) {
      _accountId = backend?.userId;
      _expiryRefresh?.cancel();
      _state = SubscriptionState(preferredModel: _state.preferredModel);
      _errorMessage = null;
      _notice = null;
      _activity = StoreActivity.idle;
      _pendingPlan = null;
    }
    gateway?.accountId = backend?.userId;
    _notify();
    unawaited(refresh());
  }

  Future<void> refresh() async {
    final remote = backend;
    if (remote == null) return;
    final version = ++_refreshVersion;
    gateway?.accountId = remote.userId;
    try {
      final state = await remote.fetchSubscription();
      if (_disposed || version != _refreshVersion) return;
      _state = state.copyWith(preferredModel: _state.preferredModel);
      _scheduleExpiryRefresh();
      _errorMessage = null;
    } on Object {
      if (_disposed || version != _refreshVersion) return;
      _state = SubscriptionState(preferredModel: _state.preferredModel);
      _errorMessage = 'Could not verify your subscription. Try refreshing.';
    }
    _notify();
  }

  void _scheduleExpiryRefresh() {
    _expiryRefresh?.cancel();
    final expiry = _state.expiresAt ?? _state.freeCreditExpiresAt;
    if (expiry == null || !expiry.isAfter(DateTime.now())) return;
    _expiryRefresh = Timer(
      expiry.difference(DateTime.now()) + const Duration(seconds: 2),
      () => unawaited(refresh()),
    );
  }

  /// Listens for purchases, including any an earlier launch left
  /// unfinished, and loads the products. Safe to call again, to reload
  /// them.
  Future<void> connectStore() async {
    final InAppPurchaseGateway? gateway = this.gateway;
    if (gateway == null || _disposed) {
      _storeAvailable = false;
      _notify();
      return;
    }
    _updates ??= gateway.purchaseUpdates.listen((updates) {
      _processing = _processing.then((_) => _onUpdates(updates)).catchError((
        Object _,
      ) {
        _errorMessage =
            'Could not verify the purchase. Use Restore Purchases to retry.';
        _activity = StoreActivity.idle;
        _pendingPlan = null;
        _notify();
      });
    }, onError: (Object _) {});
    _activity = StoreActivity.loading;
    _notify();
    final bool available = await gateway.isAvailable();
    List<StoreProduct> products = const <StoreProduct>[];
    if (available) {
      products = await gateway.queryProducts(config.allProductIdsFor(platform));
    }
    if (_disposed) {
      return;
    }
    _storeAvailable = available;
    _products.clear();
    for (final StoreProduct product in products) {
      _products[product.id] = product;
    }
    if (_activity == StoreActivity.loading) {
      _activity = StoreActivity.idle;
    }
    _notify();
  }

  /// Starts buying [plan]. Its credits arrive when the store says it has
  /// been bought.
  Future<void> purchase(
    SubscriptionPlan plan, {
    BillingCycle cycle = BillingCycle.monthly,
  }) async {
    if (backend != null &&
        (!backend!.isConfigured || backend!.userId == null)) {
      _errorMessage = 'Sign in before subscribing.';
      _notify();
      return;
    }
    this.gateway?.accountId = backend?.userId;
    final InAppPurchaseGateway? gateway = this.gateway;
    final StoreProduct? product = productFor(plan, cycle: cycle);
    _errorMessage = null;
    _notice = null;
    if (gateway == null || product == null) {
      _errorMessage =
          'The ${plan.title} plan is not available from the store right now.';
      _notify();
      return;
    }
    _activity = StoreActivity.purchasing;
    _pendingPlan = plan;
    _notify();
    unawaited(
      backend?.trackProductEvent(
        'purchase_started',
        detail: '${plan.name}_${cycle.name}',
      ),
    );
    try {
      await gateway.buySubscription(product);
    } on Object {
      _activity = StoreActivity.idle;
      _pendingPlan = null;
      _errorMessage = 'The purchase could not be started. Try again.';
      _notify();
    }
  }

  /// Adds the free credit of a gift code to the signed-in account.
  Future<void> redeemGiftCode(String code) async {
    final remote = backend;
    _errorMessage = null;
    _notice = null;
    if (remote == null || remote.userId == null) {
      _errorMessage = 'Sign in with Google to redeem a gift code.';
      _notify();
      return;
    }
    final owner = remote.userId;
    try {
      final state = await remote.redeemGiftCode(code.trim());
      if (_disposed || owner != remote.userId) return;
      _refreshVersion++;
      _state = state.copyWith(preferredModel: _state.preferredModel);
      _scheduleExpiryRefresh();
      _notice = 'Gift code redeemed. Free credit lasts one month.';
    } on Object catch (error) {
      if (_disposed) return;
      _errorMessage = switch (error is BackendFailure ? error.code : null) {
        'invalid_code' => 'That gift code is not valid.',
        'code_redeemed' => 'You have already redeemed that gift code.',
        'code_exhausted' => 'That gift code has been fully claimed.',
        'unauthorized' => 'Sign in with Google to redeem a gift code.',
        'rate_limited' => 'Too many attempts. Try again in a minute.',
        _ => 'Could not redeem the gift code. Try again.',
      };
    }
    _notify();
  }

  /// Asks the store for past purchases; any found arrive as restored.
  Future<void> restorePurchases() async {
    if (backend != null && backend!.userId == null) {
      _errorMessage = 'Sign in to restore your subscription.';
      _notify();
      return;
    }
    final InAppPurchaseGateway? gateway = this.gateway;
    _errorMessage = null;
    _notice = null;
    if (gateway == null) {
      _errorMessage = 'The store is not available on this device.';
      _notify();
      return;
    }
    _activity = StoreActivity.restoring;
    _notify();
    try {
      await gateway.restorePurchases();
    } on Object {
      _errorMessage = 'Purchases could not be restored. Try again.';
    }
    if (_activity == StoreActivity.restoring) {
      _activity = StoreActivity.idle;
    }
    _notify();
  }

  Future<void> _onUpdates(List<StorePurchaseUpdate> updates) async {
    if (backend != null) {
      for (final update in updates) {
        if (update.status == StorePurchaseStatus.purchased ||
            update.status == StorePurchaseStatus.restored) {
          final owner = backend!.userId;
          // Acknowledge only after the server has durably verified delivery.
          final verified = await backend!.verifyPurchase(update);
          if (owner != backend!.userId || _disposed) return;
          _refreshVersion++;
          _state = verified.copyWith(preferredModel: _state.preferredModel);
          _scheduleExpiryRefresh();
          _errorMessage = null;
          _notice = 'Your subscription has been verified.';
          _activity = StoreActivity.idle;
          _pendingPlan = null;
          _notify();
          if (update.pendingCompletePurchase) {
            await gateway?.completePurchase(update);
          }
        } else if (update.status == StorePurchaseStatus.pending) {
          _activity = StoreActivity.purchasing;
          _pendingPlan = planForProduct(update.productId);
        } else {
          _activity = StoreActivity.idle;
          _pendingPlan = null;
          _errorMessage = update.status == StorePurchaseStatus.canceled
              ? 'Purchase cancelled.'
              : 'The purchase could not be completed.';
        }
      }
      _notify();
      return;
    }
    // Of several purchases delivered together, as on a restore, the
    // highest plan is the one in force.
    StorePurchaseUpdate? best;
    SubscriptionPlan? bestPlan;
    for (final StorePurchaseUpdate update in updates) {
      final SubscriptionPlan? plan = planForProduct(update.productId);
      switch (update.status) {
        case StorePurchaseStatus.pending:
          _activity = StoreActivity.purchasing;
          _pendingPlan = plan;
        case StorePurchaseStatus.purchased || StorePurchaseStatus.restored:
          if (plan != null &&
              (bestPlan == null || plan.index > bestPlan.index)) {
            best = update;
            bestPlan = plan;
          }
        case StorePurchaseStatus.error:
          _activity = StoreActivity.idle;
          _pendingPlan = null;
          _errorMessage = 'The purchase failed. You have not been charged.';
        case StorePurchaseStatus.canceled:
          _activity = StoreActivity.idle;
          _pendingPlan = null;
          _errorMessage = 'Purchase cancelled.';
      }
    }
    if (best != null && bestPlan != null) {
      final bool restored = best.status == StorePurchaseStatus.restored;
      final bool isYearly = isYearlyProduct(best.productId);
      activate(bestPlan, purchaseId: best.purchaseId, isYearly: isYearly);
      _activity = StoreActivity.idle;
      _pendingPlan = null;
      _errorMessage = null;
      _notice = restored
          ? 'Restored your ${bestPlan.title} plan.'
          : 'You are on the ${bestPlan.title} plan.';
    }
    _notify();
    for (final StorePurchaseUpdate update in updates) {
      if (update.pendingCompletePurchase) {
        try {
          await gateway?.completePurchase(update);
        } on Object {
          // The store delivers it again on the next launch.
        }
      }
    }
  }

  /// Makes [plan] the active one and grants its credits, unless
  /// [purchaseId] is the purchase whose credits were already granted, as
  /// when the same subscription is restored again.
  void activate(
    SubscriptionPlan plan, {
    String? purchaseId,
    bool isYearly = false,
  }) {
    if (backend != null) return;
    final bool alreadyGranted =
        purchaseId != null &&
        purchaseId == _state.grantedPurchaseId &&
        plan == _state.activePlan;
    if (!alreadyGranted) {
      _grant(plan, purchaseId: purchaseId, isYearly: isYearly);
    }
    _notify();
  }

  void _grant(
    SubscriptionPlan plan, {
    String? purchaseId,
    bool isYearly = false,
  }) {
    _state = SubscriptionState(
      activePlan: plan,
      remainingCreditsMicroUsd: isYearly
          ? plan.yearlyIncludedCreditsMicroUsd
          : plan.includedCreditsMicroUsd,
      preferredModel: _state.preferredModel,
      grantedPurchaseId: purchaseId ?? _state.grantedPurchaseId,
    );
    _save();
  }

  @override
  AiModelAccess accessFor(AiModelId model) {
    final SubscriptionPlan? plan = activePlan;
    if (plan == null) {
      if (!hasFreeCredit || !freeCreditModels.contains(model)) {
        return AiModelAccess.noPlan;
      }
      return remainingCreditsMicroUsd > 0
          ? AiModelAccess.metered
          : AiModelAccess.outOfCredits;
    }
    if (plan.unlimitedModels.contains(model)) {
      return AiModelAccess.unlimited;
    }
    if (!plan.meteredModels.contains(model)) {
      return AiModelAccess.locked;
    }
    return _state.remainingCreditsMicroUsd > 0
        ? AiModelAccess.metered
        : AiModelAccess.outOfCredits;
  }

  @override
  void recordUsage(AiModelId model, AiTokenUsage usage) {
    if (backend != null) {
      // Usage and deduction are recorded by the endpoint. BackendAiClient
      // refreshes billing after both successful and failed responses.
      return;
    }
    if (accessFor(model) == AiModelAccess.unlimited) {
      return;
    }
    final int cost = config.costOf(model, usage);
    if (cost <= 0) {
      return;
    }
    final int remaining = _state.remainingCreditsMicroUsd - cost;
    _state = _state.copyWith(
      remainingCreditsMicroUsd: remaining < 0 ? 0 : remaining,
    );
    _save();
    _notify();
  }

  @override
  double get tokenFraction {
    final int included = includedCreditsMicroUsd;
    if (included <= 0) {
      return 0;
    }
    return (remainingCreditsMicroUsd / included).clamp(0.0, 1.0);
  }

  @override
  bool get isOutOfTokens => remainingCreditsMicroUsd <= 0;

  @override
  String get creditsLabel {
    if ((activePlan == null && !hasFreeCredit) ||
        remainingCreditsMicroUsd <= 0) {
      return 'Upgrade';
    }
    return '${formatTokenPercent(remainingCreditsMicroUsd, includedCreditsMicroUsd)} tokens';
  }

  @override
  AiRoutingPreferences get routing => _routing;

  @override
  void setRouting(AiRoutingPreferences value) {
    if (value == _routing) {
      return;
    }
    _routing = value;
    _save();
    _notify();
  }

  @override
  AiModelId? get preferredModel => _state.preferredModel;

  @override
  void setPreferredModel(AiModelId model) {
    if (model == _state.preferredModel) {
      return;
    }
    _state = _state.copyWith(preferredModel: model);
    _save();
    _notify();
  }

  /// Done once everything changed so far is written.
  Future<void> get saved => _saving;

  void _save() {
    final Map<String, Object?> json = <String, Object?>{
      ...backend == null
          ? _state.toJson()
          : {'version': 1, 'preferredModel': _state.preferredModel?.name},
      'routing': _routing.toJson(),
    };
    _saving = _saving.then((void _) async {
      try {
        await store.write(json);
      } on Object {
        // Kept in memory; written with the next change.
      }
    });
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _expiryRefresh?.cancel();
    backend?.removeListener(_accountChanged);
    unawaited(_updates?.cancel());
    super.dispose();
  }
}
