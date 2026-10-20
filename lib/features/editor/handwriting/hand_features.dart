import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../ai/notation_glyphs.dart';
import '../ink/ink_sample.dart';
import 'cubic_bezier.dart';
import 'stroke_runs.dart';

/// The letters a hand is learned from: between them, g, a, p, i and w hold
/// every kind of stroke the font is drawn with.
const String handLetters = 'gapiw';

/// The kinds of stroke a letter is made of.
enum HandPart {
  /// A line near upright or level, as the stems of p and i.
  straight,

  /// A line at a slant, as the strokes of a w.
  diagonal,

  /// An open curve, as the arch of an a.
  curve,

  /// A curve that goes most of the way round, as the bowls of a, g and p.
  bowl,
}

/// The shapes of a writer's hand, each approximated by a [CubicBezier],
/// a bowl by two:
/// how they dot an i, round a bowl, bend the arch of an a, finish the tail
/// of a g, and draw slanting and upright lines.
///
/// The font is drawn with them by [apply]: each part of a glyph changes as
/// far as the writer's shape differs from the font's own for that part
/// ([font]), so the font's letters keep what makes them legible.
@immutable
class HandFeatures {
  const HandFeatures({
    this.strength = 1,
    this.dot,
    this.dotLift,
    this.bowlLower,
    this.bowlUpper,
    this.curve,
    this.tail,
    this.diagonal,
    this.straight,
  });

  /// How far the font's strokes take these shapes on: 0 not at all, 1 all
  /// the way.
  final double strength;

  /// The dot of an i, about its middle, in grid units.
  final CubicBezier? dot;

  /// From the top of the i's stem to the middle of its dot, in grid units.
  final InkVector? dotLift;

  /// The lower half of the bowl of a, g and p, about the middle of its box,
  /// in its heights: from its rightmost point round under to its leftmost.
  /// A curve of the third degree cannot go all the way round a bowl, so a
  /// bowl is two.
  final CubicBezier? bowlLower;

  /// The upper half of that bowl, from its leftmost point back over to its
  /// rightmost.
  final CubicBezier? bowlUpper;

  /// The arch of the a, from (0, 0) to (1, 0) along its chord as drawn,
  /// bulging towards +y.
  final CubicBezier? curve;

  /// The tail of the g from where it crosses the baseline, in grid units,
  /// turned so that the stroke comes into it heading down, along +y.
  final CubicBezier? tail;

  /// The slanting lines of the w, from (0, 0) to (1, 0) along each, read
  /// along `canonicalLine`, +y to its right.
  final CubicBezier? diagonal;

  /// The upright lines of p and i, the same way.
  final CubicBezier? straight;

  /// The font's own shapes, measured from its g, a, p, i and w just as a
  /// writer's are.
  static final HandFeatures font =
      measure(<String, List<List<List<InkVector>>>>{
        for (final String letter in handLetters.split(''))
          letter: <List<List<InkVector>>>[_fontGlyph(letter)],
      }) ??
      const HandFeatures();

  static List<List<InkVector>> _fontGlyph(String char) => <List<InkVector>>[
    for (final List<double> flat in notationGlyphs[char]!.$2)
      <InkVector>[
        for (int i = 0; i < flat.length; i += 2)
          InkVector(flat[i], flat[i + 1]),
      ],
  ];

  bool get isEmpty =>
      dot == null &&
      dotLift == null &&
      bowlLower == null &&
      bowlUpper == null &&
      curve == null &&
      tail == null &&
      diagonal == null &&
      straight == null;

  HandFeatures withStrength(double strength) => HandFeatures(
    strength: strength,
    dot: dot,
    dotLift: dotLift,
    bowlLower: bowlLower,
    bowlUpper: bowlUpper,
    curve: curve,
    tail: tail,
    diagonal: diagonal,
    straight: straight,
  );

  /// [a] moved [amount] of the way towards [b]. A hand with no shapes is
  /// the font's: mixing towards it weakens the other's [strength].
  static HandFeatures? mix(HandFeatures? a, HandFeatures? b, double amount) {
    if (a == null && b == null) return null;
    if (a == null) return b!.withStrength(b.strength * amount);
    if (b == null) return a.withStrength(a.strength * (1 - amount));
    CubicBezier? curve(CubicBezier? x, CubicBezier? y) =>
        x == null ? y : (y == null ? x : x.lerp(y, amount));
    return HandFeatures(
      strength: a.strength + (b.strength - a.strength) * amount,
      dot: curve(a.dot, b.dot),
      dotLift: a.dotLift == null
          ? b.dotLift
          : (b.dotLift == null
                ? a.dotLift
                : a.dotLift! + (b.dotLift! - a.dotLift!) * amount),
      bowlLower: curve(a.bowlLower, b.bowlLower),
      bowlUpper: curve(a.bowlUpper, b.bowlUpper),
      curve: curve(a.curve, b.curve),
      tail: curve(a.tail, b.tail),
      diagonal: curve(a.diagonal, b.diagonal),
      straight: curve(a.straight, b.straight),
    );
  }

