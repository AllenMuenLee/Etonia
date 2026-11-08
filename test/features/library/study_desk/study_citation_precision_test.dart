import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_citation.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/widgets/ai_citation_highlight.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/study_desk/study_citation_refiner.dart';
import 'package:greatnote/features/library/study_desk/study_desk_models.dart';
import 'package:greatnote/features/library/study_desk/study_rag_index.dart';

/// A chunk of typed lines, one row of 20pt each from the top of a page, so that
/// a line's place says which line it is.
StudyChunk _typedChunk(List<String> lines, {int index = 1}) {
  return StudyChunk(
    noteId: 'n',
    pageIndex: 0,
    chunkIndex: index,
    kind: StudyChunkKind.text,
    logicalBounds: Rect.fromLTWH(40, 40, 400, lines.length * 20.0),
    lines: <StudyChunkLine>[
      for (int i = 0; i < lines.length; i++)
        StudyChunkLine(
          0,
          0,
          lines[i],
          bounds: Rect.fromLTWH(40, 40 + i * 20.0, 400, 18),
        ),
    ],
  );
}

const List<String> _cellNotes = <String>[
  'Mitochondria produce ATP through oxidative phosphorylation.',
  'The inner membrane folds into cristae, which add surface area.',
  'Ribosomes assemble proteins from amino acids.',
  'The Golgi apparatus packages proteins for export.',
  'Lysosomes digest worn out organelles with enzymes.',
];

StudySourceMap _map(List<StudyChunk> chunks) => StudySourceMap(
  noteIds: <int, String>{1: 'n'},
  chunks: chunks,
  crops: const <StudyChunk, Rect>{},
);

StudyCitationResolver _resolver(List<StudyChunk> chunks) =>
    StudyCitationResolver(
      map: _map(chunks),
      pageOf: (String note, int page) =>
          StoredPage(setup: const PageSetup(), strokes: const []),
      revisionOf: (String note) => 1,
    );

