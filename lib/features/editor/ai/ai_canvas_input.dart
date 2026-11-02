import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../ink/ink_sample.dart';
import '../ink/one_euro_smoother.dart';
import '../ink/selection_config.dart';
import '../ink/smoothing_config.dart';

/// Thresholds for circling on the page in AI mode, and timing and image
/// thresholds for reading handwriting on the device. All lengths are logical
/// canvas pixels.
@immutable
class AiCanvasConfig {
  const AiCanvasConfig({
    this.recognitionDelay = const Duration(milliseconds: 1200),
    this.minLoopLength = 160,
    this.minLoopExtent = 56,
    this.loopClosingFraction = 0.2,
    this.maxLoopClosingGap = 64,
    this.minLoopArea = 2400,
    this.minLoopCompactness = 0.2,
    this.minPointSpacing = 0.75,
    this.tapSlop = 12,
    this.recognitionInkWidth = 4,
    this.recognitionPadding = 24,
    this.maxRecognitionDimension = 1600,
    this.minRecognitionScale = 1,
    this.maxRecognitionScale = 3,
  }) : assert(minLoopLength > 0),
       assert(minLoopExtent > 0),
       assert(loopClosingFraction > 0 && loopClosingFraction < 1),
       assert(minLoopCompactness > 0 && minLoopCompactness <= 1),
       assert(tapSlop >= 0 && tapSlop < double.infinity),
       assert(maxRecognitionScale >= minRecognitionScale);

  /// How long the pen stays off the page after a stroke before the ink
  /// written so far is read for the handwriting index.
  final Duration recognitionDelay;

  /// A loop shorter than this, or narrower or shorter than
  /// [minLoopExtent], is a stray mark, never a circle.
  final double minLoopLength;
  final double minLoopExtent;

  /// A stroke is closed when its ends come within this fraction of its
  /// length of each other, and within [maxLoopClosingGap]; or when it
  /// crosses itself.
  final double loopClosingFraction;
  final double maxLoopClosingGap;

  /// The least area a loop must enclose, and how round it must be: its
  /// `4 * pi * area / perimeter^2`, 1 for a circle, near 0 for a scribble.
  final double minLoopArea;
  final double minLoopCompactness;

  /// Pointer samples closer than this to the last kept point are dropped.
  final double minPointSpacing;

  /// The largest width and height of a press that still counts as a tap.
  final double tapSlop;

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

/// Tells a loop drawn around something on the page, to ask about it, from a
/// stray mark.
abstract final class AiCanvasGestures {
  /// The outline [points] enclose, when they are a loop drawn to circle a
  /// spot: long and wide enough not to be a letter, closed or crossing
  /// itself, and enclosing a reasonably round region. Null otherwise.
  static List<InkVector>? contextLoop(
    List<InkVector> points, [
    AiCanvasConfig config = const AiCanvasConfig(),
  ]) {
    if (points.length < 4) {
      return null;
    }
    final double length = _length(points);
    if (length < config.minLoopLength) {
      return null;
    }
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
    if (right - left < config.minLoopExtent ||
        bottom - top < config.minLoopExtent) {
      return null;
    }
    final double gap = (points.last - points.first).length;
    final List<InkVector>? outline =
        gap <= config.maxLoopClosingGap &&
            gap <= length * config.loopClosingFraction
        ? points
        : _selfEnclosed(points);
    if (outline == null) {
      return null;
    }
    final double area = _area(outline);
    final double perimeter =
        _length(outline) + (outline.last - outline.first).length;
    if (area < config.minLoopArea || perimeter <= 0) {
      return null;
    }
    final double compactness = 4 * math.pi * area / (perimeter * perimeter);
    return compactness >= config.minLoopCompactness ? outline : null;
  }

  static double _length(List<InkVector> points) {
    double length = 0;
    for (int i = 1; i < points.length; i++) {
      length += (points[i] - points[i - 1]).length;
    }
    return length;
  }

  /// The area of the polygon through [points], closed back to the first.
  static double _area(List<InkVector> points) {
    double twice = 0;
    for (int i = 0, j = points.length - 1; i < points.length; j = i++) {
      twice += points[j].x * points[i].y - points[i].x * points[j].y;
    }
    return twice.abs() / 2;
  }

