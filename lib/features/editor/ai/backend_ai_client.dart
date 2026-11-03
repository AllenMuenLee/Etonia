import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../../../backend/backend_service.dart';
import 'ai_client.dart';
import 'ai_notation.dart';
import 'streaming_ai_client.dart';

typedef BackendInvoke =
    Future<Map<String, dynamic>> Function(String, Map<String, Object?>);
typedef BackendInvokeStream =
    Future<Stream<Map<String, dynamic>>> Function(String, Map<String, Object?>);

/// The conversation text, selected crop, and page-coordinate selection SVG are
/// forwarded transiently. Full note images and PDFs are never sent; with
/// Notation on, the rest of the note is described only as coordinates.
class BackendAiClient implements AiModelRouter {
  BackendAiClient({BackendService? backend, this.invoke, this.invokeStream})
    : _backend = backend ?? BackendService.instance;
  final BackendService _backend;
  final BackendInvoke? invoke;
  final BackendInvokeStream? invokeStream;
  bool _closed = false;
  @override
  AiModelId get defaultModel => AiModelId.sol;
  @override
  List<AiModelId> get models => AiModelId.values;
  @override
  bool get isConfigured =>
      invoke != null || invokeStream != null || _backend.isConfigured;
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

  /// Keeps twelve complete turns: enough for sustained follow-ups without
  /// paying again for an unbounded transcript. Old turns are compact, the
  /// latest two stay detailed, and applied notation is never resent.
  static List<Map<String, String>> _history(
    List<AiMessage> messages,
    int currentIndex,
  ) {
    const int maxMessages = 24;
    const int maxBytes = 24000;
    if (currentIndex <= 0) return const <Map<String, String>>[];
    final List<AiMessage> earlier = messages.take(currentIndex).toList();
    final List<Map<String, String>> history = <Map<String, String>>[
      for (int i = 0; i < earlier.length; i++)
        <String, String>{
          'role': earlier[i].role == AiRole.user ? 'user' : 'assistant',
          'content': _compactTurn(earlier[i], recent: i >= earlier.length - 4),
        },
    ];
    while (history.length > maxMessages ||
        utf8.encode(jsonEncode(history)).length > maxBytes) {
      // Remove whole turns, never leave an orphan assistant answer.
      history.removeAt(0);
      if (history.isNotEmpty && history.first['role'] == 'assistant') {
        history.removeAt(0);
      }
    }
    return history;
  }

  static String _compactTurn(AiMessage message, {required bool recent}) {
    final String? label = message.label?.trim();
    if (message.role == AiRole.user && label != null && label.isNotEmpty) {
      return label;
    }
    final String text = recent
        ? message.historyText.trim()
        : message.historyText.replaceAll(RegExp(r'\s+'), ' ').trim();
    final int limit = recent
        ? (message.role == AiRole.user ? 1200 : 4000)
        : (message.role == AiRole.user ? 400 : 700);
    if (text.length <= limit) return text;
    int cut = text.lastIndexOf(' ', limit);
    if (cut < limit * 0.6) cut = limit;
    return '${text.substring(0, cut).trimRight()} …';
  }

  @override
  Future<AiResult> send(
    AiRequest request, {
    AiPartialCallback? onPartial,
    AiNotationPartialCallback? onNotation,
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
      final double? clampedLeft = focus?.left.clamp(0.0, 1.0);
      final double? clampedTop = focus?.top.clamp(0.0, 1.0);
      final double? clampedRight = focus?.right.clamp(0.0, 1.0);
      final double? clampedBottom = focus?.bottom.clamp(0.0, 1.0);
      final bool validFocus =
          clampedLeft != null &&
          clampedTop != null &&
          clampedRight != null &&
          clampedBottom != null &&
          clampedLeft < clampedRight &&
          clampedTop < clampedBottom;
      final bool notation =
          request.notationEnabled && note != null && validFocus;
      final history = _history(request.messages, latestIndex);
      final Map<String, Object?> body = <String, Object?>{
        'requestId': _requestId(),
        'model': (request.model ?? defaultModel).name,
        'prompt': latest.text,
        if (history.isNotEmpty) 'history': history,
        // The fixed instruction, the same for every request, so providers
        // read it from their cache at a fraction of the price.
        'systemInstruction': request.systemInstruction,
        // The large notation grammar goes only to the model that draws the
        // answer, never to the one that writes it.
        if (notation && request.notationInstruction != null)
          'notationInstruction': request.notationInstruction,
        if (notation) 'animationAllowed': request.animationEnabled,
        // Asked for, since a client that does not know the events refuses them.
        if (notation && onNotation != null) 'liveNotation': true,
        // The note travels as coordinates, never as a picture: where the
        // selection is, its ink, boxes round what is near it, and where the
        // paper is blank. Apart, so it does not break the cached prefix.
        if (notation) 'noteMetadata': aiNoteMetadata(note),
        'selectedImage': base64Encode(request.imagePng),
        if (notation && request.selectionSvg != null)
          'selectedSvg': request.selectionSvg,
        // Formatted output: the provider must answer in exactly this
        if (notation)
          'notationContext': {
            'width': note.logicalSize.width,
            'height': note.logicalSize.height,
            // The crop's padding can run past the paper; the service takes
            // only the paper.
            'left': clampedLeft,
            'top': clampedTop,
            'right': clampedRight,
            'bottom': clampedBottom,
          },
      };
      final Map<String, dynamic> response = await _invoke(
        body,
        notation: notation,
        onPartial: onPartial,
        onNotation: onNotation,
      );
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
        citations: answer.citations,
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
      if (invoke == null && invokeStream == null) _backend.billingChanged();
    }
  }

  Future<Map<String, dynamic>> _invoke(
    Map<String, Object?> body, {
    required bool notation,
    required AiPartialCallback? onPartial,
    required AiNotationPartialCallback? onNotation,
  }) async {
    final BackendInvokeStream? streamCall =
        invokeStream ?? (invoke == null ? _backend.invokeStream : null);
    if (!notation || streamCall == null) {
      return (invoke ?? _backend.invoke)('ai', body);
    }
    Map<String, dynamic>? result;
    final StringBuffer svg = StringBuffer();
    await for (final Map<String, dynamic> event in await streamCall(
      'ai',
      body,
    )) {
      switch (event['type']) {
        case 'message':
          final Object? message = event['message'];
          if (message is! String || message.trim().isEmpty) {
            throw const BackendFailure('server');
          }
          onPartial?.call(message, true);
        case 'notation':
          // Only for display, so a bad one costs the preview at most.
          if (event['delta'] case final String delta) {
            svg.write(delta);
            onNotation?.call(svg.toString());
          }
        case 'result':
          if (event['answer'] is! String ||
              event['usage'] is! Map<String, dynamic>) {
            throw const BackendFailure('server');
          }
          result = event;
        case 'error':
          final Object? code = event['error'];
          throw BackendFailure(code is String ? code : 'server');
        case null:
          // A non-streaming server response during rollout.
          result = event;
        default:
          throw const BackendFailure('server');
      }
    }
    return result ?? (throw const BackendFailure('server'));
  }

  @override
  void close() => _closed = true;
}
