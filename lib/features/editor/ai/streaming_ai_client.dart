import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;

import 'ai_client.dart';
import 'ai_config.dart';
import 'ai_notation.dart';
import 'notation_space.dart';
import 'note_image_renderer.dart';

/// What an HTTP [status] that is not a success means.
AiFailureKind aiFailureKindForStatus(int status) {
  return switch (status) {
    401 || 403 => AiFailureKind.unauthorized,
    429 => AiFailureKind.rateLimited,
    >= 500 => AiFailureKind.server,
    _ => AiFailureKind.rejected,
  };
}

/// [text] without a Markdown code fence around it, which models without a
/// JSON mode sometimes add.
String stripJsonFence(String text) {
  String body = text.trim();
  if (!body.startsWith('```')) {
    return body;
  }
  final int lineEnd = body.indexOf('\n');
  body = lineEnd < 0 ? '' : body.substring(lineEnd + 1);
  body = body.trimRight();
  if (body.endsWith('```')) {
    body = body.substring(0, body.length - 3);
  }
  return body.trim();
}

/// Tells the model what surrounds the selected-ink image and its
/// page-coordinate SVG, and where it may add ink. Coordinates are rounded to 4 places, finer than a logical
/// pixel on any page the editor shows. Every provider is sent the same words.
String aiNoteMetadata(NoteImage note) {
  String n(double value) => double.parse(value.toStringAsFixed(4)).toString();
  final double width = note.logicalSize.width;
  final double height = note.logicalSize.height;
  // Asked with nothing selected, the picture is blank paper and the focus
  // is where the notes go.
  final bool blank = note.focusIsFreeSpace;
  final StringBuffer text = StringBuffer(
    'The paper is ${n(width)} x ${n(height)} logical units. ',
  );
  text.write(
    blank
        ? 'Nothing on it was selected: the attached image is blank paper, '
              'not the user\'s work, and you are not shown the sheet.'
        : 'The selected part is supplied as an image and as SVG in these '
              'same page logical coordinates; you are not shown the whole '
              'sheet.',
  );
  final bounds = note.normalizedFocusBounds;
  Object? focus;
  if (bounds != null) {
    focus = <String, Object?>{
      'left': double.parse(n(bounds.left)),
      'top': double.parse(n(bounds.top)),
      'right': double.parse(n(bounds.right)),
      'bottom': double.parse(n(bounds.bottom)),
    };
    final String range =
        'x ${n(bounds.left)} to ${n(bounds.right)}, '
        'y ${n(bounds.top)} to ${n(bounds.bottom)}';
    text.write(
      blank
          ? ' focus_bounds, $range, is the biggest blank area of the page '
                'the user is on: put what you write and draw there, or in '
                'another free area.'
          : ' The selected SVG covers $range.',
    );
  }
  final NoteFreeSpace? space = note.space;
  List<Object?>? nearby;
  if (space != null && space.nearby.isNotEmpty) {
    double r(double value) => double.parse(value.toStringAsFixed(3));
    nearby = <Object?>[
      for (final ui.Rect box in space.nearby)
        <double>[
          r(box.left / width),
          r(box.top / height),
          r(box.right / width),
          r(box.bottom / height),
        ],
    ];
    text.write(
      ' nearby_content: [left, top, right, bottom] boxes round other '
      'content near the selection, nearest first. You cannot see them.',
    );
  }
  List<Object?>? yourNotes;
  if (space != null && space.yourNotes.isNotEmpty) {
    double r(double value) => double.parse(value.toStringAsFixed(3));
    yourNotes = <Object?>[
      for (final ui.Rect box in space.yourNotes)
        <double>[
          r(box.left / width),
          r(box.top / height),
          r(box.right / width),
          r(box.bottom / height),
        ],
    ];
    text.write(
      ' your_notes: boxes round what you already drew here. Never write or '
      'draw over them or repeat what they say; add only what is new.',
    );
  }
  List<Object?>? freeAreas;
  if (space == null) {
    text.write(
      ' You may draw anywhere on the paper, inside or outside the selected '
      'region: every point must keep 0 < x < 1 and 0 < y < 1, a stroke '
      'width from each edge.',
    );
  } else if (space.hasRoom) {
    freeAreas = <Object?>[
      for (final FreeArea area in space.areas)
        <String, Object?>{
          'shape': area.isL ? 'L' : 'box',
          'parts': <Object?>[
            for (final ui.Rect part in area.parts) _box(part, note, n),
          ],
        },
    ];
    text.write(
      ' free_areas: blank space is provided, best first, each a box or an '
      'L of two boxes, with note coordinates and size in logical units '
      '(width_units x height_units). ${_describeAreas(space, note, n)} ',
    );
    text.write(
      blank
          ? 'Write and draw only inside these free areas, never on or '
                'pointing at the user\'s content. $_stickyHowTo'
          : 'Decide if the annotation needs a separate blank space, or you '
                'can annotate on the user\'s content. The coordinates match '
                'the selected SVG. $_stickyHowTo',
    );
  } else {
    text.write(
      ' No blank space is provided: annotate on the user\'s content, or use '
      'a sticky note. The coordinates match the selected SVG. $_stickyHowTo',
    );
  }
  text.write(
    ' Metadata: '
    '${jsonEncode(<String, Object?>{'logical_aspect_ratio': double.parse(n(width / height)), 'focus_bounds': focus, 'note_logical_width': double.parse(n(width)), 'note_logical_height': double.parse(n(height)), 'nearby_content': ?nearby, 'your_notes': ?yourNotes, 'free_areas': ?freeAreas})}',
  );
  return text.toString();
}

