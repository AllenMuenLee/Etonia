import 'dart:math' as math;

import '../ink/ink_sample.dart';
import 'hand_glyphs.dart';
import 'pen_smoothing.dart';
import 'stroke_runs.dart';

/// The letters the writer writes out to make a font of their own. Between
/// them they hold every part the rest of the alphabet is made of: bowls
/// (a, o), an arch (h), stems short and tall (i, b, d, h), a descender (g),
/// a crossbar (t), diagonals (v, w, A), the loops of e and s, the hook of
/// f, and the bars and bowl of the capitals (E, R). The m is written
/// rather than built, as are D, whose closures are personal enough to
/// keep as the writer made them.
const String keyLetters = 'abdefghimostvwAERD';

/// Every letter of the alphabet missing from [written], built from the
/// strokes of the letters that are there: an n is the writer's h with its
/// stem cut at the top of their small letters, an l their d's stem, a k
/// their h's stem with their v turned on its side, a j their i run on into
/// their g's tail, a P their R without its leg, an x their w's diagonals
/// crossed. Nothing is taken from a font: every line is one the writer
/// drew, laid where the letter needs it.
///
/// [written] is in the font's grid (see [HandGlyph]), leaning [slant] as
/// the writer leans: how far right the pen moves per unit it rises. The
/// letters built lean the same way.
Map<String, HandGlyph> buildMissingGlyphs(
  Map<String, HandGlyph> written, {
  required double slant,
}) => _Builder(written, slant).build();

/// [glyphs] with the letters it records as built ([HandGlyphs.built])
/// built again from those written, so a font made before the builder
/// learned better is written as it would be made now.
HandGlyphs? rebuiltGlyphs(HandGlyphs? glyphs) {
  if (glyphs == null || glyphs.built.isEmpty) return glyphs;
  final Map<String, HandGlyph> written = <String, HandGlyph>{
    for (final String char in glyphs.characters)
      if (!glyphs.built.contains(char)) char: glyphs[char]!,
  };
  return builtGlyphs(written, slant: glyphs.builtSlant);
}

/// [written], and every letter missing from it built from it
/// ([buildMissingGlyphs]), as they are saved, recording which were built.
HandGlyphs builtGlyphs(
  Map<String, HandGlyph> written, {
  required double slant,
}) {
  // Built from the letters as they are saved, so building them again when
  // the font is read gives the same.
  final HandGlyphs kept = HandGlyphs.rounded(written);
  final Map<String, HandGlyph> saved = <String, HandGlyph>{
    for (final String char in kept.characters) char: kept[char]!,
  };
  final Map<String, HandGlyph> built = buildMissingGlyphs(saved, slant: slant);
  return HandGlyphs.rounded(
    <String, HandGlyph>{...saved, ...built},
    built: built.keys.join(),
    builtSlant: built.isEmpty ? 0 : slant,
  );
}

typedef _Strokes = List<List<InkVector>>;

const double _baseline = 10;

/// How finely built letters are sampled, in grid units, as the written
/// ones are.
const double _spacing = 0.4;

/// The shortest straight line that counts as one, in grid units.
const double _minLine = 2;

const double _degree = math.pi / 180;

class _Builder {
  _Builder(Map<String, HandGlyph> written, this.slant)
    : _letters = <String, _Strokes>{
        for (final MapEntry<String, HandGlyph> entry in written.entries)
          entry.key: <List<InkVector>>[
            for (final List<InkVector> stroke in entry.value.strokes)
              <InkVector>[
                // Upright, so stems are vertical and letters can be taken
                // apart and put together square to the page.
                for (final InkVector p in stroke)
                  InkVector(p.x - slant * (_baseline - p.y), p.y),
              ],
          ],
      } {
    double? measured(String letters, double Function(_Box box) read) =>
        _median(<double>[
          for (final String letter in letters.split(''))
            if (_letters[letter] case final _Strokes strokes)
              read(_box(strokes)),
        ]);
    xTop = (measured('aenosw', (_Box b) => b.top) ?? 4).clamp(2.0, 8.0);
    ascTop = (measured('bhf', (_Box b) => b.top) ?? 0).clamp(-2.0, xTop - 1);
    descBottom = math.max(
      measured('g', (_Box b) => b.bottom) ?? 13,
      _baseline + 1.5,
    );
    lowWidth = (measured('on', (_Box b) => b.width) ?? 5).clamp(2.5, 8.0);
    capWidth = (measured('AER', (_Box b) => b.width) ?? 7).clamp(4.0, 10.0);
  }

  final double slant;

  /// Every letter, upright: those written, and those built so far.
  final Map<String, _Strokes> _letters;

  /// Where the writer's small letters reach up to.
  late final double xTop;

  /// Where their ascenders reach up to.
  late final double ascTop;

  /// Where their descenders reach down to.
  late final double descBottom;

  /// How wide their round small letters are.
  late final double lowWidth;

  /// How wide their capitals are.
  late final double capWidth;

  double get _xHeight => _baseline - xTop;

  Map<String, HandGlyph> build() {
    // In order: later letters are built from earlier ones.
    final Map<String, _Strokes? Function()> builders =
        <String, _Strokes? Function()>{
          // An n first: the u, the r, and others are built from it.
          'n': _n,
          'c': _c,
          'd': () =>
              _extendStem('a', right: true, to: ascTop) ??
              _onStem(_letters['c'], top: ascTop, bottom: _baseline),
          'h': () =>
              _extendStem('n', right: false, to: ascTop) ??
              <List<InkVector>>[
                _lay(_stem, InkVector(0, ascTop), const InkVector(0, 10)),
                ...?_letters['n'],
              ],
          'k': _k,
          'l': _l,
          'j': _j,
          'm': _m,
          'p': _p,
          'q': () =>
              _extendStem('a', right: true, to: descBottom) ??
              _onStem(_letters['c'], top: xTop, bottom: descBottom),
          'r': _r,
          'u': () => _turned(_footedN()),
          'v': _v,
          'x': _x,
          'y': _y,
          'z': _z,
          'C': () => _capital('c'),
          'O': () => _tall(_o),
          'S': () => _capital('s'),
          'U': () => _capital('u'),
          'V': () => _capital('v'),
          'W': () => _capital('w'),
          'X': () => _capital('x'),
          'Z': () => _capital('z'),
          'P': _bigP,
          'B': _bigB,
          'D': _bigD,
          'F': _bigF,
          'L': _bigL,
          'T': _bigT,
          'H': _bigH,
          'I': () => <List<InkVector>>[
            _lay(_capStem, InkVector.zero, const InkVector(0, 10)),
          ],
          'J': _bigJ,
          'N': _bigN,
          'M': _bigM,
          'Y': _bigY,
          'G': _bigG,
          'Q': _bigQ,
          'K': _bigK,
        };
    final Map<String, HandGlyph> built = <String, HandGlyph>{};
    for (final MapEntry<String, _Strokes? Function()> entry
        in builders.entries) {
      if (_letters.containsKey(entry.key)) continue;
      final _Strokes? strokes = entry.value()?.where(_useful).toList();
      if (strokes == null || strokes.isEmpty) continue;
      _letters[entry.key] = strokes;
      built[entry.key] = _glyph(strokes);
    }
    return built;
  }

