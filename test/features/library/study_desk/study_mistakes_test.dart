import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/study_desk/practice/study_mistakes.dart';
import 'package:greatnote/features/library/study_desk/practice/study_practice_models.dart';
import 'package:greatnote/features/library/study_desk/practice/study_practice_store.dart';
import 'package:greatnote/features/library/study_desk/practice/study_test_review_context.dart';
import 'package:greatnote/features/library/study_desk/study_desk_controller.dart';
import 'package:greatnote/features/library/study_desk/study_desk_store.dart';

import '../../../helpers/ai_fakes.dart';

final now = DateTime(2026, 11, 6, 12);
const choice = TestMultipleChoiceQuestion(
  id: 'sign',
  prompt: 'Solve -2x = 4.',
  topic: 'Equations',
  options: [
    PracticeChoiceOption(id: 'A', text: 'x = 2'),
    PracticeChoiceOption(id: 'B', text: 'x = -2'),
  ],
  correctOptionId: 'B',
  selectedOptionId: 'A',
  isGraded: true,
  explanation: 'Divide by negative two, preserving the negative sign.',
);

StudyTestPaper paper({List<TestQuestion>? questions, bool submitted = true}) =>
    StudyTestPaper(
      id: 'algebra',
      title: 'Algebra test',
      courseId: 'math',
      courseName: 'Math',
      instructions: 'Show working.',
      createdAt: now,
      updatedAt: now,
      submittedAt: submitted ? now : null,
      isSubmitted: submitted,
      questions: questions ?? [choice],
    );

StudyPracticeSet quiz(PracticeMultipleChoice question) => StudyPracticeSet(
  id: 'quiz',
  title: 'Equations quiz',
  createdAt: now,
  updatedAt: now,
  multipleChoiceQuestions: [question],
);

