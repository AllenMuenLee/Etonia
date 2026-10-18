import 'package:flutter/foundation.dart';

import '../editor/ai/ai_client.dart';

/// Micro-dollars in one US dollar. Every balance and price is a whole
/// number of these, so nothing drifts with floating-point rounding.
const int microUsdPerUsd = 1000000;

/// [microUsd] as dollars and cents, rounded down to the cent so a balance
/// is never shown as more than it is: `$1.20`.
String formatUsd(int microUsd) {
  final int cents = microUsd ~/ 10000;
  return '\$${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';
}

/// How a model is paid for.
enum AiModelTier {
  /// Included in every plan without limit: Haiku and Luna.
  unlimited,

  /// Paid from credits on every plan: Sonnet and Sol.
  standard,

  /// Paid from credits on Pro and Max only: Opus, Argon, and Astra.
  frontier;

  static AiModelTier of(AiModelId model) {
    return switch (model) {
      AiModelId.haiku || AiModelId.luna => unlimited,
      AiModelId.sonnet || AiModelId.sol => standard,
      AiModelId.opus || AiModelId.argon || AiModelId.astra => frontier,
    };
  }
}

/// The three monthly plans.
enum SubscriptionPlan {
  starter499(
    title: 'Starter',
    priceLabel: '\$4.99 / month',
    includedCreditsMicroUsd: 1200000,
    meteredModels: <AiModelId>{AiModelId.sonnet, AiModelId.sol},
    creditDescription: '\$1.20 AI credits for Sonnet & Sol combined',
  ),
  pro1299(
    title: 'Pro',
    priceLabel: '\$12.99 / month',
    includedCreditsMicroUsd: 5000000,
    meteredModels: _allMetered,
    creditDescription:
        '\$5.00 AI credits for Sonnet, Sol, Opus, Argon & Astra combined',
  ),
  max2999(
    title: 'Max',
    priceLabel: '\$29.99 / month',
    includedCreditsMicroUsd: 15000000,
    meteredModels: _allMetered,
    creditDescription:
        '\$15.00 AI credits for all models (Sonnet, Sol, Opus, Argon & '
        'Astra combined)',
  );

  const SubscriptionPlan({
    required this.title,
    required this.priceLabel,
    required this.includedCreditsMicroUsd,
    required this.meteredModels,
    required this.creditDescription,
  });

  static const Set<AiModelId> _allMetered = <AiModelId>{
    AiModelId.sonnet,
    AiModelId.sol,
    AiModelId.opus,
    AiModelId.argon,
    AiModelId.astra,
  };

  final String title;

  /// Shown when the store has not given a localized price.
  final String priceLabel;

  /// Credits granted on each purchase or renewal, shared by every model in
  /// [meteredModels].
  final int includedCreditsMicroUsd;
  final Set<AiModelId> meteredModels;
  final String creditDescription;

  /// Unlimited on every plan.
  Set<AiModelId> get unlimitedModels => const <AiModelId>{
    AiModelId.haiku,
    AiModelId.luna,
  };

  /// Models this plan does not include at all.
  Set<AiModelId> get lockedModels => <AiModelId>{
    for (final AiModelId model in AiModelId.values)
      if (!unlimitedModels.contains(model) && !meteredModels.contains(model))
        model,
  };

  bool includes(AiModelId model) =>
      unlimitedModels.contains(model) || meteredModels.contains(model);

  /// The cheapest plan that includes [model].
  static SubscriptionPlan lowestIncluding(AiModelId model) =>
      values.firstWhere((SubscriptionPlan plan) => plan.includes(model));
}

/// Models the free plan's one-time credit pays for. Unlike on a paid plan,
/// Haiku and Luna are charged to it too. Must match `ai_reserve` on the server.
const Set<AiModelId> freeCreditModels = <AiModelId>{
  AiModelId.haiku,
  AiModelId.luna,
  AiModelId.sonnet,
  AiModelId.sol,
};

/// What one model costs, in micro-dollars per thousand tokens: the
/// provider's list price, so credits run down as the API bill does.
@immutable
class AiModelRate {
  const AiModelRate({required this.inputPerKilo, required this.outputPerKilo});

