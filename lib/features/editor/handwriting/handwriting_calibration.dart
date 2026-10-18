import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../ai/notation_font.dart';
import '../ink/ink_sample.dart';

/// What the writer copies during calibration. Together the lines contain
/// every lowercase and capital letter, every digit, and the punctuation the
/// notation font can write, so each one can be learned at least once.
const List<String> calibrationLines = <String>[
  "Six grumpy wizards judged the quacking bovine's fluffy hat.",
  '"QUICK, HIDE!" yelled the frog. "SIX VEXED ZEBRAS WANT MY PB&J FOR GOULASH!"',
  "Oh no - my cat owes me \$1,250.47 (+ 6% tip) & 89 naps @ 3:00; it's 1/2 off* #rude?",
];

/// One step of calibration: a short phrase written on one ruled line, with
/// a remark to keep the writer company.
@immutable
class CalibrationChunk {
  const CalibrationChunk(this.text, this.quip);

  final String text;
  final String quip;

  /// The words of [text], as they should be separated on the page.
  List<String> get words => text.split(' ');
}

/// [calibrationLines], cut into phrases short enough for one ruled line on
/// a phone.
const List<CalibrationChunk> calibrationChunks = <CalibrationChunk>[
  CalibrationChunk('Six grumpy wizards', 'A bad day at the magic academy.'),
  CalibrationChunk('judged the quacking', 'The talent show has begun.'),
  CalibrationChunk("bovine's fluffy hat.", 'Harsh, but fair.'),
  CalibrationChunk('"QUICK, HIDE!" yelled', 'Capitals: please shout.'),
  CalibrationChunk('the frog.', 'Easy one. You earned it.'),
  CalibrationChunk('"SIX VEXED ZEBRAS', 'Still shouting.'),
  CalibrationChunk('WANT MY PB&J', 'They have no manners.'),
  CalibrationChunk('FOR GOULASH!"', 'A bold recipe.'),
  CalibrationChunk('Oh no - my cat', 'Meanwhile, at home…'),
  CalibrationChunk('owes me \$1,250.47', 'Itemised, of course.'),
  CalibrationChunk('(+ 6% tip) & 89 naps', 'Naps are not refundable.'),
  CalibrationChunk("@ 3:00; it's 1/2 off*", '*Terms and cats apply.'),
  CalibrationChunk('#rude?', 'Last one. Very #rude.'),
];

/// One handwritten form of a character or word, in writing units: the top
/// of a capital is y = 0, the baseline is y = 1, and x starts at the form's
/// left edge. Writing it [size] tall is a translation and a uniform scale.
@immutable
class CalibratedGlyph {
  CalibratedGlyph({
    required this.width,
    required Iterable<List<InkVector>> strokes,
  }) : strokes = List<List<InkVector>>.unmodifiable(
         strokes.map(List<InkVector>.unmodifiable),
       );

  /// Left to right, in writing units.
  final double width;

  /// Pen strokes in the order they were written.
  final List<List<InkVector>> strokes;

  /// Strokes written with the top-left of a capital at [origin], [size]
  /// tall.
  List<List<InkVector>> place(InkVector origin, double size) =>
      <List<InkVector>>[
        for (final List<InkVector> stroke in strokes)
          <InkVector>[
            for (final InkVector point in stroke)
              InkVector(origin.x + point.x * size, origin.y + point.y * size),
          ],
      ];

  Map<String, Object?> toJson() => <String, Object?>{
    'w': _round(width),
    's': <List<double>>[
      for (final List<InkVector> stroke in strokes)
        <double>[
          for (final InkVector point in stroke) ...<double>[
            _round(point.x),
            _round(point.y),
          ],
        ],
    ],
  };

  static CalibratedGlyph? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? width = json['w'];
    final Object? strokes = json['s'];
    if (width is! num || !width.isFinite || width < 0 || strokes is! List) {
      return null;
    }
    final List<List<InkVector>> parsed = <List<InkVector>>[];
    for (final Object? stroke in strokes) {
      if (stroke is! List || stroke.isEmpty || stroke.length.isOdd) {
        return null;
      }
      final List<InkVector> points = <InkVector>[];
      for (int i = 0; i < stroke.length; i += 2) {
        final Object? x = stroke[i];
        final Object? y = stroke[i + 1];
        if (x is! num || y is! num || !x.isFinite || !y.isFinite) return null;
        points.add(InkVector(x.toDouble(), y.toDouble()));
      }
      parsed.add(points);
    }
    if (parsed.isEmpty) return null;
    return CalibratedGlyph(width: width.toDouble(), strokes: parsed);
  }

  static double _round(double value) => (value * 10000).roundToDouble() / 10000;
}

