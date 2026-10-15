import 'dart:math' as math;
import 'dart:ui' show Rect, Size;

import '../ink/ink_notation.dart';
import '../ink/ink_palette.dart';
import '../ink/ink_sample.dart';
import '../ink/stroke.dart';
import 'ai_config.dart';
import 'ai_notation.dart';
import 'ink_attachment.dart';
import 'notation_font.dart';
import 'plot_features.dart';

/// Draws a notation: turns each item the model asked for into pen strokes
/// on a note [size] logical pixels big, in the items' order.
///
/// It only lays out. Whether the strokes fit the note, and adding them, is
/// for [InkController.addAiNotation], which takes all of them or none.
/// Throws a [FormatException] for an item that cannot be drawn at all, such
/// as a graph with no point where its formula is defined.
///
/// With a [snapper], the loose ends of lines, open paths, and strokes that
/// nearly reach existing ink are moved onto it.
List<GeneratedInkTrace> layoutNotation(
  AiNotation notation,
  Size size, {
  AiNotationConfig config = const AiNotationConfig(),
  InkSnapper? snapper,
}) {
  return <GeneratedInkTrace>[
    for (final AiNotationItem item in notation.items)
      ..._layoutItem(item, size, config, snapper),
  ];
}

/// [layoutNotation], with every point given the time it is drawn at, from
/// [AiNotation.timeline], which must not be null.
///
/// Each item is drawn between its start and end at an even speed: its
/// strokes one after another, in order, each point reached in proportion to
/// how far along the item's ink it lies. The pen moves between strokes in
/// no time. A dot counts as long as it is wide, so it takes its turn.
List<GeneratedInkTrace> layoutTimedNotation(
  AiNotation notation,
  Size size, {
  AiNotationConfig config = const AiNotationConfig(),
  InkSnapper? snapper,
}) {
  final AiNotationTimeline timeline = notation.timeline!;
  final List<GeneratedInkTrace> timed = <GeneratedInkTrace>[];
  for (int i = 0; i < notation.items.length; i++) {
    final List<GeneratedInkTrace> traces = _layoutItem(
      notation.items[i],
      size,
      config,
      snapper,
    );
    final AiItemTiming timing = timeline.items[i];
    double total = 0;
    for (final GeneratedInkTrace trace in traces) {
      total += _inkLength(trace);
    }
    final double span = (timing.endMs - timing.startMs).toDouble();
    double travelled = 0;
    for (final GeneratedInkTrace trace in traces) {
      final List<InkVector> points = trace.points;
      final List<double> times = <double>[];
      if (points.length == 1) {
        travelled += _inkLength(trace);
        times.add(_timeAt(timing.startMs, span, travelled, total));
      } else {
        times.add(_timeAt(timing.startMs, span, travelled, total));
        for (int p = 1; p < points.length; p++) {
          travelled += (points[p] - points[p - 1]).length;
          times.add(_timeAt(timing.startMs, span, travelled, total));
        }
      }
      timed.add(
        GeneratedInkTrace(style: trace.style, points: points, timesMs: times),
      );
    }
  }
  return timed;
}

/// How much drawing [trace] takes: its length, or its width for a dot.
double _inkLength(GeneratedInkTrace trace) {
  final List<InkVector> points = trace.points;
  if (points.length == 1) {
    return trace.style.width;
  }
  double length = 0;
  for (int i = 1; i < points.length; i++) {
    length += (points[i] - points[i - 1]).length;
  }
  return length;
}

/// When the pen has drawn [travelled] of an item's [total] ink, within the
/// [span] milliseconds after [startMs]. Never past the item's end.
double _timeAt(int startMs, double span, double travelled, double total) {
  if (total <= 0) {
    return startMs + span;
  }
  return startMs + span * math.min(1, travelled / total);
}

