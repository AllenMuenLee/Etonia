import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../ink/ink_sample.dart';
import 'glyph_builder.dart';
import 'hand_features.dart';
import 'hand_glyphs.dart';
import 'stroke_profile.dart';
import 'stroke_runs.dart';

/// The traits of a hand, applied to the built-in font so that what the
/// assistant writes looks like the writer's own writing.
///
/// The writer picks one of the [HandwritingFont]s, each a style of its own,
/// or writes out every letter to make their own: then those letters are
/// kept as [glyphs], and the traits measured from them shape whatever else
/// the font writes. Lengths are in the font's grid, where a capital or an
/// ascender is 10 tall and the baseline is y = 10, with y growing
/// downwards.
@immutable
class HandwritingStyle {
  const HandwritingStyle({
    this.slant = 0.12,
    this.widthScale = 1,
    this.xHeight = 0.62,
    this.descenderScale = 1,
    this.descenderHook = 2.6,
    this.descenderLoop = 0,
    this.loopAspect = 1,
    this.lineProfile = standardLineProfile,
    this.curveProfile = CurveProfile.zero,
    this.crossTilt = 0,
    this.wordSpacing = 5,
    this.baselineJitter = 0.11,
    this.sizeJitter = 0.025,
    this.joined = false,
    this.features,
    this.glyphs,
  });

  /// The built-in hand: an easy forward lean and a hooked g.
  static const HandwritingStyle standard = HandwritingStyle();

  /// How far the top of a letter leans right of its foot, per unit of
  /// height: the tangent of the slant. Negative leans back.
  final double slant;

  /// How wide letters and the gaps between them are, against the font.
  final double widthScale;

  /// How tall a lowercase x is, as a share of an ascender.
  final double xHeight;

  /// How deep descenders reach below the baseline, against the font.
  final double descenderScale;

  /// How far the tail of g, j, and y curls left at its foot, in grid
  /// units. Negative curls right; zero drops straight.
  final double descenderHook;

  /// How often that tail loops back up to the baseline, from 0 (never) to
  /// 1 (always); at a half or more it does.
  final double descenderLoop;

  /// How wide bowls and loops (o, a, b, d, p, q) are, against the font.
  final double loopAspect;

  /// How straight lines develop along their length: how far they stray to
  /// the side of a ruler-straight line at each point, as a share of their
  /// length. Read along `canonicalLine`, positive to its right.
  final StrokeProfile lineProfile;

  /// How tightly curves bend, by the way they face, against the font's own
  /// (see [CurveProfile]): tight-bottomed bowls, flat-sided o's, hooks that
  /// close up.
  final CurveProfile curveProfile;

  /// The built-in hand's lines: a slight bow, a little stronger near the
  /// start, as a pen's line settles.
  static const StrokeProfile standardLineProfile = StrokeProfile(<double>[
    0.012,
    -0.006,
  ]);

  /// The angle of cross-strokes such as the bar of a t, in radians;
  /// negative rises to the right.
  final double crossTilt;

  /// How wide a space between words is, in grid units, besides the gaps
  /// either side of it: at 5, words stand about an n apart, as on paper.
  final double wordSpacing;

  /// How far letters wander above and below the baseline, in grid units.
  final double baselineJitter;

  /// How much letters' sizes vary, as a share of their size.
  final double sizeJitter;

  /// The shapes of the writer's own strokes, which the font's take on in
  /// place of [lineProfile], [curveProfile], and, where it has one, the
  /// tail [descenderHook] and [descenderLoop] would draw; null for the
  /// built-in hand.
  final HandFeatures? features;

  /// Whether lowercase letters within a word are joined up, as in
  /// cursive.
  final bool joined;

  /// Letters the writer wrote out themselves, written as they wrote them
  /// in place of the font's; null for a hand made from the font alone.
  final HandGlyphs? glyphs;

  /// The saved format: 3 added [lineProfile] and [curveProfile], 4 the
  /// [features] measured from the letters g, a, p, i and w, 5 made them
  /// cubic curves, 6 learned r directly, and 7 reduced calibration to 14
  /// letters by building b, f, v and D from shared handwriting variables.
  static const int version = 7;

