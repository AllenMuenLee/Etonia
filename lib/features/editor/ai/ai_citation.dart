import 'dart:math' as math;
import 'dart:ui' show Rect;

import '../ink/ink_sample.dart';
import '../ink/stroke.dart';
import 'selection_svg_renderer.dart';

/// Cites the selection SVG's lines: `[[L12-L30]]`, or several ranges as
/// `[[L12-L30,L44]]`. Only the notation model cites, in its SVG's citation
/// descriptions; an answer saved by an earlier version holds these in its words.
const String _linesPattern =
    r'\[\[\s*L\d+(?:\s*[-–]\s*L?\d+)?'
    r'(?:\s*,\s*L\d+(?:\s*[-–]\s*L?\d+)?)*\s*\]\]';

/// Asks for a detail of the picture to be circled, the box around it given as
/// top, left, bottom, right: `[[C 120 340 180 520]]`.
const String _circlePattern =
    r'\[\[\s*C\s*(\d+(?:\.\d+)?)[\s,]+(\d+(?:\.\d+)?)[\s,]+'
    r'(\d+(?:\.\d+)?)[\s,]+(\d+(?:\.\d+)?)\s*\]\]';

/// Cites a page of one of several notes, numbered per request: its lines
/// `[[N1:P2:L4-L7]]`, typed or printed lines of one chunk `[[N1:P2:C3:T2-T4]]`,
/// a chunk `[[N1:P2:C3]]`, a detail of what was shown
/// `[[N1:P2:C 100 200 300 400]]` or `[[N1:P2:C3 100 200 300 400]]`, or the page
/// itself `[[N1:P2]]`.
const String _notePattern =
    r'\[\[\s*N\s*\d+\s*:\s*P\s*\d+(?:\s*:[^\[\]]*)?\]\]';

final RegExp _linesCitation = RegExp(_linesPattern, caseSensitive: false);
final RegExp _circleCitation = RegExp(_circlePattern, caseSensitive: false);
final RegExp _noteCitation = RegExp(
  r'\[\[\s*N\s*(\d+)\s*:\s*P\s*(\d+)(?:\s*:([^\[\]]*))?\]\]',
  caseSensitive: false,
);

final RegExp _citation = RegExp(
  '[ \\t]*(?:$_linesPattern|$_circlePattern|$_notePattern)',
  caseSensitive: false,
);

/// A citation still being written, at the end of a streaming answer.
final RegExp _openCitation = RegExp(r'[ \t]*(?:\[\[[^\[\]]*\]?|\[)$');

/// Lines [first] through [last] of the selection SVG, one-based.
class AiLineRange {
  const AiLineRange(this.first, this.last);

  final int first;
  final int last;

  String get label => first == last ? 'L$first' : 'L$first–L$last';

  @override
  bool operator ==(Object other) =>
      other is AiLineRange && other.first == first && other.last == last;

  @override
  int get hashCode => Object.hash(first, last);

  @override
  String toString() => label;
}

/// A box around one detail of the picture sent to the model, as the model
/// wrote it: each side a share of the picture's height or width, from 0 to
/// [scale], measured from its top left corner.
///
/// The model finds this by looking at the pixels. The selection SVG cannot
/// help, since it holds the picture as one opaque crop.
class AiPictureBox {
  const AiPictureBox(this.top, this.left, this.bottom, this.right);

  final double top;
  final double left;
  final double bottom;
  final double right;

  static const double scale = 1000;

  /// How much of the picture a box may cover and still be a detail of it. A
  /// ring around most of what the user chose says nothing.
  static const double maxShare = 0.5;

  /// Where this lies on a picture at [picture], or null when it is no detail
  /// of it: empty, or most of the picture.
  Rect? within(Rect picture) {
    double share(double value) => value.clamp(0, scale) / scale;
    final double x0 = share(math.min(left, right));
    final double x1 = share(math.max(left, right));
    final double y0 = share(math.min(top, bottom));
    final double y1 = share(math.max(top, bottom));
    if (x1 <= x0 || y1 <= y0 || (x1 - x0) * (y1 - y0) > maxShare) return null;
    return Rect.fromLTRB(
      picture.left + x0 * picture.width,
      picture.top + y0 * picture.height,
      picture.left + x1 * picture.width,
      picture.top + y1 * picture.height,
    );
  }
}

