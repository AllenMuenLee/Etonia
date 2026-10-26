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
  const ValueKey<String>('ai-model-selector'),
);
final Finder _pill = find.byKey(const ValueKey<String>('ai-credits-pill'));

String _shownModel(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey<String>('ai-model-label')))
    .data!;

/// The editor, with ink selected and the assistant open on a client that
/// serves every model, metered by [subscription].
Future<FakeAiModelRouter> _pumpOpen(
  WidgetTester tester,
  SubscriptionController subscription, {
  TestViewport viewport = TestViewport.tabletLandscape,
  Set<AiModelId> unconfigured = const <AiModelId>{},
}) async {
  final FakeAiModelRouter client = FakeAiModelRouter(
    unconfigured: unconfigured,
  );
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

Future<void> _choose(WidgetTester tester, AiModelId model) async {
  await tester.tap(_selector);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey<String>('ai-model-${model.name}')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the header shows the model, and every model is one tap away', (
    WidgetTester tester,
  ) async {
    final SubscriptionController plan = await loadedSubscription(
      plan: SubscriptionPlan.pro1499,
    );
    final FakeAiModelRouter client = await _pumpOpen(tester, plan);

    expect(_shownModel(tester), 'Sol');
    expect(tester.getSize(_selector).height, greaterThanOrEqualTo(48));
    await tester.tap(_selector);
    await tester.pumpAndSettle();
    for (final AiModelId model in AiModelId.values) {
      expect(
        find.byKey(ValueKey<String>('ai-model-${model.name}')),
        findsOneWidget,
      );
    }
    // Haiku and Luna are marked unlimited.
    expect(find.text('Unlimited'), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey<String>('ai-model-opus')));
    await tester.pumpAndSettle();

    expect(_shownModel(tester), 'Opus');
    expect(plan.preferredModel, AiModelId.opus);
    await tester.tap(find.text('Explain this'));
    await tester.pump();
    expect(client.requests.single.model, AiModelId.opus);
    expect(tester.takeException(), isNull);
  });

  testWidgets('on Starter, Opus, Argon, and Astra carry a lock and lead to '
      'the plans', (WidgetTester tester) async {
    final SubscriptionController plan = await loadedSubscription(
      plan: SubscriptionPlan.starter699,
    );
    await _pumpOpen(tester, plan);

    await tester.tap(_selector);
    await tester.pumpAndSettle();
    for (final AiModelId model in AiModelId.values) {
      final bool locked = <AiModelId>{
        AiModelId.opus,
        AiModelId.argon,
        AiModelId.astra,
      }.contains(model);
      expect(
        find.byKey(ValueKey<String>('ai-model-lock-${model.name}')),
        locked ? findsOneWidget : findsNothing,
        reason: model.name,
      );
    }
    await tester.tap(find.byKey(const ValueKey<String>('ai-model-astra')));
    await tester.pumpAndSettle();

    expect(find.byType(PaymentPage), findsOneWidget);
    expect(plan.preferredModel, isNull);
  });

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
    expect(
      find.descendant(
        of: _pill,
        matching: find.byKey(const ValueKey<String>('ai-token-bar')),
      ),
      findsOneWidget,
    );
    expect(tester.getSize(_pill).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(_pill).width, greaterThanOrEqualTo(48));

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

  testWidgets('out of credits, the failure offers the plans and a switch to '
      'an unlimited model that asks again', (WidgetTester tester) async {
    final SubscriptionController plan = await loadedSubscription(
      plan: SubscriptionPlan.starter699,
    );
    plan.recordUsage(
      AiModelId.sol,
      const AiTokenUsage(inputTokens: 100000000, outputTokens: 0),
    );
    final FakeAiModelRouter client = await _pumpOpen(tester, plan);

    await tester.tap(find.text('Explain this'));
    await tester.pumpAndSettle();
    expect(client.requests, isEmpty);
    expect(
      find.text(const AiFailure(AiFailureKind.insufficientCredits).message),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextButton, 'See plans'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Use Haiku'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Use Luna'));
    // Asked again at once; the answer is still on its way.
    await tester.pump();
    expect(_shownModel(tester), 'Luna');
    expect(client.requests.single.model, AiModelId.luna);
    client.answer('An answer.');
    await tester.pumpAndSettle();
    expect(find.text('An answer.'), findsOneWidget);
    expect(plan.remainingCreditsMicroUsd, 0);
  });

  testWidgets('a model without a key cannot be picked', (
    WidgetTester tester,
  ) async {
    final SubscriptionController plan = await loadedSubscription(
      plan: SubscriptionPlan.max2499,
    );
    await _pumpOpen(tester, plan, unconfigured: <AiModelId>{AiModelId.astra});
    await tester.tap(_selector);
    await tester.pumpAndSettle();
    expect(find.text('OpenAI · No API key'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('ai-model-astra')));
    await tester.pumpAndSettle();
    expect(_shownModel(tester), 'Sol');
  });

  for (final TestViewport viewport in TestViewport.values) {
    testWidgets('the header fits at ${viewport.name}', (
      WidgetTester tester,
    ) async {
      final SubscriptionController plan = await loadedSubscription(
        plan: SubscriptionPlan.max2499,
      );
      await _pumpOpen(tester, plan, viewport: viewport);
      await _choose(tester, AiModelId.astra);
      expect(_shownModel(tester), 'Astra');
      expect(
        find.descendant(of: _pill, matching: find.text('100% tokens')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