  /// Gap between letters at [widthScale] 1, in grid units.
  static const double letterSpacing = 1.6;

  /// How tall a capital is, in grid units.
  static const double _capHeight = 10;

  /// Where the font's lowercase x-height is, in grid units from the top.
  static const double _fontXTop = 3.8;

  /// Letters whose tail [descenderHook] and [descenderLoop] shape.
  static const String _tailed = 'gjy';

  /// This style moved [amount] of the way towards [other]: 0 is this, 1 is
  /// [other].
  HandwritingStyle mix(HandwritingStyle other, double amount) {
    double lerp(double a, double b) => a + (b - a) * amount;
    return HandwritingStyle(
      slant: lerp(slant, other.slant),
      widthScale: lerp(widthScale, other.widthScale),
      xHeight: lerp(xHeight, other.xHeight),
      descenderScale: lerp(descenderScale, other.descenderScale),
      descenderHook: lerp(descenderHook, other.descenderHook),
      descenderLoop: lerp(descenderLoop, other.descenderLoop),
      loopAspect: lerp(loopAspect, other.loopAspect),
      lineProfile: lineProfile.mix(other.lineProfile, amount),
      curveProfile: curveProfile.mix(other.curveProfile, amount),
      crossTilt: lerp(crossTilt, other.crossTilt),
      wordSpacing: lerp(wordSpacing, other.wordSpacing),
      baselineJitter: lerp(baselineJitter, other.baselineJitter),
      sizeJitter: lerp(sizeJitter, other.sizeJitter),
      joined: amount < 0.5 ? joined : other.joined,
      features: HandFeatures.mix(features, other.features, amount),
      glyphs: amount < 0.5 ? glyphs : other.glyphs,
    );
  }

  /// This style with other ways for its lines and curves to develop.
  HandwritingStyle withProfiles({
    StrokeProfile? lineProfile,
    CurveProfile? curveProfile,
  }) => HandwritingStyle(
    slant: slant,
    widthScale: widthScale,
    xHeight: xHeight,
    descenderScale: descenderScale,
    descenderHook: descenderHook,
    descenderLoop: descenderLoop,
    loopAspect: loopAspect,
    lineProfile: lineProfile ?? this.lineProfile,
    curveProfile: curveProfile ?? this.curveProfile,
    crossTilt: crossTilt,
    wordSpacing: wordSpacing,
    baselineJitter: baselineJitter,
    sizeJitter: sizeJitter,
    joined: joined,
    features: features,
    glyphs: glyphs,
  );

  /// This style writing [glyphs] in place of the font's letters.
  HandwritingStyle withGlyphs(HandGlyphs? glyphs) => HandwritingStyle(
    slant: slant,
    widthScale: widthScale,
    xHeight: xHeight,
    descenderScale: descenderScale,
    descenderHook: descenderHook,
    descenderLoop: descenderLoop,
    loopAspect: loopAspect,
    lineProfile: lineProfile,
    curveProfile: curveProfile,
    crossTilt: crossTilt,
    wordSpacing: wordSpacing,
    baselineJitter: baselineJitter,
    sizeJitter: sizeJitter,
    joined: joined,
    features: features,
    glyphs: glyphs,
  );

  /// This style with every trait held to what a legible hand can have.
  HandwritingStyle clamped() => HandwritingStyle(
    slant: slant.clamp(-0.35, 0.6),
    widthScale: widthScale.clamp(0.65, 1.6),
    xHeight: xHeight.clamp(0.4, 0.85),
    descenderScale: descenderScale.clamp(0.4, 1.8),
    descenderHook: descenderHook.clamp(-2.5, 4),
    descenderLoop: descenderLoop.clamp(0, 1),
    loopAspect: loopAspect.clamp(0.6, 1.6),
    lineProfile: lineProfile.limited(0.05),
    // Radii from about two thirds to half as large again as the font's.
    curveProfile: curveProfile.limited(0.4),
    crossTilt: crossTilt.clamp(-0.25, 0.25),
    wordSpacing: wordSpacing.clamp(1, 12),
    baselineJitter: baselineJitter.clamp(0, 0.6),
    sizeJitter: sizeJitter.clamp(0, 0.12),
    joined: joined,
    features: features?.clamped(),
    glyphs: glyphs,
  );

