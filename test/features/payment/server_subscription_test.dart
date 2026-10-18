import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/ai_usage_gate.dart';
import 'package:greatnote/features/payment/account_panel.dart';
import 'package:greatnote/features/payment/billing_backend.dart';
import 'package:greatnote/features/payment/in_app_purchase_gateway.dart';
import 'package:greatnote/features/payment/payment_models.dart';
import 'package:greatnote/features/payment/plans_button.dart';
import 'package:greatnote/features/payment/subscription_controller.dart';

import '../../helpers/payment_fakes.dart';
import '../../helpers/pump_app.dart';

class TestBillingBackend extends BillingBackend {
  @override
  bool isConfigured = true;
  @override
  String? userId = 'user-1';
  @override
  String? get email => 'person@example.com';
  SubscriptionState result = SubscriptionState(
    activePlan: SubscriptionPlan.pro1299,
    remainingCreditsMicroUsd: 123456,
    expiresAt: DateTime.now().add(const Duration(days: 1)),
  );
  bool fail = false;
  Completer<SubscriptionState>? verification;
  @override
  Future<SubscriptionState> fetchSubscription() async {
    if (fail) throw StateError('unavailable');
    return userId == null ? const SubscriptionState() : result;
  }

  @override
  Future<SubscriptionState> verifyPurchase(StorePurchaseUpdate purchase) async {
    if (fail) throw StateError('unverified');
    return verification?.future ?? result;
  }

  int googleSignIns = 0;

  @override
  Future<void> signInWithGoogle() async {
    googleSignIns++;
    userId = 'user-google';
    notifyListeners();
  }

  @override
  Future<void> signOut() async {
    userId = null;
    notifyListeners();
  }
}