void main() {
  group('typed line citations', () {
    test('T ranges are read with their chunk', () {
      final List<AiNoteCitation> cited = parseAiNoteCitations(
        '[[N1:P2:C3:T2-T4]] [[N1:P2:C3:T2,T5]] [[N2:P1:C1 T3]]',
      );
      expect(cited, hasLength(3));
      expect(cited[0].chunk, 3);
      expect(cited[0].typedRanges, <AiLineRange>[const AiLineRange(2, 4)]);
      expect(cited[1].typedRanges, <AiLineRange>[
        const AiLineRange(2, 2),
        const AiLineRange(5, 5),
      ]);
      expect(cited[2].chunk, 1);
      expect(cited[2].typedRanges.single, const AiLineRange(3, 3));
    });

    test('stay out of the words shown', () {
      expect(
        stripAiCitations('Cells make ATP. [[N1:P2:C3:T2-T4]]'),
        'Cells make ATP.',
      );
    });

    test('a chunk, a range of lines, and a box still read as before', () {
      expect(parseAiNoteCitations('[[N1:P2:C3]]').single.chunk, 3);
      expect(
        parseAiNoteCitations('[[N1:P2:L4-L7]]').single.ranges.single,
        const AiLineRange(4, 7),
      );
      final AiNoteCitation box = parseAiNoteCitations(
        '[[N1:P2:C3 100 200 300 400]]',
      ).single;
      expect(box.chunk, 3);
      expect(box.box, isNotNull);
      expect(box.typedRanges, isEmpty);
    });
  });

  group('lines are numbered in the excerpts', () {
    test('typed lines are headed T1, T2 and the chunk they are in', () async {
      final StudyChunk chunk = _typedChunk(_cellNotes);
      final StudyPayload payload = await const StudyContextAssembler().assemble(
        <StudyHit>[
          StudyHit(StudySearchDocument(chunk: chunk, noteTitle: 'Cells'), 1),
        ],
      );
      expect(payload.contextText, contains('[Source N1:P1:C1'));
      expect(payload.contextText, contains('T1: Mitochondria produce ATP'));
      expect(payload.contextText, contains('T5: Lysosomes digest'));
    });

    test('a line without a place on the page is not offered', () {
      final StudyChunk chunk = StudyChunk(
        noteId: 'n',
        pageIndex: 0,
        chunkIndex: 1,
        kind: StudyChunkKind.text,
        logicalBounds: const Rect.fromLTWH(0, 0, 10, 10),
        lines: const <StudyChunkLine>[StudyChunkLine(0, 0, 'older chunk')],
      );
      expect(chunk.typedLines, isEmpty);
    });

    test('a PDF page\'s lines keep where they lie', () {
      final StudyPageData page = StudyPageData(
        pageIndex: 0,
        strokes: const <StudyStrokeData>[],
        words: const <StudyWordData>[],
        boxes: const <StudyBoxData>[
          StudyBoxData(
            id: 'pdf-text-0-0',
            kind: StudyBoxKind.text,
            bounds: Rect.fromLTWH(50, 100, 400, 14),
            text: 'First printed line.',
          ),
          StudyBoxData(
            id: 'pdf-text-0-1',
            kind: StudyBoxKind.text,
            bounds: Rect.fromLTWH(50, 118, 400, 14),
            text: 'Second printed line.',
          ),
        ],
      );
      final StudyChunk chunk = StudyChunker.chunkPage('n', page).single;
      expect(chunk.typedLines, hasLength(2));
      expect(
        chunk.typedLines.first.bounds,
        const Rect.fromLTWH(50, 100, 400, 14),
      );
      expect(chunk.typedLines.last.bounds!.top, 118);
    });

    test('a text box shares its height among its lines by their length', () {
      final StudyPageData page = StudyPageData(
        pageIndex: 0,
        strokes: const <StudyStrokeData>[],
        words: const <StudyWordData>[],
        boxes: const <StudyBoxData>[
          StudyBoxData(
            id: 't',
            kind: StudyBoxKind.text,
            bounds: Rect.fromLTWH(0, 0, 300, 100),
            text: 'short\nthis line is a good deal longer than the one above',
          ),
        ],
      );
      final List<StudyChunkLine> lines = StudyChunker.chunkPage(
        'n',
        page,
      ).single.typedLines;
      expect(lines, hasLength(2));
      expect(lines.first.bounds!.bottom, lines.last.bounds!.top);
      expect(lines.first.bounds!.height, lessThan(lines.last.bounds!.height));
      expect(lines.last.bounds!.bottom, closeTo(100, 1e-9));
    });

    test('a line with its bounds survives being kept as JSON', () {
      final StudyChunk chunk = _typedChunk(_cellNotes);
      final StudyChunk read = StudyChunk.fromJson(chunk.toJson());
      expect(read.lines.map((l) => l.bounds), chunk.lines.map((l) => l.bounds));
      expect(read.typedLines, hasLength(5));
    });
  });

  group('a citation is settled against the paragraph', () {
    const String atp =
        'Mitochondria make ATP by oxidative phosphorylation, and the inner '
        'membrane folds into cristae to add surface area.';

    test('a whole-chunk citation shrinks to the lines the answer uses', () {
      final StudyChunk chunk = _typedChunk(_cellNotes);
      final List<int>? lines = StudyCitationRefiner.linesForChunk(chunk, atp);
      expect(lines, <int>[0, 1]);
    });

    test('with nothing in common, the whole chunk stays cited', () {
      final StudyChunk chunk = _typedChunk(_cellNotes);
      expect(
        StudyCitationRefiner.linesForChunk(
          chunk,
          'Photosynthesis happens in chloroplasts of plants.',
        ),
        isNull,
      );
    });

    test('a paragraph too short to check against changes nothing', () {
      final StudyChunk chunk = _typedChunk(_cellNotes);
      expect(StudyCitationRefiner.linesForChunk(chunk, 'Yes.'), isNull);
      expect(
        StudyCitationRefiner.refineLines(chunk, <int>[0, 3], 'Yes.'),
        <int>[0, 3],
      );
    });

    test(
      'two separate passages are both kept, and what lies between is not',
      () {
        final StudyChunk chunk = _typedChunk(<String>[
          'Mitochondria produce ATP through oxidative phosphorylation.',
          'Ribosomes assemble proteins from amino acids.',
          'The weather outside was warm that afternoon.',
          'Lunch was served at noon in the cafeteria.',
          'Lysosomes digest worn out organelles with enzymes.',
        ]);
        expect(
          StudyCitationRefiner.linesForChunk(
            chunk,
            'Mitochondria produce ATP, while lysosomes digest organelles '
            'using enzymes.',
          ),
          <int>[0, 4],
        );
      },
    );

    test('a range with edges the answer does not use is cut back', () {
      final StudyChunk chunk = _typedChunk(<String>[
        'Mitochondria produce ATP through oxidative phosphorylation.',
        'The inner membrane folds into cristae, which add surface area.',
        'Ribosomes assemble proteins from amino acids.',
        'The Golgi apparatus packages proteins for export.',
        'Lysosomes digest worn out organelles with enzymes.',
      ]);
      // Five lines cited, two are about the answer: the unrelated line at
      // each edge goes, up to a quarter of the range from each side.
      final List<int> refined = StudyCitationRefiner.refineLines(
        chunk,
        <int>[0, 1, 2, 3, 4],
        'Ribosomes assemble proteins, and the Golgi apparatus packages '
        'proteins for export.',
      );
      expect(refined, <int>[1, 2, 3]);
    });

    test('lines that say nothing of the answer are moved to ones that do', () {
      final StudyChunk chunk = _typedChunk(_cellNotes);
      // The model was two lines out.
      expect(
        StudyCitationRefiner.refineLines(
          chunk,
          <int>[3],
          'Lysosomes digest worn out organelles with enzymes inside the cell.',
        ),
        <int>[4],
      );
    });

    test('a citation that already says what the answer says stays put', () {
      final StudyChunk chunk = _typedChunk(_cellNotes);
      expect(
        StudyCitationRefiner.refineLines(
          chunk,
          <int>[2, 3],
          'Ribosomes assemble proteins from amino acids; the Golgi apparatus '
          'packages those proteins.',
        ),
        <int>[2, 3],
      );
    });

    test('a sentence cut off at the end of a line reaches its next line', () {
      final StudyChunk chunk = _typedChunk(<String>[
        'Mitochondria produce ATP through',
        'oxidative phosphorylation in the inner membrane.',
        'Ribosomes assemble proteins from amino acids.',
      ]);
      expect(
        StudyCitationRefiner.refineLines(chunk, <int>[
          0,
        ], 'Mitochondria produce ATP through oxidative phosphorylation.'),
        <int>[0, 1],
      );
    });

    test('and a line that begins a new sentence is not taken in', () {
      final StudyChunk chunk = _typedChunk(<String>[
        'Mitochondria produce ATP',
        'Oxidative phosphorylation happens in the inner membrane.',
      ]);
      expect(
        StudyCitationRefiner.refineLines(chunk, <int>[
          0,
        ], 'Mitochondria produce ATP through oxidative phosphorylation.'),
        <int>[0],
      );
    });

    test('a line that goes on, but not about the answer, is not taken in', () {
      final StudyChunk chunk = _typedChunk(<String>[
        'Mitochondria produce ATP through',
        'something entirely unrelated to the answer here.',
      ]);
      expect(
        StudyCitationRefiner.refineLines(chunk, <int>[
          0,
        ], 'Mitochondria produce ATP through oxidative phosphorylation.'),
        <int>[0],
      );
    });

    test('a drawing is left as cited: its words are not its evidence', () {
      final StudyChunk drawing = StudyChunk(
        noteId: 'n',
        pageIndex: 0,
        chunkIndex: 1,
        kind: StudyChunkKind.diagram,
        logicalBounds: const Rect.fromLTWH(0, 0, 100, 100),
        lines: const <StudyChunkLine>[
          StudyChunkLine(1, 1, 'cell'),
          StudyChunkLine(2, 2, 'membrane'),
        ],
      );
      expect(StudyCitationRefiner.canRefine(drawing), isFalse);
      expect(StudyCitationRefiner.refineLines(drawing, <int>[0, 1], atp), <int>[
        0,
        1,
      ]);
    });
  });

  group('the resolver marks just what the answer used', () {
    test('typed lines named by T are each marked by themselves', () {
      final StudyChunk chunk = _typedChunk(_cellNotes);
      final List<StudyParagraphLinks> links = _resolver(<StudyChunk>[chunk])
          .resolve(
            'Ribosomes assemble proteins from amino acids, and the Golgi '
            'apparatus packages proteins. [[N1:P1:C1:T3-T4]]',
          );
      final StudyCitation citation = links.single.citations.single;
      expect(citation.highlights, <Rect>[
        chunk.lines[2].bounds!,
        chunk.lines[3].bounds!,
      ]);
      expect(citation.rings, isEmpty);
      expect(citation.strokeIndices, isEmpty);
      expect(citation.focus, isNotNull);
    });

    test('a whole chunk named for a few lines marks only those', () {
      final StudyChunk chunk = _typedChunk(_cellNotes);
      final StudyCitation citation = _resolver(<StudyChunk>[chunk])
          .resolve(
            'Lysosomes digest worn out organelles using enzymes. [[N1:P1:C1]]',
          )
          .single
          .citations
          .single;
      expect(citation.highlights, <Rect>[chunk.lines[4].bounds!]);
    });

    test('a whole chunk the answer never discusses is still marked whole', () {
      final StudyChunk chunk = StudyChunk(
        noteId: 'n',
        pageIndex: 0,
        chunkIndex: 1,
        kind: StudyChunkKind.text,
        logicalBounds: const Rect.fromLTWH(40, 40, 400, 100),
        otherBounds: const Rect.fromLTWH(40, 40, 400, 100),
        lines: _typedChunk(_cellNotes).lines,
      );
      final StudyCitation citation = _resolver(<StudyChunk>[chunk])
          .resolve(
            'Photosynthesis happens in chloroplasts of green plants. '
            '[[N1:P1:C1]]',
          )
          .single
          .citations
          .single;
      expect(citation.highlights, isEmpty);
      expect(citation.rings, <Rect>[chunk.otherBounds!]);
    });

    test('a T number past the last typed line ties nothing', () {
      final StudyChunk chunk = _typedChunk(_cellNotes);
      final StudyCitation citation = _resolver(<StudyChunk>[chunk])
          .resolve('Cells have organelles. [[N1:P1:C1:T9]]')
          .single
          .citations
          .single;
      expect(citation.highlights, isEmpty);
    });

    test('a citation keeps its highlights and focus as JSON', () {
      final StudyChunk chunk = _typedChunk(_cellNotes);
      final StudyCitation citation = _resolver(<StudyChunk>[chunk])
          .resolve(
            'Ribosomes assemble proteins from amino acids. [[N1:P1:C1:T3]]',
          )
          .single
          .citations
          .single;
      final StudyCitation read = StudyCitation.fromJson(citation.toJson());
      expect(read.highlights, citation.highlights);
      expect(read.focus, citation.focus);
      expect(read.marks(1).highlights, citation.highlights);
    });

    test('two citations on a page mark both but are framed on the first', () {
      final StudyChunk chunk = _typedChunk(_cellNotes);
      final StudyCitation citation = _resolver(<StudyChunk>[chunk])
          .resolve(
            'Ribosomes assemble proteins from amino acids and lysosomes '
            'digest organelles. [[N1:P1:C1:T3]] [[N1:P1:C1:T5]]',
          )
          .single
          .citations
          .single;
      expect(citation.highlights, hasLength(2));
      expect(citation.focus, chunk.lines[2].bounds);
    });
  });

  group('handwriting', () {
    Stroke bar(double x0, double x1, double y) => Stroke.fromPoints(
      style: const StrokeStyle(ink: InkPalette.ink, width: 2),
      points: <InkVector>[InkVector(x0, y), InkVector(x1, y)],
    );

    // Four words, one to a row, 20pt apart. A mark beside the first row was
    // made after the second, so it lies, by number, between the second and
    // third words, though it is on the first row.
    final List<Stroke> strokes = <Stroke>[
      bar(60, 260, 100), // 0: mitochondria
      bar(60, 260, 120), // 1: produce
      bar(280, 300, 100), // 2: the mark, no word of its own
      bar(60, 260, 140), // 3: energy
      bar(60, 260, 160), // 4: cells
    ];
    final StoredPage page = StoredPage(
      setup: const PageSetup(),
      strokes: strokes,
    );
    final StudyChunk chunk = StudyChunker.chunkPage(
      'n',
      StudyPageData(
        pageIndex: 0,
        strokes: <StudyStrokeData>[
          for (int i = 0; i < strokes.length; i++)
            StudyStrokeData.of(strokes[i], i),
        ],
        boxes: const <StudyBoxData>[],
        words: const <StudyWordData>[
          StudyWordData(
            text: 'mitochondria',
            confidence: 0.95,
            alternatives: <String>[],
            strokeIndices: <int>[0],
          ),
          StudyWordData(
            text: 'produce',
            confidence: 0.95,
            alternatives: <String>[],
            strokeIndices: <int>[1],
          ),
          StudyWordData(
            text: 'energy',
            confidence: 0.95,
            alternatives: <String>[],
            strokeIndices: <int>[3],
          ),
          StudyWordData(
            text: 'cells',
            confidence: 0.95,
            alternatives: <String>[],
            strokeIndices: <int>[4],
          ),
        ],
      ),
    ).single;
    final StudyCitationResolver resolver = StudyCitationResolver(
      map: _map(<StudyChunk>[chunk]),
      pageOf: (String note, int pageIndex) => page,
      revisionOf: (String note) => 1,
    );

    test('the page holds the four words as one chunk', () {
      expect(chunk.strokeIndices, <int>[0, 1, 2, 3, 4]);
      expect(chunk.lines.map((StudyChunkLine l) => l.text), <String>[
        'mitochondria',
        'produce',
        'energy',
        'cells',
      ]);
    });

    test('a range marks the strokes in its lines, not all it spans', () {
      // Lines 2-4 are the strokes numbered 2 to 4, one of which is the mark.
      final StudyCitation citation = resolver
          .resolve('They produce energy quickly. [[N1:P1:L2-L4]]')
          .single
          .citations
          .single;
      expect(citation.strokeIndices, <int>[1, 3]);
    });

    test('a whole chunk marks the rows the answer is about', () {
      final StudyCitation citation = resolver
          .resolve(
            'Mitochondria produce energy. [[N1:P1:C${chunk.chunkIndex}]]',
          )
          .single
          .citations
          .single;
      expect(citation.strokeIndices, <int>[0, 1, 3]);
    });
  });

  testWidgets('typed lines are painted as a highlighter band, and repaint', (
    WidgetTester tester,
  ) async {
    Future<void> pump(List<Rect> lines) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 400,
          height: 400,
          child: AiCitationMarks(highlights: lines),
        ),
      ),
    );

    await pump(<Rect>[const Rect.fromLTWH(40, 40, 300, 16)]);
    final Finder layer = find.byKey(
      const ValueKey<String>('ai-citation-highlight-layer'),
    );
    expect(layer, findsOneWidget);
    final CustomPaint first = tester.widget(layer);
    await pump(<Rect>[
      const Rect.fromLTWH(40, 40, 300, 16),
      const Rect.fromLTWH(40, 60, 300, 16),
    ]);
    final CustomPaint second = tester.widget(layer);
    expect(
      second.painter!.shouldRepaint(first.painter!),
      isTrue,
      reason: 'A line added to a citation is drawn.',
    );
    expect(tester.takeException(), isNull);
  });
}
