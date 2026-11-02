import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_assistant_controller.dart';
import 'package:greatnote/features/editor/ai/ai_citation.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/ai/note_image_renderer.dart';
import 'package:greatnote/features/editor/ai/selection_image_renderer.dart';
import 'package:greatnote/features/editor/ai/selection_svg_renderer.dart';
import 'package:greatnote/features/editor/ai/svg_ink_converter.dart';
import 'package:greatnote/features/editor/document_io/document_models.dart';
import 'package:greatnote/features/editor/document_io/svg_document.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

import '../../../helpers/ai_fakes.dart';

Stroke _line(double y) => Stroke.fromPoints(
  style: const StrokeStyle(ink: InkPalette.ink, width: 4),
  points: <InkVector>[InkVector(100, y), InkVector(200, y)],
);

SnapshotStroke _copy(double y, {double x = 10}) => SnapshotStroke(
  points: <InkVector>[InkVector(x, y), InkVector(x + 20, y)],
  width: 2,
  color: const Color(0xFF000000),
  isDot: false,
);

SelectionImage _preview(Rect bounds) => SelectionImage(
  png: Uint8List.fromList(<int>[1]),
  width: 10,
  height: 10,
  scale: 1,
  logicalBounds: bounds,
);

void main() {
  group('reading an answer', () {
    test('citations are taken out of what is shown and of history', () {
      const String answer = 'The slope is 2. [[L5-L9]]\n\nSo it rises.';
      expect(stripAiCitations(answer), 'The slope is 2.\n\nSo it rises.');
      expect(const AiMessage.model(answer).historyText, isNot(contains('[[')));
      // What is saved still holds them, for the links to be drawn again.
      expect(const AiMessage.model(answer).wireText, contains('[[L5-L9]]'));
    });

    test('half a citation at the end of a stream is not shown', () {
      for (final String tail in <String>[
        '[',
        '[[',
        '[[L',
        '[[L5',
        '[[L5-',
        '[[L5-L9',
        '[[L5-L9]',
        '[[L5,L',
      ]) {
        expect(
          stripAiCitations('Words. $tail', streaming: true).trim(),
          'Words.',
          reason: tail,
        );
      }
      // Once it has ended, a bracket is the writer's own.
      expect(stripAiCitations('See [1]'), 'See [1]');
    });

    test('paragraphs and their ranges', () {
      final List<AiAnswerParagraph> paragraphs = parseAiAnswer(
        'First. [[L5-L9]]\n\nSecond.\n\nThird. [[L12,L30-L20]]',
      );
      expect(paragraphs.map((AiAnswerParagraph it) => it.text), <String>[
        'First.',
        'Second.',
        'Third.',
      ]);
      expect(paragraphs[0].ranges, const <AiLineRange>[AiLineRange(5, 9)]);
      expect(paragraphs[1].ranges, isEmpty);
      // A range written backwards still names those lines.
      expect(paragraphs[2].ranges, const <AiLineRange>[
        AiLineRange(12, 12),
        AiLineRange(20, 30),
      ]);
    });

    // answerParagraphs in supabase/functions/_shared/ai_policy.ts must number
    // these the same way: supabase/tests/ai_policy_test.ts checks the same
    // cases.
    final Map<String, int> numbering = <String, int>{
      'One.\n\nTwo.': 2,
      'One.\n\n\n\nTwo.\n': 2,
      'One.\nStill one.': 1,
      'One.\n\n```\ncode\n\nmore code\n```\n\nThree.': 3,
      'One.\n\n\$\$\na\n\nb\n\$\$\n\nThree.': 3,
      'One.\n\n\$\$a\$\$\n\nThree.': 3,
      'One.\n\n[[L5-L9]]\n\nTwo.': 2,
      '[[L5-L9]]\n\nOne.': 1,
      '': 0,
    };
    numbering.forEach((String answer, int count) {
      test('${jsonEncode(answer)} has $count paragraphs', () {
        expect(parseAiAnswer(answer), hasLength(count));
      });
    });

    test('a citation alone on a line belongs to the paragraph before', () {
      final List<AiAnswerParagraph> paragraphs = parseAiAnswer(
        'One.\n\n[[L5-L9]]\n\nTwo.',
      );
      expect(paragraphs.first.ranges, const <AiLineRange>[AiLineRange(5, 9)]);
    });
  });

  group('selection SVG lines', () {
    test('each citable element names the line it is really on', () {
      final SelectionSvgDocument document = const SelectionSvgRenderer()
          .document(
            snapshot: SelectionInkSnapshot.fromStrokes(<SnapshotStroke>[
              _copy(20),
              _copy(40),
            ]),
            preview: _preview(const Rect.fromLTWH(0, 0, 100, 100)),
            pageSize: const Size(200, 200),
            assistantStrokes: const <int>{1},
          );
      final List<String> lines = document.svg.split('\n');
      expect(document.lines.map((SelectionSvgLine it) => it.line), <int>[5, 6]);
      for (final SelectionSvgLine line in document.lines) {
        expect(
          lines[line.line - 1],
          contains('data-etonia-line="${line.line}"'),
        );
      }
      expect(lines[5], contains('data-etonia-author="assistant"'));
      expect(lines[4], isNot(contains('data-etonia-author')));
      expect(document.svg, startsWith('<svg'));
      expect(document.svg, endsWith('</svg>'));
    });

    test('the index without paths numbers lines as the document does', () {
      final SelectionInkSnapshot snapshot = SelectionInkSnapshot.fromStrokes(
        <SnapshotStroke>[_copy(20)],
        bitmaps: <SnapshotBitmap>[
          SnapshotBitmap(
            bytes: Uint8List.fromList(<int>[1]),
            bounds: const Rect.fromLTWH(0, 0, 100, 100),
          ),
        ],
      );
      final SelectionImage preview = _preview(
        const Rect.fromLTWH(0, 0, 100, 100),
      );
      const SelectionSvgRenderer renderer = SelectionSvgRenderer();
      final List<SelectionSvgLine> document = renderer
          .document(
            snapshot: snapshot,
            preview: preview,
            pageSize: const Size(200, 200),
          )
          .lines;
      final List<SelectionSvgLine> index = renderer.lineIndex(
        snapshot: snapshot,
        preview: preview,
      );
      expect(
        index.map((SelectionSvgLine it) => it.line),
        document.map((SelectionSvgLine it) => it.line),
      );
      // Slices let part of the picture be cited; the stroke comes after them.
      expect(index.first.strokeIndex, isNull);
      expect(index.last.strokeIndex, 0);
    });

    test('the outline gives each written line one row', () {
      final String outline = SelectionSvgRenderer.outline(
        const SelectionSvgRenderer().lineIndex(
          snapshot: SelectionInkSnapshot.fromStrokes(<SnapshotStroke>[
            _copy(20),
            _copy(21, x: 40),
            _copy(22, x: 70),
            _copy(200),
            _copy(201, x: 40),
          ]),
          preview: _preview(const Rect.fromLTWH(0, 0, 100, 300)),
        ),
      );
      expect(outline.split('\n'), hasLength(2));
      expect(outline.split('\n').first, startsWith('L5-L7 note '));
      expect(outline.split('\n').last, startsWith('L8-L9 note '));
    });

    test('the outline stays small however much ink is chosen', () {
      final List<SnapshotStroke> strokes = <SnapshotStroke>[
        for (int i = 0; i < 5000; i++) _copy(i * 10.0),
      ];
      final String outline = SelectionSvgRenderer.outline(
        const SelectionSvgRenderer().lineIndex(
          snapshot: SelectionInkSnapshot.fromStrokes(strokes),
          preview: _preview(const Rect.fromLTWH(0, 0, 100, 50000)),
        ),
      );
      final List<String> rows = outline.split('\n');
      expect(
        rows.length,
        lessThanOrEqualTo(SelectionSvgRenderer.maxOutlineRows),
      );
      // Under the limit the service holds it to.
      expect(utf8.encode(outline).length, lessThan(16000));
      // Still every line, in order.
      expect(rows.first, startsWith('L5-'));
      expect(rows.last, contains('-L5004 '));
    });

    test('a range names only what exists, however large the number', () {
      final Stroke stroke = _line(10);
      final AiSourceMap source = AiSourceMap(
        const SelectionSvgRenderer().lineIndex(
          snapshot: SelectionInkSnapshot.fromStrokes(<SnapshotStroke>[
            _copy(10),
          ]),
          preview: _preview(const Rect.fromLTWH(0, 0, 100, 100)),
        ),
        <Stroke?>[stroke],
      );
      final AiAnswerLinks links = source.resolve(
        'Real. [[L1-L999999999]]\n\nInvented. [[L500-L600]]',
      );
      expect(links.paragraphs[1]!.cited, <Stroke>[stroke]);
      expect(links.paragraphs[2], isNull);
    });
  });

  group('drawn strokes name their paragraph', () {
    test('on an element, inherited from a group, or not at all', () {
      final SvgInkConversion conversion = SvgInkConverter.convert(
        EditableSvg.parse(
          '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">'
          '<path data-etonia-paragraph="2" fill="none" stroke="#000" '
          'd="M10 10 L50 10"/>'
          '<g data-etonia-paragraph="3">'
          '<path fill="none" stroke="#000" d="M10 30 L50 30"/>'
          '<path data-etonia-paragraph="1" fill="none" stroke="#000" '
          'd="M10 50 L50 50"/>'
          '</g>'
          '<path data-etonia-paragraph="x" fill="none" stroke="#000" '
          'd="M10 70 L50 70"/>'
          '</svg>',
        ),
        defaultInk: InkPalette.ink,
        defaultWidth: 2,
      );
      expect(conversion.traces.map((trace) => trace.answerParagraph), <int?>[
        2,
        3,
        1,
        null,
      ]);
    });

    test('an arrowhead belongs to the paragraph of its shaft', () {
      final SvgInkConversion conversion = SvgInkConverter.convert(
        EditableSvg.parse(
          '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">'
          '<path data-etonia-paragraph="4" data-etonia-arrow="end" '
          'fill="none" stroke="#000" d="M10 10 L90 10"/>'
          '</svg>',
        ),
        defaultInk: InkPalette.ink,
        defaultWidth: 2,
      );
      expect(conversion.traces.length, greaterThan(1));
      expect(
        conversion.traces.map((trace) => trace.answerParagraph).toSet(),
        <int?>{4},
      );
    });
  });

  group('conversation', () {
    late InkController ink;
    late FakeAiClient client;
    late AiAssistantController assistant;
    List<Stroke> drawn = const <Stroke>[];

    AiAssistantController make() => AiAssistantController(
      client: client,
      renderer: FakeSelectionImageRenderer(),
      captureNote: () async =>
          NoteImage(logicalSize: const Size(400, 400), revision: 0),
      applyNotation: (AiNotation _, NoteImage _) => AiNotationApplication(
        AiNotationStatus.applied,
        strokes: drawn,
        paragraphs: const <int?>[2, null],
      ),
    );

    AiInkIndex index() => AiInkIndex(<(List<Stroke>, List<NoteImageElement>)>[
      (ink.strokes, ink.images),
    ]);

    setUp(() {
      ink = InkController(
        strokes: <Stroke>[_line(100), _line(300), _line(500), _line(600)],
      );
      client = FakeAiClient();
      drawn = <Stroke>[ink.strokes[2], ink.strokes[3]];
      assistant = make();
    });

    tearDown(() {
      assistant.dispose();
      ink.dispose();
    });

    Future<void> openOnFirstTwo() async {
      assistant.open(
        selectInk(ink, const Rect.fromLTRB(90, 90, 210, 310)),
        brightness: Brightness.light,
        background: Colors.white,
      );
      await pumpEventQueue();
    }

    test(
      'the words can cite with Notation off, without the costly SVG',
      () async {
        await openOnFirstTwo();
        assistant.send('Explain');
        await pumpEventQueue();
        final AiRequest request = client.requests.single;
        expect(request.selectionSvg, isNull);
        expect(request.sourceLines, startsWith('L5 note'));
        expect(request.sourceLines, contains('L6 note'));

        client.answer('About the first line. [[L5]]\n\nNot about ink.');
        await pumpEventQueue();
        final AiParagraphLinks links = assistant.answerLinks(1)!.paragraphs[1]!;
        expect(links.cited, <Stroke>[ink.strokes[0]]);
        expect(links.label, 'L5');
        expect(assistant.answerLinks(1)!.paragraphs[2], isNull);
      },
    );

    test('a conversation about nothing has nothing to cite', () async {
      assistant.send('What is 2+2?');
      await pumpEventQueue();
      expect(client.requests.single.sourceLines, isNull);
      client.answer('Four. [[L5]]');
      await pumpEventQueue();
      expect(assistant.answerLinks(1), isNull);
    });

    test('drawn strokes join the paragraph they name, and earlier notation '
        'can then be cited', () async {
      await openOnFirstTwo();
      assistant
        ..setNotationEnabled(true)
        ..send('Draw');
      await pumpEventQueue();
      client.answerResponse(
        AiAssistantResponse(
          message: 'One. [[L5]]\n\nTwo.',
          notation: AiNotation.vector(
            EditableSvg.parse(
              '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">'
              '<path d="M1 1 L9 9"/></svg>',
            ),
          ),
        ),
      );
      await pumpEventQueue();
      final AiAnswerLinks links = assistant.answerLinks(1)!;
      expect(links.paragraphs[1]!.cited, <Stroke>[ink.strokes[0]]);
      expect(links.paragraphs[2]!.drawn, <Stroke>[ink.strokes[2]]);
      expect(links.paragraphs[2]!.label, 'Notation');

      // The next question is sent those strokes, marked as the assistant's.
      assistant.send('And then?');
      await pumpEventQueue();
      final AiRequest next = client.requests.last;
      expect(next.sourceLines, contains(' ai '));
      expect(next.selectionSvg, contains('data-etonia-author="assistant"'));
      client.answer('Your own drawing shows it. [[L7]]');
      await pumpEventQueue();
      expect(assistant.answerLinks(3)!.paragraphs[1]!.cited, <Stroke>[
        ink.strokes[2],
      ]);
    });

    test('a number past the last paragraph ties nothing', () async {
      drawn = <Stroke>[ink.strokes[2]];
      await openOnFirstTwo();
      assistant
        ..setNotationEnabled(true)
        ..send('Draw');
      await pumpEventQueue();
      client.answerResponse(
        AiAssistantResponse(
          message: 'Only one.',
          notation: AiNotation.vector(
            EditableSvg.parse(
              '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">'
              '<path d="M1 1 L9 9"/></svg>',
            ),
          ),
        ),
      );
      await pumpEventQueue();
      expect(assistant.answerLinks(1), isNull);
    });

    test('focus follows what scrolls, and selecting a drawing finds its '
        'words', () async {
      await openOnFirstTwo();
      assistant
        ..setNotationEnabled(true)
        ..send('Draw');
      await pumpEventQueue();
      client.answerResponse(
        AiAssistantResponse(
          message: 'One. [[L5]]\n\nTwo.',
          notation: AiNotation.vector(
            EditableSvg.parse(
              '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">'
              '<path d="M1 1 L9 9"/></svg>',
            ),
          ),
        ),
      );
      await pumpEventQueue();

      assistant.focusParagraph(const AiParagraphRef(1, 1));
      expect(assistant.paragraphFocus.value!.links.cited, <Stroke>[
        ink.strokes[0],
      ]);
      // Nothing to show for it, or no paragraph at all: the mark stays.
      assistant.focusParagraph(const AiParagraphRef(1, 9));
      expect(assistant.paragraphFocus.value?.ref, const AiParagraphRef(1, 1));
      assistant.focusParagraph(null);
      expect(assistant.paragraphFocus.value?.ref, const AiParagraphRef(1, 1));
      // Closing the chat leaves it too.
      assistant.close();
      expect(assistant.paragraphFocus.value?.ref, const AiParagraphRef(1, 1));

      assistant.updateCurrentSelection(
        selectInk(ink, const Rect.fromLTRB(90, 490, 210, 510)),
      );
      expect(assistant.takeParagraphToShow(), const AiParagraphRef(1, 2));
      expect(assistant.takeParagraphToShow(), isNull);
      expect(assistant.paragraphFocus.value!.ref, const AiParagraphRef(1, 2));
    });

    test(
      'an answer arriving with the chat closed is marked on the note',
      () async {
        await openOnFirstTwo();
        assistant.send('Explain');
        await pumpEventQueue();
        assistant.close();
        client.answer('Words first.\n\nAbout ink. [[L5]]');
        await pumpEventQueue();
        expect(assistant.paragraphFocus.value?.ref, const AiParagraphRef(1, 2));
      },
    );

    test('another conversation\'s mark does not carry over', () async {
      await openOnFirstTwo();
      assistant.send('Explain');
      await pumpEventQueue();
      client.answer('About ink. [[L5]]');
      await pumpEventQueue();
      expect(assistant.paragraphFocus.value, isNotNull);

      // Far from the first, so a chat of its own.
      assistant.useSelection(
        selectInk(ink, const Rect.fromLTRB(90, 590, 210, 610)),
        brightness: Brightness.light,
        background: Colors.white,
      );
      await pumpEventQueue();
      assistant.focusParagraph(null);
      expect(assistant.paragraphFocus.value, isNull);
    });

    test('ink moved is still the ink cited', () async {
      await openOnFirstTwo();
      assistant.send('Explain');
      await pumpEventQueue();
      client.answer('About it. [[L5]]');
      await pumpEventQueue();
      final Stroke moved = _line(120);
      assistant.followReplacedStrokes(<Stroke, Stroke>{ink.strokes[0]: moved});
      expect(assistant.answerLinks(1)!.paragraphs[1]!.cited, contains(moved));
    });

    test('links are saved with the note and found again', () async {
      await openOnFirstTwo();
      assistant
        ..setNotationEnabled(true)
        ..send('Draw');
      await pumpEventQueue();
      client.answerResponse(
        AiAssistantResponse(
          message: 'One. [[L5]]\n\nTwo.',
          notation: AiNotation.vector(
            EditableSvg.parse(
              '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">'
              '<path d="M1 1 L9 9"/></svg>',
            ),
          ),
        ),
      );
      await pumpEventQueue();

      final Map<String, Object?> saved =
          jsonDecode(jsonEncode(assistant.toJson(index())))
              as Map<String, Object?>;
      final AiAssistantController restored = make();
      addTearDown(restored.dispose);
      restored
        ..restore(saved, index())
        ..open(
          selectInk(ink, const Rect.fromLTRB(90, 90, 210, 310)),
          brightness: Brightness.light,
          background: Colors.white,
        );
      await pumpEventQueue();

      final AiAnswerLinks links = restored.answerLinks(1)!;
      expect(links.paragraphs[1]!.cited, <Stroke>[ink.strokes[0]]);
      expect(links.paragraphs[1]!.ranges, const <AiLineRange>[
        AiLineRange(5, 5),
      ]);
      expect(links.paragraphs[2]!.drawn, <Stroke>[ink.strokes[2]]);
    });

    test('a session saved before links existed still opens', () async {
      await openOnFirstTwo();
      assistant.send('Explain');
      await pumpEventQueue();
      client.answer('Plain answer.');
      await pumpEventQueue();
      final Map<String, Object?> saved =
          jsonDecode(jsonEncode(assistant.toJson(index())))
              as Map<String, Object?>;
      final AiAssistantController restored = make();
      addTearDown(restored.dispose);
      restored
        ..restore(saved, index())
        ..open(
          selectInk(ink, const Rect.fromLTRB(90, 90, 210, 310)),
          brightness: Brightness.light,
          background: Colors.white,
        );
      await pumpEventQueue();
      expect(restored.messages.last.text, 'Plain answer.');
      expect(restored.answerLinks(1), isNull);
    });
  });
}
