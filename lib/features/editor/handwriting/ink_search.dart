import 'dart:math' as math;
import 'dart:ui';

import '../ink/ink_sample.dart';
import '../ink/stroke.dart';

/// One independently rankable piece of page ink.
///
/// Text is optional: diagrams and recognition failures remain in the index
/// and can be found with a drawn query.
class InkSearchRegion {
  InkSearchRegion({
    required Iterable<List<InkVector>> strokes,
    Iterable<String> texts = const <String>[],
    this.confidence,
    this.stickyId,
  }) : strokes = List<List<InkVector>>.unmodifiable(
         strokes
             .where((List<InkVector> stroke) => stroke.isNotEmpty)
             .map(List<InkVector>.unmodifiable),
       ),
       texts = List<String>.unmodifiable(
         texts
             .map((String text) => text.trim())
             .where((String text) => text.isNotEmpty)
             .toSet(),
       );

  final List<List<InkVector>> strokes;
  final List<String> texts;
  final double? confidence;
  final String? stickyId;

  Rect get bounds => inkBounds(strokes);
}

class InkSearchMatch {
  const InkSearchMatch({
    required this.region,
    required this.score,
    required this.textScore,
    required this.shapeScore,
  });

  final InkSearchRegion region;
  final double score;
  final double textScore;
  final double shapeScore;
}

/// Fuzzy text and query-by-sketch retrieval over small, cached stroke groups.
abstract final class InkSearch {
  static const int _grid = 28;

  static List<InkSearchMatch> find({
    required Iterable<InkSearchRegion> regions,
    String text = '',
    Iterable<List<InkVector>> strokes = const <List<InkVector>>[],
    int limit = 100,
  }) {
    final String queryText = normalizeSearchText(text);
    final List<List<InkVector>> queryInk = <List<InkVector>>[
      for (final List<InkVector> stroke in strokes)
        if (stroke.isNotEmpty) stroke,
    ];
    if (queryText.isEmpty && queryInk.isEmpty) {
      return const <InkSearchMatch>[];
    }
    final List<InkSearchMatch> matches = <InkSearchMatch>[];
    for (final InkSearchRegion region in regions) {
      double textScore = 0;
      if (queryText.isNotEmpty) {
        for (final String candidate in region.texts) {
          textScore = math.max(
            textScore,
            textSimilarity(queryText, normalizeSearchText(candidate)),
          );
        }
        // Native confidence influences rank, not whether ink is admitted.
        if (textScore > 0) {
          final double evidence = region.confidence == null
              ? 0.82
              : 0.65 + 0.35 * region.confidence!.clamp(0.0, 1.0);
          textScore *= evidence;
        }
      }
      final double shapeScore = queryInk.isEmpty || region.strokes.isEmpty
          ? 0
          : strokeSimilarity(queryInk, region.strokes);
      final double strongest = math.max(textScore, shapeScore);
      final double corroboration = math.min(textScore, shapeScore) * 0.12;
      final double score = (strongest + corroboration).clamp(0.0, 1.0);
      final double threshold = queryInk.isNotEmpty ? 0.53 : 0.48;
      if (score >= threshold) {
        matches.add(
          InkSearchMatch(
            region: region,
            score: score,
            textScore: textScore,
            shapeScore: shapeScore,
          ),
        );
      }
    }
    matches.sort((InkSearchMatch a, InkSearchMatch b) {
      final int score = b.score.compareTo(a.score);
      if (score != 0) return score;
      return a.region.bounds.top.compareTo(b.region.bounds.top);
    });
    final List<InkSearchMatch> deduplicated = <InkSearchMatch>[];
    for (final InkSearchMatch match in matches) {
      final bool duplicate = deduplicated.any((InkSearchMatch kept) {
        if (kept.region.stickyId != match.region.stickyId) return false;
        final Rect intersection = kept.region.bounds.intersect(
          match.region.bounds,
        );
        if (intersection.isEmpty) return false;
        final double smaller = math.min(
          _area(kept.region.bounds),
          _area(match.region.bounds),
        );
        return smaller > 0 && _area(intersection) / smaller > 0.82;
      });
      if (!duplicate) deduplicated.add(match);
      if (deduplicated.length >= limit) break;
    }
    return deduplicated;
  }

