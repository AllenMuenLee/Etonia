import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/handwriting_prediction.dart';

void main() {
  String choose(
    List<String> texts, {
    String draft = '',
    List<String> history = const [],
  }) => const HandwritingPrediction().choose(
    texts.map((text) => HandwritingCandidate(text)).toList(),
    HandwritingContext(draft: draft, recentMessages: history),
  );

  test('keeps native rank when there is no contextual evidence', () {
    expect(choose(['farm', 'form']), 'farm');
    expect(choose(['', '  ']), '');
  });

  test('uses prior conversation to resolve similar technical words', () {
    expect(
      choose(
        ['capacilance', 'capacitance'],
        history: ['The capacitance of this circuit depends on plate area.'],
      ),
      'capacitance',
    );
  });

  test('uses the draft to choose the likely next word in a known phrase', () {
    expect(
      choose(
        ['farm', 'form'],
        draft: 'the standard',
        history: ['The farm is large. The standard form is useful.'],
      ),
      'form',
    );
    expect(
      choose(
        ['form', 'farm'],
        draft: 'visit the',
        history: ['Fill out the form before you visit the farm.'],
      ),
      'farm',
    );
  });

  test('uses the words after ambiguous handwriting within the same batch', () {
    expect(
      choose(
        ['cell division', 'call division'],
        history: ['Call division headquarters. The cell is small.'],
      ),
      'call division',
    );
  });

  test('does not synthesize completions or unrelated topic words', () {
    expect(
      choose(
        ['cat', 'capacitor'],
        draft: 'the',
        history: ['The capacitor stores energy.'],
      ),
      'cat',
    );
    expect(choose(['cap'], history: ['capacitance']), 'cap');
  });

  test('recognizes similar joined-letter shapes in native alternatives', () {
    expect(
      choose(
        ['forrn', 'form'],
        draft: 'standard',
        history: ['Use the standard form.'],
      ),
      'form',
    );
    expect(
      choose(
        ['modem', 'modern'],
        draft: 'the',
        history: ['The modern design.'],
      ),
      'modern',
    );
  });

  test('preserves digits, operators, single letters and word count', () {
    for (final pair in [
      ['x = 2', 'x = 3'],
      ['a + b', 'a - b'],
      ['x', 'y'],
      ['can', 'can not'],
    ]) {
      expect(choose(pair, history: [pair.last, pair.last]), pair.first);
    }
  });

  test('context does not overturn a clear native confidence advantage', () {
    expect(
      const HandwritingPrediction().choose(
        const [
          HandwritingCandidate('farm', confidence: 0.95),
          HandwritingCandidate('form', confidence: 0.6),
        ],
        HandwritingContext(
          draft: 'standard',
          recentMessages: ['standard form'],
        ),
      ),
      'farm',
    );
  });

  test('never forms phrases across conversation turn boundaries', () {
    expect(
      choose(
        ['farm', 'form'],
        draft: 'standard',
        history: ['farm form', 'standard', 'form farm'],
      ),
      'farm',
    );
  });

  test('handles non-English vocabulary without an English dictionary', () {
    expect(
      choose(
        ['résistonce', 'résistance'],
        history: ['La résistance électrique'],
      ),
      'résistance',
    );
  });

  test(
    'bounds hints and preserves the word separator in native pre-context',
    () {
      final context = HandwritingContext(
        draft: 'Please explain the capacitance',
        recentMessages: List.generate(10, (i) => 'message$i'),
      );
      expect(context.preContext, 'ain the capacitance ');
      expect(context.preContext.length, 20);
      expect(context.customWords, contains('capacitance'));
      expect(context.recentMessages, hasLength(6));
      expect(context.recentMessages.first, 'message9');
      expect(HandwritingContext().preContext, '');
    },
  );
}