  /// The loop between the first and the last place the stroke crosses
  /// itself, the largest it encloses; null when it never does.
  static List<InkVector>? _selfEnclosed(List<InkVector> points) {
    List<InkVector>? best;
    double bestArea = 0;
    for (int i = 0; i < points.length - 3; i++) {
      for (int j = points.length - 2; j > i + 1; j--) {
        final InkVector? crossing = _intersection(
          points[i],
          points[i + 1],
          points[j],
          points[j + 1],
        );
        if (crossing == null) {
          continue;
        }
        final List<InkVector> loop = <InkVector>[
          crossing,
          ...points.sublist(i + 1, j + 1),
        ];
        final double area = _area(loop);
        if (area > bestArea) {
          bestArea = area;
          best = loop;
        }
        // The outermost crossing for this start encloses the most.
        break;
      }
    }
    return best;
  }

  static InkVector? _intersection(
    InkVector a,
    InkVector b,
    InkVector c,
    InkVector d,
  ) {
    final InkVector r = b - a;
    final InkVector s = d - c;
    final double denominator = r.x * s.y - r.y * s.x;
    if (denominator.abs() < 1e-9) {
      return null;
    }
    final InkVector ac = c - a;
    final double t = (ac.x * s.y - ac.y * s.x) / denominator;
    final double u = (ac.x * r.y - ac.y * r.x) / denominator;
    if (t < 0 || t > 1 || u < 0 || u > 1) {
      return null;
    }
    return a + r * t;
  }
}

/// The stroke being drawn in AI mode, smoothed as it comes in.
class _ActiveAiStroke {
  _ActiveAiStroke(this.pointer, RawInkSample first, SmoothingConfig smoothing)
    : _smoother = OneEuroSmoother(config: smoothing) {
    points.add(AiCanvasPoint(_smoother.start(first), first.timestamp));
  }

  final int pointer;
  final OneEuroSmoother _smoother;
  final List<AiCanvasPoint> points = <AiCanvasPoint>[];

  bool add(RawInkSample sample, double spacing) {
    final InkVector? next = _smoother.add(sample);
    if (next == null || (next - points.last.position).length < spacing) {
      return false;
    }
    points.add(AiCanvasPoint(next, sample.timestamp));
    return true;
  }

  void finish(Duration timestamp) {
    for (final InkVector point in _smoother.finish()) {
      points.add(AiCanvasPoint(point, timestamp));
    }
  }
}

/// What is drawn on the page in AI mode: a selection lasso that is never ink.
/// A finished stroke that circles a spot is handed to [onCircle], which takes
/// it as the assistant's context. A tap is handed to [onTap], and any other
/// stroke is dropped, for writing in AI mode is not read.
///
/// It notifies only the selection layer that paints it, never the editor.
class AiCanvasInputController extends ChangeNotifier {
  AiCanvasInputController({
    this.config = const AiCanvasConfig(),
    this.smoothing = const SmoothingConfig(),
    this.onCircle,
    this.onTap,
  });

  final AiCanvasConfig config;
  final SmoothingConfig smoothing;

  /// Asked with the outline of a loop drawn on [page].
  void Function(List<InkVector> outline, Object page)? onCircle;

  /// Asked when [page] is tapped rather than circled.
  void Function(InkVector position, Object page)? onTap;

  _ActiveAiStroke? _active;
  Object? _page;
  bool _disposed = false;

  /// The page being drawn on, if anything is shown.
  Object? get page => _page;

  /// The pointer drawing now, if any.
  int? get activePointer => _active?.pointer;

  /// The stroke being drawn, as far as it has got.
  List<AiCanvasPoint> get activePoints =>
      _active?.points ?? const <AiCanvasPoint>[];

  bool get isEmpty => _active == null;

  /// Starts a stroke on [page]. Returns false while another pointer draws.
  bool begin(int pointer, Object page, RawInkSample sample) {
    if (_disposed || _active != null || !sample.position.isFinite) {
      return false;
    }
    _page = page;
    _active = _ActiveAiStroke(pointer, sample, smoothing);
    notifyListeners();
    return true;
  }

  void add(int pointer, Iterable<RawInkSample> samples) {
    final _ActiveAiStroke? active = _active;
    if (active == null || active.pointer != pointer) {
      return;
    }
    bool changed = false;
    for (final RawInkSample sample in samples) {
      changed = active.add(sample, config.minPointSpacing) || changed;
    }
    if (changed) {
      notifyListeners();
    }
  }

