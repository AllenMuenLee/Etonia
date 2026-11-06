import 'dart:math' as math;

import '../handwriting/handwriting_style.dart';
import '../ink/ink_sample.dart';
import 'notation_glyphs.dart';

/// A single-stroke handwriting font, so that the AI says what to write and
/// the app writes it.
///
/// Glyphs are drawn on a grid where capitals, digits, and ascenders run
/// from y = 0 at the top to y = 10 on the baseline, lowercase letters start
/// near y = 4, and descenders reach y = 13. Each glyph is a list of
/// polylines; a polyline of one point is a dot.
///
/// The letters come from EMS Readability, a single-line font, and are
/// written in a [HandwritingStyle]: one of the [HandwritingFont]s, or the
/// writer's own letters, as they wrote them out.
abstract final class NotationFont {
  /// Grid units from the top of a capital to the baseline.
  static const double capHeight = 10;

  /// Grid units from the top of a capital to the bottom of a descender.
  static const double depth = 13;

  /// Gap between glyphs, in grid units.
  static const double spacing = HandwritingStyle.letterSpacing;

  /// Lines are this many text sizes apart: room enough between one line's
  /// descenders and the next line's capitals to read easily and to write
  /// in.
  static const double lineHeight = 2.0;

  /// Every character the font can write.
  static Iterable<String> get characters => _glyphs.keys;

  /// How wide [char] is, in grid units, or null when the font cannot write
  /// it.
  static double? glyphWidth(String char) => _glyphs[char]?.width;

  /// Where [char]'s ink starts and ends vertically, in capital heights
  /// below the capital line: a capital spans 0 to 1, an x-height letter
  /// about 0.4 to 1, a descender reaches 1.3. Null for a character the font
  /// cannot write or one with no ink.
  static ({double top, double bottom})? glyphSpan(String char) {
    final _Glyph? glyph = _glyphs[char];
    if (glyph == null || glyph.strokes.isEmpty) {
      return null;
    }
    double top = double.infinity;
    double bottom = double.negativeInfinity;
    for (final List<InkVector> stroke in glyph.strokes) {
      for (final InkVector point in stroke) {
        top = math.min(top, point.y);
        bottom = math.max(bottom, point.y);
      }
    }
    return (top: top / capHeight, bottom: bottom / capHeight);
  }

  /// Whether every character of [text] can be written. Line breaks are
  /// allowed.
  static bool canWrite(String text) {
    for (final int rune in text.runes) {
      final String char = String.fromCharCode(rune);
      if (char != '\n' && !_glyphs.containsKey(char)) {
        return false;
      }
    }
    return true;
  }

  /// How wide the longest line of [text] is, written [size] tall in the
  /// standard hand: the height of a capital, in the units of the result.
  /// The lean of the hand is included.
  static double width(String text, double size) {
    double widest = 0;
    for (final String line in text.split('\n')) {
      if (line.isEmpty) continue;
      widest = math.max(
        widest,
        (lineUnits(line) + HandwritingStyle.standard.slant * capHeight) *
            size /
            capHeight,
      );
    }
    return widest;
  }

  /// How far one line of text runs, in grid units, from its first letter's
  /// left edge to its last letter's right edge, without the hand's lean.
  static double lineUnits(String line) {
    double width = 0;
    for (final int rune in line.runes) {
      width += (_glyphs[String.fromCharCode(rune)]?.width ?? 0) + spacing;
    }
    return width == 0 ? 0 : width - spacing;
  }

  /// How tall [text] is, written [size] tall, descenders included.
  static double height(String text, double size) {
    final int lines = '\n'.allMatches(text).length + 1;
    return (lines - 1) * size * lineHeight + size * depth / capHeight;
  }

  /// [text] as polylines, written [size] tall in [style] with the top-left
  /// corner of its first capital at [origin]. Throws an [ArgumentError] for
  /// a character it cannot write.
  static List<List<InkVector>> write(
    String text, {
    required InkVector origin,
    required double size,
    HandwritingStyle style = HandwritingStyle.standard,
  }) {
    final double scale = size / capHeight;
    final double gap = spacing * style.widthScale;
    final List<List<InkVector>> strokes = <List<InkVector>>[];
    final List<String> lines = text.split('\n');
    for (int row = 0; row < lines.length; row++) {
      double x = 0;
      final double top = origin.y + row * size * lineHeight;
      int column = 0;
      // In a joined hand, the letter before, while the next can join it.
      List<List<InkVector>>? previous;
      String? previousChar;
      for (final int rune in lines[row].runes) {
        final String char = String.fromCharCode(rune);
        final _Glyph? glyph = _glyphs[char];
        if (glyph == null) {
          throw ArgumentError('A character the font cannot write');
        }
        if (char == ' ') {
          x += style.wordSpacing + gap;
          column++;
          previous = null;
          continue;
        }
        final double gesture = rune * 0.071 + column * 1.37 + row * 2.11;
        final ({List<List<InkVector>> strokes, double width}) shaped = style
            .shape(char, glyph.strokes, glyph.width, seed: gesture);
        final List<List<InkVector>> letter = <List<InkVector>>[
          for (final List<InkVector> stroke in shaped.strokes)
            <InkVector>[
              for (final InkVector point in stroke)
                InkVector(
                  origin.x + (x + point.x) * scale,
                  top + point.y * scale,
                ),
            ],
        ];
        final bool joins = style.joined && _joinable(char);
        if (joins && previous != null && letter.isNotEmpty) {
          final List<InkVector>? join = _join(
            previous,
            letter,
            fromTop: _joinsFromTop.contains(previousChar ?? ' '),
            baseline: top + capHeight * scale,
            xHeight: style.xHeight * capHeight * scale,
          );
          if (join != null) strokes.add(join);
        }
        strokes.addAll(letter);
        previous = joins && letter.isNotEmpty ? letter : null;
        previousChar = char;
        x += shaped.width + gap;
        column++;
      }
    }
    return strokes;
  }