  /// [strokes], upright, leaning as the writer leans again, from x = 0.
  HandGlyph _glyph(_Strokes strokes) {
    final _Strokes leaning = <List<InkVector>>[
      for (final List<InkVector> stroke in strokes)
        <InkVector>[
          for (final InkVector p in penSmoothed(stroke, spacing: _spacing))
            InkVector(p.x + slant * (_baseline - p.y), p.y),
        ],
    ];
    final _Box box = _box(leaning);
    return HandGlyph(box.width, <List<InkVector>>[
      for (final List<InkVector> stroke in leaning)
        <InkVector>[
          for (final InkVector p in stroke) InkVector(p.x - box.left, p.y),
        ],
    ]);
  }

  // ---------------------------------------------------------------------
  // The writer's lines.

  /// The longest straight line in [letter] that passes [test], from the
  /// top down, or from the left with [level].
  List<InkVector>? _line(
    String letter,
    bool Function(_Run run) test, {
    bool level = false,
  }) {
    final _Strokes? strokes = _letters[letter];
    if (strokes == null) return null;
    final _Run? run = _longest(_runs(strokes), test);
    if (run == null) return null;
    return level ? run.rightward : run.downward;
  }

  static bool _isDiagonal(_Run r) => r.lean > 8 * _degree && !r.level;

  /// A small letter's stem.
  late final List<InkVector> _stem =
      _line('i', (_Run r) => r.upright) ??
      _line('n', (_Run r) => r.upright) ??
      _line('b', (_Run r) => r.upright) ??
      _line('h', (_Run r) => r.upright) ??
      _anyLine;

  /// A capital's stem.
  late final List<InkVector> _capStem =
      _line('E', (_Run r) => r.upright) ??
      _line('R', (_Run r) => r.upright) ??
      _stem;

  /// A crossbar, from the left.
  late final List<InkVector> _bar =
      _line('t', (_Run r) => r.level, level: true) ??
      _line('E', (_Run r) => r.level, level: true) ??
      _line('A', (_Run r) => r.level, level: true) ??
      _stem;

  /// A small letter's line falling to the right, as \, from the top.
  late final List<InkVector> _fall =
      _line('w', (_Run r) => _isDiagonal(r) && r.fallsRight) ??
      _line('v', (_Run r) => _isDiagonal(r) && r.fallsRight) ??
      _line('A', (_Run r) => _isDiagonal(r) && r.fallsRight) ??
      _stem;

  /// A small letter's line rising to the right, as /, from the top.
  late final List<InkVector> _rise =
      _line('w', (_Run r) => _isDiagonal(r) && !r.fallsRight) ??
      _line('v', (_Run r) => _isDiagonal(r) && !r.fallsRight) ??
      _line('A', (_Run r) => _isDiagonal(r) && !r.fallsRight) ??
      _stem;

  /// A capital's \, from the top.
  late final List<InkVector> _capFall =
      _line('A', (_Run r) => _isDiagonal(r) && r.fallsRight) ??
      _line('R', (_Run r) => _isDiagonal(r) && r.fallsRight) ??
      _fall;

  /// A capital's /, from the top.
  late final List<InkVector> _capRise =
      _line('A', (_Run r) => _isDiagonal(r) && !r.fallsRight) ?? _rise;

  /// The longest stroke written, should no line be found at all.
  List<InkVector> get _anyLine {
    List<InkVector> longest = const <InkVector>[
      InkVector.zero,
      InkVector(0, 1),
    ];
    for (final _Strokes strokes in _letters.values) {
      for (final List<InkVector> stroke in strokes) {
        if (pathLength(stroke) > pathLength(longest)) longest = stroke;
      }
    }
    return longest;
  }

  /// The descender of the writer's g, from where it crosses the baseline
  /// on its way down, from (0, 0); null if their g has none.
  late final List<InkVector>? _tail = () {
    final _Strokes? g = _letters['g'];
    if (g == null) return null;
    int index = -1;
    int deepest = -1;
    double depth = _baseline + 0.8;
    for (int s = 0; s < g.length; s++) {
      for (int i = 0; i < g[s].length; i++) {
        if (g[s][i].y > depth) {
          depth = g[s][i].y;
          index = s;
          deepest = i;
        }
      }
    }
    if (index < 0) return null;
    List<InkVector> stroke = g[index];
    if (deepest < stroke.length / 2) {
      stroke = stroke.reversed.toList();
      deepest = stroke.length - 1 - deepest;
    }
    for (int i = deepest - 1; i >= 0; i--) {
      if (stroke[i].y > _baseline) continue;
      final InkVector a = stroke[i];
      final InkVector b = stroke[i + 1];
      final InkVector start = b.y == a.y
          ? a
          : a + (b - a) * ((_baseline - a.y) / (b.y - a.y));
      return <InkVector>[
        InkVector.zero,
        for (final InkVector p in stroke.sublist(i + 1)) p - start,
      ];
    }
    return null;
  }();

  /// The writer's c turned round: a bowl open on its left, as a P's.
  _Strokes get _rightBowl =>
      _mirrored(_letters['c'] ?? _o ?? <List<InkVector>>[_stem]);

  /// The writer's o, closed where they left it open, as an O or a c's
  /// round needs it.
  late final _Strokes? _o = switch (_letters['o']) {
    final _Strokes o => HandGlyphs.closed(HandGlyph(0, o)).strokes,
    null => null,
  };

  // ---------------------------------------------------------------------
  // Small letters.

