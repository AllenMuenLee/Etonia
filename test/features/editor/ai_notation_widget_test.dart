import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_assistant_controller.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/notation_playback.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/widgets/ai_assistant_panel.dart';
import 'package:greatnote/features/editor/widgets/ai_options.dart';
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

    // The assistant's settings are the AI tool's options.
    await tester.tap(find.byTooltip('AI settings'));
    await tester.pumpAndSettle();
    expect(find.byType(AiOptions), findsOneWidget);
    expect(find.text('Enable notation'), findsOneWidget);
    expect(find.text('Enable animation'), findsOneWidget);
    expect(find.text('Show notes in chat'), findsOneWidget);
    expect(
      tester
          .widget<AiAssistantPanel>(find.byType(AiAssistantPanel))
          .controller
          .notationEnabled,
      isTrue,
    );
    await tester.tap(find.byTooltip('AI settings'));
    await tester.pumpAndSettle();
    expect(find.byType(AiOptions), findsNothing);

    // The Settings sheet keeps the panel's side, not these.
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(EditorSettingsSheet), findsOneWidget);
    expect(find.text('Panel side'), findsOneWidget);
    expect(find.text('Enable notation'), findsNothing);
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

  testWidgets('a notation on a sticky note adds one, drawn on, beside the '
      'selection', (WidgetTester tester) async {
    final (InkController controller, FakeAiClient client) = await _open(tester);
    await tester.enterText(find.byType(TextField), 'Sketch it');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await settleAi(tester);
    client.answerResponse(
      AiAssistantResponse(
        message: 'I sketched it on a sticky note.',
        notation: AiNotation(
          label: 'Sketch',
          sticky: const AiStickySize(240, 180),
          items: <AiNotationItem>[
            AiNotationStroke(
              ink: 'blue',
              width: 3,
              points: const <AiNotationPoint>[
                AiNotationPoint(0.1, 0.1),
                AiNotationPoint(0.9, 0.9),
              ],
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The page's own ink is untouched; the drawing is on the new note.
    expect(controller.strokes, hasLength(1));
    expect(controller.stickyNotes, hasLength(1));
    final note = controller.stickyNotes.single;
    expect(note.strokes, hasLength(1));
    expect(note.localSize, const Size(240, 180));
    expect(note.colorId, 'blue');
    // Inside its paper's padding.
    for (final InkVector point in note.strokes.single.points) {
      expect(point.x, inInclusiveRange(16, 224));
      expect(point.y, inInclusiveRange(16, 164));
    }
    // Not opened for writing, and not over the selected line, but close by.
    expect(controller.editingSticky, isNull);
    const Rect line = Rect.fromLTRB(98, 98, 202, 102);
    final Rect overlap = note.bounds.intersect(line);
    expect(overlap.width <= 0 || overlap.height <= 0, isTrue);
    expect(note.bounds.top - line.bottom, lessThan(40));
    expect(controller.documentRevision, 1);
    expect(
      tester
          .widget<AiAssistantPanel>(find.byType(AiAssistantPanel))
          .controller
          .messages
          .last
          .notationStatus,
      AiNotationStatus.applied,
    );
  });

  testWidgets('Show notes in chat on keeps AI notes visible when AI is off', (
    WidgetTester tester,
  ) async {
    final (InkController controller, FakeAiClient client) = await _open(tester);
    // Pressing AI on the selection turned the palette's AI button on.
    expect(find.byTooltip('AI settings'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Label this');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await settleAi(tester);
    client.answerResponse(_notation());
    await tester.pumpAndSettle();
    final List<Stroke> trace = controller.strokes.sublist(1);
    expect(trace, hasLength(2));
    expect(trace.any(controller.isStrokeHidden), isFalse);

    // Another tool leaves AI mode, and its chat, on.
    await tester.tap(find.byTooltip('Pen'));
    await tester.pumpAndSettle();
    expect(find.byType(AiAssistantPanel), findsOneWidget);
    expect(trace.any(controller.isStrokeHidden), isFalse);
    tester.widget<AiAssistantPanel>(find.byType(AiAssistantPanel)).onClose();
    await tester.pumpAndSettle();
    expect(find.byType(AiAssistantPanel), findsNothing);
    // Notes stay visible even when AI is turned off because Show notes in chat is on.
    expect(trace.any(controller.isStrokeHidden), isFalse);
    expect(controller.isStrokeHidden(controller.strokes.first), isFalse);
    expect(controller.strokes, hasLength(3));
    expect(find.byTooltip('Turn on AI'), findsOneWidget);

    await tester.tap(find.byTooltip('Turn on AI'));
    await tester.pumpAndSettle();
    await settleAi(tester);
    expect(trace.any(controller.isStrokeHidden), isFalse);
    expect(find.byType(AiAssistantPanel), findsOneWidget);
    expect(find.byTooltip('AI settings'), findsOneWidget);

    // Closing the chat turns AI mode off, but notes stay visible.
    tester.widget<AiAssistantPanel>(find.byType(AiAssistantPanel)).onClose();
    await tester.pumpAndSettle();
    expect(find.byType(AiAssistantPanel), findsNothing);
    expect(find.byTooltip('Turn on AI'), findsOneWidget);
    expect(trace.any(controller.isStrokeHidden), isFalse);
  });

  testWidgets('Show notes in chat off hides AI notes when AI is off and shows '
      'them when AI is on', (WidgetTester tester) async {
    final (InkController controller, FakeAiClient client) = await _open(tester);
    final AiAssistantController assistant = tester
        .widget<AiAssistantPanel>(find.byType(AiAssistantPanel))
        .controller;
    assistant.setShowNotesInChat(false);
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Label this');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await settleAi(tester);
    client.answerResponse(_notation());
    await tester.pumpAndSettle();
    final List<Stroke> trace = controller.strokes.sublist(1);
    expect(trace.any(controller.isStrokeHidden), isFalse);

    // Closing the chat turns AI off; with Show notes in chat off, notes hide.
    tester.widget<AiAssistantPanel>(find.byType(AiAssistantPanel)).onClose();
    await tester.pumpAndSettle();
    expect(trace.every(controller.isStrokeHidden), isTrue);
    expect(controller.isStrokeHidden(controller.strokes.first), isFalse);

    // Turning AI back on shows them again.
    await tester.tap(find.byTooltip('Turn on AI'));
    await tester.pumpAndSettle();
    await settleAi(tester);
    expect(trace.any(controller.isStrokeHidden), isFalse);

    // Closing the chat turns AI off and hides the notes.
    tester.widget<AiAssistantPanel>(find.byType(AiAssistantPanel)).onClose();
    await tester.pumpAndSettle();
    expect(trace.every(controller.isStrokeHidden), isTrue);

    // Turning Show notes in chat back on while AI is off shows the notes.
    assistant.setShowNotesInChat(true);
    await tester.pump();
    expect(trace.any(controller.isStrokeHidden), isFalse);

    // Turning Show notes in chat off while AI is off hides them again.
    assistant.setShowNotesInChat(false);
    await tester.pump();
    expect(trace.every(controller.isStrokeHidden), isTrue);
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
    // In the canvas's own units, whatever the page's fit.
    final Offset onPage = tester
        .renderObject<RenderBox>(find.byType(InkCanvas))
        .globalToLocal(canvas.topLeft + local);
    expect(controller.activeStroke!.origin.x, closeTo(onPage.dx, 0.001));
    expect(controller.activeStroke!.origin.y, closeTo(onPage.dy, 0.001));
    expect(find.textContaining('Added to note'), findsNothing);

    await gesture.up();
    await tester.pump();
    expect(controller.strokes, hasLength(3));
    expect(controller.documentRevision, 2);
    expect(controller.notationPlayback, same(playback));
    expect(playback.isFinished, isFalse);
  });
}
