import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/ai/chat_math.dart';

String _decoded(String json) =>
    (jsonDecode(repairLatexEscapes(json)) as Map<String, Object?>)['m']!
        as String;

void main() {
  group('repairLatexEscapes', () {
    test('keeps LaTeX that the model left unescaped', () {
      expect(_decoded(r'{"m":"\frac{1}{2}"}'), r'\frac{1}{2}');
      expect(
        _decoded(r'{"m":"\theta + \beta + \rho"}'),
        r'\theta + \beta + \rho',
      );
      expect(
        _decoded(r'{"m":"\alpha \sqrt{2} \cdot \underline{x}"}'),
        r'\alpha \sqrt{2} \cdot \underline{x}',
      );
      expect(_decoded(r'{"m":"a \nabla b \neq c"}'), r'a \nabla b \neq c');
    });

    test('keeps escapes that were meant', () {
      expect(_decoded(r'{"m":"one\ntwo\nThe end"}'), 'one\ntwo\nThe end');
      expect(_decoded(r'{"m":"\\frac \"q\" \u00e9"}'), r'\frac "q" é');
      expect(_decoded(r'{"m":"a\t1"}'), 'a\t1');
    });

    test('lets a response with bare LaTeX parse', () {
      final AiAssistantResponse response = AiAssistantResponse.parse(
        r'{"version":2,"message":"$s(t) = \frac{1}{2}at^2$, $\alpha$","notation":null}',
      );
      expect(response.message, r'$s(t) = \frac{1}{2}at^2$, $\alpha$');
      expect(
        AiAssistantResponse.partialMessage(r'{"version":2,"message":"\frac{1}'),
        r'\frac{1}',
      );
    });
  });

  group('delimitBareMath', () {
    test('wraps a bare formula', () {
      expect(
        delimitBareMath(r's(t) = \frac{1}{2}at^2'),
        r'$s(t) = \frac{1}{2}at^2$',
      );
    });

    test('wraps only the formula in prose, keeping punctuation out', () {
      expect(
        delimitBareMath(r'The position is s(t) = \frac{1}{2}at^2.'),
        r'The position is $s(t) = \frac{1}{2}at^2$.',
      );
      expect(
        delimitBareMath(r'- where \Delta t is the time'),
        r'- where $\Delta t$ is the time',
      );
    });

    test('leaves delimited math, code, and plain text alone', () {
      const List<String> unchanged = <String>[
        r'Already $\frac{1}{2}$ here',
        r'Inline \(\alpha\) here',
        'No math at all',
        r'Code `\frac{a}{b}` here',
        '```\n\\frac{a}{b}\n```',
        '\\[\n\\frac{a}{b}\n\\]',
        '\$\$\n\\frac{a}{b}\n\$\$',
      ];
      for (final String text in unchanged) {
        expect(delimitBareMath(text), text);
      }
    });
  });

  group('normalizeInlineMath', () {
    test('rewrites formulas the strict dollar rule leaves as source', () {
      expect(
        normalizeInlineMath(r'So $ \int x\,dx $ here'),
        r'So \(\int x\,dx\) here',
      );
      expect(
        normalizeInlineMath('So \$\\int_2^3\\left(x\\right)\ndx\$ is it'),
        r'So \(\int_2^3\left(x\right) dx\) is it',
      );
      expect(normalizeInlineMath(r'$2 \pi r$ long'), r'\(2 \pi r\) long');
      expect(normalizeInlineMath(r'$x^2$5'), r'\(x^2\)5');
      expect(normalizeInlineMath(r'Tight $x$ too'), r'Tight \(x\) too');
    });

    test('leaves prices, display maths, escapes, and code alone', () {
      const List<String> unchanged = <String>[
        r'Costs $5 and $10 here',
        r'From $5-$10',
        r'Escaped \$5 and \$6',
        '\$\$\n\\frac{a}{b}\n\$\$',
        r'Code `$x $` here',
        '```\n\$ a \\b \$\n```',
        r'Open $\frac{1}{2} still streaming',
        'Para \$ \\alpha\n\nnext \$ para',
      ];
      for (final String text in unchanged) {
        expect(normalizeInlineMath(text), text);
      }
    });
  });
}
