import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/notation_playback.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/widgets/ai_assistant_panel.dart';
import 'package:greatnote/features/editor/widgets/editor_settings_sheet.dart';

import '../../helpers/ai_fakes.dart';
import '../../helpers/pump_app.dart';

Stroke _line() => Stroke.fromPoints(
  style: const StrokeStyle(ink: InkPalette.ink, width: 4),
  points: const <InkVector>[InkVector(100, 100), InkVector(200, 100)],
);

Future<(InkController, FakeAiClient)> _open(WidgetTester tester) async {
  final FakeAiClient client = FakeAiClient();
  final FakeNoteImageRenderer noteRenderer = FakeNoteImageRenderer();
  final InkController controller = InkController(strokes: <Stroke>[_line()]);
  addTearDown(controller.dispose);
  await pumpApp(
    tester,
    home: EditorScreen(
      inkController: controller,
      aiClient: client,
      noteImageRenderer: noteRenderer,
    ),
  );
  await tester.tap(find.byTooltip('Select'));
  selectInk(controller, const Rect.fromLTRB(80, 80, 220, 120));
  await tester.pump();
  await tester.tap(find.byTooltip('AI assistant'));
  await tester.pumpAndSettle();
  await settleAi(tester);
  return (controller, client);
}

AiAssistantResponse _notation() {
  return AiAssistantResponse(
    message: 'I added a handwritten mark.',
    notation: AiNotation(
      label: 'Blue teaching mark',
      items: <AiNotationItem>[
        AiNotationStroke(
          ink: 'blue',
          width: 3,
          points: const <AiNotationPoint>[
            AiNotationPoint(0.45, 0.45),
            AiNotationPoint(0.50, 0.50),
          ],
        ),
        AiNotationStroke(
          ink: 'blue',
          width: 3,
          points: const <AiNotationPoint>[AiNotationPoint(0.55, 0.50)],
        ),
      ],
    ),
  );
}

AiAssistantResponse _animatedNotation() {
  return AiAssistantResponse(
    message: 'I showed the current moving through the path.',
    notation: AiNotation(
      label: 'Current flow',
      items: <AiNotationItem>[
        AiNotationStroke(
          ink: 'blue',
          width: 3,
          points: const <AiNotationPoint>[
            AiNotationPoint(0.35, 0.40),
            AiNotationPoint(0.45, 0.50),
            AiNotationPoint(0.55, 0.40),
          ],
        ),
      ],
      timeline: AiNotationTimeline(
        durationMs: 1200,
        items: const <AiItemTiming>[AiItemTiming(0, 1000)],
      ),
    ),
  );
}

Future<void> _sendAnimatedNotation(
  WidgetTester tester,
  FakeAiClient client,
) async {
  final AiAssistantPanel panel = tester.widget<AiAssistantPanel>(
    find.byType(AiAssistantPanel),
  );
  panel.controller
    ..setNotationEnabled(true)
    ..setAnimationEnabled(true);
  await tester.pump();
  await tester.enterText(find.byType(TextField), 'Draw this over time');
  await tester.pump();
  await tester.tap(find.byTooltip('Send'));
  await settleAi(tester);
  client.answerResponse(_animatedNotation());
  await tester.pump();
}

