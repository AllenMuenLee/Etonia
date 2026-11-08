import 'dart:math' as math;

import 'study_desk_models.dart';
import 'study_rag_index.dart' show StudyEvidenceSelector, studyContentTokens;

/// Settles which lines of a chunk a citation really means.
///
/// A model cites a whole chunk when it should cite two sentences, is a line or
/// two out at either end, or is simply wrong about a number. This looks at the
/// words of the paragraph it wrote and at the words of the lines it cited, and
/// marks what the paragraph is about instead of all that was named:
///
/// * a whole-chunk citation shrinks to the lines the paragraph draws on;
/// * a line citation is cut back where its ends say nothing the paragraph does,
///   and reaches on to the end of a sentence it stopped in the middle of;
/// * a line citation whose lines share nothing with the paragraph, while others
///   in the chunk do, is taken as misnumbered and moved there.
///
/// Evidence is only ever narrowed or moved on a match: with nothing to go by,
/// what was cited is left as it was.
abstract final class StudyCitationRefiner {
  /// How far a sentence is followed past a cited line that stops mid-sentence.
  /// One line: notes written as lists of fragments look like one long sentence
  /// to anything that goes by the shape of a line alone.
  static const int maxReach = 1;

  /// A paragraph with fewer content words than this cannot be checked against.
  static const int minParagraphWords = 3;

  /// Whether [chunk]'s lines can be told apart by what they say. A drawing or
  /// poorly read ink is shown to the model as a picture, and its words are not
  /// what a citation of it rests on.
  static bool canRefine(StudyChunk chunk) =>
      chunk.kind == StudyChunkKind.text &&
      !chunk.lowConfidence &&
      chunk.lines.length >= 2;

  /// The lines of [chunk], as indices into [StudyChunk.lines], that a citation
  /// of all of it means, or null when it cannot be told: the paragraph shares
  /// too little with it, or it is too short to be worth narrowing.
  static List<int>? linesForChunk(StudyChunk chunk, String paragraph) {
    if (!canRefine(chunk) || chunk.lines.length < 3) return null;
    final List<_Reading>? reading = _read(chunk, paragraph);
    if (reading == null || !reading.any((_Reading line) => line.relevant)) {
      return null;
    }
    final int count = reading.length;
    final List<_Run> runs = <_Run>[];
    int i = 0;
    while (i < count) {
      if (!reading[i].relevant) {
        i++;
        continue;
      }
      int end = i;
      int score = reading[i].matched;
      int j = i + 1;
      while (j < count) {
        if (reading[j].relevant) {
          end = j;
          score += reading[j].matched;
          j++;
          continue;
        }
        // One line that says nothing of the paragraph, between two that do,
        // is part of the same passage; formulas are no break at all.
        int next = j;
        int gap = 0;
        while (next < count && !reading[next].relevant) {
          if (!reading[next].neutral) gap++;
          next++;
        }
        if (next < count && gap <= 1) {
          j = next;
          continue;
        }
        break;
      }
      runs.add(_Run(i, end, score));
      i = end + 1;
    }
    final int best = runs.map((_Run run) => run.score).reduce(math.max);
    final List<_Run> kept = <_Run>[
      for (final _Run run in runs)
        if (run.score * 2 >= best) run,
    ]..sort((_Run a, _Run b) => b.score.compareTo(a.score));
    final Set<int> chosen = <int>{};
    for (final _Run run in kept.take(3)) {
      int first = run.first;
      int last = run.last;
      // A formula beside the words belongs with them.
      if (first > 0 && reading[first - 1].neutral) first--;
      if (last < count - 1 && reading[last + 1].neutral) last++;
      final (int, int) reach = _snap(chunk, reading, first, last);
      for (int line = reach.$1; line <= reach.$2; line++) {
        chosen.add(line);
      }
    }
    return chosen.toList()..sort();
  }

  /// [cited], lines of [chunk] by index, as the paragraph's own words say they
  /// should be: cut back, reached out, or moved.
  static List<int> refineLines(
    StudyChunk chunk,
    Iterable<int> cited,
    String paragraph,
  ) {
    final List<int> lines = <int>{
      for (final int line in cited)
        if (line >= 0 && line < chunk.lines.length) line,
    }.toList()..sort();
    if (lines.isEmpty || !canRefine(chunk)) return lines;
    final List<_Reading>? reading = _read(chunk, paragraph);
    final List<int> working = reading == null
        ? lines
        : _moved(reading, lines) ?? lines;

    final Set<int> result = <int>{};
    for (final List<int> run in _runs(working)) {
      int first = run.first;
      int last = run.last;
      if (reading != null && last - first + 1 >= 4) {
        final int most = (last - first + 1) ~/ 4;
        int cut = 0;
        while (cut < most &&
            last - first + 1 > 2 &&
            _worthless(reading[first])) {
          first++;
          cut++;
        }
        cut = 0;
        while (cut < most &&
            last - first + 1 > 2 &&
            _worthless(reading[last])) {
          last--;
          cut++;
        }
      }
      final (int, int) reach = _snap(chunk, reading, first, last);
      for (int line = reach.$1; line <= reach.$2; line++) {
        result.add(line);
      }
    }
    return result.toList()..sort();
  }

