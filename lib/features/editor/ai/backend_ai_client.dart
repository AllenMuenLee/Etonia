import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../../../backend/backend_service.dart';
import 'ai_client.dart';
import 'ai_notation.dart';
import 'streaming_ai_client.dart';

typedef BackendInvoke =
    Future<Map<String, dynamic>> Function(String, Map<String, Object?>);

/// The conversation text, selected crop, and drawing coordinates are forwarded
/// transiently. Full note images and PDFs are never sent; with Notation on, the
/// rest of the note is described only as coordinates.
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

  /// Keeps the most recent complete turns, compacted, the current user
  /// message being sent separately as [prompt]. Every turn kept is paid for
  /// again on each request, so only the last few go, and only the latest
  /// answer nearly whole: enough to follow up on it. Older turns are short
  /// excerpts, and a quick action is its label, not its long prompt.
  static List<Map<String, String>> _history(
    List<AiMessage> messages,
    int currentIndex,
  ) {
    const int maxMessages = 6;
    const int maxBytes = 8000;
    if (currentIndex <= 0) return const <Map<String, String>>[];
    final List<AiMessage> earlier = messages.take(currentIndex).toList();
    final List<Map<String, String>> history = <Map<String, String>>[
      for (int i = 0; i < earlier.length; i++)
        <String, String>{
          'role': earlier[i].role == AiRole.user ? 'user' : 'assistant',
          'content': _compactTurn(earlier[i], latest: i >= earlier.length - 2),
        },
    ];
    while (history.length > maxMessages ||
        utf8.encode(jsonEncode(history)).length > maxBytes) {
      history.removeAt(0);
    }
    // A truncated conversation must not begin with an orphaned answer.
    if (history.isNotEmpty && history.first['role'] == 'assistant') {
      history.removeAt(0);
    }
    return history;
  }

  /// [message] as history: the latest exchange's answer up to 2000
  /// characters, its question up to 600; anything older a one-line excerpt.
  static String _compactTurn(AiMessage message, {required bool latest}) {
    final String? label = message.label?.trim();
    if (message.role == AiRole.user && label != null && label.isNotEmpty) {
      return label;
    }
    if (latest) {
      return _excerpt(
        message.text.trim(),
        message.role == AiRole.user ? 600 : 2000,
      );
    }
    return _excerpt(
      message.text.replaceAll(RegExp(r'\s+'), ' ').trim(),
      message.role == AiRole.user ? 200 : 300,
    );
  }

  /// [text] cut to about [max] characters, at a word break, marked as cut.
  static String _excerpt(String text, int max) {
    if (text.length <= max) return text;
    int cut = text.lastIndexOf(' ', max);
    if (cut < max * 0.6) cut = max;
    return '${text.substring(0, cut).trimRight()} …';
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
    final int latestIndex = request.messages.lastIndexWhere(
      (AiMessage message) => message.role == AiRole.user,
    );
    final AiMessage latest = latestIndex < 0
        ? const AiMessage.user('')
        : request.messages[latestIndex];
    if (latest.text.trim().isEmpty) {
      return const AiError(AiFailure(AiFailureKind.rejected));
    }
    try {
      final note = request.noteImage;
      final focus = note?.normalizedFocusBounds;
      final bool notation =
          request.notationEnabled && note != null && focus != null;
      final history = _history(request.messages, latestIndex);
      final response = await (invoke ?? _backend.invoke)('ai', {
        'requestId': _requestId(),
        'model': (request.model ?? defaultModel).name,
        'prompt': latest.text,
        if (history.isNotEmpty) 'history': history,
        // The fixed instruction, the same for every request, so providers
        // read it from their cache at a fraction of the price.
        'systemInstruction': request.systemInstruction,
        // The note travels as coordinates, never as a picture: where the
        // selection is, its ink, boxes round what is near it, and where the
        // paper is blank. Apart, so it does not break the cached prefix.
        if (notation) 'noteMetadata': aiNoteMetadata(note),
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
          'rejected' => AiFailureKind.rejected,
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
