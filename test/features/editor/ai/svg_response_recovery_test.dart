import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/ai/svg_ink_converter.dart';
import 'package:greatnote/features/editor/document_io/svg_document.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';

const String _message = '<desc data-etonia-role="message">Drawn.</desc>';
const String _line = '<path d="M10 20 L90 20" stroke="black" fill="none"/>';
const String _root = '<svg viewBox="0 0 100 100">';

void main() {
  group('SVG response recovery', () {
    for (final String metadata in <String>[
      '',
      'data-etonia-version="2"',
      'data-etonia-bounds="0 0 -10 10"',
      'data-etonia-bounds="90 90 30 30"',
      'data-etonia-bounds="0 0 10"',
      'data-etonia-bounds="NaN 0 10 10"',
    ]) {
      test('keeps renderable artwork with metadata: $metadata', () {
        final AiAssistantResponse response = AiAssistantResponse.parse(
          '<svg viewBox="0 0 100 100" $metadata>$_message$_line</svg>',
        );
        expect(response.message, 'Drawn.');
        expect(response.notationRejected, isFalse);
        final EditableSvg vector = response.notation!.vector!;
        expect(vector.contentBounds, const Rect.fromLTWH(0, 0, 100, 100));
        expect(vector.source, contains(_line));
        expect(
          SvgInkConverter.convert(
            vector,
            defaultInk: InkPalette.ink,
            defaultWidth: 2,
          ).traces,
          hasLength(1),
        );
      });
    }

    for (final String body in <String>[
      '$_message<g>$_line',
      '$_message<g>$_line</svg>',
      '$_message$_line<path d="M1',
      '<desc data-etonia-role=message>Drawn.</desc>'
          '<path d="M10 20 L90 20" stroke=black fill=none/>',
    ]) {
      test('repairs incomplete or malformed XML: $body', () {
        final AiAssistantResponse response = AiAssistantResponse.parse(
          '$_root$body',
        );
        expect(response.message, 'Drawn.');
        expect(response.notationRejected, isFalse);
        expect(response.notation!.vector!.source, contains('M10 20 L90 20'));
        expect(
          () => EditableSvg.parse(response.notation!.vector!.source),
          returnsNormally,
        );
      });
    }

    test('escapes comparisons and ampersands without damaging entities', () {
      final AiAssistantResponse response = AiAssistantResponse.parse(
        '$_root<desc data-etonia-role="message">'
        'x < 3 & y &gt; 1</desc>$_line</svg>',
      );
      expect(response.message, 'x < 3 & y > 1');
      expect(response.notationRejected, isFalse);
    });

    test('preserves quoted attributes while repairing numeric attributes', () {
      final EditableSvg svg = EditableSvg.parseResponse(
        '$_root$_message<text x=10 y=20 '
        'aria-label="x = 3">A & B</text></svg>',
      );
      expect(svg.source, contains('aria-label="x = 3"'));
      expect(svg.source, contains('A &amp; B'));
    });

    for (final String timing in <String>[
      'data-etonia-step="0"',
      'data-etonia-step="25"',
      'data-etonia-step="first"',
    ]) {
      test(
        'renders statically when animation metadata is invalid: $timing',
        () {
          final EditableSvg svg = EditableSvg.parseResponse(
            '$_root$_message<g $timing>$_line</g></svg>',
          );
          expect(svg.isAnimated, isFalse);
          expect(svg.source, contains(_line));
        },
      );
    }

    test('invalid animation duration keeps all steps visible statically', () {
      final EditableSvg svg = EditableSvg.parseResponse(
        '<svg viewBox="0 0 100 100" data-etonia-duration-ms="999999">'
        '$_message<g data-etonia-step="1">$_line</g></svg>',
      );
      expect(svg.isAnimated, isFalse);
      expect(svg.duration, Duration.zero);
      expect(svg.frame(0), contains(_line));
    });

    test('uses ordinary SVG descriptions when the message role is missing', () {
      final AiAssistantResponse response = AiAssistantResponse.parse(
        '$_root<desc>Drawn.</desc>$_line</svg>',
      );
      expect(response.message, 'Drawn.');
      expect(response.notationRejected, isFalse);
    });

    test('retains strict validation for SVG imports', () {
      expect(() => EditableSvg.parse('$_root$_line'), throwsFormatException);
    });

    test('repair does not admit executable or externally loaded content', () {
      for (final String unsafe in <String>[
        '<script>alert(1)</script>',
        '<path onclick="alert(1)" d="M1 1 L2 2"/>',
        '<use href="https://example.com/x.svg#x"/>',
        '<style>path { fill: url(https://example.com/x); }</style>',
        '<foreignObject><p>Unsafe</p></foreignObject>',
      ]) {
        final AiAssistantResponse response = AiAssistantResponse.parse(
          '$_root$_message$_line$unsafe</svg>',
        );
        expect(response.message, 'Drawn.');
        expect(response.notation, isNull);
        expect(response.notationRejected, isTrue);
        expect(
          () => EditableSvg.parseResponse('$_root$_message$_line$unsafe'),
          throwsFormatException,
        );
      }
      expect(
        () => EditableSvg.parseResponse(
          '<!DOCTYPE svg>$_root$_message$_line</svg>',
        ),
        throwsFormatException,
      );
    });

    test('repair still enforces size and tree limits', () {
      for (final String source in <String>[
        '$_root$_message${' ' * EditableSvg.maxBytes}$_line',
        '$_root$_message${'<g>' * 42}$_line',
        '$_root$_message${'<path d="M1 1"/>' * EditableSvg.maxNodes}',
      ]) {
        expect(() => EditableSvg.parseResponse(source), throwsFormatException);
      }
    });
  });
}
