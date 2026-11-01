import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/note_image_renderer.dart';
import 'package:greatnote/features/editor/ai/selection_image_renderer.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

Stroke _line() => Stroke.fromPoints(
  style: const StrokeStyle(ink: InkPalette.ink, width: 4),
  points: const <InkVector>[InkVector(10, 20), InkVector(40, 20)],
);

/// A [width] by [height] PNG, white but for a black box at [ink].
Future<Uint8List> _page(int width, int height, Rect ink) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  ui.Canvas(recorder)
    ..drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = Colors.white,
    )
    ..drawRect(ink, Paint()..color = Colors.black);
  final ui.Image image = await recorder.endRecording().toImage(width, height);
  final ByteData bytes = (await image.toByteData(
    format: ui.ImageByteFormat.png,
  ))!;
  image.dispose();
  return bytes.buffer.asUint8List();
}

bool _overlaps(Rect a, Rect b) {
  final Rect overlap = a.intersect(b);
  return overlap.width > 0 && overlap.height > 0;
}

void main() {
  test('describes the note with request metadata, and draws nothing', () async {
    final NoteImage note = await const NoteImageRenderer().render(
      NoteInkSnapshot.of(
        <Stroke>[_line()],
        logicalSize: const Size(100, 50),
        revision: 7,
        brightness: Brightness.light,
        background: Colors.white,
        focusBounds: const Rect.fromLTRB(10, 10, 50, 30),
      ),
    );

    expect(note.logicalSize, const Size(100, 50));
    expect(note.revision, 7);
    expect(note.normalizedFocusBounds, const Rect.fromLTRB(0.1, 0.2, 0.5, 0.6));
    // The ink in the focus, exactly, in note_normalized coordinates.
    expect(note.focusInk, const <List<InkVector>>[
      <InkVector>[InkVector(0.1, 0.4), InkVector(0.4, 0.4)],
    ]);
    expect(note.space, isNotNull);
  });

  test('with nothing selected, focuses on the biggest blank area', () async {
    // Ink across the top: the blank space is the rest of the page.
    final Stroke top = Stroke.fromPoints(
      style: const StrokeStyle(ink: InkPalette.ink, width: 4),
      points: const <InkVector>[InkVector(20, 40), InkVector(480, 40)],
    );
    final NoteImage note = await const NoteImageRenderer().render(
      NoteInkSnapshot.of(
        <Stroke>[top],
        logicalSize: const Size(500, 500),
        revision: 0,
        brightness: Brightness.light,
        background: Colors.white,
        focusOnFreeSpace: true,
      ),
    );

    expect(note.focusIsFreeSpace, isTrue);
    expect(note.focusInk, isEmpty);
    final Rect focus = note.space!.focus!;
    expect(focus, note.space!.areas.first.parts.first);
    expect(_overlaps(focus, top.bounds), isFalse);
    expect(
      note.normalizedFocusBounds,
      Rect.fromLTRB(
        focus.left / 500,
        focus.top / 500,
        focus.right / 500,
        focus.bottom / 500,
      ),
    );
  });

  test('without a focus, and not asked to find one, has none', () async {
    final NoteImage note = await const NoteImageRenderer().render(
      NoteInkSnapshot.of(
        <Stroke>[_line()],
        logicalSize: const Size(500, 500),
        revision: 0,
        brightness: Brightness.light,
        background: Colors.white,
      ),
    );

    expect(note.focusIsFreeSpace, isFalse);
    expect(note.normalizedFocusBounds, isNull);
  });

  test('a crop reaching past the paper keeps its exact extent', () async {
    // The selected-ink image's padding runs 12 units past the top-left
    // corner. Clamping would break its linear mapping onto the note.
    final NoteImage note = await const NoteImageRenderer().render(
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
      note.normalizedFocusBounds,
      const Rect.fromLTRB(-0.12, -0.12, 0.5, 0.6),
    );
  });

  test('pictures, sticky notes, and print on a PDF page are not blank, and '
      'what is near the selection is boxed', () async {
    const Rect printed = Rect.fromLTRB(220, 60, 380, 200);
    const Rect picture = Rect.fromLTRB(40, 220, 200, 300);
    final NoteImage note = await const NoteImageRenderer().render(
      NoteInkSnapshot.of(
        <Stroke>[_line()],
        logicalSize: const Size(500, 500),
        revision: 0,
        brightness: Brightness.light,
        background: Colors.white,
        focusBounds: const Rect.fromLTRB(0, 0, 60, 40),
        bitmaps: <SnapshotBitmap>[
          SnapshotBitmap(
            bytes: await _page(500, 500, printed),
            bounds: const Rect.fromLTWH(0, 0, 500, 500),
            affectsCrop: false,
          ),
          // An ordinary picture needs no bytes: its box is taken.
          SnapshotBitmap(bytes: Uint8List(0), bounds: picture),
        ],
      ),
    );

    for (final area in note.space!.areas) {
      for (final Rect part in area.parts) {
        expect(_overlaps(part, printed), isFalse);
        expect(_overlaps(part, picture), isFalse);
      }
    }
    // The print and the picture lie within reach of the selection.
    final List<Rect> nearby = note.space!.nearby;
    expect(nearby.any((Rect box) => _overlaps(box, printed)), isTrue);
    expect(nearby.any((Rect box) => _overlaps(box, picture)), isTrue);
  });

  test('rejects invalid sizes', () {
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
}
