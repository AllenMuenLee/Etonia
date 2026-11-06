import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/features/editor/ai/ai_assistant_controller.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/backend_ai_client.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/page/page_viewport.dart';
import 'package:greatnote/features/editor/text/note_text.dart';
import 'package:greatnote/features/editor/widgets/ai_assistant_panel.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/study_desk/practice/study_practice_models.dart';
import 'package:greatnote/features/library/study_desk/practice/study_practice_store.dart';
import 'package:greatnote/features/library/study_desk/practice/study_test_paper_player.dart';
import 'package:greatnote/features/library/study_desk/practice/study_completed_test_pdf_exporter.dart';
import 'package:greatnote/features/library/study_desk/practice/test_handwriting_canvas.dart';
import 'package:greatnote/features/library/study_desk/study_desk_controller.dart';
import 'package:greatnote/features/library/study_desk/study_desk_store.dart';
import 'package:greatnote/features/library/study_desk/study_source_tree.dart';

import '../../../helpers/ai_fakes.dart';
import '../../../helpers/pump_app.dart';

final now = DateTime(2026, 11, 6);

NoteEntry note(String id, String? folder) => NoteEntry(
  id: id,
  title: id,
  folderId: folder,
  created: now,
  modified: now,
  pageCount: 1,
);

Folder folder(String id, String? parent) =>
    Folder(id: id, name: id, parentId: parent, created: now, modified: now);

