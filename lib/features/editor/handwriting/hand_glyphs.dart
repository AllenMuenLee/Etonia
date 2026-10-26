import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../ink/ink_sample.dart';

/// One letter in the writer's own hand: its strokes in the font's grid,
/// from x = 0, with the baseline at y = 10 and a capital 10 tall.
@immutable
class HandGlyph {
  const HandGlyph(this.width, this.strokes);

  /// How far the pen moves on after the letter, without the gap to the
  /// next one.
  final double width;
  final List<List<InkVector>> strokes;
}

/// The letters of the writer's own font, by character: those they wrote
/// out, smoothed, and those built from their strokes. The assistant writes
/// these as they are, lined up ([lined]); anything else in the built-in
/// font.
@immutable
class HandGlyphs {
  HandGlyphs(
    Map<String, HandGlyph> glyphs, {
    this.built = '',
    this.builtSlant = 0,
  }) : _glyphs = Map<String, HandGlyph>.unmodifiable(glyphs);

  final Map<String, HandGlyph> _glyphs;

  /// The letters built from the others rather than written, leaning
  /// [builtSlant]. They are built again whenever the font is read, so they
  /// follow the builder as it improves.
  final String built;
  final double builtSlant;

  HandGlyph? operator [](String char) => _glyphs[char];

  Iterable<String> get characters => _glyphs.keys;

  bool get isEmpty => _glyphs.isEmpty;

  /// [char] as it is written in a line of text: its foot on the baseline,
  /// as every letter's is, or, for one with a tail, half above the line
  /// and half below, as tall above it as the small letters are; and an o
  /// closed. Each letter was written in a box of its own, a little above
  /// or below the line, which beside its neighbours reads as letters
  /// bouncing.
  HandGlyph? lined(String char) => _lined[char];

  late final Map<String, HandGlyph> _lined = _line(_glyphs, builtSlant);

  /// Letters with a tail below the line.
  static const String _tails = 'gjpqy';

  /// Letters and digits, which sit on the line; punctuation keeps its
  /// place.
  static final RegExp _sits = RegExp('[A-Za-z0-9]');

  static Map<String, HandGlyph> _line(
    Map<String, HandGlyph> glyphs,
    double slant,
  ) {
    final Map<String, HandGlyph> out = <String, HandGlyph>{};
    for (final MapEntry<String, HandGlyph> entry in glyphs.entries) {
      final String char = entry.key;
      HandGlyph glyph = entry.value;
      if ('oO0'.contains(char)) glyph = closed(glyph);
      if (char == 'g') glyph = _bowlClosed(glyph);
      if (char == 't') glyph = _crossed(glyph);
      if ('ij'.contains(char)) glyph = _dotted(glyph);
      if (char == 'I') glyph = _serifedCapitalI(glyph);
      if (_sits.hasMatch(char) && !_tails.contains(char)) {
        final double bottom = _bottom(glyph.strokes);
        if (bottom.isFinite) {
          glyph = _mappedY(glyph, (double y) => y + 10 - bottom);
        }
      }
      out[char] = glyph;
    }
    // Where the small letters reach up to, once on the line.
    final List<double> tops = <double>[
      for (final String char in 'acemnorsuvwxz'.split(''))
        if (out[char] case final HandGlyph glyph) _top(glyph.strokes),
    ]..removeWhere((double top) => !top.isFinite || top >= 9.5);
    tops.sort();
    final double xTop = tops.isEmpty ? 4 : tops[tops.length ~/ 2];
    final double depth = 10 - xTop;
    for (final String char in _tails.split('')) {
      final HandGlyph? glyph = out[char];
      if (glyph == null) continue;
      // The dot of a j is left out of where the letter starts.
      final double top = _top(<List<InkVector>>[
        for (final List<InkVector> stroke in glyph.strokes)
          if (_length(stroke) > 1.5) stroke,
      ]);
      final double bottom = _bottom(glyph.strokes);
      if (!top.isFinite || bottom - top < 1) continue;
      // Where the writer's line ran through it, kept within its middle.
      final double line = 10.0.clamp(
        top + (bottom - top) * 0.3,
        top + (bottom - top) * 0.7,
      );
      out[char] = _mappedY(
        glyph,
        (double y) => y <= line
            ? 10 - (line - y) / (line - top) * depth
            : 10 + (y - line) / (bottom - line) * depth,
      );
    }
    // An i's stem as tall as the small letters, should the writer's have
    // fallen short, and the dot of an i or a j as far above its stem as
    // theirs was, within reason: a dot written far off, or over a stem cut
    // short, floats free of its letter.
    for (final String char in <String>['i', 'j']) {
      final HandGlyph? glyph = out[char];
      final HandGlyph? written = glyphs[char];
      if (glyph == null || written == null) continue;
      final double? gap = _dotGap(_dotted(written));
      out[char] = _dotPlaced(
        glyph,
        gap: gap?.clamp(depth * 0.2, depth * 0.5),
        stemTop: char == 'i' ? xTop : null,
      );
    }
    // Each letter from where its ink starts, as wide as its ink: what was
    // moved above leaves its old width behind it, and a tail swept back
    // under the letter before is left out of where the letter starts and
    // ends, as a pen moving on along the line leaves it out.
    for (final String char in out.keys.toList()) {
      if (!_sits.hasMatch(char)) continue;
      out[char] = _anchored(
        out[char]!,
        tailed: _tails.contains(char),
        low: 10 - depth * 0.45,
      );
    }
    return out;
  }

