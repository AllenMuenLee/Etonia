import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/backend_ai_client.dart';
import 'package:greatnote/features/library/study_desk/practice/study_practice_models.dart';
import 'package:greatnote/features/library/study_desk/practice/study_practice_store.dart';
import 'package:greatnote/features/library/study_desk/practice/study_test_grader.dart';
import 'package:greatnote/features/library/study_desk/practice/study_completed_test_pdf_exporter.dart';
import 'package:greatnote/features/library/study_desk/practice/test_handwriting_canvas.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

const mcq = TestMultipleChoiceQuestion(
  id: 'mcq',
  prompt: '2 + 2?',
  options: [
    PracticeChoiceOption(id: 'A', text: '4'),
    PracticeChoiceOption(id: 'B', text: '5'),
  ],
  correctOptionId: 'A',
  points: 2,
);
TestFreeResponseQuestion frq() => TestFreeResponseQuestion(
  id: 'frq',
  prompt: 'Show the derivation.',
  subParts: const ['(a) Derive [4 Pts]', '(b) Evaluate [6 Pts]'],
  rubric: const ['Valid derivation', 'Correct result'],
  points: 10,
  handwritingStrokes: Uint8List.fromList(utf8.encode('[{"ink":"example"}]')),
);
StudyTestPaper paper(List<TestQuestion> questions) => StudyTestPaper(
  id: 'paper',
  title: 'Algebra',
  courseName: 'Math',
  instructions: 'Show all work.',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  questions: questions,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'full-page ink keeps its coordinates and bottom marks in snapshots',
    () async {
      final stroke = Stroke.fromPoints(
        style: const StrokeStyle(ink: InkPalette.ink, width: 5),
        points: const [InkVector(100, 980), InkVector(200, 980)],
      );
      final saved = encodeTestPageInk([stroke], const Size(760, 1123));
      final restored = TestQuestion.fromJson(
        mcq.copyWithStrokes(saved).toJson(),
      );
      expect(
        testInkPageSize(restored.handwritingStrokes),
        const Size(760, 1123),
      );
      expect(
        decodeTestInk(restored.handwritingStrokes).single.points,
        stroke.points,
      );
      final codec = await ui.instantiateImageCodec(
        await renderTestAnswer(saved),
      );
      try {
        final image = (await codec.getNextFrame()).image;
        try {
          expect(image.width, 760);
          expect(image.height, 1123);
          final pixels = (await image.toByteData())!;
          final offset = (980 * image.width + 150) * 4;
          expect(pixels.getUint8(offset), lessThan(150));
        } finally {
          image.dispose();
        }
      } finally {
        codec.dispose();
      }
    },
  );
  test(
    'reference sheets survive disk saves, answer changes and grading',
    () async {
      final dir = await Directory.systemTemp.createTemp('test-references-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/sets.json');
      final original = paper([mcq, frq()]).copyWith(
        referenceSheets: const [
          TestReferenceSheet(
            kind: TestReferenceKind.answerSheet,
            name: 'Marking key.pdf',
            imagePaths: ['key-1.png', 'key-2.png'],
            pdfPath: 'key.pdf',
          ),
          TestReferenceSheet(
            kind: TestReferenceKind.equationSheet,
            name: 'Formulas.png',
            imagePaths: ['formulas.png'],
          ),
        ],
      );
      await FileStudyPracticeStore(file).savePaper(original);
      final restored = (await FileStudyPracticeStore(file).loadPapers()).single;
      expect(
        restored.referenceSheets.map((s) => s.toJson()),
        original.referenceSheets.map((s) => s.toJson()),
      );
      final requests = <AiRequest>[];
      final loaded = <String>[];
      final grader = StudyTestGrader(
        send: (request) async {
          requests.add(request);
          return AiSuccess(
            requests.length <= 3
                ? 'Reference transcription ${requests.length}'
                : '{"awardedPoints":7,"maxPoints":10,"feedback":"Partial credit","breakdown":[]}',
          );
        },
      );
      final graded = await grader.grade(
        restored.copyWith(questions: [mcq.copyWithSelected('A'), frq()]),
        snapshot: (_) async => Uint8List.fromList([42]),
        loadReferenceImage: (path) async {
          loaded.add(path);
          return Uint8List.fromList([1]);
        },
      );
      expect(loaded, ['key-1.png', 'key-2.png', 'formulas.png']);
      expect(requests, hasLength(4));
      final context = jsonDecode(requests.last.messages.single.text) as Map;
      expect(context['referenceSheets'], hasLength(3));
      expect(
        requests.last.messages.single.text,
        contains('Reference transcription 3'),
      );
      expect(graded.totalScore, 9);
      expect(graded.referenceSheets, restored.referenceSheets);
      await FileStudyPracticeStore(file).savePaper(graded);
      expect(
        (await FileStudyPracticeStore(
          file,
        ).loadPapers()).single.referenceSheets.first.pdfPath,
        'key.pdf',
      );
    },
  );

  test(
    'unreadable reference sheets leave a test unsubmitted for retry',
    () async {
      final original = paper([frq()]).copyWith(
        referenceSheets: const [
          TestReferenceSheet(
            kind: TestReferenceKind.answerSheet,
            name: 'Key',
            imagePaths: ['missing.png'],
          ),
        ],
      );
      var sent = false;
      final grader = StudyTestGrader(
        send: (_) async {
          sent = true;
          return const AiSuccess('unused');
        },
      );
      await expectLater(
        grader.grade(
          original,
          snapshot: (_) async => Uint8List(0),
          loadReferenceImage: (_) async =>
              throw const FileSystemException('missing'),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(sent, isFalse);
      expect(original.isSubmitted, isFalse);
    },
  );
  testWidgets(
    'native canvas rejects touch, saves stylus ink, and restores it',
    (tester) async {
      Uint8List? saved;
      await tester.pumpWidget(
        GreatnoteApp(
          themeMode: ThemeMode.dark,
          home: Scaffold(
            body: SingleChildScrollView(
              child: TestHandwritingCanvas(onChanged: (ink) => saved = ink),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final canvas = find.byType(InkCanvas);
      expect(Theme.of(tester.element(canvas)).brightness, Brightness.light);
      final start = tester.getTopLeft(canvas) + const Offset(70, 70);
      final touch = await tester.startGesture(
        start,
        kind: PointerDeviceKind.touch,
      );
      await touch.moveBy(const Offset(40, 10));
      await touch.up();
      await tester.pump();
      expect(saved, isNull);
      final stylus = await tester.startGesture(
        start,
        kind: PointerDeviceKind.stylus,
      );
      await stylus.moveBy(const Offset(40, 10));
      await stylus.up();
      await tester.pump();
      expect(saved, isNotNull);
      final strokes = decodeTestInk(saved);
      expect(strokes, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        GreatnoteApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TestHandwritingCanvas(strokes: saved, onChanged: (_) {}),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<InkCanvas>(find.byType(InkCanvas))
            .controller
            .strokes
            .single
            .points
            .length,
        strokes.single.points.length,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  test(
    'completed papers export snapshots and grading feedback into a PDF',
    () async {
      final png = await renderTestAnswer(null);
      final captured = <String>[];
      var snapshots = 0;
      final bytes = await const StudyCompletedTestPdfExporter().export(
        paper([
          mcq.copyWithSelected('A'),
          frq().copyWithEvaluation(
            const TestAiEvaluation(
              awardedPoints: 7,
              maxPoints: 10,
              feedback: 'Check sign',
              breakdown: ['+7 working'],
            ),
          ),
        ]).copyWith(isSubmitted: true, totalScore: 9),
        snapshot: (q) async {
          snapshots++;
          return png;
        },
        rasterizeText:
            (text, {required widthPt, required fontSize, required bold}) async {
              captured.add(text);
              return (png: png, heightPt: 14.0);
            },
      );
      expect(latin1.decode(bytes.take(5).toList()), '%PDF-');
      expect(snapshots, 2);
      expect(captured.join('\n'), contains('[x] A. 4'));
      expect(captured.join('\n'), contains('7/10: Check sign'));
      expect(captured.join('\n'), contains('Final score: 9.0/12'));
    },
  );
  test('MCQ scores only a selected correct option and rejects unknown IDs', () {
    expect(mcq.isCorrect, isFalse);
    expect(mcq.copyWithSelected('A').isCorrect, isTrue);
    expect(mcq.copyWithSelected('B').isCorrect, isFalse);
    expect(() => mcq.copyWithSelected('Z'), throwsArgumentError);
  });
  test('mixed paper round trip preserves ink, rubric and grading', () {
    final original =
        paper([
          mcq.copyWithSelected('A'),
          frq().copyWithEvaluation(
            const TestAiEvaluation(
              awardedPoints: 7,
              maxPoints: 10,
              feedback: 'Check the sign.',
              breakdown: ['+7 derivation', '-3 sign error'],
              recognizedMathOrText: 'x = 2',
            ),
          ),
        ]).copyWith(
          isSubmitted: true,
          submittedAt: DateTime(2026, 2),
          totalScore: 9,
        );
    final restored = StudyTestPaper.fromJson(
      jsonDecode(jsonEncode(original.toJson())) as Map<String, Object?>,
    );
    expect(restored.toJson(), original.toJson());
    expect(restored.totalPoints, 12);
    expect(restored.answeredCount, 2);
  });
  test(
    'grader awards deterministic MCQ points and rubric partial credit',
    () async {
      var requests = 0;
      final grader = StudyTestGrader(
        send: (request) async {
          requests++;
          expect(request.imagePng, [1, 2, 3]);
          expect(request.messages.single.text, contains('Valid derivation'));
          return const AiSuccess(
            '{"awardedPoints":7,"maxPoints":10,"feedback":"Check sign","breakdown":["+7 working","-3 sign"]}',
          );
        },
      );
      final result = await grader.grade(
        paper([mcq.copyWithSelected('A'), frq()]),
        snapshot: (_) async => Uint8List.fromList([1, 2, 3]),
        clock: () => DateTime(2026, 2),
      );
      expect(result.totalScore, 9);
      expect(result.isSubmitted, isTrue);
      expect(result.submittedAt, DateTime(2026, 2));
      expect(
        (result.questions.last as TestFreeResponseQuestion)
            .aiEvaluation!
            .awardedPoints,
        7,
      );
      await grader.grade(
        result,
        snapshot: (_) async => throw StateError('Must not resubmit'),
      );
      expect(requests, 1);
    },
  );
  test('unanswered questions receive zero without an AI call', () async {
    final result =
        await StudyTestGrader(
          send: (_) => throw StateError('No request expected'),
        ).grade(
          paper([
            mcq,
            const TestFreeResponseQuestion(
              id: 'blank',
              prompt: 'Why?',
              subParts: [],
              rubric: [],
            ),
          ]),
          snapshot: (_) async => throw StateError('No snapshot expected'),
        );
    expect(result.totalScore, 0);
  });
  test('FRQ grading reads JSON and LaTeX through the backend envelope', () async {
    final client = BackendAiClient(
      invoke: (_, body) async {
        expect(
          body['systemInstruction'],
          contains('<desc data-etonia-role="message">'),
        );
        return {
          'answer':
              '<svg xmlns="http://www.w3.org/2000/svg" data-etonia-version="1" viewBox="0 0 760 360">'
              '<title>Grade</title><desc data-etonia-role="message">'
              r'{"awardedPoints":7,"maxPoints":10,"feedback":"Check $\sqrt{x} &lt; 2$ &amp; signs","breakdown":["+7 working"]}'
              '</desc></svg>',
          'usage': {'inputTokens': 10, 'outputTokens': 20},
        };
      },
    );
    addTearDown(client.close);
    final grader = StudyTestGrader(
      send: (request) async {
        final result = await client.send(request);
        expect(result, isA<AiSuccess>());
        return result as AiSuccess;
      },
    );
    final result = await grader.grade(
      paper([frq()]),
      snapshot: (_) async => Uint8List.fromList([1, 2, 3]),
    );
    expect(result.isSubmitted, isTrue);
    expect(result.totalScore, 7);
    expect(
      (result.questions.single as TestFreeResponseQuestion)
          .aiEvaluation!
          .feedback,
      r'Check $\sqrt{x} < 2$ & signs',
    );
  });
  test('invalid or mismatched AI grades never submit the paper', () async {
    for (final response in [
      '{"awardedPoints":11,"maxPoints":10,"feedback":"bad","breakdown":[]}',
      '{"awardedPoints":3,"maxPoints":4,"feedback":"bad","breakdown":[]}',
      '{"awardedPoints":7.5,"maxPoints":10,"feedback":"bad","breakdown":[]}',
      '{"awardedPoints":7,"maxPoints":10,"feedback":"bad","breakdown":[],"annotations":[{"x":2,"y":0.5,"label":"outside","isCorrect":true}]}',
    ]) {
      final original = paper([frq()]);
      final grader = StudyTestGrader(send: (_) async => AiSuccess(response));
      await expectLater(
        grader.grade(original, snapshot: (_) async => Uint8List(1)),
        throwsFormatException,
      );
      expect(original.isSubmitted, isFalse);
      expect(
        (original.questions.single as TestFreeResponseQuestion).aiEvaluation,
        isNull,
      );
    }
  });
  test(
    'legacy files migrate once and concurrent paper saves preserve ink',
    () async {
      final dir = await Directory.systemTemp.createTemp('study-paper-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/sets.json');
      final legacy = StudyPracticeSet(
        id: 'legacy',
        title: 'Old set',
        createdAt: DateTime(2025),
        updatedAt: DateTime(2025),
        flashcards: const [
          PracticeFlashcard(
            id: 'card',
            frontPrompt: 'Q',
            backAnswer: 'A',
            isMastered: true,
          ),
        ],
        multipleChoiceQuestions: const [
          PracticeMultipleChoice(
            id: 'q',
            question: 'Which?',
            options: [PracticeChoiceOption(id: 'A', text: 'Answer')],
            correctOptionId: 'A',
            userSelectedOptionId: 'A',
            isAnswered: true,
          ),
        ],
      );
      await file.writeAsString(
        jsonEncode({
          'schema': 1,
          'sets': [legacy.toJson()],
        }),
      );
      final store = FileStudyPracticeStore(file);
      expect((await store.loadDecks()).single.masteryRate, 1);
      final migrated = (await store.loadPapers()).single;
      expect(
        (migrated.questions.single as TestMultipleChoiceQuestion).isCorrect,
        isTrue,
      );
      await Future.wait([
        store.savePaper(paper([frq()])),
        store.savePaper(migrated.copyWith(totalScore: 2)),
      ]);
      final reopened = FileStudyPracticeStore(file);
      expect(await reopened.loadPapers(), hasLength(2));
      expect((await reopened.loadSets()).single.toJson(), legacy.toJson());
      await reopened.deletePaper(migrated.id);
      expect(await FileStudyPracticeStore(file).loadPapers(), hasLength(1));
    },
  );
  test('malformed exam file is preserved when a save is attempted', () async {
    final dir = await Directory.systemTemp.createTemp('study-paper-corrupt-');
    addTearDown(() => dir.delete(recursive: true));
    final store = FileStudyPracticeStore(File('${dir.path}/sets.json'));
    await store.paperFile.writeAsString('damaged');
    await expectLater(store.savePaper(paper([mcq])), throwsFormatException);
    expect(await store.paperFile.readAsString(), 'damaged');
  });
}
