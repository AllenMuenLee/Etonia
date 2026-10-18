import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/ai/notation_font.dart';
import 'package:greatnote/features/editor/ai/notation_layout.dart';
import 'package:greatnote/features/editor/handwriting/handwriting_calibration.dart';
import 'package:greatnote/features/editor/handwriting/handwriting_calibration_screen.dart';
import 'package:greatnote/features/editor/handwriting/recognized_handwriting.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';

import '../../../helpers/pump_app.dart';

const double _capTop = 20;
const double _line = 40;

/// One print letter as a single stroke: a diagonal across its box, from
/// [top] (in line heights below the capital line) down to the baseline.
List<InkVector> _letter(double left, double width, {double top = 0}) =>
    <InkVector>[
      InkVector(left, _capTop + top * _line),
      InkVector(left + width, _capTop + _line),
    ];

class _FirstRandom implements math.Random {
  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;

  @override
  int nextInt(int max) => 0;
}

/// Opens calibration from a button, as the library does, so it has a
/// route to return to.
Future<void> _openCalibration(
  WidgetTester tester,
  HandwritingProfileStore store,
) async {
  await pumpApp(
    tester,
    home: Builder(
      builder: (BuildContext context) => Center(
        child: TextButton(
          onPressed: () => showHandwritingCalibration(context, store: store),
          child: const Text('Calibrate'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Calibrate'));
  await tester.pumpAndSettle();
}

AiNotation _text(String text) => AiNotation(
  label: text,
  items: <AiNotationItem>[
    AiNotationText(text: text, x: 0.1, y: 0.2, size: 20, ink: 'ink', width: 2),
  ],
);

void main() {
  test('calibration text has every letter, digit, and punctuation mark', () {
    final String all = calibrationLines.join();
    const String required =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
        '.,!?\'"-:;()&\$%#@/+*';
    for (final int rune in required.runes) {
      expect(all, contains(String.fromCharCode(rune)));
    }
    expect(
      calibrationChunks.map((CalibrationChunk chunk) => chunk.text).join(' '),
      calibrationLines.join(' '),
    );
  });

  test('print words are cut into letters with an i-dot kept on its i', () {
    // "the frog." with one mark per character, and "Six" whose i has a
    // dot written after the rest of the word.
    const CalibrationChunk chunk = CalibrationChunk('the frog.', '');
    final List<List<InkVector>> ink = <List<InkVector>>[
      _letter(0, 10),
      _letter(16, 12),
      _letter(34, 12, top: 0.45),
      _letter(80, 10),
      _letter(96, 12, top: 0.45),
      _letter(114, 12, top: 0.45),
      _letter(132, 12, top: 0.45),
      _letter(150, 2, top: 0.95),
    ];

    final CalibrationReading reading = readCalibration(
      chunk,
      ink,
      capTop: _capTop,
      lineHeight: _line,
    );

    expect(reading.wordsMatched, isTrue);
    expect(reading.lettersLearned, 8);
    final HandwritingProfile profile = reading.profile;
    for (final String char in <String>['t', 'h', 'e', 'f', 'r', 'o', 'g']) {
      expect(profile.hasGlyph(char), isTrue, reason: char);
    }
    final CalibratedGlyph r = profile.glyphs['r']!.single;
    expect(r.width, closeTo(12 / _line, 1e-9));
    expect(r.strokes.single.first, const InkVector(0, 0.45));
    expect(r.strokes.single.last, const InkVector(12 / _line, 1));
    // Whole words are kept too, without their punctuation.
    expect(profile.words.keys, containsAll(<String>['the', 'frog']));
    expect(profile.letterGap, closeTo(6 / _line, 1e-9));

    final CalibrationReading six = readCalibration(
      const CalibrationChunk('Six', ''),
      <List<InkVector>>[
        _letter(0, 14),
        _letter(20, 2, top: 0.45),
        _letter(30, 14, top: 0.45),
        <InkVector>[const InkVector(21, _capTop + 6)],
      ],
      capTop: _capTop,
      lineHeight: _line,
    );
    expect(six.lettersLearned, 3);
    expect(six.profile.glyphs['i']!.single.strokes, hasLength(2));
  });

  test('joined writing is cut at the dip between letters', () {
    // "ui" in one pen path: the u bottoms out twice, its connector rises
    // into the i, which bottoms out once. The i's dot comes last.
    const double base = _capTop + _line;
    const double middle = _capTop + _line * 0.45;
    final CalibrationReading reading = readCalibration(
      const CalibrationChunk('ui', ''),
      <List<InkVector>>[
        const <InkVector>[
          InkVector(0, middle),
          InkVector(1, 50),
          InkVector(2, base),
          InkVector(4, 50),
          InkVector(6, middle),
          InkVector(7, 50),
          InkVector(8, base),
          InkVector(10, 50),
          InkVector(12, middle),
          InkVector(13, 50),
          InkVector(14, base),
          InkVector(16, 52),
        ],
        const <InkVector>[InkVector(13, _capTop + 10)],
      ],
      capTop: _capTop,
      lineHeight: _line,
    );

    expect(reading.lettersLearned, 2);
    final CalibratedGlyph u = reading.profile.glyphs['u']!.single;
    expect(u.strokes.single.last, const InkVector(8 / _line, 1));
    final CalibratedGlyph i = reading.profile.glyphs['i']!.single;
    expect(i.strokes, hasLength(2));
    // The cut point is shared, so the letters still meet when composed.
    expect(reading.profile.letterGap, 0);
  });

  test('quote ticks at the end of a word make one double quote', () {
    final CalibrationReading reading = readCalibration(
      const CalibrationChunk('"Hi', ''),
      <List<InkVector>>[
        const <InkVector>[InkVector(0, _capTop), InkVector(1, _capTop + 8)],
        const <InkVector>[InkVector(5, _capTop), InkVector(6, _capTop + 8)],
        _letter(12, 12),
        _letter(30, 2, top: 0.45),
        const <InkVector>[InkVector(31, _capTop + 6)],
      ],
      capTop: _capTop,
      lineHeight: _line,
    );

    expect(reading.lettersLearned, 3);
    expect(reading.profile.glyphs['"']!.single.strokes, hasLength(2));
    expect(reading.profile.words.keys, contains('Hi'));
  });

  test('words with no plausible cuts stay whole; mismatches teach nothing', () {
    final CalibrationReading joined = readCalibration(
      const CalibrationChunk('the frog.', ''),
      <List<InkVector>>[
        _letter(0, 46),
        _letter(80, 70),
        _letter(156, 2, top: 0.95),
      ],
      capTop: _capTop,
      lineHeight: _line,
    );
    expect(joined.wordsMatched, isTrue);
    expect(joined.lettersLearned, 0);
    expect(joined.profile.glyphs, isEmpty);
    // "the" is a plain word; "frog." has punctuation stuck to it.
    expect(joined.profile.words.keys, <String>['the']);

    final CalibrationReading oneBlob = readCalibration(
      const CalibrationChunk('the frog.', ''),
      <List<InkVector>>[_letter(0, 150)],
      capTop: _capTop,
      lineHeight: _line,
    );
    expect(oneBlob.wordsMatched, isFalse);
    expect(oneBlob.wordsFound, 1);
    expect(oneBlob.profile.isEmpty, isTrue);
  });

  test('profiles survive a JSON round trip and drop malformed samples', () {
    final HandwritingProfile profile = HandwritingProfile(
      glyphs: <String, List<CalibratedGlyph>>{
        'a': <CalibratedGlyph>[
          CalibratedGlyph(
            width: 0.5,
            strokes: <List<InkVector>>[
              <InkVector>[const InkVector(0, 0.4), const InkVector(0.5, 1)],
            ],
          ),
        ],
      },
      letterGap: 0.2,
      wordSpace: 0.5,
    );
    final HandwritingCalibrationState state =
        HandwritingCalibrationState.fromJson(<String, Object?>{
          ...HandwritingCalibrationState(profile: profile).toJson(),
        });
    expect(state.skipped, isFalse);
    expect(
      state.profile!.glyphs['a']!.single.strokes.single.last,
      const InkVector(0.5, 1),
    );
    expect(state.profile!.letterGap, 0.2);

    final HandwritingProfile? damaged = HandwritingProfile.fromJson(
      <String, Object?>{
        'version': 1,
        'glyphs': <String, Object?>{
          'a': <Object?>[
            <String, Object?>{'w': 'wide', 's': <Object?>[]},
          ],
          'b': <Object?>[
            <String, Object?>{
              'w': 0.4,
              's': <Object?>[
                <Object?>[0, 0, 0.4, 1],
              ],
            },
          ],
        },
        'letterGap': -3,
      },
    );
    expect(damaged!.hasGlyph('a'), isFalse);
    expect(damaged.hasGlyph('b'), isTrue);
    expect(damaged.letterGap, HandwritingProfile.defaultLetterGap);
    expect(
      HandwritingProfile.fromJson(<String, Object?>{'version': 9}),
      isNull,
    );
  });

  test('notation writes calibrated letters, then the font for the rest', () {
    CalibratedGlyph glyph(double width) => CalibratedGlyph(
      width: width,
      strokes: <List<InkVector>>[
        <InkVector>[const InkVector(0, 0), InkVector(width, 1)],
      ],
    );
    final HandwritingSampleLibrary library = HandwritingSampleLibrary(
      const <RecognizedInkWord>[],
      calibration: HandwritingProfile(
        glyphs: <String, List<CalibratedGlyph>>{
          'a': <CalibratedGlyph>[glyph(0.5)],
          'b': <CalibratedGlyph>[glyph(1)],
        },
        words: <String, List<CalibratedGlyph>>{
          'ba': <CalibratedGlyph>[glyph(2)],
        },
        letterGap: 0.25,
        random: _FirstRandom(),
      ),
    );

    // Origin (20, 20) at size 20: "a" spans 10, a 5 gap, then "b" 20.
    final traces = layoutNotation(
      _text('ab'),
      const Size(200, 100),
      handwriting: library,
    );
    expect(traces, hasLength(2));
    expect(traces[0].points.first, const InkVector(20, 20));
    expect(traces[0].points.last, const InkVector(30, 40));
    expect(traces[1].points.first, const InkVector(35, 20));
    expect(traces[1].points.last, const InkVector(55, 40));

    // A calibrated whole word wins over its letters.
    final word = layoutNotation(
      _text('ba'),
      const Size(200, 100),
      handwriting: library,
    );
    expect(word.single.points.last, const InkVector(60, 40));

    // "c" was never calibrated, so the built-in font writes it.
    final mixed = layoutNotation(
      _text('ac'),
      const Size(200, 100),
      handwriting: library,
    );
    expect(mixed.first.points.last, const InkVector(30, 40));
    expect(mixed.length, greaterThan(1));
  });

  test('the font and notation parser accept & \$ @', () {
    for (final String char in <String>['&', '\$', '@']) {
      expect(NotationFont.canWrite(char), isTrue, reason: char);
    }
    expect(
      layoutNotation(_text('PB&J @ \$5'), const Size(400, 100)),
      isNotEmpty,
    );
  });

  testWidgets('skipping remembers the choice', (WidgetTester tester) async {
    final InMemoryHandwritingProfileStore store =
        InMemoryHandwritingProfileStore();
    await _openCalibration(tester, store);
    expect(find.text('Six grumpy wizards'), findsOneWidget);

    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    expect(find.text('Calibrate'), findsOneWidget);
    expect(store.state!.skipped, isTrue);
    expect(store.state!.profile, isNull);
  });

  testWidgets('a phrase written as one word asks for more room', (
    WidgetTester tester,
  ) async {
    await _openCalibration(tester, InMemoryHandwritingProfileStore());
    final Finder pad = find.byKey(const ValueKey<String>('calibration-pad'));
    final Offset start = tester.getTopLeft(pad) + const Offset(40, 60);
    await tester.dragFrom(start, const Offset(200, 20));
    await tester.pump();
    await tester.tap(find.text('Next'));
    await tester.pump();

    expect(find.textContaining('Leave a little more room'), findsOneWidget);
    expect(find.text('Six grumpy wizards'), findsOneWidget);

    await tester.tap(find.text('Skip line'));
    await tester.pump();
    expect(find.text('judged the quacking'), findsOneWidget);
  });
}
