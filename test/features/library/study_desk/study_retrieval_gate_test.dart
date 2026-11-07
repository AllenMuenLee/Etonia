import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/backend_ai_client.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/text/note_text.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/study_desk/practice/study_mistakes.dart';
import 'package:greatnote/features/library/study_desk/practice/study_practice_models.dart';
import 'package:greatnote/features/library/study_desk/practice/study_practice_store.dart';
import 'package:greatnote/features/library/study_desk/study_desk_controller.dart';
import 'package:greatnote/features/library/study_desk/study_desk_store.dart';
import 'package:greatnote/features/library/study_desk/study_rag_index.dart';
import 'package:greatnote/features/library/study_desk/study_teaching_plan.dart';
import 'package:greatnote/features/library/study_desk/study_vectors.dart';

class _Embeddings implements StudyEmbedder {
  int calls = 0;
  @override
  bool get isAvailable => true;
  @override
  Future<List<Float32List?>> embedTexts(List<String> texts) async {
    calls++;
    return List.filled(texts.length, null);
  }

  @override
  Future<List<Float32List?>> embedImages(List<Uint8List> pngs) async {
    calls++;
    return List.filled(pngs.length, null);
  }

  @override
  Future<Float32List?> embedQuery(String text) async {
    calls++;
    return null;
  }
}

Map<String, Object?> decision({
  bool notes = false,
  List<int> mistakes = const [],
  bool brief = false,
}) => {
  'intent': 'question',
  'difficulty': 2,
  'retrieval': {
    'notes': notes,
    'mistakeIndices': mistakes,
    'query': notes ? 'force mass acceleration' : '',
    'depth': brief ? 'brief' : 'full',
  },
};

Future<
  ({
    StudyDeskController desk,
    List<Map<String, Object?>> calls,
    _Embeddings embeddings,
  })
>
fixture(
  List<Object> decisions, {
  String noteText =
      'LECTURE_PRIVATE_BODY: Force equals mass times acceleration.',
  String noteTitle = 'Physics',
}) async {
  final repo = InMemoryNoteRepository();
  final note = await repo.createNote(title: noteTitle);
  await repo.saveNote(
    note.id,
    NoteContent([
      StoredPage(
        setup: const PageSetup(),
        strokes: const [],
        textElements: [
          NoteTextElement(
            id: 'text',
            position: const InkVector(20, 30),
            text: noteText,
          ),
        ],
      ),
    ]),
  );
  final practice = InMemoryStudyPracticeStore();
  await practice.writeMistakes([
    for (var i = 0; i < 2; i++)
      StudyMistake(
        sourceId: 'test-$i',
        testTitle: 'Physics test $i',
        questionNumber: i + 1,
        gradedAt: DateTime(2026, 11, 7),
        question: TestMultipleChoiceQuestion(
          id: 'q-$i',
          prompt: i == 0
              ? 'Find force from mass and acceleration.'
              : 'Define heat capacity.',
          topic: i == 0 ? 'Force' : 'Heat',
          options: const [
            PracticeChoiceOption(id: 'A', text: 'A'),
            PracticeChoiceOption(id: 'B', text: 'B'),
          ],
          correctOptionId: 'B',
          selectedOptionId: 'A',
          isGraded: true,
          explanation:
              'A negative sign was lost. ${'additional detail ' * 20} ARCHIVED_FEEDBACK_$i',
        ),
      ),
  ]);
  final calls = <Map<String, Object?>>[];
  var at = 0;
  final client = BackendAiClient(
    invoke: (_, body) async {
      calls.add(body);
      final task = (body['routing'] as Map)['task'];
      final value = task == 'study.plan' ? decisions[at++] : null;
      return {
        'answer': task == 'study.plan'
            ? (value is String ? value : jsonEncode(value))
            : task == 'study.suggestions'
            ? '{"questions":["Why?","Example?","What next?"]}'
            : 'A complete explanation.',
        'responseFormat': body['responseFormat'],
        'usage': {'inputTokens': 1, 'outputTokens': 1},
      };
    },
  );
  final embeddings = _Embeddings();
  final desk = StudyDeskController(
    repository: repo,
    client: client,
    store: InMemoryStudyDeskStore(),
    practiceStore: practice,
    embedder: embeddings,
  );
  await desk.load();
  desk.addNotes([note.id]);
  addTearDown(() {
    desk.dispose();
    client.close();
    repo.dispose();
  });
  return (desk: desk, calls: calls, embeddings: embeddings);
}