  /// [glyph] moved to start at x = 0 and as wide as its ink, or for one
  /// [tailed], as the ink of its body above the tail. A flick off its
  /// foot, along the line below [low], is mostly left out of its width:
  /// in a word the pen runs on from it into the next letter, so the next
  /// one starts beside it, not after it.
  static HandGlyph _anchored(
    HandGlyph glyph, {
    required bool tailed,
    required double low,
  }) {
    double left = double.infinity;
    double right = double.negativeInfinity;
    for (final bool bodyOnly in <bool>[if (tailed) true, false]) {
      for (final List<InkVector> stroke in glyph.strokes) {
        for (final InkVector p in stroke) {
          if (bodyOnly && p.y > 10.3) continue;
          left = math.min(left, p.x);
          right = math.max(right, p.x);
        }
      }
      if (right - left > 0.5) break;
      left = double.infinity;
      right = double.negativeInfinity;
    }
    if (!left.isFinite) return glyph;
    double width = right - left;
    final List<InkVector>? exit = glyph.strokes.isEmpty
        ? null
        : glyph.strokes.last;
    if (!tailed && exit != null && exit.length > 3) {
      // The flick: what is left after the pen last moved more down than
      // along.
      int from = exit.length - 1;
      while (from > 0) {
        final InkVector step = exit[from] - exit[from - 1];
        if (step.y > step.x.abs()) break;
        from--;
      }
      final List<InkVector> flick = exit.sublist(from);
      final bool along =
          from > 0 &&
          flick.every((InkVector p) => p.y >= low && p.x >= flick.first.x);
      if (along && flick.last.x - flick.first.x > (10 - low) * 0.5) {
        double body = double.negativeInfinity;
        for (final List<InkVector> stroke in glyph.strokes) {
          final int end = identical(stroke, exit) ? from + 1 : stroke.length;
          for (final InkVector p in stroke.take(end)) {
            body = math.max(body, p.x);
          }
        }
        if (body.isFinite && body < right) {
          width = body + (right - body) * 0.3 - left;
        }
      }
    }
    return HandGlyph(width, <List<InkVector>>[
      for (final List<InkVector> stroke in glyph.strokes)
        <InkVector>[
          for (final InkVector p in stroke) InkVector(p.x - left, p.y),
        ],
    ]);
  }

