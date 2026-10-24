import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ink/ink_sample.dart';

/// Timing and image thresholds for reading handwriting on the device. All
/// lengths are logical canvas pixels.
@immutable
class AiCanvasConfig {
  const AiCanvasConfig({
    this.recognitionDelay = const Duration(milliseconds: 1200),
    this.recognitionInkWidth = 4,
    this.recognitionPadding = 24,
    this.maxRecognitionDimension = 1600,
    this.minRecognitionScale = 1,
    this.maxRecognitionScale = 3,
  }) : assert(maxRecognitionScale >= minRecognitionScale);

  /// How long the pen stays off the page after a stroke before the ink
  /// written so far is read for the handwriting index.
  final Duration recognitionDelay;

  /// How the strokes are drawn for the recognizer: dark ink of this width
  /// on white, with this much margin around them.
  final double recognitionInkWidth;
  final double recognitionPadding;

  /// The longest side of the image handed to the recognizer, and the range
  /// it is scaled within to get there.
  final double maxRecognitionDimension;
  final double minRecognitionScale;
  final double maxRecognitionScale;
}

/// One point of a stroke handed to the recognizer.
@immutable
class AiCanvasPoint {
  const AiCanvasPoint(this.position, this.timestamp);

  final InkVector position;
  final Duration timestamp;
}

/// A finished stroke handed to the recognizer.
@immutable
class AiCanvasStroke {
  AiCanvasStroke(List<AiCanvasPoint> points, {this.screenBounds})
    : points = List<AiCanvasPoint>.unmodifiable(points);

  final List<AiCanvasPoint> points;

  /// Where the stroke was shown on screen, in global coordinates, when it
  /// was finished; null when that was not known.
  final Rect? screenBounds;

  Iterable<InkVector> get positions =>
      points.map((AiCanvasPoint point) => point.position);

  Rect get bounds => _boundsOf(positions);

  static Rect _boundsOf(Iterable<InkVector> points) {
    double left = double.infinity;
    double top = double.infinity;
    double right = double.negativeInfinity;
    double bottom = double.negativeInfinity;
    for (final InkVector point in points) {
      left = math.min(left, point.x);
      top = math.min(top, point.y);
      right = math.max(right, point.x);
      bottom = math.max(bottom, point.y);
    }
    return left.isFinite ? Rect.fromLTRB(left, top, right, bottom) : Rect.zero;
  }
}
