import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../ink/ink_sample.dart';
import '../ink/stroke.dart';
import 'handwriting_style.dart';

/// The minimum normalized recognizer confidence required for a reading to be
/// shown in search. Uncertain readings remain metadata rather than becoming
/// searchable words.
const double searchableHandwritingConfidence = 0.50;

/// Reuse stays stricter than search because a false positive here would make
/// AI notation draw the wrong source strokes as text.
const double reusableHandwritingConfidence = 0.90;

/// A searchable reading of a group of page strokes, plus a normalized copy
/// of their geometry. The copy is deliberately vector-only: fitting it to a
/// new text box is an affine transform and needs no generative model.
@immutable
class RecognizedInkWord {
  RecognizedInkWord({
    required this.text,
    required this.confidence,
    required Iterable<Stroke> sourceStrokes,
    required Iterable<List<InkVector>> normalizedStrokes,
    required this.aspectRatio,
    this.stickyId,
  }) : sourceStrokes = List<Stroke>.unmodifiable(sourceStrokes),
       normalizedStrokes = List<List<InkVector>>.unmodifiable(
         normalizedStrokes.map(List<InkVector>.unmodifiable),
       );

  /// Builds a word from ink currently on a page. Empty/invalid geometry is
  /// rejected, and very large samples stay searchable without entering the
  /// reusable pool.
  factory RecognizedInkWord.fromStrokes({
    required String text,
    required double? confidence,
    required List<Stroke> strokes,
    String? stickyId,
  }) {
    final Rect bounds = _geometryBoundsOf(strokes);
    final double width = math.max(bounds.width, 1e-6);
    final double height = math.max(bounds.height, 1e-6);
    final int pointCount = strokes.fold<int>(
      0,
      (int count, Stroke stroke) => count + stroke.points.length,
    );
    final bool reusable =
        confidence != null &&
        confidence >= reusableHandwritingConfidence &&
        pointCount <= maxReusablePoints &&
        !bounds.isEmpty &&
        bounds.isFinite;
    return RecognizedInkWord(
      text: text.trim(),
      confidence: confidence,
      sourceStrokes: strokes,
      normalizedStrokes: reusable
          ? <List<InkVector>>[
              for (final Stroke stroke in strokes)
                <InkVector>[
                  for (final InkVector point in stroke.points)
                    InkVector(
                      (point.x - bounds.left) / width,
                      (point.y - bounds.top) / height,
                    ),
                ],
            ]
          : const <List<InkVector>>[],
      aspectRatio: width / height,
      stickyId: stickyId,
    );
  }

  static const int maxReusablePoints = 4096;

  final String text;
  final double? confidence;

  /// Identity links to the live page strokes. If any is erased, the search
  /// entry is removed; transforms replace these links with their successors.
  final List<Stroke> sourceStrokes;

  /// Strokes translated and independently scaled into the unit square.
  final List<List<InkVector>> normalizedStrokes;
  final double aspectRatio;

  /// Null for paper ink; otherwise the sticky note whose local-coordinate
  /// strokes produced this reading.
  final String? stickyId;

  bool get isSearchable =>
      confidence != null && confidence! >= searchableHandwritingConfidence;

  bool get isReusable =>
      isSearchable &&
      normalizedStrokes.isNotEmpty &&
      aspectRatio.isFinite &&
      aspectRatio > 0;

  Rect get bounds => boundsOf(sourceStrokes);

  RecognizedInkWord follow(Map<Stroke, Stroke> replacements) =>
      RecognizedInkWord(
        text: text,
        confidence: confidence,
        sourceStrokes: <Stroke>[
          for (final Stroke stroke in sourceStrokes)
            replacements[stroke] ?? stroke,
        ],
        normalizedStrokes: normalizedStrokes,
        aspectRatio: aspectRatio,
        stickyId: stickyId,
      );

  static Rect boundsOf(Iterable<Stroke> strokes) {
    Rect? bounds;
    for (final Stroke stroke in strokes) {
      bounds = bounds?.expandToInclude(stroke.bounds) ?? stroke.bounds;
    }
    return bounds ?? Rect.zero;
  }

  static Rect _geometryBoundsOf(Iterable<Stroke> strokes) {
    double left = double.infinity;
    double top = double.infinity;
    double right = double.negativeInfinity;
    double bottom = double.negativeInfinity;
    for (final Stroke stroke in strokes) {
      for (final InkVector point in stroke.points) {
        left = math.min(left, point.x);
        top = math.min(top, point.y);
        right = math.max(right, point.x);
        bottom = math.max(bottom, point.y);
      }
    }
    return left.isFinite ? Rect.fromLTRB(left, top, right, bottom) : Rect.zero;
  }
}

/// A bounded lookup of high-confidence handwritten forms. Samples are kept
/// as distinct variants: generation chooses one randomly and only translates
/// and scales it, avoiding the distortions caused by averaging strokes with
/// different topology or stroke order.
class HandwritingSampleLibrary {
  HandwritingSampleLibrary(
    Iterable<RecognizedInkWord> words, {
    math.Random? random,
    this.maxVariantsPerText = 12,
    this.calibration,
  }) : _random = random ?? math.Random() {
    for (final RecognizedInkWord word in words) {
      if (!word.isReusable) continue;
      final String key = canonical(word.text);
      if (key.isEmpty) continue;
      final List<RecognizedInkWord> variants = _samples.putIfAbsent(
        key,
        () => <RecognizedInkWord>[],
      );
      if (variants.length < maxVariantsPerText) variants.add(word);
    }
  }

  final math.Random _random;
  final int maxVariantsPerText;

  /// The writer's hand from calibration, shared by every note. Text the
  /// note has no samples for is written in it.
  final HandwritingStyle? calibration;

  final Map<String, List<RecognizedInkWord>> _samples =
      <String, List<RecognizedInkWord>>{};

  // Case is part of the glyph geometry: reusing "cat" for "Cat" would alter
  // the requested notation even though search itself is case-insensitive.
  static String canonical(String text) => text.trim();

  int variantsFor(String text) => _samples[canonical(text)]?.length ?? 0;

  bool get isEmpty => _samples.isEmpty && calibration == null;

  RecognizedInkWord? choose(String text) {
    final List<RecognizedInkWord>? variants = _samples[canonical(text)];
    if (variants == null || variants.isEmpty) return null;
    return variants[_random.nextInt(variants.length)];
  }

  Map<String, List<RecognizedInkWord>> get samples =>
      UnmodifiableMapView<String, List<RecognizedInkWord>>(
        <String, List<RecognizedInkWord>>{
          for (final MapEntry<String, List<RecognizedInkWord>> entry
              in _samples.entries)
            entry.key: List<RecognizedInkWord>.unmodifiable(entry.value),
        },
      );
}
