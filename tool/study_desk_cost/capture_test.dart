// Measurement harness: synthetic notes, production request construction, no API calls.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/backend_ai_client.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/text/note_text.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/study_desk/study_desk_controller.dart';
import 'package:greatnote/features/library/study_desk/study_desk_models.dart';
import 'package:greatnote/features/library/study_desk/study_desk_store.dart';
import 'package:greatnote/features/library/study_desk/study_teaching_plan.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'capture synthetic Study Desk requests without contacting providers',
    () async {
      final fixtures =
          jsonDecode(
                File(
                  Platform.environment['STUDY_CAPTURE_FIXTURES'] ??
                      'tool/study_desk_cost/fixtures.json',
                ).readAsStringSync(),
              )
              as List<Object?>;
      final captured = <Map<String, Object?>>[];
      for (final value in fixtures) {
        final fixture = value as Map<String, Object?>;
        final repository = InMemoryNoteRepository();
        final note = await repository.createNote(
          title: (fixture['title'] ?? fixture['id']) as String,
        );
        final attach = fixture['attachNotes'] != false;
        final store = InMemoryStudyDeskStore();
        final plan = StudyTeachingPlan.tryRead(fixture['plan']);
        final history = (fixture['history'] as List<Object?>? ?? const []).map((
          raw,
        ) {
          final message = raw! as Map<String, Object?>;
          return message['role'] == 'user'
              ? StudyMessage.user(message['text']! as String)
              : StudyMessage.answer(message['text']! as String);
        }).toList();
        final session = StudySession(
          id: 'synthetic-session',
          created: DateTime.utc(2026, 11, 6),
          teachingPlan: plan,
          messages: history,
          sources: [if (attach) StudySourceItem(noteId: note.id)],
        );
        await store.write(
          StudyDeskState(
            semanticSearch: false,
            sessions: [session],
            currentSessionId: session.id,
          ),
        );
        await repository.saveNote(
          note.id,
          NoteContent([
            StoredPage(
              setup: const PageSetup(),
              strokes: const [],
              textElements: [
                NoteTextElement(
                  id: 'synthetic-text',
                  position: const InkVector(30, 40),
                  text: fixture['text'] as String,
                ),
              ],
            ),
          ]),
        );
        if (!attach) await repository.deleteNote(note.id);
        final client = BackendAiClient(
          invoke: (_, body) async {
            final task = (body['routing'] as Map<String, Object?>)['task'];
            final answer = task == 'study.plan'
                ? jsonEncode({
                    'intent': 'question',
                    'difficulty': fixture['difficulty'] ?? 2,
                  })
                : task == 'study.suggestions'
                ? '{"questions":["An example?","Why?","What next?"]}'
                : 'Synthetic answer for request capture only.';
            captured.add({
              'fixture': fixture['id'],
              'task': task,
              if (fixture.containsKey('partition'))
                'partition': fixture['partition'],
              if (fixture.containsKey('kind')) 'kind': fixture['kind'],
              if (fixture.containsKey('difficulty'))
                'difficulty': fixture['difficulty'],
              if (fixture.containsKey('reference'))
                'reference': fixture['reference'],
              'routing': body['routing'],
              'responseFormat': body['responseFormat'],
              'studyPolicyVersion': body['studyPolicyVersion'],
              'turnId': body['turnId'],
              'systemInstruction': body['systemInstruction'],
              'prompt': body['prompt'],
              'history': body['history'] ?? [],
              'syntheticAnswer': answer,
            });
            return {
              'responseFormat': body['responseFormat'],
              'answer': body['responseFormat'] != null
                  ? answer
                  : '<svg xmlns="http://www.w3.org/2000/svg" data-etonia-version="1">'
                        '<title>Study</title><desc data-etonia-role="message">'
                        '${htmlEscape.convert(answer)}</desc></svg>',
              // Fake usage is intentionally excluded from the captured measurement.
              'usage': {'inputTokens': 0, 'outputTokens': 0},
            };
          },
        );
        final desk = StudyDeskController(
          repository: repository,
          client: client,
          store: store,
        );
        try {
          await desk.load();
          if (attach) desk.addNotes([note.id]);
          await desk.send(fixture['question'] as String);
          while (desk.generatingSuggestions.value) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          expect(
            captured.where((r) => r['fixture'] == fixture['id']).length,
            plan != null &&
                    const ['next', 'next step'].contains(fixture['question'])
                ? 2
                : 3,
          );
        } finally {
          desk.dispose();
          repository.dispose();
          client.close();
        }
      }
      final output = File(
        Platform.environment['STUDY_CAPTURE_OUTPUT'] ??
            'build/study_desk_cost_audit/captured_requests.json',
      );
      output.parent.createSync(recursive: true);
      output.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(captured),
      );
    },
  );
}