/// The writer's own letters and words, learned from calibration. Generated
/// text uses them in place of the built-in font.
class HandwritingProfile {
  HandwritingProfile({
    Map<String, List<CalibratedGlyph>> glyphs =
        const <String, List<CalibratedGlyph>>{},
    Map<String, List<CalibratedGlyph>> words =
        const <String, List<CalibratedGlyph>>{},
    this.letterGap = defaultLetterGap,
    this.wordSpace = defaultWordSpace,
    math.Random? random,
  }) : glyphs = _bounded(glyphs),
       words = _bounded(words),
       _random = random ?? math.Random();

  /// Writing units between letters and words when calibration measured
  /// none.
  static const double defaultLetterGap = 0.12;
  static const double defaultWordSpace = 0.34;

  /// Distinct variants kept for one character or word.
  static const int maxVariants = 12;

  final Map<String, List<CalibratedGlyph>> glyphs;
  final Map<String, List<CalibratedGlyph>> words;
  final double letterGap;
  final double wordSpace;
  final math.Random _random;

  bool get isEmpty => glyphs.isEmpty && words.isEmpty;

  bool hasGlyph(String char) => glyphs[char]?.isNotEmpty ?? false;

  /// Whether any part of [text] can be written in the writer's hand.
  bool canWriteAny(String text) =>
      (words[text]?.isNotEmpty ?? false) ||
      text.runes.any((int rune) => hasGlyph(String.fromCharCode(rune)));

  CalibratedGlyph? chooseGlyph(String char) => _choose(glyphs[char]);

  CalibratedGlyph? chooseWord(String word) => _choose(words[word]);

  CalibratedGlyph? _choose(List<CalibratedGlyph>? variants) =>
      variants == null || variants.isEmpty
      ? null
      : variants[_random.nextInt(variants.length)];

  /// This profile with [other]'s samples added, keeping at most
  /// [maxVariants] of each. Measured spacing comes from [other].
  HandwritingProfile mergedWith(HandwritingProfile other) {
    Map<String, List<CalibratedGlyph>> merge(
      Map<String, List<CalibratedGlyph>> a,
      Map<String, List<CalibratedGlyph>> b,
    ) => <String, List<CalibratedGlyph>>{
      for (final String key in <String>{...a.keys, ...b.keys})
        key: <CalibratedGlyph>[...?b[key], ...?a[key]],
    };
    return HandwritingProfile(
      glyphs: merge(glyphs, other.glyphs),
      words: merge(words, other.words),
      letterGap: other.letterGap,
      wordSpace: other.wordSpace,
      random: _random,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'letterGap': letterGap,
    'wordSpace': wordSpace,
    'glyphs': _samplesToJson(glyphs),
    'words': _samplesToJson(words),
  };

  /// Reads a saved profile. Malformed samples are dropped; a profile that
  /// cannot be read at all is null.
  static HandwritingProfile? fromJson(Object? json, {math.Random? random}) {
    if (json is! Map || json['version'] != 1) return null;
    double spacing(Object? value, double fallback) =>
        value is num && value.isFinite && value >= 0 && value < 4
        ? value.toDouble()
        : fallback;
    return HandwritingProfile(
      glyphs: _samplesFromJson(json['glyphs']),
      words: _samplesFromJson(json['words']),
      letterGap: spacing(json['letterGap'], defaultLetterGap),
      wordSpace: spacing(json['wordSpace'], defaultWordSpace),
      random: random,
    );
  }

  static Map<String, Object?> _samplesToJson(
    Map<String, List<CalibratedGlyph>> samples,
  ) => <String, Object?>{
    for (final MapEntry<String, List<CalibratedGlyph>> entry in samples.entries)
      entry.key: <Object?>[
        for (final CalibratedGlyph glyph in entry.value) glyph.toJson(),
      ],
  };

  static Map<String, List<CalibratedGlyph>> _samplesFromJson(Object? json) {
    if (json is! Map) return const <String, List<CalibratedGlyph>>{};
    final Map<String, List<CalibratedGlyph>> samples =
        <String, List<CalibratedGlyph>>{};
    for (final MapEntry<Object?, Object?> entry in json.entries) {
      final Object? key = entry.key;
      final Object? variants = entry.value;
      if (key is! String || key.isEmpty || variants is! List) continue;
      final List<CalibratedGlyph> parsed = <CalibratedGlyph>[
        for (final Object? variant in variants)
          ?CalibratedGlyph.fromJson(variant),
      ];
      if (parsed.isNotEmpty) samples[key] = parsed;
    }
    return samples;
  }

  static Map<String, List<CalibratedGlyph>> _bounded(
    Map<String, List<CalibratedGlyph>> samples,
  ) => Map<String, List<CalibratedGlyph>>.unmodifiable(<
    String,
    List<CalibratedGlyph>
  >{
    for (final MapEntry<String, List<CalibratedGlyph>> entry in samples.entries)
      if (entry.value.isNotEmpty)
        entry.key: List<CalibratedGlyph>.unmodifiable(
          entry.value.take(maxVariants),
        ),
  });
}

/// What one calibration step learned.
@immutable
class CalibrationReading {
  const CalibrationReading({
    required this.profile,
    required this.wordsFound,
    required this.wordsExpected,
    required this.lettersLearned,
  });

