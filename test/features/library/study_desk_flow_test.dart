import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/study_desk/practice/import_test_paper_sheet.dart';
import 'package:greatnote/features/library/study_desk/practice/study_generate_test_sheet.dart';
import 'package:greatnote/features/library/study_desk/practice/study_practice_models.dart';
import 'package:greatnote/features/library/study_desk/practice/study_practice_store.dart';
import 'package:greatnote/features/library/study_desk/practice/study_practice_studio_view.dart';
import 'package:greatnote/features/library/study_desk/study_desk_controller.dart';
import 'package:greatnote/features/library/study_desk/study_desk_models.dart';
import 'package:greatnote/features/library/study_desk/study_desk_screen.dart';
import 'package:greatnote/features/library/study_desk/study_desk_store.dart';
import 'package:greatnote/features/library/study_desk/study_source_picker.dart';

import '../../helpers/ai_fakes.dart';
import '../../helpers/pump_app.dart';

final _now = DateTime(2026, 11, 5, 12);

Future<
  ({
    StudyDeskController desk,
    StudyCourse course,
    FakeAiClient client,
    InMemoryStudyPracticeStore practice,
  })
>
_fixture() async {
  final repository = InMemoryNoteRepository();
  final note = await repository.createNote(title: 'Mechanics notes');
  final course = StudyCourse(
    id: 'physics',
    name: 'Physics',
    colorHex: '#006C67',
    createdAt: _now,
    associatedNoteIds: [note.id],
  );
  final other = StudyCourse(
    id: 'chem',
    name: 'Chemistry',
    colorHex: '#6750A4',
    createdAt: _now,
    associatedNoteIds: [note.id],
  );
  final store = InMemoryStudyDeskStore();
  await store.write(
    StudyDeskState(
      courses: [course, other],
      sources: [StudySourceItem(noteId: note.id)],
      sessions: [
        StudySession(
          id: 'chat',
          created: _now,
          courseId: course.id,
          messages: [
            const StudyMessage.user('Explain momentum'),
            const StudyMessage.answer('Momentum is mass times velocity.'),
          ],
        ),
        StudySession(
          id: 'other-chat',
          created: _now,
          courseId: other.id,
          messages: [const StudyMessage.user('Explain atoms')],
        ),
        StudySession(
          id: 'quick',
          created: _now,
          messages: [const StudyMessage.user('What is a prime number?')],
        ),
      ],
      currentSessionId: 'chat',
    ),
  );
  final practice = InMemoryStudyPracticeStore();
  for (final owner in [course.id, other.id]) {
    await practice.saveSet(
      StudyPracticeSet(
        id: 'deck-$owner',
        title: '$owner deck',
        createdAt: _now,
        updatedAt: _now,
        courseId: owner,
        sourceNoteIds: [note.id],
        flashcards: [
          PracticeFlashcard(
            id: 'card-$owner',
            frontPrompt: 'Define momentum',
            backAnswer: 'Mass times velocity',
          ),
        ],
      ),
    );
    await practice.savePaper(
      StudyTestPaper(
        id: 'paper-$owner',
        title: '$owner test',
        courseName: owner,
        instructions: 'Answer all questions',
        createdAt: _now,
        updatedAt: _now,
        courseId: owner,
        sourceNoteIds: [note.id],
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
  return (desk: desk, course: course, client: client, practice: practice);
}

Future<void> _mount(
  WidgetTester tester,
  StudyDeskController desk, {
  Size size = const Size(1200, 900),
  ThemeMode theme = ThemeMode.light,
  double textScale = 1,
}) async {
  setViewportSize(tester, size);
  await tester.pumpWidget(
    GreatnoteApp(
      themeMode: theme,
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: StudyDeskScreen(
            controller: desk,
            thumbnail: (_) => const SizedBox(),
            onEditCitation: (_) {},
            onAddSources: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _tap(WidgetTester tester, String key) async {
  if (_key(key).evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      _key(key),
      250,
      scrollable: find.byType(Scrollable).last,
    );
  }
  await tester.ensureVisible(_key(key));
  await tester.pumpAndSettle();
  await tester.tap(_key(key));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'class chat sources can be edited independently and kept for the first message',
    (tester) async {
      final f = await _fixture();
      final extra = await f.desk.repository.createNote(
        title: 'Lab observations',
      );
      await _mount(tester, f.desk);
      await _tap(tester, 'study-class-physics');
      final original = f.desk.sources.single.noteId;
      final context = tester.element(_key('study-class-overview-physics'));
      final choosing = showStudySourcePicker(context, controller: f.desk);
      await tester.pumpAndSettle();
      await _tap(tester, 'study-pick-note-${extra.id}');
      await _tap(tester, 'study-source-done');
      await choosing;
      expect(f.desk.retrievalNoteIds, [original, extra.id]);
      tester
          .widget<InputChip>(_key('study-chat-source-$original'))
          .onDeleted!();
      await tester.pumpAndSettle();
      expect(f.desk.retrievalNoteIds, [extra.id]);
      expect(f.desk.selectedCourse!.associatedNoteIds, [original]);
      await tester.tap(_key('study-chat-source-${extra.id}'));
      await tester.pumpAndSettle();
      expect(f.desk.retrievalNoteIds, [extra.id]);
      expect(f.desk.paneOpen, isTrue);
      f.desk.closePane();
      await tester.pumpAndSettle();
      final session = f.desk.sessionId;
      await tester.enterText(
        _key('study-composer'),
        'Explain these observations',
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      for (var i = 0; i < 20 && f.client.requests.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(f.desk.page, StudyDeskPage.workspace);
      expect(f.desk.sessionId, session);
      expect(f.desk.currentSession.courseId, f.course.id);
      expect(f.desk.retrievalNoteIds, [extra.id]);
      f.client.answer('Here is what the observations show.');
      await tester.pumpAndSettle();
      expect(f.desk.currentSession.sources!.map((source) => source.noteId), [
        extra.id,
      ]);
    },
  );

  testWidgets('opens directly into chat with classes and history on the left', (
    tester,
  ) async {
    final f = await _fixture();
    await _mount(tester, f.desk);
    expect(_key('study-composer'), findsOneWidget);
    expect(_key('study-navigation-sidebar'), findsOneWidget);
    expect(_key('study-class-physics'), findsOneWidget);
    expect(_key('study-class-chem'), findsOneWidget);
    expect(find.text('Recent'), findsOneWidget);
    for (final chat in ['chat', 'other-chat', 'quick']) {
      expect(_key('study-session-$chat'), findsOneWidget);
    }
    expect(
      tester.getTopLeft(_key('study-navigation-sidebar')).dx,
      lessThan(tester.getTopLeft(_key('study-chat-column')).dx),
    );
    expect(find.text('Momentum is mass times velocity.'), findsOneWidget);
  });

  testWidgets('adding a class opens its page with chosen sources', (
    tester,
  ) async {
    final f = await _fixture();
    await _mount(tester, f.desk);
    await _tap(tester, 'study-add-class');
    await tester.enterText(find.byType(TextField).last, 'Calculus');
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Mechanics notes'));
    await tester.pump();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(f.desk.selectedCourse?.name, 'Calculus');
    expect(f.desk.page, StudyDeskPage.course);
    expect(f.desk.sources.map((s) => s.noteId), f.course.associatedNoteIds);
    expect(f.desk.messages, isEmpty);
    expect(f.desk.allSessions.map((s) => s.id), contains('chat'));
  });

  testWidgets(
    'class activity mixes chats, tests and flashcards below the composer',
    (tester) async {
      final f = await _fixture();
      await _mount(tester, f.desk);
      await _tap(tester, 'study-class-chem');
      expect(f.desk.page, StudyDeskPage.course);
      expect(f.desk.currentSession.courseId, 'chem');
      for (final chat in ['chat', 'other-chat', 'quick']) {
        expect(_key('study-session-$chat'), findsOneWidget);
      }
      final landing = _key('study-class-overview-chem');
      expect(landing, findsOneWidget);
      expect(find.text('General study'), findsNothing);
      expect(_key('study-class-material-chat-other-chat'), findsOneWidget);
      expect(_key('study-class-material-test-paper-chem'), findsOneWidget);
      expect(_key('study-class-tabs'), findsNothing);
      final composer = tester.getRect(_key('study-composer-bar'));
      expect(composer.center.dx, tester.getRect(landing).center.dx);
      expect(
        tester.getTopLeft(_key('study-class-material-chat-other-chat')).dy,
        greaterThan(composer.bottom),
      );
      await tester.scrollUntilVisible(
        _key('study-class-material-deck-deck-chem'),
        160,
        scrollable: find
            .descendant(of: landing, matching: find.byType(Scrollable))
            .first,
      );
      expect(_key('study-class-material-deck-deck-chem'), findsOneWidget);
      expect(_key('study-class-material-test-paper-physics'), findsNothing);
      await tester.ensureVisible(_key('study-class-material-test-paper-chem'));
      await tester.pumpAndSettle();
      await _tap(tester, 'study-class-material-test-paper-chem');
      expect(f.desk.activeTestPaperId, 'paper-chem');
      expect(f.desk.currentSession.courseId, 'chem');
      expect(f.desk.allSessions.map((s) => s.id), contains('chat'));
    },
  );

  testWidgets(
    'sending from a class expands a fresh chat and keeps its history',
    (tester) async {
      final f = await _fixture();
      await _mount(tester, f.desk);
      await _tap(tester, 'study-class-physics');
      final session = f.desk.sessionId;
      await tester.enterText(_key('study-composer'), 'Explain kinetic energy');
      await tester.pump();
      expect(_key('study-class-overview-physics'), findsOneWidget);
      await tester.tap(find.byTooltip('Send'));
      for (var i = 0; i < 12 && f.client.requests.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump();
      expect(f.desk.page, StudyDeskPage.workspace);
      expect(_key('study-class-overview-physics'), findsNothing);
      expect(f.desk.sessionId, session);
      expect(f.desk.currentSession.courseId, 'physics');
      expect(f.desk.sources.map((s) => s.noteId), f.course.associatedNoteIds);
      expect(f.desk.messages.single.text, 'Explain kinetic energy');
      expect(f.client.requests.single.messages, hasLength(1));
      f.client.answer('Kinetic energy is the energy of motion.');
      await tester.pumpAndSettle();
      expect(find.textContaining('energy of motion'), findsOneWidget);
      expect(f.desk.handleBack(), isTrue);
      await tester.pumpAndSettle();
      expect(_key('study-class-overview-physics'), findsOneWidget);
      await _tap(tester, 'study-class-material-chat-chat');
      expect(f.desk.page, StudyDeskPage.workspace);
      expect(find.text('Momentum is mass times velocity.'), findsOneWidget);
    },
  );

  testWidgets('sidebar keeps both libraries available across navigation', (
    tester,
  ) async {
    final f = await _fixture();
    await _mount(tester, f.desk);
    await _tap(tester, 'study-nav-flashcards');
    expect(_key('practice-deck-deck-physics'), findsOneWidget);
    expect(_key('practice-deck-deck-chem'), findsOneWidget);
    await _tap(tester, 'study-nav-tests');
    expect(_key('study-paper-paper-physics'), findsOneWidget);
    expect(_key('study-paper-paper-chem'), findsOneWidget);
    await _tap(tester, 'study-sidebar-back');
    expect(find.text('Momentum is mass times velocity.'), findsOneWidget);
    expect(find.text('Recent'), findsOneWidget);
  });

  testWidgets('class draft survives reselecting the class and switching tabs', (
    tester,
  ) async {
    final f = await _fixture();
    await _mount(tester, f.desk);
    await _tap(tester, 'study-class-physics');
    final session = f.desk.sessionId;
    await tester.enterText(_key('study-composer'), 'Help with this class');
    await _tap(tester, 'study-class-physics');
    expect(f.desk.sessionId, session);
    await _tap(tester, 'study-nav-flashcards');
    await _tap(tester, 'study-sidebar-back');
    expect(_key('study-class-overview-physics'), findsOneWidget);
    expect(
      tester.widget<TextField>(_key('study-composer')).controller!.text,
      'Help with this class',
    );
    expect(f.desk.messages, isEmpty);
  });

  testWidgets(
    'new chat clears explicit sources and searches the whole library',
    (tester) async {
      final f = await _fixture();
      await _mount(tester, f.desk);
      await _tap(tester, 'study-new-chat');
      expect(f.desk.messages, isEmpty);
      expect(f.desk.currentSession.courseId, isNull);
      expect(f.desk.sources, isEmpty);
      expect(f.desk.retrievalNoteIds, f.desk.allNotes.map((n) => n.id));
      expect(find.text('Searching your entire library'), findsNothing);
      expect(f.desk.allSessions.map((s) => s.id), contains('chat'));
    },
  );

  testWidgets('study creation forms work without attaching sources', (
    tester,
  ) async {
    final f = await _fixture();
    await _mount(tester, f.desk);
    await _tap(tester, 'study-new-chat');
    await tester.pumpAndSettle();
    await _tap(tester, 'study-nav-flashcards');
    await tester.tap(_key('practice-generate'));
    await tester.pumpAndSettle();
    expect(find.byType(StudyGenerateSheet), findsOneWidget);
    expect(
      tester.widget<FilledButton>(_key('generate-submit')).onPressed,
      isNotNull,
    );
    Navigator.of(tester.element(find.byType(StudyGenerateSheet))).pop();
    await tester.pumpAndSettle();
    await tester.tap(_key('study-nav-tests'));
    await tester.pumpAndSettle();
    expect(_key('study-material-import'), findsOneWidget);
    expect(find.text('Import test paper'), findsOneWidget);
    expect(find.text('Create test'), findsOneWidget);
    await tester.tap(_key('practice-generate'));
    await tester.pumpAndSettle();
    expect(find.byType(StudyGenerateTestSheet), findsOneWidget);
    Navigator.of(tester.element(find.byType(StudyGenerateTestSheet))).pop();
    await tester.pumpAndSettle();
    await tester.tap(_key('study-material-import'));
    await tester.pumpAndSettle();
    expect(find.byType(ImportTestPaperSheet), findsOneWidget);
  });

  testWidgets(
    'search filters saved conversations and reopening restores transcript',
    (tester) async {
      final f = await _fixture();
      await _mount(tester, f.desk);
      await _tap(tester, 'study-search-history');
      await tester.enterText(_key('study-sidebar-search'), 'no such chat');
      await tester.pumpAndSettle();
      expect(_key('study-session-chat'), findsNothing);
      await tester.enterText(_key('study-sidebar-search'), 'momentum');
      await tester.pumpAndSettle();
      await tester.tap(_key('study-session-chat').last);
      await tester.pumpAndSettle();
      expect(find.text('Momentum is mass times velocity.'), findsOneWidget);
    },
  );

  for (final size in [
    const Size(390, 844),
    const Size(800, 1280),
    const Size(1200, 900),
  ]) {
    testWidgets('chat and class navigation fit $size with large text', (
      tester,
    ) async {
      final f = await _fixture();
      await _mount(
        tester,
        f.desk,
        size: size,
        theme: ThemeMode.dark,
        textScale: 1.6,
      );

      if (size.width < 900) await _tap(tester, 'study-toggle-history');
      expect(_key('study-navigation-sidebar'), findsOneWidget);
      await _tap(tester, 'study-class-chem');
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        _key('study-class-material-test-paper-chem'),
        200,
        scrollable: find
            .descendant(
              of: _key('study-class-overview-chem'),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await _tap(tester, 'study-class-material-test-paper-chem');
      await tester.pumpAndSettle();
      expect(f.desk.activeTestPaperId, 'paper-chem');
    });
  }
}
