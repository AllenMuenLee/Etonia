import 'dart:collection';
import 'dart:ui';

import 'ink_palette.dart';
import 'ink_sample.dart';
import 'one_euro_smoother.dart';
import 'smoothing_config.dart';

/// Appearance captured at pointer-down. Later pen changes never touch it.
class StrokeStyle {
  const StrokeStyle({required this.ink, required this.width});

  final InkColor ink;

  /// Logical canvas pixels.
  final double width;
}

/// Where a [Stroke]'s geometry came from.
enum StrokeSource {
  /// Drawn by a pointer and filtered by the smoother.
  input,

  /// Built from points, such as a piece left by an area erase.
  derived,
}

/// A finished, immutable stroke.
///
/// A stroke either comes straight from input, through [ActiveStroke.finish],
/// or is derived from existing points, through [Stroke.fromPoints]. Only an
/// input stroke has [rawSamples]. Raw samples do not map index-for-index
/// onto [points], so a piece cut from a stroke cannot say which samples are
/// its own, and it carries none rather than invented ones.
class Stroke {
  Stroke._({
    required this.style,
    required this.source,
    required this.rawSamples,
    required this.points,
    required this.path,
    required this.isDot,
    required this.bounds,
  });

  /// A stroke through [points], which are used as given: they are never
  /// smoothed. The path is built here, once.
  factory Stroke.fromPoints({
    required StrokeStyle style,
    required List<InkVector> points,
  }) {
    assert(points.isNotEmpty);
    final InkVector origin = points.first;
    final Path path = Path()..moveTo(origin.x, origin.y);
    final _Extent extent = _Extent(origin);
    for (int i = 1; i < points.length; i++) {
      final InkVector point = points[i];
      path.lineTo(point.x, point.y);
      extent.add(point);
    }
    return Stroke._(
      style: style,
      source: StrokeSource.derived,
      rawSamples: const <RawInkSample>[],
      points: List<InkVector>.unmodifiable(points),
      path: path,
      isDot: extent.isDot,
      bounds: extent.bounds(style.width),
    );
  }

  final StrokeStyle style;

  final StrokeSource source;

  /// The unmodified input. Empty unless [source] is [StrokeSource.input].
  final List<RawInkSample> rawSamples;

  /// The filtered polyline that is rendered.
  final List<InkVector> points;

  /// [points] as a path, built once when the stroke was created.
  final Path path;

  /// True when the stroke has no extent and renders as a round dot.
  final bool isDot;

  /// The box around the rendered ink: [points] grown by half the width.
  final Rect bounds;
}

/// The stroke being drawn. It only ever grows: samples are appended and each
/// one extends the cached path by a single segment.
class ActiveStroke {
  ActiveStroke({
    required this.style,
    required RawInkSample first,
    SmoothingConfig config = const SmoothingConfig(),
  }) : _smoother = OneEuroSmoother(config: config) {
    final InkVector origin = _smoother.start(first);
    _rawSamples.add(first);
    _points.add(origin);
    _path.moveTo(origin.x, origin.y);
    _extent = _Extent(origin);
  }

  final StrokeStyle style;
  final OneEuroSmoother _smoother;
  final List<RawInkSample> _rawSamples = <RawInkSample>[];
  final List<InkVector> _points = <InkVector>[];
  final Path _path = Path();
  late final _Extent _extent;
  double _length = 0;

  int get pointCount => _points.length;

  /// The filtered points so far.
  List<InkVector> get points => UnmodifiableListView<InkVector>(_points);

  /// Where the pointer was last reported, which the filtered points may
  /// not have reached yet.
  InkVector get lastRawPosition => _rawSamples.last.position;

  /// Length of the filtered polyline so far.
  double get length => _length;

  InkVector get origin => _points.first;

  InkVector get lastPoint => _points.last;

  Path get path => _path;

  bool get isDot => _extent.isDot;

  /// Returns whether the rendered geometry changed.
  bool add(RawInkSample sample) {
    final InkVector? output = _smoother.add(sample);
    if (output == null) {
      return false;
    }
    _rawSamples.add(sample);
    return _appendPoint(output);
  }

  Stroke finish() {
    _smoother.finish().forEach(_appendPoint);
    return Stroke._(
      style: style,
      source: StrokeSource.input,
      rawSamples: List<RawInkSample>.unmodifiable(_rawSamples),
      points: List<InkVector>.unmodifiable(_points),
      path: _path,
      isDot: isDot,
      bounds: _extent.bounds(style.width),
    );
  }

  bool _appendPoint(InkVector point) {
    if (point == _points.last) {
      return false;
    }
    _length += (point - _points.last).length;
    _points.add(point);
    _path.lineTo(point.x, point.y);
    _extent.add(point);
    return true;
  }
}

/// Running extent of a polyline: its bounding box and how far it strays
/// from its first point.
class _Extent {
  _Extent(this._origin)
    : _minX = _origin.x,
      _maxX = _origin.x,
      _minY = _origin.y,
      _maxY = _origin.y;

  /// Below this extent a stroke is a tap and is drawn as a dot.
  static const double _dotExtent = 0.01;

  final InkVector _origin;
  double _minX;
  double _maxX;
  double _minY;
  double _maxY;
  double _maxDistanceFromOrigin = 0;

  bool get isDot => _maxDistanceFromOrigin < _dotExtent;

  void add(InkVector point) {
    if (point.x < _minX) {
      _minX = point.x;
    } else if (point.x > _maxX) {
      _maxX = point.x;
    }
    if (point.y < _minY) {
      _minY = point.y;
    } else if (point.y > _maxY) {
      _maxY = point.y;
    }
    final double distance = (point - _origin).length;
    if (distance > _maxDistanceFromOrigin) {
      _maxDistanceFromOrigin = distance;
    }
  }

  Rect bounds(double width) {
    final double half = width / 2;
    return Rect.fromLTRB(
      _minX - half,
      _minY - half,
      _maxX + half,
      _maxY + half,
    );
  }
}
