import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_response_text.dart';

void main() {
  group('assistant text transferred to Study Desk', () {
    test('drops generated end markers and everything after them', () {
      const answer = '## MOSFET\n\nThe gate voltage controls the channel.';
      for (final marker in ['(end)', '(stop)', '(END)', '(Stop).']) {
        expect(
          assistantTextForStudyDesk(
            '$answer\n\n$marker\nMOSFET overview complete.\n'
            'Review the regions and the threshold condition next.\n'
            'Good luck.\n(stop)\nFinal line.\n.....',
          ),
          answer,
        );
      }
    });

    test('drops standalone trailing sign-offs without an end marker', () {
      expect(
        assistantTextForStudyDesk(
          'The threshold is Vth.\n\nGood luck.\n'
          'Final line.\n.....\n',
        ),
        'The threshold is Vth.',
      );
    });

    test('preserves literal examples, formulas and SVG text', () {
      for (final answer in [
        'A call to (stop) ends the process.',
        '> (end)\n\nThis is a quoted marker.',
        'Good luck.\n\nNow calculate the current.',
        '```text\n(end)\n\nGood luck.\n```',
        '~~~~text\n(stop)\n```\n~~~~',
        '\$\$\n(end)\n\$\$',
        '<svg>\n<text>\n(stop)\n</text>\n</svg>',
        'The threshold is Vth.\n\nReview the regions next.',
        'MOSFET overview complete.\n\nNow calculate the current.',
      ]) {
        expect(assistantTextForStudyDesk(answer), answer);
      }
    });

    test(
      'drops a completion footer without dropping a useful review prompt',
      () {
        expect(
          assistantTextForStudyDesk(
            'The gate voltage controls the channel.\n\n'
            'MOSFET overview complete.\n'
            'Review the regions and the threshold condition next.\nGood luck.',
          ),
          'The gate voltage controls the channel.',
        );
      },
    );

    test('filters a marker after a code block', () {
      expect(
        assistantTextForStudyDesk('```text\n(end)\n```\n\n(stop)\nFinal line.'),
        '```text\n(end)\n```',
      );
    });

    test('removes drawing narration between substantive paragraphs', () {
      for (final label in ['notation:', '**Notation:**', '- Notation:']) {
        expect(
          assistantTextForStudyDesk(
            'The channel forms above the threshold.\n\n'
            '$label the cutoff and linear formulas in blue\n'
            'below the saturation formula.\n\n'
            'The drain current depends on gate voltage.',
          ).split(RegExp(r'\n\s*\n')),
          [
            'The channel forms above the threshold.',
            'The drain current depends on gate voltage.',
          ],
        );
      }
    });

    test('preserves notation definitions, quotes and code examples', () {
      for (final answer in [
        'Notation: Vth denotes the threshold voltage.',
        '> Notation: formulas in blue below the graph.',
        '```text\nNotation: formulas in blue below the graph.\n```',
        '\$\$\nNotation: formulas in blue below the graph.\n\$\$',
        '<svg>\n<text>Notation: formulas in blue below the graph.</text>\n</svg>',
        'Use mathematical notation: the blue curve is the current.',
      ]) {
        expect(assistantTextForStudyDesk(answer), answer);
      }
    });

    test('does not remove code or the next list item after narration', () {
      expect(
        assistantTextForStudyDesk(
          'Notation: formula added in blue.\n'
          '- The current is zero below threshold.\n\n'
          '```text\nNotation: a formula in blue.\n```',
        ),
        '- The current is zero below threshold.\n\n'
        '```text\nNotation: a formula in blue.\n```',
      );
    });
  });
}
