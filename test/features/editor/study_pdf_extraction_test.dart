import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/document_io/document_platform.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart' as pdfrx;

Future<bool> _hasInk(Image image) async {
  final bytes = (await image.toByteData(format: ImageByteFormat.rawRgba))!;
  final pixels = bytes.buffer.asUint8List();
  for (int i = 0; i < pixels.length; i += 4) {
    if (pixels[i] < 100 && pixels[i + 1] < 100 && pixels[i + 2] < 100) {
      return true;
    }
  }
  return false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Uint8List bytes;
  setUpAll(() async {
    await pdfrx.pdfrxInitialize();
    final document = pw.Document();
    document.addPage(pw.Page(build: (_) => pw.Text('Cover')));
    document.addPage(
      pw.Page(build: (_) => pw.Text('Chapter 1 Initial-value problems')),
    );
    document.addPage(
      pw.Page(
        build: (_) =>
            pw.Container(width: 200, height: 200, color: PdfColors.black),
      ),
    );
    bytes = await document.save();
  });

  test('extracts searchable text beyond the initially loaded cover', () async {
    final pages = await const PdfrxRasterizer().extractText(bytes, {1, 2});
    expect(
      pages[1]!.map((run) => run.text).join(' '),
      contains('Initial-value problems'),
    );
    expect(pages[2], isEmpty, reason: 'The drawing page really has no text.');
  });

  test('a byte-backed PDF over one MB opens and extracts text', () async {
    final padded = Uint8List(2 * 1024 * 1024)..setAll(0, bytes);
    final pages = await const PdfrxRasterizer().extractText(padded, {1});
    expect(
      pages[1]!.map((run) => run.text).join(' '),
      contains('Initial-value problems'),
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  test(
    'scan and image render paths load the requested non-cover page',
    () async {
      const rasterizer = PdfrxRasterizer();
      final png = await rasterizer.render(
        bytes,
        2,
        pixelWidth: 200,
        pixelHeight: 300,
      );
      final codec = await instantiateImageCodec(png.png);
      final image = (await codec.getNextFrame()).image;
      codec.dispose();
      try {
        expect(await _hasInk(image), isTrue);
      } finally {
        image.dispose();
      }
      final open = await rasterizer.open(bytes);
      try {
        final rendered = await open.renderImage(
          2,
          pixelWidth: 200,
          pixelHeight: 300,
        );
        try {
          expect(await _hasInk(rendered), isTrue);
        } finally {
          rendered.dispose();
        }
      } finally {
        await open.dispose();
      }
    },
  );
}
