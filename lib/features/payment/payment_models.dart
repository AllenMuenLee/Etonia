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

/// Remaining token allowance as a whole percentage (`0` to `100`), rounded
/// down so a partially used pool never reads as `100%`, and a positive
/// remainder never reads as `0%`.
int tokenPercent(int remaining, int included) {
  if (included <= 0 || remaining <= 0) {
    return 0;
  }
  if (remaining >= included) {
    return 100;
  }
  final int pct = (remaining * 100) ~/ included;
  return pct == 0 ? 1 : pct;
}

/// Remaining token allowance formatted as `100%`.
String formatTokenPercent(int remaining, int included) =>
    '${tokenPercent(remaining, included)}%';

/// How a model is paid for.
enum AiModelTier {
  /// Included in every plan without limit: Haiku and Luna.
  unlimited,

  /// Paid from credits on every plan: Sonnet, Sol, and Flash.
  standard,

  /// Paid from credits on Pro and Max only: Opus, Argon, and Astra.
  frontier;

  static AiModelTier of(AiModelId model) {
    return switch (model) {
      AiModelId.haiku || AiModelId.luna => unlimited,
      AiModelId.sonnet || AiModelId.sol || AiModelId.flash => standard,
      AiModelId.opus || AiModelId.argon || AiModelId.astra => frontier,
    };
  }
}

/// The billing cycle chosen by the user.
enum BillingCycle {
  monthly(label: 'Monthly'),
  yearly(label: 'Yearly');

  const BillingCycle({required this.label});
  final String label;
}

/// The three subscription plans.
enum SubscriptionPlan {
  starter699(
    title: 'Starter',
    priceLabel: '\$6.99 / month',
    yearlyPriceLabel: '\$69.99 / year',
    includedCreditsMicroUsd: 2450000,
    yearlyIncludedCreditsMicroUsd: 29400000,
    tokenPoolScale: 0.28,
    meteredModels: <AiModelId>{
      AiModelId.sonnet,
      AiModelId.sol,
      AiModelId.flash,
    },
    creditDescription: 'AI tokens for Sonnet, Sol & Flash combined',
  ),
  pro1499(
    title: 'Pro',
    priceLabel: '\$14.99 / month',
    yearlyPriceLabel: '\$149.99 / year',
    includedCreditsMicroUsd: 5250000,
    yearlyIncludedCreditsMicroUsd: 63000000,
    tokenPoolScale: 0.6,
    meteredModels: _allMetered,
    creditDescription:
        'AI tokens for Sonnet, Sol, Flash, Opus, Argon & Astra combined',
  ),
  max2499(
    title: 'Max',
    priceLabel: '\$24.99 / month',
    yearlyPriceLabel: '\$249.99 / year',
    includedCreditsMicroUsd: 8750000,
    yearlyIncludedCreditsMicroUsd: 105000000,
    tokenPoolScale: 1.0,
    meteredModels: _allMetered,
    creditDescription:
        'AI tokens for all models (Sonnet, Sol, Flash, Opus, Argon & '
        'Astra combined)',
  );

  const SubscriptionPlan({
    required this.title,
    required this.priceLabel,
    required this.yearlyPriceLabel,
    required this.includedCreditsMicroUsd,
    required this.yearlyIncludedCreditsMicroUsd,
    required this.tokenPoolScale,
    required this.meteredModels,
    required this.creditDescription,
  });

  static const Set<AiModelId> _allMetered = <AiModelId>{
    AiModelId.sonnet,
    AiModelId.sol,
    AiModelId.flash,
    AiModelId.opus,
    AiModelId.argon,
    AiModelId.astra,
  };

  final String title;

  /// Shown when the store has not given a localized price.
  final String priceLabel;
  final String yearlyPriceLabel;

  /// Credits granted on each purchase or renewal, shared by every model in
  /// [meteredModels].
  final int includedCreditsMicroUsd;
  final int yearlyIncludedCreditsMicroUsd;