/// The strokes that draw one item, in order.
List<GeneratedInkTrace> _layoutItem(
  AiNotationItem item,
  Size size,
  AiNotationConfig config,
  InkSnapper? snapper,
) {
  final List<GeneratedInkTrace> traces = <GeneratedInkTrace>[];
  List<InkVector> snapEnds(List<InkVector> line) {
    return snapper == null ? line : snapper.snapEnds(line);
  }

  {
    final StrokeStyle style = StrokeStyle(
      ink:
          InkPalette.byId(item.ink) ??
          (throw const FormatException('Unknown ink')),
      width: item.width,
    );
    void add(List<InkVector> line, [StrokeStyle? lineStyle]) {
      for (final List<InkVector> piece in _pieces(line)) {
        traces.add(GeneratedInkTrace(style: lineStyle ?? style, points: piece));
      }
    }

    InkVector page(AiNotationPoint point) {
      return InkVector(point.x * size.width, point.y * size.height);
    }

    /// [line] in [lineStyle], with arrowheads on the ends [arrow] asks for.
    void addStyled(
      List<InkVector> line,
      AiLineStyle lineStyle, [
      AiArrow arrow = AiArrow.none,
    ]) {
      _styled(line, lineStyle, item.width).forEach(add);
      if (arrow == AiArrow.end || arrow == AiArrow.both) {
        add(_arrowhead(line, item.width));
      }
      if (arrow == AiArrow.start || arrow == AiArrow.both) {
        add(_arrowhead(line.reversed.toList(), item.width));
      }
    }

    switch (item) {
      case AiNotationText():
        NotationFont.write(
          item.text,
          origin: InkVector(item.x * size.width, item.y * size.height),
          size: item.size,
        ).forEach(add);
      case AiNotationGraph():
        _graph(item, size, config, add);
      case AiNotationPlot():
        _plot(item, size, config, add);
      case AiNotationPath():
        final List<InkVector> points = <InkVector>[...item.points.map(page)];
        addStyled(
          _path(item.closed ? points : snapEnds(points), item),
          item.lineStyle,
          item.arrow,
        );
      case AiNotationLine():
        addStyled(
          snapEnds(<InkVector>[page(item.from), page(item.to)]),
          item.lineStyle,
          item.arrow,
        );
      case AiNotationShape():
        addStyled(
          _shape(
            item.shape,
            Rect.fromLTRB(
              item.left * size.width,
              item.top * size.height,
              item.right * size.width,
              item.bottom * size.height,
            ),
          ),
          item.lineStyle,
        );
      case AiNotationStroke():
        add(snapEnds(<InkVector>[...item.points.map(page)]));
    }
  }
  return traces;
}

/// [line] drawn whole, or cut into dashes or dots along its length.
List<List<InkVector>> _styled(
  List<InkVector> line,
  AiLineStyle style,
  double width,
) {
  if (style == AiLineStyle.solid || line.length < 2) {
    return <List<InkVector>>[line];
  }
  double length = 0;
  for (int i = 1; i < line.length; i++) {
    length += (line[i] - line[i - 1]).length;
  }
  final bool dotted = style == AiLineStyle.dotted;
  // A dot or dash every [period]; never more than _maxMarks of them.
  final double period = math.max(
    dotted ? math.max(6, width * 3) : math.max(12, width * 6),
    length / _maxMarks,
  );
  final double dash = dotted ? 0 : period * 0.6;
  final List<List<InkVector>> marks = <List<InkVector>>[];
  for (double start = 0; start <= length + 1e-9; start += period) {
    marks.add(
      dotted
          ? <InkVector>[_along(line, start)]
          : _between(line, start, math.min(length, start + dash)),
    );
  }
  return marks;
}

/// The most dashes or dots one line is cut into.
const int _maxMarks = 300;

/// The point [distance] along [line].
InkVector _along(List<InkVector> line, double distance) {
  double travelled = 0;
  for (int i = 1; i < line.length; i++) {
    final InkVector step = line[i] - line[i - 1];
    final double length = step.length;
    if (travelled + length >= distance && length > 0) {
      return line[i - 1] + step * ((distance - travelled) / length);
    }
    travelled += length;
  }
  return line.last;
}

