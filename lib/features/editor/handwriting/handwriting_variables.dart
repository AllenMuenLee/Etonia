import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../ink/ink_sample.dart';
import 'hand_glyphs.dart';

/// Measurements shared by every glyph synthesized from a writer's samples.
///
/// These are deliberately semantic rather than per-character knobs.  A loop
/// seen in the ascender of a `d`, for example, also shapes a missing `l`; the
/// width and drop of a shoulder shape `r`, `n`, and `m`; roundness measured
/// from `o` shapes a missing zero.  This keeps generated letters in one hand
/// without mistaking one letter for a chopped-up copy of another.
@immutable
class HandwritingVariables {
  const HandwritingVariables({
    this.xTop = 4,
    this.ascenderTop = 0,
    this.descenderBottom = 13,
    this.lowercaseWidth = 5,
    this.capitalWidth = 7,
    this.ascenderLoop = 0,
    this.ascenderLoopWidth = 2.4,
    this.shoulderWidth = 2.8,
    this.shoulderDrop = 0.16,
    this.capitalBarWidth = 5.2,
    this.zeroAspect = 0.55,
  });

  /// Top of letters such as `a`, in the ten-unit glyph grid.
  final double xTop;

  /// Top of tall lowercase letters.
  final double ascenderTop;

  /// Bottom of descenders.
  final double descenderBottom;

  /// Typical width of a lowercase bowl or shoulder.
  final double lowercaseWidth;

  /// Typical capital width.
  final double capitalWidth;

  /// Confidence from 0 to 1 that tall lowercase stems are looped/cursive.
  final double ascenderLoop;

  /// Width of a cursive ascender loop in grid units.
  final double ascenderLoopWidth;

  /// Width of the shoulder used by `r`, and as a basis for `n` and `m`.
  final double shoulderWidth;

  /// How far an `r` shoulder ends below the x-height, as a share of x-height.
  final double shoulderDrop;

  /// Width of the top and bottom bars of capital `I`.
  final double capitalBarWidth;

  /// Width divided by height for a zero.
  final double zeroAspect;

  /// Reads robust medians from all available samples. [glyphs] are in the
  /// ten-unit grid and lean by [slant]; measurements are made upright.
  factory HandwritingVariables.measure(
    Map<String, HandGlyph> glyphs, {
    required double slant,
  }) {
    final Map<String, List<List<InkVector>>> upright =
        <String, List<List<InkVector>>>{
          for (final MapEntry<String, HandGlyph> entry in glyphs.entries)
            entry.key: <List<InkVector>>[
              for (final List<InkVector> stroke in entry.value.strokes)
                <InkVector>[
                  for (final InkVector p in stroke)
                    InkVector(p.x - slant * (10 - p.y), p.y),
                ],
            ],
        };

    double? measured(String letters, double Function(_Box box) read) {
      final List<double> values = <double>[
        for (final String letter in letters.split(''))
          if (upright[letter] case final List<List<InkVector>> strokes)
            read(_Box.of(strokes)),
      ];
      return values.isEmpty ? null : _median(values);
    }

    final double xTop = (measured('aeosw', (_Box b) => b.top) ?? 4).clamp(
      2.0,
      8.0,
    );
    final double ascenderTop = (measured('bdfhklt', (_Box b) => b.top) ?? 0)
        .clamp(-2.0, xTop - 1);
    final double descenderBottom = math.max(
      measured('gjpqy', (_Box b) => b.bottom) ?? 13,
      11.5,
    );
    final double lowercaseWidth = (measured('aorsw', (_Box b) => b.width) ?? 5)
        .clamp(2.5, 8.0);
    final double capitalWidth = (measured('AERDHN', (_Box b) => b.width) ?? 7)
        .clamp(4.0, 10.0);
    final double xHeight = math.max(10 - xTop, 1);

    final List<double> loopScores = <double>[];
    final List<double> loopWidths = <double>[];
    for (final String letter in 'bdhfl'.split('')) {
      final List<List<InkVector>>? strokes = upright[letter];
      if (strokes == null) continue;
      final _Ascender? ascender = _ascender(strokes, xTop, ascenderTop);
      if (ascender == null) continue;
      loopScores.add(
        ((ascender.width / xHeight - 0.05) / 0.28).clamp(0.0, 1.0),
      );
      if (ascender.width > xHeight * 0.08) loopWidths.add(ascender.width);
    }

    final List<double> shoulderWidths = <double>[];
    final List<double> shoulderDrops = <double>[];
    for (final String letter in 'rhnm'.split('')) {
      final List<List<InkVector>>? strokes = upright[letter];
      if (strokes == null) continue;
      final _Box box = _Box.of(strokes);
      shoulderWidths.add(box.width.clamp(1.5, 7.0));
      if (letter == 'r') {
        final InkVector end = _rightmostEnd(strokes);
        shoulderDrops.add(((end.y - xTop) / xHeight).clamp(0.0, 0.55));
      }
    }

    final List<double> bars = <double>[];
    for (final String letter in 'EAFHT'.split('')) {
      final List<List<InkVector>>? strokes = upright[letter];
      if (strokes == null) continue;
      for (final List<InkVector> stroke in strokes) {
        final _Box box = _Box.of(<List<InkVector>>[stroke]);
        if (box.width > box.height * 2.5 && box.width > 2) bars.add(box.width);
      }
    }

    final List<double> zeroAspects = <double>[];
    for (final String letter in '0Oo'.split('')) {
      if (upright[letter] case final List<List<InkVector>> strokes) {
        final _Box box = _Box.of(strokes);
        if (box.height > 1) {
          final double scale = letter == 'o' ? 0.9 : 1;
          zeroAspects.add((box.width / box.height * scale).clamp(0.35, 0.8));
        }
      }
    }

    return HandwritingVariables(
      xTop: xTop,
      ascenderTop: ascenderTop,
      descenderBottom: descenderBottom,
      lowercaseWidth: lowercaseWidth,
      capitalWidth: capitalWidth,
      ascenderLoop: loopScores.isEmpty ? 0 : _median(loopScores),
      ascenderLoopWidth: loopWidths.isEmpty
          ? xHeight * 0.38
          : _median(loopWidths).clamp(0.8, xHeight * 0.8),
      shoulderWidth: shoulderWidths.isEmpty
          ? lowercaseWidth * 0.58
          : _median(shoulderWidths).clamp(1.5, lowercaseWidth),
      shoulderDrop: shoulderDrops.isEmpty ? 0.16 : _median(shoulderDrops),
      capitalBarWidth: bars.isEmpty
          ? capitalWidth * 0.74
          : _median(bars).clamp(capitalWidth * 0.55, capitalWidth * 1.1),
      zeroAspect: zeroAspects.isEmpty ? 0.55 : _median(zeroAspects),
    );
  }

