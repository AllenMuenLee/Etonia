import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../../../backend/backend_service.dart';
import 'ai_client.dart';
import 'ai_notation.dart';
import 'streaming_ai_client.dart';

typedef BackendInvoke =
    Future<Map<String, dynamic>> Function(String, Map<String, Object?>);

/// Only the current prompt, selected crop, and drawing coordinates are forwarded
/// transiently. Full note images, PDFs and conversation history are never sent;
/// with Notation on, the rest of the note is described only as coordinates.
class BackendAiClient implements AiModelRouter {
  BackendAiClient({BackendService? backend, this.invoke})
    : _backend = backend ?? BackendService.instance;
  final BackendService _backend;
  final BackendInvoke? invoke;
  bool _closed = false;
  @override
  AiModelId get defaultModel => AiModelId.sol;
  @override
  List<AiModelId> get models => AiModelId.values;
  @override
  bool get isConfigured => invoke != null || _backend.isConfigured;
  @override
  bool isModelConfigured(AiModelId model) => isConfigured;
  @override
  String get modelLabel => defaultModel.label;

  static String _requestId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  @override
  Future<AiResult> send(
    AiRequest request, {
    AiPartialCallback? onPartial,
  }) async {
    if (_closed) return const AiError(AiFailure(AiFailureKind.interrupted));
    if (!isConfigured) {
      return const AiError(AiFailure(AiFailureKind.notConfigured));
    }
    final latest = request.messages.lastWhere(
      (m) => m.role == AiRole.user,
      orElse: () => const AiMessage.user(''),
    );
    if (latest.text.trim().isEmpty) {
      return const AiError(AiFailure(AiFailureKind.rejected));
    }
    try {
      final note = request.noteImage;
      final focus = note?.normalizedFocusBounds;
      final bool notation =
          request.notationEnabled && note != null && focus != null;
      final response = await (invoke ?? _backend.invoke)('ai', {
        'requestId': _requestId(),
        'model': (request.model ?? defaultModel).name,
        'prompt': latest.text,
        // The note travels as coordinates in the instruction, never as a
        // picture: where the selection is, its ink, boxes round what is
        // near it, and where the paper is blank.
        'systemInstruction': notation
            ? '${request.systemInstruction}\n\n${aiNoteMetadata(note)}'
            : request.systemInstruction,
        'selectedImage': base64Encode(request.imagePng),
        // Formatted output: the provider must answer in exactly this
        // shape, the words in message and the drawing in notation.
        if (notation) 'responseSchema': aiResponseJsonSchema(),
        if (notation)
          'notationContext': {
            'width': note.logicalSize.width,
            'height': note.logicalSize.height,
            // The crop's padding can run past the paper; the service takes
            // only the paper.
            'left': focus.left.clamp(0.0, 1.0),
            'top': focus.top.clamp(0.0, 1.0),
            'right': focus.right.clamp(0.0, 1.0),
            'bottom': focus.bottom.clamp(0.0, 1.0),
          },
      });
      if (_closed) return const AiError(AiFailure(AiFailureKind.interrupted));
      final String raw = stripJsonFence(response['answer'] as String);
      final AiAssistantResponse answer;
      try {
        answer = AiAssistantResponse.parse(raw);
      } on FormatException {
        // Usually cut off by the output limit, which reasoning counts
        // against. Words that all arrived are kept, as when a stream
        // breaks off; the drawing is lost.
        final (String, bool)? words = AiAssistantResponse.partialMessageState(
          raw,
        );
        if (words != null && words.$2) {
          onPartial?.call(words.$1, true);
        }
        return const AiError(AiFailure(AiFailureKind.malformed));
      }
      onPartial?.call(answer.message, true);
      final usage = response['usage'] as Map<String, dynamic>;
      return AiSuccess(
        answer.message,
        notation: request.notationEnabled ? answer.notation : null,
        notationRejected: answer.notationRejected,
        usage: AiTokenUsage(
          inputTokens: usage['inputTokens'] as int,
          outputTokens: usage['outputTokens'] as int,
        ),
      );
    } on BackendFailure catch (error) {
      return AiError(
        AiFailure(switch (error.code) {
          'unauthorized' => AiFailureKind.unauthorized,
          'not_configured' => AiFailureKind.notConfigured,
          'plan_required' => AiFailureKind.planRequired,
          'insufficient_credits' => AiFailureKind.insufficientCredits,
          'rate_limited' || 'request_in_progress' => AiFailureKind.rateLimited,
          _ => AiFailureKind.server,
        }),
      );
    } on TimeoutException {
      return const AiError(AiFailure(AiFailureKind.timeout));
    } on Object {
      return const AiError(AiFailure(AiFailureKind.network));
    } finally {
      if (invoke == null) _backend.billingChanged();
    }
  }

  @override
  void close() => _closed = true;
}
