import 'dart:math' as math;

/// Local hints for reading the next handwritten words. Conversation turns
/// stay separate so a phrase cannot accidentally span two speakers.
class HandwritingContext {
  HandwritingContext({
    String draft = '',
    Iterable<String> recentMessages = const [],
  }) : draft = _tail(draft, 1000),
       recentMessages = List<String>.unmodifiable(
         recentMessages
             .toList()
             .reversed
             .take(6)
             .map((text) => _tail(text, 2000)),
       );

  final String draft;
  final List<String> recentMessages;

  /// A space matters: AI canvas batches are appended as separate words.
  String get preContext =>
      draft.trimRight().isEmpty ? '' : _tail('${draft.trimRight()} ', 20);

  List<String> get customWords => <String>{
    ..._words(draft).reversed,
    for (final text in recentMessages) ..._words(text).reversed,
  }.where((word) => word.length > 2 && word.length <= 40).take(64).toList();

  static String _tail(String text, int length) =>
      text.length <= length ? text : text.substring(text.length - length);
}

class HandwritingCandidate {
  const HandwritingCandidate(this.text, {this.confidence});

  final String text;

  /// Normalized confidence, when provided by the recognizer (Vision).
  /// ML Kit text candidates have rank, not comparable probabilities.
  final double? confidence;
}

final RegExp _wordPattern = RegExp(
  r"[\p{L}\p{M}]+(?:['’][\p{L}\p{M}]+)*",
  unicode: true,
);

List<String> _words(String text) => _wordPattern
    .allMatches(text.toLowerCase())
    .map((match) => match.group(0)!)
    .toList();

/// Ranks actual readings of the ink, never generates unwritten words.
/// Native recognition rank and letter similarity remain the baseline;
/// nearby vocabulary and observed phrases can break an ambiguous tie.
class HandwritingPrediction {
  const HandwritingPrediction();

  String choose(
    List<HandwritingCandidate> candidates,
    HandwritingContext context,
  ) {
    final readings = candidates
        .where((c) => c.text.trim().isNotEmpty)
        .take(5)
        .toList();
    if (readings.isEmpty) return '';
    final first = readings.first;
    final original = first.text.trim();
    // Bound work for unusually large native responses.
    if (original.length > 512) return original;
    final originalWords = _words(original);
    final corpus = <List<String>>[
      _words(context.draft),
      for (final message in context.recentMessages) _words(message),
    ];
    final prefix = _words(context.draft);
    String best = original;
    double bestScore = _contextScore(originalWords, prefix, corpus);
    for (int index = 1; index < readings.length; index++) {
      final candidate = readings[index];
      final text = candidate.text.trim();
      if (text.length > 512) continue;
      final words = _words(text);
      if (!_similar(original, text, originalWords, words)) continue;
      final confidenceGap =
          first.confidence != null && candidate.confidence != null
          ? math.max(0.0, first.confidence! - candidate.confidence!)
          : 0.0;
      if (confidenceGap > 0.15) continue;
      final distance =
          _distance(original.toLowerCase(), text.toLowerCase()) /
          math.max(original.length, text.length);
      final score =
          _contextScore(words, prefix, corpus) -
          0.12 * index -
          0.5 * distance -
          2 * confidenceGap;
      if (score > bestScore + 0.02) {
        best = text;
        bestScore = score;
      }
    }
    return best;
  }

  static bool _similar(
    String first,
    String next,
    List<String> a,
    List<String> b,
  ) {
    if (a.isEmpty || a.length != b.length) return false;
    // Numbers, operators, punctuation and word boundaries are not guesses.
    String structure(String text) => text
        .toLowerCase()
        .replaceAll(_wordPattern, '#')
        .replaceAll(RegExp(r'\s+'), '');
    if (structure(first) != structure(next)) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] == b[i]) continue;
      final length = math.min(a[i].length, b[i].length);
      if (length <= 1 || _distance(a[i], b[i]) > (length < 5 ? 1 : 2)) {
        return false;
      }
    }
    return true;
  }

  static double _contextScore(
    List<String> words,
    List<String> prefix,
    List<List<String>> corpus,
  ) {
    if (words.isEmpty) return 0;
    final sequence = <String>[...prefix, ...words];
    double score = 0;
    for (int i = prefix.length; i < sequence.length; i++) {
      double evidence = 0;
      for (int source = 0; source < corpus.length; source++) {
        final tokens = corpus[source];
        for (int j = 0; j < tokens.length; j++) {
          if (tokens[j] != sequence[i]) continue;
          evidence = math.max(evidence, source == 0 ? 0.30 : 0.26);
          if (i > 0 && j > 0 && tokens[j - 1] == sequence[i - 1]) {
            evidence = math.max(evidence, 0.48);
            if (i > 1 && j > 1 && tokens[j - 2] == sequence[i - 2]) {
              evidence = 0.85;
            }
          }
          // Right-hand words within this batch also disambiguate a reading.
          if (i + 1 < sequence.length &&
              j + 1 < tokens.length &&
              tokens[j + 1] == sequence[i + 1]) {
            evidence = math.max(evidence, 0.48);
          }
        }
      }
      score += evidence;
    }
    return score;
  }

  static double _distance(String a, String b) {
    // Joined pen strokes often make two letters look like one. These
    // still have to be alternatives returned by the native recognizer.
    const joinedLetters = [('rn', 'm'), ('cl', 'd'), ('vv', 'w')];
    var previous = List<double>.generate(b.length + 1, (i) => i.toDouble());
    List<double>? beforePrevious;
    for (int i = 0; i < a.length; i++) {
      final current = List<double>.filled(b.length + 1, 0)..[0] = i + 1.0;
      for (int j = 0; j < b.length; j++) {
        current[j + 1] = math.min(
          math.min(current[j] + 1, previous[j + 1] + 1),
          previous[j] + (a[i] == b[j] ? 0 : 1),
        );
        for (final (joined, single) in joinedLetters) {
          if (i > 0 && a.substring(i - 1, i + 1) == joined && b[j] == single) {
            current[j + 1] = math.min(current[j + 1], beforePrevious![j] + 0.5);
          }
          if (j > 0 && b.substring(j - 1, j + 1) == joined && a[i] == single) {
            current[j + 1] = math.min(current[j + 1], previous[j - 1] + 0.5);
          }
        }
      }
      beforePrevious = previous;
      previous = current;
    }
    return previous.last;
  }
}