  /// These shapes held to what a legible hand can have. The bounds are on
  /// the control points, which stand out about twice as far as the curve
  /// they shape: a bowl a box high has points reaching past ±1.2.
  HandFeatures clamped() {
    CubicBezier? held(
      CubicBezier? curve,
      double left,
      double right,
      double top,
      double bottom,
    ) => curve?.mapped(
      (InkVector p) =>
          InkVector(p.x.clamp(left, right), p.y.clamp(top, bottom)),
    );
    return HandFeatures(
      strength: strength.clamp(0.0, 1.0),
      dot: held(dot, -3, 3, -3, 3),
      dotLift: dotLift == null
          ? null
          : InkVector(
              dotLift!.x.clamp(-2.0, 2.0),
              dotLift!.y.clamp(-5.0, -0.3),
            ),
      bowlLower: held(bowlLower, -3, 3, -2.5, 2.5),
      bowlUpper: held(bowlUpper, -3, 3, -2.5, 2.5),
      curve: held(curve, -1, 2, -1.5, 2),
      tail: held(tail, -10, 10, -4, 12),
      diagonal: held(diagonal, -0.5, 1.5, -0.25, 0.25),
      straight: held(straight, -0.5, 1.5, -0.25, 0.25),
    );
  }

  // ---------------------------------------------------------------------
  // Measuring.

  /// The shapes of the hand that wrote [letters]: for each of
  /// [handLetters], the samples written of it, each a list of strokes in
  /// the font's grid (upright, the baseline at y = 10, the x-height near
  /// y = 3.8). What a letter does not show is left null; null when nothing
  /// could be read.
  static HandFeatures? measure(
    Map<String, List<List<List<InkVector>>>> letters,
  ) {
    final List<List<InkVector>> straights = <List<InkVector>>[];
    final List<List<InkVector>> diagonals = <List<InkVector>>[];
    final List<List<InkVector>> curves = <List<InkVector>>[];
    final List<(String, List<InkVector>)> bowls = <(String, List<InkVector>)>[];
    final List<List<InkVector>> tails = <List<InkVector>>[];
    final List<List<InkVector>> dots = <List<InkVector>>[];
    final List<InkVector> lifts = <InkVector>[];

    for (final MapEntry<String, List<List<List<InkVector>>>> entry
        in letters.entries) {
      for (final List<List<InkVector>> sample in entry.value) {
        final List<List<InkVector>> strokes = <List<InkVector>>[
          for (final List<InkVector> stroke in sample)
            if (stroke.isNotEmpty) _prepared(stroke),
        ];
        if (strokes.isEmpty) continue;
        final List<_Part> parts = <_Part>[
          for (final List<InkVector> stroke in strokes) ..._partsOf(stroke),
        ];
        switch (entry.key) {
          case 'i':
            _readI(strokes, straights, dots, lifts);
          case 'p':
            final _Part? stem = _longest(parts, (_Part p) => p.isUpright);
            if (stem != null) straights.add(stem.points);
            final _Part? bowl = _longest(parts, (_Part p) => p.isBowl);
            if (bowl != null) bowls.add((entry.key, bowl.points));
          case 'a':
            final _Part? bowl = _longest(parts, (_Part p) => p.isBowl);
            if (bowl != null) bowls.add((entry.key, bowl.points));
            final _Part? arch = _longest(
              parts,
              (_Part p) => p.kind == HandPart.curve && _isArch(p.points),
            );
            if (arch != null) curves.add(arch.points);
          case 'g':
            final _Part? bowl = _longest(parts, (_Part p) => p.isBowl);
            if (bowl != null) bowls.add((entry.key, bowl.points));
            final List<InkVector>? tail = _tailOf(strokes);
            if (tail != null) tails.add(tail);
          case 'w':
            for (final _Part part in parts) {
              if (part.kind == HandPart.curve || part.kind == HandPart.bowl) {
                continue;
              }
              final double lean = part.lean;
              if (lean > 3 * math.pi / 180 && lean < math.pi / 3) {
                diagonals.add(part.points);
              }
            }
        }
      }
    }

    final ({CubicBezier lower, CubicBezier upper})? halves = _fitBowls(bowls);
    final HandFeatures features = HandFeatures(
      straight: _fitLines(straights),
      diagonal: _fitLines(diagonals),
      curve: curves.isEmpty
          ? null
          : CubicBezier.fit(
              <List<InkVector>>[
                for (final List<InkVector> c in curves) _curveFrame(c),
              ],
              start: InkVector.zero,
              end: const InkVector(1, 0),
            ),
      bowlLower: halves?.lower,
      bowlUpper: halves?.upper,
      tail: tails.isEmpty
          ? null
          : CubicBezier.fit(tails, start: InkVector.zero),
      dot: dots.isEmpty
          ? null
          : (dots.every((List<InkVector> d) => _extent(d) < 0.25)
                ? CubicBezier.point(InkVector.zero)
                : CubicBezier.fit(<List<InkVector>>[
                    for (final List<InkVector> d in dots)
                      if (d.length > 1) d,
                  ])),
      dotLift: lifts.isEmpty
          ? null
          : lifts.reduce((InkVector a, InkVector b) => a + b) *
                (1 / lifts.length),
    );
    return features.isEmpty ? null : features;
  }

  static void _readI(
    List<List<InkVector>> strokes,
    List<List<InkVector>> straights,
    List<List<InkVector>> dots,
    List<InkVector> lifts,
  ) {
    List<InkVector> stem = strokes.first;
    for (final List<InkVector> stroke in strokes) {
      if (pathLength(stroke) > pathLength(stem)) stem = stroke;
    }
    InkVector top = stem.first;
    for (final InkVector p in stem) {
      if (p.y < top.y) top = p;
    }
    final _Part? line = _longest(_partsOf(stem), (_Part p) => p.isUpright);
    if (line != null) straights.add(line.points);
    // The dot: a small mark above the stem; the highest, if there are more.
    List<InkVector>? dot;
    for (final List<InkVector> stroke in strokes) {
      if (identical(stroke, stem) || _extent(stroke) > 2.5) continue;
      final InkVector middle = _centroid(stroke);
      if (middle.y > top.y + 0.5) continue;
      if (dot == null || middle.y < _centroid(dot).y) dot = stroke;
    }
    if (dot == null) return;
    final InkVector middle = _centroid(dot);
    dots.add(<InkVector>[for (final InkVector p in dot) p - middle]);
    lifts.add(middle - top);
  }

