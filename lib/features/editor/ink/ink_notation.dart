import 'ink_sample.dart';
import 'stroke.dart';

/// One already validated, page-local trace to append to the ink document.
class GeneratedInkTrace {
  GeneratedInkTrace({
    required this.style,
    required List<InkVector> points,
    List<double>? timesMs,
    List<double>? widths,
  }) : points = List<InkVector>.unmodifiable(points),
       timesMs = timesMs == null ? null : List<double>.unmodifiable(timesMs),
       widths = widths == null ? null : List<double>.unmodifiable(widths);

  final StrokeStyle style;
  final List<InkVector> points;

  /// For a trace drawn over time, when each of [points] is reached, in
  /// milliseconds from the start of the drawing; never decreasing. Null for
  /// a trace that appears all at once.
  final List<double>? timesMs;

  /// A pen-width factor at each point. AI ink uses a restrained pressure
  /// rhythm so its traces feel drawn rather than mechanically plotted.
  final List<double>? widths;
}

enum AddNotationResult {
  /// Added, and visible at once.
  added,

  /// Added, and being drawn over time: see
  /// [InkController.notationPlayback].
  addedWithPlayback,
  stale,
  busy,
  invalid,
}

/// What one appended notation may hold, once laid out: written text and
/// drawn graphs make many strokes from little input. Bounded, so a
/// notation can never stall the editor.
class GeneratedInkLimits {
  const GeneratedInkLimits({
    this.maxTraces = 3000,
    this.maxPointsPerTrace = 128,
    this.maxTotalPoints = 60000,
    this.minWidth = 0.5,
    this.maxWidth = 20,
    this.maxPlaybackDuration = const Duration(milliseconds: 12000),
  });

  final int maxTraces;
  final int maxPointsPerTrace;
  final int maxTotalPoints;
  final double minWidth;
  final double maxWidth;

  /// The longest a notation may take to draw.
  final Duration maxPlaybackDuration;
}
