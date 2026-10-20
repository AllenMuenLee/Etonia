import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_assistant_controller.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/ai_usage_gate.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/payment/in_app_purchase_gateway.dart';
import 'package:greatnote/features/payment/payment_models.dart';
import 'package:greatnote/features/payment/subscription_controller.dart';

import '../../helpers/ai_fakes.dart';
import '../../helpers/payment_fakes.dart';

const Set<AiModelId> _unlimited = <AiModelId>{AiModelId.haiku, AiModelId.luna};
const Set<AiModelId> _metered = <AiModelId>{
  AiModelId.sonnet,
  AiModelId.sol,
  AiModelId.opus,
  AiModelId.argon,
  AiModelId.astra,
};

/// Far more than any plan's credits.
const AiTokenUsage _huge = AiTokenUsage(
  inputTokens: 10000000,
  outputTokens: 10000000,
);

const AiTokenUsage _turn = AiTokenUsage(inputTokens: 1000, outputTokens: 1000);

void main() {
  group('plans', () {
    test('Starter: unlimited Haiku and Luna, \$1.20 for Sonnet and Sol, the '
        'rest locked', () async {
      final SubscriptionController plan = await loadedSubscription(
        plan: SubscriptionPlan.starter499,
      );
      expect(plan.remainingCreditsMicroUsd, 1200000);
      expect(plan.includedCreditsMicroUsd, 1200000);
      for (final AiModelId model in _unlimited) {
        expect(plan.accessFor(model), AiModelAccess.unlimited);
        expect(plan.checkAccess(model), isNull);
        plan.recordUsage(model, _turn);
      }
      // \$0 for any number of unlimited turns.
      expect(plan.remainingCreditsMicroUsd, 1200000);
      for (final AiModelId model in <AiModelId>[
        AiModelId.sonnet,
        AiModelId.sol,
      ]) {
        expect(plan.accessFor(model), AiModelAccess.metered);
        expect(plan.checkAccess(model), isNull);
      }
      for (final AiModelId model in <AiModelId>[
        AiModelId.opus,
        AiModelId.argon,
        AiModelId.astra,
      ]) {
        expect(plan.accessFor(model), AiModelAccess.locked);
        expect(plan.checkAccess(model)?.kind, AiFailureKind.planRequired);
      }
      expect(SubscriptionPlan.starter499.lockedModels, <AiModelId>{
        AiModelId.opus,
        AiModelId.argon,
        AiModelId.astra,
      });
      expect(plan.creditsLabel, '100% tokens');
      expect(plan.tokenFraction, 1.0);
    });

    for (final (SubscriptionPlan tier, int credits, String label)
        in <(SubscriptionPlan, int, String)>[
          (SubscriptionPlan.pro1299, 5000000, '100% tokens'),
          (SubscriptionPlan.max2999, 15000000, '100% tokens'),
        ]) {
      test('${tier.title}: unlimited Haiku and Luna, $label across all five '
          'metered models', () async {
        final SubscriptionController plan = await loadedSubscription(
          plan: tier,
        );
        expect(plan.remainingCreditsMicroUsd, credits);
        expect(plan.creditsLabel, label);
        expect(tier.lockedModels, isEmpty);
        for (final AiModelId model in _unlimited) {
          expect(plan.accessFor(model), AiModelAccess.unlimited);
        }
        for (final AiModelId model in _metered) {
          expect(plan.accessFor(model), AiModelAccess.metered);
          expect(plan.checkAccess(model), isNull);
        }
        // One pool: a turn on any of them draws on the same balance.
        plan.recordUsage(AiModelId.opus, _turn);
        plan.recordUsage(AiModelId.astra, _turn);
        expect(
          plan.remainingCreditsMicroUsd,
          credits - 24000 /* Opus */ - 60000 /* Astra */,
        );
      });
    }

    test('without a plan every model needs one', () async {
      final SubscriptionController none = await loadedSubscription();
      for (final AiModelId model in AiModelId.values) {
        expect(none.accessFor(model), AiModelAccess.noPlan);
        expect(none.checkAccess(model)?.kind, AiFailureKind.planRequired);
      }
      expect(none.creditsLabel, 'Upgrade');
    });
  });

  group('metering', () {
    test('cost follows the per-model token rates, in micro-dollars', () {
      const PaymentConfig config = PaymentConfig();
      // Sonnet 5.5: \$2 in, \$10 out per million tokens.
      expect(config.costOf(AiModelId.sonnet, _turn), 12000);
      // GPT-6 Astra: $10 in, $50 out.
      expect(config.costOf(AiModelId.astra, _turn), 60000);
      // Rounded up, never down to free.
      expect(
        config.costOf(
          AiModelId.luna,
          const AiTokenUsage(inputTokens: 1, outputTokens: 0),
        ),
        1,
      );
      expect(formatUsd(1200000), '\$1.20');
      expect(formatUsd(1199999), '\$1.19');
      expect(formatUsd(15000000), '\$15.00');
      expect(formatTokenPercent(1200000, 1200000), '100%');
      expect(formatTokenPercent(1199999, 1200000), '99%');
      expect(formatTokenPercent(1, 15000000), '1%');
      expect(formatTokenPercent(0, 15000000), '0%');
    });

    test('spent credits stop metered models but never Haiku or Luna', () async {
      final SubscriptionController plan = await loadedSubscription(
        plan: SubscriptionPlan.max2999,
      );
      plan.recordUsage(AiModelId.sonnet, _huge);
      // Clamped at zero.
      expect(plan.remainingCreditsMicroUsd, 0);
      expect(plan.creditsLabel, 'Upgrade');
      for (final AiModelId model in _metered) {
        expect(plan.accessFor(model), AiModelAccess.outOfCredits);
        expect(
          plan.checkAccess(model)?.kind,
          AiFailureKind.insufficientCredits,
        );
      }
      for (final AiModelId model in _unlimited) {
        expect(plan.checkAccess(model), isNull);
        plan.recordUsage(model, _huge);
      }
      expect(plan.remainingCreditsMicroUsd, 0);
    });

    test('the assistant refuses a locked model without sending, and charges '
        'a metered answer', () async {
      final SubscriptionController plan = await loadedSubscription(
        plan: SubscriptionPlan.starter499,
      );
      final FakeAiModelRouter client = FakeAiModelRouter();
      final InkController ink = InkController(
        strokes: <Stroke>[
          Stroke.fromPoints(
            style: const StrokeStyle(ink: InkPalette.ink, width: 4),
            points: const <InkVector>[InkVector(100, 100), InkVector(200, 100)],
          ),
        ],
      );
      final AiAssistantController assistant = AiAssistantController(
        client: client,
        renderer: FakeSelectionImageRenderer(),
        usageGate: plan,
      );
      addTearDown(() {
        assistant.dispose();
        ink.dispose();
      });
      assistant.open(
        selectInk(ink, const Rect.fromLTRB(90, 90, 210, 110)),
        brightness: Brightness.light,
        background: Colors.white,
      );
      await pumpEventQueue();

      assistant.selectModel(AiModelId.opus);
      expect(plan.preferredModel, AiModelId.opus);
      expect(assistant.send('Hello'), isTrue);
      await pumpEventQueue();
      expect(client.requests, isEmpty);
      expect(assistant.failure?.kind, AiFailureKind.planRequired);

      // Switching to an unlimited model and asking again goes through free.
      assistant.selectModel(AiModelId.haiku);
      expect(assistant.retry(), isTrue);
      await pumpEventQueue();
      expect(client.requests.single.model, AiModelId.haiku);
      client.complete(const AiSuccess('Hi.', usage: _turn));
      await pumpEventQueue();
      expect(plan.remainingCreditsMicroUsd, 1200000);

      assistant.selectModel(AiModelId.sonnet);
      expect(assistant.send('More'), isTrue);
      await pumpEventQueue();
      expect(client.requests.last.model, AiModelId.sonnet);
      client.complete(const AiSuccess('More.', usage: _turn));
      await pumpEventQueue();
      expect(plan.remainingCreditsMicroUsd, 1200000 - 12000);

      // Without reported usage, a deterministic estimate is charged.
      expect(assistant.send('Again'), isTrue);
      await pumpEventQueue();
      final AiRequest request = client.requests.last;
      client.answer('Again.');
      await pumpEventQueue();
      final AiTokenUsage estimate = AiTokenUsage.estimate(request, 'Again.');
      expect(estimate.estimated, isTrue);
      expect(
        plan.remainingCreditsMicroUsd,
        1200000 - 12000 - plan.config.costOf(AiModelId.sonnet, estimate),
      );
    });
  });

  group('purchases and persistence', () {
    test('upgrading replaces the plan and grants its credits, and survives a '
        'reload', () async {
      final InMemorySubscriptionStore store = InMemorySubscriptionStore();
      final SubscriptionController first = await loadedSubscription(
        store: store,
        plan: SubscriptionPlan.starter499,
      );
      first.recordUsage(AiModelId.sol, _turn);
      first.activate(SubscriptionPlan.pro1299, purchaseId: 'order-2');
      first.setPreferredModel(AiModelId.argon);
      await first.saved;

      final SubscriptionController reloaded = await loadedSubscription(
        store: store,
      );
      expect(reloaded.activePlan, SubscriptionPlan.pro1299);
      expect(reloaded.remainingCreditsMicroUsd, 5000000);
      expect(reloaded.preferredModel, AiModelId.argon);
      expect(reloaded.accessFor(AiModelId.argon), AiModelAccess.metered);
    });

    test(
      'a purchase completes, activates its plan, and grants credits',
      () async {
        final FakeInAppPurchaseGateway gateway = FakeInAppPurchaseGateway();
        final SubscriptionController plan = SubscriptionController(
          store: InMemorySubscriptionStore(),
          gateway: gateway,
          platform: TargetPlatform.android,
        );
        await plan.load();
        await plan.connectStore();
        expect(plan.storeAvailable, isTrue);
        expect(plan.priceFor(SubscriptionPlan.pro1299), '\$12.99 / month');

        final List<StoreActivity> seen = <StoreActivity>[];
        plan.addListener(() => seen.add(plan.activity));
        await plan.purchase(SubscriptionPlan.pro1299);
        await pumpEventQueue();

        expect(seen, contains(StoreActivity.purchasing));
        expect(plan.activity, StoreActivity.idle);
        expect(plan.activePlan, SubscriptionPlan.pro1299);
        expect(plan.remainingCreditsMicroUsd, 5000000);
        expect(gateway.completed.single.purchaseId, 'order-1');
      },
    );

    test(
      'restoring the same purchase again does not grant credits twice',
      () async {
        final FakeInAppPurchaseGateway gateway = FakeInAppPurchaseGateway()
          ..restorable = const <StorePurchaseUpdate>[
            StorePurchaseUpdate(
              productId: 'etonia_plan_499_monthly',
              purchaseId: 'old-1',
              status: StorePurchaseStatus.restored,
            ),
            StorePurchaseUpdate(
              productId: 'etonia_plan_2999_monthly',
              purchaseId: 'old-2',
              status: StorePurchaseStatus.restored,
              pendingCompletePurchase: true,
            ),
          ];
        final SubscriptionController plan = SubscriptionController(
          store: InMemorySubscriptionStore(),
          gateway: gateway,
          platform: TargetPlatform.android,
        );
        await plan.load();
        await plan.connectStore();
        await plan.restorePurchases();
        await pumpEventQueue();
        // The highest plan delivered is the one in force.
        expect(plan.activePlan, SubscriptionPlan.max2999);
        expect(plan.remainingCreditsMicroUsd, 15000000);
        expect(plan.notice, contains('Restored'));
        expect(gateway.completed.single.purchaseId, 'old-2');

        plan.recordUsage(AiModelId.opus, _turn);
        await plan.restorePurchases();
        await pumpEventQueue();
        expect(plan.remainingCreditsMicroUsd, 15000000 - 24000);
      },
    );

    test('a cancelled purchase leaves the plan alone and says so', () async {
      final FakeInAppPurchaseGateway gateway = FakeInAppPurchaseGateway()
        ..autoComplete = false;
      final SubscriptionController plan = SubscriptionController(
        store: InMemorySubscriptionStore(),
        gateway: gateway,
        platform: TargetPlatform.android,
      );
      await plan.load();
      await plan.connectStore();
      await plan.purchase(SubscriptionPlan.starter499);
      gateway.deliver(const <StorePurchaseUpdate>[
        StorePurchaseUpdate(
          productId: 'etonia_plan_499_monthly',
          status: StorePurchaseStatus.canceled,
        ),
      ]);
      await pumpEventQueue();
      expect(plan.activePlan, isNull);
      expect(plan.activity, StoreActivity.idle);
      expect(plan.errorMessage, 'Purchase cancelled.');
    });

    test('iOS uses the App Store product IDs', () {
      final SubscriptionController plan = SubscriptionController(
        store: InMemorySubscriptionStore(),
        platform: TargetPlatform.iOS,
      );
      expect(
        plan.planForProduct('com.etonia.app.plan.1299.monthly'),
        SubscriptionPlan.pro1299,
      );
      expect(plan.planForProduct('etonia_plan_1299_monthly'), isNull);
    });

    test('the file store keeps the subscription beside the library', () async {
      final Directory directory = await Directory.systemTemp.createTemp(
        'greatnote_subscription',
      );
      addTearDown(() => directory.delete(recursive: true));
      final File file = File('${directory.path}/subscription.json');
      final SubscriptionController first = SubscriptionController(
        store: FileSubscriptionStore(file),
      );
      await first.load();
      first.activate(SubscriptionPlan.starter499);
      await first.saved;

      final SubscriptionController second = SubscriptionController(
        store: FileSubscriptionStore(file),
      );
      await second.load();
      expect(second.activePlan, SubscriptionPlan.starter499);
      expect(second.remainingCreditsMicroUsd, 1200000);
    });
  });
}
