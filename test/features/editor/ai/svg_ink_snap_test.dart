import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ink_attachment.dart';
import 'package:greatnote/features/editor/ai/svg_ink_snap.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:xml/xml.dart';

// The user's triangle, one stroke, with its tip at (200, 100).
final InkSnapper _triangle = InkSnapper(<List<InkVector>>[
  <InkVector>[
    const InkVector(100, 50),
    const InkVector(200, 100),
    const InkVector(100, 150),
    const InkVector(100, 50),
  ],
], reach: 16);

XmlElement _root(String body) => XmlDocument.parse(
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 300">$body</svg>',
).rootElement;

void main() {
  group('SvgInkSnap', () {
    test('a lead that stops short of the tip is joined to it', () {
      final XmlElement root = _root(
        '<line x1="260" y1="100" x2="205" y2="101"/>',
      );
      final moved = SvgInkSnap.apply(root, _triangle);

      final XmlElement line = root.childElements.single;
      expect(line.getAttribute('x2'), '200.0');
      expect(line.getAttribute('y2'), '100.0');
      // The far end is nowhere near the ink and stays.
      expect(line.getAttribute('x1'), '260.0');
      expect(moved, isNotNull);
    });

    test('open paths snap both free ends and keep their curve', () {
      final XmlElement root = _root(
        '<path d="M 96 52 C 120 20 140 20 160 30 L 205 99"/>',
      );
      SvgInkSnap.apply(root, _triangle);

      final String d = root.childElements.single.getAttribute('d')!;
      expect(d, startsWith('M100.0 50.0'));
      expect(d, contains('C120.0 20.0 140.0 20.0 160.0 30.0'));
      expect(d, endsWith('L200.0 100.0'));
    });

    test('polylines snap their ends', () {
      final XmlElement root = _root(
        '<polyline points="300,100 250,102 203,101"/>',
      );
      SvgInkSnap.apply(root, _triangle);
      expect(
        root.childElements.single.getAttribute('points'),
        '300.0,100.0 250.0,102.0 200.0,100.0',
      );
    });

    test('closed, relative, transformed, and defs shapes are left alone', () {
      const String body =
          '<path d="M 205 100 L 260 80 L 260 120 Z"/>'
          '<path d="m 205 100 l 40 0"/>'
          '<line transform="translate(1 1)" x1="300" y1="100" x2="205" y2="100"/>'
          '<defs><line x1="300" y1="100" x2="205" y2="100"/></defs>'
          '<g data-etonia-handwriting="1">'
          '<path d="M 300 100 L 205 100"/></g>';
      final XmlElement root = _root(body);
      final String before = root.toXmlString();

      expect(SvgInkSnap.apply(root, _triangle), isNull);
      expect(root.toXmlString(), before);
    });

    test('a lead is never collapsed to nothing', () {
      final XmlElement root = _root(
        '<line x1="203" y1="100" x2="205" y2="101"/>',
      );
      SvgInkSnap.apply(root, _triangle);
      final XmlElement line = root.childElements.single;
      expect((
        line.getAttribute('x1'),
        line.getAttribute('x2'),
      ), isNot(('200.0', '200.0')));
    });

    test('with no ink nothing moves', () {
      final XmlElement root = _root(
        '<line x1="260" y1="100" x2="205" y2="101"/>',
      );
      expect(
        SvgInkSnap.apply(
          root,
          InkSnapper(const <List<InkVector>>[], reach: 16),
        ),
        isNull,
      );
    });
  });
}
