import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/features/editor/ai/ai_config.dart';
import 'package:greatnote/features/editor/ai/selection_image_renderer.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

import '../../../helpers/ai_fakes.dart';

const Color _white = Color(0xFFFFFFFF);
const Color _black = Color(0xFF000000);
const Color _red = Color(0xFFFF0000);
const Color _blue = Color(0xFF0000FF);

InkColor _ink(String id) {
  return InkPalette.colors.firstWhere((InkColor ink) => ink.id == id);
}

SnapshotStroke _line(
  InkVector from,
  InkVector to, {
  double width = 4,
  Color color = _black,
}) {
  return SnapshotStroke(
    points: <InkVector>[from, to],
    width: width,
    color: color,
    isDot: false,
  );
}

SnapshotStroke _dot(InkVector at, {double width = 10, Color color = _black}) {
  return SnapshotStroke(
    points: <InkVector>[at],
    width: width,
    color: color,
    isDot: true,
  );
}

/// The pixels of a PNG, addressed in the page's logical coordinates.
class _Decoded {
  _Decoded(this._rgba, this.width, this.height, this._image);

  final ByteData _rgba;
  final int width;
  final int height;
  final SelectionImage _image;

  Uint8List get bytes => _rgba.buffer.asUint8List();

  Color pixel(int x, int y) {
    final int offset = (y * width + x) * 4;
    return Color.fromARGB(
      _rgba.getUint8(offset + 3),
      _rgba.getUint8(offset),
      _rgba.getUint8(offset + 1),
      _rgba.getUint8(offset + 2),
    );
  }

  /// The pixel showing the page position ([x], [y]).
  Color at(double x, double y) {
    return pixel(
      ((x - _image.logicalBounds.left) * _image.scale).floor(),
      ((y - _image.logicalBounds.top) * _image.scale).floor(),
    );
  }
}

Future<_Decoded> _decode(SelectionImage image) async {
  final ui.Codec codec = await ui.instantiateImageCodec(image.png);
  final ui.FrameInfo frame = await codec.getNextFrame();
  final ByteData? rgba = await frame.image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );
  final _Decoded decoded = _Decoded(
    rgba!,
    frame.image.width,
    frame.image.height,
    image,
  );
  frame.image.dispose();
  codec.dispose();
  return decoded;
}

Future<Uint8List> _solidPng(Color color) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  ui.Canvas(
    recorder,
  ).drawRect(const Rect.fromLTWH(0, 0, 4, 2), Paint()..color = color);
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(4, 2);
  final ByteData data = (await image.toByteData(
    format: ui.ImageByteFormat.png,
  ))!;
  image.dispose();
  picture.dispose();
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

Matcher _fails(SelectionImageFailure failure) {
  return throwsA(
    isA<SelectionImageException>()
        .having((SelectionImageException e) => e.failure, 'failure', failure)
        .having(
          (SelectionImageException e) => e.message,
          'message',
          isNotEmpty,
        ),
  );
}