void main() {
  testWidgets('Notation is on by default and appends returned vector ink', (
    WidgetTester tester,
  ) async {
    final (InkController controller, FakeAiClient client) = await _open(tester);

    expect(find.text('Enable notation'), findsNothing);
    expect(find.text('Enable animation'), findsNothing);
    expect(find.text('Panel side'), findsNothing);
    expect(find.text('Add to note'), findsNothing);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(EditorSettingsSheet), findsOneWidget);
    expect(find.text('Enable notation'), findsOneWidget);
    expect(find.text('Enable animation'), findsOneWidget);
    expect(find.text('Panel side'), findsOneWidget);
    expect(
      tester
          .widget<AiAssistantPanel>(find.byType(AiAssistantPanel))
          .controller
          .notationEnabled,
      isTrue,
    );
    Navigator.of(tester.element(find.byType(EditorSettingsSheet))).pop();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Label this');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await settleAi(tester);

    expect(client.requests, hasLength(1));
    expect(client.requests.single.notationEnabled, isTrue);
    expect(client.requests.single.noteImage, isNotNull);
    expect(client.requests.single.noteImage!.revision, 0);
    client.answerResponse(_notation());
    await tester.pumpAndSettle();

    expect(controller.strokes, hasLength(3));
    expect(controller.strokes[1].source, StrokeSource.derived);
    expect(controller.strokes[2].isDot, isTrue);
    expect(controller.strokes[1].style.ink.id, 'blue');
    expect(controller.documentRevision, 1);
    expect(find.text('I added a handwritten mark.'), findsOneWidget);
    expect(find.textContaining('AI notation:'), findsNothing);
    expect(find.textContaining('Added to note'), findsNothing);
    expect(find.text('Add to note'), findsNothing);
  });

  testWidgets('the AI button shows AI notes while on and hides them when off', (
    WidgetTester tester,
  ) async {
    final (InkController controller, FakeAiClient client) = await _open(tester);
    // Pressing AI on the selection turned the palette's AI button on.
    expect(find.byTooltip('Turn off AI'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Label this');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await settleAi(tester);
    client.answerResponse(_notation());
    await tester.pumpAndSettle();
    final List<Stroke> trace = controller.strokes.sublist(1);
    expect(trace, hasLength(2));
    expect(trace.any(controller.isStrokeHidden), isFalse);

    // Closing the chat keeps AI mode, and its notes, on.
    tester.widget<AiAssistantPanel>(find.byType(AiAssistantPanel)).onClose();
    await tester.pumpAndSettle();
    expect(find.byType(AiAssistantPanel), findsNothing);
    expect(find.byTooltip('Turn off AI'), findsOneWidget);
    expect(trace.any(controller.isStrokeHidden), isFalse);

    await tester.tap(find.byTooltip('Turn off AI'));
    await tester.pumpAndSettle();
    expect(trace.every(controller.isStrokeHidden), isTrue);
    expect(controller.isStrokeHidden(controller.strokes.first), isFalse);
    expect(controller.strokes, hasLength(3));
    expect(find.byTooltip('Turn on AI'), findsOneWidget);

    await tester.tap(find.byTooltip('Turn on AI'));
    await tester.pumpAndSettle();
    await settleAi(tester);
    expect(trace.any(controller.isStrokeHidden), isFalse);
    expect(find.byType(AiAssistantPanel), findsOneWidget);
    expect(find.byTooltip('Turn off AI'), findsOneWidget);
  });

  testWidgets('a changed note makes in-flight notation non-destructive', (
    WidgetTester tester,
  ) async {
    final (InkController controller, FakeAiClient client) = await _open(tester);
    tester
        .widget<AiAssistantPanel>(find.byType(AiAssistantPanel))
        .controller
        .setNotationEnabled(true);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Draw here');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await settleAi(tester);
    expect(client.requests, hasLength(1));

    controller
      ..startStroke(
        pointer: 9,
        sample: const RawInkSample(
          position: InkVector(300, 300),
          timestamp: Duration.zero,
        ),
        style: const StrokeStyle(ink: InkPalette.ink, width: 3),
      )
      ..endStroke(9);
    expect(controller.documentRevision, 1);
    client.answerResponse(_notation());
    await tester.pumpAndSettle();

    expect(controller.strokes, hasLength(2));
    expect(
      tester
          .widget<AiAssistantPanel>(find.byType(AiAssistantPanel))
          .controller
          .messages
          .last
          .notationStatus,
      AiNotationStatus.notAppliedStale,
    );
    expect(find.textContaining('Not applied'), findsNothing);
  });

  testWidgets('closing AI keeps animation looping without chat controls', (
    WidgetTester tester,
  ) async {
    final (InkController controller, FakeAiClient client) = await _open(tester);
    await _sendAnimatedNotation(tester, client);

    expect(controller.strokes, hasLength(2));
    expect(controller.documentRevision, 1);
    expect(controller.notationPlayback, isNotNull);
    expect(find.textContaining('Drawing…'), findsNothing);
    expect(find.textContaining('Added to note'), findsNothing);
    expect(find.text('Finish now'), findsNothing);

    final Object playback = controller.notationPlayback!;
    final Duration beforeClose = controller.notationPlayback!.clockElapsed;
    await tester.tap(find.byTooltip('Close AI assistant'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 1300));

    expect(find.byType(AiAssistantPanel), findsNothing);
    expect(controller.notationPlayback, same(playback));
    expect(controller.notationPlayback!.clockElapsed, greaterThan(beforeClose));
    expect(controller.strokes, hasLength(2));
    expect(controller.documentRevision, 1);
  });

  testWidgets('playback loops without recommitting or chat status', (
    WidgetTester tester,
  ) async {
    final (InkController controller, FakeAiClient client) = await _open(tester);
    await _sendAnimatedNotation(tester, client);

    final List<Stroke> committed = controller.strokes.toList();
    final Object playback = controller.notationPlayback!;
    expect(find.textContaining('Drawing…'), findsNothing);
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pump();

    expect(controller.notationPlayback, same(playback));
    expect(controller.strokes, orderedEquals(committed));
    expect(controller.documentRevision, 1);
    expect(find.textContaining('Drawing…'), findsNothing);
    expect(find.textContaining('Added to note'), findsNothing);
  });

  testWidgets('reduced motion applies timed notation statically', (
    WidgetTester tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final (InkController controller, FakeAiClient client) = await _open(tester);
    await _sendAnimatedNotation(tester, client);

    expect(controller.notationPlayback, isNull);
    expect(controller.strokes, hasLength(2));
    expect(controller.documentRevision, 1);
    expect(find.textContaining('Drawing…'), findsNothing);
    expect(find.textContaining('Added to note'), findsNothing);
    expect(find.text('Finish now'), findsNothing);
  });

  testWidgets('writing over a notation keeps it playing', (
    WidgetTester tester,
  ) async {
    final (InkController controller, FakeAiClient client) = await _open(tester);
    await _sendAnimatedNotation(tester, client);
    expect(controller.notationPlayback, isNotNull);

    await tester.tap(find.byTooltip('Pen'));
    await tester.pump();
    expect(controller.notationPlayback, isNotNull);
    final Rect canvas = tester.getRect(find.byType(InkCanvas));
    final Offset local = Offset(canvas.width * 0.25, canvas.height * 0.75);
    final TestGesture gesture = await tester.startGesture(
      canvas.topLeft + local,
      kind: PointerDeviceKind.stylus,
    );
    await tester.pump();

    final NotationPlayback playback = controller.notationPlayback!;
    expect(playback.isFinished, isFalse);
    expect(controller.activeStroke, isNotNull);
    expect(controller.activeStroke!.origin.x, closeTo(local.dx, 0.001));
    expect(controller.activeStroke!.origin.y, closeTo(local.dy, 0.001));
    expect(find.textContaining('Added to note'), findsNothing);

    await gesture.up();
    await tester.pump();
    expect(controller.strokes, hasLength(3));
    expect(controller.documentRevision, 2);
    expect(controller.notationPlayback, same(playback));
    expect(playback.isFinished, isFalse);
  });
}
