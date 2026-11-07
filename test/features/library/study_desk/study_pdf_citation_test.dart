import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/document_io/document_models.dart';
import 'package:greatnote/features/editor/document_io/document_platform.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/study_desk/study_desk_controller.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart' as pdfrx;

import '../../../helpers/ai_fakes.dart';

/// A Hello World PDF run through everything the Study Desk does with a PDF:
/// pdfium reads it, the desk searches it and builds the request, and, with
/// real answers (see `CAPTURE_DIR` and `ANSWERS_DIR`), the citations a model
/// writes are resolved to the PDF's page.
///
/// With `CAPTURE_DIR` set, the request each scenario sends is written there as
/// JSON, for a script to put to real models. With `ANSWERS_DIR` set, the
/// answers that script wrote are played back through the desk.
const String question = 'What does the PDF say about Hello World?';

/// 'text': a PDF with a text layer. 'scan': a page with no text at all, as a
/// scan is.
Future<(StudyDeskController, FakeAiClient, NoteEntry)> _desk(
  String scenario,
) async {
  final pw.Document pdf = pw.Document();
  if (scenario == 'text') {
    pdf.addPage(
      pw.Page(
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: <pw.Widget>[
            pw.Text('Chapter 1 Hello World'),
            pw.Text(
              'The Hello World program is the first program a student '
              'writes. It prints the words Hello World to the screen and '
              'then stops.',
            ),
          ],
        ),
      ),
    );
  } else {
    pdf.addPage(
      pw.Page(
        build: (_) =>
            pw.Container(width: 300, height: 300, color: PdfColors.grey800),
      ),
    );
  }
  final bytes = await pdf.save();
  final InMemoryNoteRepository repository = InMemoryNoteRepository();
  final NoteEntry created = await repository.createNote(title: 'Intro.pdf');
  final String assetId = await repository.storeAsset(
    created.id,
    bytes,
    kind: NoteAssetKind.pdf,
    extension: 'pdf',
  );
  final NoteEntry note = await repository.saveNote(
    created.id,
    NoteContent(<StoredPage>[
      StoredPage(
        setup: const PageSetup(),
        strokes: const [],
        pdfSource: PdfPageSource(
          assetId: assetId,
          pageIndex: 0,
          pageSize: const Size(595, 842),
        ),
      ),
    ]),
  );
  final FakeAiClient client = FakeAiClient();
  final StudyDeskController desk = StudyDeskController(
    repository: repository,
    client: client,
    pdfRasterizer: const PdfrxRasterizer(),
  );
  addTearDown(() {
    desk.dispose();
    repository.dispose();
  });
  await desk.load();
  desk.addNotes(<String>[note.id]);
  return (desk, client, note);
}

Future<AiRequest> _ask(
  StudyDeskController desk,
  FakeAiClient client,
  String? answer,
) async {
  final Future<void> sent = desk.send(question);
  for (int i = 0; i < 200 && client.requests.isEmpty; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  expect(client.requests, isNotEmpty, reason: 'nothing was sent to the AI');
  final AiRequest request = client.requests.first;
  if (answer != null) {
    client.answer(answer);
  } else {
    client.answer('ok');
  }
  await sent;
  return request;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await pdfrx.pdfrxInitialize();
  });

  for (final String scenario in <String>['text', 'scan']) {
    test(
      '$scenario PDF: the excerpts reach the model, headed to be cited',
      () async {
        final (desk, client, note) = await _desk(scenario);
        final AiRequest request = await _ask(desk, client, null);
        final String message = request.messages.last.text;
        expect(
          message,
          contains('[Source N1:P1'),
          reason: 'The PDF page is not among the excerpts the model is given.',
        );
        expect(message, contains('Intro.pdf'));
        if (scenario == 'text') {
          expect(message, contains('Hello World'));
        }
        final String? dir = Platform.environment['CAPTURE_DIR'];
        if (dir != null) {
          File('$dir/$scenario.json').writeAsStringSync(
            jsonEncode(<String, Object?>{
              'system': request.systemInstruction,
              'message': message,
              'noteId': note.id,
            }),
          );
        }
      },
    );
  }

  final String? answers = Platform.environment['ANSWERS_DIR'];
  if (answers != null) {
    for (final FileSystemEntity file in Directory(answers).listSync()) {
      if (file is! File || !file.path.endsWith('.json')) continue;
      final Map<String, Object?> data =
          jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      final String scenario = data['scenario']! as String;
      final String who = data['model']! as String;
      test(
        '$scenario PDF, answered by $who: the citation resolves to the PDF',
        () async {
          final (desk, client, note) = await _desk(scenario);
          await _ask(desk, client, data['answer']! as String);
          final answer = desk.messages.last;
          final cited = <String>{
            for (final link in answer.links)
              for (final citation in link.citations) citation.noteId,
          };
          expect(
            cited,
            contains(note.id),
            reason: 'The answer\n${answer.text}\ncites nothing in the PDF.',
          );
        },
      );
    }
  }
}
