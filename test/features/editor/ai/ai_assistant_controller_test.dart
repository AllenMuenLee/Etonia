import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_assistant_controller.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/ai_config.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/ai/note_image_renderer.dart';
import 'package:greatnote/features/editor/ai/selection_image_renderer.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/ink_selection.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

import '../../../helpers/ai_fakes.dart';

const Rect _top = Rect.fromLTRB(90, 90, 210, 110);
const Rect _bottom = Rect.fromLTRB(90, 290, 210, 310);

Stroke _line(double y) {
  return Stroke.fromPoints(
    style: const StrokeStyle(ink: InkPalette.ink, width: 4),
    points: <InkVector>[InkVector(100, y), InkVector(200, y)],
  );
}

/// Everything a test needs: ink with two lines, a fake service, a fake
/// renderer, and the assistant between them.
class _Rig {
  _Rig({bool configured = true})
    : client = FakeAiClient(isConfigured: configured) {
    assistant = AiAssistantController(client: client, renderer: renderer);
    assistant.addListener(() => notifications++);
  }

  final InkController ink = InkController(
    strokes: <Stroke>[_line(100), _line(300)],
  );
  final FakeAiClient client;
  final FakeSelectionImageRenderer renderer = FakeSelectionImageRenderer();
  late final AiAssistantController assistant;
  int notifications = 0;
  bool _disposed = false;

  /// Selects the ink in [box] and opens the assistant on it.
  Future<InkSelection> open([Rect box = _top]) async {
    final InkSelection selection = selectInk(ink, box);
    assistant.open(
      selection,
      brightness: Brightness.light,
      background: Colors.white,
    );
    await pumpEventQueue();
    return selection;
  }

  void dispose() {
    if (!_disposed) {
      _disposed = true;
      assistant.dispose();
      ink.dispose();
    }
  }
}

class _ManualPresentation implements AiNotationPresentation {
  final Completer<void> _done = Completer<void>();
  int finishes = 0;

  @override
  Future<void> get done => _done.future;

  @override
  void finish() {
    finishes++;
    complete();
  }

  void complete() {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }
}

List<String> _texts(AiAssistantController assistant) {
  return <String>[
    for (final AiMessage message in assistant.messages)
      '${message.role.name}: ${message.displayText}',
  ];
}

InkSelection _selectionOf(InkController ink, List<int> indices) {
  final List<Stroke> strokes = <Stroke>[
    for (final int index in indices) ink.strokes[index],
  ];
  return InkSelection(
    indices: indices,
    strokes: strokes,
    frame: frameAround(strokes),
  );
}

