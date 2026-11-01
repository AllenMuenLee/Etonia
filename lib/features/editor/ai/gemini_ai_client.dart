import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_client.dart';
import 'ai_config.dart';
import 'ai_notation.dart';
import 'streaming_ai_client.dart';

/// Calls Gemini's streaming `generateContent` directly from the app.
///
/// The request carries the selection image and the conversation, and the key
/// travels only in the `x-goog-api-key` header. Nothing sent or received is
/// logged, and no failure carries any of it.
class GeminiAiClient implements AiClient {
  /// With no [httpClient], one is created on first use and closed by
  /// [close]. A client passed in stays the caller's to close.
  GeminiAiClient({
    required this.config,
    http.Client? httpClient,
    this.notationConfig = const AiNotationConfig(),
  }) : _httpClient = httpClient,
       _ownsHttpClient = httpClient == null;

  final AiApiConfig config;
  final AiNotationConfig notationConfig;
  final bool _ownsHttpClient;
  http.Client? _httpClient;
  bool _closed = false;

  static const Set<String> _blockingFinishReasons = <String>{
    'SAFETY',
    'RECITATION',
    'LANGUAGE',
    'BLOCKLIST',
    'PROHIBITED_CONTENT',
    'SPII',
    'IMAGE_SAFETY',
  };

  @override
  bool get isConfigured => config.hasApiKey;

  @override
  String get modelLabel => config.modelLabel;

  /// The JSON body for [request]. The first user turn carries the clean PNG
  /// crop and, with Notation on, the same selection as SVG beside it, on
  /// every call: the endpoint keeps no state.
  static Map<String, Object?> buildBody(
    AiRequest request, {
    String? thinkingLevel = AiApiConfig.defaultThinkingLevel,
    int? thinkingBudget = AiApiConfig.defaultThinkingBudget,
    AiNotationConfig notationConfig = const AiNotationConfig(),
  }) {
    bool selectionPending = true;
    final String? selectionSvg = request.modelSelectionSvg;
    int lastUser = -1;
    for (int i = 0; i < request.messages.length; i++) {
      if (request.messages[i].role == AiRole.user) {
        lastUser = i;
      }
    }
    final List<Map<String, Object?>> contents = <Map<String, Object?>>[];
    for (int index = 0; index < request.messages.length; index++) {
      final AiMessage message = request.messages[index];
      final bool withSelection =
          selectionPending && message.role == AiRole.user;
      if (withSelection) {
        selectionPending = false;
      }
      contents.add(<String, Object?>{
        'role': message.role.name,
        'parts': <Map<String, Object?>>[
          if (withSelection) ...<Map<String, Object?>>[
            <String, Object?>{'text': 'Selected ink image:'},
            <String, Object?>{
              'inline_data': <String, Object?>{
                'mime_type': 'image/png',
                'data': base64Encode(request.imagePng),
              },
            },
            if (selectionSvg != null)
              <String, Object?>{'text': aiSelectionSvgText(selectionSvg)},
          ],
          if (request.noteImage case final note? when index == lastUser)
            <String, Object?>{'text': aiNoteMetadata(note)},
          <String, Object?>{'text': message.historyText},
        ],
      });
    }
    return <String, Object?>{
      'system_instruction': <String, Object?>{
        'parts': <Map<String, Object?>>[
          <String, Object?>{'text': request.providerSystemInstruction},
        ],
      },
      'contents': contents,
      'generationConfig': <String, Object?>{
        'responseMimeType': 'text/plain',
        'maxOutputTokens': notationConfig.maxOutputTokens,
        if (thinkingLevel != null || thinkingBudget != null)
          'thinkingConfig': <String, Object?>{
            'thinkingLevel': ?thinkingLevel,
            'thinkingBudget': ?thinkingBudget,
          },
      },
    };
  }

  @override
  Future<AiResult> send(
    AiRequest request, {
    AiPartialCallback? onPartial,
  }) async {
    if (!isConfigured) {
      return const AiError(AiFailure(AiFailureKind.notConfigured));
    }
    final String body = jsonEncode(
      buildBody(
        request,
        thinkingLevel: config.requestThinking.level,
        thinkingBudget: config.requestThinking.budget,
        notationConfig: notationConfig,
      ),
    );
    final _AnswerReader reader = _AnswerReader(notationConfig, onPartial);
    AiResult result = await _attempt(body, reader);
    // Only an internal error or an unavailable service is sent again: the
    // service answers those at once, having generated nothing. Anything
    // that may have produced an answer, such as a timeout or a stream cut
    // off part way, is not.
    for (
      int retry = 0;
      retry < config.serverErrorRetries &&
          !reader.hasText &&
          result is AiError &&
          (result.failure.statusCode == 500 ||
              result.failure.statusCode == 503);
      retry++
    ) {
      await Future<void>.delayed(config.retryDelay);
      result = await _attempt(body, reader);
    }
    return result;
  }