  /// The samples from this step alone.
  final HandwritingProfile profile;
  final int wordsFound;
  final int wordsExpected;

  /// How many characters were cut cleanly from their words.
  final int lettersLearned;

  /// Whether the ink split into as many words as the phrase has. Otherwise
  /// nothing was learned, because words cannot be matched to their text.
  bool get wordsMatched => wordsFound == wordsExpected;
}

/// Learns letters and words from [strokes] written for [chunk] on a ruled
/// line whose capital line is at [capTop] and whose baseline is
/// [lineHeight] below it.
///
/// Words are found at clear horizontal gaps. Within a word, strokes whose
/// horizontal extents overlap form one mark, so an i-dot or t-cross stays
/// with its letter. With one mark per character the pairing is direct.
/// Joined-up letters are cut where the pen bottoms out between them,
/// choosing the places that best match each letter's expected width; a word
/// whose cuts cannot be placed plausibly is kept whole rather than cut at a
/// guess.
CalibrationReading readCalibration(
  CalibrationChunk chunk,
  List<List<InkVector>> strokes, {
  required double capTop,
  required double lineHeight,
}) {
  final List<String> expected = chunk.words;
  final List<List<List<InkVector>>> wordInk = _splitWords(strokes);
  if (wordInk.length != expected.length) {
    return CalibrationReading(
      profile: HandwritingProfile(),
      wordsFound: wordInk.length,
      wordsExpected: expected.length,
      lettersLearned: 0,
    );
  }

  // Cut letters first: letters of a known height then locate the writer's
  // actual capital line and baseline, which the guides only suggest.
  final List<List<_Mark>?> letters = <List<_Mark>?>[
    for (int i = 0; i < expected.length; i++)
      _cutLetters(expected[i], wordInk[i]),
  ];
  final List<double> tops = <double>[];
  final List<double> bottoms = <double>[];
  for (int i = 0; i < expected.length; i++) {
    final List<_Mark>? marks = letters[i];
    if (marks == null) continue;
    for (final _Mark mark in marks) {
      // Letters cut from joined writing have approximate bounds.
      if (!mark.joined && _capHeightChars.contains(mark.char)) {
        tops.add(mark.bounds.top);
        bottoms.add(mark.bounds.bottom);
      }
    }
  }
  double top = capTop;
  double height = lineHeight;
  if (tops.isNotEmpty) {
    final double measuredTop = _median(tops);
    final double measuredHeight = _median(bottoms) - measuredTop;
    // Implausible measurements (a stray scribble) keep the guides.
    if (measuredHeight > lineHeight * 0.3 && measuredHeight < lineHeight * 3) {
      top = measuredTop;
      height = measuredHeight;
    }
  }

  CalibratedGlyph normalize(
    List<List<InkVector>> ink,
    double left,
    double right,
  ) => CalibratedGlyph(
    width: (right - left) / height,
    strokes: <List<InkVector>>[
      for (final List<InkVector> stroke in ink)
        <InkVector>[
          for (final InkVector point in stroke)
            InkVector((point.x - left) / height, (point.y - top) / height),
        ],
    ],
  );

  final Map<String, List<CalibratedGlyph>> glyphs =
      <String, List<CalibratedGlyph>>{};
  final Map<String, List<CalibratedGlyph>> words =
      <String, List<CalibratedGlyph>>{};
  final List<double> letterGaps = <double>[];
  final List<double> wordGaps = <double>[];
  int learned = 0;
  for (int i = 0; i < expected.length; i++) {
    final List<_Mark>? marks = letters[i];
    if (i > 0) {
      wordGaps.add(
        (_Bounds.of(wordInk[i]).left - _Bounds.of(wordInk[i - 1]).right) /
            height,
      );
    }
    if (marks == null) {
      // Kept whole, but only when the token is a plain word: punctuation
      // stuck to it could not be separated again.
      if (_plainWord.hasMatch(expected[i])) {
        final _Bounds bounds = _Bounds.of(wordInk[i]);
        words
            .putIfAbsent(expected[i], () => <CalibratedGlyph>[])
            .add(normalize(wordInk[i], bounds.left, bounds.right));
      }
      continue;
    }
    for (int m = 0; m < marks.length; m++) {
      final _Mark mark = marks[m];
      glyphs
          .putIfAbsent(mark.char, () => <CalibratedGlyph>[])
          .add(normalize(mark.strokes, mark.bounds.left, mark.bounds.right));
      learned++;
      if (m > 0) {
        // Letters cut from one joined stroke touch: their gap is none.
        letterGaps.add(
          mark.joined && mark.group == marks[m - 1].group
              ? 0
              : (mark.bounds.left - marks[m - 1].bounds.right) / height,
        );
      }
    }
    // The word inside any punctuation, kept whole as well, so common words
    // keep their natural joins and spacing.
    for (final RegExpMatch match in _wordCore.allMatches(expected[i])) {
      final List<_Mark> core = marks.sublist(match.start, match.end);
      if (core.length < 2) continue;
      words
          .putIfAbsent(match.group(0)!, () => <CalibratedGlyph>[])
          .add(
            normalize(
              <List<InkVector>>[for (final _Mark mark in core) ...mark.strokes],
              core.first.bounds.left,
              core.last.bounds.right,
            ),
          );
    }
  }
  double spacing(List<double> gaps, double fallback, double max) {
    final List<double> plausible = gaps
        .where((double gap) => gap >= 0 && gap < max)
        .toList();
    return plausible.isEmpty ? fallback : _median(plausible);
  }

  return CalibrationReading(
    profile: HandwritingProfile(
      glyphs: glyphs,
      words: words,
      letterGap: spacing(letterGaps, HandwritingProfile.defaultLetterGap, 1),
      wordSpace: spacing(wordGaps, HandwritingProfile.defaultWordSpace, 2),
    ),
    wordsFound: wordInk.length,
    wordsExpected: expected.length,
    lettersLearned: learned,
  );
}

/// Characters whose top meets the capital line and whose bottom sits on the
/// baseline, in most hands.
const Set<String> _capHeightChars = <String>{
  'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'K', 'L', 'M', 'N', 'O', //
  'P', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', //
  '0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
};

final RegExp _plainWord = RegExp(r'^[\p{L}\p{M}\p{N}]+$', unicode: true);
final RegExp _wordCore = RegExp(r'[\p{L}\p{M}\p{N}]+', unicode: true);

@immutable
class _Bounds {
  const _Bounds(this.left, this.top, this.right, this.bottom);

