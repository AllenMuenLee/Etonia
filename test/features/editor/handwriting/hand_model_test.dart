import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/handwriting/glyph_builder.dart';
import 'package:greatnote/features/editor/handwriting/hand_glyphs.dart';
import 'package:greatnote/features/editor/handwriting/hand_model.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';

/// [slot]'s average letter as strokes.
HandStrokes _average(HandSlot slot) {
  final HandStrokes strokes = <List<InkVector>>[];
  int d = 0;
  for (final int count in slot.counts) {
    strokes.add(<InkVector>[
      for (int p = 0; p < count; p++)
        InkVector(slot.mean[d + 2 * p], slot.mean[d + 2 * p + 1]),
    ]);
    d += 2 * count;
  }
  return strokes;
}

void main() {
  final HandModel model = HandModel.bundled!;

  HandSlot slotOf(String char) => model.slots
      .where((HandSlot s) => s.char == char)
      .reduce((HandSlot a, HandSlot b) => a.samples >= b.samples ? a : b);

  test('the bundled model decodes and survives a round trip', () {
    expect(model.dimensions, greaterThan(0));
    expect(
      model.slots.map((HandSlot s) => s.char).toSet(),
      containsAll(<String>['a', 'j', 'x', 'D']),
    );
    final HandModel again = HandModel.decode(model.encode());
    expect(again.slots, hasLength(model.slots.length));
    expect(again.fallbacks, model.fallbacks);
    final HandSlot a = model.slots.first;
    final HandSlot b = again.slots.first;
    for (int i = 0; i < a.mean.length; i++) {
      expect(b.mean[i], closeTo(a.mean[i], 0.002));
    }
  });

  test('a letter lines up whatever direction and order it was written', () {
    final HandSlot slot = slotOf('t');
    final HandStrokes average = _average(slot);
    final HandStrokes scrambled = <List<InkVector>>[
      for (final List<InkVector> stroke in average.reversed)
        stroke.reversed.toList(),
    ];
    // Strokes in another order, each written the other way, lay out as the
    // letter itself does.
    final (Float64List straight, double straightError) = alignToSlot(
      average,
      slot.counts,
      slot.mean,
    );
    final (Float64List layout, double error) = alignToSlot(
      scrambled,
      slot.counts,
      slot.mean,
    );
    expect(error, closeTo(straightError, 1e-6));
    for (int i = 0; i < layout.length; i++) {
      expect(layout[i], closeTo(straight[i], 1e-6));
    }
  });

  test('the average hand is predicted as the average hand', () {
    final HandEstimate? estimate = model.estimate(<String, HandStrokes>{
      for (final String char in keyLetters.split(''))
        char: _average(slotOf(char)),
    });
    expect(estimate, isNotNull);
    expect(estimate!.read, containsAll(keyLetters.split('')));
    expect(model.trusts(estimate), isTrue);
    // Hands spread one unit along each dimension: the average one lies
    // well within that of the middle.
    for (final double z in estimate.position) {
      expect(z.abs(), lessThan(1));
    }
    // A couple of letters say too little to be trusted.
    expect(
      model.trusts(
        model.estimate(<String, HandStrokes>{
          'a': _average(slotOf('a')),
          'o': _average(slotOf('o')),
        })!,
      ),
      isFalse,
    );
    final HandStrokes? j = model.letter('j', estimate);
    expect(j, isNotNull);
    expect(j!.expand((List<InkVector> s) => s), isNotEmpty);
  });

  test('the builder writes every letter, with the model or without', () {
    final Map<String, HandGlyph> written = <String, HandGlyph>{
      for (final String char in keyLetters.split(''))
        char: () {
          final HandStrokes strokes = _average(slotOf(char));
          double right = 0;
          for (final InkVector p in strokes.expand((List<InkVector> s) => s)) {
            if (p.x > right) right = p.x;
          }
          return HandGlyph(right, strokes);
        }(),
    };
    final Map<String, HandGlyph> withModel = buildMissingGlyphs(
      written,
      slant: 0,
    );
    HandModel.debugDisabled = true;
    addTearDown(() => HandModel.debugDisabled = false);
    final Map<String, HandGlyph> alone = buildMissingGlyphs(written, slant: 0);
    expect(withModel.keys.toSet(), alone.keys.toSet());
    expect(withModel.keys, containsAll(<String>['j', 'l', 'x', 'z']));
  });
}
