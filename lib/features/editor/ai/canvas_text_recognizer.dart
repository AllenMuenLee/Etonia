import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../ink/ink_sample.dart';
import 'ai_canvas_input.dart';
import 'handwriting_prediction.dart';

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
    this.context,
  }) : strokes = List<AiCanvasStroke>.unmodifiable(strokes);

  final List<AiCanvasStroke> strokes;

  /// The strokes drawn for the recognizer. Kept in memory only for the
  /// recognition call.
  final Uint8List png;
  final ui.Size pixelSize;

  /// What [png] shows, in page coordinates, its margin included.
  final ui.Rect logicalBounds;

  final HandwritingContext? context;

  HandwritingBatch withContext(HandwritingContext context) => HandwritingBatch(
    strokes: strokes,
    png: png,
    pixelSize: pixelSize,
    logicalBounds: logicalBounds,
    context: context,
  );
}

/// Reads handwriting as text, on the device. Injected into the editor so
/// tests can answer without platform channels.
abstract interface class CanvasTextRecognizer {
  /// The words [batch] shows, or an empty string when none could be read or
  /// recognition is unavailable. Never throws.
  Future<String> recognize(HandwritingBatch batch);
}

@immutable
class RecognizedTextSegment {
  const RecognizedTextSegment(this.text, {this.confidence});

  final String text;
  final double? confidence;
}

/// Optional richer recognizer contract used by persistent handwriting
/// indexing. Existing/test recognizers can keep implementing the string-only
/// interface; their results are searchable but are not trusted for reuse.
abstract interface class DetailedCanvasTextRecognizer
    implements CanvasTextRecognizer {
  Future<List<RecognizedTextSegment>> recognizeDetailed(HandwritingBatch batch);
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
      canvas.drawPath(_smoothPath(stroke.points), ink);
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

  /// Curves through the midpoints of [points], as the glow draws them, so
  /// letters scaled up for the recognizer stay round instead of faceted. A
  /// single point is a dot.
  static ui.Path _smoothPath(List<AiCanvasPoint> points) {
    final InkVector first = points.first.position;
    final ui.Path path = ui.Path()
      ..moveTo(first.x, first.y)
      ..lineTo(first.x, first.y);
    for (int i = 1; i < points.length - 1; i++) {
      final InkVector p = points[i].position;
      final InkVector q = points[i + 1].position;
      path.quadraticBezierTo(p.x, p.y, (p.x + q.x) / 2, (p.y + q.y) / 2);
    }
    if (points.length > 1) {
      final InkVector last = points.last.position;
      path.lineTo(last.x, last.y);
    }
    return path;
  }
}

/// Reads handwriting with the platform's own on-device text recognition:
/// Apple's Vision framework on iPadOS and iOS, Google's ML Kit on Android.
///
/// The offscreen image, stroke points and bounded context hints cross the
/// channel. All recognition and prediction stay on the device. No
/// system text input, Scribble, or stylus handwriting is involved, so the
/// system never draws ink of its own over the page.
class PlatformCanvasTextRecognizer implements DetailedCanvasTextRecognizer {
  const PlatformCanvasTextRecognizer();

  static const MethodChannel channel = MethodChannel(
    'com.etonia.app/handwriting_recognizer',
  );

  @override
  Future<String> recognize(HandwritingBatch batch) async {
    final List<RecognizedTextSegment> segments = await recognizeDetailed(batch);
    return segments.map((RecognizedTextSegment value) => value.text).join(' ');
  }

  @override
  Future<List<RecognizedTextSegment>> recognizeDetailed(
    HandwritingBatch batch,
  ) async {
    try {
      final context = batch.context ?? HandwritingContext();
      final Object? response = await channel.invokeMethod<Object?>(
        'recognize',
        <String, Object?>{
          'png': batch.png,
          'width': batch.pixelSize.width.round(),
          'height': batch.pixelSize.height.round(),
          // The area the strokes were written in, in their own units.
          'logicalWidth': batch.logicalBounds.width,
          'logicalHeight': batch.logicalBounds.height,
          'preContext': context.preContext,
          'customWords': context.customWords,
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
      // String responses are accepted for older native builds and OCR fallback.
      if (response is String) {
        final String text = response.trim();
        return text.isEmpty
            ? const <RecognizedTextSegment>[]
            : <RecognizedTextSegment>[RecognizedTextSegment(text)];
      }
      if (response is! Map<Object?, Object?> ||
          response['segments'] is! List<Object?>) {
        return const <RecognizedTextSegment>[];
      }
      final words = <RecognizedTextSegment>[];
      for (final Object? segment
          in (response['segments'] as List<Object?>).take(64)) {
        if (segment is! List<Object?>) continue;
        final candidates = <HandwritingCandidate>[];
        for (final Object? value in segment.take(5)) {
          if (value is! Map<Object?, Object?> || value['text'] is! String) {
            continue;
          }
          final Object? confidence = value['confidence'];
          candidates.add(
            HandwritingCandidate(
              value['text'] as String,
              confidence:
                  confidence is num &&
                      confidence.isFinite &&
                      confidence >= 0 &&
                      confidence <= 1
                  ? confidence.toDouble()
                  : null,
            ),
          );
        }
        final chosen = const HandwritingPrediction().choose(
          candidates,
          HandwritingContext(
            draft: <String>[
              context.draft,
              ...words.map((RecognizedTextSegment word) => word.text),
            ].join(' '),
            recentMessages: context.recentMessages.reversed,
          ),
        );
        if (chosen.isNotEmpty) {
          final HandwritingCandidate selected = candidates.firstWhere(
            (HandwritingCandidate candidate) => candidate.text.trim() == chosen,
            orElse: () => candidates.first,
          );
          words.add(
            RecognizedTextSegment(chosen, confidence: selected.confidence),
          );
        }
      }
      return words;
    } on MissingPluginException {
      return const <RecognizedTextSegment>[];
    } on PlatformException {
      return const <RecognizedTextSegment>[];
    }
  }
}

/// Reads detailed results when available without widening the long-standing
/// [CanvasTextRecognizer] test/injection contract.
Future<List<RecognizedTextSegment>> recognizeTextSegments(
  CanvasTextRecognizer recognizer,
  HandwritingBatch batch,
) async {
  if (recognizer is DetailedCanvasTextRecognizer) {
    return recognizer.recognizeDetailed(batch);
  }
  final String text = (await recognizer.recognize(batch)).trim();
  return text.isEmpty
      ? const <RecognizedTextSegment>[]
      : <RecognizedTextSegment>[RecognizedTextSegment(text)];
}
