import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/library/library_models.dart' show FolderColor;
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/study_desk/practice/study_practice_models.dart';
import 'package:greatnote/features/library/study_desk/practice/study_practice_store.dart';
import 'package:greatnote/features/library/study_desk/study_desk_controller.dart';
import 'package:greatnote/features/library/study_desk/study_desk_models.dart';
import 'package:greatnote/features/library/study_desk/study_desk_screen.dart';
import 'package:greatnote/features/library/study_desk/study_desk_store.dart';
import 'package:greatnote/features/library/study_desk/study_desk_widgets.dart';

import '../../../helpers/ai_fakes.dart';
import '../../../helpers/pump_app.dart';

Finder key(String value) => find.byKey(ValueKey(value));

void main() {
  for (final size in [const Size(390, 844), const Size(1200, 950)]) {
    testWidgets(
      'folder suggestions initialize a class and all descendants at $size',
      (tester) async {
        final repository = InMemoryNoteRepository();
        final root = await repository.createFolder(
          'Physics',
          color: FolderColor.teal,
        );
        final nested = await repository.createFolder(
          'Mechanics',
          parentId: root.id,
        );
        final direct = await repository.createNote(
          title: 'Overview',
          folderId: root.id,
        );
        final child = await repository.createNote(
          title: 'Momentum',
          folderId: nested.id,
        );
        await repository.createNote(title: 'Unrelated');
        final linked = await repository.createFolder('Chemistry');
        final store = InMemoryStudyDeskStore();
        final client = FakeAiClient();
        final desk = StudyDeskController(
          repository: repository,
          client: client,
          store: store,
        );
        addTearDown(() {
          desk.dispose();
          client.close();
          repository.dispose();
        });
        await desk.load();
        desk.addCourse('Existing chemistry', folderIds: [linked.id]);
        expect(desk.suggestedClassFolders.map((f) => f.id), [root.id]);
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
        expect(key('study-chat-add-source').hitTestable(), findsOneWidget);
        // On a phone the history, and the suggestions in it, start closed.
        if (key('study-navigation-sidebar').evaluate().isEmpty) {
          await tester.tap(key('study-toggle-history'));
          await tester.pumpAndSettle();
        }
        final suggestion = key('study-suggest-class-${root.id}').last;
        await tester.ensureVisible(suggestion);
        await tester.pumpAndSettle();
        await tester.tap(suggestion);
        await tester.pumpAndSettle();
        expect(desk.page, StudyDeskPage.course);
        expect(desk.selectedCourse!.name, 'Physics');
        expect(desk.selectedCourse!.colorHex, FolderColor.teal.colorHex);
        expect(desk.selectedCourse!.associatedFolderIds, [root.id]);
        expect(
          desk.sources.map((s) => s.noteId),
          unorderedEquals([direct.id, child.id]),
        );
        expect(key('study-suggest-class-${root.id}'), findsNothing);
        desk.initializeSuggestedClass(root);
        expect(desk.courses, hasLength(2));
        expect((await store.read())!.courses.last.associatedFolderIds, [
          root.id,
        ]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  test('a suggested class is hidden when a class already has its name, '
      'and when it is closed', () async {
    final repository = InMemoryNoteRepository();
    final physics = await repository.createFolder('Physics');
    final art = await repository.createFolder('Art');
    final store = InMemoryStudyDeskStore();
    final client = FakeAiClient();
    final desk = StudyDeskController(
      repository: repository,
      client: client,
      store: store,
    );
    addTearDown(() {
      desk.dispose();
      client.close();
      repository.dispose();
    });
    await desk.load();
    expect(desk.suggestedClassFolders.map((f) => f.id), [art.id, physics.id]);
    // The same name, in another case and with space around it.
    desk.addCourse('  physics ');
    expect(desk.suggestedClassFolders.map((f) => f.id), [art.id]);
    desk.dismissSuggestedClass(art);
    expect(desk.suggestedClassFolders, isEmpty);
    expect((await store.read())!.dismissedSuggestions, [art.id]);
  });

  test('a class can be renamed, pinned and deleted', () async {
    final repository = InMemoryNoteRepository();
    final client = FakeAiClient();
    final desk = StudyDeskController(
      repository: repository,
      client: client,
      store: InMemoryStudyDeskStore(),
    );
    addTearDown(() {
      desk.dispose();
      client.close();
      repository.dispose();
    });
    await desk.load();
    final math = desk.addCourse('Math');
    final art = desk.addCourse('Art');
    desk.renameCourse(math.id, 'Maths');
    expect(desk.courses.first.name, 'Maths');
    desk.recolorCourse(math.id, '#2F9E44');
    expect(desk.courses.first.colorHex, '#2F9E44');
    // Neither a blank name nor another class's name is taken.
    desk.renameCourse(math.id, ' ');
    desk.renameCourse(math.id, 'art');
    expect(desk.courses.first.name, 'Maths');
    desk.setCoursePinned(art.id, true);
    expect(desk.courses.last.isPinned, isTrue);
    desk.newChat(courseId: art.id);
    await desk.deleteCourse(art.id);
    expect(desk.courses.map((c) => c.id), [math.id]);
    expect(desk.currentSession.courseId, isNull);
  });

  testWidgets(
    'recent work includes all material types and searches them together',
    (tester) async {
      final repository = InMemoryNoteRepository();
      final client = FakeAiClient();
      final practice = InMemoryStudyPracticeStore();
      final now = DateTime(2026, 11, 6);
      await practice.savePaper(
        StudyTestPaper(
          id: 'test',
          title: 'Algebra test',
          courseName: 'Math',
          instructions: '',
          createdAt: now,
          updatedAt: now,
          questions: const [],
        ),
      );
      await practice.saveSet(
        StudyPracticeSet(
          id: 'deck',
          title: 'Algebra flashcards',
          createdAt: now,
          updatedAt: now.add(const Duration(minutes: 1)),
          flashcards: const [
            PracticeFlashcard(
              id: 'card',
              frontPrompt: '2 + 2?',
              backAnswer: '4',
            ),
          ],
        ),
      );
      final store = InMemoryStudyDeskStore();
      await store.write(
        StudyDeskState(
          sessions: [
            StudySession(
              id: 'chat',
              title: 'Geometry chat',
              created: now,
              messages: const [StudyMessage.user('Explain angles')],
            ),
          ],
          currentSessionId: 'chat',
        ),
      );
      final desk = StudyDeskController(
        repository: repository,
        client: client,
        store: store,
        practiceStore: practice,
      );
      addTearDown(() {
        desk.dispose();
        client.close();
        repository.dispose();
      });
      await desk.load();
      await pumpApp(
        tester,
        size: const Size(1200, 950),
        home: Scaffold(
          body: StudyDeskScreen(
            controller: desk,
            thumbnail: (_) => const SizedBox(),
            onEditCitation: (_) {},
            onAddSources: () {},
          ),
        ),
      );
      expect(key('study-session-chat'), findsOneWidget);
      expect(key('study-recent-test-test'), findsOneWidget);
      expect(key('study-recent-deck-deck'), findsOneWidget);
      expect(
        tester.getTopLeft(key('study-recent-deck-deck')).dy,
        lessThan(tester.getTopLeft(key('study-recent-test-test')).dy),
      );
      await tester.tap(key('study-search-history'));
      await tester.pumpAndSettle();
      await tester.enterText(key('study-sidebar-search'), 'Algebra');
      await tester.pumpAndSettle();
      expect(key('study-session-chat'), findsNothing);
      expect(key('study-recent-test-test'), findsOneWidget);
      expect(key('study-recent-deck-deck'), findsOneWidget);
      await tester.tap(key('study-recent-deck-deck'));
      await tester.pumpAndSettle();
      expect(desk.activeFlashcardSetId, 'deck');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'graded paper divider resizes, clamps, resets, and supports keyboard input',
    (tester) async {
      await pumpApp(
        tester,
        size: const Size(1200, 900),
        home: const Scaffold(
          body: StudyResizableSplit(
            leading: SizedBox(key: ValueKey('left')),
            trailing: SizedBox(key: ValueKey('right')),
          ),
        ),
      );
      final divider = key('study-graded-paper-resize');
      final initial = tester.getSize(key('right')).width;
      await tester.drag(divider, const Offset(-180, 0));
      await tester.pumpAndSettle();
      expect(tester.getSize(key('right')).width, greaterThan(initial + 100));
      await tester.drag(divider, const Offset(-1500, 0));
      await tester.pumpAndSettle();
      expect(tester.getSize(key('left')).width, greaterThanOrEqualTo(320));
      await tester.tap(divider);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(divider);
      await tester.pumpAndSettle();
      expect(tester.getSize(key('right')).width, closeTo(initial, 1));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(tester.getSize(key('right')).width, greaterThan(initial));
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(tester.getSize(key('right')).width, closeTo(initial, 1));
      expect(tester.takeException(), isNull);
    },
  );

  for (final fromChat in [false, true]) {
    testWidgets(
      'recent tests keep their review chat inside the test, fromChat=$fromChat',
      (tester) async {
        final repository = InMemoryNoteRepository();
        final client = FakeAiClient();
        final store = InMemoryStudyDeskStore();
        final practice = InMemoryStudyPracticeStore();
        final now = DateTime(2026, 11, 6);
        await store.write(
          StudyDeskState(
            currentSessionId: 'original',
            sessions: [
              StudySession(
                id: 'original',
                title: 'Original algebra discussion',
                created: now,
                messages: const [StudyMessage.user('Explain equations')],
              ),
            ],
          ),
        );
        final paper = StudyTestPaper(
          id: 'combined',
          title: 'Algebra test',
          courseName: 'Math',
          instructions: '',
          createdAt: now,
          updatedAt: now,
          sourceSessionId: fromChat ? 'original' : null,
          questions: const [],
          isSubmitted: true,
          totalScore: 0,
        );
        await practice.savePaper(paper);
        final desk = StudyDeskController(
          repository: repository,
          client: client,
          store: store,
          practiceStore: practice,
        );
        addTearDown(() {
          desk.dispose();
          client.close();
          repository.dispose();
        });
        await desk.load();
        await pumpApp(
          tester,
          size: const Size(1400, 1000),
          home: Scaffold(
            body: StudyDeskScreen(
              controller: desk,
              thumbnail: (_) => const SizedBox(),
              onEditCitation: (_) {},
              onAddSources: () {},
            ),
          ),
        );
        await tester.tap(key('study-recent-test-combined'));
        await tester.pumpAndSettle();
        final review = desk.sessionId;
        desk.updateSession(
          review,
          title: 'Algebra review conversation',
          isPinned: true,
        );
        await tester.pumpAndSettle();
        await tester.tap(key('study-toggle-history'));
        await tester.pumpAndSettle();
        expect(key('study-recent-test-combined'), findsOneWidget);
        expect(key('study-session-$review'), findsNothing);
        expect(key('study-session-original'), findsOneWidget);
        expect(desk.allSessions.any((s) => s.id == review), isTrue);
        desk.newChat();
        await tester.pumpAndSettle();
        await tester.tap(key('study-recent-test-combined'));
        await tester.pumpAndSettle();
        expect(desk.sessionId, review);
        expect(desk.currentSession.testPaperId, paper.id);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