List<Map<String, Object?>> taskCalls(
  List<Map<String, Object?>> calls,
  String task,
) => calls.where((c) => (c['routing'] as Map)['task'] == task).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'an introduction uses a small note anchor without paid embeddings on a local match',
    () async {
      final text = [
        for (var i = 0; i < 45; i++)
          'Force section $i: A force changes motion. Mass describes resistance to acceleration. '
              'A larger applied force produces a larger acceleration for the same mass.',
      ].join('\n\n');
      final f = await fixture(
        [decision(notes: true, brief: true)],
        noteText: text,
        noteTitle: 'Lecture 1',
      );
      await f.desk.send('Introduce force.');
      final answer = taskCalls(f.calls, 'study.answer').single;
      final prompt = answer['prompt']! as String;
      final source = prompt
          .split('help:\n\n')
          .last
          .split('\n\nQuestion: ')
          .first;
      expect(source, contains('[Source '));
      expect(source, contains('Force section'));
      expect(
        StudyContextAssembler.estimateTokens(source),
        lessThanOrEqualTo(800),
      );
      expect(answer['systemInstruction'], contains('primary source'));
      expect(f.embeddings.calls, 0);
      expect(f.desk.index.reads, 1);
      expect(
        taskCalls(f.calls, 'study.plan').single['prompt'],
        isNot(contains('Force section')),
      );
    },
  );
  test(
    'a brief budget expands locally when it would drop an intact mathematical block',
    () async {
      final text =
          'Force = mass * acceleration. ${'This force law applies to a constant mass in an inertial reference frame. ' * 80}BOUNDARY_CONDITION_END';
      final f = await fixture([
        decision(notes: true, brief: true),
      ], noteText: text);
      await f.desk.send('Introduce force.');
      final prompt =
          taskCalls(f.calls, 'study.answer').single['prompt']! as String;
      expect(prompt, contains('Force = mass * acceleration.'));
      expect(prompt, contains('BOUNDARY_CONDITION_END'));
      expect(f.embeddings.calls, 0);
    },
  );
  test(
    'each turn gets a fresh model decision before any note indexing or embedding',
    () async {
      final f = await fixture([decision(), decision()]);
      await f.desk.send('Calculate 17 + 28.');
      await f.desk.send('Please make the explanation shorter.');
      expect(taskCalls(f.calls, 'study.plan'), hasLength(2));
      expect(f.desk.index.reads, 0);
      expect(f.embeddings.calls, 0);
      for (final c in taskCalls(f.calls, 'study.plan')) {
        expect(
          c['selectedImage'],
          base64Encode(StudyContextAssembler.placeholderPng),
        );
        expect(c.containsKey('studyPolicyVersion'), isFalse);
        expect(c['prompt'], isNot(contains('LECTURE_PRIVATE_BODY')));
        expect(c['prompt'], isNot(contains('ARCHIVED_FEEDBACK')));
      }
      for (final c in taskCalls(f.calls, 'study.answer')) {
        expect(c['prompt'], isNot(contains('[Source ')));
        expect(c['prompt'], isNot(contains('ARCHIVED_FEEDBACK')));
        expect(
          c['systemInstruction'],
          isNot(contains('Treat supplied past mistakes')),
        );
      }
    },
  );
  test(
    'notes are retrieved only after the model requests a source connection',
    () async {
      final f = await fixture([decision(notes: true), decision()]);
      await f.desk.send('Connect force to my physics notes.');
      expect(f.desk.index.reads, 1);
      expect(
        taskCalls(f.calls, 'study.answer').single['prompt'],
        contains('LECTURE_PRIVATE_BODY'),
      );
      final embeds = f.embeddings.calls;
      await f.desk.send('What is 2 + 2?');
      expect(
        taskCalls(f.calls, 'study.answer').last['prompt'],
        isNot(contains('LECTURE_PRIVATE_BODY')),
      );
      expect(f.embeddings.calls, embeds);
    },
  );
  test(
    'a relevant mistake can be retrieved without notes, selecting only that record',
    () async {
      final f = await fixture([
        decision(mistakes: [1]),
      ]);
      await f.desk.send('Find force from mass and acceleration.');
      final answer = taskCalls(f.calls, 'study.answer').single;
      expect(answer['prompt'], contains('ARCHIVED_FEEDBACK_0'));
      expect(answer['prompt'], isNot(contains('ARCHIVED_FEEDBACK_1')));
      expect(answer['prompt'], isNot(contains('LECTURE_PRIVATE_BODY')));
      expect(f.desk.index.reads, 0);
      expect(f.embeddings.calls, 0);
    },
  );
  test(
    'invalid or missing retrieval decisions default to no source retrieval',
    () async {
      final f = await fixture([
        'broken JSON',
        {'intent': 'question'},
        decision(mistakes: [8]),
      ]);
      for (final prompt in ['Hello', 'Thanks', 'Another general question']) {
        await f.desk.send(prompt);
      }
      expect(taskCalls(f.calls, 'study.answer'), hasLength(3));
      expect(f.desk.index.reads, 0);
      expect(f.embeddings.calls, 0);
      for (final c in taskCalls(f.calls, 'study.answer')) {
        expect(c['prompt'], isNot(contains('ARCHIVED_FEEDBACK')));
      }
    },
  );
  test('malformed retrieval fields cannot turn on retrieval', () {
    for (final retrieval in [
      {'notes': 'yes', 'mistakeIndices': <int>[], 'query': ''},
      {
        'notes': true,
        'mistakeIndices': [0],
        'query': '',
      },
      {
        'notes': true,
        'mistakeIndices': [9],
        'query': '',
      },
      {
        'notes': true,
        'mistakeIndices': [1, 2, 3, 4],
        'query': '',
      },
      {'notes': true, 'mistakeIndices': <int>[], 'query': 'x' * 301},
      {
        'notes': true,
        'mistakeIndices': <int>[],
        'query': '',
        'depth': 'unbounded',
      },
    ]) {
      expect(
        StudyTeachingDecision.parse(
          jsonEncode({'intent': 'question', 'retrieval': retrieval}),
        ),
        isNull,
      );
    }
  });
}