  /// A line at the edge of a citation that says nothing the paragraph says,
  /// and is no formula, which a paragraph may use without repeating.
  static bool _worthless(_Reading line) =>
      !line.neutral && !line.math && line.matched == 0;

  /// [lines] moved to the best window of as many lines when none of them says
  /// anything of the paragraph and some other lines of the chunk do; null when
  /// they should stay.
  static List<int>? _moved(List<_Reading> reading, List<int> lines) {
    final List<int> words = <int>[
      for (final int line in lines)
        if (!reading[line].neutral) line,
    ];
    if (words.isEmpty || words.any((int line) => reading[line].matched > 0)) {
      return null;
    }
    final int size = math.min(lines.length, 6);
    int bestScore = 0;
    int bestStart = -1;
    for (int start = 0; start + size <= reading.length; start++) {
      int score = 0;
      for (int line = start; line < start + size; line++) {
        score += reading[line].matched;
      }
      if (score > bestScore) {
        bestScore = score;
        bestStart = start;
      }
    }
    if (bestStart < 0 || bestScore < 2) return null;
    return <int>[for (int line = 0; line < size; line++) bestStart + line];
  }

  /// [lines] split where they are not next to each other.
  static List<List<int>> _runs(List<int> lines) {
    final List<List<int>> runs = <List<int>>[];
    for (final int line in lines) {
      if (runs.isNotEmpty && runs.last.last + 1 == line) {
        runs.last.add(line);
      } else {
        runs.add(<int>[line]);
      }
    }
    return runs;
  }

  /// [first] through [last], made to take in the rest of a sentence it begins
  /// or ends partway through. Handwritten rows break wherever the page does,
  /// so a row that starts in lower case goes on from the one before, and one
  /// that stops with no full stop goes on in the next. Only a row that also
  /// says a word the paragraph says is taken in: its shape alone is no proof,
  /// and with no paragraph to check against, nothing is added.
  static (int, int) _snap(
    StudyChunk chunk,
    List<_Reading>? reading,
    int first,
    int last,
  ) {
    if (reading == null) return (first, last);
    final List<StudyChunkLine> lines = chunk.lines;
    int steps = 0;
    while (first > 0 &&
        steps < maxReach &&
        _continues(lines[first].text) &&
        !_ends(lines[first - 1].text) &&
        reading[first - 1].exact > 0) {
      first--;
      steps++;
    }
    steps = 0;
    while (last < lines.length - 1 &&
        steps < maxReach &&
        !_ends(lines[last].text) &&
        _continues(lines[last + 1].text) &&
        reading[last + 1].exact > 0) {
      last++;
      steps++;
    }
    return (first, last);
  }

  static final RegExp _sentenceEnd = RegExp(r'[.!?:;…。！？；：][\s"”’)\]]*$');
  static final RegExp _lowerStart = RegExp(
    r'^[\s"“‘(\[]*\p{Ll}',
    unicode: true,
  );

  static bool _ends(String text) => _sentenceEnd.hasMatch(text.trimRight());

  /// Whether [text] picks up a sentence begun before it.
  static bool _continues(String text) => _lowerStart.hasMatch(text);

  static List<_Reading>? _read(StudyChunk chunk, String paragraph) {
    final Set<String> words = studyContentTokens(paragraph).toSet();
    if (words.length < minParagraphWords) return null;
    final Set<String> stems = <String>{
      for (final String word in words)
        if (word.length >= 5) word.substring(0, 5),
    };
    bool says(String token) =>
        words.contains(token) ||
        (token.length >= 5 && stems.contains(token.substring(0, 5)));
    return <_Reading>[
      for (final StudyChunkLine line in chunk.lines)
        () {
          final Set<String> tokens = studyContentTokens(line.text).toSet();
          return _Reading(
            tokens: tokens.length,
            matched: tokens.where(says).length,
            exact: tokens.where(words.contains).length,
            math: StudyEvidenceSelector.hasMathematics(line.text),
          );
        }(),
    ];
  }
}

/// What one line of a chunk shares with a paragraph.
class _Reading {
  const _Reading({
    required this.tokens,
    required this.matched,
    required this.exact,
    required this.math,
  });

  final int tokens;

  /// Words shared with the paragraph, a word and its stem counting as one.
  final int matched;

  /// Words shared exactly.
  final int exact;
  final bool math;

  /// No words to compare: a formula, a number, a symbol.
  bool get neutral => tokens == 0;

  /// Said by the paragraph: two of its words, or most of a short line's.
  bool get relevant =>
      matched >= 2 || (matched >= 1 && (tokens <= 3 || matched / tokens >= .4));
}

class _Run {
  const _Run(this.first, this.last, this.score);

  final int first;
  final int last;
  final int score;
}