void main() {
  test('local balance and debug grants cannot override server state', () async {
    final backend = TestBillingBackend();
    final store = InMemorySubscriptionStore({
      'activePlan': 'max2999',
      'remainingCreditsMicroUsd': 999999999,
      'grantedPurchaseId': 'forged',
      'preferredModel': 'sol',
    });
    final controller = SubscriptionController(
      store: store,
      backend: backend,
      config: const PaymentConfig(debugPlan: 'max2999'),
    );
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.activePlan, SubscriptionPlan.pro1299);
    expect(controller.remainingCreditsMicroUsd, 123456);
    controller.activate(SubscriptionPlan.max2999, purchaseId: 'forged');
    expect(controller.activePlan, SubscriptionPlan.pro1299);
    controller.recordUsage(
      AiModelId.sol,
      const AiTokenUsage(inputTokens: 1000, outputTokens: 1000),
    );
    await pumpEventQueue();
    expect(controller.remainingCreditsMicroUsd, 123456);
    await controller.saved;
    expect(store.json, {'version': 1, 'preferredModel': 'sol'});
  });

  test('expiry, unavailable backend and sign-out fail closed', () async {
    final backend = TestBillingBackend();
    final controller = SubscriptionController(
      store: InMemorySubscriptionStore(),
      backend: backend,
    );
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.accessFor(AiModelId.sol), AiModelAccess.metered);
    backend.result = SubscriptionState(
      activePlan: SubscriptionPlan.pro1299,
      remainingCreditsMicroUsd: 5000000,
      expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
    );
    await controller.refresh();
    expect(controller.accessFor(AiModelId.haiku), AiModelAccess.noPlan);
    backend.fail = true;
    await controller.refresh();
    expect(controller.activePlan, isNull);
    expect(controller.remainingCreditsMicroUsd, 0);
    backend.fail = false;
    await backend.signOut();
    await pumpEventQueue();
    expect(controller.activePlan, isNull);
  });

  test(
    'the free one-time credit pays only for Haiku, Luna, Sonnet and Sol',
    () async {
      final backend = TestBillingBackend()
        ..result = const SubscriptionState(
          remainingCreditsMicroUsd: 500000,
          freeCreditMicroUsd: 500000,
        );
      final controller = SubscriptionController(
        store: InMemorySubscriptionStore(),
        backend: backend,
      );
      addTearDown(controller.dispose);
      await controller.load();
      expect(controller.activePlan, isNull);
      expect(controller.hasFreeCredit, isTrue);
      expect(controller.includedCreditsMicroUsd, 500000);
      expect(controller.accessFor(AiModelId.haiku), AiModelAccess.metered);
      expect(controller.accessFor(AiModelId.sol), AiModelAccess.metered);
      expect(controller.accessFor(AiModelId.opus), AiModelAccess.noPlan);
      expect(controller.creditsLabel, '\$0.50 left');
      expect(PlansButton.labelFor(controller), 'Free · \$0.50');

      backend.result = const SubscriptionState(freeCreditMicroUsd: 500000);
      await controller.refresh();
      expect(controller.accessFor(AiModelId.luna), AiModelAccess.outOfCredits);
      expect(controller.creditsLabel, 'Upgrade');
      expect(PlansButton.labelFor(controller), 'Plans');

      // Without a grant (anonymous device, or a device that already claimed it).
      backend.result = const SubscriptionState();
      await controller.refresh();
      expect(controller.hasFreeCredit, isFalse);
      expect(controller.accessFor(AiModelId.haiku), AiModelAccess.noPlan);
    },
  );

  test('server state parses the free credit', () {
    final state = SubscriptionState.fromJson(const <String, Object?>{
      'plan': 'free',
      'activePlan': null,
      'remainingCreditsMicroUsd': 120000,
      'freeCreditMicroUsd': 500000,
      'grantedPurchaseId': 'free:user-1',
    });
    expect(state.activePlan, isNull);
    expect(state.freeCreditMicroUsd, 500000);
    expect(
      state.copyWith(preferredModel: AiModelId.sol).freeCreditMicroUsd,
      500000,
    );
  });

  test(
    'purchase is not completed until durable server verification succeeds',
    () async {
      final backend = TestBillingBackend()
        ..verification = Completer<SubscriptionState>();
      final gateway = FakeInAppPurchaseGateway();
      final controller = SubscriptionController(
        store: InMemorySubscriptionStore(),
        backend: backend,
        gateway: gateway,
      );
      addTearDown(controller.dispose);
      addTearDown(gateway.close);
      await controller.load();
      await controller.connectStore();
      await controller.purchase(SubscriptionPlan.pro1299);
      await pumpEventQueue();
      expect(gateway.boundAccountId, backend.userId);
      expect(gateway.completed, isEmpty);
      backend.verification!.complete(backend.result);
      await pumpEventQueue();
      expect(gateway.completed, hasLength(1));
      expect(controller.remainingCreditsMicroUsd, 123456);
    },
  );

  test(
    'failed verification never acknowledges a purchase or grants credits',
    () async {
      final backend = TestBillingBackend()..fail = true;
      final gateway = FakeInAppPurchaseGateway();
      final controller = SubscriptionController(
        store: InMemorySubscriptionStore(),
        backend: backend,
        gateway: gateway,
      );
      addTearDown(controller.dispose);
      addTearDown(gateway.close);
      await controller.load();
      await controller.connectStore();
      await controller.purchase(SubscriptionPlan.pro1299);
      await pumpEventQueue();
      expect(gateway.completed, isEmpty);
      expect(controller.activePlan, isNull);
      expect(controller.errorMessage, contains('verify'));
    },
  );

  test('late verification cannot apply to another signed-in account', () async {
    final backend = TestBillingBackend()
      ..verification = Completer<SubscriptionState>();
    final gateway = FakeInAppPurchaseGateway();
    final controller = SubscriptionController(
      store: InMemorySubscriptionStore(),
      backend: backend,
      gateway: gateway,
    );
    addTearDown(controller.dispose);
    addTearDown(gateway.close);
    await controller.load();
    await controller.connectStore();
    await controller.purchase(SubscriptionPlan.pro1299);
    await pumpEventQueue();
    await backend.signOut();
    backend.verification!.complete(backend.result);
    await pumpEventQueue();
    expect(controller.activePlan, isNull);
    expect(gateway.completed, isEmpty);
    await controller.purchase(SubscriptionPlan.pro1299);
    expect(gateway.bought, hasLength(1));
  });

  testWidgets(
    'AccountPanel signs in directly with Google without email or Apple options',
    (WidgetTester tester) async {
      final backend = TestBillingBackend()..userId = null;
      final controller = SubscriptionController(
        store: InMemorySubscriptionStore(),
        backend: backend,
      );
      await controller.load();
      await pumpApp(
        tester,
        home: Scaffold(
          body: AccountPanel(backend: backend, controller: controller),
        ),
      );
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.text('Continue with Apple'), findsNothing);

      await tester.tap(find.byKey(const ValueKey<String>('sign-in-google')));
      await tester.pumpAndSettle();
      expect(backend.googleSignIns, 1);
      expect(backend.userId, 'user-google');
      expect(find.text('Sign out'), findsOneWidget);

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(backend.userId, isNull);
      controller.dispose();
    },
  );
}
