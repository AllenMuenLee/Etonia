import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui';

import 'ink_palette.dart';
import 'ink_sample.dart';
import 'one_euro_smoother.dart';
import 'smoothing_config.dart';

/// Which kind of mark the writing tool makes.
enum WritingStyle {
  pen('Pen'),
  highlighter('Highlighter');

  const WritingStyle(this.label);

  final String label;
}

/// Appearance captured at pointer-down. Later pen changes never touch it.
///
/// [opacity] is applied exactly once, by [resolve]: every painter (the
/// editor's layers, snapshots, thumbnails, selection images) draws the
/// resolved color with ordinary source-over compositing, never pre-blended
/// against the paper.
class StrokeStyle {
  const StrokeStyle({
    required this.ink,
    required this.width,
    this.writing = WritingStyle.pen,
    this.opacity = 1,
  });

  /// The opacity a highlighter mark is drawn at unless configured otherwise.
  static const double defaultHighlighterOpacity = 0.35;

  final InkColor ink;

  /// Logical canvas pixels.
  final double width;

  /// Pen or highlighter. Strokes saved before highlighters existed are pen.
  final WritingStyle writing;

  /// From just above 0 to 1; 1 for a pen.
  final double opacity;

  bool get isHighlighter => writing == WritingStyle.highlighter;

  /// The ink for [brightness], with [opacity] applied.
  Color resolve(Brightness brightness) {
    final Color color = ink.resolve(brightness);
    return opacity >= 1 ? color : color.withValues(alpha: color.a * opacity);
  }

  /// This style at another width, as when a transform scales the stroke.
  StrokeStyle withWidth(double width) {
    return StrokeStyle(
      ink: ink,
      width: width,
      writing: writing,
      opacity: opacity,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is StrokeStyle &&
        other.ink == ink &&
        other.width == width &&
        other.writing == writing &&
        other.opacity == opacity;
  }

  @override
  int get hashCode => Object.hash(ink, width, writing, opacity);
}

/// How a pen stroke's width changes along it: tapered ends and stylus
/// pressure. Captured at pointer-down, like [StrokeStyle].
class StrokeDynamics {
  const StrokeDynamics({this.taper = 0, this.pressure = 0})
    : assert(taper >= 0 && taper <= 1),
      assert(pressure >= 0 && pressure <= 1);

  /// A uniform stroke, as wide as its style from end to end.
  static const StrokeDynamics none = StrokeDynamics();

  /// How sharply the ends narrow, from 0 (round, full width) to 1 (a fine
  /// point).
  final double taper;

  /// How much pressure widens or narrows the line, from 0 (not at all) to
  /// 1. Neutral pressure, and a device that reports none, leave the width
  /// as set.
  final double pressure;

  bool get isNone => taper == 0 && pressure == 0;

  /// The narrowest an end gets, as a fraction of the width.
  double get _tipFraction => 1 - 0.85 * taper;

  /// How far an end narrows over, for a stroke [width] wide.
  double taperLength(double width) => width * (1 + 7 * taper);

  /// The width factor [distance] along a taper [length] long.
  double taperAt(double distance, double length) {
    if (taper == 0 || length <= 0 || distance >= length) {
      return 1;
    }
    final double t = (distance / length).clamp(0.0, 1.0);
    final double eased = t * (2 - t);
    return _tipFraction + (1 - _tipFraction) * eased;
  }

