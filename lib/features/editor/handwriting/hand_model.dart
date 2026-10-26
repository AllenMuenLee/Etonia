import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../ink/ink_sample.dart';
import 'hand_model_data.dart';

/// A letter's strokes, each a list of points.
typedef HandStrokes = List<List<InkVector>>;

/// How real writers' letters vary together, learned from many hands: from
/// the letters one writer wrote it predicts the shape of those they did
/// not.
///
/// Every letter is laid out the same way for every writer (a universal
/// parameterization, after Campbell & Kautz, "Learning a Manifold of
/// Fonts", 2014): its strokes in pen order, each resampled to a fixed
/// number of points by arc length, so point i is the same place on the
/// letter in every hand. A letter written in different ways (an f of one
/// stroke or two) has a [HandSlot] for each way, and a writer's way leaves
/// the others missing. Written letters are points in a low-dimensional
/// linear space, learned with missing data allowed (as Balashova et al.,
/// "Learning a Stroke-Based Representation for Fonts", 2019, found works
/// better than non-linear models here). Completing a hand is then one small
/// regularized least-squares solve and a matrix product.
///
/// Coordinates are the font's grid, upright (slant taken out), each letter
/// from x = 0: see [uprightLetter].
@immutable
class HandModel {
  const HandModel({
    required this.dimensions,
    required this.noise,
    required this.slots,
    required this.writers,
    this.fallbacks = const <String, double>{},
  });

  /// How far, letter by letter, a letter the builder makes from the
  /// writer's own lines may lie from the predicted one and still be
  /// written (see the builder): 0 writes the prediction always, a huge
  /// value keeps the builder's letter always. Chosen when the model is
  /// learned, by which does better on writers it was not learned from:
  /// letters built from a close written relative (an m from the writer's n)
  /// keep their build, those with none (a j, an x) take the prediction.
  final Map<String, double> fallbacks;

  /// Between the two, for letters with no choice made.
  static const double defaultFallback = 0.18;

  /// [fallbacks] for [char].
  double fallbackFor(String char) => fallbacks[char] ?? defaultFallback;

  /// The space's dimensions: how many numbers describe a hand.
  final int dimensions;

  /// The variance, per coordinate, the space does not explain: how far a
  /// writer's letters wander from what it predicts. It weighs what was
  /// written against the average hand.
  final double noise;

  final List<HandSlot> slots;

  /// The hands the model was learned from: where each lies in the space,
  /// and which way it writes each letter. A letter not written is written
  /// the way the nearest of these hands writes it.
  final List<HandWriter> writers;

  /// The model learned from the UJI Pen Characters v2 writers, decoded on
  /// first use; null when none is bundled.
  static HandModel? get bundled => _bundled;
  static final HandModel? _bundled = handModelData.isEmpty
      ? null
      : HandModel.decode(handModelData);

  /// A model to use in place of [bundled], for evaluating models learned
  /// from part of the writers on the rest (by the tools, not the app).
  /// Null leaves [bundled] in use.
  static HandModel? debugOverride;

  /// Set to turn the model off altogether, as when measuring what the
  /// builder does alone.
  static bool debugDisabled = false;

  /// One fallback for every letter in place of [fallbacks], as when the
  /// tools try settings; null uses [fallbacks].
  static double? debugFallback;

  /// The model in use, if any.
  static HandModel? get active =>
      debugDisabled ? null : (debugOverride ?? bundled);

