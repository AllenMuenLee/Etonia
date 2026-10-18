import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/ai/canvas_text_recognizer.dart';
import 'package:greatnote/features/editor/ai/notation_layout.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/handwriting/handwriting_indexer.dart';
import 'package:greatnote/features/editor/handwriting/recognized_handwriting.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/page/note_document.dart';
import 'package:greatnote/features/editor/sticky/sticky_note.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';

import '../../../helpers/pump_app.dart';

Stroke _stroke(double left, double top, double right, double bottom) =>
    Stroke.fromPoints(
      style: const StrokeStyle(ink: InkPalette.ink, width: 2),
      points: <InkVector>[InkVector(left, top), InkVector(right, bottom)],
    );

class _DetailedRecognizer implements DetailedCanvasTextRecognizer {
  const _DetailedRecognizer(this.text, this.confidence);

  final String text;
  final double confidence;

  @override
  Future<String> recognize(HandwritingBatch batch) async => text;

  @override
  Future<List<RecognizedTextSegment>> recognizeDetailed(
    HandwritingBatch batch,
  ) async => <RecognizedTextSegment>[
    RecognizedTextSegment(text, confidence: confidence),
  ];
}

class _CyclingRandom implements math.Random {
  int value = 0;

  @override
  bool nextBool() => nextInt(2) == 0;

  @override
  double nextDouble() => nextInt(1000) / 1000;

  @override
  int nextInt(int max) => value++ % max;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('recognizes separated page ink as searchable reusable words', () async {
    final Stroke first = _stroke(10, 10, 25, 30);
    final Stroke second = _stroke(70, 10, 85, 30);
    const HandwritingIndexer indexer = HandwritingIndexer(
      recognizer: _DetailedRecognizer('hello', 0.94),
      renderer: HandwritingImageRenderer(),
    );

    expect(splitIntoWordGroups(<Stroke>[first, second]), hasLength(2));
    final List<RecognizedInkWord> words = await indexer.recognize(<Stroke>[
      first,
    ]);
    expect(words.single.text, 'hello');
    expect(words.single.isReusable, isTrue);
    expect(words.single.normalizedStrokes.single.first, const InkVector(0, 0));
    expect(words.single.normalizedStrokes.single.last, const InkVector(1, 1));
  });

  test('low-confidence recognition is neither searchable nor reusable', () {
    final Stroke stroke = _stroke(0, 0, 20, 10);
    final RecognizedInkWord word = RecognizedInkWord.fromStrokes(
      text: 'maybe',
      confidence: 0.5,
      strokes: <Stroke>[stroke],
    );
    final NoteDocument document = NoteDocument(
      pages: <NotePage>[
        NotePage(
          ink: InkController(strokes: <Stroke>[stroke]),
          recognizedWords: <RecognizedInkWord>[word],
        ),
      ],
    );

    expect(word.isSearchable, isFalse);
    expect(word.isReusable, isFalse);
    expect(word.normalizedStrokes, isEmpty);
    expect(NoteContent.fromDocument(document).searchableText, isEmpty);
    document.dispose();
  });

  test(
    'storage preserves word links and library search includes ink',
    () async {
      final Stroke stroke = _stroke(5, 8, 45, 28);
      final RecognizedInkWord word = RecognizedInkWord.fromStrokes(
        text: 'Quadratic',
        confidence: 0.96,
        strokes: <Stroke>[stroke],
      );
      final NoteDocument document = NoteDocument(
        pages: <NotePage>[
          NotePage(ink: InkController(strokes: <Stroke>[stroke])),
        ],
      );
      document.addRecognizedWord(document.current, word);
      final NoteContent stored = NoteContent.fromDocument(document);
      final NoteContent restored = NoteContent.fromJson(stored.toJson());
      final NoteDocument roundTrip = restored.toDocument();

      expect(roundTrip.current.recognizedWords.single.text, 'Quadratic');
      expect(roundTrip.current.recognizedWords.single.isSearchable, isTrue);
      expect(
        roundTrip.current.recognizedWords.single.sourceStrokes.single,
        same(roundTrip.current.ink.strokes.single),
      );

      final InMemoryNoteRepository repository = InMemoryNoteRepository();
      final note = await repository.createNote(title: 'Lecture');
      await repository.saveNote(note.id, restored);
      expect((await repository.search('quadratic')).notes.single.id, note.id);
      roundTrip.dispose();
      document.dispose();
    },
  );