  /// The width factor for a [reading] from 0 to 1; 0.5 is neutral.
  double pressureFactor(double reading) {
    return 1 + pressure * 0.75 * (2 * reading.clamp(0.0, 1.0) - 1);
  }
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
    this.widths,
  });

  /// A stroke through [points], which are used as given: they are never
  /// smoothed. The path is built here, once. [widths], when given, holds a
  /// width factor for each point.
  factory Stroke.fromPoints({
    required StrokeStyle style,
    required List<InkVector> points,
    List<double>? widths,
  }) {
    assert(points.isNotEmpty);
    assert(widths == null || widths.length == points.length);
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
      bounds: extent.bounds(style.width * _widest(widths)),
      widths: widths == null ? null : List<double>.unmodifiable(widths),
    );
  }

  /// The largest width factor, never under 1, so bounds are never smaller
  /// than those of an even stroke.
  static double _widest(List<double>? widths) {
    return widths == null ? 1 : math.max(1, widths.fold<double>(0, math.max));
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

  /// The width at each point, as a factor of [StrokeStyle.width], or null
  /// for a stroke of even width.
  final List<double>? widths;

  /// The filled outline of a stroke of varying width; null for an even
  /// one, which is drawn by stroking [path]. Built when first painted.
  late final Path? outline = widths == null
      ? null
      : buildInkOutline(points, widths!, style.width);

  /// Width factors for [piece], a run of points lying along this stroke in
  /// order, such as a piece left by an erase; null for an even stroke.
  List<double>? widthsAlong(List<InkVector> piece) {
    final List<double>? own = widths;
    if (own == null) {
      return null;
    }
    if (points.length == 1) {
      return List<double>.filled(piece.length, own.first);
    }
    const double tolerance = 1e-3;
    final List<double> result = <double>[];
    int segment = 0;
    for (final InkVector point in piece) {
      double? found;
      for (int j = segment; j < points.length - 1; j++) {
        final InkVector a = points[j];
        final InkVector d = points[j + 1] - a;
        final double lengthSquared = d.dot(d);
        final double t = lengthSquared == 0
            ? 0
            : ((point - a).dot(d) / lengthSquared).clamp(0.0, 1.0);
        if ((a + d * t - point).length <= tolerance) {
          segment = j;
          found = own[j] + (own[j + 1] - own[j]) * t;
          break;
        }
      }
      result.add(found ?? 1);
    }
    return result;
  }
}

/// The filled outline of a polyline whose width changes along it: a disc
/// at each end and at each sharp turn, joined by a quadrilateral along
/// each segment, with the wedges between two segments at a gentler turn
/// filled, so no sliver of paper shows through however far it is zoomed.
/// Every part winds the same way, so the union fills without holes under
/// the nonzero rule.
Path buildInkOutline(
  List<InkVector> points,
  List<double> widths,
  double width,
) {
  final Path path = Path();
  if (points.isEmpty) {
    return path;
  }
  double radius(int i) => width * widths[i] / 2;
  void disc(int i) {
    final InkVector p = points[i];
    path.addOval(Rect.fromCircle(center: Offset(p.x, p.y), radius: radius(i)));
  }

  // A triangle wound clockwise on screen, like the rest, whichever order
  // its corners come in.
  void triangle(InkVector a, InkVector b, InkVector c) {
    final double turn = (b - a).x * (c - a).y - (b - a).y * (c - a).x;
    if (turn == 0) {
      return;
    }
    final (InkVector second, InkVector third) = turn > 0 ? (b, c) : (c, b);
    path
      ..moveTo(a.x, a.y)
      ..lineTo(second.x, second.y)
      ..lineTo(third.x, third.y)
      ..close();
  }

  disc(0);
  // Turns sharper than this get a disc, so the outside of a corner stays
  // round; gentler ones get their wedge filled, its outside a chord too
  // short to see as a facet.
  const double turnCosine = 0.985;
  for (int i = 0; i < points.length - 1; i++) {
    final InkVector a = points[i];
    final InkVector b = points[i + 1];
    final InkVector d = b - a;
    final double length = d.length;
    if (length == 0) {
      continue;
    }
    final InkVector n = d.perpendicular * (1 / length);
    final double ra = radius(i);
    final double rb = radius(i + 1);
    // Clockwise on screen, like addOval.
    final InkVector p0 = a - n * ra;
    final InkVector p1 = b - n * rb;
    final InkVector p2 = b + n * rb;
    final InkVector p3 = a + n * ra;
    path
      ..moveTo(p0.x, p0.y)
      ..lineTo(p1.x, p1.y)
      ..lineTo(p2.x, p2.y)
      ..lineTo(p3.x, p3.y)
      ..close();
    if (i + 2 < points.length) {
      final InkVector next = points[i + 2] - b;
      final double nextLength = next.length;
      if (nextLength > 0 && d.dot(next) / (length * nextLength) < turnCosine) {
        disc(i + 1);
      } else if (nextLength > 0) {
        // The next segment's ends at b; between them and this one's, on
        // the outside of the turn, a wedge reaching in to b.
        final InkVector m = next.perpendicular * (1 / nextLength);
        triangle(b, p1, b - m * rb);
        triangle(b, p2, b + m * rb);
      }
    }
  }
  disc(points.length - 1);
  return path;
}

