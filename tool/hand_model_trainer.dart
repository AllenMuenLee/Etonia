// Learning a HandModel from many writers' letters, offline.
//
// Each letter is laid out by arc length in pen order (see HandModel), ways
// of writing it with different stroke counts get slots of their own, and a
// linear space is fitted to the hands with the missing slots filled in
// iteratively (PCA with missing data, after Balashova et al. 2019 and
// Roweis' EM-PCA).

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:greatnote/features/editor/handwriting/glyph_builder.dart';
import 'package:greatnote/features/editor/handwriting/hand_glyphs.dart';
import 'package:greatnote/features/editor/handwriting/hand_model.dart';
import 'package:greatnote/features/editor/handwriting/handwriting_calibration.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';

import 'uji_data.dart';

/// One writer's letters, upright, in the font's grid, each from x = 0.
typedef Hand = Map<String, UjiStrokes>;

/// The characters a model learns: those the builder may build, and those
/// it reads them from.
const String modelCharacters =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0';

/// [samples] read through the calibration exactly as the app reads a
/// writer's pad, then stood upright: the key letters from the key page
/// alone, as the builder receives them, and every other letter from all the
/// pages, at the same size. Null when the key page cannot be read.
Hand? handOf(Map<String, UjiStrokes> samples) {
  if (!keyLetters.split('').every(samples.containsKey)) return null;
  final UjiScale scale = ujiScale(samples);
  final HandGlyphs? key = readCustomFont(<UjiStrokes>[
    calibrationPage(samples, scale),
  ]).style?.glyphs;
  final HandGlyphs? all = readCustomFont(<UjiStrokes>[
    for (int page = 0; page < customFontPages.length; page++)
      calibrationPage(samples, scale, page: page),
  ]).style?.glyphs;
  if (key == null || all == null) return null;
  final double slant = key.builtSlant;
  // All the pages' capitals set the size there; the key page's three set
  // it on their own. Put the rest at the key page's size.
  double capital(HandGlyphs glyphs, String char) =>
      10 -
      glyphs[char]!.strokes
          .expand((List<InkVector> s) => s)
          .map((InkVector p) => p.y)
          .reduce(math.min);
  final double factor =
      median(<double>[
        for (final String c in 'AER'.split('')) capital(key, c),
      ]) /
      median(<double>[for (final String c in 'AER'.split('')) capital(all, c)]);
  final Hand hand = <String, UjiStrokes>{};
  for (final String char in modelCharacters.split('')) {
    final HandGlyph? glyph = keyLetters.contains(char) ? key[char] : all[char];
    if (glyph == null || glyph.strokes.isEmpty) continue;
    final UjiStrokes strokes = keyLetters.contains(char)
        ? glyph.strokes
        : <List<InkVector>>[
            for (final List<InkVector> stroke in glyph.strokes)
              <InkVector>[
                for (final InkVector p in stroke)
                  InkVector(p.x * factor, 10 + (p.y - 10) * factor),
              ],
          ];
    hand[char] = uprightLetter(strokes, slant: slant);
  }
  return hand;
}

/// A model of [hands], with [dimensions] numbers to a hand and about
/// [points] points to a letter. A way of writing a letter needs
/// [minSamples] hands that write it so to get a slot.
///
/// With [writers], which writer each hand is (a writer's hands are kept
/// together), each letter's [HandModel.fallbacks] is chosen too: models
/// are learned from some of the writers and the builder run with each on
/// the rest, and each letter takes the fallback that matched those
/// writers' own letters most often.
HandModel trainHandModel(
  List<Hand> hands, {
  List<int>? writers,
  int dimensions = 8,
  int points = 32,
  int minSamples = 6,
}) {
  HandModel fit(List<Hand> some) => _fit(
    some,
    dimensions: dimensions,
    points: points,
    minSamples: minSamples,
  );
  final HandModel model = fit(hands);
  if (writers == null) return model;
  return HandModel(
    dimensions: model.dimensions,
    noise: model.noise,
    slots: model.slots,
    writers: model.writers,
    fallbacks: _chooseFallbacks(hands, writers, fit),
  );
}

/// The fallbacks a letter may take: always the prediction, the builder's
/// letter unless it strays, and always the builder's letter. On a tie the
/// later, which keeps more of the writer's own lines, wins.
const List<double> _fallbackChoices = <double>[
  0,
  HandModel.defaultFallback,
  1e9,
];

