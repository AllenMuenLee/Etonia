import 'dart:math' as math;
import 'dart:ui';

import 'package:path_parsing/path_parsing.dart';
import 'package:xml/xml.dart';

import '../document_io/svg_document.dart';
import '../ink/ink_notation.dart';
import '../ink/ink_palette.dart';
import '../ink/ink_sample.dart';
import '../ink/stroke.dart';

/// Native ink produced from a model-authored SVG.
class SvgInkConversion {
  const SvgInkConversion({required this.traces, this.playbackDuration});

  final List<GeneratedInkTrace> traces;
  final Duration? playbackDuration;
}

/// Turns the line art in a validated AI SVG into ordinary editor strokes.
///
/// Each SVG contour becomes its own [GeneratedInkTrace]. This deliberately
/// targets the small, handwritten line-art SVG vocabulary in the AI prompt;
/// paint-server effects are reduced to their semantic ink color rather than
/// retained as a single unerasable picture.
abstract final class SvgInkConverter {
  static SvgInkConversion convert(
    EditableSvg vector, {
    required InkColor defaultInk,
    required double defaultWidth,
    bool animate = true,
  }) {
    final XmlElement root = XmlDocument.parse(vector.source).rootElement;
    final _Collector collector = _Collector(
      page: vector.viewBox,
      defaultInk: defaultInk,
      defaultWidth: defaultWidth,
      stepCount: animate ? vector.stepCount : 0,
      duration: vector.duration,
    );
    collector.visit(
      root,
      const _Affine.identity(),
      _Presentation.root(defaultInk, defaultWidth),
    );
    if (collector.traces.isEmpty) {
      throw const FormatException('SVG has no editable strokes');
    }
    return SvgInkConversion(
      traces: List<GeneratedInkTrace>.unmodifiable(collector.traces),
      playbackDuration: animate && vector.isAnimated ? vector.duration : null,
    );
  }
}

class _Collector {
  _Collector({
    required this.page,
    required this.defaultInk,
    required this.defaultWidth,
    required this.stepCount,
    required this.duration,
  });

  final Rect page;
  final InkColor defaultInk;
  final double defaultWidth;
  final int stepCount;
  final Duration duration;
  final List<GeneratedInkTrace> traces = <GeneratedInkTrace>[];

  /// Curves are first sampled below a logical pixel, then simplified only
  /// where the resulting polyline stays within this distance of the curve.
  /// The error remains imperceptible even under a deep canvas zoom.
  static const double _sampleSpacing = 0.25;
  static const double _curveTolerance = 0.005;
  static const int _maxSampleSegments = 8191;

  static const Set<String> _nonDrawingTrees = <String>{
    'defs',
    'marker',
    'lineargradient',
    'radialgradient',
    'pattern',
    'clippath',
    'mask',
    'filter',
    'title',
    'desc',
    'metadata',
    'style',
  };

  void visit(
    XmlElement element,
    _Affine parentTransform,
    _Presentation parentPaint,
  ) {
    final String name = element.name.local.toLowerCase();
    if (_nonDrawingTrees.contains(name)) return;
    final _Presentation paint = parentPaint.under(element);
    if (paint.hidden) return;
    final _Affine transform = parentTransform.multiplied(
      _Affine.parse(element.getAttribute('transform')),
    );
    final Path? path = _geometry(element, name);
    if (path != null) {
      _addPath(path, transform, paint, name);
      return;
    }
    for (final XmlElement child in element.childElements) {
      visit(child, transform, paint);
    }
  }