void main() {
  testWidgets('returning to the source chat saves pending test answers', (
    tester,
  ) async {
    setViewportSize(tester, const Size(1200, 1000));
    final repo = InMemoryNoteRepository();
    final entry = await repo.createNote(title: 'Algebra');
    final client = FakeAiClient();
    final practice = InMemoryStudyPracticeStore();
    final desk = StudyDeskController(
      repository: repo,
      client: client,
      practiceStore: practice,
    );
    addTearDown(repo.dispose);
    addTearDown(client.close);
    addTearDown(desk.dispose);
    await desk.load();
    desk.importAssistantConversation(
      messages: const [AiMessage.user('Explain equations')],
      noteId: entry.id,
    );
    final original = desk.sessionId;
    final paper = StudyTestPaper(
      id: 'test',
      title: 'Equations',
      courseName: 'Math',
      instructions: 'Choose an answer.',
      createdAt: now,
      updatedAt: now,
      sourceSessionId: original,
      questions: const [
        TestMultipleChoiceQuestion(
          id: 'q',
          prompt: '2x = 4?',
          options: [
            PracticeChoiceOption(id: 'A', text: '2'),
            PracticeChoiceOption(id: 'B', text: '3'),
          ],
          correctOptionId: 'A',
        ),
      ],
    );
    await desk.saveTestPaper(paper);
    desk.openTestPaper(paper);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: StudyTestPaperPlayer(
            paper: paper,
            controller: desk,
            onClose: () {},
            onViewCitation: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('test-option-q-A')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('test-source-conversation')));
    await tester.pumpAndSettle();
    expect(desk.sessionId, original);
    expect(desk.mode, StudyDeskMode.chat);
    expect(desk.activeTestPaperId, isNull);
    expect(
      ((await practice.loadPapers()).single.questions.single
              as TestMultipleChoiceQuestion)
          .selectedOptionId,
      'A',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'graded callouts open on the shared note viewport and survive export',
    (tester) async {
      const annotation = TestAiAnnotation(
        x: .5,
        y: .25,
        label: '-2: Check the sign.',
        isCorrect: false,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: TestHandwritingCanvas(
              readOnly: true,
              onChanged: (_) {},
              annotations: const [annotation],
            ),
          ),
        ),
      );
      expect(find.byType(PageViewport), findsOneWidget);
      expect(find.byKey(const ValueKey('study-in-situ-toolbar')), findsNothing);
      await tester.tap(find.byIcon(Icons.error));
      await tester.pumpAndSettle();
      expect(find.text(annotation.label), findsOneWidget);
      await tester.runAsync(() async {
        final plain = await renderTestAnswer(null);
        final marked = await renderTestAnswer(
          null,
          annotations: const [annotation],
        );
        expect(marked, isNot(orderedEquals(plain)));
        final exportedText = <String>[];
        final paper = StudyTestPaper(
          id: 'marked',
          title: 'Test',
          courseName: '',
          instructions: '',
          createdAt: now,
          updatedAt: now,
          questions: const [
            TestFreeResponseQuestion(
              id: 'q',
              prompt: 'Solve',
              subParts: [],
              rubric: [],
              aiEvaluation: TestAiEvaluation(
                awardedPoints: 8,
                maxPoints: 10,
                feedback: 'Check your arithmetic.',
                breakdown: [],
                annotations: [annotation],
              ),
            ),
          ],
        );
        await StudyCompletedTestPdfExporter().export(
          paper,
          rasterizeText:
              (
                text, {
                required widthPt,
                required fontSize,
                required bold,
              }) async {
                exportedText.add(text);
                return (png: plain, heightPt: 12.0);
              },
        );
        expect(exportedText, contains('1. ${annotation.label}'));
      });
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'import preserves the transcript, source note and existing chats after restart',
    () async {
      final repo = InMemoryNoteRepository();
      final entry = await repo.createNote(title: 'Algebra');
      final store = InMemoryStudyDeskStore();
      final client = FakeAiClient();
      final desk = StudyDeskController(
        repository: repo,
        client: client,
        store: store,
      );
      addTearDown(repo.dispose);
      addTearDown(client.close);
      addTearDown(desk.dispose);
      await desk.load();
      desk.importAssistantConversation(
        messages: const [AiMessage.user('First chat')],
        noteId: entry.id,
      );
      final previous = desk.sessionId;
      const transcript = [
        AiMessage.user('Solve 2x = 4'),
        AiMessage.model('Divide by two: x = 2.'),
      ];
      desk.importAssistantConversation(messages: transcript, noteId: entry.id);
      final imported = desk.sessionId;
      expect(imported, isNot(previous));
      expect(desk.messages.map((m) => m.text), transcript.map((m) => m.text));
      expect(desk.messages.map((m) => m.fromUser), [true, false]);
      expect(desk.sources.single.noteId, entry.id);
      final restored = StudyDeskController(
        repository: repo,
        client: client,
        store: store,
      );
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.sessionId, imported);
      expect(
        restored.messages.map((m) => m.text),
        transcript.map((m) => m.text),
      );
      restored.openMaterialSourceChat(previous);
      expect(restored.messages.single.text, 'First chat');
    },
  );

  test(
    'import removes assistant footers and persists the visible transcript',
    () async {
      final repo = InMemoryNoteRepository();
      final entry = await repo.createNote(title: 'MOSFET');
      final store = InMemoryStudyDeskStore();
      final client = FakeAiClient();
      final desk = StudyDeskController(
        repository: repo,
        client: client,
        store: store,
      );
      addTearDown(repo.dispose);
      addTearDown(client.close);
      addTearDown(desk.dispose);
      await desk.load();
      const transcript = [
        AiMessage.user('Internal quick-action prompt', label: 'Explain'),
        AiMessage.model(
          'The gate voltage controls the channel.\n\n'
          'Notation: the cutoff and linear formulas in blue below the saturation formula.\n\n(end)\n'
          'MOSFET overview complete.\n'
          'Review the regions and the threshold condition next.\n'
          'Good luck.\n(stop)\nFinal line.\n.....',
        ),
        AiMessage.user('What does (stop) mean?'),
        AiMessage.model('(stop)\nFinal line.'),
      ];
      desk.importAssistantConversation(messages: transcript, noteId: entry.id);
      const expected = [
        'Explain',
        'The gate voltage controls the channel.',
        'What does (stop) mean?',
      ];
      expect(desk.messages.map((m) => m.text), expected);
      expect(desk.sources.single.noteId, entry.id);
      expect(transcript[1].text, contains('MOSFET overview complete.'));
      final restored = StudyDeskController(
        repository: repo,
        client: client,
        store: store,
      );
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.messages.map((m) => m.text), expected);
      expect(restored.messages.map((m) => m.fromUser), [true, false, true]);
    },
  );

  test(
    'generation retains the originating chat when another chat is opened in flight',
    () async {
      final repo = InMemoryNoteRepository();
      final entry = await repo.createNote(title: 'Algebra');
      await repo.saveNote(
        entry.id,
        NoteContent([
          StoredPage(
            setup: const PageSetup(),
            strokes: const [],
            textElements: [
              NoteTextElement(
                id: 'text',
                position: const InkVector(40, 40),
                text: 'Solve linear equations by dividing both sides.',
              ),
            ],
          ),
        ]),
      );
      final response = Completer<Map<String, dynamic>>();
      final requested = Completer<void>();
      Map<String, Object?>? sent;
      final client = BackendAiClient(
        invoke: (_, body) {
          sent = body;
          if (!requested.isCompleted) requested.complete();
          return response.future;
        },
      );
      final store = InMemoryStudyDeskStore();
      final practice = InMemoryStudyPracticeStore();
      final desk = StudyDeskController(
        repository: repo,
        client: client,
        store: store,
        practiceStore: practice,
      );
      addTearDown(repo.dispose);
      addTearDown(client.close);
      addTearDown(desk.dispose);
      await desk.load();
      desk.importAssistantConversation(
        messages: const [AiMessage.user('Explain dividing both sides')],
        noteId: entry.id,
      );
      final original = desk.sessionId;
      final generating = desk.generateTestPaperFromActiveTopic(
        topic: 'Linear equations',
        mcqCount: 1,
        frqCount: 0,
      );
      await requested.future.timeout(const Duration(seconds: 10));
      expect(sent?['prompt'], contains('Explain dividing both sides'));
      desk.newChat();
      final newer = desk.sessionId;
      final json = jsonEncode({
        'title': 'Linear equations',
        'courseName': 'Algebra',
        'instructions': 'Choose an answer.',
        'questions': [
          {
            'id': 'q',
            'kind': 'multipleChoice',
            'prompt': '2x = 4. Find x.',
            'points': 2,
            'correctOptionId': 'B',
            'options': [
              for (final id in ['A', 'B', 'C', 'D']) {'id': id, 'text': id},
            ],
          },
        ],
      }).replaceAll('&', '&amp;').replaceAll('<', '&lt;');
      response.complete({
        'usage': {'inputTokens': 100, 'outputTokens': 100},
        'answer':
            '<svg xmlns="http://www.w3.org/2000/svg" data-etonia-version="1"><title>Test</title><desc data-etonia-role="message">$json</desc></svg>',
      });
      final generated = await generating;
      expect(generated, isNotNull, reason: '${desk.practiceFailure}');
      expect(generated!.sourceSessionId, original);
      expect(desk.sessionId, newer);
      expect(desk.activeTestPaperId, isNull);
      expect((await practice.loadPapers()).single.sourceSessionId, original);
      expect(
        StudyTestPaper.fromJson(
          generated.copyWith(isSubmitted: true).toJson(),
        ).sourceSessionId,
        original,
      );
      desk.openMaterialSourceChat(original);
      expect(desk.messages.single.text, 'Explain dividing both sides');
    },
  );

  test(
    'deck reset, review edits and legacy conversion retain the source chat',
    () {
      final deck = StudyPracticeSet(
        id: 'deck',
        title: 'Algebra',
        createdAt: now,
        updatedAt: now,
        sourceSessionId: 'chat',
      );
      final restored = StudyPracticeSet.fromJson(
        deck.reset(now).copyWith(title: 'Renamed').toJson(),
      );
      expect(restored.sourceSessionId, 'chat');
      expect(StudyTestPaper.fromLegacy(restored).sourceSessionId, 'chat');
      final old = deck.toJson()..remove('sourceSessionId');
      expect(StudyPracticeSet.fromJson(old).sourceSessionId, isNull);
    },
  );

  testWidgets(
    'folder selection includes nested notes and survives collapsing and rebuilding',
    (tester) async {
      var selected = <String>{};
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => StudySourceTree(
                notes: [
                  note('First', 'Physics'),
                  note('Second', 'Mechanics'),
                  note('Other', null),
                ],
                folders: [
                  folder('Physics', null),
                  folder('Mechanics', 'Physics'),
                ],
                selected: selected,
                onSelectionChanged: (next) => setState(() => selected = next),
              ),
            ),
          ),
        ),
      );
      final physics = find.byKey(const ValueKey('source-tree-folder-Physics'));
      final checkbox = find
          .descendant(of: physics, matching: find.byType(Checkbox))
          .first;
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      expect(selected, {'First', 'Second'});
      await tester.tap(find.text('Mechanics'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mechanics'));
      await tester.pumpAndSettle();
      expect(find.text('Second'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('source-tree-note-Second')));
      await tester.pumpAndSettle();
      expect(selected, {'First'});
      expect(tester.widget<Checkbox>(checkbox).value, isNull);
    },
  );

  testWidgets('read-only source tree opens nested notes', (tester) async {
    String? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudySourceTree(
            notes: [note('Equations', 'Algebra')],
            folders: [folder('Math', null), folder('Algebra', 'Math')],
            onOpenNote: (id) => opened = id,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Equations'));
    expect(opened, 'Equations');
  });

  testWidgets(
    'assistant import is disabled for an empty conversation and enabled for completed messages',
    (tester) async {
      final client = FakeAiClient();
      final controller = AiAssistantController(client: client);
      addTearDown(controller.dispose);
      addTearDown(client.close);
      var imports = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: AiAssistantPanel(
              controller: controller,
              onClose: () {},
              onNewChat: () {},
              onAddToContext: () {},
              onImportToStudyDesk: () => imports++,
            ),
          ),
        ),
      );
      final button = find.byKey(const ValueKey('ai-import-to-study-desk'));
      expect(tester.widget<IconButton>(button).onPressed, isNull);
      controller.send('Explain linear equations');
      await tester.pump();
      expect(tester.widget<IconButton>(button).onPressed, isNull);
      client.answer('Divide both sides by the coefficient.');
      await tester.pumpAndSettle();
      await tester.tap(button);
      expect(imports, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
