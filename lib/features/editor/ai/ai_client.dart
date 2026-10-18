import 'dart:typed_data';

import 'ai_models.dart';
import 'ai_notation.dart';
import 'note_image_renderer.dart';

export 'ai_models.dart';

/// Receives the assistant's message as far as it has been written, and
/// whether all of it has: then only the notation, if any, is still coming.
typedef AiPartialCallback = void Function(String message, bool isComplete);

/// Who wrote a chat message.
enum AiRole { user, model }

/// One chat message. Immutable.
class AiMessage {
  const AiMessage({
    required this.role,
    required this.text,
    this.label,
    this.notation,
    this.notationStatus = AiNotationStatus.none,
  });

  const AiMessage.user(this.text, {this.label})
    : role = AiRole.user,
      notation = null,
      notationStatus = AiNotationStatus.none;

  const AiMessage.model(
    this.text, {
    this.notation,
    this.notationStatus = AiNotationStatus.none,
  }) : role = AiRole.model,
       label = null;

  final AiRole role;

  /// What the model is sent, or what it answered.
  final String text;

  /// Shown in the transcript in place of [text], for a quick action.
  final String? label;

  final AiNotation? notation;

  /// Local-only result of attempting to apply [notation].
  final AiNotationStatus notationStatus;

  String get displayText => label ?? text;

  /// This message, with what the app did with its notation now [status].
  AiMessage withNotationStatus(AiNotationStatus status) {
    return AiMessage(
      role: role,
      text: text,
      label: label,
      notation: notation,
      notationStatus: status,
    );
  }

  /// Provider history keeps the fixed model envelope but never local status.
  String get wireText => role == AiRole.user
      ? text
      : AiAssistantResponse(message: text, notation: notation).toJsonString();
}

/// Everything one stateless `generateContent` call needs. Immutable.
class AiRequest {
  AiRequest({
    required this.systemInstruction,
    required this.imagePng,
    required List<AiMessage> messages,
    this.noteImage,
    this.notationEnabled = false,
    this.animationEnabled = false,
    this.model,
  }) : messages = List<AiMessage>.unmodifiable(messages);

  /// Which model answers, for a client that serves several
  /// ([AiModelRouter]). A client with one model ignores it.
  final AiModelId? model;

  final String systemInstruction;

  /// The selected ink, sent with the first user message of every request.
  final Uint8List imagePng;

  /// Present only for a request submitted with Notation enabled.
  final NoteImage? noteImage;

  final bool notationEnabled;

  /// Whether a request with notation may use meaningful timed motion.
  final bool animationEnabled;

  /// The conversation in order, ending with the user message to answer.
  final List<AiMessage> messages;
}

/// Why a request produced no answer.
enum AiFailureKind {
  /// No API key was configured.
  notConfigured,

  /// No response within the configured time.
  timeout,

  /// The service could not be reached.
  network,

  /// The key was refused.
  unauthorized,

  /// Too many requests, or the quota is spent.
  rateLimited,

  /// The service refused the request as invalid.
  rejected,

  /// The service failed.
  server,

  /// The prompt or the answer was blocked.
  blocked,

  /// A response with no answer in it.
  empty,

  /// A response that could not be understood.
  malformed,

  /// The current note could not be captured for Notation.
  noteUnavailable,

  /// The note was closed before the answer arrived.
  interrupted,

  /// No active plan includes the chosen model.
  planRequired,

  /// The plan's AI credits for metered models are spent.
  insufficientCredits,
}

/// A failed request. Carries nothing from the request or the response body,
/// so it is safe to show and to log.
class AiFailure {
  const AiFailure(this.kind, {this.statusCode});

  final AiFailureKind kind;

  /// The HTTP status, when there was one.
  final int? statusCode;

