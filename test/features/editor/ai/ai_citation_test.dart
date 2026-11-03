import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_assistant_controller.dart';
import 'package:greatnote/features/editor/ai/ai_citation.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/ai_config.dart';
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
import 'package:greatnote/features/editor/ink/ink_selection.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/widgets/ai_citation_highlight.dart';

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
    test('citations an earlier version saved in an answer are taken out of '
        'what is shown and of history', () {
      const String answer = 'The slope is 2. [[L5-L9]]\n\nSo it rises.';
      expect(stripAiCitations(answer), 'The slope is 2.\n\nSo it rises.');
      expect(const AiMessage.model(answer).historyText, isNot(contains('[[')));
      // What is saved still holds them, for the links to be drawn again.
      expect(const AiMessage.model(answer).wireText, contains('[[L5-L9]]'));
      // A bracket is the writer's own.
      expect(stripAiCitations('See [1]'), 'See [1]');
    });

    test('paragraphs', () {
      expect(
        parseAiAnswer('First. [[L5-L9]]\n\nSecond.\n\nThird. [[L12,L30-L20]]'),
        <String>['First.', 'Second.', 'Third.'],
      );
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
      'One.\n\n[[C 1 2 3 4]]\n\nTwo.': 2,
      '': 0,
    };
    numbering.forEach((String answer, int count) {
      test('${jsonEncode(answer)} has $count paragraphs', () {
        expect(parseAiAnswer(answer), hasLength(count));
      });
    });

    test('a citation alone on a line is no paragraph', () {
      expect(parseAiAnswer('One.\n\n[[L5-L9]]\n\nTwo.'), <String>[
        'One.',
        'Two.',
      ]);
    });
  });

  group('the notation model says what each paragraph is about', () {
    const String response =
        '<svg xmlns="http://www.w3.org/2000/svg" data-etonia-version="1" '
        'viewBox="0 0 400 400">'
        '<desc data-etonia-role="message">One.\n\nTwo.</desc>'
        '<desc data-etonia-role="citation" data-etonia-paragraph="1">'
        '[[L5-L9]]</desc>'
        '<g><desc data-etonia-role="citation" data-etonia-paragraph="2">'
        '[[L12]]</desc></g>'
        '<desc data-etonia-role="citation" data-etonia-paragraph="2">'
        '[[C 1 2 3 4]]</desc>'
        '<desc data-etonia-role="citation" data-etonia-paragraph="x">'
        '[[L1]]</desc>'
        '<desc data-etonia-role="citation">[[L2]]</desc>'
        '<desc>[[L3]]</desc>'
        '</svg>';

    test('in its citation descriptions, without having to draw', () {
      final AiAssistantResponse parsed = AiAssistantResponse.parse(response);
      expect(parsed.message, 'One.\n\nTwo.');
      expect(parsed.notation, isNull);
      expect(parsed.notationRejected, isFalse);
      expect(parsed.citations, <int, String>{
        1: '[[L5-L9]]',
        2: '[[L12]] [[C 1 2 3 4]]',
      });
      expect(AiSuccess.response(parsed).citations, parsed.citations);
    });

    test('only the notation prompt asks for citations', () {
      for (final String prompt in <String>[
        AiPrompts.textSystem,
        AiPrompts.system,
        AiPrompts.systemFor(notationEnabled: false),
      ]) {
        expect(prompt, isNot(contains('[[')));
        expect(prompt, isNot(contains('data-etonia-role="citation"')));
      }
      final String notation = AiPrompts.systemFor(notationEnabled: true);
      expect(notation, contains('data-etonia-role="citation"'));
      expect(notation, contains('[[L12-L30]]'));
      expect(notation, contains('[[C top left bottom right]]'));
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

    test('a range names only what exists, however large the number', () {
      final Stroke stroke = _line(10);
      final AiSourceMap source = AiSourceMap(
        const <SelectionSvgLine>[SelectionSvgLine(line: 5, strokeIndex: 0)],
        <Stroke?>[stroke],
      );
      final AiAnswerLinks links = source.resolve(<int, String>{
        1: '[[L1-L999999999]]',
        2: '[[L500-L600]]',
      }, paragraphs: 2);
      expect(links.paragraphs[1]!.cited, <Stroke>[stroke]);
      expect(links.paragraphs[2], isNull);
    });

    test('a range written backwards still names those lines', () {
      final Stroke stroke = _line(10);
      final AiParagraphLinks links = AiSourceMap(
        const <SelectionSvgLine>[SelectionSvgLine(line: 25, strokeIndex: 0)],
        <Stroke?>[stroke],
      ).resolve(<int, String>{1: '[[L30-L20]]'}, paragraphs: 1).paragraphs[1]!;
      expect(links.ranges, const <AiLineRange>[AiLineRange(20, 30)]);
      expect(links.cited, <Stroke>[stroke]);
    });

    test('a number past the last paragraph ties nothing', () {
      final AiAnswerLinks links = AiSourceMap(
        const <SelectionSvgLine>[SelectionSvgLine(line: 5, strokeIndex: 0)],
        <Stroke?>[_line(10)],
      ).resolve(<int, String>{0: '[[L5]]', 2: '[[L5]]'}, paragraphs: 1);
      expect(links.paragraphs, isEmpty);
    });
  });

  group('a detail of a picture is circled', () {
    const Rect picture = Rect.fromLTWH(100, 200, 400, 800);

    AiSourceMap source({Rect? shown = picture}) => AiSourceMap(
      const <SelectionSvgLine>[],
      const <Stroke?>[],
      picture: shown,
    );

    test('the citation is taken out of what is shown', () {
      expect(
        stripAiCitations('The valve. [[C 100 250 200 750]]'),
        'The valve.',
      );
      expect(stripAiCitations('Next. [[C 1, 2, 3, 4]]'), 'Next.');
    });

    test('the box lands where it says on the picture', () {
      final AiParagraphLinks links = source().resolve(<int, String>{
        1: '[[C 100 250 200 750]]',
      }, paragraphs: 1).paragraphs[1]!;
      expect(links.circles.single, const Rect.fromLTRB(200, 280, 400, 360));
      expect(links.ranges, isEmpty);
      expect(links.isEmpty, isFalse);
      expect(links.label, 'Picture');
    });

    test('a box written the wrong way round still lands there', () {
      final AiParagraphLinks links = source().resolve(<int, String>{
        1: '[[C 200 750 100 250]]',
      }, paragraphs: 1).paragraphs[1]!;
      expect(links.circles.single, const Rect.fromLTRB(200, 280, 400, 360));
    });

    test('a box past the edge stops at the edge', () {
      final AiParagraphLinks links = source().resolve(<int, String>{
        1: '[[C 900 0 5000 100]]',
      }, paragraphs: 1).paragraphs[1]!;
      expect(links.circles.single, const Rect.fromLTRB(100, 920, 140, 1000));
    });

    test('nothing is circled that is no detail of the picture', () {
      final AiAnswerLinks links = source().resolve(<int, String>{
        1: '[[C 0 0 1000 1000]]',
        2: '[[C 0 0 800 800]]',
        3: '[[C 10 10 10 90]]',
      }, paragraphs: 3);
      expect(links.paragraphs, isEmpty);
    });

    test('a paragraph gets only so many rings', () {
      final AiParagraphLinks links = source().resolve(<int, String>{
        1:
            '[[C 0 0 9 9]] [[C 10 10 19 19]] [[C 20 20 29 29]] '
            '[[C 30 30 39 39]] [[C 40 40 49 49]]',
      }, paragraphs: 1).paragraphs[1]!;
      expect(links.circles, hasLength(AiSourceMap.maxCircles));
    });

    test('with no picture sent nothing is circled', () {
      final AiAnswerLinks links = source(
        shown: null,
      ).resolve(<int, String>{1: '[[C 100 250 200 750]]'}, paragraphs: 1);
      expect(links.paragraphs, isEmpty);
    });

    test('a picture gets no line of its own', () {
      final SelectionInkSnapshot snapshot = SelectionInkSnapshot.fromStrokes(
        const <SnapshotStroke>[],
        bitmaps: <SnapshotBitmap>[
          SnapshotBitmap(
            bytes: Uint8List.fromList(<int>[1]),
            bounds: const Rect.fromLTWH(0, 0, 100, 400),
          ),
        ],
      );
      expect(snapshot.holdsPicture, isTrue);
      final SelectionSvgDocument document = const SelectionSvgRenderer()
          .document(
            snapshot: snapshot,
            preview: _preview(const Rect.fromLTWH(0, 0, 100, 400)),
            pageSize: const Size(200, 400),
          );
      expect(document.lines, isEmpty);
      expect(document.svg, isNot(contains('data-etonia-role="region"')));
    });

    test('the ring holds all of the detail, and keeps close to a long one', () {
      for (final Rect detail in <Rect>[
        const Rect.fromLTWH(100, 100, 80, 80),
        const Rect.fromLTWH(100, 100, 600, 20),
        const Rect.fromLTWH(100, 100, 20, 600),
        const Rect.fromLTWH(100, 100, 2, 2),
      ]) {
        final Rect ring = aiCitationRing(detail);
        final double a = ring.width / 2;
        final double b = ring.height / 2;
        final Offset corner = detail.topLeft - ring.center;
        expect(
          corner.dx * corner.dx / (a * a) + corner.dy * corner.dy / (b * b),
          lessThanOrEqualTo(1.0001),
          reason: '$detail in $ring',
        );
        expect(ring.center, detail.center);
      }
      expect(
        aiCitationRing(const Rect.fromLTWH(100, 100, 600, 20)).width,
        lessThan(640),
      );
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

    /// Answers as the notation model does, citing without drawing.
    void answerCiting(String message, Map<int, String> citations) {
      client.answerResponse(
        AiAssistantResponse(message: message, citations: citations),
      );
    }

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

    /// Opens on the first two strokes and asks with Notation on, the only way
    /// an answer gets citations.
    Future<void> askWithNotation() async {
      await openOnFirstTwo();
      assistant
        ..setNotationEnabled(true)
        ..send('Explain');
      await pumpEventQueue();
    }

    test('with Notation off nothing is tied to the note', () async {
      await openOnFirstTwo();
      assistant.send('Explain');
      await pumpEventQueue();
      expect(client.requests.single.selectionSvg, isNull);
      answerCiting('About the first line.', <int, String>{1: '[[L5]]'});
      await pumpEventQueue();
      expect(assistant.answerLinks(1), isNull);
      expect(assistant.paragraphFocus.value, isNull);
    });

    test('the chat model\'s words tie nothing, even when they cite', () async {
      await askWithNotation();
      client.answer('About the first line. [[L5]]\n\nNot about ink.');
      await pumpEventQueue();
      expect(assistant.answerLinks(1), isNull);
      expect(assistant.paragraphFocus.value, isNull);
    });

    test('the notation model ties the words to the note', () async {
      await askWithNotation();
      final AiRequest request = client.requests.single;
      expect(request.selectionSvg, contains('data-etonia-line="5"'));
      expect(request.selectionSvg, contains('data-etonia-line="6"'));

      answerCiting('About the first line.\n\nNot about ink.', <int, String>{
        1: '[[L5]]',
      });
      await pumpEventQueue();
      final AiParagraphLinks links = assistant.answerLinks(1)!.paragraphs[1]!;
      expect(links.cited, <Stroke>[ink.strokes[0]]);
      expect(links.label, 'L5');
      expect(assistant.answerLinks(1)!.paragraphs[2], isNull);
      expect(assistant.paragraphFocus.value?.ref, const AiParagraphRef(1, 1));
    });

    test('nothing is tied while the answer is still being written', () async {
      await askWithNotation();
      client.stream('About the first line.');
      await pumpEventQueue();
      expect(assistant.answerLinks(1), isNull);
    });

    test('words kept when the drawing fails are tied to nothing', () async {
      await askWithNotation();
      client.stream('About the first line.', isComplete: true);
      await pumpEventQueue();
      client.fail(AiFailureKind.network);
      await pumpEventQueue();
      expect(assistant.messages.last.text, 'About the first line.');
      expect(assistant.answerLinks(1), isNull);
    });

    test('a conversation about nothing has nothing to cite', () async {
      assistant
        ..setNotationEnabled(true)
        ..send('What is 2+2?');
      await pumpEventQueue();
      answerCiting('Four.', <int, String>{1: '[[L5]]'});
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
          message: 'One.\n\nTwo.',
          citations: const <int, String>{1: '[[L5]]'},
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
      expect(next.selectionSvg, contains('data-etonia-author="assistant"'));
      answerCiting('Your own drawing shows it.', <int, String>{1: '[[L7]]'});
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
          message: 'One.\n\nTwo.',
          citations: const <int, String>{1: '[[L5]]'},
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
        await askWithNotation();
        assistant.close();
        answerCiting('Words first.\n\nAbout ink.', <int, String>{2: '[[L5]]'});
        await pumpEventQueue();
        expect(assistant.paragraphFocus.value?.ref, const AiParagraphRef(1, 2));
      },
    );

    test('another conversation\'s mark does not carry over', () async {
      await askWithNotation();
      answerCiting('About ink.', <int, String>{1: '[[L5]]'});
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
      await askWithNotation();
      answerCiting('About it.', <int, String>{1: '[[L5]]'});
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
          message: 'One.\n\nTwo.',
          citations: const <int, String>{1: '[[L5]]'},
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

    group('with a picture chosen', () {
      void openPicture(AiAssistantController on) {
        final InkSelection selection = selectInk(
          ink,
          const Rect.fromLTRB(90, 90, 210, 110),
        );
        on.open(
          selection,
          brightness: Brightness.light,
          background: Colors.white,
          snapshot: SelectionInkSnapshot.of(
            selection,
            brightness: Brightness.light,
            background: Colors.white,
            bitmaps: <SnapshotBitmap>[
              SnapshotBitmap(
                bytes: Uint8List.fromList(<int>[1]),
                bounds: const Rect.fromLTWH(0, 0, 100, 50),
              ),
            ],
          ),
          page: ink,
        );
      }

      Future<void> askAboutPicture() async {
        openPicture(assistant);
        await pumpEventQueue();
        assistant
          ..setNotationEnabled(true)
          ..send('Explain');
        await pumpEventQueue();
        // The fake renderer's picture lies at 0 0 100 50.
        answerCiting('The valve.', <int, String>{1: '[[C 100 200 200 400]]'});
        await pumpEventQueue();
      }

      Map<String, Object?> saved({String Function(String)? edit}) {
        final String json = jsonEncode(assistant.toJson(index()));
        return jsonDecode(edit == null ? json : edit(json))
            as Map<String, Object?>;
      }

      test(
        'the model is told of it, and its box lands on the picture',
        () async {
          await askAboutPicture();
          expect(
            client.requests.single.selectionSvg,
            allOf(
              contains('data-etonia-role="selected-raster-context"'),
              contains('data-etonia-line="5"'),
            ),
          );
          final AiParagraphLinks links = assistant
              .answerLinks(1)!
              .paragraphs[1]!;
          expect(links.circles.single, const Rect.fromLTRB(20, 5, 40, 10));
          expect(links.cited, isEmpty);
          expect(links.label, 'Picture');
        },
      );

      testWidgets('it is ringed, never highlighted', (
        WidgetTester tester,
      ) async {
        await tester.runAsync(askAboutPicture);
        assistant.focusParagraph(const AiParagraphRef(1, 1));
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: AiCitationHighlight(assistant: assistant, page: ink),
          ),
        );
        final RenderObject layer = tester.renderObject(
          find.byKey(const ValueKey<String>('ai-citation-highlight-layer')),
        );
        expect(
          layer,
          paints..something(
            (Symbol method, List<dynamic> arguments) =>
                method == #drawOval &&
                (arguments[1] as Paint).color.toARGB32() ==
                    aiCitationRingColor.toARGB32(),
          ),
        );
        expect(layer, paintsExactlyCountTimes(#drawRRect, 0));
        expect(layer, paintsExactlyCountTimes(#saveLayer, 0));
      });

      test('the ring is saved with the note and found again', () async {
        await askAboutPicture();
        final AiAssistantController restored = make();
        addTearDown(restored.dispose);
        restored.restore(saved(), index());
        openPicture(restored);
        await pumpEventQueue();
        expect(
          restored.answerLinks(1)!.paragraphs[1]!.circles.single,
          const Rect.fromLTRB(20, 5, 40, 10),
        );
      });

      test('the bands an older note saved are left behind', () async {
        await askAboutPicture();
        final AiAssistantController restored = make();
        addTearDown(restored.dispose);
        restored.restore(
          saved(
            edit: (String json) => json.replaceAll('"circles"', '"regions"'),
          ),
          index(),
        );
        openPicture(restored);
        await pumpEventQueue();
        expect(restored.answerLinks(1), isNull);
      });
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