  factory _Bounds.of(Iterable<List<InkVector>> strokes) {
    double left = double.infinity;
    double top = double.infinity;
    double right = double.negativeInfinity;
    double bottom = double.negativeInfinity;
    for (final List<InkVector> stroke in strokes) {
      for (final InkVector point in stroke) {
        left = math.min(left, point.x);
        top = math.min(top, point.y);
        right = math.max(right, point.x);
        bottom = math.max(bottom, point.y);
      }
    }
    return _Bounds(left, top, right, bottom);
  }

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;
  double get centerX => (left + right) / 2;
}

class _Mark {
  _Mark(this.char, this.strokes, {required this.group, this.joined = false})
    : bounds = _Bounds.of(strokes);

  final String char;
  final List<List<InkVector>> strokes;
  final _Bounds bounds;

  /// The separate mark of ink this letter came from.
  final int group;

  /// Cut from ink shared with neighbouring letters.
  final bool joined;
}

/// Splits ink into words at clear horizontal gaps, in left-to-right order.
List<List<List<InkVector>>> _splitWords(List<List<InkVector>> strokes) {
  final List<List<InkVector>> ordered =
      strokes.where((List<InkVector> stroke) => stroke.isNotEmpty).toList()
        ..sort(
          (List<InkVector> a, List<InkVector> b) => _Bounds.of(
            <List<InkVector>>[a],
          ).left.compareTo(_Bounds.of(<List<InkVector>>[b]).left),
        );
  if (ordered.isEmpty) return const <List<List<InkVector>>>[];
  final double height = _Bounds.of(ordered).height;
  final double gap = math.max(12, height * 0.35);
  final List<List<List<InkVector>>> words = <List<List<InkVector>>>[];
  List<List<InkVector>> current = <List<InkVector>>[];
  double right = double.negativeInfinity;
  for (final List<InkVector> stroke in ordered) {
    final _Bounds bounds = _Bounds.of(<List<InkVector>>[stroke]);
    if (current.isNotEmpty && bounds.left > right + gap) {
      words.add(current);
      current = <List<InkVector>>[];
      right = double.negativeInfinity;
    }
    current.add(stroke);
    right = math.max(right, bounds.right);
  }
  words.add(current);
  // Restore writing order inside each word.
  return <List<List<InkVector>>>[
    for (final List<List<InkVector>> word in words)
      <List<InkVector>>[
        for (final List<InkVector> stroke in strokes)
          if (word.contains(stroke)) stroke,
      ],
  ];
}

/// [word]'s ink cut into one mark per character, or null when the marks
/// and characters cannot be paired with confidence.
List<_Mark>? _cutLetters(String word, List<List<InkVector>> ink) {
  final List<String> chars = <String>[
    for (final int rune in word.runes) String.fromCharCode(rune),
  ];
  final List<List<List<InkVector>>> marks = _mergeQuoteTicks(
    chars,
    _marksOf(ink),
  );
  if (marks.length == chars.length) {
    return <_Mark>[
      for (int i = 0; i < chars.length; i++)
        _Mark(chars[i], marks[i], group: i),
    ];
  }
  if (marks.length > chars.length) return null;
  // Fewer marks than characters: some letters are joined. Decide how many
  // letters each mark holds, then cut the marks holding several.
  final List<int>? runs = _assignRuns(chars, marks);
  if (runs == null) return null;
  final List<_Mark> cut = <_Mark>[];
  int next = 0;
  for (int m = 0; m < marks.length; m++) {
    final List<String> run = chars.sublist(next, next + runs[m]);
    next += runs[m];
    if (run.length == 1) {
      cut.add(_Mark(run.single, marks[m], group: m));
      continue;
    }
    final List<List<List<InkVector>>>? pieces = _splitJoined(marks[m], run);
    if (pieces == null) return null;
    for (int j = 0; j < run.length; j++) {
      cut.add(_Mark(run[j], pieces[j], group: m, joined: true));
    }
  }
  return cut;
}

/// A double quote is two ticks side by side: at either end of a word, two
/// short marks in its upper half are joined into one.
List<List<List<InkVector>>> _mergeQuoteTicks(
  List<String> chars,
  List<List<List<InkVector>>> marks,
) {
  if (marks.length < 2) return marks;
  final _Bounds word = _Bounds.of(<List<InkVector>>[
    for (final List<List<InkVector>> mark in marks) ...mark,
  ]);
  bool tick(List<List<InkVector>> mark) {
    final _Bounds bounds = _Bounds.of(mark);
    return bounds.height < word.height * 0.5 &&
        bounds.bottom < word.top + word.height * 0.6;
  }

  final List<List<List<InkVector>>> merged = List<List<List<InkVector>>>.of(
    marks,
  );
  if (chars.first == '"' && tick(merged[0]) && tick(merged[1])) {
    merged.replaceRange(0, 2, <List<List<InkVector>>>[
      <List<InkVector>>[...merged[0], ...merged[1]],
    ]);
  }
  final int last = merged.length - 1;
  if (chars.length > 1 &&
      chars.last == '"' &&
      last >= 1 &&
      tick(merged[last]) &&
      tick(merged[last - 1])) {
    merged.replaceRange(last - 1, last + 1, <List<List<InkVector>>>[
      <List<InkVector>>[...merged[last - 1], ...merged[last]],
    ]);
  }
  return merged;
}

/// The relative width a character usually takes, from the built-in font.
double _expectedWidth(String char) =>
    (NotationFont.glyphWidth(char) ?? 5) + NotationFont.spacing;

/// How many consecutive characters each mark holds, chosen so that each
/// mark's share of the word's width best matches its letters' share.
List<int>? _assignRuns(List<String> chars, List<List<List<InkVector>>> marks) {
  final int markCount = marks.length;
  final int charCount = chars.length;
  final List<double> widths = <double>[
    for (final List<List<InkVector>> mark in marks)
      math.max(_Bounds.of(mark).width, 1),
  ];
  final double totalWidth = widths.fold<double>(
    0,
    (double a, double b) => a + b,
  );
  final List<double> prefix = <double>[0];
  for (final String char in chars) {
    prefix.add(prefix.last + _expectedWidth(char));
  }
  final double totalExpected = prefix.last;
  final List<List<double>> best = <List<double>>[
    for (int m = 0; m <= markCount; m++)
      List<double>.filled(charCount + 1, double.infinity),
  ];
  final List<List<int>> from = <List<int>>[
    for (int m = 0; m <= markCount; m++) List<int>.filled(charCount + 1, -1),
  ];
  best[0][0] = 0;
  for (int m = 1; m <= markCount; m++) {
    for (int c = m; c <= charCount - (markCount - m); c++) {
      for (int a = m - 1; a < c; a++) {
        if (best[m - 1][a] == double.infinity) continue;
        final double share = widths[m - 1] / totalWidth;
        final double expected = (prefix[c] - prefix[a]) / totalExpected;
        final double cost =
            best[m - 1][a] + (share - expected) * (share - expected);
        if (cost < best[m][c]) {
          best[m][c] = cost;
          from[m][c] = a;
        }
      }
    }
  }
  if (best[markCount][charCount] == double.infinity) return null;
  final List<int> runs = List<int>.filled(markCount, 0);
  int c = charCount;
  for (int m = markCount; m > 0; m--) {
    final int a = from[m][c];
    runs[m - 1] = c - a;
    c = a;
  }
  return runs;
}

/// A candidate place to cut joined writing.
typedef _Cut = ({int index, double x, bool lift});

/// One joined mark cut into [chars].length letters, or null when no
/// plausible set of cuts exists.
///
/// Small strokes (dots and cross-bars) are set aside. The rest are read as
/// one pen path; candidate cuts are pen lifts and the points where the path
/// bottoms out in the lower part of the mark, which is where connecting
/// strokes leave one letter for the next. The cuts chosen are those closest
/// to where the letters' expected widths put the boundaries, in pen order
/// and moving rightwards; each must land within half a letter of its
/// expected place. Small strokes then join the letter beneath them.
List<List<List<InkVector>>>? _splitJoined(
  List<List<InkVector>> strokes,
  List<String> chars,
) {
  final _Bounds bounds = _Bounds.of(strokes);
  final double accentSize = bounds.height * 0.35;
  final List<List<InkVector>> spine = <List<InkVector>>[];
  final List<List<InkVector>> accents = <List<InkVector>>[];
  for (final List<InkVector> stroke in strokes) {
    final _Bounds own = _Bounds.of(<List<InkVector>>[stroke]);
    (math.max(own.width, own.height) < accentSize ? accents : spine).add(
      stroke,
    );
  }
  if (spine.isEmpty) return null;

  final List<InkVector> path = <InkVector>[];
  final Set<int> strokeStarts = <int>{};
  for (final List<InkVector> stroke in spine) {
    if (path.isNotEmpty) strokeStarts.add(path.length);
    path.addAll(stroke);
  }
  int strokeOf(int index) =>
      strokeStarts.where((int start) => start <= index).length;

  final List<_Cut> candidates = <_Cut>[];
  final double lowerPart = bounds.top + bounds.height * 0.4;
  for (int i = 1; i < path.length - 1; i++) {
    if (strokeStarts.contains(i)) {
      candidates.add((
        index: i,
        x: (path[i - 1].x + path[i].x) / 2,
        lift: true,
      ));
      continue;
    }
    // The lowest point of a dip within its own stroke: y grows downwards.
    final InkVector point = path[i];
    if (point.y < lowerPart) continue;
    final int stroke = strokeOf(i);
    bool lowest = true;
    for (
      int j = math.max(0, i - 3);
      j <= math.min(path.length - 1, i + 3);
      j++
    ) {
      if (j == i || strokeOf(j) != stroke) continue;
      if (path[j].y > point.y || (path[j].y == point.y && j < i)) {
        lowest = false;
        break;
      }
    }
    // A dip at a stroke's own end is not between letters.
    final bool atEnd = strokeStarts.contains(i + 1) || i == path.length - 1;
    if (lowest && !atEnd) candidates.add((index: i, x: point.x, lift: false));
  }
  final int cuts = chars.length - 1;
  if (candidates.length < cuts) return null;

  final double width = math.max(bounds.width, 1);
  final List<double> letterWidths = <double>[
    for (final String char in chars) _expectedWidth(char),
  ];
  final double sum = letterWidths.fold<double>(
    0,
    (double a, double b) => a + b,
  );
  final List<double> expectedX = <double>[];
  double running = 0;
  for (int j = 0; j < cuts; j++) {
    running += letterWidths[j];
    expectedX.add(bounds.left + width * running / sum);
  }

  // best[j][c]: lowest cost with cut j at candidate c.
  final int count = candidates.length;
  final List<List<double>> best = <List<double>>[
    for (int j = 0; j < cuts; j++) List<double>.filled(count, double.infinity),
  ];
  final List<List<int>> previous = <List<int>>[
    for (int j = 0; j < cuts; j++) List<int>.filled(count, -1),
  ];
  double cost(int j, int c) {
    final double d = (candidates[c].x - expectedX[j]) / width;
    return d * d;
  }

  for (int c = 0; c < count; c++) {
    best[0][c] = cost(0, c);
  }
  for (int j = 1; j < cuts; j++) {
    for (int c = 0; c < count; c++) {
      for (int p = 0; p < c; p++) {
        if (best[j - 1][p] == double.infinity) continue;
        if (candidates[c].x <= candidates[p].x) continue;
        final double total = best[j - 1][p] + cost(j, c);
        if (total < best[j][c]) {
          best[j][c] = total;
          previous[j][c] = p;
        }
      }
    }
  }
  int chosen = -1;
  for (int c = 0; c < count; c++) {
    if (best[cuts - 1][c] == double.infinity) continue;
    if (chosen < 0 || best[cuts - 1][c] < best[cuts - 1][chosen]) chosen = c;
  }
  if (chosen < 0) return null;
  final List<_Cut> picked = List<_Cut>.filled(cuts, candidates[chosen]);
  for (int j = cuts - 1; j >= 0; j--) {
    picked[j] = candidates[chosen];
    chosen = previous[j][chosen];
  }
  final double tolerance = width / chars.length * 0.5;
  for (int j = 0; j < cuts; j++) {
    if ((picked[j].x - expectedX[j]).abs() > tolerance) return null;
  }

  // Cut the path. A dip is shared by the letters either side of it; a pen
  // lift needs no shared point.
  final List<List<List<InkVector>>> pieces = <List<List<InkVector>>>[];
  final List<(double, double)> spans = <(double, double)>[];
  int start = 0;
  double left = bounds.left;
  for (int j = 0; j <= cuts; j++) {
    final _Cut? cut = j < cuts ? picked[j] : null;
    final int end = cut == null
        ? path.length
        : (cut.lift ? cut.index : cut.index + 1);
    final List<List<InkVector>> piece = <List<InkVector>>[<InkVector>[]];
    for (int i = start; i < end; i++) {
      if (strokeStarts.contains(i) && i != start) piece.add(<InkVector>[]);
      piece.last.add(path[i]);
    }
    pieces.add(<List<InkVector>>[
      for (final List<InkVector> stroke in piece)
        if (stroke.isNotEmpty) stroke,
    ]);
    final double right = cut?.x ?? bounds.right;
    spans.add((left, right));
    left = right;
    if (cut != null) start = cut.index;
  }
  if (pieces.any((List<List<InkVector>> piece) => piece.isEmpty)) return null;
  for (final List<InkVector> accent in accents) {
    final double x = _Bounds.of(<List<InkVector>>[accent]).centerX;
    int nearest = 0;
    double distance = double.infinity;
    for (int j = 0; j < spans.length; j++) {
      final (double from, double to) = spans[j];
      final double d = x < from ? from - x : (x > to ? x - to : 0);
      if (d < distance) {
        distance = d;
        nearest = j;
      }
    }
    pieces[nearest].add(accent);
  }
  return pieces;
}

/// Groups strokes whose horizontal extents overlap, left to right. A small
/// stroke over another (a dot or a cross-bar) joins it.
List<List<List<InkVector>>> _marksOf(List<List<InkVector>> ink) {
  final List<(List<InkVector>, _Bounds)> ordered =
      <(List<InkVector>, _Bounds)>[
        for (final List<InkVector> stroke in ink)
          (stroke, _Bounds.of(<List<InkVector>>[stroke])),
      ]..sort(
        ((List<InkVector>, _Bounds) a, (List<InkVector>, _Bounds) b) =>
            a.$2.left.compareTo(b.$2.left),
      );
  final List<List<List<InkVector>>> marks = <List<List<InkVector>>>[];
  final List<_Bounds> extents = <_Bounds>[];
  for (final (List<InkVector> stroke, _Bounds bounds) in ordered) {
    if (marks.isNotEmpty) {
      final _Bounds last = extents.last;
      final double overlap =
          math.min(last.right, bounds.right) - math.max(last.left, bounds.left);
      final double narrower = math.max(math.min(last.width, bounds.width), 1);
      final bool insideLast =
          bounds.centerX >= last.left && bounds.centerX <= last.right;
      if (overlap / narrower >= 0.5 || (bounds.width < 4 && insideLast)) {
        marks.last.add(stroke);
        extents.last = _Bounds(
          math.min(last.left, bounds.left),
          math.min(last.top, bounds.top),
          math.max(last.right, bounds.right),
          math.max(last.bottom, bounds.bottom),
        );
        continue;
      }
    }
    marks.add(<List<InkVector>>[stroke]);
    extents.add(bounds);
  }
  // Keep each mark's strokes in the order they were written.
  return <List<List<InkVector>>>[
    for (final List<List<InkVector>> mark in marks)
      <List<InkVector>>[
        for (final List<InkVector> stroke in ink)
          if (mark.contains(stroke)) stroke,
      ],
  ];
}

double _median(List<double> values) {
  final List<double> sorted = List<double>.of(values)..sort();
  final int middle = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[middle]
      : (sorted[middle - 1] + sorted[middle]) / 2;
}

/// Where the profile is kept, and whether the writer has been asked.
abstract class HandwritingProfileStore {
  /// The saved state, or null when calibration has never been offered.
  Future<HandwritingCalibrationState?> read();

