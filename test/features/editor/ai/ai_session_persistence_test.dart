import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_assistant_controller.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/ai_config.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/ai/note_image_renderer.dart';
import 'package:greatnote/features/editor/document_io/document_models.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_notation.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/ink_selection.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/page/note_document.dart';
import 'package:greatnote/features/library/note_content.dart';

import '../../../helpers/ai_fakes.dart';

Stroke _line(double y) {
  return Stroke.fromPoints(
    style: const StrokeStyle(ink: InkPalette.ink, width: 4),
    points: <InkVector>[InkVector(100, y), InkVector(200, y)],
  );
}

InkSelection _selectionOf(InkController ink, List<int> indices) {
  final List<Stroke> strokes = <Stroke>[
    for (final int index in indices) ink.strokes[index],
  ];
  return InkSelection(
    indices: indices,
    strokes: strokes,
    frame: frameAround(strokes),
  );
}

AiInkIndex _indexOf(InkController ink) {
  return AiInkIndex(<(List<Stroke>, List<NoteImageElement>)>[
    (ink.strokes, ink.images),
  ]);
}

/// What the note file would hold: the session through JSON text and back.
Map<String, Object?> _throughJson(Map<String, Object?> json) {
  return jsonDecode(jsonEncode(json)) as Map<String, Object?>;
}

