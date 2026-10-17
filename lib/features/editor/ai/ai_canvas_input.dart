import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ink/ink_controller.dart';
import '../ink/ink_sample.dart';
import '../ink/one_euro_smoother.dart';
import '../ink/smoothing_config.dart';

/// Thresholds for writing on the page in AI mode. All lengths are logical
/// canvas pixels.
@immutable
class AiCanvasConfig {
  const AiCanvasConfig({
    this.recognitionDelay = const Duration(milliseconds: 800),
    this.minLoopLength = 160,
    this.minLoopExtent = 56,
    this.loopClosingFraction = 0.2,
    this.maxLoopClosingGap = 64,
    this.minLoopArea = 2400,
    this.minLoopCompactness = 0.2,
    this.minPointSpacing = 0.75,
    this.glowWidth = 3,
    this.recognitionInkWidth = 4,
    this.recognitionPadding = 24,
    this.maxRecognitionDimension = 1600,
    this.minRecognitionScale = 1,
    this.maxRecognitionScale = 3,
  }) : assert(minLoopLength > 0),
       assert(minLoopExtent > 0),
       assert(loopClosingFraction > 0 && loopClosingFraction < 1),
       assert(minLoopCompactness > 0 && minLoopCompactness <= 1),
       assert(maxRecognitionScale >= minRecognitionScale);

  /// How long the pen stays off the screen after a stroke before the
  /// strokes written so far are read as words and go into the chat's
  /// input. A new stroke started sooner joins them.
  final Duration recognitionDelay;

  /// A loop shorter than this, or narrower or shorter than
  /// [minLoopExtent], is writing (an `o`, a `0`, a dot), never a circle.
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

  /// The width of the glowing stroke's bright core.
  final double glowWidth;

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

/// One point of a stroke written in AI mode.
@immutable
class AiCanvasPoint {
  const AiCanvasPoint(this.position, this.timestamp);

  final InkVector position;
  final Duration timestamp;
}

/// A finished stroke written in AI mode. It is never ink: it is not in the
/// document, its history, or what is saved.
@immutable
class AiCanvasStroke {
  AiCanvasStroke(List<AiCanvasPoint> points)
    : points = List<AiCanvasPoint>.unmodifiable(points);

  final List<AiCanvasPoint> points;

  Iterable<InkVector> get positions =>
      points.map((AiCanvasPoint point) => point.position);

  Rect get bounds {
    double left = double.infinity;
    double top = double.infinity;
    double right = double.negativeInfinity;
    double bottom = double.negativeInfinity;
    for (final AiCanvasPoint point in points) {
      left = math.min(left, point.position.x);
      top = math.min(top, point.position.y);
      right = math.max(right, point.position.x);
      bottom = math.max(bottom, point.position.y);
    }
    return points.isEmpty ? Rect.zero : Rect.fromLTRB(left, top, right, bottom);
  }
}

/// Tells a loop drawn around something on the page, to ask about it, from
/// handwriting.
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

/// The stroke being written in AI mode, smoothed as it comes in.
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

/// What is written on the page in AI mode: a glowing stroke that is never
/// ink. A finished stroke either circles a spot, which [onCircle] is asked
/// to take as the assistant's context, or is handwriting: strokes written
/// one soon after another are held together until the pen rests for
/// [AiCanvasConfig.recognitionDelay], then handed to [onHandwriting] as one
/// batch and cleared.
///
/// It notifies only the glow layer that paints it, never the editor.
class AiCanvasInputController extends ChangeNotifier {
  AiCanvasInputController({
    this.config = const AiCanvasConfig(),
    this.smoothing = const SmoothingConfig(),
    this.onCircle,
    this.onHandwriting,
  });

  final AiCanvasConfig config;
  final SmoothingConfig smoothing;

  /// Asked with the outline of a loop drawn on [page], when no handwriting
  /// is waiting. Returns true when it took the loop as context: then the
  /// loop is cleared and is not handwriting.
  bool Function(List<InkVector> outline, InkController page)? onCircle;

  /// Handed each finished batch of handwriting, written on [page].
  /// [openPanel] is false when the batch was cut short by the chat closing.
  void Function(
    List<AiCanvasStroke> strokes,
    InkController page, {
    required bool openPanel,
  })?
  onHandwriting;

  _ActiveAiStroke? _active;
  final List<AiCanvasStroke> _pending = <AiCanvasStroke>[];
  InkController? _page;
  Timer? _timer;
  bool _disposed = false;

  /// The page being written on, if anything is shown.
  InkController? get page => _page;

  /// The pointer writing now, if any.
  int? get activePointer => _active?.pointer;

