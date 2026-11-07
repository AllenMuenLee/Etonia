import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/payment/payment_models.dart';
import 'package:greatnote/features/payment/payment_page.dart';
import 'package:greatnote/features/payment/subscription_controller.dart';

import '../../helpers/ai_fakes.dart';
import '../../helpers/editor_harness.dart';
import '../../helpers/payment_fakes.dart';
import '../../helpers/pump_app.dart';

Stroke _line(double y) {
  return Stroke.fromPoints(
    style: const StrokeStyle(ink: InkPalette.ink, width: 4),
    points: <InkVector>[
      for (double x = 120; x <= 220; x += 20) InkVector(x, y),
    ],
  );
}

final Finder _selector = find.byKey(
  const ValueKey<String>('ai-thinking-selector'),
);
final Finder _pill = find.byKey(const ValueKey<String>('ai-credits-pill'));

String _shown(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey<String>('ai-thinking-label')))
    .data!;

/// The editor, with ink selected and the assistant open on a client that
/// chooses its own model, metered by [subscription].
Future<FakeAiModelRouter> _pumpOpen(
  WidgetTester tester,
  SubscriptionController subscription, {
  TestViewport viewport = TestViewport.tabletLandscape,
}) async {
  final FakeAiModelRouter client = FakeAiModelRouter()..routes = true;
  final InkController controller = await pumpEditor(
    tester,
    viewport: viewport,
    strokes: <Stroke>[_line(200), _line(240)],
    aiClient: client,
    subscription: subscription,
  );
  await tester.tap(find.byTooltip('Select'));
  await tester.pumpAndSettle();
  selectInk(controller, const Rect.fromLTRB(100, 170, 240, 270));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('AI assistant'));
  await tester.pumpAndSettle();
  await settleAi(tester);
  return client;
}

Future<void> _openAdvanced(WidgetTester tester) async {
  await tester.tap(_selector);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey<String>('ai-thinking-advanced')));
  await tester.pumpAndSettle();
}