  /// The o with its right side left open.
  _Strokes? _c() {
    final _Strokes? o = _o;
    if (o == null) return null;
    final List<InkVector> loop = _longestStroke(o);
    if (loop.length < 4) return <List<InkVector>>[loop];
    final _Box box = _box(<List<InkVector>>[loop]);
    final InkVector middle = box.center;
    final double rx = math.max(box.width / 2, 0.1);
    final double ry = math.max(box.height / 2, 0.1);
    bool open(InkVector p) =>
        math.atan2((p.y - middle.y) / ry, (p.x - middle.x) / rx).abs() <
        50 * _degree;
    // The longest run of points outside the opening: round the loop where
    // it closes, so an o begun on its left still opens on its right.
    final bool closed = (loop.first - loop.last).length < box.height * 0.35;
    final int n = loop.length;
    final int first = loop.indexWhere(open);
    if (first < 0) return <List<InkVector>>[loop];
    int best = 0;
    int bestLength = 0;
    int start = 0;
    int length = 0;
    final int from = closed ? first + 1 : 0;
    for (int k = 0; k < n; k++) {
      final int i = (from + k) % n;
      if (!closed && k > 0 && i == 0) break;
      if (open(loop[i])) {
        length = 0;
        continue;
      }
      if (length == 0) start = i;
      length++;
      if (length > bestLength) {
        best = start;
        bestLength = length;
      }
    }
    if (bestLength < 3) return <List<InkVector>>[loop];
    return <List<InkVector>>[
      <InkVector>[for (int k = 0; k < bestLength; k++) loop[(best + k) % n]],
    ];
  }

  /// [bowl] with a stem down its right side, from [top] to [bottom].
  _Strokes? _onStem(
    _Strokes? bowl, {
    required double top,
    required double bottom,
  }) {
    if (bowl == null) return null;
    final _Box box = _box(bowl);
    return <List<InkVector>>[
      ...bowl,
      _lay(_stem, InkVector(box.right, top), InkVector(box.right, bottom)),
    ];
  }

  /// [letter] with the stem on its right, or its left, carried on up or
  /// down to [to], as the writer draws that stem: an a into a d or a q,
  /// an n into an h. A flick off the stem's end is left off so it runs on
  /// straight. Null when the letter has no such stem.
  _Strokes? _extendStem(
    String letter, {
    required bool right,
    required double to,
  }) {
    final _Strokes? strokes = _letters[letter];
    if (strokes == null) return null;
    final _Box box = _box(strokes);
    final _Run? run = _longest(
      _runs(strokes),
      (_Run r) =>
          r.upright &&
          r.length > _xHeight * 0.4 &&
          (right
              ? r.centerX > box.left + box.width * 0.55
              : r.centerX < box.left + box.width * 0.45),
    );
    if (run == null) return null;
    List<InkVector> stroke = strokes[run.stroke];
    final bool topFirst = run.points.first.y < run.points.last.y;
    final bool upward = to < run.top;
    int at = upward == topFirst ? run.from : run.to;
    final double flick = _xHeight * 0.3;
    if (at > 0 && at < stroke.length - 1) {
      if (pathLength(stroke.sublist(at)) < flick) {
        stroke = stroke.sublist(0, at + 1);
      } else if (pathLength(stroke.sublist(0, at + 1)) < flick) {
        stroke = stroke.sublist(at);
        at = 0;
      }
    }
    final InkVector end = stroke[at];
    final List<InkVector> down = run.downward;
    final InkVector heading = down.last - down.first;
    final InkVector target = end + heading * ((to - end.y) / heading.y);
    final List<InkVector> extended = _excursion(
      stroke,
      at,
      _lay(down, end, target),
    );
    return <List<InkVector>>[
      for (int i = 0; i < strokes.length; i++)
        i == run.stroke ? extended : strokes[i],
    ];
  }

  /// The tall stem of the writer's d, or failing that their b or h.
  _Strokes _l() {
    for (final String letter in <String>['d', 'b', 'h']) {
      final List<InkVector>? stem = _line(
        letter,
        (_Run r) => r.upright && r.top < xTop - 1,
      );
      if (stem != null) return <List<InkVector>>[stem];
    }
    return <List<InkVector>>[
      _lay(_stem, InkVector(0, ascTop), const InkVector(0, 10)),
    ];
  }

  /// The h's stem, from the top of its ascender to the baseline.
  _Run? _hStem() {
    final _Strokes? h = _letters['h'];
    if (h == null) return null;
    final _Box box = _box(h);
    return _longest(
      _runs(h),
      (_Run r) =>
          r.upright &&
          r.top < xTop - 1 &&
          r.centerX < box.left + box.width * 0.45,
    );
  }

  /// The h with its stem cut where the small letters' tops are, so only
  /// the part of it beside the arch is left. Where the pen went up the
  /// stem and came back down it, it now turns at the cut.
  _Strokes? _n() {
    final _Strokes? h = _letters['h'];
    if (h == null) return null;
    final _Box box = _box(h);
    // The stem's side of the letter, clear of the arch's top.
    final double stemSide = box.left + box.width * 0.4;
    bool above(InkVector p) => p.y < xTop && p.x < stemSide;
    InkVector crossing(InkVector a, InkVector b) =>
        b.y == a.y ? b : a + (b - a) * ((xTop - a.y) / (b.y - a.y));
    final _Strokes cut = <List<InkVector>>[];
    for (final List<InkVector> stroke in h) {
      final List<InkVector> kept = <InkVector>[];
      for (int k = 0; k < stroke.length; k++) {
        final bool out = above(stroke[k]);
        if (k > 0 && out != above(stroke[k - 1])) {
          kept.add(crossing(stroke[k - 1], stroke[k]));
        }
        if (!out) kept.add(stroke[k]);
      }
      if (kept.isNotEmpty) cut.add(kept);
    }
    return cut.isEmpty ? null : cut;
  }

  /// The h's stem, with the v turned on its side, its point to the left,
  /// for the arm and the leg.
  _Strokes? _k() {
    final _Strokes? v = _letters['v'];
    final _Run? stem = _hStem();
    final List<InkVector> tall = stem == null
        ? _l().single
        : _letters['h']![stem.stroke].sublist(stem.from, stem.to + 1);
    if (v == null) return null;
    // A quarter turn: what pointed down points left, and the v's left
    // arm, drawn first, is the k's arm, its right arm the k's leg.
    final _Strokes turned = <List<InkVector>>[
      for (final List<InkVector> stroke in v)
        <InkVector>[for (final InkVector p in stroke) InkVector(-p.y, p.x)],
    ];
    final _Box box = _box(turned);
    final double sy = _xHeight / math.max(box.height, 0.1);
    final double sx = math.min(sy, lowWidth * 0.8 / math.max(box.width, 0.1));
    final double x = _box(<List<InkVector>>[tall]).center.x;
    return <List<InkVector>>[
      tall,
      for (final List<InkVector> stroke in turned)
        <InkVector>[
          for (final InkVector p in stroke)
            InkVector(x + (p.x - box.left) * sx, xTop + (p.y - box.top) * sy),
        ],
    ];
  }

