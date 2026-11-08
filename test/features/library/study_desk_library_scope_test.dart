import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/ai/backend_ai_client.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/text/note_text.dart';
import 'package:greatnote/features/library/library_screen.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/study_desk/study_desk_controller.dart';
import 'package:greatnote/features/library/study_desk/study_desk_screen.dart';

import '../../helpers/ai_fakes.dart';
import '../../helpers/document_io_fakes.dart';
import '../../helpers/pump_app.dart';

void main() {
  test(
    'unattached chat retrieves notes across folders, excluding trash',
    () async {
      final repository = InMemoryNoteRepository();
      final sent = <String>[];
      final client = BackendAiClient(
        invoke: (_, body) async {
          // The client rewrites the system text it sends, so requests are told
          // apart by their task.
          final task = (body['routing'] as Map?)?['task'];
          final planning = task == 'study.plan';
          if (task != 'study.plan' && task != 'study.suggestions') {
            sent.add(body.toString());
          }
          return <String, dynamic>{
            // As the server does, so that a text or JSON reply is accepted.
            if (body['responseFormat'] != null)
              'responseFormat': body['responseFormat'],
            'usage': <String, dynamic>{'inputTokens': 1, 'outputTokens': 1},
            // Retrieval happens only when the planner asks for it.
            'answer': planning
                ? '{"intent":"question","retrieval":{"notes":true,'
                      '"mistakeIndices":[],"query":"momentum lab results",'
                      '"depth":"full"}}'
                : 'Momentum is conserved.',
          };
        },
      );
      final desk = StudyDeskController(repository: repository, client: client);
      addTearDown(() {
        desk.dispose();
        client.close();
        repository.dispose();
      });
      final folder = await repository.createFolder('Physics');
      final first = await repository.createNote(
        title: 'Mechanics',
        folderId: folder.id,
      );
      final second = await repository.createNote(title: 'Experiments');
      final trashed = await repository.createNote(title: 'Deleted draft');
      for (final entry in [
        (first, 'Momentum lab result alpha: 12 kilogram meters per second.'),
        (second, 'Momentum lab result beta: 18 kilogram meters per second.'),
        (trashed, 'Momentum secret deleted result gamma.'),
      ]) {
        await repository.saveNote(
          entry.$1.id,
          NoteContent([
            StoredPage(
              setup: const PageSetup(),
              strokes: const [],
              textElements: [
                NoteTextElement(
                  id: 'text',
                  position: const InkVector(40, 40),
                  text: entry.$2,
                ),
              ],
            ),
          ]),
        );
      }
      await repository.deleteNote(trashed.id);
      await desk.load();
      await desk.send('Compare the momentum lab results');
      expect(desk.sources, isEmpty);
      expect(sent.last, contains('result alpha'));
      expect(sent.last, contains('result beta'));
      expect(sent.last, isNot(contains('deleted result gamma')));
      desk.newChat(noteIds: [first.id]);
      await desk.send('Compare the momentum lab results');
      expect(sent.last, contains('result alpha'));
      expect(sent.last, isNot(contains('result beta')));
      desk.setSourceEnabled(first.id, false);
      expect(desk.retrievalNoteIds, isEmpty);
      expect(desk.canSend, isFalse);
    },
  );

  for (final saveInFolder in [false, true]) {
    testWidgets(
      'test PDF saves to ${saveInFolder ? 'a nested folder' : 'library root'} without leaving desk',
      (tester) async {
        final repository = InMemoryNoteRepository();
        final client = FakeAiClient();
        addTearDown(() {
          repository.dispose();
          client.close();
        });
        final parent = await repository.createFolder('Physics');
        final child = await repository.createFolder(
          'Tests',
          parentId: parent.id,
        );
        setViewportSize(tester, const Size(1200, 900));
        await tester.pumpWidget(
          GreatnoteApp(
            home: LibraryScreen(
              repository: repository,
              aiClient: client,
              pdfRasterizer: FakePdfRasterizer(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('sidebar-study-desk')));
        await tester.pumpAndSettle();
        final screen = tester.widget<StudyDeskScreen>(
          find.byType(StudyDeskScreen),
        );
        final saving = screen.onSaveTestToLibrary!(
          Uint8List.fromList([37, 80, 68, 70]),
          'Momentum test',
        );
        await tester.pumpAndSettle();
        if (saveInFolder) expect(find.text('Physics / Tests'), findsOneWidget);
        await tester.tap(
          find.byKey(
            ValueKey(
              saveInFolder
                  ? 'study-save-folder-${child.id}'
                  : 'study-save-library-root',
            ),
          ),
        );
        await tester.pumpAndSettle();
        await saving;
        final notes = await repository.allNotes();
        expect(notes.single.title, 'Momentum test');
        expect(notes.single.folderId, saveInFolder ? child.id : null);
        final content = await repository.loadNote(notes.single.id);
        expect(content.pages.single.pdfSource, isNotNull);
        expect(find.byKey(const ValueKey('study-composer')), findsOneWidget);
        expect(find.text('Test added to your library.'), findsOneWidget);
        // Cancelling the destination chooser creates no second copy.
        final cancelled = screen.onSaveTestToLibrary!(
          Uint8List(0),
          'Cancelled',
        );
        await tester.pumpAndSettle();
        Navigator.of(tester.element(find.byType(SimpleDialog))).pop();
        await tester.pumpAndSettle();
        await cancelled;
        expect(await repository.allNotes(), hasLength(1));
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }
}
