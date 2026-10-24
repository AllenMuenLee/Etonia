import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable;
import 'package:xml/xml.dart';

import '../ink/stroke.dart' show Stroke;
import 'ai_config.dart';
import 'chat_math.dart';
import 'notation_font.dart';
import 'notation_formula.dart';
import 'notation_math.dart';
import '../document_io/svg_document.dart';

/// One normalized point on the note: (0, 0) is its top-left corner and
/// (1, 1) its bottom-right.
class AiNotationPoint {
  const AiNotationPoint(this.x, this.y);

  final double x;
  final double y;

  Map<String, Object?> toJson() => <String, Object?>{'x': x, 'y': y};
}

/// One thing the model asks to have drawn. The app does the drawing: the
/// model says what, where, and in which ink and pen width.
sealed class AiNotationItem {
  const AiNotationItem({required this.ink, required this.width});

  /// The `type` written in the response.
  String get type;

  /// An [InkPalette] ID.
  final String ink;

  /// Pen width, in logical pixels.
  final double width;

  Map<String, Object?> toJson();
}

/// Words written in the app's handwriting font, [NotationFont].
class AiNotationText extends AiNotationItem {
  const AiNotationText({
    required this.text,
    required this.x,
    required this.y,
    required this.size,
    required super.ink,
    required super.width,
  });

  @override
  String get type => 'text';

  /// May hold line breaks.
  final String text;

  /// The top-left corner of the first letter, normalized.
  final double x;
  final double y;

  /// The height of a capital letter, in logical pixels.
  final double size;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'text': text,
    'x': x,
    'y': y,
    'size': size,
    'ink': ink,
    'width': width,
  };
}

/// A formula in LaTeX, laid out by the app as it is written by hand and
/// written in [NotationFont].
class AiNotationMath extends AiNotationItem {
  const AiNotationMath({
    required this.math,
    required this.x,
    required this.y,
    required this.size,
    required super.ink,
    required super.width,
  });

  @override
  String get type => 'math';

  final NotationMath math;

  /// The top-left corner of the formula, normalized.
  final double x;
  final double y;

  /// The height of a capital letter at the formula's full size, in logical
  /// pixels.
  final double size;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'latex': math.source,
    'x': x,
    'y': y,
    'size': size,
    'ink': ink,
    'width': width,
  };
}

/// The graph of a formula in x, drawn by the app inside a box on the note.
class AiNotationGraph extends AiNotationItem {
  const AiNotationGraph({
    required this.formula,
    required this.xFrom,
    required this.xTo,
    required this.yFrom,
    required this.yTo,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.axes,
    required super.ink,
    required super.width,
  });

  @override
  String get type => 'graph';

  final NotationFormula formula;

  /// Where the graph starts and ends, in the formula's own x.
  final double xFrom;
  final double xTo;

  /// The y the box spans, in the formula's own y; both null to fit the
  /// curve.
  final double? yFrom;
  final double? yTo;

  /// The box on the note, normalized.
  final double left;
  final double top;
  final double right;
  final double bottom;

  /// Whether to draw the x and y axes where they cross the box.
  final bool axes;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'formula': formula.source,
    'x_from': xFrom,
    'x_to': xTo,
    'y_from': yFrom,
    'y_to': yTo,
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
    'axes': axes,
    'ink': ink,
    'width': width,
  };
}

/// A point in a plot's own units: the x and y of its graph, not the note.
class AiPlotPoint {
  const AiPlotPoint(this.x, this.y);

  final double x;
  final double y;

  Map<String, Object?> toJson() => <String, Object?>{'x': x, 'y': y};
}

/// A feature of a function's curve that the app finds, and marks with a dot
/// and its coordinates.
enum AiPlotMark {
  /// Where the curve meets y = 0.
  roots,

  /// Its local maxima and minima.
  extrema,

  /// Where it crosses x = 0.
  yIntercept('y_intercept');

  const AiPlotMark([this._wire]);

  final String? _wire;

  /// As written in the response.
  String get wire => _wire ?? name;
}

/// One thing drawn inside an [AiNotationPlot], placed in the plot's units.
/// The plot gives the pen width.
sealed class AiPlotChild {
  const AiPlotChild({required this.ink});

  /// The `type` written in the response.
  String get type;

  /// An [InkPalette] ID.
  final String ink;

  Map<String, Object?> toJson();
}

/// The curve of a formula in x, across the whole plot.
class AiPlotFunction extends AiPlotChild {
  AiPlotFunction({
    required this.formula,
    this.lineStyle = AiLineStyle.solid,
    List<AiPlotMark> marks = const <AiPlotMark>[],
    required super.ink,
  }) : marks = List<AiPlotMark>.unmodifiable(marks);

  @override
  String get type => 'function';

  final NotationFormula formula;
  final AiLineStyle lineStyle;

  /// The features the app finds on the curve and marks, labelled with
  /// their coordinates.
  final List<AiPlotMark> marks;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'formula': formula.source,
    'line_style': lineStyle.name,
    'marks': <String>[for (final AiPlotMark mark in marks) mark.wire],
    'ink': ink,
  };
}

/// A dot at a point of the plot, with an optional label beside it.
class AiPlotDot extends AiPlotChild {
  const AiPlotDot({required this.at, this.label, required super.ink});

  @override
  String get type => 'point';

  final AiPlotPoint at;

  /// Written just above and to the right of the dot.
  final String? label;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'x': at.x,
    'y': at.y,
    'label': ?label,
    'ink': ink,
  };
}

/// A straight line between two points of the plot.
class AiPlotSegment extends AiPlotChild {
  const AiPlotSegment({
    required this.from,
    required this.to,
    this.lineStyle = AiLineStyle.solid,
    this.arrow = AiArrow.none,
    required super.ink,
  });

  @override
  String get type => 'segment';

  final AiPlotPoint from;
  final AiPlotPoint to;
  final AiLineStyle lineStyle;
  final AiArrow arrow;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'from': from.toJson(),
    'to': to.toJson(),
    'line_style': lineStyle.name,
    'arrow': arrow.name,
    'ink': ink,
  };
}

/// Words written just above and to the right of a point of the plot.
class AiPlotLabel extends AiPlotChild {
  const AiPlotLabel({required this.at, required this.text, required super.ink});

  @override
  String get type => 'label';

  final AiPlotPoint at;
  final String text;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'x': at.x,
    'y': at.y,
    'text': text,
    'ink': ink,
  };
}

/// Hatching between a formula's curve and a [base] curve, y = 0 unless
/// given, from x [from] to x [to]: an area under a curve, or between two.
class AiPlotShade extends AiPlotChild {
  const AiPlotShade({
    required this.formula,
    this.base,
    required this.from,
    required this.to,
    required super.ink,
  });

  @override
  String get type => 'shade';

  final NotationFormula formula;
  final NotationFormula? base;
  final double from;
  final double to;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'formula': formula.source,
    'base': ?base?.source,
    'from': from,
    'to': to,
    'ink': ink,
  };
}

/// The points where two formulas' curves meet, found by the app, each
/// marked with a dot and its coordinates.
class AiPlotIntersections extends AiPlotChild {
  const AiPlotIntersections({
    required this.first,
    required this.second,
    required super.ink,
  });

  @override
  String get type => 'intersections';

  final NotationFormula first;
  final NotationFormula second;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'of': <String>[first.source, second.source],
    'ink': ink,
  };
}

/// A coordinate plane in a box on the note. Everything in it is placed in
/// the plot's own x and y; the app maps them onto the note, and can draw
/// numbered ticks along the axes.
class AiNotationPlot extends AiNotationItem {
  AiNotationPlot({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.xFrom,
    required this.xTo,
    required this.yFrom,
    required this.yTo,
    required this.axes,
    required this.ticks,
    required List<AiPlotChild> children,
    required super.ink,
    required super.width,
  }) : children = List<AiPlotChild>.unmodifiable(children);

