import 'dart:async';

/// Elements an unfinished SVG may be cut inside: whatever has been closed
/// within them stands on its own. Inside anything else, such as a `<text>` or
/// `<defs>`, a finished child means nothing until its parent ends.
const Set<String> _containers = <String>{'svg', 'g'};

/// The part of [source], an SVG still being written, that can be drawn: every
/// element finished so far, with those still open closed. Null until an
/// element has finished, or when [source] is not an SVG or is not well formed.
String? completedSvgDocument(String source) {
  final String body = source.replaceFirst('\uFEFF', '');
  final RegExpMatch? head = RegExp(
    r'^\s*(?:```[^\n]*\n\s*)?(?:<\?xml\b[^>]*\?>\s*)?(?=<svg\b)',
    caseSensitive: false,
  ).firstMatch(body);
  if (head == null) return null;
  final List<String> open = <String>[];
  int safeEnd = -1;
  List<String> safeOpen = const <String>[];
  int i = head.end;
  while (true) {
    final int start = body.indexOf('<', i);
    if (start < 0) break;
    String? skipTo;
    if (body.startsWith('<!--', start)) {
      skipTo = '-->';
    } else if (body.startsWith('<![CDATA[', start)) {
      skipTo = ']]>';
    } else if (body.startsWith('<?', start)) {
      skipTo = '?>';
    } else if (body.startsWith('<!', start)) {
      return null;
    }
    if (skipTo != null) {
      final int end = body.indexOf(skipTo, start);
      if (end < 0) break;
      i = end + skipTo.length;
      continue;
    }
    final int end = _tagEnd(body, start);
    if (end < 0) break;
    i = end + 1;
    final bool closing = body.startsWith('</', start);
    final String name = _tagName(body, closing ? start + 2 : start + 1);
    final bool closes;
    if (closing) {
      if (open.isEmpty || open.last != name) return null;
      open.removeLast();
      closes = true;
    } else if (body.codeUnitAt(end - 1) == 0x2F) {
      closes = true;
    } else {
      open.add(name);
      closes = false;
    }
    if (open.isEmpty) {
      return closes ? body.substring(head.end, i) : null;
    }
    if (closes && open.every(_isContainer)) {
      safeEnd = i;
      safeOpen = List<String>.of(open);
    }
  }
  if (safeEnd < 0) return null;
  final StringBuffer document = StringBuffer(body.substring(head.end, safeEnd));
  for (final String name in safeOpen.reversed) {
    document.write('</$name>');
  }
  return document.toString();
}

bool _isContainer(String name) => _containers.contains(name.toLowerCase());

/// Where the tag opening at [start] ends, outside its quoted attributes, or
/// -1 when it has not ended yet.
int _tagEnd(String source, int start) {
  int? quote;
  for (int i = start + 1; i < source.length; i++) {
    final int unit = source.codeUnitAt(i);
    if (quote != null) {
      if (unit == quote) quote = null;
    } else if (unit == 0x22 || unit == 0x27) {
      quote = unit;
    } else if (unit == 0x3E) {
      return i;
    }
  }
  return -1;
}

String _tagName(String source, int start) {
  int end = start;
  while (end < source.length) {
    final int unit = source.codeUnitAt(end);
    if (unit == 0x3E || unit == 0x2F || unit <= 0x20) break;
    end++;
  }
  return source.substring(start, end);
}

/// Draws an SVG as it is written, without falling behind it.
///
/// Laying out handwriting takes real time on the UI thread and grows with the
/// drawing, so each draw waits a few times as long as the last one took: at
/// most a quarter of the time goes to this, on any device.
class LiveNotationPainter {
  LiveNotationPainter(
    this._draw, {
    this.minInterval = const Duration(milliseconds: 120),
    this.busyFactor = 4,
  });

  /// Draws a complete SVG document. Throwing leaves the last drawing shown.
  final void Function(String document) _draw;
  final Duration minInterval;
  final int busyFactor;

  String? _pending;
  String? _drawn;
  Timer? _timer;
  bool _closed = false;

  /// Takes the whole SVG written so far.
  void add(String source) {
    if (_closed) return;
    final String? document = completedSvgDocument(source);
    if (document == null || document == _drawn) return;
    _pending = document;
    if (_timer == null) _flush();
  }

  void _flush() {
    _timer = null;
    final String? document = _pending;
    if (_closed || document == null) return;
    _pending = null;
    _drawn = document;
    final Stopwatch took = Stopwatch()..start();
    try {
      _draw(document);
    } on Object {
      // Only a preview: nothing here may cost the answer. The next element
      // may draw, and the answer is checked again whole when it arrives.
    }
    final Duration wait = took.elapsed * busyFactor;
    _timer = Timer(wait > minInterval ? wait : minInterval, _flush);
  }

  /// Draws nothing more.
  void close() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }
}