  /// [glyph], a t, with its bar slid along to cross the stem where the
  /// writer drew it beside the stem, not across it: a bar run up to the
  /// stem's side and stopped is read as a z or a τ.
  static HandGlyph _crossed(HandGlyph glyph) {
    List<InkVector>? stem;
    List<InkVector>? bar;
    for (final List<InkVector> stroke in glyph.strokes) {
      if (stroke.length < 2) continue;
      final double wide = _right(stroke) - _left(stroke);
      final double tall =
          _bottom(<List<InkVector>>[stroke]) - _top(<List<InkVector>>[stroke]);
      if (wide > tall * 2.5 &&
          (bar == null || wide > _right(bar) - _left(bar))) {
        bar = stroke;
      } else if (stem == null ||
          tall >
              _bottom(<List<InkVector>>[stem]) -
                  _top(<List<InkVector>>[stem])) {
        stem = stroke;
      }
    }
    if (stem == null || bar == null || identical(stem, bar)) return glyph;
    final double y =
        (_top(<List<InkVector>>[bar]) + _bottom(<List<InkVector>>[bar])) / 2;
    // Where the stem is at the bar's height.
    double? x;
    for (int i = 1; i < stem.length; i++) {
      final InkVector a = stem[i - 1];
      final InkVector b = stem[i];
      if ((a.y - y) * (b.y - y) <= 0 && a.y != b.y) {
        x = a.x + (b.x - a.x) * (y - a.y) / (b.y - a.y);
        break;
      }
    }
    if (x == null) return glyph;
    final double left = _left(bar);
    final double width = _right(bar) - left;
    final double share = (x - left) / width;
    if (share > 0.2 && share < 0.8) return glyph;
    final double dx = x - (left + width * 0.4);
    return HandGlyph(glyph.width, <List<InkVector>>[
      for (final List<InkVector> stroke in glyph.strokes)
        if (identical(stroke, bar))
          <InkVector>[
            for (final InkVector p in stroke) InkVector(p.x + dx, p.y),
          ]
        else
          stroke,
    ]);
  }

  /// [glyph], a g, with its bowl closed over the top where the writer
  /// left it open: a g begun down the left of its bowl, as the arm of a y
  /// is, is read as a y. The pen now sets off from the top of the stem,
  /// over the bowl, and on as the writer went.
  static HandGlyph _bowlClosed(HandGlyph glyph) {
    List<InkVector>? main;
    for (final List<InkVector> stroke in glyph.strokes) {
      if (main == null || _length(stroke) > _length(main)) main = stroke;
    }
    if (main == null || main.length < 8) return glyph;
    // Down the bowl's left side to its foot, and up to the stem's top.
    int foot = 0;
    int k = 1;
    for (; k < main.length; k++) {
      if (main[k].y > main[foot].y) {
        foot = k;
      } else if (main[foot].y - main[k].y > 0.4) {
        break;
      }
    }
    if (foot == 0 || k >= main.length) return glyph;
    int join = foot;
    for (k = foot + 1; k < main.length; k++) {
      if (main[k].y < main[join].y) {
        join = k;
      } else if (main[k].y - main[join].y > 0.4) {
        break;
      }
    }
    final InkVector start = main.first;
    final InkVector top = main[join];
    double bowlLeft = double.infinity;
    for (final InkVector p in main.take(join + 1)) {
      bowlLeft = math.min(bowlLeft, p.x);
    }
    final double bowl = top.x - bowlLeft;
    InkVector into = InkVector.zero;
    for (final InkVector p in main.skip(1)) {
      if ((p - start).length >= bowl * 0.3) {
        into = (p - start) * (1 / (p - start).length);
        break;
      }
    }
    // Begun at the top of the bowl, or near the stem: closed as written.
    if (bowl < 1 || into.y < 0.6 || start.x > top.x - bowl * 0.4) {
      return glyph;
    }
    final InkVector c1 = top + InkVector(-bowl * 0.3, -bowl * 0.35);
    final InkVector c2 = start - into * (bowl * 0.5);
    const int steps = 8;
    final List<InkVector> over = <InkVector>[
      for (int i = 0; i < steps; i++)
        () {
          final double t = i / steps;
          final double u = 1 - t;
          return top * (u * u * u) +
              c1 * (3 * u * u * t) +
              c2 * (3 * u * t * t) +
              start * (t * t * t);
        }(),
    ];
    return HandGlyph(glyph.width, <List<InkVector>>[
      for (final List<InkVector> stroke in glyph.strokes)
        identical(stroke, main) ? <InkVector>[...over, ...stroke] : stroke,
    ]);
  }

  static double _left(List<InkVector> stroke) =>
      stroke.fold(double.infinity, (double v, InkVector p) => math.min(v, p.x));

  static double _right(List<InkVector> stroke) => stroke.fold(
    double.negativeInfinity,
    (double v, InkVector p) => math.max(v, p.x),
  );