/// [text] with every citation taken out: what a reader, or a later turn, gets.
String stripAiCitations(String text) => text.replaceAll(_citation, '');

/// [text] as far as a stream has written it, with no citation showing, not even
/// one that has only begun.
String stripPartialAiCitations(String text) =>
    stripAiCitations(text).replaceFirst(_openCitation, '');

/// What one `[[N..:P..]]` citation names, as the model wrote it: [note] and
/// [page] are from one, and [note] means something only to its own request.
class AiNoteCitation {
  const AiNoteCitation({
    required this.note,
    required this.page,
    this.ranges = const <AiLineRange>[],
    this.typedRanges = const <AiLineRange>[],
    this.chunk,
    this.box,
  });

  final int note;
  final int page;

  /// The lines cited. A line is a stroke, counted from one down the page.
  final List<AiLineRange> ranges;

  /// The typed or printed lines cited, `T2-T4`, counted from one within
  /// [chunk]: they have no strokes to number.
  final List<AiLineRange> typedRanges;

  /// The chunk cited, or the one [box] is measured on.
  final int? chunk;

  /// A detail to ring: on [chunk]'s picture, or else on what was shown of the
  /// page.
  final AiPictureBox? box;
}

final RegExp _chunkBody = RegExp(
  r'^C\s*(?:(\d+)\s+)?(\d+(?:\.\d+)?)[\s,]+(\d+(?:\.\d+)?)[\s,]+'
  r'(\d+(?:\.\d+)?)[\s,]+(\d+(?:\.\d+)?)$',
  caseSensitive: false,
);
final RegExp _chunkOnlyBody = RegExp(r'^C\s*(\d+)$', caseSensitive: false);

/// `C3:T2-T4`, `C3 T2`, `C3:T2-T4,T7`: typed lines of a chunk.
final RegExp _chunkTypedBody = RegExp(
  r'^C\s*(\d+)\s*[:,\s]\s*(T\s*\d+(?:\s*[-–]\s*T?\s*\d+)?'
  r'(?:\s*,\s*T?\s*\d+(?:\s*[-–]\s*T?\s*\d+)?)*)$',
  caseSensitive: false,
);

List<AiLineRange> _typedIn(String list) {
  final List<AiLineRange> cited = <AiLineRange>[];
  final RegExp number = RegExp(r'\d+');
  for (final String part in list.split(',')) {
    final List<int> ends = <int>[
      for (final Match end in number.allMatches(part)) int.parse(end[0]!),
    ];
    if (ends.isEmpty) continue;
    final int first = ends.first;
    final int last = ends.last;
    cited.add(
      first <= last ? AiLineRange(first, last) : AiLineRange(last, first),
    );
  }
  return cited;
}

/// Every `[[N..:P..]]` citation in [text], in order. What follows the page, if
/// it cannot be read, leaves a citation of the page: the model meant at least
/// that.
List<AiNoteCitation> parseAiNoteCitations(String text) {
  return <AiNoteCitation>[
    for (final Match match in _noteCitation.allMatches(text))
      _noteCitationOf(
        int.parse(match[1]!),
        int.parse(match[2]!),
        (match[3] ?? '').trim(),
      ),
  ];
}

AiNoteCitation _noteCitationOf(int note, int page, String body) {
  final Match? box = _chunkBody.firstMatch(body);
  if (box != null) {
    return AiNoteCitation(
      note: note,
      page: page,
      chunk: box[1] == null ? null : int.parse(box[1]!),
      box: AiPictureBox(
        double.parse(box[2]!),
        double.parse(box[3]!),
        double.parse(box[4]!),
        double.parse(box[5]!),
      ),
    );
  }
  final Match? typed = _chunkTypedBody.firstMatch(body);
  if (typed != null) {
    return AiNoteCitation(
      note: note,
      page: page,
      chunk: int.parse(typed[1]!),
      typedRanges: _typedIn(typed[2]!),
    );
  }
  final Match? chunk = _chunkOnlyBody.firstMatch(body);
  if (chunk != null) {
    return AiNoteCitation(note: note, page: page, chunk: int.parse(chunk[1]!));
  }
  return AiNoteCitation(note: note, page: page, ranges: _citedIn('[[$body]]'));
}

