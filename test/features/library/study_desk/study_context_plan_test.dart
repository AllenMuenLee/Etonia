import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/text/note_text.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/study_desk/study_context_plan.dart';
import 'package:greatnote/features/library/study_desk/study_desk_controller.dart';
import 'package:greatnote/features/library/study_desk/study_desk_models.dart';
import 'package:greatnote/features/library/study_desk/study_rag_index.dart';

import '../../../helpers/ai_fakes.dart';

final _now = DateTime(2026, 11, 5);

class _RoutedFakeAiClient extends FakeAiClient implements AiModelRouter {
  bool plannerAvailable = true;

  @override
  List<AiModelId> get models => plannerAvailable ? [AiModelId.luna] : [];

  @override
  AiModelId get defaultModel => AiModelId.luna;

  @override
  bool isModelConfigured(AiModelId model) => true;
}

NoteEntry _note({
  String id = 'book',
  String title = 'Biology',
  int pages = 1000,
}) => NoteEntry(
  id: id,
  title: title,
  folderId: null,
  created: _now,
  modified: _now,
  pageCount: pages,
);

StudySearchDocument _document(int page, String text, {String id = 'book'}) =>
    StudySearchDocument(
      noteTitle: 'Biology',
      chunk: StudyChunk(
        noteId: id,
        pageIndex: page,
        chunkIndex: 1,
        kind: StudyChunkKind.text,
        logicalBounds: const Rect.fromLTWH(50, 50, 500, 500),
        typed: text,
        lines: [StudyChunkLine(0, 0, text)],
      ),
    );

List<StudySearchDocument> _book() => [
  _document(0, 'Contents\nChapter 1 Cells .... 11\nChapter 2 Energy .... 501'),
  _document(10, 'Chapter 1: Cells\nCell structure'),
  _document(250, 'Cells have membranes.'),
  _document(500, 'Chapter 2: Energy\nPhotosynthesis introduction'),
  _document(700, 'Photosynthesis uses sunlight. CHAPTER_TWO_BODY'),
  _document(999, 'Energy review'),
];