  /// The tallest stroke of [strokes] with more than one point.
  static List<InkVector>? _stemOf(List<List<InkVector>> strokes) {
    List<InkVector>? stem;
    double tallest = 0;
    for (final List<InkVector> stroke in strokes) {
      if (stroke.length < 2) continue;
      final double tall =
          _bottom(<List<InkVector>>[stroke]) - _top(<List<InkVector>>[stroke]);
      if (stem == null || tall > tallest) {
        stem = stroke;
        tallest = tall;
      }
    }
    return stem;
  }

  /// How far above the top of [glyph]'s stem its dot is; null with no dot.
  static double? _dotGap(HandGlyph glyph) {
    final List<InkVector>? stem = _stemOf(glyph.strokes);
    if (stem == null) return null;
    final double top = _top(<List<InkVector>>[stem]);
    for (final List<InkVector> stroke in glyph.strokes) {
      if (stroke.length == 1 && stroke.single.y < top) {
        return top - stroke.single.y;
      }
    }
    return null;
  }

  /// [glyph], an i or a j dotted ([_dotted]), with its stem grown from its
  /// foot, the way it leans, to reach [stemTop] if it falls well short of
  /// it, and its dot [gap] above the stem's top.
  static HandGlyph _dotPlaced(HandGlyph glyph, {double? gap, double? stemTop}) {
    final List<InkVector>? stem = _stemOf(glyph.strokes);
    if (stem == null) return glyph;
    List<InkVector> grown = stem;
    InkVector foot = stem.first;
    for (final InkVector p in stem) {
      if (p.y > foot.y) foot = p;
    }
    final double written = _top(<List<InkVector>>[stem]);
    final double tall = foot.y - written;
    if (stemTop != null && tall > 0.1 && tall < (foot.y - stemTop) * 0.75) {
      final double f = (foot.y - stemTop) / tall;
      grown = <InkVector>[
        for (final InkVector p in stem) foot + (p - foot) * f,
      ];
    }
    InkVector top = grown.first;
    for (final InkVector p in grown) {
      if (p.y < top.y) top = p;
    }
    return HandGlyph(glyph.width, <List<InkVector>>[
      for (final List<InkVector> stroke in glyph.strokes)
        if (identical(stroke, stem))
          grown
        else if (gap != null && stroke.length == 1 && stroke.single.y < written)
          <InkVector>[InkVector(top.x, top.y - gap)]
        else
          stroke,
    ]);
  }

  /// [glyph] with unmistakable top and bottom bars. Even when a sample in
  /// the optional capitals page is only an upright, capital I must not be
  /// rendered as the vertical-bar symbol.
  static HandGlyph _serifedCapitalI(HandGlyph glyph) {
    double left = double.infinity;
    double right = double.negativeInfinity;
    double top = double.infinity;
    double bottom = double.negativeInfinity;
    for (final List<InkVector> stroke in glyph.strokes) {
      for (final InkVector p in stroke) {
        left = math.min(left, p.x);
        right = math.max(right, p.x);
        top = math.min(top, p.y);
        bottom = math.max(bottom, p.y);
      }
    }
    if (!left.isFinite || bottom - top < 1) return glyph;
    final double height = bottom - top;
    bool horizontalAt(double y) {
      for (final List<InkVector> stroke in glyph.strokes) {
        if (stroke.length < 2) continue;
        double strokeLeft = double.infinity;
        double strokeRight = double.negativeInfinity;
        double strokeTop = double.infinity;
        double strokeBottom = double.negativeInfinity;
        for (final InkVector p in stroke) {
          strokeLeft = math.min(strokeLeft, p.x);
          strokeRight = math.max(strokeRight, p.x);
          strokeTop = math.min(strokeTop, p.y);
          strokeBottom = math.max(strokeBottom, p.y);
        }
        final double away = (strokeTop + strokeBottom) / 2 - y;
        if (away.abs() <= height * 0.15 &&
            strokeRight - strokeLeft >
                math.max(strokeBottom - strokeTop, 0.1) * 2.5) {
          return true;
        }
      }
      return false;
    }

    final double width = math.max(right - left, height * 0.52);
    final double center = (left + right) / 2;
    final List<List<InkVector>> strokes = <List<InkVector>>[
      ...glyph.strokes,
      if (!horizontalAt(top))
        <InkVector>[
          InkVector(center - width / 2, top),
          InkVector(center + width / 2, top),
        ],
      if (!horizontalAt(bottom))
        <InkVector>[
          InkVector(center - width / 2, bottom),
          InkVector(center + width / 2, bottom),
        ],
    ];
    return HandGlyph(math.max(glyph.width, width), strokes);
  }

