import 'dart:convert';

import 'ai_client.dart';
import 'ai_config.dart';
import 'streaming_ai_client.dart';

/// Calls OpenAI's streaming Chat Completions directly from the app.
///
/// The key travels only in the `Authorization` header. The answer is asked
/// for as a JSON object, in the same version-2 envelope Gemini returns.
class OpenAiClient extends SseAiClient {
  OpenAiClient({
    required this.config,
    required this.model,
    super.httpClient,
    super.notationConfig,
  }) : super(timing: config);

  final AiApiConfig config;

  /// The OpenAI model ID, such as `gpt-6.1-sol`.
  final String model;

  /// The most output the request asks for; OpenAI's chat models stop at
  /// this.
  static const int maxOutputTokens = 32768;

  @override
  bool get isConfigured => config.openAiKey.isNotEmpty;

  @override
  String get modelLabel => model;

  @override
  Uri get endpoint => Uri.parse('${config.openAiBaseUrl}/chat/completions');

  @override
  Map<String, String> get headers => <String, String>{
    'Authorization': 'Bearer ${config.openAiKey}',
  };

  @override
  Map<String, Object?> body(AiRequest request) =>
      buildBody(request, model: model, notationConfig: notationConfig);

  /// The JSON body for [request]. The selected ink rides in the first user
  /// turn, and the whole note with its metadata in the last, on every call.
  static Map<String, Object?> buildBody(
    AiRequest request, {
    required String model,
    AiNotationConfig notationConfig = const AiNotationConfig(),
  }) {
    final int lastUser = aiLastUserIndex(request);
    bool imagePending = true;
    Map<String, Object?> image(List<int> png) => <String, Object?>{
      'type': 'image_url',
      'image_url': <String, Object?>{
        'url': 'data:image/png;base64,${base64Encode(png)}',
      },
    };
    Map<String, Object?> text(String value) => <String, Object?>{
      'type': 'text',
      'text': value,
    };
    final List<Map<String, Object?>> messages = <Map<String, Object?>>[
      <String, Object?>{'role': 'system', 'content': request.systemInstruction},
    ];
    for (int index = 0; index < request.messages.length; index++) {
      final AiMessage message = request.messages[index];
      if (message.role == AiRole.model) {
        messages.add(<String, Object?>{
          'role': 'assistant',
          'content': message.wireText,
        });
        continue;
      }
      final bool withImage = imagePending;
      imagePending = false;
      messages.add(<String, Object?>{
        'role': 'user',
        'content': <Map<String, Object?>>[
          if (withImage) ...<Map<String, Object?>>[
            text('Selected ink image:'),
            image(request.imagePng),
          ],
          if (request.noteImage case final note? when index == lastUser)
            text(aiNoteMetadata(note)),
          text(message.wireText),
        ],
      });
    }
    return <String, Object?>{
      'model': model,
      'stream': true,
      'stream_options': <String, Object?>{'include_usage': true},
      'response_format': <String, Object?>{'type': 'json_object'},
      'max_completion_tokens': notationConfig.maxOutputTokens < maxOutputTokens
          ? notationConfig.maxOutputTokens
          : maxOutputTokens,
      'messages': messages,
    };
  }

  @override
  SseAnswerReader newReader(AiPartialCallback? onPartial) =>
      _OpenAiAnswerReader(notationConfig, onPartial);
}

class _OpenAiAnswerReader extends SseAnswerReader {
  _OpenAiAnswerReader(super.config, super.onPartial);

  @override
  void onEvent(String? type, Object? json) {
    if (json is! Map<String, Object?>) {
      malformed = true;
      return;
    }
    if (json['error'] case final Map<String, Object?> failure) {
      final Object? code = failure['code'];
      error = AiFailure(switch (failure['type']) {
        'insufficient_quota' ||
        'rate_limit_exceeded' => AiFailureKind.rateLimited,
        'invalid_request_error' => AiFailureKind.rejected,
        _ when code == 'content_filter' => AiFailureKind.blocked,
        _ => AiFailureKind.server,
      });
      return;
    }
    if (json['usage'] case final Map<String, Object?> usage) {
      if (usage['prompt_tokens'] case final int prompt) {
        inputTokens = prompt;
      }
      if (usage['completion_tokens'] case final int completion) {
        outputTokens = completion;
      }
    }
    final Object? choices = json['choices'];
    if (choices is! List<Object?> || choices.isEmpty) {
      return;
    }
    final Object? choice = choices.first;
    if (choice is! Map<String, Object?>) {
      return;
    }
    if (choice['finish_reason'] == 'content_filter') {
      blocked = true;
    }
    if (choice['delta'] case final Map<String, Object?> delta) {
      if (delta['refusal'] case final String refusal when refusal.isNotEmpty) {
        blocked = true;
      }
      if (delta['content'] case final String piece) {
        addText(piece);
      }
    }
  }
}
