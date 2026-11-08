import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/backend/backend_service.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/backend_ai_client.dart';
import 'package:greatnote/features/editor/ai/notation_space.dart';
import 'package:greatnote/features/editor/ai/note_image_renderer.dart';
import 'package:greatnote/features/editor/ai/streaming_ai_client.dart';

void main() {
  group('routing preview', () {
    AiRequest request() => AiRequest(
      systemInstruction: 'Use the note as source.',
      legacySystemInstruction: 'Legacy instruction',
      imagePng: Uint8List.fromList([1, 2, 3]),
      routing: const AiRouting(
        task: AiRouteTask.studyAnswer,
        needsVision: true,
      ),
      responseFormat: AiResponseFormat.text,
      messages: const [AiMessage.user('Explain this diagram.')],
    );
    test(
      'returns the selected model without requiring an answer or token usage',
      () async {
        final calls = <Map<String, Object?>>[];
        final client = BackendAiClient(
          invoke: (_, body) async {
            calls.add(body);
            return {
              'routePreview': true,
              'servedBy': {'model': 'luna', 'effort': 'medium'},
            };
          },
        );
        addTearDown(client.close);
        final result = await client.previewRoute(request()) as AiSuccess;
        expect(result.servedBy, AiModelId.luna);
        expect(result.usage, isNull);
        expect(calls, hasLength(1));
        expect(calls.single['routeOnly'], true);
        expect(calls.single['model'], 'auto');
        expect(calls.single['prompt'], 'Explain this diagram.');
        expect(calls.single['selectedImage'], base64Encode([1, 2, 3]));
        expect((calls.single['routing'] as Map)['needsVision'], true);
      },
    );
    test(
      'an old server rejection never falls back to paid answer execution',
      () async {
        var calls = 0;
        final client = BackendAiClient(
          invoke: (_, _) async {
            calls++;
            throw const BackendFailure('rejected');
          },
        );
        addTearDown(client.close);
        final result = await client.previewRoute(request()) as AiError;
        expect(result.failure.kind, AiFailureKind.rejected);
        expect(calls, 1);
      },
    );
    test(
      'ordinary answer payloads are not mistaken for route decisions',
      () async {
        final client = BackendAiClient(
          invoke: (_, _) async => {
            'answer': 'Unexpected answer',
            'servedBy': {'model': 'haiku'},
            'usage': {'inputTokens': 1, 'outputTokens': 1},
          },
        );
        addTearDown(client.close);
        final result = await client.previewRoute(request()) as AiError;
        expect(result.failure.kind, AiFailureKind.malformed);
      },
    );
  });
  test('shows the completed chat answer before notation finishes', () async {
    final Completer<void> notation = Completer<void>();
    final List<(String, bool)> partials = <(String, bool)>[];
    final client = BackendAiClient(
      invokeStream: (_, _) async => (() async* {
        yield <String, dynamic>{
          'type': 'message',
          'message': 'The answer is 42.',
        };
        await notation.future;
        yield <String, dynamic>{
          'type': 'result',
          'answer':
              '<svg xmlns="http://www.w3.org/2000/svg" '
              'data-etonia-version="1" viewBox="0 0 100 100" '
              'data-etonia-bounds="10 10 80 20">'
              '<title>Answer</title>'
              '<desc data-etonia-role="message">The answer is 42.</desc>'
              '<path d="M10 20 L90 20" fill="none" stroke="black"/>'
              '</svg>',
          'usage': <String, dynamic>{'inputTokens': 10, 'outputTokens': 20},
        };
      })(),
    );
    final Future<AiResult> pending = client.send(
      AiRequest(
        systemInstruction: 'words',
        notationInstruction: 'drawing',
        notationEnabled: true,
        imagePng: Uint8List.fromList(<int>[1]),
        noteImage: NoteImage(
          logicalSize: const Size(100, 100),
          revision: 0,
          normalizedFocusBounds: const Rect.fromLTRB(.1, .1, .9, .9),
        ),
        messages: const <AiMessage>[AiMessage.user('Explain it')],
      ),
      onPartial: (String message, bool complete) =>
          partials.add((message, complete)),
    );

    await pumpEventQueue();
    expect(partials, <(String, bool)>[('The answer is 42.', true)]);

    notation.complete();
    final AiSuccess answer = await pending as AiSuccess;
    expect(answer.notation?.vector, isNotNull);
  });

  group('live notation', () {
    const String answer =
        '<svg xmlns="http://www.w3.org/2000/svg" '
        'data-etonia-version="1" viewBox="0 0 100 100" '
        'data-etonia-bounds="10 10 80 20">'
        '<desc data-etonia-role="message">Done.</desc>'
        '<path d="M10 20 L90 20" fill="none" stroke="black"/>'
        '</svg>';
    AiRequest request() => AiRequest(
      systemInstruction: 'words',
      notationInstruction: 'drawing',
      notationEnabled: true,
      imagePng: Uint8List.fromList(<int>[1]),
      noteImage: NoteImage(
        logicalSize: const Size(100, 100),
        revision: 0,
        normalizedFocusBounds: const Rect.fromLTRB(.1, .1, .9, .9),
      ),
      messages: const <AiMessage>[AiMessage.user('Explain it')],
    );

    test('tells the listener the SVG as it grows', () async {
      Map<String, Object?>? sent;
      final List<String> written = <String>[];
      final client = BackendAiClient(
        invokeStream: (_, Map<String, Object?> body) async {
          sent = body;
          return Stream<Map<String, dynamic>>.fromIterable(
            <Map<String, dynamic>>[
              <String, dynamic>{'type': 'message', 'message': 'Done.'},
              <String, dynamic>{'type': 'notation', 'delta': '<svg>'},
              // Only for display: a bad one is not a failed answer.
              <String, dynamic>{'type': 'notation', 'delta': 7},
              <String, dynamic>{'type': 'notation', 'delta': '<g/>'},
              <String, dynamic>{
                'type': 'result',
                'answer': answer,
                'usage': <String, dynamic>{'inputTokens': 1, 'outputTokens': 2},
              },
            ],
          );
        },
      );
      final AiResult result = await client.send(
        request(),
        onNotation: written.add,
      );
      expect(sent?['liveNotation'], isTrue);
      expect(written, <String>['<svg>', '<svg><g/>']);
      expect((result as AiSuccess).notation?.vector, isNotNull);
    });

    test('is not asked for without a listener', () async {
      Map<String, Object?>? sent;
      final client = BackendAiClient(
        invokeStream: (_, Map<String, Object?> body) async {
          sent = body;
          return Stream<Map<String, dynamic>>.value(<String, dynamic>{
            'type': 'result',
            'answer': answer,
            'usage': <String, dynamic>{'inputTokens': 1, 'outputTokens': 2},
          });
        },
      );
      await client.send(request());
      expect(sent!.containsKey('liveNotation'), isFalse);
    });
  });

  test(
    'conversation history, current prompt, and selected crop are sent but the full note is not',
    () async {
      Map<String, Object?>? sent;
      final client = BackendAiClient(
        invoke: (name, body) async {
          expect(name, 'ai');
          sent = body;
          return {
            'answer': '{"version":2,"message":"answer","notation":null}',
            'usage': {'inputTokens': 10, 'outputTokens': 20},
          };
        },
      );
      final result = await client.send(
        AiRequest(
          systemInstruction: 'public instructions',
          imagePng: Uint8List.fromList([1, 2, 3]),
          model: AiModelId.sol,
          notationEnabled: true,
          notationInstruction: 'drawing instructions',
          noteImage: NoteImage(
            logicalSize: const Size(100, 200),
            revision: 7,
            normalizedFocusBounds: const Rect.fromLTRB(.1, .2, .3, .4),
          ),
          messages: const [
            AiMessage.user('OLD PRIVATE QUESTION'),
            AiMessage.model('OLD PRIVATE ANSWER'),
            AiMessage.user('CURRENT QUESTION'),
          ],
        ),
      );
      expect(result, isA<AiSuccess>());
      expect(sent!['prompt'], 'CURRENT QUESTION');
      expect(sent!['history'], <Map<String, String>>[
        <String, String>{'role': 'user', 'content': 'OLD PRIVATE QUESTION'},
        <String, String>{'role': 'assistant', 'content': 'OLD PRIVATE ANSWER'},
      ]);
      expect(sent!['selectedImage'], base64Encode([1, 2, 3]));
      final encoded = jsonEncode(sent);
      expect(encoded, contains('OLD PRIVATE QUESTION'));
      expect(encoded, contains('OLD PRIVATE ANSWER'));
      expect(
        encoded,
        isNot(contains(base64Encode(utf8.encode('FULL PRIVATE NOTE')))),
      );
      expect(
        sent!.keys,
        unorderedEquals([
          'requestId',
          'model',
          'prompt',
          'history',
          'systemInstruction',
          'notationInstruction',
          'animationAllowed',
          'noteMetadata',
          'selectedImage',
          'notationContext',
        ]),
      );
      // SVG is generated directly, so no legacy JSON response schema is sent.
      expect(sent, isNot(contains('responseSchema')));
      expect(sent!['requestId'], matches(RegExp(r'^[a-f0-9-]{36}$')));
    },
  );
  test('history keeps the latest twelve complete turns', () async {
    Map<String, Object?>? sent;
    final client = BackendAiClient(
      invoke: (_, body) async {
        sent = body;
        return {
          'answer': '{"version":2,"message":"answer","notation":null}',
          'usage': {'inputTokens': 10, 'outputTokens': 20},
        };
      },
    );
    await client.send(
      AiRequest(
        systemInstruction: '',
        imagePng: Uint8List.fromList([1]),
        messages: <AiMessage>[
          for (int turn = 0; turn < 51; turn++) ...<AiMessage>[
            AiMessage.user('question $turn'),
            AiMessage.model('answer $turn'),
          ],
          const AiMessage.user('current'),
        ],
      ),
    );

    final history = sent!['history']! as List<Map<String, String>>;
    expect(history, hasLength(24));
    expect(history.first, {'role': 'user', 'content': 'question 39'});
    expect(history.last['role'], 'assistant');
    expect(history.last['content'], contains('answer 50'));
  });
  test(
    'history compacts old turns, uses quick-action labels, and keeps recent answers',
    () async {
      Map<String, Object?>? sent;
      final client = BackendAiClient(
        invoke: (_, body) async {
          sent = body;
          return {
            'answer': '{"version":2,"message":"answer","notation":null}',
            'usage': {'inputTokens': 10, 'outputTokens': 20},
          };
        },
      );
      final String longAnswer = List<String>.filled(600, 'word').join(' ');
      await client.send(
        AiRequest(
          systemInstruction: '',
          imagePng: Uint8List.fromList([1]),
          messages: <AiMessage>[
            AiMessage.user(
              List<String>.filled(200, 'prompt').join(' '),
              label: 'Explain this',
            ),
            AiMessage.model('$longAnswer\n\n$longAnswer'),
            const AiMessage.user('Why?'),
            AiMessage.model(longAnswer),
            const AiMessage.user('current'),
          ],
        ),
      );

      final history = sent!['history']! as List<Map<String, String>>;
      expect(history, hasLength(4));
      expect(history[0]['content'], 'Explain this');
      expect(history[1]['content']!.length, lessThanOrEqualTo(4002));
      expect(history[1]['content'], endsWith('…'));
      expect(history[2]['content'], 'Why?');
      expect(history[3]['content'], longAnswer);
    },
  );

  test('with Notation on, the note goes as coordinates apart from the fixed '
      'instruction, and the selection is kept to the paper', () async {
    Map<String, Object?>? sent;
    final client = BackendAiClient(
      invoke: (_, body) async {
        sent = body;
        return {
          'answer': '{"version":2,"message":"answer","notation":null}',
          'usage': {'inputTokens': 10, 'outputTokens': 20},
        };
      },
    );
    final NoteImage note = NoteImage(
      logicalSize: const Size(480, 480),
      revision: 0,
      // The crop's padding runs past the top-left corner.
      normalizedFocusBounds: const Rect.fromLTRB(-.02, -.01, .3, .4),
      space: NoteFreeSpace.measure(
        pageSize: const Size(480, 480),
        blocks: const [Rect.fromLTRB(0, 0, 240, 240)],
        focus: const Rect.fromLTRB(0, 0, 144, 192),
      ),
    );
    await client.send(
      AiRequest(
        systemInstruction: 'public instructions',
        imagePng: Uint8List.fromList([1, 2, 3]),
        selectionSvg:
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 480 480" '
            'data-etonia-coordinate-space="note" '
            'data-etonia-selection-bounds="0 0 144 192">'
            '<path d="M1 2 L3 4"/></svg>',
        notationEnabled: true,
        notationInstruction: 'drawing instructions',
        noteImage: note,
        messages: const [AiMessage.user('Draw it')],
      ),
    );

    // The fixed instruction alone, so providers can cache it.
    expect(sent!['systemInstruction'], 'public instructions');
    expect(sent!['notationInstruction'], 'drawing instructions');
    expect(sent!['animationAllowed'], isFalse);
    expect(sent!['selectedImage'], base64Encode([1, 2, 3]));
    expect(sent!['selectedSvg'], contains('<path d="M1 2 L3 4"/>'));
    expect(sent!['noteMetadata'], aiNoteMetadata(note));
    expect(sent!['noteMetadata'], contains('"free_areas"'));
    expect(sent!['notationContext'], {
      'width': 480.0,
      'height': 480.0,
      'left': 0.0,
      'top': 0.0,
      'right': .3,
      'bottom': .4,
    });
  });

  test(
    'when selection focus bounds collapse at page edge, notation is omitted',
    () async {
      Map<String, Object?>? sent;
      final client = BackendAiClient(
        invoke: (_, body) async {
          sent = body;
          return {
            'answer': '{"version":2,"message":"answer","notation":null}',
            'usage': {'inputTokens': 10, 'outputTokens': 20},
          };
        },
      );
      final NoteImage note = NoteImage(
        logicalSize: const Size(480, 480),
        revision: 0,
        // Selection fully off the right edge: both clamp to 1.0.
        normalizedFocusBounds: const Rect.fromLTRB(1.05, 0.2, 1.2, 0.5),
        space: NoteFreeSpace.measure(
          pageSize: const Size(480, 480),
          blocks: const [],
          focus: const Rect.fromLTRB(480, 96, 480, 240),
        ),
      );
      await client.send(
        AiRequest(
          systemInstruction: 'public instructions',
          imagePng: Uint8List.fromList([1, 2, 3]),
          selectionSvg:
              '<svg xmlns="http://www.w3.org/2000/svg" '
              'viewBox="0 0 480 480" data-etonia-coordinate-space="note" '
              'data-etonia-selection-bounds="504 96 72 144"></svg>',
          notationEnabled: true,
          notationInstruction: 'drawing instructions',
          noteImage: note,
          messages: const [AiMessage.user('Draw it')],
        ),
      );

      expect(sent!['notationContext'], isNull);
      expect(sent!['selectedSvg'], isNull);
      expect(sent!['notationInstruction'], isNull);
    },
  );

  test('an answer cut off by the output limit is reported as unreadable, '
      'not as a lost connection, and keeps words that all arrived', () async {
    final List<(String, bool)> partials = <(String, bool)>[];
    final client = BackendAiClient(
      invoke: (_, _) async => {
        // Cut off in the drawing, as Claude Haiku answered at its limit.
        'answer':
            '{"version":2,"message":"The hypotenuse is 5.","notation":'
            '{"label":"Working","items":[{"type":"text","text":"c = √25 = 5',
        'usage': {'inputTokens': 6438, 'outputTokens': 4096},
      },
    );
    final result = await client.send(
      AiRequest(
        systemInstruction: '',
        imagePng: Uint8List.fromList([1]),
        messages: const [AiMessage.user('Solve it')],
      ),
      onPartial: (String message, bool complete) =>
          partials.add((message, complete)),
    );

    expect((result as AiError).failure.kind, AiFailureKind.malformed);
    expect(partials, [('The hypotenuse is 5.', true)]);
  });

  test(
    'backend denial is reported without retrying or falling back to a provider',
    () async {
      int calls = 0;
      final client = BackendAiClient(
        invoke: (_, _) async {
          calls++;
          throw const BackendFailure('insufficient_credits');
        },
      );
      final result = await client.send(
        AiRequest(
          systemInstruction: '',
          imagePng: Uint8List(0),
          messages: const [AiMessage.user('question')],
        ),
      );
      expect(
        (result as AiError).failure.kind,
        AiFailureKind.insufficientCredits,
      );
      expect(calls, 1);
    },
  );

  test('a first question sends no history field', () async {
    Map<String, Object?>? sent;
    final client = BackendAiClient(
      invoke: (_, body) async {
        sent = body;
        return {
          'answer': '{"version":2,"message":"answer","notation":null}',
          'usage': {'inputTokens': 10, 'outputTokens': 20},
        };
      },
    );
    await client.send(
      AiRequest(
        systemInstruction: '',
        imagePng: Uint8List.fromList([1]),
        messages: const [AiMessage.user('first')],
      ),
    );
    expect(sent!.containsKey('history'), isFalse);
  });

  test('a request the backend rejects is reported as rejected', () async {
    final client = BackendAiClient(
      invoke: (_, _) async => throw const BackendFailure('rejected'),
    );
    final result = await client.send(
      AiRequest(
        systemInstruction: '',
        imagePng: Uint8List(0),
        messages: const [AiMessage.user('question')],
      ),
    );
    expect((result as AiError).failure.kind, AiFailureKind.rejected);
  });
}
