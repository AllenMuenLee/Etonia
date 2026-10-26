import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/features/payment/in_app_purchase_gateway.dart';
import 'package:greatnote/features/payment/payment_models.dart';
import 'package:greatnote/features/payment/payment_page.dart';
import 'package:greatnote/features/payment/subscription_controller.dart';

import '../../helpers/payment_fakes.dart';
import '../../helpers/pump_app.dart';

Finder _card(SubscriptionPlan plan) =>
    find.byKey(ValueKey<String>('plan-${plan.name}'));

Finder _button(SubscriptionPlan plan) =>
    find.descendant(of: _card(plan), matching: find.byType(FilledButton));

String _balance(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey<String>('payment-credit-balance')))
    .data!;

/// The page on a store-backed controller, the store loaded.
Future<(SubscriptionController, FakeInAppPurchaseGateway)> _pumpPage(
  WidgetTester tester, {
  TestViewport viewport = TestViewport.tabletLandscape,
  ThemeMode themeMode = ThemeMode.light,
  FakeInAppPurchaseGateway? gateway,
  SubscriptionPlan? plan,
}) async {
  final FakeInAppPurchaseGateway store = gateway ?? FakeInAppPurchaseGateway();
  final SubscriptionController controller = SubscriptionController(
    store: InMemorySubscriptionStore(),
    gateway: store,
    platform: TargetPlatform.android,
  );
  addTearDown(controller.dispose);
  await controller.load();
  if (plan != null) {
    controller.activate(plan);
  }
  await pumpApp(
    tester,
    viewport: viewport,
    themeMode: themeMode,
    home: PaymentPage(controller: controller),
  );
  return (controller, store);
}

Future<void> _tapButton(WidgetTester tester, SubscriptionPlan plan) async {
  await tester.ensureVisible(_button(plan));
  await tester.pumpAndSettle();
  await tester.tap(_button(plan));
}

