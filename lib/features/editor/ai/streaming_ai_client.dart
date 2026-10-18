import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;

import '../ink/ink_sample.dart';
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

/// Tells the model, in words and coordinates instead of a picture, what
/// the note's paper is, where the selected-ink image sits on it, what is
/// near it, and where it may draw. Coordinates are rounded to 4 places,
/// finer than a logical pixel on any page the editor shows. Every provider
/// is sent the same words.
String aiNoteMetadata(NoteImage note) {
  String n(double value) => double.parse(value.toStringAsFixed(4)).toString();
  final double width = note.logicalSize.width;
  final double height = note.logicalSize.height;
  final StringBuffer text = StringBuffer(
    'The note is a sheet of paper ${n(width)} x ${n(height)} logical '
    'units. You are not shown the whole sheet: only the selected-ink '
    'image, and the coordinates below. Note coordinates are '
    'note_normalized: x = 0 is the left edge of the paper and x = 1 the '
    'right edge; y = 0 is the top edge and y = 1 the bottom edge. One '
    'logical unit is 1/${n(width)} of x and 1/${n(height)} of y.',
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
    text.write(
      ' The selected-ink image is a crop of this note covering '
      'x ${n(bounds.left)} to ${n(bounds.right)} and '
      'y ${n(bounds.top)} to ${n(bounds.bottom)}. A point u of the way '
      'across and v of the way down the selected-ink image is at note '
      'x = ${n(bounds.left)} + u * ${n(bounds.width)}, '
      'y = ${n(bounds.top)} + v * ${n(bounds.height)}.',
    );
  }
  List<Object?>? ink;
  if (note.focusInk.isNotEmpty) {
    double r(double value) => double.parse(value.toStringAsFixed(3));
    ink = <Object?>[
      for (final List<InkVector> outline in note.focusInk)
        <Object?>[
          for (final InkVector point in outline)
            <double>[r(point.x), r(point.y)],
        ],
    ];
    text.write(
      ' selected_ink in the metadata is the user\'s ink in and around the '
      'selected region, measured exactly: one polyline per pen stroke, as '
      '[x, y] note coordinates, reduced to its ends and corners, so each '
      'straight side of a shape is the segment between two consecutive '
      'points. A triangle drawn in one stroke, for example, is its three '
      'corners with the first repeated at the end. Whenever your drawing '
      'connects to this ink, such as a lead or wire to a component, a '
      'pin, a line completing a shape, or an arrow or leader line to a '
      'part, take the touching point from selected_ink, not from the '
      'image: use a listed point for a corner or an end, or interpolate '
      'between two consecutive points for a place along a side (a third '
      'of the way down a side from (x1, y1) to (x2, y2) is '
      'x1 + (x2 - x1) / 3, y1 + (y2 - y1) / 3). Start or end your line '
      'exactly there, so it touches the ink without a gap or overlap, '
      'and run it away from the shape, outward.',
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
      ' nearby_content in the metadata is what else is on the paper near '
      'the selected region, nearest first: one [left, top, right, bottom] '
      'box in note coordinates round each group of writing, drawing, '
      'picture, sticky note, or print. You cannot see what they hold. '
      'Never draw over them, and point to one only when the user asks '
      'about it.',
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
      ' your_notes in the metadata is what you, the assistant, have already '
      'written and drawn on this note: one [left, top, right, bottom] box in '
      'note coordinates round each group of it. Never write or draw over '
      'them, and never write a label or answer again where one of yours '
      'already says it: add only what is new, in blank space. The app moves '
      'any text of yours that would land on them.',
    );
  }
  List<Object?>? freeAreas;
  if (space == null) {
    text.write(
      ' You may draw anywhere on the paper, inside or outside the selected '
      'region: every point must keep 0 < x < 1 and 0 < y < 1, with a margin '
      'of at least the stroke width from each edge.',
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
      ' The app has measured where the paper is blank, keeping clear of '
      'all ink, pictures, sticky notes, and print. free_areas in the '
      'metadata lists those blank areas, best first: nearest the selected '
      'region and biggest. Each is a box, or an L made of two boxes that '
      'meet at a corner. Every box gives its note coordinates and its size '
      'in logical units, width_units by height_units. ${_describeAreas(space, note, n)} '
      'Put every new drawing and every piece of writing inside one of '
      'these areas, sized to fit the box it goes in: work out each text\'s '
      'width and height from its size, and each plot\'s or shape\'s box, in '
      'logical units, and check they fit. In an L, you can put a drawing in '
      'one box and its words in the other. Only marks on the user\'s own '
      'ink go outside them: a circle, underline, check, or cross on it, and '
      'the far end of a leader line or arrow to it. If what you need to '
      'draw does not fit in any area, even made smaller, draw it on a '
      'sticky note instead. $_stickyHowTo',
    );
  } else {
    text.write(
      ' The app has measured the paper, and no blank area on it is big '
      'enough to draw or write in: do not draw on the paper. When a drawing '
      'or a handwritten answer would help, draw it on a sticky note '
      'instead. $_stickyHowTo',
    );
  }
  text.write(
    ' Metadata: '
    '${jsonEncode(<String, Object?>{'logical_aspect_ratio': double.parse(n(width / height)), 'focus_bounds': focus, 'note_logical_width': double.parse(n(width)), 'note_logical_height': double.parse(n(height)), 'selected_ink': ?ink, 'nearby_content': ?nearby, 'your_notes': ?yourNotes, 'free_areas': ?freeAreas})}',
  );
  return text.toString();
}

/// How the model asks for a sticky note.
const String _stickyHowTo =
    'To draw on a sticky note, give notation a sticky object with its '
    'width and height in logical units (width 120 to 640, height 90 to '
    '480), just big enough for what you draw with a little margin, and set '
    'coordinate_space to "sticky_normalized". Every coordinate in that '
    'notation is then measured over the sticky note, not the paper: x = 0 '
    'is its left edge and x = 1 its right, y = 0 its top and y = 1 its '
    'bottom, so one logical unit is 1/width of x and 1/height of y. Keep '
    'every mark a little inside 0 and 1. The app sticks the note on the '
    'page beside the selected region. Everything in that notation goes on '
    'the sticky note: it cannot also mark the paper. A notation without '
    'sticky is drawn on the paper, with coordinate_space "note_normalized".';

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
  int _textBytes = 0;
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
    _textBytes = 0;
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
    _textBytes += utf8.encode(piece).length;
    if (_textBytes > config.maxResponseBytes) {
      malformed = true;
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
    final int maxBytes = notationConfig.maxResponseBytes * 2;
    int bytes = 0;
    try {
      await for (final String line
          in response.stream
              .timeout(timing.timeout)
              .map((List<int> chunk) {
                bytes += chunk.length;
                if (bytes > maxBytes) {
                  throw const FormatException('Too large');
                }
                return chunk;
              })
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (!reader.addLine(line)) {
          break;
        }
      }
    } on FormatException {
      if (!abort.isCompleted) {
        abort.complete();
      }
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