void main() {
  const SelectionImageRenderer renderer = SelectionImageRenderer();

  test(
    'a dot becomes a small, finite PNG with the dot in the middle',
    () async {
      final SelectionImage image = await renderer.render(
        SelectionInkSnapshot.fromStrokes(<SnapshotStroke>[
          _dot(const InkVector(50, 50)),
        ]),
      );

      // The disc's 10 px box, plus 12 px on every side, at 3x.
      expect(image.logicalBounds, const Rect.fromLTRB(33, 33, 67, 67));
      expect(image.width, 102);
      expect(image.height, 102);
      expect(image.png.sublist(0, 8), <int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
      ]);
      final _Decoded pixels = await _decode(image);
      expect(pixels.width, 102);
      expect(pixels.height, 102);
      expect(pixels.at(50, 50), isSameColorAs(_black));
      expect(pixels.at(53, 50), isSameColorAs(_black));
      // Round, not square: the corner of the disc's box is paper.
      expect(pixels.at(45.5, 45.5), isSameColorAs(_white));
      expect(pixels.at(34, 34), isSameColorAs(_white));
    },
  );

  test('an image-only selection is cropped and painted', () async {
    final SelectionImage image = await renderer.render(
      SelectionInkSnapshot.fromStrokes(
        const <SnapshotStroke>[],
        bitmaps: <SnapshotBitmap>[
          SnapshotBitmap(
            bytes: await _solidPng(_red),
            bounds: const Rect.fromLTWH(40, 50, 80, 40),
          ),
        ],
      ),
    );
    expect(image.logicalBounds, const Rect.fromLTRB(28, 38, 132, 102));
    expect((await _decode(image)).at(80, 70), _red);
  });

  test('explicit PDF bounds crop a page bitmap without selected ink', () async {
    final SelectionImage image = await renderer.render(
      SelectionInkSnapshot.fromStrokes(
        const <SnapshotStroke>[],
        explicitBounds: const Rect.fromLTWH(40, 50, 80, 40),
        bitmaps: <SnapshotBitmap>[
          SnapshotBitmap(
            bytes: await _solidPng(_red),
            bounds: const Rect.fromLTWH(0, 0, 200, 100),
            affectsCrop: false,
          ),
        ],
      ),
    );

    expect(image.logicalBounds, const Rect.fromLTRB(28, 38, 132, 102));
    expect((await _decode(image)).at(80, 70), _red);
  });

  test('strokes keep their order, colors, widths, and round caps', () async {
    final SelectionImage image = await renderer.render(
      SelectionInkSnapshot.fromStrokes(<SnapshotStroke>[
        _line(
          const InkVector(100, 100),
          const InkVector(200, 100),
          width: 20,
          color: _red,
        ),
        _line(
          const InkVector(150, 60),
          const InkVector(150, 140),
          width: 6,
          color: _blue,
        ),
        _dot(const InkVector(120, 100), width: 8, color: _black),
      ]),
    );
    final _Decoded pixels = await _decode(image);

    // Later strokes are on top where they cross.
    expect(pixels.at(150, 100), isSameColorAs(_blue));
    expect(pixels.at(120, 100), isSameColorAs(_black));
    // Each has its own color and width.
    expect(pixels.at(180, 100), isSameColorAs(_red));
    expect(pixels.at(180, 108), isSameColorAs(_red));
    expect(pixels.at(180, 112), isSameColorAs(_white));
    expect(pixels.at(150, 70), isSameColorAs(_blue));
    expect(pixels.at(155, 70), isSameColorAs(_white));
    // A round cap reaches half the width past the end point, and is cut
    // away at its corners.
    expect(pixels.at(207, 100), isSameColorAs(_red));
    expect(pixels.at(208.5, 108.5), isSameColorAs(_white));
  });

  test('the crop is the ink bounds plus exactly the padding', () async {
    final SnapshotStroke stroke = _line(
      const InkVector(100, 200),
      const InkVector(200, 200),
    );
    final SelectionImage image = await renderer.render(
      SelectionInkSnapshot.fromStrokes(<SnapshotStroke>[stroke]),
    );

    // Ink: 98..202 by 198..202. Padded by 12: 128 by 28, at 3x.
    expect(image.logicalBounds, const Rect.fromLTRB(86, 186, 214, 214));
    expect(image.scale, 3);
    expect(image.width, 384);
    expect(image.height, 84);
    final _Decoded pixels = await _decode(image);
    expect(pixels.at(98.5, 200), isSameColorAs(_black));
    expect(pixels.at(96, 200), isSameColorAs(_white));
    expect(pixels.pixel(0, 0), isSameColorAs(_white));
    expect(pixels.pixel(383, 83), isSameColorAs(_white));

    const SelectionImageRenderer wider = SelectionImageRenderer(
      config: AiImageConfig(padding: 30),
    );
    final SelectionImageLayout layout = wider.layout(
      SelectionInkSnapshot.fromStrokes(<SnapshotStroke>[stroke]),
    );
    expect(layout.logicalBounds, const Rect.fromLTRB(68, 168, 232, 232));
  });

  test('unselected ink and selection chrome are left out', () async {
    final InkController controller = InkController(
      strokes: <Stroke>[
        Stroke.fromPoints(
          style: const StrokeStyle(ink: InkPalette.ink, width: 4),
          points: const <InkVector>[InkVector(100, 100), InkVector(200, 100)],
        ),
        // Runs straight through the crop, but stays outside the lasso.
        Stroke.fromPoints(
          style: StrokeStyle(ink: _ink('red'), width: 8),
          points: const <InkVector>[InkVector(150, 0), InkVector(150, 600)],
        ),
        Stroke.fromPoints(
          style: StrokeStyle(ink: _ink('blue'), width: 4),
          points: const <InkVector>[InkVector(100, 140), InkVector(200, 140)],
        ),
      ],
    );
    addTearDown(controller.dispose);
    // Two rectangles, added up by hand: the lasso must miss the red line.
    controller
      ..beginLasso(pointer: 1, position: const InkVector(90, 90))
      ..updateLasso(1, const InkVector(140, 90))
      ..updateLasso(1, const InkVector(140, 150))
      ..updateLasso(1, const InkVector(90, 150))
      ..endLasso(1, const InkVector(90, 90));
    expect(controller.selection!.indices, <int>[0, 2]);
    final List<Stroke> before = List<Stroke>.of(controller.strokes);

    final SelectionInkSnapshot snapshot = SelectionInkSnapshot.of(
      controller.selection!,
      brightness: Brightness.light,
      background: AppColors.light.writingSurface,
    );
    final SelectionImage image = await renderer.render(snapshot);
    final _Decoded pixels = await _decode(image);

    expect(image.logicalBounds, const Rect.fromLTRB(86, 86, 214, 154));
    expect(pixels.at(120, 100), isSameColorAs(InkPalette.ink.onLightPaper));
    expect(pixels.at(120, 140), isSameColorAs(_ink('blue').onLightPaper));
    // Where the unselected red line crosses, on the ink and between it.
    expect(pixels.at(150, 120), isSameColorAs(AppColors.light.writingSurface));
    expect(pixels.at(150, 92), isSameColorAs(AppColors.light.writingSurface));
    expect(pixels.at(150, 100), isSameColorAs(InkPalette.ink.onLightPaper));
    // The frame's corners, where the handles sit, its edges, and the
    // rotation handle's stem above it.
    for (final (double x, double y) in <(double, double)>[
      (98, 98),
      (202, 98),
      (202, 142),
      (98, 142),
      (150, 97),
      (97, 120),
      (203, 120),
      (150, 90),
    ]) {
      expect(
        pixels.at(x, y),
        isSameColorAs(AppColors.light.writingSurface),
        reason: '$x, $y',
      );
    }
    // Only paper and the two selected inks, and the blends at their edges:
    // nothing accent-colored, nothing red.
    final Color accent = AppColors.light.accent;
    final Color red = _ink('red').onLightPaper;
    for (int y = 0; y < pixels.height; y++) {
      for (int x = 0; x < pixels.width; x++) {
        final Color pixel = pixels.pixel(x, y);
        expect(pixel, isNot(isSameColorAs(accent)));
        expect(pixel, isNot(isSameColorAs(red)));
        expect(pixel.a, 1);
      }
    }
    // Taking the snapshot and drawing it left the document alone.
    expect(controller.strokes, before);
    expect(controller.selection!.indices, <int>[0, 2]);
  });

  test('the snapshot no longer depends on the editor', () async {
    final InkController controller = InkController(
      strokes: <Stroke>[
        Stroke.fromPoints(
          style: const StrokeStyle(ink: InkPalette.ink, width: 4),
          points: const <InkVector>[InkVector(100, 100), InkVector(200, 100)],
        ),
      ],
    );
    addTearDown(controller.dispose);
    final SelectionInkSnapshot snapshot = SelectionInkSnapshot.of(
      selectInk(controller, const Rect.fromLTRB(90, 90, 210, 110)),
      brightness: Brightness.light,
      background: _white,
    );
    expect(snapshot.isOf(controller.selection!), isTrue);
    final SelectionImageLayout before = renderer.layout(snapshot);

    // Move the ink, then cut it.
    controller
      ..beginSelectionGesture(pointer: 1, position: const InkVector(150, 100))
      ..endSelectionGesture(1, const InkVector(400, 400));
    expect(snapshot.isOf(controller.selection!), isFalse);
    controller.cutSelection();

    expect(snapshot.strokes.single.points, const <InkVector>[
      InkVector(100, 100),
      InkVector(200, 100),
    ]);
    expect(renderer.layout(snapshot).logicalBounds, before.logicalBounds);
    expect(
      () => snapshot.strokes.add(snapshot.strokes.first),
      throwsUnsupportedError,
    );
    expect(
      () => snapshot.strokes.single.points.add(InkVector.zero),
      throwsUnsupportedError,
    );
  });

  for (final (Brightness brightness, AppColors colors)
      in <(Brightness, AppColors)>[
        (Brightness.light, AppColors.light),
        (Brightness.dark, AppColors.dark),
      ]) {
    test('${brightness.name} paper is behind ${brightness.name} ink', () async {
      final InkController controller = InkController(
        strokes: <Stroke>[
          Stroke.fromPoints(
            style: const StrokeStyle(ink: InkPalette.ink, width: 6),
            points: const <InkVector>[InkVector(40, 40), InkVector(140, 40)],
          ),
        ],
      );
      addTearDown(controller.dispose);
      final SelectionInkSnapshot snapshot = SelectionInkSnapshot.of(
        selectInk(controller, const Rect.fromLTRB(30, 30, 150, 50)),
        brightness: brightness,
        // Translucent on purpose: the image must come out opaque.
        background: colors.writingSurface.withValues(alpha: 0.5),
      );
      final _Decoded pixels = await _decode(await renderer.render(snapshot));

      expect(snapshot.brightness, brightness);
      expect(snapshot.background, isSameColorAs(colors.writingSurface));
      expect(pixels.pixel(0, 0), isSameColorAs(colors.writingSurface));
      expect(
        pixels.at(90, 40),
        isSameColorAs(InkPalette.ink.resolve(brightness)),
      );
    });
  }

  test('a large selection is shrunk to fit 2048 pixels', () async {
    final SelectionImage image = await renderer.render(
      SelectionInkSnapshot.fromStrokes(<SnapshotStroke>[
        _line(
          const InkVector(0, 0),
          const InkVector(5000, 1000),
          width: 20,
          color: _red,
        ),
      ]),
    );

    // 5044 by 1044 logical pixels.
    expect(image.width, 2048);
    expect(image.height, lessThanOrEqualTo(2048));
    expect(image.scale, closeTo(2048 / 5044, 1e-9));
    expect(image.height, (1044 * image.scale).ceil());
    expect(image.width / image.height, closeTo(5044 / 1044, 0.02));
    final _Decoded pixels = await _decode(image);
    expect(pixels.width, 2048);
    expect(pixels.at(2500, 500), isSameColorAs(_red));

    // Tall selections are limited the same way.
    final SelectionImageLayout tall = renderer.layout(
      SelectionInkSnapshot.fromStrokes(<SnapshotStroke>[
        _line(const InkVector(0, 0), const InkVector(100, 9000)),
      ]),
    );
    expect(tall.height, 2048);
    expect(tall.width, lessThan(2048));
  });

  test('a small selection is drawn at 3x and no more', () async {
    final SelectionImage image = await renderer.render(
      SelectionInkSnapshot.fromStrokes(<SnapshotStroke>[
        _dot(const InkVector(5, 5), width: 1),
      ]),
    );

    expect(image.scale, 3);
    expect(image.width, 75);
    expect(image.height, 75);
  });

  test('geometry that cannot be drawn fails before anything is allocated', () {
    int images = 0;
    final SelectionImageRenderer counting = SelectionImageRenderer(
      debugOnImage: (ui.Image _) => images++,
    );
    final Map<SelectionInkSnapshot, SelectionImageFailure> cases =
        <SelectionInkSnapshot, SelectionImageFailure>{
          SelectionInkSnapshot.fromStrokes(const <SnapshotStroke>[]):
              SelectionImageFailure.empty,
          SelectionInkSnapshot.fromStrokes(<SnapshotStroke>[
            SnapshotStroke(
              points: const <InkVector>[],
              width: 4,
              color: _black,
              isDot: false,
            ),
          ]): SelectionImageFailure.empty,
          SelectionInkSnapshot.fromStrokes(<SnapshotStroke>[
            _line(const InkVector(0, 0), const InkVector(double.nan, 10)),
          ]): SelectionImageFailure.invalidGeometry,
          SelectionInkSnapshot.fromStrokes(<SnapshotStroke>[
            _line(const InkVector(0, 0), const InkVector(double.infinity, 10)),
          ]): SelectionImageFailure.invalidGeometry,
          SelectionInkSnapshot.fromStrokes(<SnapshotStroke>[
            _dot(const InkVector(0, 0), width: double.infinity),
          ]): SelectionImageFailure.invalidGeometry,
          SelectionInkSnapshot.fromStrokes(<SnapshotStroke>[
            _dot(const InkVector(0, 0), width: 0),
          ]): SelectionImageFailure.invalidGeometry,
          SelectionInkSnapshot.fromStrokes(<SnapshotStroke>[
            _dot(const InkVector(0, 0), width: double.nan),
          ]): SelectionImageFailure.invalidGeometry,
          SelectionInkSnapshot.fromStrokes(<SnapshotStroke>[
            _line(
              const InkVector(-double.maxFinite, 0),
              const InkVector(double.maxFinite, 10),
            ),
          ]): SelectionImageFailure.invalidGeometry,
        };

    for (final MapEntry<SelectionInkSnapshot, SelectionImageFailure> entry
        in cases.entries) {
      expect(() => counting.layout(entry.key), _fails(entry.value));
      expect(counting.render(entry.key), _fails(entry.value));
    }
    final SelectionImageLayout huge = counting.layout(
      SelectionInkSnapshot.fromStrokes(<SnapshotStroke>[
        _line(const InkVector(0, 0), const InkVector(1e9, 1e9)),
      ]),
    );
    expect(huge.width, 2048);
    expect(huge.height, 2048);
    expect(images, 0);
  });

  test('drawing the same snapshot again gives the same image', () async {
    final SelectionInkSnapshot snapshot =
        SelectionInkSnapshot.fromStrokes(<SnapshotStroke>[
          _line(
            const InkVector(10, 10),
            const InkVector(90, 70),
            width: 5,
            color: _blue,
          ),
          _dot(const InkVector(60, 20), color: _red),
        ]);

    final SelectionImage first = await renderer.render(snapshot);
    final SelectionImage second = await renderer.render(snapshot);

    expect(second.width, first.width);
    expect(second.height, first.height);
    expect(second.scale, first.scale);
    expect(second.logicalBounds, first.logicalBounds);
    expect((await _decode(second)).bytes, (await _decode(first)).bytes);
  });

  test('the native image is released once it is encoded', () async {
    final List<ui.Image> images = <ui.Image>[];
    final SelectionImageRenderer tracking = SelectionImageRenderer(
      debugOnImage: images.add,
    );

    final SelectionImage image = await tracking.render(
      SelectionInkSnapshot.fromStrokes(<SnapshotStroke>[
        _dot(const InkVector(50, 50)),
      ]),
    );

    expect(images, hasLength(1));
    expect(images.single.debugDisposed, isTrue);
    // The bytes outlive it.
    expect(image.png, isNotEmpty);
  });
}