  /// Visual scale (`0` to `1`) of this tier's token pool on the plan card bar.
  final double tokenPoolScale;
  final Set<AiModelId> meteredModels;
  final String creditDescription;

  /// How much more token allowance this plan provides compared to the previous plan.
  String get tokenComparisonText {
    return switch (this) {
      SubscriptionPlan.starter699 => 'Essential AI access',
      SubscriptionPlan.pro1499 => '2.1× more tokens than Starter',
      SubscriptionPlan.max2499 => '1.7× more tokens than Pro (3.6× Starter)',
    };
  }

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
  AiModelId.flash,
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
    this.androidYearlyProductIds = defaultAndroidYearlyProductIds,
    this.iosProductIds = defaultIosProductIds,
    this.iosYearlyProductIds = defaultIosYearlyProductIds,
    this.rates = defaultRates,
    this.debugPlan = '',
  });

  const PaymentConfig.fromEnvironment()
    : this(
        androidProductIds: const <SubscriptionPlan, String>{
          SubscriptionPlan.starter699: String.fromEnvironment(
            'IAP_ANDROID_PLAN_699_ID',
            defaultValue: 'etonia_plan_699_monthly',
          ),
          SubscriptionPlan.pro1499: String.fromEnvironment(
            'IAP_ANDROID_PLAN_1499_ID',
            defaultValue: 'etonia_plan_1499_monthly',
          ),
          SubscriptionPlan.max2499: String.fromEnvironment(
            'IAP_ANDROID_PLAN_2499_ID',
            defaultValue: 'etonia_plan_2499_monthly',
          ),
        },
        androidYearlyProductIds: const <SubscriptionPlan, String>{
          SubscriptionPlan.starter699: String.fromEnvironment(
            'IAP_ANDROID_PLAN_699_YEARLY_ID',
            defaultValue: 'etonia_plan_699_yearly',
          ),
          SubscriptionPlan.pro1499: String.fromEnvironment(
            'IAP_ANDROID_PLAN_1499_YEARLY_ID',
            defaultValue: 'etonia_plan_1499_yearly',
          ),
          SubscriptionPlan.max2499: String.fromEnvironment(
            'IAP_ANDROID_PLAN_2499_YEARLY_ID',
            defaultValue: 'etonia_plan_2499_yearly',
          ),
        },
        iosProductIds: const <SubscriptionPlan, String>{
          SubscriptionPlan.starter699: String.fromEnvironment(
            'IAP_IOS_PLAN_699_ID',
            defaultValue: 'com.etonia.app.plan.699.monthly',
          ),
          SubscriptionPlan.pro1499: String.fromEnvironment(
            'IAP_IOS_PLAN_1499_ID',
            defaultValue: 'com.etonia.app.plan.1499.monthly',
          ),
          SubscriptionPlan.max2499: String.fromEnvironment(
            'IAP_IOS_PLAN_2499_ID',
            defaultValue: 'com.etonia.app.plan.2499.monthly',
          ),
        },
        iosYearlyProductIds: const <SubscriptionPlan, String>{
          SubscriptionPlan.starter699: String.fromEnvironment(
            'IAP_IOS_PLAN_699_YEARLY_ID',
            defaultValue: 'com.etonia.app.plan.699.yearly',
          ),
          SubscriptionPlan.pro1499: String.fromEnvironment(
            'IAP_IOS_PLAN_1499_YEARLY_ID',
            defaultValue: 'com.etonia.app.plan.1499.yearly',
          ),
          SubscriptionPlan.max2499: String.fromEnvironment(
            'IAP_IOS_PLAN_2499_YEARLY_ID',
            defaultValue: 'com.etonia.app.plan.2499.yearly',
          ),
        },
        debugPlan: const String.fromEnvironment('IAP_DEBUG_PLAN'),
      );

  static const Map<SubscriptionPlan, String> defaultAndroidProductIds =
      <SubscriptionPlan, String>{
        SubscriptionPlan.starter699: 'etonia_plan_699_monthly',
        SubscriptionPlan.pro1499: 'etonia_plan_1499_monthly',
        SubscriptionPlan.max2499: 'etonia_plan_2499_monthly',
      };

  static const Map<SubscriptionPlan, String> defaultAndroidYearlyProductIds =
      <SubscriptionPlan, String>{
        SubscriptionPlan.starter699: 'etonia_plan_699_yearly',
        SubscriptionPlan.pro1499: 'etonia_plan_1499_yearly',
        SubscriptionPlan.max2499: 'etonia_plan_2499_yearly',
      };

  static const Map<SubscriptionPlan, String> defaultIosProductIds =
      <SubscriptionPlan, String>{
        SubscriptionPlan.starter699: 'com.etonia.app.plan.699.monthly',
        SubscriptionPlan.pro1499: 'com.etonia.app.plan.1499.monthly',
        SubscriptionPlan.max2499: 'com.etonia.app.plan.2499.monthly',
      };

  static const Map<SubscriptionPlan, String> defaultIosYearlyProductIds =
      <SubscriptionPlan, String>{
        SubscriptionPlan.starter699: 'com.etonia.app.plan.699.yearly',
        SubscriptionPlan.pro1499: 'com.etonia.app.plan.1499.yearly',
        SubscriptionPlan.max2499: 'com.etonia.app.plan.2499.yearly',
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
        // Gemini 3.8 Flash introductory prices through December 31, 2026.
        AiModelId.flash: AiModelRate(inputPerKilo: 750, outputPerKilo: 3750),
        // Claude Opus 5.5: $4 / $20.
        AiModelId.opus: AiModelRate(inputPerKilo: 4000, outputPerKilo: 20000),
        // Gemini 4 Argon: $4 / $20, its price after the launch offer.
        AiModelId.argon: AiModelRate(inputPerKilo: 4000, outputPerKilo: 20000),
        // GPT-6 Astra: $10 / $50.
        AiModelId.astra: AiModelRate(inputPerKilo: 10000, outputPerKilo: 50000),
      };

  final Map<SubscriptionPlan, String> androidProductIds;
  final Map<SubscriptionPlan, String> androidYearlyProductIds;
  final Map<SubscriptionPlan, String> iosProductIds;
  final Map<SubscriptionPlan, String> iosYearlyProductIds;
  final Map<AiModelId, AiModelRate> rates;

  /// A plan's enum name, such as `pro1499`, granted on launch to a debug
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

  /// The store's product IDs for the platform and billing cycle.
  Map<SubscriptionPlan, String> productIdsFor(
    TargetPlatform platform, {
    BillingCycle cycle = BillingCycle.monthly,
  }) {
    final bool isApple =
        platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
    if (cycle == BillingCycle.yearly) {
      return isApple ? iosYearlyProductIds : androidYearlyProductIds;
    }
    return isApple ? iosProductIds : androidProductIds;
  }

  /// All known store product IDs across both monthly and yearly cycles.
  Set<String> allProductIdsFor(TargetPlatform platform) {
    return <String>{
      ...productIdsFor(platform, cycle: BillingCycle.monthly).values,
      ...productIdsFor(platform, cycle: BillingCycle.yearly).values,
    };
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
    this.freeCreditExpiresAt,
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
      freeCreditExpiresAt: DateTime.tryParse(
        json['freeCreditExpiresAt'] as String? ?? '',
      ),
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

  /// The free credit the server granted this account (the one-time credit and
  /// any gift codes), or 0. Only meaningful without an [activePlan];
  /// [remainingCreditsMicroUsd] is what is left of it.
  final int freeCreditMicroUsd;

  /// When the free credit ends, one month after it was last granted.
  final DateTime? freeCreditExpiresAt;

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
      freeCreditExpiresAt: freeCreditExpiresAt,
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