void main() {
  group('streaming', _streamingTests);

  late _Rig rig;

  setUp(() => rig = _Rig());
  tearDown(() => rig.dispose());

  test(
    'opening snapshots the selection and leaves the document alone',
    () async {
      final List<Stroke> before = List<Stroke>.of(rig.ink.strokes);
      int inkChanges = 0;
      int selectionChanges = 0;
      final InkSelection selection = selectInk(rig.ink, _top);
      rig.ink.completedStrokesListenable.addListener(() => inkChanges++);
      rig.ink.selectionListenable.addListener(() => selectionChanges++);

      expect(rig.assistant.isOpen, isFalse);
      expect(rig.assistant.side, AiPanelSide.left);
      rig.assistant.open(
        selection,
        brightness: Brightness.dark,
        background: const Color(0xFF26272B),
      );

      // Open at once, with the snapshot taken before any asynchronous work.
      expect(rig.assistant.isOpen, isTrue);
      final AiSelectionContext context = rig.assistant.context!;
      expect(context.isRendering, isTrue);
      expect(context.snapshot.brightness, Brightness.dark);
      expect(context.snapshot.background, const Color(0xFF26272B));
      expect(context.snapshot.strokes.single.points, before[0].points);
      expect(context.snapshot.strokes.single.width, 4);
      expect(context.snapshot.strokes.single.color, InkPalette.ink.onDarkPaper);
      expect(context.snapshot.strokes.single.isDot, isFalse);
      expect(rig.assistant.canSend, isFalse);

      await pumpEventQueue();

      expect(context.image, isNotNull);
      expect(rig.assistant.canSend, isTrue);
      expect(rig.renderer.snapshots.single, same(context.snapshot));
      expect(rig.ink.strokes, before);
      expect(rig.ink.selection, same(selection));
      expect(rig.ink.canPaste, isFalse);
      expect(inkChanges, 0);
      expect(selectionChanges, 0);
    },
  );

  test('opening sends nothing', () async {
    await rig.open();
    rig.assistant
      ..close()
      ..setSide(AiPanelSide.left);
    await rig.open();

    expect(rig.client.requests, isEmpty);
    expect(rig.assistant.messages, isEmpty);
    expect(rig.assistant.requestState, AiRequestState.idle);
  });

  test('a question with nothing selected is sent as about the page', () async {
    rig.assistant.show();

    expect(rig.assistant.context, isNull);
    expect(rig.assistant.canSend, isTrue);
    expect(rig.assistant.hasSelection, isFalse);
    // A quick action is about chosen ink, so there is nothing to act on.
    expect(rig.assistant.sendQuickAction(AiQuickAction.explain), isFalse);
    expect(rig.client.requests, isEmpty);

    expect(rig.assistant.send('What is a derivative?'), isTrue);

    final AiSelectionContext context = rig.assistant.context!;
    expect(context.isPage, isTrue);
    expect(context.groups, isEmpty);
    // Its notes go wherever the shown page is blank.
    expect(context.logicalBounds, isNull);
    expect(rig.assistant.hasSelection, isFalse);
    // No ink was drawn: blank paper stands in for it.
    expect(rig.renderer.snapshots, isEmpty);
    await pumpEventQueue();
    final AiRequest request = rig.client.requests.single;
    expect(request.imagePng, isNotEmpty);
    expect(request.selectionSvg, isNull);
    expect(request.systemInstruction, endsWith(AiPrompts.noSelection));
    expect(_texts(rig.assistant), <String>['user: What is a derivative?']);

    rig.client.answer('The rate of change.');
    await pumpEventQueue();
    expect(rig.assistant.send('An example?'), isTrue);
    await pumpEventQueue();
    expect(rig.client.requests, hasLength(2));
    expect(rig.assistant.context, same(context));
  });

  test('a page chat drawing on the note keeps no focus, and is found by '
      'selecting its notes', () async {
    final InkController ink = InkController(
      strokes: <Stroke>[_line(100), _line(300), _line(500)],
    );
    final FakeAiClient client = FakeAiClient();
    final AiAssistantController assistant = AiAssistantController(
      client: client,
      renderer: FakeSelectionImageRenderer(),
      animationEnabled: false,
      captureNote: () async =>
          NoteImage(logicalSize: const Size(10, 10), revision: 0),
      applyNotation: (AiNotation _, NoteImage _) => AiNotationApplication(
        AiNotationStatus.applied,
        strokes: <Stroke>[ink.strokes[2]],
      ),
    );
    addTearDown(ink.dispose);
    addTearDown(assistant.dispose);

    assistant
      ..setNotationEnabled(true)
      ..send('Draw a parabola');
    await pumpEventQueue();
    final AiRequest request = client.requests.single;
    expect(request.selectionSvg, isNull);
    expect(request.notationInstruction, endsWith(AiPrompts.noSelection));
    client.answerResponse(
      AiAssistantResponse(
        message: 'Here.',
        notation: AiNotation(
          label: 'Parabola',
          items: <AiNotationItem>[
            AiNotationStroke(
              ink: 'green',
              width: 3,
              points: const <AiNotationPoint>[
                AiNotationPoint(0.2, 0.2),
                AiNotationPoint(0.3, 0.3),
              ],
            ),
          ],
        ),
      ),
    );
    await pumpEventQueue();

    final AiSelectionContext page = assistant.context!;
    expect(page.logicalBounds, isNull);
    expect(assistant.notationStrokesIn(ink.strokes), <Stroke>[ink.strokes[2]]);

    // Another chat, then its notes selected again, resumes it.
    assistant.open(
      _selectionOf(ink, <int>[0]),
      brightness: Brightness.light,
      background: Colors.white,
    );
    await pumpEventQueue();
    expect(assistant.context!.isPage, isFalse);
    assistant.useSelection(
      _selectionOf(ink, <int>[2]),
      brightness: Brightness.light,
      background: Colors.white,
    );
    expect(assistant.context, same(page));
  });

  for (final AiQuickAction action in AiQuickAction.values) {
    test('${action.label} sends its exact prompt with the image', () async {
      await rig.open();

      expect(rig.assistant.sendQuickAction(action), isTrue);

      final AiRequest request = rig.client.requests.single;
      expect(
        request.systemInstruction,
        AiPrompts.systemFor(notationEnabled: false),
      );
      expect(request.imagePng, same(rig.assistant.context!.image!.png));
      expect(request.messages.single.role, AiRole.user);
      expect(request.messages.single.text, action.prompt);
      // The transcript shows the short label as a user message.
      expect(_texts(rig.assistant), <String>['user: ${action.label}']);
      expect(rig.assistant.requestState, AiRequestState.sending);
    });
  }

  test('the prompts teach the subject and keep their guard rails', () {
    expect(AiQuickAction.explain.label, 'Explain this');
    expect(AiQuickAction.grade.label, 'Grade this');
    // Explain teaches the subject of the ink; it does not describe the
    // picture.
    expect(AiPrompts.explain, startsWith('Teach me the subject'));
    expect(AiPrompts.explain, contains('what each part or component is'));
    expect(AiPrompts.explain, contains('Do not describe what the image'));
    // Unclear work is read the likeliest way and answered, not queried.
    expect(AiPrompts.explain, contains('go with the most likely reading'));
    expect(
      AiPrompts.grade,
      'Review the selected handwritten work for correctness. State what is '
      'correct, identify mistakes with specific explanations, and suggest '
      'an improved answer. If no question, answer key, rubric, or point '
      'total is visible, assume the most likely task, state that in one '
      'short line, and give full formative feedback rather than inventing '
      'an authoritative score.',
    );
    expect(AiPrompts.system, contains('teach that subject'));
    expect(AiPrompts.system, contains('do not describe the image'));
    expect(AiPrompts.system, contains('Never ask the user to confirm'));
    expect(AiPrompts.system, contains('do not invent facts'));
    expect(
      AiPrompts.system,
      contains('never claim an official grade without a provided rubric'),
    );

    final String drawing = AiPrompts.systemFor(notationEnabled: true);
    expect(drawing, contains('Interact with that SVG'));
    // The note stays the user's, and each stroke names its paragraph.
    expect(drawing, contains('existing-ink paths in the selected SVG'));
    expect(drawing, contains("annotate directly on the user's strokes"));
    expect(drawing, contains("do not redraw the user's note"));
    expect(drawing, contains('data-etonia-paragraph="N"'));
    expect(drawing, contains('data-etonia-line'));
    // Words become the user's own handwriting, kept as SVG paths.
    expect(drawing, contains('user-configured handwriting'));
    // How to annotate is the model's choice.
    expect(drawing, isNot(contains('sketching quickly')));
    expect(drawing, isNot(contains('margin note')));
  });

  test('typed messages and follow-ups carry the history in order', () async {
    await rig.open();

    expect(rig.assistant.send('  What is this?  '), isTrue);
    expect(rig.client.requests[0].messages.single.text, 'What is this?');
    rig.client.answer('A line.');
    await pumpEventQueue();
    expect(rig.assistant.requestState, AiRequestState.idle);

    rig.assistant.sendQuickAction(AiQuickAction.grade);
    rig.client.answer('Looks right.');
    await pumpEventQueue();
    rig.assistant.send('Why?');

    expect(
      <String>[
        for (final AiMessage message in rig.client.requests[2].messages)
          '${message.role.name}: ${message.text}',
      ],
      <String>[
        'user: What is this?',
        'model: A line.',
        'user: ${AiPrompts.grade}',
        'model: Looks right.',
        'user: Why?',
      ],
    );
    // The same image goes with every request.
    for (final AiRequest request in rig.client.requests) {
      expect(request.imagePng, same(rig.assistant.context!.image!.png));
    }
    expect(_texts(rig.assistant), <String>[
      'user: What is this?',
      'model: A line.',
      'user: Grade this',
      'model: Looks right.',
      'user: Why?',
    ]);
    expect(() => rig.assistant.messages.clear(), throwsUnsupportedError);
    expect(
      () => rig.client.requests.last.messages.clear(),
      throwsUnsupportedError,
    );
  });

  test('empty and whitespace messages are ignored', () async {
    await rig.open();
    final int notifications = rig.notifications;

    for (final String text in <String>['', '   ', '\n\t ']) {
      expect(rig.assistant.send(text), isFalse);
    }

    expect(rig.client.requests, isEmpty);
    expect(rig.assistant.messages, isEmpty);
    expect(rig.notifications, notifications);
  });

  test('a second send is refused while one is under way', () async {
    await rig.open();

    expect(rig.assistant.send('One'), isTrue);
    expect(rig.assistant.canSend, isFalse);
    expect(rig.assistant.send('Two'), isFalse);
    expect(rig.assistant.sendQuickAction(AiQuickAction.explain), isFalse);
    expect(rig.assistant.retry(), isFalse);

    expect(rig.client.requests, hasLength(1));
    expect(_texts(rig.assistant), <String>['user: One']);

    rig.client.answer('Done');
    await pumpEventQueue();
    expect(rig.assistant.send('Two'), isTrue);
    expect(rig.client.requests, hasLength(2));
  });

  test('a failure keeps the message, and Retry sends it once more', () async {
    await rig.open();
    rig.assistant.send('First');
    rig.client.answer('Answer');
    await pumpEventQueue();
    rig.assistant.send('Second');
    rig.client.fail(AiFailureKind.timeout);
    await pumpEventQueue();

    expect(rig.assistant.requestState, AiRequestState.failed);
    expect(rig.assistant.failure!.kind, AiFailureKind.timeout);
    // Nothing was retried behind the user's back, and nothing was lost.
    expect(rig.client.requests, hasLength(2));
    expect(_texts(rig.assistant), <String>[
      'user: First',
      'model: Answer',
      'user: Second',
    ]);

    expect(rig.assistant.retry(), isTrue);

    expect(rig.assistant.requestState, AiRequestState.sending);
    expect(rig.assistant.failure, isNull);
    expect(rig.client.requests, hasLength(3));
    expect(
      <String>[
        for (final AiMessage message in rig.client.requests[2].messages)
          message.text,
      ],
      <String>['First', 'Answer', 'Second'],
    );
    expect(rig.assistant.messages, hasLength(3));

    rig.client.fail(AiFailureKind.server);
    await pumpEventQueue();
    rig.assistant.retry();
    rig.client.answer('At last');
    await pumpEventQueue();

    expect(_texts(rig.assistant), <String>[
      'user: First',
      'model: Answer',
      'user: Second',
      'model: At last',
    ]);
    expect(rig.assistant.requestState, AiRequestState.idle);
    expect(rig.assistant.retry(), isFalse);
    expect(rig.client.requests, hasLength(4));
  });

  test('a new message replaces one that failed unanswered', () async {
    await rig.open();
    rig.assistant.send('First');
    rig.client.answer('Answer');
    await pumpEventQueue();
    rig.assistant.send('Blocked question');
    rig.client.fail(AiFailureKind.blocked);
    await pumpEventQueue();

    expect(rig.assistant.send('Another question'), isTrue);

    expect(_texts(rig.assistant), <String>[
      'user: First',
      'model: Answer',
      'user: Another question',
    ]);
    expect(
      rig.client.requests.last.messages.map((AiMessage m) => m.role),
      <AiRole>[AiRole.user, AiRole.model, AiRole.user],
    );
    expect(rig.assistant.failure, isNull);
  });

  test('a client that throws is a failure, not a crash', () async {
    final AiAssistantController assistant = AiAssistantController(
      client: _ThrowingClient(),
      renderer: rig.renderer,
    );
    addTearDown(assistant.dispose);
    assistant.open(
      selectInk(rig.ink, _top),
      brightness: Brightness.light,
      background: Colors.white,
    );
    await pumpEventQueue();

    assistant.send('Hello');
    await pumpEventQueue();

    expect(assistant.requestState, AiRequestState.failed);
    expect(assistant.failure!.kind, AiFailureKind.network);
    expect(assistant.messages, hasLength(1));
  });

  test('an answer to an inactive conversation is remembered', () async {
    await rig.open();
    rig.assistant.send('About the top line');
    final AiSelectionContext top = rig.assistant.context!;

    // A different selection activates a different conversation.
    await rig.open(_bottom);
    expect(rig.assistant.messages, isEmpty);
    expect(rig.assistant.requestState, AiRequestState.idle);
    rig.assistant.send('About the bottom line');

    rig.client.answer('Top answer', index: 0);
    await pumpEventQueue();

    expect(_texts(rig.assistant), <String>['user: About the bottom line']);
    expect(rig.assistant.requestState, AiRequestState.sending);

    rig.client.answer('Bottom answer', index: 1);
    await pumpEventQueue();
    expect(_texts(rig.assistant), <String>[
      'user: About the bottom line',
      'model: Bottom answer',
    ]);
    expect(
      rig.client.requests[0].imagePng,
      isNot(rig.client.requests[1].imagePng),
    );

    // Returning to the first ink resumes the answer that arrived while its
    // conversation was inactive.
    await rig.open(_top);
    expect(rig.assistant.context, same(top));
    expect(_texts(rig.assistant), <String>[
      'user: About the top line',
      'model: Top answer',
    ]);
  });

  test('a stale failure cannot mark the new conversation failed', () async {
    await rig.open();
    rig.assistant.send('Old');
    await rig.open(_bottom);

    rig.client.fail(AiFailureKind.server, index: 0);
    await pumpEventQueue();

    expect(rig.assistant.requestState, AiRequestState.idle);
    expect(rig.assistant.failure, isNull);
  });

  test('a changed selection is flagged, and the conversation kept', () async {
    final InkSelection first = await rig.open();
    rig.assistant.send('Question');
    rig.client.answer('Answer');
    await pumpEventQueue();
    final AiSelectionContext context = rig.assistant.context!;
    final SelectionImage image = context.image!;

    rig.assistant.updateCurrentSelection(first);
    expect(rig.assistant.selectionChanged, isFalse);

    final InkSelection second = selectInk(rig.ink, _bottom);
    rig.assistant.updateCurrentSelection(second);

    expect(rig.assistant.selectionChanged, isTrue);
    expect(rig.assistant.context, same(context));
    expect(rig.assistant.context!.image, same(image));
    expect(rig.assistant.messages, hasLength(2));
    expect(rig.renderer.snapshots, hasLength(1));

    // Moving the selected ink makes it different ink too.
    selectInk(rig.ink, _top);
    rig.ink
      ..beginSelectionGesture(pointer: 1, position: const InkVector(150, 100))
      ..endSelectionGesture(1, const InkVector(170, 130));
    rig.assistant.updateCurrentSelection(rig.ink.selection);
    expect(rig.assistant.selectionChanged, isTrue);
    expect(rig.assistant.context!.image, same(image));

    // With nothing selected there is nothing else to offer.
    rig.ink.clearSelection();
    rig.assistant.updateCurrentSelection(null);
    expect(rig.assistant.selectionChanged, isFalse);
    expect(rig.assistant.messages, hasLength(2));
    expect(rig.assistant.context, same(context));
  });

  test(
    'Use current selection switches threads without mixing requests',
    () async {
      await rig.open();
      rig.assistant.send('Old question');
      final AiSelectionContext old = rig.assistant.context!;
      final InkSelection second = selectInk(rig.ink, _bottom);
      rig.assistant.updateCurrentSelection(second);
      expect(rig.assistant.selectionChanged, isTrue);

      rig.assistant.useSelection(
        second,
        brightness: Brightness.light,
        background: Colors.white,
      );
      await pumpEventQueue();

      expect(rig.assistant.selectionChanged, isFalse);
      expect(rig.assistant.context, isNot(same(old)));
      expect(rig.assistant.context!.snapshot.isOf(second), isTrue);
      expect(rig.assistant.messages, isEmpty);
      expect(rig.assistant.requestState, AiRequestState.idle);
      expect(rig.assistant.isOpen, isTrue);
      // Switching sent nothing new.
      expect(rig.client.requests, hasLength(1));

      rig.client.answer('Old answer', index: 0);
      await pumpEventQueue();
      expect(rig.assistant.messages, isEmpty);

      await rig.open(_top);
      expect(rig.assistant.context, same(old));
      expect(_texts(rig.assistant), <String>[
        'user: Old question',
        'model: Old answer',
      ]);
    },
  );

  test('Add to context keeps the chat and sends the ink together', () async {
    await rig.open();
    rig.assistant.send('Question');
    rig.client.answer('Answer');
    await pumpEventQueue();
    final AiSelectionContext old = rig.assistant.context!;
    final InkSelection second = selectInk(rig.ink, _bottom);
    rig.assistant.updateCurrentSelection(second);
    expect(rig.assistant.selectionChanged, isTrue);
    expect(rig.assistant.selectionHasChat, isFalse);

    rig.assistant.addToContext(second);
    await pumpEventQueue();

    expect(rig.assistant.selectionChanged, isFalse);
    expect(rig.assistant.context, isNot(same(old)));
    expect(rig.assistant.context!.snapshot.strokes, hasLength(2));
    expect(rig.assistant.context!.snapshot.brightness, Brightness.light);
    expect(_texts(rig.assistant), <String>['user: Question', 'model: Answer']);
    expect(rig.renderer.snapshots, hasLength(2));

    // Either line, or both, now finds this conversation.
    rig.assistant.updateCurrentSelection(second);
    expect(rig.assistant.selectionChanged, isFalse);
    rig.assistant.send('And now?');
    expect(
      rig.client.requests.last.imagePng,
      same(rig.assistant.context!.image!.png),
    );
    expect(rig.client.requests.last.messages, hasLength(3));
    await rig.open(_bottom);
    expect(rig.assistant.messages, hasLength(3));

    // Adding what is already there changes nothing.
    final AiSelectionContext merged = rig.assistant.context!;
    rig.assistant.addToContext(second);
    expect(rig.assistant.context, same(merged));
  });

  test('removing a context group narrows the next model request', () async {
    await rig.open();
    final AiContextGroup first = rig.assistant.context!.groups.single;
    final InkSelection second = selectInk(rig.ink, _bottom);

    rig.assistant.addToContext(second);
    await pumpEventQueue();
    expect(rig.assistant.context!.snapshot.sourceStrokeCount, 2);

    rig.assistant.removeContext(first);
    await pumpEventQueue();

    final AiSelectionContext narrowed = rig.assistant.context!;
    expect(narrowed.groups, hasLength(1));
    expect(narrowed.snapshot.isOf(second), isTrue);
    expect(narrowed.snapshot.sourceStrokeCount, 1);
    expect(rig.assistant.send('Use only the remaining context'), isTrue);
    expect(rig.client.requests.single.imagePng, same(narrowed.image!.png));

    rig.assistant.removeContext(narrowed.groups.single);
    expect(rig.assistant.context!.isPage, isTrue);
    expect(rig.assistant.hasSelection, isFalse);
    expect(
      rig.assistant.messages.single.text,
      'Use only the remaining context',
    );
  });

  test('a selection with a remembered chat is flagged as such', () async {
    await rig.open(_bottom);
    await rig.open(_top);
    rig.assistant.updateCurrentSelection(selectInk(rig.ink, _bottom));

    expect(rig.assistant.selectionChanged, isTrue);
    expect(rig.assistant.selectionHasChat, isTrue);
  });

  test('strokes an answer drew belong to its conversation', () async {
    final InkController ink = InkController(
      strokes: <Stroke>[_line(100), _line(300), _line(500), _line(520)],
    );
    final FakeAiClient client = FakeAiClient();
    final FakeSelectionImageRenderer renderer = FakeSelectionImageRenderer();
    final AiAssistantController assistant = AiAssistantController(
      client: client,
      renderer: renderer,
      animationEnabled: false,
      captureNote: () async =>
          NoteImage(logicalSize: const Size(10, 10), revision: 0),
      // Stands in for the editor, which reports the strokes it added.
      applyNotation: (AiNotation _, NoteImage _) => AiNotationApplication(
        AiNotationStatus.applied,
        strokes: <Stroke>[ink.strokes[2], ink.strokes[3]],
      ),
    );
    addTearDown(ink.dispose);
    addTearDown(assistant.dispose);

    assistant.open(
      _selectionOf(ink, <int>[0]),
      brightness: Brightness.light,
      background: Colors.white,
    );
    await pumpEventQueue();
    final AiSelectionContext drawn = assistant.context!;
    assistant
      ..setNotationEnabled(true)
      ..send('Draw');
    await pumpEventQueue();
    client.answerResponse(
      AiAssistantResponse(
        message: 'Drawn.',
        notation: AiNotation(
          label: 'Lines',
          items: <AiNotationItem>[
            AiNotationStroke(
              ink: 'green',
              width: 3,
              points: const <AiNotationPoint>[
                AiNotationPoint(0.2, 0.2),
                AiNotationPoint(0.3, 0.3),
              ],
            ),
          ],
        ),
      ),
    );
    await pumpEventQueue();

    // The conversation preview/range now includes all returned notation,
    // while its matching identity still comes only from the original ink.
    expect(renderer.snapshots.last.strokes, hasLength(3));
    expect(assistant.context!.snapshot.sourceStrokeCount, 1);

    // Only the drawing is selected: still the same chat, not a new one.
    assistant.updateCurrentSelection(_selectionOf(ink, <int>[2, 3]));
    expect(assistant.selectionChanged, isFalse);
    assistant.open(
      _selectionOf(ink, <int>[1]),
      brightness: Brightness.light,
      background: Colors.white,
    );
    await pumpEventQueue();
    expect(assistant.context, isNot(same(drawn)));
    assistant.open(
      _selectionOf(ink, <int>[3]),
      brightness: Brightness.light,
      background: Colors.white,
    );
    expect(assistant.context, same(drawn));
    expect(_texts(assistant), <String>['user: Draw', 'model: Drawn.']);

    // Adding the drawing to the chat does not draw it into the image twice.
    assistant.addToContext(_selectionOf(ink, <int>[0, 2, 3]));
    expect(assistant.context, same(drawn));
  });

  group('opening with nothing selected', () {
    final Object pageOne = Object();
    final Object pageTwo = Object();
    late Object shown;
    late AiAssistantController assistant;

    setUp(() {
      shown = pageOne;
      assistant = AiAssistantController(
        client: rig.client,
        renderer: rig.renderer,
        shownPage: () => shown,
      );
      addTearDown(assistant.dispose);
    });

    Future<void> answer(String question) async {
      assistant.send(question);
      rig.client.answer('Answer');
      await pumpEventQueue();
    }

    test('resumes a chat had on the page shown', () async {
      assistant.show();
      await answer('Question');
      final AiSelectionContext context = assistant.context!;

      assistant
        ..close()
        ..show();

      expect(assistant.isOpen, isTrue);
      expect(assistant.context, same(context));
      expect(_texts(assistant), <String>['user: Question', 'model: Answer']);
    });

    test(
      'does not resume a chat had on another page, until back there',
      () async {
        assistant.show();
        await answer('Question');
        final AiSelectionContext context = assistant.context!;
        assistant.close();

        shown = pageTwo;
        assistant.show();
        expect(assistant.isOpen, isTrue);
        expect(assistant.context, isNull);
        expect(assistant.messages, isEmpty);
        assistant.close();

        shown = pageOne;
        assistant.show();
        expect(assistant.context, same(context));
        expect(_texts(assistant), <String>['user: Question', 'model: Answer']);
      },
    );

    test('a chat about ink lies on the page that ink was chosen on', () async {
      assistant.open(
        selectInk(rig.ink, _top),
        brightness: Brightness.light,
        background: Colors.white,
        page: pageOne,
      );
      await pumpEventQueue();
      final AiSelectionContext context = assistant.context!;
      assistant.close();

      shown = pageTwo;
      assistant.show();
      expect(assistant.context, isNull);
      assistant.close();

      shown = pageOne;
      assistant.show();
      expect(assistant.context, same(context));
    });

    test('a chat continued on another page lies there too', () async {
      assistant.show();
      await answer('First');
      shown = pageTwo;
      await answer('Second');
      final AiSelectionContext context = assistant.context!;

      assistant
        ..close()
        ..show();
      expect(assistant.context, same(context));
      assistant.close();

      shown = pageOne;
      assistant.show();
      expect(assistant.context, same(context));
    });

    test(
      'a chat started on the new page is the last one from then on',
      () async {
        assistant.show();
        await answer('On one');
        assistant.close();

        shown = pageTwo;
        assistant.show();
        await answer('On two');
        final AiSelectionContext two = assistant.context!;
        expect(_texts(assistant), <String>['user: On two', 'model: Answer']);
        assistant.close();

        shown = pageOne;
        assistant.show();
        expect(assistant.context, isNull);
        assistant.close();

        shown = pageTwo;
        assistant.show();
        expect(assistant.context, same(two));
      },
    );

    test('an answer arriving for the chat left behind is kept', () async {
      assistant.show();
      assistant.send('Question');
      assistant.close();

      shown = pageTwo;
      assistant.show();
      expect(assistant.requestState, AiRequestState.idle);
      rig.client.answer('Answer');
      await pumpEventQueue();
      expect(assistant.messages, isEmpty);
      assistant.close();

      shown = pageOne;
      assistant.show();
      expect(_texts(assistant), <String>['user: Question', 'model: Answer']);
    });
  });

  test('closing keeps everything; the same selection reopens it', () async {
    final InkSelection selection = await rig.open();
    rig.assistant
      ..setSide(AiPanelSide.left)
      ..draft = 'half a thought'
      ..send('Question');
    final AiSelectionContext context = rig.assistant.context!;

    rig.assistant.close();
    expect(rig.assistant.isOpen, isFalse);
    // The answer arrives while the panel is closed, and is kept.
    rig.client.answer('Answer');
    await pumpEventQueue();

    // Copying does not make it a different selection.
    rig.ink.copySelection();
    rig.assistant.open(
      rig.ink.selection!,
      brightness: Brightness.dark,
      background: Colors.black,
    );
    await pumpEventQueue();

    expect(rig.ink.selection, same(selection));
    expect(rig.assistant.isOpen, isTrue);
    expect(rig.assistant.side, AiPanelSide.left);
    expect(rig.assistant.draft, 'half a thought');
    expect(rig.assistant.context, same(context));
    // The image is the one captured first, in the theme it was captured in.
    expect(rig.assistant.context!.snapshot.brightness, Brightness.light);
    expect(_texts(rig.assistant), <String>['user: Question', 'model: Answer']);
    expect(rig.renderer.snapshots, hasLength(1));
    expect(rig.client.requests, hasLength(1));
  });

  test('the same strokes selected again are the same conversation', () async {
    await rig.open();
    rig.assistant.send('Question');
    rig.ink.clearSelection();

    await rig.open();

    expect(rig.assistant.messages, hasLength(1));
    expect(rig.renderer.snapshots, hasLength(1));
  });

  test(
    'more than half of remembered strokes resumes its conversation',
    () async {
      final InkController ink = InkController(
        strokes: <Stroke>[for (int i = 0; i < 7; i++) _line(i * 40.0)],
      );
      final FakeAiClient client = FakeAiClient();
      final FakeSelectionImageRenderer renderer = FakeSelectionImageRenderer();
      final AiAssistantController assistant = AiAssistantController(
        client: client,
        renderer: renderer,
      );
      addTearDown(ink.dispose);
      addTearDown(assistant.dispose);

      assistant.open(
        _selectionOf(ink, <int>[0, 1, 2]),
        brightness: Brightness.light,
        background: Colors.white,
      );
      await pumpEventQueue();
      final AiSelectionContext remembered = assistant.context!;
      assistant.send('Remember this');
      client.answer('Remembered');
      await pumpEventQueue();

      assistant.open(
        _selectionOf(ink, <int>[6]),
        brightness: Brightness.light,
        background: Colors.white,
      );
      await pumpEventQueue();
      assistant.open(
        // Two of the three remembered strokes, but only half of this selection.
        _selectionOf(ink, <int>[0, 1, 3, 4]),
        brightness: Brightness.light,
        background: Colors.white,
      );

      expect(assistant.context, same(remembered));
      expect(_texts(assistant), <String>[
        'user: Remember this',
        'model: Remembered',
      ]);
      expect(renderer.snapshots, hasLength(2));
    },
  );

  test(
    '51 percent of the current selection resumes its conversation',
    () async {
      final InkController ink = InkController(
        strokes: <Stroke>[for (int i = 0; i < 7; i++) _line(i * 40.0)],
      );
      final FakeSelectionImageRenderer renderer = FakeSelectionImageRenderer();
      final AiAssistantController assistant = AiAssistantController(
        client: rig.client,
        renderer: renderer,
      );
      addTearDown(ink.dispose);
      addTearDown(assistant.dispose);

      assistant.open(
        _selectionOf(ink, <int>[0, 1, 2, 3]),
        brightness: Brightness.light,
        background: Colors.white,
      );
      await pumpEventQueue();
      final AiSelectionContext remembered = assistant.context!;
      assistant.open(
        _selectionOf(ink, <int>[6]),
        brightness: Brightness.light,
        background: Colors.white,
      );
      await pumpEventQueue();
      assistant.open(
        // Half of the remembered strokes, but two thirds of this selection.
        _selectionOf(ink, <int>[0, 1, 4]),
        brightness: Brightness.light,
        background: Colors.white,
      );

      expect(assistant.context, same(remembered));
      expect(renderer.snapshots, hasLength(2));
    },
  );

  test('exactly half on both sides starts a new conversation', () async {
    final InkController ink = InkController(
      strokes: <Stroke>[for (int i = 0; i < 7; i++) _line(i * 40.0)],
    );
    final FakeSelectionImageRenderer renderer = FakeSelectionImageRenderer();
    final AiAssistantController assistant = AiAssistantController(
      client: rig.client,
      renderer: renderer,
    );
    addTearDown(ink.dispose);
    addTearDown(assistant.dispose);

    assistant.open(
      _selectionOf(ink, <int>[0, 1, 2, 3]),
      brightness: Brightness.light,
      background: Colors.white,
    );
    await pumpEventQueue();
    final AiSelectionContext first = assistant.context!;
    assistant.open(
      _selectionOf(ink, <int>[0, 1, 4, 5]),
      brightness: Brightness.light,
      background: Colors.white,
    );
    await pumpEventQueue();

    expect(assistant.context, isNot(same(first)));
    expect(renderer.snapshots, hasLength(2));
  });

  test('placement notifies only for opening, closing, and side', () async {
    final List<AiPanelPlacement> placements = <AiPanelPlacement>[];
    rig.assistant.placement.addListener(
      () => placements.add(rig.assistant.placement.value),
    );

    await rig.open();
    rig.assistant.send('Question');
    rig.client.answer('Answer');
    await pumpEventQueue();
    rig.assistant.setSide(AiPanelSide.left);
    rig.assistant.setSide(AiPanelSide.right);
    rig.assistant.close();

    expect(placements, const <AiPanelPlacement>[
      AiPanelPlacement(isOpen: true, side: AiPanelSide.left),
      AiPanelPlacement(isOpen: true, side: AiPanelSide.right),
      AiPanelPlacement(isOpen: false, side: AiPanelSide.right),
    ]);
  });

  test('without a key the assistant opens but cannot send', () async {
    rig.dispose();
    rig = _Rig(configured: false);
    await rig.open();

    expect(rig.assistant.isOpen, isTrue);
    expect(rig.assistant.isConfigured, isFalse);
    expect(rig.assistant.context!.image, isNotNull);
    expect(rig.assistant.canSend, isFalse);
    expect(rig.assistant.send('Hello'), isFalse);
    expect(rig.assistant.sendQuickAction(AiQuickAction.explain), isFalse);
    expect(rig.client.requests, isEmpty);
    expect(rig.assistant.messages, isEmpty);
  });

  test(
    'an image that cannot be made is reported, and nothing is sent',
    () async {
      rig.renderer.error = const SelectionImageException(
        SelectionImageFailure.tooLarge,
      );
      await rig.open();

      expect(rig.assistant.context!.image, isNull);
      expect(rig.assistant.context!.isRendering, isFalse);
      expect(
        rig.assistant.context!.imageError!.failure,
        SelectionImageFailure.tooLarge,
      );
      expect(rig.assistant.send('Hello'), isFalse);
      expect(rig.client.requests, isEmpty);
    },
  );

  test('an image finished for a replaced selection changes nothing', () async {
    rig.renderer.gate = Completer<void>();
    await rig.open();
    final AiSelectionContext first = rig.assistant.context!;
    await rig.open(_bottom);
    final int notifications = rig.notifications;

    rig.renderer.gate!.complete();
    await pumpEventQueue();

    // Only the current context's image is announced.
    expect(rig.notifications, notifications + 1);
    expect(rig.assistant.context, isNot(same(first)));
    expect(rig.assistant.context!.image, isNotNull);
  });

  test('disposing mid-capture and mid-request is safe and silent', () async {
    rig.renderer.gate = Completer<void>();
    rig.assistant.open(
      selectInk(rig.ink, _top),
      brightness: Brightness.light,
      background: Colors.white,
    );
    final int beforeCapture = rig.notifications;
    rig.dispose();
    rig.renderer.gate!.complete();
    await pumpEventQueue();
    expect(rig.notifications, beforeCapture);

    rig = _Rig();
    await rig.open();
    rig.assistant.send('Question');
    final int beforeAnswer = rig.notifications;
    final AiAssistantController assistant = rig.assistant;
    final FakeAiClient client = rig.client;
    rig.dispose();
    client.answer('Too late');
    await pumpEventQueue();

    expect(rig.notifications, beforeAnswer);
    // Nothing more is accepted either.
    expect(assistant.send('Again'), isFalse);
    expect(assistant.retry(), isFalse);
    expect(client.requests, hasLength(1));
  });

  test(
    'Notation captures note context and applies a structured response',
    () async {
      final FakeAiClient client = FakeAiClient();
      final FakeSelectionImageRenderer renderer = FakeSelectionImageRenderer();
      final NoteImage note = NoteImage(
        logicalSize: const Size(100, 50),
        revision: 4,
      );
      int applications = 0;
      final AiAssistantController assistant = AiAssistantController(
        client: client,
        renderer: renderer,
        animationEnabled: false,
        captureNote: () async => note,
        applyNotation: (AiNotation notation, NoteImage context) {
          applications++;
          expect(context, same(note));
          expect(notation.label, 'Check mark');
          // With Animation off, even timed provider output is handed to the
          // editor as ordinary static notation.
          expect(notation.timeline, isNull);
          return const AiNotationApplication(AiNotationStatus.applied);
        },
      );
      addTearDown(assistant.dispose);
      assistant.open(
        selectInk(rig.ink, _top),
        brightness: Brightness.light,
        background: Colors.white,
      );
      await pumpEventQueue();
      assistant
        ..setNotationEnabled(true)
        ..send('Mark this');
      await pumpEventQueue();

      expect(client.requests.single.notationEnabled, isTrue);
      expect(client.requests.single.animationEnabled, isFalse);
      expect(client.requests.single.noteImage, same(note));
      expect(
        client.requests.single.imagePng,
        same(assistant.context!.image!.png),
      );
      expect(client.requests.single.selectionSvg, startsWith('<svg'));
      expect(client.requests.single.selectionSvg, contains('<path'));
      expect(
        client.requests.single.selectionSvg,
        contains('viewBox="0 0 100 50"'),
      );
      expect(client.requests.single.systemInstruction, AiPrompts.textSystem);
      expect(
        client.requests.single.systemInstruction,
        contains('include only title and the message desc'),
      );
      expect(
        client.requests.single.notationInstruction,
        contains('Notation is on'),
      );
      client.answerResponse(
        AiAssistantResponse(
          message: 'Done.',
          notation: AiNotation(
            label: 'Check mark',
            items: <AiNotationItem>[
              AiNotationStroke(
                ink: 'green',
                width: 3,
                points: const <AiNotationPoint>[
                  AiNotationPoint(0.2, 0.2),
                  AiNotationPoint(0.3, 0.3),
                ],
              ),
            ],
            timeline: AiNotationTimeline(
              durationMs: 500,
              items: const <AiItemTiming>[AiItemTiming(0, 400)],
            ),
          ),
        ),
      );
      await pumpEventQueue();

      expect(applications, 1);
      expect(assistant.messages.last.text, 'Done.');
      expect(assistant.messages.last.notationStatus, AiNotationStatus.applied);
    },
  );

  test(
    'notation status changes from animating to applied exactly once',
    () async {
      final FakeAiClient client = FakeAiClient();
      final _ManualPresentation presentation = _ManualPresentation();
      int applications = 0;
      int notifications = 0;
      final AiAssistantController assistant = AiAssistantController(
        client: client,
        renderer: FakeSelectionImageRenderer(),
        captureNote: () async =>
            NoteImage(logicalSize: const Size(10, 10), revision: 0),
        applyNotation: (AiNotation notation, NoteImage _) {
          applications++;
          expect(notation.timeline, isNotNull);
          return AiNotationApplication(
            AiNotationStatus.animating,
            presentation: presentation,
          );
        },
      )..addListener(() => notifications++);
      addTearDown(assistant.dispose);
      assistant.open(
        selectInk(rig.ink, _top),
        brightness: Brightness.light,
        background: Colors.white,
      );
      await pumpEventQueue();
      assistant
        ..setNotationEnabled(true)
        ..setAnimationEnabled(true)
        ..send('Draw');
      await pumpEventQueue();
      client.answerResponse(
        AiAssistantResponse(
          message: 'Done.',
          notation: AiNotation(
            label: 'Current flow',
            items: <AiNotationItem>[
              AiNotationStroke(
                ink: 'blue',
                width: 3,
                points: const <AiNotationPoint>[
                  AiNotationPoint(0.2, 0.2),
                  AiNotationPoint(0.3, 0.3),
                ],
              ),
            ],
            timeline: AiNotationTimeline(
              durationMs: 500,
              items: const <AiItemTiming>[AiItemTiming(0, 400)],
            ),
          ),
        ),
      );
      await pumpEventQueue();

      expect(applications, 1);
      expect(assistant.isDrawingNotation, isTrue);
      expect(client.requests.single.animationEnabled, isTrue);
      expect(assistant.messages, hasLength(2));
      final String wireText = assistant.messages.last.wireText;
      expect(
        assistant.messages.last.notationStatus,
        AiNotationStatus.animating,
      );

      assistant.close();
      await pumpEventQueue();
      expect(assistant.isDrawingNotation, isTrue);
      expect(presentation.finishes, 0);

      final int beforeCompletion = notifications;
      presentation.complete();
      await pumpEventQueue();

      expect(assistant.isDrawingNotation, isFalse);
      expect(assistant.messages, hasLength(2));
      expect(assistant.messages.last.notationStatus, AiNotationStatus.applied);
      expect(assistant.messages.last.wireText, wireText);
      expect(applications, 1);
      expect(notifications, beforeCompletion + 1);

      // Completing and finishing again cannot add a turn or apply it again.
      presentation.complete();
      assistant.finishNotationDrawing();
      await pumpEventQueue();
      expect(assistant.messages, hasLength(2));
      expect(applications, 1);
      expect(notifications, beforeCompletion + 1);
      expect(presentation.finishes, 0);
    },
  );

  for (final bool reenable in <bool>[false, true]) {
    test('turning Notation off in flight revokes mutation authority'
        '${reenable ? ', even if it is turned back on' : ''}', () async {
      final FakeAiClient client = FakeAiClient();
      int applications = 0;
      final AiAssistantController assistant = AiAssistantController(
        client: client,
        renderer: FakeSelectionImageRenderer(),
        captureNote: () async =>
            NoteImage(logicalSize: const Size(10, 10), revision: 0),
        applyNotation: (AiNotation _, NoteImage _) {
          applications++;
          return const AiNotationApplication(AiNotationStatus.applied);
        },
      );
      addTearDown(assistant.dispose);
      assistant.open(
        selectInk(rig.ink, _top),
        brightness: Brightness.light,
        background: Colors.white,
      );
      await pumpEventQueue();
      assistant
        ..setNotationEnabled(true)
        ..send('Draw');
      await pumpEventQueue();
      assistant.setNotationEnabled(false);
      if (reenable) {
        assistant.setNotationEnabled(true);
      }
      client.answerResponse(
        AiAssistantResponse(
          message: 'I prepared a mark.',
          notation: AiNotation(
            label: 'Mark',
            items: <AiNotationItem>[
              AiNotationStroke(
                ink: 'red',
                width: 2,
                points: const <AiNotationPoint>[AiNotationPoint(0.5, 0.5)],
              ),
            ],
          ),
        ),
      );
      await pumpEventQueue();

      expect(applications, 0);
      expect(
        assistant.messages.last.notationStatus,
        AiNotationStatus.notAppliedRevoked,
      );
    });
  }

  test('provider notation on an off-mode request is discarded', () async {
    final FakeAiClient client = FakeAiClient();
    int captures = 0;
    int applications = 0;
    final AiAssistantController assistant = AiAssistantController(
      client: client,
      renderer: FakeSelectionImageRenderer(),
      captureNote: () async {
        captures++;
        throw StateError('off mode must not capture the note');
      },
      applyNotation: (AiNotation _, NoteImage _) {
        applications++;
        return const AiNotationApplication(AiNotationStatus.applied);
      },
    );
    addTearDown(assistant.dispose);
    assistant.open(
      selectInk(rig.ink, _top),
      brightness: Brightness.light,
      background: Colors.white,
    );
    await pumpEventQueue();
    assistant.send('Answer only');
    await pumpEventQueue();

    expect(client.requests.single.notationEnabled, isFalse);
    expect(client.requests.single.noteImage, isNull);
    expect(
      client.requests.single.systemInstruction,
      contains('Notation is off'),
    );
    client.answerResponse(
      AiAssistantResponse(
        message: 'Here is the answer.',
        notation: AiNotation(
          label: 'Unauthorized mark',
          items: <AiNotationItem>[
            AiNotationStroke(
              ink: 'red',
              width: 2,
              points: const <AiNotationPoint>[AiNotationPoint(0.5, 0.5)],
            ),
          ],
        ),
      ),
    );
    await pumpEventQueue();

    expect(captures, 0);
    expect(applications, 0);
    expect(assistant.messages.last.text, 'Here is the answer.');
    expect(assistant.messages.last.notation, isNull);
    expect(
      assistant.messages.last.notationStatus,
      AiNotationStatus.notAppliedNotationOff,
    );
    expect(assistant.messages.last.wireText, contains('"notation":null'));
  });
}