  Path? _geometry(XmlElement element, String name) {
    switch (name) {
      case 'path':
        final String? data = element.getAttribute('d');
        if (data == null || data.trim().isEmpty) return null;
        final Path path = Path();
        try {
          writeSvgPathDataToPath(data, _FlutterPathProxy(path));
        } on Object {
          throw const FormatException('Invalid SVG path');
        }
        return path;
      case 'line':
        return Path()
          ..moveTo(_number(element, 'x1'), _number(element, 'y1'))
          ..lineTo(_number(element, 'x2'), _number(element, 'y2'));
      case 'polyline':
      case 'polygon':
        final List<Offset> points = _points(element.getAttribute('points'));
        if (points.isEmpty) return null;
        final Path path = Path()..moveTo(points.first.dx, points.first.dy);
        for (final Offset point in points.skip(1)) {
          path.lineTo(point.dx, point.dy);
        }
        if (name == 'polygon') path.close();
        return path;
      case 'rect':
        final double x = _number(element, 'x');
        final double y = _number(element, 'y');
        final double width = _number(element, 'width');
        final double height = _number(element, 'height');
        if (width <= 0 || height <= 0) return null;
        final double? rawRx = _optionalNumber(element, 'rx');
        final double? rawRy = _optionalNumber(element, 'ry');
        final double rx = math.max(0, rawRx ?? rawRy ?? 0);
        final double ry = math.max(0, rawRy ?? rawRx ?? 0);
        return Path()..addRRect(
          RRect.fromRectXY(Rect.fromLTWH(x, y, width, height), rx, ry),
        );
      case 'circle':
        final double radius = _number(element, 'r');
        if (radius <= 0) return null;
        return Path()..addOval(
          Rect.fromCircle(
            center: Offset(_number(element, 'cx'), _number(element, 'cy')),
            radius: radius,
          ),
        );
      case 'ellipse':
        final double rx = _number(element, 'rx');
        final double ry = _number(element, 'ry');
        if (rx <= 0 || ry <= 0) return null;
        return Path()..addOval(
          Rect.fromCenter(
            center: Offset(_number(element, 'cx'), _number(element, 'cy')),
            width: rx * 2,
            height: ry * 2,
          ),
        );
      default:
        return null;
    }
  }

  void _addPath(
    Path path,
    _Affine transform,
    _Presentation paint,
    String elementName,
  ) {
    final bool canFill = <String>{
      'path',
      'polygon',
      'rect',
      'circle',
      'ellipse',
    }.contains(elementName);
    final bool useStroke = paint.strokePainted;
    if (!useStroke && !(canFill && paint.fillPainted)) return;

    final String? inkId = useStroke
        ? paint.strokeInk ?? paint.commonInk
        : paint.fillInk ?? paint.commonInk;
    final InkColor ink =
        (inkId == null ? null : InkPalette.byId(inkId)) ?? defaultInk;
    final double opacity =
        (paint.opacity * (useStroke ? paint.strokeOpacity : paint.fillOpacity))
            .clamp(0.01, 1.0);
    // SVG stroke-width is intentionally ignored. AI line art should have the
    // exact same base width as the user's current pen, including through SVG
    // scale transforms.
    final double width = defaultWidth.clamp(0.5, 20.0);
    final double geometryScale = transform.maxScale;
    if (!width.isFinite || geometryScale <= 0) {
      throw const FormatException('Invalid SVG transform');
    }
    final StrokeStyle style = StrokeStyle(
      ink: ink,
      width: width,
      opacity: opacity,
    );
    for (final PathMetric metric in path.computeMetrics()) {
      if (metric.length <= 0 || !metric.length.isFinite) continue;
      final int segments = (metric.length * geometryScale / _sampleSpacing)
          .ceil()
          .clamp(1, _maxSampleSegments);
      final List<InkVector> points = <InkVector>[];
      for (int i = 0; i <= segments; i++) {
        final Tangent? tangent = metric.getTangentForOffset(
          metric.length * i / segments,
        );
        if (tangent == null) continue;
        final Offset point = transform.apply(tangent.position);
        if (!point.dx.isFinite || !point.dy.isFinite) {
          throw const FormatException('Invalid SVG geometry');
        }
        final double half = width / 2;
        if (page.width <= width || page.height <= width) {
          throw const FormatException('SVG stroke leaves the page');
        }
        // Provider curves occasionally overshoot their declared content box
        // by a fraction of a pixel. Clip the native centerline into the
        // writable area instead of rejecting the entire notation for one
        // control-point approximation outside the paper.
        final InkVector next = InkVector(
          point.dx.clamp(page.left + half, page.right - half),
          point.dy.clamp(page.top + half, page.bottom - half),
        );
        if (points.isEmpty || next != points.last) points.add(next);
      }
      if (points.isEmpty) continue;
      final List<InkVector> smooth = _simplify(points, _curveTolerance);
      traces.add(
        GeneratedInkTrace(
          style: style,
          points: smooth,
          timesMs: _times(smooth.length, paint.step),
        ),
      );
    }
  }