  /// [strokes], one glyph of the font for [char] laid out from x = 0, in
  /// this hand, with how far the pen moves on after it. [seed] varies the
  /// wavering of lines from one letter to the next.
  ({List<List<InkVector>> strokes, double width}) shape(
    String char,
    List<List<InkVector>> strokes,
    double width, {
    double seed = 0,
  }) {
    final HandGlyph? own = glyphs?.lined(char);
    if (own != null) return (strokes: own.strokes, width: own.width);
    if (strokes.isEmpty) return (strokes: strokes, width: width * widthScale);
    final bool lowercase = _isLowercase(char);
    List<List<InkVector>> shaped = strokes;
    if (lowercase) {
      shaped = _mapped(shaped, (InkVector p) => InkVector(p.x, _lowerY(p.y)));
    }
    final HandFeatures? hand = features;
    if (hand != null && !hand.isEmpty) {
      // The writer's own shapes, in place of the traits that approximate
      // them.
      shaped = hand.apply(
        char,
        _tilted(shaped),
        bowls: lowercase || 'oO0'.contains(char),
        tailed: _tailed.contains(char),
        seed: seed,
      );
      if (hand.tail == null && _tailed.contains(char)) {
        shaped = _curlTail(shaped, _hookFor(char));
      }
      return _placed(shaped, seed, lines: hand.straight == null);
    }
    if (_tailed.contains(char)) {
      shaped = _curlTail(shaped, _hookFor(char));
    }
    if ((loopAspect - 1).abs() > 0.01 && (lowercase || 'oO0'.contains(char))) {
      shaped = _bowls(shaped, stems: lowercase);
    }
    shaped = _tilted(shaped);
    if (!curveProfile.isZero) {
      shaped = <List<InkVector>>[
        for (final List<InkVector> stroke in shaped)
          withCurves(
            stroke,
            curveProfile,
            size: _capHeight,
            // As finely, against a capital, as calibration reads a writer.
            spacing: 0.4,
          ),
      ];
    }
    return _placed(shaped, seed, lines: true);
  }

  /// [strokes], marks in the font's grid that are no letter, such as a
  /// fraction bar, a radical, or a bracket drawn as tall as a formula,
  /// drawn as this hand draws: its lines and curves bending as its do, its
  /// cross-strokes tilted, and leaning as its letters do about the
  /// baseline at y = 10. [seed] makes each mark a little different.
  List<List<InkVector>> mark(List<List<InkVector>> strokes, {double seed = 0}) {
    if (strokes.isEmpty) return strokes;
    // A bar across a formula drifts as a cross-stroke does, but a long one
    // turned by a letter's angle would run far off level: the longer it
    // is, the less it turns.
    List<List<InkVector>> shaped = <List<InkVector>>[
      for (final List<InkVector> stroke in strokes)
        () {
          final ({double left, double right, double top, double bottom}) box =
              _box(<List<InkVector>>[stroke]);
          final double length = box.right - box.left;
          if (crossTilt == 0 ||
              stroke.length < 2 ||
              length < 2 ||
              box.bottom - box.top > length * 0.3) {
            return stroke;
          }
          final double angle = crossTilt * math.min(1, 6 / length);
          final InkVector middle = InkVector(
            (box.left + box.right) / 2,
            (box.top + box.bottom) / 2,
          );
          final double c = math.cos(angle);
          final double sn = math.sin(angle);
          return <InkVector>[
            for (final InkVector p in stroke)
              middle +
                  InkVector(
                    (p.x - middle.x) * c - (p.y - middle.y) * sn,
                    (p.x - middle.x) * sn + (p.y - middle.y) * c,
                  ),
          ];
        }(),
    ];
    final HandFeatures? hand = features;
    if (hand != null && !hand.isEmpty) {
      // A mark is no i or j, so its dots stay where they are.
      shaped = hand.apply('-', shaped, bowls: false, tailed: false, seed: seed);
      if (hand.straight == null) shaped = _lines(shaped, seed);
    } else {
      if (!curveProfile.isZero) {
        shaped = <List<InkVector>>[
          for (final List<InkVector> stroke in shaped)
            stroke.length < 3
                ? stroke
                : withCurves(
                    stroke,
                    curveProfile,
                    size: _capHeight,
                    spacing: 0.4,
                  ),
        ];
      }
      shaped = _lines(shaped, seed);
    }
    return _mapped(
      shaped,
      (InkVector p) => InkVector(p.x + (10 - p.y) * slant, p.y),
    );
  }

