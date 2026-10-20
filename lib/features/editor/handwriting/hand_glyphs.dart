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
/// these as they are; anything else in the built-in font.
@immutable
class HandGlyphs {
  HandGlyphs(Map<String, HandGlyph> glyphs)
    : _glyphs = Map<String, HandGlyph>.unmodifiable(glyphs);

  final Map<String, HandGlyph> _glyphs;

  HandGlyph? operator [](String char) => _glyphs[char];

  Iterable<String> get characters => _glyphs.keys;

  bool get isEmpty => _glyphs.isEmpty;

  /// Each glyph as its width and its strokes, every stroke flattened to
  /// x, y, x, y…, to a hundredth of a grid unit.
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
    return glyphs.isEmpty ? null : HandGlyphs(glyphs);
  }

  /// [glyphs] with every number as [toJson] keeps it, so they compare
  /// equal to themselves read back.
  static HandGlyphs rounded(Map<String, HandGlyph> glyphs) =>
      HandGlyphs(<String, HandGlyph>{
        for (final MapEntry<String, HandGlyph> entry in glyphs.entries)
          entry.key: HandGlyph(_round(entry.value.width), <List<InkVector>>[
            for (final List<InkVector> stroke in entry.value.strokes)
              <InkVector>[
                for (final InkVector p in stroke)
                  InkVector(_round(p.x), _round(p.y)),
              ],
          ]),
      });

  static double _round(double value) => (value * 100).roundToDouble() / 100;

  @override
  bool operator ==(Object other) {
    if (other is! HandGlyphs || other._glyphs.length != _glyphs.length) {
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
    for (final String char in _glyphs.keys.toList()..sort()) ...<Object>[
      char,
      _glyphs[char]!.width,
    ],
  ]);
}