  /// The i's stem running on into the g's descender, dotted as the i is.
  _Strokes? _j() {
    final _Strokes? i = _letters['i'];
    if (i == null) return null;
    // The tallest stroke: a dash over the i can be longer than its stem.
    final List<InkVector> written = _tallestStroke(i);
    List<InkVector> stem = written;
    if (stem.first.y > stem.last.y) stem = stem.reversed.toList();
    int deepest = 0;
    for (int k = 0; k < stem.length; k++) {
      if (stem[k].y > stem[deepest].y) deepest = k;
    }
    stem = stem.sublist(0, deepest + 1);
    final List<InkVector>? tail = _tail;
    final List<InkVector> drawn = tail != null && stem.length > 1
        ? _attach(stem, tail)
        : <InkVector>[
            ...stem,
            ..._lay(
              _stem,
              stem.last,
              InkVector(stem.last.x, descBottom),
            ).skip(1),
          ];
    return <List<InkVector>>[
      for (final List<InkVector> stroke in i)
        identical(stroke, written) ? drawn : stroke,
    ];
  }

  /// The stroke of the n that arches, and where its arch leaves the stem.
  ({int stroke, int from, _Box box})? _arch() {
    final _Strokes? n = _letters['n'];
    if (n == null) return null;
    final _Box box = _box(n);
    int index = 0;
    for (int s = 1; s < n.length; s++) {
      if (_box(<List<InkVector>>[n[s]]).right >
          _box(<List<InkVector>>[n[index]]).right) {
        index = s;
      }
    }
    final List<InkVector> stroke = n[index];
    int furthest = 0;
    for (int k = 0; k < stroke.length; k++) {
      if (stroke[k].x > stroke[furthest].x) furthest = k;
    }
    int from = -1;
    for (int k = 0; k < furthest; k++) {
      if (stroke[k].x < box.left + box.width * 0.3) from = k;
    }
    if (from < 0) {
      if (stroke.first.x > box.left + box.width * 0.45) return null;
      from = 0;
    }
    return (stroke: index, from: from, box: box);
  }

  /// The arch of the n stopped where its right leg reaches the baseline: a
  /// flick or swoop off its foot belongs at the end of a word, not inside
  /// an m, nor, turned over, at the top of a u.
  _Strokes? _footedN() {
    final _Strokes? n = _letters['n'];
    final ({int stroke, int from, _Box box})? arch = _arch();
    if (n == null || arch == null) return n;
    final List<InkVector> stroke = n[arch.stroke];
    int peak = arch.from;
    for (int k = arch.from; k < stroke.length; k++) {
      if (stroke[k].y < stroke[peak].y) peak = k;
    }
    for (int k = peak + 1; k < stroke.length; k++) {
      if (stroke[k].y < _baseline) continue;
      final InkVector a = stroke[k - 1];
      final InkVector b = stroke[k];
      final InkVector foot = b.y == a.y
          ? b
          : a + (b - a) * ((_baseline - a.y) / (b.y - a.y));
      return <List<InkVector>>[
        for (int s = 0; s < n.length; s++)
          s == arch.stroke ? <InkVector>[...stroke.take(k), foot] : n[s],
      ];
    }
    return n;
  }

  /// The n with its arch drawn again beside it, a little narrower.
  _Strokes? _m() {
    final _Strokes? n = _footedN();
    final ({int stroke, int from, _Box box})? arch = _arch();
    if (n == null) return null;
    if (arch == null) {
      return <List<InkVector>>[
        ...n,
        ..._moved(n, InkVector(lowWidth * 0.8, 0)),
      ];
    }
    final List<InkVector> stroke = n[arch.stroke];
    int peak = arch.from;
    for (int k = arch.from; k < stroke.length; k++) {
      if (stroke[k].y < stroke[peak].y) peak = k;
    }
    // Where the pen turns at the foot of the stem to go back up it, when
    // the n is one stroke: the second arch sets off from the first's foot
    // just as the first set off from the stem's.
    int turn = 0;
    for (int k = 1; k < peak; k++) {
      if (stroke[k].y > stroke[turn].y) turn = k;
    }
    final bool retraced =
        turn > 0 && stroke[turn].y > _baseline - _xHeight * 0.3;
    final List<InkVector> over = stroke.sublist(retraced ? turn : arch.from);
    final double step = over.last.x - over.first.x;
    if (step < 1) return null;
    // Back up the arch's right side, and over again.
    final List<InkVector> twice = <InkVector>[
      ...stroke,
      for (final InkVector p in over.skip(retraced ? 1 : 0))
        p + InkVector(step, 0),
    ];
    final double left = arch.box.left;
    return <List<InkVector>>[
      for (int s = 0; s < n.length; s++)
        <InkVector>[
          for (final InkVector p in s == arch.stroke ? twice : n[s])
            InkVector(left + (p.x - left) * 0.82, p.y),
        ],
    ];
  }

  /// The n stopped at the shoulder of its arch.
  _Strokes? _r() {
    final _Strokes? n = _footedN();
    final ({int stroke, int from, _Box box})? arch = _arch();
    if (n == null || arch == null) return n;
    final List<InkVector> stroke = n[arch.stroke];
    // Measured without a swoop off the n's foot, which would carry the
    // shoulder on down the leg, so the r reads as an n.
    final _Box box = _box(n);
    int peak = arch.from;
    int end = stroke.length - 1;
    for (int k = arch.from; k < stroke.length; k++) {
      if (stroke[k].y < stroke[peak].y) peak = k;
      if (stroke[k].x - box.left >= box.width * 0.6 ||
          (k > peak && stroke[k].y > stroke[peak].y + _xHeight * 0.15)) {
        end = k;
        break;
      }
    }
    return <List<InkVector>>[
      for (int s = 0; s < n.length; s++)
        s == arch.stroke ? stroke.sublist(0, end + 1) : n[s],
    ];
  }

