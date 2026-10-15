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
}