/// The part of [line] from [start] to [end] along it, corners included.
List<InkVector> _between(List<InkVector> line, double start, double end) {
  final List<InkVector> part = <InkVector>[_along(line, start)];
  double travelled = 0;
  for (int i = 1; i < line.length; i++) {
    travelled += (line[i] - line[i - 1]).length;
    if (travelled > start && travelled < end) {
      part.add(line[i]);
    }
  }
  part.add(_along(line, end));
  return part;
}

/// An open arrowhead at the end of [line], pointing the way it ends, sized
/// to the pen [width].
List<InkVector> _arrowhead(List<InkVector> line, double width) {
  final double size = math.max(10, width * 4);
  final InkVector tip = line.last;
  // The direction over the last stretch of the line, so that a curve's
  // head follows the curve rather than its final tiny step.
  double total = 0;
  for (int i = 1; i < line.length; i++) {
    total += (line[i] - line[i - 1]).length;
  }
  final InkVector back = _along(line, math.max(0, total - size));
  InkVector direction = tip - back;
  if (direction.length < 1e-9) {
    direction = const InkVector(1, 0);
  }
  direction = direction * (1 / direction.length);
  const double spread = 0.45; // radians, about 26 degrees
  InkVector wing(double turn) {
    final double c = math.cos(turn);
    final double s = math.sin(turn);
    final InkVector rotated = InkVector(
      direction.x * c - direction.y * s,
      direction.x * s + direction.y * c,
    );
    return tip - rotated * size;
  }

  return <InkVector>[wing(spread), tip, wing(-spread)];
}

/// The outline of [shape] filling [box], closed: it ends where it starts.
List<InkVector> _shape(AiShapeKind shape, Rect box) {
  final InkVector center = InkVector(box.center.dx, box.center.dy);
  final double rx = box.width / 2;
  final double ry = box.height / 2;
  List<InkVector> closed(List<InkVector> corners) {
    return <InkVector>[...corners, corners.first];
  }

  /// [count] points around the box's ellipse, from straight up,
  /// clockwise, alternating between [outer] and [inner] of its size.
  List<InkVector> around(int count, {double outer = 1, double inner = 1}) {
    return closed(<InkVector>[
      for (int i = 0; i < count; i++)
        () {
          final double angle = -math.pi / 2 + 2 * math.pi * i / count;
          final double scale = i.isEven ? outer : inner;
          return center +
              InkVector(
                math.cos(angle) * rx * scale,
                math.sin(angle) * ry * scale,
              );
        }(),
    ]);
  }

  switch (shape) {
    case AiShapeKind.ellipse:
      return around(48);
    case AiShapeKind.circle:
      final double r = math.min(rx, ry);
      return <InkVector>[
        for (int i = 0; i <= 48; i++)
          center +
              InkVector(
                math.cos(2 * math.pi * i / 48) * r,
                math.sin(2 * math.pi * i / 48) * r,
              ),
      ];
    case AiShapeKind.rectangle:
      return closed(<InkVector>[
        InkVector(box.left, box.top),
        InkVector(box.right, box.top),
        InkVector(box.right, box.bottom),
        InkVector(box.left, box.bottom),
      ]);
    case AiShapeKind.triangle:
      return closed(<InkVector>[
        InkVector(center.x, box.top),
        InkVector(box.right, box.bottom),
        InkVector(box.left, box.bottom),
      ]);
    case AiShapeKind.triangleDown:
      return closed(<InkVector>[
        InkVector(center.x, box.bottom),
        InkVector(box.left, box.top),
        InkVector(box.right, box.top),
      ]);
    case AiShapeKind.triangleLeft:
      return closed(<InkVector>[
        InkVector(box.left, center.y),
        InkVector(box.right, box.bottom),
        InkVector(box.right, box.top),
      ]);
    case AiShapeKind.triangleRight:
      return closed(<InkVector>[
        InkVector(box.right, center.y),
        InkVector(box.left, box.top),
        InkVector(box.left, box.bottom),
      ]);
    case AiShapeKind.rightTriangle:
      return closed(<InkVector>[
        InkVector(box.left, box.top),
        InkVector(box.right, box.bottom),
        InkVector(box.left, box.bottom),
      ]);
    case AiShapeKind.diamond:
      return around(4);
    case AiShapeKind.pentagon:
      return around(5);
    case AiShapeKind.hexagon:
      return around(6);
    case AiShapeKind.star:
      return around(10, inner: 0.4);
  }
}

