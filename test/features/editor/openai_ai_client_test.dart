import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/ai_config.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/ai/multi_provider_ai_client.dart';
import 'package:greatnote/features/editor/ai/note_image_renderer.dart';
import 'package:greatnote/features/editor/ai/openai_ai_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../helpers/ai_fakes.dart';

/// Not a real credential.
const String _fakeKey = 'sk-test-openai-not-a-real-credential';

final Uint8List _ink = Uint8List.fromList(<int>[0x89, 0x50, 1, 2, 3, 4]);

const AiApiConfig _config = AiApiConfig(
  apiKey: '',
  openAiApiKey: _fakeKey,
  retryDelay: Duration.zero,
);

AiRequest _request({bool withNote = false}) {
  return AiRequest(
    systemInstruction: AiPrompts.system,
    imagePng: _ink,
    model: AiModelId.astra,
    noteImage: withNote
        ? NoteImage(
            logicalSize: const Size(100, 140),
            revision: 1,
            normalizedFocusBounds: const Rect.fromLTRB(0.1, 0.1, 0.5, 0.3),
          )
        : null,
    notationEnabled: withNote,
    messages: const <AiMessage>[
      AiMessage.user('What is this?'),
      AiMessage.model('A circuit.'),
      AiMessage.user('Explain it.'),
    ],
  );
}

/// One chat completion chunk carrying [content].
String _chunk(String content) {
  return 'data: ${jsonEncode(<String, Object?>{
    'choices': <Object?>[
      <String, Object?>{
        'index': 0,
        'delta': <String, Object?>{'content': content},
      },
    ],
  })}\n\n';
}

const String _usage =
    'data: {"choices":[],"usage":{"prompt_tokens":1234,"completion_tokens":56}}\n\n';

/// The answer [json] split into small pieces, then usage and [DONE].
List<String> _stream(String json) {
  return <String>[
    for (int i = 0; i < json.length; i += 7)
      _chunk(json.substring(i, i + 7 > json.length ? json.length : i + 7)),
    _usage,
    'data: [DONE]\n\n',
  ];
}

OpenAiClient _client(
  Future<http.StreamedResponse> Function(http.BaseRequest request) handler, {
  AiApiConfig config = _config,
}) {
  return OpenAiClient(
    config: config,
    model: 'gpt-6.1-sol',
    httpClient: MockClient.streaming(
      (http.BaseRequest request, http.ByteStream body) => handler(request),
    ),
  );
}

http.StreamedResponse _sse(List<String> events, {int status = 200}) {
  return http.StreamedResponse(
    Stream<List<int>>.fromIterable(<List<int>>[
      for (final String event in events) utf8.encode(event),
    ]),
    status,
    headers: <String, String>{'content-type': 'text/event-stream'},
  );
}

void _expectNothingLeaked(AiFailure failure) {
  for (final String text in <String>[failure.message, failure.toString()]) {
    expect(text, isNot(contains(_fakeKey)));
    expect(text, isNot(contains(base64Encode(_ink))));
    expect(text, isNot(contains('What is this?')));
  }
}