  /// Where [written] puts its writer in the space: the most likely hand
  /// given the letters they wrote. [written] holds upright letters
  /// ([uprightLetter]). Null when none of them can be read against the
  /// model.
  HandEstimate? estimate(Map<String, HandStrokes> written) {
    final int q = dimensions;
    // Normal equations of the regularized fit: (WᵀW + σ²I) z = Wᵀ(y − μ),
    // over the coordinates of the letters written.
    final Float64List normal = Float64List(q * q);
    final Float64List right = Float64List(q);
    final Set<String> read = <String>{};
    final List<(HandSlot, Float64List)> matches = <(HandSlot, Float64List)>[];
    for (final MapEntry<String, HandStrokes> entry in written.entries) {
      final (HandSlot, Float64List)? match = _match(entry.key, entry.value);
      if (match == null) continue;
      final (HandSlot slot, Float64List y) = match;
      read.add(entry.key);
      matches.add(match);
      for (int d = 0; d < y.length; d++) {
        final double residual = y[d] - slot.mean[d];
        final int row = d * q;
        for (int i = 0; i < q; i++) {
          final double wi = slot.basis[row + i];
          right[i] += wi * residual;
          for (int j = i; j < q; j++) {
            normal[i * q + j] += wi * slot.basis[row + j];
          }
        }
      }
    }
    if (read.isEmpty) return null;
    for (int i = 0; i < q; i++) {
      normal[i * q + i] += noise;
      for (int j = 0; j < i; j++) {
        normal[i * q + j] = normal[j * q + i];
      }
    }
    final Float64List position = _solve(normal, right, q);
    // How far the letters written lie from the hand found for them.
    double misfit = 0;
    int coordinates = 0;
    for (final (HandSlot slot, Float64List y) in matches) {
      for (int d = 0; d < y.length; d++) {
        double predicted = slot.mean[d];
        for (int i = 0; i < q; i++) {
          predicted += slot.basis[d * q + i] * position[i];
        }
        misfit += (y[d] - predicted) * (y[d] - predicted);
        coordinates++;
      }
    }
    return HandEstimate(position, read, misfit / coordinates);
  }

  /// Whether [estimate] can be trusted to predict letters: read from most
  /// of the key letters, and a hand like those the model was learned from,
  /// its letters lying no further from the hand found than theirs did. A
  /// hand of a few letters, or unlike any it learned, says too little; the
  /// builder's letters, made from the writer's own lines, are kept.
  bool trusts(HandEstimate estimate) =>
      estimate.read.length >= minimumLetters &&
      estimate.misfit <= misfitLimit * noise;

  /// How many letters an estimate must be read from to be trusted.
  static const int minimumLetters = 10;

  /// How far, as a multiple of [noise], a hand's letters may lie from the
  /// hand found for them, and the estimate still be trusted. Writers the
  /// bundled model never saw lie 0.6 to 4.3 times it, half under 1.4.
  static const double misfitLimit = 5;

  /// [char] as the hand at [at] writes it, upright, from x = 0; null when
  /// the model has no such letter.
  HandStrokes? letter(String char, HandEstimate at) {
    final HandSlot? slot = _slotFor(char, at.position);
    if (slot == null) return null;
    final int q = dimensions;
    final HandStrokes strokes = <List<InkVector>>[];
    int d = 0;
    for (final int count in slot.counts) {
      final List<InkVector> stroke = <InkVector>[];
      for (int p = 0; p < count; p++) {
        double x = slot.mean[d];
        double y = slot.mean[d + 1];
        for (int i = 0; i < q; i++) {
          x += slot.basis[d * q + i] * at.position[i];
          y += slot.basis[(d + 1) * q + i] * at.position[i];
        }
        stroke.add(InkVector(x, y));
        d += 2;
      }
      strokes.add(stroke);
    }
    return strokes;
  }

  /// The way of writing [char] that the hands nearest [position] use most.
  HandSlot? _slotFor(String char, Float64List position) {
    final List<int> ways = <int>[
      for (int s = 0; s < slots.length; s++)
        if (slots[s].char == char) s,
    ];
    if (ways.isEmpty) return null;
    if (ways.length == 1) return slots[ways.single];
    final List<(double, int)> near = <(double, int)>[
      for (final HandWriter writer in writers)
        if (writer.ways[char] case final int way)
          (writer.distanceTo(position), way),
    ]..sort(((double, int) a, (double, int) b) => a.$1.compareTo(b.$1));
    final Map<int, double> votes = <int, double>{};
    for (final (double distance, int way) in near.take(_neighbours)) {
      votes[way] = (votes[way] ?? 0) + 1 / (distance + 0.1);
    }
    if (votes.isEmpty) {
      return ways
          .map((int s) => slots[s])
          .reduce((HandSlot a, HandSlot b) => a.samples >= b.samples ? a : b);
    }
    final int best = votes.entries
        .reduce(
          (MapEntry<int, double> a, MapEntry<int, double> b) =>
              a.value >= b.value ? a : b,
        )
        .key;
    return slots[best];
  }