/// The longest polyline one stroke may hold; longer ones are drawn as
/// several strokes that meet end to end.
const int _maxStrokePoints = 128;

Iterable<List<InkVector>> _pieces(List<InkVector> line) sync* {
  if (line.length <= _maxStrokePoints) {
    yield line;
    return;
  }
  for (int start = 0; start < line.length - 1; start += _maxStrokePoints - 1) {
    yield line.sublist(start, math.min(line.length, start + _maxStrokePoints));
  }
}

void _graph(
  AiNotationGraph graph,
  Size size,
  AiNotationConfig config,
  void Function(List<InkVector> line, [StrokeStyle? style]) add,
) {
  final Rect box = Rect.fromLTRB(
    graph.left * size.width,
    graph.top * size.height,
    graph.right * size.width,
    graph.bottom * size.height,
  );
  final int count = math.max(2, config.graphSamples);
  final double span = graph.xTo - graph.xFrom;
  final List<double> xs = <double>[
    for (int i = 0; i < count; i++) graph.xFrom + span * i / (count - 1),
  ];
  final List<double> ys = <double>[
    for (final double x in xs) graph.formula.evaluate(x),
  ];

  double? low = graph.yFrom;
  double? high = graph.yTo;
  if (low == null || high == null) {
    // Fit the curve, with a little room above and below.
    final Iterable<double> finite = ys.where((double y) => y.isFinite);
    if (finite.isEmpty) {
      throw const FormatException('Nothing to graph');
    }
    low = finite.reduce(math.min);
    high = finite.reduce(math.max);
    if (high - low < 1e-9) {
      low -= 1;
      high += 1;
    }
    final double room = (high - low) * 0.05;
    low -= room;
    high += room;
  }
  final double bottom = low;
  final double rise = high - low;
  double px(double x) => box.left + (x - graph.xFrom) / span * box.width;
  double py(double y) => box.bottom - (y - bottom) / rise * box.height;
  bool inside(double y) => y.isFinite && y >= bottom && y <= bottom + rise;

  if (graph.axes) {
    final StrokeStyle axisStyle = StrokeStyle(
      ink: InkPalette.byId('graphite')!,
      width: math.max(1, graph.width * 0.6),
    );
    final double head = math.min(8, math.min(box.width, box.height) / 12);
    if (inside(0)) {
      final double y = py(0);
      add(<InkVector>[
        InkVector(box.left, y),
        InkVector(box.right, y),
      ], axisStyle);
      add(<InkVector>[
        InkVector(box.right - head, y - head / 2),
        InkVector(box.right, y),
        InkVector(box.right - head, y + head / 2),
      ], axisStyle);
    }
    if (graph.xFrom <= 0 && graph.xTo >= 0) {
      final double x = px(0);
      add(<InkVector>[
        InkVector(x, box.bottom),
        InkVector(x, box.top),
      ], axisStyle);
      add(<InkVector>[
        InkVector(x - head / 2, box.top + head),
        InkVector(x, box.top),
        InkVector(x + head / 2, box.top + head),
      ], axisStyle);
    }
  }

  _curveRuns(graph.formula.evaluate, xs, ys, bottom, rise, px, py).forEach(add);
}

