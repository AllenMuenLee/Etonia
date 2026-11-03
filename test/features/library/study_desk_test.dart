import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/features/editor/ai/ai_citation.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/ai_config.dart';
import 'package:greatnote/features/editor/document_io/document_models.dart';
import 'package:greatnote/features/editor/document_io/document_platform.dart';
import 'package:greatnote/features/editor/document_io/svg_document.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/text/note_text.dart';
import 'package:greatnote/features/editor/widgets/ai_citation_highlight.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/library_screen.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/study_desk/study_citation_preview.dart';
import 'package:greatnote/features/library/study_desk/study_desk_models.dart';
import 'package:greatnote/features/library/study_desk/study_desk_screen.dart';
import 'package:greatnote/features/library/study_desk/study_desk_store.dart';
import 'package:greatnote/features/library/study_desk/study_rag_index.dart';

import '../../helpers/ai_fakes.dart';
import '../../helpers/pump_app.dart';

final DateTime _now = DateTime(2026, 11, 3, 9);

Stroke _line(double x0, double y0, double x1, double y1, {String? id}) =>
    Stroke.fromPoints(
      style: const StrokeStyle(ink: InkPalette.ink, width: 2),
      points: <InkVector>[InkVector(x0, y0), InkVector(x1, y1)],
      id: id,
    );

StoredRecognizedInkWord _word(
  String text,
  List<int> strokes, {
  double confidence = 0.95,
  List<String> alternatives = const <String>[],
}) => StoredRecognizedInkWord(
  text: text,
  confidence: confidence,
  alternatives: alternatives,
  strokeIndices: strokes,
  normalizedStrokes: const <List<InkVector>>[],
  aspectRatio: 2,
);

NoteImageElement _svgImage() => NoteImageElement(
  id: 'svg-1',
  assetId: '',
  pixelSize: const Size(200, 150),
  center: const InkVector(500, 860),
  size: const Size(200, 150),
  vector: EditableSvg.parse(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 150">'
    '<title>Krebs cycle</title><desc>Energy pathway</desc>'
    '<circle cx="100" cy="75" r="50"/><text x="10" y="20">Citrate</text>'
    '</svg>',
  ),
);

/// A page of each kind, each far enough from the others to be its own chunk:
/// written words; a drawing with no words in it and its label just beside it;
/// and an inline SVG with handwriting touching it.
StoredPage _mixedPage() {
  final List<Stroke> strokes = <Stroke>[
    // 0-2: Three written words, in a row.
    _line(60, 100, 120, 100),
    _line(130, 100, 190, 100),
    _line(200, 100, 260, 100),
    // 3-8: A box with a line and a curve in it; nothing reads as a word.
    _line(100, 300, 300, 300),
    _line(300, 300, 300, 500),
    _line(300, 500, 100, 500),
    _line(100, 500, 100, 300),
    _line(120, 400, 280, 400),
    _line(200, 320, 200, 480),
    // 9: The label, 50pt under the box: too far to join it, near enough to name.
    _line(150, 550, 250, 550),
    // 10: Handwriting touching the SVG below.
    _line(420, 950, 560, 950),
  ];
  return StoredPage(
    setup: const PageSetup(),
    strokes: strokes,
    images: <NoteImageElement>[_svgImage()],
    recognizedWords: <StoredRecognizedInkWord>[
      _word('Mitosis', <int>[0]),
      _word('has', <int>[1]),
      _word('phases', <int>[2]),
      _word('ribosome', <int>[9]),
      _word('citrate', <int>[10]),
    ],
  );
}

StudyChunk _chunkHolding(List<StudyChunk> chunks, int stroke) =>
    chunks.firstWhere((StudyChunk c) => c.strokeIndices.contains(stroke));

/// A page like one of a lecture: [words] each one stroke, in a row each.
StoredPage _writtenPage(List<String> words, {String prefix = 's'}) {
  return StoredPage(
    setup: const PageSetup(),
    strokes: <Stroke>[
      for (int i = 0; i < words.length; i++)
        _line(60, 80.0 + i * 30, 300, 80.0 + i * 30, id: '$prefix$i'),
    ],
    recognizedWords: <StoredRecognizedInkWord>[
      for (int i = 0; i < words.length; i++) _word(words[i], <int>[i]),
    ],
  );
}

Future<NoteEntry> _storeNote(
  NoteRepository repository,
  String title,
  List<StoredPage> pages, {
  String? folderId,
}) async {
  final NoteEntry note = await repository.createNote(
    title: title,
    folderId: folderId,
  );
  return repository.saveNote(note.id, NoteContent(pages));
}

/// Which rows of a [_writtenPage] [strokes] are.
List<int> _rows(Iterable<Stroke> strokes) => <int>[
  for (final Stroke stroke in strokes) (stroke.points.first.y - 80) ~/ 30,
];

StudySearchDocument _document(StudyChunk chunk, String title) =>
    StudySearchDocument(chunk: chunk, noteTitle: title);

List<StudySearchDocument> _documentsOf(
  String noteId,
  String title,
  List<StoredPage> pages,
) => <StudySearchDocument>[
  for (final StudyChunk chunk in StudyChunker.chunkNote(
    StudyNoteData.of(noteId, NoteContent(pages)),
  ))
    _document(chunk, title),
];

/// Counts what it is asked to draw, drawing nothing.
class _CountingRenderer implements StudyChunkRenderer {
  final List<StudyChunk> rendered = <StudyChunk>[];
  int combined = 0;

  @override
  Future<StudyCrop?> render(StudyChunk chunk) async {
    rendered.add(chunk);
    return StudyCrop(
      chunk: chunk,
      png: Uint8List.fromList(<int>[rendered.length]),
      logicalBounds: chunk.logicalBounds,
    );
  }

  @override
  Future<Uint8List> combine(List<StudyCrop> crops) async {
    combined++;
    return Uint8List.fromList(<int>[99]);
  }
}

/// A fake PDF's words, by page.
class _FakePdfText implements PdfTextExtractor {
  _FakePdfText(this.pages);

  final Map<int, List<PdfTextRun>> pages;
  Object? error;
  int reads = 0;

  @override
  Future<Map<int, List<PdfTextRun>>> extractText(
    Uint8List bytes,
    Set<int> pageIndices,
  ) async {
    reads++;
    if (error case final Object error) throw error;
    return <int, List<PdfTextRun>>{
      for (final int index in pageIndices)
        index: pages[index] ?? const <PdfTextRun>[],
    };
  }
}

/// A line of a page, at [top] down it as a share of its height.
PdfTextRun _pdfLine(String text, double top, {double left = 0.1}) =>
    PdfTextRun(text, Rect.fromLTRB(left, top, left + 0.4, top + 0.015));

StoredPage _pdfPage(int pdfPage, {List<Rect> masks = const <Rect>[]}) =>
    StoredPage(
      setup: const PageSetup(),
      strokes: const <Stroke>[],
      pdfSource: PdfPageSource(
        assetId: 'book',
        pageIndex: pdfPage,
        pageSize: const Size(600, 800),
      ),
      pdfMasks: masks,
    );

Future<NoteEntry> _storePdfNote(
  NoteRepository repository,
  String title,
  List<StoredPage> pages,
) async {
  final NoteEntry note = await repository.createNote(title: title);
  final String asset = await repository.storeAsset(
    note.id,
    Uint8List.fromList(<int>[1, 2, 3]),
    kind: NoteAssetKind.pdf,
    extension: 'pdf',
  );
  return repository.saveNote(
    note.id,
    NoteContent(<StoredPage>[
      for (final StoredPage page in pages)
        StoredPage(
          setup: page.setup,
          strokes: page.strokes,
          pdfMasks: page.pdfMasks,
          pdfSource: PdfPageSource(
            assetId: asset,
            pageIndex: page.pdfSource!.pageIndex,
            pageSize: page.pdfSource!.pageSize,
          ),
        ),
    ]),
  );
}