  /// The slot [strokes] are a way of writing [char] in, with them laid out
  /// as it lays letters out: the one they lie nearest of those with as
  /// many strokes.
  (HandSlot, Float64List)? _match(String char, HandStrokes strokes) {
    (HandSlot, Float64List)? best;
    double bestError = double.infinity;
    for (final HandSlot slot in slots) {
      if (slot.char != char || slot.counts.length != strokes.length) continue;
      final (Float64List y, double error) = alignToSlot(
        strokes,
        slot.counts,
        slot.mean,
      );
      if (error < bestError) {
        best = (slot, y);
        bestError = error;
      }
    }
    return best;
  }

  static const int _neighbours = 7;

  // -----------------------------------------------------------------------
  // Storage.

  /// The model in [encoded]: a JSON header, a newline, then base64 of the
  /// numbers as 16-bit fixed point.
  factory HandModel.decode(String encoded) {
    final int split = encoded.indexOf('\n');
    final Map<String, Object?> header =
        jsonDecode(encoded.substring(0, split)) as Map<String, Object?>;
    final ByteData bytes = ByteData.sublistView(
      base64Decode(encoded.substring(split + 1)),
    );
    final double scale = (header['scale']! as num).toDouble();
    final int q = header['dimensions']! as int;
    int offset = 0;
    Float64List read(int count, double unit) {
      final Float64List out = Float64List(count);
      for (int i = 0; i < count; i++) {
        out[i] = bytes.getInt16(offset, Endian.little) * unit;
        offset += 2;
      }
      return out;
    }

    final List<HandSlot> slots = <HandSlot>[
      for (final Object? raw in header['slots']! as List<Object?>)
        () {
          final Map<String, Object?> s = raw! as Map<String, Object?>;
          final List<int> counts = (s['counts']! as List<Object?>).cast<int>();
          final int length = 2 * counts.fold<int>(0, (int a, int b) => a + b);
          return HandSlot(
            char: s['char']! as String,
            counts: counts,
            samples: s['samples']! as int,
            mean: read(length, scale),
            basis: read(length * q, scale),
          );
        }(),
    ];
    final List<HandWriter> writers = <HandWriter>[
      for (final Object? raw in header['writers']! as List<Object?>)
        () {
          final Map<String, Object?> w = raw! as Map<String, Object?>;
          return HandWriter(
            read(q, 1 / 1000),
            (w['ways']! as Map<String, Object?>).cast<String, int>(),
          );
        }(),
    ];
    return HandModel(
      dimensions: q,
      noise: (header['noise']! as num).toDouble(),
      slots: slots,
      writers: writers,
      fallbacks: <String, double>{
        for (final MapEntry<String, Object?> e
            in ((header['fallbacks'] ?? const <String, Object?>{})
                    as Map<String, Object?>)
                .entries)
          e.key: (e.value! as num).toDouble(),
      },
    );
  }

  /// This model as [HandModel.decode] reads it.
  String encode() {
    const double scale = 1 / 500;
    final BytesBuilder out = BytesBuilder();
    void write(Iterable<double> values, double unit) {
      final ByteData data = ByteData(2);
      for (final double v in values) {
        data.setInt16(
          0,
          (v / unit).round().clamp(-32768, 32767),
          Endian.little,
        );
        out.add(data.buffer.asUint8List());
      }
    }

    for (final HandSlot slot in slots) {
      write(slot.mean, scale);
      write(slot.basis, scale);
    }
    for (final HandWriter writer in writers) {
      write(writer.position, 1 / 1000);
    }
    final String header = jsonEncode(<String, Object?>{
      'dimensions': dimensions,
      'noise': noise,
      'scale': scale,
      'slots': <Object?>[
        for (final HandSlot slot in slots)
          <String, Object?>{
            'char': slot.char,
            'counts': slot.counts,
            'samples': slot.samples,
          },
      ],
      'writers': <Object?>[
        for (final HandWriter writer in writers)
          <String, Object?>{'ways': writer.ways},
      ],
      'fallbacks': fallbacks,
    });
    return '$header\n${base64Encode(out.toBytes())}';
  }
}

/// One way of writing one letter: how many strokes, how many points each
/// is laid out with, and the average and directions of variation of those
/// points across hands.
@immutable
class HandSlot {
  const HandSlot({
    required this.char,
    required this.counts,
    required this.samples,
    required this.mean,
    required this.basis,
  });

  final String char;

  /// Points per stroke, in pen order.
  final List<int> counts;

