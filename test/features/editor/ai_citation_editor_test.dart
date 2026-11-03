import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_assistant_controller.dart';
import 'package:greatnote/features/editor/ai/ai_citation.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/page/page_viewport.dart';
import 'package:greatnote/features/editor/widgets/ai_assistant_panel.dart';
import 'package:greatnote/features/editor/widgets/ai_citation_highlight.dart';

import '../../helpers/ai_fakes.dart';
import '../../helpers/editor_harness.dart';

Stroke _line(double y) => Stroke.fromPoints(
  style: const StrokeStyle(ink: InkPalette.ink, width: 4),
  points: <InkVector>[InkVector(100, y), InkVector(220, y)],
);

void main() {
  autoScrollTests();

  testWidgets('through the real editor: the notation model cites the selection '
      'SVG, and the strokes it draws name their paragraph', (
    WidgetTester tester,
  ) async {
    final FakeAiClient client = FakeAiClient();
    final InkController ink = await pumpEditor(
      tester,
      strokes: <Stroke>[_line(100), _line(160)],
      aiClient: client,
    );
    selectInk(ink, const Rect.fromLTRB(90, 90, 230, 170));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('AI assistant'));
    await tester.pumpAndSettle();
    await settleAi(tester);

    final AiAssistantController assistant = tester
        .widget<AiAssistantPanel>(find.byType(AiAssistantPanel))
        .controller;
    assistant.setNotationEnabled(true);
    await tester.pump();
    await tester.tap(find.text('Explain this'));
    await settleAi(tester);

    final AiRequest request = client.requests.single;
    final List<String> svgLines = request.selectionSvg!.split('\n');
    expect(svgLines[4], contains('data-etonia-line="5"'));
    expect(svgLines[5], contains('data-etonia-line="6"'));

    final Size page = request.noteImage!.logicalSize;
    final int before = ink.strokes.length;
    client.answerResponse(
      AiAssistantResponse.parse(
        '<svg xmlns="http://www.w3.org/2000/svg" data-etonia-version="1" '
        'viewBox="0 0 ${page.width} ${page.height}" '
        'data-etonia-bounds="100 200 200 80">'
        '<desc data-etonia-role="message">The first line says this.\n\n'
        'The second says that.</desc>'
        '<desc data-etonia-role="citation" data-etonia-paragraph="1">[[L5]]'
        '</desc>'
        '<desc data-etonia-role="citation" data-etonia-paragraph="2">[[L6]]'
        '</desc>'
        '<line data-etonia-paragraph="2" x1="100" y1="210" x2="280" '
        'y2="210" stroke="black"/>'
        '<text data-etonia-paragraph="1" x="100" y="260" '
        'font-size="16">ok</text>'
        '</svg>',
      ),
    );
    await tester.pumpAndSettle();

    final List<Stroke> added = ink.strokes.sublist(before);
    expect(added, isNotEmpty);
    final AiAnswerLinks links = assistant.answerLinks(1)!;
    expect(links.paragraphs[1]!.cited, <Stroke>[ink.strokes[0]]);
    expect(links.paragraphs[2]!.cited, <Stroke>[ink.strokes[1]]);
    // The line for one paragraph, the handwriting for the other: all of it
    // tied to something, none of it to both.
    expect(links.paragraphs[2]!.drawn, isNotEmpty);
    expect(links.paragraphs[1]!.drawn, isNotEmpty);
    expect(
      links.paragraphs[1]!.drawn.length + links.paragraphs[2]!.drawn.length,
      added.length,
    );

    // On show, highlighted, and with its citation under it.
    expect(assistant.paragraphFocus.value, isNotNull);
    expect(
      find.byKey(const ValueKey<String>('ai-citation-highlight-layer')),
      findsWidgets,
    );
    expect(find.text('L5'), findsOneWidget);
    expect(find.text('L6'), findsOneWidget);
    expect(find.textContaining('[['), findsNothing);

    // Pressing a citation reads that paragraph and is safe on the note.
    await tester.tap(find.text('L5'));
    await tester.pumpAndSettle();
    expect(assistant.paragraphFocus.value?.ref, const AiParagraphRef(1, 1));
    expect(tester.takeException(), isNull);

    // Selecting what was drawn for the second paragraph finds its words.
    final Stroke drawnForSecond = links.paragraphs[2]!.drawn.first;
    final Rect box = drawnForSecond.bounds.inflate(4);
    selectInk(ink, box);
    await tester.pumpAndSettle();
    expect(assistant.paragraphFocus.value?.ref, const AiParagraphRef(1, 2));
    expect(tester.takeException(), isNull);
  });
}

void autoScrollTests() {
  testWidgets('the note follows the paragraph being read only when its ink is '
      'not all in view', (WidgetTester tester) async {
    final FakeAiClient client = FakeAiClient();
    final InkController ink = await pumpEditor(
      tester,
      strokes: <Stroke>[_line(200), _line(230), _line(1110)],
      aiClient: client,
    );
    selectInk(ink, const Rect.fromLTRB(90, 190, 230, 1120));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('AI assistant'));
    await tester.pumpAndSettle();
    await settleAi(tester);
    final AiAssistantController assistant = tester
        .widget<AiAssistantPanel>(find.byType(AiAssistantPanel))
        .controller;
    assistant.setNotationEnabled(true);
    await tester.pump();
    assistant.send('Explain');
    await settleAi(tester);
    final Finder layer = find.byType(AiCitationHighlight).first;
    client.answerResponse(
      const AiAssistantResponse(
        message: 'The top.\n\nAlso the top.\n\nFar down.',
        citations: <int, String>{1: '[[L5]]', 2: '[[L6]]', 3: '[[L7]]'},
      ),
    );
    await tester.pumpAndSettle();

    // Reading the top of the page brings the top into view...
    assistant.focusParagraph(const AiParagraphRef(1, 1));
    await tester.pumpAndSettle();
    final Offset start = tester.getTopLeft(layer);
    // ...and the next paragraph's ink is already there: nothing moves.
    assistant.focusParagraph(const AiParagraphRef(1, 2));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(layer), start);

    // Out of view: the note comes to it, and it ends up on screen.
    assistant.focusParagraph(const AiParagraphRef(1, 3));
    await tester.pumpAndSettle();
    final Offset moved = tester.getTopLeft(layer);
    expect(moved.dy, lessThan(start.dy));
    final Rect area = tester.getRect(find.byType(PageViewport));
    final RenderBox box = tester.renderObject<RenderBox>(layer);
    expect(area.contains(box.localToGlobal(const Offset(100, 1110))), isTrue);
    expect(area.contains(box.localToGlobal(const Offset(220, 1110))), isTrue);

    // In view now: going back to the same one again moves nothing.
    assistant.focusParagraph(const AiParagraphRef(1, 3));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(layer), moved);
    expect(tester.takeException(), isNull);
  });
}
