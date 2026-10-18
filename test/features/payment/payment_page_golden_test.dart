@Tags(<String>['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/payment/payment_models.dart';
import 'package:greatnote/features/payment/payment_page.dart';
import 'package:greatnote/features/payment/subscription_controller.dart';

import '../../helpers/payment_fakes.dart';
import '../../helpers/pump_app.dart';

Future<void> _pumpPlans(WidgetTester tester, ThemeMode themeMode) async {
  final SubscriptionController controller = SubscriptionController(
    store: InMemorySubscriptionStore(),
    gateway: FakeInAppPurchaseGateway(),
    platform: TargetPlatform.android,
  );
  addTearDown(controller.dispose);
  await controller.load();
  controller.activate(SubscriptionPlan.pro1299);
  setViewportSize(tester, TestViewport.tabletLandscape.size);
  await tester.pumpWidget(
    GreatnoteApp(
      themeMode: themeMode,
      home: PaymentPage(controller: controller),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final (String name, ThemeMode themeMode) in <(String, ThemeMode)>[
    ('light', ThemeMode.light),
    ('dark', ThemeMode.dark),
  ]) {
    testWidgets('plans: tablet landscape $name', (WidgetTester tester) async {
      await _pumpPlans(tester, themeMode);
      await expectLater(
        find.byType(GreatnoteApp),
        matchesGoldenFile('goldens/payment_plans_tablet_landscape_$name.png'),
      );
    });
  }
}