  /// How many of the hands learned from wrote the letter this way.
  final int samples;

  /// The average hand's points, x and y interleaved.
  final Float64List mean;

  /// How each coordinate moves along each of the space's dimensions,
  /// row-major: coordinate d, dimension i at d * dimensions + i.
  final Float64List basis;
}

/// One of the hands a [HandModel] learned from.
@immutable
class HandWriter {
  const HandWriter(this.position, this.ways);

  final Float64List position;

  /// Which slot, by index into [HandModel.slots], it writes each letter in.
  final Map<String, int> ways;

  double distanceTo(Float64List other) {
    double sum = 0;
    for (int i = 0; i < position.length; i++) {
      final double d = position[i] - other[i];
      sum += d * d;
    }
    return math.sqrt(sum);
  }
}

/// Where a writer lies in a [HandModel]'s space, and which of their letters
/// put them there.
@immutable
class HandEstimate {
  const HandEstimate(this.position, this.read, this.misfit);

  final Float64List position;
  final Set<String> read;

  /// The mean squared distance, per coordinate, of the letters written
  /// from the same letters as the hand at [position] writes them.
  final double misfit;
}

/// [strokes], in the font's grid and leaning [slant], stood upright and
/// moved to start at x = 0, as a [HandModel] lays letters out.
HandStrokes uprightLetter(HandStrokes strokes, {required double slant}) {
  final HandStrokes upright = <List<InkVector>>[
    for (final List<InkVector> stroke in strokes)
      <InkVector>[
        for (final InkVector p in stroke)
          InkVector(p.x - slant * (10 - p.y), p.y),
      ],
  ];
  double left = double.infinity;
  for (final List<InkVector> stroke in upright) {
    for (final InkVector p in stroke) {
      left = math.min(left, p.x);
    }
  }
  if (!left.isFinite) return upright;
  return <List<InkVector>>[
    for (final List<InkVector> stroke in upright)
      <InkVector>[for (final InkVector p in stroke) InkVector(p.x - left, p.y)],
  ];
}

/// [strokes] laid out against [reference] (x and y interleaved, [counts]
/// points per stroke): each stroke resampled by arc length to its count,
/// in the stroke order, direction and, for a closed loop, starting point
/// that lie nearest the reference. Returns the layout and its summed
/// squared distance from the reference. [strokes] must have as many
/// strokes as [counts].
(Float64List, double) alignToSlot(
  HandStrokes strokes,
  List<int> counts,
  Float64List reference,
) {
  final int n = counts.length;
  final List<int> starts = <int>[];
  int at = 0;
  for (final int c in counts) {
    starts.add(at);
    at += 2 * c;
  }
  // Each stroke's best layout in each place, and its cost.
  final List<List<(Float64List, double)>> fits = <List<(Float64List, double)>>[
    for (final List<InkVector> stroke in strokes)
      <(Float64List, double)>[
        for (int place = 0; place < n; place++)
          _bestStroke(stroke, counts[place], reference, starts[place]),
      ],
  ];
  List<int> order = List<int>.generate(n, (int i) => i);
  double best = double.infinity;
  // Every order for a few strokes; pen order beyond that.
  for (final List<int> permutation
      in n <= 4 ? _permutations(n) : <List<int>>[order]) {
    double cost = 0;
    for (int place = 0; place < n; place++) {
      cost += fits[permutation[place]][place].$2;
    }
    if (cost < best) {
      best = cost;
      order = permutation;
    }
  }
  final Float64List out = Float64List(at);
  for (int place = 0; place < n; place++) {
    out.setAll(starts[place], fits[order[place]][place].$1);
  }
  return (out, best);
}

