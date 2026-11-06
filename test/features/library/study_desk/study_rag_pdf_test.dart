import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/document_io/document_models.dart';
import 'package:greatnote/features/editor/document_io/document_platform.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/study_desk/study_context_plan.dart';
import 'package:greatnote/features/library/study_desk/study_desk_store.dart';
import 'package:greatnote/features/library/study_desk/study_rag_index.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final file = File('test/027137121.pdf');

  test(
    '027137121: discovers chapters and retrieves chapter 1 content',
    () async {
      await pdfrx.pdfrxInitialize();
      final bytes = await file.readAsBytes();
      const extractor = PdfrxRasterizer();
      final inspection = await extractor.inspect(bytes);
      expect(inspection.pageSizes, hasLength(2938));
      final repository = InMemoryNoteRepository();
      addTearDown(repository.dispose);
      final created = await repository.createNote(title: '027137121');
      final assetId = await repository.storeAsset(
        created.id,
        bytes,
        kind: NoteAssetKind.pdf,
        extension: 'pdf',
      );
      final note = await repository.saveNote(
        created.id,
        NoteContent([
          for (int i = 0; i < inspection.pageSizes.length; i++)
            StoredPage(
              setup: const PageSetup(),
              strokes: const [],
              pdfSource: PdfPageSource(
                assetId: assetId,
                pageIndex: i,
                pageSize: inspection.pageSizes[i],
              ),
            ),
        ]),
      );
      final cacheDirectory = await Directory.systemTemp.createTemp(
        'study-rag-pdf',
      );
      addTearDown(() => cacheDirectory.delete(recursive: true));
      final cache = FileStudyChunkCache(cacheDirectory);
      final index = StudyRagIndex(
        repository: repository,
        pdfText: extractor,
        pdfOutline: extractor,
        diskCache: cache,
      );
      final chunks = await index.chunksFor(note);
      final restored = await cache.read(note.id, note.revision);
      expect(restored, isNotNull);
      expect(restored!.where((c) => c.sourceSection != null), hasLength(20));
      final documents = [
        for (final chunk in restored)
          StudySearchDocument(chunk: chunk, noteTitle: note.title),
      ];
      StudyContextPlan plan(String prompt) => StudyContextPlan.forQuestion(
        prompt: prompt,
        documents: documents,
        notes: [note],
        mode: StudyQueryMode.search,
        assembler: const StudyContextAssembler(),
      );

      final overview = plan('List all chapters in this textbook');
      expect(overview.outlineOnly, isTrue);
      expect(overview.documents, isEmpty);
      final catalogue =
          jsonDecode(overview.catalogue.split('\n')[1]) as Map<String, Object?>;
      final chapters = (catalogue['detectedChapters']! as List)
          .cast<Map<String, Object?>>();
      expect(chapters, hasLength(20));
      const starts = [
        41,
        135,
        359,
        640,
        783,
        869,
        929,
        1064,
        1330,
        1642,
        1737,
        1855,
        1947,
        2057,
        2113,
        2209,
        2250,
        2345,
        2407,
        2493,
        2621,
      ];
      for (int i = 0; i < 20; i++) {
        expect(chapters[i]['chapter'], '${i + 1}');
        expect(chapters[i]['notePages'], '${starts[i]}-${starts[i + 1] - 1}');
      }
      expect(chapters.first['title'], 'Introduction to Differential Equations');
      expect(chapters.last['title'], 'Conformal Mappings');

      final selected = plan('Summarize chapter 1');
      expect(selected.unknownScope, isFalse);
      expect(selected.mode, StudyQueryMode.overview);
      expect(
        selected.documents.every(
          (d) => d.chunk.pageIndex >= 40 && d.chunk.pageIndex < 134,
        ),
        isTrue,
      );
      final chapterText = selected.documents
          .map((d) => 'Page ${d.chunk.pageIndex + 1}\n${d.chunk.typed}')
          .join('\n\n');
      for (final phrase in [
        'Definitions and Terminology',
        'Initial-Value Problems',
        'Mathematical Models',
        'dependent variable',
        'initial condition',
        'population',
        'radioactive',
      ]) {
        expect(chapterText.toLowerCase(), contains(phrase.toLowerCase()));
      }

      final queryResults = <Map<String, Object?>>[];
      for (final query in [
        'What is the order of a differential equation?',
        'What are initial conditions (IC) in an initial-value problem?',
        'How does the Malthus population model describe population growth?',
        'How is radioactive decay modeled?',
      ]) {
        final scope = plan('$query In chapter 1');
        final hits = StudyRetriever.retrieve(scope.documents, query);
        expect(hits, isNotEmpty);
        final payload = await const StudyContextAssembler().assemble(hits);
        expect(payload.contextText, isNotEmpty);
        expect(
          payload.map.chunks.every(
            (c) => c.pageIndex >= 40 && c.pageIndex < 134,
          ),
          isTrue,
        );
        final expected = switch (query) {
          String q when q.contains('order') => 'highest derivative',
          String q when q.contains('initial') =>
            'are called initial conditions',
          String q when q.contains('Malthus') => 'rate at which a population',
          _ => 'number of nuclei',
        };
        expect(
          payload.contextText.toLowerCase().replaceAll(RegExp(r'\s+'), ' '),
          contains(expected),
        );
        queryResults.add({
          'query': query,
          'pages': hits.map((h) => h.chunk.pageIndex + 1).toList(),
          'context': payload.contextText,
        });
      }
      final overviewHits = StudyRetriever.retrieve(
        selected.documents,
        'Summarize chapter 1',
        mode: selected.mode,
      );
      final sampledPages = overviewHits
          .map((h) => h.chunk.pageIndex + 1)
          .toList();
      expect(sampledPages.first, lessThanOrEqualTo(60));
      expect(sampledPages.last, greaterThanOrEqualTo(115));
      expect(overviewHits.every((h) => h.chunk.typed.length > 150), isTrue);

      await Directory('build').create(recursive: true);
      await File('build/study_rag_pdf_report.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'pdf': file.path,
          'pages': inspection.pageSizes.length,
          'chunks': chunks.length,
          'chapters': chapters,
          'selectedChapter': 1,
          'selectedChunks': selected.documents.length,
          'overviewPages': sampledPages,
          'queries': queryResults,
        }),
      );
      await File('build/study_rag_chapter_1.txt').writeAsString(chapterText);
    },
    timeout: const Timeout(Duration(minutes: 10)),
    skip: !file.existsSync()
        ? 'Supply test/027137121.pdf to run the real PDF regression.'
        : false,
  );
}
