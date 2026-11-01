import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/selection_image_renderer.dart';
import 'package:greatnote/features/editor/ai/selection_svg_renderer.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:xml/xml.dart';

void main() {
  test('native selection ink stays vector in page coordinates', () {
    final SelectionInkSnapshot snapshot = SelectionInkSnapshot.fromStrokes(
      <SnapshotStroke>[
        SnapshotStroke(
          points: const <InkVector>[InkVector(20, 30), InkVector(40, 50)],
          width: 3,
          color: const Color(0xFF123456),
          isDot: false,
        ),
        SnapshotStroke(
          points: const <InkVector>[InkVector(60, 70)],
          width: 4,
          color: const Color(0xFFABCDEF),
          isDot: true,
        ),
      ],
    );
    final SelectionImage preview = SelectionImage(
      png: Uint8List.fromList(<int>[1]),
      width: 100,
      height: 80,
      scale: 2,
      logicalBounds: const Rect.fromLTWH(14, 24, 52, 52),
    );

    final String source = const SelectionSvgRenderer().render(
      snapshot: snapshot,
      preview: preview,
      pageSize: const Size(200, 100),
    );
    final XmlElement root = XmlDocument.parse(source).rootElement;

    expect(root.getAttribute('viewBox'), '0 0 200 100');
    expect(root.getAttribute('data-etonia-coordinate-space'), 'note');
    expect(root.getAttribute('data-etonia-selection-bounds'), '14 24 52 52');
    expect(
      root.findAllElements('path').single.getAttribute('d'),
      'M20 30 L40 50',
    );
    expect(
      root.findAllElements('path').single.getAttribute('stroke'),
      '#123456',
    );
    expect(root.findAllElements('circle').single.getAttribute('cx'), '60');
    expect(root.findAllElements('image'), isEmpty);
  });

  test('raster-backed selections embed only the cropped preview', () {
    final SelectionInkSnapshot snapshot = SelectionInkSnapshot.fromStrokes(
      <SnapshotStroke>[
        SnapshotStroke(
          points: const <InkVector>[InkVector(12, 22), InkVector(20, 30)],
          width: 2,
          color: const Color(0xFF112233),
          isDot: false,
        ),
      ],
      explicitBounds: const Rect.fromLTWH(10, 20, 30, 40),
      bitmaps: <SnapshotBitmap>[
        SnapshotBitmap(
          bytes: Uint8List.fromList(<int>[9, 8, 7]),
          bounds: const Rect.fromLTWH(0, 0, 300, 400),
          affectsCrop: false,
        ),
      ],
    );
    final SelectionImage preview = SelectionImage(
      png: Uint8List.fromList(<int>[1, 2, 3, 4]),
      width: 60,
      height: 80,
      scale: 2,
      logicalBounds: const Rect.fromLTWH(10, 20, 30, 40),
    );

    final String source = const SelectionSvgRenderer().render(
      snapshot: snapshot,
      preview: preview,
      pageSize: const Size(300, 400),
    );
    final XmlElement image = XmlDocument.parse(
      source,
    ).rootElement.findAllElements('image').single;

    expect(image.getAttribute('x'), '10');
    expect(image.getAttribute('y'), '20');
    expect(image.getAttribute('width'), '30');
    expect(image.getAttribute('height'), '40');
    expect(image.getAttribute('href'), 'data:image/png;base64,AQIDBA==');
    expect(
      XmlDocument.parse(
        source,
      ).rootElement.findAllElements('path').single.getAttribute('d'),
      'M12 22 L20 30',
    );
    expect(
      source,
      isNot(contains('CQgH')),
    ); // Never embed the full-page source.
  });
}
