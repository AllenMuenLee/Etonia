import 'dart:math' as math;

import '../ink/ink_sample.dart';

/// A single-stroke handwriting font, so that the AI says what to write and
/// the app writes it.
///
/// Glyphs are drawn on a grid where capitals and digits run from y = 0 at
/// the top to y = 10 on the baseline, lowercase letters start at y = 4, and
/// descenders reach y = 13. Each glyph is a list of polylines; a polyline
/// of one point is a dot.
abstract final class NotationFont {
  /// Grid units from the top of a capital to the baseline.
  static const double capHeight = 10;

  /// Grid units from the top of a capital to the bottom of a descender.
  static const double depth = 13;

  /// Gap between glyphs, in grid units.
  static const double spacing = 1.6;

  /// Lines are this many text sizes apart.
  static const double lineHeight = 1.6;

  /// Every character the font can write.
  static Iterable<String> get characters => _glyphs.keys;

  /// How wide [char] is, in grid units, or null when the font cannot write
  /// it.
  static double? glyphWidth(String char) => _glyphs[char]?.width;

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

  /// How wide the longest line of [text] is, written [size] tall: the
  /// height of a capital, in the units of the result.
  static double width(String text, double size) {
    double widest = 0;
    for (final String line in text.split('\n')) {
      widest = math.max(widest, _lineWidth(line) * size / capHeight);
    }
    return widest;
  }

  /// How tall [text] is, written [size] tall, descenders included.
  static double height(String text, double size) {
    final int lines = '\n'.allMatches(text).length + 1;
    return (lines - 1) * size * lineHeight + size * depth / capHeight;
  }

  /// [text] as polylines, written [size] tall with the top-left corner of
  /// its first capital at [origin]. Throws an [ArgumentError] for a
  /// character it cannot write.
  static List<List<InkVector>> write(
    String text, {
    required InkVector origin,
    required double size,
  }) {
    final double scale = size / capHeight;
    final List<List<InkVector>> strokes = <List<InkVector>>[];
    final List<String> lines = text.split('\n');
    for (int row = 0; row < lines.length; row++) {
      double x = 0;
      final double top = origin.y + row * size * lineHeight;
      int column = 0;
      for (final int rune in lines[row].runes) {
        final _Glyph? glyph = _glyphs[String.fromCharCode(rune)];
        if (glyph == null) {
          throw ArgumentError('A character the font cannot write');
        }
        final double gesture = rune * 0.071 + column * 1.37 + row * 2.11;
        final double baselineDrift = 0.11 * math.sin(gesture);
        final double stretch = 1 + 0.025 * math.sin(gesture * 1.73);
        final double rotation = 0.018 * math.sin(gesture * 0.83);
        final double cosine = math.cos(rotation);
        final double sine = math.sin(rotation);
        for (int stroke = 0; stroke < glyph.strokes.length; stroke++) {
          final List<InkVector> line = glyph.strokes[stroke];
          strokes.add(<InkVector>[
            for (final InkVector point in line)
              _handPoint(
                point,
                origin: origin,
                top: top,
                x: x,
                glyphWidth: glyph.width,
                scale: scale,
                stretch: stretch,
                cosine: cosine,
                sine: sine,
                baselineDrift: baselineDrift,
                gesture: gesture + stroke * 0.91,
              ),
          ]);
        }
        x += glyph.width + spacing;
        column++;
      }
    }
    return strokes;
  }

  /// Gives the otherwise exact plotter font the small inconsistencies of a
  /// real hand. The variation is derived from the text itself rather than
  /// randomness, so a note lays out identically every time it is opened.
  static InkVector _handPoint(
    InkVector point, {
    required InkVector origin,
    required double top,
    required double x,
    required double glyphWidth,
    required double scale,
    required double stretch,
    required double cosine,
    required double sine,
    required double baselineDrift,
    required double gesture,
  }) {
    final double centerX = glyphWidth / 2;
    final double dx = (point.x - centerX) * stretch;
    final double dy = point.y - capHeight;
    // A shared forward lean reads as handwriting. Rotation, baseline drift,
    // and a very small pen wobble stop repeated letters looking stamped.
    final double leanedX =
        dx * cosine - dy * sine + (capHeight - point.y) * 0.055;
    final double turnedY = dx * sine + dy * cosine + capHeight;
    final double wobbleX = 0.055 * math.sin(gesture + point.y * 0.79);
    final double wobbleY = 0.065 * math.sin(gesture * 1.19 + point.x * 0.67);
    return InkVector(
      origin.x + (x + centerX + leanedX + wobbleX) * scale,
      top + (turnedY + baselineDrift + wobbleY) * scale,
    );
  }