/// One paragraph of an answer: what to show, and the words as written, with
/// the citations any block of nothing but citations after it added.
class AiAnswerBlock {
  const AiAnswerBlock(this.text, this.source);

  final String text;
  final String source;
}

/// The same paragraphs as [parseAiAnswer], each with its citations.
List<AiAnswerBlock> parseAiAnswerBlocks(String markdown) {
  final List<AiAnswerBlock> blocks = <AiAnswerBlock>[];
  String pending = '';
  for (final String block in _blocks(markdown)) {
    final String text = stripAiCitations(block).trim();
    if (text.isNotEmpty) {
      blocks.add(AiAnswerBlock(text, '$pending$block'));
      pending = '';
    } else if (blocks.isEmpty) {
      pending += block;
    } else {
      final AiAnswerBlock last = blocks.removeLast();
      blocks.add(AiAnswerBlock(last.text, '${last.source}$block'));
    }
  }
  return blocks;
}

final Expando<String> _strokeKeys = Expando<String>('aiStrokeKey');

/// Names [stroke] by where it runs, the same on every load and every run, as
/// most strokes are saved with no id of their own. A stroke left alone keeps its
/// key through any edit of the page; one moved or redrawn is another stroke. Two
/// strokes drawn exactly alike share one, which marks both.
String aiStrokeKey(Stroke stroke) => _strokeKeys[stroke] ??= () {
  // FNV-1a, as it is kept in files: the platform's hashes change between runs.
  int hash = 0x811C9DC5;
  void add(int value) {
    hash = ((hash ^ (value & 0xFFFFFFFF)) * 0x01000193) & 0xFFFFFFFF;
  }

  for (final InkVector point in stroke.points) {
    // A tenth of a point: what saving leaves of a coordinate stays the same.
    add((point.x * 10).round());
    add((point.y * 10).round());
  }
  add((stroke.style.width * 10).round());
  return '${stroke.points.length}-${hash.toRadixString(36)}';
}();

/// What to mark on a page of a note opened from outside its own chat, by
/// [aiStrokeKey], as the strokes in the editor are not the ones cited.
class AiNoteMarks {
  const AiNoteMarks({
    required this.noteId,
    required this.pageIndex,
    this.strokeKeys = const <String>{},
    this.strokeIndices = const <int>[],
    this.rings = const <Rect>[],
    this.highlights = const <Rect>[],
  });

  final String noteId;

  /// From zero.
  final int pageIndex;
  final Set<String> strokeKeys;

  /// Typed or printed lines to highlight, in page coordinates: text has no
  /// strokes to mark, and a ring round a line says less than a highlighter.
  final List<Rect> highlights;

  /// By place on the page, for when no key is found: given only while the note
  /// has not changed since it was cited.
  final List<int> strokeIndices;

  /// Details to ring, in page coordinates.
  final List<Rect> rings;

  /// Which of [strokes], a page's in order, these are.
  List<Stroke> strokesIn(List<Stroke> strokes) {
    final List<Stroke> found = <Stroke>[
      for (final Stroke stroke in strokes)
        if (strokeKeys.contains(aiStrokeKey(stroke))) stroke,
    ];
    if (found.isNotEmpty) return found;
    return <Stroke>[
      for (final int index in strokeIndices)
        if (index >= 0 && index < strokes.length) strokes[index],
    ];
  }
}

