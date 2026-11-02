import 'dart:ui' show Rect;

import '../ink/stroke.dart';
import 'selection_svg_renderer.dart';

/// Cites the selection SVG's lines at a paragraph's end: `[[L12-L30]]`, or
/// several ranges as `[[L12-L30,L44]]`.
final RegExp _citation = RegExp(
  r'[ \t]*\[\[\s*L\d+(?:\s*[-–]\s*L?\d+)?'
  r'(?:\s*,\s*L\d+(?:\s*[-–]\s*L?\d+)?)*\s*\]\]',
  caseSensitive: false,
);

/// A citation still being written at the end of a streaming answer.
final RegExp _unfinishedCitation = RegExp(
  r'[ \t]*\[(?:\[[\sLl\d,–-]*\]?)?$',
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

/// One block of an answer, with its citations taken out.
class AiAnswerParagraph {
  const AiAnswerParagraph(this.text, this.ranges);

  /// The Markdown to show.
  final String text;

  /// What it cites, as the model wrote it. Not yet checked against the SVG.
  final List<AiLineRange> ranges;
}

/// [text] with every citation taken out: what a reader, or a later turn, gets.
String stripAiCitations(String text, {bool streaming = false}) {
  final String stripped = text.replaceAll(_citation, '');
  return streaming ? stripped.replaceFirst(_unfinishedCitation, '') : stripped;
}

/// The paragraphs of [markdown], numbered from one by their place in the
/// list. They are the blocks between blank lines, a fenced code block or
/// `$$` formula staying whole; a citation alone on a line belongs to the
/// paragraph before it.
///
/// `answerParagraphs` in `supabase/functions/_shared/ai_policy.ts` numbers
/// them the same way for the drawing model, so a stroke's paragraph number
/// finds the same paragraph here. Change both together.
List<AiAnswerParagraph> parseAiAnswer(
  String markdown, {
  bool streaming = false,
}) {
  final List<String> texts = <String>[];
  final List<List<AiLineRange>> ranges = <List<AiLineRange>>[];
  for (final String block in _blocks(markdown)) {
    final String text = stripAiCitations(block, streaming: streaming).trim();
    final List<AiLineRange> cited = _citedIn(block);
    if (text.isNotEmpty) {
      texts.add(text);
      ranges.add(cited);
    } else if (ranges.isNotEmpty) {
      ranges.last.addAll(cited);
    }
  }
  return <AiAnswerParagraph>[
    for (int i = 0; i < texts.length; i++)
      AiAnswerParagraph(texts[i], List<AiLineRange>.unmodifiable(ranges[i])),
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
  for (final Match token in _citation.allMatches(block)) {
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

/// What a paragraph of an answer is tied to on the note.
class AiParagraphLinks {
  AiParagraphLinks({
    this.ranges = const <AiLineRange>[],
    this.regions = const <Rect>[],
    Iterable<Stroke> cited = const <Stroke>[],
    Iterable<Stroke> drawn = const <Stroke>[],
  }) {
    this.cited.addAll(cited);
    this.drawn.addAll(drawn);
  }

  /// The citations that named something in the selection.
  final List<AiLineRange> ranges;

  /// Parts of a picture or printed page it cites, in page coordinates.
  final List<Rect> regions;

  /// The ink it cites: the user's, or the assistant's earlier notation.
  final Set<Stroke> cited = Set<Stroke>.identity();

  /// The strokes the notation model drew for it.
  final Set<Stroke> drawn = Set<Stroke>.identity();

  bool get isEmpty => cited.isEmpty && drawn.isEmpty && regions.isEmpty;

  /// Shown after the paragraph.
  String get label => ranges.isEmpty
      ? 'Notation'
      : ranges.map((AiLineRange range) => range.label).join(', ');
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

/// What one request's line numbers mean: the selection SVG it was sent, with
/// the note's stroke behind each of that SVG's stroke lines. Numbers belong
/// to the request, since each is sent the selection as it stands then.
class AiSourceMap {
  AiSourceMap(Iterable<SelectionSvgLine> lines, this.origins)
    : _lines = <int, SelectionSvgLine>{
        for (final SelectionSvgLine line in lines) line.line: line,
      };

  final Map<int, SelectionSvgLine> _lines;

  /// By stroke index in the snapshot the SVG was made from; null for a stroke
  /// no longer on the note.
  final List<Stroke?> origins;

  /// [text]'s citations, as far as they name something in the selection.
  AiAnswerLinks resolve(String text, {bool streaming = false}) {
    final AiAnswerLinks links = AiAnswerLinks();
    final List<AiAnswerParagraph> paragraphs = parseAiAnswer(
      text,
      streaming: streaming,
    );
    for (int i = 0; i < paragraphs.length; i++) {
      final List<AiLineRange> valid = <AiLineRange>[];
      final List<Rect> regions = <Rect>[];
      final List<Stroke> cited = <Stroke>[];
      for (final AiLineRange range in paragraphs[i].ranges) {
        bool named = false;
        // Bounded by what exists: a model can write any number here.
        for (final int number in _lines.keys) {
          if (number < range.first || number > range.last) continue;
          final SelectionSvgLine line = _lines[number]!;
          named = true;
          if (line.strokeIndex case final int index) {
            if (index < origins.length) {
              if (origins[index] case final Stroke stroke) cited.add(stroke);
            }
          } else {
            regions.add(line.bounds);
          }
        }
        if (named) valid.add(range);
      }
      if (valid.isNotEmpty) {
        links.paragraphs[i + 1] = AiParagraphLinks(
          ranges: List<AiLineRange>.unmodifiable(valid),
          regions: _joinedRegions(regions),
          cited: cited,
        );
      }
    }
    return links;
  }

  /// Slices that touch, as one rectangle.
  static List<Rect> _joinedRegions(List<Rect> regions) {
    final List<Rect> joined = <Rect>[];
    for (final Rect region in regions) {
      if (joined.isNotEmpty &&
          (joined.last.bottom - region.top).abs() < 0.01 &&
          joined.last.left == region.left &&
          joined.last.right == region.right) {
        joined.last = joined.last.expandToInclude(region);
      } else {
        joined.add(region);
      }
    }
    return List<Rect>.unmodifiable(joined);
  }
}
