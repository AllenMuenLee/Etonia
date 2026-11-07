import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/ai_config.dart';
import 'package:greatnote/features/editor/ai/backend_ai_client.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/text/note_text.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/study_desk/practice/study_practice_models.dart';
import 'package:greatnote/features/library/study_desk/study_desk_controller.dart';
import 'package:greatnote/features/library/study_desk/study_desk_models.dart';
import 'package:greatnote/features/library/study_desk/study_desk_store.dart';
import 'package:greatnote/features/library/study_desk/study_teaching_plan.dart';

Map<String, Object?> lesson() => {
  'topic': 'Algebra',
  'activeStep': 0,
  'steps': [
    {
      'title': 'Variables',
      'goal': 'Understand a variable as a placeholder for a number.',
      'retrievalQuery': 'variable placeholder',
      'foundationExercise': 'If x is 2, what is x + 1?',
    },
    {
      'title': 'Equations',
      'goal': 'Keep both sides equal.',
      'retrievalQuery': 'equations balance equality',
      'foundationExercise': 'Solve x + 1 = 3.',
    },
    {
      'title': 'Applications',
      'goal': 'Translate a word problem into an equation.',
      'retrievalQuery': 'word problem equation',
      'foundationExercise': 'Write an equation for two equal groups.',
    },
  ],
};

class _Router extends AiModelRouter {
  final requests = <AiRequest>[];
  final decisions = <AiResult>[];
  final configured = {AiModelId.luna, AiModelId.haiku, AiModelId.sol};
  Completer<AiResult>? plannerGate;
  Completer<AiResult>? suggestionGate;
  bool failAnswer = false;

  @override
  bool get isConfigured => true;
  @override
  String get modelLabel => 'Sol';
  @override
  AiModelId get defaultModel => AiModelId.sol;
  @override
  List<AiModelId> get models => AiModelId.values;
  @override
  bool isModelConfigured(AiModelId model) => configured.contains(model);
  @override
  void close() {}

  @override
  Future<AiResult> send(
    AiRequest request, {
    AiPartialCallback? onPartial,
    AiNotationPartialCallback? onNotation,
  }) async {
    requests.add(request);
    if (request.systemInstruction == AiPrompts.studyTeachingPlannerSystem) {
      if (plannerGate != null) return plannerGate!.future;
      final result = decisions.isEmpty
          ? const AiSuccess('{"intent":"question"}')
          : decisions.removeAt(0);
      // These source/lesson fixtures explicitly ask the fake model to retrieve.
      if (result is AiSuccess) {
        try {
          final value = jsonDecode(result.text) as Map<String, dynamic>;
          value.putIfAbsent(
            'retrieval',
            () => {'notes': true, 'mistakeIndices': <int>[], 'query': ''},
          );
          return AiSuccess(jsonEncode(value));
        } on Object {
          return result;
        }
      }
      return result;
    }
    if (request.systemInstruction == AiPrompts.studySuggestionsSystem) {
      return suggestionGate?.future ??
          const AiSuccess('["An example?","Why?","What next?"]');
    }
    if (failAnswer) return const AiError(AiFailure(AiFailureKind.network));
    onPartial?.call('A variable is a placeholder for a number.', true);
    return const AiSuccess('A variable is a placeholder for a number.');
  }

  List<AiRequest> get answers => requests
      .where((r) => r.systemInstruction.startsWith(AiPrompts.studySystem))
      .toList();
}