  /// [strokes] turned upside down, drawn the other way: an n into a u.
  _Strokes? _turned(_Strokes? strokes) {
    if (strokes == null) return null;
    final InkVector c = _box(strokes).center;
    return <List<InkVector>>[
      for (final List<InkVector> stroke in strokes.reversed)
        <InkVector>[
          for (final InkVector p in stroke.reversed)
            InkVector(2 * c.x - p.x, 2 * c.y - p.y),
        ],
    ];
  }

  /// The first half of the w, its right arm raised to the left's height.
  _Strokes _v() {
    final _Strokes? w = _letters['w'];
    _Strokes made() => <List<InkVector>>[
      <InkVector>[
        ..._lay(_fall, InkVector(0, xTop), InkVector(lowWidth * 0.45, 10)),
        ..._lay(
          _rise,
          InkVector(lowWidth * 0.45, 10),
          InkVector(lowWidth * 0.9, xTop),
        ).skip(1),
      ],
    ];
    if (w == null) return made();
    final _Box box = _box(w);
    final List<InkVector> main = _longestStroke(w);
    // A w drawn as two v's: the first is one.
    if (w.length > 1 && _box(<List<InkVector>>[main]).width < box.width * 0.7) {
      return <List<InkVector>>[main];
    }
    int middle = -1;
    for (int k = 2; k < main.length - 2; k++) {
      final double share = (main[k].x - box.left) / box.width;
      if (share < 0.3 || share > 0.7) continue;
      if (middle < 0 || main[k].y < main[middle].y) middle = k;
    }
    if (middle < 0) return made();
    final List<InkVector> half = main.first.x <= main.last.x
        ? main.sublist(0, middle + 1)
        : main.sublist(middle);
    int vertex = 0;
    for (int k = 0; k < half.length; k++) {
      if (half[k].y > half[vertex].y) vertex = k;
    }
    // The w's middle is often lower than its outer arms.
    final bool cutLast = main.first.x <= main.last.x;
    final InkVector cut = cutLast ? half.last : half.first;
    final InkVector outer = cutLast ? half.first : half.last;
    final double raise =
        ((_baseline - outer.y) / math.max(_baseline - cut.y, 0.5)).clamp(
          1.0,
          2.2,
        );
    return <List<InkVector>>[
      <InkVector>[
        for (int k = 0; k < half.length; k++)
          if (cutLast ? k > vertex : k < vertex)
            InkVector(half[k].x, _baseline - (_baseline - half[k].y) * raise)
          else
            half[k],
      ],
    ];
  }

  /// The w's diagonals crossed.
  _Strokes _x() {
    final double w = lowWidth * 0.9;
    return <List<InkVector>>[
      _lay(_fall, InkVector(0, xTop), InkVector(w, 10)),
      _lay(_rise, InkVector(w, xTop), const InkVector(0, 10)),
    ];
  }

  /// A v whose right arm runs on into the g's descender.
  _Strokes _y() {
    final double w = lowWidth * 0.95;
    final InkVector foot = InkVector(w * 0.5, 10);
    final List<InkVector> arm = _lay(_rise, InkVector(w, xTop), foot);
    final List<InkVector>? tail = _tail;
    return <List<InkVector>>[
      _lay(_fall, InkVector(0, xTop), foot),
      if (tail != null)
        _attach(arm, tail)
      else
        <InkVector>[
          ...arm,
          ..._lay(
            _rise,
            foot,
            InkVector(foot.x - w * 0.25, descBottom),
          ).skip(1),
        ],
    ];
  }

  /// The t's crossbar, a / from the w, and the crossbar again.
  _Strokes _z() {
    final double w = lowWidth * 0.9;
    return <List<InkVector>>[
      <InkVector>[
        ..._lay(_bar, InkVector(0, xTop), InkVector(w, xTop)),
        ..._lay(_rise, InkVector(w, xTop), const InkVector(0, 10)).skip(1),
        ..._lay(_bar, const InkVector(0, 10), InkVector(w, 10)).skip(1),
      ],
    ];
  }

  /// The b with its stem moved down below the line.
  _Strokes? _p() {
    final _Strokes? b = _letters['b'];
    final _Run? run = b == null
        ? null
        : _longest(
            _runs(b),
            (_Run r) => r.upright && r.top < xTop - 1 && r.length > 4,
          );
    if (b == null || run == null) {
      return <List<InkVector>>[
        _lay(_stem, InkVector(0, xTop), InkVector(0, descBottom)),
        ..._fit(_rightBowl, 0, xTop, lowWidth * 0.9, 10),
      ];
    }
    final double scale = (descBottom - xTop) / (run.bottom - run.top);
    InkVector moved(InkVector p) =>
        InkVector(p.x, xTop + (p.y - run.top) * scale);
    final List<InkVector> stroke = b[run.stroke];
    final bool topFirst = run.points.first.y <= run.points.last.y;
    final int top = topFirst ? run.from : run.to;
    final InkVector shift = moved(stroke[top]) - stroke[top];
    return <List<InkVector>>[
      for (int s = 0; s < b.length; s++)
        if (s != run.stroke)
          b[s]
        else
          <InkVector>[
            for (int k = 0; k < stroke.length; k++)
              if (k >= run.from && k <= run.to)
                moved(stroke[k])
              else if (topFirst ? k < run.from : k > run.to)
                stroke[k] + shift
              else
                stroke[k],
          ],
    ];
  }

  // ---------------------------------------------------------------------
  // Capitals.

  /// The small [letter], as tall as a capital.
  _Strokes? _capital(String letter) => _tall(_letters[letter]);

  /// [strokes], a small letter, as tall as a capital.
  _Strokes? _tall(_Strokes? strokes) {
    if (strokes == null) return null;
    final double f = _baseline / _xHeight;
    return <List<InkVector>>[
      for (final List<InkVector> stroke in strokes)
        <InkVector>[
          for (final InkVector p in stroke)
            InkVector(p.x * f, _baseline - (_baseline - p.y) * f),
        ],
    ];
  }

