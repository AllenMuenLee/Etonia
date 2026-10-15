import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_config.dart';
import 'package:greatnote/features/editor/ai/note_image_renderer.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

Stroke _line() => Stroke.fromPoints(
  style: const StrokeStyle(ink: InkPalette.ink, width: 4),
  points: const <InkVector>[InkVector(10, 20), InkVector(40, 20)],
);

void main() {
  test('renders the full surface with request metadata', () async {
    final NoteImage image = await const NoteImageRenderer().render(
      NoteInkSnapshot.of(
        <Stroke>[_line()],
        logicalSize: const Size(100, 50),
        revision: 7,
        brightness: Brightness.light,
        background: Colors.white,
        focusBounds: const Rect.fromLTRB(10, 10, 50, 30),
      ),
    );

    expect(image.width, 200);
    expect(image.height, 100);
    expect(image.scale, 2);
    expect(image.logicalSize, const Size(100, 50));
    expect(image.revision, 7);
    expect(
      image.normalizedFocusBounds,
      const Rect.fromLTRB(0.1, 0.2, 0.5, 0.6),
    );
    // The ink in the focus, exactly, in note_normalized coordinates.
    expect(image.focusInk, const <List<InkVector>>[
      <InkVector>[InkVector(0.1, 0.4), InkVector(0.4, 0.4)],
    ]);
    final ui.Codec codec = await ui.instantiateImageCodec(image.png);
    final ui.FrameInfo frame = await codec.getNextFrame();
    expect(frame.image.width, 200);
    expect(frame.image.height, 100);
    frame.image.dispose();
    codec.dispose();
  });

  test('overlays a faint coordinate grid unless it is turned off', () async {
    Future<(NoteImage, ByteData)> render(AiImageConfig config) async {
      final NoteImage image = await NoteImageRenderer(config: config).render(
        NoteInkSnapshot.of(
          const <Stroke>[],
          logicalSize: const Size(100, 50),
          revision: 0,
          brightness: Brightness.light,
          background: Colors.white,
        ),
      );
      final ui.Codec codec = await ui.instantiateImageCodec(image.png);
      final ui.FrameInfo frame = await codec.getNextFrame();
      final ByteData bytes = (await frame.image.toByteData())!;
      frame.image.dispose();
      codec.dispose();
      return (image, bytes);
    }

    // In the 200 x 100 image, the x = 0.3 line runs down pixel column 60
    // and the fainter x = 0.35 line down column 70; column 65 lies between
    // them. Row 63 is clear of the horizontal lines, and these columns of
    // the labels along the left edge.
    int red(ByteData bytes, int x, int y) => bytes.getUint8((y * 200 + x) * 4);

    final (NoteImage gridded, ByteData lines) = await render(
      const AiImageConfig(),
    );
    expect(gridded.gridDivisions, 10);
    expect(red(lines, 60, 63), lessThan(255));
    expect(red(lines, 70, 63), lessThan(255));
    expect(red(lines, 70, 63), greaterThan(red(lines, 60, 63)));
    expect(red(lines, 65, 63), 255);

    final (NoteImage plain, ByteData blank) = await render(
      const AiImageConfig(noteGridDivisions: 0),
    );
    expect(plain.gridDivisions, 0);
    expect(red(blank, 60, 63), 255);
  });

  test('a crop reaching past the paper keeps its exact extent', () async {
    // The selected-ink image's padding runs 12 units past the top-left
    // corner. Clamping would break its linear mapping onto the note.
    final NoteImage image = await const NoteImageRenderer().render(
      NoteInkSnapshot.of(
        <Stroke>[_line()],
        logicalSize: const Size(100, 50),
        revision: 0,
        brightness: Brightness.light,
        background: Colors.white,
        focusBounds: const Rect.fromLTRB(-12, -6, 50, 30),
      ),
    );

    expect(
      image.normalizedFocusBounds,
      const Rect.fromLTRB(-0.12, -0.12, 0.5, 0.6),
    );
  });

  test('downscales large surfaces and rejects invalid sizes', () async {
    final NoteImage image = await const NoteImageRenderer().render(
      NoteInkSnapshot.of(
        const <Stroke>[],
        logicalSize: const Size(4000, 2000),
        revision: 0,
        brightness: Brightness.dark,
        background: Colors.black,
      ),
    );
    expect(image.width, 2048);
    expect(image.height, 1024);
    expect(image.scale, closeTo(0.512, 1e-12));

    expect(
      () => const NoteImageRenderer().render(
        NoteInkSnapshot.of(
          const <Stroke>[],
          logicalSize: Size.zero,
          revision: 0,
          brightness: Brightness.light,
          background: Colors.white,
        ),
      ),
      throwsA(isA<NoteImageException>()),
    );
  });

  test('refuses a surface that must shrink below the minimum ratio', () {
    expect(
      () => const NoteImageRenderer(config: AiImageConfig(minPixelRatio: 1))
          .render(
            NoteInkSnapshot.of(
              const <Stroke>[],
              logicalSize: const Size(3000, 100),
              revision: 0,
              brightness: Brightness.light,
              background: Colors.white,
            ),
          ),
      throwsA(
        isA<NoteImageException>().having(
          (NoteImageException error) => error.failure,
          'failure',
          NoteImageFailure.tooLarge,
        ),
      ),
    );
  });
}