Future<StudyDeskController> fixture(
  AiClient client, {
  InMemoryStudyDeskStore? store,
  int pageCount = 2,
  bool chapters = false,
  bool attachNotes = true,
}) async {
  final repository = InMemoryNoteRepository();
  var note = await repository.createNote(title: 'Algebra');
  note = await repository.saveNote(
    note.id,
    NoteContent([
      for (var i = 0; i < pageCount; i++)
        StoredPage(
          setup: const PageSetup(),
          strokes: const [],
          textElements: [
            NoteTextElement(
              id: 'page-$i',
              position: const InkVector(30, 40),
              text: chapters
                  ? 'Chapter ${i + 1} Algebra\n'
                        'Variables and equations balance equality.'
                  : i == 0
                  ? 'A variable is a placeholder for a number.'
                  : 'Equations balance equality: keep both sides equal.',
            ),
          ],
        ),
    ]),
  );
  if (!attachNotes) await repository.deleteNote(note.id);
  final desk = StudyDeskController(
    repository: repository,
    client: client,
    store: store,
  );
  await desk.load();
  if (attachNotes) desk.addNotes([note.id]);
  addTearDown(() {
    desk.dispose();
    repository.dispose();
    client.close();
  });
  return desk;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rapid suggestion refreshes share the in-progress generation', () async {
    final router = _Router()..suggestionGate = Completer<AiResult>();
    final desk = await fixture(router);
    await desk.send('What is a variable?');
    final before = router.requests.length;
    await Future.wait([desk.refreshSuggestions(), desk.refreshSuggestions()]);
    expect(router.requests.length, before);
    router.suggestionGate!.complete(
      const AiSuccess('["Why?","An example?","What next?"]'),
    );
    while (desk.generatingSuggestions.value) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(desk.dynamicSuggestions.value, hasLength(3));
  });

  test(
    'backend navigation gets a fresh retrieval decision and commits only after a successful answer',
    () async {
      var planCalls = 0;
      var failAnswer = false;
      final seen = <Map<String, Object?>>[];
      final client = BackendAiClient(
        invoke: (_, body) async {
          seen.add(body);
          final task = (body['routing'] as Map<String, Object?>)['task'];
          if (task == 'study.plan') planCalls++;
          if (task == 'study.answer' && failAnswer) {
            return {
              'answer': '',
              'responseFormat': 'text',
              'usage': {'inputTokens': 1, 'outputTokens': 0},
            };
          }
          return {
            'answer': task == 'study.plan'
                ? jsonEncode({
                    'intent': planCalls == 1 ? 'topic' : 'continue',
                    'difficulty': 3,
                    if (planCalls == 1) 'plan': lesson() else 'activeStep': 1,
                    'retrieval': {
                      'notes': false,
                      'mistakeIndices': <int>[],
                      'query': '',
                    },
                  })
                : task == 'study.suggestions'
                ? '{"questions":["Why?","An example?","What next?"]}'
                : 'A complete lesson step and understanding check.',
            'responseFormat': body['responseFormat'],
            'usage': {'inputTokens': 10, 'outputTokens': 10},
          };
        },
      );
      final desk = await fixture(client);
      await desk.send('Teach algebra');
      expect(desk.currentSession.teachingPlan!.activeStep, 0);
      failAnswer = true;
      await desk.send('next');
      expect(desk.currentSession.teachingPlan!.activeStep, 0);
      expect(planCalls, 2);
      failAnswer = false;
      await desk.send('next');
      expect(desk.currentSession.teachingPlan!.activeStep, 1);
      expect(planCalls, 3);
      final answer = seen.lastWhere(
        (body) => (body['routing'] as Map)['task'] == 'study.answer',
      );
      expect((answer['routing'] as Map)['difficulty'], 3);
    },
  );

  test('topic plan persists and step retrieval changes across turns', () async {
    final router = _Router();
    router.decisions.add(
      AiSuccess(jsonEncode({'intent': 'topic', 'plan': lesson()})),
    );
    final store = InMemoryStudyDeskStore();
    final desk = await fixture(router, store: store);
    await desk.send('Teach me algebra from the basics');
    expect(router.requests.first.model, AiModelId.luna);
    expect(
      router.requests.first.messages.last.text,
      contains('Available notes'),
    );
    expect(
      router.requests.first.messages.last.text,
      isNot(contains('placeholder')),
    );
    expect(router.answers.single.model, AiModelId.sol);
    expect(
      router.answers.single.messages.last.text,
      contains('foundationExercise'),
    );
    expect(router.answers.single.messages.last.text, contains('placeholder'));
    expect(desk.messages, hasLength(2));
    expect(desk.currentSession.teachingPlan!.activeStep, 0);

    router.decisions.add(
      const AiSuccess('{"intent":"continue","activeStep":1}'),
    );
    await desk.send('3. Please continue');
    expect(desk.currentSession.teachingPlan!.activeStep, 1);
    expect(
      router.answers.last.messages.last.text,
      contains('Equations balance equality'),
    );
    final snapshot = StudyDeskState.fromJson(
      jsonDecode(jsonEncode((await store.read())!.toJson()))
          as Map<String, Object?>,
    );
    final saved = snapshot.sessions.single.teachingPlan!;
    expect(saved.activeStep, 1);
    expect(saved.scopePrompt, 'Teach me algebra from the basics');

    final restored = StudyDeskController(
      repository: desk.repository,
      client: router,
      store: store,
    );
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.currentSession.teachingPlan!.activeStep, 1);
    router.decisions.add(
      const AiSuccess('{"intent":"continue","activeStep":1}'),
    );
    await restored.send('I do not understand equality');
    expect(restored.currentSession.teachingPlan!.activeStep, 1);
    expect(router.answers.last.messages.last.text, contains('"activeStep":1'));
  });

  test('focused questions retain a lesson without advancing it', () async {
    final router = _Router();
    router.decisions.add(
      AiSuccess(jsonEncode({'intent': 'topic', 'plan': lesson()})),
    );
    final desk = await fixture(router);
    await desk.send('Teach algebra');
    await desk.send('What does equality mean?');
    expect(desk.currentSession.teachingPlan!.activeStep, 0);
    expect(
      router.answers.last.messages.last.text,
      contains('"intent":"question"'),
    );
    expect(
      router.answers.last.messages.last.text,
      contains('Equations balance equality'),
    );
    expect(router.answers.last.model, AiModelId.sol);
    expect(
      router.answers.last.systemInstruction,
      contains('Finish when the explanation is complete'),
    );
    expect(desk.showTestRecommendation, isFalse);
  });

  test(
    'small problems use the selected model without a lesson or test',
    () async {
      final router = _Router()..configured.add(AiModelId.sonnet);
      final desk = await fixture(router);
      desk.selectModel(AiModelId.sonnet);
      await desk.send('Solve x + 1 = 3');
      expect(router.requests.first.model, AiModelId.haiku);
      expect(router.answers.single.model, AiModelId.sonnet);
      expect(desk.currentSession.teachingPlan, isNull);
      expect(
        router.answers.single.systemInstruction,
        contains('Finish when the explanation is complete'),
      );
      await desk.send('What is equality?');
      expect(desk.showTestRecommendation, isFalse);
      final suggestions = router.requests.lastWhere(
        (r) => r.systemInstruction == AiPrompts.studySuggestionsSystem,
      );
      final context = jsonDecode(suggestions.messages.single.text) as Map;
      expect(context['teachingIntent'], 'question');
      expect(context['lessonStage'], isNull);
    },
  );

  test('graded-paper review routes both questions and whole topics', () async {
    final router = _Router();
    final desk = await fixture(router);
    final now = DateTime(2026, 11, 6);
    final paper = StudyTestPaper(
      id: 'review-routing',
      title: 'Algebra paper',
      courseName: 'Algebra',
      instructions: 'Show your working',
      createdAt: now,
      updatedAt: now,
      isSubmitted: true,
      totalScore: 2,
      questions: const [
        TestMultipleChoiceQuestion(
          id: 'q1',
          prompt: 'Solve x + 1 = 3',
          points: 2,
          options: [
            PracticeChoiceOption(id: 'A', text: 'x = 2'),
            PracticeChoiceOption(id: 'B', text: 'x = 4'),
          ],
          correctOptionId: 'A',
          selectedOptionId: 'A',
        ),
      ],
    );
    await desk.saveTestPaper(paper);
    desk.startTestReviewChat(paper);
    await desk.send('Why is the answer to question 1 x = 2?');
    expect(router.requests.first.model, AiModelId.luna);
    expect(
      router.requests.first.messages.last.text,
      contains('completed test is available'),
    );
    expect(
      router.requests.first.messages.last.text,
      isNot(contains('Solve x + 1 = 3')),
    );
    expect(router.answers.last.model, AiModelId.sol);
    expect(
      router.answers.last.systemInstruction,
      contains('Finish when the explanation is complete'),
    );
    expect(desk.currentSession.teachingPlan, isNull);

    router.decisions.addAll([
      AiSuccess(jsonEncode({'intent': 'topic', 'plan': lesson()})),
      const AiSuccess('{"intent":"continue","activeStep":1}'),
      const AiSuccess('{"intent":"continue","activeStep":2}'),
      const AiSuccess('{"intent":"assessment"}'),
    ]);
    await desk.send('Teach me algebra from the basics');
    expect(desk.currentSession.teachingPlan!.activeStep, 0);
    expect(
      router.answers.last.systemInstruction,
      contains('Teach only the active lesson step'),
    );
    await desk.send('Next');
    await desk.send('Next');
    await desk.send('Next');
    expect(desk.currentSession.testPaperId, paper.id);
    expect(
      desk.currentSession.teachingPlan!.stage,
      StudyTeachingStage.assessment,
    );
    expect(
      router.answers.last.systemInstruction,
      contains('Give the final test now'),
    );
    expect(router.answers.last.messages.last.text, contains('Solve x + 1 = 3'));
    expect(desk.testPapers.single.totalScore, 2);
  });

  for (final attachNotes in [true, false]) {
    test('lesson ends with a persisted test (notes: $attachNotes)', () async {
      final router = _Router();
      router.decisions.addAll([
        AiSuccess(jsonEncode({'intent': 'topic', 'plan': lesson()})),
        const AiSuccess('{"intent":"continue","activeStep":1}'),
        const AiSuccess('{"intent":"continue","activeStep":2}'),
        const AiSuccess('{"intent":"assessment"}'),
      ]);
      final store = InMemoryStudyDeskStore();
      final desk = await fixture(
        router,
        store: store,
        attachNotes: attachNotes,
      );
      expect(desk.hasRetrievalNotes, attachNotes);
      await desk.send('Explain algebra');
      await desk.send('Next');
      await desk.send('Next');
      expect(
        desk.currentSession.teachingPlan!.stage,
        StudyTeachingStage.learning,
      );
      expect(desk.showTestRecommendation, isFalse);
      await desk.send('Next');
      expect(router.answers.last.model, AiModelId.sol);
      expect(
        router.answers.last.systemInstruction,
        contains('Give the final test now'),
      );
      expect(
        router.answers.last.systemInstruction,
        contains('3 to 5 numbered'),
      );
      expect(
        router.answers.last.systemInstruction,
        contains('Review solutions after the student attempts'),
      );
      expect(desk.currentSession.teachingPlan!.activeStep, 2);
      expect(
        desk.currentSession.teachingPlan!.stage,
        StudyTeachingStage.assessment,
      );
      expect(desk.showTestRecommendation, attachNotes);
      final suggestions = router.requests.lastWhere(
        (r) => r.systemInstruction == AiPrompts.studySuggestionsSystem,
      );
      final context = jsonDecode(suggestions.messages.single.text) as Map;
      expect(context['teachingIntent'], 'assessment');
      expect(context['lessonStage'], 'assessment');
      final saved = StudyDeskState.fromJson(
        jsonDecode(jsonEncode((await store.read())!.toJson()))
            as Map<String, Object?>,
      );
      expect(
        saved.sessions.single.teachingPlan!.stage,
        StudyTeachingStage.assessment,
      );
      expect(desk.messages, hasLength(8));

      final restored = StudyDeskController(
        repository: desk.repository,
        client: router,
        store: store,
      );
      addTearDown(restored.dispose);
      await restored.load();
      await restored.send('What does this symbol mean?');
      expect(
        restored.currentSession.teachingPlan!.stage,
        StudyTeachingStage.assessment,
      );
      expect(
        router.answers.last.systemInstruction,
        contains('Finish when the explanation is complete'),
      );
      router.decisions.add(const AiSuccess('{"intent":"review"}'));
      await restored.send('1. x = 2');
      expect(
        restored.currentSession.teachingPlan!.stage,
        StudyTeachingStage.assessment,
      );
      expect(
        router.answers.last.systemInstruction,
        contains('Offer hints for remaining questions'),
      );
      router.decisions.add(const AiSuccess('{"intent":"complete"}'));
      await restored.send('2. x = 3. 3. x + x = 4');
      expect(restored.showTestRecommendation, isFalse);
      expect(
        restored.currentSession.teachingPlan!.stage,
        StudyTeachingStage.completed,
      );
      expect(
        router.answers.last.systemInstruction,
        contains('Review the student\'s final test answers'),
      );
      await restored.send('Why is my answer wrong?');
      expect(
        restored.currentSession.teachingPlan!.stage,
        StudyTeachingStage.completed,
      );
      expect(
        router.answers.last.systemInstruction,
        contains('Finish when the explanation is complete'),
      );
    });
  }

  test(
    'failed final test delivery can be retried without advancing state',
    () async {
      final router = _Router();
      router.decisions.addAll([
        AiSuccess(jsonEncode({'intent': 'topic', 'plan': lesson()})),
        const AiSuccess('{"intent":"continue","activeStep":1}'),
        const AiSuccess('{"intent":"continue","activeStep":2}'),
        const AiSuccess('{"intent":"assessment"}'),
        const AiSuccess('{"intent":"assessment"}'),
      ]);
      final desk = await fixture(router);
      await desk.send('Teach algebra');
      await desk.send('Next');
      await desk.send('Next');
      router.failAnswer = true;
      await desk.send('Next');
      expect(
        desk.currentSession.teachingPlan!.stage,
        StudyTeachingStage.learning,
      );
      expect(desk.failure, isNotNull);
      router.failAnswer = false;
      await desk.retry();
      expect(
        desk.currentSession.teachingPlan!.stage,
        StudyTeachingStage.assessment,
      );
      expect(desk.messages, hasLength(8));
    },
  );

  test('assessment transitions reject early tests, skips, and restarts', () {
    final initial = StudyTeachingPlan.tryRead(lesson())!;
    final finalStep = initial.atStep(initial.steps.length - 1);
    expect(
      StudyTeachingDecision.parse('{"intent":"assessment"}', previous: initial),
      isNull,
    );
    expect(
      StudyTeachingDecision.parse('{"intent":"complete"}', previous: finalStep),
      isNull,
    );
    expect(
      StudyTeachingDecision.parse('{"intent":"review"}', previous: finalStep),
      isNull,
    );
    final testing = StudyTeachingDecision.parse(
      '{"intent":"assessment"}',
      previous: finalStep,
    )!.plan!;
    expect(
      StudyTeachingDecision.parse('{"intent":"assessment"}', previous: testing),
      isNull,
    );
    expect(
      StudyTeachingDecision.parse(
        '{"intent":"continue","activeStep":2}',
        previous: testing,
      ),
      isNull,
    );
    final completed = StudyTeachingDecision.parse(
      '{"intent":"complete"}',
      previous: testing,
    )!.plan!;
    expect(
      StudyTeachingDecision.parse(
        '{"intent":"assessment"}',
        previous: completed,
      ),
      isNull,
    );
    expect(
      StudyTeachingPlan.tryRead({...lesson(), 'stage': 'unknown'}),
      isNull,
    );
    expect(
      StudyTeachingPlan.tryRead({...lesson(), 'stage': 'assessment'}),
      isNull,
    );
    expect(initial.stage, StudyTeachingStage.learning);
    expect(
      StudyTeachingPlan.tryRead(completed.toJson())!.stage,
      StudyTeachingStage.completed,
    );
  });

  test(
    'lesson next and numerical answers stay inside the chosen chapter',
    () async {
      final router = _Router();
      router.decisions.add(
        AiSuccess(jsonEncode({'intent': 'topic', 'plan': lesson()})),
      );
      final desk = await fixture(router, chapters: true);
      await desk.send('Teach me chapter 2');
      expect(desk.currentSession.teachingPlan, isNotNull);
      router.decisions.add(
        const AiSuccess('{"intent":"continue","activeStep":1}'),
      );
      await desk.send('Next');
      expect(desk.currentSession.teachingPlan!.activeStep, 1);
      expect(router.answers.last.messages.last.text, contains('Chapter 2'));
      expect(
        router.answers.last.messages.last.text,
        isNot(contains('Chapter 1')),
      );
      router.decisions.add(
        const AiSuccess('{"intent":"continue","activeStep":1}'),
      );
      await desk.send('1');
      expect(router.answers.last.messages.last.text, contains('Chapter 2'));
      expect(
        router.answers.last.messages.last.text,
        isNot(contains('Chapter 1')),
      );
    },
  );

  test('planner failures and invalid output still allow an answer', () async {
    final router = _Router();
    final desk = await fixture(router);
    for (final result in [
      const AiError(AiFailure(AiFailureKind.network)),
      const AiSuccess('invalid json'),
      const AiSuccess('{"intent":"topic","plan":{"steps":[]}}'),
    ]) {
      router.decisions.add(result);
      await desk.send('What is a variable?');
      expect(desk.failure, isNull);
      expect(desk.currentSession.teachingPlan, isNull);
    }
    expect(router.answers, hasLength(3));
  });

  test('a failed teaching answer does not commit lesson progress', () async {
    final router = _Router();
    router.decisions.add(
      AiSuccess(jsonEncode({'intent': 'topic', 'plan': lesson()})),
    );
    final desk = await fixture(router);
    await desk.send('Teach algebra');
    router.failAnswer = true;
    router.decisions.add(
      const AiSuccess('{"intent":"continue","activeStep":1}'),
    );
    await desk.send('Next');
    expect(desk.currentSession.teachingPlan!.activeStep, 0);
    expect(desk.failure!.kind, AiFailureKind.network);
  });

  test('late planning results cannot enter a different chat', () async {
    final router = _Router()..plannerGate = Completer<AiResult>();
    final desk = await fixture(router);
    final original = desk.currentSession.id;
    final pending = desk.send('Teach algebra');
    while (router.requests.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    desk.newChat();
    router.plannerGate!.complete(
      AiSuccess(jsonEncode({'intent': 'topic', 'plan': lesson()})),
    );
    await pending;
    expect(router.answers, hasLength(1));
    expect(desk.messages, isEmpty);
    expect(desk.currentSession.teachingPlan, isNull);
    expect(
      desk.allSessions.singleWhere((s) => s.id == original).teachingPlan,
      isNotNull,
    );
  });

  test('oversized sources request a scope before planning a lesson', () async {
    final router = _Router();
    router.decisions.add(
      AiSuccess(jsonEncode({'intent': 'topic', 'plan': lesson()})),
    );
    final desk = await fixture(router, pageCount: 45);
    await desk.send('Teach me the whole book');
    expect(
      router.requests.first.messages.last.text,
      contains('Available notes'),
    );
    expect(
      router.answers.single.systemInstruction,
      contains('Only the source catalogue is supplied'),
    );
    expect(desk.currentSession.teachingPlan, isNull);
    expect(router.requests.first.model, AiModelId.luna);
  });

  test(
    'the retrieval decision still runs when only a premium model is configured',
    () async {
      final router = _Router()
        ..configured.removeAll([AiModelId.luna, AiModelId.haiku]);
      final desk = await fixture(router);
      await desk.send('What is a variable?');
      expect(router.requests.first.model, AiModelId.sol);
      expect(
        router.requests.first.systemInstruction,
        AiPrompts.studyTeachingPlannerSystem,
      );
      expect(router.answers, hasLength(1));
    },
  );

  test(
    'planner JSON and tutor Markdown travel through the plain backend transport',
    () async {
      final seen = <Map<String, Object?>>[];
      final client = BackendAiClient(
        invoke: (_, body) async {
          seen.add(body);
          final task = (body['routing'] as Map<String, Object?>)['task'];
          final answer = task == 'study.plan'
              ? jsonEncode({'intent': 'topic', 'plan': lesson()})
              : task == 'study.suggestions'
              ? '["Why?","An example?","What next?"]'
              : 'A variable holds a number.';
          return <String, dynamic>{
            'answer': answer,
            'responseFormat': body['responseFormat'],
            'usage': {'inputTokens': 80, 'outputTokens': 30},
          };
        },
      );
      final desk = await fixture(client);
      await desk.send('Teach algebra');
      expect(desk.currentSession.teachingPlan!.topic, 'Algebra');
      // The app names no model: the server routes each task.
      expect(seen.first['model'], 'auto');
      expect(seen.first['responseFormat'], 'json');
      expect((seen.first['routing'] as Map)['task'], 'study.plan');
      expect(seen[1]['model'], 'auto');
      expect(seen[1]['responseFormat'], 'text');
      expect(seen[1]['turnId'], seen.first['turnId']);
      expect((seen[1]['routing'] as Map)['task'], 'study.answer');
      expect(seen[1]['prompt'], contains('foundationExercise'));
    },
  );

  test(
    'malformed plans and skipped steps are rejected without losing history',
    () {
      final previous = StudyTeachingPlan.tryRead(lesson())!;
      expect(
        StudyTeachingDecision.parse(
          '{"intent":"continue","activeStep":2}',
          previous: previous,
        ),
        isNull,
      );
      expect(
        StudyTeachingDecision.parse(
          '{"intent":"continue","activeStep":-1}',
          previous: previous,
        ),
        isNull,
      );
      expect(
        StudyTeachingPlan.tryRead({...lesson(), 'activeStep': 99}),
        isNull,
      );
      final legacy = StudySession.fromJson({
        'id': 'old',
        'created': 1,
        'messages': <Object?>[],
      });
      expect(legacy.teachingPlan, isNull);
      final damaged = StudySession.fromJson({
        ...legacy.toJson(),
        'messages': [
          {'user': true, 'text': 'Keep my chat'},
        ],
        'teachingPlan': {'topic': 'bad'},
      });
      expect(damaged.messages.single.text, 'Keep my chat');
      expect(damaged.teachingPlan, isNull);
    },
  );
}
