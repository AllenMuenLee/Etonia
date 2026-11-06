import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/ai_config.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/ai/gemini_ai_client.dart';
import 'package:greatnote/features/editor/ai/note_image_renderer.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Not a real credential.
const String _fakeKey = 'test-key-not-a-real-credential';

/// Stands in for response text that must never reach the user or a log.
const String _bodySecret = 'response-body-detail-0123456789';

final Uint8List _png = Uint8List.fromList(<int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  for (int i = 0; i < 60; i++) i * 3 % 256,
]);

const AiApiConfig _config = AiApiConfig(
  apiKey: _fakeKey,
  retryDelay: Duration.zero,
);

AiRequest _request([List<AiMessage>? messages]) {
  return AiRequest(
    systemInstruction: AiPrompts.system,
    imagePng: _png,
    messages: messages ?? const <AiMessage>[AiMessage.user('What is this?')],
  );
}

String _answer(List<Object?> parts, {String? finishReason}) {
  return jsonEncode(<String, Object?>{
    'candidates': <Object?>[
      <String, Object?>{
        'content': <String, Object?>{'role': 'model', 'parts': parts},
        'finishReason': ?finishReason,
      },
    ],
  });
}

String _wire(String message) =>
    AiAssistantResponse(message: message).toJsonString();