  /// Ends the stroke [pointer] is drawing, and hands it over if it circles.
  void end(int pointer, Iterable<RawInkSample> samples) {
    final _ActiveAiStroke? active = _active;
    if (active == null || active.pointer != pointer) {
      return;
    }
    add(pointer, samples);
    active.finish(
      samples.isEmpty ? active.points.last.timestamp : samples.last.timestamp,
    );
    final Object page = _page!;
    _active = null;
    _page = null;
    final List<InkVector>? outline = AiCanvasGestures.contextLoop(
      active.points
          .map((AiCanvasPoint point) => point.position)
          .toList(growable: false),
      config,
    );
    if (_disposed) {
      return;
    }
    notifyListeners();
    if (outline != null) {
      onCircle?.call(outline, page);
    } else if (active.points.isNotEmpty) {
      final Rect bounds = AiCanvasStroke(active.points).bounds;
      if (bounds.width <= config.tapSlop && bounds.height <= config.tapSlop) {
        onTap?.call(active.points.first.position, page);
      }
    }
  }

  /// Drops the stroke [pointer] is drawing.
  void cancel(int pointer) {
    if (_active?.pointer == pointer) {
      clear();
    }
  }

  /// Drops the stroke being drawn.
  void clear() {
    if (_active == null) {
      return;
    }
    _active = null;
    _page = null;
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Paints what is drawn in AI mode on [page] like the ordinary selection
/// lasso: a dashed accent outline, with no neon halo. Repaints only when
/// [input] changes.
class AiCanvasStrokePainter extends CustomPainter {
  AiCanvasStrokePainter({
    required this.input,
    required this.page,
    required this.color,
    this.selectionConfig = const SelectionConfig(),
    this.scale = 1,
    this.scaleProvider,
  }) : super(repaint: input);

  final AiCanvasInputController input;
  final Object page;
  final Color color;
  final SelectionConfig selectionConfig;
  final double scale;
  final double Function()? scaleProvider;

  double get _screenScale {
    final double? dynamicScale = scaleProvider?.call();
    if (dynamicScale != null && dynamicScale > 0 && dynamicScale.isFinite) {
      return dynamicScale;
    }
    return scale > 0 && scale.isFinite ? scale : 1;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (!identical(input.page, page)) {
      return;
    }
    final Path path = Path();
    _addSmooth(path, input.activePoints);
    final double screenScale = _screenScale;
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color
      ..strokeWidth = AppSizes.focusRingWidth / screenScale;
    canvas.drawPath(
      _dashed(
        path,
        selectionConfig.lassoDashLength / screenScale,
        selectionConfig.lassoDashGap / screenScale,
      ),
      paint,
    );
  }

  static Path _dashed(Path source, double dash, double gap) {
    final Path result = Path();
    for (final PathMetric metric in source.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        result.addPath(
          metric.extractPath(
            distance,
            math.min(distance + dash, metric.length),
          ),
          Offset.zero,
        );
        distance += dash + gap;
      }
    }
    return result;
  }

  /// Through the midpoints of [points], curving at each point, so a stroke
  /// of few samples still reads as a smooth line. A single point is a dot.
  static void _addSmooth(Path path, List<AiCanvasPoint> points) {
    if (points.isEmpty) {
      return;
    }
    final InkVector first = points.first.position;
    path.moveTo(first.x, first.y);
    if (points.length == 1) {
      path.lineTo(first.x, first.y);
      return;
    }
    for (int i = 1; i < points.length - 1; i++) {
      final InkVector p = points[i].position;
      final InkVector q = points[i + 1].position;
      path.quadraticBezierTo(p.x, p.y, (p.x + q.x) / 2, (p.y + q.y) / 2);
    }
    final InkVector last = points.last.position;
    path.lineTo(last.x, last.y);
  }

  @override
  bool shouldRepaint(AiCanvasStrokePainter oldDelegate) {
    return oldDelegate.input != input ||
        oldDelegate.page != page ||
        oldDelegate.color != color ||
        oldDelegate.selectionConfig != selectionConfig ||
        oldDelegate.scale != scale ||
        oldDelegate.scaleProvider != scaleProvider;
  }
}
