import 'dart:math' as math;

import '../ai/ai_canvas_input.dart';
import '../ai/canvas_text_recognizer.dart';
import '../ai/handwriting_prediction.dart';
import '../ink/ink_sample.dart';
import '../ink/stroke.dart';
import 'recognized_handwriting.dart';

/// Converts newly committed page ink into searchable words. Recognition is
/// deliberately asynchronous and outside [InkController], so pen latency and
/// undo history are unaffected.
class HandwritingIndexer {
  const HandwritingIndexer({required this.recognizer, required this.renderer});

  final CanvasTextRecognizer recognizer;
  final HandwritingImageRenderer renderer;

  Future<List<RecognizedInkWord>> recognize(
    List<Stroke> strokes, {
    HandwritingContext? context,
    String? stickyId,
  }) async {
    final List<RecognizedInkWord> words = <RecognizedInkWord>[];
    for (final List<Stroke> group in splitIntoWordGroups(strokes)) {
      final List<AiCanvasStroke> canvasStrokes = _canvasStrokes(group);
      final HandwritingBatch rendered =
          recognizer is PlatformCanvasTextRecognizer
          ? renderer.vectors(canvasStrokes)
          : await renderer.render(canvasStrokes);
      final List<RecognizedTextSegment> readings = await recognizeTextSegments(
        recognizer,
        context == null ? rendered : rendered.withContext(context),
      );
      final String text = readings
          .map((RecognizedTextSegment value) => value.text.trim())
          .where((String value) => value.isNotEmpty)
          .join(' ');
      final List<String> alternatives = <String>{
        for (final RecognizedTextSegment reading in readings)
          ...reading.alternatives,
      }.where((String value) => value != text).toList();
      final List<double> confidences = <double>[
        for (final RecognizedTextSegment value in readings)
          if (value.confidence != null) value.confidence!,
      ];
      // Every segment must be confident before the combined strokes can be
      // reused. A partial/legacy result stays searchable only.
      final double? confidence =
          confidences.length == readings.length && confidences.isNotEmpty
          ? confidences.reduce(math.min)
          : null;
      words.add(
        RecognizedInkWord.fromStrokes(
          text: text,
          confidence: confidence,
          alternatives: alternatives,
          strokes: group,
          stickyId: stickyId,
        ),
      );
    }
    return words;
  }

  static List<AiCanvasStroke> _canvasStrokes(List<Stroke> strokes) {
    int syntheticMicros = 0;
    return <AiCanvasStroke>[
      for (final Stroke stroke in strokes)
        AiCanvasStroke(
          stroke.rawSamples.isNotEmpty
              ? <AiCanvasPoint>[
                  for (final sample in stroke.rawSamples)
                    AiCanvasPoint(sample.position, sample.timestamp),
                ]
              : <AiCanvasPoint>[
                  for (final InkVector point in stroke.points)
                    AiCanvasPoint(
                      point,
                      Duration(microseconds: syntheticMicros += 8000),
                    ),
                ],
        ),
    ];
  }
}

/// Splits a burst of pen strokes at clear horizontal or line gaps. Small
/// marks written back over a word (an i-dot or t-cross) remain with it.
List<List<Stroke>> splitIntoWordGroups(List<Stroke> strokes) {
  if (strokes.isEmpty) return const <List<Stroke>>[];
  final List<List<Stroke>> groups = <List<Stroke>>[];
  List<Stroke> current = <Stroke>[];
  var bounds = strokes.first.bounds;
  for (final Stroke stroke in strokes) {
    if (current.isNotEmpty) {
      final double height = math.max(bounds.height, stroke.bounds.height);
      final double horizontalGap = math.max(12, height * 0.32);
      final bool newLine =
          stroke.bounds.top > bounds.bottom + math.max(8, height * 0.35);
      final bool nextWord =
          stroke.bounds.left > bounds.right + horizontalGap &&
          stroke.bounds.top < bounds.bottom + height * 0.5;
      if (newLine || nextWord) {
        groups.add(current);
        current = <Stroke>[];
        bounds = stroke.bounds;
      }
    }
    current.add(stroke);
    bounds = current.length == 1
        ? stroke.bounds
        : bounds.expandToInclude(stroke.bounds);
  }
  if (current.isNotEmpty) groups.add(current);
  return groups;
}