  /// How far [char]'s tail curls. A g whose tail drops straight reads as a
  /// q, so it always curls; a y or j curled too far crosses its own stroke.
  double _hookFor(String char) => char == 'g'
      ? (descenderHook.abs() < 1.6
            ? (descenderHook < 0 ? -1.6 : 1.6)
            : descenderHook)
      : descenderHook.clamp(-2.2, 2.2);

  /// [shaped] laid from x = 0, its [lines] wavering as this hand's do, and
  /// leaning; with how far the pen moves on after it.
  ({List<List<InkVector>> strokes, double width}) _placed(
    List<List<InkVector>> shaped,
    double seed, {
    required bool lines,
  }) {
    // Shaping may move ink past the glyph's edges or short of them: it
    // starts at x = 0 again and is as wide as its ink.
    double left = double.infinity;
    double right = double.negativeInfinity;
    for (final List<InkVector> stroke in shaped) {
      for (final InkVector p in stroke) {
        left = math.min(left, p.x);
        right = math.max(right, p.x);
      }
    }
    final double advance = right - left;
    final double shift = -left;
    shaped = _mapped(shaped, (InkVector p) => InkVector(p.x + shift, p.y));
    if (lines) shaped = _lines(shaped, seed);
    return (
      strokes: _mapped(
        shaped,
        (InkVector p) => InkVector(p.x * widthScale + (10 - p.y) * slant, p.y),
      ),
      width: advance * widthScale,
    );
  }

  static bool _isLowercase(String char) =>
      char.length == 1 &&
      char.codeUnitAt(0) >= 0x61 &&
      char.codeUnitAt(0) <= 0x7A;

  static List<List<InkVector>> _mapped(
    List<List<InkVector>> strokes,
    InkVector Function(InkVector point) map,
  ) => <List<InkVector>>[
    for (final List<InkVector> stroke in strokes)
      <InkVector>[...stroke.map(map)],
  ];

  /// A lowercase letter's [y] with its x-height at [xHeight] and its
  /// descender [descenderScale] deep; the ascender line stays put.
  double _lowerY(double y) {
    final double xTop = 10 - 10 * xHeight;
    if (y >= 10) return 10 + (y - 10) * descenderScale;
    if (y >= _fontXTop) {
      return 10 - (10 - y) / (10 - _fontXTop) * (10 - xTop);
    }
    return xTop * y / _fontXTop;
  }

