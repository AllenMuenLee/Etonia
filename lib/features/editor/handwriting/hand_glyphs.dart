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
      if ('oO'.contains(char)) glyph = closed(glyph);
      if ('ij'.contains(char)) glyph = _dotted(glyph);
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
    return out;
  }

  /// [glyph] with a stroke that nearly closes on itself closed: the pen
  /// carried on from its end round to its start, the way each was
  /// heading.
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
    InkVector heading(List<InkVector> points) {
      for (final InkVector p in points.skip(1)) {
        final InkVector step = p - points.first;
        if (step.length >= size * 0.15) return step * (1 / step.length);
      }
      return InkVector.zero;
    }

    // Leaving the end as it was heading, and coming into the start as the
    // stroke set off from it.
    final InkVector out = heading(loop.reversed.toList()) * -1;
    final InkVector into = heading(loop);
    final InkVector c1 = end + out * (gap * 0.45);
    final InkVector c2 = start - into * (gap * 0.45);
    const int steps = 8;
    final List<InkVector> bridge = <InkVector>[
      for (int i = 1; i <= steps; i++)
        () {
          final double t = i / steps;
          final double u = 1 - t;
          return end * (u * u * u) +
              c1 * (3 * u * u * t) +
              c2 * (3 * u * t * t) +
              start * (t * t * t);
        }(),
    ];
    return HandGlyph(glyph.width, <List<InkVector>>[
      for (final List<InkVector> stroke in glyph.strokes)
        identical(stroke, loop) ? <InkVector>[...stroke, ...bridge] : stroke,
    ]);
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
