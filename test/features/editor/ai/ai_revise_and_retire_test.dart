import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_assistant_controller.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/document_io/document_models.dart';

import '../../../helpers/ai_fakes.dart';

Stroke _line(double y) {
  return Stroke.fromPoints(
    style: const StrokeStyle(ink: InkPalette.ink, width: 4),
    points: <InkVector>[InkVector(100, y), InkVector(200, y)],
  );
}

AiInkIndex _indexOf(InkController ink) {
  return AiInkIndex(<(List<Stroke>, List<NoteImageElement>)>[
    (ink.strokes, ink.images),
  ]);
}

List<String> _texts(AiAssistantController assistant) => <String>[
  for (final AiMessage message in assistant.messages)
    '${message.role.name}: ${message.displayText}',
];

void main() {
  late InkController ink;
  late FakeAiClient client;
  late AiAssistantController assistant;
  var disposed = false;

  Future<void> open() async {
    assistant.open(
      selectInk(ink, const Rect.fromLTRB(90, 90, 210, 110)),
      brightness: Brightness.light,
      background: Colors.white,
    );
    await pumpEventQueue();
  }

  /// Asks [question] and has it answered with [answer].
  Future<void> exchange(String question, String answer) async {
    expect(assistant.send(question), isTrue);
    await pumpEventQueue();
    client.answer(answer);
    await pumpEventQueue();
  }

  setUp(() async {
    disposed = false;
    ink = InkController(strokes: <Stroke>[_line(100), _line(300)]);
    client = FakeAiClient();
    assistant = AiAssistantController(
      client: client,
      renderer: FakeSelectionImageRenderer(),
    );
    await open();
  });

  tearDown(() {
    if (!disposed) assistant.dispose();
    ink.dispose();
  });

  group('editing a message', () {
    test('sends the new words and takes away what came after', () async {
      await exchange('first', 'Answer one.');
      await exchange('second', 'Answer two.');
      expect(assistant.messagesAfter(0), 3);

      expect(assistant.editMessage(0, '  first, reworded  '), isTrue);
      await pumpEventQueue();

      expect(assistant.requestState, AiRequestState.sending);
      expect(_texts(assistant), <String>['user: first, reworded']);
      // The model is sent the conversation as it stands now, not as it was.
      expect(
        client.requests.last.messages.map((AiMessage m) => m.text),
        <String>['first, reworded'],
      );

      client.answer('Reworded answer.');
      await pumpEventQueue();
      expect(_texts(assistant), <String>[
        'user: first, reworded',
        'model: Reworded answer.',
      ]);
    });

    test(
      'only a user message, with words, when nothing is on its way',
      () async {
        await exchange('first', 'Answer one.');

        expect(assistant.editMessage(1, 'not yours to edit'), isFalse);
        expect(assistant.editMessage(0, '   '), isFalse);
        expect(assistant.editMessage(5, 'nothing there'), isFalse);
        expect(_texts(assistant), <String>[
          'user: first',
          'model: Answer one.',
        ]);

        expect(assistant.send('second'), isTrue);
        await pumpEventQueue();
        expect(assistant.canReviseMessage(0), isFalse);
        expect(assistant.editMessage(0, 'too late'), isFalse);
        expect(assistant.messages, hasLength(3));
      },
    );

    test('a failed question can be edited and sent again', () async {
      expect(assistant.send('oops'), isTrue);
      await pumpEventQueue();
      client.fail(AiFailureKind.network);
      await pumpEventQueue();
      expect(assistant.requestState, AiRequestState.failed);

      expect(assistant.editMessage(0, 'fixed'), isTrue);
      await pumpEventQueue();
      expect(assistant.requestState, AiRequestState.sending);
      expect(assistant.failure, isNull);
      expect(_texts(assistant), <String>['user: fixed']);
    });
  });

  group('running an answer again', () {
    test('asks the same question and replaces the answer', () async {
      await exchange('first', 'Answer one.');
      await exchange('second', 'Answer two.');

      expect(assistant.rerunMessage(1), isTrue);
      await pumpEventQueue();

      expect(assistant.requestState, AiRequestState.sending);
      // Its answer and what followed it are gone, and the question stands.
      expect(_texts(assistant), <String>['user: first']);
      expect(
        client.requests.last.messages.map((AiMessage m) => m.text),
        <String>['first'],
      );

      client.answer('Answer one, better.');
      await pumpEventQueue();
      expect(_texts(assistant), <String>[
        'user: first',
        'model: Answer one, better.',
      ]);
    });

    test('only an answer to a question, when nothing is on its way', () async {
      await exchange('first', 'Answer one.');

      expect(assistant.rerunMessage(0), isFalse);
      expect(assistant.rerunMessage(9), isFalse);
      expect(client.requests, hasLength(1));

      expect(assistant.send('second'), isTrue);
      await pumpEventQueue();
      expect(assistant.rerunMessage(1), isFalse);
      expect(client.requests, hasLength(2));
    });
  });

  group('an editor that closes while an answer is on its way', () {
    test('keeps asking, and the answer is saved with the note', () async {
      expect(assistant.send('What is this?'), isTrue);
      await pumpEventQueue();
      final Map<String, Object?> left = assistant.toJson(_indexOf(ink))!;

      Map<String, Object?>? saved;
      var released = false;
      assistant.retire(
        session: left,
        save: (Map<String, Object?> session) async => saved = session,
        release: () => released = true,
      );
      expect(released, isFalse, reason: 'the answer is still being waited for');
      expect(saved, isNull);

      client.answer('It is a line.');
      await pumpEventQueue();
      disposed = true;

      expect(released, isTrue);
      final List<Object?> conversations = saved!['conversations']! as List;
      final List<Object?> messages =
          (conversations.single! as Map<String, Object?>)['messages']! as List;
      expect(messages, hasLength(2));
      final Map<String, Object?> reply = messages.last! as Map<String, Object?>;
      expect(reply['role'], 'model');
      expect(
        AiAssistantResponse.parse(reply['wire']! as String).message,
        'It is a line.',
      );
      // What the note was left holding is not changed under its own save.
      expect(
        ((left['conversations']! as List).single! as Map)['messages'],
        hasLength(1),
      );
      // And what was saved reads back as a conversation that was answered.
      expect(
        jsonEncode(saved),
        isNot(contains('failure')),
        reason: 'an answered question is not a failed one',
      );
    });

    test('keeps the question when the answer fails', () async {
      expect(assistant.send('What is this?'), isTrue);
      await pumpEventQueue();
      Map<String, Object?>? saved;
      assistant.retire(
        session: assistant.toJson(_indexOf(ink)),
        save: (Map<String, Object?> session) async => saved = session,
      );

      client.fail(AiFailureKind.network);
      await pumpEventQueue();
      disposed = true;

      final Map<String, Object?> conversation =
          (saved!['conversations']! as List).single! as Map<String, Object?>;
      expect(conversation['messages'], hasLength(1));
      expect(conversation['failure'], AiFailureKind.network.name);
    });

    test('is let go at once when there is nothing to wait for', () async {
      await exchange('first', 'Answer one.');
      var saves = 0;
      var released = false;
      assistant.retire(
        session: assistant.toJson(_indexOf(ink)),
        save: (Map<String, Object?> session) async => saves++,
        release: () => released = true,
      );
      disposed = true;

      expect(released, isTrue);
      expect(saves, 0);
    });
  });
}