  /// Whether [points] arch over, as the top of an a: left to right, the
  /// middle above the ends.
  static bool _isArch(List<InkVector> points) {
    final InkVector chord = points.last - points.first;
    if (chord.x < chord.length * 0.3) return false;
    final InkVector middle = points[points.length ~/ 2];
    final double chordY =
        points.first.y +
        chord.y *
            ((middle.x - points.first.x) / (chord.x == 0 ? 1 : chord.x)).clamp(
              0.0,
              1.0,
            );
    return middle.y < chordY;
  }

  /// The tail of a g among [strokes], from where the stroke crosses the
  /// baseline on its way down to where it ends or comes back up to the
  /// line, turned so that it sets off along +y.
  static List<InkVector>? _tailOf(List<List<InkVector>> strokes) {
    final _Descender? found = _descender(strokes);
    if (found == null) return null;
    final List<InkVector> stroke = found.stroke;
    final InkVector heading = _heading(stroke, found.crossing, found.start);
    int end = stroke.length - 1;
    int deepest = found.crossing + 1;
    for (int i = found.crossing + 1; i < stroke.length; i++) {
      if (stroke[i].y > stroke[deepest].y) deepest = i;
      if (i > deepest && stroke[i].y < 9.6) {
        end = i;
        break;
      }
    }
    final double turn = math.atan2(heading.y, heading.x) - math.pi / 2;
    final double c = math.cos(turn);
    final double s = math.sin(turn);
    return <InkVector>[
      for (final InkVector p in <InkVector>[
        found.start,
        ...stroke.sublist(found.crossing + 1, end + 1),
      ])
        () {
          final InkVector d = p - found.start;
          return InkVector(d.x * c + d.y * s, -d.x * s + d.y * c);
        }(),
    ];
  }

  /// The stroke among [strokes] that reaches deepest below the baseline,
  /// turned so that its descender is at its end, with the last point
  /// before it crosses the baseline on the way down and where it crosses.
  static _Descender? _descender(List<List<InkVector>> strokes) {
    int strokeIndex = -1;
    int deepest = -1;
    double depth = 10.8;
    for (int s = 0; s < strokes.length; s++) {
      for (int i = 0; i < strokes[s].length; i++) {
        if (strokes[s][i].y > depth) {
          depth = strokes[s][i].y;
          strokeIndex = s;
          deepest = i;
        }
      }
    }
    if (strokeIndex < 0) return null;
    List<InkVector> stroke = strokes[strokeIndex];
    final bool reversed = deepest < stroke.length / 2;
    if (reversed) {
      stroke = stroke.reversed.toList();
      deepest = stroke.length - 1 - deepest;
    }
    for (int i = deepest - 1; i >= 0; i--) {
      if (stroke[i].y <= 10) {
        final InkVector a = stroke[i];
        final InkVector b = stroke[i + 1];
        final InkVector start = b.y == a.y
            ? a
            : a + (b - a) * ((10 - a.y) / (b.y - a.y));
        return (
          index: strokeIndex,
          reversed: reversed,
          stroke: stroke,
          crossing: i,
          start: start,
        );
      }
    }
    return null;
  }

  /// The way [stroke] heads as it reaches [start], just after [crossing]:
  /// over the last unit and a half before it, downwards.
  static InkVector _heading(
    List<InkVector> stroke,
    int crossing,
    InkVector start,
  ) {
    InkVector back = stroke[crossing];
    double walked = (start - back).length;
    for (int i = crossing - 1; i >= 0 && walked < 1.5; i--) {
      walked += (stroke[i + 1] - stroke[i]).length;
      back = stroke[i];
    }
    final InkVector heading = start - back;
    final double length = heading.length;
    if (length < 1e-6 || heading.y < length * 0.3) return const InkVector(0, 1);
    return heading * (1 / length);
  }

  static CubicBezier? _fitLines(List<List<InkVector>> lines) {
    if (lines.isEmpty) return null;
    return CubicBezier.fit(
      <List<InkVector>>[for (final List<InkVector> l in lines) _lineFrame(l)],
      start: InkVector.zero,
      end: const InkVector(1, 0),
    );
  }

  /// [line] along its chord, read along `canonicalLine`: from (0, 0) to
  /// (1, 0), its course to the right as +y, in its lengths.
  static List<InkVector> _lineFrame(List<InkVector> line) {
    final double length = (line.last - line.first).length;
    final List<InkVector> frame = <InkVector>[
      for (final InkVector p in line)
        () {
          final ({double t, double offset}) at = alongLine(
            p,
            line.first,
            line.last,
          );
          return InkVector(at.t, at.offset / length);
        }(),
    ];
    return frame.first.x > frame.last.x ? frame.reversed.toList() : frame;
  }

  /// [curve] along its chord as drawn, from (0, 0) to (1, 0), bulging
  /// towards +y, in its lengths.
  static List<InkVector> _curveFrame(List<InkVector> curve) {
    final ({InkVector along, InkVector across, double length, double side})
    frame = _curveAxes(curve);
    return <InkVector>[
      for (final InkVector p in curve)
        InkVector(
          (p - curve.first).dot(frame.along) / frame.length,
          (p - curve.first).dot(frame.across) / frame.length * frame.side,
        ),
    ];
  }