  /// The descender's tail drawn again from where it crosses the baseline:
  /// on down the way it was heading, then curled [hook] to the side, and looped back up when [descenderLoop] says so.
  List<List<InkVector>> _curlTail(List<List<InkVector>> strokes, double hook) {
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
    if (strokeIndex < 0) return strokes;
    List<InkVector> stroke = strokes[strokeIndex];
    // Worked on as if the tail ends the stroke.
    final bool reversed = deepest < stroke.length / 2;
    if (reversed) {
      stroke = stroke.reversed.toList();
      deepest = stroke.length - 1 - deepest;
    }
    int crossing = -1;
    for (int i = deepest - 1; i >= 0; i--) {
      if (stroke[i].y <= 10) {
        crossing = i;
        break;
      }
    }
    if (crossing < 0) return strokes;
    final InkVector a = stroke[crossing];
    final InkVector b = stroke[crossing + 1];
    final InkVector start = b.y == a.y
        ? a
        : a + (b - a) * ((10 - a.y) / (b.y - a.y));
    final double down = stroke[deepest].y - 10;
    // On the way the stroke crosses the baseline, down to the old depth;
    // towards the old foot where it crosses nearly flat.
    final InkVector crossingStep = b - a;
    final InkVector heading = crossingStep.y > crossingStep.length * 0.3
        ? crossingStep * (down / crossingStep.y)
        : stroke[deepest] - start;
    final InkVector foot = start + heading;
    final List<InkVector> tail;
    if (descenderLoop >= 0.5) {
      // A narrow teardrop: down past the foot, round to the left, and back
      // up to cross the stem at the baseline.
      final double side = hook < 0 ? -1 : 1;
      final double reach = hook.abs().clamp(1.2, down * 0.7);
      final InkVector bottom = InkVector(
        foot.x - side * reach * 0.4,
        10 + down,
      );
      tail = <InkVector>[
        ..._cubic(start, start + heading * 0.75, foot, bottom),
        ..._cubic(
          bottom,
          bottom + InkVector(-side * reach * 0.8, 0),
          InkVector(start.x - side * reach * 0.7, 10 + down * 0.15),
          InkVector(start.x + side * 0.5, 9.8),
        ).skip(1),
      ];
    } else {
      tail = _cubic(
        start,
        start + heading * 0.85,
        InkVector(foot.x - hook * 0.2, 10 + down),
        InkVector(
          foot.x - hook,
          10 + down - math.min(hook.abs() * 0.35, down * 0.3),
        ),
      );
    }
    final List<InkVector> drawn = <InkVector>[
      ...stroke.take(crossing + 1),
      if ((start - a).length > 1e-6) start,
      ...tail.skip(1),
    ];
    return <List<InkVector>>[
      for (int s = 0; s < strokes.length; s++)
        s == strokeIndex
            ? (reversed ? drawn.reversed.toList() : drawn)
            : strokes[s],
    ];
  }

  /// Bowls widened or narrowed by [loopAspect]: a closed stroke about the
  /// side where it meets the rest of its letter, or its middle; with
  /// [stems], the ink of a stroke that has a stem, about the stem.
  List<List<InkVector>> _bowls(
    List<List<InkVector>> strokes, {
    required bool stems,
  }) {
    final List<List<InkVector>> out = <List<InkVector>>[];
    for (int s = 0; s < strokes.length; s++) {
      final List<InkVector> stroke = strokes[s];
      if (stroke.length < 3) {
        out.add(stroke);
        continue;
      }
      final ({double left, double right, double top, double bottom}) box = _box(
        <List<InkVector>>[stroke],
      );
      final double size = math.max(box.right - box.left, box.bottom - box.top);
      final bool closed =
          size >= 2 && (stroke.first - stroke.last).length < size * 0.3;
      double? anchor;
      if (closed) {
        anchor = (box.left + box.right) / 2;
        for (int o = 0; o < strokes.length; o++) {
          if (o == s) continue;
          final ({double left, double right, double top, double bottom}) other =
              _box(<List<InkVector>>[strokes[o]]);
          if ((other.right - box.left).abs() < 0.6 ||
              (other.left - box.left).abs() < 0.6) {
            anchor = box.left;
          } else if ((other.left - box.right).abs() < 0.6 ||
              (other.right - box.right).abs() < 0.6) {
            anchor = box.right;
          }
        }
      } else if (stems) {
        // The longest near-vertical line in the stroke.
        double longest = 4.5;
        for (int i = 1; i < stroke.length; i++) {
          final InkVector step = stroke[i] - stroke[i - 1];
          if (step.x.abs() < step.y.abs() * 0.12 && step.length > longest) {
            longest = step.length;
            anchor = (stroke[i].x + stroke[i - 1].x) / 2;
          }
        }
      }
      if (anchor == null) {
        out.add(stroke);
        continue;
      }
      final double about = anchor;
      out.add(<InkVector>[
        for (final InkVector p in stroke)
          InkVector(about + (p.x - about) * loopAspect, p.y),
      ]);
    }
    return out;
  }

