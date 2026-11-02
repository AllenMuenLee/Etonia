import 'dart:convert';

import 'ai_client.dart';
import 'ai_config.dart';
import 'streaming_ai_client.dart';

/// Calls Anthropic's streaming Messages API directly from the app.
///
/// The key travels only in the `x-api-key` header. Claude is told to answer
/// as a self-contained SVG document by the system instruction; a code fence
/// around it is tolerated.
class ClaudeAiClient extends SseAiClient {
  ClaudeAiClient({
    required this.config,
    required this.model,
    super.httpClient,
    super.notationConfig,
  }) : super(timing: config);

  final AiApiConfig config;

  /// The Claude model ID, such as `claude-sonnet-5-5`.
  final String model;

  static const String apiVersion = '2023-06-01';

  @override
  bool get isConfigured => config.claudeKey.isNotEmpty;

  @override
  String get modelLabel => model;

  @override
  Uri get endpoint => Uri.parse('${config.claudeBaseUrl}/messages');

  @override
  Map<String, String> get headers => <String, String>{
    'x-api-key': config.claudeKey,
    'anthropic-version': apiVersion,
  };

  /// Claude answers 529 when it is overloaded, at once.
  @override
  Set<int> get retriedStatuses => const <int>{500, 503, 529};

  @override
  Map<String, Object?> body(AiRequest request) =>
      buildBody(request, model: model, notationConfig: notationConfig);

  /// The JSON body for [request]. The first user turn carries the clean PNG
  /// crop and, with Notation on, the same selection as SVG beside it.
  static Map<String, Object?> buildBody(
    AiRequest request, {
    required String model,
    AiNotationConfig notationConfig = const AiNotationConfig(),
  }) {
    final int lastUser = aiLastUserIndex(request);
    bool selectionPending = true;
    final String? selectionSvg = request.modelSelectionSvg;
    Map<String, Object?> image(List<int> png) => <String, Object?>{
      'type': 'image',
      'source': <String, Object?>{
        'type': 'base64',
        'media_type': 'image/png',
        'data': base64Encode(png),
      },
    };
    Map<String, Object?> text(String value) => <String, Object?>{
      'type': 'text',
      'text': value,
    };
    final List<Map<String, Object?>> messages = <Map<String, Object?>>[];
    for (int index = 0; index < request.messages.length; index++) {
      final AiMessage message = request.messages[index];
      if (message.role == AiRole.model) {
        messages.add(<String, Object?>{
          'role': 'assistant',
          'content': message.historyText,
        });
        continue;
      }
      final bool withSelection = selectionPending;
      selectionPending = false;
      messages.add(<String, Object?>{
        'role': 'user',
        'content': <Map<String, Object?>>[
          if (withSelection) ...<Map<String, Object?>>[
            text('Selected ink image:'),
            image(request.imagePng),
            if (selectionSvg != null) text(aiSelectionSvgText(selectionSvg)),
            if (request.sourceLines case final String lines)
              text(aiSourceLinesText(lines)),
          ],
          if (request.noteImage case final note? when index == lastUser)
            text(aiNoteMetadata(note)),
          text(message.wireText),
        ],
      });
    }
    return <String, Object?>{
      'model': model,
      'max_tokens': notationConfig.maxOutputTokens,
      'stream': true,
      'system': request.providerSystemInstruction,
      'messages': messages,
    };
  }

  @override
  SseAnswerReader newReader(AiPartialCallback? onPartial) =>
      _ClaudeAnswerReader(notationConfig, onPartial);
}

class _ClaudeAnswerReader extends SseAnswerReader {
  _ClaudeAnswerReader(super.config, super.onPartial);

  @override
  void onEvent(String? type, Object? json) {
    if (json is! Map<String, Object?>) {
      malformed = true;
      return;
    }
    switch (json['type'] ?? type) {
      case 'message_start':
        if (json['message'] case {'usage': final Map<String, Object?> usage}) {
          _readUsage(usage);
        }
      case 'content_block_delta':
        if (json['delta'] case {
          'type': 'text_delta',
          'text': final String piece,
        }) {
          addText(piece);
        }
      case 'message_delta':
        if (json['usage'] case final Map<String, Object?> usage) {
          _readUsage(usage);
        }
        if (json['delta'] case {'stop_reason': 'refusal'}) {
          blocked = true;
        }
      case 'message_stop':
        markDone();
      case 'error':
        final Object? kind = json['error'] is Map<String, Object?>
            ? (json['error']! as Map<String, Object?>)['type']
            : null;
        error = AiFailure(switch (kind) {
          'authentication_error' ||
          'permission_error' => AiFailureKind.unauthorized,
          'rate_limit_error' => AiFailureKind.rateLimited,
          'invalid_request_error' ||
          'request_too_large' => AiFailureKind.rejected,
          _ => AiFailureKind.server,
        }, statusCode: kind == 'overloaded_error' ? 529 : null);
    }
  }

  /// Reads the running token counts; cached prompt tokens are input too.
  void _readUsage(Map<String, Object?> usage) {
    int? sum(List<String> keys) {
      int? total;
      for (final String key in keys) {
        if (usage[key] case final int value) {
          total = (total ?? 0) + value;
        }
      }
      return total;
    }

    inputTokens =
        sum(const <String>[
          'input_tokens',
          'cache_creation_input_tokens',
          'cache_read_input_tokens',
        ]) ??
        inputTokens;
    outputTokens = sum(const <String>['output_tokens']) ?? outputTokens;
  }
}