void main() {
  testWidgets('shows all three plans with their prices, tokens, and '
      'unlimited Haiku & Luna', (WidgetTester tester) async {
    await _pumpPage(tester);

    for (final (SubscriptionPlan plan, String price, String tokens)
        in <(SubscriptionPlan, String, String)>[
          (
            SubscriptionPlan.starter699,
            '\$6.99 / month',
            'AI tokens for Sonnet & Sol combined',
          ),
          (
            SubscriptionPlan.pro1499,
            '\$14.99 / month',
            'AI tokens for Sonnet, Sol, Opus, Argon & Astra combined',
          ),
          (
            SubscriptionPlan.max2499,
            '\$24.99 / month',
            'AI tokens for all models (Sonnet, Sol, Opus, Argon & '
                'Astra combined)',
          ),
        ]) {
      Finder inCard(Finder finder) =>
          find.descendant(of: _card(plan), matching: finder);
      expect(inCard(find.text(plan.title)), findsOneWidget);
      expect(inCard(find.text(price)), findsOneWidget);
      expect(inCard(find.text(tokens)), findsOneWidget);
      expect(
        inCard(
          find.byKey(ValueKey<String>('plan-token-comparison-${plan.name}')),
        ),
        findsOneWidget,
      );
      expect(inCard(find.text(plan.tokenComparisonText)), findsOneWidget);
      expect(inCard(find.text('Unlimited Haiku & Luna')), findsOneWidget);
      expect(inCard(find.text('Subscribe')), findsOneWidget);
    }
    // Starter locks the frontier models.
    expect(
      find.descendant(
        of: _card(SubscriptionPlan.starter699),
        matching: find.text('Opus · Locked'),
      ),
      findsOneWidget,
    );
    expect(find.text('No plan'), findsOneWidget);
    expect(find.text('AI tokens'), findsOneWidget);
    expect(_balance(tester), '0%');
    expect(
      find.byKey(const ValueKey<String>('payment-token-bar')),
      findsOneWidget,
    );
    expect(find.text('Restore Purchases'), findsOneWidget);
    expect(
      find.descendant(
        of: _card(SubscriptionPlan.pro1499),
        matching: find.byKey(const ValueKey<String>('pro-recommended')),
      ),
      findsOneWidget,
    );
    expect(find.text('Recommended'), findsOneWidget);
  });

  testWidgets('the localized store price is shown when the store gives one', (
    WidgetTester tester,
  ) async {
    await _pumpPage(
      tester,
      gateway: FakeInAppPurchaseGateway(
        prices: const <SubscriptionPlan, String>{
          SubscriptionPlan.starter699: '6,99 €',
          SubscriptionPlan.pro1499: '14,99 €',
          SubscriptionPlan.max2499: '24,99 €',
        },
      ),
    );
    expect(find.text('6,99 € / month'), findsOneWidget);
  });

  testWidgets('toggle switches between monthly and yearly billing', (
    WidgetTester tester,
  ) async {
    await _pumpPage(tester);

    expect(find.text('\$6.99 / month'), findsOneWidget);
    expect(find.text('\$14.99 / month'), findsOneWidget);
    expect(find.text('\$24.99 / month'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('billing-cycle-yearly')),
    );
    await tester.pumpAndSettle();

    expect(find.text('\$69.99 / year'), findsOneWidget);
    expect(find.text('\$149.99 / year'), findsOneWidget);
    expect(find.text('\$249.99 / year'), findsOneWidget);
  });

  for (final (SubscriptionPlan plan, String meter)
      in <(SubscriptionPlan, String)>[
        (SubscriptionPlan.starter699, '100%'),
        (SubscriptionPlan.pro1499, '100%'),
        (SubscriptionPlan.max2499, '100%'),
      ]) {
    testWidgets('buying ${plan.title} goes pending, then purchased, and '
        'fills the meter', (WidgetTester tester) async {
      final FakeInAppPurchaseGateway gateway = FakeInAppPurchaseGateway()
        ..autoComplete = false;
      final (SubscriptionController controller, _) = await _pumpPage(
        tester,
        gateway: gateway,
      );

      await _tapButton(tester, plan);
      await tester.pump();
      expect(
        gateway.bought.single.id,
        controller.config.androidProductIds[plan],
      );
      gateway.deliver(<StorePurchaseUpdate>[
        StorePurchaseUpdate(
          productId: gateway.bought.single.id,
          purchaseId: 'order-${plan.name}',
          status: StorePurchaseStatus.pending,
        ),
      ]);
      await tester.pump();
      expect(controller.activity, StoreActivity.purchasing);
      expect(find.text('Waiting for the store to confirm…'), findsOneWidget);
      expect(
        find.descendant(of: _card(plan), matching: find.text('Purchasing…')),
        findsOneWidget,
      );

      gateway.deliver(<StorePurchaseUpdate>[
        StorePurchaseUpdate(
          productId: gateway.bought.single.id,
          purchaseId: 'order-${plan.name}',
          status: StorePurchaseStatus.purchased,
          pendingCompletePurchase: true,
        ),
      ]);
      await tester.pumpAndSettle();

      expect(gateway.completed.single.purchaseId, 'order-${plan.name}');
      expect(controller.activePlan, plan);
      expect(_balance(tester), meter);
      expect(
        find.descendant(of: _card(plan), matching: find.text('Current Plan')),
        findsOneWidget,
      );
      expect(tester.widget<FilledButton>(_button(plan)).onPressed, isNull);
    });
  }

  testWidgets('a higher plan offers Upgrade and a lower one Switch Plan', (
    WidgetTester tester,
  ) async {
    await _pumpPage(tester, plan: SubscriptionPlan.pro1499);
    expect(
      find.descendant(
        of: _card(SubscriptionPlan.max2499),
        matching: find.text('Upgrade'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _card(SubscriptionPlan.starter699),
        matching: find.text('Switch Plan'),
      ),
      findsOneWidget,
    );
    expect(find.text('Pro · \$14.99 / month'), findsOneWidget);
  });

  testWidgets('Restore Purchases restores an earlier subscription', (
    WidgetTester tester,
  ) async {
    final FakeInAppPurchaseGateway gateway = FakeInAppPurchaseGateway()
      ..restorable = const <StorePurchaseUpdate>[
        StorePurchaseUpdate(
          productId: 'etonia_plan_1499_monthly',
          purchaseId: 'earlier',
          status: StorePurchaseStatus.restored,
          pendingCompletePurchase: true,
        ),
      ];
    final (SubscriptionController controller, _) = await _pumpPage(
      tester,
      gateway: gateway,
    );
    await tester.ensureVisible(find.text('Restore Purchases'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore Purchases'));
    await tester.pumpAndSettle();

    expect(gateway.restores, 1);
    expect(controller.activePlan, SubscriptionPlan.pro1499);
    expect(_balance(tester), '100%');
    expect(find.text('Restored your Pro plan.'), findsOneWidget);
    expect(gateway.completed.single.purchaseId, 'earlier');
  });

  testWidgets(
    'a cancelled purchase shows an inline error and changes nothing',
    (WidgetTester tester) async {
      final FakeInAppPurchaseGateway gateway = FakeInAppPurchaseGateway()
        ..autoComplete = false;
      final (SubscriptionController controller, _) = await _pumpPage(
        tester,
        gateway: gateway,
      );
      await _tapButton(tester, SubscriptionPlan.max2499);
      gateway.deliver(const <StorePurchaseUpdate>[
        StorePurchaseUpdate(
          productId: 'etonia_plan_2499_monthly',
          status: StorePurchaseStatus.canceled,
        ),
      ]);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('payment-error')),
        findsOneWidget,
      );
      expect(find.text('Purchase cancelled.'), findsOneWidget);
      expect(controller.activePlan, isNull);
    },
  );

  testWidgets('without a store the page says so', (WidgetTester tester) async {
    await _pumpPage(
      tester,
      gateway: FakeInAppPurchaseGateway(available: false),
    );
    expect(find.textContaining('store is not available'), findsOneWidget);
  });

  for (final TestViewport viewport in TestViewport.values) {
    for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
      testWidgets('fits at ${viewport.name} in ${mode.name} with high '
          'contrast and 48 px targets', (WidgetTester tester) async {
        await _pumpPage(
          tester,
          viewport: viewport,
          themeMode: mode,
          plan: SubscriptionPlan.starter699,
        );
        expect(tester.takeException(), isNull);

        // Side by side on tablets, stacked on phones.
        final Rect starter = tester.getRect(_card(SubscriptionPlan.starter699));
        final Rect pro = tester.getRect(_card(SubscriptionPlan.pro1499));
        if (viewport == TestViewport.compact) {
          expect(pro.top, greaterThan(starter.bottom));
        } else {
          expect(pro.top, starter.top);
          expect(pro.left, greaterThan(starter.right));
          expect(pro.height, starter.height);
        }

        final Finder restore = find.widgetWithText(
          OutlinedButton,
          'Restore Purchases',
        );
        expect(tester.getSize(restore).height, greaterThanOrEqualTo(48));
        final BuildContext context = tester.element(
          _card(SubscriptionPlan.pro1499),
        );
        final AppColors colors = AppColors.of(context);
        for (final SubscriptionPlan plan in SubscriptionPlan.values) {
          await tester.ensureVisible(_button(plan));
          await tester.pumpAndSettle();
          final Size size = tester.getSize(_button(plan));
          expect(size.height, greaterThanOrEqualTo(48));
          expect(size.width, greaterThanOrEqualTo(48));
          // Every word on a card is readable against its background.
          for (final Element element
              in find
                  .descendant(of: _card(plan), matching: find.byType(RichText))
                  .evaluate()) {
            final RichText text = element.widget as RichText;
            final Color? color = text.text.style?.color;
            if (color == null) {
              continue;
            }
            // Text in the paper colour, quieter or not, is on the ink card.
            final Color background =
                color.withValues(alpha: 1) == colors.onAccent
                ? colors.accent
                : colors.surface;
            expect(
              contrastRatio(Color.alphaBlend(color, background), background),
              greaterThanOrEqualTo(4.5),
              reason: '${text.text.toPlainText()} in ${plan.name}',
            );
          }
        }
        // Badges and chips sit on tinted fills.
        for (final Color fill in <Color>[
          Color.alphaBlend(colors.selected, colors.surface),
          colors.surfaceMuted,
        ]) {
          expect(
            contrastRatio(colors.textPrimary, fill),
            greaterThanOrEqualTo(4.5),
          );
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