  /// Cross-strokes, such as the bar of a t, turned about their middles by
  /// [crossTilt]; the strokes they are part of follow their ends. Done on
  /// the font's own segments, before anything divides them.
  List<List<InkVector>> _tilted(List<List<InkVector>> strokes) {
    if (crossTilt == 0) return strokes;
    final double c = math.cos(crossTilt);
    final double sn = math.sin(crossTilt);
    return <List<InkVector>>[
      for (final List<InkVector> original in strokes)
        () {
          final List<InkVector> stroke = List<InkVector>.of(original);
          for (int i = 1; i < stroke.length; i++) {
            final InkVector step = stroke[i] - stroke[i - 1];
            if (step.length < 2 || step.y.abs() >= step.x.abs() * 0.3) {
              continue;
            }
            final InkVector middle = (stroke[i] + stroke[i - 1]) * 0.5;
            InkVector turn(InkVector p) {
              final InkVector d = p - middle;
              return middle + InkVector(d.x * c - d.y * sn, d.x * sn + d.y * c);
            }

            stroke[i - 1] = turn(stroke[i - 1]);
            stroke[i] = turn(stroke[i]);
          }
          return stroke;
        }(),
    ];
  }

  /// Straight lines straying from straight along their length by
  /// [lineProfile], as this hand's do. [seed] makes each letter's lines a
  /// little different, smoothly, so no line is drawn with a saw's teeth.
  List<List<InkVector>> _lines(List<List<InkVector>> strokes, double seed) {
    if (lineProfile.isZero) return strokes;
    final List<List<InkVector>> out = <List<InkVector>>[];
    for (int s = 0; s < strokes.length; s++) {
      final List<InkVector> stroke = strokes[s];
      // The lines calibration would find, found the same way, each
      // straying from straight as the hand's do. Their ends stay put, so
      // the rest of the stroke meets them as before.
      final List<InkVector> line = densified(stroke, _lineSpacing);
      int run = 0;
      for (final (int from, int to) in straightRuns(
        line,
        minLength: _minLine,
      )) {
        // How strongly this letter's lines take the hand's shape: a little
        // different each time, as no two lines are alike.
        final double strength =
            1 + 0.3 * math.sin(seed * 1.37 + s * 2.3 + run * 0.71);
        run++;
        final InkVector a = line[from];
        final InkVector b = line[to];
        final double length = (b - a).length;
        final InkVector direction = canonicalLine((b - a) * (1 / length));
        final InkVector normal = InkVector(-direction.y, direction.x);
        for (int k = from + 1; k < to; k++) {
          final double t = alongLine(line[k], a, b).t.clamp(0.0, 1.0);
          line[k] = line[k] + normal * (length * strength * lineProfile.at(t));
        }
      }
      out.add(line);
    }
    return out;
  }

  /// How finely the font's strokes are sampled to find and shape their
  /// lines: as finely, against a capital, as calibration samples the
  /// writer's.
  static const double _lineSpacing = 0.5;

  /// The shortest line whose course is shaped: as calibration measures.
  static const double _minLine = 3.5;

  static List<InkVector> _cubic(
    InkVector p0,
    InkVector p1,
    InkVector p2,
    InkVector p3,
  ) {
    const int steps = 10;
    return <InkVector>[
      for (int i = 0; i <= steps; i++)
        () {
          final double t = i / steps;
          final double u = 1 - t;
          return p0 * (u * u * u) +
              p1 * (3 * u * u * t) +
              p2 * (3 * u * t * t) +
              p3 * (t * t * t);
        }(),
    ];
  }