  static String normalizeSearchText(String text) {
    String value = text.trim().toLowerCase();
    const Map<String, String> aliases = <String, String>{
      r'\int': '∫',
      'integral': '∫',
      r'\sum': '∑',
      'summation': '∑',
      r'\sqrt': '√',
      'square root': '√',
      r'\infty': '∞',
      'infinity': '∞',
      r'\alpha': 'α',
      'alpha': 'α',
      r'\beta': 'β',
      'beta': 'β',
      r'\gamma': 'γ',
      'gamma': 'γ',
      r'\delta': 'δ',
      'delta': 'δ',
      r'\theta': 'θ',
      'theta': 'θ',
      r'\lambda': 'λ',
      'lambda': 'λ',
      r'\mu': 'μ',
      r'\pi': 'π',
      r'\sigma': 'σ',
      r'\omega': 'ω',
    };
    value = aliases[value] ?? value;
    return value
        .replaceAll(RegExp(r'[‐‑‒–—−]'), '-')
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  static double textSimilarity(String query, String candidate) {
    if (query.isEmpty || candidate.isEmpty) return 0;
    if (query == candidate) return 1;
    if (candidate.contains(query)) return query.length == 1 ? 0.78 : 0.96;
    if (query.contains(candidate)) return candidate.length == 1 ? 0.68 : 0.88;
    final int longest = math.max(query.runes.length, candidate.runes.length);
    final double edit = 1 - _distance(query, candidate) / longest;
    final double grams = _bigramDice(query, candidate);
    return (edit * 0.68 + grams * 0.32).clamp(0.0, 1.0);
  }

  static double strokeSimilarity(
    Iterable<List<InkVector>> query,
    Iterable<List<InkVector>> candidate,
  ) {
    final _InkRaster a = _raster(query);
    final _InkRaster b = _raster(candidate);
    if (a.cells.isEmpty || b.cells.isEmpty) return 0;
    double best = 0;
    for (int dy = -2; dy <= 2; dy++) {
      for (int dx = -2; dx <= 2; dx++) {
        int near = 0;
        for (final int cell in a.cells) {
          final int x = cell % _grid + dx;
          final int y = cell ~/ _grid + dy;
          if (x < 0 || y < 0 || x >= _grid || y >= _grid) continue;
          bool found = false;
          for (int oy = -1; oy <= 1 && !found; oy++) {
            for (int ox = -1; ox <= 1; ox++) {
              final int px = x + ox;
              final int py = y + oy;
              if (px >= 0 &&
                  py >= 0 &&
                  px < _grid &&
                  py < _grid &&
                  b.cells.contains(py * _grid + px)) {
                found = true;
                break;
              }
            }
          }
          if (found) near++;
        }
        final double recall = near / a.cells.length;
        int reverseNear = 0;
        for (final int cell in b.cells) {
          final int x = cell % _grid - dx;
          final int y = cell ~/ _grid - dy;
          bool found = false;
          for (int oy = -1; oy <= 1 && !found; oy++) {
            for (int ox = -1; ox <= 1; ox++) {
              final int px = x + ox;
              final int py = y + oy;
              if (px >= 0 &&
                  py >= 0 &&
                  px < _grid &&
                  py < _grid &&
                  a.cells.contains(py * _grid + px)) {
                found = true;
                break;
              }
            }
          }
          if (found) reverseNear++;
        }
        final double precision = reverseNear / b.cells.length;
        final double f1 = precision + recall == 0
            ? 0
            : 2 * precision * recall / (precision + recall);
        best = math.max(best, f1);
      }
    }
    final double aspectPenalty = math.exp(
      -0.45 * (math.log(a.aspect / b.aspect)).abs(),
    );
    final double strokePenalty = math
        .pow(
          math.min(a.strokeCount, b.strokeCount) /
              math.max(a.strokeCount, b.strokeCount),
          0.12,
        )
        .toDouble();
    return (best * aspectPenalty * strokePenalty).clamp(0.0, 1.0);
  }

  /// Joins strokes that touch or nearly touch. This makes an entire circuit
  /// or graph searchable even when it was drawn over several pauses.
  static List<InkSearchRegion> connectedRegions(
    Iterable<Stroke> source, {
    String? stickyId,
    double gap = 10,
  }) {
    final List<Stroke> strokes = source
        .where((Stroke stroke) => !stroke.style.isHighlighter)
        .toList();
    if (strokes.isEmpty) return const <InkSearchRegion>[];
    final List<int> parent = List<int>.generate(strokes.length, (int i) => i);
    int root(int value) {
      while (parent[value] != value) {
        parent[value] = parent[parent[value]];
        value = parent[value];
      }
      return value;
    }

    void join(int a, int b) {
      a = root(a);
      b = root(b);
      if (a != b) parent[b] = a;
    }

    for (int i = 0; i < strokes.length; i++) {
      final Rect a = strokes[i].bounds.inflate(gap);
      for (int j = i + 1; j < strokes.length; j++) {
        if (!a.overlaps(strokes[j].bounds.inflate(gap))) continue;
        if (_strokeDistance(strokes[i].points, strokes[j].points) <= gap) {
          join(i, j);
        }
      }
    }
    final Map<int, List<Stroke>> groups = <int, List<Stroke>>{};
    for (int i = 0; i < strokes.length; i++) {
      groups.putIfAbsent(root(i), () => <Stroke>[]).add(strokes[i]);
    }
    return <InkSearchRegion>[
      for (final List<Stroke> group in groups.values)
        InkSearchRegion(
          strokes: <List<InkVector>>[
            for (final Stroke stroke in group) stroke.points,
          ],
          stickyId: stickyId,
        ),
    ];
  }

  /// Builds short, same-line windows so a phrase is compared as a phrase,
  /// while unknown symbols between recognized words remain part of its ink.
  static List<InkSearchRegion> lineSequences(
    Iterable<InkSearchRegion> source, {
    int maxTokens = 8,
  }) {
    final List<InkSearchRegion> regions =
        source
            .where((InkSearchRegion region) => region.texts.isNotEmpty)
            .toList()
          ..sort((InkSearchRegion a, InkSearchRegion b) {
            final double height = math.max(a.bounds.height, b.bounds.height);
            if ((a.bounds.center.dy - b.bounds.center.dy).abs() <=
                height * 0.6) {
              return a.bounds.left.compareTo(b.bounds.left);
            }
            return a.bounds.top.compareTo(b.bounds.top);
          });
    final List<InkSearchRegion> sequences = <InkSearchRegion>[];
    for (int start = 0; start < regions.length; start++) {
      final List<InkSearchRegion> run = <InkSearchRegion>[regions[start]];
      for (
        int end = start + 1;
        end < regions.length && run.length < maxTokens;
        end++
      ) {
        final InkSearchRegion previous = run.last;
        final InkSearchRegion next = regions[end];
        if (previous.stickyId != next.stickyId) break;
        final double height = math.max(
          math.max(previous.bounds.height, next.bounds.height),
          1,
        );
        if ((previous.bounds.center.dy - next.bounds.center.dy).abs() >
                height * 0.7 ||
            next.bounds.left - previous.bounds.right > height * 3.5) {
          break;
        }
        run.add(next);
        sequences.add(
          InkSearchRegion(
            strokes: <List<InkVector>>[
              for (final InkSearchRegion region in run) ...region.strokes,
            ],
            texts: <String>[
              run.map((InkSearchRegion region) => region.texts.first).join(' '),
            ],
            confidence: run
                .map((InkSearchRegion region) => region.confidence)
                .whereType<double>()
                .fold<double?>(
                  null,
                  (double? value, double confidence) =>
                      value == null ? confidence : math.min(value, confidence),
                ),
            stickyId: run.first.stickyId,
          ),
        );
      }
    }
    return sequences;
  }

  static _InkRaster _raster(Iterable<List<InkVector>> source) {
    final List<List<InkVector>> strokes = source
        .where((List<InkVector> stroke) => stroke.isNotEmpty)
        .toList();
    final Rect bounds = inkBounds(strokes);
    if (bounds.isEmpty && strokes.every((List<InkVector> s) => s.length < 2)) {
      return const _InkRaster(<int>{}, 1, 0);
    }
    final double width = math.max(bounds.width, 1e-6);
    final double height = math.max(bounds.height, 1e-6);
    final double longest = math.max(width, height);
    final double padX = (longest - width) / 2;
    final double padY = (longest - height) / 2;
    int cell(InkVector point) {
      final int x = (((point.x - bounds.left + padX) / longest) * (_grid - 1))
          .round()
          .clamp(0, _grid - 1);
      final int y = (((point.y - bounds.top + padY) / longest) * (_grid - 1))
          .round()
          .clamp(0, _grid - 1);
      return y * _grid + x;
    }

    final Set<int> cells = <int>{};
    for (final List<InkVector> stroke in strokes) {
      cells.add(cell(stroke.first));
      for (int i = 1; i < stroke.length; i++) {
        final InkVector a = stroke[i - 1];
        final InkVector b = stroke[i];
        final int steps = math.max(
          1,
          ((b - a).length / longest * _grid * 2).ceil(),
        );
        for (int step = 1; step <= steps; step++) {
          cells.add(cell(a + (b - a) * (step / steps)));
        }
      }
    }
    return _InkRaster(cells, width / height, strokes.length);
  }

  static double _strokeDistance(List<InkVector> a, List<InkVector> b) {
    double best = double.infinity;
    final int stepA = math.max(1, a.length ~/ 32);
    final int stepB = math.max(1, b.length ~/ 32);
    for (int i = 0; i < a.length; i += stepA) {
      for (int j = 0; j < b.length; j += stepB) {
        best = math.min(best, (a[i] - b[j]).length);
      }
    }
    return best;
  }

  static int _distance(String a, String b) {
    final List<int> left = a.runes.toList();
    final List<int> right = b.runes.toList();
    List<int> previous = List<int>.generate(right.length + 1, (int i) => i);
    for (int i = 0; i < left.length; i++) {
      final List<int> current = List<int>.filled(right.length + 1, 0)
        ..[0] = i + 1;
      for (int j = 0; j < right.length; j++) {
        current[j + 1] = math.min(
          math.min(current[j] + 1, previous[j + 1] + 1),
          previous[j] + (left[i] == right[j] ? 0 : 1),
        );
      }
      previous = current;
    }
    return previous.last;
  }

  static double _bigramDice(String a, String b) {
    Set<String> grams(String value) {
      final List<int> runes = value.runes.toList();
      if (runes.length < 2) return <String>{value};
      return <String>{
        for (int i = 1; i < runes.length; i++)
          String.fromCharCodes(<int>[runes[i - 1], runes[i]]),
      };
    }

    final Set<String> left = grams(a);
    final Set<String> right = grams(b);
    return 2 * left.intersection(right).length / (left.length + right.length);
  }

  static double _area(Rect rect) => rect.width * rect.height;
}

Rect inkBounds(Iterable<List<InkVector>> strokes) {
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
  return left.isFinite ? Rect.fromLTRB(left, top, right, bottom) : Rect.zero;
}

class _InkRaster {
  const _InkRaster(this.cells, this.aspect, this.strokeCount);

  final Set<int> cells;
  final double aspect;
  final int strokeCount;
}
