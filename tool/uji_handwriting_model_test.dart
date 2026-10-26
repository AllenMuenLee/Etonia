// Real-handwriting evaluation for the calibration model.
//
// Download UJI Pen Characters v2 from
// https://archive.ics.uci.edu/dataset/177/uji+pen+characters+version+2
// (Prat, Castro, Llorens, Marzal & Vilar, CC BY 4.0), then run:
//
//   $env:UJI_PEN_CHARACTERS='.../ujipenchars2.txt'
//   flutter test tool/uji_handwriting_model_test.dart
//
// This is outside test/ deliberately: normal tests stay offline and the
// third-party dataset is neither downloaded nor redistributed by the app.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/handwriting/glyph_builder.dart';
import 'package:greatnote/features/editor/handwriting/hand_glyphs.dart';
import 'package:greatnote/features/editor/handwriting/handwriting_calibration.dart';
import 'package:greatnote/features/editor/handwriting/handwriting_style.dart';

import 'uji_data.dart';

typedef _Strokes = UjiStrokes;

/// The letters built rather than written, compared with each writer's own.
const String _heldOut = 'bcfjklmnpquvxyz0D';

/// How often each built small letter is written in English, per hundred
/// letters.
const Map<String, double> _frequency = <String, double>{
  'b': 1.49,
  'c': 2.78,
  'f': 2.23,
  'j': 0.15,
  'k': 0.77,
  'l': 4.03,
  'm': 2.41,
  'n': 6.75,
  'p': 1.93,
  'q': 0.10,
  'u': 2.76,
  'v': 0.98,
  'x': 0.15,
  'y': 1.97,
  'z': 0.07,
};

void main() {
  test('held-out glyphs follow real writers at 80% or better', () {
    final String? path = Platform.environment['UJI_PEN_CHARACTERS'];
    if (path == null || !File(path).existsSync()) {
      fail('Set UJI_PEN_CHARACTERS to the extracted ujipenchars2.txt file.');
    }
    final Map<String, Map<String, _Strokes>> writers =
        <String, Map<String, _Strokes>>{
          for (final MapEntry<String, Map<int, Map<String, _Strokes>>> e
              in readUji(File(path)).entries)
            if (e.value[1] case final Map<String, _Strokes> first) e.key: first,
        };
    int tested = 0;
    int matched = 0;
    final Map<String, (int, int)> byLetter = <String, (int, int)>{};
    final Map<String, List<double>> byLetterDistance = <String, List<double>>{};
    final List<double> distances = <double>[];

    // Letters written on the optional pages too, to see what writing one
    // more would be worth.
    final String extra = Platform.environment['UJI_EXTRA'] ?? '';
    for (final Map<String, _Strokes> samples in writers.values) {
      if (!keyLetters.split('').every(samples.containsKey)) continue;
      if (!extra.split('').every(samples.containsKey)) continue;
      final UjiScale scale = ujiScale(samples);
      final CalibrationReading reading = readCustomFont(<_Strokes>[
        calibrationPage(samples, scale),
        for (int page = 1; page < customFontPages.length; page++)
          calibrationPage(samples, scale, page: page, only: extra),
      ]);
      final HandwritingStyle? style = reading.style;
      if (style == null) continue;
      for (final String letter in _heldOut.split('')) {
        if (extra.contains(letter) || keyLetters.contains(letter)) continue;
        final _Strokes? actual = samples[letter];
        final HandGlyph? generated = style.glyphs?[letter];
        if (actual == null || generated == null) continue;
        final double distance = shapeDistance(
          generated.strokes,
          gridGlyph(actual, scale),
        );
        distances.add(distance);
        (byLetterDistance[letter] ??= <double>[]).add(distance);
        final bool close = distance <= 0.16;
        tested++;
        if (close) matched++;
        final (int, int) old = byLetter[letter] ?? (0, 0);
        byLetter[letter] = (old.$1 + (close ? 1 : 0), old.$2 + 1);
      }
    }

    final double accuracy = tested == 0 ? 0 : matched / tested;
    // ignore: avoid_print
    print(
      'UJI real-handwriting structural accuracy: '
      '${(accuracy * 100).toStringAsFixed(1)}% ($matched/$tested); '
      '${<String>[for (final MapEntry<String, (int, int)> e in byLetter.entries) '${e.key} ${(100 * e.value.$1 / e.value.$2).toStringAsFixed(1)}%'].join(', ')}',
    );
    // Weighted by how often each small letter is written in English, so a
    // letter that is everywhere counts for more than a q.
    double weighted = 0;
    double weights = 0;
    for (final MapEntry<String, double> e in _frequency.entries) {
      // A letter written out is written as it was.
      final (int, int)? result =
          extra.contains(e.key) || keyLetters.contains(e.key)
          ? (1, 1)
          : byLetter[e.key];
      if (result == null) continue;
      weighted += e.value * result.$1 / result.$2;
      weights += e.value;
    }
    // ignore: avoid_print
    print(
      'extra "$extra": frequency-weighted small-letter accuracy '
      '${(100 * weighted / weights).toStringAsFixed(1)}%',
    );
    // ignore: avoid_print
    print(
      'mean distance:${<String>[for (final MapEntry<String, List<double>> e in byLetterDistance.entries) '${e.key} ${(100 * e.value.reduce((double a, double b) => a + b) / e.value.length).toStringAsFixed(1)}'].join(', ')}',
    );
    // ignore: avoid_print
    print(
      'thresholds:${<double>[0.12, 0.14, 0.16, 0.18].map((double t) => '${(t * 100).round()}%=${distances.where((double d) => d <= t).length}/${distances.length}').join(', ')}',
    );
    expect(writers.length, 60);
    expect(tested, greaterThanOrEqualTo(450));
    expect(accuracy, greaterThanOrEqualTo(0.8));
  });
}