  static List<InkVector> _simplify(List<InkVector> points, double tolerance) {
    if (points.length <= 2) return points;
    final List<bool> keep = List<bool>.filled(points.length, false);
    keep[0] = true;
    keep[points.length - 1] = true;
    final List<(int, int)> ranges = <(int, int)>[(0, points.length - 1)];
    final double squaredTolerance = tolerance * tolerance;
    while (ranges.isNotEmpty) {
      final (int first, int last) = ranges.removeLast();
      double farthest = squaredTolerance;
      int index = -1;
      for (int i = first + 1; i < last; i++) {
        final double distance = _squaredDistanceToSegment(
          points[i],
          points[first],
          points[last],
        );
        if (distance > farthest) {
          farthest = distance;
          index = i;
        }
      }
      if (index >= 0) {
        keep[index] = true;
        ranges
          ..add((first, index))
          ..add((index, last));
      }
    }
    return <InkVector>[
      for (int i = 0; i < points.length; i++)
        if (keep[i]) points[i],
    ];
  }

  static double _squaredDistanceToSegment(
    InkVector point,
    InkVector start,
    InkVector end,
  ) {
    final InkVector segment = end - start;
    final double squaredLength = segment.dot(segment);
    final double t = squaredLength == 0
        ? 0
        : ((point - start).dot(segment) / squaredLength).clamp(0.0, 1.0);
    final InkVector delta = point - (start + segment * t);
    return delta.dot(delta);
  }

  List<double>? _times(int count, int? step) {
    if (stepCount == 0) return null;
    if (step == null) return List<double>.filled(count, 0);
    if (step < 1 || step > stepCount) {
      throw const FormatException('Invalid SVG animation step');
    }
    final double total =
        duration.inMicroseconds / Duration.microsecondsPerMillisecond;
    final double start = total * (step - 1) / stepCount;
    final double end = total * step / stepCount;
    if (count == 1) return <double>[end];
    return <double>[
      for (int i = 0; i < count; i++) start + (end - start) * i / (count - 1),
    ];
  }

  static double _number(XmlElement element, String name) =>
      _optionalNumber(element, name) ?? 0;

  static double? _optionalNumber(XmlElement element, String name) {
    final String? source = element.getAttribute(name);
    if (source == null) return null;
    final RegExpMatch? match = RegExp(
      r'^\s*([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?)',
    ).firstMatch(source);
    final double? value = double.tryParse(match?.group(1) ?? '');
    if (value == null || !value.isFinite) {
      throw const FormatException('Invalid SVG number');
    }
    return value;
  }

  static List<Offset> _points(String? source) {
    if (source == null) return const <Offset>[];
    final List<double> values = RegExp(
      r'[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?',
    ).allMatches(source).map((Match match) => double.parse(match[0]!)).toList();
    if (values.length.isOdd) throw const FormatException('Invalid SVG points');
    return <Offset>[
      for (int i = 0; i < values.length; i += 2)
        Offset(values[i], values[i + 1]),
    ];
  }
}

class _FlutterPathProxy implements PathProxy {
  _FlutterPathProxy(this.path);

  final Path path;

  @override
  void moveTo(double x, double y) => path.moveTo(x, y);

  @override
  void lineTo(double x, double y) => path.lineTo(x, y);