  /// [glyph] with a stroke that nearly closes on itself closed. The pen's
  /// landing and lift, whose hooks and slowing turn the wrong way, are cut
  /// off first, and further while an end curls inside the bowl; the ends
  /// left are joined by a cubic leaving and arriving along the loop's own
  /// tangents, its handles those of a circular arc through the turn
  /// between them, so the bowl closes round instead of dipping in.
  static HandGlyph closed(HandGlyph glyph) {
    List<InkVector>? loop;
    for (final List<InkVector> stroke in glyph.strokes) {
      if (loop == null || _length(stroke) > _length(loop)) loop = stroke;
    }
    if (loop == null || loop.length < 6) return glyph;
    double left = double.infinity;
    double right = double.negativeInfinity;
    double top = double.infinity;
    double bottom = double.negativeInfinity;
    for (final InkVector p in loop) {
      left = math.min(left, p.x);
      right = math.max(right, p.x);
      top = math.min(top, p.y);
      bottom = math.max(bottom, p.y);
    }
    final double size = math.max(right - left, bottom - top);
    final InkVector start = loop.first;
    final InkVector end = loop.last;
    final double gap = (end - start).length;
    if (gap < size * 0.08 || gap > size * 0.8) return glyph;
    final List<InkVector> ring = loop;
    final double length = _length(ring);
    final List<InkVector> hull = _hull(ring);
    // A tenth of the loop off each end, and on while that end lies inside
    // the bowl, up to three tenths.
    int from = 0;
    double cut = 0;
    while (from < ring.length - 2 &&
        (cut < length * 0.1 ||
            (cut < length * 0.3 && _inside(hull, ring[from]) > size * 0.03))) {
      cut += (ring[from + 1] - ring[from]).length;
      from++;
    }
    int to = ring.length - 1;
    cut = 0;
    while (to > from + 4 &&
        (cut < length * 0.1 ||
            (cut < length * 0.3 && _inside(hull, ring[to]) > size * 0.03))) {
      cut += (ring[to] - ring[to - 1]).length;
      to--;
    }
    if (to - from < 4) return glyph;
    // The way the loop runs at each cut, over a little of its length.
    InkVector along(int at, int step) {
      int k = at;
      while (k + step >= from &&
          k + step <= to &&
          (ring[k] - ring[at]).length < size * 0.08) {
        k += step;
      }
      final InkVector run = step < 0 ? ring[at] - ring[k] : ring[k] - ring[at];
      return run.length == 0 ? InkVector.zero : run * (1 / run.length);
    }

    final InkVector a = ring[to];
    final InkVector b = ring[from];
    final InkVector out = along(to, -1);
    final InkVector into = along(from, 1);
    final double chord = (b - a).length;
    // A circular arc turning θ has handles (4/3)·tan(θ/4)·r, with its chord
    // 2·r·sin(θ/2).
    final double turn = math.acos(out.dot(into).clamp(-1.0, 1.0));
    final double handle = turn < 0.05
        ? chord / 3
        : (chord * 2 / 3 * math.tan(turn / 4) / math.sin(turn / 2)).clamp(
            chord / 3,
            chord * 0.8,
          );
    final InkVector c1 = a + out * handle;
    final InkVector c2 = b - into * handle;
    final int steps = math.max(6, (chord / 0.4).ceil());
    final List<InkVector> bridge = <InkVector>[
      for (int i = 1; i <= steps; i++)
        () {
          final double t = i / steps;
          final double u = 1 - t;
          return a * (u * u * u) +
              c1 * (3 * u * u * t) +
              c2 * (3 * u * t * t) +
              b * (t * t * t);
        }(),
    ];
    final List<InkVector> closedLoop = <InkVector>[
      ...ring.sublist(from, to + 1),
      ...bridge,
    ];
    return HandGlyph(glyph.width, <List<InkVector>>[
      for (final List<InkVector> stroke in glyph.strokes)
        identical(stroke, loop) ? closedLoop : stroke,
    ]);
  }

