import 'dart:async';
import 'dart:collection';
import 'dart:ui' show Path, PathMetric, Size;

import 'package:flutter/foundation.dart';

import 'ink_sample.dart';
import 'stroke.dart';

/// How much of a timed trace shows at one moment.
enum TraceRevealState {
  /// Its first point is still to come.
  hidden,

  /// Drawn up to [TraceReveal.tip].
  partial,

  /// All of it.
  complete,
}

/// The part of a timed trace that shows at one moment.
@immutable
class TraceReveal {
  const TraceReveal._(this.state, this.reached, this.tip);

  static const TraceReveal hidden = TraceReveal._(
    TraceRevealState.hidden,
    -1,
    null,
  );
  static const TraceReveal complete = TraceReveal._(
    TraceRevealState.complete,
    -1,
    null,
  );

  final TraceRevealState state;

  /// While [TraceRevealState.partial]: the last point already reached.
  /// Every point up to it shows.
  final int reached;

  /// While [TraceRevealState.partial]: where the pen is now, on the segment
  /// from point [reached] to the next.
  final InkVector? tip;

  @override
  bool operator ==(Object other) {
    return other is TraceReveal &&
        other.state == state &&
        other.reached == reached &&
        other.tip == tip;
  }

  @override
  int get hashCode => Object.hash(state, reached, tip);

  @override
  String toString() => 'TraceReveal(${state.name}, $reached, $tip)';
}

/// What of the trace through [points], reached at [timesMs], shows at
/// [elapsedMs]: nothing before its first time; the points reached so far
/// and the point linearly between the last of them and the next; then all
/// of it, from its last time on. A one-point trace is complete from its
/// time. [timesMs] never decreases.
TraceReveal revealTrace(
  List<InkVector> points,
  List<double> timesMs,
  double elapsedMs,
) {
  assert(points.isNotEmpty && points.length == timesMs.length);
  if (elapsedMs < timesMs.first) {
    return TraceReveal.hidden;
  }
  if (elapsedMs >= timesMs.last) {
    return TraceReveal.complete;
  }
  // The last point reached: times[low] <= elapsed < times[high].
  int low = 0;
  int high = timesMs.length - 1;
  while (high - low > 1) {
    final int middle = (low + high) >> 1;
    if (timesMs[middle] <= elapsedMs) {
      low = middle;
    } else {
      high = middle;
    }
  }
  final double from = timesMs[low];
  final double to = timesMs[high];
  final InkVector a = points[low];
  final InkVector b = points[high];
  return TraceReveal._(
    TraceRevealState.partial,
    low,
    a + (b - a) * ((elapsedMs - from) / (to - from)),
  );
}

/// A notation that has been added to the document and is drawn over time,
/// again and again. Presentation only: the document already holds all of
/// [strokes], and nothing here changes it.
///
/// It refers to the exact stroke instances it added, so it can never hide
/// any other stroke, even one with the same points. A stroke the document
/// replaces with a moved copy is followed to the copy; one it drops is let
/// go and no longer drawn. Made and finished by `InkController`, which owns
/// its clock.
class NotationPlayback {
  NotationPlayback(
    List<Stroke> strokes, {
    required List<List<double>> timesMs,
    required this.duration,
    required this.surfaceSize,
    this._startedAt = Duration.zero,
  }) : assert(strokes.length == timesMs.length),
       _strokes = List<Stroke>.of(strokes),
       _owned = HashSet<Stroke>.identity()..addAll(strokes),
       _times = <Float64List>[
         for (final List<double> times in timesMs) Float64List.fromList(times),
       ],
       _lengths = <Float64List>[
         for (final Stroke stroke in strokes) _cumulativeLengths(stroke.points),
       ],
       _metrics = List<PathMetric?>.filled(strokes.length, null);

  final List<Stroke> _strokes;

  /// The strokes it draws, in document order. Some may have been let go:
  /// see [owns].
  List<Stroke> get strokes => UnmodifiableListView<Stroke>(_strokes);

  /// From the first moment to the end, hold included.
  final Duration duration;

  /// The writing surface's logical size when the notation was added.
  final Size surfaceSize;

  final Set<Stroke> _owned;
  final List<Float64List> _times;

  /// For each stroke, how far along it each of its points lies.
  final List<Float64List> _lengths;

  /// Measured only while a stroke is partly drawn.
  final List<PathMetric?> _metrics;
  int _cachedMetricCount = 0;
  int _peakCachedMetricCount = 0;

  /// The controller's clock when it was added.
  final Duration _startedAt;

  final Completer<void> _done = Completer<void>();
  bool _finished = false;
  Duration _elapsed = Duration.zero;
  Duration _clockElapsed = Duration.zero;