const int _innerFolds = 5;

Map<String, double> _chooseFallbacks(
  List<Hand> hands,
  List<int> writers,
  HandModel Function(List<Hand> hands) fit,
) {
  final List<int> distinct = writers.toSet().toList()..sort();
  final Map<String, List<int>> matched = <String, List<int>>{};
  final HandModel? override = HandModel.debugOverride;
  final double? fallback = HandModel.debugFallback;
  final bool disabled = HandModel.debugDisabled;
  HandModel.debugDisabled = false;
  for (int fold = 0; fold < _innerFolds; fold++) {
    final Set<int> test = <int>{
      for (int i = fold; i < distinct.length; i += _innerFolds) distinct[i],
    };
    HandModel.debugOverride = fit(<Hand>[
      for (int h = 0; h < hands.length; h++)
        if (!test.contains(writers[h])) hands[h],
    ]);
    for (int h = 0; h < hands.length; h++) {
      if (!test.contains(writers[h])) continue;
      final Hand hand = hands[h];
      // The key letters as the builder receives them; upright already.
      final Map<String, HandGlyph> written = <String, HandGlyph>{
        for (final String char in keyLetters.split(''))
          if (hand[char] case final UjiStrokes strokes)
            char: HandGlyph(ujiBox(strokes).right, strokes),
      };
      for (int k = 0; k < _fallbackChoices.length; k++) {
        HandModel.debugFallback = _fallbackChoices[k];
        final Map<String, HandGlyph> built = buildMissingGlyphs(
          written,
          slant: 0,
        );
        for (final MapEntry<String, HandGlyph> e in built.entries) {
          final UjiStrokes? actual = hand[e.key];
          if (actual == null) continue;
          if (shapeDistance(e.value.strokes, actual) <= 0.16) {
            (matched[e.key] ??= List<int>.filled(
              _fallbackChoices.length,
              0,
            ))[k]++;
          }
        }
      }
    }
  }
  HandModel.debugOverride = override;
  HandModel.debugFallback = fallback;
  HandModel.debugDisabled = disabled;
  return <String, double>{
    for (final MapEntry<String, List<int>> e in matched.entries)
      e.key: () {
        int best = _fallbackChoices.length - 1;
        for (int k = _fallbackChoices.length - 2; k >= 0; k--) {
          if (e.value[k] > e.value[best]) best = k;
        }
        return _fallbackChoices[best];
      }(),
  };
}