  static double _lineWidth(String line) {
    double width = 0;
    for (final int rune in line.runes) {
      width += (_glyphs[String.fromCharCode(rune)]?.width ?? 0) + spacing;
    }
    return width == 0 ? 0 : width - spacing;
  }

  static final Map<String, _Glyph> _glyphs = _build();

  static Map<String, _Glyph> _build() {
    final Map<String, _Glyph> g = <String, _Glyph>{};
    _Glyph glyph(double width, List<List<InkVector>> strokes) {
      return _Glyph(width, strokes);
    }

    final _Glyph two = glyph(6, <List<InkVector>>[
      <InkVector>[..._arc(3, 3, 3, 3, 180, 405), _p(0, 10), _p(6, 10)],
    ]);
    final _Glyph three = glyph(6, <List<InkVector>>[
      <InkVector>[
        ..._arc(3, 2.5, 3, 2.5, 200, 450),
        ..._arc(3, 7.5, 3, 2.5, 270, 520),
      ],
    ]);
    final List<InkVector> lowerBowl = _arc(2.5, 7, 2.5, 3, 0, 360);
    final List<InkVector> capitalBowl = _arc(3.5, 5, 3.5, 5, 0, 360);

    g
      // Digits.
      ..['0'] = glyph(6, <List<InkVector>>[_arc(3, 5, 3, 5, 0, 360)])
      ..['1'] = glyph(4, <List<InkVector>>[
        <InkVector>[_p(0.5, 2), _p(2.5, 0), _p(2.5, 10)],
      ])
      ..['2'] = two
      ..['3'] = three
      ..['4'] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(4.5, 10), _p(4.5, 0), _p(0, 7), _p(6, 7)],
      ])
      ..['5'] = glyph(6, <List<InkVector>>[
        <InkVector>[
          _p(5.5, 0),
          _p(0.5, 0),
          _p(0.2, 4.6),
          ..._arc(3, 6.8, 3, 3.2, 225, 500),
        ],
      ])
      ..['6'] = glyph(6, <List<InkVector>>[
        <InkVector>[
          _p(5, 0.6),
          _p(3, 0),
          _p(1, 1),
          _p(0, 4),
          ..._arc(3, 7, 3, 3, 180, 540),
        ],
      ])
      ..['7'] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(0, 0), _p(6, 0), _p(2, 10)],
      ])
      ..['8'] = glyph(6, <List<InkVector>>[
        _arc(3, 2.5, 2.6, 2.5, 90, 450),
        _arc(3, 7.5, 3, 2.5, 270, 630),
      ])
      ..['9'] = glyph(6, <List<InkVector>>[
        _arc(3, 3, 3, 3, 0, 360),
        <InkVector>[_p(6, 3), _p(6, 6), _p(5, 9), _p(3, 10), _p(1, 9.5)],
      ])
      // Capitals.
      ..['A'] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(0, 10), _p(3, 0), _p(6, 10)],
        <InkVector>[_p(1, 6.5), _p(5, 6.5)],
      ])
      ..['B'] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(0, 0), _p(0, 10)],
        <InkVector>[_p(0, 0), ..._arc(3.5, 2.5, 2.5, 2.5, 270, 450), _p(0, 5)],
        <InkVector>[_p(0, 5), ..._arc(4, 7.5, 2.5, 2.5, 270, 450), _p(0, 10)],
      ])
      ..['C'] = glyph(6.5, <List<InkVector>>[_arc(3.5, 5, 3.5, 5, -40, -320)])
      ..['D'] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(0, 0), _p(0, 10)],
        <InkVector>[_p(0, 0), ..._arc(2, 5, 4, 5, 270, 450), _p(0, 10)],
      ])
      ..['E'] = glyph(5.5, <List<InkVector>>[
        <InkVector>[_p(5.5, 0), _p(0, 0), _p(0, 10), _p(5.5, 10)],
        <InkVector>[_p(0, 5), _p(4.5, 5)],
      ])
      ..['F'] = glyph(5.5, <List<InkVector>>[
        <InkVector>[_p(5.5, 0), _p(0, 0), _p(0, 10)],
        <InkVector>[_p(0, 5), _p(4.5, 5)],
      ])
      ..['G'] = glyph(6.5, <List<InkVector>>[
        <InkVector>[..._arc(3.5, 5, 3.5, 5, -40, -360), _p(4, 5)],
      ])
      ..['H'] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(0, 0), _p(0, 10)],
        <InkVector>[_p(6, 0), _p(6, 10)],
        <InkVector>[_p(0, 5), _p(6, 5)],
      ])
      ..['I'] = glyph(4, <List<InkVector>>[
        <InkVector>[_p(0, 0), _p(4, 0)],
        <InkVector>[_p(2, 0), _p(2, 10)],
        <InkVector>[_p(0, 10), _p(4, 10)],
      ])
      ..['J'] = glyph(5, <List<InkVector>>[
        <InkVector>[_p(1, 0), _p(5, 0)],
        <InkVector>[_p(4, 0), _p(4, 7.5), ..._arc(2, 7.5, 2, 2.5, 0, 180)],
      ])
      ..['K'] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(0, 0), _p(0, 10)],
        <InkVector>[_p(6, 0), _p(0, 6)],
        <InkVector>[_p(2, 4.3), _p(6, 10)],
      ])
      ..['L'] = glyph(5.5, <List<InkVector>>[
        <InkVector>[_p(0, 0), _p(0, 10), _p(5.5, 10)],
      ])
      ..['M'] = glyph(8, <List<InkVector>>[
        <InkVector>[_p(0, 10), _p(0, 0), _p(4, 7), _p(8, 0), _p(8, 10)],
      ])
      ..['N'] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(0, 10), _p(0, 0), _p(6, 10), _p(6, 0)],
      ])
      ..['O'] = glyph(7, <List<InkVector>>[capitalBowl])
      ..['P'] = glyph(6, <List<InkVector>>[
        <InkVector>[
          _p(0, 10),
          _p(0, 0),
          ..._arc(3.5, 2.75, 2.5, 2.75, 270, 450),
          _p(0, 5.5),
        ],
      ])
      ..['Q'] = glyph(7, <List<InkVector>>[
        capitalBowl,
        <InkVector>[_p(4, 7), _p(7, 10.5)],
      ])
      ..['R'] = glyph(6, <List<InkVector>>[
        <InkVector>[
          _p(0, 10),
          _p(0, 0),
          ..._arc(3.5, 2.75, 2.5, 2.75, 270, 450),
          _p(0, 5.5),
        ],
        <InkVector>[_p(3, 5.5), _p(6, 10)],
      ])
      ..['S'] = glyph(6, <List<InkVector>>[
        <InkVector>[
          ..._arc(3, 2.6, 2.8, 2.6, -30, -270),
          ..._arc(3, 7.5, 3, 2.5, -90, 150),
        ],
      ])
      ..['T'] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(0, 0), _p(6, 0)],
        <InkVector>[_p(3, 0), _p(3, 10)],
      ])
      ..['U'] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(0, 0), _p(0, 7), ..._arc(3, 7, 3, 3, 180, 0), _p(6, 0)],
      ])
      ..['V'] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(0, 0), _p(3, 10), _p(6, 0)],
      ])
      ..['W'] = glyph(8, <List<InkVector>>[
        <InkVector>[_p(0, 0), _p(2, 10), _p(4, 3), _p(6, 10), _p(8, 0)],
      ])
      ..['X'] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(0, 0), _p(6, 10)],
        <InkVector>[_p(6, 0), _p(0, 10)],
      ])
      ..['Y'] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(0, 0), _p(3, 5), _p(6, 0)],
        <InkVector>[_p(3, 5), _p(3, 10)],
      ])
      ..['Z'] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(0, 0), _p(6, 0), _p(0, 10), _p(6, 10)],
      ])
      // Lowercase.
      ..['a'] = glyph(5, <List<InkVector>>[
        lowerBowl,
        <InkVector>[_p(5, 4), _p(5, 10)],
      ])
      ..['b'] = glyph(5, <List<InkVector>>[
        <InkVector>[_p(0, 0), _p(0, 10)],
        lowerBowl,
      ])
      ..['c'] = glyph(5, <List<InkVector>>[_arc(2.7, 7, 2.7, 3, -40, -320)])
      ..['d'] = glyph(5, <List<InkVector>>[
        lowerBowl,
        <InkVector>[_p(5, 0), _p(5, 10)],
      ])
      ..['e'] = glyph(5, <List<InkVector>>[
        <InkVector>[_p(0, 7), _p(5, 7), ..._arc(2.5, 7, 2.5, 3, 0, -320)],
      ])
      ..['f'] = glyph(4.5, <List<InkVector>>[
        <InkVector>[
          _p(4.5, 0.5),
          _p(3.5, 0),
          _p(2.5, 0),
          _p(1.5, 1),
          _p(1.5, 10),
        ],
        <InkVector>[_p(0, 4), _p(4, 4)],
      ])
      ..['g'] = glyph(5, <List<InkVector>>[
        lowerBowl,
        <InkVector>[
          _p(5, 4),
          _p(5, 11),
          _p(4, 12.7),
          _p(2.5, 13),
          _p(0.8, 12.5),
        ],
      ])
      ..['h'] = glyph(5, <List<InkVector>>[
        <InkVector>[_p(0, 0), _p(0, 10)],
        <InkVector>[..._arc(2.5, 6.5, 2.5, 2.5, 180, 360), _p(5, 10)],
      ])
      ..['i'] = glyph(2, <List<InkVector>>[
        <InkVector>[_p(1, 4), _p(1, 10)],
        <InkVector>[_p(1, 1.8)],
      ])
      ..['j'] = glyph(3, <List<InkVector>>[
        <InkVector>[_p(2.5, 4), _p(2.5, 11.5), _p(1.8, 12.8), _p(0.5, 13)],
        <InkVector>[_p(2.5, 1.8)],
      ])
      ..['k'] = glyph(5, <List<InkVector>>[
        <InkVector>[_p(0, 0), _p(0, 10)],
        <InkVector>[_p(4.5, 4), _p(0, 8)],
        <InkVector>[_p(1.6, 6.7), _p(5, 10)],
      ])
      ..['l'] = glyph(2, <List<InkVector>>[
        <InkVector>[_p(1, 0), _p(1, 10)],
      ])
      ..['m'] = glyph(8, <List<InkVector>>[
        <InkVector>[_p(0, 4), _p(0, 10)],
        <InkVector>[..._arc(2, 6.2, 2, 2.2, 180, 360), _p(4, 10)],
        <InkVector>[..._arc(6, 6.2, 2, 2.2, 180, 360), _p(8, 10)],
      ])
      ..['n'] = glyph(5, <List<InkVector>>[
        <InkVector>[_p(0, 4), _p(0, 10)],
        <InkVector>[..._arc(2.5, 6.5, 2.5, 2.5, 180, 360), _p(5, 10)],
      ])
      ..['o'] = glyph(5, <List<InkVector>>[lowerBowl])
      ..['p'] = glyph(5, <List<InkVector>>[
        <InkVector>[_p(0, 4), _p(0, 13)],
        lowerBowl,
      ])
      ..['q'] = glyph(5, <List<InkVector>>[
        lowerBowl,
        <InkVector>[_p(5, 4), _p(5, 13)],
      ])
      ..['r'] = glyph(4.5, <List<InkVector>>[
        <InkVector>[_p(0, 4), _p(0, 10)],
        _arc(3, 6.5, 3, 2.5, 180, 300),
      ])
      ..['s'] = glyph(5, <List<InkVector>>[
        <InkVector>[
          ..._arc(2.5, 5.5, 2.3, 1.5, -30, -270),
          ..._arc(2.5, 8.5, 2.5, 1.5, -90, 150),
        ],
      ])
      ..['t'] = glyph(4, <List<InkVector>>[
        <InkVector>[_p(2, 1.5), _p(2, 9), _p(2.8, 10), _p(4, 9.8)],
        <InkVector>[_p(0, 4), _p(4, 4)],
      ])
      ..['u'] = glyph(5, <List<InkVector>>[
        <InkVector>[_p(0, 4), _p(0, 7.5), ..._arc(2.5, 7.5, 2.5, 2.5, 180, 0)],
        <InkVector>[_p(5, 4), _p(5, 10)],
      ])
      ..['v'] = glyph(5, <List<InkVector>>[
        <InkVector>[_p(0, 4), _p(2.5, 10), _p(5, 4)],
      ])
      ..['w'] = glyph(7, <List<InkVector>>[
        <InkVector>[_p(0, 4), _p(1.8, 10), _p(3.5, 5.5), _p(5.2, 10), _p(7, 4)],
      ])
      ..['x'] = glyph(5, <List<InkVector>>[
        <InkVector>[_p(0, 4), _p(5, 10)],
        <InkVector>[_p(5, 4), _p(0, 10)],
      ])
      ..['y'] = glyph(5, <List<InkVector>>[
        <InkVector>[_p(0, 4), _p(2.5, 10)],
        <InkVector>[_p(5, 4), _p(2, 11.5), _p(1, 12.8), _p(0, 13)],
      ])
      ..['z'] = glyph(5, <List<InkVector>>[
        <InkVector>[_p(0, 4), _p(5, 4), _p(0, 10), _p(5, 10)],
      ])
      // Punctuation.
      ..[' '] = glyph(3, const <List<InkVector>>[])
      ..['.'] = glyph(1, <List<InkVector>>[
        <InkVector>[_p(0.5, 10)],
      ])
      ..[','] = glyph(1.5, <List<InkVector>>[
        <InkVector>[_p(1, 9.6), _p(1, 10.5), _p(0.3, 11.8)],
      ])
      ..[':'] = glyph(1, <List<InkVector>>[
        <InkVector>[_p(0.5, 5)],
        <InkVector>[_p(0.5, 10)],
      ])
      ..[';'] = glyph(1.5, <List<InkVector>>[
        <InkVector>[_p(1, 5)],
        <InkVector>[_p(1, 9.6), _p(1, 10.5), _p(0.3, 11.8)],
      ])
      ..['!'] = glyph(2, <List<InkVector>>[
        <InkVector>[_p(1, 0), _p(1, 7)],
        <InkVector>[_p(1, 10)],
      ])
      ..['?'] = glyph(6, <List<InkVector>>[
        <InkVector>[..._arc(3, 2.8, 3, 2.8, 180, 405), _p(3, 6.2), _p(3, 7.5)],
        <InkVector>[_p(3, 10)],
      ])
      ..['\''] = glyph(1, <List<InkVector>>[
        <InkVector>[_p(0.5, 0), _p(0.5, 3)],
      ])
      ..['"'] = glyph(3, <List<InkVector>>[
        <InkVector>[_p(0.5, 0), _p(0.5, 3)],
        <InkVector>[_p(2.5, 0), _p(2.5, 3)],
      ])
      ..['('] = glyph(3, <List<InkVector>>[_arc(4, 5, 3.5, 6, 236, 124)])
      ..[')'] = glyph(3, <List<InkVector>>[_arc(-1, 5, 3.5, 6, -56, 56)])
      ..['['] = glyph(3, <List<InkVector>>[
        <InkVector>[_p(2.5, -0.5), _p(0.5, -0.5), _p(0.5, 10.5), _p(2.5, 10.5)],
      ])
      ..[']'] = glyph(3, <List<InkVector>>[
        <InkVector>[_p(0.5, -0.5), _p(2.5, -0.5), _p(2.5, 10.5), _p(0.5, 10.5)],
      ])
      ..['{'] = glyph(3.5, <List<InkVector>>[
        <InkVector>[
          _p(3, -0.5),
          _p(2, 0),
          _p(1.6, 1.5),
          _p(1.6, 4),
          _p(0.5, 5),
          _p(1.6, 6),
          _p(1.6, 8.5),
          _p(2, 10),
          _p(3, 10.5),
        ],
      ])
      ..['}'] = glyph(3.5, <List<InkVector>>[
        <InkVector>[
          _p(0.5, -0.5),
          _p(1.5, 0),
          _p(1.9, 1.5),
          _p(1.9, 4),
          _p(3, 5),
          _p(1.9, 6),
          _p(1.9, 8.5),
          _p(1.5, 10),
          _p(0.5, 10.5),
        ],
      ])
      ..['|'] = glyph(2, <List<InkVector>>[
        <InkVector>[_p(1, -0.5), _p(1, 10.5)],
      ])
      ..['_'] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(0, 10.5), _p(6, 10.5)],
      ])
      ..['~'] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(0, 6), _p(1.5, 4.8), _p(3, 6), _p(4.5, 7), _p(6, 5.8)],
      ])
      ..['#'] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(2, 0.5), _p(1, 10)],
        <InkVector>[_p(5, 0.5), _p(4, 10)],
        <InkVector>[_p(0, 3.5), _p(6, 3.5)],
        <InkVector>[_p(0, 7), _p(6, 7)],
      ])
      ..['%'] = glyph(7, <List<InkVector>>[
        _arc(1.5, 2, 1.3, 1.8, 0, 360),
        _arc(5.5, 8, 1.3, 1.8, 0, 360),
        <InkVector>[_p(6, 0.5), _p(1, 9.5)],
      ])
      ..['\$'] = glyph(6, <List<InkVector>>[
        <InkVector>[
          ..._arc(3, 2.6, 2.8, 2.1, -30, -270),
          ..._arc(3, 6.9, 3, 2.2, -90, 150),
        ],
        <InkVector>[_p(3, -0.8), _p(3, 9.9)],
      ])
      ..['&'] = glyph(6.5, <List<InkVector>>[
        <InkVector>[
          _p(6.5, 10),
          _p(2, 4),
          _p(1.6, 2.4),
          _p(2.5, 0.6),
          _p(3.6, 1),
          _p(3.8, 2.4),
          _p(2.8, 4),
          _p(0.8, 6.3),
          _p(0.6, 8.4),
          _p(1.8, 9.9),
          _p(3.6, 9.8),
          _p(5.6, 7),
        ],
      ])
      ..['@'] = glyph(8.6, <List<InkVector>>[
        _arc(4.3, 5.6, 1.7, 2.1, 0, 360),
        <InkVector>[
          _p(6, 3.4),
          _p(6, 7.2),
          _p(7.2, 7.6),
          ..._arc(4.3, 5.3, 4.3, 4.7, 10, -300),
        ],
      ])
      // Mathematics.
      ..['+'] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(0.5, 5.5), _p(5.5, 5.5)],
        <InkVector>[_p(3, 3), _p(3, 8)],
      ])
      ..['-'] = glyph(5, <List<InkVector>>[
        <InkVector>[_p(0.5, 5.5), _p(4.5, 5.5)],
      ])
      ..['−'] = glyph(5, <List<InkVector>>[
        <InkVector>[_p(0.5, 5.5), _p(4.5, 5.5)],
      ])
      ..['='] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(0.5, 4.2), _p(5.5, 4.2)],
        <InkVector>[_p(0.5, 6.8), _p(5.5, 6.8)],
      ])
      ..['*'] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(3, 3), _p(3, 8)],
        <InkVector>[_p(0.8, 4.2), _p(5.2, 6.8)],
        <InkVector>[_p(5.2, 4.2), _p(0.8, 6.8)],
      ])
      ..['×'] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(1, 3.5), _p(5, 7.5)],
        <InkVector>[_p(5, 3.5), _p(1, 7.5)],
      ])
      ..['·'] = glyph(1, <List<InkVector>>[
        <InkVector>[_p(0.5, 5.5)],
      ])
      ..['÷'] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(0.5, 5.5), _p(5.5, 5.5)],
        <InkVector>[_p(3, 3)],
        <InkVector>[_p(3, 8)],
      ])
      ..['/'] = glyph(5, <List<InkVector>>[
        <InkVector>[_p(0, 10.5), _p(5, -0.5)],
      ])
      ..['\\'] = glyph(5, <List<InkVector>>[
        <InkVector>[_p(0, -0.5), _p(5, 10.5)],
      ])
      ..['^'] = glyph(4, <List<InkVector>>[
        <InkVector>[_p(0, 4), _p(2, 0.5), _p(4, 4)],
      ])
      ..['<'] = glyph(5.5, <List<InkVector>>[
        <InkVector>[_p(5, 2.5), _p(0.5, 5.5), _p(5, 8.5)],
      ])
      ..['>'] = glyph(5.5, <List<InkVector>>[
        <InkVector>[_p(0.5, 2.5), _p(5, 5.5), _p(0.5, 8.5)],
      ])
      ..['≤'] = glyph(5.5, <List<InkVector>>[
        <InkVector>[_p(5, 1.5), _p(0.5, 4.5), _p(5, 7.5)],
        <InkVector>[_p(0.5, 9.5), _p(5, 9.5)],
      ])
      ..['≥'] = glyph(5.5, <List<InkVector>>[
        <InkVector>[_p(0.5, 1.5), _p(5, 4.5), _p(0.5, 7.5)],
        <InkVector>[_p(0.5, 9.5), _p(5, 9.5)],
      ])
      ..['≠'] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(0.5, 4.2), _p(5.5, 4.2)],
        <InkVector>[_p(0.5, 6.8), _p(5.5, 6.8)],
        <InkVector>[_p(4.5, 2.5), _p(1.5, 8.5)],
      ])
      ..['≈'] = glyph(6, <List<InkVector>>[
        <InkVector>[
          _p(0, 4.6),
          _p(1.5, 3.6),
          _p(3, 4.6),
          _p(4.5, 5.4),
          _p(6, 4.4),
        ],
        <InkVector>[_p(0, 7.2), _p(1.5, 6.2), _p(3, 7.2), _p(4.5, 8), _p(6, 7)],
      ])
      ..['±'] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(0.5, 4.5), _p(5.5, 4.5)],
        <InkVector>[_p(3, 2), _p(3, 7)],
        <InkVector>[_p(0.5, 9), _p(5.5, 9)],
      ])
      ..['√'] = glyph(9, <List<InkVector>>[
        <InkVector>[
          _p(0, 6),
          _p(1.5, 5.3),
          _p(3, 10),
          _p(5.5, -0.5),
          _p(9, -0.5),
        ],
      ])
      ..['π'] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(0, 4), _p(6, 4)],
        <InkVector>[_p(1.8, 4), _p(1.5, 10)],
        <InkVector>[_p(4.3, 4), _p(4.5, 9.5), _p(5.5, 10)],
      ])
      ..['θ'] = glyph(6, <List<InkVector>>[
        _arc(3, 5, 3, 5, 0, 360),
        <InkVector>[_p(0, 5), _p(6, 5)],
      ])
      ..['Δ'] = glyph(6, <List<InkVector>>[
        <InkVector>[_p(0, 10), _p(3, 0), _p(6, 10), _p(0, 10)],
      ])
      ..['∞'] = glyph(8.8, <List<InkVector>>[
        _arc(2.2, 5.5, 2.2, 2, 0, 360),
        _arc(6.6, 5.5, 2.2, 2, 180, 540),
      ])
      ..['°'] = glyph(3, <List<InkVector>>[_arc(1.5, 1.5, 1.3, 1.3, 0, 360)])
      ..['→'] = glyph(8, <List<InkVector>>[
        <InkVector>[_p(0, 5.5), _p(8, 5.5)],
        <InkVector>[_p(5.5, 3.5), _p(8, 5.5), _p(5.5, 7.5)],
      ])
      ..['←'] = glyph(8, <List<InkVector>>[
        <InkVector>[_p(8, 5.5), _p(0, 5.5)],
        <InkVector>[_p(2.5, 3.5), _p(0, 5.5), _p(2.5, 7.5)],
      ])
      ..['²'] = _small(two)
      ..['³'] = _small(three)
      ..['✓'] = glyph(7, <List<InkVector>>[
        <InkVector>[_p(0, 5.5), _p(2.5, 9.5), _p(7, 0.5)],
      ]);
    return g;
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
