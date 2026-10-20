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

  /// Lines are this many text sizes apart.
  static const double lineHeight = 1.6;

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
        final double baselineDrift = style.baselineJitter * math.sin(gesture);
        final double stretch = 1 + style.sizeJitter * math.sin(gesture * 1.73);
        final double rotation = 0.018 * math.sin(gesture * 0.83);
        final double cosine = math.cos(rotation);
        final double sine = math.sin(rotation);
        final List<List<InkVector>> letter = <List<InkVector>>[
          for (int stroke = 0; stroke < shaped.strokes.length; stroke++)
            <InkVector>[
              for (final InkVector point in shaped.strokes[stroke])
                _handPoint(
                  point,
                  origin: origin,
                  top: top,
                  x: x,
                  glyphWidth: shaped.width,
                  scale: scale,
                  stretch: stretch,
                  cosine: cosine,
                  sine: sine,
                  baselineDrift: baselineDrift,
                  gesture: gesture + stroke * 0.91,
                ),
            ],
        ];
        final bool joins = style.joined && _joinable(char);
        if (joins && previous != null && letter.isNotEmpty) {
          final List<InkVector>? join = _join(
            previous,
            letter,
            fromTop: _joinsFromTop.contains(previousChar ?? ' '),
            baseline: top + (capHeight + baselineDrift) * scale,
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

  /// Gives each letter the small inconsistencies of a real hand: a slight
  /// turn, size, and drift off the baseline, and a very small pen wobble.
  /// The variation is derived from the text itself rather than randomness,
  /// so a note lays out identically every time it is opened.
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
    final double dy = (point.y - capHeight) * stretch;
    final double turnedX = dx * cosine - dy * sine;
    final double turnedY = dx * sine + dy * cosine + capHeight;
    final double wobbleX = 0.05 * math.sin(gesture + point.y * 0.79);
    final double wobbleY = 0.05 * math.sin(gesture * 1.19 + point.x * 0.67);
    return InkVector(
      origin.x + (x + centerX + turnedX + wobbleX) * scale,
      top + (turnedY + baselineDrift + wobbleY) * scale,
    );
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
      ' ': const _Glyph(3, <List<InkVector>>[]),
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
    return glyphs;
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