  static ({double left, double right, double top, double bottom}) _box(
    List<List<InkVector>> strokes,
  ) {
    double left = double.infinity;
    double right = double.negativeInfinity;
    double top = double.infinity;
    double bottom = double.negativeInfinity;
    for (final List<InkVector> stroke in strokes) {
      for (final InkVector p in stroke) {
        left = math.min(left, p.x);
        right = math.max(right, p.x);
        top = math.min(top, p.y);
        bottom = math.max(bottom, p.y);
      }
    }
    return (left: left, right: right, top: top, bottom: bottom);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'version': version,
    'slant': slant,
    'widthScale': widthScale,
    'xHeight': xHeight,
    'descenderScale': descenderScale,
    'descenderHook': descenderHook,
    'descenderLoop': descenderLoop,
    'loopAspect': loopAspect,
    'lineProfile': lineProfile.toJson(),
    'curveProfile': curveProfile.toJson(),
    'crossTilt': crossTilt,
    'wordSpacing': wordSpacing,
    'baselineJitter': baselineJitter,
    'sizeJitter': sizeJitter,
    if (joined) 'joined': true,
    if (features != null) 'features': features!.toJson(),
    if (glyphs != null) 'glyphs': glyphs!.toJson(),
  };

  /// Reads a saved style; a trait that is missing or unreadable is the
  /// [standard] one. Null for anything that is not a saved style of this
  /// [version]: a style saved before the hand's shapes were measured from
  /// its letters is calibrated again.
  static HandwritingStyle? fromJson(Object? json) {
    if (json is! Map || json['version'] != version) return null;
    double read(String key, double fallback) {
      final Object? value = json[key];
      return value is num && value.isFinite ? value.toDouble() : fallback;
    }

    const HandwritingStyle d = standard;
    return HandwritingStyle(
      slant: read('slant', d.slant),
      widthScale: read('widthScale', d.widthScale),
      xHeight: read('xHeight', d.xHeight),
      descenderScale: read('descenderScale', d.descenderScale),
      descenderHook: read('descenderHook', d.descenderHook),
      descenderLoop: read('descenderLoop', d.descenderLoop),
      loopAspect: read('loopAspect', d.loopAspect),
      lineProfile: StrokeProfile.fromJson(json['lineProfile']) ?? d.lineProfile,
      curveProfile:
          CurveProfile.fromJson(json['curveProfile']) ?? d.curveProfile,
      crossTilt: read('crossTilt', d.crossTilt),
      // Calibration has no words to measure a space from, so a saved one
      // is the built-in hand's as it was then: it follows the built-in one.
      wordSpacing: d.wordSpacing,
      baselineJitter: read('baselineJitter', d.baselineJitter),
      sizeJitter: read('sizeJitter', d.sizeJitter),
      joined: json['joined'] == true,
      features: HandFeatures.fromJson(json['features']),
      glyphs: rebuiltGlyphs(HandGlyphs.fromJson(json['glyphs'])),
    ).clamped();
  }

  @override
  bool operator ==(Object other) =>
      other is HandwritingStyle &&
      other.slant == slant &&
      other.widthScale == widthScale &&
      other.xHeight == xHeight &&
      other.descenderScale == descenderScale &&
      other.descenderHook == descenderHook &&
      other.descenderLoop == descenderLoop &&
      other.loopAspect == loopAspect &&
      other.lineProfile == lineProfile &&
      other.curveProfile == curveProfile &&
      other.crossTilt == crossTilt &&
      other.wordSpacing == wordSpacing &&
      other.baselineJitter == baselineJitter &&
      other.sizeJitter == sizeJitter &&
      other.joined == joined &&
      other.features == features &&
      other.glyphs == glyphs;

  @override
  int get hashCode => Object.hash(
    slant,
    widthScale,
    xHeight,
    descenderScale,
    descenderHook,
    descenderLoop,
    loopAspect,
    lineProfile,
    curveProfile,
    crossTilt,
    wordSpacing,
    baselineJitter,
    sizeJitter,
    joined,
    features,
    glyphs,
  );

  @override
  String toString() => 'HandwritingStyle(${toJson()..remove('version')})';
}