HandModel _fit(
  List<Hand> hands, {
  required int dimensions,
  required int points,
  required int minSamples,
  int iterations = 40,
}) {
  final int n = hands.length;
  final List<HandSlot> slotShapes = <HandSlot>[];
  // Each slot's laid-out letters, by hand; null where a hand wrote the
  // letter another way, or not at all.
  final List<List<Float64List?>> columns = <List<Float64List?>>[];
  final List<Map<String, int>> ways = <Map<String, int>>[
    for (int i = 0; i < n; i++) <String, int>{},
  ];

  for (final String char in modelCharacters.split('')) {
    final Map<int, List<int>> byStrokes = <int, List<int>>{};
    for (int h = 0; h < n; h++) {
      final UjiStrokes? strokes = hands[h][char];
      if (strokes == null || strokes.isEmpty || strokes.length > 6) continue;
      (byStrokes[strokes.length] ??= <int>[]).add(h);
    }
    for (final MapEntry<int, List<int>> group in byStrokes.entries) {
      if (group.value.length < minSamples) continue;
      final List<UjiStrokes> letters = <UjiStrokes>[
        for (final int h in group.value) hands[h][char]!,
      ];
      final List<int> counts = _counts(letters, points);
      final Float64List mean = _layoutMean(letters, counts);
      final List<Float64List?> column = List<Float64List?>.filled(n, null);
      for (final int h in group.value) {
        column[h] = alignToSlot(hands[h][char]!, counts, mean).$1;
        ways[h][char] = slotShapes.length;
      }
      slotShapes.add(
        HandSlot(
          char: char,
          counts: counts,
          samples: group.value.length,
          mean: mean,
          basis: Float64List(0),
        ),
      );
      columns.add(column);
    }
  }

  // The hands as rows of one matrix, slot after slot.
  final List<int> offsets = <int>[];
  int width = 0;
  for (final HandSlot slot in slotShapes) {
    offsets.add(width);
    width += slot.mean.length;
  }
  final List<Float64List> filled = <Float64List>[
    for (int h = 0; h < n; h++) Float64List(width),
  ];
  final List<Uint8List> seen = <Uint8List>[
    for (int h = 0; h < n; h++) Uint8List(width),
  ];
  for (int s = 0; s < slotShapes.length; s++) {
    for (int h = 0; h < n; h++) {
      final Float64List? values = columns[s][h];
      final int at = offsets[s];
      if (values == null) {
        filled[h].setAll(at, slotShapes[s].mean);
      } else {
        filled[h].setAll(at, values);
        seen[h].fillRange(at, at + values.length, 1);
      }
    }
  }

  final int q = math.min(dimensions, n - 1);
  late Float64List mu;
  late List<Float64List> scores; // n × q, unit variance
  late List<Float64List> loadings; // width × q
  for (int round = 0; round < iterations; round++) {
    mu = Float64List(width);
    for (final Float64List row in filled) {
      for (int d = 0; d < width; d++) {
        mu[d] += row[d] / n;
      }
    }
    final List<Float64List> centred = <Float64List>[
      for (final Float64List row in filled)
        Float64List.fromList(<double>[
          for (int d = 0; d < width; d++) row[d] - mu[d],
        ]),
    ];
    final Float64List gram = Float64List(n * n);
    for (int i = 0; i < n; i++) {
      for (int j = i; j < n; j++) {
        double sum = 0;
        final Float64List a = centred[i];
        final Float64List b = centred[j];
        for (int d = 0; d < width; d++) {
          sum += a[d] * b[d];
        }
        gram[i * n + j] = sum;
        gram[j * n + i] = sum;
      }
    }
    final (Float64List values, List<Float64List> vectors) = _eigen(gram, n);
    final List<int> top = List<int>.generate(n, (int i) => i)
      ..sort((int a, int b) => values[b].compareTo(values[a]));
    scores = <Float64List>[for (int h = 0; h < n; h++) Float64List(q)];
    loadings = <Float64List>[for (int d = 0; d < width; d++) Float64List(q)];
    for (int k = 0; k < q; k++) {
      final Float64List u = vectors[top[k]];
      for (int h = 0; h < n; h++) {
        scores[h][k] = u[h] * math.sqrt(n.toDouble());
      }
      for (int d = 0; d < width; d++) {
        double sum = 0;
        for (int h = 0; h < n; h++) {
          sum += centred[h][d] * u[h];
        }
        loadings[d][k] = sum / math.sqrt(n.toDouble());
      }
    }
    // What is missing, as the space would have it.
    for (int h = 0; h < n; h++) {
      for (int d = 0; d < width; d++) {
        if (seen[h][d] == 1) continue;
        double value = mu[d];
        for (int k = 0; k < q; k++) {
          value += loadings[d][k] * scores[h][k];
        }
        filled[h][d] = value;
      }
    }
  }

  double residual = 0;
  int observed = 0;
  for (int h = 0; h < n; h++) {
    for (int d = 0; d < width; d++) {
      if (seen[h][d] == 0) continue;
      double value = mu[d];
      for (int k = 0; k < q; k++) {
        value += loadings[d][k] * scores[h][k];
      }
      residual += (filled[h][d] - value) * (filled[h][d] - value);
      observed++;
    }
  }

  return HandModel(
    dimensions: q,
    noise: residual / math.max(observed, 1),
    slots: <HandSlot>[
      for (int s = 0; s < slotShapes.length; s++)
        HandSlot(
          char: slotShapes[s].char,
          counts: slotShapes[s].counts,
          samples: slotShapes[s].samples,
          mean: Float64List.sublistView(
            mu,
            offsets[s],
            offsets[s] + slotShapes[s].mean.length,
          ),
          basis: Float64List.fromList(<double>[
            for (
              int d = offsets[s];
              d < offsets[s] + slotShapes[s].mean.length;
              d++
            )
              ...loadings[d],
          ]),
        ),
    ],
    writers: <HandWriter>[
      for (int h = 0; h < n; h++) HandWriter(scores[h], ways[h]),
    ],
  );
}