/// How the model asks for a sticky note.
const String _stickyHowTo =
    'For a sticky note, give notation a sticky object {width, height} in '
    'logical units (width 120 to 640, height 90 to 480), just big enough, '
    'and coordinate_space "sticky_normalized": every coordinate is then 0 '
    'to 1 over the note, kept a little inside. The app places it beside '
    'the selection; that notation cannot also mark the paper.';

/// [box] as the model is told it: note coordinates and logical size.
Map<String, Object?> _box(
  ui.Rect box,
  NoteImage note,
  String Function(double) n,
) {
  final double width = note.logicalSize.width;
  final double height = note.logicalSize.height;
  return <String, Object?>{
    'left': double.parse(n(box.left / width)),
    'top': double.parse(n(box.top / height)),
    'right': double.parse(n(box.right / width)),
    'bottom': double.parse(n(box.bottom / height)),
    'width_units': box.width.round(),
    'height_units': box.height.round(),
  };
}

/// The free areas in words, so the sizes are hard to miss.
String _describeAreas(
  NoteFreeSpace space,
  NoteImage note,
  String Function(double) n,
) {
  final double width = note.logicalSize.width;
  final double height = note.logicalSize.height;
  String part(ui.Rect box) =>
      'x ${n(box.left / width)} to ${n(box.right / width)}, '
      'y ${n(box.top / height)} to ${n(box.bottom / height)} '
      '(${box.width.round()} x ${box.height.round()} units)';
  final StringBuffer text = StringBuffer();
  for (int i = 0; i < space.areas.length; i++) {
    final FreeArea area = space.areas[i];
    text.write(
      area.isL
          ? 'Area ${i + 1} is an L: ${part(area.parts[0])}, joined by '
                '${part(area.parts[1])}. '
          : 'Area ${i + 1} is a box: ${part(area.parts[0])}. ',
    );
  }
  return text.toString().trimRight();
}

/// Index of the last user message in [request], where the note metadata
/// goes.
int aiLastUserIndex(AiRequest request) {
  for (int i = request.messages.length - 1; i >= 0; i--) {
    if (request.messages[i].role == AiRole.user) {
      return i;
    }
  }
  return -1;
}

/// Puts one answer together from a provider's server-sent events. A
/// subclass reads each event's JSON; this keeps the text, the usage, and
/// what went wrong, and tells the listener the message as it grows.
abstract class SseAnswerReader {
  SseAnswerReader(this.config, this._onPartial);

  final AiNotationConfig config;
  final AiPartialCallback? _onPartial;

  int _status = 200;
  final StringBuffer _text = StringBuffer();
  final List<String> _data = <String>[];
  String? _event;
  bool _done = false;
  bool blocked = false;
  bool malformed = false;
  AiFailure? error;
  int? inputTokens;
  int? outputTokens;
  String? _shown;
  bool _shownComplete = false;

  bool get _stopped => malformed || error != null || _done;

  /// Whether any answer text has arrived in this attempt.
  bool get hasText => _text.isNotEmpty;

  int get status => _status;

  /// Starts over for a new attempt answered with [status].
  void start(int status) {
    _status = status;
    _text.clear();
    _data.clear();
    _event = null;
    _done = false;
    blocked = false;
    malformed = false;
    error = null;
    inputTokens = null;
    outputTokens = null;
    _shown = null;
    _shownComplete = false;
  }

  /// Takes one line of the body. Returns false once nothing more is
  /// needed.
  bool addLine(String line) {
    if (line.isEmpty) {
      _endEvent();
    } else if (line.startsWith('data:')) {
      _data.add(line.substring(line.startsWith('data: ') ? 6 : 5));
    } else if (line.startsWith('event:')) {
      _event = line.substring(6).trim();
    }
    // Other fields, and comments, carry nothing an answer needs.
    return !_stopped;
  }

  /// Reads one event: its [type], when the stream names one, and its JSON.
  void onEvent(String? type, Object? json);

  /// Ends the stream early, for a provider's end-of-stream sentinel.
  void markDone() => _done = true;

  /// Adds a piece of the answer.
  void addText(String piece) {
    if (piece.isEmpty) {
      return;
    }
    _text.write(piece);
  }

