import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/backend/backend_service.dart' show BackendFailure;
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/ai_usage_gate.dart';
import 'package:greatnote/features/payment/account_page.dart';
import 'package:greatnote/features/payment/account_panel.dart';
import 'package:greatnote/features/payment/payment_models.dart';
import 'package:greatnote/features/payment/plans_button.dart';
import 'package:greatnote/features/payment/subscription_controller.dart';

import '../../helpers/payment_fakes.dart';
import '../../helpers/pump_app.dart';

void main() {
  test('local balance and debug grants cannot override server state', () async {
    final backend = TestBillingBackend();
    final store = InMemorySubscriptionStore({
      'activePlan': 'max2499',
      'remainingCreditsMicroUsd': 999999999,
      'grantedPurchaseId': 'forged',
      'preferredModel': 'sol',
    });
    final controller = SubscriptionController(
      store: store,
      backend: backend,
      config: const PaymentConfig(debugPlan: 'max2499'),
    );
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.activePlan, SubscriptionPlan.pro1499);
    expect(controller.remainingCreditsMicroUsd, 123456);
    controller.activate(SubscriptionPlan.max2499, purchaseId: 'forged');
    expect(controller.activePlan, SubscriptionPlan.pro1499);
    controller.recordUsage(
      AiModelId.sol,
      const AiTokenUsage(inputTokens: 1000, outputTokens: 1000),
    );
    await pumpEventQueue();
    expect(controller.remainingCreditsMicroUsd, 123456);
    await controller.saved;
    expect(store.json, {
      'version': 1,
      'preferredModel': 'sol',
      'routing': const AiRoutingPreferences().toJson(),
    });
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
      activePlan: SubscriptionPlan.pro1499,
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
    'the free one-time credit pays only for Haiku, Luna, Sonnet, Sol and Flash',
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
      expect(controller.creditsLabel, '100% tokens');
      expect(PlansButton.labelFor(controller), 'Free · 100%');

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

  test('a gift code adds free credit that lapses after its month', () async {
    final backend = TestBillingBackend()..result = const SubscriptionState();
    final controller = SubscriptionController(
      store: InMemorySubscriptionStore(),
      backend: backend,
    );
    addTearDown(controller.dispose);
    await controller.load();
    await controller.redeemGiftCode(' GIFT-123 ');
    expect(backend.redeemed, 'GIFT-123');
    expect(controller.hasFreeCredit, isTrue);
    expect(controller.remainingCreditsMicroUsd, 3500000);
    expect(controller.errorMessage, isNull);

    backend.redeemError = const BackendFailure('invalid_code');
    await controller.redeemGiftCode('nope');
    expect(controller.errorMessage, 'That gift code is not valid.');

    backend.result = SubscriptionState(
      remainingCreditsMicroUsd: 3500000,
      freeCreditMicroUsd: 3500000,
      freeCreditExpiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
    );
    await controller.refresh();
    expect(controller.remainingCreditsMicroUsd, 0);
    expect(controller.accessFor(AiModelId.haiku), AiModelAccess.outOfCredits);
  });

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
      await controller.purchase(SubscriptionPlan.pro1499);
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
      await controller.purchase(SubscriptionPlan.pro1499);
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
    await controller.purchase(SubscriptionPlan.pro1499);
    await pumpEventQueue();
    await backend.signOut();
    backend.verification!.complete(backend.result);
    await pumpEventQueue();
    expect(controller.activePlan, isNull);
    expect(gateway.completed, isEmpty);
    await controller.purchase(SubscriptionPlan.pro1499);
    expect(gateway.bought, hasLength(1));
  });

  testWidgets(
    'AccountPanel signs in directly with Google, with no email option and no '
    'Apple option off Apple devices',
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

  testWidgets('on Apple devices, Sign in with Apple is offered beside Google', (
    WidgetTester tester,
  ) async {
    final backend = TestBillingBackend()
      ..userId = null
      ..canSignInWithApple = true;
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
    expect(find.text('Continue with Google'), findsOneWidget);
    final Finder apple = find.byKey(const ValueKey<String>('sign-in-apple'));
    expect(apple, findsOneWidget);
    // At least as prominent as Google's, as Apple's guidelines require.
    expect(
      tester.getSize(apple).height,
      greaterThanOrEqualTo(
        tester
            .getSize(find.byKey(const ValueKey<String>('sign-in-google')))
            .height,
      ),
    );

    await tester.tap(apple);
    await tester.pumpAndSettle();
    expect(backend.appleSignIns, 1);
    expect(find.text('Signed in with Apple'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('deleting the account asks first, then deletes it', (
    WidgetTester tester,
  ) async {
    final backend = TestBillingBackend();
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
    final Finder delete = find.byKey(const ValueKey<String>('delete-account'));

    // Cancelling keeps the account.
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(find.text('Delete your account?'), findsOneWidget);
    expect(
      find.textContaining('Notes on this device are kept'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(backend.deletions, 0);
    expect(backend.userId, isNotNull);

    // A failure says so and leaves the account signed in.
    backend.deleteError = StateError('offline');
    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete account'));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not delete your account. Please try again.'),
      findsOneWidget,
    );
    expect(backend.userId, isNotNull);

    backend.deleteError = null;
    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete account'));
    await tester.pumpAndSettle();
    expect(backend.deletions, 1);
    expect(backend.userId, isNull);
    expect(find.text('Your account was deleted'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    controller.dispose();
  });

  for (final TestViewport viewport in <TestViewport>[
    TestViewport.compact,
    TestViewport.tabletLandscape,
  ]) {
    testWidgets(
      'the account page splits the profile, subscription and backup into tabs at '
      '${viewport.name}',
      (WidgetTester tester) async {
        final backend = TestBillingBackend();
        final controller = SubscriptionController(
          store: InMemorySubscriptionStore(),
          backend: backend,
        );
        await controller.load();
        await pumpApp(
          tester,
          viewport: viewport,
          home: AccountPage(
            controller: controller,
            backup: const Text('backup section'),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.text('person@example.com'), findsOneWidget);
        for (final String tab in <String>[
          'Profile',
          'Subscription',
          'Backup',
        ]) {
          expect(find.text(tab), findsOneWidget);
        }

        await tester.tap(
          find.byKey(const ValueKey<String>('account-tab-subscription')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Pro · \$14.99 / month'), findsOneWidget);
        expect(find.text('person@example.com'), findsNothing);
        // Every plan is listed here, not one tap away.
        for (final SubscriptionPlan plan in SubscriptionPlan.values) {
          final Finder card = find.byKey(ValueKey<String>('plan-${plan.name}'));
          await tester.ensureVisible(card);
          expect(card, findsOneWidget);
        }
        // App Review requires a way to restore purchases beside the plans.
        await tester.ensureVisible(find.text('Restore Purchases'));
        expect(find.text('Restore Purchases'), findsOneWidget);

        await tester.tap(
          find.byKey(const ValueKey<String>('account-tab-backup')),
        );
        await tester.pumpAndSettle();
        expect(find.text('backup section'), findsOneWidget);
        expect(
          find.byKey(const ValueKey<String>('plan-pro1499')),
          findsNothing,
        );
        controller.dispose();
      },
    );
  }

  testWidgets('the account page without a backup section says so', (
    WidgetTester tester,
  ) async {
    final backend = TestBillingBackend()..userId = null;
    final controller = SubscriptionController(
      store: InMemorySubscriptionStore(),
      backend: backend,
    );
    await controller.load();
    await pumpApp(tester, home: AccountPage(controller: controller));
    expect(find.text('Continue with Google'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('account-tab-backup')));
    await tester.pumpAndSettle();
    expect(find.text('Backup is not available in this build.'), findsOneWidget);
    controller.dispose();
  });
}
