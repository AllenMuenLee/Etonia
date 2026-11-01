import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/ai_config.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/ai/claude_ai_client.dart';
import 'package:greatnote/features/editor/ai/note_image_renderer.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Not a real credential.
const String _fakeKey = 'sk-ant-test-not-a-real-credential';

final Uint8List _ink = Uint8List.fromList(<int>[0x89, 0x50, 1, 2, 3, 4]);
const String _selectionSvg =
    '<svg viewBox="0 0 100 140" data-etonia-coordinate-space="note" '
    'data-etonia-selection-bounds="10 14 40 28"><path d="M10 14 L50 42"/></svg>';

const AiApiConfig _config = AiApiConfig(
  apiKey: '',
  claudeApiKey: _fakeKey,
  retryDelay: Duration.zero,
);

AiRequest _request({bool withNote = false}) {
  return AiRequest(
    systemInstruction: AiPrompts.system,
    imagePng: _ink,
    model: AiModelId.sonnet,
    noteImage: withNote
        ? NoteImage(logicalSize: const Size(100, 140), revision: 1)
        : null,
    notationEnabled: withNote,
    selectionSvg: withNote ? _selectionSvg : null,
    messages: const <AiMessage>[
      AiMessage.user('What is this?'),
      AiMessage.model('A circuit.'),
      AiMessage.user('Explain it.'),
    ],
  );
}

String _event(String type, Map<String, Object?> data) =>
    'event: $type\ndata: ${jsonEncode(<String, Object?>{'type': type, ...data})}\n\n';

/// A Messages stream answering [json] in small pieces.
List<String> _stream(String json, {String stopReason = 'end_turn'}) {
  return <String>[
    _event('message_start', <String, Object?>{
      'message': <String, Object?>{
        'id': 'msg_1',
        'usage': <String, Object?>{'input_tokens': 2048, 'output_tokens': 1},
      },
    }),
    _event('content_block_start', <String, Object?>{
      'index': 0,
      'content_block': <String, Object?>{'type': 'text', 'text': ''},
    }),
    'event: ping\ndata: {"type":"ping"}\n\n',
    for (int i = 0; i < json.length; i += 6)
      _event('content_block_delta', <String, Object?>{
        'index': 0,
        'delta': <String, Object?>{
          'type': 'text_delta',
          'text': json.substring(i, i + 6 > json.length ? json.length : i + 6),
        },
      }),
    _event('content_block_stop', <String, Object?>{'index': 0}),
    _event('message_delta', <String, Object?>{
      'delta': <String, Object?>{'stop_reason': stopReason},
      'usage': <String, Object?>{'output_tokens': 77},
    }),
    _event('message_stop', <String, Object?>{}),
  ];
}

http.StreamedResponse _sse(List<String> events, {int status = 200}) {
  return http.StreamedResponse(
    Stream<List<int>>.fromIterable(<List<int>>[
      for (final String event in events) utf8.encode(event),
    ]),
    status,
  );
}