/// Points per stroke for [letters], all with the same number of strokes:
/// about [points] in all, shared by the strokes' typical lengths in pen
/// order, at least three each.
List<int> _counts(List<UjiStrokes> letters, int points) {
  final int strokes = letters.first.length;
  final List<double> lengths = List<double>.filled(strokes, 0);
  for (final UjiStrokes letter in letters) {
    for (int s = 0; s < strokes; s++) {
      lengths[s] += _length(letter[s]) / letters.length;
    }
  }
  final double total = lengths.fold(0, (double a, double b) => a + b);
  return <int>[
    for (final double length in lengths)
      math.max(3, (points * length / math.max(total, 1e-9)).round()),
  ];
}

/// The average layout of [letters]: begun from the most central one in pen
/// order, then each laid out against the average and averaged again.
Float64List _layoutMean(List<UjiStrokes> letters, List<int> counts) {
  Float64List penOrder(UjiStrokes letter) => Float64List.fromList(<double>[
    for (int s = 0; s < counts.length; s++)
      for (final InkVector p in resampleCount(
        letter[s],
        counts[s],
      )) ...<double>[p.x, p.y],
  ]);

  final List<UjiStrokes> pool = letters.take(40).toList();
  Float64List mean = penOrder(pool.first);
  double best = double.infinity;
  for (final UjiStrokes candidate in pool) {
    final Float64List layout = penOrder(candidate);
    double sum = 0;
    for (final UjiStrokes other in pool) {
      sum += alignToSlot(other, counts, layout).$2;
    }
    if (sum < best) {
      best = sum;
      mean = layout;
    }
  }
  for (int round = 0; round < 4; round++) {
    final Float64List next = Float64List(mean.length);
    for (final UjiStrokes letter in letters) {
      final Float64List layout = alignToSlot(letter, counts, mean).$1;
      for (int d = 0; d < next.length; d++) {
        next[d] += layout[d] / letters.length;
      }
    }
    mean = next;
  }
  return mean;
}

double _length(List<InkVector> stroke) {
  double sum = 0;
  for (int i = 1; i < stroke.length; i++) {
    sum += (stroke[i] - stroke[i - 1]).length;
  }
  return sum;
}

/// Eigenvalues and eigenvectors of the symmetric [n] by [n] matrix [a]
/// (row-major), by cyclic Jacobi rotations.
(Float64List, List<Float64List>) _eigen(Float64List a, int n) {
  final Float64List m = Float64List.fromList(a);
  final Float64List v = Float64List(n * n);
  for (int i = 0; i < n; i++) {
    v[i * n + i] = 1;
  }
  double size = 0;
  for (int i = 0; i < n * n; i++) {
    size += m[i] * m[i];
  }
  for (int sweep = 0; sweep < 60; sweep++) {
    double off = 0;
    for (int i = 0; i < n; i++) {
      for (int j = i + 1; j < n; j++) {
        off += m[i * n + j] * m[i * n + j];
      }
    }
    if (off <= 1e-22 * size) break;
    for (int p = 0; p < n; p++) {
      for (int q = p + 1; q < n; q++) {
        final double apq = m[p * n + q];
        if (apq.abs() < 1e-300) continue;
        final double app = m[p * n + p];
        final double aqq = m[q * n + q];
        final double theta = (aqq - app) / (2 * apq);
        final double t =
            (theta >= 0 ? 1 : -1) /
            (theta.abs() + math.sqrt(theta * theta + 1));
        final double c = 1 / math.sqrt(t * t + 1);
        final double s = t * c;
        for (int k = 0; k < n; k++) {
          final double mkp = m[k * n + p];
          final double mkq = m[k * n + q];
          m[k * n + p] = c * mkp - s * mkq;
          m[k * n + q] = s * mkp + c * mkq;
        }
        for (int k = 0; k < n; k++) {
          final double mpk = m[p * n + k];
          final double mqk = m[q * n + k];
          m[p * n + k] = c * mpk - s * mqk;
          m[q * n + k] = s * mpk + c * mqk;
        }
        for (int k = 0; k < n; k++) {
          final double vkp = v[k * n + p];
          final double vkq = v[k * n + q];
          v[k * n + p] = c * vkp - s * vkq;
          v[k * n + q] = s * vkp + c * vkq;
        }
      }
    }
  }
  return (
    Float64List.fromList(<double>[for (int i = 0; i < n; i++) m[i * n + i]]),
    <Float64List>[
      for (int k = 0; k < n; k++)
        Float64List.fromList(<double>[
          for (int i = 0; i < n; i++) v[i * n + k],
        ]),
    ],
  );
}
