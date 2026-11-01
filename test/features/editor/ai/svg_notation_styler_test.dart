import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ink_attachment.dart';
import 'package:greatnote/features/editor/ai/notation_space.dart';
import 'package:greatnote/features/editor/ai/svg_ink_converter.dart';
import 'package:greatnote/features/editor/ai/svg_notation_styler.dart';
import 'package:greatnote/features/editor/document_io/svg_document.dart';
import 'package:greatnote/features/editor/handwriting/handwriting_fonts.dart';
import 'package:greatnote/features/editor/handwriting/handwriting_style.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:xml/xml.dart';

const String _source = '''
<svg xmlns="http://www.w3.org/2000/svg" data-etonia-version="1"
  viewBox="0 0 400 300" data-etonia-bounds="20 30 300 180">
  <title>Force note</title>
  <desc data-etonia-role="message">Resolve the force.</desc>
  <text x="60" y="90" font-size="24" fill="black"
    data-etonia-step="1">Force = 12 N</text>
  <path d="M40 130 L260 130" stroke="black" fill="none"/>
  <circle cx="280" cy="130" r="18" fill="none" stroke="#1f5fd1"
    data-etonia-stroke-ink="blue"/>
</svg>
''';

void main() {
  final InkColor red = InkPalette.byId('red')!;
  group('SvgNotationStyler', () {
    test('turns SVG text into the configured handwriting paths', () {
      final EditableSvg vector = EditableSvg.parse(
        _source,
        modelResponse: true,
      );
      final EditableSvg normal = SvgNotationStyler.apply(
        vector,
        handwriting: HandwritingStyle.standard,
        defaultInk: red,
        penWidth: 4,
      );
      final EditableSvg cursive = SvgNotationStyler.apply(
        vector,
        handwriting: HandwritingFont.cursive.style!,
        defaultInk: red,
        penWidth: 4,
      );

      expect(normal.source, isNot(contains('<text')));
      expect(normal.source, contains('aria-label="Force = 12 N"'));
      expect(normal.source, contains('data-etonia-handwriting="1"'));
      expect(normal.source, contains('data-etonia-stroke-ink="red"'));
      expect(normal.source, contains('stroke-width="4.0"'));
      expect(normal.source, isNot(contains('data-etonia-step="1"')));
      expect(normal.source, contains('data-etonia-static="1"'));
      expect(normal.isAnimated, isFalse);
      expect(normal.message, 'Resolve the force.');
      expect(cursive.source, isNot(normal.source));
    });

    test('keeps only explicitly semantic motion and fixes nested text', () {
      final EditableSvg styled = SvgNotationStyler.apply(
        EditableSvg.parse('''
<svg xmlns="http://www.w3.org/2000/svg" data-etonia-version="1"
  viewBox="0 0 400 300" data-etonia-bounds="20 20 360 260"
  data-etonia-duration-ms="1200">
  <title>Flow</title>
  <desc data-etonia-role="message">Flow through the pipe.</desc>
  <line x1="20" y1="30" x2="380" y2="30" stroke="black"
    data-etonia-step="1"/>
  <g data-etonia-motion="1" data-etonia-step="2">
    <circle cx="180" cy="150" r="20" fill="none" stroke="blue"/>
    <text x="180" y="200" font-size="20" fill="black">speed</text>
  </g>
</svg>
''', modelResponse: true),
        handwriting: HandwritingStyle.standard,
        defaultInk: red,
        penWidth: 3,
      );

      final XmlDocument document = XmlDocument.parse(styled.source);
      expect(styled.stepCount, 2);
      expect(
        document
            .findAllElements('line')
            .single
            .getAttribute('data-etonia-step'),
        isNull,
      );
      final XmlElement label = document
          .findAllElements('g')
          .firstWhere(
            (XmlElement group) => group.getAttribute('aria-label') == 'speed',
          );
      expect(label.getAttribute('data-etonia-static'), '1');
      expect(label.getAttribute('data-etonia-step'), isNull);

      final SvgInkConversion conversion = SvgInkConverter.convert(
        styled,
        defaultInk: InkPalette.ink,
        defaultWidth: 3,
      );
      // Traversal emits the fixed line, the moving circle, then every stroke
      // of the handwritten label. Only the circle receives playback times.
      expect(conversion.traces[0].timesMs, everyElement(0));
      expect(conversion.traces[1].timesMs!.last, greaterThan(0));
      for (final trace in conversion.traces.skip(2)) {
        expect(trace.timesMs, everyElement(0));
      }
    });

    test('a dot, such as an i\'s, is a path that paints', () {
      final EditableSvg styled = SvgNotationStyler.apply(
        EditableSvg.parse(
          _source.replaceFirst('Force = 12 N', 'i'),
          modelResponse: true,
        ),
        handwriting: HandwritingStyle.standard,
        defaultInk: red,
        penWidth: 4,
      );
      final List<String> paths = <String>[
        for (final XmlElement path in XmlDocument.parse(
          styled.source,
        ).findAllElements('path'))
          if (path.getAttribute('data-etonia-stroke-ink') == 'red')
            path.getAttribute('d')!,
      ];
      expect(paths, isNotEmpty);
      // A lone move paints nothing, even with round caps.
      for (final String d in paths) {
        expect(d, contains('L'));
      }
    });

    test('caps text at the writer\'s size', () {
      double height(double? cap) {
        final EditableSvg styled = SvgNotationStyler.apply(
          EditableSvg.parse(_source, modelResponse: true),
          handwriting: HandwritingStyle.standard,
          defaultInk: red,
          penWidth: 4,
          maxTextSize: cap ?? double.infinity,
        );
        final XmlElement group = XmlDocument.parse(styled.source)
            .findAllElements('g')
            .firstWhere(
              (XmlElement g) => g.getAttribute('aria-label') == 'Force = 12 N',
            );
        double top = double.infinity;
        double bottom = double.negativeInfinity;
        for (final XmlElement path in group.findAllElements('path')) {
          final List<double> numbers = RegExp(r'-?\d+(?:\.\d+)?')
              .allMatches(path.getAttribute('d')!)
              .map((Match m) => double.parse(m[0]!))
              .toList();
          for (int k = 1; k < numbers.length; k += 2) {
            top = math.min(top, numbers[k]);
            bottom = math.max(bottom, numbers[k]);
          }
        }
        return bottom - top;
      }

      expect(height(12), closeTo(height(null) / 2, height(null) * 0.05));
    });

    test('lays out LaTeX in SVG text in the configured handwriting', () {
      final EditableSvg vector = EditableSvg.parse(
        _source.replaceFirst('Force = 12 N', r'$\frac{a}{b} + x^2$'),
        modelResponse: true,
      );
      final EditableSvg normal = SvgNotationStyler.apply(
        vector,
        handwriting: HandwritingStyle.standard,
        defaultInk: red,
        penWidth: 4,
      );
      final EditableSvg cursive = SvgNotationStyler.apply(
        vector,
        handwriting: HandwritingFont.cursive.style!,
        defaultInk: red,
        penWidth: 4,
      );

      expect(normal.source, isNot(contains('<text')));
      expect(normal.source, contains(r'aria-label="$\frac{a}{b} + x^2$"'));
      // The fraction bar and the letters are all separate strokes.
      expect('<path'.allMatches(normal.source).length, greaterThan(6));
      expect(cursive.source, isNot(normal.source));
    });

    test('lays out simple delimited and bare model LaTeX', () {
      EditableSvg style(String text) => SvgNotationStyler.apply(
        EditableSvg.parse(
          _source.replaceFirst('Force = 12 N', text),
          modelResponse: true,
        ),
        handwriting: HandwritingStyle.standard,
        defaultInk: red,
        penWidth: 3,
      );

      final EditableSvg plain = style('x = 42');
      final EditableSvg simple = style(r'$x = 42$');
      final EditableSvg bare = style(r'\frac{1}{2}x');

      int paths(EditableSvg svg) =>
          XmlDocument.parse(svg.source).findAllElements('path').length;
      // The dollar delimiters guide layout; they are not handwritten.
      expect(paths(simple), paths(plain));
      expect(simple.source, contains(r'aria-label="$x = 42$"'));
      // Bare LaTeX is repaired and produces fraction strokes instead of
      // rejecting the complete annotation.
      expect(paths(bare), greaterThan(3));
      expect(bare.source, contains(r'aria-label="\frac{1}{2}x"'));
    });

    test('semantic inks follow light and dark note themes', () {
      final EditableSvg styled = SvgNotationStyler.apply(
        EditableSvg.parse(_source, modelResponse: true),
        handwriting: HandwritingStyle.standard,
        defaultInk: red,
        penWidth: 3,
      );

      final String light = styled.frame(
        styled.stepCount,
        brightness: Brightness.light,
      );
      final String dark = styled.frame(
        styled.stepCount,
        brightness: Brightness.dark,
      );
      expect(light.toLowerCase(), contains('#c62f2f'));
      expect(dark.toLowerCase(), contains('#ff8a80'));
      expect(light.toLowerCase(), contains('#1f5fd1'));
      expect(dark.toLowerCase(), contains('#7fa8ff'));
    });

    test('declared bounds grow to hold the handwriting that replaced text', () {
      final EditableSvg vector = EditableSvg.parse(
        _source.replaceFirst('Force = 12 N', 'Force = 12 N at the pivot point'),
        modelResponse: true,
      );
      final EditableSvg styled = SvgNotationStyler.apply(
        vector,
        handwriting: HandwritingStyle.standard,
        defaultInk: red,
        penWidth: 4,
      );
      final Rect paper = styled.viewBox.inflate(0.01);
      expect(
        styled.contentBounds.right,
        greaterThan(vector.contentBounds.right),
      );
      expect(styled.contentBounds.left, lessThanOrEqualTo(60));
      expect(paper.contains(styled.contentBounds.topLeft), isTrue);
      expect(paper.contains(styled.contentBounds.bottomRight), isTrue);
      // Cropping keeps every written stroke inside the frame.
      expect(styled.croppedToContent().viewBox, styled.contentBounds);
    });

    test('text near the right edge is slid back onto the paper', () {
      final EditableSvg vector = EditableSvg.parse(
        _source.replaceFirst('x="60"', 'x="380"'),
        modelResponse: true,
      );
      final EditableSvg styled = SvgNotationStyler.apply(
        vector,
        handwriting: HandwritingStyle.standard,
        defaultInk: red,
        penWidth: 4,
      );
      expect(styled.contentBounds.right, lessThanOrEqualTo(400));
      expect(styled.contentBounds.left, greaterThanOrEqualTo(0));
    });

    test('loose ends join the user ink and the bounds follow', () {
      final EditableSvg vector = EditableSvg.parse(
        _source.replaceFirst(
          '<path d="M40 130 L260 130" stroke="black" fill="none"/>',
          '<path d="M40 130 L260 130" stroke="black" fill="none"/>'
              '<line x1="300" y1="200" x2="215" y2="196" stroke="black"/>',
        ),
        modelResponse: true,
      );
      final EditableSvg styled = SvgNotationStyler.apply(
        vector,
        handwriting: HandwritingStyle.standard,
        defaultInk: red,
        penWidth: 3,
        snapper: InkSnapper(<List<InkVector>>[
          <InkVector>[const InkVector(210, 190), const InkVector(210, 40)],
        ], reach: 16),
      );
      expect(styled.source, contains('x2="210.0"'));
      expect(styled.source, contains('y2="190.0"'));
      expect(styled.contentBounds.bottom, greaterThanOrEqualTo(200));
    });

    group('space round the ink', () {
      // The user's ink: a word written across the middle of the paper.
      final List<InkVector> word = <InkVector>[
        for (double x = 100; x <= 260; x += 4) InkVector(x, 150),
      ];
      NotationClearance clearance() => NotationClearance(
        pageSize: const Size(400, 300),
        ink: <SpaceStroke>[(points: word, width: 3)],
      );
      EditableSvg style(String body) => SvgNotationStyler.apply(
        EditableSvg.parse(
          '<svg xmlns="http://www.w3.org/2000/svg" data-etonia-version="1" '
          'viewBox="0 0 400 300" data-etonia-bounds="20 20 360 260">'
          '<title>Memo</title>'
          '<desc data-etonia-role="message">Memo.</desc>$body</svg>',
          modelResponse: true,
        ),
        handwriting: HandwritingStyle.standard,
        defaultInk: red,
        penWidth: 2,
        clearance: clearance(),
      );
      double distance(Rect box) =>
          math.max(0, math.max(box.top - 151.5, 148.5 - box.bottom));

      test('a memo written on the user\'s ink is moved clear of it', () {
        final EditableSvg styled = style(
          '<text x="120" y="158" font-size="20">Key step</text>',
        );
        final Rect memo = _inkOf(styled, 'Key step');
        // At least the clearance (0.6 of a 20 size) from the stroke's edge.
        expect(distance(memo), greaterThanOrEqualTo(12 - 1.5));
        // Moved the short way, staying near where the model put it.
        expect((memo.left - 120).abs(), lessThan(40));
      });

      test('a stack of lines moves as one, with its underline', () {
        final EditableSvg styled = style(
          '<text x="120" y="150" font-size="20">Area = 12</text>'
          '<text x="120" y="190" font-size="20">so h = 4</text>'
          '<line x1="120" y1="198" x2="220" y2="198" stroke="black"/>',
        );
        final Rect first = _inkOf(styled, 'Area = 12');
        final Rect second = _inkOf(styled, 'so h = 4');
        expect(distance(first), greaterThanOrEqualTo(12 - 1.5));
        expect(distance(second), greaterThanOrEqualTo(12 - 1.5));
        expect(first.left, closeTo(second.left, 0.5));
        final XmlElement line = XmlDocument.parse(
          styled.source,
        ).findAllElements('line').single;
        expect(line.getAttribute('transform'), startsWith('translate('));
      });

      test('writing already clear of the ink, or pinned, stays put', () {
        final EditableSvg clear = style(
          '<text x="120" y="80" font-size="20">Key step</text>',
        );
        expect(_inkOf(clear, 'Key step').top, closeTo(60, 3));
        final EditableSvg pinned = style(
          '<text x="120" y="158" font-size="20" data-etonia-fixed="1">'
          'Key step</text>',
        );
        expect(_inkOf(pinned, 'Key step').bottom, greaterThan(150));
        expect(_inkOf(pinned, 'Key step').top, lessThan(150));
      });
    });

    group('line spacing', () {
      EditableSvg style(String body) => SvgNotationStyler.apply(
        EditableSvg.parse(
          '<svg xmlns="http://www.w3.org/2000/svg" data-etonia-version="1" '
          'viewBox="0 0 400 300" data-etonia-bounds="20 20 360 260">'
          '<title>Working</title>'
          '<desc data-etonia-role="message">Working.</desc>$body</svg>',
          modelResponse: true,
        ),
        handwriting: HandwritingStyle.standard,
        defaultInk: red,
        penWidth: 2,
      );

      test('crowded lines of working are spaced two sizes apart', () {
        final EditableSvg styled = style(
          '<text x="40" y="60" font-size="20">Force = 12 N</text>'
          '<text x="40" y="80" font-size="20">Mass = 3 kg</text>'
          '<text x="40" y="100" font-size="20">Accel = 4 N</text>',
        );
        final Rect first = _inkOf(styled, 'Force = 12 N');
        final Rect second = _inkOf(styled, 'Mass = 3 kg');
        final Rect third = _inkOf(styled, 'Accel = 4 N');
        expect(second.top - first.top, greaterThanOrEqualTo(1.9 * 20));
        expect(third.top - second.top, greaterThanOrEqualTo(1.9 * 20));
        // The first line stays where the model put it.
        expect(first.top, closeTo(40, 3));
        expect(styled.contentBounds.bottom, greaterThanOrEqualTo(third.bottom));
      });

      test('a fraction pushes the line under it clear', () {
        final EditableSvg styled = style(
          r'<text x="40" y="80" font-size="20">$x = \frac{a + b}{2}$</text>'
          '<text x="40" y="110" font-size="20">Then x = 5</text>',
        );
        final Rect fraction = _inkOf(styled, r'$x = \frac{a + b}{2}$');
        final Rect next = _inkOf(styled, 'Then x = 5');
        expect(next.top - fraction.bottom, greaterThanOrEqualTo(0.5 * 20));
      });

      test('an underline moves with its line', () {
        final EditableSvg styled = style(
          '<text x="40" y="60" font-size="20">Force = 12 N</text>'
          '<text x="40" y="80" font-size="20">Mass = 3 kg</text>'
          '<line x1="40" y1="88" x2="160" y2="88" stroke="black"/>',
        );
        final Rect mass = _inkOf(styled, 'Mass = 3 kg');
        final XmlElement line = XmlDocument.parse(
          styled.source,
        ).findAllElements('line').single;
        final double drop = double.parse(
          RegExp(
            r'translate\(0 ([\d.]+)\)',
          ).firstMatch(line.getAttribute('transform')!)!.group(1)!,
        );
        expect(drop, greaterThan(10));
        // Still just under the line it underlines.
        expect((88 + drop - mass.bottom).abs(), lessThan(8));
      });

      test('lines spaced well, side by side, or pinned stay put', () {
        const String spaced =
            '<text x="40" y="60" font-size="20">Force = 12 N</text>'
            '<text x="40" y="110" font-size="20">Mass = 3 kg</text>'
            '<text x="240" y="64" font-size="20">beside it</text>'
            '<text x="60" y="140" font-size="14">A</text>'
            '<text x="60" y="152" font-size="14">B</text>';
        final EditableSvg styled = style(spaced);
        expect(_inkOf(styled, 'Mass = 3 kg').top, closeTo(90, 3));
        expect(_inkOf(styled, 'beside it').bottom, closeTo(64, 4));
        expect(_inkOf(styled, 'A').bottom, closeTo(140, 3));
        expect(_inkOf(styled, 'B').bottom, closeTo(152, 3));
      });

      test('a stack at the foot of the paper is spaced upward', () {
        final EditableSvg styled = style(
          '<text x="40" y="240" font-size="20">Force = 12 N</text>'
          '<text x="40" y="262" font-size="20">Mass = 3 kg</text>'
          '<text x="40" y="284" font-size="20">Accel = 4 N</text>',
        );
        final Rect first = _inkOf(styled, 'Force = 12 N');
        final Rect second = _inkOf(styled, 'Mass = 3 kg');
        final Rect third = _inkOf(styled, 'Accel = 4 N');
        expect(second.top - first.top, greaterThanOrEqualTo(1.9 * 20));
        expect(third.top - second.top, greaterThanOrEqualTo(1.9 * 20));
        // The bottom line stays where the model put it.
        expect(third.bottom, closeTo(284, 3));
        expect(styled.contentBounds.bottom, lessThanOrEqualTo(300));
      });
    });

    test('rejects labels the configured handwriting cannot represent', () {
      final EditableSvg vector = EditableSvg.parse(
        _source.replaceFirst('Force = 12 N', '日本語'),
        modelResponse: true,
      );
      expect(
        () => SvgNotationStyler.apply(
          vector,
          handwriting: HandwritingStyle.standard,
          defaultInk: InkPalette.ink,
          penWidth: 3,
        ),
        throwsFormatException,
      );
    });
  });
}

/// The box round the handwriting that replaced the text [label].
Rect _inkOf(EditableSvg svg, String label) {
  final XmlElement group = XmlDocument.parse(svg.source)
      .findAllElements('g')
      .firstWhere((XmlElement g) => g.getAttribute('aria-label') == label);
  double left = double.infinity, top = double.infinity;
  double right = double.negativeInfinity, bottom = double.negativeInfinity;
  for (final XmlElement path in group.findAllElements('path')) {
    final List<double> values = <double>[
      for (final RegExpMatch match in RegExp(
        r'-?\d+(?:\.\d+)?',
      ).allMatches(path.getAttribute('d')!))
        double.parse(match.group(0)!),
    ];
    for (int i = 0; i + 1 < values.length; i += 2) {
      left = math.min(left, values[i]);
      right = math.max(right, values[i]);
      top = math.min(top, values[i + 1]);
      bottom = math.max(bottom, values[i + 1]);
    }
  }
  return Rect.fromLTRB(left, top, right, bottom);
}