ClaudeAiClient _client(
  Future<http.StreamedResponse> Function(http.BaseRequest request) handler, {
  AiApiConfig config = _config,
}) {
  return ClaudeAiClient(
    config: config,
    model: 'claude-sonnet-5-5',
    httpClient: MockClient.streaming(
      (http.BaseRequest request, http.ByteStream body) => handler(request),
    ),
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
  test('posts to Messages with x-api-key and anthropic-version', () async {
    late http.Request sent;
    final ClaudeAiClient client = ClaudeAiClient(
      config: _config,
      model: 'claude-sonnet-5-5',
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
    expect(await client.send(_request()), isA<AiSuccess>());
    expect(sent.url.toString(), 'https://api.anthropic.com/v1/messages');
    expect(sent.headers['x-api-key'], _fakeKey);
    expect(sent.headers['anthropic-version'], '2023-06-01');
    expect(sent.headers.containsKey('Authorization'), isFalse);
    final Map<String, Object?> body =
        jsonDecode(sent.body) as Map<String, Object?>;
    expect(body['model'], 'claude-sonnet-5-5');
    expect(body['stream'], isTrue);
    expect(body['system'], AiPrompts.system);
    expect(body['max_tokens'], const AiNotationConfig().maxOutputTokens);
  });

  test('max_tokens is not cut by the app', () {
    final Map<String, Object?> body = ClaudeAiClient.buildBody(
      _request(),
      model: 'claude-opus-5-5',
      notationConfig: const AiNotationConfig(maxOutputTokens: 200000),
    );
    expect(body['max_tokens'], 200000);
  });

  test('the ink is an image and SVG text in the first turn; the note is '
      'only its metadata, in the last', () {
    final Map<String, Object?> body = ClaudeAiClient.buildBody(
      _request(withNote: true),
      model: 'claude-sonnet-5-5',
    );
    final List<Object?> messages = body['messages']! as List<Object?>;
    expect(messages, hasLength(3));
    final List<Object?> first =
        (messages[0]! as Map<String, Object?>)['content']! as List<Object?>;
    // Handwriting cannot be read from paths: the picture always comes too.
    expect(first, hasLength(4));
    expect((first[1]! as Map<String, Object?>)['type'], 'image');
    expect(
      (first[2]! as Map<String, Object?>)['text'],
      contains(_selectionSvg),
    );
    expect((first[3]! as Map<String, Object?>)['text'], 'What is this?');
    expect(jsonEncode(body).split(base64Encode(_ink)).length, 2);
    expect((messages[1]! as Map<String, Object?>)['role'], 'assistant');
    final List<Object?> last =
        (messages[2]! as Map<String, Object?>)['content']! as List<Object?>;
    expect(
      (last[0]! as Map<String, Object?>)['text'],
      contains('note_logical_width'),
    );
    expect(last, hasLength(2));
    expect((last[1]! as Map<String, Object?>)['text'], 'Explain it.');
  });

  test('streams the message, parses notation, and reports usage', () async {
    final String json = _withNotation('Current flows.');
    final List<(String, bool)> partials = <(String, bool)>[];
    final AiResult result = await _client(
      (_) async => _sse(_stream(json)),
    ).send(_request(), onPartial: (String m, bool c) => partials.add((m, c)));
    expect(partials.last, ('Current flows.', true));
    expect(partials.length, greaterThan(1));
    final AiSuccess success = result as AiSuccess;
    expect(success.text, 'Current flows.');
    expect(success.notation, isNotNull);
    expect(
      success.usage,
      const AiTokenUsage(inputTokens: 2048, outputTokens: 77),
    );
  });

  test('a code fence around the JSON is tolerated', () async {
    final AiResult result = await _client(
      (_) async => _sse(
        _stream(
          '```json\n${const AiAssistantResponse(message: 'Fenced').toJsonString()}\n```',
        ),
      ),
    ).send(_request());
    expect((result as AiSuccess).text, 'Fenced');
  });

  group('failures', () {
    for (final (int status, AiFailureKind kind) in <(int, AiFailureKind)>[
      (401, AiFailureKind.unauthorized),
      (403, AiFailureKind.unauthorized),
      (429, AiFailureKind.rateLimited),
      (500, AiFailureKind.server),
      (529, AiFailureKind.server),
    ]) {
      test('$status is ${kind.name}', () async {
        final AiResult result = await _client(
          (_) async => _sse(<String>['{"secret":"body"}'], status: status),
        ).send(_request());
        final AiFailure failure = (result as AiError).failure;
        expect(failure.kind, kind);
        _expectNothingLeaked(failure);
      });
    }

    test('an overloaded 529 is sent again once', () async {
      int calls = 0;
      final AiResult result = await _client((_) async {
        calls++;
        return calls == 1
            ? _sse(const <String>[], status: 529)
            : _sse(
                _stream(
                  const AiAssistantResponse(message: 'Ok').toJsonString(),
                ),
              );
      }).send(_request());
      expect(calls, 2);
      expect((result as AiSuccess).text, 'Ok');
    });

    test('an error event mid-stream is mapped by its type', () async {
      final AiResult result = await _client(
        (_) async => _sse(<String>[
          _event('error', <String, Object?>{
            'error': <String, Object?>{
              'type': 'overloaded_error',
              'message': 'Overloaded',
            },
          }),
        ]),
      ).send(_request());
      expect((result as AiError).failure.kind, AiFailureKind.server);
    });

    test('a refusal is blocked', () async {
      final AiResult result = await _client(
        (_) async => _sse(_stream('', stopReason: 'refusal')),
      ).send(_request());
      expect((result as AiError).failure.kind, AiFailureKind.blocked);
    });

    test('malformed JSON is malformed', () async {
      final AiResult result = await _client(
        (_) async => _sse(_stream('{"version":2,"message":')),
      ).send(_request());
      expect((result as AiError).failure.kind, AiFailureKind.malformed);
    });

    test('silence past the timeout is a timeout', () async {
      final AiResult result = await _client(
        (_) => Completer<http.StreamedResponse>().future,
        config: const AiApiConfig(
          apiKey: '',
          claudeApiKey: _fakeKey,
          timeout: Duration(milliseconds: 20),
        ),
      ).send(_request());
      expect((result as AiError).failure.kind, AiFailureKind.timeout);
    });

    test('a thrown error quotes nothing', () async {
      final AiResult result = await _client(
        (_) async =>
            throw http.ClientException('$_fakeKey ${base64Encode(_ink)}'),
      ).send(_request());
      final AiFailure failure = (result as AiError).failure;
      expect(failure.kind, AiFailureKind.network);
      _expectNothingLeaked(failure);
    });
  });
}