  test('storage restores recognized sticky ink to its sticky strokes', () {
    final Stroke stroke = _stroke(10, 12, 60, 36);
    final StickyNoteElement sticky = StickyNoteElement(
      id: 'sticky-1',
      center: const InkVector(200, 180),
      size: const Size(240, 180),
      colorId: 'yellow',
      strokes: <Stroke>[stroke],
    );
    final NoteDocument document = NoteDocument(
      pages: <NotePage>[
        NotePage(ink: InkController(stickyNotes: <StickyNoteElement>[sticky])),
      ],
    );
    document.addRecognizedWord(
      document.current,
      RecognizedInkWord.fromStrokes(
        text: 'sticky',
        confidence: 0.97,
        strokes: <Stroke>[stroke],
        stickyId: sticky.id,
      ),
    );

    final NoteDocument restored = NoteContent.fromJson(
      NoteContent.fromDocument(document).toJson(),
    ).toDocument();
    final RecognizedInkWord word = restored.current.recognizedWords.single;
    expect(word.stickyId, sticky.id);
    expect(
      word.sourceStrokes.single,
      same(restored.current.ink.stickyNotes.single.strokes.single),
    );
    restored.dispose();
    document.dispose();
  });

  test('AI notation randomly chooses intact high-confidence samples', () {
    RecognizedInkWord sample(double endY) => RecognizedInkWord.fromStrokes(
      text: 'answer',
      confidence: 0.99,
      strokes: <Stroke>[_stroke(0, 0, 20, endY)],
    );
    final HandwritingSampleLibrary library = HandwritingSampleLibrary(
      <RecognizedInkWord>[sample(10), sample(20)],
      random: _CyclingRandom(),
    );
    final AiNotation notation = AiNotation(
      label: 'answer',
      items: const <AiNotationItem>[
        AiNotationText(
          text: 'answer',
          x: 0.1,
          y: 0.2,
          size: 20,
          ink: 'ink',
          width: 2,
        ),
      ],
    );

    final first = layoutNotation(
      notation,
      const Size(200, 100),
      handwriting: library,
    );
    final second = layoutNotation(
      notation,
      const Size(200, 100),
      handwriting: library,
    );

    expect(library.variantsFor('answer'), 2);
    expect(first.single.points.first, const InkVector(20, 20));
    expect(second.single.points.first, const InkVector(20, 20));
    // The two source aspect ratios are 2 and 1, so the fitted endpoints
    // prove that separate pool entries were selected instead of averaged.
    expect(first.single.points.last.x, 60);
    expect(second.single.points.last.x, 40);
  });

  testWidgets('find filters low confidence, highlights, and closes safely', (
    WidgetTester tester,
  ) async {
    final Stroke stroke = _stroke(5, 8, 45, 28);
    final Stroke lowConfidenceShape = _stroke(60, 8, 90, 38);
    final NoteDocument document = NoteDocument(
      pages: <NotePage>[
        NotePage(
          ink: InkController(strokes: <Stroke>[stroke, lowConfidenceShape]),
          recognizedWords: <RecognizedInkWord>[
            RecognizedInkWord.fromStrokes(
              text: 'Quadratic',
              confidence: 0.96,
              strokes: <Stroke>[stroke],
            ),
            RecognizedInkWord.fromStrokes(
              text: 'Quadratic',
              confidence: 0.42,
              strokes: <Stroke>[lowConfidenceShape],
            ),
          ],
        ),
      ],
    );
    addTearDown(document.dispose);
    await pumpApp(tester, home: EditorScreen(document: document));

    await tester.tap(find.byTooltip('Find handwriting'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'quadratic');
    await tester.pump();
    expect(find.textContaining('1 of 1'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('handwriting-search-highlight-0')),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(TextButton, 'Done'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(find.text('Find handwriting'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('handwriting-search-highlight-0')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