/// The stroke being drawn. It only ever grows: samples are appended and each
/// one extends the cached path by a single segment.
class ActiveStroke {
  ActiveStroke({
    required this.style,
    required RawInkSample first,
    SmoothingConfig config = const SmoothingConfig(),
    this.dynamics = StrokeDynamics.none,
  }) : _smoother = OneEuroSmoother(config: config) {
    final InkVector origin = _smoother.start(first);
    _rawSamples.add(first);
    _points.add(origin);
    _path.moveTo(origin.x, origin.y);
    _extent = _Extent(origin);
    _pressure = first.pressure ?? _neutralPressure;
    if (!dynamics.isNone) {
      _distances.add(0);
      _pressureFactors.add(dynamics.pressureFactor(_pressure));
      _widths.add(_pressureFactors.last * dynamics.taperAt(0, _taperLength));
    }
  }

  static const double _neutralPressure = 0.5;

  /// How much of each new pressure reading is taken; the rest is the
  /// running value, so a noisy sensor does not make the edge wobble.
  static const double _pressureSmoothing = 0.3;

  final StrokeStyle style;
  final StrokeDynamics dynamics;
  final OneEuroSmoother _smoother;
  final List<RawInkSample> _rawSamples = <RawInkSample>[];
  final List<InkVector> _points = <InkVector>[];
  final Path _path = Path();
  late final _Extent _extent;
  double _length = 0;

  /// Kept only when [dynamics] vary the width, one per point.
  final List<double> _distances = <double>[];
  final List<double> _pressureFactors = <double>[];
  final List<double> _widths = <double>[];
  double _pressure = _neutralPressure;
  Path? _outline;

  double get _taperLength => dynamics.taperLength(style.width);

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

  /// The width factor at each point so far, or null for an even stroke.
  /// The far end is tapered only once the stroke is finished.
  List<double>? get widths =>
      dynamics.isNone ? null : UnmodifiableListView<double>(_widths);

  /// The filled outline so far, for a stroke of varying width.
  Path? get outline {
    if (dynamics.isNone) {
      return null;
    }
    return _outline ??= buildInkOutline(_points, _widths, style.width);
  }

  /// Returns whether the rendered geometry changed.
  bool add(RawInkSample sample) {
    final InkVector? output = _smoother.add(sample);
    if (output == null) {
      return false;
    }
    _rawSamples.add(sample);
    final double? pressure = sample.pressure;
    if (pressure != null) {
      _pressure += (pressure - _pressure) * _pressureSmoothing;
    }
    return _appendPoint(output);
  }

  Stroke finish() {
    _smoother.finish().forEach(_appendPoint);
    final List<double>? widths = dynamics.isNone ? null : _finalWidths();
    return Stroke._(
      style: style,
      source: StrokeSource.input,
      rawSamples: List<RawInkSample>.unmodifiable(_rawSamples),
      points: List<InkVector>.unmodifiable(_points),
      path: _path,
      isDot: isDot,
      bounds: _extent.bounds(style.width * Stroke._widest(widths)),
      widths: widths == null ? null : List<double>.unmodifiable(widths),
    );
  }

  /// Both ends tapered, each over at most 40% of the stroke, so a short
  /// stroke still reaches its full width in the middle.
  List<double> _finalWidths() {
    final double length = math.min(_taperLength, _length * 0.4);
    return <double>[
      for (int i = 0; i < _points.length; i++)
        _pressureFactors[i] *
            dynamics.taperAt(_distances[i], length) *
            dynamics.taperAt(_length - _distances[i], length),
    ];
  }

  bool _appendPoint(InkVector point) {
    if (point == _points.last) {
      return false;
    }
    _length += (point - _points.last).length;
    _points.add(point);
    _path.lineTo(point.x, point.y);
    _extent.add(point);
    if (!dynamics.isNone) {
      _distances.add(_length);
      _pressureFactors.add(dynamics.pressureFactor(_pressure));
      _widths.add(
        _pressureFactors.last * dynamics.taperAt(_length, _taperLength),
      );
      _outline = null;
    }
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
