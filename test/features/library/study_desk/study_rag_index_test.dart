import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/document_io/document_models.dart';
import 'package:greatnote/features/editor/document_io/document_platform.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/study_desk/study_context_plan.dart';
import 'package:greatnote/features/library/study_desk/study_desk_models.dart';
import 'package:greatnote/features/library/study_desk/study_desk_store.dart';
import 'package:greatnote/features/library/study_desk/study_rag_index.dart';

class _Pdf implements PdfTextExtractor, PdfOutlineReader {
  bool failText = false;
  bool failOutline = false;
  bool omitLastPage = false;
  int reads = 0;
  List<PdfOutlineEntry> outline = const [];

  @override
  Future<Map<int, List<PdfTextRun>>> extractText(
    Uint8List bytes,
    Set<int> pageIndices,
  ) async {
    reads++;
    if (failText) throw StateError('Temporary read failure');
    return {
      for (final page in pageIndices)
        if (!omitLastPage || page != pageIndices.last)
          page: [
            PdfTextRun(
              'Body of PDF page $page',
              const Rect.fromLTWH(.1, .1, .8, .1),
            ),
          ],
    };
  }

  @override
  Future<List<PdfOutlineEntry>> readOutline(Uint8List bytes) async {
    if (failOutline) throw StateError('Temporary outline failure');
    return outline;
  }
}

Future<NoteEntry> _note(
  NoteRepository repository,
  List<int> sourcePages,
) async {
  final note = await repository.createNote(title: 'Book');
  final assetId = await repository.storeAsset(
    note.id,
    Uint8List.fromList([1]),
    kind: NoteAssetKind.pdf,
    extension: 'pdf',
  );
  return repository.saveNote(
    note.id,
    NoteContent([
      for (final page in sourcePages)
        StoredPage(
          setup: const PageSetup(),
          strokes: const [],
          pdfSource: PdfPageSource(
            assetId: assetId,
            pageIndex: page,
            pageSize: const Size(600, 800),
          ),
        ),
    ]),
  );
}

StudyContextPlan _plan(
  NoteEntry note,
  List<StudyChunk> chunks,
  String prompt,
) => StudyContextPlan.forQuestion(
  prompt: prompt,
  documents: [
    for (final chunk in chunks)
      StudySearchDocument(chunk: chunk, noteTitle: note.title),
  ],
  notes: [note],
  mode: StudyQueryMode.search,
  assembler: const StudyContextAssembler(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a failed PDF read is retried in the same index at the same revision',
    () async {
      final repository = InMemoryNoteRepository();
      addTearDown(repository.dispose);
      final note = await _note(repository, [0]);
      final pdf = _Pdf()..failText = true;
      final index = StudyRagIndex(repository: repository, pdfText: pdf);
      expect((await index.chunksFor(note)).single.needsPicture, isTrue);
      pdf.failText = false;
      expect(
        (await index.chunksFor(note)).single.typed,
        contains('PDF page 0'),
      );
      expect(pdf.reads, 2);
    },
  );

  test('missing page results are incomplete and retried', () async {
    final repository = InMemoryNoteRepository();
    addTearDown(repository.dispose);
    final note = await _note(repository, [0, 1]);
    final pdf = _Pdf()..omitLastPage = true;
    final index = StudyRagIndex(repository: repository, pdfText: pdf);
    expect((await index.chunksFor(note)).last.needsPicture, isTrue);
    pdf.omitLastPage = false;
    expect((await index.chunksFor(note)).last.typed, contains('PDF page 1'));
    expect(pdf.reads, 2);
  });

  test('duplicate PDF pages retain text at both note positions', () async {
    final repository = InMemoryNoteRepository();
    addTearDown(repository.dispose);
    final note = await _note(repository, [1, 0, 1]);
    final pdf = _Pdf();
    final chunks = await StudyRagIndex(
      repository: repository,
      pdfText: pdf,
    ).chunksFor(note);
    expect(chunks.map((c) => c.typed), [
      'Body of PDF page 1',
      'Body of PDF page 0',
      'Body of PDF page 1',
    ]);
    expect(pdf.reads, 1);
  });

  test(
    'bookmark chapters map reordered pages and exclude back matter',
    () async {
      final repository = InMemoryNoteRepository();
      addTearDown(repository.dispose);
      final note = await _note(repository, [10, 11, 20, 21, 30, 10]);
      final pdf = _Pdf()
        ..outline = const [
          PdfOutlineEntry(
            title: '1 Foundations',
            pageIndex: 10,
            children: [
              PdfOutlineEntry(title: '1.1 Definitions', pageIndex: 11),
              PdfOutlineEntry(title: 'Chapter 1 in Review', pageIndex: 19),
            ],
          ),
          PdfOutlineEntry(title: '2 Applications', pageIndex: 20),
          PdfOutlineEntry(title: 'Appendices', pageIndex: 30),
        ];
      final chunks = await StudyRagIndex(
        repository: repository,
        pdfText: pdf,
      ).chunksFor(note);
      expect(
        _plan(
          note,
          chunks,
          'Chapter 1',
        ).documents.map((d) => d.chunk.pageIndex),
        [0, 1, 5],
      );
      expect(
        _plan(
          note,
          chunks,
          'Chapter 2',
        ).documents.map((d) => d.chunk.pageIndex),
        [2, 3],
      );
      final restored = [
        for (final c in chunks)
          StudyChunk.fromJson(
            jsonDecode(jsonEncode(c.toJson())) as Map<String, Object?>,
          ),
      ];
      expect(
        _plan(note, restored, 'Chapter 2').catalogue,
        contains('Applications'),
      );
    },
  );

  test('chapter bookmarks nested under parts remain chapter choices', () async {
    final repository = InMemoryNoteRepository();
    addTearDown(repository.dispose);
    final note = await _note(repository, [0, 1, 2, 3]);
    final pdf = _Pdf()
      ..outline = const [
        PdfOutlineEntry(
          title: 'Part 1 Foundations',
          pageIndex: 0,
          children: [
            PdfOutlineEntry(title: 'Chapter 1 Cells', pageIndex: 0),
            PdfOutlineEntry(title: 'Chapter 2 Energy', pageIndex: 2),
          ],
        ),
      ];
    final chunks = await StudyRagIndex(
      repository: repository,
      pdfText: pdf,
    ).chunksFor(note);
    expect(
      _plan(note, chunks, 'Chapter 2').documents.map((d) => d.chunk.pageIndex),
      [2, 3],
    );
  });

  test(
    'a failed outline read is retried without losing extracted text',
    () async {
      final repository = InMemoryNoteRepository();
      addTearDown(repository.dispose);
      final note = await _note(repository, [0]);
      final pdf = _Pdf()..failOutline = true;
      final index = StudyRagIndex(repository: repository, pdfText: pdf);
      expect((await index.chunksFor(note)).single.typed, isNotEmpty);
      pdf.failOutline = false;
      pdf.outline = const [
        PdfOutlineEntry(title: '1 Foundations', pageIndex: 0),
      ];
      expect(
        (await index.chunksFor(note)).single.sourceSection?.title,
        '1 Foundations',
      );
      expect(pdf.reads, 2);
    },
  );

  test(
    'old disk indexes are invalidated when chapter metadata changes',
    () async {
      final directory = await Directory.systemTemp.createTemp('rag-cache');
      addTearDown(() => directory.delete(recursive: true));
      await File('${directory.path}/book.json').writeAsString(
        jsonEncode({'version': 2, 'revision': 1, 'chunks': <Object?>[]}),
      );
      expect(await FileStudyChunkCache(directory).read('book', 1), isNull);
    },
  );
}