StudyContextPlan _plan(
  String prompt, {
  List<StudySearchDocument>? documents,
  List<NoteEntry>? notes,
  List<StudyMessage> history = const [],
  StudyQueryMode mode = StudyQueryMode.search,
  StudyContextAssembler assembler = const StudyContextAssembler(),
}) => StudyContextPlan.forQuestion(
  prompt: prompt,
  documents: documents ?? _book(),
  notes: notes ?? [_note()],
  mode: mode,
  history: history,
  assembler: assembler,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('scope before retrieval', () {
    test(
      'chapter listing uses the catalogue without retrieving body samples',
      () {
        final plan = _plan('Extract all chapters');
        expect(plan.outlineOnly, isTrue);
        expect(plan.documents, isEmpty);
        expect(plan.catalogue, contains('Cells'));
        expect(plan.instructions, contains('List the detected chapter'));
      },
    );

    test(
      'chapter heading beyond four lines can use a title in another chunk',
      () {
        final note = _note(pages: 20);
        final chunks = StudyChunker.chunkNote(
          const StudyNoteData('book', [
            StudyPageData(
              pageIndex: 2,
              strokes: [],
              words: [],
              boxes: [
                StudyBoxData(
                  id: 'heading',
                  kind: StudyBoxKind.text,
                  bounds: Rect.fromLTWH(20, 20, 500, 100),
                  text: '1.1\n1.2\n1.3\n1.4\nCHAPTER 1',
                ),
                StudyBoxData(
                  id: 'title',
                  kind: StudyBoxKind.text,
                  bounds: Rect.fromLTWH(20, 500, 500, 100),
                  text: 'Cells',
                ),
              ],
            ),
            StudyPageData(
              pageIndex: 12,
              strokes: [],
              words: [],
              boxes: [
                StudyBoxData(
                  id: 'next',
                  kind: StudyBoxKind.text,
                  bounds: Rect.fromLTWH(20, 20, 500, 100),
                  text: 'Chapter 2\nEnergy',
                ),
              ],
            ),
          ]),
        );
        final plan = _plan(
          'Chapter 1',
          notes: [note],
          documents: [
            for (final chunk in chunks)
              StudySearchDocument(chunk: chunk, noteTitle: note.title),
          ],
        );
        expect(plan.unknownScope, isFalse);
        expect(plan.documents, hasLength(2));
        expect(plan.catalogue, contains('Cells'));
        expect(plan.catalogue, contains('3-12'));
      },
    );

    for (final prompt in [
      'Summarize the textbook',
      'Summarise this book',
      'Teach me the entire book',
      'Quiz me on these notes',
      'Find connections between these notes, and gaps in what they cover.',
      'Summarize Biology',
      'Walk me through this textbook',
    ]) {
      test('asks for a chapter for "$prompt"', () {
        final plan = _plan(prompt);
        expect(plan.outlineOnly, isTrue);
        expect(plan.documents, isEmpty);
        expect(plan.catalogue, contains('1000'));
        expect(plan.catalogue, contains('Cells'));
        expect(plan.catalogue, contains('Energy'));
        expect(plan.catalogue, isNot(contains('CHAPTER_TWO_BODY')));
        expect(plan.instructions, contains('ask which chapter to start with'));
      });
    }

    test('a short note can still be summarized directly', () {
      final plan = _plan(
        'Summarize the textbook',
        documents: [_document(0, 'A short explanation.')],
        notes: [_note(pages: 1)],
      );
      expect(plan.outlineOnly, isFalse);
      expect(plan.documents, hasLength(1));
    });

    test('large text triggers scoping even on a few pages', () {
      final plan = _plan(
        'Summarize this book',
        documents: [_document(0, 'Detailed material. ' * 2000)],
        notes: [_note(pages: 3)],
      );
      expect(plan.outlineOnly, isTrue);
    });

    test('focused questions still search a large book', () {
      final plan = _plan('Explain how photosynthesis uses sunlight');
      expect(plan.outlineOnly, isFalse);
      final hits = StudyRetriever.retrieve(plan.documents, 'photosynthesis');
      expect(hits.any((hit) => hit.chunk.pageIndex == 700), isTrue);
      expect(
        plan.instructions,
        contains('Answer focused topic questions directly'),
      );
    });

    test('semantic scope assessment also reaches the answer model', () {
      final plan = _plan('Prepare a detailed learning journey for me');
      expect(plan.catalogue, contains('1000'));
      expect(
        plan.instructions,
        contains('Assess the user intent using the conversation'),
      );
    });

    test('starter overview scopes large sources', () {
      expect(
        _plan('Review', mode: StudyQueryMode.overview).outlineOnly,
        isTrue,
      );
    });

    for (final choice in ['Chapter 2', 'Start with 2', '2', 'Energy']) {
      test('chapter choice "$choice" limits body retrieval', () {
        final plan = _plan(
          choice,
          history: const [
            StudyMessage.user('Summarize the textbook'),
            StudyMessage.answer('Which chapter should we start with?'),
          ],
        );
        expect(plan.outlineOnly, isFalse);
        expect(plan.documents.map((d) => d.chunk.pageIndex), [500, 700, 999]);
      });
    }

    test('a chapter summary uses overview retrieval within its boundaries', () {
      final plan = _plan('Summarize chapter 1');
      expect(plan.mode, StudyQueryMode.overview);
      expect(plan.documents.map((d) => d.chunk.pageIndex), [10, 250]);
    });

    test(
      'an explicit chapter wins over a different chapter title in the question',
      () {
        final plan = _plan('Explain energy in chapter 1');
        expect(plan.documents.map((d) => d.chunk.pageIndex), [10, 250]);
        expect(plan.mode, StudyQueryMode.search);
      },
    );

    test('a short quiz follow-up retains its chapter', () {
      final plan = _plan(
        'Quiz me',
        history: const [
          StudyMessage.user('Chapter 2'),
          StudyMessage.answer('Energy summary'),
        ],
      );
      expect(plan.documents.map((d) => d.chunk.pageIndex), [500, 700, 999]);
    });

    test('next chapter advances instead of repeating the previous one', () {
      final plan = _plan(
        'Next chapter',
        history: const [
          StudyMessage.user('Chapter 1'),
          StudyMessage.answer('Cells summary'),
        ],
      );
      expect(plan.documents.map((d) => d.chunk.pageIndex), [500, 700, 999]);
    });

    test('follow-ups after advancing keep the new chapter', () {
      final plan = _plan(
        'Tell me more',
        history: const [
          StudyMessage.user('Chapter 1'),
          StudyMessage.answer('Cells summary'),
          StudyMessage.user('Next chapter'),
          StudyMessage.answer('Energy summary'),
        ],
      );
      expect(plan.documents.map((d) => d.chunk.pageIndex), [500, 700, 999]);
    });

    test(
      'contents entries without page numbers are not chapter boundaries',
      () {
        final plan = _plan(
          'Chapter 1',
          documents: [
            _document(0, 'Contents\nChapter 1: Cells\nChapter 2: Energy'),
            ..._book().skip(1),
          ],
        );
        expect(plan.documents.map((d) => d.chunk.pageIndex), [10, 250]);
      },
    );

    test('part headings do not replace chapter boundaries', () {
      final plan = _plan(
        'Chapter 1',
        documents: [_document(0, 'Part 1: Foundations'), ..._book().skip(1)],
      );
      expect(plan.documents.map((d) => d.chunk.pageIndex), [10, 250]);
    });

    test('a referential follow-up retains its chapter', () {
      final plan = _plan(
        'Tell me more',
        history: const [
          StudyMessage.user('Chapter 2'),
          StudyMessage.answer('Energy summary'),
        ],
      );
      expect(plan.documents.map((d) => d.chunk.pageIndex), [500, 700, 999]);
    });

    test('a new broad request does not inherit an old chapter', () {
      final plan = _plan(
        'Summarize the whole textbook',
        history: const [
          StudyMessage.user('Chapter 2'),
          StudyMessage.answer('Energy summary'),
        ],
      );
      expect(plan.outlineOnly, isTrue);
    });

    test('a missing chapter asks for a scope instead of guessing passages', () {
      final plan = _plan('Summarize chapter 99');
      expect(plan.outlineOnly, isTrue);
      expect(plan.documents, isEmpty);
      expect(plan.instructions, contains('could not be located reliably'));
    });

    test(
      'a scan with no chapter text asks without inventing a chapter list',
      () {
        final plan = _plan('Summarize this textbook', documents: []);
        expect(plan.outlineOnly, isTrue);
        expect(plan.catalogue, contains('"detectedChapters":[]'));
        expect(
          plan.instructions,
          contains('ask for a chapter title or a small page range'),
        );
      },
    );

    test('the page-range fallback actually limits the next retrieval', () {
      final plan = _plan('Summarize pages 501-701');
      expect(plan.outlineOnly, isFalse);
      expect(plan.documents.map((d) => d.chunk.pageIndex), [500, 700]);
    });

    test('an invalid page range asks instead of retrieving unrelated text', () {
      expect(_plan('Summarize pages 2000-2100').outlineOnly, isTrue);
    });

    test(
      'repeated running chapter headers do not move the chapter boundary',
      () {
        final plan = _plan(
          'Chapter 2',
          documents: [..._book(), _document(750, 'Chapter 2: Energy')],
        );
        expect(
          plan.documents.map((d) => d.chunk.pageIndex),
          containsAll([500, 700, 999, 750]),
        );
      },
    );

    test('a named book restricts scope among multiple selected sources', () {
      final plan = _plan(
        'Summarize Biology chapter 2',
        notes: [
          _note(),
          _note(id: 'physics', title: 'Physics'),
        ],
        documents: [
          ..._book(),
          _document(0, 'Chapter 2: Forces', id: 'physics'),
        ],
      );
      expect(plan.documents.every((d) => d.chunk.noteId == 'book'), isTrue);
      expect(plan.documents, hasLength(3));
    });

    test('a chapter number shared by two books needs a source choice', () {
      final plan = _plan(
        'Chapter 2',
        notes: [
          _note(),
          _note(id: 'physics', title: 'Physics'),
        ],
        documents: [
          ..._book(),
          _document(0, 'Chapter 2: Forces', id: 'physics'),
        ],
      );
      expect(plan.outlineOnly, isTrue);
    });
  });

  test('catalogue bytes are reserved before excerpts are packed', () async {
    final document = _document(0, '材料 ' * 500);
    const assembler = StudyContextAssembler(
      maxTextTokens: 2000,
      maxTotalBytes: 800,
    );
    final payload = await assembler.assemble([
      StudyHit(document, 1),
    ], reservedTextBytes: 400);
    // CJK text uses more bytes than the same number of English characters.
    expect(utf8.encode(payload.contextText).length, lessThanOrEqualTo(400));
  });

  test(
    'controller sends only an outline, then retrieves the chosen chapter',
    () async {
      final repository = InMemoryNoteRepository();
      final client = _RoutedFakeAiClient();
      final note = await repository.createNote(title: 'Biology');
      await repository.saveNote(
        note.id,
        NoteContent([
          for (int i = 0; i < 60; i++)
            StoredPage(
              setup: const PageSetup(),
              strokes: const [],
              textElements: [
                NoteTextElement(
                  id: 'text-$i',
                  position: const InkVector(50, 50),
                  text: i == 0
                      ? 'Chapter 1: Cells\nCELL_BODY'
                      : i == 30
                      ? 'Chapter 2: Energy\nENERGY_BODY'
                      : i < 30
                      ? 'CELL_BODY'
                      : 'ENERGY_BODY',
                ),
              ],
            ),
        ]),
      );
      final desk = StudyDeskController(repository: repository, client: client);
      addTearDown(() {
        desk.dispose();
        repository.dispose();
        client.close();
      });
      await desk.load();
      desk.addNotes([note.id]);

      Future<void> waitForRequest(int count) async {
        for (int i = 0; i < 200 && client.requests.length < count; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(client.requests, hasLength(count));
      }

      final first = desk.send('Summarize the textbook');
      await waitForRequest(1);
      final outline = client.requests[0];
      expect(outline.messages.single.text, contains('Cells'));
      expect(outline.messages.single.text, isNot(contains('CELL_BODY')));
      expect(outline.imagePng, StudyContextAssembler.placeholderPng);
      expect(
        outline.systemInstruction,
        contains('ask which chapter to start with'),
      );
      client.answer('Which chapter should we start with?', index: 0);
      await first;
      await waitForRequest(2);
      client.answer('["Chapter 1", "Chapter 2", "Choose pages"]', index: 1);
      client.plannerAvailable = false;

      final second = desk.send('Chapter 2');
      await waitForRequest(3);
      expect(client.requests[2].messages.last.text, contains('ENERGY_BODY'));
      expect(
        client.requests[2].messages.last.text,
        isNot(contains('CELL_BODY')),
      );
      client.answer('Energy summary.', index: 2);
      await second;
      if (client.requests.length > 3) {
        client.complete(
          const AiError(AiFailure(AiFailureKind.network)),
          index: 3,
        );
      }
    },
  );
}