  /// How far into the current loop it is. Wraps to zero at [duration].
  Duration get elapsed => _elapsed;

  /// Total active ticker time, across every loop.
  Duration get clockElapsed => _clockElapsed;

  /// Whether it has stopped for good and its strokes are ordinary ink.
  bool get isFinished => _finished;

  /// Completes once it has been drawn whole for the first time, or once it
  /// is finished, whichever is sooner. It keeps looping after that.
  Future<void> get done => _done.future;

  /// Whether every stroke it drew has left the document.
  bool get isEmpty => _owned.isEmpty;

  /// Lightweight profile instrumentation for the temporary path-measure
  /// cache. It is bounded by [strokes.length] and released as traces finish.
  int get cachedPathMetricCount => _cachedMetricCount;
  int get peakCachedPathMetricCount => _peakCachedMetricCount;

  /// Whether [stroke] is one of [strokes] and is still being drawn here,
  /// rather than by the layer that paints finished ink.
  bool owns(Stroke stroke) => !_finished && _owned.contains(stroke);

  /// When each point of stroke [index] is reached, in milliseconds from the
  /// start of each loop.
  List<double> timesAt(int index) => _times[index];

  /// What of stroke [index] shows now.
  TraceReveal revealAt(int index) {
    return revealTrace(
      _strokes[index].points,
      _times[index],
      _elapsed.inMicroseconds / Duration.microsecondsPerMillisecond,
    );
  }

  /// The path of stroke [index] as far as [reveal], a partial one, has
  /// drawn it: cut from the stroke's own cached path, so it is the same
  /// line. Null while it has no length, when it shows as a dot.
  Path? partialPath(int index, TraceReveal reveal) {
    assert(reveal.state == TraceRevealState.partial);
    final List<InkVector> points = _strokes[index].points;
    final double length =
        _lengths[index][reveal.reached] +
        (reveal.tip! - points[reveal.reached]).length;
    if (length <= 0) {
      return null;
    }
    PathMetric? metric = _metrics[index];
    if (metric == null) {
      metric = _measure(_strokes[index]);
      _metrics[index] = metric;
      if (metric != null) {
        _cachedMetricCount++;
        if (_cachedMetricCount > _peakCachedMetricCount) {
          _peakCachedMetricCount = _cachedMetricCount;
        }
      }
    }
    return metric?.extractPath(0, length);
  }

  /// Lets go of what was measured for stroke [index], once it is complete.
  void releaseMeasure(int index) {
    if (_metrics[index] != null) {
      _metrics[index] = null;
      _cachedMetricCount--;
    }
  }

  /// Moves the total clock on to [elapsed] and derives the phase within the
  /// repeating animation. Only `InkController` calls this, so that the
  /// layers painting the playback hear of it.
  void advanceTo(Duration elapsed) {
    if (elapsed > _clockElapsed) {
      _clockElapsed = elapsed;
      _elapsed = Duration(
        microseconds: elapsed.inMicroseconds % duration.inMicroseconds,
      );
      if (elapsed >= duration && !_done.isCompleted) {
        _done.complete();
      }
    }
  }

  /// [advanceTo] on the controller's [clock], which was at [_startedAt]
  /// when this was added.
  void advanceClockTo(Duration clock) => advanceTo(clock - _startedAt);

  /// Follows [stroke] to [replacement], a copy of it with every point moved,
  /// or lets it go when the copy has a different number of points. Only
  /// `InkController` calls this.
  void replace(Stroke stroke, Stroke? replacement) {
    final int index = _strokes.indexWhere((Stroke s) => identical(s, stroke));
    if (index < 0 || !_owned.remove(stroke)) {
      return;
    }
    releaseMeasure(index);
    if (replacement == null ||
        replacement.points.length != stroke.points.length) {
      return;
    }
    _strokes[index] = replacement;
    _lengths[index] = _cumulativeLengths(replacement.points);
    _owned.add(replacement);
  }

  /// Hands every stroke back to the finished-ink layer. Only
  /// `InkController` calls this, for the same reason as [advanceTo].
  void markFinished() {
    if (_finished) {
      return;
    }
    _finished = true;
    _metrics.fillRange(0, _metrics.length, null);
    _cachedMetricCount = 0;
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  static PathMetric? _measure(Stroke stroke) {
    final Iterator<PathMetric> metrics = stroke.path.computeMetrics().iterator;
    return metrics.moveNext() ? metrics.current : null;
  }

  static Float64List _cumulativeLengths(List<InkVector> points) {
    final Float64List lengths = Float64List(points.length);
    for (int i = 1; i < points.length; i++) {
      lengths[i] = lengths[i - 1] + (points[i] - points[i - 1]).length;
    }
    return lengths;
  }
}
