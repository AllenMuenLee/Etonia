import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_assistant_controller.dart';
import 'package:greatnote/features/editor/ai/ai_canvas_input.dart';
import 'package:greatnote/features/editor/ai/flying_words.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/sticky/sticky_note.dart';
import 'package:greatnote/features/editor/widgets/ai_assistant_panel.dart';
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

final Finder _glowLayer = find.byKey(
  const ValueKey<String>('ai-canvas-stroke-layer'),
);

AiCanvasInputController _input(WidgetTester tester) {
  final CustomPaint paint = tester.widget<CustomPaint>(_glowLayer.first);
  return (paint.painter! as AiCanvasStrokePainter).input;
}

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

/// A loop of [radius] around [center], drawn to come back to its start.
List<Offset> _loop(Offset center, double radius, {double turn = 1}) {
  const int steps = 72;
  return <Offset>[
    for (int i = 0; i <= steps; i++)
      center +
          Offset(
            radius * math.cos(2 * math.pi * turn * i / steps),
            radius * math.sin(2 * math.pi * turn * i / steps),
          ),
  ];
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
      expect(find.byTooltip('Turn off AI'), findsOneWidget);
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

    testWidgets('closing the chat leaves AI mode on', (
      WidgetTester tester,
    ) async {
      await _pump(tester);
      await _turnOnAi(tester);
      await _closeChat(tester);
      expect(find.byType(AiAssistantPanel), findsNothing);
      expect(_aiOn(tester), isTrue);
      expect(_tool(tester), EditorTool.ai);
    });

    testWidgets('Escape closes the chat and leaves AI mode on', (
      WidgetTester tester,
    ) async {
      await _pump(tester);
      await _turnOnAi(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AiAssistantPanel), findsNothing);
      expect(_aiOn(tester), isTrue);
    });

    testWidgets('turned off, closes the chat, clears what was written, and '
        'gives back the previous tool', (WidgetTester tester) async {
      final _Editor editor = await _pump(tester);
      await tester.tap(find.byTooltip('Eraser'));
      await tester.pump();
      await _turnOnAi(tester);
      await _write(tester, _letter(const Offset(300, 300)));
      expect(_input(tester).pendingStrokes, hasLength(1));

      await tester.tap(find.byTooltip('Turn off AI'));
      await tester.pumpAndSettle();
      expect(_aiOn(tester), isFalse);
      expect(find.byType(AiAssistantPanel), findsNothing);
      expect(_input(tester).isEmpty, isTrue);
      expect(_tool(tester), EditorTool.eraser);
      // Nothing waiting was read.
      await tester.pump(const Duration(seconds: 2));
      expect(editor.recognizer.batches, isEmpty);
    });

    testWidgets('other tools work as usual while AI mode stays on', (
      WidgetTester tester,
    ) async {
      final _Editor editor = await _pump(tester);
      await _turnOnAi(tester);
      await _closeChat(tester);

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
  });

  group('writing in AI mode', () {
    testWidgets('glows on its own layer and is never ink', (
      WidgetTester tester,
    ) async {
      final _Editor editor = await _pump(
        tester,
        strokes: <Stroke>[_mark(const Offset(500, 500))],
      );
      await _turnOnAi(tester);
      final TestGesture gesture = await _write(
        tester,
        _letter(const Offset(300, 300)),
        lift: false,
      );
      final AiCanvasInputController input = _input(tester);
      expect(input.activePoints.length, greaterThan(4));
      expect(identical(input.page, editor.ink), isTrue);
      // Halo, aura, core, and highlight.
      expect(
        tester.renderObject(_glowLayer.first),
        paints
          ..path()
          ..path()
          ..path()
          ..path(),
      );
      expect(editor.ink.strokes, hasLength(1));
      expect(editor.ink.activeStroke, isNull);

      await gesture.up();
      await tester.pump(const Duration(seconds: 1));
      expect(editor.ink.strokes, hasLength(1));
      expect(editor.ink.documentRevision, 0);
      expect(editor.ink.canUndo, isFalse);
    });

    testWidgets('a pen tap on the selection frame stays for the assistant', (
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
      final Stroke before = editor.ink.strokes.single;
      await _write(tester, <Offset>[
        const Offset(200, 200),
        const Offset(230, 230),
      ]);
      expect(editor.ink.activeTransform, isNull);
      expect(editor.ink.strokes.single, same(before));
    });
  });

  group('circling a spot', () {
    testWidgets('selects what it encloses and asks about it', (
      WidgetTester tester,
    ) async {
      final _Editor editor = await _pump(
        tester,
        strokes: <Stroke>[
          _mark(const Offset(200, 200)),
          _mark(const Offset(600, 600)),
        ],
      );
      await _turnOnAi(tester);
      await _closeChat(tester);

      await _write(tester, _loop(const Offset(200, 200), 70));
      await tester.pumpAndSettle();
      await settleAi(tester);

      expect(editor.ink.selection, isNotNull);
      expect(editor.ink.selection!.indices, <int>[0]);
      expect(find.byType(AiAssistantPanel), findsOneWidget);
      expect(_assistant(tester).context!.snapshot.strokes, hasLength(1));
      expect(_input(tester).isEmpty, isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(editor.recognizer.batches, isEmpty);

      // Circling somewhere else chooses that instead.
      await _write(tester, _loop(const Offset(600, 600), 70));
      await tester.pumpAndSettle();
      await settleAi(tester);
      expect(editor.ink.selection!.indices, <int>[1]);
      expect(
        _assistant(tester).context!.snapshot.strokes.single.points.first.x,
        closeTo(580, 0.01),
      );
      expect(editor.ink.strokes, hasLength(2));
    });

    testWidgets('selects a sticky note it encloses', (
      WidgetTester tester,
    ) async {
      final _Editor editor = await _pump(
        tester,
        stickies: <StickyNoteElement>[
          StickyNoteElement(
            id: 'note',
            center: const InkVector(300, 300),
            size: const Size(80, 80),
            colorId: StickyPalette.yellow.id,
          ),
        ],
      );
      await _turnOnAi(tester);
      await _write(tester, _loop(const Offset(300, 300), 90));
      await tester.pumpAndSettle();
      await settleAi(tester);
      expect(editor.ink.selection?.stickyCount, 1);
      expect(_assistant(tester).context, isNotNull);
    });

    testWidgets('a small o or an open stroke is handwriting, not a circle', (
      WidgetTester tester,
    ) async {
      final _Editor editor = await _pump(
        tester,
        strokes: <Stroke>[_mark(const Offset(200, 200))],
      );
      await _turnOnAi(tester);

      // An "o" the size of a letter, over the ink.
      await _write(tester, _loop(const Offset(200, 200), 12));
      expect(editor.ink.selection, isNull);
      expect(_input(tester).pendingStrokes, hasLength(1));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(editor.recognizer.batches, hasLength(1));

      // Most of a circle, left open.
      await _write(tester, _loop(const Offset(200, 200), 80, turn: 0.6));
      expect(editor.ink.selection, isNull);
      expect(_input(tester).pendingStrokes, hasLength(1));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(editor.recognizer.batches, hasLength(2));
      expect(_assistant(tester).context, isNull);
    });

    testWidgets('a loop around nothing is handwriting', (
      WidgetTester tester,
    ) async {
      final _Editor editor = await _pump(tester);
      await _turnOnAi(tester);
      await _write(tester, _loop(const Offset(300, 300), 80));
      expect(editor.ink.selection, isNull);
      expect(_input(tester).pendingStrokes, hasLength(1));
    });
  });

  group('handwriting in AI mode', () {
    void enqueue(WidgetTester tester, _Editor editor) {
      _input(tester).onHandwriting!(
        [
          AiCanvasStroke(const [
            AiCanvasPoint(InkVector(300, 300), Duration.zero),
            AiCanvasPoint(InkVector(320, 310), Duration(milliseconds: 20)),
          ]),
        ],
        editor.ink,
        openPanel: true,
      );
    }

    testWidgets('queued words use the preceding result and latest draft', (
      tester,
    ) async {
      final editor = await _pump(tester);
      await _turnOnAi(tester);
      final first = Completer<String>();
      editor.recognizer.onRecognize = (_) =>
          editor.recognizer.batches.length == 1
          ? first.future
          : Future.value('form');
      await tester.enterText(find.byType(TextField), 'the');
      enqueue(tester, editor);
      enqueue(tester, editor);
      await tester.pump();
      expect(editor.recognizer.batches, hasLength(1));
      await tester.enterText(find.byType(TextField), 'please explain the');
      first.complete('standard');
      await tester.pumpAndSettle();
      expect(editor.recognizer.batches, hasLength(2));
      expect(
        editor.recognizer.batches.last.context!.draft,
        'please explain the standard',
      );
      expect(_assistant(tester).draft, 'please explain the standard form');
    });

    testWidgets('recognition receives the active conversation', (tester) async {
      final editor = await _pump(
        tester,
        strokes: [_mark(const Offset(200, 200))],
      );
      await tester.tap(find.byTooltip('Select'));
      await tester.pump();
      selectInk(editor.ink, const Rect.fromLTRB(150, 180, 250, 220));
      await tester.pump();
      await _turnOnAi(tester);
      await settleAi(tester);
      expect(_assistant(tester).send('Explain capacitance'), isTrue);
      await tester.pump();
      editor.client.answer('Capacitance measures stored charge per volt.');
      await tester.pumpAndSettle();
      enqueue(tester, editor);
      await tester.pumpAndSettle();
      expect(editor.recognizer.batches.single.context!.recentMessages, [
        'Capacitance measures stored charge per volt.',
        'Explain capacitance',
      ]);
      // Recognition is local; only the explicit chat send called the AI client.
      expect(editor.client.requests, hasLength(1));
    });

    testWidgets('a recognition timeout releases the next word', (tester) async {
      final editor = await _pump(tester);
      await _turnOnAi(tester);
      final first = Completer<String>();
      editor.recognizer.onRecognize = (_) =>
          editor.recognizer.batches.length == 1
          ? first.future
          : Future.value('next');
      enqueue(tester, editor);
      enqueue(tester, editor);
      await tester.pump();
      await tester.pump(const Duration(seconds: 9));
      await tester.pumpAndSettle();
      expect(_assistant(tester).draft, 'next');
      first.complete('late');
      await tester.pumpAndSettle();
      expect(_assistant(tester).draft, 'next');
    });

    testWidgets('turning AI off discards queued and in-flight recognition', (
      tester,
    ) async {
      final editor = await _pump(tester);
      await _turnOnAi(tester);
      final first = Completer<String>();
      editor.recognizer.onRecognize = (_) => first.future;
      enqueue(tester, editor);
      enqueue(tester, editor);
      await tester.pump();
      await tester.tap(find.byTooltip('Turn off AI'));
      await tester.pumpAndSettle();
      editor.recognizer.onRecognize = null;
      editor.recognizer.text = 'new';
      await _turnOnAi(tester);
      enqueue(tester, editor);
      await tester.pumpAndSettle();
      expect(_assistant(tester).draft, 'new');
      first.complete('stale');
      await tester.pumpAndSettle();
      expect(editor.recognizer.batches, hasLength(2));
      expect(_assistant(tester).draft, 'new');
    });

    testWidgets('is read into the composer once the pen rests', (
      WidgetTester tester,
    ) async {
      final _Editor editor = await _pump(tester);
      editor.recognizer.text = 'what is this';
      await _turnOnAi(tester);
      await tester.enterText(find.byType(TextField), 'Hello');
      await tester.pump();

      await _write(tester, _letter(const Offset(300, 300)));
      expect(_input(tester).pendingStrokes, hasLength(1));
      await tester.pump(const Duration(milliseconds: 500));
      expect(editor.recognizer.batches, isEmpty);
      // A second stroke before the pause joins the first.
      await _write(tester, _letter(const Offset(340, 300)));
      expect(_input(tester).pendingStrokes, hasLength(2));
      // Still under 1.2 s since the pen left the screen.
      await tester.pump(const Duration(milliseconds: 1150));
      expect(editor.recognizer.batches, isEmpty);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(editor.recognizer.batches, hasLength(1));
      expect(editor.recognizer.batches.single.strokes, hasLength(2));
      expect(editor.recognizer.batches.single.png, isNotEmpty);
      expect(editor.recognizer.batches.single.context!.draft, 'Hello');
      expect(editor.renderer.batches.single, hasLength(2));
      expect(_input(tester).isEmpty, isTrue);
      // The words land in the composer once they have flown there.
      await tester.pumpAndSettle();
      expect(_assistant(tester).draft, 'Hello what is this');
      final TextField field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'Hello what is this');
      expect(
        field.controller!.selection,
        const TextSelection.collapsed(offset: 'Hello what is this'.length),
      );
      expect(editor.ink.strokes, isEmpty);
    });

    testWidgets('the words fly from the page into the composer', (
      WidgetTester tester,
    ) async {
      final _Editor editor = await _pump(tester);
      editor.recognizer.text = 'fly';
      await _turnOnAi(tester);

      await _write(tester, _letter(const Offset(300, 300)));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(editor.recognizer.batches, hasLength(1));
      // In flight: shown over the page, not yet in the composer.
      expect(find.byType(FlyingWords), findsOneWidget);
      expect(find.text('fly'), findsOneWidget);
      expect(_assistant(tester).draft, isEmpty);

      await tester.pumpAndSettle();
      expect(find.byType(FlyingWords), findsNothing);
      expect(_assistant(tester).draft, 'fly');
    });

    testWidgets('reopens a closed chat with the words in the composer', (
      WidgetTester tester,
    ) async {
      final _Editor editor = await _pump(tester);
      editor.recognizer.text = 'explain';
      await _turnOnAi(tester);
      await _closeChat(tester);
      expect(find.byType(AiAssistantPanel), findsNothing);

      await _write(tester, _letter(const Offset(300, 300)));
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(find.byType(AiAssistantPanel), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'explain',
      );
      expect(_aiOn(tester), isTrue);
    });

    testWidgets('switching tools reads what is waiting at once', (
      WidgetTester tester,
    ) async {
      final _Editor editor = await _pump(tester);
      editor.recognizer.text = 'now';
      await _turnOnAi(tester);
      await _write(tester, _letter(const Offset(300, 300)));
      await tester.tap(find.byTooltip('Pen'));
      await tester.pump();
      await tester.pump();
      expect(editor.recognizer.batches, hasLength(1));
      await tester.pumpAndSettle();
      expect(_assistant(tester).draft, 'now');
    });

    testWidgets('nothing read adds nothing', (WidgetTester tester) async {
      final _Editor editor = await _pump(tester);
      editor.recognizer.text = '  ';
      await _turnOnAi(tester);
      await _closeChat(tester);
      await _write(tester, _letter(const Offset(300, 300)));
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(editor.recognizer.batches, hasLength(1));
      expect(find.byType(AiAssistantPanel), findsNothing);
    });
  });
}