  Future<AiResult> _attempt(String body, _AnswerReader reader) async {
    if (_closed) {
      return const AiError(AiFailure(AiFailureKind.network));
    }
    // Completing this drops the connection: after a timeout, an error
    // status, or a body over the size limit.
    final Completer<void> abort = Completer<void>();
    try {
      final http.AbortableRequest post =
          http.AbortableRequest(
              'POST',
              config.endpoint,
              abortTrigger: abort.future,
            )
            ..headers['Content-Type'] = 'application/json'
            ..headers['x-goog-api-key'] = config.apiKey
            ..body = body;
      final http.Client client = _httpClient ??= http.Client();
      // Silence is limited to [AiApiConfig.timeout], waiting for the
      // service and between the pieces of its answer; the whole attempt to
      // [AiApiConfig.maxDuration].
      return await client
          .send(post)
          .timeout(config.timeout)
          .then(
            (http.StreamedResponse response) => _read(response, reader, abort),
          )
          .timeout(config.maxDuration);
    } on TimeoutException {
      if (!abort.isCompleted) {
        abort.complete();
      }
      return const AiError(AiFailure(AiFailureKind.timeout));
    } on Object {
      // Deliberately not inspected: an error's text can quote the request.
      return const AiError(AiFailure(AiFailureKind.network));
    }
  }

  /// Reads a streamed answer event by event, telling [reader] each one.
  /// The body is never echoed into a failure.
  Future<AiResult> _read(
    http.StreamedResponse response,
    _AnswerReader reader,
    Completer<void> abort,
  ) async {
    final int status = response.statusCode;
    if (status < 200 || status >= 300) {
      abort.complete();
      return AiError(AiFailure(_failureKind(status), statusCode: status));
    }
    reader.start(status);
    try {
      await for (final String line
          in response.stream
              .timeout(config.timeout)
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (!reader.addLine(line)) {
          break;
        }
      }
    } on FormatException {
      // Invalid UTF-8 is not a readable model response.
      if (!abort.isCompleted) {
        abort.complete();
      }
      return AiError(AiFailure(AiFailureKind.malformed, statusCode: status));
    }
    return reader.finish();
  }

  static AiFailureKind _failureKind(int status) =>
      aiFailureKindForStatus(status);

  static String? _blockReason(Object? promptFeedback) {
    if (promptFeedback is! Map<String, Object?>) {
      return null;
    }
    final Object? reason = promptFeedback['blockReason'];
    return reason is String && reason != 'BLOCK_REASON_UNSPECIFIED'
        ? reason
        : null;
  }

  @override
  void close() {
    _closed = true;
    if (_ownsHttpClient) {
      _httpClient?.close();
    }
    _httpClient = null;
  }
}

/// Puts one answer together from the events of a streamed response: the
/// text of each candidate, whether anything was blocked, and any error the
/// service reported part way. A body that is not server-sent events is
/// read as one whole response, or a list of them.
class _AnswerReader {
  _AnswerReader(this._config, this._onPartial);

  final AiNotationConfig _config;
  final AiPartialCallback? _onPartial;

  int _status = 200;

  /// Whether the body is server-sent events; unknown until its first line.
  bool? _events;
  final List<String> _data = <String>[];
  final StringBuffer _whole = StringBuffer();

  /// Each candidate's text so far, by candidate index.
  final SplayTreeMap<int, StringBuffer> _texts =
      SplayTreeMap<int, StringBuffer>();
  bool _blocked = false;
  bool _malformed = false;
  AiFailure? _error;
  String? _shown;
  bool _shownComplete = false;
  int? _inputTokens;
  int? _outputTokens;

  bool get _stopped => _malformed || _error != null;

  /// Whether any answer text has arrived in this attempt.
  bool get hasText => _texts.isNotEmpty;

  /// Starts over for a new attempt answered with [status].
  void start(int status) {
    _status = status;
    _events = null;
    _data.clear();
    _whole.clear();
    _texts.clear();
    _blocked = false;
    _malformed = false;
    _error = null;
    _shown = null;
    _shownComplete = false;
    _inputTokens = null;
    _outputTokens = null;
  }

  /// Takes one line of the body. Returns false once nothing more is
  /// needed.
  bool addLine(String line) {
    if (_events == null) {
      // Blank lines ahead of the first one say nothing yet.
      if (line.trim().isEmpty) {
        return true;
      }
      _events = line.startsWith('data:');
    }
    if (!_events!) {
      _whole.writeln(line);
      return true;
    }
    if (line.isEmpty) {
      _endEvent();
    } else if (line.startsWith('data:')) {
      _data.add(line.substring(line.startsWith('data: ') ? 6 : 5));
    }
    // Other fields, and comments, carry nothing an answer needs.
    return !_stopped;
  }