/// The paragraphs of [markdown] as Markdown to show, numbered from one by their
/// place in the list. They are the blocks between blank lines, a fenced code
/// block or `$$` formula staying whole; a block of nothing but citations is no
/// paragraph.
///
/// `answerParagraphs` in `supabase/functions/_shared/ai_policy.ts` numbers
/// them the same way for the drawing model, so a paragraph number it writes
/// finds the same paragraph here. Change both together.
List<String> parseAiAnswer(String markdown) {
  return <String>[
    for (final String block in _blocks(markdown))
      if (stripAiCitations(block).trim() case final String text
          when text.isNotEmpty)
        text,
  ];
}

List<String> _blocks(String markdown) {
  final List<String> blocks = <String>[];
  final StringBuffer block = StringBuffer();
  bool inFence = false;
  bool inFormula = false;
  bool inSvg = false;
  void flush() {
    if (block.isNotEmpty) blocks.add(block.toString());
    block.clear();
  }

  for (final String line in markdown.split('\n')) {
    final String trimmed = line.trim();
    if (!inFence &&
        !inFormula &&
        RegExp(r'<svg\b', caseSensitive: false).hasMatch(line)) {
      inSvg = true;
    }
    if (!inFormula && trimmed.startsWith('```')) {
      inFence = !inFence;
    } else if (!inFence && '\$\$'.allMatches(trimmed).length.isOdd) {
      inFormula = !inFormula;
    }
    if (trimmed.isEmpty && !inFence && !inFormula && !inSvg) {
      flush();
    } else {
      block.writeln(line);
    }
    if (!inFence && RegExp(r'</svg\s*>', caseSensitive: false).hasMatch(line)) {
      inSvg = false;
    }
  }
  flush();
  return blocks;
}

List<AiLineRange> _citedIn(String block) {
  final List<AiLineRange> cited = <AiLineRange>[];
  final RegExp number = RegExp(r'\d+');
  for (final Match token in _linesCitation.allMatches(block)) {
    for (final String part in token[0]!.split(',')) {
      final List<int> ends = <int>[
        for (final Match end in number.allMatches(part)) int.parse(end[0]!),
      ];
      if (ends.isEmpty) continue;
      final int first = ends.first;
      final int last = ends.last;
      cited.add(
        first <= last ? AiLineRange(first, last) : AiLineRange(last, first),
      );
    }
  }
  return cited;
}

List<AiPictureBox> _circledIn(String block) {
  return <AiPictureBox>[
    for (final Match token in _circleCitation.allMatches(block))
      AiPictureBox(
        double.parse(token[1]!),
        double.parse(token[2]!),
        double.parse(token[3]!),
        double.parse(token[4]!),
      ),
  ];
}

/// What a paragraph of an answer is tied to on the note.
class AiParagraphLinks {
  AiParagraphLinks({
    this.ranges = const <AiLineRange>[],
    this.circles = const <Rect>[],
    Iterable<Stroke> cited = const <Stroke>[],
    Iterable<Stroke> drawn = const <Stroke>[],
  }) {
    this.cited.addAll(cited);
    this.drawn.addAll(drawn);
  }

  /// The citations that named something in the selection.
  final List<AiLineRange> ranges;

  /// Details of a picture or printed page to ring, in page coordinates.
  final List<Rect> circles;

  /// The ink it cites: the user's, or the assistant's earlier notation.
  final Set<Stroke> cited = Set<Stroke>.identity();

  /// The strokes the notation model drew for it.
  final Set<Stroke> drawn = Set<Stroke>.identity();

  bool get isEmpty => cited.isEmpty && drawn.isEmpty && circles.isEmpty;

  /// Shown after the paragraph.
  String get label {
    final List<String> parts = <String>[
      for (final AiLineRange range in ranges) range.label,
      if (circles.isNotEmpty) 'Picture',
    ];
    return parts.isEmpty ? 'Notation' : parts.join(', ');
  }
}

/// One answer's links, by paragraph number, from one.
class AiAnswerLinks {
  final Map<int, AiParagraphLinks> paragraphs = <int, AiParagraphLinks>{};

  bool get isEmpty =>
      paragraphs.values.every((AiParagraphLinks links) => links.isEmpty);