  @override
  String get type => 'plot';

  /// The box on the note, normalized.
  final double left;
  final double top;
  final double right;
  final double bottom;

  /// The x the box spans, in the plot's own units.
  final double xFrom;
  final double xTo;

  /// The y the box spans; both null to fit its functions and points.
  final double? yFrom;
  final double? yTo;

  /// Whether to draw the x and y axes: through 0 where the box reaches
  /// it, and along its bottom or left edge where it does not. They are
  /// drawn in [ink].
  final bool axes;

  /// Whether to number the axes at evenly spaced, round values.
  final bool ticks;

  /// Drawn in order, after the axes.
  final List<AiPlotChild> children;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
    'x_from': xFrom,
    'x_to': xTo,
    'y_from': yFrom,
    'y_to': yTo,
    'axes': axes,
    'ticks': ticks,
    'children': <Object?>[
      for (final AiPlotChild child in children) child.toJson(),
    ],
    'ink': ink,
    'width': width,
  };
}

/// How a [AiNotationPath] goes from one key point to the next.
enum AiPathSegment {
  straight,

  /// A smooth curve, bent by the key points on either side.
  curve,
}

/// How a line, path, or shape is drawn along its length.
enum AiLineStyle { solid, dashed, dotted }

/// Which ends of a line or path carry an arrowhead.
enum AiArrow { none, start, end, both }

/// A shape the app draws inside a box.
enum AiShapeKind {
  /// Fills the box: around something, to circle it.
  ellipse,

  /// The largest circle that fits the box, at its centre.
  circle,
  rectangle,

  /// Its apex at the middle of the box's top edge.
  triangle,

  /// Its apex at the middle of the box's bottom edge.
  triangleDown('triangle_down'),

  /// Its apex at the middle of the box's left edge.
  triangleLeft('triangle_left'),

  /// Its apex at the middle of the box's right edge.
  triangleRight('triangle_right'),

  /// Its right angle at the box's bottom-left corner.
  rightTriangle('right_triangle'),
  diamond,
  pentagon,
  hexagon,
  star;

  const AiShapeKind([this._wire]);

  final String? _wire;

  /// As written in the response.
  String get wire => _wire ?? name;
}

/// A straight line between two points, which may be dashed, dotted, or an
/// arrow.
class AiNotationLine extends AiNotationItem {
  const AiNotationLine({
    required this.from,
    required this.to,
    required this.lineStyle,
    required this.arrow,
    required super.ink,
    required super.width,
  });

  @override
  String get type => 'line';

  final AiNotationPoint from;
  final AiNotationPoint to;
  final AiLineStyle lineStyle;
  final AiArrow arrow;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'from': from.toJson(),
    'to': to.toJson(),
    'line_style': lineStyle.name,
    'arrow': arrow.name,
    'ink': ink,
    'width': width,
  };
}

/// A shape drawn by the app to fill a box on the note.
class AiNotationShape extends AiNotationItem {
  const AiNotationShape({
    required this.shape,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.lineStyle,
    required super.ink,
    required super.width,
  });

  @override
  String get type => 'shape';

  final AiShapeKind shape;

  /// The box, normalized.
  final double left;
  final double top;
  final double right;
  final double bottom;

  final AiLineStyle lineStyle;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'shape': shape.wire,
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
    'line_style': lineStyle.name,
    'ink': ink,
    'width': width,
  };
}

/// A freehand graph or shape through key points, each gap either straight
/// or curved.
class AiNotationPath extends AiNotationItem {
  AiNotationPath({
    required List<AiNotationPoint> points,
    required List<AiPathSegment> segments,
    required this.closed,
    this.lineStyle = AiLineStyle.solid,
    this.arrow = AiArrow.none,
    required super.ink,
    required super.width,
  }) : points = List<AiNotationPoint>.unmodifiable(points),
       segments = List<AiPathSegment>.unmodifiable(segments);

  @override
  String get type => 'path';

  final List<AiNotationPoint> points;

  /// One per gap: between each point and the next, and, when [closed],
  /// from the last back to the first.
  final List<AiPathSegment> segments;

  final bool closed;

  final AiLineStyle lineStyle;

  /// Never at an end of a [closed] path, which has none.
  final AiArrow arrow;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'points': <Object?>[
      for (final AiNotationPoint point in points) point.toJson(),
    ],
    'segments': <String>[
      for (final AiPathSegment segment in segments) segment.name,
    ],
    'closed': closed,
    'line_style': lineStyle.name,
    'arrow': arrow.name,
    'ink': ink,
    'width': width,
  };
}

/// One pen-down stroke through points given one by one: a dot, or an open
/// polyline. For small marks such as a tick or an arrowhead.
class AiNotationStroke extends AiNotationItem {
  AiNotationStroke({
    required super.ink,
    required super.width,
    required List<AiNotationPoint> points,
  }) : points = List<AiNotationPoint>.unmodifiable(points);

  @override
  String get type => 'stroke';

  final List<AiNotationPoint> points;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'points': <Object?>[
      for (final AiNotationPoint point in points) point.toJson(),
    ],
    'ink': ink,
    'width': width,
  };
}

/// When one notation item is drawn: its strokes appear between [startMs]
/// and [endMs], counted from the start of the notation's animation.
@immutable
class AiItemTiming {
  const AiItemTiming(this.startMs, this.endMs);

  final int startMs;

  /// Equal to [startMs] for an item that appears all at once.
  final int endMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'start_ms': startMs,
    'end_ms': endMs,
  };

  @override
  bool operator ==(Object other) {
    return other is AiItemTiming &&
        other.startMs == startMs &&
        other.endMs == endMs;
  }

  @override
  int get hashCode => Object.hash(startMs, endMs);
}

/// How a notation animates: how long it lasts, and when each of its items
/// is drawn. Optional: without one, the notation appears all at once.
class AiNotationTimeline {
  AiNotationTimeline({
    required this.durationMs,
    required List<AiItemTiming> items,
  }) : items = List<AiItemTiming>.unmodifiable(items),
       _steps = null;

  /// The timeline for items drawn in the order of their [steps], one per
  /// item: the lowest step first, and items that share a step at the same
  /// time. Each item takes about as long as a hand would to draw it, with
  /// a short pause between steps. One that would outlast
  /// [AiNotationConfig.maxDurationMs] is sped up to fit.
  ///
  /// A step of [fixedStep] marks a fixed item, such as a label, an axis, or
  /// the figure something moves over: it is shown whole from the start of
  /// every repeat and never redrawn. At least one item must have a step.
  factory AiNotationTimeline.fromSteps(
    List<AiNotationItem> items,
    List<int> steps, {
    AiNotationConfig config = const AiNotationConfig(),
  }) {
    assert(items.isNotEmpty && items.length == steps.length);
    assert(steps.any((int step) => step != fixedStep));
    final List<int> draw = <int>[for (final item in items) _drawMs(item)];
    final List<int> order =
        steps.where((int step) => step != fixedStep).toSet().toList()..sort();
    final Map<int, int> startOf = <int, int>{};
    int time = 0;
    int lastEnd = 0;
    for (final int step in order) {
      startOf[step] = time;
      int longest = 0;
      for (int i = 0; i < items.length; i++) {
        if (steps[i] == step && draw[i] > longest) {
          longest = draw[i];
        }
      }
      lastEnd = time + longest;
      time = lastEnd + config.stepPauseMs;
    }
    final int hold = config.stepFinalHoldMs;
    final double scale = lastEnd + hold > config.maxDurationMs
        ? (config.maxDurationMs - hold) / lastEnd
        : 1;
    return AiNotationTimeline._withSteps(
      durationMs: math.max(
        config.minDurationMs,
        (lastEnd * scale).round() + hold,
      ),
      items: <AiItemTiming>[
        for (int i = 0; i < items.length; i++)
          steps[i] == fixedStep
              ? const AiItemTiming(0, 0)
              : AiItemTiming(
                  (startOf[steps[i]]! * scale).round(),
                  ((startOf[steps[i]]! + draw[i]) * scale).round(),
                ),
      ],
      steps: steps,
    );
  }