  /// The convex hull of [points], its corners in order round it.
  static List<InkVector> _hull(List<InkVector> points) {
    final List<InkVector> sorted = <InkVector>[...points]
      ..sort(
        (InkVector p, InkVector q) =>
            p.x != q.x ? p.x.compareTo(q.x) : p.y.compareTo(q.y),
      );
    double cross(InkVector o, InkVector p, InkVector q) =>
        (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x);
    final List<InkVector> hull = <InkVector>[];
    for (final List<InkVector> pass in <List<InkVector>>[
      sorted,
      sorted.reversed.toList(),
    ]) {
      final int base = hull.length;
      for (final InkVector p in pass) {
        while (hull.length >= base + 2 &&
            cross(hull[hull.length - 2], hull.last, p) <= 0) {
          hull.removeLast();
        }
        hull.add(p);
      }
      hull.removeLast();
    }
    return hull;
  }

  /// How far [p] lies inside [hull], from its nearest side; 0 on it.
  static double _inside(List<InkVector> hull, InkVector p) {
    if (hull.length < 3) return 0;
    double nearest = double.infinity;
    for (int i = 0; i < hull.length; i++) {
      final InkVector s = hull[i];
      final InkVector e = hull[(i + 1) % hull.length];
      final InkVector side = e - s;
      if (side.length == 0) continue;
      final double away =
          ((p.x - s.x) * side.y - (p.y - s.y) * side.x).abs() / side.length;
      nearest = math.min(nearest, away);
    }
    return nearest.isFinite ? nearest : 0;
  }

  /// [glyph], an i or a j, with what was written above its stem, a dot or
  /// a dash, made a dot, a little above the stem's top.
  static HandGlyph _dotted(HandGlyph glyph) {
    // The tallest stroke: a dash over an i can be longer than its stem.
    double tallness(List<InkVector> stroke) =>
        _bottom(<List<InkVector>>[stroke]) - _top(<List<InkVector>>[stroke]);
    List<InkVector>? stem;
    for (final List<InkVector> stroke in glyph.strokes) {
      if (stem == null || tallness(stroke) > tallness(stem)) stem = stroke;
    }
    if (stem == null) return glyph;
    InkVector top = stem.first;
    for (final InkVector p in stem) {
      if (p.y < top.y) top = p;
    }
    final double tall = _bottom(<List<InkVector>>[stem]) - top.y;
    if (tall < 1) return glyph;
    return HandGlyph(glyph.width, <List<InkVector>>[
      for (final List<InkVector> stroke in glyph.strokes)
        if (identical(stroke, stem) ||
            _bottom(<List<InkVector>>[stroke]) > top.y)
          stroke
        else
          <InkVector>[
            InkVector(
              top.x,
              math.min(
                _top(<List<InkVector>>[stroke]) +
                    (_bottom(<List<InkVector>>[stroke]) -
                            _top(<List<InkVector>>[stroke])) /
                        2,
                top.y - tall * 0.3,
              ),
            ),
          ],
    ]);
  }

  static HandGlyph _mappedY(HandGlyph glyph, double Function(double y) map) =>
      HandGlyph(glyph.width, <List<InkVector>>[
        for (final List<InkVector> stroke in glyph.strokes)
          <InkVector>[
            for (final InkVector p in stroke) InkVector(p.x, map(p.y)),
          ],
      ]);

  static double _top(List<List<InkVector>> strokes) {
    double top = double.infinity;
    for (final List<InkVector> stroke in strokes) {
      for (final InkVector p in stroke) {
        top = math.min(top, p.y);
      }
    }
    return top;
  }

  static double _bottom(List<List<InkVector>> strokes) {
    double bottom = double.negativeInfinity;
    for (final List<InkVector> stroke in strokes) {
      for (final InkVector p in stroke) {
        bottom = math.max(bottom, p.y);
      }
    }
    return bottom;
  }

  static double _length(List<InkVector> stroke) {
    double sum = 0;
    for (int i = 1; i < stroke.length; i++) {
      sum += (stroke[i] - stroke[i - 1]).length;
    }
    return sum;
  }