  /// The R without its leg.
  _Strokes _bigP() {
    final _Strokes? r = _letters['R'];
    if (r != null) {
      final _Box box = _box(r);
      final _Run? leg = _longest(
        _runs(r),
        (_Run run) =>
            run.fallsRight &&
            !run.level &&
            run.lean > 12 * _degree &&
            run.bottom > _baseline - 2 &&
            run.centerX > box.left + box.width * 0.4,
      );
      if (leg != null) {
        final _Strokes without = _without(r, <_Run>[leg]);
        if (without.isNotEmpty) return without;
      }
    }
    return <List<InkVector>>[
      _lay(_capStem, InkVector.zero, const InkVector(0, 10)),
      ..._fit(_rightBowl, 0, 0, capWidth * 0.8, 5.5),
    ];
  }

  /// The P's stem and its bowl, apart.
  ({List<InkVector> stem, List<InkVector> bowl})? _stemAndBowl() {
    final _Strokes? p = _letters['P'];
    if (p == null) return null;
    final _Run? stem = _longest(
      _runs(p),
      (_Run r) => r.upright && r.length > 5,
    );
    if (stem == null) return null;
    List<InkVector>? bowl;
    for (final List<InkVector> piece in _without(p, <_Run>[stem])) {
      if (bowl == null ||
          _box(<List<InkVector>>[piece]).width >
              _box(<List<InkVector>>[bowl]).width) {
        bowl = piece;
      }
    }
    return bowl == null ? null : (stem: stem.downward, bowl: bowl);
  }

  /// The P with its bowl drawn again below, a little wider.
  _Strokes _bigB() {
    final ({List<InkVector> stem, List<InkVector> bowl})? parts =
        _stemAndBowl();
    if (parts == null) {
      return <List<InkVector>>[
        _lay(_capStem, InkVector.zero, const InkVector(0, 10)),
        ..._fit(_rightBowl, 0, 0, capWidth * 0.7, 5),
        ..._fit(_rightBowl, 0, 5, capWidth * 0.8, 10),
      ];
    }
    final _Box box = _box(<List<InkVector>>[parts.bowl]);
    final double middle = math.min(box.bottom, 5.8);
    return <List<InkVector>>[
      parts.stem,
      ..._fit(
        <List<InkVector>>[parts.bowl],
        box.left,
        box.top,
        box.right,
        middle,
      ),
      ..._fit(
        <List<InkVector>>[parts.bowl],
        box.left,
        middle,
        box.left + box.width * 1.12,
        10,
      ),
    ];
  }

  /// The P with its bowl drawn all the way down the stem.
  _Strokes _bigD() {
    final ({List<InkVector> stem, List<InkVector> bowl})? parts =
        _stemAndBowl();
    if (parts == null) {
      return <List<InkVector>>[
        _lay(_capStem, InkVector.zero, const InkVector(0, 10)),
        ..._fit(_rightBowl, 0, 0, capWidth, 10),
      ];
    }
    final _Box box = _box(<List<InkVector>>[parts.bowl]);
    return <List<InkVector>>[
      parts.stem,
      ..._fit(
        <List<InkVector>>[parts.bowl],
        box.left,
        box.top,
        box.left + box.width * 1.3,
        10,
      ),
    ];
  }

  /// The E's bars, from the top down.
  List<_Run> get _bars {
    final _Strokes? e = _letters['E'];
    if (e == null) return const <_Run>[];
    return <_Run>[
      for (final _Run r in _runs(e))
        if (r.level) r,
    ]..sort((_Run a, _Run b) => a.centerY.compareTo(b.centerY));
  }

  /// The E without its foot.
  _Strokes _bigF() {
    final List<_Run> bars = _bars;
    if (bars.length >= 2 && bars.last.centerY > 6.5) {
      final _Strokes without = _without(_letters['E']!, <_Run>[bars.last]);
      if (without.isNotEmpty) return without;
    }
    return <List<InkVector>>[
      _lay(_capStem, InkVector.zero, const InkVector(0, 10)),
      _lay(_bar, InkVector.zero, InkVector(capWidth * 0.8, 0)),
      _lay(_bar, const InkVector(0, 5), InkVector(capWidth * 0.6, 5)),
    ];
  }

  /// The E without the bars above its foot.
  _Strokes _bigL() {
    final List<_Run> bars = _bars;
    if (bars.length >= 2 && bars.last.centerY > 6.5) {
      // What is left of a bar too short to read as a line goes too: only
      // the stem, and what runs along the foot, stay.
      final _Strokes without = <List<InkVector>>[
        for (final List<InkVector> piece in _without(
          _letters['E']!,
          bars.sublist(0, bars.length - 1),
        ))
          if (_box(<List<InkVector>>[piece]).height > 3 ||
              _box(<List<InkVector>>[piece]).top > 7.5)
            piece,
      ];
      if (without.isNotEmpty) return without;
    }
    return <List<InkVector>>[
      <InkVector>[
        ..._lay(_capStem, InkVector.zero, const InkVector(0, 10)),
        ..._lay(
          _bar,
          const InkVector(0, 10),
          InkVector(capWidth * 0.8, 10),
        ).skip(1),
      ],
    ];
  }

  /// The E's top bar over a stem from its middle.
  _Strokes _bigT() {
    final List<_Run> bars = _bars;
    final List<InkVector> top = bars.isNotEmpty && bars.first.centerY < 3.5
        ? bars.first.rightward
        : _bar;
    final double w = math.max((top.last - top.first).length, capWidth * 0.7);
    return <List<InkVector>>[
      _lay(top, InkVector.zero, InkVector(w, 0)),
      _lay(_capStem, InkVector(w / 2, 0), InkVector(w / 2, 10)),
    ];
  }

  /// Two of the E's stems, joined by its middle bar.
  _Strokes _bigH() {
    final List<_Run> bars = _bars;
    final List<InkVector> middle = bars.length >= 3
        ? bars[bars.length ~/ 2].rightward
        : _bar;
    final double w = capWidth;
    return <List<InkVector>>[
      _lay(_capStem, InkVector.zero, const InkVector(0, 10)),
      _lay(_capStem, InkVector(w, 0), InkVector(w, 10)),
      _lay(middle, const InkVector(0, 5.2), InkVector(w, 5.2)),
    ];
  }

  /// The j's stem and descender, as tall as a capital, without the dot.
  _Strokes? _bigJ() {
    final _Strokes? j = _letters['j'];
    if (j == null) return null;
    final List<InkVector> hook = _longestStroke(j);
    final _Box box = _box(<List<InkVector>>[hook]);
    final double f = _baseline / math.max(box.height, 1);
    return <List<InkVector>>[
      <InkVector>[
        for (final InkVector p in hook)
          InkVector((p.x - box.left) * f, (p.y - box.top) * f),
      ],
    ];
  }