  @override
  void cubicTo(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
  ) => path.cubicTo(x1, y1, x2, y2, x3, y3);

  @override
  void close() => path.close();
}

class _Presentation {
  const _Presentation({
    required this.stroke,
    required this.fill,
    required this.strokeWidth,
    required this.opacity,
    required this.strokeOpacity,
    required this.fillOpacity,
    required this.hidden,
    this.commonInk,
    this.strokeInk,
    this.fillInk,
    this.step,
  });

  factory _Presentation.root(InkColor ink, double width) => _Presentation(
    stroke: 'none',
    fill: 'black',
    strokeWidth: width.isFinite ? width.clamp(0.5, 20) : 1,
    opacity: 1,
    strokeOpacity: 1,
    fillOpacity: 1,
    hidden: false,
    commonInk: ink.id,
  );

  final String stroke;
  final String fill;
  final double strokeWidth;
  final double opacity;
  final double strokeOpacity;
  final double fillOpacity;
  final bool hidden;
  final String? commonInk;
  final String? strokeInk;
  final String? fillInk;
  final int? step;

  bool get strokePainted => !_notPainted(stroke) && opacity * strokeOpacity > 0;
  bool get fillPainted => !_notPainted(fill) && opacity * fillOpacity > 0;

  _Presentation under(XmlElement element) {
    final Map<String, String> style = _style(element.getAttribute('style'));
    String? value(String name) => style[name] ?? element.getAttribute(name);
    final String nextStroke = value('stroke') ?? stroke;
    final String nextFill = value('fill') ?? fill;
    final double nextWidth = _length(value('stroke-width')) ?? strokeWidth;
    final double localOpacity = _fraction(value('opacity')) ?? 1;
    final double nextStrokeOpacity =
        _fraction(value('stroke-opacity')) ?? strokeOpacity;
    final double nextFillOpacity =
        _fraction(value('fill-opacity')) ?? fillOpacity;
    final String? nextCommon =
        element.getAttribute('data-etonia-ink') ?? commonInk;
    final int? ownStep = int.tryParse(
      element.getAttribute('data-etonia-step') ?? '',
    );
    final bool explicitlyStatic =
        element.getAttribute('data-etonia-static') == '1';
    final String display = (value('display') ?? '').trim().toLowerCase();
    final String visibility = (value('visibility') ?? '').trim().toLowerCase();
    return _Presentation(
      stroke: nextStroke,
      fill: nextFill,
      strokeWidth: nextWidth,
      opacity: opacity * localOpacity,
      strokeOpacity: nextStrokeOpacity,
      fillOpacity: nextFillOpacity,
      hidden:
          hidden ||
          display == 'none' ||
          visibility == 'hidden' ||
          visibility == 'collapse' ||
          opacity * localOpacity <= 0,
      commonInk: nextCommon,
      strokeInk:
          element.getAttribute('data-etonia-stroke-ink') ??
          (nextCommon != commonInk ? nextCommon : strokeInk),
      fillInk:
          element.getAttribute('data-etonia-fill-ink') ??
          (nextCommon != commonInk ? nextCommon : fillInk),
      step: explicitlyStatic ? null : ownStep ?? step,
    );
  }

  static bool _notPainted(String value) {
    final String paint = value.trim().toLowerCase();
    return paint.isEmpty || paint == 'none' || paint == 'transparent';
  }

  static Map<String, String> _style(String? source) {
    if (source == null) return const <String, String>{};
    final Map<String, String> result = <String, String>{};
    for (final String declaration in source.split(';')) {
      final int colon = declaration.indexOf(':');
      if (colon <= 0) continue;
      result[declaration.substring(0, colon).trim().toLowerCase()] = declaration
          .substring(colon + 1)
          .trim();
    }
    return result;
  }

  static double? _length(String? source) {
    if (source == null) return null;
    final RegExpMatch? match = RegExp(
      r'^\s*([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?)',
    ).firstMatch(source);
    final double? value = double.tryParse(match?.group(1) ?? '');
    return value != null && value.isFinite && value >= 0 ? value : null;
  }