  /// Whether [char] joins its neighbours in a joined hand: lowercase
  /// letters do.
  static bool _joinable(String char) =>
      char.length == 1 &&
      char.codeUnitAt(0) >= 0x61 &&
      char.codeUnitAt(0) <= 0x7A;

  /// Letters a joined hand leaves from the top of, as its pen ends there.
  static const String _joinsFromTop = 'bovw';

  /// The stroke joined writing draws from the letter [from] into the
  /// letter [to]: from where [from] is left, low on its right, or high
  /// with [fromTop], swinging up into the left of [to] within the
  /// x-height. Null when they are too far apart for a join to read as
  /// one.
  static List<InkVector>? _join(
    List<List<InkVector>> from,
    List<List<InkVector>> to, {
    required bool fromTop,
    required double baseline,
    required double xHeight,
  }) {
    InkVector? end;
    for (final List<InkVector> stroke in from) {
      for (final InkVector p in stroke) {
        final bool low = p.y >= baseline - xHeight * 0.3;
        final bool high = p.y <= baseline - xHeight * 0.6;
        if ((fromTop ? high : low) && (end == null || p.x > end.x)) end = p;
      }
    }
    InkVector? start;
    double best = double.infinity;
    for (final List<InkVector> stroke in to) {
      for (final InkVector p in stroke) {
        if (p.y < baseline - xHeight * 1.05 || p.y > baseline) continue;
        // Leftmost, and near the top of the x-height.
        final double score =
            p.x + 0.5 * (p.y - (baseline - xHeight * 0.75)).abs();
        if (score < best) {
          best = score;
          start = p;
        }
      }
    }
    if (end == null || start == null) return null;
    final double dx = start.x - end.x;
    if (dx < -xHeight * 0.2 || dx > xHeight * 2.5) return null;
    final InkVector c1 = InkVector(
      end.x + dx * 0.45,
      fromTop ? end.y : end.y + xHeight * 0.05,
    );
    final InkVector c2 = InkVector(
      start.x - dx * 0.15,
      start.y + (end.y - start.y) * 0.4,
    );
    const int steps = 8;
    return <InkVector>[
      for (int i = 0; i <= steps; i++)
        () {
          final double t = i / steps;
          final double u = 1 - t;
          return end! * (u * u * u) +
              c1 * (3 * u * u * t) +
              c2 * (3 * u * t * t) +
              start! * (t * t * t);
        }(),
    ];
  }

  static final Map<String, _Glyph> _glyphs = _build();

