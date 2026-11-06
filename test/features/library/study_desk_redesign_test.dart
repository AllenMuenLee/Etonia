import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/ai/ai_citation.dart';
import 'package:greatnote/features/editor/ai/backend_ai_client.dart';
import 'package:greatnote/features/editor/widgets/rich_answer_markdown.dart';
import 'package:greatnote/features/editor/widgets/ai_citation_highlight.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/study_desk/study_desk_controller.dart';
import 'package:greatnote/features/library/study_desk/study_desk_models.dart';
import 'package:greatnote/features/library/study_desk/study_desk_screen.dart';
import 'package:greatnote/features/library/study_desk/study_desk_store.dart';
import 'package:greatnote/features/library/study_desk/study_history_sidebar.dart';
import 'package:greatnote/features/library/study_desk/study_citation_preview.dart';
import 'package:greatnote/features/library/study_desk/study_diagram_card.dart';
import 'package:greatnote/features/library/study_desk/study_rag_index.dart';

import '../../helpers/ai_fakes.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/document_io_fakes.dart';

final now = DateTime(2026, 11, 4, 12);

Future<
  ({
    StudyDeskController desk,
    InMemoryNoteRepository repository,
    FakeAiClient client,
    InMemoryStudyDeskStore store,
  })
>
fixture({
  List<StudyMessage> messages = const [],
  StudyChunkRenderer? renderer,
}) async {
  final repository = InMemoryNoteRepository(clock: () => now);
  final note = await repository.createNote(title: 'Mechanics');
  final store = InMemoryStudyDeskStore();
  await store.write(
    StudyDeskState(
      sources: [StudySourceItem(noteId: note.id)],
      sessions: [StudySession(id: 'initial', created: now, messages: messages)],
      currentSessionId: 'initial',
    ),
  );
  final client = FakeAiClient();
  final desk = StudyDeskController(
    repository: repository,
    client: client,
    store: store,
    clock: () => now,
    renderer: renderer,
  );
  await desk.load();
  addTearDown(() {
    desk.dispose();
    repository.dispose();
    client.close();
  });
  return (desk: desk, repository: repository, client: client, store: store);
}