  static double? _fraction(String? source) {
    if (source == null) return null;
    final String value = source.trim();
    final bool percent = value.endsWith('%');
    final double? parsed = double.tryParse(
      percent ? value.substring(0, value.length - 1) : value,
    );
    return parsed == null
        ? null
        : (parsed / (percent ? 100 : 1)).clamp(0.0, 1.0);
  }
}

/// The six values of an SVG 2D affine transform.
class _Affine {
  const _Affine(this.a, this.b, this.c, this.d, this.e, this.f);
  const _Affine.identity() : this(1, 0, 0, 1, 0, 0);

  final double a;
  final double b;
  final double c;
  final double d;
  final double e;
  final double f;

  double get maxScale {
    final double x = math.sqrt(a * a + b * b);
    final double y = math.sqrt(c * c + d * d);
    return math.max(x, y);
  }

  Offset apply(Offset point) =>
      Offset(a * point.dx + c * point.dy + e, b * point.dx + d * point.dy + f);

  _Affine multiplied(_Affine other) => _Affine(
    a * other.a + c * other.b,
    b * other.a + d * other.b,
    a * other.c + c * other.d,
    b * other.c + d * other.d,
    a * other.e + c * other.f + e,
    b * other.e + d * other.f + f,
  );

  static _Affine parse(String? source) {
    if (source == null || source.trim().isEmpty) {
      return const _Affine.identity();
    }
    final RegExp expression = RegExp(r'([A-Za-z]+)\s*\(([^)]*)\)');
    _Affine result = const _Affine.identity();
    int end = 0;
    for (final RegExpMatch match in expression.allMatches(source)) {
      if (source
          .substring(end, match.start)
          .replaceAll(',', '')
          .trim()
          .isNotEmpty) {
        throw const FormatException('Invalid SVG transform');
      }
      end = match.end;
      final String name = match.group(1)!.toLowerCase();
      final List<double> values =
          RegExp(r'[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?')
              .allMatches(match.group(2)!)
              .map((Match m) => double.parse(m[0]!))
              .toList();
      final _Affine operation;
      switch (name) {
        case 'matrix' when values.length == 6:
          operation = _Affine(
            values[0],
            values[1],
            values[2],
            values[3],
            values[4],
            values[5],
          );
        case 'translate' when values.length == 1 || values.length == 2:
          operation = _Affine(
            1,
            0,
            0,
            1,
            values[0],
            values.length == 2 ? values[1] : 0,
          );
        case 'scale' when values.length == 1 || values.length == 2:
          operation = _Affine(
            values[0],
            0,
            0,
            values.length == 2 ? values[1] : values[0],
            0,
            0,
          );
        case 'rotate' when values.length == 1 || values.length == 3:
          final double angle = values[0] * math.pi / 180;
          final _Affine rotation = _Affine(
            math.cos(angle),
            math.sin(angle),
            -math.sin(angle),
            math.cos(angle),
            0,
            0,
          );
          operation = values.length == 1
              ? rotation
              : _Affine(1, 0, 0, 1, values[1], values[2])
                    .multiplied(rotation)
                    .multiplied(_Affine(1, 0, 0, 1, -values[1], -values[2]));
        case 'skewx' when values.length == 1:
          operation = _Affine(
            1,
            0,
            math.tan(values[0] * math.pi / 180),
            1,
            0,
            0,
          );
        case 'skewy' when values.length == 1:
          operation = _Affine(
            1,
            math.tan(values[0] * math.pi / 180),
            0,
            1,
            0,
            0,
          );
        default:
          throw const FormatException('Unsupported SVG transform');
      }
      result = result.multiplied(operation);
    }
    if (source.substring(end).replaceAll(',', '').trim().isNotEmpty) {
      throw const FormatException('Invalid SVG transform');
    }
    return result;
  }
}
