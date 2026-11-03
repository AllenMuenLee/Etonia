import 'dart:math' as math;
import 'dart:ui' show Rect;

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

final RegExp _linesCitation = RegExp(_linesPattern, caseSensitive: false);
final RegExp _circleCitation = RegExp(_circlePattern, caseSensitive: false);

final RegExp _citation = RegExp(
  '[ \\t]*(?:$_linesPattern|$_circlePattern)',
  caseSensitive: false,
);

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
  void flush() {
    if (block.isNotEmpty) blocks.add(block.toString());
    block.clear();
  }

  for (final String line in markdown.split('\n')) {
    final String trimmed = line.trim();
    if (!inFormula && trimmed.startsWith('```')) {
      inFence = !inFence;
    } else if (!inFence && '\$\$'.allMatches(trimmed).length.isOdd) {
      inFormula = !inFormula;
    }
    if (trimmed.isEmpty && !inFence && !inFormula) {
      flush();
    } else {
      block.writeln(line);
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