/// A client whose service answers every request with [body].
GeminiAiClient _answering(String body, {int status = 200}) {
  return GeminiAiClient(
    config: _config,
    httpClient: MockClient((http.Request _) async {
      return http.Response(
        body,
        status,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }),
  );
}

Future<AiFailure> _failureOf(GeminiAiClient client) async {
  final AiResult result = await client.send(_request());
  expect(result, isA<AiError>());
  return (result as AiError).failure;
}

/// Everything a failure could put in front of a user or into a log.
void _expectNothingLeaked(AiFailure failure) {
  for (final String text in <String>[failure.message, failure.toString()]) {
    expect(text, isNot(contains(_fakeKey)));
    expect(text, isNot(contains(base64Encode(_png))));
    expect(text, isNot(contains(_bodySecret)));
    expect(text, isNot(contains('What is this?')));
  }
  expect(failure.message, isNotEmpty);
}

void main() {
  test('the model, endpoint, and timeout are the documented ones', () {
    expect(AiApiConfig.defaultModel, 'gemini-2.5-flash');
    expect(_config.modelId, 'gemini-2.5-flash');
    expect(_config.modelLabel, 'Gemini 2.5 Flash');
    expect(AiApiConfig.modelEnvironmentKey, 'GEMINI_MODEL');
    expect(
      _config.endpoint.toString(),
      'https://generativelanguage.googleapis.com/v1beta/models/'
      'gemini-2.5-flash:streamGenerateContent?alt=sse',
    );
    // Silence allowed, then the whole answer.
    expect(_config.timeout, const Duration(seconds: 90));
    expect(_config.maxDuration, const Duration(minutes: 4));
    // Gemini 2.5 refuses thinkingLevel, so none is sent by default.
    expect(_config.thinkingLevel, isNull);
    expect(_config.thinkingBudget, isNull);
    expect(_config.toString(), isNot(contains(_fakeKey)));
    expect(const AiApiConfig(apiKey: '  ').hasApiKey, isFalse);
  });

  test('thinking is sent the way each model takes it', () {
    ({String? level, int? budget}) thinking(
      String model, {
      String? level,
      int? budget,
    }) {
      return AiApiConfig(
        apiKey: _fakeKey,
        model: model,
        thinkingLevel: level,
        thinkingBudget: budget,
      ).requestThinking;
    }

    // Nothing given: nothing sent, which every model accepts.
    expect(thinking('gemini-2.5-flash'), (level: null, budget: null));
    expect(thinking('gemma-4-31b-it', level: '  '), (
      level: null,
      budget: null,
    ));
    // Models that take a level get the API's enum name, however it was
    // written: as the enum, in lower case, or as the SDKs' constant.
    for (final String given in <String>[
      'HIGH',
      ' High ',
      'high',
      'ThinkingLevel.HIGH',
    ]) {
      expect(thinking('gemma-4-31b-it', level: given), (
        level: 'HIGH',
        budget: null,
      ), reason: given);
    }
    expect(thinking('gemini-3-flash-preview', level: 'minimal'), (
      level: 'MINIMAL',
      budget: null,
    ));
    // Gemini 2.5 refuses a level, so it gets the level's budget.
    for (final MapEntry<String, int> entry
        in AiApiConfig.thinkingLevelBudgets.entries) {
      expect(thinking('gemini-2.5-flash', level: entry.key), (
        level: null,
        budget: entry.value,
      ));
    }
    expect(AiApiConfig.thinkingLevelBudgets, <String, int>{
      'MINIMAL': 0,
      'LOW': 1024,
      'MEDIUM': 4096,
      'HIGH': 16384,
    });
    expect(thinking('gemini-2.5-flash', level: 'ThinkingLevel.LOW'), (
      level: null,
      budget: 1024,
    ));
    // 2.5 Pro cannot turn thinking off.
    expect(thinking('gemini-2.5-pro', level: 'minimal'), (
      level: null,
      budget: 128,
    ));
    expect(thinking('gemini-2.5-pro', level: 'low'), (
      level: null,
      budget: 1024,
    ));
    // An unknown level is sent, so the service refuses it visibly.
    expect(thinking('gemini-2.5-flash', level: 'hgih'), (
      level: 'HGIH',
      budget: null,
    ));
    // A budget wins over a level, for any model; -1 is dynamic.
    expect(thinking('gemma-4-31b-it', level: 'high', budget: 512), (
      level: null,
      budget: 512,
    ));
    expect(thinking('gemini-2.5-flash', level: 'low', budget: -1), (
      level: null,
      budget: -1,
    ));
    // A budget that was not a whole number counts as not given.
    expect(thinking('gemini-2.5-flash', level: 'low', budget: -2), (
      level: null,
      budget: 1024,
    ));

    final String described = const AiApiConfig(
      apiKey: _fakeKey,
      thinkingLevel: 'low',
    ).toString();
    expect(described, contains('thinkingBudget: 1024'));
    expect(described, isNot(contains(_fakeKey)));
  });

  test('the thinking sent is the one worked out for the model', () async {
    final List<Map<String, Object?>> configs = <Map<String, Object?>>[];
    for (final (String model, String level) in <(String, String)>[
      ('gemini-2.5-flash', 'low'),
      ('gemma-4-26b-a4b-it', 'low'),
    ]) {
      await GeminiAiClient(
        config: AiApiConfig(
          apiKey: _fakeKey,
          model: model,
          thinkingLevel: level,
        ),
        httpClient: MockClient((http.Request request) async {
          configs.add(
            (jsonDecode(request.body)
                    as Map<String, Object?>)['generationConfig']!
                as Map<String, Object?>,
          );
          return http.Response('{}', 200);
        }),
      ).send(_request());
    }

    expect(configs[0]['thinkingConfig'], <String, Object?>{
      'thinkingBudget': 1024,
    });
    expect(configs[1]['thinkingConfig'], <String, Object?>{
      'thinkingLevel': 'LOW',
    });
  });

  test('the model can be chosen, and is shown by name or ID', () async {
    for (final (String given, String id, String label)
        in <(String, String, String)>[
          ('gemma-4-31b-it', 'gemma-4-31b-it', 'Gemma 4 31B'),
          ('  gemini-2.5-pro ', 'gemini-2.5-pro', 'Gemini 2.5 Pro'),
          // As copied from the API's model list.
          ('models/gemini-2.5-flash', 'gemini-2.5-flash', 'Gemini 2.5 Flash'),
          // One it has no name for.
          (
            'gemini-3-flash-preview',
            'gemini-3-flash-preview',
            'gemini-3-flash-preview',
          ),
          // Blank is the default.
          ('', 'gemini-2.5-flash', 'Gemini 2.5 Flash'),
          ('   ', 'gemini-2.5-flash', 'Gemini 2.5 Flash'),
        ]) {
      final AiApiConfig config = AiApiConfig(apiKey: _fakeKey, model: given);
      expect(config.modelId, id, reason: given);
      expect(config.modelLabel, label, reason: given);
      expect(
        config.endpoint.toString(),
        'https://generativelanguage.googleapis.com/v1beta/models/'
        '$id:streamGenerateContent?alt=sse',
        reason: given,
      );
      expect(GeminiAiClient(config: config).modelLabel, label);
      expect(config.toString(), contains(id));
      expect(config.toString(), isNot(contains(_fakeKey)));
    }

    // Whatever is given stays one path segment of the endpoint.
    final List<http.Request> seen = <http.Request>[];
    await GeminiAiClient(
      config: const AiApiConfig(apiKey: _fakeKey, model: 'a/b?c=d#e'),
      httpClient: MockClient((http.Request request) async {
        seen.add(request);
        return http.Response('{}', 200);
      }),
    ).send(_request());
    expect(seen.single.url.host, 'generativelanguage.googleapis.com');
    expect(seen.single.url.pathSegments, <String>[
      'v1beta',
      'models',
      'a/b?c=d#e:streamGenerateContent',
    ]);
    expect(seen.single.url.queryParameters, <String, String>{'alt': 'sse'});
  });

  test('a request streams from generateContent, key in a header', () async {
    final List<http.Request> seen = <http.Request>[];
    final GeminiAiClient client = GeminiAiClient(
      config: _config,
      httpClient: MockClient((http.Request request) async {
        seen.add(request);
        return http.Response(
          _answer(<Object?>[
            <String, Object?>{'text': _wire('It is a triangle.')},
          ]),
          200,
        );
      }),
    );

    final AiResult result = await client.send(_request());

    expect((result as AiSuccess).text, 'It is a triangle.');
    final http.Request request = seen.single;
    expect(request.method, 'POST');
    expect(request.url.scheme, 'https');
    expect(request.url.host, 'generativelanguage.googleapis.com');
    expect(
      request.url.path,
      '/v1beta/models/gemini-2.5-flash:streamGenerateContent',
    );
    // Server-sent events, so the answer can be shown as it is written.
    expect(request.url.queryParameters, <String, String>{'alt': 'sse'});
    expect(request.headers['Content-Type'], 'application/json');
    expect(request.headers['x-goog-api-key'], _fakeKey);
    // The key travels in that header and nowhere else.
    expect(request.url.toString(), isNot(contains(_fakeKey)));
    expect(request.body, isNot(contains(_fakeKey)));
    expect(
      request.headers.entries.where(
        (MapEntry<String, String> header) => header.value.contains(_fakeKey),
      ),
      hasLength(1),
    );
  });

  test('the first turn carries the image, then the prompt', () async {
    late Map<String, Object?> body;
    final GeminiAiClient client = GeminiAiClient(
      config: _config,
      httpClient: MockClient((http.Request request) async {
        body = jsonDecode(request.body) as Map<String, Object?>;
        return http.Response(
          _answer(<Object?>[
            <String, Object?>{'text': _wire('ok')},
          ]),
          200,
        );
      }),
    );

    await client.send(
      _request(const <AiMessage>[
        AiMessage.user(AiPrompts.explain, label: 'Explain this'),
      ]),
    );

    expect(body, <String, Object?>{
      'system_instruction': <String, Object?>{
        'parts': <Object?>[
          <String, Object?>{'text': AiPrompts.system},
        ],
      },
      'contents': <Object?>[
        <String, Object?>{
          'role': 'user',
          'parts': <Object?>[
            <String, Object?>{'text': 'Selected ink image:'},
            <String, Object?>{
              'inline_data': <String, Object?>{
                'mime_type': 'image/png',
                'data': base64Encode(_png),
              },
            },
            // The prompt itself, not the label shown in the transcript.
            <String, Object?>{'text': AiPrompts.explain},
          ],
        },
      ],
      'generationConfig': <String, Object?>{
        'responseMimeType': 'text/plain',
        'maxOutputTokens': const AiNotationConfig().maxOutputTokens,
        // No thinkingConfig: the model decides how long to think.
      },
    });
  });

  test('follow-ups resend the whole conversation, in order', () {
    final Map<String, Object?> body = GeminiAiClient.buildBody(
      _request(const <AiMessage>[
        AiMessage.user('First question'),
        AiMessage.model('First answer'),
        AiMessage.user('Second question'),
        AiMessage.model('Second answer'),
        AiMessage.user('Third question'),
      ]),
    );
    final List<Object?> contents = body['contents']! as List<Object?>;

    expect(
      <String>[
        for (final Object? turn in contents)
          (turn! as Map<String, Object?>)['role']! as String,
      ],
      <String>['user', 'model', 'user', 'model', 'user'],
    );
    // The image is in the first turn only, and still there.
    final List<List<Object?>> parts = <List<Object?>>[
      for (final Object? turn in contents)
        (turn! as Map<String, Object?>)['parts']! as List<Object?>,
    ];
    expect(parts[0], hasLength(3));
    expect(parts[0][0], <String, Object?>{'text': 'Selected ink image:'});
    expect(
      ((parts[0][1]! as Map<String, Object?>)['inline_data']!
          as Map<String, Object?>)['data'],
      base64Encode(_png),
    );
    expect(parts[0][2], <String, Object?>{'text': 'First question'});
    expect(parts[1], <Object?>[
      <String, Object?>{'text': 'First answer'},
    ]);
    expect(parts[2], <Object?>[
      <String, Object?>{'text': 'Second question'},
    ]);
    expect(parts[3], <Object?>[
      <String, Object?>{'text': 'Second answer'},
    ]);
    expect(parts[4], <Object?>[
      <String, Object?>{'text': 'Third question'},
    ]);
    expect(
      jsonEncode(body).split(base64Encode(_png)),
      hasLength(2),
      reason: 'the image is sent once per request',
    );
  });

  test('notation context is attached only to the latest user turn', () {
    final Map<String, Object?> body = GeminiAiClient.buildBody(
      AiRequest(
        systemInstruction: AiPrompts.systemFor(notationEnabled: true),
        imagePng: _png,
        noteImage: NoteImage(
          logicalSize: const ui.Size(300, 200),
          revision: 42,
          normalizedFocusBounds: const ui.Rect.fromLTRB(0.1, 0.2, 0.4, 0.6),
          focusInk: const <List<InkVector>>[
            <InkVector>[
              InkVector(0.12, 0.25),
              InkVector(0.12, 0.55),
              InkVector(0.31234, 0.4),
              InkVector(0.12, 0.25),
            ],
          ],
        ),
        notationEnabled: true,
        selectionSvg:
            '<svg viewBox="0 0 300 200" '
            'data-etonia-coordinate-space="note" '
            'data-etonia-selection-bounds="30 40 90 80">'
            '<path data-etonia-kind="existing-ink" '
            'd="M36 50 L36 110 L93.6 80 L36 50"/></svg>',
        messages: const <AiMessage>[
          AiMessage.user('First'),
          AiMessage.model('Answer'),
          AiMessage.user('Draw a label'),
        ],
      ),
    );
    final List<Object?> contents = body['contents']! as List<Object?>;
    final List<Object?> firstParts =
        (contents[0]! as Map<String, Object?>)['parts']! as List<Object?>;
    final List<Object?> latestParts =
        (contents[2]! as Map<String, Object?>)['parts']! as List<Object?>;

    // The picture to read, then the same selection as SVG, then the words.
    expect(firstParts, hasLength(4));
    expect(firstParts[1], contains('inline_data'));
    expect(
      (firstParts[2]! as Map<String, Object?>)['text'],
      allOf(contains('Read what is written'), contains('<path')),
    );
    // The metadata, then the words: no picture of the note.
    expect(latestParts, hasLength(2));
    expect(jsonEncode(latestParts), isNot(contains('inline_data')));
    expect(
      (latestParts[0]! as Map<String, Object?>)['text'],
      allOf(
        contains('The selected part is supplied as an image and as SVG'),
        contains('"logical_aspect_ratio":1.5'),
        contains('"focus_bounds":{"left":0.1,"top":0.2,'),
        contains('"note_logical_width":300.0'),
      ),
    );
    expect(
      (latestParts[0]! as Map<String, Object?>)['text'],
      allOf(
        contains('The selected SVG covers x 0.1 to 0.4, y 0.2 to 0.6.'),
        // It may draw outside that region, but not off the paper.
        contains('inside or outside the selected region'),
        contains('every point must keep 0 < x < 1 and 0 < y < 1'),
      ),
    );
    expect(latestParts[1], <String, Object?>{'text': 'Draw a label'});
    expect(
      jsonEncode(body),
      isNot(contains('"revision"')),
      reason: 'the captured document revision stays local',
    );
  });

  test('text parts are joined in order, and thoughts are left out', () async {
    final String wire = _wire('One, two, three.');
    final int first = wire.length ~/ 3;
    final int second = first * 2;
    final AiResult result = await _answering(
      _answer(<Object?>[
        <String, Object?>{'text': 'planning...', 'thought': true},
        <String, Object?>{'text': wire.substring(0, first)},
        <String, Object?>{
          'inline_data': <String, Object?>{'mime_type': 'x', 'data': 'y'},
        },
        <String, Object?>{'text': wire.substring(first, second)},
        <String, Object?>{'text': wire.substring(second)},
      ]),
    ).send(_request());

    expect((result as AiSuccess).text, 'One, two, three.');
  });

  test('a later candidate answers when the first is empty', () async {
    final AiResult result = await _answering(
      jsonEncode(<String, Object?>{
        'candidates': <Object?>[
          <String, Object?>{'finishReason': 'STOP'},
          <String, Object?>{
            'content': <String, Object?>{
              'parts': <Object?>[
                <String, Object?>{'text': _wire('Second')},
              ],
            },
          },
        ],
      }),
    ).send(_request());

    expect((result as AiSuccess).text, 'Second');
  });

  group('failures', () {
    final Map<String, (String, AiFailureKind)> bodies =
        <String, (String, AiFailureKind)>{
          'no candidates': ('{"candidates": []}', AiFailureKind.empty),
          'a missing candidate list': ('{}', AiFailureKind.empty),
          'a candidate with no content': (
            '{"candidates": [{"finishReason": "STOP"}]}',
            AiFailureKind.empty,
          ),
          'blank text': (
            _answer(<Object?>[
              <String, Object?>{'text': '  \n '},
            ]),
            AiFailureKind.empty,
          ),
          'only thoughts': (
            _answer(<Object?>[
              <String, Object?>{'text': _bodySecret, 'thought': true},
            ]),
            AiFailureKind.empty,
          ),
          'a blocked prompt': (
            '{"promptFeedback": {"blockReason": "SAFETY", '
                '"note": "$_bodySecret"}}',
            AiFailureKind.blocked,
          ),
          'a blocked answer': (
            _answer(const <Object?>[], finishReason: 'SAFETY'),
            AiFailureKind.blocked,
          ),
          'a recitation stop': (
            '{"candidates": [{"finishReason": "RECITATION"}]}',
            AiFailureKind.blocked,
          ),
          'text that is not JSON': (
            '<html>$_bodySecret</html>',
            AiFailureKind.malformed,
          ),
          'cut-off JSON': (
            '{"candidates": [{"content": {"parts": [{"text": "$_bodySecret',
            AiFailureKind.malformed,
          ),
          'JSON that is not an object': (
            '["$_bodySecret"]',
            AiFailureKind.malformed,
          ),
          'candidates that are not a list': (
            '{"candidates": "$_bodySecret"}',
            AiFailureKind.malformed,
          ),
        };
    for (final MapEntry<String, (String, AiFailureKind)> entry
        in bodies.entries) {
      test('${entry.key} is ${entry.value.$2.name}', () async {
        final AiFailure failure = await _failureOf(_answering(entry.value.$1));

        expect(failure.kind, entry.value.$2);
        _expectNothingLeaked(failure);
      });
    }

    for (final (int status, AiFailureKind kind) in <(int, AiFailureKind)>[
      (400, AiFailureKind.rejected),
      (401, AiFailureKind.unauthorized),
      (403, AiFailureKind.unauthorized),
      (404, AiFailureKind.rejected),
      (429, AiFailureKind.rateLimited),
      (500, AiFailureKind.server),
      (503, AiFailureKind.server),
      (302, AiFailureKind.rejected),
    ]) {
      test('status $status is ${kind.name}', () async {
        final AiFailure failure = await _failureOf(
          _answering(
            // An error body can echo the request, key included.
            '{"error": {"message": "$_bodySecret $_fakeKey"}}',
            status: status,
          ),
        );

        expect(failure.kind, kind);
        expect(failure.statusCode, status);
        _expectNothingLeaked(failure);
      });
    }

    test('no answer within the timeout is a timeout', () async {
      final Completer<http.Response> never = Completer<http.Response>();
      final GeminiAiClient client = GeminiAiClient(
        config: const AiApiConfig(
          apiKey: _fakeKey,
          timeout: Duration(milliseconds: 20),
        ),
        httpClient: MockClient((http.Request _) => never.future),
      );
      final Stopwatch watch = Stopwatch()..start();

      final AiFailure failure = await _failureOf(client);

      expect(failure.kind, AiFailureKind.timeout);
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      _expectNothingLeaked(failure);
    });

    test('a connection that fails is a network failure', () async {
      for (final Object error in <Object>[
        http.ClientException('Failed host lookup $_bodySecret $_fakeKey'),
        StateError(_bodySecret),
      ]) {
        final AiFailure failure = await _failureOf(
          GeminiAiClient(
            config: _config,
            httpClient: MockClient((http.Request _) => throw error),
          ),
        );

        expect(failure.kind, AiFailureKind.network);
        _expectNothingLeaked(failure);
      }
    });

    test('without a key nothing is sent', () async {
      int calls = 0;
      final GeminiAiClient client = GeminiAiClient(
        config: const AiApiConfig(apiKey: ''),
        httpClient: MockClient((http.Request _) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );

      expect(client.isConfigured, isFalse);
      expect((await _failureOf(client)).kind, AiFailureKind.notConfigured);
      expect(calls, 0);
    });

    for (final int status in <int>[500, 503]) {
      test('a $status is sent once more, then reported', () async {
        final List<String> bodies = <String>[];
        final GeminiAiClient client = GeminiAiClient(
          config: _config,
          httpClient: MockClient((http.Request request) async {
            bodies.add(request.body);
            return http.Response('{}', status);
          }),
        );

        final AiFailure failure = await _failureOf(client);

        expect(failure.kind, AiFailureKind.server);
        expect(bodies, hasLength(2));
        expect(bodies[1], bodies[0]);
      });

      test('a $status followed by an answer is an answer', () async {
        int calls = 0;
        final GeminiAiClient client = GeminiAiClient(
          config: _config,
          httpClient: MockClient((http.Request _) async {
            calls++;
            return calls == 1
                ? http.Response('{}', status)
                : http.Response(
                    _answer(<Object?>[
                      <String, Object?>{'text': _wire('Second time')},
                    ]),
                    200,
                  );
          }),
        );

        final AiResult result = await client.send(_request());

        expect((result as AiSuccess).text, 'Second time');
        expect(calls, 2);
      });
    }

    for (final int status in <int>[400, 429, 502, 504]) {
      test('a $status is not sent again', () async {
        int calls = 0;
        final GeminiAiClient client = GeminiAiClient(
          config: _config,
          httpClient: MockClient((http.Request _) async {
            calls++;
            return http.Response('{}', status);
          }),
        );

        await _failureOf(client);

        expect(calls, 1);
      });
    }

    test('a timeout is not sent again', () async {
      int calls = 0;
      final GeminiAiClient client = GeminiAiClient(
        config: const AiApiConfig(
          apiKey: _fakeKey,
          timeout: Duration(milliseconds: 20),
          retryDelay: Duration.zero,
        ),
        httpClient: MockClient((http.Request _) {
          calls++;
          return Completer<http.Response>().future;
        }),
      );

      expect((await _failureOf(client)).kind, AiFailureKind.timeout);
      expect(calls, 1);
    });

    test('retries can be turned off, and thinking turned on', () async {
      final List<String> bodies = <String>[];
      final GeminiAiClient client = GeminiAiClient(
        config: const AiApiConfig(
          apiKey: _fakeKey,
          model: 'gemma-4-31b-it',
          serverErrorRetries: 0,
          thinkingLevel: 'high',
        ),
        httpClient: MockClient((http.Request request) async {
          bodies.add(request.body);
          return http.Response('{}', 500);
        }),
      );

      await _failureOf(client);

      expect(bodies, hasLength(1));
      expect(
        (jsonDecode(bodies.single) as Map<String, Object?>)['generationConfig'],
        <String, Object?>{
          'responseMimeType': 'text/plain',
          'maxOutputTokens': const AiNotationConfig().maxOutputTokens,
          'thinkingConfig': <String, Object?>{'thinkingLevel': 'HIGH'},
        },
      );
    });
  });

  test('close leaves a borrowed HTTP client open, and stops sending', () async {
    int calls = 0;
    final MockClient mock = MockClient((http.Request _) async {
      calls++;
      return http.Response(
        _answer(<Object?>[
          <String, Object?>{'text': _wire('ok')},
        ]),
        200,
      );
    });
    final GeminiAiClient client = GeminiAiClient(
      config: _config,
      httpClient: mock,
    );
    expect(await client.send(_request()), isA<AiSuccess>());

    client.close();

    expect((await _failureOf(client)).kind, AiFailureKind.network);
    expect(calls, 1);
    // Still usable by whoever owns it.
    expect((await mock.get(Uri.parse('https://example.com'))).statusCode, 200);
  });

  group('streaming', () {
    /// One server-sent event carrying [text] as the next piece of the
    /// answer.
    String event(String text, {String? finishReason}) {
      return 'data: ${_answer(<Object?>[
        <String, Object?>{'text': text},
      ], finishReason: finishReason)}\r\n\r\n';
    }

    /// A client whose service streams [chunks] of bytes, one at a time.
    GeminiAiClient streaming(List<List<int>> chunks, {int status = 200}) {
      return GeminiAiClient(
        config: _config,
        httpClient: MockClient.streaming((
          http.BaseRequest _,
          http.ByteStream _,
        ) async {
          return http.StreamedResponse(
            Stream<List<int>>.fromIterable(chunks),
            status,
            headers: <String, String>{'content-type': 'text/event-stream'},
          );
        }),
      );
    }

    // The answer as the service writes it: message first, then notation.
    final String full = AiAssistantResponse(
      message: 'Line one.\n"x" = 3 ✓',
      notation: AiNotation(
        label: 'Answer',
        items: <AiNotationItem>[
          AiNotationStroke(
            ink: 'blue',
            width: 3,
            points: const <AiNotationPoint>[
              AiNotationPoint(0.5, 0.5),
              AiNotationPoint(0.6, 0.5),
            ],
          ),
        ],
      ),
    ).toJsonString();

    test('shows the message as it is written, then the whole answer', () async {
      final int cut1 = full.indexOf('one.') + 2;
      final int cut2 = full.indexOf('✓');
      final int cut3 = full.indexOf('"notation"') + 5;
      final List<(String, bool)> partials = <(String, bool)>[];

      final AiResult result =
          await streaming(<List<int>>[
            utf8.encode(event(full.substring(0, cut1))),
            utf8.encode(event(full.substring(cut1, cut2))),
            utf8.encode(event(full.substring(cut2, cut3))),
            utf8.encode(event(full.substring(cut3), finishReason: 'STOP')),
          ]).send(
            _request(),
            onPartial: (String message, bool isComplete) =>
                partials.add((message, isComplete)),
          );

      expect(partials, <(String, bool)>[
        ('Line on', false),
        ('Line one.\n"x" = 3 ', false),
        // The rest of the message, closed: only the drawing is to come.
        ('Line one.\n"x" = 3 ✓', true),
      ]);
      final AiSuccess success = result as AiSuccess;
      expect(success.text, 'Line one.\n"x" = 3 ✓');
      expect(success.notation!.label, 'Answer');
      expect(
        (success.notation!.items.single as AiNotationStroke).points,
        hasLength(2),
      );
    });

    test(
      'events and characters split across reads are put back together',
      () async {
        // Every byte arrives on its own: lines, escapes, and the bytes of a
        // multibyte character are all cut.
        final List<int> bytes = utf8.encode(
          '${event(full.substring(0, full.length ~/ 2))}'
          '${event(full.substring(full.length ~/ 2))}',
        );
        final List<String> partials = <String>[];

        final AiResult result = await streaming(<List<int>>[
          for (final int byte in bytes) <int>[byte],
        ]).send(_request(), onPartial: (String m, bool _) => partials.add(m));

        expect((result as AiSuccess).text, 'Line one.\n"x" = 3 ✓');
        expect(result.notation, isNotNull);
        expect(partials.last, 'Line one.\n"x" = 3 ✓');
      },
    );

    test('an error part way is a failure, and is not sent again', () async {
      int calls = 0;
      final GeminiAiClient client = GeminiAiClient(
        config: _config,
        httpClient: MockClient.streaming((
          http.BaseRequest _,
          http.ByteStream _,
        ) async {
          calls++;
          return http.StreamedResponse(
            Stream<List<int>>.fromIterable(<List<int>>[
              utf8.encode(event(full.substring(0, 30))),
              utf8.encode(
                'data: {"error": {"code": 503, "message": "$_bodySecret"}}'
                '\r\n\r\n',
              ),
            ]),
            200,
          );
        }),
      );
      final List<String> partials = <String>[];

      final AiResult result = await client.send(
        _request(),
        onPartial: (String m, bool _) => partials.add(m),
      );

      final AiFailure failure = (result as AiError).failure;
      expect(failure.kind, AiFailureKind.server);
      expect(failure.statusCode, 503);
      _expectNothingLeaked(failure);
      expect(partials, isNotEmpty);
      // Some of an answer had already arrived, so it is not asked again.
      expect(calls, 1);
    });

    test('a valid stream larger than the former app cap is accepted', () async {
      final String message = 'x' * (256 * 1024 + 1);
      final String answer = AiAssistantResponse(
        message: message,
      ).toJsonString();
      final List<List<int>> chunks = <List<int>>[];
      for (int start = 0; start < answer.length; start += 4096) {
        final int end = math.min(start + 4096, answer.length);
        chunks.add(utf8.encode(event(answer.substring(start, end))));
      }

      final AiResult result = await streaming(chunks).send(_request());

      expect((result as AiSuccess).text, message);
    });

    /// A client whose service sends [events] one by one, [gap] apart.
    GeminiAiClient paced(
      List<String> events,
      Duration gap, {
      required Duration timeout,
      Duration maxDuration = const Duration(minutes: 1),
    }) {
      return GeminiAiClient(
        config: AiApiConfig(
          apiKey: _fakeKey,
          timeout: timeout,
          maxDuration: maxDuration,
          serverErrorRetries: 0,
        ),
        httpClient: MockClient.streaming((
          http.BaseRequest _,
          http.ByteStream _,
        ) async {
          return http.StreamedResponse(
            Stream<List<int>>.periodic(
              gap,
              (int i) => utf8.encode(events[i]),
            ).take(events.length),
            200,
          );
        }),
      );
    }

    List<String> pieces(int count) {
      final int size = (full.length / count).ceil();
      return <String>[
        for (int start = 0; start < full.length; start += size)
          event(
            full.substring(
              start,
              start + size > full.length ? full.length : start + size,
            ),
          ),
      ];
    }

    test('a long answer that keeps arriving is not cut off', () async {
      // 8 pieces 30 ms apart: 240 ms in all, more than three times the
      // 70 ms of silence allowed.
      final AiResult result = await paced(
        pieces(8),
        const Duration(milliseconds: 30),
        timeout: const Duration(milliseconds: 70),
      ).send(_request());

      expect((result as AiSuccess).notation, isNotNull);
    });

    test('a stream that goes quiet times out', () async {
      final List<String> partials = <String>[];

      final AiResult result = await paced(
        pieces(4),
        const Duration(milliseconds: 200),
        timeout: const Duration(milliseconds: 60),
      ).send(_request(), onPartial: (String m, bool _) => partials.add(m));

      expect((result as AiError).failure.kind, AiFailureKind.timeout);
    });

    test('an answer streaming past the overall limit is cut off', () async {
      final AiResult result = await paced(
        pieces(40),
        const Duration(milliseconds: 20),
        timeout: const Duration(seconds: 5),
        maxDuration: const Duration(milliseconds: 150),
      ).send(_request());

      expect((result as AiError).failure.kind, AiFailureKind.timeout);
    });

    test('a thinking budget is sent when set', () {
      final Map<String, Object?> body = GeminiAiClient.buildBody(
        _request(),
        thinkingBudget: 1024,
      );
      expect(
        (body['generationConfig']! as Map<String, Object?>)['thinkingConfig'],
        <String, Object?>{'thinkingBudget': 1024},
      );
    });

    test('a message cut off without a notation is not an answer', () async {
      final List<String> partials = <String>[];

      final AiResult result = await streaming(<List<int>>[
        utf8.encode(event(full.substring(0, full.indexOf('"notation"')))),
      ]).send(_request(), onPartial: (String m, bool _) => partials.add(m));

      expect(partials.last, 'Line one.\n"x" = 3 ✓');
      // The words were shown while they arrived, but an answer that never
      // finished is never kept.
      expect((result as AiError).failure.kind, AiFailureKind.malformed);
    });
  });
}
