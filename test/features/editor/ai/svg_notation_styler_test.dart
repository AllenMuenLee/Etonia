import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ink_attachment.dart';
import 'package:greatnote/features/editor/ai/svg_notation_styler.dart';
import 'package:greatnote/features/editor/document_io/svg_document.dart';
import 'package:greatnote/features/editor/handwriting/handwriting_fonts.dart';
import 'package:greatnote/features/editor/handwriting/handwriting_style.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';

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
      expect(normal.source, contains('data-etonia-step="1"'));
      expect(normal.message, 'Resolve the force.');
      expect(cursive.source, isNot(normal.source));
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