  static Map<String, _Glyph> _build() {
    final Map<String, _Glyph> glyphs = <String, _Glyph>{
      for (final MapEntry<String, (double, List<List<double>>)> entry
          in notationGlyphs.entries)
        entry.key: _Glyph(entry.value.$1, <List<InkVector>>[
          for (final List<double> flat in entry.value.$2)
            <InkVector>[
              for (int i = 0; i < flat.length; i += 2)
                InkVector(flat[i], flat[i + 1]),
            ],
        ]),
      // As wide as the built-in hand's space, so a line is measured as it
      // is written.
      ' ': _Glyph(HandwritingStyle.standard.wordSpacing, <List<InkVector>>[]),
    };
    glyphs['−'] = glyphs['-']!;
    glyphs['²'] = _small(glyphs['2']!);
    glyphs['³'] = _small(glyphs['3']!);
    // Mathematics the single-line font does not have, drawn by hand.
    glyphs
      ..['≤'] = _Glyph(5.5, <List<InkVector>>[
        <InkVector>[_p(5, 1.5), _p(0.5, 4.5), _p(5, 7.5)],
        <InkVector>[_p(0.5, 9.5), _p(5, 9.5)],
      ])
      ..['≥'] = _Glyph(5.5, <List<InkVector>>[
        <InkVector>[_p(0.5, 1.5), _p(5, 4.5), _p(0.5, 7.5)],
        <InkVector>[_p(0.5, 9.5), _p(5, 9.5)],
      ])
      ..['≠'] = _Glyph(6, <List<InkVector>>[
        <InkVector>[_p(0.5, 4.2), _p(5.5, 4.2)],
        <InkVector>[_p(0.5, 6.8), _p(5.5, 6.8)],
        <InkVector>[_p(4.5, 2.5), _p(1.5, 8.5)],
      ])
      ..['≈'] = _Glyph(6, <List<InkVector>>[
        <InkVector>[
          _p(0, 4.6),
          _p(1.5, 3.6),
          _p(3, 4.6),
          _p(4.5, 5.4),
          _p(6, 4.4),
        ],
        <InkVector>[_p(0, 7.2), _p(1.5, 6.2), _p(3, 7.2), _p(4.5, 8), _p(6, 7)],
      ])
      ..['√'] = _Glyph(9, <List<InkVector>>[
        <InkVector>[
          _p(0, 6),
          _p(1.5, 5.3),
          _p(3, 10),
          _p(5.5, -0.5),
          _p(9, -0.5),
        ],
      ])
      ..['π'] = _Glyph(6, <List<InkVector>>[
        <InkVector>[_p(0, 4), _p(6, 4)],
        <InkVector>[_p(1.8, 4), _p(1.5, 10)],
        <InkVector>[_p(4.3, 4), _p(4.5, 9.5), _p(5.5, 10)],
      ])
      ..['θ'] = _Glyph(6, <List<InkVector>>[
        _arc(3, 5, 3, 5, 0, 360),
        <InkVector>[_p(0, 5), _p(6, 5)],
      ])
      ..['Δ'] = _Glyph(6, <List<InkVector>>[
        <InkVector>[_p(0, 10), _p(3, 0), _p(6, 10), _p(0, 10)],
      ])
      ..['∞'] = _Glyph(8.8, <List<InkVector>>[
        _arc(2.2, 5.5, 2.2, 2, 0, 360),
        _arc(6.6, 5.5, 2.2, 2, 180, 540),
      ])
      ..['→'] = _Glyph(8, <List<InkVector>>[
        <InkVector>[_p(0, 5.5), _p(8, 5.5)],
        <InkVector>[_p(5.5, 3.5), _p(8, 5.5), _p(5.5, 7.5)],
      ])
      ..['←'] = _Glyph(8, <List<InkVector>>[
        <InkVector>[_p(8, 5.5), _p(0, 5.5)],
        <InkVector>[_p(2.5, 3.5), _p(0, 5.5), _p(2.5, 7.5)],
      ])
      ..['✓'] = _Glyph(7, <List<InkVector>>[
        <InkVector>[_p(0, 5.5), _p(2.5, 9.5), _p(7, 0.5)],
      ]);
    _addGreek(glyphs);
    _addSymbols(glyphs);
    return glyphs;
  }

