import 'dart:typed_data';

import 'ai_notation.dart';
import 'note_image_renderer.dart';

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
  }) : messages = List<AiMessage>.unmodifiable(messages);

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
        'AI is not set up. Add a Gemini API key to send messages.',
      AiFailureKind.timeout => 'The AI service took too long to respond.',
      AiFailureKind.network =>
        'Could not reach the AI service. Check your connection.',
      AiFailureKind.unauthorized => 'The AI service rejected the API key.',
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

class AiSuccess extends AiResult {
  const AiSuccess(this.text, {this.notation, this.notationRejected = false});

  factory AiSuccess.response(AiAssistantResponse response) {
    return AiSuccess(
      response.message,
      notation: response.notation,
      notationRejected: response.notationRejected,
    );
  }

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