void main() {
  test('conversations survive closing and reopening the note', () async {
    // The first session: two lines, one conversation answered with a
    // drawing, and one left waiting for its answer.
    final InkController ink = InkController(
      strokes: <Stroke>[_line(100), _line(300), _line(500)],
    );
    final FakeAiClient client = FakeAiClient();
    final AiAssistantController first = AiAssistantController(
      client: client,
      renderer: FakeSelectionImageRenderer(),
      captureNote: () async => NoteImage(
        png: Uint8List.fromList(<int>[1]),
        width: 10,
        height: 10,
        scale: 1,
        logicalSize: const Size(10, 10),
        revision: 0,
      ),
      // Stands in for the editor, which reports the strokes it added.
      applyNotation: (AiNotation _, NoteImage _) => AiNotationApplication(
        AiNotationStatus.applied,
        strokes: <Stroke>[ink.strokes[2]],
      ),
    );
    addTearDown(ink.dispose);
    addTearDown(first.dispose);

    first.open(
      _selectionOf(ink, <int>[0]),
      brightness: Brightness.light,
      background: Colors.white,
    );
    await pumpEventQueue();
    int saves = 0;
    first.sessionListenable.addListener(() => saves++);
    first
      ..setNotationEnabled(true)
      ..sendQuickAction(AiQuickAction.values.first);
    await pumpEventQueue();
    final AiNotation notation = AiNotation(
      label: 'Line',
      items: <AiNotationItem>[
        AiNotationStroke(
          ink: 'green',
          width: 3,
          points: const <AiNotationPoint>[
            AiNotationPoint(0.2, 0.2),
            AiNotationPoint(0.3, 0.3),
          ],
        ),
      ],
    );
    client.answerResponse(
      AiAssistantResponse(message: 'Drawn.', notation: notation),
    );
    await pumpEventQueue();
    expect(saves, 2, reason: 'the question, then the answer');

    first.open(
      _selectionOf(ink, <int>[1]),
      brightness: Brightness.light,
      background: Colors.white,
    );
    await pumpEventQueue();
    first.send('Still thinking?');
    await pumpEventQueue();

    final Map<String, Object?> saved = _throughJson(
      first.toJson(_indexOf(ink))!,
    );

    // Reopened: the same ink read back from the file, as new objects.
    final InkController reopened = InkController(
      strokes: <Stroke>[
        for (final Stroke stroke in ink.strokes)
          Stroke.fromPoints(style: stroke.style, points: stroke.points),
      ],
    );
    final FakeSelectionImageRenderer renderer = FakeSelectionImageRenderer();
    final AiAssistantController second = AiAssistantController(
      client: FakeAiClient(),
      renderer: renderer,
    );
    addTearDown(reopened.dispose);
    addTearDown(second.dispose);
    second.restore(saved, _indexOf(reopened));
    expect(renderer.snapshots, isEmpty, reason: 'drawn only when resumed');

    // Selecting the drawing finds the conversation it came from.
    second.open(
      _selectionOf(reopened, <int>[2]),
      brightness: Brightness.light,
      background: Colors.white,
    );
    await pumpEventQueue();
    expect(second.messages, hasLength(2));
    expect(second.messages[0].label, AiQuickAction.values.first.label);
    expect(second.messages[0].text, AiQuickAction.values.first.prompt);
    expect(second.messages[1].text, 'Drawn.');
    expect(second.messages[1].notation?.label, 'Line');
    expect(second.messages[1].notationStatus, AiNotationStatus.applied);
    expect(
      second.context!.snapshot.strokes.single.points,
      ink.strokes[0].points,
    );
    expect(second.context!.image, isNotNull);
    expect(second.canSend, isTrue);

    // The unanswered question can be asked again.
    second.open(
      _selectionOf(reopened, <int>[1]),
      brightness: Brightness.light,
      background: Colors.white,
    );
    await pumpEventQueue();
    expect(second.messages.single.text, 'Still thinking?');
    expect(second.requestState, AiRequestState.failed);
    expect(second.failure?.kind, AiFailureKind.interrupted);
  });

  test('a conversation whose ink has all gone is forgotten', () async {
    final InkController ink = InkController(strokes: <Stroke>[_line(100)]);
    final FakeAiClient client = FakeAiClient();
    final AiAssistantController assistant = AiAssistantController(
      client: client,
      renderer: FakeSelectionImageRenderer(),
    );
    addTearDown(ink.dispose);
    addTearDown(assistant.dispose);
    assistant.open(
      _selectionOf(ink, <int>[0]),
      brightness: Brightness.light,
      background: Colors.white,
    );
    await pumpEventQueue();
    assistant.send('Hello');
    await pumpEventQueue();
    client.answer('Hi.');
    await pumpEventQueue();

    final InkController empty = InkController();
    addTearDown(empty.dispose);
    final AiAssistantController reopened = AiAssistantController(
      client: FakeAiClient(),
      renderer: FakeSelectionImageRenderer(),
    );
    addTearDown(reopened.dispose);
    reopened.restore(
      _throughJson(assistant.toJson(_indexOf(ink))!),
      _indexOf(empty),
    );
    expect(reopened.toJson(_indexOf(empty)), isNull);
  });

  test('saved bitmaps are kept from cleanup', () {
    expect(
      AiAssistantController.referencedAssets(<String, Object?>{
        'version': aiSessionVersion,
        'conversations': <Object?>[
          <String, Object?>{
            'snapshot': <String, Object?>{
              'bitmaps': <Object?>[
                <String, Object?>{'asset': 'photo'},
                <String, Object?>{'asset': 'scan', 'pdfPage': 0},
              ],
            },
          },
        ],
      }),
      <String>{'photo', 'scan'},
    );
  });

  test('a looping AI drawing plays again when the note is reopened', () {
    final InkController ink = InkController(strokes: <Stroke>[_line(100)]);
    addTearDown(ink.dispose);
    expect(
      ink.addAiNotation(
        traces: <GeneratedInkTrace>[
          GeneratedInkTrace(
            style: const StrokeStyle(ink: InkPalette.ink, width: 3),
            points: <InkVector>[
              const InkVector(20, 20),
              const InkVector(60, 40),
              const InkVector(90, 90),
            ],
            timesMs: <double>[0, 200, 600],
          ),
        ],
        expectedRevision: ink.documentRevision,
        surfaceSize: const Size(400, 300),
        playbackDuration: const Duration(milliseconds: 900),
      ),
      AddNotationResult.addedWithPlayback,
    );
    final NoteDocument document = NoteDocument(
      pages: <NotePage>[NotePage(ink: ink, ownsInk: false)],
    )..aiSession = <String, Object?>{'version': aiSessionVersion};
    addTearDown(document.dispose);

    final NoteContent read = NoteContent.fromJson(
      _throughJson(NoteContent.fromDocument(document).toJson()),
    );
    final NoteDocument reopened = read.toDocument();
    addTearDown(reopened.dispose);

    final InkController page = reopened.pages.single.ink;
    expect(page.strokes, hasLength(2));
    final playback = page.notationPlayback!;
    expect(playback.strokes.single, same(page.strokes[1]));
    expect(playback.timesAt(0), <double>[0, 200, 600]);
    expect(playback.duration, const Duration(milliseconds: 900));
    expect(playback.surfaceSize, const Size(400, 300));
    expect(page.isPlayingStroke(page.strokes[0]), isFalse);
    expect(reopened.aiSession, <String, Object?>{'version': aiSessionVersion});
  });

  test('a finished drawing is saved as ordinary ink', () {
    final InkController ink = InkController();
    addTearDown(ink.dispose);
    ink.addAiNotation(
      traces: <GeneratedInkTrace>[
        GeneratedInkTrace(
          style: const StrokeStyle(ink: InkPalette.ink, width: 3),
          points: <InkVector>[const InkVector(20, 20), const InkVector(60, 40)],
          timesMs: <double>[0, 200],
        ),
      ],
      expectedRevision: ink.documentRevision,
      surfaceSize: const Size(400, 300),
      playbackDuration: const Duration(milliseconds: 300),
    );
    ink.finishNotationPlayback();
    final NoteDocument document = NoteDocument(
      pages: <NotePage>[NotePage(ink: ink, ownsInk: false)],
    );
    addTearDown(document.dispose);
    final NoteContent content = NoteContent.fromDocument(document);
    expect(content.pages.single.playbacks, isEmpty);
    expect(content.toJson().containsKey('ai'), isFalse);
  });
}