  /// The Greek letters LaTeX names, lowercase on the x-height like the
  /// Latin ones.
  static void _addGreek(Map<String, _Glyph> glyphs) {
    _Glyph lines(double width, List<List<double>> strokes) {
      return _Glyph(width, <List<InkVector>>[
        for (final List<double> flat in strokes)
          <InkVector>[
            for (int i = 0; i < flat.length; i += 2) _p(flat[i], flat[i + 1]),
          ],
      ]);
    }

    glyphs
      ..['α'] = lines(5.5, <List<double>>[
        <double>[
          5.3,
          3.9,
          4.6,
          6.5,
          3.8,
          8.6,
          2.6,
          10,
          1.2,
          9.8,
          0.2,
          8.4,
          0.1,
          6.2,
          0.9,
          4.4,
          2.2,
          3.8,
          3.4,
          4.3,
          4.2,
          6.3,
          4.8,
          8.8,
          5.5,
          10,
        ],
      ])
      ..['β'] = lines(4.8, <List<double>>[
        <double>[
          0.4,
          13,
          0.4,
          2.5,
          1,
          0.6,
          2.2,
          0,
          3.4,
          0.4,
          3.9,
          1.6,
          3.6,
          3,
          2.4,
          4.4,
          1.4,
          4.6,
          2.6,
          4.7,
          4.2,
          5.6,
          4.8,
          7.2,
          4.4,
          8.9,
          3.2,
          10,
          1.8,
          10,
          0.4,
          9,
        ],
      ])
      ..['γ'] = lines(5, <List<double>>[
        <double>[
          0,
          4.2,
          0.9,
          3.8,
          1.7,
          4.6,
          2.8,
          8.2,
          2.8,
          12.2,
          2.4,
          13,
          2,
          12.2,
          2.4,
          10,
          5,
          3.8,
        ],
      ])
      ..['δ'] = lines(4.6, <List<double>>[
        <double>[
          3.8,
          0.6,
          2.4,
          0,
          1.2,
          0.4,
          1.2,
          1.6,
          2.6,
          2.8,
          4.2,
          4.4,
          4.6,
          6.6,
          4.2,
          8.8,
          2.8,
          10,
          1.4,
          9.8,
          0.2,
          8.4,
          0.2,
          6.4,
          1.2,
          4.8,
          2.6,
          3.4,
        ],
      ])
      ..['ε'] = lines(4, <List<double>>[
        <double>[
          3.8,
          4.4,
          2.6,
          3.8,
          1,
          4,
          0.4,
          5,
          1,
          6.4,
          2.6,
          6.8,
          1,
          7,
          0.1,
          8.2,
          0.6,
          9.6,
          2.2,
          10,
          3.9,
          9.4,
        ],
      ])
      ..['ϵ'] = lines(4, <List<double>>[
        <double>[4, 4, 2.4, 3.8, 0.8, 4.6, 0.1, 6.8, 0.6, 9, 2.2, 10, 3.8, 9.6],
        <double>[0.2, 6.9, 3.2, 6.9],
      ])
      ..['ζ'] = lines(4.2, <List<double>>[
        <double>[
          0.8,
          0,
          3.6,
          0,
          1.4,
          2.4,
          0.2,
          5,
          0.2,
          7.8,
          1.2,
          9.4,
          3,
          10,
          3.6,
          11,
          3.2,
          12.4,
          2.4,
          13,
        ],
      ])
      ..['η'] = lines(4.4, <List<double>>[
        <double>[0, 4, 0.4, 3.8, 0.6, 4.6, 0.6, 10],
        <double>[0.6, 5.4, 1.6, 4.1, 2.8, 3.8, 3.8, 4.4, 4.2, 5.6, 4.2, 13],
      ])
      ..['ι'] = lines(1.6, <List<double>>[
        <double>[0.4, 3.8, 0.4, 9.2, 0.9, 10, 1.6, 9.6],
      ])
      ..['κ'] = lines(4.4, <List<double>>[
        <double>[0.4, 3.8, 0.4, 10],
        <double>[4.2, 3.9, 0.4, 7.2],
        <double>[1.6, 6.2, 4.4, 10],
      ])
      ..['λ'] = lines(5, <List<double>>[
        <double>[0.6, 0.2, 1.4, 0, 2.2, 0.8, 5, 10],
        <double>[2.9, 4.2, 0, 10],
      ])
      ..['μ'] = lines(4.6, <List<double>>[
        <double>[0.4, 13, 0.4, 3.8],
        <double>[0.4, 8.2, 1, 9.6, 2.2, 10, 3.4, 9.5, 4, 8.2],
        <double>[4, 3.8, 4, 9.4, 4.6, 10],
      ])
      ..['ν'] = lines(4.4, <List<double>>[
        <double>[0, 3.8, 1.6, 10, 3.6, 7, 4.4, 3.8],
      ])
      ..['ξ'] = lines(4.2, <List<double>>[
        <double>[
          3.6,
          0.2,
          1.6,
          0.2,
          0.8,
          1.2,
          1,
          2.6,
          2.6,
          3.4,
          1,
          3.8,
          0.2,
          5.2,
          0.4,
          7.6,
          1.6,
          9.2,
          3.4,
          10,
          3.8,
          11.2,
          3.2,
          12.6,
          2.4,
          13,
        ],
      ])
      ..['ρ'] = lines(4.6, <List<double>>[
        <double>[
          0.4,
          13,
          0.4,
          6.6,
          0.9,
          4.6,
          2.2,
          3.8,
          3.6,
          4.1,
          4.4,
          5.4,
          4.6,
          7.2,
          4.1,
          9,
          2.8,
          10,
          1.4,
          9.8,
          0.4,
          8.8,
        ],
      ])
      ..['σ'] = lines(5.4, <List<double>>[
        <double>[
          5.4,
          3.8,
          2.4,
          3.8,
          0.8,
          4.6,
          0.1,
          6.6,
          0.4,
          8.8,
          1.8,
          10,
          3.2,
          9.8,
          4.2,
          8.4,
          4.3,
          6.2,
          3.6,
          4.4,
          2.4,
          3.8,
        ],
      ])
      ..['ς'] = lines(4, <List<double>>[
        <double>[
          4,
          4.2,
          2.4,
          3.8,
          0.8,
          4.8,
          0.2,
          6.8,
          1,
          8.6,
          3,
          9.6,
          3.6,
          11,
          3,
          12.6,
          2.2,
          13,
        ],
      ])
      ..['τ'] = lines(4.6, <List<double>>[
        <double>[0, 3.8, 4.6, 3.8],
        <double>[2.3, 3.8, 2.1, 9, 2.6, 10, 3.6, 9.6],
      ])
      ..['υ'] = lines(4.4, <List<double>>[
        <double>[
          0,
          4.4,
          0.5,
          3.8,
          0.8,
          4.4,
          0.8,
          7.8,
          1.6,
          9.6,
          2.6,
          10,
          3.6,
          9.4,
          4.3,
          7.6,
          4.4,
          5.6,
          3.9,
          3.8,
        ],
      ])
      ..['φ'] = lines(5.4, <List<double>>[
        <double>[
          1.4,
          4.2,
          0.2,
          5.8,
          0.3,
          8,
          1.6,
          9.6,
          3,
          10,
          4.6,
          9.4,
          5.4,
          7.6,
          5.2,
          5.4,
          4.2,
          4,
          3.2,
          4.2,
          2.6,
          6,
          2.4,
          13,
        ],
      ])
      ..['ϕ'] = _Glyph(5.4, <List<InkVector>>[
        <InkVector>[_p(2.7, 0.5), _p(2.7, 13)],
        _arc(2.7, 6.9, 2.7, 3.1, 0, 360),
      ])
      ..['χ'] = lines(5, <List<double>>[
        <double>[0, 4, 0.8, 3.8, 1.6, 4.6, 3.6, 12, 4.4, 13, 5, 12.8],
        <double>[4.8, 4, 0.2, 13],
      ])
      ..['ψ'] = lines(5.6, <List<double>>[
        <double>[2.8, 0.6, 2.8, 13],
        <double>[
          0,
          4,
          0.4,
          3.8,
          0.7,
          4.6,
          0.8,
          7.4,
          1.6,
          9.4,
          2.8,
          10,
          4,
          9.4,
          4.8,
          7.4,
          5,
          4.6,
          5.6,
          3.8,
        ],
      ])
      ..['ω'] = lines(6.6, <List<double>>[
        <double>[
          1.2,
          3.9,
          0.2,
          5.6,
          0.2,
          8.2,
          1,
          9.8,
          2.2,
          10,
          3,
          9,
          3.3,
          7,
          3.6,
          9,
          4.4,
          10,
          5.6,
          9.8,
          6.4,
          8.2,
          6.4,
          5.6,
          5.4,
          3.9,
        ],
      ])
      ..['Γ'] = lines(5, <List<double>>[
        <double>[5, 0, 0.4, 0, 0.4, 10],
      ])
      ..['Θ'] = _Glyph(7, <List<InkVector>>[
        _arc(3.5, 5, 3.5, 5, 0, 360),
        <InkVector>[_p(1.8, 5), _p(5.2, 5)],
      ])
      ..['Λ'] = lines(6, <List<double>>[
        <double>[0, 10, 3, 0, 6, 10],
      ])
      ..['Ξ'] = lines(5.6, <List<double>>[
        <double>[0.2, 0, 5.4, 0],
        <double>[1, 5, 4.6, 5],
        <double>[0, 10, 5.6, 10],
      ])
      ..['Π'] = lines(6, <List<double>>[
        <double>[0, 0, 6, 0],
        <double>[0.8, 0, 0.8, 10],
        <double>[5.2, 0, 5.2, 10],
      ])
      ..['Σ'] = lines(5.6, <List<double>>[
        <double>[5.4, 0.8, 5.4, 0, 0, 0, 3, 5, 0, 10, 5.6, 10, 5.6, 9.2],
      ])
      ..['Υ'] = lines(6, <List<double>>[
        <double>[0, 1, 1, 0, 2.2, 0.6, 3, 2.6, 3, 10],
        <double>[3, 2.6, 3.8, 0.6, 5, 0, 6, 1],
      ])
      ..['Φ'] = _Glyph(7, <List<InkVector>>[
        <InkVector>[_p(3.5, 0), _p(3.5, 10)],
        _arc(3.5, 5, 3.5, 2.8, 0, 360),
      ])
      ..['Ψ'] = lines(6.4, <List<double>>[
        <double>[3.2, 0, 3.2, 10],
        <double>[
          0,
          0.4,
          0.4,
          3.6,
          1.4,
          5.6,
          3.2,
          6.4,
          5,
          5.6,
          6,
          3.6,
          6.4,
          0.4,
        ],
      ])
      ..['Ω'] = lines(7.4, <List<double>>[
        <double>[
          0,
          10,
          2.4,
          10,
          2.4,
          9.2,
          1,
          7.6,
          0.4,
          5.4,
          0.8,
          2.6,
          2,
          0.8,
          3.7,
          0,
          5.4,
          0.8,
          6.6,
          2.6,
          7,
          5.4,
          6.4,
          7.6,
          5,
          9.2,
          5,
          10,
          7.4,
          10,
        ],
      ]);
    glyphs
      ..['ϑ'] = glyphs['θ']!
      ..['ϱ'] = glyphs['ρ']!
      ..['ϖ'] = glyphs['π']!;
  }