  /// The stroke being written, as far as it has got.
  List<AiCanvasPoint> get activePoints =>
      _active?.points ?? const <AiCanvasPoint>[];

  /// Finished handwriting waiting to be read.
  List<AiCanvasStroke> get pendingStrokes =>
      List<AiCanvasStroke>.unmodifiable(_pending);

  bool get isEmpty => _active == null && _pending.isEmpty;

  /// Whether a batch is waiting for the pen to rest.
  bool get isWaiting => _timer?.isActive ?? false;

  /// Starts a stroke on [page]. Returns false while another pointer writes.
  bool begin(int pointer, InkController page, RawInkSample sample) {
    if (_disposed || _active != null || !sample.position.isFinite) {
      return false;
    }
    if (_page != null && !identical(_page, page)) {
      // Writing moved to another page: what was written stays together.
      flush();
    }
    _timer?.cancel();
    _timer = null;
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

  /// Ends the stroke [pointer] is writing, and decides what it was.
  void end(int pointer, Iterable<RawInkSample> samples) {
    final _ActiveAiStroke? active = _active;
    if (active == null || active.pointer != pointer) {
      return;
    }
    add(pointer, samples);
    active.finish(
      samples.isEmpty ? active.points.last.timestamp : samples.last.timestamp,
    );
    _active = null;
    final AiCanvasStroke stroke = AiCanvasStroke(active.points);
    final InkController page = _page!;
    if (_pending.isEmpty) {
      final List<InkVector>? outline = AiCanvasGestures.contextLoop(
        stroke.positions.toList(growable: false),
        config,
      );
      if (outline != null && (onCircle?.call(outline, page) ?? false)) {
        if (!_disposed) {
          _page = null;
          notifyListeners();
        }
        return;
      }
    }
    _pending.add(stroke);
    _timer = Timer(config.recognitionDelay, flush);
    notifyListeners();
  }

  /// Drops the stroke [pointer] is writing.
  void cancel(int pointer) {
    if (_active?.pointer == pointer) {
      cancelActive();
    }
  }

  /// Drops the stroke being written, keeping finished handwriting.
  void cancelActive() {
    if (_active == null) {
      return;
    }
    _active = null;
    if (_pending.isEmpty) {
      _page = null;
    } else {
      _timer ??= Timer(config.recognitionDelay, flush);
    }
    notifyListeners();
  }

  /// Hands any waiting handwriting over now, without waiting for the pen
  /// to rest. A stroke still being written is dropped.
  void flush({bool openPanel = true}) {
    _timer?.cancel();
    _timer = null;
    _active = null;
    final InkController? page = _page;
    final List<AiCanvasStroke> strokes = List<AiCanvasStroke>.of(_pending);
    _pending.clear();
    _page = null;
    if (_disposed) {
      return;
    }
    notifyListeners();
    if (strokes.isNotEmpty && page != null) {
      onHandwriting?.call(strokes, page, openPanel: openPanel);
    }
  }

  /// Clears everything written, reading none of it.
  void clear() {
    _timer?.cancel();
    _timer = null;
    final bool hadAny = !isEmpty;
    _active = null;
    _pending.clear();
    _page = null;
    if (hadAny && !_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// Paints what is written in AI mode on [page] as a glowing path: a soft,
/// blurred halo in [color], a translucent aura, and a bright core with
/// round caps and joins. Repaints only when [input] changes.
class AiCanvasStrokePainter extends CustomPainter {
  AiCanvasStrokePainter({
    required this.input,
    required this.page,
    required this.color,
    required this.core,
    this.width = 3,
  }) : super(repaint: input);

  final AiCanvasInputController input;
  final InkController page;
  final Color color;
  final Color core;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    if (!identical(input.page, page)) {
      return;
    }
    final Path path = Path();
    for (final AiCanvasStroke stroke in input.pendingStrokes) {
      _addSmooth(path, stroke.points);
    }
    _addSmooth(path, input.activePoints);
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas
      ..drawPath(
        path,
        paint
          ..color = color.withValues(alpha: 0.45)
          ..strokeWidth = width * 5
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, width * 2.2),
      )
      ..drawPath(
        path,
        paint
          ..color = color.withValues(alpha: 0.55)
          ..strokeWidth = width * 2.2
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, width * 0.6),
      )
      ..drawPath(
        path,
        paint
          ..color = color
          ..strokeWidth = width
          ..maskFilter = null,
      )
      ..drawPath(
        path,
        paint
          ..color = core
          ..strokeWidth = width * 0.45,
      );
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
        oldDelegate.core != core ||
        oldDelegate.width != width;
  }
}
