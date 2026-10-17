import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../ink/ink_sample.dart';
import 'ai_canvas_input.dart';

/// Handwriting written on the page in AI mode, ready to be read: the
/// strokes, with their timing, and the same strokes drawn as dark ink on an
/// opaque white image cropped to them.
@immutable
class HandwritingBatch {
  HandwritingBatch({
    required List<AiCanvasStroke> strokes,
    required this.png,
    required this.pixelSize,
    required this.logicalBounds,
  }) : strokes = List<AiCanvasStroke>.unmodifiable(strokes);

  final List<AiCanvasStroke> strokes;

  /// The strokes drawn for the recognizer. Kept in memory only for the
  /// recognition call.
  final Uint8List png;
  final ui.Size pixelSize;

  /// What [png] shows, in page coordinates, its margin included.
  final ui.Rect logicalBounds;
}

/// Reads handwriting as text, on the device. Injected into the editor so
/// tests can answer without platform channels.
abstract interface class CanvasTextRecognizer {
  /// The words [batch] shows, or an empty string when none could be read or
  /// recognition is unavailable. Never throws.
  Future<String> recognize(HandwritingBatch batch);
}

/// Draws handwriting for a [CanvasTextRecognizer]: dark ink on white,
/// cropped to the union of the strokes plus a margin, scaled up so small
/// writing still has pixels to read.
class HandwritingImageRenderer {
  const HandwritingImageRenderer({this.config = const AiCanvasConfig()});

  final AiCanvasConfig config;

  Future<HandwritingBatch> render(List<AiCanvasStroke> strokes) async {
    ui.Rect? union;
    for (final AiCanvasStroke stroke in strokes) {
      if (stroke.points.isEmpty) continue;
      union = union?.expandToInclude(stroke.bounds) ?? stroke.bounds;
    }
    final ui.Rect bounds = (union ?? ui.Rect.zero).inflate(
      config.recognitionPadding,
    );
    final double longest = math.max(bounds.width, bounds.height);
    final double scale = longest <= 0
        ? config.minRecognitionScale
        : (config.maxRecognitionDimension / longest).clamp(
            config.minRecognitionScale,
            config.maxRecognitionScale,
          );
    final int width = math.max(1, (bounds.width * scale).ceil());
    final int height = math.max(1, (bounds.height * scale).ceil());
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder)
      ..drawRect(
        ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        ui.Paint()..color = const ui.Color(0xFFFFFFFF),
      )
      ..scale(scale)
      ..translate(-bounds.left, -bounds.top);
    final ui.Paint ink = ui.Paint()
      ..color = const ui.Color(0xFF000000)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = config.recognitionInkWidth
      ..strokeCap = ui.StrokeCap.round
      ..strokeJoin = ui.StrokeJoin.round
      ..isAntiAlias = true;
    for (final AiCanvasStroke stroke in strokes) {
      if (stroke.points.isEmpty) continue;
      final ui.Path path = ui.Path();
      final InkVector first = stroke.points.first.position;
      path
        ..moveTo(first.x, first.y)
        ..lineTo(first.x, first.y);
      for (final AiCanvasPoint point in stroke.points.skip(1)) {
        path.lineTo(point.position.x, point.position.y);
      }
      canvas.drawPath(path, ink);
    }
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(width, height);
    picture.dispose();
    try {
      final ByteData? bytes = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      return HandwritingBatch(
        strokes: strokes,
        png: bytes!.buffer.asUint8List(),
        pixelSize: ui.Size(width.toDouble(), height.toDouble()),
        logicalBounds: bounds,
      );
    } finally {
      image.dispose();
    }
  }
}

/// Reads handwriting with the platform's own on-device text recognition:
/// Apple's Vision framework on iPadOS and iOS, Google's ML Kit on Android.
///
/// Only the offscreen image and the stroke points cross the channel. No
/// system text input, Scribble, or stylus handwriting is involved, so the
/// system never draws ink of its own over the page.
class PlatformCanvasTextRecognizer implements CanvasTextRecognizer {
  const PlatformCanvasTextRecognizer();

  static const MethodChannel channel = MethodChannel(
    'com.greatnote.app/handwriting_recognizer',
  );

  @override
  Future<String> recognize(HandwritingBatch batch) async {
    try {
      final String? text = await channel.invokeMethod<String>(
        'recognize',
        <String, Object?>{
          'png': batch.png,
          'width': batch.pixelSize.width.round(),
          'height': batch.pixelSize.height.round(),
          'strokes': <List<double>>[
            for (final AiCanvasStroke stroke in batch.strokes)
              <double>[
                for (final AiCanvasPoint point in stroke.points) ...<double>[
                  point.position.x - batch.logicalBounds.left,
                  point.position.y - batch.logicalBounds.top,
                  point.timestamp.inMicroseconds / 1000,
                ],
              ],
          ],
        },
      );
      return text?.trim() ?? '';
    } on MissingPluginException {
      return '';
    } on PlatformException {
      return '';
    }
  }
}