  /// The operators, relations, arrows, and other symbols of mathematics
  /// that LaTeX names, drawn round the math axis, the height of the middle
  /// of a plus sign.
  static void _addSymbols(Map<String, _Glyph> glyphs) {
    const double axis = 4.95;
    List<InkVector> line(double x0, double y0, double x1, double y1) =>
        <InkVector>[_p(x0, y0), _p(x1, y1)];
    List<InkVector> dot(double x, double y) => <InkVector>[_p(x, y)];
    List<InkVector> wave(double y) => <InkVector>[
      _p(0, y + 0.65),
      _p(0.9, y - 0.35),
      _p(1.9, y - 0.65),
      _p(3.4, y + 0.55),
      _p(4.5, y + 0.65),
      _p(5.4, y - 0.55),
    ];
    List<InkVector> slash(double width) => line(width - 0.8, 0, 0.8, 11);
    List<InkVector> head(double x, double y, double dx) => <InkVector>[
      _p(x - dx, y - 2.6),
      _p(x, y),
      _p(x - dx, y + 2.6),
    ];
    final _Glyph element = _Glyph(5, <List<InkVector>>[
      _arc(5, 5.6, 4.6, 4, 270, 90),
      line(0.4, 5.6, 5, 5.6),
    ]);
    final _Glyph subset = _Glyph(5.4, <List<InkVector>>[
      <InkVector>[_p(5.4, 1.6), ..._arc(3, 5.6, 3, 4, 270, 90), _p(5.4, 9.6)],
    ]);
    final _Glyph superset = _Glyph(5.4, <List<InkVector>>[
      <InkVector>[_p(0, 1.6), ..._arc(2.4, 5.6, 3, 4, 270, 450), _p(0, 9.6)],
    ]);
    glyphs
      ..['−'] = _Glyph(5.32, <List<InkVector>>[line(0, axis, 5.32, axis)])
      ..['±'] = _Glyph(5.4, <List<InkVector>>[
        line(0, 3.9, 5.4, 3.9),
        line(2.7, 1.2, 2.7, 6.6),
        line(0, 9, 5.4, 9),
      ])
      ..['∓'] = _Glyph(5.4, <List<InkVector>>[
        line(0, 1.6, 5.4, 1.6),
        line(0, 6.6, 5.4, 6.6),
        line(2.7, 3.9, 2.7, 9.3),
      ])
      ..['≡'] = _Glyph(5.4, <List<InkVector>>[
        line(0, 2.9, 5.4, 2.9),
        line(0, axis, 5.4, axis),
        line(0, 7, 5.4, 7),
      ])
      ..['∼'] = _Glyph(5.4, <List<InkVector>>[wave(axis)])
      ..['≃'] = _Glyph(5.4, <List<InkVector>>[wave(3.9), line(0, 7, 5.4, 7)])
      ..['≅'] = _Glyph(5.4, <List<InkVector>>[
        wave(2.6),
        line(0, 5.4, 5.4, 5.4),
        line(0, 8, 5.4, 8),
      ])
      ..['∝'] = _Glyph(6.4, <List<InkVector>>[
        <InkVector>[
          _p(6.4, 3.4),
          _p(5, 3.2),
          _p(3.8, 4),
          _p(2.4, 6.2),
          _p(1.2, 6.8),
          _p(0.2, 6.2),
          _p(0, 5),
          _p(0.2, 3.8),
          _p(1.2, 3.2),
          _p(2.4, 3.8),
          _p(3.8, 6),
          _p(5, 6.8),
          _p(6.4, 6.6),
        ],
      ])
      ..['≪'] = _Glyph(7.4, <List<InkVector>>[
        <InkVector>[_p(4.6, 7.4), _p(0, axis), _p(4.6, 2.5)],
        <InkVector>[_p(7.4, 7.4), _p(2.8, axis), _p(7.4, 2.5)],
      ])
      ..['≫'] = _Glyph(7.4, <List<InkVector>>[
        <InkVector>[_p(0, 7.4), _p(4.6, axis), _p(0, 2.5)],
        <InkVector>[_p(2.8, 7.4), _p(7.4, axis), _p(2.8, 2.5)],
      ])
      ..['∈'] = element
      ..['∉'] = _Glyph(5, <List<InkVector>>[...element.strokes, slash(5)])
      ..['∋'] = _Glyph(5, <List<InkVector>>[
        _arc(0, 5.6, 4.6, 4, 270, 450),
        line(0, 5.6, 4.6, 5.6),
      ])
      ..['⊂'] = subset
      ..['⊃'] = superset
      ..['⊆'] = _Glyph(5.4, <List<InkVector>>[
        <InkVector>[_p(5.4, 1), ..._arc(3, 4.4, 3, 3.4, 270, 90), _p(5.4, 7.8)],
        line(0, 10, 5.4, 10),
      ])
      ..['⊇'] = _Glyph(5.4, <List<InkVector>>[
        <InkVector>[_p(0, 1), ..._arc(2.4, 4.4, 3, 3.4, 270, 450), _p(0, 7.8)],
        line(0, 10, 5.4, 10),
      ])
      ..['∪'] = _Glyph(5.4, <List<InkVector>>[
        <InkVector>[_p(0, 2), ..._arc(2.7, 6.6, 2.7, 3.4, 180, 0), _p(5.4, 2)],
      ])
      ..['∩'] = _Glyph(5.4, <List<InkVector>>[
        <InkVector>[
          _p(0, 10),
          ..._arc(2.7, 5.4, 2.7, 3.4, 180, 360),
          _p(5.4, 10),
        ],
      ])
      ..['∧'] = _Glyph(5, <List<InkVector>>[
        <InkVector>[_p(0, 10), _p(2.5, 2), _p(5, 10)],
      ])
      ..['∨'] = _Glyph(5, <List<InkVector>>[
        <InkVector>[_p(0, 2), _p(2.5, 10), _p(5, 2)],
      ])
      ..['⊕'] = _Glyph(6.6, <List<InkVector>>[
        _arc(3.3, axis, 3.3, 3.3, 0, 360),
        line(0, axis, 6.6, axis),
        line(3.3, axis - 3.3, 3.3, axis + 3.3),
      ])
      ..['⊗'] = _Glyph(6.6, <List<InkVector>>[
        _arc(3.3, axis, 3.3, 3.3, 0, 360),
        line(0.97, axis - 2.33, 5.63, axis + 2.33),
        line(0.97, axis + 2.33, 5.63, axis - 2.33),
      ])
      ..['∘'] = _Glyph(3, <List<InkVector>>[_arc(1.5, axis, 1.5, 1.5, 0, 360)])
      ..['∂'] = _Glyph(5, <List<InkVector>>[
        <InkVector>[
          _p(0.8, 1.2),
          _p(2, 0.2),
          _p(3.4, 0.2),
          _p(4.6, 1.6),
          _p(5, 4.4),
          _p(4.6, 7.6),
          _p(3.4, 9.6),
          _p(2, 10),
          _p(0.6, 9.4),
          _p(0.2, 7.8),
          _p(0.8, 6.2),
          _p(2.2, 5.4),
          _p(3.6, 5.6),
          _p(4.8, 6.6),
        ],
      ])
      ..['∇'] = _Glyph(6, <List<InkVector>>[
        <InkVector>[_p(0, 0), _p(6, 0), _p(3, 10), _p(0, 0)],
      ])
      ..['∀'] = _Glyph(6, <List<InkVector>>[
        <InkVector>[_p(0, 0), _p(3, 10), _p(6, 0)],
        line(1.1, 3.7, 4.9, 3.7),
      ])
      ..['∃'] = _Glyph(5, <List<InkVector>>[
        <InkVector>[_p(0, 0), _p(5, 0), _p(5, 10), _p(0, 10)],
        line(1, 5, 5, 5),
      ])
      ..['∄'] = _Glyph(5, <List<InkVector>>[
        <InkVector>[_p(0, 0), _p(5, 0), _p(5, 10), _p(0, 10)],
        line(1, 5, 5, 5),
        slash(5),
      ])
      ..['∅'] = _Glyph(6, <List<InkVector>>[
        _arc(3, 5, 2.8, 4, 0, 360),
        line(5.4, 0, 0.6, 10),
      ])
      ..['∠'] = _Glyph(6.4, <List<InkVector>>[
        <InkVector>[_p(6, 1.6), _p(0, 10), _p(6.4, 10)],
      ])
      ..['⊥'] = _Glyph(6, <List<InkVector>>[
        line(3, 1, 3, 10),
        line(0, 10, 6, 10),
      ])
      ..['∥'] = _Glyph(1.6, <List<InkVector>>[
        line(0, -0.5, 0, 12.5),
        line(1.6, -0.5, 1.6, 12.5),
      ])
      ..['¬'] = _Glyph(5, <List<InkVector>>[
        <InkVector>[_p(0, 4.2), _p(5, 4.2), _p(5, 6.8)],
      ])
      ..['ℓ'] = _Glyph(3, <List<InkVector>>[
        <InkVector>[
          _p(0.2, 8.8),
          _p(1.6, 7),
          _p(2.6, 4.6),
          _p(2.8, 2),
          _p(2.4, 0.4),
          _p(1.8, 0),
          _p(1.2, 0.6),
          _p(0.9, 3),
          _p(0.8, 7),
          _p(1, 9.2),
          _p(1.8, 10),
          _p(2.8, 9.6),
        ],
      ])
      ..['∫'] = _Glyph(3.6, <List<InkVector>>[
        <InkVector>[
          _p(3.6, 0.4),
          _p(3, -0.4),
          _p(2.2, -0.2),
          _p(1.8, 1.4),
          _p(1.8, 10.6),
          _p(1.4, 12.4),
          _p(0.6, 12.6),
          _p(0, 11.8),
        ],
      ])
      ..['∮'] = _Glyph(3.6, <List<InkVector>>[
        <InkVector>[
          _p(3.6, 0.4),
          _p(3, -0.4),
          _p(2.2, -0.2),
          _p(1.8, 1.4),
          _p(1.8, 10.6),
          _p(1.4, 12.4),
          _p(0.6, 12.6),
          _p(0, 11.8),
        ],
        _arc(1.8, 6.1, 1.5, 1.5, 0, 360),
      ])
      ..['⇒'] = _Glyph(8.4, <List<InkVector>>[
        line(0, 3.6, 7, 3.6),
        line(0, 6.3, 7, 6.3),
        head(8.4, axis, 3),
      ])
      ..['⇐'] = _Glyph(8.4, <List<InkVector>>[
        line(1.4, 3.6, 8.4, 3.6),
        line(1.4, 6.3, 8.4, 6.3),
        head(0, axis, -3),
      ])
      ..['⇔'] = _Glyph(10, <List<InkVector>>[
        line(1.4, 3.6, 8.6, 3.6),
        line(1.4, 6.3, 8.6, 6.3),
        head(0, axis, -3),
        head(10, axis, 3),
      ])
      ..['↔'] = _Glyph(9, <List<InkVector>>[
        line(0, axis, 9, axis),
        head(0, axis, -2.5),
        head(9, axis, 2.5),
      ])
      ..['↦'] = _Glyph(8, <List<InkVector>>[
        line(0, axis - 2, 0, axis + 2),
        line(0, axis, 8, axis),
        head(8, axis, 2.5),
      ])
      ..['↑'] = _Glyph(4, <List<InkVector>>[
        line(2, 10, 2, 0),
        <InkVector>[_p(0, 2.5), _p(2, 0), _p(4, 2.5)],
      ])
      ..['↓'] = _Glyph(4, <List<InkVector>>[
        line(2, 0, 2, 10),
        <InkVector>[_p(0, 7.5), _p(2, 10), _p(4, 7.5)],
      ])
      ..['⋯'] = _Glyph(6, <List<InkVector>>[
        dot(0.4, axis),
        dot(3, axis),
        dot(5.6, axis),
      ])
      ..['…'] = _Glyph(6, <List<InkVector>>[
        dot(0.4, 9.6),
        dot(3, 9.6),
        dot(5.6, 9.6),
      ])
      ..['⋮'] = _Glyph(0.8, <List<InkVector>>[
        dot(0.4, 1.4),
        dot(0.4, 5.4),
        dot(0.4, 9.4),
      ])
      ..['⋱'] = _Glyph(6, <List<InkVector>>[
        dot(0.4, 1.4),
        dot(3, 5.4),
        dot(5.6, 9.4),
      ])
      ..['′'] = _Glyph(1.6, <List<InkVector>>[line(1.6, -0.2, 0.4, 3.4)])
      ..['″'] = _Glyph(3, <List<InkVector>>[
        line(1.6, -0.2, 0.4, 3.4),
        line(3, -0.2, 1.8, 3.4),
      ])
      ..['⟨'] = _Glyph(2.6, <List<InkVector>>[
        <InkVector>[_p(2.6, -0.4), _p(0, 6), _p(2.6, 12.4)],
      ])
      ..['⟩'] = _Glyph(2.6, <List<InkVector>>[
        <InkVector>[_p(0, -0.4), _p(2.6, 6), _p(0, 12.4)],
      ])
      ..['ℤ'] = _Glyph(5.4, <List<InkVector>>[
        line(0.2, 0, 5.4, 0),
        line(5.4, 0, 1.4, 10),
        line(4, 0, 0, 10),
        line(0, 10, 5.4, 10),
      ]);
    glyphs
      ..['∑'] = glyphs['Σ']!
      ..['∏'] = glyphs['Π']!
      ..['△'] = glyphs['Δ']!
      ..['‖'] = glyphs['∥']!
      ..['∖'] = glyphs['\\']!
      ..['∗'] = glyphs['*']!
      ..['⋅'] = glyphs['·']!
      ..['ℏ'] = glyphs['ħ'] = _Glyph(glyphs['h']!.width, <List<InkVector>>[
        ...glyphs['h']!.strokes,
        line(-0.6, 2.6, 2.4, 1.2),
      ]);
    // Blackboard bold: the letter with a second stem beside its first.
    for (final (String letter, String bold) in <(String, String)>[
      ('R', 'ℝ'),
      ('N', 'ℕ'),
      ('Q', 'ℚ'),
      ('C', 'ℂ'),
    ]) {
      final _Glyph glyph = glyphs[letter]!;
      double left = double.infinity;
      for (final List<InkVector> stroke in glyph.strokes) {
        for (final InkVector p in stroke) {
          left = math.min(left, p.x);
        }
      }
      final bool round = letter == 'Q' || letter == 'C';
      glyphs[bold] = _Glyph(glyph.width, <List<InkVector>>[
        ...glyph.strokes,
        line(left + 1.1, round ? 1.6 : 0, left + 1.1, round ? 8.4 : 10),
      ]);
    }
  }

  /// [glyph] at half size, raised, as an exponent.
  static _Glyph _small(_Glyph glyph) {
    return _Glyph(glyph.width / 2, <List<InkVector>>[
      for (final List<InkVector> line in glyph.strokes)
        <InkVector>[
          for (final InkVector point in line)
            InkVector(point.x / 2, point.y / 2),
        ],
    ]);
  }

  static InkVector _p(double x, double y) => InkVector(x, y);

  /// Points along an ellipse around ([cx], [cy]) from angle [from] to [to],
  /// in degrees, both included. 0 points right and angles grow clockwise,
  /// since y grows down.
  static List<InkVector> _arc(
    double cx,
    double cy,
    double rx,
    double ry,
    double from,
    double to,
  ) {
    final int steps = math.max(2, ((to - from).abs() / 22.5).ceil());
    return <InkVector>[
      for (int i = 0; i <= steps; i++)
        InkVector(
          cx + rx * math.cos((from + (to - from) * i / steps) * math.pi / 180),
          cy + ry * math.sin((from + (to - from) * i / steps) * math.pi / 180),
        ),
    ];
  }
}

class _Glyph {
  const _Glyph(this.width, this.strokes);

  final double width;
  final List<List<InkVector>> strokes;
}