/// The answer [message], with a one-stroke notation, as a model writes it.
String _withNotation(String message) {
  return AiAssistantResponse(
    message: message,
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
}

void main() {
  test('posts to Chat Completions with a bearer key and streams', () async {
    late http.Request sent;
    final OpenAiClient client = OpenAiClient(
      config: _config,
      model: 'gpt-6.1-sol',
      httpClient: MockClient.streaming((
        http.BaseRequest request,
        http.ByteStream body,
      ) async {
        sent = http.Request(request.method, request.url)
          ..headers.addAll(request.headers)
          ..bodyBytes = await body.toBytes();
        return _sse(
          _stream(const AiAssistantResponse(message: 'Hi').toJsonString()),
        );
      }),
    );
    final AiResult result = await client.send(_request());

    expect(result, isA<AiSuccess>());
    expect(sent.url.toString(), 'https://api.openai.com/v1/chat/completions');
    expect(sent.headers['Authorization'], 'Bearer $_fakeKey');
    expect(sent.headers['Content-Type'], startsWith('application/json'));
    final Map<String, Object?> body =
        jsonDecode(sent.body) as Map<String, Object?>;
    expect(body['model'], 'gpt-6.1-sol');
    expect(body['stream'], isTrue);
    expect(body['stream_options'], <String, Object?>{'include_usage': true});
    expect(body['response_format'], <String, Object?>{'type': 'json_object'});
  });

  test('the selected ink rides in the first user turn and the note, only as '
      'metadata, in the last', () {
    final Map<String, Object?> body = OpenAiClient.buildBody(
      _request(withNote: true),
      model: 'gpt-6.1-sol',
    );
    final List<Object?> messages = body['messages']! as List<Object?>;
    expect(messages.first, <String, Object?>{
      'role': 'system',
      'content': AiPrompts.system,
    });
    final List<Object?> first =
        (messages[1]! as Map<String, Object?>)['content']! as List<Object?>;
    expect(first[1], <String, Object?>{
      'type': 'image_url',
      'image_url': <String, Object?>{
        'url': 'data:image/png;base64,${base64Encode(_ink)}',
      },
    });
    expect(messages[2], <String, Object?>{
      'role': 'assistant',
      'content': const AiAssistantResponse(
        message: 'A circuit.',
      ).toJsonString(),
    });
    final List<Object?> last =
        (messages[3]! as Map<String, Object?>)['content']! as List<Object?>;
    expect(
      (last[0]! as Map<String, Object?>)['text'],
      contains('you are not shown the whole sheet'),
    );
    expect(
      (last[0]! as Map<String, Object?>)['text'],
      contains('"focus_bounds"'),
    );
    expect(last, hasLength(2));
    expect((last[1]! as Map<String, Object?>)['text'], 'Explain it.');
    // Only one turn carries the selected ink.
    expect(jsonEncode(body).split(base64Encode(_ink)).length, 2);
  });

  test('streams the message, then parses notation and usage', () async {
    final String json = _withNotation("Ohm's law.");
    final List<(String, bool)> partials = <(String, bool)>[];
    final OpenAiClient client = _client((_) async => _sse(_stream(json)));
    final AiResult result = await client.send(
      _request(),
      onPartial: (String message, bool complete) =>
          partials.add((message, complete)),
    );

    expect(partials, isNotEmpty);
    expect(partials.last, ("Ohm's law.", true));
    expect(partials.first.$1.length, lessThan("Ohm's law.".length));
    final AiSuccess success = result as AiSuccess;
    expect(success.text, "Ohm's law.");
    expect(success.notation, isNotNull);
    expect(success.notation!.items, hasLength(1));
    expect(
      success.usage,
      const AiTokenUsage(inputTokens: 1234, outputTokens: 56),
    );
  });

  group('failures', () {
    for (final (int status, AiFailureKind kind) in <(int, AiFailureKind)>[
      (401, AiFailureKind.unauthorized),
      (403, AiFailureKind.unauthorized),
      (429, AiFailureKind.rateLimited),
      (500, AiFailureKind.server),
      (400, AiFailureKind.rejected),
    ]) {
      test('$status is ${kind.name}', () async {
        final AiResult result = await _client(
          (_) async =>
              _sse(<String>['{"error":"secret detail"}'], status: status),
        ).send(_request());
        final AiFailure failure = (result as AiError).failure;
        expect(failure.kind, kind);
        expect(failure.statusCode, status);
        _expectNothingLeaked(failure);
        expect(failure.toString(), isNot(contains('secret detail')));
      });
    }

    test('an answer that is not the JSON envelope is malformed', () async {
      final AiResult result = await _client(
        (_) async => _sse(_stream('not json at all')),
      ).send(_request());
      expect((result as AiError).failure.kind, AiFailureKind.malformed);
    });

    test('a content filter stop is blocked', () async {
      final AiResult result = await _client(
        (_) async => _sse(<String>[
          'data: {"choices":[{"index":0,"delta":{},"finish_reason":"content_filter"}]}\n\n',
          'data: [DONE]\n\n',
        ]),
      ).send(_request());
      expect((result as AiError).failure.kind, AiFailureKind.blocked);
    });

    test('silence past the timeout is a timeout', () async {
      final AiResult result = await _client(
        (_) => Completer<http.StreamedResponse>().future,
        config: const AiApiConfig(
          apiKey: '',
          openAiApiKey: _fakeKey,
          timeout: Duration(milliseconds: 20),
        ),
      ).send(_request());
      expect((result as AiError).failure.kind, AiFailureKind.timeout);
    });

    test('a connection error is a network failure, quoting nothing', () async {
      final AiResult result = await _client(
        (_) async => throw http.ClientException(
          'failed with $_fakeKey and ${base64Encode(_ink)}',
        ),
      ).send(_request());
      final AiFailure failure = (result as AiError).failure;
      expect(failure.kind, AiFailureKind.network);
      _expectNothingLeaked(failure);
    });

    test('without a key nothing is sent', () async {
      bool called = false;
      final AiResult result = await _client((_) async {
        called = true;
        return _sse(const <String>[]);
      }, config: const AiApiConfig(apiKey: 'gemini-only')).send(_request());
      expect((result as AiError).failure.kind, AiFailureKind.notConfigured);
      expect(called, isFalse);
    });
  });

  group('keys and routing', () {
    test('existing key names are read when the documented ones are blank', () {
      const AiApiConfig config = AiApiConfig(
        apiKey: '',
        claudeApiKey: '  ',
        claudeApiKeyFallbacks: <String>['', 'anthropic-key'],
        openAiApiKeyFallbacks: <String>['openai-key'],
      );
      expect(config.claudeKey, 'anthropic-key');
      expect(config.openAiKey, 'openai-key');
      expect(config.toString(), isNot(contains('anthropic-key')));
      expect(config.toString(), isNot(contains('openai-key')));
      expect(AiApiConfig.claudeEnvironmentKey, 'Claude_API_KEY');
      expect(AiApiConfig.openAiEnvironmentKey, 'Openai_API_KEY');
    });

    test('model IDs default to the newest of each and follow overrides', () {
      const AiApiConfig plain = AiApiConfig(apiKey: '');
      expect(plain.providerModelId(AiModelId.haiku), 'claude-haiku-5-5');
      expect(plain.providerModelId(AiModelId.sonnet), 'claude-sonnet-5-5');
      expect(plain.providerModelId(AiModelId.opus), 'claude-opus-5-5');
      expect(plain.providerModelId(AiModelId.luna), 'gpt-6-luna');
      expect(plain.providerModelId(AiModelId.sol), 'gpt-6.1-sol');
      expect(plain.providerModelId(AiModelId.astra), 'gpt-6-astra');
      expect(plain.providerModelId(AiModelId.argon), 'gemini-4-argon');
      const AiApiConfig overridden = AiApiConfig(
        apiKey: '',
        model: 'gemini-old',
        modelOverrides: <AiModelId, String>{
          AiModelId.astra: 'gpt-6-astra-2026-09-03',
          AiModelId.luna: '',
        },
      );
      expect(
        overridden.providerModelId(AiModelId.astra),
        'gpt-6-astra-2026-09-03',
      );
      // A blank override is the default; GEMINI_MODEL picks none of them.
      expect(overridden.providerModelId(AiModelId.luna), 'gpt-6-luna');
      expect(overridden.providerModelId(AiModelId.argon), 'gemini-4-argon');
    });

    test('MultiProviderAiClient sends Haiku, Sonnet, and Opus to Claude, '
        'Luna, Sol, and Astra to OpenAI, and Argon to Gemini', () async {
      final Map<AiProvider, List<(AiModelId, String)>> made =
          <AiProvider, List<(AiModelId, String)>>{};
      final Map<AiModelId, FakeAiClient> clients = <AiModelId, FakeAiClient>{};
      AiProviderClientFactory recording(AiProvider provider) {
        return (AiModelId model, String id) {
          (made[provider] ??= <(AiModelId, String)>[]).add((model, id));
          return clients[model] = FakeAiClient();
        };
      }

      final MultiProviderAiClient router = MultiProviderAiClient(
        config: const AiApiConfig(
          apiKey: 'g',
          claudeApiKey: 'c',
          openAiApiKey: 'o',
        ),
        factories: <AiProvider, AiProviderClientFactory>{
          for (final AiProvider provider in AiProvider.values)
            provider: recording(provider),
        },
      );
      for (final AiModelId model in AiModelId.values) {
        final Future<AiResult> answer = router.send(
          AiRequest(
            systemInstruction: 's',
            imagePng: _ink,
            model: model,
            messages: const <AiMessage>[AiMessage.user('hi')],
          ),
        );
        clients[model]!.answer(model.label);
        expect(((await answer) as AiSuccess).text, model.label);
      }
      expect(made[AiProvider.claude], <(AiModelId, String)>[
        (AiModelId.haiku, 'claude-haiku-5-5'),
        (AiModelId.sonnet, 'claude-sonnet-5-5'),
        (AiModelId.opus, 'claude-opus-5-5'),
      ]);
      expect(made[AiProvider.openai], <(AiModelId, String)>[
        (AiModelId.luna, 'gpt-6-luna'),
        (AiModelId.sol, 'gpt-6.1-sol'),
        (AiModelId.astra, 'gpt-6-astra'),
      ]);
      expect(made[AiProvider.gemini], <(AiModelId, String)>[
        (AiModelId.argon, 'gemini-4-argon'),
      ]);
      router.close();
      expect(clients.values.every((FakeAiClient c) => c.closed), isTrue);
    });

    test('a model whose provider has no key is not configured', () async {
      final MultiProviderAiClient router = MultiProviderAiClient(
        config: const AiApiConfig(apiKey: 'gemini-only'),
      );
      expect(router.isConfigured, isTrue);
      expect(router.isModelConfigured(AiModelId.argon), isTrue);
      expect(router.isModelConfigured(AiModelId.sol), isFalse);
      expect(router.isModelConfigured(AiModelId.haiku), isFalse);
      expect(router.isModelConfigured(AiModelId.astra), isFalse);
      final AiResult result = await router.send(
        AiRequest(
          systemInstruction: 's',
          imagePng: _ink,
          model: AiModelId.astra,
          messages: const <AiMessage>[AiMessage.user('hi')],
        ),
      );
      expect((result as AiError).failure.kind, AiFailureKind.notConfigured);
      router.close();
    });
  });
}