  /// Up a stem, down the A's \, and up a stem again.
  _Strokes _bigN() {
    final double w = capWidth;
    return <List<InkVector>>[
      <InkVector>[
        ..._lay(_capStem, const InkVector(0, 10), InkVector.zero),
        ..._lay(_capFall, InkVector.zero, InkVector(w, 10)).skip(1),
        ..._lay(_capStem, InkVector(w, 10), InkVector(w, 0)).skip(1),
      ],
    ];
  }

  /// Up a stem, down the A's \ and up its /, and down a stem.
  _Strokes _bigM() {
    final double w = capWidth * 1.2;
    final InkVector valley = InkVector(w / 2, 7);
    return <List<InkVector>>[
      <InkVector>[
        ..._lay(_capStem, const InkVector(0, 10), InkVector.zero),
        ..._lay(_capFall, InkVector.zero, valley).skip(1),
        ..._lay(_capRise, valley, InkVector(w, 0)).skip(1),
        ..._lay(_capStem, InkVector(w, 0), InkVector(w, 10)).skip(1),
      ],
    ];
  }

  /// The A's legs meeting halfway down, over a stem.
  _Strokes _bigY() {
    final double w = capWidth;
    final InkVector fork = InkVector(w / 2, 5);
    return <List<InkVector>>[
      <InkVector>[
        ..._lay(_capFall, InkVector.zero, fork),
        ..._lay(_capStem, fork, InkVector(w / 2, 10)).skip(1),
      ],
      _lay(_capRise, InkVector(w, 0), fork),
    ];
  }

  /// The C, turning in at its foot to a short bar.
  _Strokes? _bigG() {
    final _Strokes? c = _letters['C'];
    if (c == null) return null;
    final _Box box = _box(c);
    final List<InkVector> main = _longestStroke(c);
    List<InkVector> stroke = main.first.y > main.last.y
        ? main.reversed.toList()
        : main;
    final InkVector end = stroke.last;
    final InkVector corner = InkVector(end.x, math.min(end.y, 5.8));
    stroke = <InkVector>[
      ...stroke,
      if (end.y > 6.5) ..._lay(_capStem, end, corner).skip(1),
      ..._lay(
        _bar,
        corner,
        InkVector(corner.x - box.width * 0.4, corner.y),
      ).skip(1),
    ];
    return <List<InkVector>>[
      for (final List<InkVector> s in c) identical(s, main) ? stroke : s,
    ];
  }

  /// The O, with the A's \ across its foot.
  _Strokes? _bigQ() {
    final _Strokes? o = _letters['O'];
    if (o == null) return null;
    final _Box box = _box(o);
    return <List<InkVector>>[
      ...o,
      _lay(
        _capFall,
        InkVector(box.left + box.width * 0.55, box.top + box.height * 0.68),
        InkVector(box.right + box.width * 0.05, box.bottom + 0.8),
      ),
    ];
  }

  /// The k, its arm and leg grown to reach the top of its stem.
  _Strokes _bigK() {
    final _Strokes? k = _letters['k'];
    final _Run? stem = k == null
        ? null
        : _longest(_runs(k), (_Run r) => r.upright && r.top < xTop - 1);
    if (k == null || stem == null) {
      final double w = capWidth * 0.85;
      return <List<InkVector>>[
        _lay(_capStem, InkVector.zero, const InkVector(0, 10)),
        <InkVector>[
          ..._lay(_capRise, InkVector(w, 0), const InkVector(0.2, 5.5)),
          ..._lay(
            _capFall,
            const InkVector(0.2, 5.5),
            InkVector(w, 10),
          ).skip(1),
        ],
      ];
    }
    final double x = (stem.points.first.x + stem.points.last.x) / 2;
    double top = _baseline;
    for (int s = 0; s < k.length; s++) {
      for (int i = 0; i < k[s].length; i++) {
        final bool inStem = s == stem.stroke && i >= stem.from && i <= stem.to;
        if (!inStem && k[s][i].y >= xTop - 0.5) top = math.min(top, k[s][i].y);
      }
    }
    final double tall = _baseline / math.max(_baseline - stem.top, 1);
    final double grow = (_baseline / math.max(_baseline - top, 1)).clamp(
      1.0,
      3.0,
    );
    final double widen = math.sqrt(grow);
    return <List<InkVector>>[
      for (int s = 0; s < k.length; s++)
        <InkVector>[
          for (int i = 0; i < k[s].length; i++)
            if ((s == stem.stroke && i >= stem.from && i <= stem.to) ||
                k[s][i].y < xTop - 0.5)
              InkVector(k[s][i].x, _baseline - (_baseline - k[s][i].y) * tall)
            else
              InkVector(
                x + (k[s][i].x - x) * widen,
                _baseline - (_baseline - k[s][i].y) * grow,
              ),
        ],
    ];
  }

  // ---------------------------------------------------------------------
  // Putting lines together.

  /// [stroke] carried on from [path]'s start, its point at [at], along
  /// [path]: from an end, it runs on; from its middle, it goes out along
  /// [path] and back, as a pen retraces a stem.
  static List<InkVector> _excursion(
    List<InkVector> stroke,
    int at,
    List<InkVector> path,
  ) {
    if (at == 0) {
      return <InkVector>[...path.reversed, ...stroke.skip(1)];
    }
    if (at == stroke.length - 1) {
      return <InkVector>[...stroke, ...path.skip(1)];
    }
    return <InkVector>[
      ...stroke.sublist(0, at + 1),
      ...path.skip(1),
      ...path.reversed.skip(1),
      ...stroke.sublist(at + 1),
    ];
  }

  /// [stroke] running on into [tail], a stroke from (0, 0), turned to
  /// come on from it smoothly.
  static List<InkVector> _attach(List<InkVector> stroke, List<InkVector> tail) {
    final InkVector into = _heading(stroke.reversed.toList()) * -1;
    final InkVector out = _heading(tail);
    double turn = math.atan2(into.y, into.x) - math.atan2(out.y, out.x);
    turn = math.atan2(math.sin(turn), math.cos(turn)).clamp(-0.7, 0.7);
    final double c = math.cos(turn);
    final double s = math.sin(turn);
    return <InkVector>[
      ...stroke,
      for (final InkVector p in tail.skip(1))
        stroke.last + InkVector(p.x * c - p.y * s, p.x * s + p.y * c),
    ];
  }