  final int inputPerKilo;
  final int outputPerKilo;

  /// What [usage] costs, rounded up to the micro-dollar.
  int cost(AiTokenUsage usage) {
    final int total =
        usage.inputTokens * inputPerKilo + usage.outputTokens * outputPerKilo;
    return (total + 999) ~/ 1000;
  }
}

/// Store product IDs and per-model token rates. Product IDs come from
/// `dart_defines.json`.
@immutable
class PaymentConfig {
  const PaymentConfig({
    this.androidProductIds = defaultAndroidProductIds,
    this.iosProductIds = defaultIosProductIds,
    this.rates = defaultRates,
    this.debugPlan = '',
  });

  const PaymentConfig.fromEnvironment()
    : this(
        androidProductIds: const <SubscriptionPlan, String>{
          SubscriptionPlan.starter499: String.fromEnvironment(
            'IAP_ANDROID_PLAN_499_ID',
            defaultValue: 'etonia_plan_499_monthly',
          ),
          SubscriptionPlan.pro1299: String.fromEnvironment(
            'IAP_ANDROID_PLAN_1299_ID',
            defaultValue: 'etonia_plan_1299_monthly',
          ),
          SubscriptionPlan.max2999: String.fromEnvironment(
            'IAP_ANDROID_PLAN_2999_ID',
            defaultValue: 'etonia_plan_2999_monthly',
          ),
        },
        iosProductIds: const <SubscriptionPlan, String>{
          SubscriptionPlan.starter499: String.fromEnvironment(
            'IAP_IOS_PLAN_499_ID',
            defaultValue: 'com.etonia.app.plan.499.monthly',
          ),
          SubscriptionPlan.pro1299: String.fromEnvironment(
            'IAP_IOS_PLAN_1299_ID',
            defaultValue: 'com.etonia.app.plan.1299.monthly',
          ),
          SubscriptionPlan.max2999: String.fromEnvironment(
            'IAP_IOS_PLAN_2999_ID',
            defaultValue: 'com.etonia.app.plan.2999.monthly',
          ),
        },
        debugPlan: const String.fromEnvironment('IAP_DEBUG_PLAN'),
      );

  static const Map<SubscriptionPlan, String> defaultAndroidProductIds =
      <SubscriptionPlan, String>{
        SubscriptionPlan.starter499: 'etonia_plan_499_monthly',
        SubscriptionPlan.pro1299: 'etonia_plan_1299_monthly',
        SubscriptionPlan.max2999: 'etonia_plan_2999_monthly',
      };

  static const Map<SubscriptionPlan, String> defaultIosProductIds =
      <SubscriptionPlan, String>{
        SubscriptionPlan.starter499: 'com.etonia.app.plan.499.monthly',
        SubscriptionPlan.pro1299: 'com.etonia.app.plan.1299.monthly',
        SubscriptionPlan.max2999: 'com.etonia.app.plan.2999.monthly',
      };

  /// List prices per million tokens, as micro-dollars per thousand.
  static const Map<AiModelId, AiModelRate> defaultRates =
      <AiModelId, AiModelRate>{
        // Claude Haiku 5.5: $0.10 / $0.50.
        AiModelId.haiku: AiModelRate(inputPerKilo: 100, outputPerKilo: 500),
        // GPT-6 Luna: $0.10 / $0.50.
        AiModelId.luna: AiModelRate(inputPerKilo: 100, outputPerKilo: 500),
        // Claude Sonnet 5.5: $2 / $10.
        AiModelId.sonnet: AiModelRate(inputPerKilo: 2000, outputPerKilo: 10000),
        // GPT-6.1 Sol: $2 / $10.
        AiModelId.sol: AiModelRate(inputPerKilo: 2000, outputPerKilo: 10000),
        // Claude Opus 5.5: $4 / $20.
        AiModelId.opus: AiModelRate(inputPerKilo: 4000, outputPerKilo: 20000),
        // Gemini 4 Argon: $4 / $20, its price after the launch offer.
        AiModelId.argon: AiModelRate(inputPerKilo: 4000, outputPerKilo: 20000),
        // GPT-6 Astra: $10 / $50.
        AiModelId.astra: AiModelRate(inputPerKilo: 10000, outputPerKilo: 50000),
      };