/// The curve of [f] through the samples [xs], [ys], as runs of page points,
/// broken where it is undefined, leaves [bottom]..[bottom] + [rise], or
/// jumps, as at an asymptote.
List<List<InkVector>> _curveRuns(
  double Function(double x) f,
  List<double> xs,
  List<double> ys,
  double bottom,
  double rise,
  double Function(double x) px,
  double Function(double y) py,
) {
  bool inside(double y) => y.isFinite && y >= bottom && y <= bottom + rise;
  final List<List<InkVector>> runs = <List<InkVector>>[];
  List<InkVector> run = <InkVector>[];
  void endRun() {
    if (run.length >= 2) {
      runs.add(run);
    }
    run = <InkVector>[];
  }

  for (int i = 0; i < xs.length; i++) {
    final double y = ys[i];
    if (!inside(y)) {
      endRun();
      continue;
    }
    if (run.isNotEmpty && _jumps(f, rise, xs[i - 1], ys[i - 1], xs[i], y)) {
      endRun();
    }
    run.add(InkVector(px(xs[i]), py(y)));
  }
  endRun();
  return runs;
}

/// Whether the curve breaks between two neighbouring samples: they are a
/// quarter of the box's [rise] or more apart, and the value halfway is not
/// between them.
bool _jumps(
  double Function(double x) f,
  double rise,
  double x0,
  double y0,
  double x1,
  double y1,
) {
  final double gap = (y1 - y0).abs();
  if (gap < rise * 0.25) {
    return false;
  }
  final double middle = f((x0 + x1) / 2);
  if (!middle.isFinite) {
    return true;
  }
  final double lowest = math.min(y0, y1);
  final double highest = math.max(y0, y1);
  final double slack = gap * 0.25;
  return middle < lowest - slack || middle > highest + slack;
}

/// The polyline of a path: its key points joined straight, or by a smooth
/// curve that the points on either side bend.
List<InkVector> _path(List<InkVector> points, AiNotationPath path) {
  final int n = points.length;
  final List<InkVector> line = <InkVector>[points.first];
  for (int i = 0; i < path.segments.length; i++) {
    final InkVector from = points[i];
    final InkVector to = points[(i + 1) % n];
    if (path.segments[i] == AiPathSegment.straight) {
      line.add(to);
      continue;
    }
    // The neighbours beyond each end, or a reflection where there is none.
    final InkVector before = path.closed
        ? points[(i - 1 + n) % n]
        : (i > 0 ? points[i - 1] : from * 2 - to);
    final InkVector after = path.closed
        ? points[(i + 2) % n]
        : (i + 2 < n ? points[i + 2] : to * 2 - from);
    line.addAll(_curve(before, from, to, after));
  }
  return line;
}

/// Points along the centripetal Catmull-Rom curve from [p1] to [p2], [p1]
/// left out. Centripetal spacing keeps it from looping or overshooting
/// between close key points.
List<InkVector> _curve(InkVector p0, InkVector p1, InkVector p2, InkVector p3) {
  double knot(InkVector a, InkVector b) {
    return math.max(math.sqrt((b - a).length), 1e-4);
  }

  const double t0 = 0;
  final double t1 = t0 + knot(p0, p1);
  final double t2 = t1 + knot(p1, p2);
  final double t3 = t2 + knot(p2, p3);
  InkVector lerp(InkVector a, InkVector b, double ta, double tb, double t) {
    return a * ((tb - t) / (tb - ta)) + b * ((t - ta) / (tb - ta));
  }

  final int steps = math.max(4, math.min(24, ((p2 - p1).length / 6).ceil()));
  return <InkVector>[
    for (int i = 1; i <= steps; i++)
      () {
        final double t = t1 + (t2 - t1) * i / steps;
        final InkVector a1 = lerp(p0, p1, t0, t1, t);
        final InkVector a2 = lerp(p1, p2, t1, t2, t);
        final InkVector a3 = lerp(p2, p3, t2, t3, t);
        final InkVector b1 = lerp(a1, a2, t0, t2, t);
        final InkVector b2 = lerp(a2, a3, t1, t3, t);
        return lerp(b1, b2, t1, t2, t);
      }(),
  ];
}

