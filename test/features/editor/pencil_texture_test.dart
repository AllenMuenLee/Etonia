import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_painter.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/pen_settings.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/library/note_content.dart';

Future<Uint8List> _render(WritingStyle writing) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  final ui.Path path = ui.Path()
    ..moveTo(8, 16)
    ..cubicTo(28, 4, 44, 28, 72, 16);
  paintInkStroke(
    canvas,
    color: const ui.Color(0xFF202020),
    width: 8,
    path: path,
    origin: const InkVector(8, 16),
    isDot: false,
    writing: writing,
  );
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(80, 32);
  picture.dispose();
  final ByteData data = (await image.toByteData(
    format: ui.ImageByteFormat.rawRgba,
  ))!;
  image.dispose();
  return data.buffer.asUint8List();
}

void main() {
  test('pencil settings produce a pencil stroke with pen dynamics', () {
    final PenSettings settings = PenSettings.defaults().copyWith(
      style: WritingStyle.pencil,
      tipSharpness: 0.7,
      pressureSensitivity: 0.6,
    );

    expect(settings.isPencil, isTrue);
    expect(settings.activeInk, settings.ink);
    expect(settings.activeWidth, settings.width);
    expect(settings.strokeStyle().writing, WritingStyle.pencil);
    expect(settings.dynamics.isNone, isFalse);
    expect(settings.armsHoldToShape, isTrue);
  });

  test('a saved pencil keeps its style and variable widths', () {
    final Stroke pencil = Stroke.fromPoints(
      style: const StrokeStyle(
        ink: InkPalette.ink,
        width: 5,
        writing: WritingStyle.pencil,
      ),
      points: const <InkVector>[InkVector(0, 0), InkVector(20, 10)],
      widths: const <double>[0.5, 1.2],
    );

    final Map<String, Object?> json = StoredPage.strokeToJson(pencil);
    final Stroke restored = StoredPage.strokeFromJson(json)!;

    expect(json['style'], 'pencil');
    expect(restored.style, pencil.style);
    expect(restored.widths, pencil.widths);
  });

  test(
    'pencil grain is deterministic and visibly different from pen',
    () async {
      final Uint8List first = await _render(WritingStyle.pencil);
      final Uint8List second = await _render(WritingStyle.pencil);
      final Uint8List pen = await _render(WritingStyle.pen);

      expect(first, orderedEquals(second));
      expect(first, isNot(orderedEquals(pen)));
    },
  );
}