  void _endEvent() {
    final String? type = _event;
    _event = null;
    if (_data.isEmpty || _stopped) {
      _data.clear();
      return;
    }
    final String payload = _data.join('\n');
    _data.clear();
    if (payload.trim() == '[DONE]') {
      markDone();
      return;
    }
    final Object? json;
    try {
      json = jsonDecode(payload);
    } on FormatException {
      malformed = true;
      return;
    }
    onEvent(type, json);
    _report();
  }

  /// The answer, once the body has ended.
  AiResult finish() {
    _done = false;
    _endEvent();
    final AiFailure? error = this.error;
    if (error != null) {
      return AiError(error);
    }
    if (malformed) {
      return AiError(AiFailure(AiFailureKind.malformed, statusCode: _status));
    }
    final String answer = stripJsonFence(_text.toString());
    if (answer.isEmpty) {
      return AiError(
        AiFailure(
          blocked ? AiFailureKind.blocked : AiFailureKind.empty,
          statusCode: _status,
        ),
      );
    }
    if (blocked) {
      return AiError(AiFailure(AiFailureKind.blocked, statusCode: _status));
    }
    final int? input = inputTokens;
    final int? output = outputTokens;
    try {
      return AiSuccess.response(
        AiAssistantResponse.parse(answer, config: config),
        usage: input == null && output == null
            ? null
            : AiTokenUsage(inputTokens: input ?? 0, outputTokens: output ?? 0),
      );
    } on FormatException {
      return AiError(AiFailure(AiFailureKind.malformed, statusCode: _status));
    }
  }

  /// Tells the listener the message written so far, when it has grown.
  void _report() {
    final AiPartialCallback? onPartial = _onPartial;
    if (onPartial == null || _stopped || _text.isEmpty) {
      return;
    }
    final (String, bool)? state = AiAssistantResponse.partialMessageState(
      _text.toString(),
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

/// Sends one JSON request that answers in server-sent events, and reads it
/// with an [SseAnswerReader]. The key travels only in [headers]; nothing
/// sent or received is logged, and no failure carries any of it.
abstract class SseAiClient implements AiClient {
  /// With no [httpClient], one is created on first use and closed by
  /// [close]. A client passed in stays the caller's to close.
  SseAiClient({
    required this.timing,
    http.Client? httpClient,
    this.notationConfig = const AiNotationConfig(),
  }) : _httpClient = httpClient,
       _ownsHttpClient = httpClient == null;

  /// Timeouts and retries, shared with the Gemini client.
  final AiApiConfig timing;
  final AiNotationConfig notationConfig;
  final bool _ownsHttpClient;
  http.Client? _httpClient;
  bool _closed = false;

  Uri get endpoint;

  /// Every header but the content type, the key among them.
  Map<String, String> get headers;

  Map<String, Object?> body(AiRequest request);

  SseAnswerReader newReader(AiPartialCallback? onPartial);

  /// Statuses a provider answers at once without generating, which are
  /// sent again.
  Set<int> get retriedStatuses => const <int>{500, 503};

  @override
  Future<AiResult> send(
    AiRequest request, {
    AiPartialCallback? onPartial,
  }) async {
    if (!isConfigured) {
      return const AiError(AiFailure(AiFailureKind.notConfigured));
    }
    final String encoded = jsonEncode(body(request));
    final SseAnswerReader reader = newReader(onPartial);
    AiResult result = await _attempt(encoded, reader);
    for (
      int retry = 0;
      retry < timing.serverErrorRetries &&
          !reader.hasText &&
          result is AiError &&
          retriedStatuses.contains(result.failure.statusCode);
      retry++
    ) {
      await Future<void>.delayed(timing.retryDelay);
      result = await _attempt(encoded, reader);
    }
    return result;
  }

  Future<AiResult> _attempt(String body, SseAnswerReader reader) async {
    if (_closed) {
      return const AiError(AiFailure(AiFailureKind.network));
    }
    final Completer<void> abort = Completer<void>();
    try {
      final http.AbortableRequest post =
          http.AbortableRequest('POST', endpoint, abortTrigger: abort.future)
            ..headers['Content-Type'] = 'application/json'
            ..headers.addAll(headers)
            ..body = body;
      final http.Client client = _httpClient ??= http.Client();
      return await client
          .send(post)
          .timeout(timing.timeout)
          .then(
            (http.StreamedResponse response) => _read(response, reader, abort),
          )
          .timeout(timing.maxDuration);
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

  Future<AiResult> _read(
    http.StreamedResponse response,
    SseAnswerReader reader,
    Completer<void> abort,
  ) async {
    final int status = response.statusCode;
    if (status < 200 || status >= 300) {
      abort.complete();
      return AiError(
        AiFailure(aiFailureKindForStatus(status), statusCode: status),
      );
    }
    reader.start(status);
    try {
      await for (final String line
          in response.stream
              .timeout(timing.timeout)
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (!reader.addLine(line)) {
          break;
        }
      }
    } on FormatException {
      if (!abort.isCompleted) abort.complete();
      return AiError(AiFailure(AiFailureKind.malformed, statusCode: status));
    }
    return reader.finish();
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
