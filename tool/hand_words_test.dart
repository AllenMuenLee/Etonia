// Writes words in a saved handwriting profile, as the assistant writes them,
// and the profile's letters on their own, to a JSON file of polylines for
// looking at:
//
//   $env:HAND_PROFILE='.../handwriting_profile.json'
//   $env:HAND_WORDS_OUT='.../words.json'
//   flutter test tool/hand_words_test.dart
//
// Optionally HAND_PROFILE_OUT writes the profile back with every built
// letter as the builder makes it now.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/notation_font.dart';
import 'package:greatnote/features/editor/handwriting/hand_glyphs.dart';
import 'package:greatnote/features/editor/handwriting/handwriting_calibration.dart';
import 'package:greatnote/features/editor/handwriting/handwriting_style.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';

const List<String> _lines = <String>[
  'minimum number summary',
  'the quick brown fox',
  'jumps over the lazy dog',
  'hello world function',
  'build maximum value',
  'university mammal humming',
  'abcdefghijklm',
  'nopqrstuvwxyz',
];

void main() {
  test('write words', () {
    final String? path = Platform.environment['HAND_PROFILE'];
    final String? out = Platform.environment['HAND_WORDS_OUT'];
    if (path == null || out == null) {
      fail('Set HAND_PROFILE and HAND_WORDS_OUT.');
    }
    final Map<String, Object?> json =
        jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
    final HandwritingCalibrationState state =
        HandwritingCalibrationState.fromJson(json);
    final HandwritingStyle style = state.style!;
    final HandGlyphs glyphs = style.glyphs!;
    // HAND_LINES, lines split by `|`, in place of the sample lines.
    final List<String> lines =
        Platform.environment['HAND_LINES']?.split('|') ?? _lines;
    File(out).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'built': glyphs.built,
        'lines': <Object?>[
          for (final String line in lines)
            <List<double>>[
              for (final List<InkVector> stroke in NotationFont.write(
                line,
                origin: InkVector.zero,
                size: 10,
                style: style,
              ))
                <double>[
                  for (final InkVector p in stroke) ...<double>[p.x, p.y],
                ],
            ],
        ],
      }),
    );
    final String? profileOut = Platform.environment['HAND_PROFILE_OUT'];
    if (profileOut != null) {
      File(profileOut).writeAsStringSync(jsonEncode(state.toJson()));
    }
  });
}