/// [stroke] resampled to [count] points, forwards or backwards, and for a
/// closed loop from whichever point, whichever lies nearest the points of
/// [reference] from [offset].
(Float64List, double) _bestStroke(
  List<InkVector> stroke,
  int count,
  Float64List reference,
  int offset,
) {
  final List<InkVector> points = resampleCount(stroke, count);
  final double length = _length(stroke);
  // A loop may start anywhere on it; an open stroke whose ends come near,
  // as a narrow u, v or m does, may not.
  final double referenceGap = math.sqrt(
    math.pow(reference[offset] - reference[offset + 2 * count - 2], 2) +
        math.pow(reference[offset + 1] - reference[offset + 2 * count - 1], 2),
  );
  double referenceLength = 0;
  for (int i = 1; i < count; i++) {
    referenceLength += math.sqrt(
      math.pow(reference[offset + 2 * i] - reference[offset + 2 * i - 2], 2) +
          math.pow(
            reference[offset + 2 * i + 1] - reference[offset + 2 * i - 1],
            2,
          ),
    );
  }
  final bool closed =
      count >= 6 &&
      length > 0 &&
      (stroke.first - stroke.last).length < 0.1 * length &&
      referenceGap < 0.1 * referenceLength;
  Float64List? best;
  double bestCost = double.infinity;
  for (final bool reversed in <bool>[false, true]) {
    final List<InkVector> ordered = reversed
        ? points.reversed.toList()
        : points;
    for (int shift = 0; shift < (closed ? count : 1); shift++) {
      double cost = 0;
      for (int i = 0; i < count; i++) {
        final InkVector p = ordered[(i + shift) % count];
        final double dx = p.x - reference[offset + 2 * i];
        final double dy = p.y - reference[offset + 2 * i + 1];
        cost += dx * dx + dy * dy;
      }
      if (cost < bestCost) {
        bestCost = cost;
        best = Float64List(2 * count);
        for (int i = 0; i < count; i++) {
          final InkVector p = ordered[(i + shift) % count];
          best[2 * i] = p.x;
          best[2 * i + 1] = p.y;
        }
      }
    }
  }
  return (best!, bestCost);
}

/// [stroke] as [count] points evenly spaced along it; a dot as [count]
/// copies of itself.
List<InkVector> resampleCount(List<InkVector> stroke, int count) {
  if (stroke.isEmpty) return List<InkVector>.filled(count, InkVector.zero);
  final double total = _length(stroke);
  if (total <= 1e-9 || count == 1) {
    return List<InkVector>.filled(count, stroke.first);
  }
  final List<InkVector> out = <InkVector>[stroke.first];
  final double step = total / (count - 1);
  double travelled = 0;
  double next = step;
  for (int i = 1; i < stroke.length && out.length < count - 1; i++) {
    final InkVector a = stroke[i - 1];
    final InkVector b = stroke[i];
    final double segment = (b - a).length;
    while (segment > 0 &&
        travelled + segment >= next &&
        out.length < count - 1) {
      final double t = (next - travelled) / segment;
      out.add(a + (b - a) * t);
      next += step;
    }
    travelled += segment;
  }
  while (out.length < count) {
    out.add(stroke.last);
  }
  return out;
}

double _length(List<InkVector> stroke) {
  double sum = 0;
  for (int i = 1; i < stroke.length; i++) {
    sum += (stroke[i] - stroke[i - 1]).length;
  }
  return sum;
}

List<List<int>> _permutations(int n) {
  if (n <= 1) return <List<int>>[List<int>.generate(n, (int i) => i)];
  final List<List<int>> out = <List<int>>[];
  for (final List<int> rest in _permutations(n - 1)) {
    for (int at = 0; at <= rest.length; at++) {
      out.add(<int>[...rest.sublist(0, at), n - 1, ...rest.sublist(at)]);
    }
  }
  return out;
}

/// The solution of the symmetric positive definite system [a] x = [b],
/// [a] being [n] by [n], row-major, by Cholesky factorization.
Float64List _solve(Float64List a, Float64List b, int n) {
  final Float64List l = Float64List(n * n);
  for (int i = 0; i < n; i++) {
    for (int j = 0; j <= i; j++) {
      double sum = a[i * n + j];
      for (int k = 0; k < j; k++) {
        sum -= l[i * n + k] * l[j * n + k];
      }
      l[i * n + j] = i == j
          ? math.sqrt(math.max(sum, 1e-12))
          : sum / l[j * n + j];
    }
  }
  final Float64List y = Float64List(n);
  for (int i = 0; i < n; i++) {
    double sum = b[i];
    for (int k = 0; k < i; k++) {
      sum -= l[i * n + k] * y[k];
    }
    y[i] = sum / l[i * n + i];
  }
  final Float64List x = Float64List(n);
  for (int i = n - 1; i >= 0; i--) {
    double sum = y[i];
    for (int k = i + 1; k < n; k++) {
      sum -= l[k * n + i] * x[k];
    }
    x[i] = sum / l[i * n + i];
  }
  return x;
}