void _streamingTests() {
  late _Rig rig;

  setUp(() => rig = _Rig());
  tearDown(() => rig.dispose());

  test('the answer shows as it streams, then becomes a message', () async {
    await rig.open();
    rig.assistant.sendQuickAction(AiQuickAction.explain);
    expect(rig.assistant.partialAnswer, isNull);
    expect(rig.assistant.sendingWithNotation, isFalse);

    final int before = rig.notifications;
    rig.client.stream('Two');
    rig.client.stream('Two lines');
    // The same text again is not news.
    rig.client.stream('Two lines');
    rig.client.stream('Two lines.', isComplete: true);

    expect(rig.notifications, before + 3);
    expect(rig.assistant.partialAnswer, 'Two lines.');
    expect(rig.assistant.partialAnswerComplete, isTrue);
    expect(rig.assistant.requestState, AiRequestState.sending);
    // Not part of the conversation until the whole answer is in.
    expect(_texts(rig.assistant), <String>['user: Explain this']);

    rig.client.answer('Two lines.');
    await pumpEventQueue();

    expect(rig.assistant.partialAnswer, isNull);
    expect(rig.assistant.partialAnswerComplete, isFalse);
    expect(_texts(rig.assistant), <String>[
      'user: Explain this',
      'model: Two lines.',
    ]);
  });

  group('notation shown as it is written', () {
    late FakeAiClient client;
    late List<String> events;
    late AiAssistantController assistant;
    final NoteImage note = NoteImage(
      logicalSize: const Size(100, 50),
      revision: 0,
    );

    setUp(() {
      client = FakeAiClient();
      events = <String>[];
      assistant = AiAssistantController(
        client: client,
        renderer: FakeSelectionImageRenderer(),
        animationEnabled: false,
        captureNote: () async => note,
        applyNotation: (AiNotation _, NoteImage _) {
          events.add('apply');
          return const AiNotationApplication(AiNotationStatus.applied);
        },
        previewNotation: (String svg, NoteImage context) {
          expect(context, same(note));
          events.add(svg);
        },
        endNotationPreview: (NoteImage context) {
          expect(context, same(note));
          events.add('end');
        },
      );
      addTearDown(assistant.dispose);
    });

    AiNotation notation() => AiNotation(
      label: 'Line',
      items: <AiNotationItem>[
        AiNotationStroke(
          ink: 'green',
          width: 3,
          points: const <AiNotationPoint>[
            AiNotationPoint(.1, .1),
            AiNotationPoint(.2, .2),
          ],
        ),
      ],
    );

    test('is replaced by the notes it became', () async {
      assistant
        ..setNotationEnabled(true)
        ..send('Draw');
      await pumpEventQueue();
      client.streamNotation('<svg>');
      client.streamNotation('<svg><g/>');
      client.answerResponse(
        AiAssistantResponse(message: 'Here.', notation: notation()),
      );
      await pumpEventQueue();
      expect(events, <String>['<svg>', '<svg><g/>', 'apply', 'end']);
    });

    test('goes away when the answer fails', () async {
      assistant
        ..setNotationEnabled(true)
        ..send('Draw');
      await pumpEventQueue();
      client.streamNotation('<svg>');
      client.fail(AiFailureKind.server);
      await pumpEventQueue();
      expect(events, <String>['<svg>', 'end']);
    });

    test('stops when Notation is turned off part way', () async {
      assistant
        ..setNotationEnabled(true)
        ..send('Draw');
      await pumpEventQueue();
      client.streamNotation('<svg>');
      assistant.setNotationEnabled(false);
      client.streamNotation('<svg><g/>');
      expect(events, <String>['<svg>', 'end']);
    });

    test('is not asked for with Notation off', () async {
      assistant.send('Draw');
      await pumpEventQueue();
      client.streamNotation('<svg>');
      client.answer('Words.');
      await pumpEventQueue();
      expect(events, isEmpty);
    });
  });

  test('a failure part way drops what had streamed', () async {
    await rig.open();
    rig.assistant.send('Question');
    rig.client.stream('Half an ans');

    rig.client.fail(AiFailureKind.server);
    await pumpEventQueue();

    expect(rig.assistant.partialAnswer, isNull);
    expect(rig.assistant.requestState, AiRequestState.failed);
    expect(_texts(rig.assistant), <String>['user: Question']);
  });

  for (final bool notation in <bool>[true, false]) {
    test('words that all arrived are kept when the drawing breaks off '
        '(Notation ${notation ? 'on' : 'off'})', () async {
      int applications = 0;
      final AiAssistantController assistant = AiAssistantController(
        client: rig.client,
        renderer: rig.renderer,
        captureNote: () async =>
            NoteImage(logicalSize: const Size(10, 10), revision: 0),
        applyNotation: (AiNotation _, NoteImage _) {
          applications++;
          return const AiNotationApplication(AiNotationStatus.applied);
        },
      );
      addTearDown(assistant.dispose);
      assistant.open(
        selectInk(rig.ink, _top),
        brightness: Brightness.light,
        background: Colors.white,
      );
      await pumpEventQueue();
      assistant
        ..setNotationEnabled(notation)
        ..send('Solve it');
      await pumpEventQueue();
      rig.client.stream('x = 3, because 5 − 2 = 3.', isComplete: true);

      rig.client.fail(AiFailureKind.timeout);
      await pumpEventQueue();

      expect(assistant.requestState, AiRequestState.idle);
      expect(assistant.failure, isNull);
      expect(assistant.messages.last.role, AiRole.model);
      expect(assistant.messages.last.text, 'x = 3, because 5 − 2 = 3.');
      expect(assistant.messages.last.notation, isNull);
      expect(
        assistant.messages.last.notationStatus,
        notation
            ? AiNotationStatus.notAppliedIncomplete
            : AiNotationStatus.none,
      );
      expect(assistant.messages.last.wireText, contains('"notation":null'));
      expect(applications, 0);
    });
  }

  test('words still arriving when it breaks off are not kept', () async {
    await rig.open();
    rig.assistant.send('Question');
    rig.client.stream('x = 3, beca');

    rig.client.fail(AiFailureKind.timeout);
    await pumpEventQueue();

    expect(rig.assistant.requestState, AiRequestState.failed);
    expect(rig.assistant.failure!.kind, AiFailureKind.timeout);
    expect(_texts(rig.assistant), <String>['user: Question']);
  });

  test('a blocked answer is withheld even after its words', () async {
    await rig.open();
    rig.assistant.send('Question');
    rig.client.stream('Some words.', isComplete: true);

    rig.client.fail(AiFailureKind.blocked);
    await pumpEventQueue();

    expect(rig.assistant.requestState, AiRequestState.failed);
    expect(_texts(rig.assistant), <String>['user: Question']);
  });

  test('a replaced conversation streams nothing into the new one', () async {
    await rig.open();
    rig.assistant.send('About the top line');
    rig.client.stream('Top');
    await rig.open(_bottom);
    expect(rig.assistant.partialAnswer, isNull);

    final int before = rig.notifications;
    rig.client.stream('Top answer, still coming', index: 0);

    expect(rig.assistant.partialAnswer, isNull);
    expect(rig.notifications, before);
  });
}

class _ThrowingClient implements AiClient {
  @override
  bool get isConfigured => true;

  @override
  String get modelLabel => 'Broken';

  @override
  Future<AiResult> send(
    AiRequest request, {
    AiPartialCallback? onPartial,
    AiNotationPartialCallback? onNotation,
  }) async => throw StateError('boom');

  @override
  void close() {}
}
