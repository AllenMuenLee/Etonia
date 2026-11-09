import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/study_desk/study_desk_controller.dart';
import 'package:greatnote/features/library/study_desk/study_desk_models.dart';
import 'package:greatnote/features/library/study_desk/study_desk_store.dart';

import '../../../helpers/ai_fakes.dart';

Future<(StudyDeskController, FakeAiClient)> _desk() async {
  final InMemoryNoteRepository repository = InMemoryNoteRepository();
  final FakeAiClient client = FakeAiClient();
  final StudyDeskController desk = StudyDeskController(
    repository: repository,
    client: client,
    store: InMemoryStudyDeskStore(),
  );
  await desk.load();
  addTearDown(() {
    desk.dispose();
    repository.dispose();
    client.close();
  });
  return (desk, client);
}

List<String> _texts(StudyDeskController desk) => <String>[
  for (final StudyMessage message in desk.messages)
    '${message.fromUser ? 'you' : 'answer'}: ${message.text}',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an answer that comes after another chat was opened is kept with '
      'the chat it answers', () async {
    final (StudyDeskController desk, FakeAiClient client) = await _desk();

    unawaited(desk.send('What is a variable?'));
    await pumpEventQueue();
    final String first = desk.sessionId;
    expect(desk.isBusy, isTrue);

    // Leave half way: start another chat while the first is still asking.
    desk.newChat();
    await pumpEventQueue();
    expect(desk.sessionId, isNot(first));
    expect(desk.isBusy, isFalse, reason: 'the new chat is not waiting');
    expect(desk.canSend, isTrue);
    expect(desk.hasPendingAnswers, isTrue);
    expect(desk.isAnswering(first), isTrue);

    client.answer('A placeholder for a number.');
    await pumpEventQueue();

    // Nothing landed in the chat on screen.
    expect(desk.messages, isEmpty);
    expect(desk.hasPendingAnswers, isFalse);

    desk.openSession(first);
    expect(_texts(desk), <String>[
      'you: What is a variable?',
      'answer: A placeholder for a number.',
    ]);
    expect(desk.isBusy, isFalse);
  });

  test(
    'two chats can be waiting at once, and each gets its own answer',
    () async {
      final (StudyDeskController desk, FakeAiClient client) = await _desk();

      unawaited(desk.send('First question'));
      await pumpEventQueue();
      final String first = desk.sessionId;
      desk.newChat();
      unawaited(desk.send('Second question'));
      await pumpEventQueue();
      final String second = desk.sessionId;
      expect(
        client.requests.where((AiRequest r) => r.messages.isNotEmpty),
        hasLength(2),
      );

      // The second chat is answered first.
      client.answer('Second answer.', index: client.requests.length - 1);
      await pumpEventQueue();
      expect(_texts(desk), <String>[
        'you: Second question',
        'answer: Second answer.',
      ]);
      expect(desk.isAnswering(first), isTrue);

      client.answer('First answer.', index: 0);
      await pumpEventQueue();

      desk.openSession(first);
      expect(_texts(desk), <String>[
        'you: First question',
        'answer: First answer.',
      ]);
      desk.openSession(second);
      expect(_texts(desk), <String>[
        'you: Second question',
        'answer: Second answer.',
      ]);
    },
  );

  test('a chat deleted while it was asking takes its answer with it', () async {
    final (StudyDeskController desk, FakeAiClient client) = await _desk();

    unawaited(desk.send('Question'));
    await pumpEventQueue();
    final String first = desk.sessionId;
    desk.newChat();
    desk.deleteSession(first);

    client.answer('Too late.');
    await pumpEventQueue();

    expect(desk.hasSession(first), isFalse);
    expect(desk.allSessions, isEmpty);
    expect(desk.hasPendingAnswers, isFalse);
  });

  test('a question that failed can be retried from its own chat', () async {
    final (StudyDeskController desk, FakeAiClient client) = await _desk();

    unawaited(desk.send('Question'));
    await pumpEventQueue();
    final String first = desk.sessionId;
    desk.newChat();
    client.fail(AiFailureKind.network);
    await pumpEventQueue();
    expect(
      desk.failure,
      isNull,
      reason: 'the failure belongs to the first chat',
    );

    desk.openSession(first);
    expect(desk.failure?.kind, AiFailureKind.network);
    unawaited(desk.retry());
    await pumpEventQueue();
    expect(desk.isBusy, isTrue);
    client.answer('Second time lucky.');
    await pumpEventQueue();
    expect(_texts(desk), <String>[
      'you: Question',
      'answer: Second time lucky.',
    ]);
  });

  group('changing a message', () {
    Future<StudyDeskController> twoTurns(
      FakeAiClient client,
      StudyDeskController desk,
    ) async {
      unawaited(desk.send('One?'));
      await pumpEventQueue();
      client.answer('Answer one.');
      await pumpEventQueue();
      unawaited(desk.send('Two?'));
      await pumpEventQueue();
      client.answer('Answer two.');
      await pumpEventQueue();
      return desk;
    }

    test('an edited question is asked in place of the old one', () async {
      final (StudyDeskController desk, FakeAiClient client) = await _desk();
      await twoTurns(client, desk);
      expect(desk.messagesAfter(0), 3);

      unawaited(desk.editQuestion(0, '  One, reworded?  '));
      await pumpEventQueue();
      expect(desk.isBusy, isTrue);
      expect(_texts(desk), <String>['you: One, reworded?']);
      client.answer('Reworded answer.');
      await pumpEventQueue();

      expect(_texts(desk), <String>[
        'you: One, reworded?',
        'answer: Reworded answer.',
      ]);
    });

    test('an answer run again replaces itself and what followed', () async {
      final (StudyDeskController desk, FakeAiClient client) = await _desk();
      await twoTurns(client, desk);
      final int before = client.requests.length;

      unawaited(desk.rerunAnswer(1));
      await pumpEventQueue();
      expect(desk.isBusy, isTrue);
      expect(_texts(desk), <String>['you: One?']);
      expect(client.requests.length, greaterThan(before));
      client.answer('Answer one, again.');
      await pumpEventQueue();

      expect(_texts(desk), <String>['you: One?', 'answer: Answer one, again.']);
    });

    test('only the right kind of message, while nothing is asking', () async {
      final (StudyDeskController desk, FakeAiClient client) = await _desk();
      await twoTurns(client, desk);

      expect(
        await desk.editQuestion(1, 'an answer is not a question'),
        isFalse,
      );
      expect(await desk.editQuestion(0, '   '), isFalse);
      expect(await desk.rerunAnswer(0), isFalse);
      expect(await desk.rerunAnswer(9), isFalse);
      expect(desk.messages, hasLength(4));

      unawaited(desk.send('Three?'));
      await pumpEventQueue();
      expect(desk.canReviseMessage(0), isFalse);
      expect(await desk.editQuestion(0, 'too late'), isFalse);
      expect(desk.messages, hasLength(5));
    });
  });
}