  /// The step of an item that does not move: it has no step on the wire.
  static const int fixedStep = 0;

  AiNotationTimeline._withSteps({
    required this.durationMs,
    required List<AiItemTiming> items,
    required List<int> steps,
  }) : items = List<AiItemTiming>.unmodifiable(items),
       _steps = List<int>.unmodifiable(steps);

  final int durationMs;

  /// One per item of the notation, in the same order.
  final List<AiItemTiming> items;

  final List<int>? _steps;

  /// The step of each item, as the model gave it, [fixedStep] for an item
  /// it gave none: for a timeline built from times, its items ranked by
  /// when they start, from 1.
  List<int> get steps {
    final List<int>? steps = _steps;
    if (steps != null) {
      return steps;
    }
    final List<int> starts =
        items.map((AiItemTiming timing) => timing.startMs).toSet().toList()
          ..sort();
    return <int>[
      for (final AiItemTiming timing in items)
        starts.indexOf(timing.startMs) + 1,
    ];
  }

  /// About how long a hand takes to draw [item], in milliseconds.
  static int _drawMs(AiNotationItem item) {
    // Pen speed over the note: a line across the whole paper takes about
    // 1.5 s, plus a moment to put the pen down.
    int travel(double length, int least, int most) {
      return (least + 1500 * length).round().clamp(least, most);
    }

    double polyline(List<AiNotationPoint> points) {
      double length = 0;
      for (int i = 1; i < points.length; i++) {
        length += math.sqrt(
          math.pow(points[i].x - points[i - 1].x, 2) +
              math.pow(points[i].y - points[i - 1].y, 2),
        );
      }
      return length;
    }

    return switch (item) {
      // About 140 ms a character, as a quick hand writes.
      AiNotationText() =>
        (140 *
                item.text.runes
                    .where((int rune) => rune != 0x20 && rune != 0x0A)
                    .length)
            .clamp(300, 2400),
      AiNotationMath() => (140 * item.math.marks).clamp(300, 3600),
      AiNotationLine() => travel(
        polyline(<AiNotationPoint>[item.from, item.to]),
        250,
        1200,
      ),
      AiNotationShape() => travel(
        2 * ((item.right - item.left) + (item.bottom - item.top)),
        350,
        1500,
      ),
      AiNotationPath() => travel(polyline(item.points), 250, 1800),
      AiNotationStroke() => travel(polyline(item.points), 150, 900),
      AiNotationGraph() => 1200,
      AiNotationPlot() =>
        (500 +
                (item.ticks ? 400 : 0) +
                item.children.fold<int>(
                  0,
                  (int sum, AiPlotChild child) =>
                      sum + (child is AiPlotFunction ? 900 : 350),
                ))
            .clamp(800, 4000),
    };
  }
}

/// The sticky note a notation is drawn on, in logical units, instead of
/// the page. The app decides where it goes.
@immutable
class AiStickySize {
  const AiStickySize(this.width, this.height);

  final double width;
  final double height;

  Map<String, Object?> toJson() => <String, Object?>{
    'width': width,
    'height': height,
  };

  @override
  bool operator ==(Object other) =>
      other is AiStickySize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);
}

/// An append-only drawing returned with one assistant answer.
class AiNotation {
  AiNotation({
    required this.label,
    required List<AiNotationItem> items,
    this.timeline,
    this.sticky,
    this.vector,
  }) : assert(timeline == null || timeline.items.length == items.length),
       items = List<AiNotationItem>.unmodifiable(items);

  factory AiNotation.vector(EditableSvg vector) => AiNotation(
    label: vector.label,
    items: const <AiNotationItem>[],
    vector: vector,
  );

  static const String coordinateSpace = 'note_normalized';

  /// The coordinates of a notation on a [sticky] note: (0, 0) is the
  /// sticky note's top-left corner and (1, 1) its bottom-right.
  static const String stickyCoordinateSpace = 'sticky_normalized';

  /// When not null, the whole notation goes on a new sticky note this big,
  /// and its coordinates are [stickyCoordinateSpace].
  final AiStickySize? sticky;

  /// The SVG-native notation returned by current models. Legacy structured
  /// items remain readable so existing notes and conversations still load.
  final EditableSvg? vector;

  final String label;

  /// Drawn in order, each above the ones before.
  final List<AiNotationItem> items;

  /// Null when the model gave no timing, or timing that could not be used:
  /// the notation is then drawn all at once.
  final AiNotationTimeline? timeline;

  Map<String, Object?> toJson() {
    if (vector != null) {
      return <String, Object?>{'svg': vector!.source};
    }
    final List<int>? steps = timeline?.steps;
    return <String, Object?>{
      'label': label,
      'coordinate_space': sticky == null
          ? coordinateSpace
          : stickyCoordinateSpace,
      'sticky': ?sticky?.toJson(),
      'items': <Object?>[
        for (int i = 0; i < items.length; i++)
          <String, Object?>{
            ...items[i].toJson(),
            if (steps != null && steps[i] != AiNotationTimeline.fixedStep)
              'step': steps[i],
          },
      ],
    };
  }
}

/// The complete, versioned assistant wire response.
class AiAssistantResponse {
  const AiAssistantResponse({
    required this.message,
    this.notation,
    this.notationRejected = false,
  });

  static const int version = 2;

  final String message;
  final AiNotation? notation;