/// Flips the switch [key] in the Advanced dialog.
Future<void> _toggle(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey<String>(key)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the header shows Thinking: Auto, and a level is one tap away', (
    WidgetTester tester,
  ) async {
    final SubscriptionController plan = await loadedSubscription(
      plan: SubscriptionPlan.pro1499,
    );
    final FakeAiModelRouter client = await _pumpOpen(tester, plan);

    expect(_shown(tester), 'Thinking: Auto');
    expect(
      find.byKey(const ValueKey<String>('ai-model-selector')),
      findsNothing,
    );
    expect(tester.getSize(_selector).height, greaterThanOrEqualTo(48));
    await tester.tap(_selector);
    await tester.pumpAndSettle();
    for (final AiEffort effort in AiEffort.values) {
      expect(
        find.byKey(ValueKey<String>('ai-thinking-${effort.name}')),
        findsOneWidget,
      );
    }
    await tester.tap(find.byKey(const ValueKey<String>('ai-thinking-high')));
    await tester.pumpAndSettle();

    expect(_shown(tester), 'Thinking: High');
    expect(plan.routing.effort, AiEffort.high);
    await tester.tap(find.text('Explain this'));
    await tester.pump();
    final AiRequest request = client.requests.single;
    // The app names no model: the server chooses.
    expect(request.model, isNull);
    expect(request.routing!.task, AiRouteTask.editorAnswer);
    expect(request.routing!.effort, AiEffort.high);
    expect(request.routing!.allowedModels, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Advanced turns off a provider, or one model, for good', (
    WidgetTester tester,
  ) async {
    final SubscriptionController plan = await loadedSubscription(
      plan: SubscriptionPlan.pro1499,
    );
    final FakeAiModelRouter client = await _pumpOpen(tester, plan);

    await _openAdvanced(tester);
    expect(
      find.byKey(const ValueKey<String>('ai-advanced-settings')),
      findsOneWidget,
    );
    await _toggle(tester, 'ai-provider-gemini');
    await _toggle(tester, 'ai-model-luna');
    expect(plan.routing.disabledModels, <AiModelId>{
      AiModelId.argon,
      AiModelId.luna,
    });
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Explain this'));
    await tester.pump();
    expect(client.requests.single.routing!.allowedModels, <AiModelId>{
      AiModelId.haiku,
      AiModelId.sonnet,
      AiModelId.sol,
      AiModelId.opus,
      AiModelId.astra,
    });
  });

  testWidgets('every model off says so, and sends nothing', (
    WidgetTester tester,
  ) async {
    final SubscriptionController plan = await loadedSubscription(
      plan: SubscriptionPlan.pro1499,
    );
    final FakeAiModelRouter client = await _pumpOpen(tester, plan);
    for (final AiProvider provider in AiProvider.values) {
      plan.setRouting(plan.routing.withProvider(provider, enabled: false));
    }
    await tester.pumpAndSettle();

    await tester.tap(find.text('Explain this'));
    await tester.pumpAndSettle();
    expect(client.requests, isEmpty);
    expect(
      find.text(const AiFailure(AiFailureKind.noModelEnabled).message),
      findsOneWidget,
    );
  });

  testWidgets('the model used is shown only when the user asks', (
    WidgetTester tester,
  ) async {
    final SubscriptionController plan = await loadedSubscription(
      plan: SubscriptionPlan.pro1499,
    );
    final FakeAiModelRouter client = await _pumpOpen(tester, plan);

    await tester.tap(find.text('Explain this'));
    await tester.pump();
    client.complete(const AiSuccess('Done.', servedBy: AiModelId.luna));
    await tester.pumpAndSettle();
    expect(_shown(tester), 'Thinking: Auto');

    plan.setRouting(plan.routing.copyWith(showModelUsed: true));
    await tester.pumpAndSettle();
    expect(_shown(tester), 'Thinking: Auto · Luna');
  });

  testWidgets('a paid plan out of credits carries on without saying so', (
    WidgetTester tester,
  ) async {
    final SubscriptionController plan = await loadedSubscription(
      plan: SubscriptionPlan.starter699,
    );
    plan.recordUsage(
      AiModelId.sol,
      const AiTokenUsage(inputTokens: 100000000, outputTokens: 0),
    );
    final FakeAiModelRouter client = await _pumpOpen(tester, plan);

    await tester.tap(find.text('Explain this'));
    await tester.pump();
    // Sent, not refused: the server answers on an unlimited model.
    expect(client.requests, hasLength(1));
    client.complete(const AiSuccess('An answer.', servedBy: AiModelId.haiku));
    await tester.pumpAndSettle();
    expect(find.text('An answer.'), findsOneWidget);
    expect(
      find.text(const AiFailure(AiFailureKind.insufficientCredits).message),
      findsNothing,
    );
    expect(plan.remainingCreditsMicroUsd, 0);
  });

  testWidgets(
    'a free plan with its credit spent is refused, and offered plans',
    (WidgetTester tester) async {
      final TestBillingBackend backend = TestBillingBackend()
        ..result = SubscriptionState(
          freeCreditMicroUsd: 500000,
          freeCreditExpiresAt: DateTime.now().add(const Duration(days: 20)),
        );
      final SubscriptionController plan = SubscriptionController(
        store: InMemorySubscriptionStore(),
        backend: backend,
      );
      addTearDown(plan.dispose);
      await plan.load();
      final FakeAiModelRouter client = await _pumpOpen(tester, plan);

      await tester.tap(find.text('Explain this'));
      await tester.pumpAndSettle();
      expect(client.requests, isEmpty);
      expect(
        find.text(const AiFailure(AiFailureKind.insufficientCredits).message),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextButton, 'See plans'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Use Haiku'), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, 'See plans'));
      await tester.pumpAndSettle();
      expect(find.byType(PaymentPage), findsOneWidget);
    },
  );

  testWidgets('the credits pill shows the balance and opens the plans', (
    WidgetTester tester,
  ) async {
    final SubscriptionController plan = await loadedSubscription(
      plan: SubscriptionPlan.starter699,
    );
    await _pumpOpen(tester, plan);

    expect(
      find.descendant(of: _pill, matching: find.text('100% tokens')),
      findsOneWidget,
    );
    expect(tester.getSize(_pill).height, greaterThanOrEqualTo(48));
    plan.recordUsage(
      AiModelId.sol,
      const AiTokenUsage(inputTokens: 100000000, outputTokens: 0),
    );
    await tester.pump();
    expect(
      find.descendant(of: _pill, matching: find.text('Upgrade')),
      findsOneWidget,
    );
    await tester.tap(_pill);
    await tester.pumpAndSettle();
    expect(find.byType(PaymentPage), findsOneWidget);
  });

  test('what the user chose survives a restart', () async {
    final InMemorySubscriptionStore store = InMemorySubscriptionStore();
    final SubscriptionController first = await loadedSubscription(store: store);
    first.setRouting(
      const AiRoutingPreferences(
        effort: AiEffort.low,
        disabledModels: <AiModelId>{AiModelId.argon},
        showModelUsed: true,
      ),
    );
    await first.saved;

    final SubscriptionController second = await loadedSubscription(
      store: store,
    );
    expect(second.routing.effort, AiEffort.low);
    expect(second.routing.disabledModels, <AiModelId>{AiModelId.argon});
    expect(second.routing.showModelUsed, isTrue);
  });

  for (final TestViewport viewport in TestViewport.values) {
    testWidgets('the header fits at ${viewport.name}', (
      WidgetTester tester,
    ) async {
      final SubscriptionController plan = await loadedSubscription(
        plan: SubscriptionPlan.max2499,
      );
      await _pumpOpen(tester, plan, viewport: viewport);
      await tester.tap(_selector);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('ai-thinking-medium')),
      );
      await tester.pumpAndSettle();
      expect(_shown(tester), 'Thinking: Medium');
      expect(
        find.descendant(of: _pill, matching: find.text('100% tokens')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