  static ({InkVector along, InkVector across, double length, double side})
  _curveAxes(List<InkVector> curve) {
    final InkVector chord = curve.last - curve.first;
    final double length = math.max(chord.length, 1e-6);
    final InkVector along = chord * (1 / length);
    final InkVector across = InkVector(-along.y, along.x);
    double bulge = 0;
    for (final InkVector p in curve) {
      bulge += (p - curve.first).dot(across);
    }
    return (
      along: along,
      across: across,
      length: length,
      side: bulge < 0 ? -1 : 1,
    );
  }

  /// Two curves through every bowl in [bowls], under and over, each bowl
  /// first laid once round clockwise from its rightmost side, about the
  /// middle of its box, in its heights; so bowls begun anywhere and drawn
  /// either way agree. The halves are pinned where they meet, at the
  /// bowls' rightmost and leftmost reach.
  ///
  /// The font's a, g and p differ, so each bowl is first read against the
  /// font's own bowl in that letter, and laid on the font's bowls taken
  /// together: what the curve keeps is how the writer's bowls differ, the
  /// same whichever of their bowls could be read.
  static ({CubicBezier lower, CubicBezier upper})? _fitBowls(
    List<(String, List<InkVector>)> bowls,
  ) {
    if (bowls.isEmpty) return null;
    const int half = _bins ~/ 2;
    final List<List<InkVector>> lower = <List<InkVector>>[];
    final List<List<InkVector>> upper = <List<InkVector>>[];
    double right = 0;
    double left = 0;
    for (final (String letter, List<InkVector> bowl) in bowls) {
      final List<double> radii = _polar(_normalizedBowl(bowl));
      final List<double>? font = _fontBowls[letter];
      if (font != null) {
        for (int k = 0; k < _bins; k++) {
          radii[k] *= _fontBowl[k] / math.max(font[k], 1e-3);
        }
      }
      InkVector at(int k) {
        final double angle = 2 * math.pi * k / _bins;
        final double r = radii[k % _bins];
        return InkVector(r * math.cos(angle), r * math.sin(angle));
      }

      lower.add(<InkVector>[for (int k = 0; k <= half; k++) at(k)]);
      upper.add(<InkVector>[for (int k = half; k <= _bins; k++) at(k)]);
      right += radii[0] / bowls.length;
      left += radii[half] / bowls.length;
    }
    final List<List<double>> evenly = <List<double>>[
      for (int i = 0; i < bowls.length; i++)
        <double>[for (int k = 0; k <= half; k++) k / half],
    ];
    final CubicBezier? under = CubicBezier.fit(
      lower,
      start: InkVector(right, 0),
      end: InkVector(-left, 0),
      parameters: evenly,
    );
    final CubicBezier? over = CubicBezier.fit(
      upper,
      start: InkVector(-left, 0),
      end: InkVector(right, 0),
      parameters: evenly,
    );
    if (under == null || over == null) return null;
    return (lower: under, upper: over);
  }

  /// How far the bowl of each of the font's a, g and p reaches, about its
  /// middle, in each direction (see [_polar]).
  static final Map<String, List<double>> _fontBowls = <String, List<double>>{
    for (final String letter in <String>['a', 'g', 'p'])
      if (_longest(<_Part>[
            for (final List<InkVector> stroke in _fontGlyph(letter))
              ..._partsOf(_prepared(stroke)),
          ], (_Part p) => p.isBowl)
          case final _Part bowl)
        letter: _polar(_normalizedBowl(bowl.points)),
  };

  /// The font's bowls taken together, direction by direction.
  static final List<double> _fontBowl = <double>[
    for (int k = 0; k < _bins; k++)
      _fontBowls.values.fold<double>(
            0,
            (double sum, List<double> r) => sum + r[k],
          ) /
          _fontBowls.length,
  ];

  /// [bowl] about the middle of its box, in its heights.
  static List<InkVector> _normalizedBowl(List<InkVector> bowl) {
    final _Box box = _Box.of(bowl);
    final double height = math.max(box.height, 0.5);
    return <InkVector>[
      for (final InkVector p in bowl) (p - box.center) * (1 / height),
    ];
  }

  /// How many directions a bowl's radius is read in.
  static const int _bins = 72;

  /// How far [points], about the origin, reach in each of [_bins]
  /// directions clockwise from +x: their outline, with any gap, where the
  /// bowl meets its stem, bridged straight across.
  static List<double> _polar(List<InkVector> points) {
    final List<double?> radii = List<double?>.filled(_bins, null);
    for (final InkVector p in densified(points, 0.02)) {
      double angle = math.atan2(p.y, p.x);
      if (angle < 0) angle += 2 * math.pi;
      final int bin = (angle / (2 * math.pi) * _bins).round() % _bins;
      radii[bin] = math.max(radii[bin] ?? 0, p.length);
    }
    final List<int> known = <int>[
      for (int k = 0; k < _bins; k++)
        if (radii[k] != null) k,
    ];
    if (known.isEmpty) return List<double>.filled(_bins, 0.5);
    List<double> out = List<double>.filled(_bins, 0);
    for (int k = 0; k < _bins; k++) {
      if (radii[k] != null) {
        out[k] = radii[k]!;
        continue;
      }
      // The nearest known directions either side, round the circle.
      int before = k;
      int after = k;
      int stepsBefore = 0;
      int stepsAfter = 0;
      do {
        before = (before - 1 + _bins) % _bins;
        stepsBefore++;
      } while (radii[before] == null);
      do {
        after = (after + 1) % _bins;
        stepsAfter++;
      } while (radii[after] == null);
      out[k] =
          radii[before]! +
          (radii[after]! - radii[before]!) *
              stepsBefore /
              (stepsBefore + stepsAfter);
    }
    for (int pass = 0; pass < 2; pass++) {
      out = <double>[
        for (int k = 0; k < _bins; k++)
          (out[(k - 1 + _bins) % _bins] + 2 * out[k] + out[(k + 1) % _bins]) /
              4,
      ];
    }
    return out;
  }