  /// Whether a notation came with the answer but broke the contract, and
  /// was dropped. The message is kept. Local only, never sent.
  final bool notationRejected;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': version,
    'message': message,
    'notation': notation?.toJson(),
  };

  String toJsonString() => jsonEncode(toJson());

  /// Parses the closed response contract. Throws only a generic
  /// [FormatException], never one containing response content, when the
  /// envelope or its message is wrong. A wrong notation alone is dropped,
  /// whole, and reported by [notationRejected].
  static AiAssistantResponse parse(
    String source, {
    AiNotationConfig config = const AiNotationConfig(),
  }) {
    final String trimmed = source.trim();
    if (_looksLikeSvgResponse(trimmed)) {
      try {
        final EditableSvg svg = EditableSvg.parse(trimmed, modelResponse: true);
        return AiAssistantResponse(
          message: svg.message!,
          notation: svg.hasVisualContent ? AiNotation.vector(svg) : null,
        );
      } on FormatException {
        return AiAssistantResponse(
          message: EditableSvg.messageFromResponse(trimmed),
          notationRejected: true,
        );
      }
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(repairLatexEscapes(source));
    } on Object {
      throw const FormatException('Invalid AI response');
    }
    final Map<String, Object?> root = _object(decoded, const <String>{
      'version',
      'message',
      'notation',
    });
    if (root['version'] != version) {
      throw const FormatException('Unsupported AI response');
    }
    final Object? rawMessage = root['message'];
    if (rawMessage is! String || rawMessage.trim().isEmpty) {
      throw const FormatException('Invalid AI response');
    }
    final String message = rawMessage.trim();
    final Object? rawNotation = root['notation'];
    if (rawNotation == null) {
      return AiAssistantResponse(message: message);
    }
    try {
      return AiAssistantResponse(
        message: message,
        notation: _notation(rawNotation, config),
      );
    } on FormatException {
      return AiAssistantResponse(message: message, notationRejected: true);
    }
  }

  /// A notation's label when the model gave none.
  static const String defaultLabel = 'Notes';

  static AiNotation _notation(Object? raw, AiNotationConfig config) {
    // Models not held to the schema leave out the label and the coordinate
    // space; neither changes what is drawn, so each has a default.
    final Map<String, Object?> notation = _object(
      raw,
      const <String>{'items'},
      optional: const <String>{'label', 'coordinate_space', 'sticky'},
    );
    final Object rawLabel = notation['label'] ?? defaultLabel;
    if (rawLabel is! String) {
      throw const FormatException('Invalid AI response');
    }
    final String label = rawLabel.trim().isEmpty
        ? defaultLabel
        : rawLabel.trim();
    if (label.runes.length > config.maxLabelRunes) {
      throw const FormatException('Invalid AI response');
    }
    final AiStickySize? sticky = notation['sticky'] == null
        ? null
        : _sticky(notation['sticky'], config);
    final String space = sticky == null
        ? AiNotation.coordinateSpace
        : AiNotation.stickyCoordinateSpace;
    if ((notation['coordinate_space'] ?? space) != space) {
      throw const FormatException('Invalid AI response');
    }
    final Object? rawItems = notation['items'];
    if (rawItems is! List<Object?> ||
        rawItems.isEmpty ||
        rawItems.length > config.maxItems) {
      throw const FormatException('Invalid AI response');
    }
    final _Budget budget = _Budget(config);
    final List<AiNotationItem> items = <AiNotationItem>[];
    // Each item's step, taken off it before its drawing is read.
    final List<Object?> steps = <Object?>[];
    bool anyStep = false;
    for (final Object? rawItem in rawItems) {
      if (rawItem is! Map<String, Object?>) {
        throw const FormatException('Invalid AI response');
      }
      final Object? step = rawItem['step'];
      anyStep = anyStep || step != null;
      steps.add(step);
      items.add(
        _item(Map<String, Object?>.of(rawItem)..remove('step'), config, budget),
      );
    }
    return AiNotation(
      label: label,
      items: items,
      timeline: anyStep ? _timeline(items, steps, config) : null,
      sticky: sticky,
    );
  }

  /// The sticky note's size, brought within the sizes one may be.
  static AiStickySize _sticky(Object? raw, AiNotationConfig config) {
    final Map<String, Object?> sticky = _object(raw, const <String>{
      'width',
      'height',
    });
    final double width = _number(sticky['width']);
    final double height = _number(sticky['height']);
    if (width <= 0 || height <= 0) {
      throw const FormatException('Invalid AI response');
    }
    return AiStickySize(
      width.clamp(config.minStickyWidth, config.maxStickyWidth),
      height.clamp(config.minStickyHeight, config.maxStickyHeight),
    );
  }

  /// The notation's animation, or null when a step breaks the rules: then
  /// it is drawn all at once instead, and the drawing itself is unaffected.
  ///
  /// Every step given is a JSON integer from 1 through the configured most:
  /// `1.0` is not one. An item without one is fixed: shown whole for the
  /// whole animation. The app works out the times from them.
  static AiNotationTimeline? _timeline(
    List<AiNotationItem> items,
    List<Object?> rawSteps,
    AiNotationConfig config,
  ) {
    final List<int> steps = <int>[];
    for (final Object? step in rawSteps) {
      if (step == null) {
        steps.add(AiNotationTimeline.fixedStep);
        continue;
      }
      if (step is! int || step < 1 || step > config.maxSteps) {
        return null;
      }
      steps.add(step);
    }
    return AiNotationTimeline.fromSteps(items, steps, config: config);
  }

  static AiNotationItem _item(
    Object? raw,
    AiNotationConfig config,
    _Budget budget,
  ) {
    if (raw is! Map<String, Object?>) {
      throw const FormatException('Invalid AI response');
    }
    switch (raw['type']) {
      case 'text':
        final Map<String, Object?> item = _object(raw, const <String>{
          'type',
          'text',
          'x',
          'y',
          'size',
          'ink',
          'width',
        });
        final Object? text = item['text'];
        if (text is! String ||
            text.trim().isEmpty ||
            text.runes.length > config.maxTextRunes) {
          throw const FormatException('Invalid AI response');
        }
        budget.text(text.runes.length);
        final double size = _number(item['size']);
        if (size < config.minTextSize || size > config.maxTextSize) {
          throw const FormatException('Invalid AI response');
        }
        // Text with LaTeX in it, as models often write, is laid out as
        // the formula it means rather than written out as its source.
        final String delimited = delimitBareMath(text);
        if (NotationMath.hasMath(delimited)) {
          return AiNotationMath(
            math: NotationMath.parse(NotationMath.fromText(delimited)),
            x: _unit(item['x']),
            y: _unit(item['y']),
            size: size,
            ink: _ink(item['ink'], config),
            width: _width(item['width'], config),
          );
        }
        if (!NotationFont.canWrite(text)) {
          throw const FormatException('Invalid AI response');
        }
        return AiNotationText(
          text: text,
          x: _unit(item['x']),
          y: _unit(item['y']),
          size: size,
          ink: _ink(item['ink'], config),
          width: _width(item['width'], config),
        );
      case 'math':
        final Map<String, Object?> item = _object(raw, const <String>{
          'type',
          'latex',
          'x',
          'y',
          'size',
          'ink',
          'width',
        });
        final Object? latex = item['latex'];
        if (latex is! String ||
            latex.trim().isEmpty ||
            latex.runes.length > config.maxMathRunes) {
          throw const FormatException('Invalid AI response');
        }
        budget.text(latex.runes.length);
        final double size = _number(item['size']);
        if (size < config.minTextSize || size > config.maxTextSize) {
          throw const FormatException('Invalid AI response');
        }
        return AiNotationMath(
          math: NotationMath.parse(latex),
          x: _unit(item['x']),
          y: _unit(item['y']),
          size: size,
          ink: _ink(item['ink'], config),
          width: _width(item['width'], config),
        );
      case 'graph':
        final Map<String, Object?> item = _object(raw, const <String>{
          'type',
          'formula',
          'x_from',
          'x_to',
          'y_from',
          'y_to',
          'left',
          'top',
          'right',
          'bottom',
          'axes',
          'ink',
          'width',
        });
        final Object? formula = item['formula'];
        if (formula is! String ||
            formula.length > config.maxFormulaLength ||
            item['axes'] is! bool) {
          throw const FormatException('Invalid AI response');
        }
        final double xFrom = _range(item['x_from'], config);
        final double xTo = _range(item['x_to'], config);
        final Object? rawYFrom = item['y_from'];
        final Object? rawYTo = item['y_to'];
        if ((rawYFrom == null) != (rawYTo == null)) {
          throw const FormatException('Invalid AI response');
        }
        final double? yFrom = rawYFrom == null
            ? null
            : _range(rawYFrom, config);
        final double? yTo = rawYTo == null ? null : _range(rawYTo, config);
        final double left = _unit(item['left']);
        final double top = _unit(item['top']);
        final double right = _unit(item['right']);
        final double bottom = _unit(item['bottom']);
        if (xFrom >= xTo ||
            (yFrom != null && yFrom >= yTo!) ||
            left >= right ||
            top >= bottom) {
          throw const FormatException('Invalid AI response');
        }
        return AiNotationGraph(
          formula: NotationFormula.parse(formula),
          xFrom: xFrom,
          xTo: xTo,
          yFrom: yFrom,
          yTo: yTo,
          left: left,
          top: top,
          right: right,
          bottom: bottom,
          axes: item['axes']! as bool,
          ink: _ink(item['ink'], config),
          width: _width(item['width'], config),
        );
      case 'plot':
        final Map<String, Object?> item = _object(raw, const <String>{
          'type',
          'left',
          'top',
          'right',
          'bottom',
          'x_from',
          'x_to',
          'y_from',
          'y_to',
          'axes',
          'ticks',
          'children',
          'ink',
          'width',
        });
        final Object? axes = item['axes'];
        final Object? ticks = item['ticks'];
        final Object? rawChildren = item['children'];
        if (axes is! bool ||
            ticks is! bool ||
            rawChildren is! List<Object?> ||
            rawChildren.length > config.maxPlotChildren) {
          throw const FormatException('Invalid AI response');
        }
        final double xFrom = _range(item['x_from'], config);
        final double xTo = _range(item['x_to'], config);
        final Object? rawYFrom = item['y_from'];
        final Object? rawYTo = item['y_to'];
        if ((rawYFrom == null) != (rawYTo == null)) {
          throw const FormatException('Invalid AI response');
        }
        final double? yFrom = rawYFrom == null
            ? null
            : _range(rawYFrom, config);
        final double? yTo = rawYTo == null ? null : _range(rawYTo, config);
        final double left = _unit(item['left']);
        final double top = _unit(item['top']);
        final double right = _unit(item['right']);
        final double bottom = _unit(item['bottom']);
        if (xFrom >= xTo ||
            (yFrom != null && yFrom >= yTo!) ||
            left >= right ||
            top >= bottom) {
          throw const FormatException('Invalid AI response');
        }
        return AiNotationPlot(
          left: left,
          top: top,
          right: right,
          bottom: bottom,
          xFrom: xFrom,
          xTo: xTo,
          yFrom: yFrom,
          yTo: yTo,
          axes: axes,
          ticks: ticks,
          children: <AiPlotChild>[
            for (final Object? child in rawChildren)
              _plotChild(child, config, budget),
          ],
          ink: _ink(item['ink'], config),
          width: _width(item['width'], config),
        );
      case 'path':
        final Map<String, Object?> item = _object(raw, const <String>{
          'type',
          'points',
          'segments',
          'closed',
          'line_style',
          'arrow',
          'ink',
          'width',
        });
        final Object? closed = item['closed'];
        final AiArrow arrow = _arrow(item['arrow']);
        if (closed is! bool || (closed && arrow != AiArrow.none)) {
          throw const FormatException('Invalid AI response');
        }
        final List<AiNotationPoint> points = _points(
          item['points'],
          max: config.maxPathPoints,
          budget: budget,
        );
        final Object? rawSegments = item['segments'];
        final int gaps = closed ? points.length : points.length - 1;
        if (points.length < 2 ||
            rawSegments is! List<Object?> ||
            rawSegments.length != gaps) {
          throw const FormatException('Invalid AI response');
        }
        return AiNotationPath(
          points: points,
          segments: <AiPathSegment>[
            for (final Object? segment in rawSegments)
              switch (segment) {
                'straight' => AiPathSegment.straight,
                'curve' => AiPathSegment.curve,
                _ => throw const FormatException('Invalid AI response'),
              },
          ],
          closed: closed,
          lineStyle: _lineStyle(item['line_style']),
          arrow: arrow,
          ink: _ink(item['ink'], config),
          width: _width(item['width'], config),
        );
      case 'line':
        final Map<String, Object?> item = _object(raw, const <String>{
          'type',
          'from',
          'to',
          'line_style',
          'arrow',
          'ink',
          'width',
        });
        final AiNotationPoint from = _pointOf(_xy(item['from']));
        final AiNotationPoint to = _pointOf(_xy(item['to']));
        if (from.x == to.x && from.y == to.y) {
          throw const FormatException('Invalid AI response');
        }
        return AiNotationLine(
          from: from,
          to: to,
          lineStyle: _lineStyle(item['line_style']),
          arrow: _arrow(item['arrow']),
          ink: _ink(item['ink'], config),
          width: _width(item['width'], config),
        );
      case 'shape':
        final Map<String, Object?> item = _object(raw, const <String>{
          'type',
          'shape',
          'left',
          'top',
          'right',
          'bottom',
          'line_style',
          'ink',
          'width',
        });
        final AiShapeKind shape = AiShapeKind.values.firstWhere(
          (AiShapeKind kind) => kind.wire == item['shape'],
          orElse: () => throw const FormatException('Invalid AI response'),
        );
        final double left = _unit(item['left']);
        final double top = _unit(item['top']);
        final double right = _unit(item['right']);
        final double bottom = _unit(item['bottom']);
        if (left >= right || top >= bottom) {
          throw const FormatException('Invalid AI response');
        }
        return AiNotationShape(
          shape: shape,
          left: left,
          top: top,
          right: right,
          bottom: bottom,
          lineStyle: _lineStyle(item['line_style']),
          ink: _ink(item['ink'], config),
          width: _width(item['width'], config),
        );
      case 'stroke':
        final Map<String, Object?> item = _object(raw, const <String>{
          'type',
          'points',
          'ink',
          'width',
        });
        return AiNotationStroke(
          points: _points(
            item['points'],
            max: config.maxPointsPerStroke,
            budget: budget,
          ),
          ink: _ink(item['ink'], config),
          width: _width(item['width'], config),
        );
      default:
        throw const FormatException('Invalid AI response');
    }
  }

  static AiPlotChild _plotChild(
    Object? raw,
    AiNotationConfig config,
    _Budget budget,
  ) {
    if (raw is! Map<String, Object?>) {
      throw const FormatException('Invalid AI response');
    }
    switch (raw['type']) {
      case 'function':
        final Map<String, Object?> item = _object(
          raw,
          const <String>{'type', 'formula', 'ink'},
          optional: const <String>{'line_style', 'marks'},
        );
        final Object rawMarks = item['marks'] ?? const <Object?>[];
        if (rawMarks is! List<Object?>) {
          throw const FormatException('Invalid AI response');
        }
        return AiPlotFunction(
          formula: _formula(item['formula'], config),
          lineStyle: item.containsKey('line_style')
              ? _lineStyle(item['line_style'])
              : AiLineStyle.solid,
          marks: <AiPlotMark>{
            for (final Object? mark in rawMarks)
              AiPlotMark.values.firstWhere(
                (AiPlotMark kind) => kind.wire == mark,
                orElse: () =>
                    throw const FormatException('Invalid AI response'),
              ),
          }.toList(),
          ink: _ink(item['ink'], config),
        );
      case 'point':
        final Map<String, Object?> item = _object(
          raw,
          const <String>{'type', 'x', 'y', 'ink'},
          optional: const <String>{'label'},
        );
        final Object? label = item['label'];
        return AiPlotDot(
          at: AiPlotPoint(_range(item['x'], config), _range(item['y'], config)),
          label: label == null ? null : _plotText(label, config, budget),
          ink: _ink(item['ink'], config),
        );
      case 'segment':
        final Map<String, Object?> item = _object(
          raw,
          const <String>{'type', 'from', 'to', 'ink'},
          optional: const <String>{'line_style', 'arrow'},
        );
        final AiPlotPoint from = _plotPoint(item['from'], config);
        final AiPlotPoint to = _plotPoint(item['to'], config);
        if (from.x == to.x && from.y == to.y) {
          throw const FormatException('Invalid AI response');
        }
        return AiPlotSegment(
          from: from,
          to: to,
          lineStyle: item.containsKey('line_style')
              ? _lineStyle(item['line_style'])
              : AiLineStyle.solid,
          arrow: item.containsKey('arrow')
              ? _arrow(item['arrow'])
              : AiArrow.none,
          ink: _ink(item['ink'], config),
        );
      case 'label':
        final Map<String, Object?> item = _object(raw, const <String>{
          'type',
          'x',
          'y',
          'text',
          'ink',
        });
        return AiPlotLabel(
          at: AiPlotPoint(_range(item['x'], config), _range(item['y'], config)),
          text: _plotText(item['text'], config, budget),
          ink: _ink(item['ink'], config),
        );
      case 'shade':
        final Map<String, Object?> item = _object(
          raw,
          const <String>{'type', 'formula', 'from', 'to', 'ink'},
          optional: const <String>{'base'},
        );
        final double from = _range(item['from'], config);
        final double to = _range(item['to'], config);
        if (from >= to) {
          throw const FormatException('Invalid AI response');
        }
        final Object? base = item['base'];
        return AiPlotShade(
          formula: _formula(item['formula'], config),
          base: base == null ? null : _formula(base, config),
          from: from,
          to: to,
          ink: _ink(item['ink'], config),
        );
      case 'intersections':
        final Map<String, Object?> item = _object(raw, const <String>{
          'type',
          'of',
          'ink',
        });
        final Object? of = item['of'];
        if (of is! List<Object?> || of.length != 2) {
          throw const FormatException('Invalid AI response');
        }
        return AiPlotIntersections(
          first: _formula(of[0], config),
          second: _formula(of[1], config),
          ink: _ink(item['ink'], config),
        );
      default:
        throw const FormatException('Invalid AI response');
    }
  }

  static NotationFormula _formula(Object? raw, AiNotationConfig config) {
    if (raw is! String || raw.length > config.maxFormulaLength) {
      throw const FormatException('Invalid AI response');
    }
    return NotationFormula.parse(raw);
  }

  /// Text the app writes in a plot: one the font can write, counted toward
  /// the notation's text.
  static String _plotText(
    Object? raw,
    AiNotationConfig config,
    _Budget budget,
  ) {
    if (raw is! String ||
        raw.trim().isEmpty ||
        raw.runes.length > config.maxTextRunes ||
        !NotationFont.canWrite(raw)) {
      throw const FormatException('Invalid AI response');
    }
    budget.text(raw.runes.length);
    return raw;
  }

  static AiPlotPoint _plotPoint(Object? raw, AiNotationConfig config) {
    final Map<String, Object?> point = _xy(raw);
    return AiPlotPoint(_range(point['x'], config), _range(point['y'], config));
  }

  /// A point given as {"x": x, "y": y}, or as [x, y], which models not
  /// held to the schema often write, as {"x": x, "y": y}.
  static Map<String, Object?> _xy(Object? raw) {
    if (raw is List<Object?> && raw.length == 2) {
      return <String, Object?>{'x': raw[0], 'y': raw[1]};
    }
    return _object(raw, const <String>{'x', 'y'});
  }

  static List<AiNotationPoint> _points(
    Object? raw, {
    required int max,
    required _Budget budget,
  }) {
    if (raw is! List<Object?> || raw.isEmpty || raw.length > max) {
      throw const FormatException('Invalid AI response');
    }
    budget.points(raw.length);
    return <AiNotationPoint>[
      for (final Object? rawPoint in raw) _pointOf(_xy(rawPoint)),
    ];
  }

  static AiNotationPoint _pointOf(Map<String, Object?> point) {
    return AiNotationPoint(_unit(point['x']), _unit(point['y']));
  }

  static AiLineStyle _lineStyle(Object? value) {
    return AiLineStyle.values.firstWhere(
      (AiLineStyle style) => style.name == value,
      orElse: () => throw const FormatException('Invalid AI response'),
    );
  }

  static AiArrow _arrow(Object? value) {
    return AiArrow.values.firstWhere(
      (AiArrow arrow) => arrow.name == value,
      orElse: () => throw const FormatException('Invalid AI response'),
    );
  }

  static String _ink(Object? value, AiNotationConfig config) {
    if (value is! String || !config.inkIds.contains(value)) {
      throw const FormatException('Invalid AI response');
    }
    return value;
  }

  static double _width(Object? value, AiNotationConfig config) {
    final double width = _number(value);
    if (width < config.minWidth || width > config.maxWidth) {
      throw const FormatException('Invalid AI response');
    }
    return width;
  }

  /// A normalized coordinate, from 0 through 1.
  static double _unit(Object? value) {
    final double unit = _number(value);
    if (unit < 0 || unit > 1) {
      throw const FormatException('Invalid AI response');
    }
    return unit;
  }

  /// A coordinate in a formula's own units.
  static double _range(Object? value, AiNotationConfig config) {
    final double number = _number(value);
    if (number.abs() > config.maxGraphCoordinate) {
      throw const FormatException('Invalid AI response');
    }
    return number;
  }

  /// The `message` written so far in [source], the start of a response
  /// still being streamed: the decoded text of the top-level `message`
  /// string, complete or not, or null until it has begun. Display only:
  /// nothing is validated, and the finished text goes through [parse].
  static String? partialMessage(String source) {
    return partialMessageState(source)?.$1;
  }

  /// [partialMessage], and whether its closing quote has arrived: after
  /// that, only the notation is still to come.
  static (String, bool)? partialMessageState(String source) {
    if (_looksLikeSvgResponse(source)) {
      final RegExp start = RegExp(
        r'''<desc\b[^>]*data-etonia-role=["']message["'][^>]*>''',
        caseSensitive: false,
      );
      final RegExpMatch? match = start.firstMatch(source);
      if (match == null) return null;
      final int bodyStart = match.end;
      final int end = source.indexOf('</desc>', bodyStart);
      final String raw = end < 0
          ? source.substring(bodyStart)
          : source.substring(bodyStart, end);
      return (_decodeXmlText(raw), end >= 0);
    }
    source = repairLatexEscapes(source);
    int depth = 0;
    String? key;
    bool afterColon = false;
    int i = 0;
    while (i < source.length) {
      final int unit = source.codeUnitAt(i);
      if (unit == 0x22) {
        final (String text, int end, bool closed) = _readString(source, i + 1);
        if (depth == 1) {
          if (afterColon && key == 'message') {
            return (text, closed);
          }
          if (!afterColon) {
            key = text;
          }
        }
        if (!closed) {
          return null;
        }
        i = end;
        continue;
      }
      switch (unit) {
        case 0x7B || 0x5B: // { [
          depth++;
        case 0x7D || 0x5D: // } ]
          depth--;
        case 0x3A when depth == 1: // :
          afterColon = true;
        case 0x2C when depth == 1: // ,
          afterColon = false;
          key = null;
      }
      i++;
    }
    return null;
  }

  static bool _looksLikeSvgResponse(String source) {
    String head = source.trimLeft().replaceFirst('\uFEFF', '');
    if (head.startsWith('```')) {
      final int lineEnd = head.indexOf('\n');
      if (lineEnd < 0) return false;
      head = head.substring(lineEnd + 1).trimLeft();
    }
    return RegExp(
      r'^(?:<\?xml\b[^>]*>\s*)?<svg\b',
      caseSensitive: false,
    ).hasMatch(head);
  }

  static String _decodeXmlText(String source) {
    try {
      return XmlDocument.parse('<text>$source</text>').rootElement.innerText;
    } on Object {
      return source
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&amp;', '&');
    }
  }

  /// Decodes the JSON string whose contents start at [start]: its text, the
  /// index after its closing quote, and whether it was closed. An escape
  /// cut off by the end of [source] is left out.
  static (String, int, bool) _readString(String source, int start) {
    final StringBuffer text = StringBuffer();
    int i = start;
    while (i < source.length) {
      final int unit = source.codeUnitAt(i);
      if (unit == 0x22) {
        return (text.toString(), i + 1, true);
      }
      if (unit != 0x5C) {
        text.writeCharCode(unit);
        i++;
        continue;
      }
      if (i + 1 >= source.length) {
        break;
      }
      final String escape = source[i + 1];
      if (escape == 'u') {
        if (i + 6 > source.length) {
          break;
        }
        final int? code = int.tryParse(
          source.substring(i + 2, i + 6),
          radix: 16,
        );
        if (code == null) {
          break;
        }
        text.writeCharCode(code);
        i += 6;
        continue;
      }
      text.write(switch (escape) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        'b' => '\b',
        'f' => '\f',
        _ => escape,
      });
      i += 2;
    }
    return (text.toString(), source.length, false);
  }

  /// [value] as an object with every key in [expected], any of [optional],
  /// and nothing else.
  static Map<String, Object?> _object(
    Object? value,
    Set<String> expected, {
    Set<String> optional = const <String>{},
  }) {
    if (value is! Map<String, Object?> ||
        !value.keys.toSet().containsAll(expected) ||
        value.keys.any(
          (String key) => !expected.contains(key) && !optional.contains(key),
        )) {
      throw const FormatException('Invalid AI response');
    }
    return value;
  }

  static double _number(Object? value) {
    if (value is! num) {
      throw const FormatException('Invalid AI response');
    }
    final double result = value.toDouble();
    if (!result.isFinite) {
      throw const FormatException('Invalid AI response');
    }
    return result;
  }
}

