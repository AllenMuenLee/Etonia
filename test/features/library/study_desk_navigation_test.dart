import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/text/note_text.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/study_desk/practice/study_generate_test_sheet.dart';
import 'package:greatnote/features/library/study_desk/practice/study_practice_generator.dart';
import 'package:greatnote/features/library/study_desk/practice/study_practice_models.dart';
import 'package:greatnote/features/library/study_desk/practice/study_practice_store.dart';
import 'package:greatnote/features/library/study_desk/study_desk_controller.dart';
import 'package:greatnote/features/library/study_desk/study_desk_models.dart';
import 'package:greatnote/features/library/study_desk/study_desk_screen.dart';
import 'package:greatnote/features/library/study_desk/study_desk_store.dart';
import 'package:greatnote/features/library/study_desk/study_source_picker.dart';

import '../../helpers/ai_fakes.dart';
import '../../helpers/pump_app.dart';

final _now = DateTime(2026, 11, 5);
Finder key(String value) => find.byKey(ValueKey(value));

Future<
  ({StudyDeskController desk, FakeAiClient client, String first, String second})
>
fixture({List<StudyMessage> messages = const []}) async {
  final repository = InMemoryNoteRepository();
  final first = await repository.createNote(title: 'Mechanics');
  final second = await repository.createNote(title: 'Chemistry');
  for (final note in [first, second]) {
    await repository.saveNote(
      note.id,
      NoteContent([
        StoredPage(
          setup: const PageSetup(),
          strokes: const [],
          textElements: [
            NoteTextElement(
              id: 'text',
              position: const InkVector(40, 40),
              text: note == first
                  ? 'Momentum is mass times velocity. Mechanics marker alpha.'
                  : 'Acids donate protons. Chemistry marker beta.',
            ),
          ],
        ),
      ]),
    );
  }
  final store = InMemoryStudyDeskStore();
  await store.write(
    StudyDeskState(
      currentSessionId: 'chat',
      sessions: [
        StudySession(
          id: 'chat',
          created: _now,
          title: 'A saved chat',
          messages: messages,
          sources: [StudySourceItem(noteId: first.id)],
        ),
      ],
      courses: [
        StudyCourse(
          id: 'physics',
          name: 'Physics',
          colorHex: '#A5A5A5',
          createdAt: _now,
          associatedNoteIds: [first.id],
        ),
      ],
    ),
  );
  final practice = InMemoryStudyPracticeStore();
  for (final grouped in [false, true]) {
    final suffix = grouped ? 'class' : 'ungrouped';
    await practice.saveSet(
      StudyPracticeSet(
        id: 'deck-$suffix',
        title: 'Deck $suffix',
        courseId: grouped ? 'physics' : null,
        createdAt: _now,
        updatedAt: _now,
        flashcards: const [
          PracticeFlashcard(
            id: 'card',
            frontPrompt: 'What is momentum?',
            backAnswer: 'Mass times velocity.',
          ),
        ],
      ),
    );
    await practice.savePaper(
      StudyTestPaper(
        id: 'paper-$suffix',
        title: 'Test $suffix',
        courseName: 'Physics',
        courseId: grouped ? 'physics' : null,
        instructions: 'Show your work.',
        createdAt: _now,
        updatedAt: _now,
        questions: const [],
      ),
    );
  }
  final client = FakeAiClient();
  final desk = StudyDeskController(
    repository: repository,
    client: client,
    store: store,
    practiceStore: practice,
  );
  await desk.load();
  addTearDown(() {
    desk.dispose();
    repository.dispose();
    client.close();
  });
  return (desk: desk, client: client, first: first.id, second: second.id);
}

