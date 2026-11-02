import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/features/editor/ai/ai_assistant_controller.dart';
import 'package:greatnote/features/editor/ai/ai_citation.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/ai/note_image_renderer.dart';
import 'package:greatnote/features/editor/document_io/svg_document.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/widgets/ai_assistant_panel.dart';
import 'package:greatnote/features/editor/widgets/ai_citation_highlight.dart';

import '../../../helpers/ai_fakes.dart';

Stroke _line(double y) => Stroke.fromPoints(
  style: const StrokeStyle(ink: InkPalette.ink, width: 4),
  points: <InkVector>[InkVector(100, y), InkVector(200, y)],
);

Finder _chip(String label) => find.bySemanticsLabel(label);

void main() {
  late InkController ink;
  late FakeAiClient client;
  late AiAssistantController assistant;
  int shownOnNote = 0;
  List<Stroke> drawn = const <Stroke>[];

  /// A long paragraph, tall enough that the transcript must scroll.
  String long(String word) => List<String>.filled(120, word).join(' ');

  Future<void> pumpEditor(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Row(
            children: <Widget>[
              SizedBox(
                width: 400,
                child: AiAssistantPanel(
                  controller: assistant,
                  onClose: () {},
                  onNewChat: () {},
                  onAddToContext: () {},
                  onShowOnNote: () => shownOnNote++,
                ),
              ),
              Expanded(
                child: Stack(
                  children: <Widget>[
                    AiCitationHighlight(assistant: assistant, page: ink),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> ask(WidgetTester tester, String answer) async {
    await tester.runAsync(() async {
      assistant.open(
        selectInk(ink, const Rect.fromLTRB(90, 90, 210, 310)),
        brightness: Brightness.light,
        background: Colors.white,
      );
      await pumpEventQueue();
    });
    await tester.pump();
    assistant.setNotationEnabled(true);
    await tester.runAsync(() async {
      assistant.send('Explain');
      await pumpEventQueue();
      client.answerResponse(
        AiAssistantResponse(
          message: answer,
          notation: AiNotation.vector(
            EditableSvg.parse(
              '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">'
              '<path d="M1 1 L9 9"/></svg>',
            ),
          ),
        ),
      );
      await pumpEventQueue();
    });
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  setUp(() {
    shownOnNote = 0;
    ink = InkController(strokes: <Stroke>[_line(100), _line(300), _line(500)]);
    drawn = <Stroke>[ink.strokes[2]];
    client = FakeAiClient();
    assistant = AiAssistantController(
      client: client,
      renderer: FakeSelectionImageRenderer(),
      captureNote: () async =>
          NoteImage(logicalSize: const Size(400, 400), revision: 0),
      applyNotation: (AiNotation _, NoteImage _) => AiNotationApplication(
        AiNotationStatus.applied,
        strokes: drawn,
        paragraphs: const <int?>[3],
      ),
    );
  });

  tearDown(() {
    assistant.dispose();
    ink.dispose();
  });

  testWidgets('citations show after their paragraphs, not in the words', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await pumpEditor(tester);
    await ask(tester, 'About the first. [[L5]]\n\nA short aside.');

    expect(find.textContaining('[['), findsNothing);
    expect(find.textContaining('About the first.'), findsOneWidget);
    expect(_chip('Show on the note: L5'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('scrolling the chat moves the highlight from paragraph to '
      'paragraph, and on to the strokes drawn for one', (
    WidgetTester tester,
  ) async {
    await pumpEditor(tester);
    await ask(
      tester,
      '${long('first')} [[L5]]\n\n'
      '${long('second')} [[L6]]\n\n'
      '${long('third')}',
    );

    // A new answer scrolls the transcript to its end.
    expect(assistant.paragraphFocus.value?.ref, const AiParagraphRef(1, 3));
    expect(assistant.paragraphFocus.value!.links.drawn, <Stroke>[
      ink.strokes[2],
    ]);
    expect(
      find.byKey(const ValueKey<String>('ai-citation-highlight-layer')),
      findsOneWidget,
    );

    final Finder list = find.byType(ListView);
    final ScrollPosition position = tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)).first,
        )
        .position;
    position.jumpTo(0);
    await tester.pump();
    await tester.pump();
    expect(assistant.paragraphFocus.value?.ref, const AiParagraphRef(1, 1));
    expect(assistant.paragraphFocus.value!.links.cited, <Stroke>[
      ink.strokes[0],
    ]);
  });

  testWidgets('a citation pressed shows its paragraph on the note, and stays '
      'the one being read until the user scrolls', (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await pumpEditor(tester);
    await ask(tester, 'Short one. [[L5]]\n\nShort two. [[L6]]');

    await tester.tap(_chip('Show on the note: L5'));
    await tester.pump();
    await tester.pump();
    expect(shownOnNote, 1);
    expect(assistant.paragraphFocus.value?.ref, const AiParagraphRef(1, 1));
    semantics.dispose();
  });

  testWidgets('selecting a drawing scrolls the chat to its words', (
    WidgetTester tester,
  ) async {
    await pumpEditor(tester);
    await ask(
      tester,
      '${long('first')} [[L5]]\n\n'
      '${long('second')} [[L6]]\n\n'
      '${long('third')}',
    );
    final Finder list = find.byType(ListView);
    final ScrollPosition position = tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)).first,
        )
        .position;
    position.jumpTo(0);
    await tester.pump();
    await tester.pump();
    expect(position.pixels, 0);

    assistant.updateCurrentSelection(
      selectInk(ink, const Rect.fromLTRB(90, 490, 210, 510)),
    );
    await tester.pumpAndSettle();

    expect(position.pixels, greaterThan(0));
    expect(assistant.paragraphFocus.value?.ref, const AiParagraphRef(1, 3));
  });

  testWidgets('an answer citing nothing reads as it always has', (
    WidgetTester tester,
  ) async {
    assistant = AiAssistantController(
      client: client,
      renderer: FakeSelectionImageRenderer(),
    );
    await pumpEditor(tester);
    await tester.runAsync(() async {
      assistant.open(
        selectInk(ink, const Rect.fromLTRB(90, 90, 210, 310)),
        brightness: Brightness.light,
        background: Colors.white,
      );
      await pumpEventQueue();
    });
    await tester.pump();
    await tester.runAsync(() async {
      assistant.send('Explain');
      await pumpEventQueue();
      client.answer('Nothing cited.\n\nStill nothing.');
      await pumpEventQueue();
    });
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Nothing cited.'), findsOneWidget);
    expect(assistant.paragraphFocus.value, isNull);
    expect(
      find.byKey(const ValueKey<String>('ai-citation-highlight-layer')),
      findsNothing,
    );
  });
}