/// What one notation has used of the limits that span its items.
class _Budget {
  _Budget(this._config);

  final AiNotationConfig _config;
  int _points = 0;
  int _characters = 0;

  void points(int count) {
    _points += count;
    if (_points > _config.maxTotalPoints) {
      throw const FormatException('Invalid AI response');
    }
  }

  void text(int characters) {
    _characters += characters;
    if (_characters > _config.maxTotalTextRunes) {
      throw const FormatException('Invalid AI response');
    }
  }
}

/// Local outcome of a model notation. Never serialized to the provider.
enum AiNotationStatus {
  none,

  /// Added to the note, and being drawn there over time. Becomes [applied]
  /// when the drawing finishes or is skipped.
  animating,
  applied,

  /// The request was sent with Notation off.
  notAppliedNotationOff,

  /// Notation was turned off while the request was in flight.
  notAppliedRevoked,
  notAppliedStale,
  notAppliedBusy,
  notAppliedInvalid,

  /// The answer's words arrived, but it broke off, or timed out, before its
  /// drawing was complete.
  notAppliedIncomplete,
}

extension AiNotationStatusText on AiNotationStatus {
  String? get message => switch (this) {
    AiNotationStatus.none => null,
    AiNotationStatus.animating => 'Drawing…',
    AiNotationStatus.applied => 'Added to note',
    AiNotationStatus.notAppliedNotationOff => 'Not applied — Notation is off',
    AiNotationStatus.notAppliedRevoked =>
      'Not applied — Notation was turned off',
    AiNotationStatus.notAppliedStale => 'Not applied — the note changed',
    AiNotationStatus.notAppliedBusy =>
      'Not applied — finish the current gesture and try again',
    AiNotationStatus.notAppliedInvalid =>
      'Not applied — the drawing ran off the page or could not be read',
    AiNotationStatus.notAppliedIncomplete =>
      'Not applied — the drawing did not finish. Ask again for it.',
  };
}