  Future<void> write(HandwritingCalibrationState state);
}

/// A profile and whether calibration was finished or skipped.
@immutable
class HandwritingCalibrationState {
  const HandwritingCalibrationState({this.profile, this.skipped = false});

  final HandwritingProfile? profile;

  /// The writer chose not to calibrate; they are not asked again at
  /// startup.
  final bool skipped;

  Map<String, Object?> toJson() => <String, Object?>{
    'skipped': skipped,
    if (profile != null) 'profile': profile!.toJson(),
  };

  static HandwritingCalibrationState fromJson(Map<String, Object?> json) =>
      HandwritingCalibrationState(
        profile: HandwritingProfile.fromJson(json['profile']),
        skipped: json['skipped'] == true,
      );
}

/// Keeps the profile in one JSON file, written atomically.
class FileHandwritingProfileStore implements HandwritingProfileStore {
  FileHandwritingProfileStore(this.file);

  final File file;

  @override
  Future<HandwritingCalibrationState?> read() async {
    try {
      if (!await file.exists()) return null;
      final Object? json = jsonDecode(await file.readAsString());
      return json is Map<String, Object?>
          ? HandwritingCalibrationState.fromJson(json)
          : const HandwritingCalibrationState();
    } on Object {
      // A damaged file counts as asked, so startup is not interrupted again;
      // calibration stays available from the library menu.
      return const HandwritingCalibrationState();
    }
  }

  @override
  Future<void> write(HandwritingCalibrationState state) async {
    await file.parent.create(recursive: true);
    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(state.toJson()), flush: true);
    await temporary.rename(file.path);
  }
}

/// Keeps the profile in memory, for tests and harnesses.
class InMemoryHandwritingProfileStore implements HandwritingProfileStore {
  InMemoryHandwritingProfileStore([this.state]);

  HandwritingCalibrationState? state;

  @override
  Future<HandwritingCalibrationState?> read() async => state;

  @override
  Future<void> write(HandwritingCalibrationState state) async {
    this.state = state;
  }
}

/// The writer's profile for the running app. Every note's AI notation reads
/// it, so it lives outside any single note.
abstract final class HandwritingCalibration {
  static final ValueNotifier<HandwritingProfile?> current =
      ValueNotifier<HandwritingProfile?>(null);
}