  /// [paragraph]'s links, made when it has none yet.
  AiParagraphLinks of(int paragraph) =>
      paragraphs.putIfAbsent(paragraph, AiParagraphLinks.new);

  /// Follows strokes the editor replaced. The old ones are kept, as the
  /// conversation keeps its own, for an undo to bring back.
  bool follow(Map<Stroke, Stroke> replaced) {
    bool changed = false;
    for (final AiParagraphLinks links in paragraphs.values) {
      for (final Set<Stroke> strokes in <Set<Stroke>>[
        links.cited,
        links.drawn,
      ]) {
        for (final MapEntry<Stroke, Stroke> entry in replaced.entries) {
          if (strokes.contains(entry.key)) {
            changed = strokes.add(entry.value) || changed;
          }
        }
      }
    }
    return changed;
  }
}

/// A paragraph of the open conversation: the message it is in, as an index
/// into its messages, and its number from one.
class AiParagraphRef {
  const AiParagraphRef(this.message, this.paragraph);

  final int message;
  final int paragraph;

  @override
  bool operator ==(Object other) =>
      other is AiParagraphRef &&
      other.message == message &&
      other.paragraph == paragraph;

  @override
  int get hashCode => Object.hash(message, paragraph);
}

/// The paragraph being read, and what to show for it on the note.
class AiParagraphFocus {
  const AiParagraphFocus(this.ref, this.links);

  final AiParagraphRef ref;
  final AiParagraphLinks links;
}

/// What one request's citations mean: the selection SVG it was sent, with the
/// note's stroke behind each of that SVG's lines, and where the picture it was
/// sent lies. Numbers belong to the request, since each is sent the selection
/// as it stands then.
class AiSourceMap {
  AiSourceMap(Iterable<SelectionSvgLine> lines, this.origins, {this.picture})
    : _lines = <int, SelectionSvgLine>{
        for (final SelectionSvgLine line in lines) line.line: line,
      };

  final Map<int, SelectionSvgLine> _lines;

  /// By stroke index in the snapshot the SVG was made from; null for a stroke
  /// no longer on the note.
  final List<Stroke?> origins;

  /// Where the image sent lies in page coordinates, when it shows a picture or
  /// printed page, so that a detail of it can be circled. Null otherwise.
  final Rect? picture;

  /// The most rings a paragraph gets, whatever the model writes.
  static const int maxCircles = 3;

  /// What the notation model cites for each of an answer's [paragraphs], as far
  /// as it names something in the selection. A number past the last paragraph
  /// ties nothing.
  AiAnswerLinks resolve(Map<int, String> citations, {required int paragraphs}) {
    final AiAnswerLinks links = AiAnswerLinks();
    for (final MapEntry<int, String> citation in citations.entries) {
      final int paragraph = citation.key;
      if (paragraph < 1 || paragraph > paragraphs) continue;
      final List<AiLineRange> valid = <AiLineRange>[];
      final List<Stroke> cited = <Stroke>[];
      for (final AiLineRange range in _citedIn(citation.value)) {
        bool named = false;
        // Bounded by what exists: a model can write any number here.
        for (final int number in _lines.keys) {
          if (number < range.first || number > range.last) continue;
          named = true;
          final int index = _lines[number]!.strokeIndex;
          if (index < origins.length) {
            if (origins[index] case final Stroke stroke) cited.add(stroke);
          }
        }
        if (named) valid.add(range);
      }
      final Rect? shown = picture;
      final List<Rect> circles = shown == null
          ? const <Rect>[]
          : _circledIn(citation.value)
                .map((AiPictureBox box) => box.within(shown))
                .nonNulls
                .take(maxCircles)
                .toList(growable: false);
      if (valid.isNotEmpty || circles.isNotEmpty) {
        links.paragraphs[paragraph] = AiParagraphLinks(
          ranges: List<AiLineRange>.unmodifiable(valid),
          circles: circles,
          cited: cited,
        );
      }
    }
    return links;
  }
}