/// Draws [plot]: its axes and numbered ticks, then each child in order,
/// placed by mapping the plot's own x and y onto its box on the note.
/// What falls outside the box is left out, so a segment is cut at its
/// edge and a mark beyond it is not drawn; the app's own labels are kept
/// on the paper.
void _plot(
  AiNotationPlot plot,
  Size size,
  AiNotationConfig config,
  void Function(List<InkVector> line, [StrokeStyle? style]) add,
) {
  final Rect box = Rect.fromLTRB(
    plot.left * size.width,
    plot.top * size.height,
    plot.right * size.width,
    plot.bottom * size.height,
  );
  final double xFrom = plot.xFrom;
  final double xTo = plot.xTo;
  final double span = xTo - xFrom;
  final int count = math.max(2, config.graphSamples);
  final List<double> xs = <double>[
    for (int i = 0; i < count; i++) xFrom + span * i / (count - 1),
  ];
  // Each function's samples, worked out once for fitting and drawing.
  final Map<AiPlotChild, List<double>> samples = <AiPlotChild, List<double>>{
    for (final AiPlotChild child in plot.children)
      if (child is AiPlotFunction)
        child: <double>[for (final double x in xs) child.formula.evaluate(x)],
  };

  double? low = plot.yFrom;
  double? high = plot.yTo;
  if (low == null || high == null) {
    // Fit the curves and points, with a little room above and below.
    final List<double> fit = <double>[
      for (final List<double> ys in samples.values)
        ...ys.where((double y) => y.isFinite),
      for (final AiPlotChild child in plot.children)
        ...switch (child) {
          AiPlotDot(:final AiPlotPoint at) => <double>[at.y],
          AiPlotLabel(:final AiPlotPoint at) => <double>[at.y],
          AiPlotSegment(:final AiPlotPoint from, :final AiPlotPoint to) =>
            <double>[from.y, to.y],
          _ => const <double>[],
        },
    ];
    if (fit.isEmpty) {
      throw const FormatException('Nothing to plot');
    }
    low = fit.reduce(math.min);
    high = fit.reduce(math.max);
    if (high - low < 1e-9) {
      low -= 1;
      high += 1;
    }
    final double room = (high - low) * 0.05;
    low -= room;
    high += room;
  }
  final double bottom = low;
  final double top = high;
  final double rise = top - bottom;
  double px(double x) => box.left + (x - xFrom) / span * box.width;
  double py(double y) => box.bottom - (y - bottom) / rise * box.height;
  bool inBox(double x, double y) {
    return x.isFinite &&
        y.isFinite &&
        x >= xFrom &&
        x <= xTo &&
        y >= bottom &&
        y <= top;
  }

  StrokeStyle styleOf(String ink, double width) {
    return StrokeStyle(
      ink: InkPalette.byId(ink) ?? (throw const FormatException('Unknown ink')),
      width: width,
    );
  }

  final double textSize = config.plotTextSize;
  final double fineWidth = math.max(1, plot.width * 0.6);
  final double dotWidth = math.min(20, math.max(5, plot.width * 2.5));

  /// [text] written [textSize] tall with its top-left at [origin], moved
  /// only as far as it must be to stay on the paper.
  void write(String text, InkVector origin, StrokeStyle style) {
    final double textWidth = NotationFont.width(text, textSize);
    final double textHeight = NotationFont.height(text, textSize);
    final double margin = style.width + 2;
    final InkVector kept = InkVector(
      origin.x.clamp(margin, math.max(margin, size.width - margin - textWidth)),
      origin.y.clamp(
        margin,
        math.max(margin, size.height - margin - textHeight),
      ),
    );
    for (final List<InkVector> line in NotationFont.write(
      text,
      origin: kept,
      size: textSize,
    )) {
      add(line, style);
    }
  }

  /// [text] just above and to the right of the page point [at]; to its
  /// left, or below, where the box ends first.
  void labelAt(InkVector at, String text, StrokeStyle style) {
    const double gap = 5;
    final double textWidth = NotationFont.width(text, textSize);
    double x = at.x + gap;
    if (x + textWidth > box.right && at.x - gap - textWidth >= box.left) {
      x = at.x - gap - textWidth;
    }
    double y = at.y - gap - textSize;
    if (y < box.top) {
      y = at.y + gap;
    }
    write(text, InkVector(x, y), style);
  }

  /// A dot at the plot's ([x], [y]), with [label] beside it.
  void mark(double x, double y, String? label, String ink) {
    if (!inBox(x, y)) {
      return;
    }
    final InkVector at = InkVector(px(x), py(y));
    add(<InkVector>[at], styleOf(ink, dotWidth));
    if (label != null) {
      labelAt(at, label, styleOf(ink, fineWidth));
    }
  }

  // The axes: through 0 where the box reaches it, along its edge where it
  // does not.
  final StrokeStyle axisStyle = styleOf(plot.ink, fineWidth);
  final double axisY = bottom <= 0 && top >= 0 ? py(0) : box.bottom;
  final double axisX = xFrom <= 0 && xTo >= 0 ? px(0) : box.left;
  final double head = math.min(8, math.min(box.width, box.height) / 12);
  if (plot.axes) {
    add(<InkVector>[
      InkVector(box.left, axisY),
      InkVector(box.right, axisY),
    ], axisStyle);
    add(<InkVector>[
      InkVector(box.right - head, axisY - head / 2),
      InkVector(box.right, axisY),
      InkVector(box.right - head, axisY + head / 2),
    ], axisStyle);
    add(<InkVector>[
      InkVector(axisX, box.bottom),
      InkVector(axisX, box.top),
    ], axisStyle);
    add(<InkVector>[
      InkVector(axisX - head / 2, box.top + head),
      InkVector(axisX, box.top),
      InkVector(axisX + head / 2, box.top + head),
    ], axisStyle);
  }
  if (plot.ticks) {
    const double tick = 4;
    // Fewer numbers on a short axis, so they do not run together.
    final int xTarget = (box.width / (textSize * 5)).floor().clamp(2, 10);
    final int yTarget = (box.height / (textSize * 3)).floor().clamp(2, 10);
    for (final double x in niceTicks(xFrom, xTo, target: xTarget)) {
      final double at = px(x);
      // None at the origin, where the axes cross, or under an arrowhead.
      if ((at - axisX).abs() < 1 || box.right - at < head * 1.5) {
        continue;
      }
      // Kept inside the box, as the box is kept on the paper.
      add(<InkVector>[
        InkVector(at, math.max(box.top, axisY - tick)),
        InkVector(at, math.min(box.bottom, axisY + tick)),
      ], axisStyle);
      final String text = formatPlotNumber(x);
      write(
        text,
        InkVector(
          at - NotationFont.width(text, textSize) / 2,
          axisY + tick + 3,
        ),
        axisStyle,
      );
    }
    for (final double y in niceTicks(bottom, top, target: yTarget)) {
      final double at = py(y);
      if ((at - axisY).abs() < 1 || at - box.top < head * 1.5) {
        continue;
      }
      add(<InkVector>[
        InkVector(math.max(box.left, axisX - tick), at),
        InkVector(math.min(box.right, axisX + tick), at),
      ], axisStyle);
      final String text = formatPlotNumber(y);
      write(
        text,
        InkVector(
          axisX - tick - 3 - NotationFont.width(text, textSize),
          at - textSize / 2,
        ),
        axisStyle,
      );
    }
  }

  for (final AiPlotChild child in plot.children) {
    final StrokeStyle style = styleOf(child.ink, plot.width);
    void addLine(List<InkVector> line, AiLineStyle lineStyle) {
      for (final List<InkVector> piece in _styled(
        line,
        lineStyle,
        plot.width,
      )) {
        add(piece, style);
      }
    }

    switch (child) {
      case AiPlotFunction():
        final double Function(double) f = child.formula.evaluate;
        for (final List<InkVector> run in _curveRuns(
          f,
          xs,
          samples[child]!,
          bottom,
          rise,
          px,
          py,
        )) {
          addLine(run, child.lineStyle);
        }
        for (final AiPlotMark kind in child.marks) {
          final List<double> found = switch (kind) {
            AiPlotMark.roots => findRoots(f, xFrom, xTo),
            AiPlotMark.extrema => findExtrema(f, xFrom, xTo),
            AiPlotMark.yIntercept =>
              xFrom <= 0 && xTo >= 0 ? <double>[0] : const <double>[],
          };
          for (final double x in found.take(config.maxPlotMarks)) {
            final double y = kind == AiPlotMark.roots ? 0 : f(x);
            mark(x, y, formatPlotPoint(x, y), child.ink);
          }
        }
      case AiPlotDot():
        mark(child.at.x, child.at.y, child.label, child.ink);
      case AiPlotSegment():
        final List<InkVector>? line = _clip(
          InkVector(px(child.from.x), py(child.from.y)),
          InkVector(px(child.to.x), py(child.to.y)),
          box,
        );
        if (line == null) {
          break;
        }
        addLine(line, child.lineStyle);
        if (child.arrow == AiArrow.end || child.arrow == AiArrow.both) {
          add(_arrowhead(line, plot.width), style);
        }
        if (child.arrow == AiArrow.start || child.arrow == AiArrow.both) {
          add(_arrowhead(line.reversed.toList(), plot.width), style);
        }
      case AiPlotLabel():
        if (inBox(child.at.x, child.at.y)) {
          labelAt(
            InkVector(px(child.at.x), py(child.at.y)),
            child.text,
            styleOf(child.ink, fineWidth),
          );
        }
      case AiPlotShade():
        final StrokeStyle hatch = styleOf(
          child.ink,
          math.max(1, plot.width * 0.5),
        );
        for (final List<InkVector> line in _shade(
          child,
          math.max(child.from, xFrom),
          math.min(child.to, xTo),
          bottom,
          top,
          px,
          py,
        )) {
          add(line, hatch);
        }
      case AiPlotIntersections():
        final List<double> found = findIntersections(
          child.first.evaluate,
          child.second.evaluate,
          xFrom,
          xTo,
        );
        for (final double x in found.take(config.maxPlotMarks)) {
          final double y = child.first.evaluate(x);
          mark(x, y, formatPlotPoint(x, y), child.ink);
        }
    }
  }
}

