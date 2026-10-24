import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_assistant_controller.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/sticky/sticky_note.dart';
import 'package:greatnote/features/editor/widgets/ai_assistant_panel.dart';
import 'package:greatnote/features/editor/widgets/ai_options.dart';
import 'package:greatnote/features/editor/widgets/tool_palette.dart';

import '../../helpers/ai_fakes.dart';
import '../../helpers/pump_app.dart';

/// A short line of ink at [center], on the page.
Stroke _mark(Offset center) => Stroke.fromPoints(
  style: const StrokeStyle(ink: InkPalette.ink, width: 4),
  points: <InkVector>[
    InkVector(center.dx - 20, center.dy),
    InkVector(center.dx + 20, center.dy),
  ],
);

class _Editor {
  _Editor(this.ink, this.client, this.recognizer, this.renderer);

  final InkController ink;
  final FakeAiClient client;
  final FakeCanvasTextRecognizer recognizer;
  final FakeHandwritingImageRenderer renderer;
}

Future<_Editor> _pump(
  WidgetTester tester, {
  Iterable<Stroke> strokes = const <Stroke>[],
  Iterable<StickyNoteElement> stickies = const <StickyNoteElement>[],
  ThemeMode themeMode = ThemeMode.light,
}) async {
  final InkController ink = InkController(
    strokes: strokes,
    stickyNotes: stickies,
  );
  addTearDown(ink.dispose);
  final FakeAiClient client = FakeAiClient();
  final FakeCanvasTextRecognizer recognizer = FakeCanvasTextRecognizer();
  final FakeHandwritingImageRenderer renderer = FakeHandwritingImageRenderer();
  await pumpApp(
    tester,
    themeMode: themeMode,
    home: EditorScreen(
      inkController: ink,
      aiClient: client,
      initialNotationEnabled: false,
      textRecognizer: recognizer,
      handwritingRenderer: renderer,
    ),
  );
  return _Editor(ink, client, recognizer, renderer);
}

EditorTool _tool(WidgetTester tester) =>
    tester.widget<ToolPalette>(find.byType(ToolPalette)).tool.value;

bool _aiOn(WidgetTester tester) =>
    tester.widget<ToolPalette>(find.byType(ToolPalette)).aiActive.value;

AiAssistantController _assistant(WidgetTester tester) =>
    tester.widget<AiAssistantPanel>(find.byType(AiAssistantPanel)).controller;

/// Where page point [page] is on screen, through the page's zoom.
Offset _screen(WidgetTester tester, Offset page) => tester
    .renderObject<RenderBox>(find.byType(InkCanvas).first)
    .localToGlobal(page);

int _pointer = 40;

/// Writes along [points], in page coordinates, with a stylus, a few
/// milliseconds per sample. Lifts the pen unless [lift] is false.
Future<TestGesture> _write(
  WidgetTester tester,
  List<Offset> points, {
  bool lift = true,
}) async {
  final TestGesture gesture = await tester.createGesture(
    pointer: _pointer++,
    kind: PointerDeviceKind.stylus,
  );
  Duration time = const Duration(seconds: 10);
  await gesture.down(_screen(tester, points.first), timeStamp: time);
  for (final Offset point in points.skip(1)) {
    time += const Duration(milliseconds: 8);
    await gesture.moveTo(_screen(tester, point), timeStamp: time);
  }
  await tester.pump();
  if (lift) {
    await gesture.up(timeStamp: time + const Duration(milliseconds: 8));
    await tester.pump();
  }
  return gesture;
}

/// A short, letter-sized squiggle starting at [start].
List<Offset> _letter(Offset start) => <Offset>[
  for (int i = 0; i <= 12; i++) start + Offset(i * 2.0, 10 * math.sin(i / 2)),
];

Future<void> _turnOnAi(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Turn on AI'));
  await tester.pumpAndSettle();
}

Future<void> _closeChat(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Close AI assistant'));
  await tester.pumpAndSettle();
}