  final Map<SubscriptionPlan, String> androidProductIds;
  final Map<SubscriptionPlan, String> iosProductIds;
  final Map<AiModelId, AiModelRate> rates;

  /// A plan's enum name, such as `pro1299`, granted on launch to a debug
  /// or profile build with no plan, so AI can be tried before the store
  /// products exist. Ignored in release builds.
  final String debugPlan;

  /// The plan [debugPlan] names, outside release builds.
  SubscriptionPlan? get debugGrant {
    if (kReleaseMode) {
      return null;
    }
    for (final SubscriptionPlan plan in SubscriptionPlan.values) {
      if (plan.name == debugPlan.trim()) {
        return plan;
      }
    }
    return null;
  }

  /// The store's product IDs for the platform the app runs on.
  Map<SubscriptionPlan, String> productIdsFor(TargetPlatform platform) {
    return platform == TargetPlatform.iOS || platform == TargetPlatform.macOS
        ? iosProductIds
        : androidProductIds;
  }

  /// What an answer from [model] costs.
  int costOf(AiModelId model, AiTokenUsage usage) {
    return rates[model]?.cost(usage) ?? 0;
  }
}

/// What is remembered about the subscription between launches.
@immutable
class SubscriptionState {
  const SubscriptionState({
    this.activePlan,
    this.remainingCreditsMicroUsd = 0,
    this.preferredModel,
    this.grantedPurchaseId,
    this.expiresAt,
    this.status,
    this.freeCreditMicroUsd = 0,
  });

  factory SubscriptionState.fromJson(Map<String, Object?> json) {
    T? byName<T extends Enum>(List<T> values, Object? name) {
      for (final T value in values) {
        if (value.name == name) {
          return value;
        }
      }
      return null;
    }

    final Object? remaining = json['remainingCreditsMicroUsd'];
    final Object? freeCredit = json['freeCreditMicroUsd'];
    return SubscriptionState(
      activePlan: byName(SubscriptionPlan.values, json['activePlan']),
      remainingCreditsMicroUsd: remaining is int && remaining > 0
          ? remaining
          : 0,
      preferredModel: byName(AiModelId.values, json['preferredModel']),
      grantedPurchaseId: json['grantedPurchaseId'] as String?,
      expiresAt: DateTime.tryParse(json['expiresAt'] as String? ?? ''),
      status: json['status'] as String?,
      freeCreditMicroUsd: freeCredit is int && freeCredit > 0 ? freeCredit : 0,
    );
  }

  final SubscriptionPlan? activePlan;
  final int remainingCreditsMicroUsd;
  final AiModelId? preferredModel;

  /// The purchase whose credits were last granted, so restoring it again
  /// does not grant them twice.
  final String? grantedPurchaseId;
  final DateTime? expiresAt;
  final String? status;

  /// The one-time credit the server granted this free account, or 0. Only
  /// meaningful without an [activePlan]; [remainingCreditsMicroUsd] is
  /// what is left of it.
  final int freeCreditMicroUsd;

  SubscriptionState copyWith({
    SubscriptionPlan? activePlan,
    int? remainingCreditsMicroUsd,
    AiModelId? preferredModel,
    String? grantedPurchaseId,
  }) {
    return SubscriptionState(
      activePlan: activePlan ?? this.activePlan,
      remainingCreditsMicroUsd:
          remainingCreditsMicroUsd ?? this.remainingCreditsMicroUsd,
      preferredModel: preferredModel ?? this.preferredModel,
      grantedPurchaseId: grantedPurchaseId ?? this.grantedPurchaseId,
      expiresAt: expiresAt,
      status: status,
      freeCreditMicroUsd: freeCreditMicroUsd,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'activePlan': activePlan?.name,
    'remainingCreditsMicroUsd': remainingCreditsMicroUsd,
    'preferredModel': preferredModel?.name,
    'grantedPurchaseId': grantedPurchaseId,
  };
}