  HandwritingVariables clamped() => HandwritingVariables(
    xTop: xTop.clamp(2.0, 8.0),
    ascenderTop: ascenderTop.clamp(-2.0, xTop - 1),
    descenderBottom: descenderBottom.clamp(11.5, 18.0),
    lowercaseWidth: lowercaseWidth.clamp(2.5, 8.0),
    capitalWidth: capitalWidth.clamp(4.0, 10.0),
    ascenderLoop: ascenderLoop.clamp(0.0, 1.0),
    ascenderLoopWidth: ascenderLoopWidth.clamp(0.8, 6.0),
    shoulderWidth: shoulderWidth.clamp(1.5, 7.0),
    shoulderDrop: shoulderDrop.clamp(0.0, 0.55),
    capitalBarWidth: capitalBarWidth.clamp(2.8, 11.0),
    zeroAspect: zeroAspect.clamp(0.35, 0.8),
  );
}

typedef _Ascender = ({double width});

_Ascender? _ascender(
  List<List<InkVector>> strokes,
  double xTop,
  double ascenderTop,
) {
  List<InkVector>? best;
  int top = -1;
  for (final List<InkVector> stroke in strokes) {
    if (stroke.length < 3) continue;
    int candidate = 0;
    for (int i = 1; i < stroke.length; i++) {
      if (stroke[i].y < stroke[candidate].y) candidate = i;
    }
    if (stroke[candidate].y > (xTop + ascenderTop) / 2) continue;
    if (best == null || stroke[candidate].y < best[top].y) {
      best = stroke;
      top = candidate;
    }
  }
  if (best == null) return null;
  // How far apart the pen's way up and its way down are, across the
  // ascender: a loop holds them apart, while a stem gone up on a slant and
  // come straight back down, as from the bowl of a d, keeps them together
  // however far it leans.
  final double peak = best[top].y;
  final double ceiling = peak + (xTop - peak) * 0.8;
  final List<double> widths = <double>[];
  for (final double share in <double>[0.3, 0.45, 0.6, 0.75, 0.9]) {
    final double y = peak + (ceiling - peak) * share;
    final List<double> crossings = <double>[
      for (int i = 1; i < best.length; i++)
        if ((best[i - 1].y - y) * (best[i].y - y) <= 0 &&
            best[i - 1].y != best[i].y)
          best[i - 1].x +
              (best[i].x - best[i - 1].x) *
                  (y - best[i - 1].y) /
                  (best[i].y - best[i - 1].y),
    ];
    widths.add(
      crossings.length < 2
          ? 0
          : crossings.reduce(math.max) - crossings.reduce(math.min),
    );
  }
  return (width: _median(widths));
}

InkVector _rightmostEnd(List<List<InkVector>> strokes) {
  InkVector best = strokes.first.first;
  for (final List<InkVector> stroke in strokes) {
    for (final InkVector end in <InkVector>[stroke.first, stroke.last]) {
      if (end.x > best.x) best = end;
    }
  }
  return best;
}

double _median(List<double> values) {
  values.sort();
  final int middle = values.length ~/ 2;
  return values.length.isOdd
      ? values[middle]
      : (values[middle - 1] + values[middle]) / 2;
}

class _Box {
  const _Box(this.left, this.top, this.right, this.bottom);

  factory _Box.of(Iterable<List<InkVector>> strokes) {
    double left = double.infinity;
    double top = double.infinity;
    double right = double.negativeInfinity;
    double bottom = double.negativeInfinity;
    for (final List<InkVector> stroke in strokes) {
      for (final InkVector p in stroke) {
        left = math.min(left, p.x);
        top = math.min(top, p.y);
        right = math.max(right, p.x);
        bottom = math.max(bottom, p.y);
      }
    }
    return _Box(left, top, right, bottom);
  }

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;
}