  /// The way [points] set off, over their first unit and a half.
  static InkVector _heading(List<InkVector> points) {
    double walked = 0;
    for (int i = 1; i < points.length; i++) {
      walked += (points[i] - points[i - 1]).length;
      if (walked >= 1.5) return points[i] - points.first;
    }
    final InkVector all = points.last - points.first;
    return all.length < 1e-9 ? const InkVector(0, 1) : all;
  }

  /// [source], a line of the writer's, laid from [start] to [end]: its
  /// bow and wobble kept, in proportion to its length.
  static List<InkVector> _lay(
    List<InkVector> source,
    InkVector start,
    InkVector end,
  ) {
    final InkVector chord = source.last - source.first;
    final double squared = chord.dot(chord);
    if (source.length < 2 || squared < 1e-9) return <InkVector>[start, end];
    final InkVector target = end - start;
    return <InkVector>[
      for (final InkVector p in source)
        () {
          final InkVector v = p - source.first;
          final double along = v.dot(chord) / squared;
          final double aside = (chord.x * v.y - chord.y * v.x) / squared;
          return start + target * along + target.perpendicular * aside;
        }(),
    ];
  }

  /// [strokes] stretched to fill the box from [left], [top] to [right],
  /// [bottom].
  static _Strokes _fit(
    _Strokes strokes,
    double left,
    double top,
    double right,
    double bottom,
  ) {
    final _Box box = _box(strokes);
    final double sx = box.width < 1e-6 ? 1 : (right - left) / box.width;
    final double sy = box.height < 1e-6 ? 1 : (bottom - top) / box.height;
    return <List<InkVector>>[
      for (final List<InkVector> stroke in strokes)
        <InkVector>[
          for (final InkVector p in stroke)
            InkVector(left + (p.x - box.left) * sx, top + (p.y - box.top) * sy),
        ],
    ];
  }

  static _Strokes _moved(_Strokes strokes, InkVector by) => <List<InkVector>>[
    for (final List<InkVector> stroke in strokes)
      <InkVector>[for (final InkVector p in stroke) p + by],
  ];

  static _Strokes _mirrored(_Strokes strokes) => <List<InkVector>>[
    for (final List<InkVector> stroke in strokes)
      <InkVector>[for (final InkVector p in stroke) InkVector(-p.x, p.y)],
  ];

  /// [strokes] with the lines [runs] taken out of them, each stroke cut
  /// where they were; pieces too small to read are left out.
  static _Strokes _without(_Strokes strokes, List<_Run> runs) {
    final _Strokes out = <List<InkVector>>[];
    for (int s = 0; s < strokes.length; s++) {
      final List<_Run> cuts = <_Run>[
        for (final _Run r in runs)
          if (r.stroke == s) r,
      ]..sort((_Run a, _Run b) => a.from.compareTo(b.from));
      if (cuts.isEmpty) {
        out.add(strokes[s]);
        continue;
      }
      // What is left either side of a cut; a scrap of a point or two is
      // not a dot the writer made.
      void keep(List<InkVector> piece) {
        if (piece.length > 1 && pathLength(piece) > 0.8) out.add(piece);
      }

      int start = 0;
      for (final _Run cut in cuts) {
        if (cut.from >= start) keep(strokes[s].sublist(start, cut.from + 1));
        start = math.max(start, cut.to);
      }
      keep(strokes[s].sublist(start));
    }
    return out.where(_useful).toList();
  }

  static bool _useful(List<InkVector> stroke) =>
      stroke.length == 1 || (stroke.length > 1 && pathLength(stroke) > 0.8);
}

/// A straight line in one of a letter's strokes.
class _Run {
  _Run(this.stroke, this.from, this.to, this.points);

  /// Which stroke, and where in it, both ends included.
  final int stroke;
  final int from;
  final int to;
  final List<InkVector> points;

  InkVector get chord => points.last - points.first;
  double get length => chord.length;

  /// How far it leans from upright, from 0 to π/2.
  double get lean => math.atan2(chord.x.abs(), chord.y.abs());

  bool get upright => lean < 25 * _degree;
  bool get level => lean > 60 * _degree;

  /// Whether it falls to the right going down the page, as \.
  bool get fallsRight => chord.x * chord.y > 0;

  double get top => math.min(points.first.y, points.last.y);
  double get bottom => math.max(points.first.y, points.last.y);
  double get centerX => (points.first.x + points.last.x) / 2;
  double get centerY => (points.first.y + points.last.y) / 2;

  List<InkVector> get downward =>
      points.first.y <= points.last.y ? points : points.reversed.toList();

  List<InkVector> get rightward =>
      points.first.x <= points.last.x ? points : points.reversed.toList();
}

List<_Run> _runs(_Strokes strokes) => <_Run>[
  for (int s = 0; s < strokes.length; s++)
    for (final (int from, int to) in straightRuns(
      strokes[s],
      minLength: _minLine,
    ))
      _Run(s, from, to, strokes[s].sublist(from, to + 1)),
];

_Run? _longest(List<_Run> runs, bool Function(_Run run) test) {
  _Run? best;
  for (final _Run run in runs) {
    if (test(run) && (best == null || run.length > best.length)) best = run;
  }
  return best;
}

List<InkVector> _tallestStroke(_Strokes strokes) {
  List<InkVector> tallest = strokes.first;
  for (final List<InkVector> stroke in strokes) {
    if (_box(<List<InkVector>>[stroke]).height >
        _box(<List<InkVector>>[tallest]).height) {
      tallest = stroke;
    }
  }
  return tallest;
}

List<InkVector> _longestStroke(_Strokes strokes) {
  List<InkVector> longest = strokes.first;
  for (final List<InkVector> stroke in strokes) {
    if (pathLength(stroke) > pathLength(longest)) longest = stroke;
  }
  return longest;
}

double? _median(List<double> values) {
  if (values.isEmpty) return null;
  final List<double> sorted = List<double>.of(values)..sort();
  final int middle = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[middle]
      : (sorted[middle - 1] + sorted[middle]) / 2;
}

_Box _box(Iterable<List<InkVector>> strokes) {
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
  if (!left.isFinite) return const _Box(0, 0, 0, 0);
  return _Box(left, top, right, bottom);
}

class _Box {
  const _Box(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;
  InkVector get center => InkVector((left + right) / 2, (top + bottom) / 2);
}