  /// Each glyph as its width and its strokes, every stroke flattened to
  /// x, y, x, y…, to a hundredth of a grid unit; and which were built.
  Map<String, Object?> toJson() => <String, Object?>{
    for (final MapEntry<String, HandGlyph> entry in _glyphs.entries)
      entry.key: <Object?>[
        _round(entry.value.width),
        <List<double>>[
          for (final List<InkVector> stroke in entry.value.strokes)
            <double>[
              for (final InkVector p in stroke) ...<double>[
                _round(p.x),
                _round(p.y),
              ],
            ],
        ],
      ],
    // Not a single character, so a reader that knows nothing of it passes
    // it by.
    if (built.isNotEmpty)
      'built': <String, Object?>{'letters': built, 'slant': builtSlant},
  };

  /// Reads saved glyphs, leaving out any that are unreadable; null when
  /// none are left.
  static HandGlyphs? fromJson(Object? json) {
    if (json is! Map) return null;
    final Map<String, HandGlyph> glyphs = <String, HandGlyph>{};
    for (final MapEntry<Object?, Object?> entry in json.entries) {
      final Object? key = entry.key;
      final Object? value = entry.value;
      if (key is! String || key.runes.length != 1) continue;
      if (value is! List || value.length != 2) continue;
      final Object? width = value[0];
      final Object? strokes = value[1];
      if (width is! num || !width.isFinite || width < 0 || strokes is! List) {
        continue;
      }
      final List<List<InkVector>> read = <List<InkVector>>[];
      for (final Object? stroke in strokes) {
        if (stroke is! List || stroke.length < 2 || stroke.length.isOdd) {
          continue;
        }
        if (!stroke.every((Object? v) => v is num && v.isFinite)) continue;
        read.add(<InkVector>[
          for (int i = 0; i + 1 < stroke.length; i += 2)
            InkVector(
              (stroke[i] as num).toDouble(),
              (stroke[i + 1] as num).toDouble(),
            ),
        ]);
      }
      if (read.isEmpty) continue;
      glyphs[key] = HandGlyph(width.toDouble(), read);
    }
    if (glyphs.isEmpty) return null;
    final Object? built = json['built'];
    final Object? letters = built is Map ? built['letters'] : null;
    final Object? slant = built is Map ? built['slant'] : null;
    return HandGlyphs(
      glyphs,
      built: letters is String
          ? letters.split('').where(glyphs.containsKey).join()
          : '',
      builtSlant: slant is num && slant.isFinite ? slant.toDouble() : 0,
    );
  }

  /// [glyphs] with every number as [toJson] keeps it, so they compare
  /// equal to themselves read back.
  static HandGlyphs rounded(
    Map<String, HandGlyph> glyphs, {
    String built = '',
    double builtSlant = 0,
  }) => HandGlyphs(
    <String, HandGlyph>{
      for (final MapEntry<String, HandGlyph> entry in glyphs.entries)
        entry.key: HandGlyph(_round(entry.value.width), <List<InkVector>>[
          for (final List<InkVector> stroke in entry.value.strokes)
            <InkVector>[
              for (final InkVector p in stroke)
                InkVector(_round(p.x), _round(p.y)),
            ],
        ]),
    },
    built: built,
    builtSlant: builtSlant,
  );

  static double _round(double value) => (value * 100).roundToDouble() / 100;

  @override
  bool operator ==(Object other) {
    if (other is! HandGlyphs ||
        other._glyphs.length != _glyphs.length ||
        other.built != built ||
        other.builtSlant != builtSlant) {
      return false;
    }
    for (final MapEntry<String, HandGlyph> entry in _glyphs.entries) {
      final HandGlyph? theirs = other._glyphs[entry.key];
      if (theirs == null ||
          theirs.width != entry.value.width ||
          !listEquals(
            <InkVector>[for (final List<InkVector> s in theirs.strokes) ...s],
            <InkVector>[
              for (final List<InkVector> s in entry.value.strokes) ...s,
            ],
          ) ||
          theirs.strokes.length != entry.value.strokes.length) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(<Object>[
    built,
    for (final String char in _glyphs.keys.toList()..sort()) ...<Object>[
      char,
      _glyphs[char]!.width,
    ],
  ]);
}