  static double _radiusAt(List<double> radii, double angle) {
    double turn = angle / (2 * math.pi);
    turn -= turn.floorToDouble();
    final double at = turn * _bins;
    final int k = at.floor();
    final double f = at - k;
    return radii[k % _bins] + (radii[(k + 1) % _bins] - radii[k % _bins]) * f;
  }

  static final Expando<List<double>> _polars = Expando<List<double>>();

  /// How far this hand's bowl reaches in each direction; null without one.
  List<double>? get _bowlRadii {
    final CubicBezier? lower = bowlLower;
    final CubicBezier? upper = bowlUpper;
    if (lower == null || upper == null) return null;
    return _polars[this] ??= _polar(<InkVector>[
      ...lower.sampled(180),
      ...upper.sampled(180).skip(1),
    ]);
  }

  static final Expando<List<InkVector>> _samples = Expando<List<InkVector>>();

  /// Where [curve], one along its chord from x = 0 to 1, is at [x].
  static double _yAt(CubicBezier curve, double x) {
    final List<InkVector> points = _samples[curve] ??= curve.sampled(64);
    if (x <= points.first.x) return points.first.y;
    for (int i = 1; i < points.length; i++) {
      final InkVector a = points[i - 1];
      final InkVector b = points[i];
      if ((a.x - x) * (b.x - x) <= 0) {
        final double span = b.x - a.x;
        return span.abs() < 1e-9 ? a.y : a.y + (b.y - a.y) * (x - a.x) / span;
      }
    }
    return points.last.y;
  }

  static final Expando<List<double>> _lengths = Expando<List<double>>();

  /// The point [share] of the way along [curve], by length.
  static InkVector _alongLength(CubicBezier curve, double share) {
    final List<InkVector> points = _samples[curve] ??= curve.sampled(64);
    final List<double> lengths = _lengths[curve] ??= () {
      final List<double> out = <double>[0];
      for (int i = 1; i < points.length; i++) {
        out.add(out.last + (points[i] - points[i - 1]).length);
      }
      return out;
    }();
    final double target = share.clamp(0.0, 1.0) * lengths.last;
    for (int i = 1; i < points.length; i++) {
      if (lengths[i] >= target) {
        final double step = lengths[i] - lengths[i - 1];
        final double f = step <= 0 ? 0 : (target - lengths[i - 1]) / step;
        return points[i - 1] + (points[i] - points[i - 1]) * f;
      }
    }
    return points.last;
  }

  // ---------------------------------------------------------------------
  // Drawing.

  /// [strokes], a glyph of [char] in the font's grid, drawn in these
  /// shapes: dots as the writer's, i and j dotted where theirs are, lines
  /// and curves bending as theirs do, bowls with [bowls] rounded as theirs,
  /// and with [tailed] the descender finished as their g's. [seed] makes
  /// each letter's lines a little different, as no two lines are alike.
  List<List<InkVector>> apply(
    String char,
    List<List<InkVector>> strokes, {
    required bool bowls,
    required bool tailed,
    double seed = 0,
  }) {
    if (strength <= 0 || isEmpty) return strokes;
    final HandFeatures reference = font;
    final double s = strength;

    final List<bool> isDot = <bool>[
      for (final List<InkVector> stroke in strokes)
        stroke.length == 1 || _extent(stroke) < 0.4,
    ];
    final List<List<InkVector>> dense = <List<InkVector>>[
      for (int i = 0; i < strokes.length; i++)
        isDot[i] ? strokes[i] : densified(strokes[i], _spacing),
    ];
    final List<List<_Part>> parts = <List<_Part>>[
      for (int i = 0; i < dense.length; i++)
        isDot[i] ? const <_Part>[] : _partsOf(dense[i]),
    ];
    // Upright lines a bowl may hang from.
    final List<_Part> stems = <_Part>[
      for (final List<_Part> stroke in parts)
        for (final _Part part in stroke)
          if (part.kind == HandPart.straight && part.lean < math.pi / 4) part,
    ];

    final List<List<InkVector>> out = <List<InkVector>>[];
    for (int i = 0; i < strokes.length; i++) {
      if (isDot[i]) {
        out.add(_dotted(char, strokes[i], dense, isDot, s));
        continue;
      }
      final List<InkVector> points = dense[i];
      final List<InkVector> drawn = List<InkVector>.of(points);
      int index = 0;
      for (final _Part part in parts[i]) {
        final double variation =
            1 + 0.25 * math.sin(seed * 1.37 + i * 2.3 + index * 0.71);
        index++;
        switch (part.kind) {
          case HandPart.straight:
            _bend(
              points,
              drawn,
              part,
              straight,
              reference.straight,
              s * variation,
            );
          case HandPart.diagonal:
            _bend(
              points,
              drawn,
              part,
              diagonal,
              reference.diagonal,
              s * variation,
            );
          case HandPart.curve:
            _arch(points, drawn, part, s);
          case HandPart.bowl:
            if (bowls) _round(points, drawn, part, stems, s);
        }
      }
      out.add(drawn);
    }
    return tailed && tail != null ? _tailed(out, s) : out;
  }