  /// What the user is told.
  String get message {
    return switch (kind) {
      AiFailureKind.notConfigured =>
        'AI account services are not configured in this build.',
      AiFailureKind.timeout => 'The AI service took too long to respond.',
      AiFailureKind.network =>
        'Could not reach the AI service. Check your connection.',
      AiFailureKind.unauthorized => 'Sign in from Plans & Credits to use AI.',
      AiFailureKind.rateLimited =>
        'The AI service is busy or over its limit. Try again shortly.',
      AiFailureKind.rejected => 'The AI service could not accept the request.',
      AiFailureKind.server => 'The AI service had a problem. Try again.',
      AiFailureKind.blocked =>
        'The AI service declined to answer this request.',
      AiFailureKind.empty => 'The AI service returned an empty answer.',
      AiFailureKind.malformed =>
        'The AI service returned an answer that could not be read.',
      AiFailureKind.noteUnavailable =>
        'The current note could not be prepared for Notation.',
      AiFailureKind.interrupted =>
        'The note was closed before the answer arrived. Try again.',
      AiFailureKind.planRequired =>
        'Your plan does not include this model. Upgrade in Plans & '
            'Credits, or pick a model your plan includes.',
      AiFailureKind.insufficientCredits =>
        'Your AI credits are used up. Upgrade in Plans & Credits; Haiku '
            'and Luna are unlimited on every paid plan.',
    };
  }

  @override
  String toString() {
    return 'AiFailure(${kind.name}'
        '${statusCode == null ? '' : ', status $statusCode'})';
  }
}

/// The outcome of a request: the answer, or why there is none.
sealed class AiResult {
  const AiResult();
}

/// The tokens one answer took, as the provider reported them or, when it
/// did not, as [AiTokenUsage.estimate] guessed.
class AiTokenUsage {
  const AiTokenUsage({
    required this.inputTokens,
    required this.outputTokens,
    this.estimated = false,
  });

  /// About what a provider counts for the one image the app sends, at most
  /// [AiImageConfig.maxDimension] on a side.
  static const int imageTokens = 800;

  /// Characters per token, near enough for English and JSON.
  static const int charactersPerToken = 4;

  /// A deterministic guess from what was sent and what came back, for a
  /// provider that reported no usage.
  factory AiTokenUsage.estimate(AiRequest request, String answer) {
    int characters = request.systemInstruction.length;
    for (final AiMessage message in request.messages) {
      characters += message.wireText.length;
    }
    return AiTokenUsage(
      inputTokens: (characters / charactersPerToken).ceil() + imageTokens,
      outputTokens: (answer.length / charactersPerToken).ceil(),
      estimated: true,
    );
  }

  final int inputTokens;
  final int outputTokens;

  /// Whether this was guessed rather than reported.
  final bool estimated;

  @override
  bool operator ==(Object other) {
    return other is AiTokenUsage &&
        other.inputTokens == inputTokens &&
        other.outputTokens == outputTokens &&
        other.estimated == estimated;
  }

  @override
  int get hashCode => Object.hash(inputTokens, outputTokens, estimated);

  @override
  String toString() {
    return 'AiTokenUsage(in: $inputTokens, out: $outputTokens'
        '${estimated ? ', estimated' : ''})';
  }
}

class AiSuccess extends AiResult {
  const AiSuccess(
    this.text, {
    this.notation,
    this.notationRejected = false,
    this.usage,
  });

  factory AiSuccess.response(
    AiAssistantResponse response, {
    AiTokenUsage? usage,
  }) {
    return AiSuccess(
      response.message,
      notation: response.notation,
      notationRejected: response.notationRejected,
      usage: usage,
    );
  }

  /// The tokens the answer took, when the provider said.
  final AiTokenUsage? usage;

  final String text;
  final AiNotation? notation;

  /// Whether a notation came with the answer but was unusable, and was
  /// dropped whole. [text] is still the answer.
  final bool notationRejected;
}

class AiError extends AiResult {
  const AiError(this.failure);

  final AiFailure failure;
}

/// Answers a conversation about an image. The editor depends on this alone,
/// so a production build can swap the direct Gemini client for one that
/// calls a backend holding the provider key.
abstract class AiClient {
  /// Whether [send] can work at all. False when no key is configured.
  bool get isConfigured;

  /// Shown in the panel header.
  String get modelLabel;

  /// Never throws: every failure is an [AiError].
  ///
  /// While the answer streams in, [onPartial] is told the readable message
  /// written so far, each time it grows. It is for display only: the
  /// result, and any notation in it, arrives once the answer is complete.
  Future<AiResult> send(AiRequest request, {AiPartialCallback? onPartial});

  /// Releases what the client holds. It must not be used afterwards.
  void close();
}

/// A client that serves several models, chosen per request by
/// [AiRequest.model].
abstract class AiModelRouter implements AiClient {
  /// Every model a request may name, in the order the picker shows them.
  List<AiModelId> get models;

  /// The model a request that names none is answered by.
  AiModelId get defaultModel;

  /// Whether a request naming [model] can be sent: its provider has a key.
  bool isModelConfigured(AiModelId model);
}