  /// The answer, once the body has ended.
  AiResult finish() {
    if (_events ?? false) {
      _endEvent();
    } else if (!_stopped) {
      final String whole = _whole.toString();
      if (whole.trim().isEmpty) {
        _malformed = true;
      } else {
        _decode(whole);
      }
    }
    final AiFailure? error = _error;
    if (error != null) {
      return AiError(error);
    }
    if (_malformed) {
      return AiError(AiFailure(AiFailureKind.malformed, statusCode: _status));
    }
    // Only the first candidate with an answer is used.
    for (final StringBuffer text in _texts.values) {
      final String answer = text.toString().trim();
      if (answer.isEmpty) {
        continue;
      }
      final int? input = _inputTokens;
      final int? output = _outputTokens;
      try {
        return AiSuccess.response(
          AiAssistantResponse.parse(answer, config: _config),
          usage: input == null && output == null
              ? null
              : AiTokenUsage(
                  inputTokens: input ?? 0,
                  outputTokens: output ?? 0,
                ),
        );
      } on FormatException {
        return AiError(AiFailure(AiFailureKind.malformed, statusCode: _status));
      }
    }
    return AiError(
      AiFailure(
        _blocked ? AiFailureKind.blocked : AiFailureKind.empty,
        statusCode: _status,
      ),
    );
  }

  void _endEvent() {
    if (_data.isEmpty || _stopped) {
      _data.clear();
      return;
    }
    final String json = _data.join('\n');
    _data.clear();
    _decode(json);
    _report();
  }

  void _decode(String json) {
    final Object? value;
    try {
      value = jsonDecode(json);
    } on FormatException {
      _malformed = true;
      return;
    }
    if (value is List<Object?>) {
      value.forEach(_response);
    } else {
      _response(value);
    }
  }

  /// Adds one `GenerateContentResponse`, or the error that replaced it.
  void _response(Object? value) {
    if (_stopped) {
      return;
    }
    if (value is! Map<String, Object?>) {
      _malformed = true;
      return;
    }
    final Object? error = value['error'];
    if (error is Map<String, Object?>) {
      final Object? code = error['code'];
      final int? status = code is int ? code : null;
      _error = AiFailure(
        status == null
            ? AiFailureKind.server
            : GeminiAiClient._failureKind(status),
        statusCode: status,
      );
      return;
    }
    // Each event repeats the running totals; the last one holds.
    if (value['usageMetadata'] case final Map<String, Object?> usage) {
      if (usage['promptTokenCount'] case final int prompt) {
        _inputTokens = prompt;
      }
      // Thinking is billed as output.
      final Object? candidates = usage['candidatesTokenCount'];
      final Object? thoughts = usage['thoughtsTokenCount'];
      if (candidates is int || thoughts is int) {
        _outputTokens =
            (candidates is int ? candidates : 0) +
            (thoughts is int ? thoughts : 0);
      }
    }
    if (GeminiAiClient._blockReason(value['promptFeedback']) != null) {
      _blocked = true;
    }
    final Object? candidates = value['candidates'];
    if (candidates == null) {
      return;
    }
    if (candidates is! List<Object?>) {
      _malformed = true;
      return;
    }
    for (int position = 0; position < candidates.length; position++) {
      final Object? candidate = candidates[position];
      if (candidate is! Map<String, Object?>) {
        continue;
      }
      if (GeminiAiClient._blockingFinishReasons.contains(
        candidate['finishReason'],
      )) {
        _blocked = true;
      }
      final Object? index = candidate['index'];
      final Object? content = candidate['content'];
      final Object? parts = content is Map<String, Object?>
          ? content['parts']
          : null;
      if (parts is! List<Object?>) {
        continue;
      }
      for (final Object? part in parts) {
        if (part is! Map<String, Object?> || part['thought'] == true) {
          continue;
        }
        final Object? piece = part['text'];
        if (piece is! String || piece.isEmpty) {
          continue;
        }
        _texts
            .putIfAbsent(index is int ? index : position, StringBuffer.new)
            .write(piece);
      }
    }
  }

  /// Tells the listener the message written so far, when it has grown.
  void _report() {
    final AiPartialCallback? onPartial = _onPartial;
    if (onPartial == null || _stopped || _texts.isEmpty) {
      return;
    }
    final (String, bool)? state = AiAssistantResponse.partialMessageState(
      _texts.values.first.toString(),
    );
    if (state == null) {
      return;
    }
    final (String message, bool complete) = state;
    if (message == _shown && complete == _shownComplete) {
      return;
    }
    _shown = message;
    _shownComplete = complete;
    onPartial(message, complete);
  }
}