Future<void> waitForRequest(FakeAiClient client, int count) async {
  for (var i = 0; i < 200 && client.requests.length < count; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(client.requests, hasLength(count));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('archive only graded misses including partial credit and blanks', () {
    final partial = TestFreeResponseQuestion(
      id: 'partial',
      prompt: 'Explain division by a negative number.',
      points: 5,
      subParts: const [],
      rubric: const [],
      modelAnswer: 'Retain the sign.',
      handwritingStrokes: Uint8List.fromList([1, 2, 3]),
      aiEvaluation: const TestAiEvaluation(
        awardedPoints: 3,
        maxPoints: 5,
        feedback: 'Sign error.',
        breakdown: ['Method: 3/3', 'Sign: 0/2'],
        recognizedMathOrText: 'x = 2',
      ),
    );
    final blank = TestMultipleChoiceQuestion(
      id: 'blank',
      prompt: 'A blank question',
      options: choice.options,
      correctOptionId: 'B',
      isGraded: true,
    );
    final original = paper(
      questions: [
        choice,
        partial,
        blank,
        choice.copyWith(selectedOptionId: 'B'),
        choice.copyWith(isGraded: false),
        const TestFreeResponseQuestion(
          id: 'ungraded',
          prompt: 'Unfinished',
          subParts: [],
          rubric: [],
        ),
      ],
    );
    final mistakes = StudyMistake.fromPaper(original).toList();
    expect(mistakes.map((m) => m.questionNumber), [1, 2, 3]);
    expect(mistakes[1].context['studentAnswer'], 'x = 2');
    expect(mistakes[1].context['feedback'], 'Sign error.');
    expect(mistakes[2].context['unanswered'], true);
    expect(
      StudyMistake.fromPaper(original.copyWith(isSubmitted: false)),
      isEmpty,
    );
    final restored = StudyMistake.fromJson(
      jsonDecode(jsonEncode(mistakes[1].toJson())) as Map<String, Object?>,
    );
    expect(restored.toJson(), mistakes[1].toJson());
    expect(restored.gradedAt, now);
  });

  test(
    'exam selections wait for grading; resetting retains instant misses',
    () async {
      final store = InMemoryStudyPracticeStore();
      final q = PracticeMultipleChoice(
        id: 'q',
        question: choice.prompt,
        options: choice.options,
        correctOptionId: 'B',
        explanation: choice.explanation,
      );
      await store.saveSet(quiz(q.answered('A', graded: false)));
      expect(await store.loadMistakes(), isEmpty);
      await store.updateSet(quiz(q.answered('A', graded: false).graded()));
      expect(await store.loadMistakes(), hasLength(1));
      await store.updateSet(quiz(q.cleared()));
      await store.updateSet(quiz(q.answered('B')));
      await store.deleteSet('quiz');
      expect(await store.loadMistakes(), hasLength(1));
      expect(
        PracticeMultipleChoice.fromJson(q.answered('A').toJson()).isGraded,
        true,
      );
    },
  );

  test(
    'history survives disk restart, replacement and deleting original test',
    () async {
      final dir = await Directory.systemTemp.createTemp('etonia-mistakes-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/practice.json');
      final store = FileStudyPracticeStore(file);
      await Future.wait([store.savePaper(paper()), store.savePaper(paper())]);
      expect(await store.loadMistakes(), hasLength(1));
      await store.savePaper(
        paper(questions: [choice.copyWith(selectedOptionId: 'B')]),
      );
      await store.deletePaper('algebra');
      final reopened = FileStudyPracticeStore(file);
      expect(await reopened.loadPapers(), isEmpty);
      final history = await reopened.loadMistakes();
      expect(history, hasLength(1));
      expect(history.single.testTitle, 'Algebra test');
      expect(
        (history.single.question as TestMultipleChoiceQuestion)
            .selectedOptionId,
        'A',
      );
      expect(history.single.courseId, 'math');
      expect(history.single.gradedAt, now);
    },
  );

  test(
    'existing graded papers backfill; malformed history is preserved',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'etonia-mistake-backfill-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final store = FileStudyPracticeStore(File('${dir.path}/practice.json'));
      await store.writePapers([paper()]);
      expect(await store.loadMistakes(), hasLength(1));
      await store.mistakeFile.writeAsString('{damaged');
      await expectLater(store.savePaper(paper()), throwsFormatException);
      expect(await store.mistakeFile.readAsString(), '{damaged');
      // A failed write does not poison the serialization queue.
      await store.mistakeFile.writeAsString('{"schema":1,"mistakes":[]}');
      expect(await store.loadMistakes(), hasLength(1));
    },
  );

  test('retrieval prioritizes exact questions and bounds Unicode context', () {
    final target = StudyMistake.fromPaper(paper()).single;
    final candidates = [
      for (var i = 0; i < 20; i++)
        StudyMistake(
          sourceId: 'other-$i',
          testTitle: 'Other test $i',
          questionNumber: 1,
          gradedAt: now.add(Duration(days: i)),
          question: TestMultipleChoiceQuestion(
            id: '$i',
            prompt: 'Solve 2x = 4. 解释方程',
            topic: 'Equations',
            options: choice.options,
            correctOptionId: 'B',
            isGraded: true,
          ),
        ),
      target,
      target,
    ];
    final context = studyMistakeContext(
      candidates,
      '  Solve   -2x = 4.  ',
      maxBytes: 2400,
    );
    expect(utf8.encode(context).length, lessThanOrEqualTo(2400));
    final decoded =
        jsonDecode(context.substring(context.indexOf('\n') + 1).trim()) as List;
    expect(decoded.length, lessThanOrEqualTo(8));
    expect((decoded.first as Map)['test'], 'Algebra test');
    expect(
      decoded.where((m) => (m as Map)['test'] == 'Algebra test'),
      hasLength(1),
    );
    expect(studyMistakeContext([target], 'Why?', maxBytes: 10), isEmpty);
    expect(studyMistakeContext([], 'Why?'), isEmpty);
  });

  test('paraphrases remain candidates, never confirmed by keyword overlap', () {
    final context = studyMistakeContext(
      StudyMistake.fromPaper(paper()).toList(),
      'How does dividing both sides by a value below zero work?',
    );
    expect(context, contains('Algebra test'));
    expect(context, contains('NOT confirmed matches'));
    expect(
      studyMistakeInstructions,
      contains(
        'Require evidence of the same question or a shared specific error mechanism',
      ),
    );
    expect(studyMistakeInstructions, contains('uncertain matches'));
  });

  test(
    'chat without notes and retries receive history without changing transcript',
    () async {
      final repository = InMemoryNoteRepository();
      final client = FakeAiClient();
      final practice = InMemoryStudyPracticeStore();
      final desk = StudyDeskController(
        repository: repository,
        client: client,
        practiceStore: practice,
        store: InMemoryStudyDeskStore(),
        clock: () => now,
      );
      addTearDown(desk.dispose);
      addTearDown(repository.dispose);
      addTearDown(client.close);
      await desk.load();
      await desk.saveTestPaper(paper());
      expect(desk.mistakes, hasLength(1));
      final pending = desk.send('Solve -2x = 4.');
      await waitForRequest(client, 1);
      final request = client.requests.last;
      expect(request.systemInstruction, contains(studyMistakeInstructions));
      expect(request.messages.last.text, contains('Algebra test'));
      expect(request.messages.last.text, contains(choice.explanation));
      expect(desk.messages.last.text, 'Solve -2x = 4.');
      client.fail(AiFailureKind.network);
      await pending;
      final retry = desk.retry();
      await waitForRequest(client, 2);
      expect(
        client.requests.last.messages.last.text,
        contains('Past mistakes'),
      );
      client.answer(
        'Recall question 1 in your Algebra test: keep the negative sign. x = -2.',
      );
      await retry;
      expect(desk.messages.where((m) => m.fromUser), hasLength(1));
      expect(desk.messages.last.text, contains('Algebra test'));
      expect(desk.testPapers.single.questions.single.toJson(), choice.toJson());
    },
  );

  test(
    'restored review chat receives memory and reserves room for it',
    () async {
      final repository = InMemoryNoteRepository();
      final client = FakeAiClient();
      final practice = InMemoryStudyPracticeStore();
      await practice.savePaper(paper());
      final desk = StudyDeskController(
        repository: repository,
        client: client,
        practiceStore: practice,
        store: InMemoryStudyDeskStore(),
        clock: () => now,
      );
      addTearDown(desk.dispose);
      addTearDown(repository.dispose);
      addTearDown(client.close);
      await desk.load();
      expect(desk.mistakes, hasLength(1));
      desk.startTestReviewChat(desk.testPapers.single);
      final pending = desk.send('Why was question 1 wrong?');
      await waitForRequest(client, 1);
      final request = client.requests.last;
      expect(request.systemInstruction, contains(studyMistakeInstructions));
      expect(request.messages.last.text, contains('Completed test source'));
      expect(request.messages.last.text, contains('Past mistakes'));
      expect(utf8.encode(request.messages.last.text).length, lessThan(24000));
      client.answer('In question 1, you lost the negative sign.');
      await pending;

      final longPaper = paper(
        questions: [
          for (var i = 0; i < 100; i++)
            TestMultipleChoiceQuestion(
              id: '$i',
              prompt: List.filled(200, '解释方程').join(),
              options: choice.options,
              correctOptionId: 'B',
              isGraded: true,
            ),
        ],
      );
      final payload = await studyTestReviewPayload(
        longPaper,
        'Question 1',
        [],
        reservedTextBytes: 10000,
      );
      expect(utf8.encode(payload.contextText).length, lessThan(11200));
    },
  );
}