  /// A dot drawn as the writer's, and for an i or j, as high above its
  /// stem as theirs.
  List<InkVector> _dotted(
    String char,
    List<InkVector> stroke,
    List<List<InkVector>> strokes,
    List<bool> isDot,
    double s,
  ) {
    InkVector middle = _centroid(stroke);
    if ('ij'.contains(char) && dotLift != null) {
      InkVector? top;
      for (int i = 0; i < strokes.length; i++) {
        if (isDot[i]) continue;
        for (final InkVector p in strokes[i]) {
          if ((p.x - middle.x).abs() < 2 && (top == null || p.y < top.y)) {
            top = p;
          }
        }
      }
      if (top != null) {
        final InkVector lift = middle - top;
        middle = top + lift + (dotLift! - lift) * s;
      }
    }
    final CubicBezier? shape = dot;
    if (shape == null || shape.extent < 0.25) return <InkVector>[middle];
    return <InkVector>[
      for (final InkVector p in shape.sampled(12)) middle + p * s,
    ];
  }

  /// A line's course moved from the font's [reference] towards [shape].
  static void _bend(
    List<InkVector> points,
    List<InkVector> drawn,
    _Part part,
    CubicBezier? shape,
    CubicBezier? reference,
    double s,
  ) {
    if (shape == null || reference == null) return;
    final InkVector a = points[part.from];
    final InkVector b = points[part.to];
    final double length = (b - a).length;
    if (length < 1) return;
    final InkVector direction = canonicalLine((b - a) * (1 / length));
    final InkVector normal = InkVector(-direction.y, direction.x);
    for (int k = part.from + 1; k < part.to; k++) {
      final double t = alongLine(points[k], a, b).t.clamp(0.0, 1.0);
      final double moved = (_yAt(shape, t) - _yAt(reference, t)) * s * length;
      drawn[k] = points[k] + normal * moved;
    }
  }

  /// An open curve bent from the font's arch towards the writer's.
  void _arch(
    List<InkVector> points,
    List<InkVector> drawn,
    _Part part,
    double s,
  ) {
    final CubicBezier? shape = curve;
    final CubicBezier? reference = font.curve;
    if (shape == null || reference == null) return;
    final List<InkVector> run = points.sublist(part.from, part.to + 1);
    final ({InkVector along, InkVector across, double length, double side})
    axes = _curveAxes(run);
    if (axes.length < 1) return;
    // Matched by how far along each curve, not by where along the chord:
    // an arch that bends back past its chord's end reads the same way.
    final double total = pathLength(run);
    double walked = 0;
    for (int k = 1; k < run.length - 1; k++) {
      walked += (run[k] - run[k - 1]).length;
      InkVector moved =
          (_alongLength(shape, walked / total) -
              _alongLength(reference, walked / total)) *
          s;
      if (moved.length > 0.35) moved = moved * (0.35 / moved.length);
      drawn[part.from + k] =
          run[k] +
          (axes.along * moved.x + axes.across * (moved.y * axes.side)) *
              axes.length;
    }
  }

  /// A bowl rounded from the font's towards the writer's: each point's
  /// reach from the bowl's middle scaled, direction by direction, as the
  /// writer's bowl reaches against the font's. A bowl hanging from a stem
  /// keeps that side against it, and where it runs on into the rest of
  /// its stroke it eases back into it.
  void _round(
    List<InkVector> points,
    List<InkVector> drawn,
    _Part part,
    List<_Part> stems,
    double s,
  ) {
    final List<double>? writer = _bowlRadii;
    final List<double>? fontRadii = font._bowlRadii;
    if (writer == null || fontRadii == null) return;
    final List<InkVector> run = points.sublist(part.from, part.to + 1);
    final _Box box = _Box.of(run);
    final double height = math.max(box.height, 0.5);
    final List<InkVector> moved = <InkVector>[
      for (final InkVector p in run)
        () {
          final InkVector v = (p - box.center) * (1 / height);
          final double angle = math.atan2(v.y, v.x);
          final double theirs = _radiusAt(writer, angle);
          final double ours = math.max(_radiusAt(fontRadii, angle), 1e-3);
          final double ratio = (1 + s * (theirs / ours - 1)).clamp(0.6, 1.6);
          return box.center + v * (ratio * height);
        }(),
    ];
    // The side a stem holds stays where it was.
    double shift = 0;
    for (final _Part stem in stems) {
      final _Box line = _Box.of(<InkVector>[
        stem.points.first,
        stem.points.last,
      ]);
      if (line.bottom < box.top || line.top > box.bottom) continue;
      final double x = (line.left + line.right) / 2;
      final _Box now = _Box.of(moved);
      if ((x - box.left).abs() < 0.9) {
        shift = box.left - now.left;
      } else if ((x - box.right).abs() < 0.9) {
        shift = box.right - now.right;
      }
    }
    final List<double> along = <double>[0];
    for (int k = 1; k < run.length; k++) {
      along.add(along.last + (run[k] - run[k - 1]).length);
    }
    final double total = math.max(along.last, 1e-6);
    final bool easeStart = part.from > 0;
    final bool easeEnd = part.to < points.length - 1;
    for (int k = 0; k < run.length; k++) {
      double weight = 1;
      if (easeStart) weight = math.min(weight, along[k] / (total * 0.2));
      if (easeEnd) {
        weight = math.min(weight, (total - along[k]) / (total * 0.2));
      }
      weight = weight.clamp(0.0, 1.0);
      weight = weight * weight * (3 - 2 * weight);
      final InkVector target = moved[k] + InkVector(shift, 0);
      drawn[part.from + k] = run[k] + (target - run[k]) * weight;
    }
  }

