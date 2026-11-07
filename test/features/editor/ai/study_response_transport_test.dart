import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/backend/backend_service.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/ai_config.dart';
import 'package:greatnote/features/editor/ai/backend_ai_client.dart';

void main() {
  AiRequest request({AiResponseFormat format = AiResponseFormat.text}) =>
      AiRequest(
        systemInstruction: 'Return Markdown',
        legacySystemInstruction: 'Return SVG',
        responseFormat: format,
        turnId: BackendAiClient.newRequestId(),
        imagePng: Uint8List(0),
        messages: const [AiMessage.user('Explain x > 3.')],
      );
  test(
    'plain answers preserve math, citation tags, and a complete code fence',
    () async {
      const answer =
          '```python\nprint("x > 3")\n```\n\nDomain: \$x > 3\$. [[N1:P1:C1]]';
      final client = BackendAiClient(
        invoke: (_, body) async {
          expect(body['responseFormat'], 'text');
          expect(body['turnId'], matches(RegExp(r'^[0-9a-f-]{36}$')));
          return {
            'answer': answer,
            'responseFormat': 'text',
            'usage': {'inputTokens': 1200, 'outputTokens': 70},
            'servedBy': {'model': 'luna'},
          };
        },
      );
      final result = await client.send(request());
      expect(result, isA<AiSuccess>());
      expect((result as AiSuccess).text, answer);
      expect(result.servedBy, AiModelId.luna);
      client.close();
    },
  );
  test('JSON transport rejects malformed or scalar results', () async {
    for (final answer in ['{broken', '42']) {
      final client = BackendAiClient(
        invoke: (_, _) async => {
          'answer': answer,
          'responseFormat': 'json',
          'usage': {'inputTokens': 1, 'outputTokens': 1},
        },
      );
      expect(
        await client.send(request(format: AiResponseFormat.json)),
        isA<AiError>(),
      );
      client.close();
    }
  });
  test(
    'an old server rejection falls back once to legacy SVG before provider work',
    () async {
      var calls = 0;
      final client = BackendAiClient(
        invoke: (_, body) async {
          calls++;
          if (calls == 1) throw const BackendFailure('rejected');
          expect(body.containsKey('responseFormat'), isFalse);
          expect(body.containsKey('turnId'), isFalse);
          expect(body.containsKey('studyPolicyVersion'), isFalse);
          expect(body['systemInstruction'], 'Return SVG');
          return {
            'answer':
                '<svg xmlns="http://www.w3.org/2000/svg" data-etonia-version="1">'
                '<title>Domain</title><desc data-etonia-role="message">x &gt; 3</desc></svg>',
            'usage': {'inputTokens': 1, 'outputTokens': 1},
          };
        },
      );
      expect((await client.send(request()) as AiSuccess).text, 'x > 3');
      expect(calls, 2);
      client.close();
    },
  );
  test('provider failures are not replayed as legacy work', () async {
    var calls = 0;
    final client = BackendAiClient(
      invoke: (_, _) async {
        calls++;
        throw const BackendFailure('server');
      },
    );
    expect(await client.send(request()), isA<AiError>());
    expect(calls, 1);
    client.close();
  });
  test(
    'plain tutor policy keeps citations and technical meaning without XML escaping',
    () {
      for (final entry in [
        (AiPrompts.studySystem, false),
        (AiPrompts.studyTeachingPlannerSystem, true),
        (AiPrompts.studySuggestionsSystem, true),
      ]) {
        final instruction = AiPrompts.plainStudyInstruction(
          entry.$1,
          json: entry.$2,
        );
        expect(instruction, isNot(contains('message desc')));
        expect(instruction, isNot(contains('XML-escape')));
        expect(instruction, isNot(contains('data-etonia-version')));
      }
      final tutor = AiPrompts.plainStudyInstruction(
        AiPrompts.studySystem,
        json: false,
      );
      expect(tutor, contains('[[N1:P2:L4-L7]]'));
      expect(tutor, contains('domains'));
      expect(tutor, contains('fenced svg block'));
    },
  );
}
