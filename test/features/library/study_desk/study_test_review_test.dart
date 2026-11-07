import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/ai/backend_ai_client.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/study_desk/practice/study_completed_test_pdf_exporter.dart';
import 'package:greatnote/features/library/study_desk/practice/study_practice_models.dart';
import 'package:greatnote/features/library/study_desk/practice/study_practice_store.dart';
import 'package:greatnote/features/library/study_desk/practice/study_test_grader.dart';
import 'package:greatnote/features/library/study_desk/practice/study_test_paper_player.dart';
import 'package:greatnote/features/library/study_desk/practice/study_test_review_context.dart';
import 'package:greatnote/features/library/study_desk/practice/test_handwriting_canvas.dart';
import 'package:greatnote/features/library/study_desk/study_desk_controller.dart';
import 'package:greatnote/features/library/study_desk/study_desk_models.dart';
import 'package:greatnote/features/library/study_desk/study_desk_screen.dart';
import 'package:greatnote/features/library/study_desk/study_desk_store.dart';

import '../../../helpers/ai_fakes.dart';
import '../../../helpers/pump_app.dart';

final _now = DateTime(2026, 11, 5);
Uint8List _ink() => Uint8List.fromList(
  utf8.encode(
    jsonEncode([
      StoredPage.strokeToJson(
        Stroke.fromPoints(
          style: const StrokeStyle(ink: InkPalette.ink, width: 2),
          points: const [InkVector(60, 60), InkVector(100, 90)],
        ),
      ),
    ]),
  ),
);

StudyTestPaper _paper({bool handwritten = true}) => StudyTestPaper(
  id: 'review-test',
  title: 'Algebra test',
  courseName: 'Math',
  instructions: 'Show your working.',
  createdAt: _now,
  updatedAt: _now,
  questions: handwritten
      ? [
          TestFreeResponseQuestion(
            id: 'derivation',
            prompt: 'Solve 2x = 4.',
            points: 10,
            subParts: const [],
            rubric: const ['Divide both sides by two'],
            modelAnswer: 'x = 2',
            handwritingStrokes: _ink(),
          ),
        ]
      : const [
          TestMultipleChoiceQuestion(
            id: 'choice',
            prompt: '2 + 2?',
            points: 2,
            options: [
              PracticeChoiceOption(id: 'A', text: '4'),
              PracticeChoiceOption(id: 'B', text: '5'),
            ],
            correctOptionId: 'A',
          ),
        ],
);

const _gradeJson =
    '{"awardedPoints":7,"maxPoints":10,"feedback":"Check the sign.",'
    '"breakdown":["+7 valid method","-3 sign error"],"recognizedMathOrText":"x = -2"}';
const _gradeSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" data-etonia-version="1" '
    'viewBox="0 0 760 360" data-etonia-bounds="110 60 220 100">'
    '<title>Grading</title><desc data-etonia-role="message">$_gradeJson</desc>'
    '<path d="M120 80 L140 100 M140 80 L120 100" fill="none" stroke="red" stroke-width="2"/>'
    '<text x="170" y="95" font-size="16" fill="red">-3 sign</text></svg>';

