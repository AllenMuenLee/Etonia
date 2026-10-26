import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_config.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/ai/notation_font.dart';
import 'package:greatnote/features/editor/ai/notation_layout.dart';
import 'package:greatnote/features/editor/handwriting/glyph_builder.dart';
import 'package:greatnote/features/editor/handwriting/hand_features.dart';
import 'package:greatnote/features/editor/handwriting/hand_glyphs.dart';
import 'package:greatnote/features/editor/handwriting/handwriting_calibration.dart';
import 'package:greatnote/features/editor/handwriting/handwriting_calibration_screen.dart';
import 'package:greatnote/features/editor/handwriting/handwriting_fonts.dart';
import 'package:greatnote/features/editor/handwriting/handwriting_style.dart';
import 'package:greatnote/features/editor/handwriting/handwriting_variables.dart';
import 'package:greatnote/features/editor/handwriting/cubic_bezier.dart';
import 'package:greatnote/features/editor/handwriting/recognized_handwriting.dart';
import 'package:greatnote/features/editor/handwriting/stroke_profile.dart';
import 'package:greatnote/features/editor/handwriting/stroke_runs.dart'
    show pathLength, signedTurn;
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_notation.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';

import '../../../helpers/pump_app.dart';

/// The letters of [page] of [customFontPages] as [style] writes them, one
/// in each box, in ruled units; [skip] are left out.
List<List<InkVector>> _page(
  int page,
  HandwritingStyle style, {
  String skip = '',
}) {
  final List<String> rows = customFontPages[page];
  return <List<InkVector>>[
    for (int r = 0; r < rows.length; r++)
      for (int c = 0; c < rows[r].length; c++)
        if (!skip.contains(rows[r][c]))
          ...NotationFont.write(
            rows[r][c],
            // A capital 0.9 tall, sitting on the row's baseline.
            origin: InkVector(
              c * calibrationCell + 0.3,
              r * calibrationRowGap - 0.9,
            ),
            size: 0.9,
            style: style,
          ),
  ];
}

/// Every page of the custom font written in [style].
List<List<List<InkVector>>> _pages(HandwritingStyle style) =>
    <List<List<InkVector>>>[
      for (int p = 0; p < customFontPages.length; p++) _page(p, style),
    ];

/// A hand unlike the built-in one in every shape calibration reads.
const HandwritingStyle _loopy = HandwritingStyle(
  slant: 0.35,
  widthScale: 1.2,
  descenderHook: 3,
  descenderLoop: 1,
  loopAspect: 1.35,
  // Lines that bow out to their right, read top to bottom.
  lineProfile: StrokeProfile(<double>[0.18]),
);

/// How far [curve], one along a chord, strays to the side, at most.
double _drift(CubicBezier curve, CubicBezier from) {
  double most = 0;
  for (int i = 0; i <= 20; i++) {
    most = math.max(most, (curve.at(i / 20).y - from.at(i / 20).y).abs());
  }
  return most;
}

Rect _inkBounds(Iterable<List<InkVector>> strokes) {
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
  return Rect.fromLTRB(left, top, right, bottom);
}