void main() {
  group('PDFs', () {
    test('runs on one line join; those apart stay apart', () {
      final List<PdfTextRun> lines = joinPdfTextRuns(<PdfTextRun>[
        const PdfTextRun('The Krebs', Rect.fromLTRB(0.1, 0.1, 0.3, 0.12)),
        const PdfTextRun('cycle\n', Rect.fromLTRB(0.305, 0.1, 0.4, 0.12)),
        const PdfTextRun('  ', Rect.fromLTRB(0.4, 0.1, 0.41, 0.12)),
        const PdfTextRun('Next line', Rect.fromLTRB(0.1, 0.14, 0.3, 0.16)),
        const PdfTextRun('Far column', Rect.fromLTRB(0.7, 0.14, 0.9, 0.16)),
      ]);
      expect(lines.map((PdfTextRun line) => line.text), <String>[
        'The Krebs cycle',
        'Next line',
        'Far column',
      ]);
      expect(lines.first.bounds.right, 0.4);
    });

    test('its words are found and sent as words, costing no picture', () async {
      final InMemoryNoteRepository repository = InMemoryNoteRepository();
      addTearDown(repository.dispose);
      final NoteEntry note = await _storePdfNote(
        repository,
        'Textbook',
        <StoredPage>[_pdfPage(0), _pdfPage(1)],
      );
      final _FakePdfText text = _FakePdfText(<int, List<PdfTextRun>>{
        0: <PdfTextRun>[_pdfLine('Contract law offers', 0.1)],
        1: <PdfTextRun>[
          _pdfLine('The Krebs cycle makes ATP', 0.1),
          _pdfLine('in the mitochondrial matrix', 0.13),
        ],
      });
      final List<StudyChunk> chunks = await StudyRagIndex(
        repository: repository,
        pdfText: text,
      ).chunksFor(note);
      expect(text.reads, 1, reason: 'One PDF, opened once.');
      expect(chunks.length, 2);
      final StudyChunk chunk = chunks.last;
      expect(chunk.pageIndex, 1);
      expect(chunk.kind, StudyChunkKind.text);
      expect(chunk.needsPicture, isFalse);
      expect(chunk.typed, contains('Krebs cycle'));
      // Placed on the page as it is shown: shares of 600 by 800.
      expect(chunk.logicalBounds.left, closeTo(60, 0.001));
      expect(chunk.logicalBounds.top, closeTo(80, 0.001));

      final List<StudyHit> hits = StudyRetriever.retrieve(<StudySearchDocument>[
        for (final StudyChunk c in chunks) _document(c, 'Textbook'),
      ], 'where is ATP made');
      expect(hits.single.chunk, same(chunk));
      final _CountingRenderer renderer = _CountingRenderer();
      final StudyPayload payload = await const StudyContextAssembler().assemble(
        hits,
        renderer: renderer,
      );
      expect(renderer.rendered, isEmpty);
      expect(payload.imagePng, StudyContextAssembler.placeholderPng);
      expect(payload.contextText, contains('The Krebs cycle makes ATP'));
      expect(
        payload.contextText,
        contains('[Source N1:P2:C1 | Note: "Textbook"'),
      );
    });

    test(
      'a scanned page, with no words, is drawn for the model instead',
      () async {
        final InMemoryNoteRepository repository = InMemoryNoteRepository();
        addTearDown(repository.dispose);
        final NoteEntry note = await _storePdfNote(
          repository,
          'Scan',
          <StoredPage>[_pdfPage(0)],
        );
        final StudyChunk chunk = (await StudyRagIndex(
          repository: repository,
          pdfText: _FakePdfText(const <int, List<PdfTextRun>>{}),
        ).chunksFor(note)).single;
        expect(chunk.kind, StudyChunkKind.diagram);
        expect(chunk.needsPicture, isTrue);
        expect(chunk.logicalBounds, const Rect.fromLTWH(0, 0, 600, 800));
      },
    );

    test('words rubbed out of the PDF are not read', () {
      final List<StudyChunk> chunks = StudyChunker.chunkPage(
        'n',
        StudyPageData.of(
          _pdfPage(0, masks: const <Rect>[Rect.fromLTWH(0, 70, 600, 40)]),
          0,
          pdfText: <PdfTextRun>[
            _pdfLine('rubbed out', 0.1),
            _pdfLine('still there', 0.5),
          ],
        ),
      );
      expect(chunks.single.typed, 'still there');
    });

    test(
      'a PDF that cannot be read now is tried again, not remembered',
      () async {
        final Directory directory = await Directory.systemTemp.createTemp(
          'pdf',
        );
        addTearDown(() => directory.delete(recursive: true));
        final InMemoryNoteRepository repository = InMemoryNoteRepository();
        addTearDown(repository.dispose);
        final NoteEntry note = await _storePdfNote(
          repository,
          'Book',
          <StoredPage>[_pdfPage(0)],
        );
        final FileStudyChunkCache cache = FileStudyChunkCache(directory);
        await StudyRagIndex(
          repository: repository,
          diskCache: cache,
          pdfText: _FakePdfText(const <int, List<PdfTextRun>>{})
            ..error = StateError('No engine'),
        ).chunksFor(note);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(await cache.read(note.id, note.revision), isNull);
      },
    );

    test('two columns in one chunk are read one after the other', () {
      final StudyChunk chunk = StudyChunker.chunkPage(
        'n',
        StudyPageData.of(
          _pdfPage(0),
          0,
          pdfText: <PdfTextRun>[
            _pdfLine('left one', 0.10, left: 0.05),
            _pdfLine('left two', 0.12, left: 0.05),
            _pdfLine('right one', 0.10, left: 0.46),
            _pdfLine('right two', 0.12, left: 0.46),
          ],
        ),
      ).single;
      expect(chunk.lines.map((StudyChunkLine line) => line.text), <String>[
        'left one',
        'left two',
        'right one',
        'right two',
      ]);
    });
  });

  group('What the tutor is told about the notes', () {
    test('it is told to answer, and never to comment on the notes', () {
      const String system = AiPrompts.studySystem;
      expect(system, contains('Always answer the question asked'));
      expect(system, contains('silently ignore any excerpt'));
      expect(system, contains('Never remark on how the question relates'));
      // What used to invite it.
      expect(system, isNot(contains('say so in one short line')));
      expect(system, isNot(contains('Base your answer on the excerpts')));
    });
  });

  group('Handwriting and diagram chunks', () {
    test('a page falls into text, diagram, and mixed chunks', () {
      final List<StudyChunk> chunks = StudyChunker.chunkPage(
        'n1',
        StudyPageData.of(_mixedPage(), 0),
      );

      final StudyChunk text = _chunkHolding(chunks, 0);
      expect(text.kind, StudyChunkKind.text);
      expect(text.strokeIndices, <int>[0, 1, 2]);
      expect(text.handwriting, 'Mitosis has phases');
      expect(text.needsPicture, isFalse);

      final StudyChunk diagram = _chunkHolding(chunks, 3);
      expect(diagram.kind, StudyChunkKind.diagram);
      expect(diagram.strokeIndices, <int>[3, 4, 5, 6, 7, 8]);
      expect(diagram.needsPicture, isTrue);
      expect(diagram.handwriting, isEmpty);
      // Beside the drawing, but no part of it, the label still names it.
      expect(diagram.anchors, contains('ribosome'));
      expect(diagram.tags, containsAll(<String>['box', 'axes']));

      final StudyChunk mixed = _chunkHolding(chunks, 10);
      expect(mixed.kind, StudyChunkKind.mixed);
      expect(mixed.imageIds, <String>['svg-1']);
      expect(mixed.svgText, contains('Krebs cycle'));
      expect(mixed.svgText, contains('Energy pathway'));
      expect(mixed.svgText, contains('Citrate'));

      expect(
        <int>{for (final StudyChunk c in chunks) c.chunkIndex}.length,
        chunks.length,
      );
    });

    test('a page of dense writing splits into bands of limited height', () {
      final StoredPage page = _writtenPage(
        List<String>.generate(40, (int i) => 'word$i'),
      );
      final List<StudyChunk> chunks = StudyChunker.chunkPage(
        'n1',
        StudyPageData.of(page, 0),
      );
      expect(chunks.length, greaterThan(1));
      for (final StudyChunk chunk in chunks) {
        expect(
          chunk.logicalBounds.height,
          lessThanOrEqualTo(StudyChunker.maxClusterHeight),
        );
      }
      // Every stroke is in exactly one.
      expect(
        chunks.expand((StudyChunk c) => c.strokeIndices).toList()..sort(),
        List<int>.generate(40, (int i) => i),
      );
    });

    test('a typed caption near a drawing is among its labels', () {
      final StoredPage page = StoredPage(
        setup: const PageSetup(),
        strokes: <Stroke>[
          _line(100, 300, 300, 300),
          _line(300, 300, 300, 500),
          _line(300, 500, 100, 500),
          _line(100, 500, 100, 300),
        ],
        textElements: const <NoteTextElement>[
          NoteTextElement(
            id: 't1',
            position: InkVector(100, 545),
            text: 'Figure 1: the mitochondrion',
          ),
        ],
      );
      final StudyChunk diagram = _chunkHolding(
        StudyChunker.chunkPage('n1', StudyPageData.of(page, 0)),
        0,
      );
      expect(diagram.anchors, contains('Figure 1: the mitochondrion'));
    });

    test('poorly read writing is shown to the model, not trusted', () {
      final StoredPage page = StoredPage(
        setup: const PageSetup(),
        strokes: <Stroke>[_line(60, 100, 120, 100)],
        recognizedWords: <StoredRecognizedInkWord>[
          _word('rnitosis', <int>[0], confidence: 0.3),
        ],
      );
      final StudyChunk chunk = StudyChunker.chunkPage(
        'n1',
        StudyPageData.of(page, 0),
      ).single;
      expect(chunk.kind, StudyChunkKind.text);
      expect(chunk.lowConfidence, isTrue);
      expect(chunk.needsPicture, isTrue);
    });

    test('chunks survive being kept as JSON', () {
      final List<StudyChunk> chunks = StudyChunker.chunkPage(
        'n1',
        StudyPageData.of(_mixedPage(), 2),
      );
      final List<StudyChunk> back = <StudyChunk>[
        for (final StudyChunk chunk in chunks)
          StudyChunk.fromJson(
            jsonDecode(jsonEncode(chunk.toJson())) as Map<String, Object?>,
          ),
      ];
      expect(
        back.map((StudyChunk c) => jsonEncode(c.toJson())),
        chunks.map((StudyChunk c) => jsonEncode(c.toJson())),
      );
      expect(back.first.pageIndex, 2);
    });
  });

  group('Finding chunks', () {
    final List<StudySearchDocument> documents = <StudySearchDocument>[
      ..._documentsOf('bio', 'Cell Biology', <StoredPage>[
        _writtenPage(<String>['Unrelated', 'lecture', 'housekeeping']),
        _mixedPage(),
      ]),
      ..._documentsOf('law', 'Contract Law', <StoredPage>[
        _writtenPage(<String>['Offer', 'acceptance', 'consideration']),
      ]),
    ];

    test('a diagram label finds the diagram, and nothing unrelated', () {
      final List<StudyHit> hits = StudyRetriever.retrieve(
        documents,
        'What does the ribosome do?',
      );
      expect(hits.first.chunk.noteId, 'bio');
      expect(hits.first.chunk.pageIndex, 1);
      expect(
        hits.map((StudyHit hit) => hit.chunk.kind),
        contains(StudyChunkKind.diagram),
      );
      expect(
        hits.map((StudyHit hit) => hit.chunk.noteId),
        isNot(contains('law')),
      );
      expect(
        hits.where((StudyHit hit) => hit.chunk.pageIndex == 0),
        isEmpty,
        reason: 'The other page of the same note says nothing about it.',
      );
    });

    test('a visual word brings up drawings, not pages of words', () {
      final List<StudyHit> hits = StudyRetriever.retrieve(
        documents,
        'show me the diagram',
      );
      expect(hits, isNotEmpty);
      for (final StudyHit hit in hits) {
        expect(hit.chunk.kind, isNot(StudyChunkKind.text));
        expect(hit.chunk.noteId, 'bio');
      }
    });

    test('words inside an SVG find it', () {
      final List<StudyHit> hits = StudyRetriever.retrieve(
        documents,
        'krebs cycle energy pathway',
      );
      expect(hits.first.chunk.kind, StudyChunkKind.mixed);
      expect(hits.first.chunk.imageIds, <String>['svg-1']);
    });

    test(
      'a reading the recognizer only offered as second best still finds',
      () {
        final StoredPage page = StoredPage(
          setup: const PageSetup(),
          strokes: <Stroke>[_line(60, 100, 200, 100)],
          recognizedWords: <StoredRecognizedInkWord>[
            _word('rnitosis', <int>[0], alternatives: <String>['mitosis']),
          ],
        );
        final List<StudyHit> hits = StudyRetriever.retrieve(
          <StudySearchDocument>[
            ..._documentsOf('messy', 'Scrawl', <StoredPage>[page]),
            ...documents,
          ],
          'mitosis',
        );
        expect(hits.map((StudyHit hit) => hit.chunk.noteId), contains('messy'));
      },
    );

    test('a misspelled word still finds by its letters', () {
      final List<StudyHit> hits = StudyRetriever.retrieve(documents, 'ribosme');
      expect(hits.first.chunk.anchors, contains('ribosome'));
    });

    test('words in Chinese can be found', () {
      final StoredPage page = StoredPage(
        setup: const PageSetup(),
        strokes: <Stroke>[_line(60, 100, 200, 100)],
        recognizedWords: <StoredRecognizedInkWord>[
          _word('細胞分裂的過程', <int>[0]),
        ],
      );
      final List<StudyHit> hits = StudyRetriever.retrieve(<StudySearchDocument>[
        ..._documentsOf('zh', '生物筆記', <StoredPage>[page]),
        ...documents,
      ], '細胞分裂');
      expect(hits.first.chunk.noteId, 'zh');
    });

    test('an overview takes from each note in turn, at most five', () {
      final List<StudyHit> hits = StudyRetriever.retrieve(
        documents,
        'Summarize key concepts',
        mode: StudyQueryMode.overview,
      );
      expect(hits.length, lessThanOrEqualTo(StudyRetriever.maxChunks));
      expect(hits.map((StudyHit hit) => hit.chunk.noteId).toSet(), <String>{
        'bio',
        'law',
      });
    });
  });

  group('Packing what was found', () {
    test('text chunks draw nothing, and cost no picture', () async {
      final _CountingRenderer renderer = _CountingRenderer();
      final List<StudyHit> hits = StudyRetriever.retrieve(
        _documentsOf('bio', 'Cell Biology', <StoredPage>[
          _writtenPage(<String>['Mitosis', 'phases', 'prophase']),
        ]),
        'mitosis phases',
      );
      final StudyPayload payload = await const StudyContextAssembler().assemble(
        hits,
        renderer: renderer,
      );
      expect(renderer.rendered, isEmpty);
      expect(payload.panelCount, 0);
      expect(payload.imagePng, StudyContextAssembler.placeholderPng);
      expect(
        payload.contextText,
        contains('[Source N1:P1:C1 | Note: "Cell Biology", Page 1]'),
      );
      expect(payload.contextText, contains('L1: Mitosis'));
      expect(payload.contextText, isNot(contains('<svg')));
      expect(payload.contextText, isNot(contains('base64')));
    });

    test(
      'the placeholder image is a real 1x1 PNG, as the service asks',
      () async {
        final Uint8List png = StudyContextAssembler.placeholderPng;
        expect(png.sublist(0, 8), <int>[137, 80, 78, 71, 13, 10, 26, 10]);
        final ByteData header = ByteData.sublistView(png, 16, 24);
        expect(header.getUint32(0), 1);
        expect(header.getUint32(4), 1);
      },
    );

    test('at most two chunks are drawn, as one image', () async {
      final _CountingRenderer renderer = _CountingRenderer();
      final List<StudyHit> hits = <StudyHit>[
        for (int i = 0; i < 4; i++)
          StudyHit(
            _document(
              StudyChunk(
                noteId: 'bio',
                pageIndex: 0,
                chunkIndex: i + 1,
                kind: StudyChunkKind.diagram,
                logicalBounds: Rect.fromLTWH(0, i * 200.0, 100, 100),
              ),
              'Cell Biology',
            ),
            4.0 - i,
          ),
      ];
      final StudyPayload payload = await const StudyContextAssembler().assemble(
        hits,
        renderer: renderer,
      );
      expect(renderer.rendered.map((StudyChunk c) => c.chunkIndex), <int>[
        1,
        2,
      ]);
      expect(renderer.combined, 1);
      expect(payload.panelCount, 2);
      expect(payload.imagePng, <int>[99]);
      expect(payload.contextText, contains('Picture panel A'));
      expect(payload.contextText, contains('Picture panel B'));
      expect(payload.contextText, isNot(contains('Picture panel C')));
    });

    test('the words stay within their token budget', () async {
      final String long = List<String>.filled(400, 'mitochondrion').join(' ');
      final List<StudyHit> hits = <StudyHit>[
        for (int i = 0; i < 5; i++)
          StudyHit(
            _document(
              StudyChunk(
                noteId: 'bio',
                pageIndex: i,
                chunkIndex: 1,
                kind: StudyChunkKind.text,
                logicalBounds: const Rect.fromLTWH(0, 0, 100, 100),
                lines: <StudyChunkLine>[StudyChunkLine(1, 2, long)],
              ),
              'Cell Biology',
            ),
            1,
          ),
      ];
      final StudyPayload payload = await const StudyContextAssembler().assemble(
        hits,
      );
      expect(payload.estimatedTextTokens, lessThanOrEqualTo(3000));
      expect(
        StudyContextAssembler.estimateTokens(payload.contextText),
        lessThanOrEqualTo(3001),
      );
    });
  });

  group('Keeping chunks', () {
    test('a note is read once for each revision', () async {
      final InMemoryNoteRepository repository = InMemoryNoteRepository();
      addTearDown(repository.dispose);
      final NoteEntry note = await _storeNote(repository, 'Bio', <StoredPage>[
        _writtenPage(<String>['one']),
      ]);
      final StudyRagIndex index = StudyRagIndex(repository: repository);
      await index.chunksFor(note);
      await index.chunksFor(note);
      expect(index.reads, 1);

      final NoteEntry saved = await repository.saveNote(
        note.id,
        NoteContent(<StoredPage>[
          _writtenPage(<String>['one', 'two']),
        ]),
      );
      expect(saved.revision, greaterThan(note.revision));
      final List<StudyChunk> chunks = await index.chunksFor(saved);
      expect(index.reads, 2);
      expect(chunks.single.handwriting, 'one two');
    });

    test('kept on disk, a new index does not read the note again', () async {
      final Directory directory = await Directory.systemTemp.createTemp(
        'study',
      );
      addTearDown(() => directory.delete(recursive: true));
      final InMemoryNoteRepository repository = InMemoryNoteRepository();
      addTearDown(repository.dispose);
      final NoteEntry note = await _storeNote(repository, 'Bio', <StoredPage>[
        _mixedPage(),
      ]);
      final FileStudyChunkCache cache = FileStudyChunkCache(directory);
      final StudyRagIndex first = StudyRagIndex(
        repository: repository,
        diskCache: cache,
      );
      final List<StudyChunk> worked = await first.chunksFor(note);
      await cache.write(note.id, note.revision, worked);

      final StudyRagIndex second = StudyRagIndex(
        repository: repository,
        diskCache: cache,
      );
      final List<StudyChunk> read = await second.chunksFor(note);
      expect(second.reads, 0);
      expect(read.length, worked.length);

      await cache.retain(const <String>{});
      expect(await cache.read(note.id, note.revision), isNull);
    });

    test('a note of 8 KB or more is chunked on another isolate', () async {
      final InMemoryNoteRepository repository = InMemoryNoteRepository();
      addTearDown(repository.dispose);
      final List<String> words = List<String>.generate(
        200,
        (int i) => 'word$i',
      );
      final StoredPage page = _writtenPage(words);
      final StudyNoteData data = StudyNoteData.of(
        'n',
        NoteContent(<StoredPage>[page]),
      );
      expect(
        data.estimatedBytes,
        greaterThanOrEqualTo(StudyRagIndex.offMainBytes),
      );
      final NoteEntry note = await _storeNote(repository, 'Long', <StoredPage>[
        page,
      ]);
      final List<StudyChunk> chunks = await StudyRagIndex(
        repository: repository,
      ).chunksFor(note);
      expect(
        chunks.expand((StudyChunk c) => c.strokeIndices).length,
        words.length,
      );
    });

    test('the desk survives in its file, written whole', () async {
      final Directory directory = await Directory.systemTemp.createTemp('desk');
      addTearDown(() => directory.delete(recursive: true));
      final File file = File('${directory.path}/study_desk.json');
      final FileStudyDeskStore store = FileStudyDeskStore(file);
      await store.write(
        StudyDeskState(
          sources: const <StudySourceItem>[
            StudySourceItem(noteId: 'a'),
            StudySourceItem(noteId: 'b', enabled: false),
          ],
          sessions: <StudySession>[
            StudySession(
              id: 's',
              created: _now,
              messages: const <StudyMessage>[
                StudyMessage.user('Why?'),
                StudyMessage.answer(
                  'Because.',
                  links: <StudyParagraphLinks>[
                    StudyParagraphLinks(
                      paragraph: 1,
                      citations: <StudyCitation>[
                        StudyCitation(
                          noteId: 'a',
                          pageIndex: 1,
                          revision: 3,
                          strokeKeys: <String>['x'],
                          strokeIndices: <int>[7],
                          rings: <Rect>[Rect.fromLTRB(1, 2, 3, 4)],
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
          currentSessionId: 's',
        ),
      );
      final StudyDeskState back = (await FileStudyDeskStore(file).read())!;
      expect(back.sources.last.enabled, isFalse);
      expect(back.currentSessionId, 's');
      final StudyCitation citation = back.sessions.single.messages.last
          .citationsOf(1)
          .single;
      expect(citation.strokeKeys, <String>['x']);
      expect(citation.rings.single, const Rect.fromLTRB(1, 2, 3, 4));
      expect(await File('${file.path}.tmp').exists(), isFalse);
    });

    test('a damaged desk starts over rather than failing', () async {
      final Directory directory = await Directory.systemTemp.createTemp('desk');
      addTearDown(() => directory.delete(recursive: true));
      final File file = File('${directory.path}/study_desk.json')
        ..writeAsStringSync('{not json');
      expect(await FileStudyDeskStore(file).read(), isNull);
    });
  });

  group('Multi-note citations', () {
    test('every form is read, and none is left in the words', () {
      const String answer =
          'First [[N1:P2:L4-L7]] and [[N1:P2:L9,L12-L13]].\n\n'
          'Second [[N2:P1:C3]].\n\n'
          'Third [[N1:P2:C 100 200 300 400]] [[N1:P2:C3 1 2 3 4]] [[N3:P4]].\n\n'
          '[[N9:P9:C9]]';
      final List<String> paragraphs = parseAiAnswer(answer);
      expect(paragraphs, <String>['First and.', 'Second.', 'Third.']);

      final List<AiNoteCitation> first = parseAiNoteCitations(
        'x [[N1:P2:L4-L7]] [[N1:P2:L9,L12-L13]]',
      );
      expect(first[0].note, 1);
      expect(first[0].page, 2);
      expect(first[0].ranges, const <AiLineRange>[AiLineRange(4, 7)]);
      expect(first[1].ranges, const <AiLineRange>[
        AiLineRange(9, 9),
        AiLineRange(12, 13),
      ]);

      final AiNoteCitation chunk = parseAiNoteCitations('[[N2:P1:C3]]').single;
      expect(chunk.chunk, 3);
      expect(chunk.box, isNull);

      final AiNoteCitation box = parseAiNoteCitations(
        '[[N1:P2:C 100 200 300 400]]',
      ).single;
      expect(box.chunk, isNull);
      expect(box.box!.top, 100);
      expect(box.box!.right, 400);

      final AiNoteCitation onChunk = parseAiNoteCitations(
        '[[N1:P2:C3 1 2 3 4]]',
      ).single;
      expect(onChunk.chunk, 3);
      expect(onChunk.box!.left, 2);

      final AiNoteCitation page = parseAiNoteCitations('[[N3:P4]]').single;
      expect(page.note, 3);
      expect(page.ranges, isEmpty);
    });

    test('the citations a single-note chat knows still work', () {
      expect(stripAiCitations('a [[L1-L2]] b [[C 1 2 3 4]]'), 'a b');
    });

    test('a block of nothing but citations belongs to the one before it', () {
      final List<AiAnswerBlock> blocks = parseAiAnswerBlocks(
        'Words.\n\n[[N1:P1:L1]]\n\nMore.',
      );
      expect(blocks.length, 2);
      expect(parseAiNoteCitations(blocks[0].source).single.page, 1);
      expect(parseAiNoteCitations(blocks[1].source), isEmpty);
    });

    test('a citation half written in a stream does not show', () {
      expect(stripPartialAiCitations('Some words [[N1:P'), 'Some words');
      expect(stripPartialAiCitations('Some words ['), 'Some words');
      expect(stripPartialAiCitations('Done [[N1:P2:L1]] next'), 'Done next');
    });

    group('resolve', () {
      final StoredPage first = _writtenPage(<String>['a'], prefix: 'p1-');
      final StoredPage second = _writtenPage(
        List<String>.generate(10, (int i) => 'w$i'),
        prefix: 'p2-',
      );
      StudyCitationResolver resolver({StudySourceMap? map}) =>
          StudyCitationResolver(
            map:
                map ??
                StudySourceMap(
                  noteIds: const <int, String>{1: 'bio'},
                  chunks: const <StudyChunk>[],
                  crops: const <StudyChunk, Rect>{},
                ),
            pageOf: (String note, int page) => note != 'bio'
                ? null
                : (page == 0 ? first : (page == 1 ? second : null)),
            revisionOf: (String note) => 5,
          );

      test('to the exact strokes and rings of note 1, page 2', () {
        final List<StudyParagraphLinks> links = resolver().resolve(
          'Words [[N1:P2:L4-L7]] [[N1:P2:C 100 200 300 400]]',
        );
        final StudyCitation citation = links.single.citations.single;
        expect(citation.noteId, 'bio');
        expect(citation.pageIndex, 1);
        expect(citation.strokeKeys, <String>[
          for (final int i in <int>[3, 4, 5, 6]) aiStrokeKey(second.strokes[i]),
        ]);
        expect(citation.strokesOn(second, 5), <Stroke>[
          second.strokes[3],
          second.strokes[4],
          second.strokes[5],
          second.strokes[6],
        ]);
        // A4: 794 wide, 1123 high. 100-300 of 1000 down, 200-400 across.
        final Rect ring = citation.rings.single;
        expect(ring.left, closeTo(794 * 0.2, 0.001));
        expect(ring.top, closeTo(1123 * 0.1, 0.001));
        expect(ring.right, closeTo(794 * 0.4, 0.001));
        expect(ring.bottom, closeTo(1123 * 0.3, 0.001));
      });

      test('a box is measured on the picture that was sent', () {
        const StudyChunk chunk = StudyChunk(
          noteId: 'bio',
          pageIndex: 1,
          chunkIndex: 3,
          kind: StudyChunkKind.diagram,
          logicalBounds: Rect.fromLTWH(100, 100, 100, 100),
        );
        final StudySourceMap map = StudySourceMap(
          noteIds: const <int, String>{1: 'bio'},
          chunks: const <StudyChunk>[chunk],
          crops: <StudyChunk, Rect>{
            chunk: const Rect.fromLTWH(90, 90, 200, 200),
          },
        );
        for (final String tag in <String>[
          '[[N1:P2:C3 0 0 500 500]]',
          '[[N1:P2:C 0 0 500 500]]',
        ]) {
          expect(
            resolver(map: map).resolve('x $tag').single.citations.single.rings,
            <Rect>[const Rect.fromLTRB(90, 90, 190, 190)],
          );
        }
      });

      test('numbers that name nothing tie nothing', () {
        expect(resolver().resolve('x [[N7:P1:L1]]'), isEmpty);
        expect(resolver().resolve('x [[N1:P9:L1]]'), isEmpty);
        final StudyCitation clipped = resolver()
            .resolve('x [[N1:P2:L9-L999999999]]')
            .single
            .citations
            .single;
        expect(clipped.strokeIndices, <int>[8, 9]);
      });

      test('each page cited makes one chip', () {
        final List<StudyParagraphLinks> links = resolver().resolve(
          'x [[N1:P1:L1]] [[N1:P2:L1]] [[N1:P2:L2]]\n\ny [[N1:P2:L3]]',
        );
        expect(links.length, 2);
        expect(links[0].citations.length, 2);
        expect(links[0].citations[1].strokeIndices, <int>[0, 1]);
        expect(links[1].paragraph, 2);
      });

      test('strokes left alone are found by shape; erased ones are gone', () {
        final StudyCitation citation = resolver()
            .resolve('x [[N1:P2:L1-L3]]')
            .single
            .citations
            .single;
        final StoredPage edited = StoredPage(
          setup: const PageSetup(),
          strokes: <Stroke>[
            _line(0, 0, 10, 10),
            second.strokes[2],
            second.strokes[0],
          ],
        );
        expect(citation.strokesOn(edited, 6), <Stroke>[
          second.strokes[2],
          second.strokes[0],
        ]);
      });

      test('a stroke keeps its key through saving and reading', () async {
        final InMemoryNoteRepository repository = InMemoryNoteRepository();
        addTearDown(repository.dispose);
        final NoteEntry note = await _storeNote(repository, 'N', <StoredPage>[
          second,
        ]);
        final StoredPage read = (await repository.loadNote(
          note.id,
        )).pages.single;
        // Most strokes are given a new id each time they are read.
        expect(read.strokes[3].id, isNot(second.strokes[3].id));
        expect(aiStrokeKey(read.strokes[3]), aiStrokeKey(second.strokes[3]));
        expect(
          aiStrokeKey(second.strokes[3]),
          isNot(aiStrokeKey(second.strokes[4])),
        );
      });

      test('a citation with no key found is marked by place, if unchanged', () {
        const StudyCitation citation = StudyCitation(
          noteId: 'bio',
          pageIndex: 1,
          revision: 5,
          strokeKeys: <String>['gone'],
          strokeIndices: <int>[1],
        );
        expect(citation.strokesOn(second, 5), <Stroke>[second.strokes[1]]);
        expect(citation.strokesOn(second, 6), isEmpty);
      });
    });
  });

  test('the view centers what is cited, 24 points clear of the edges', () {
    const Size view = Size(500, 800);
    const Rect marked = Rect.fromLTWH(100, 200, 200, 100);
    final Matrix4 matrix = StudyCitationPreview.focusOn(
      page: const Size(794, 1123),
      view: view,
      marked: marked,
    );
    final double scale = matrix.getMaxScaleOnAxis();
    expect(scale, closeTo((500 - 48) / 200, 0.001));
    final Offset center = MatrixUtils.transformPoint(matrix, marked.center);
    expect(center.dx, closeTo(view.width / 2, 0.001));
    expect(center.dy, closeTo(view.height / 2, 0.001));
    final Rect shown = MatrixUtils.transformRect(matrix, marked);
    expect(shown.left, greaterThanOrEqualTo(24 - 0.001));
    expect(shown.right, lessThanOrEqualTo(view.width - 24 + 0.001));
  });

  group('The screen', () {
    late InMemoryNoteRepository repository;
    late FakeAiClient client;
    late NoteEntry note;

    // Made inside each test, in its fake-async zone: futures of a repository made
    // outside it complete where no pump reaches them.
    Future<void> prepare() async {
      repository = InMemoryNoteRepository(clock: () => _now);
      client = FakeAiClient();
      note = await _storeNote(repository, 'Cell Biology', <StoredPage>[
        _writtenPage(<String>['Introduction'], prefix: 'one-'),
        _writtenPage(
          List<String>.generate(8, (int i) => 'mitosis$i'),
          prefix: 'two-',
        ),
      ]);
      addTearDown(repository.dispose);
    }

    void testDesk(String description, WidgetTesterCallback body) {
      testWidgets(description, (WidgetTester tester) async {
        await prepare();
        await body(tester);
      });
    }

    Future<void> pumpLibrary(
      WidgetTester tester, {
      TestViewport viewport = TestViewport.tabletLandscape,
    }) async {
      setViewportSize(tester, viewport.size);
      await tester.pumpWidget(
        GreatnoteApp(
          themeMode: ThemeMode.light,
          home: LibraryScreen(
            repository: repository,
            clock: () => _now,
            aiClient: client,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> openDeskWithNote(WidgetTester tester) async {
      await tester.tap(
        find.byKey(const ValueKey<String>('sidebar-study-desk')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(StudyDeskScreen), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('study-empty-add-sources')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey<String>('study-pick-note-${note.id}')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('study-source-done')));
      await tester.pumpAndSettle();
    }

    /// Lets a question reach the client, with the loader running, so without
    /// waiting for everything to settle.
    Future<void> ask(WidgetTester tester, String question) async {
      await tester.enterText(
        find.byKey(const ValueKey<String>('study-composer')),
        question,
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    Future<void> answer(WidgetTester tester, String text) async {
      client.answer(text);
      await tester.pumpAndSettle();
    }

    testDesk('sits above the folders, with its count', (
      WidgetTester tester,
    ) async {
      await pumpLibrary(tester);
      final Finder row = find.byKey(
        const ValueKey<String>('sidebar-study-desk'),
      );
      expect(row, findsOneWidget);
      expect(find.text(StudyDesk.title), findsOneWidget);
      expect(
        tester.getTopLeft(row).dy,
        lessThan(tester.getTopLeft(find.text('Folders')).dy),
      );
      expect(
        tester.getTopLeft(row).dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const ValueKey<String>('sidebar-library')))
              .dy,
        ),
      );
      await openDeskWithNote(tester);
      await tester.tap(find.byKey(const ValueKey<String>('study-leave')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: row, matching: find.text('1')),
        findsOneWidget,
      );
    });

    testDesk('its bar replaces the folder controls, and no new-note button', (
      WidgetTester tester,
    ) async {
      await pumpLibrary(tester);
      expect(find.byTooltip('Sort'), findsOneWidget);
      await openDeskWithNote(tester);
      expect(find.byTooltip('Sort'), findsNothing);
      expect(find.text('1 source'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('study-add-sources')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('study-new-chat')),
        findsOneWidget,
      );
      expect(find.byType(FloatingActionButton), findsNothing);
    });

    testDesk('it fills the window, and the way back returns to the folder', (
      WidgetTester tester,
    ) async {
      final Folder folder = await repository.createFolder('Biology');
      await _storeNote(repository, 'Inside', <StoredPage>[
        _writtenPage(<String>['x']),
      ], folderId: folder.id);
      await pumpLibrary(tester);
      await tester.tap(
        find.byKey(ValueKey<String>('sidebar-folder-${folder.id}')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Inside'), findsOneWidget);

      await openDeskWithNote(tester);
      // Nothing of the library is left in front: no folders, no search.
      expect(
        find.byKey(const ValueKey<String>('library-sidebar')),
        findsNothing,
      );
      expect(find.byType(TextField), findsOneWidget, reason: 'The composer.');
      final Size window = TestViewport.tabletLandscape.size;
      expect(tester.getSize(find.byType(StudyDeskScreen)).width, window.width);
      expect(tester.getTopLeft(find.byType(StudyDeskScreen)).dx, 0);

      await tester.tap(find.byKey(const ValueKey<String>('study-leave')));
      await tester.pumpAndSettle();
      expect(find.byType(StudyDeskScreen), findsNothing);
      expect(find.text('Inside'), findsOneWidget, reason: 'Where it was left.');
      expect(
        find.byKey(const ValueKey<String>('library-sidebar')),
        findsOneWidget,
      );
    });

    testDesk('the chat keeps a reading width, in the middle of the window', (
      WidgetTester tester,
    ) async {
      await pumpLibrary(tester);
      await openDeskWithNote(tester);
      final Rect chat = tester.getRect(
        find.byKey(const ValueKey<String>('study-chat-column')),
      );
      expect(chat.width, StudyDeskScreen.readingWidth);
      expect(chat.center.dx, TestViewport.tabletLandscape.size.width / 2);
    });

    testDesk('the system bars go for the desk, and return with the library', (
      WidgetTester tester,
    ) async {
      final List<String> modes = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
            modes.add(call.arguments as String);
          }
          // Manual mode, as in a note, is sent as the overlays it keeps.
          if (call.method == 'SystemChrome.setEnabledSystemUIOverlays') {
            modes.add('manual');
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
      const String away = 'SystemUiMode.immersiveSticky';
      await pumpLibrary(tester);
      expect(modes, isNot(contains(away)));

      await openDeskWithNote(tester);
      expect(modes.last, away);

      // Through a note and back, they go again.
      await ask(tester, 'Explain mitosis3');
      await answer(tester, 'In phases. [[N1:P2:L4-L7]]');
      await tester.tap(find.text('Cell Biology · p.2'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('study-edit-note')));
      await tester.pumpAndSettle();
      expect(modes.last, isNot(away));
      await tester.tap(find.byTooltip('Back to ${StudyDesk.title}'));
      await tester.pumpAndSettle();
      expect(modes.last, away);

      await tester.tap(find.byKey(const ValueKey<String>('study-leave')));
      await tester.pumpAndSettle();
      expect(modes.last, 'SystemUiMode.edgeToEdge');
    });

    testDesk('the keyboard lifts the composer clear of itself on a phone', (
      WidgetTester tester,
    ) async {
      await pumpLibrary(tester, viewport: TestViewport.compact);
      await tester.tap(find.byTooltip('Folders'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('sidebar-study-desk')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('study-empty-add-sources')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey<String>('study-pick-note-${note.id}')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('study-source-done')));
      await tester.pumpAndSettle();

      const double keyboard = 300;
      tester.view.viewInsets = const FakeViewPadding(bottom: keyboard);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(
        tester
            .getBottomLeft(find.byKey(const ValueKey<String>('study-composer')))
            .dy,
        lessThanOrEqualTo(TestViewport.compact.size.height - keyboard),
      );
    });

    testDesk('a question sends only what it retrieved, with no picture', (
      WidgetTester tester,
    ) async {
      await pumpLibrary(tester);
      await openDeskWithNote(tester);
      await ask(tester, 'What is mitosis3?');

      final AiRequest request = client.requests.single;
      expect(request.imagePng, StudyContextAssembler.placeholderPng);
      expect(request.selectionSvg, isNull);
      expect(request.notationEnabled, isFalse);
      expect(request.messages.single.text, contains('[Source N1:P2:C'));
      expect(request.messages.single.text, contains('mitosis3'));
      expect(request.messages.single.text, isNot(contains('Introduction')));
      expect(request.messages.single.label, 'What is mitosis3?');

      await answer(tester, 'It is a phase.');
      expect(find.textContaining('It is a phase.'), findsOneWidget);

      // Later turns send the words said, never what was retrieved for them.
      await ask(tester, 'Tell me about Introduction please');
      final List<AiMessage> sent = client.requests.last.messages;
      expect(sent.length, 3);
      expect(sent[0].text, 'What is mitosis3?');
      expect(sent[1].text, 'It is a phase.');
      expect(sent[2].text, contains('Introduction'));
      await answer(tester, 'Done.');
    });

    testDesk('with nothing to read, the question goes alone', (
      WidgetTester tester,
    ) async {
      final NoteEntry empty = await repository.createNote(title: 'Blank');
      await pumpLibrary(tester);
      await tester.tap(
        find.byKey(const ValueKey<String>('sidebar-study-desk')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('study-empty-add-sources')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey<String>('study-pick-note-${empty.id}')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('study-source-done')));
      await tester.pumpAndSettle();
      await ask(tester, 'What is entropy?');
      expect(client.requests.single.messages.single.text, 'What is entropy?');
      await answer(tester, 'A measure of disorder.');
    });

    testDesk('a failed turn is not sent as history, and can be tried again', (
      WidgetTester tester,
    ) async {
      await pumpLibrary(tester);
      await openDeskWithNote(tester);
      await ask(tester, 'First question about mitosis1');
      client.fail(AiFailureKind.network);
      await tester.pumpAndSettle();
      expect(find.text('Try again'), findsOneWidget);

      await tester.tap(find.text('Try again'));
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(client.requests.length, 2);
      expect(client.requests.last.messages.length, 1);
      await answer(tester, 'Answered.');

      await ask(tester, 'A second question about mitosis2');
      expect(client.requests.last.messages.length, 3);
      await answer(tester, 'Also answered.');
    });

    testDesk('a note left unticked is not asked about, but stays on the desk', (
      WidgetTester tester,
    ) async {
      await _storeNote(repository, 'Contract Law', <StoredPage>[
        _writtenPage(<String>['mitosis offer']),
      ]);
      await pumpLibrary(tester);
      await openDeskWithNote(tester);
      await tester.tap(
        find.descendant(
          of: find.byKey(ValueKey<String>('study-source-${note.id}')),
          matching: find.byType(Checkbox),
        ),
      );
      await tester.pump();
      expect(find.text('0 sources'), findsOneWidget);
      expect(
        find.byKey(ValueKey<String>('study-source-${note.id}')),
        findsOneWidget,
      );
      // With nothing in context, nothing can be asked.
      await tester.enterText(
        find.byKey(const ValueKey<String>('study-composer')),
        'mitosis',
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Send'), warnIfMissed: false);
      await tester.pump();
      expect(client.requests, isEmpty);
    });

    testDesk('Enter sends; Shift with Enter does not', (
      WidgetTester tester,
    ) async {
      await pumpLibrary(tester);
      await openDeskWithNote(tester);
      await tester.tap(find.byKey(const ValueKey<String>('study-composer')));
      await tester.enterText(
        find.byKey(const ValueKey<String>('study-composer')),
        'About mitosis1',
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.pump();
      expect(client.requests, isEmpty);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(client.requests.length, 1);
      await answer(tester, 'Yes.');
    });

    testDesk('starters ask, and the diagrams one looks for diagrams', (
      WidgetTester tester,
    ) async {
      await pumpLibrary(tester);
      await openDeskWithNote(tester);
      for (final String label in <String>[
        'Summarize key concepts',
        'Quiz me on these notes',
        'Explain the diagrams',
        'Find connections & gaps',
      ]) {
        expect(find.text(label, skipOffstage: false), findsOneWidget);
      }
      await tester.tap(find.text('Summarize key concepts'));
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final AiMessage sent = client.requests.single.messages.single;
      expect(sent.label, 'Summarize key concepts');
      expect(sent.text, contains('[Source N1:'));
      await answer(tester, 'A summary.');
      expect(find.text('Summarize key concepts'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('study-starters')),
        findsNothing,
      );
    });

    Future<void> dragToDesk(WidgetTester tester, Finder item) async {
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(item),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(
        tester.getCenter(
          find.byKey(const ValueKey<String>('sidebar-study-desk')),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pump();
    }

    testDesk('a note dropped on the row joins it, and is announced', (
      WidgetTester tester,
    ) async {
      await pumpLibrary(tester);
      await dragToDesk(tester, find.byKey(ValueKey<String>('note-${note.id}')));
      expect(
        find.text('Added "Cell Biology" to the ${StudyDesk.title}'),
        findsOneWidget,
      );
      final Finder row = find.byKey(
        const ValueKey<String>('sidebar-study-desk'),
      );
      expect(
        find.descendant(of: row, matching: find.text('1')),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
    });

    testDesk('a folder dropped on the row brings every note below it', (
      WidgetTester tester,
    ) async {
      final Folder folder = await repository.createFolder('Biology');
      final Folder inner = await repository.createFolder(
        'Inner',
        parentId: folder.id,
      );
      await _storeNote(repository, 'A', <StoredPage>[
        _writtenPage(<String>['x']),
      ], folderId: folder.id);
      await _storeNote(repository, 'B', <StoredPage>[
        _writtenPage(<String>['y']),
      ], folderId: inner.id);
      await pumpLibrary(tester);
      await dragToDesk(
        tester,
        find.byKey(ValueKey<String>('folder-${folder.id}')),
      );
      expect(
        find.text('Added 2 notes from "Biology" to the ${StudyDesk.title}'),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      await dragToDesk(
        tester,
        find.byKey(ValueKey<String>('folder-${folder.id}')),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('"Biology" is already on the ${StudyDesk.title}'),
        findsOneWidget,
      );
    });

    testDesk('a chip opens the page, marked, beside the chat where it fits', (
      WidgetTester tester,
    ) async {
      await pumpLibrary(tester);
      await openDeskWithNote(tester);
      await ask(tester, 'Explain mitosis3');
      await answer(
        tester,
        'Mitosis proceeds in phases. [[N1:P2:L4-L7]] '
        '[[N1:P2:C 100 200 300 400]]',
      );

      // No tag shows; a chip does.
      expect(find.textContaining('[['), findsNothing);
      expect(find.textContaining('L4'), findsNothing);
      final Finder chip = find.text('Cell Biology · p.2');
      expect(chip, findsOneWidget);

      await tester.tap(chip);
      await tester.pumpAndSettle();

      final Finder pane = find.byKey(
        const ValueKey<String>('study-inspection-pane'),
      );
      expect(pane, findsOneWidget);
      expect(find.text('Page 2 of 2'), findsOneWidget);
      expect(
        find.descendant(of: pane, matching: find.text('Cell Biology')),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(pane).dx,
        greaterThan(tester.getTopLeft(find.byType(StudyDeskScreen)).dx),
        reason: 'Side by side with the chat.',
      );

      final AiCitationMarks marks = tester.widget(
        find.descendant(of: pane, matching: find.byType(AiCitationMarks)),
      );
      expect(_rows(marks.strokes), <int>[3, 4, 5, 6]);
      expect(marks.circles.length, 1);
      expect(
        find.descendant(
          of: pane,
          matching: find.byKey(
            const ValueKey<String>('ai-citation-highlight-layer'),
          ),
        ),
        findsOneWidget,
      );
    });

    testDesk('over the chat on a phone, with a way back', (
      WidgetTester tester,
    ) async {
      await pumpLibrary(tester, viewport: TestViewport.compact);
      await tester.tap(find.byTooltip('Folders'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('sidebar-study-desk')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('study-empty-add-sources')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey<String>('study-pick-note-${note.id}')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('study-source-done')));
      await tester.pumpAndSettle();

      await ask(tester, 'Explain mitosis3');
      await answer(tester, 'In phases. [[N1:P2:L4-L7]]');

      // The bar still names the desk, with little room to do it in.
      final Finder name = find.text(StudyDesk.title);
      expect(name, findsWidgets);
      expect(tester.getSize(name.first).width, greaterThan(60));

      // Reading on, the pane does not cover the chat by itself.
      final Finder pane = find.byKey(
        const ValueKey<String>('study-inspection-pane'),
      );
      expect(pane, findsNothing);

      await tester.tap(find.text('Cell Biology · p.2'));
      await tester.pumpAndSettle();
      expect(pane, findsOneWidget);
      expect(tester.getSize(pane).width, TestViewport.compact.size.width);

      await tester.tap(
        find.byKey(const ValueKey<String>('study-inspection-close')),
      );
      await tester.pumpAndSettle();
      expect(pane, findsNothing);
      expect(find.textContaining('In phases.'), findsOneWidget);
    });

    testDesk('Edit opens the cited page; Back returns to the desk, intact', (
      WidgetTester tester,
    ) async {
      await pumpLibrary(tester);
      await openDeskWithNote(tester);
      await ask(tester, 'Explain mitosis3');
      await answer(tester, 'In phases. [[N1:P2:L4-L7]]');
      await tester.tap(find.text('Cell Biology · p.2'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey<String>('study-edit-note')));
      await tester.pumpAndSettle();

      final EditorScreen editor = tester.widget(find.byType(EditorScreen));
      expect(editor.document!.currentIndex, 1, reason: 'At the cited page.');
      final AiNoteMarksLayer layer = tester
          .widgetList<AiNoteMarksLayer>(find.byType(AiNoteMarksLayer))
          .firstWhere((AiNoteMarksLayer layer) => layer.pageIndex == 1);
      expect(_rows(layer.marks.value!.strokesIn(layer.page.strokes)), <int>[
        3,
        4,
        5,
        6,
      ]);
      expect(
        find.descendant(
          of: find.byWidget(layer),
          matching: find.byType(AiCitationMarks),
        ),
        findsOneWidget,
      );

      // Erase one cited stroke with the real eraser, then go back, which saves.
      expect(
        layer.page.startErase(
          pointer: 1,
          position: const InkVector(150, 200),
          settings: const EraserSettings(mode: EraserMode.stroke, size: 20),
        ),
        isTrue,
      );
      layer.page.endErase(1);
      await tester.pump();
      expect(_rows(layer.page.strokes), isNot(contains(4)));

      await tester.tap(find.byTooltip('Back to ${StudyDesk.title}'));
      await tester.pumpAndSettle();

      expect(find.byType(StudyDeskScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('In phases.'), findsOneWidget);
      expect(find.text('1 source'), findsOneWidget);
      expect(
        find.byTooltip('Sort'),
        findsNothing,
        reason: 'Not the folder grid.',
      );

      // What is shown follows the note as edited.
      final Finder pane = find.byKey(
        const ValueKey<String>('study-inspection-pane'),
      );
      expect(pane, findsOneWidget);
      final AiCitationMarks marks = tester.widget(
        find.descendant(of: pane, matching: find.byType(AiCitationMarks)),
      );
      expect(_rows(marks.strokes), <int>[3, 5, 6]);

      // And the next question reads only the note as edited.
      await ask(tester, 'What about mitosis5 and mitosis4?');
      final String excerpts = client.requests.last.messages.last.text
          .split('Question:')
          .first;
      expect(excerpts, contains('mitosis5'));
      expect(excerpts, isNot(contains('mitosis4')));
      // The stroke after the one erased is now the page's fifth.
      expect(excerpts, contains('L5: mitosis5'));
      await answer(tester, 'Fine.');
    });

    testDesk('the system back gesture from the editor goes to the desk too', (
      WidgetTester tester,
    ) async {
      await pumpLibrary(tester);
      await openDeskWithNote(tester);
      await ask(tester, 'Explain mitosis3');
      await answer(tester, 'In phases. [[N1:P2:L4-L7]]');
      await tester.tap(find.text('Cell Biology · p.2'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('study-edit-note')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EditorScreen>(find.byType(EditorScreen))
            .document!
            .currentIndex,
        1,
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(StudyDeskScreen), findsOneWidget);
      expect(find.textContaining('In phases.'), findsOneWidget);

      // Back again shuts the pane, then leaves the desk for the folder.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('study-inspection-pane')),
        findsNothing,
      );
      expect(find.byType(StudyDeskScreen), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(StudyDeskScreen), findsNothing);
    });

    testDesk('New Chat keeps the sources, and clears the transcript', (
      WidgetTester tester,
    ) async {
      await pumpLibrary(tester);
      await openDeskWithNote(tester);
      await ask(tester, 'Explain mitosis3');
      await answer(tester, 'In phases.');
      await tester.tap(find.byKey(const ValueKey<String>('study-new-chat')));
      await tester.pumpAndSettle();
      expect(find.textContaining('In phases.'), findsNothing);
      expect(find.text('1 source'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('study-starters')),
        findsOneWidget,
      );
      await ask(tester, 'Something about mitosis2');
      expect(client.requests.last.messages.length, 1);
      await answer(tester, 'Fresh.');
    });

    testDesk('text keeps its contrast on the desk in both themes', (
      WidgetTester tester,
    ) async {
      for (final ThemeMode mode in <ThemeMode>[
        ThemeMode.light,
        ThemeMode.dark,
      ]) {
        setViewportSize(tester, TestViewport.tabletLandscape.size);
        await tester.pumpWidget(
          GreatnoteApp(
            themeMode: mode,
            home: LibraryScreen(
              key: ValueKey<ThemeMode>(mode),
              repository: repository,
              clock: () => _now,
              aiClient: client,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey<String>('sidebar-study-desk')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        final AppColors colors = AppColors.of(
          tester.element(find.byType(StudyDeskScreen)),
        );
        Color over(Color top, Color under) => Color.alphaBlend(top, under);
        final Color page = over(colors.surface, colors.background);
        // A question's bubble, a citation chip, and a source card.
        expect(
          contrastRatio(colors.textPrimary, over(colors.selected, page)),
          greaterThanOrEqualTo(4.5),
        );
        // A source card left out of the questions, and a starter.
        expect(
          contrastRatio(colors.textPrimary, over(colors.surfaceMuted, page)),
          greaterThanOrEqualTo(4.5),
        );
        // The paragraph being read, marked as on the note.
        expect(
          contrastRatio(
            colors.textPrimary,
            over(aiCitationHighlightColor.withValues(alpha: 0.22), page),
          ),
          greaterThanOrEqualTo(4.5),
        );
        // Secondary text: folder names, hints, page numbers.
        expect(
          contrastRatio(colors.textSecondary, page),
          greaterThanOrEqualTo(3),
        );
      }
    });
  });

  testWidgets('a crop shows only its chunk, and two stack into one PNG', (
    WidgetTester tester,
  ) async {
    final InMemoryNoteRepository repository = InMemoryNoteRepository();
    addTearDown(repository.dispose);
    final StoredPage page = _mixedPage();
    final List<StudyChunk> chunks = StudyChunker.chunkPage(
      'n1',
      StudyPageData.of(page, 0),
    );
    final PageStudyChunkRenderer renderer = PageStudyChunkRenderer(
      repository: repository,
      loadPage: (String note, int index) async => page,
    );
    final StudyChunk diagram = _chunkHolding(chunks, 3);
    final StudyChunk mixed = _chunkHolding(chunks, 10);

    final (StudyCrop, StudyCrop, ui.Image, ui.Image) out = (await tester
        .runAsync(() async {
          final StudyCrop? first = await renderer.render(diagram);
          final StudyCrop? second = await renderer.render(mixed);
          Future<ui.Image> decode(Uint8List png) async =>
              (await (await ui.instantiateImageCodec(
                png,
              )).getNextFrame()).image;
          final Uint8List both = await renderer.combine(<StudyCrop>[
            first!,
            second!,
          ]);
          // What is sent when nothing needs a picture must decode as well.
          final ui.Image placeholder = await decode(
            StudyContextAssembler.placeholderPng,
          );
          expect(placeholder.width, 1);
          expect(placeholder.height, 1);
          placeholder.dispose();
          return (first, second, await decode(first.png), await decode(both));
        }))!;
    final (StudyCrop first, StudyCrop second, ui.Image one, ui.Image both) =
        out;
    addTearDown(one.dispose);
    addTearDown(both.dispose);

    // The crop is the chunk and its padding: never the page.
    expect(
      first.logicalBounds.overlaps(_chunkHolding(chunks, 0).logicalBounds),
      isFalse,
    );
    expect(first.logicalBounds.contains(diagram.logicalBounds.center), isTrue);
    expect(first.logicalBounds.height, lessThan(300));
    expect(one.width, lessThanOrEqualTo(1024));
    expect(both.height, greaterThan(one.height));
    expect(both.height, lessThanOrEqualTo(2048));

    // Its lines are the page's own: L4 is the page's fourth stroke.
    final String svg = first.svg!;
    expect(svg, contains('data-etonia-line="4"'));
    expect(svg, contains('data-etonia-line="9"'));
    expect(svg, isNot(contains('data-etonia-line="10"')));
    expect(svg, isNot(contains('base64')));
    // The SVG picture really is drawn into the mixed chunk's crop.
    expect(second.png, isNotEmpty);
    expect(second.logicalBounds.contains(const Offset(500, 860)), isTrue);
  });
}