Future<StudyDeskController> _desk(
  AiClient client, {
  StudyDeskStore? store,
  StudyPracticeStore? practice,
  InMemoryNoteRepository? repository,
}) async {
  final repo = repository ?? InMemoryNoteRepository();
  final desk = StudyDeskController(
    repository: repo,
    client: client,
    store: store,
    practiceStore: practice ?? InMemoryStudyPracticeStore(),
    clock: () => _now,
  );
  await desk.load();
  addTearDown(desk.dispose);
  if (repository == null) addTearDown(repo.dispose);
  return desk;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'one notation-model request preserves student ink and saves marks for export',
    () async {
      final original = _paper();
      final originalInk = original.questions.single.handwritingStrokes!;
      final image = await renderTestAnswer(originalInk);
      var calls = 0;
      final client = BackendAiClient(
        invoke: (_, body) async {
          calls++;
          expect(body['task'], 'testGrading');
          expect(body['model'], 'auto');
          expect((body['routing'] as Map)['task'], 'test.grading');
          expect(
            body['selectedSvg'],
            contains('data-etonia-selection-bounds="0 0 760.0 360.0"'),
          );
          return {
            'answer': _gradeSvg,
            'usage': {'inputTokens': 20, 'outputTokens': 30},
          };
        },
      );
      addTearDown(client.close);
      final desk = await _desk(client);
      desk.selectModel(AiModelId.astra);
      final graded = await desk.testGrader.grade(
        original,
        snapshot: (_) async => image,
      );
      expect(calls, 1);
      expect(desk.selectedModel, AiModelId.astra);
      expect(graded.totalScore, 7);
      final response = graded.questions.single as TestFreeResponseQuestion;
      expect(response.handwritingStrokes, originalInk);
      expect(
        decodeTestInk(response.aiEvaluation!.markingStrokes).length,
        greaterThan(2),
      );
      final restored = StudyTestPaper.fromJson(
        jsonDecode(jsonEncode(graded.toJson())) as Map<String, dynamic>,
      );
      final marked = await snapshotStudyTestQuestion(restored.questions.single);
      expect(marked, isNot(image));
      expect(
        (restored.questions.single as TestFreeResponseQuestion)
            .aiEvaluation!
            .markingStrokes,
        response.aiEvaluation!.markingStrokes,
      );
    },
  );

  test(
    'review chat retains its test after session switches and restart, and sends its real work',
    () async {
      final client = FakeAiClient();
      final store = InMemoryStudyDeskStore();
      final practice = InMemoryStudyPracticeStore();
      final repo = InMemoryNoteRepository();
      addTearDown(repo.dispose);
      addTearDown(client.close);
      await repo.createNote(title: 'Unrelated private library note');
      final desk = await _desk(
        client,
        store: store,
        practice: practice,
        repository: repo,
      );
      final graded = await StudyTestGrader(
        send: (_) async => const AiSuccess(_gradeJson),
      ).grade(_paper(), snapshot: (_) async => renderTestAnswer(_ink()));
      await desk.saveTestPaper(graded);
      desk.newChat();
      final previousId = desk.sessionId;
      desk.startTestReviewChat(graded);
      final reviewId = desk.sessionId;
      expect(reviewId, isNot(previousId));
      expect(desk.mode, StudyDeskMode.chat);
      expect(desk.currentSession.testPaperId, graded.id);
      expect(desk.retrievalNotes, isEmpty);
      desk.newChat();
      desk.openSession(reviewId);
      final kept = StudyDeskState.fromJson(
        jsonDecode(jsonEncode((await store.read())!.toJson()))
            as Map<String, dynamic>,
      );
      final diskStore = InMemoryStudyDeskStore();
      await diskStore.write(kept);
      final reopened = await _desk(
        client,
        store: diskStore,
        practice: practice,
        repository: repo,
      );
      expect(reopened.testPaperSource!.id, graded.id);
      final pending = reopened.send('Why did I lose points on question 1?');
      for (var i = 0; i < 100 && client.requests.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(client.requests, hasLength(1));
      final request = client.requests.single;
      expect(request.messages.last.text, contains('Check the sign.'));
      expect(request.messages.last.text, contains('x = -2'));
      expect(
        request.messages.last.text,
        isNot(contains('Unrelated private library note')),
      );
      expect(request.imagePng, isNotEmpty);
      expect(request.systemInstruction, contains('completed, graded test'));
      client.answer('Question 1 lost three points for the sign error.');
      await pending;
      expect(reopened.messages.last.text, contains('three points'));
      expect(reopened.testPapers.single.totalScore, 7);
    },
  );

  for (final size in [const Size(390, 844), const Size(1400, 1000)]) {
    testWidgets('Review Graded Paper opens its chat and reuses it at $size', (
      tester,
    ) async {
      final client = FakeAiClient();
      addTearDown(client.close);
      final desk = await _desk(client);
      final graded = _paper(
        handwritten: false,
      ).copyWith(isSubmitted: true, totalScore: 2);
      await desk.saveTestPaper(graded);
      desk.setMode(StudyDeskMode.practice);
      desk.setPracticeSection(PracticeStudioSection.tests);
      await pumpApp(
        tester,
        size: size,
        home: Scaffold(
          body: StudyDeskScreen(
            controller: desk,
            thumbnail: (_) => const SizedBox(),
            onEditCitation: (_) {},
            onAddSources: () {},
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('study-paper-menu-review-test')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review Graded Paper'));
      await tester.pumpAndSettle();
      expect(desk.mode, StudyDeskMode.chat);
      expect(desk.testPaperSource?.id, graded.id);
      expect(find.text('Graded Paper'), findsOneWidget);
      if (size.width >= 840) {
        final chat = tester.getRect(
          find.byKey(const ValueKey('study-chat-column')),
        );
        final paper = tester.getRect(find.byType(StudyTestPaperPlayer));
        expect(chat.right, lessThanOrEqualTo(paper.left));
        expect(
          find.byKey(const ValueKey('study-composer')).hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('study-navigation-sidebar')),
          findsNothing,
        );
        final divider = find.byKey(const ValueKey('study-graded-paper-resize'));
        await tester.drag(divider, const Offset(-180, 0));
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byType(StudyTestPaperPlayer)).width,
          greaterThan(paper.width + 100),
        );
        await tester.drag(divider, const Offset(1500, 0));
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byType(StudyTestPaperPlayer)).width,
          greaterThanOrEqualTo(320),
        );
        expect(
          find.byKey(const ValueKey('study-composer')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } else {
        expect(find.byType(BottomSheet), findsOneWidget);
      }
      final reviewId = desk.sessionId;
      await tester.tap(find.byTooltip('Close graded paper'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('study-composer')).hitTestable(),
        findsOneWidget,
      );
      desk.openTestReview(graded);
      await tester.pumpAndSettle();
      expect(desk.sessionId, reviewId);
      expect(
        desk.allSessions.where((session) => session.testPaperId == graded.id),
        hasLength(1),
      );
      expect(find.text('Graded Paper'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('submitting opens a new test-sourced chat at $size', (
      tester,
    ) async {
      final client = FakeAiClient();
      addTearDown(client.close);
      final desk = await _desk(client);
      await desk.saveTestPaper(_paper(handwritten: false));
      desk.openTestPaper(desk.testPapers.single);
      final previousId = desk.sessionId;
      await pumpApp(
        tester,
        size: size,
        home: Scaffold(
          body: StudyDeskScreen(
            controller: desk,
            thumbnail: (_) => const SizedBox(),
            onEditCitation: (_) {},
            onAddSources: () {},
          ),
        ),
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('test-option-choice-A')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('test-option-choice-A')));
      await tester.pump(const Duration(milliseconds: 450));
      await tester.tap(find.text('Grade now'));
      await tester.pumpAndSettle();
      expect(desk.sessionId, isNot(previousId));
      expect(desk.mode, StudyDeskMode.chat);
      expect(desk.testPaperSource!.totalScore, 2);
      expect(find.byKey(const ValueKey('study-test-source')), findsOneWidget);
      expect(find.byKey(const ValueKey('study-composer')), findsOneWidget);
      if (size.width < 900) {
        await tester.tap(find.byKey(const ValueKey('study-test-source')));
        await tester.pumpAndSettle();
      }
      expect(find.text('Graded Paper'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'failed grading keeps answers editable and creates no review chat until retry succeeds',
    (tester) async {
      final client = FakeAiClient();
      addTearDown(client.close);
      final desk = await _desk(client);
      final paper = _paper();
      await desk.saveTestPaper(paper);
      final previous = desk.sessionId;
      await pumpApp(
        tester,
        home: Scaffold(
          body: StudyTestPaperPlayer(
            paper: paper,
            controller: desk,
            onClose: () {},
            onViewCitation: (_) {},
          ),
        ),
      );
      await tester.tap(find.text('Grade now'));
      await settleAi(tester);
      expect(client.requests.single.testGrading, isTrue);
      expect(client.requests.single.notationEnabled, isTrue);
      client.fail(AiFailureKind.network);
      await tester.pumpAndSettle();
      expect(desk.sessionId, previous);
      expect(desk.testPapers.single.isSubmitted, isFalse);
      expect(
        desk.testPapers.single.questions.single.handwritingStrokes,
        paper.questions.single.handwritingStrokes,
      );
      await tester.tap(find.text('Grade now'));
      await settleAi(tester);
      client.answerResponse(AiAssistantResponse.parse(_gradeSvg));
      await tester.pumpAndSettle();
      expect(desk.sessionId, isNot(previous));
      expect(desk.testPaperSource!.isSubmitted, isTrue);
      expect(desk.testPaperSource!.totalScore, 7);
      expect(
        find.byKey(ValueKey('test-marking-${paper.questions.single.id}')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'review payload bounds long papers and does not invent an out-of-range question',
    () async {
      final original = _paper(handwritten: false);
      final long = original.copyWith(
        questions: [
          for (var i = 0; i < 100; i++)
            TestMultipleChoiceQuestion(
              id: '$i',
              prompt: 'Question $i ${'algebra ' * 100}',
              points: 2,
              options: const [PracticeChoiceOption(id: 'A', text: '4')],
              correctOptionId: 'A',
            ),
        ],
      );
      final payload = await studyTestReviewPayload(
        long,
        'Explain question 500',
        const [],
      );
      expect(utf8.encode(payload.contextText).length, lessThan(19000));
      expect(payload.contextText, contains('outside this test'));
      expect(payload.contextText, contains('Remaining test context omitted'));
    },
  );
}
