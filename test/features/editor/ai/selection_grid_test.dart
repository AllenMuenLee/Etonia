import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/selection_grid.dart';
import 'package:greatnote/features/editor/ai/selection_image_renderer.dart';

Future<SelectionImage> _solid(int width, int height, ui.Rect bounds) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFF0000),
  );
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(width, height);
  final ByteData? bytes = await image.toByteData(
    format: ui.ImageByteFormat.png,
  );
  image.dispose();
  picture.dispose();
  return SelectionImage(
    png: bytes!.buffer.asUint8List(),
    width: width,
    height: height,
    scale: width / bounds.width,
    logicalBounds: bounds,
  );
}

Future<(ui.Image, ByteData)> _decode(Uint8List png) async {
  final ui.Codec codec = await ui.instantiateImageCodec(png);
  final ui.Image image = (await codec.getNextFrame()).image;
  codec.dispose();
  final ByteData data = (await image.toByteData())!;
  return (image, data);
}

ui.Color _at(ui.Image image, ByteData data, int x, int y) {
  final int i = (y * image.width + x) * 4;
  return ui.Color.fromARGB(
    data.getUint8(i + 3),
    data.getUint8(i),
    data.getUint8(i + 1),
    data.getUint8(i + 2),
  );
}

void main() {
  test('the grid adds a numbered margin round the untouched picture', () async {
    final SelectionImage selection = await _solid(
      300,
      150,
      const ui.Rect.fromLTWH(100, 200, 200, 100),
    );
    final Uint8List png = await const SelectionGridRenderer().render(
      selection,
      const ui.Size(1000, 1000),
    );
    expect(png, isNot(same(selection.png)));
    final (ui.Image image, ByteData data) = await _decode(png);
    addTearDown(image.dispose);

    // A margin on every side for the numbers, the picture in the middle.
    expect(image.width, greaterThan(300));
    expect(image.height, greaterThan(150));
    final int side = (image.width - 300) ~/ 2;
    final int band = (image.height - 150) ~/ 2;
    expect(_at(image, data, 0, 0), const ui.Color(0xFFFFFFFF));
    // Between grid lines the picture is as it was.
    final ui.Color inside = _at(image, data, side + 7, band + 7);
    expect(inside.r, greaterThan(0.9));
    expect(inside.g, lessThan(0.1));
  });

  test('without a note size the picture goes out as it was', () async {
    final SelectionImage selection = await _solid(
      40,
      40,
      const ui.Rect.fromLTWH(0, 0, 40, 40),
    );
    final Uint8List png = await const SelectionGridRenderer().render(
      selection,
      ui.Size.zero,
    );
    expect(png, same(selection.png));
  });

  test('an oversized grid is gently reduced instead of discarded', () async {
    final SelectionImage selection = await _solid(
      600,
      300,
      const ui.Rect.fromLTWH(100, 200, 400, 200),
    );
    final Uint8List full = await const SelectionGridRenderer(
      maxPngBytes: 1000000,
    ).render(selection, const ui.Size(1000, 1000));
    final Uint8List fitted = await const SelectionGridRenderer(
      maxPngBytes: 1000,
    ).render(selection, const ui.Size(1000, 1000));
    final (ui.Image fullImage, _) = await _decode(full);
    final (ui.Image fittedImage, _) = await _decode(fitted);
    addTearDown(fullImage.dispose);
    addTearDown(fittedImage.dispose);

    expect(fitted.lengthInBytes, lessThanOrEqualTo(1000));
    expect(fittedImage.width, lessThan(fullImage.width));
    expect(fittedImage.height, lessThan(fullImage.height));
  });

  test(
    'a grid exceeding maxDimension is scaled down within maxDimension',
    () async {
      final SelectionImage selection = await _solid(
        500,
        300,
        const ui.Rect.fromLTWH(100, 200, 400, 200),
      );
      final Uint8List png = await const SelectionGridRenderer(
        maxDimension: 400,
      ).render(selection, const ui.Size(1000, 1000));
      final (ui.Image image, _) = await _decode(png);
      addTearDown(image.dispose);

      expect(image.width, lessThanOrEqualTo(400));
      expect(image.height, lessThanOrEqualTo(400));
    },
  );
}