/// A notation already added to the note and being drawn there over time.
/// Presentation only: the note holds all of it from the start.
abstract interface class AiNotationPresentation {
  /// Completes once, when the drawing has finished or been skipped.
  Future<void> get done;

  /// Shows the whole drawing now. Does nothing once [done].
  void finish();
}

/// What became of one notation the assistant tried to add.
class AiNotationApplication {
  const AiNotationApplication(
    this.status, {
    this.presentation,
    this.strokes = const <Stroke>[],
  }) : assert((status == AiNotationStatus.animating) == (presentation != null));

  final AiNotationStatus status;

  /// The strokes added to the note, so that selecting them later finds the
  /// conversation that drew them. Empty when nothing was added.
  final List<Stroke> strokes;

  /// The drawing in progress, when [status] is
  /// [AiNotationStatus.animating].
  final AiNotationPresentation? presentation;
}

/// Closed JSON Schema sent to Gemini and mirrored by [AiAssistantResponse.parse].
///
/// It carries no `maxItems`: the Gemma endpoints answer any schema that
/// does with 400 or 500, so the counts are enforced only by the parser,
/// along with the limits a schema cannot state, such as text the font can
/// write and a formula that reads. An animation's `step` is optional: an
/// item without one is fixed, shown whole while the stepped items move.
Map<String, Object?> aiResponseJsonSchema([
  AiNotationConfig config = const AiNotationConfig(),
]) {
  /// A closed object that needs every one of [properties], and may also
  /// have any of [optional].
  Map<String, Object?> object(
    Map<String, Object?> properties, {
    Map<String, Object?> optional = const <String, Object?>{},
    String? description,
  }) {
    return <String, Object?>{
      'type': 'object',
      'description': ?description,
      'additionalProperties': false,
      'properties': <String, Object?>{...properties, ...optional},
      'required': properties.keys.toList(),
    };
  }

  final Map<String, Object?> itemTiming = <String, Object?>{
    'step': <String, Object?>{
      'type': 'integer',
      'minimum': 1,
      'maximum': config.maxSteps,
      'description':
          'Animation only, and only for something that moves or changes: '
          'the order this item is drawn in, lowest first; items with the '
          'same step are drawn together. Leave it out on fixed items, such '
          'as labels, axes, and the figure things move over: they are '
          'shown at once and stay still.',
    },
  };

  Map<String, Object?> type(String name) {
    return <String, Object?>{
      'type': 'string',
      'enum': <String>[name],
    };
  }

  Map<String, Object?> unit() {
    return <String, Object?>{'type': 'number', 'minimum': 0, 'maximum': 1};
  }

  final Map<String, Object?> ink = <String, Object?>{
    'type': 'string',
    'enum': config.inkIds,
  };
  final Map<String, Object?> width = <String, Object?>{
    'type': 'number',
    'minimum': config.minWidth,
    'maximum': config.maxWidth,
  };
  final Map<String, Object?> points = <String, Object?>{
    'type': 'array',
    'minItems': 1,
    'items': object(<String, Object?>{'x': unit(), 'y': unit()}),
  };
  Map<String, Object?> choice(Iterable<String> values) {
    return <String, Object?>{'type': 'string', 'enum': values.toList()};
  }

  final Map<String, Object?> lineStyle = choice(
    AiLineStyle.values.map((AiLineStyle style) => style.name),
  );
  final Map<String, Object?> arrow = choice(
    AiArrow.values.map((AiArrow arrow) => arrow.name),
  );
  final Map<String, Object?> point = object(<String, Object?>{
    'x': unit(),
    'y': unit(),
  });
  final Map<String, Object?> nullableNumber = <String, Object?>{
    'anyOf': <Object?>[
      <String, Object?>{'type': 'null'},
      <String, Object?>{'type': 'number'},
    ],
  };
  final Map<String, Object?> formula = <String, Object?>{
    'type': 'string',
    'minLength': 1,
  };
  final Map<String, Object?> number = <String, Object?>{'type': 'number'};
  final Map<String, Object?> plotPoint = object(<String, Object?>{
    'x': number,
    'y': number,
  });
  final List<Object?> plotChildren = <Object?>[
    object(
      <String, Object?>{
        'type': type('function'),
        'formula': formula,
        'ink': ink,
      },
      optional: <String, Object?>{
        'line_style': lineStyle,
        'marks': <String, Object?>{
          'type': 'array',
          'items': choice(AiPlotMark.values.map((AiPlotMark m) => m.wire)),
        },
      },
      description:
          "A formula's curve; marks name features the app finds and labels.",
    ),
    object(
      <String, Object?>{
        'type': type('point'),
        'x': number,
        'y': number,
        'ink': ink,
      },
      optional: <String, Object?>{
        'label': <String, Object?>{'type': 'string', 'minLength': 1},
      },
      description: 'A dot, optionally labelled.',
    ),
    object(
      <String, Object?>{
        'type': type('segment'),
        'from': plotPoint,
        'to': plotPoint,
        'ink': ink,
      },
      optional: <String, Object?>{'line_style': lineStyle, 'arrow': arrow},
      description: 'A straight line between two points of the plot.',
    ),
    object(<String, Object?>{
      'type': type('label'),
      'x': number,
      'y': number,
      'text': <String, Object?>{'type': 'string', 'minLength': 1},
      'ink': ink,
    }, description: 'Words just above and right of a point.'),
    object(
      <String, Object?>{
        'type': type('shade'),
        'formula': formula,
        'from': number,
        'to': number,
        'ink': ink,
      },
      optional: <String, Object?>{'base': formula},
      description: 'Hatching between a curve and base (default y = 0).',
    ),
    object(<String, Object?>{
      'type': type('intersections'),
      'of': <String, Object?>{'type': 'array', 'minItems': 2, 'items': formula},
      'ink': ink,
    }, description: 'Marks and labels where two curves meet.'),
  ];
  final List<Object?> items = <Object?>[
    object(
      <String, Object?>{
        'type': type('text'),
        'text': <String, Object?>{
          'type': 'string',
          'minLength': 1,
          'maxLength': config.maxTextRunes,
        },
        'x': unit(),
        'y': unit(),
        'size': <String, Object?>{
          'type': 'number',
          'minimum': config.minTextSize,
          'maximum': config.maxTextSize,
        },
        'ink': ink,
        'width': width,
      },
      optional: itemTiming,
      description:
          'A short label or key step, written in the app handwriting; at '
          'most ${config.maxTextRunes} characters.',
    ),
    object(
      <String, Object?>{
        'type': type('math'),
        'latex': <String, Object?>{
          'type': 'string',
          'minLength': 1,
          'maxLength': config.maxMathRunes,
        },
        'x': unit(),
        'y': unit(),
        'size': <String, Object?>{
          'type': 'number',
          'minimum': config.minTextSize,
          'maximum': config.maxTextSize,
        },
        'ink': ink,
        'width': width,
      },
      optional: itemTiming,
      description:
          'A formula in LaTeX, without \$, laid out and handwritten by the '
          'app; x and y are its top-left corner.',
    ),
    object(
      <String, Object?>{
        'type': type('graph'),
        'formula': <String, Object?>{'type': 'string', 'minLength': 1},
        'x_from': <String, Object?>{'type': 'number'},
        'x_to': <String, Object?>{'type': 'number'},
        'y_from': nullableNumber,
        'y_to': nullableNumber,
        'left': unit(),
        'top': unit(),
        'right': unit(),
        'bottom': unit(),
        'axes': <String, Object?>{'type': 'boolean'},
        'ink': ink,
        'width': width,
      },
      optional: itemTiming,
      description: 'The graph of a formula in x, drawn by the app.',
    ),
    object(
      <String, Object?>{
        'type': type('plot'),
        'left': unit(),
        'top': unit(),
        'right': unit(),
        'bottom': unit(),
        'x_from': <String, Object?>{'type': 'number'},
        'x_to': <String, Object?>{'type': 'number'},
        'y_from': nullableNumber,
        'y_to': nullableNumber,
        'axes': <String, Object?>{'type': 'boolean'},
        'ticks': <String, Object?>{'type': 'boolean'},
        'children': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{'anyOf': plotChildren},
        },
        'ink': ink,
        'width': width,
      },
      optional: itemTiming,
      description:
          'A coordinate plane in a box; its children are placed in its own '
          'x and y.',
    ),
    object(
      <String, Object?>{
        'type': type('path'),
        'points': <String, Object?>{...points, 'minItems': 2},
        'segments': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{
            'type': 'string',
            'enum': <String>['straight', 'curve'],
          },
        },
        'closed': <String, Object?>{'type': 'boolean'},
        'line_style': lineStyle,
        'arrow': arrow,
        'ink': ink,
        'width': width,
      },
      optional: itemTiming,
      description: 'A freehand graph or shape through key points.',
    ),
    object(
      <String, Object?>{
        'type': type('line'),
        'from': point,
        'to': point,
        'line_style': lineStyle,
        'arrow': arrow,
        'ink': ink,
        'width': width,
      },
      optional: itemTiming,
      description: 'A straight line, dashed or dotted, or an arrow.',
    ),
    object(
      <String, Object?>{
        'type': type('shape'),
        'shape': choice(
          AiShapeKind.values.map((AiShapeKind kind) => kind.wire),
        ),
        'left': unit(),
        'top': unit(),
        'right': unit(),
        'bottom': unit(),
        'line_style': lineStyle,
        'ink': ink,
        'width': width,
      },
      optional: itemTiming,
      description: 'A simple shape drawn to fill a box.',
    ),
    object(
      <String, Object?>{
        'type': type('stroke'),
        'points': points,
        'ink': ink,
        'width': width,
      },
      optional: itemTiming,
      description: 'One pen stroke through the given points.',
    ),
  ];
  final Map<String, Object?> notation = object(
    <String, Object?>{
      'label': <String, Object?>{
        'type': 'string',
        'minLength': 1,
        'maxLength': config.maxLabelRunes,
        'description': 'A short description of the drawing.',
      },
      'coordinate_space': choice(<String>[
        AiNotation.coordinateSpace,
        AiNotation.stickyCoordinateSpace,
      ]),
      'items': <String, Object?>{
        'type': 'array',
        'minItems': 1,
        'items': <String, Object?>{'anyOf': items},
      },
    },
    optional: <String, Object?>{
      'sticky': object(
        <String, Object?>{
          'width': <String, Object?>{
            'type': 'number',
            'minimum': config.minStickyWidth,
            'maximum': config.maxStickyWidth,
          },
          'height': <String, Object?>{
            'type': 'number',
            'minimum': config.minStickyHeight,
            'maximum': config.maxStickyHeight,
          },
        },
        description:
            'Only when the note has no room: draw on a new sticky note '
            'this big, in logical units, with coordinate_space '
            'sticky_normalized.',
      ),
    },
  );
  return <String, Object?>{
    'type': 'object',
    'additionalProperties': false,
    // The readable answer first, so it is written, and can be shown, before
    // the drawing; then everything the app needs to draw.
    'properties': <String, Object?>{
      'message': <String, Object?>{
        'type': 'string',
        'minLength': 1,
        'description': 'The readable assistant answer, in Markdown.',
      },
      'version': <String, Object?>{
        'type': 'integer',
        'enum': <int>[AiAssistantResponse.version],
      },
      'notation': <String, Object?>{
        'description':
            'What to write and draw on the note, or null for a simple text '
            'answer.',
        'anyOf': <Object?>[
          <String, Object?>{'type': 'null'},
          notation,
        ],
      },
    },
    'required': <String>['message', 'version', 'notation'],
  };
}