void main() {
  group('the AI button', () {
    testWidgets('is off at launch and enabled with no AI notes yet', (
      WidgetTester tester,
    ) async {
      await _pump(tester);
      expect(_aiOn(tester), isFalse);
      expect(_tool(tester), EditorTool.pen);
      expect(
        find.byKey(const ValueKey<String>('ai-notes-visibility-toggle')),
        findsNothing,
      );
      final Finder button = find.byKey(
        const ValueKey<String>('ai-mode-toggle'),
      );
      expect(
        find.descendant(of: button, matching: find.text('AI')),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('AI mode')),
        matchesSemantics(
          label: 'AI mode',
          isButton: true,
          isEnabled: true,
          hasEnabledState: true,
          hasToggledState: true,
          isToggled: false,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      final Size size = tester.getSize(button);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    });

    testWidgets('pressed, opens the chat with nothing chosen yet', (
      WidgetTester tester,
    ) async {
      await _pump(tester);
      await _turnOnAi(tester);
      expect(_aiOn(tester), isTrue);
      expect(_tool(tester), EditorTool.ai);
      expect(find.byType(AiAssistantPanel), findsOneWidget);
      expect(find.text(AiAssistantPanel.noContextPrompt), findsOneWidget);
      expect(_assistant(tester).context, isNull);
      expect(find.byTooltip('AI settings'), findsOneWidget);
      expect(
        tester.getSemantics(find.bySemanticsLabel('AI mode')),
        matchesSemantics(
          label: 'AI mode',
          isButton: true,
          isEnabled: true,
          hasEnabledState: true,
          hasToggledState: true,
          isToggled: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
    });

    testWidgets('pressed with a selection, asks about it', (
      WidgetTester tester,
    ) async {
      final _Editor editor = await _pump(
        tester,
        strokes: <Stroke>[_mark(const Offset(200, 200))],
      );
      await tester.tap(find.byTooltip('Select'));
      await tester.pump();
      selectInk(editor.ink, const Rect.fromLTRB(150, 180, 250, 220));
      await tester.pump();
      await _turnOnAi(tester);
      await settleAi(tester);
      expect(_tool(tester), EditorTool.ai);
      expect(_assistant(tester).context, isNotNull);
      expect(editor.ink.selection, isNotNull);
    });

    testWidgets('the selection AI action turns the palette AI button on', (
      WidgetTester tester,
    ) async {
      final _Editor editor = await _pump(
        tester,
        strokes: <Stroke>[_mark(const Offset(200, 200))],
      );
      await tester.tap(find.byTooltip('Select'));
      await tester.pump();
      selectInk(editor.ink, const Rect.fromLTRB(150, 180, 250, 220));
      await tester.pump();
      await tester.tap(find.byTooltip('AI assistant'));
      await tester.pumpAndSettle();
      await settleAi(tester);

      expect(find.byType(AiAssistantPanel), findsOneWidget);
      expect(_assistant(tester).context, isNotNull);
      expect(_assistant(tester).context!.snapshot.strokes, hasLength(1));
      expect(_aiOn(tester), isTrue);
      expect(_tool(tester), EditorTool.ai);
      // What was asked about stays selected.
      expect(editor.ink.selection, isNotNull);
    });

    testWidgets('closing the chat turns AI mode off', (
      WidgetTester tester,
    ) async {
      await _pump(tester);
      await tester.tap(find.byTooltip('Eraser'));
      await tester.pump();
      await _turnOnAi(tester);
      await _closeChat(tester);
      expect(find.byType(AiAssistantPanel), findsNothing);
      expect(_aiOn(tester), isFalse);
      expect(_tool(tester), EditorTool.eraser);
    });

    testWidgets('Escape closes the chat and turns AI mode off', (
      WidgetTester tester,
    ) async {
      await _pump(tester);
      await _turnOnAi(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AiAssistantPanel), findsNothing);
      expect(_aiOn(tester), isFalse);
    });

    testWidgets('closing the chat gives back the previous tool', (
      WidgetTester tester,
    ) async {
      await _pump(tester);
      await tester.tap(find.byTooltip('Eraser'));
      await tester.pump();
      await _turnOnAi(tester);

      await _closeChat(tester);
      expect(_aiOn(tester), isFalse);
      expect(find.byType(AiAssistantPanel), findsNothing);
      expect(_tool(tester), EditorTool.eraser);
    });

    testWidgets('other tools work as usual while AI mode stays on', (
      WidgetTester tester,
    ) async {
      final _Editor editor = await _pump(tester);
      await _turnOnAi(tester);

      await tester.tap(find.byTooltip('Pen'));
      await tester.pump();
      expect(_tool(tester), EditorTool.pen);
      expect(_aiOn(tester), isTrue);
      await _write(tester, _letter(const Offset(300, 300)));
      expect(editor.ink.strokes, hasLength(1));

      await tester.tap(find.byTooltip('Eraser'));
      await tester.pump();
      expect(_tool(tester), EditorTool.eraser);
      await tester.tap(find.byTooltip('Select'));
      await tester.pump();
      expect(_tool(tester), EditorTool.select);
      await tester.tap(find.byTooltip('Sticky note'));
      await tester.pumpAndSettle();
      expect(_tool(tester), EditorTool.sticky);
      expect(_aiOn(tester), isTrue);
    });

    testWidgets('pressing the chat, its text or its composer, takes up the AI '
        'tool', (WidgetTester tester) async {
      await _pump(tester);
      await _turnOnAi(tester);

      await tester.tap(find.byTooltip('Pen'));
      await tester.pump();
      expect(_tool(tester), EditorTool.pen);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(_tool(tester), EditorTool.ai);
      expect(_aiOn(tester), isTrue);

      await tester.tap(find.byTooltip('Eraser'));
      await tester.pump();
      expect(_tool(tester), EditorTool.eraser);
      await tester.tap(find.text(AiAssistantPanel.noContextPrompt));
      await tester.pump();
      expect(_tool(tester), EditorTool.ai);
    });

    testWidgets('pressed while on, opens the AI settings', (
      WidgetTester tester,
    ) async {
      await _pump(tester);
      await _turnOnAi(tester);
      expect(find.text('Enable notation'), findsNothing);

      await tester.tap(find.byTooltip('AI settings'));
      await tester.pumpAndSettle();
      expect(find.byType(AiOptions), findsOneWidget);
      expect(find.text('Enable animation'), findsOneWidget);
      expect(find.text('Show notes in chat'), findsOneWidget);
      // AI mode stays on, and the chat open, while its settings change.
      expect(_aiOn(tester), isTrue);
      expect(find.byType(AiAssistantPanel), findsOneWidget);

      final AiAssistantController assistant = _assistant(tester);
      final bool notation = assistant.notationEnabled;
      final bool animation = assistant.animationEnabled;
      final bool inChat = assistant.showNotesInChat;
      await tester.tap(find.text('Enable notation'));
      await tester.tap(find.text('Enable animation'));
      await tester.tap(find.text('Show notes in chat'));
      await tester.pump();
      expect(assistant.notationEnabled, !notation);
      expect(assistant.animationEnabled, !animation);
      expect(assistant.showNotesInChat, !inChat);
    });
  });
}