  /// The descender's tail, from where it crosses the baseline, moved from
  /// the font's towards the writer's g, turned to the way this letter's
  /// stroke comes down into it.
  List<List<InkVector>> _tailed(List<List<InkVector>> strokes, double s) {
    final _Descender? found = _descender(strokes);
    if (found == null) return strokes;
    final List<InkVector> stroke = found.stroke;
    final InkVector heading = _heading(stroke, found.crossing, found.start);
    final double turn = math.atan2(heading.y, heading.x) - math.pi / 2;
    final double c = math.cos(turn);
    final double sn = math.sin(turn);
    final List<InkVector> theirs = <InkVector>[
      for (final InkVector p in tail!.sampled(48))
        found.start + InkVector(p.x * c - p.y * sn, p.x * sn + p.y * c),
    ];
    final List<InkVector> ours = <InkVector>[
      found.start,
      ...stroke.sublist(found.crossing + 1),
    ];
    const int count = 24;
    final List<InkVector> a = _evenly(ours, count);
    final List<InkVector> b = _evenly(theirs, count);
    final List<InkVector> drawn = <InkVector>[
      ...stroke.take(found.crossing + 1),
      if ((found.start - stroke[found.crossing]).length > 1e-6) found.start,
      for (int k = 1; k <= count; k++) a[k] + (b[k] - a[k]) * s,
    ];
    return <List<InkVector>>[
      for (int i = 0; i < strokes.length; i++)
        i == found.index
            ? (found.reversed ? drawn.reversed.toList() : drawn)
            : strokes[i],
    ];
  }

  /// [count] + 1 points evenly along [points], ends included.
  static List<InkVector> _evenly(List<InkVector> points, int count) {
    if (points.length < 2) {
      return List<InkVector>.filled(count + 1, points.first);
    }
    final double total = pathLength(points);
    if (total <= 0) return List<InkVector>.filled(count + 1, points.first);
    final List<InkVector> out = <InkVector>[points.first];
    int i = 1;
    double walked = 0;
    for (int k = 1; k < count; k++) {
      final double target = total * k / count;
      while (i < points.length - 1 &&
          walked + (points[i] - points[i - 1]).length < target) {
        walked += (points[i] - points[i - 1]).length;
        i++;
      }
      final double step = (points[i] - points[i - 1]).length;
      final double f = step == 0
          ? 0
          : ((target - walked) / step).clamp(0.0, 1.0);
      out.add(points[i - 1] + (points[i] - points[i - 1]) * f);
    }
    out.add(points.last);
    return out;
  }

  // ---------------------------------------------------------------------
  // Saving.

  Map<String, Object?> toJson() => <String, Object?>{
    'strength': strength,
    if (dot != null) 'dot': dot!.toJson(),
    if (dotLift != null) 'dotLift': <double>[dotLift!.x, dotLift!.y],
    if (bowlLower != null) 'bowlLower': bowlLower!.toJson(),
    if (bowlUpper != null) 'bowlUpper': bowlUpper!.toJson(),
    if (curve != null) 'curve': curve!.toJson(),
    if (tail != null) 'tail': tail!.toJson(),
    if (diagonal != null) 'diagonal': diagonal!.toJson(),
    if (straight != null) 'straight': straight!.toJson(),
  };

  /// Saved shapes; any that is missing or unreadable is null. Null for
  /// anything that is not a map.
  static HandFeatures? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? strength = json['strength'];
    final Object? lift = json['dotLift'];
    return HandFeatures(
      strength: strength is num && strength.isFinite ? strength.toDouble() : 1,
      dot: CubicBezier.fromJson(json['dot']),
      dotLift:
          lift is List &&
              lift.length == 2 &&
              lift.every((Object? v) => v is num && v.isFinite)
          ? InkVector((lift[0] as num).toDouble(), (lift[1] as num).toDouble())
          : null,
      bowlLower: CubicBezier.fromJson(json['bowlLower']),
      bowlUpper: CubicBezier.fromJson(json['bowlUpper']),
      curve: CubicBezier.fromJson(json['curve']),
      tail: CubicBezier.fromJson(json['tail']),
      diagonal: CubicBezier.fromJson(json['diagonal']),
      straight: CubicBezier.fromJson(json['straight']),
    ).clamped();
  }

  @override
  bool operator ==(Object other) =>
      other is HandFeatures &&
      other.strength == strength &&
      other.dot == dot &&
      other.dotLift == dotLift &&
      other.bowlLower == bowlLower &&
      other.bowlUpper == bowlUpper &&
      other.curve == curve &&
      other.tail == tail &&
      other.diagonal == diagonal &&
      other.straight == straight;

  @override
  int get hashCode => Object.hash(
    strength,
    dot,
    dotLift,
    bowlLower,
    bowlUpper,
    curve,
    tail,
    diagonal,
    straight,
  );

  @override
  String toString() => 'HandFeatures(${toJson()})';
}

