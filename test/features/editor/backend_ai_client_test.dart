import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/backend/backend_service.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/ai/backend_ai_client.dart';
import 'package:greatnote/features/editor/ai/notation_space.dart';
import 'package:greatnote/features/editor/ai/note_image_renderer.dart';
import 'package:greatnote/features/editor/ai/streaming_ai_client.dart';

void main() {
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
          'noteMetadata',
          'selectedImage',
          'notationContext',
          'responseSchema',
        ]),
      );
      // With Notation on, the provider is held to the app's answer shape:
      // the words first, then the drawing.
      expect(sent!['responseSchema'], aiResponseJsonSchema());
      expect(
        ((sent!['responseSchema']! as Map<String, Object?>)['properties']!
                as Map<String, Object?>)
            .keys
            .first,
        'message',
      );
      expect(sent!['requestId'], matches(RegExp(r'^[a-f0-9-]{36}$')));
    },
  );
  test('history keeps only the last three complete turns', () async {
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
    expect(history, hasLength(6));
    expect(history.first, {'role': 'user', 'content': 'question 48'});
    expect(history.last, {'role': 'assistant', 'content': 'answer 50'});
  });
  test('history is compacted: older turns are excerpts, quick actions their '
      'labels, and only the latest answer stays nearly whole', () async {
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
    final String longAnswer = List<String>.filled(400, 'word').join(' ');
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
    // A quick action goes as its label.
    expect(history[0]['content'], 'Explain this');
    // An older answer is a short, one-line excerpt.
    expect(history[1]['content']!.length, lessThanOrEqualTo(302));
    expect(history[1]['content'], endsWith('…'));
    expect(history[1]['content'], isNot(contains('\n')));
    expect(history[2]['content'], 'Why?');
    // The latest answer is kept up to 2000 characters.
    expect(history[3]['content']!.length, greaterThan(1900));
    expect(history[3]['content']!.length, lessThanOrEqualTo(2002));
  });

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
        notationEnabled: true,
        noteImage: note,
        messages: const [AiMessage.user('Draw it')],
      ),
    );

    // The fixed instruction alone, so providers can cache it.
    expect(sent!['systemInstruction'], 'public instructions');
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