/// Opens calibration from a button, as the library does, so it has a
/// route to return to.
Future<void> _openCalibration(
  WidgetTester tester,
  HandwritingProfileStore store, {
  TestViewport viewport = TestViewport.tabletLandscape,
}) async {
  await pumpApp(
    tester,
    viewport: viewport,
    home: Builder(
      builder: (BuildContext context) => Center(
        child: TextButton(
          onPressed: () => showHandwritingCalibration(context, store: store),
          child: const Text('Open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

Finder get _pad => find.byKey(const ValueKey<String>('calibration-pad'));

Finder _card(HandwritingFont font) =>
    find.byKey(ValueKey<String>('calibration-font-${font.name}'));

/// From the fonts to the pad, by the card for the writer's own.
Future<void> _startWriting(WidgetTester tester) async {
  await tester.scrollUntilVisible(_card(HandwritingFont.custom), 100);
  await tester.ensureVisible(_card(HandwritingFont.custom));
  await tester.pumpAndSettle();
  await tester.tap(_card(HandwritingFont.custom));
  await tester.pumpAndSettle();
}

/// The pad's ruling for the page on it.
CalibrationRuling _rulingOf(WidgetTester tester, int page) =>
    calibrationRuling(tester.getSize(_pad), customFontPages[page]);

/// Draws [ruled], in ruled units, onto the pad showing [page].
Future<void> _draw(
  WidgetTester tester,
  int page,
  List<List<InkVector>> ruled,
) async {
  final Offset origin = tester.getTopLeft(_pad);
  final List<List<InkVector>> strokes = CalibrationDraft.decode(
    ruled,
    ruling: _rulingOf(tester, page),
  );
  for (final List<InkVector> stroke in strokes) {
    final TestGesture pen = await tester.startGesture(
      origin + Offset(stroke.first.x, stroke.first.y),
      kind: PointerDeviceKind.stylus,
    );
    for (final InkVector p in stroke.skip(1)) {
      await pen.moveTo(origin + Offset(p.x, p.y));
    }
    await pen.up();
  }
  await tester.pump();
}

AiNotation _text(String text, {double x = 0.1, double size = 20}) => AiNotation(
  label: text,
  items: <AiNotationItem>[
    AiNotationText(text: text, x: x, y: 0.2, size: size, ink: 'ink', width: 2),
  ],
);

Rect _bounds(List<GeneratedInkTrace> traces) => _inkBounds(<List<InkVector>>[
  for (final GeneratedInkTrace t in traces) t.points,
]);

void main() {
  tearDown(() => HandwritingCalibration.current.value = null);

  test('there are five fonts to choose, and the writer\'s own', () {
    expect(HandwritingFont.presets, hasLength(5));
    expect(HandwritingFont.values.last, HandwritingFont.custom);
    expect(HandwritingFont.custom.style, isNull);
    final Set<HandwritingStyle> styles = <HandwritingStyle>{
      for (final HandwritingFont font in HandwritingFont.presets) font.style!,
    };
    expect(styles, hasLength(5), reason: 'each font is a hand of its own');
    expect(HandwritingFont.normal.style, HandwritingStyle.standard);
    expect(HandwritingFont.cursive.style!.joined, isTrue);
    // Every font is legible as it is.
    for (final HandwritingFont font in HandwritingFont.presets) {
      expect(font.style!.clamped(), font.style, reason: font.name);
    }
  });

  test('the custom font asks for the key letters, and others if wanted', () {
    expect(customFontPages.first.join(), keyLetters);
    // No more than fifteen to write before the font is made.
    expect(keyLetters, hasLength(15));
    final List<String> all = customFontPages
        .expand((List<String> p) => p)
        .join()
        .split('');
    expect(all.toSet(), hasLength(all.length), reason: 'each box once');
    expect(
      (all..sort()).join(),
      (('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789').split(
        '',
      )..sort()).join(),
    );
    expect(customFontPageOptional(0), isFalse);
    for (int p = 1; p < customFontPages.length; p++) {
      expect(customFontPageOptional(p), isTrue);
    }
  });

  test('the key letters alone make every letter, from their strokes', () {
    for (final HandwritingStyle writer in <HandwritingStyle>[
      HandwritingStyle.standard,
      _loopy,
    ]) {
      final CalibrationReading reading = readCustomFont(<List<List<InkVector>>>[
        _page(0, writer),
      ]);
      expect(reading.complete, isTrue);
      final HandGlyphs glyphs = reading.style!.glyphs!;
      // Zero is structural too: when its optional box is blank it is made
      // from the writer's round forms instead of falling back to a font.
      const String letters =
          'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0';
      expect(glyphs.characters.toSet(), letters.split('').toSet());
      for (final String inferred in 'bfvD'.split('')) {
        expect(glyphs.built, contains(inferred), reason: inferred);
      }
      expect(glyphs['b']!.strokes, isNotEmpty);
      expect(glyphs['f']!.strokes.length, greaterThanOrEqualTo(2));
      expect(_inkBounds(glyphs['v']!.strokes).width, greaterThan(2));
      expect(_inkBounds(glyphs['D']!.strokes).height, greaterThan(8));
      final Rect x = _inkBounds(glyphs['x']!.strokes);
      final Rect o = _inkBounds(glyphs['o']!.strokes);
      // Small letters as tall as the writer's, sitting on the line.
      expect(x.top, closeTo(o.top, 1));
      expect(x.bottom, closeTo(NotationFont.capHeight, 0.6));
      // Ascenders as tall as the writer's b, descenders as deep as their g.
      final double ascender = _inkBounds(glyphs['b']!.strokes).top;
      final double descender = _inkBounds(glyphs['g']!.strokes).bottom;
      for (final String tall in 'dhl'.split('')) {
        expect(
          _inkBounds(glyphs[tall]!.strokes).top,
          closeTo(ascender, 1.2),
          reason: tall,
        );
      }
      for (final String deep in 'jpqy'.split('')) {
        expect(
          _inkBounds(glyphs[deep]!.strokes).bottom,
          closeTo(descender, 1.5),
          reason: deep,
        );
      }
      // Capitals as tall as the writer's, sitting on the line.
      for (final String capital in 'BCDFGHIJKLMNOPSTUVWXYZ'.split('')) {
        final Rect bounds = _inkBounds(glyphs[capital]!.strokes);
        expect(bounds.top, closeTo(0, 1.2), reason: capital);
        expect(
          bounds.bottom,
          closeTo(10, capital == 'J' ? 1 : 0.6),
          reason: capital,
        );
      }
      // The m is two of the n's arches; the P the R without its leg.
      expect(
        _inkBounds(glyphs['m']!.strokes).width,
        greaterThan(_inkBounds(glyphs['n']!.strokes).width * 1.3),
      );
      double ink(String letter) => glyphs[letter]!.strokes.fold<double>(
        0,
        (double sum, List<InkVector> s) => sum + pathLength(s),
      );
      expect(ink('P'), lessThan(ink('R') - 3));
    }

    // Built from the writer's strokes: another hand builds other letters.
    HandGlyphs built(HandwritingStyle writer) => readCustomFont(
      <List<List<InkVector>>>[_page(0, writer)],
    ).style!.glyphs!;
    final HandGlyphs plain = built(HandwritingStyle.standard);
    final HandGlyphs loopy = built(_loopy);
    for (final String letter in 'dhmpquvxyzBDFHLMNPTY'.split('')) {
      expect(
        loopy[letter]!.strokes,
        isNot(plain[letter]!.strokes),
        reason: letter,
      );
    }
    // A letter written out is used as written, not built.
    final HandGlyphs more = readCustomFont(<List<List<InkVector>>>[
      _page(0, _loopy),
      _page(1, HandwritingStyle.standard),
    ]).style!.glyphs!;
    expect(more['q']!.strokes, isNot(loopy['q']!.strokes));
    expect(more['Q'], isNotNull);
  });

  test('a swoop off the foot of the n stays out of the u and m', () {
    // Down the stem, back up it, over the arch, down the leg, and off in a
    // long swoop below the line.
    final List<InkVector> n = <InkVector>[
      for (double y = 4.5; y <= 10; y += 0.5) InkVector(0, y),
      for (double y = 9.5; y >= 6; y -= 0.5) InkVector(0.1, y),
      const InkVector(1, 4.8),
      const InkVector(2.5, 4.3),
      const InkVector(4, 5),
      for (double y = 5.5; y <= 10; y += 0.5) InkVector(4.6, y),
      const InkVector(5, 11.2),
      const InkVector(6.5, 12),
      const InkVector(8, 11.6),
      const InkVector(9.5, 10.8),
    ];
    final Map<String, HandGlyph> glyphs = buildMissingGlyphs(
      <String, HandGlyph>{
        'n': HandGlyph(9.5, <List<InkVector>>[n]),
      },
      slant: 0,
    );
    for (final String letter in 'um'.split('')) {
      final Rect bounds = _inkBounds(glyphs[letter]!.strokes);
      expect(bounds.top, greaterThan(4), reason: letter);
      expect(bounds.bottom, lessThan(10.3), reason: letter);
    }
    // Two arches, each about as wide as the n's without its swoop.
    final double m = _inkBounds(glyphs['m']!.strokes).width;
    expect(m, greaterThan(4.6 * 1.4));
    expect(m, lessThan(4.6 * 2.1));
  });

  test('shared variables carry a cursive ascender from d into l', () {
    // A one-stroke d: bowl, rising entry, loop over the ascender, and the
    // downstroke. The missing l should use the whole gesture, not a | cut
    // out of its straight side.
    const List<InkVector> d = <InkVector>[
      InkVector(3.2, 10),
      InkVector(1.3, 9.4),
      InkVector(0.5, 7),
      InkVector(1.4, 4.5),
      InkVector(2.2, 8.8),
      InkVector(2.5, 10),
      InkVector(2.7, 7),
      InkVector(3.5, 2),
      InkVector(2.7, 0),
      InkVector(1.8, 1.3),
      InkVector(2.2, 5),
      InkVector(2.4, 10),
    ];
    const Map<String, HandGlyph> written = <String, HandGlyph>{
      'd': HandGlyph(3.5, <List<InkVector>>[d]),
      'o': HandGlyph(4, <List<InkVector>>[
        <InkVector>[
          InkVector(2, 4),
          InkVector(4, 7),
          InkVector(2, 10),
          InkVector(0, 7),
          InkVector(2, 4),
        ],
      ]),
    };
    final HandwritingVariables variables = HandwritingVariables.measure(
      written,
      slant: 0,
    );
    final HandGlyph l = buildMissingGlyphs(written, slant: 0)['l']!;
    final Rect bounds = _inkBounds(l.strokes);
    expect(variables.ascenderLoop, greaterThan(0.35));
    expect(bounds.width, greaterThan(0.8));
    expect(bounds.top, closeTo(0, 0.5));
    expect(bounds.bottom, closeTo(10, 0.5));
  });

  test('a d gone up on a slant and straight back down has no loop', () {
    // Round the bowl, up from its foot on a long slant to the top of the
    // ascender, and back down hugging the way up: wide across the
    // ascender, but nothing held apart, so the l is a stem, not that
    // gesture with its doubled head.
    final List<InkVector> d = <InkVector>[
      const InkVector(2.5, 5.9),
      const InkVector(0.9, 6.5),
      const InkVector(0, 9.4),
      const InkVector(0.5, 9.8),
      for (double t = 0; t < 1; t += 0.1)
        InkVector(1.2 + 3.7 * t, 9.2 - 3.2 * t),
      for (double t = 0; t <= 1; t += 0.1)
        InkVector(4.9 + 1.4 * t, 6 - 5.2 * t),
      for (double t = 0.1; t <= 1; t += 0.1)
        InkVector(6.1 - 1.5 * t, 1 + 9 * t),
    ];
    final Map<String, HandGlyph> written = <String, HandGlyph>{
      'd': HandGlyph(6.3, <List<InkVector>>[d]),
      'o': const HandGlyph(4, <List<InkVector>>[
        <InkVector>[
          InkVector(2, 5),
          InkVector(4, 7.5),
          InkVector(2, 10),
          InkVector(0, 7.5),
          InkVector(2, 5),
        ],
      ]),
    };
    expect(
      HandwritingVariables.measure(written, slant: 0).ascenderLoop,
      lessThan(0.35),
    );
    final HandGlyph l = buildMissingGlyphs(written, slant: 0)['l']!;
    expect(l.strokes, hasLength(1));
    final Rect bounds = _inkBounds(l.strokes);
    expect(bounds.width, lessThan(2));
    expect(bounds.top, lessThan(2));
    expect(bounds.bottom, closeTo(10, 0.3));
  });

  test('a u is the a with the top of its bowl left off', () {
    // From the top right of the bowl, over its top, down its left side,
    // round its foot, up its right side, and down the stem.
    final List<InkVector> a = <InkVector>[
      for (int k = 0; k <= 30; k++)
        InkVector(
          2 + 2 * math.cos(-math.pi / 3 - k * math.pi * 5 / 3 / 30),
          7.5 + 2.5 * math.sin(-math.pi / 3 - k * math.pi * 5 / 3 / 30),
        ),
      for (double y = 7; y >= 5; y -= 0.5) InkVector(4, y),
      for (double y = 5.5; y <= 10; y += 0.5) InkVector(4, y),
    ];
    final List<InkVector> u = buildMissingGlyphs(<String, HandGlyph>{
      'a': HandGlyph(4, <List<InkVector>>[a]),
    }, slant: 0)['u']!.strokes.single;
    final Rect bounds = _inkBounds(<List<InkVector>>[u]);
    // Both arms reach the top, open between them.
    expect(bounds.top, closeTo(5, 0.3));
    expect(u.first.y, closeTo(5, 0.3));
    expect(u.first.x, lessThan(1));
    expect(u.where((InkVector p) => p.y < 6 && p.x > 1 && p.x < 3.4), isEmpty);
    expect(bounds.bottom, lessThan(10.3));
  });

  test('an i written short stands as tall as the small letters', () {
    // The dot a dash far up and to the left, and the stem two fifths as
    // tall as the a and the o.
    final HandGlyphs glyphs = HandGlyphs(<String, HandGlyph>{
      'a': const HandGlyph(4, <List<InkVector>>[
        <InkVector>[
          InkVector(3, 5),
          InkVector(0, 7),
          InkVector(1, 10),
          InkVector(3, 5),
          InkVector(3, 10),
        ],
      ]),
      'o': const HandGlyph(4, <List<InkVector>>[
        <InkVector>[
          InkVector(2, 5),
          InkVector(4, 7.5),
          InkVector(2, 10),
          InkVector(0, 7.5),
          InkVector(2, 5),
        ],
      ]),
      'i': const HandGlyph(3, <List<InkVector>>[
        <InkVector>[InkVector(0, 1.5), InkVector(2.3, 1.4)],
        <InkVector>[InkVector(3, 8), InkVector(2.95, 10)],
      ]),
    });
    final List<List<InkVector>> i = glyphs.lined('i')!.strokes;
    final List<InkVector> stem = i.firstWhere(
      (List<InkVector> s) => s.length > 1,
    );
    final InkVector dot = i
        .firstWhere((List<InkVector> s) => s.length == 1)
        .single;
    final Rect bounds = _inkBounds(<List<InkVector>>[stem]);
    expect(bounds.top, closeTo(5, 0.1));
    expect(bounds.bottom, closeTo(10, 0.01));
    // Over the stem, no further above it than half the small letters.
    expect(dot.x, closeTo(stem.first.x, 0.01));
    expect(bounds.top - dot.y, inInclusiveRange(1, 2.5));
  });

  test('r, zero and capital I remain distinct symbols', () {
    final HandwritingStyle style = readCustomFont(<List<List<InkVector>>>[
      _page(0, HandwritingStyle.standard),
    ]).style!;
    final HandGlyphs glyphs = style.glyphs!;

    // r is a required original, never an n/h derivative in a new profile.
    expect(glyphs.built, isNot(contains('r')));
    expect(glyphs['r'], isNotNull);

    // Zero is generated from the writer's round forms even when the digit
    // page is skipped, and closes cleanly.
    final HandGlyph zero = glyphs['0']!;
    final List<InkVector> loop = zero.strokes.reduce(
      (List<InkVector> a, List<InkVector> b) =>
          pathLength(a) >= pathLength(b) ? a : b,
    );
    expect((loop.first - loop.last).length, lessThan(0.4));
    final Rect zeroBounds = _inkBounds(zero.strokes);
    expect(zeroBounds.width / zeroBounds.height, inInclusiveRange(0.35, 0.8));

    final HandGlyph bareI = HandGlyphs(<String, HandGlyph>{
      'I': const HandGlyph(0, <List<InkVector>>[
        <InkVector>[InkVector(0, 0), InkVector(0, 10)],
      ]),
    }).lined('I')!;
    expect(bareI.strokes, hasLength(3));
    expect(_inkBounds(bareI.strokes).width, greaterThan(5));

    // Both presets and custom output give I two serifs; | stays one line.
    for (final HandwritingStyle hand in <HandwritingStyle>[
      HandwritingStyle.standard,
      style,
    ]) {
      final List<List<InkVector>> capital = NotationFont.write(
        'I',
        origin: InkVector.zero,
        size: 10,
        style: hand,
      );
      expect(capital.length, greaterThanOrEqualTo(3));
      expect(_inkBounds(capital).width, greaterThan(2.8));
    }
    final List<List<InkVector>> bar = NotationFont.write(
      '|',
      origin: InkVector.zero,
      size: 10,
      style: HandwritingStyle.standard,
    );
    expect(bar, hasLength(1));
    expect(
      _inkBounds(
        NotationFont.write(
          'I',
          origin: InkVector.zero,
          size: 10,
          style: HandwritingStyle.standard,
        ),
      ).width,
      greaterThan(_inkBounds(bar).width * 2),
    );
  });

  test('letters are written on one line, tails half below it', () {
    List<List<InkVector>> box(double top, double bottom) => <List<InkVector>>[
      <InkVector>[
        InkVector(0, top),
        InkVector(0, bottom),
        InkVector(3, bottom),
        InkVector(3, top),
      ],
    ];
    final HandGlyphs glyphs = HandGlyphs(<String, HandGlyph>{
      // Written a little above and below the line, as in their boxes.
      'a': HandGlyph(3, box(4.4, 9.4)),
      'n': HandGlyph(3, box(5.2, 10.8)),
      'B': HandGlyph(3, box(0.5, 10.5)),
      'g': HandGlyph(3, box(4.2, 16)),
      // A dash over the stem, longer than the stem itself.
      'i': const HandGlyph(5, <List<InkVector>>[
        <InkVector>[InkVector(0, 2), InkVector(5, 2)],
        <InkVector>[InkVector(3, 5), InkVector(3, 10)],
      ]),
      ',': HandGlyph(1, box(9, 11)),
    });
    for (final String letter in 'anBi'.split('')) {
      expect(
        _inkBounds(glyphs.lined(letter)!.strokes).bottom,
        closeTo(10, 1e-9),
        reason: letter,
      );
    }
    // Punctuation keeps its place.
    expect(_inkBounds(glyphs.lined(',')!.strokes).bottom, 11);
    // The small letters reach up to 5 once on the line, so a tail stands
    // 5 above it and hangs 5 below.
    final Rect g = _inkBounds(glyphs.lined('g')!.strokes);
    expect(g.top, closeTo(5, 1e-9));
    expect(g.bottom, closeTo(15, 1e-9));
    // The dash is a dot over the stem.
    final List<List<InkVector>> i = glyphs.lined('i')!.strokes;
    expect(i.first, hasLength(1));
    expect(i.first.single.x, 3);
    expect(i.first.single.y, lessThan(5));
  });

  test('an o left open is closed when written', () {
    // Round from the top left, stopping short of where it began.
    final List<InkVector> open = <InkVector>[
      for (int k = 0; k <= 15; k++)
        InkVector(
          2.5 + 2.5 * math.cos(math.pi * (1.2 + k * 1.5 / 15)),
          7 - 2.8 * math.sin(math.pi * (1.2 + k * 1.5 / 15)),
        ),
    ];
    final HandGlyphs glyphs = HandGlyphs(<String, HandGlyph>{
      'o': HandGlyph(5, <List<InkVector>>[open]),
    });
    final List<InkVector> closed = glyphs.lined('o')!.strokes.single;
    expect((closed.last - closed.first).length, lessThan(0.3));
    expect(closed.length, greaterThan(open.length));
  });

  test('an o begun low and lifted in a curl closes round, not dented', () {
    // Begun below the middle of its left side, round past the top, and
    // lifted with a curl in toward the middle.
    final List<InkVector> open = <InkVector>[
      for (int k = 0; k <= 30; k++)
        InkVector(
          2.5 + 2.5 * math.cos(math.pi * (1.05 + k * 1.45 / 30)),
          7 - 2.8 * math.sin(math.pi * (1.05 + k * 1.45 / 30)),
        ),
      const InkVector(1.9, 4.5),
      const InkVector(1.6, 5.0),
      const InkVector(1.7, 5.4),
    ];
    final HandGlyphs glyphs = HandGlyphs(<String, HandGlyph>{
      'o': HandGlyph(5, <List<InkVector>>[open]),
    });
    final List<InkVector> closed = glyphs.lined('o')!.strokes.single;
    expect((closed.last - closed.first).length, lessThan(0.3));
    // It turns the one way all round: nowhere does it bend back in.
    double? sign;
    for (int k = 1; k < closed.length - 1; k++) {
      final InkVector a = closed[k] - closed[k - 1];
      final InkVector b = closed[k + 1] - closed[k];
      if (a.length < 1e-6 || b.length < 1e-6) continue;
      final double turn = (a.x * b.y - a.y * b.x) / (a.length * b.length);
      if (turn.abs() < 0.02) continue;
      sign ??= turn.sign;
      expect(turn.sign, sign, reason: 'bends back at point $k');
    }
  });

  test('built letters are built again when the font is read', () {
    final HandwritingStyle custom = readCustomFont(<List<List<InkVector>>>[
      _page(0, _loopy),
    ]).style!;
    final HandGlyphs glyphs = custom.glyphs!;
    expect(glyphs.built, contains('m'));
    expect(glyphs.built, contains('u'));
    expect(glyphs.built, isNot(contains('r')));
    expect(glyphs.built, isNot(contains('n')));
    // A font saved with an m the builder has since learned to make
    // better: read back, it has the m the builder makes now.
    final Map<String, Object?> json = custom.toJson();
    final Map<String, Object?> saved = Map<String, Object?>.of(
      json['glyphs']! as Map<String, Object?>,
    );
    saved['m'] = <Object?>[
      1,
      <Object?>[
        <double>[0, 0, 1, 1],
      ],
    ];
    final HandwritingStyle reread = HandwritingStyle.fromJson(
      jsonDecode(jsonEncode(<String, Object?>{...json, 'glyphs': saved})),
    )!;
    expect(reread.glyphs, glyphs);
  });

  test('cursive joins the letters of a word, and only those', () {
    final HandwritingStyle cursive = HandwritingFont.cursive.style!;
    List<List<InkVector>> write(String text, HandwritingStyle style) =>
        NotationFont.write(
          text,
          origin: InkVector.zero,
          size: 10,
          style: style,
        );
    final HandwritingStyle unjoined = HandwritingStyle(
      slant: cursive.slant,
      widthScale: cursive.widthScale,
      xHeight: cursive.xHeight,
      descenderScale: cursive.descenderScale,
      descenderHook: cursive.descenderHook,
      descenderLoop: cursive.descenderLoop,
      loopAspect: cursive.loopAspect,
      wordSpacing: cursive.wordSpacing,
      baselineJitter: cursive.baselineJitter,
      sizeJitter: cursive.sizeJitter,
    );
    // "mun": a join between m and u, and u and n.
    expect(write('mun', cursive).length - write('mun', unjoined).length, 2);
    // Nothing joins across a space, or into a capital or a digit.
    expect(write('m n', cursive).length, write('m n', unjoined).length);
    expect(write('Mu3', cursive).length, write('Mu3', unjoined).length);
  });

  test('a cubic Bézier fits the curve it was sampled from', () {
    final CubicBezier truth = CubicBezier(const <InkVector>[
      InkVector(0, 0),
      InkVector(1, 3),
      InkVector(5, -2),
      InkVector(7, 0),
    ]);
    // Sampled unevenly, as a pen slows into a turn.
    final List<InkVector> samples = <InkVector>[
      for (int i = 0; i <= 60; i++) truth.at(math.pow(i / 60, 1.4).toDouble()),
    ];
    final CubicBezier free = CubicBezier.fit(<List<InkVector>>[samples])!;
    final CubicBezier pinned = CubicBezier.fit(
      <List<InkVector>>[samples],
      start: truth.points.first,
      end: truth.points.last,
    )!;
    for (final CubicBezier fitted in <CubicBezier>[free, pinned]) {
      for (int i = 0; i <= 20; i++) {
        final InkVector p = truth.at(i / 20);
        double nearest = double.infinity;
        for (final InkVector q in fitted.sampled(400)) {
          nearest = math.min(nearest, (p - q).length);
        }
        expect(nearest, lessThan(0.05), reason: '$fitted at ${i / 20}');
      }
    }
    expect(pinned.points.first, truth.points.first);
    expect(pinned.points.last, truth.points.last);
    expect(
      CubicBezier.fit(<List<InkVector>>[samples.take(3).toList()]),
      isNull,
    );
  });

  test('the font has every shape calibration measures', () {
    final HandFeatures font = HandFeatures.font;
    expect(font.straight, isNotNull);
    expect(font.diagonal, isNotNull);
    expect(font.curve, isNotNull);
    expect(font.bowlLower, isNotNull);
    expect(font.bowlUpper, isNotNull);
    // The halves meet, so the bowl is closed.
    expect(font.bowlLower!.points.last, font.bowlUpper!.points.first);
    expect(font.bowlUpper!.points.last, font.bowlLower!.points.first);
    expect(font.tail, isNotNull);
    expect(font.dot, isNotNull);
    expect(font.dotLift, isNotNull);
    // The font's lines are ruler straight, its dot a point.
    expect(
      _drift(
        font.straight!,
        CubicBezier.line(InkVector.zero, const InkVector(1, 0)),
      ),
      lessThan(0.01),
    );
    expect(font.dot!.extent, lessThan(0.25));
    // The arch bulges, and the g's tail drops.
    expect(font.curve!.at(0.5).y, greaterThan(0.15));
    expect(font.tail!.points.last.y, greaterThan(2));
  });

  test('every letter written out becomes a letter of the font', () {
    final CalibrationReading reading = readCustomFont(_pages(_loopy));
    expect(reading.complete, isTrue);
    final HandwritingStyle style = reading.style!;
    final HandGlyphs glyphs = style.glyphs!;
    expect(
      glyphs.characters.toSet(),
      customFontPages.expand((List<String> p) => p).join().split('').toSet(),
    );
    // Capitals as tall as the font's, sitting on its baseline.
    final Rect h = _inkBounds(glyphs['H']!.strokes);
    expect(h.bottom, closeTo(NotationFont.capHeight, 0.4));
    expect(h.height, closeTo(NotationFont.capHeight, 0.6));
    // The g's tail hangs below it.
    expect(_inkBounds(glyphs['g']!.strokes).bottom, greaterThan(11.5));
    // Everything else is written leaning as the writer's letters do.
    expect(style.slant, greaterThan(HandwritingStyle.standard.slant + 0.1));

    // The font writes the writer's letters, not its own.
    final List<List<InkVector>> a = NotationFont.write(
      'a',
      origin: InkVector.zero,
      size: 10,
      style: style.withGlyphs(null),
    );
    final List<List<InkVector>> own = NotationFont.write(
      'a',
      origin: InkVector.zero,
      size: 10,
      style: style,
    );
    expect(own.length, glyphs['a']!.strokes.length);
    expect(own, isNot(a));
  });

  test('key letters left out are asked for, others are not', () {
    final List<List<List<InkVector>>> pages = <List<List<InkVector>>>[
      _page(0, HandwritingStyle.standard, skip: 'hw'),
    ];
    final CalibrationReading reading = readCustomFont(pages);
    expect(reading.complete, isFalse);
    expect(reading.missing, <String>['h', 'w']);
    expect(reading.style, isNull);
    expect(missingLetters(3, const <List<InkVector>>[]), hasLength(10));

    pages[0] = _page(0, HandwritingStyle.standard);
    final HandwritingStyle style = readCustomFont(pages).style!;
    // Letters left out are built; digits are written in the font.
    expect(style.glyphs!['7'], isNull);
    expect(style.glyphs!['a'], isNotNull);
    expect(style.glyphs!['q'], isNotNull);
  });

  test('a dot strays out of its box but stays with its letter', () {
    // An i dotted high, above the box's top.
    final int iColumn = customFontPages[0][0].indexOf('i');
    final List<List<InkVector>> page = <List<InkVector>>[
      ..._page(0, HandwritingStyle.standard, skip: 'i'),
      <InkVector>[
        InkVector(iColumn * calibrationCell + 0.7, -0.6),
        InkVector(iColumn * calibrationCell + 0.7, 0),
      ],
      <InkVector>[InkVector(iColumn * calibrationCell + 0.75, -1.4)],
    ];
    expect(missingLetters(0, page), isEmpty);
    final List<List<List<List<InkVector>>>> cells = calibrationCells(
      page,
      ruledUnits(3),
      customFontPages[0],
    );
    expect(customFontPages[0][0][iColumn], 'i');
    expect(cells[0][iColumn], hasLength(2));
  });

  test('a row that drifts off its boxes still gives each letter its own', () {
    // Each letter a little further right than the last, the k past the
    // end of the row, and the norstw all left of their boxes.
    final List<String> rows = customFontPages[0];
    List<List<InkVector>> letter(int r, int c, double dx) => NotationFont.write(
      rows[r][c],
      origin: InkVector(
        c * calibrationCell + 0.3 + dx,
        r * calibrationRowGap - 0.9,
      ),
      size: 0.9,
      style: HandwritingStyle.standard,
    );
    final List<List<InkVector>> page = <List<InkVector>>[
      for (int c = 0; c < rows[0].length; c++) ...letter(0, c, c * 0.25),
      for (int c = 0; c < rows[1].length; c++) ...letter(1, c, -0.9),
      for (int c = 0; c < rows[2].length; c++) ...letter(2, c, 0),
    ];
    expect(missingLetters(0, page), isEmpty);

    final List<List<List<List<InkVector>>>> drifted = calibrationCells(
      page,
      ruledUnits(rows.length),
      rows,
    );
    final List<List<List<List<InkVector>>>> placed = calibrationCells(
      _page(0, HandwritingStyle.standard),
      ruledUnits(rows.length),
      rows,
    );
    for (int r = 0; r < rows.length; r++) {
      for (int c = 0; c < rows[r].length; c++) {
        expect(
          drifted[r][c],
          hasLength(placed[r][c].length),
          reason: rows[r][c],
        );
      }
    }
    // The letters themselves are as if written in their boxes.
    final HandGlyphs fromDrifted = readCustomFont(<List<List<InkVector>>>[
      page,
    ]).style!.glyphs!;
    final HandGlyphs fromPlaced = readCustomFont(<List<List<InkVector>>>[
      _page(0, HandwritingStyle.standard),
    ]).style!.glyphs!;
    for (final String l in rows.join().split('')) {
      expect(fromDrifted[l]!.width, closeTo(fromPlaced[l]!.width, 1e-6));
    }
  });

  test('no letter is drawn with saw teeth, in any hand', () {
    const String letters =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    for (final HandwritingStyle style in <HandwritingStyle>[
      for (final HandwritingFont font in HandwritingFont.presets) font.style!,
      readCustomFont(_pages(_loopy)).style!.withGlyphs(null),
      // Profiles of the highest degree, ringing as hard as they can.
      const HandwritingStyle(
        lineProfile: StrokeProfile(<double>[0.1, 0, 0, 0, 0, 0, 0, 0, 0.3]),
        curveProfile: CurveProfile(<double>[
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.6, 0.6, //
        ]),
      ),
    ]) {
      for (final String char in letters.split('')) {
        final List<List<InkVector>> strokes = NotationFont.write(
          char,
          origin: InkVector.zero,
          size: 10,
          style: style.clamped(),
        );
        for (final List<InkVector> stroke in strokes) {
          // A tooth: a sharp turn one way straight after one the other
          // way, between points closer than a fifth of the letter. A pen
          // doubling back on itself, as at the foot of the font's a, is a
          // cusp of the letter, not a tooth.
          for (int i = 2; i < stroke.length - 1; i++) {
            final double a = signedTurn(
              stroke[i - 2],
              stroke[i - 1],
              stroke[i],
            );
            final double b = signedTurn(
              stroke[i - 1],
              stroke[i],
              stroke[i + 1],
            );
            final bool close = (stroke[i] - stroke[i - 1]).length < 2;
            final bool cusp = a.abs() > 2.4 || b.abs() > 2.4;
            expect(
              close && !cusp && a.abs() > 0.25 && b.abs() > 0.25 && a * b < 0,
              isFalse,
              reason: '$char in $style at $i',
            );
          }
        }
      }
    }
  });

  test('styles survive JSON, and unreadable traits fall back', () {
    final HandwritingStyle custom = readCustomFont(_pages(_loopy)).style!;
    final HandwritingStyle reread = HandwritingStyle.fromJson(
      jsonDecode(jsonEncode(custom.toJson())),
    )!;
    expect(reread, custom);
    expect(reread.glyphs, isNotNull);
    // A saved space is the built-in hand's of its day, never measured: it
    // follows the built-in hand's as that changes.
    final HandwritingStyle cursive = HandwritingFont.cursive.style!;
    final HandwritingStyle cursiveReread = HandwritingStyle.fromJson(
      jsonDecode(jsonEncode(cursive.toJson())),
    )!;
    expect(
      cursiveReread.toJson()..remove('wordSpacing'),
      cursive.toJson()..remove('wordSpacing'),
    );
    expect(cursiveReread.wordSpacing, HandwritingStyle.standard.wordSpacing);

    final HandwritingStyle partial = HandwritingStyle.fromJson(
      <String, Object?>{
        'version': HandwritingStyle.version,
        'slant': 9,
        'xHeight': 'tall',
        'curveProfile': <Object?>[1, 'x'],
        'lineProfile': <Object?>[9],
        'glyphs': <String, Object?>{
          'a': <Object?>[
            4,
            <Object?>[
              <double>[0, 5, 4, 10],
            ],
          ],
          'b': 'nope',
          'cd': <Object?>[1, <Object?>[]],
        },
      },
    )!;
    // Held to what a legible hand can have.
    expect(partial.slant, 0.6);
    expect(partial.xHeight, HandwritingStyle.standard.xHeight);
    expect(partial.curveProfile, HandwritingStyle.standard.curveProfile);
    expect(partial.lineProfile.peak, closeTo(0.05, 1e-9));
    expect(partial.glyphs!.characters, <String>['a']);
    expect(HandwritingStyle.fromJson(<String, Object?>{'version': 1}), isNull);
    expect(HandwritingStyle.fromJson('nope'), isNull);

    final HandwritingCalibrationState state =
        HandwritingCalibrationState.fromJson(
          jsonDecode(
                jsonEncode(
                  HandwritingCalibrationState(
                    style: custom,
                    font: HandwritingFont.custom,
                    chatReminderDismissed: true,
                    textSize: AiTextSize.large,
                  ).toJson(),
                ),
              )
              as Map<String, Object?>,
        );
    expect(state.style, custom);
    expect(state.font, HandwritingFont.custom);
    expect(state.skipped, isFalse);
    expect(state.chatReminderDismissed, isTrue);
    expect(state.textSize, AiTextSize.large);
    // Choosing another font keeps the other choices.
    final HandwritingCalibrationState rechosen = state.withStyle(
      HandwritingFont.print.style,
      HandwritingFont.print,
    );
    expect(rechosen.font, HandwritingFont.print);
    expect(rechosen.chatReminderDismissed, isTrue);
    expect(rechosen.textSize, AiTextSize.large);
    expect(
      HandwritingCalibrationState.fromJson(<String, Object?>{}).textSize,
      AiTextSize.medium,
    );
  });

  test('a preset is read back as the font is now', () {
    final HandwritingCalibrationState state =
        HandwritingCalibrationState.fromJson(<String, Object?>{
          'font': 'rounded',
          'style': const HandwritingStyle(slant: 0.5).toJson(),
        });
    expect(state.font, HandwritingFont.rounded);
    expect(state.style, HandwritingFont.rounded.style);
  });

  test('a hand calibrated before there were fonts asks again', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'handwriting_test',
    );
    addTearDown(() => directory.delete(recursive: true));
    final File file = File('${directory.path}/handwriting.json');
    final FileHandwritingProfileStore store = FileHandwritingProfileStore(file);

    await file.writeAsString(
      jsonEncode(<String, Object?>{
        'skipped': false,
        'profile': <String, Object?>{
          'version': 1,
          'glyphs': <String, Object?>{},
        },
      }),
    );
    expect(await store.read(), isNull);

    // Measured from a few letters, with no font chosen.
    await file.writeAsString(
      jsonEncode(<String, Object?>{'skipped': false, 'style': _loopy.toJson()}),
    );
    expect(await store.read(), isNull);

    // A writer's own font whose letters are lost.
    await file.writeAsString(
      jsonEncode(<String, Object?>{'font': 'custom', 'style': _loopy.toJson()}),
    );
    expect(await store.read(), isNull);

    // Skipped, before there were fonts: still skipped.
    await file.writeAsString(jsonEncode(<String, Object?>{'skipped': true}));
    expect((await store.read())!.skipped, isTrue);

    await store.write(
      HandwritingCalibrationState(
        style: HandwritingFont.quick.style,
        font: HandwritingFont.quick,
      ),
    );
    expect((await store.read())!.font, HandwritingFont.quick);
    expect((await store.read())!.style, HandwritingFont.quick.style);

    await file.writeAsString('{not json');
    final HandwritingCalibrationState? damaged = await store.read();
    expect(damaged, isNotNull);
    expect(damaged!.style, isNull);
  });

  test('the font and half-written pages outlive the app', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'handwriting_test',
    );
    addTearDown(() => directory.delete(recursive: true));
    final File file = File('${directory.path}/handwriting.json');
    // Letters left half-written in the old calibration's boxes: not put in
    // the font's.
    await File('${file.path}.font.draft').writeAsString('[[0, 0, 1, 1]]');
    final FileHandwritingProfileStore first = FileHandwritingProfileStore(file);
    expect(await first.readDraft(), isEmpty);
    final List<List<List<InkVector>>> draft = <List<List<InkVector>>>[
      <List<InkVector>>[
        <InkVector>[const InkVector(0.5, -1), const InkVector(1.5, 0)],
      ],
      <List<InkVector>>[
        <InkVector>[const InkVector(2, -0.6)],
      ],
      const <List<InkVector>>[],
    ];
    await first.writeDraft(draft);
    final HandwritingStyle custom = readCustomFont(_pages(_loopy)).style!;
    await first.write(
      HandwritingCalibrationState(style: custom, font: HandwritingFont.custom),
    );

    // As after the app restarts, or signs in again.
    final FileHandwritingProfileStore second = FileHandwritingProfileStore(
      file,
    );
    expect((await second.read())!.style, custom);
    expect(await second.readDraft(), draft);

    await second.writeDraft(const <List<List<InkVector>>>[]);
    expect(await FileHandwritingProfileStore(file).readDraft(), isEmpty);
  });

  test('notation is written in the chosen hand', () {
    List<GeneratedInkTrace> layout(HandwritingStyle? style) => layoutNotation(
      _text('got both'),
      const Size(400, 100),
      handwriting: HandwritingSampleLibrary(
        const <RecognizedInkWord>[],
        calibration: style,
      ),
    );
    final List<InkVector> standard = <InkVector>[
      for (final GeneratedInkTrace t in layout(null)) ...t.points,
    ];
    for (final HandwritingStyle style in <HandwritingStyle>[
      HandwritingFont.cursive.style!,
      HandwritingFont.print.style!,
      readCustomFont(_pages(_loopy)).style!,
    ]) {
      expect(<InkVector>[
        for (final GeneratedInkTrace t in layout(style)) ...t.points,
      ], isNot(standard));
    }
  });

  test('a wider hand still fits where the font would', () {
    // Text that just fits before the edge of the paper in the built-in
    // hand. A wider hand used to run off it, and the whole notation was
    // refused, so the assistant wrote nothing.
    const Size page = Size(800, 600);
    const String text = 'quickly jumping notes';
    final double x =
        (page.width - 4 - NotationFont.width(text, 30)) / page.width;
    for (final HandwritingStyle wide in <HandwritingStyle>[
      const HandwritingStyle(
        slant: 0.5,
        widthScale: 1.5,
        descenderScale: 1.6,
        wordSpacing: 10,
      ),
      HandwritingFont.rounded.style!,
      readCustomFont(_pages(_loopy)).style!,
    ]) {
      final List<GeneratedInkTrace> traces = layoutNotation(
        _text(text, x: x, size: 30),
        page,
        handwriting: HandwritingSampleLibrary(
          const <RecognizedInkWord>[],
          calibration: wide,
        ),
      );
      final Rect bounds = _bounds(traces);
      expect(bounds.left, greaterThanOrEqualTo(x * page.width - 0.5));
      expect(bounds.right, lessThanOrEqualTo(page.width - 4 + 0.5));
      expect(
        bounds.top,
        greaterThanOrEqualTo(0.2 * page.height - 30 * 0.1 - 0.5),
      );
      final InkController controller = InkController();
      addTearDown(controller.dispose);
      expect(
        controller.addAiNotation(
          traces: traces,
          expectedRevision: 0,
          surfaceSize: page,
        ),
        AddNotationResult.added,
      );
    }
  });

  test('the writer\'s hand is smoothed, ends kept', () {
    final List<InkVector> jagged = <InkVector>[
      for (int i = 0; i <= 40; i++) InkVector(i.toDouble(), i.isEven ? 0 : 1),
    ];
    final List<InkVector> smooth = beautifyHandwriting(<List<InkVector>>[
      jagged,
      const <InkVector>[InkVector(5, 5)],
    ], spacing: 2).first;
    expect(smooth.first, jagged.first);
    expect(smooth.last, jagged.last);
    for (final InkVector point in smooth.skip(1).take(smooth.length - 2)) {
      expect(point.y, inInclusiveRange(0.2, 0.8));
    }
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
    expect(find.text("Choose the AI's handwriting"), findsOneWidget);

    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    expect(find.text('Open'), findsOneWidget);
    expect(store.state!.skipped, isTrue);
    expect(store.state!.style, isNull);
  });

  testWidgets('choosing a font saves it', (WidgetTester tester) async {
    final InMemoryHandwritingProfileStore store =
        InMemoryHandwritingProfileStore();
    await _openCalibration(tester, store);
    for (final HandwritingFont font in HandwritingFont.values) {
      expect(find.text(font.label), findsOneWidget, reason: font.name);
    }

    await tester.tap(_card(HandwritingFont.cursive));
    await tester.pump();
    await tester.tap(find.text('Use this handwriting'));
    await tester.pumpAndSettle();

    expect(store.state!.font, HandwritingFont.cursive);
    expect(store.state!.style, HandwritingFont.cursive.style);
    expect(store.state!.skipped, isFalse);
    expect(HandwritingCalibration.current.value, HandwritingFont.cursive.style);
    expect(find.text('Open'), findsOneWidget);
  });

  testWidgets('the font chosen before is chosen again', (
    WidgetTester tester,
  ) async {
    final InMemoryHandwritingProfileStore store =
        InMemoryHandwritingProfileStore(
          HandwritingCalibrationState(
            style: HandwritingFont.quick.style,
            font: HandwritingFont.quick,
          ),
        );
    await _openCalibration(tester, store);
    await tester.tap(find.text('Use this handwriting'));
    await tester.pumpAndSettle();
    expect(store.state!.font, HandwritingFont.quick);
  });

  testWidgets('writing the key letters makes the writer\'s own font', (
    WidgetTester tester,
  ) async {
    final InMemoryHandwritingProfileStore store =
        InMemoryHandwritingProfileStore();
    await _openCalibration(tester, store);
    await _startWriting(tester);
    expect(find.textContaining('Key letters'), findsOneWidget);

    await _draw(tester, 0, _page(0, _loopy));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    // Only that it is finished: neither the font nor more letters to write.
    expect(
      find.byKey(const ValueKey<String>('calibration-finished')),
      findsOneWidget,
    );
    expect(find.textContaining('Write more'), findsNothing);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    final HandwritingStyle saved = store.state!.style!;
    expect(store.state!.font, HandwritingFont.custom);
    expect(saved.glyphs!['Q'], isNotNull);
    expect(saved.glyphs!['5'], isNull);
    expect(HandwritingCalibration.current.value, saved);
    expect(store.draft, isEmpty);
    expect(find.text('Open'), findsOneWidget);
  });

  testWidgets('key letters left out are asked for', (
    WidgetTester tester,
  ) async {
    await _openCalibration(tester, InMemoryHandwritingProfileStore());
    await _startWriting(tester);
    await _draw(tester, 0, _page(0, HandwritingStyle.standard, skip: 'gw'));
    await tester.tap(find.text('Done'));
    await tester.pump();

    expect(find.text('Write g and w in their boxes too.'), findsOneWidget);
    expect(find.textContaining('Key letters'), findsOneWidget);
  });

  testWidgets('the eraser removes what it touches, and undo restores it', (
    WidgetTester tester,
  ) async {
    final InMemoryHandwritingProfileStore store =
        InMemoryHandwritingProfileStore();
    await _openCalibration(tester, store);
    await _startWriting(tester);
    final Offset topLeft = tester.getTopLeft(_pad);
    final CalibrationRuling ruling = _rulingOf(tester, 0);
    final double y = ruling.baselines.first - ruling.lineHeight / 2;
    final double first = ruling.left + ruling.cellWidth * 0.3;
    final double second = ruling.left + ruling.cellWidth * 2.3;
    Future<void> line(double x) async {
      final TestGesture pen = await tester.startGesture(
        topLeft + Offset(x, y),
        kind: PointerDeviceKind.stylus,
      );
      await pen.moveTo(topLeft + Offset(x + 20, y));
      await pen.up();
      await tester.pump();
    }

    await line(first);
    await line(second);
    expect(store.draft.first, hasLength(2));

    // The pen's eraser end.
    await tester.dragFrom(
      topLeft + Offset(first + 10, y - 20),
      const Offset(0, 40),
      kind: PointerDeviceKind.invertedStylus,
    );
    await tester.pump();
    expect(store.draft.first, hasLength(1));

    // The eraser button, with the tip.
    await tester.tap(find.byKey(const ValueKey<String>('calibration-eraser')));
    await tester.pump();
    await tester.dragFrom(
      topLeft + Offset(second + 10, y - 20),
      const Offset(0, 40),
      kind: PointerDeviceKind.stylus,
    );
    await tester.pump();
    expect(store.draft, isEmpty);

    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();
    expect(store.draft.first, hasLength(1));
  });

  testWidgets('half-written letters are there when calibration reopens', (
    WidgetTester tester,
  ) async {
    final InMemoryHandwritingProfileStore store =
        InMemoryHandwritingProfileStore()
          ..draft = <List<List<InkVector>>>[
            _page(0, HandwritingStyle.standard),
            <List<InkVector>>[
              <InkVector>[const InkVector(0.3, -0.5), const InkVector(0.6, 0)],
            ],
            const <List<InkVector>>[],
          ];
    await _openCalibration(tester, store);
    await _startWriting(tester);

    // On the key letters, as they were left.
    expect(find.textContaining('Key letters'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Clear'))
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(store.draft, isEmpty);
  });

  testWidgets('only a pen writes on the pad', (WidgetTester tester) async {
    await _openCalibration(tester, InMemoryHandwritingProfileStore());
    await _startWriting(tester);
    await tester.dragFrom(
      tester.getTopLeft(_pad) + const Offset(40, 40),
      const Offset(200, 10),
    );
    await tester.pump();

    expect(find.text('Use your pen to write here'), findsOneWidget);
    final FilledButton next = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Done'),
    );
    expect(next.onPressed, isNull);
  });

  for (final TestViewport viewport in TestViewport.values) {
    testWidgets('every page fits one screen: ${viewport.name}', (
      WidgetTester tester,
    ) async {
      await _openCalibration(
        tester,
        InMemoryHandwritingProfileStore(),
        viewport: viewport,
      );
      expect(tester.takeException(), isNull);
      await _startWriting(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(Scrollable), findsNothing);
      final Rect screen =
          Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
      final CalibrationRuling ruling = _rulingOf(tester, 0);
      final double columns = customFontPages[0]
          .map((String row) => row.length)
          .reduce(math.max)
          .toDouble();
      // Every box is on the pad, and big enough to write in.
      expect(ruling.left, greaterThanOrEqualTo(-0.5));
      expect(
        ruling.left + ruling.cellWidth * columns,
        lessThanOrEqualTo(tester.getSize(_pad).width + 0.5),
      );
      expect(ruling.lineHeight, greaterThanOrEqualTo(22));
      expect(
        ruling.baselines.last + ruling.lineHeight * 0.8,
        lessThanOrEqualTo(tester.getSize(_pad).height + 0.5),
      );
      final Finder done = find.text('Done');
      expect(screen.contains(tester.getBottomRight(done)), isTrue);
      await _draw(tester, 0, _page(0, HandwritingStyle.standard));
      await tester.tap(done);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(screen.contains(tester.getBottomRight(find.text('Done'))), isTrue);
    });
  }
}