/// The stroke a descender hangs from: which of a glyph's strokes it is,
/// whether it was turned round so that the descender ends it, the stroke
/// so turned, the last point before it crosses the baseline going down,
/// and where it crosses.
typedef _Descender = ({
  int index,
  bool reversed,
  List<InkVector> stroke,
  int crossing,
  InkVector start,
});

/// How finely strokes are sampled to find and reshape their parts, in grid
/// units.
const double _spacing = 0.35;

/// The shortest straight line that counts as one, in grid units.
const double _minLine = 2.5;

/// A turn sharper than this, in radians over a few samples, is a corner.
const double _corner = 1.0;

/// A curve that turns at least this far, in radians, is a bowl.
const double _bowlTurn = 170 * math.pi / 180;

/// An open curve turns at least this far, in radians.
const double _curveTurn = 40 * math.pi / 180;

/// Lines this close to upright or level, in radians, are straight; any
/// other line is diagonal.
const double _diagonalFrom = 10 * math.pi / 180;

/// [stroke] of a writer's, in the font's grid, sampled as the font's
/// strokes are and smoothed of the pen's tremor.
List<InkVector> _prepared(List<InkVector> stroke) => stroke.length == 1
    ? stroke
    : smoothedPoints(resampled(densified(stroke, _spacing), _spacing));

class _Part {
  _Part(this.kind, this.from, this.to, this.points);

  final HandPart kind;
  final int from;
  final int to;

  /// The stroke's points from [from] to [to], both included.
  final List<InkVector> points;

  bool get isBowl => kind == HandPart.bowl && _Box.of(points).center.y < 10.5;

  /// How far the line leans from upright, in radians, from 0 to π/2.
  double get lean {
    final InkVector chord = points.last - points.first;
    return math.atan2(chord.x.abs(), chord.y.abs());
  }

  /// A line near enough upright to be a stem.
  bool get isUpright =>
      (kind == HandPart.straight || kind == HandPart.diagonal) &&
      lean < math.pi / 6;

  double get length => pathLength(points);
}

_Part? _longest(List<_Part> parts, bool Function(_Part part) test) {
  _Part? best;
  for (final _Part part in parts) {
    if (test(part) && (best == null || part.length > best.length)) best = part;
  }
  return best;
}

/// The lines and curves of [points], a stroke sampled finely and evenly:
/// cut at its corners, then within each piece its straight runs, and
/// between them, the curves that turn far enough to be a bowl or, turning
/// one way, an open curve.
List<_Part> _partsOf(List<InkVector> points) {
  final int n = points.length;
  final List<_Part> parts = <_Part>[];
  if (n < 3) return parts;
  final List<double> turns = <double>[
    for (int i = 0; i < n; i++)
      i < 2 || i >= n - 2
          ? 0
          : signedTurn(points[i - 2], points[i], points[i + 2]).abs(),
  ];
  final List<int> cuts = <int>[0];
  for (int i = 2; i < n - 2; i++) {
    if (turns[i] > _corner &&
        turns[i] >= turns[i - 1] &&
        turns[i] > turns[i + 1]) {
      cuts.add(i);
    }
  }
  cuts.add(n - 1);
  for (int c = 0; c + 1 < cuts.length; c++) {
    final int from = cuts[c];
    final int to = cuts[c + 1];
    if (to - from < 2) continue;
    final List<InkVector> piece = points.sublist(from, to + 1);
    void curved(int a, int b) {
      if (b - a < 2) return;
      final List<InkVector> run = piece.sublist(a, b + 1);
      if (pathLength(run) < 1.5) return;
      final List<InkVector> smooth = smoothedPoints(run);
      double net = 0;
      double total = 0;
      for (int i = 1; i < smooth.length - 1; i++) {
        final double turn = signedTurn(smooth[i - 1], smooth[i], smooth[i + 1]);
        net += turn;
        total += turn.abs();
      }
      final HandPart? kind = net.abs() >= _bowlTurn
          ? HandPart.bowl
          : (net.abs() >= _curveTurn && net.abs() >= total * 0.6
                ? HandPart.curve
                : null);
      if (kind != null) parts.add(_Part(kind, from + a, from + b, run));
    }

    int previous = 0;
    for (final (int a, int b) in straightRuns(piece, minLength: _minLine)) {
      curved(previous, a);
      final InkVector chord = piece[b] - piece[a];
      final double lean = math.atan2(chord.x.abs(), chord.y.abs());
      parts.add(
        _Part(
          lean < _diagonalFrom || lean > math.pi / 2 - _diagonalFrom
              ? HandPart.straight
              : HandPart.diagonal,
          from + a,
          from + b,
          piece.sublist(a, b + 1),
        ),
      );
      previous = b;
    }
    curved(previous, piece.length - 1);
  }
  return parts;
}

double _extent(List<InkVector> stroke) {
  final _Box box = _Box.of(stroke);
  return math.max(box.width, box.height);
}

InkVector _centroid(List<InkVector> stroke) =>
    stroke.reduce((InkVector a, InkVector b) => a + b) * (1 / stroke.length);

class _Box {
  const _Box(this.left, this.top, this.right, this.bottom);

  factory _Box.of(List<InkVector> points) {
    double left = double.infinity;
    double top = double.infinity;
    double right = double.negativeInfinity;
    double bottom = double.negativeInfinity;
    for (final InkVector p in points) {
      left = math.min(left, p.x);
      top = math.min(top, p.y);
      right = math.max(right, p.x);
      bottom = math.max(bottom, p.y);
    }
    return _Box(left, top, right, bottom);
  }

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;
  InkVector get center => InkVector((left + right) / 2, (top + bottom) / 2);
}