Future<void> mount(
  WidgetTester tester,
  StudyDeskController desk, {
  Widget? body,
  Size size = const Size(1200, 950),
}) async {
  setViewportSize(tester, size);
  await tester.pumpWidget(
    GreatnoteApp(
      home: Scaffold(
        body:
            body ??
            StudyDeskScreen(
              controller: desk,
              thumbnail: (_) => const SizedBox(),
              onEditCitation: (_) {},
              onAddSources: () {},
            ),
      ),
    ),
  );
  if (body == null) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> waitForRequest(
  WidgetTester tester,
  FakeAiClient client,
  int count,
) async {
  for (var i = 0; i < 100 && client.requests.length < count; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(client.requests.length, count);
}

void main() {
  test(
    'class sources initialize chats without collecting edits from other chats',
    () async {
      final f = await fixture(
        messages: [const StudyMessage.user('Explain momentum')],
      );
      final original = f.desk.sessionId;
      final course = f.desk.courses.single;
      f.desk.startCourseChat(course);
      expect(f.desk.sources.map((s) => s.noteId), [f.first]);
      f.desk.removeSource(f.first);
      f.desk.addNotes([f.second]);
      expect(f.desk.courseNoteIds(course), {f.first});
      f.desk.startCourseChat(course);
      expect(f.desk.sources.map((s) => s.noteId), [f.first]);
      f.desk.openSession(original);
      expect(f.desk.sources.map((s) => s.noteId), [f.first]);
    },
  );

  testWidgets(
    'sidebar opens complete libraries with ungrouped work first and list view',
    (tester) async {
      final f = await fixture();
      await mount(tester, f.desk);
      expect(key('study-mode-practice'), findsNothing);
      expect(key('study-add-sources'), findsNothing);
      expect(find.byTooltip('Close history'), findsOneWidget);
      expect(key('study-sidebar-search'), findsNothing);
      await tester.tap(key('study-search-history'));
      await tester.pumpAndSettle();
      expect(key('study-sidebar-search'), findsOneWidget);
      await tester.tap(key('study-search-history'));
      await tester.pumpAndSettle();
      await tester.tap(key('study-nav-flashcards'));
      await tester.pumpAndSettle();
      expect(key('practice-deck-deck-ungrouped'), findsOneWidget);
      expect(key('practice-deck-deck-class'), findsOneWidget);
      expect(
        tester.getTopLeft(key('study-material-group-ungrouped')).dy,
        lessThan(tester.getTopLeft(key('study-material-group-physics')).dy),
      );
      await tester.tap(key('study-material-list'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: key('practice-deck-deck-class'),
          matching: find.byType(ListTile),
        ),
        findsOneWidget,
      );
      await tester.tap(key('study-nav-tests'));
      await tester.pumpAndSettle();
      expect(key('study-paper-paper-ungrouped'), findsOneWidget);
      expect(key('study-paper-paper-class'), findsOneWidget);
      expect(key('practice-deck-deck-class'), findsNothing);
      await tester.tap(key('study-sidebar-back'));
      await tester.pumpAndSettle();
      expect(key('study-composer'), findsOneWidget);
    },
  );

  testWidgets(
    'source chips scroll with history, open preview, and remove only with x',
    (tester) async {
      final f = await fixture(
        messages: [
          for (var i = 0; i < 24; i++)
            StudyMessage.user('A long question about momentum, number $i.'),
        ],
      );
      await mount(tester, f.desk);
      expect(key('study-chat-source-${f.first}').hitTestable(), findsNothing);
      final transcript = find.ancestor(
        of: key('study-chat-sources'),
        matching: find.byType(Scrollable),
      );
      final list = find.byType(ListView).last;
      await tester.drag(list, const Offset(0, 2500));
      await tester.pumpAndSettle();
      await tester.ensureVisible(key('study-chat-source-${f.first}'));
      await tester.pumpAndSettle();
      expect(transcript, findsOneWidget);
      await tester.tap(key('study-chat-source-${f.first}'));
      await tester.pumpAndSettle();
      expect(f.desk.sources.single.noteId, f.first);
      expect(f.desk.paneOpen, isTrue);
      expect(f.desk.focus!.citation.noteId, f.first);
      await tester.tap(find.byTooltip('Remove source'));
      await tester.pumpAndSettle();
      expect(f.desk.sources, isEmpty);
    },
  );

  testWidgets('an open source picker cannot attach notes to another chat', (
    tester,
  ) async {
    final f = await fixture();
    await mount(tester, f.desk);
    final choosing = showStudySourcePicker(
      tester.element(find.byType(StudyDeskScreen)),
      controller: f.desk,
    );
    await tester.pumpAndSettle();
    await tester.tap(key('study-pick-note-${f.second}'));
    await tester.pump();
    f.desk.newChat();
    await tester.pump();
    await tester.tap(key('study-source-done'));
    await tester.pumpAndSettle();
    await choosing;
    expect(f.desk.sources, isEmpty);
  });

  testWidgets(
    'test setup uses selected materials and ignores stale lightweight suggestions',
    (tester) async {
      final f = await fixture();
      await mount(
        tester,
        f.desk,
        body: StudyGenerateTestSheet(controller: f.desk),
      );
      await waitForRequest(tester, f.client, 1);
      expect(f.client.requests.first.model, AiModelId.luna);
      expect(
        f.client.requests.first.messages.single.text,
        contains('marker alpha'),
      );
      expect(
        f.client.requests.first.messages.single.text,
        isNot(contains('marker beta')),
      );
      await tester.tap(key('test-material-${f.first}'));
      await tester.pump();
      await tester.tap(key('test-material-${f.second}'));
      await tester.pump(const Duration(milliseconds: 400));
      await waitForRequest(tester, f.client, 2);
      f.client.answer(
        '["Acid-base reactions", "Proton transfer", "pH"]',
        index: 1,
      );
      await tester.pumpAndSettle();
      f.client.answer('["Momentum", "Velocity", "Forces"]', index: 0);
      await tester.pumpAndSettle();
      expect(find.text('Acid-base reactions'), findsOneWidget);
      expect(find.text('Momentum'), findsNothing);
      expect(
        find.byType(DropdownButtonFormField<PracticeDifficulty>),
        findsNothing,
      );
      for (final difficulty in ['Fundamental', 'Medium', 'Hard']) {
        expect(find.text(difficulty), findsOneWidget);
      }
      await tester.tap(find.text('Acid-base reactions'));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'Acid-base reactions',
      );
      expect(f.desk.sources.single.noteId, f.first);
    },
  );

  test(
    'test generation sends only selected notes and keeps source ids',
    () async {
      final f = await fixture();
      final generating = f.desk.generateTestPaperFromActiveTopic(
        noteIds: [f.second],
        topic: 'Acids',
        mcqCount: 1,
        frqCount: 0,
      );
      for (var i = 0; i < 100 && f.client.requests.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        f.client.requests.single.messages.single.text,
        contains('marker beta'),
      );
      expect(
        f.client.requests.single.messages.single.text,
        isNot(contains('marker alpha')),
      );
      f.client.answer(
        jsonEncode({
          'title': 'Acids',
          'courseName': 'Chemistry',
          'instructions': 'Choose one.',
          'questions': [
            {
              'id': 'one',
              'kind': 'multipleChoice',
              'points': 1,
              'prompt': 'What does an acid donate?',
              'options': [
                {'id': 'A', 'text': 'A proton'},
                {'id': 'B', 'text': 'An electron'},
                {'id': 'C', 'text': 'A neutron'},
                {'id': 'D', 'text': 'An atom'},
              ],
              'correctOptionId': 'A',
            },
          ],
        }),
      );
      final paper = await generating;
      expect(paper, isNotNull);
      expect(paper!.sourceNoteIds, [f.second]);
      expect(f.desk.sources.single.noteId, f.first);
      expect(
        await f.desk.generateTestPaperFromActiveTopic(noteIds: []),
        isNull,
      );
    },
  );
}