/// Vertical hatching between [shade]'s curve and its base, every few
/// pixels from x [from] to [to], kept between y [bottom] and [top].
List<List<InkVector>> _shade(
  AiPlotShade shade,
  double from,
  double to,
  double bottom,
  double top,
  double Function(double x) px,
  double Function(double y) py,
) {
  if (from >= to) {
    return const <List<InkVector>>[];
  }
  const double spacing = 7;
  final int lines = math.max(1, ((px(to) - px(from)) / spacing).floor());
  final List<List<InkVector>> hatching = <List<InkVector>>[];
  for (int i = 0; i <= lines; i++) {
    final double x = from + (to - from) * i / lines;
    final double curve = shade.formula.evaluate(x);
    final double base = shade.base?.evaluate(x) ?? 0;
    if (!curve.isFinite || !base.isFinite) {
      continue;
    }
    final double y0 = py(base.clamp(bottom, top));
    final double y1 = py(curve.clamp(bottom, top));
    if ((y1 - y0).abs() >= 1) {
      hatching.add(<InkVector>[InkVector(px(x), y0), InkVector(px(x), y1)]);
    }
  }
  return hatching;
}

/// The part of the line from [a] to [b] inside [box], or null when none of
/// it is: Liang-Barsky clipping.
List<InkVector>? _clip(InkVector a, InkVector b, Rect box) {
  double enter = 0;
  double leave = 1;
  final double dx = b.x - a.x;
  final double dy = b.y - a.y;
  for (final (double p, double q) in <(double, double)>[
    (-dx, a.x - box.left),
    (dx, box.right - a.x),
    (-dy, a.y - box.top),
    (dy, box.bottom - a.y),
  ]) {
    if (p == 0) {
      if (q < 0) {
        return null;
      }
      continue;
    }
    final double t = q / p;
    if (p < 0) {
      enter = math.max(enter, t);
    } else {
      leave = math.min(leave, t);
    }
  }
  if (enter >= leave) {
    return null;
  }
  return <InkVector>[
    InkVector(a.x + dx * enter, a.y + dy * enter),
    InkVector(a.x + dx * leave, a.y + dy * leave),
  ];
}