Future<void> mountDesk(WidgetTester tester, StudyDeskController desk) async {
  desk.setMode(StudyDeskMode.chat);
  setViewportSize(tester, const Size(1200, 850));
  await tester.pumpWidget(
    GreatnoteApp(
      home: Scaffold(
        body: StudyDeskScreen(
          controller: desk,
          thumbnail: (_) => const SizedBox(),
          onEditCitation: (_) {},
          onAddSources: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('saved whole-page circles are hidden while the page is shown', (
    tester,
  ) async {
    final f = await fixture();
    final citation = StudyCitation(
      noteId: f.desk.sources.single.noteId,
      pageIndex: 0,
      revision: 0,
      bounds: const Rect.fromLTWH(0, 0, 794, 1123),
      rings: const [Rect.fromLTWH(0, 0, 794, 1123)],
    );
    await tester.pumpWidget(
      GreatnoteApp(
        home: Scaffold(
          body: StudyCitationPreview(
            controller: f.desk,
            citation: citation,
            onEdit: (_) {},
            onClose: () {},
            enableNativeInk: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('study-cited-page')),
      findsOneWidget,
    );
    expect(
      tester.widget<AiCitationMarks>(find.byType(AiCitationMarks)).circles,
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  test('suggestions work through the production response envelope', () async {
    final repository = InMemoryNoteRepository();
    final note = await repository.createNote(title: 'Physics');
    var requests = 0;
    final client = BackendAiClient(
      invoke: (_, body) async {
        requests++;
        final suggestions = (body['systemInstruction']! as String).contains(
          'JSON array of exactly three',
        );
        final planning = (body['systemInstruction']! as String).contains(
          'You plan tutoring lessons',
        );
        return <String, dynamic>{
          'answer':
              '<svg xmlns="http://www.w3.org/2000/svg" data-etonia-version="1">'
              '<title>Study</title><desc data-etonia-role="message">'
              '${planning
                  ? '{"intent":"question"}'
                  : suggestions
                  ? '["Explain torque", "Show an example", "What is inertia?"]'
                  : 'Momentum is conserved.'}'
              '</desc></svg>',
          'usage': {'inputTokens': 100, 'outputTokens': 40},
        };
      },
    );
    final desk = StudyDeskController(repository: repository, client: client);
    addTearDown(() {
      desk.dispose();
      repository.dispose();
      client.close();
    });
    await desk.load();
    desk.addNotes([note.id]);
    await desk.send('Explain momentum');
    for (var i = 0; i < 10 && desk.generatingSuggestions.value; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(requests, 3);
    expect(desk.dynamicSuggestions.value, [
      'Explain torque',
      'Show an example',
      'What is inertia?',
    ]);
  });

  test('merged page citations keep each diagram crop separate from prose', () {
    const prose = StudyCitation(
      noteId: 'n',
      pageIndex: 0,
      revision: 1,
      kind: StudyChunkKind.text,
      bounds: Rect.fromLTWH(0, 0, 200, 100),
    );
    const diagram = StudyCitation(
      noteId: 'n',
      pageIndex: 0,
      revision: 1,
      kind: StudyChunkKind.diagram,
      bounds: Rect.fromLTWH(100, 300, 200, 100),
    );
    const another = StudyCitation(
      noteId: 'n',
      pageIndex: 0,
      revision: 1,
      kind: StudyChunkKind.mixed,
      bounds: Rect.fromLTWH(100, 600, 200, 100),
    );
    final merged = prose.merged(diagram).merged(another);
    final restored = StudyCitation.fromJson(merged.toJson());
    expect(restored.diagramCitations.map((c) => c.bounds), [
      diagram.bounds,
      another.bounds,
    ]);
    expect(restored.diagramCitations.first.rings, [diagram.bounds]);
  });

  testWidgets(
    'diagram cards load the exact crop once across transcript rebuilds',
    (tester) async {
      final renderer = _CropRenderer();
      final f = await fixture(renderer: renderer);
      final citation = StudyCitation(
        noteId: f.desk.sources.single.noteId,
        pageIndex: 0,
        revision: 0,
        kind: StudyChunkKind.diagram,
        bounds: const Rect.fromLTWH(20, 30, 200, 100),
      );
      var opened = false;
      Widget card() => GreatnoteApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: StudyDiagramCard(
                controller: f.desk,
                citation: citation.diagramCitations.single,
                onPressed: () => opened = true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(card());
      await tester.pumpAndSettle();
      expect(renderer.chunks.single.logicalBounds, citation.bounds);
      await tester.pumpWidget(card());
      await tester.pumpAndSettle();
      expect(renderer.chunks, hasLength(1));
      await tester.tap(find.byType(StudyDiagramCard));
      expect(opened, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  group('Course and history persistence', () {
    test('schema 1 migrates with derived titles and timestamps', () {
      final state = StudyDeskState.fromJson({
        'schema': 1,
        'sessions': [
          {
            'id': 'old',
            'created': now.millisecondsSinceEpoch,
            'messages': [
              {'user': true, 'text': 'Explain angular momentum'},
              {'text': 'It is conserved.'},
            ],
          },
        ],
      });
      final session = state.sessions.single;
      expect(state.courses, isEmpty);
      expect(session.title, 'Explain angular momentum');
      expect(session.updatedAt, session.createdAt);
      expect(session.isPinned, isFalse);
      expect(session.courseId, isNull);
    });

    test(
      'courses, explicit titles, pins, sources and diagram geometry round trip',
      () {
        final course = StudyCourse(
          id: 'physics',
          name: 'AP Physics',
          colorHex: '#006C67',
          createdAt: now,
          associatedFolderIds: ['folder'],
          associatedNoteIds: ['note'],
        );
        const citation = StudyCitation(
          noteId: 'note',
          pageIndex: 0,
          revision: 3,
          kind: StudyChunkKind.diagram,
          bounds: Rect.fromLTWH(10, 20, 100, 80),
        );
        final session = StudySession(
          id: 'chat',
          created: now.subtract(const Duration(days: 2)),
          updatedAt: now,
          title: 'Torque',
          courseId: course.id,
          isPinned: true,
          sources: const [StudySourceItem(noteId: 'note', enabled: false)],
          messages: [
            const StudyMessage.answer(
              'Diagram',
              links: [
                StudyParagraphLinks(paragraph: 1, citations: [citation]),
              ],
            ),
          ],
        );
        final original = StudyDeskState(
          courses: [course],
          sessions: [session],
          currentSessionId: session.id,
        );
        final state = StudyDeskState.fromJson(
          jsonDecode(jsonEncode(original.toJson())) as Map<String, Object?>,
        );
        expect(state.toJson(), original.toJson());
        expect(state.sessions.single.title, 'Torque');
        expect(session.copyWith(courseId: null).courseId, isNull);
        expect(session.copyWith(title: 'Rotation').courseId, 'physics');
      },
    );

    test(
      'course and query filtering preserve pins and chronological groups',
      () {
        final sessions = [
          StudySession(
            id: 'pinned',
            created: now.subtract(const Duration(days: 90)),
            isPinned: true,
            courseId: 'physics',
            title: 'Torque',
            messages: const [StudyMessage.user('Angular momentum')],
          ),
          StudySession(
            id: 'today',
            created: now,
            courseId: 'physics',
            title: 'Energy',
          ),
          StudySession(
            id: 'week',
            created: now.subtract(const Duration(days: 6)),
            courseId: 'physics',
          ),
          StudySession(
            id: 'older',
            created: now.subtract(const Duration(days: 8)),
            courseId: 'physics',
          ),
          StudySession(
            id: 'other',
            created: now,
            courseId: 'calculus',
            title: 'Energy',
          ),
        ];
        final groups = studyHistoryGroups(
          sessions,
          now: now,
          courseId: 'physics',
        );
        expect(groups.map((k, v) => MapEntry(k, v.map((s) => s.id).toList())), {
          'Pinned': ['pinned'],
          'Today': ['today'],
          'Previous 7 Days': ['week'],
          'Older Sessions': ['older'],
        });
        expect(
          studyHistoryGroups(
            sessions,
            now: now,
            query: 'angular',
          )['Pinned']!.single.id,
          'pinned',
        );
        expect(
          studyHistoryGroups(sessions, now: now, query: '2026-11-04')['Today'],
          hasLength(2),
        );
      },
    );

    test(
      'session switching restores sources and management survives reload',
      () async {
        final f = await fixture(
          messages: const [
            StudyMessage.user('Momentum'),
            StudyMessage.answer('Conserved'),
          ],
        );
        final firstNote = f.desk.sources.single.noteId;
        final second = await f.repository.createNote(title: 'Calculus');
        // Repository listeners update the available note index asynchronously.
        await Future<void>.delayed(Duration.zero);
        final course = f.desk.addCourse('Physics', noteIds: [firstNote]);
        f.desk.updateSession(
          'initial',
          title: 'Rotation',
          courseId: course.id,
          assignCourse: true,
          isPinned: true,
        );
        f.desk.newChat(noteIds: [second.id]);
        expect(f.desk.sources.single.noteId, second.id);
        f.desk.openSession('initial');
        expect(f.desk.sources.single.noteId, firstNote);
        expect(f.desk.currentSession.title, 'Rotation');
        expect(f.desk.currentSession.isPinned, isTrue);
        expect(
          f.desk.exportTranscript(f.desk.currentSession),
          contains('## You\n\nMomentum'),
        );
        final kept = (await f.store.read())!;
        expect(kept.courses.single.id, course.id);
        expect(
          kept.sessions
              .singleWhere((s) => s.id == 'initial')
              .sources!
              .single
              .noteId,
          firstNote,
        );
        f.desk.updateSession('initial', assignCourse: true);
        expect(f.desk.currentSession.courseId, isNull);
        f.desk.deleteSession('initial');
        expect(f.desk.messages, isEmpty);
        expect(f.desk.allSessions, isEmpty);
      },
    );

    test('history retains more than twenty conversations', () async {
      final f = await fixture();
      final sessions = [
        for (var i = 0; i < 30; i++)
          StudySession(
            id: '$i',
            created: now,
            messages: const [StudyMessage.user('Study')],
          ),
      ];
      await f.store.write(
        StudyDeskState(sessions: sessions, currentSessionId: '29'),
      );
      final reloaded = StudyDeskController(
        repository: f.repository,
        client: f.client,
        store: f.store,
      );
      addTearDown(reloaded.dispose);
      await reloaded.load();
      reloaded.newChat();
      expect(reloaded.allSessions, hasLength(30));
      expect((await f.store.read())!.sessions, hasLength(31));
    });
  });

  test('focus changes never broadcast a transcript update', () async {
    final f = await fixture();
    var broadcasts = 0;
    f.desk.addListener(() => broadcasts++);
    final citation = StudyCitation(
      noteId: f.desk.sources.single.noteId,
      pageIndex: 0,
      revision: 0,
    );
    f.desk.focusCitation(citation, message: 1, paragraph: 1);
    f.desk.focusCitation(citation, message: 1, paragraph: 2);
    expect(f.desk.focusedParagraphNotifier.value, (1, 2));
    expect(f.desk.citationFocusNotifier.value!.paragraph, 2);
    expect(f.desk.citationPaneOpen.value, isTrue);
    f.desk.closePane();
    expect(f.desk.citationPaneOpen.value, isFalse);
    expect(broadcasts, 0);
  });

  test(
    'background suggestions validate JSON and ignore stale session results',
    () async {
      final f = await fixture();
      Future<void> completeTurn() async {
        final pending = f.desk.send('Explain momentum');
        while (f.client.requests.isEmpty) {
          await Future<void>.delayed(Duration.zero);
        }
        f.client.answer('Momentum is conserved.', index: 0);
        await pending;
      }

      await completeTurn();
      expect(f.client.requests, hasLength(2));
      expect(
        f.client.requests[1].systemInstruction,
        contains('data-etonia-role="message"'),
      );
      expect(
        f.client.requests[1].systemInstruction,
        contains('JSON array of exactly three'),
      );
      final context =
          jsonDecode(f.client.requests[1].messages.single.text) as Map;
      expect(context['question'], 'Explain momentum');
      f.client.answer(
        '["What about torque?", "Show an example", "Explain angular momentum"]',
        index: 1,
      );
      await Future<void>.delayed(Duration.zero);
      expect(f.desk.dynamicSuggestions.value, hasLength(3));
      final refresh = f.desk.refreshSuggestions();
      f.client.answer('["duplicate", "duplicate", "third"]', index: 2);
      await refresh;
      expect(f.desk.dynamicSuggestions.value.first, 'What about torque?');
      final stale = f.desk.refreshSuggestions();
      f.desk.newChat();
      f.client.answer('["Old A", "Old B", "Old C"]', index: 3);
      await stale;
      expect(f.desk.dynamicSuggestions.value, isEmpty);
      expect(f.desk.generatingSuggestions.value, isFalse);
    },
  );

  testWidgets(
    'scrolling and focus changes preserve transcript widgets and wait for idle',
    (tester) async {
      final f = await fixture();
      final citation = StudyCitation(
        noteId: f.desk.sources.single.noteId,
        pageIndex: 0,
        revision: 0,
      );
      final message = StudyMessage.answer(
        [
          for (var i = 1; i <= 18; i++)
            'Paragraph $i explains momentum and torque. ' * 8,
        ].join('\n\n'),
        links: [
          for (var i = 1; i <= 18; i++)
            StudyParagraphLinks(paragraph: i, citations: [citation]),
        ],
      );
      await f.store.write(
        StudyDeskState(
          sources: f.desk.sources,
          sessions: [
            StudySession(id: 'long', created: now, messages: [message]),
          ],
          currentSessionId: 'long',
        ),
      );
      final desk = StudyDeskController(
        repository: f.repository,
        client: f.client,
        store: f.store,
      );
      addTearDown(desk.dispose);
      await desk.load();
      await mountDesk(tester, desk);
      final before = tester
          .widgetList<AiAnswerMarkdown>(find.byType(AiAnswerMarkdown))
          .toList();
      desk.focusCitation(citation, message: 0, paragraph: 17, open: false);
      await tester.pumpAndSettle();
      final after = tester
          .widgetList<AiAnswerMarkdown>(find.byType(AiAnswerMarkdown))
          .toList();
      expect(after.length, before.length);
      expect(
        List.generate(before.length, (i) => identical(before[i], after[i])),
        everyElement(isTrue),
      );
      var events = 0;
      desk.addListener(() => events++);
      final transcript = find
          .descendant(
            of: find.byType(StudyDeskScreen),
            matching: find.byType(ListView),
          )
          .last;
      final gesture = await tester.startGesture(tester.getCenter(transcript));
      await gesture.moveBy(const Offset(0, 240));
      await tester.pump(const Duration(milliseconds: 200));
      expect(desk.focusedParagraphNotifier.value, (0, 17));
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 160));
      expect(events, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'same-page citation changes preserve the viewer and animate its matrix',
    (tester) async {
      final f = await fixture();
      final first = StudyCitation(
        noteId: f.desk.sources.single.noteId,
        pageIndex: 0,
        revision: 0,
        rings: const [Rect.fromLTWH(40, 60, 200, 100)],
      );
      final second = StudyCitation(
        noteId: first.noteId,
        pageIndex: 0,
        revision: 0,
        rings: const [Rect.fromLTWH(300, 650, 200, 100)],
      );
      Widget preview(StudyCitation citation) => GreatnoteApp(
        home: Scaffold(
          body: StudyCitationPreview(
            controller: f.desk,
            citation: citation,
            onEdit: (_) {},
            onClose: () {},
            enableNativeInk: false,
          ),
        ),
      );
      await tester.pumpWidget(preview(first));
      await tester.pumpAndSettle();
      final viewer = tester.state(find.byType(InteractiveViewer));
      final transform = tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!;
      final start = transform.value.clone();
      await tester.pumpWidget(preview(second));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final middle = transform.value.clone();
      expect(middle, isNot(start));
      await tester.pumpAndSettle();
      expect(transform.value, isNot(middle));
      expect(
        identical(viewer, tester.state(find.byType(InteractiveViewer))),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'the history sidebar creates classes, renames and pins conversations',
    (tester) async {
      final f = await fixture(
        messages: const [
          StudyMessage.user('Explain torque'),
          StudyMessage.answer('Torque changes momentum'),
        ],
      );
      final sink = FakeExportSink();
      await tester.pumpWidget(
        GreatnoteApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: StudyHistorySidebar(
                controller: f.desk,
                onClose: () {},
                onAddSources: () {},
                exportSink: sink,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Rotational inertia');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(f.desk.currentSession.title, 'Rotational inertia');
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin'));
      await tester.pumpAndSettle();
      expect(f.desk.currentSession.isPinned, isTrue);
      await tester.tap(find.byTooltip('Add Class'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'AP Physics');
      await tester.pump();
      await tester.tap(find.text('Add').last);
      await tester.pumpAndSettle();
      expect(f.desk.courses.single.name, 'AP Physics');
      expect(find.text('Recent'), findsOneWidget);
      expect(find.text('Rotational inertia'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'suggestions follow the last answer and scroll away with history',
    (tester) async {
      final f = await fixture(
        messages: [StudyMessage.answer('Momentum and torque. ' * 550)],
      );
      await mountDesk(tester, f.desk);
      f.desk.dynamicSuggestions.value = [
        'What is torque?',
        'Show an example',
        'What is conserved?',
      ];
      await tester.pumpAndSettle();
      final list = tester.widgetList<ListView>(find.byType(ListView)).last;
      list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('Explore next').hitTestable(), findsOneWidget);
      list.controller!.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text('Explore next').hitTestable(), findsNothing);
      list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
      await tester.pumpAndSettle();
      await tester.tap(find.text('What is torque?'));
      await tester.pump();
      expect(f.desk.messages.last.text, 'What is torque?');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  group('Rich answer rendering', () {
    const svg =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 60">\n\n<circle cx="50" cy="30" r="20" fill="blue"/></svg>';
    test('raw and fenced SVG stay whole and code remains literal', () {
      expect(parseAiAnswer('Before\n\n$svg\n\nAfter'), hasLength(3));
      expect(
        richAnswerBlocks(
          'Before\n\n```svg\n$svg\n```\nAfter',
        ).map((b) => b.kind),
        ['markdown', 'svg', 'markdown'],
      );
      expect(
        richAnswerBlocks('```python\nprint("<svg></svg>")\n```').single.kind,
        'markdown',
      );
      expect(
        richAnswerBlocks('Use the `<svg></svg>` element.').single.kind,
        'markdown',
      );
      expect(
        richAnswerBlocks('> [!THEOREM]\n> Energy is conserved.').single.kind,
        'theorem',
      );
      expect(safeChatSvg(svg), isNotNull);
      expect(
        safeChatSvg('<svg><image href="https://example.com/a.png"/></svg>'),
        isNull,
      );
      expect(safeChatSvg('<svg><script>alert(1)</script></svg>'), isNull);
      expect(safeChatSvg('<svg>'), isNull);
    });

    testWidgets(
      'diagrams, callouts, code copy and wide math work in both themes',
      (tester) async {
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        const source =
            '```svg\n$svg\n```\n\n> [!FORMULA]\n> '
            r'$E=mc^2$'
            '\n\n```python\nprint(1)\nprint(2)\n```\n\n'
            r'$$\int_0^\infty e^{-x^2} dx = \frac{\sqrt{\pi}}{2} + a + b + c + d + e + f + g + h + i + j + k + l$$';
        for (final theme in [ThemeMode.light, ThemeMode.dark]) {
          await tester.pumpWidget(
            GreatnoteApp(
              themeMode: theme,
              home: const Scaffold(
                body: SingleChildScrollView(
                  child: Center(
                    child: SizedBox(
                      width: 300,
                      child: SelectionArea(child: AiAnswerMarkdown(source)),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(SvgPicture), findsOneWidget);
          expect(find.text('Formula'), findsOneWidget);
          expect(find.text('python'), findsOneWidget);
          await tester.ensureVisible(find.byTooltip('Copy code'));
          await tester.tap(find.byTooltip('Copy code'));
          await tester.pumpAndSettle();
          expect(copied, contains('print(1)\nprint(2)'));
          expect(find.byTooltip('Copied'), findsOneWidget);
          expect(
            tester
                .widgetList<GptMarkdown>(find.byType(GptMarkdown))
                .last
                .styleSheet!
                .latex!
                .scrollBlockHorizontally,
            isTrue,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        }
      },
    );
  });
}

class _CropRenderer implements StudyChunkRenderer {
  final chunks = <StudyChunk>[];
  @override
  Future<StudyCrop?> render(StudyChunk chunk) async {
    chunks.add(chunk);
    return StudyCrop(
      chunk: chunk,
      png: StudyContextAssembler.placeholderPng,
      logicalBounds: chunk.logicalBounds,
    );
  }

  @override
  Future<Uint8List> combine(List<StudyCrop> crops) async =>
      StudyContextAssembler.placeholderPng;
}
