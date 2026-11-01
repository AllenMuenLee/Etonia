import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import '../ink/ink_notation.dart';
import '../ink/ink_sample.dart';
import 'ai_config.dart';

/// Keeps what an AI notation writes off ink already on the paper (the
/// assistant's earlier notes, and the user's own when given), and off what
/// it has already written itself: each piece of text that would land on, or
/// crowd, either is moved the shortest way clear, within [reach], on the
/// paper. Text that finds no clear place within reach stays where it was.
/// Lines, arrows, and shapes are not moved: they are meant to touch ink.
class NotationClearance {
  NotationClearance({
    required this.pageSize,
    Iterable<SpaceStroke> ink = const <SpaceStroke>[],
    this.gap = 6,
    this.reach = 240,
    this.step = 6,
  }) : _grid = _Grid(
         pageSize,
         math.max(1, (pageSize.width / _cell(pageSize)).ceil()),
         math.max(1, (pageSize.height / _cell(pageSize)).ceil()),
       ) {
    for (final SpaceStroke stroke in ink) {
      _grid.markStroke(stroke.points, stroke.width / 2);
    }
    final int width = _grid.columns + 1;
    _sums = Int32List(width * (_grid.rows + 1));
    for (int row = 0; row < _grid.rows; row++) {
      int line = 0;
      for (int column = 0; column < _grid.columns; column++) {
        line += _grid.cells[row * _grid.columns + column];
        _sums[(row + 1) * width + column + 1] =
            _sums[row * width + column + 1] + line;
      }
    }
  }

  final Size pageSize;

  /// The clear space kept round each piece of text, in logical units.
  final double gap;

  /// The furthest a piece of text is moved, and the steps it is moved in.
  final double reach;
  final double step;

  final _Grid _grid;
  late final Int32List _sums;

  /// What this notation has written so far.
  final List<Rect> _written = <Rect>[];

  /// Fine enough to tell a letter from the space beside it.
  static double _cell(Size page) =>
      math.max(4, math.max(page.width, page.height) / 400);

  /// [text], the strokes of one piece of writing, moved clear if it would
  /// land on earlier notes or earlier writing; otherwise as it is.
  List<GeneratedInkTrace> place(List<GeneratedInkTrace> text) {
    final Rect? box = _bounds(text);
    if (box == null) {
      return text;
    }
    final Offset shift = clear(box);
    if (shift == Offset.zero) {
      return text;
    }
    return <GeneratedInkTrace>[
      for (final GeneratedInkTrace trace in text)
        GeneratedInkTrace(
          style: trace.style,
          points: <InkVector>[
            for (final InkVector point in trace.points)
              InkVector(point.x + shift.dx, point.y + shift.dy),
          ],
          timesMs: trace.timesMs,
          widths: trace.widths,
        ),
    ];
  }

  /// How far [box], one piece of writing, must move to keep [gap] (or this
  /// clearance's own) clear of the ink and of what has been written: the
  /// shortest move within [reach] that keeps it on the paper, or none when
  /// it is clear already or nowhere within reach is. It counts as written
  /// there from now on.
  Offset clear(Rect box, {double? gap}) {
    final double room = gap ?? this.gap;
    // A little inside the edge: a pen's pressure can widen it past its width.
    final Rect paper = (Offset.zero & pageSize).deflate(2);
    Offset shift = Offset.zero;
    if (!_isClear(box, room)) {
      // Rings of growing radius: the nearest clear place wins.
      search:
      for (double radius = step; radius <= reach; radius += step) {
        final int directions = math.max(
          8,
          (2 * math.pi * radius / step).ceil(),
        );
        for (int i = 0; i < directions; i++) {
          final double angle = 2 * math.pi * i / directions;
          final Offset candidate = Offset(
            radius * math.cos(angle),
            radius * math.sin(angle),
          );
          final Rect moved = box.shift(candidate);
          if (_contains(paper, moved) && _isClear(moved, room)) {
            shift = candidate;
            break search;
          }
        }
      }
    }
    _written.add(box.shift(shift));
    return shift;
  }

  /// Counts [box] as written where it is, without moving it: a label that
  /// must stay on the spot the model chose.
  void reserve(Rect box) => _written.add(box);

  bool _isClear(Rect box, double gap) {
    final Rect padded = box.inflate(gap);
    for (final Rect written in _written) {
      if (written.overlaps(padded)) {
        return false;
      }
    }
    final int width = _grid.columns + 1;
    final int left = (padded.left / _grid.cellWidth).floor().clamp(
      0,
      _grid.columns,
    );
    final int top = (padded.top / _grid.cellHeight).floor().clamp(
      0,
      _grid.rows,
    );
    final int right = (padded.right / _grid.cellWidth).ceil().clamp(
      0,
      _grid.columns,
    );
    final int bottom = (padded.bottom / _grid.cellHeight).ceil().clamp(
      0,
      _grid.rows,
    );
    return _sums[bottom * width + right] -
            _sums[top * width + right] -
            _sums[bottom * width + left] +
            _sums[top * width + left] ==
        0;
  }

  static bool _contains(Rect outer, Rect inner) =>
      inner.left >= outer.left &&
      inner.top >= outer.top &&
      inner.right <= outer.right &&
      inner.bottom <= outer.bottom;

  /// The box round [traces]' ink, pen width included; null without ink.
  static Rect? _bounds(List<GeneratedInkTrace> traces) {
    double left = double.infinity;
    double top = double.infinity;
    double right = double.negativeInfinity;
    double bottom = double.negativeInfinity;
    for (final GeneratedInkTrace trace in traces) {
      final double half = trace.style.width / 2;
      for (final InkVector point in trace.points) {
        left = math.min(left, point.x - half);
        top = math.min(top, point.y - half);
        right = math.max(right, point.x + half);
        bottom = math.max(bottom, point.y + half);
      }
    }
    return left.isFinite ? Rect.fromLTRB(left, top, right, bottom) : null;
  }
}

/// One blank area of the paper the model may draw in: a box, or an L made
/// of a box and an arm running off one end of it. Page-local logical units.
class FreeArea {
  FreeArea(List<Rect> parts) : parts = List<Rect>.unmodifiable(parts);

  /// The box, then the arm, if any.
  final List<Rect> parts;

  bool get isL => parts.length == 2;

  Rect get bounds => isL ? parts[0].expandToInclude(parts[1]) : parts[0];
}

/// One pen stroke, as far as finding blank paper is concerned.
typedef SpaceStroke = ({List<InkVector> points, double width});

/// A page-wide picture under the ink, such as a PDF page, as RGBA pixels
/// stretched over [bounds]. Whatever is printed on it is not blank.
class SpaceBackground {
  const SpaceBackground({
    required this.bounds,
    required this.width,
    required this.height,
    required this.rgba,
  });

  final Rect bounds;
  final int width;
  final int height;
  final Uint8List rgba;
}

/// A box of grid cells: columns [left, right), rows [top, bottom).
class _Box {
  const _Box(this.left, this.top, this.right, this.bottom);

  final int left;
  final int top;
  final int right;
  final int bottom;

  int get columns => right - left;
  int get rows => bottom - top;
}

/// Where a note's paper is blank: the areas the model is told it may draw
/// in, nearest the selection first, and where a sticky note goes when none
/// is big enough.
///
/// The paper is looked at as a grid of cells. A cell is taken when ink, an
/// image, a sticky note, or print on the page's background reaches within
/// [AiSpaceConfig.clearance] of it, or it is within
/// [AiSpaceConfig.edgeMargin] of the paper's edge.
class NoteFreeSpace {
  NoteFreeSpace._(
    this._columns,
    this._rows,
    this._taken, {
    required this.pageSize,
    required this.focus,
    required this.areas,
    required this.nearby,
    required this.yourNotes,
    required this.config,
  });

  factory NoteFreeSpace.measure({
    required Size pageSize,
    Iterable<SpaceStroke> strokes = const <SpaceStroke>[],
    Iterable<Rect> blocks = const <Rect>[],
    Iterable<SpaceBackground> backgrounds = const <SpaceBackground>[],
    Iterable<SpaceStroke> aiNotes = const <SpaceStroke>[],
    Rect? focus,
    AiSpaceConfig config = const AiSpaceConfig(),
  }) {
    final double cell = math.max(
      config.cellSize,
      math.max(pageSize.width, pageSize.height) / config.maxCells,
    );
    final int columns = math.max(1, (pageSize.width / cell).ceil());
    final int rows = math.max(1, (pageSize.height / cell).ceil());
    final _Grid grid = _Grid(pageSize, columns, rows);
    for (final SpaceStroke stroke in strokes) {
      grid.markStroke(stroke.points, stroke.width / 2);
    }
    for (final Rect block in blocks) {
      grid.markRect(block);
    }
    for (final SpaceBackground background in backgrounds) {
      grid.markBackground(background, config.backgroundInkThreshold);
    }
    final Rect? usableFocus = focus == null || !focus.isFinite || focus.isEmpty
        ? null
        : focus;
    grid.dilate(
      (config.clearance / grid.cellWidth).ceil(),
      (config.clearance / grid.cellHeight).ceil(),
    );
    final List<Rect> nearby = usableFocus == null
        ? const <Rect>[]
        : _nearby(grid, usableFocus, config);
    grid.markEdges(
      (config.edgeMargin / grid.cellWidth).ceil(),
      (config.edgeMargin / grid.cellHeight).ceil(),
    );
    final Uint8List taken = Uint8List.fromList(grid.cells);
    final List<FreeArea> areas = _findAreas(grid, usableFocus, config);
    return NoteFreeSpace._(
      columns,
      rows,
      taken,
      pageSize: pageSize,
      focus: usableFocus,
      areas: areas,
      nearby: nearby,
      yourNotes: _yourNotes(
        pageSize,
        columns,
        rows,
        aiNotes,
        usableFocus,
        config,
      ),
      config: config,
    );
  }

  final Size pageSize;

  /// The selected region the areas are ranked by nearness to, if any.
  final Rect? focus;

  /// What else is on the paper near [focus], nearest first: one box round
  /// each group of ink, picture, sticky note, or print, within
  /// [AiSpaceConfig.nearbyReach] of it and not wholly inside it. The model
  /// is told these in place of a picture of the page. Empty without a
  /// focus.
  final List<Rect> nearby;

  /// What the assistant has already written and drawn on the paper, one box
  /// round each group of it, nearest the selection first: places it must
  /// never write over. At most [AiSpaceConfig.maxNearby].
  final List<Rect> yourNotes;

  /// Nearest and biggest first. Empty when no blank area is big enough.
  final List<FreeArea> areas;

  final AiSpaceConfig config;

  final int _columns;
  final int _rows;
  final Uint8List _taken;

  bool get hasRoom => areas.isNotEmpty;

  double get _cellWidth => pageSize.width / _columns;
  double get _cellHeight => pageSize.height / _rows;

  /// Where a sticky note of [wanted] size goes: on the paper, within its
  /// edge margin, near the selection, covering as little as it can of the
  /// selection first and then of anything else. Shrunk, keeping its shape,
  /// when the paper is too small for it.
  Rect placeSticky(Size wanted) {
    final double margin = config.edgeMargin;
    final double roomWidth = math.max(1, pageSize.width - 2 * margin);
    final double roomHeight = math.max(1, pageSize.height - 2 * margin);
    final double shrink = math.min(
      1,
      math.min(roomWidth / wanted.width, roomHeight / wanted.height),
    );
    final Size size = Size(wanted.width * shrink, wanted.height * shrink);
    final double maxLeft = pageSize.width - margin - size.width;
    final double maxTop = pageSize.height - margin - size.height;
    final Int32List sums = _summedTaken();
    final double cellArea = _cellWidth * _cellHeight;
    Rect? best;
    double bestCost = double.infinity;
    for (int row = 0; row < _rows; row++) {
      final double top = math.min(math.max(margin, row * _cellHeight), maxTop);
      for (int column = 0; column < _columns; column++) {
        final double left = math.min(
          math.max(margin, column * _cellWidth),
          maxLeft,
        );
        final Rect rect = Rect.fromLTWH(left, top, size.width, size.height);
        final double covered = _takenIn(sums, rect) * cellArea;
        final Rect? selected = focus;
        double cost = covered;
        if (selected != null) {
          final Rect overlap = rect.intersect(selected);
          if (overlap.width > 0 && overlap.height > 0) {
            cost += 4 * overlap.width * overlap.height;
          }
          cost += 2 * _distance(rect, selected);
        }
        if (cost < bestCost) {
          bestCost = cost;
          best = rect;
        }
      }
    }
    return best ??
        Rect.fromLTWH(
          math.max(0, maxLeft),
          math.max(0, maxTop),
          size.width,
          size.height,
        );
  }

  /// Taken cells, summed over every box from the top-left: entry
  /// (row, column) of a grid one larger each way.
  Int32List _summedTaken() {
    final int width = _columns + 1;
    final Int32List sums = Int32List(width * (_rows + 1));
    for (int row = 0; row < _rows; row++) {
      int line = 0;
      for (int column = 0; column < _columns; column++) {
        line += _taken[row * _columns + column];
        sums[(row + 1) * width + column + 1] =
            sums[row * width + column + 1] + line;
      }
    }
    return sums;
  }

  /// Taken cells [rect] reaches into.
  int _takenIn(Int32List sums, Rect rect) {
    final int width = _columns + 1;
    final int left = (rect.left / _cellWidth).floor().clamp(0, _columns);
    final int top = (rect.top / _cellHeight).floor().clamp(0, _rows);
    final int right = (rect.right / _cellWidth).ceil().clamp(0, _columns);
    final int bottom = (rect.bottom / _cellHeight).ceil().clamp(0, _rows);
    return sums[bottom * width + right] -
        sums[top * width + right] -
        sums[bottom * width + left] +
        sums[top * width + left];
  }

  /// The boxes of [NoteFreeSpace.nearby], from [grid] taken with its
  /// clearance, which joins the strokes of a word or a line into one group.
  /// The boxes of [NoteFreeSpace.yourNotes]: [aiNotes] grouped as the
  /// rest of the ink is, on a grid of their own.
  static List<Rect> _yourNotes(
    Size pageSize,
    int columns,
    int rows,
    Iterable<SpaceStroke> aiNotes,
    Rect? focus,
    AiSpaceConfig config,
  ) {
    if (aiNotes.isEmpty) {
      return const <Rect>[];
    }
    final _Grid grid = _Grid(pageSize, columns, rows);
    for (final SpaceStroke stroke in aiNotes) {
      grid.markStroke(stroke.points, stroke.width / 2);
    }
    grid.dilate(
      (config.clearance / grid.cellWidth).ceil(),
      (config.clearance / grid.cellHeight).ceil(),
    );
    final Rect anchor = focus ?? Offset.zero & pageSize;
    final List<Rect> boxes = _shrunkGroups(grid, config)
      ..sort(
        (Rect a, Rect b) =>
            _distance(a, anchor).compareTo(_distance(b, anchor)),
      );
    return boxes.take(config.maxNearby).toList();
  }

  /// A box round each group of taken cells in [grid], which was grown by
  /// the clearance, shrunk back by as many whole cells: within a cell of
  /// what it holds.
  static List<Rect> _shrunkGroups(_Grid grid, AiSpaceConfig config) {
    final double across =
        (config.clearance / grid.cellWidth).ceil() * grid.cellWidth;
    final double down =
        (config.clearance / grid.cellHeight).ceil() * grid.cellHeight;
    return <Rect>[
      for (final _Box box in grid.groups())
        Rect.fromLTRB(
          math.max(0, box.left * grid.cellWidth + across),
          math.max(0, box.top * grid.cellHeight + down),
          math.min(grid.pageSize.width, box.right * grid.cellWidth - across),
          math.min(grid.pageSize.height, box.bottom * grid.cellHeight - down),
        ),
    ].where((Rect r) => !r.isEmpty).toList();
  }

  static List<Rect> _nearby(_Grid grid, Rect focus, AiSpaceConfig config) {
    final List<(Rect, double)> found = <(Rect, double)>[];
    for (final Rect rect in _shrunkGroups(grid, config)) {
      final Rect inside = rect.intersect(focus);
      if (inside == rect) {
        continue;
      }
      final double distance = _distance(rect, focus);
      if (distance <= config.nearbyReach) {
        found.add((rect, distance));
      }
    }
    found.sort(((Rect, double) a, (Rect, double) b) => a.$2.compareTo(b.$2));
    return <Rect>[
      for (final (Rect rect, double _) in found.take(config.maxNearby)) rect,
    ];
  }

  static List<FreeArea> _findAreas(
    _Grid grid,
    Rect? focus,
    AiSpaceConfig config,
  ) {
    final double cellWidth = grid.cellWidth;
    final double cellHeight = grid.cellHeight;
    Rect rectOf(_Box box) => Rect.fromLTRB(
      box.left * cellWidth,
      box.top * cellHeight,
      box.right * cellWidth,
      box.bottom * cellHeight,
    );
    final double diagonal = grid.pageSize.longestSide * math.sqrt2;
    double score(Rect rect) {
      final double area = rect.width * rect.height;
      if (focus == null) {
        return area;
      }
      final double far =
          1 + _distance(rect, focus) / (config.nearness * diagonal);
      return area / (far * far);
    }

    // An arm is as thick as a box is tall, both ways.
    final int thinColumns = (config.minHeight / cellWidth).ceil();
    final int thinRows = (config.minHeight / cellHeight).ceil();
    final double minArea = config.minWidth * config.minHeight;
    bool isBox(_Box box) {
      return box.columns * cellWidth >= config.minWidth - 1e-6 &&
          box.rows * cellHeight >= config.minHeight - 1e-6;
    }

    bool isArm(_Box arm) {
      final Rect rect = rectOf(arm);
      return rect.shortestSide >= config.minHeight - 1e-6 &&
          rect.width * rect.height >= minArea - 1e-6;
    }

    final List<FreeArea> areas = <FreeArea>[];
    while (areas.length < config.maxAreas) {
      final List<_Box> boxes = grid.blankBoxes(thinColumns, thinRows);
      _Box? main;
      double best = 0;
      for (final _Box box in boxes) {
        if (!isBox(box)) continue;
        final double value = score(rectOf(box));
        if (value > best) {
          best = value;
          main = box;
        }
      }
      if (main == null) {
        break;
      }
      _Box? arm;
      double armArea = 0;
      for (final _Box other in boxes) {
        for (final _Box candidate in _armsOff(main, other)) {
          final double area = candidate.columns * candidate.rows.toDouble();
          if (area > armArea && isArm(candidate)) {
            armArea = area;
            arm = candidate;
          }
        }
      }
      areas.add(FreeArea(<Rect>[rectOf(main), if (arm != null) rectOf(arm)]));
      grid.markBox(main);
      if (arm != null) {
        grid.markBox(arm);
      }
    }
    return areas;
  }

  /// The parts of blank box [other] that would make an L with [main]: an
  /// arm running up or down off one end of a wider [main], or left or right
  /// off one end of a taller one.
  static Iterable<_Box> _armsOff(_Box main, _Box other) sync* {
    final bool vertical =
        other.columns < main.columns &&
        other.left >= main.left &&
        other.right <= main.right &&
        (other.left == main.left || other.right == main.right) &&
        other.top <= main.bottom &&
        other.bottom >= main.top;
    if (vertical) {
      if (other.bottom > main.bottom) {
        yield _Box(other.left, main.bottom, other.right, other.bottom);
      }
      if (other.top < main.top) {
        yield _Box(other.left, other.top, other.right, main.top);
      }
    }
    final bool horizontal =
        other.rows < main.rows &&
        other.top >= main.top &&
        other.bottom <= main.bottom &&
        (other.top == main.top || other.bottom == main.bottom) &&
        other.left <= main.right &&
        other.right >= main.left;
    if (horizontal) {
      if (other.right > main.right) {
        yield _Box(main.right, other.top, other.right, other.bottom);
      }
      if (other.left < main.left) {
        yield _Box(other.left, other.top, main.left, other.bottom);
      }
    }
  }
}

/// How far apart [a] and [b] are: 0 when they touch or overlap.
double _distance(Rect a, Rect b) {
  final double dx = math.max(0, math.max(a.left - b.right, b.left - a.right));
  final double dy = math.max(0, math.max(a.top - b.bottom, b.top - a.bottom));
  return math.sqrt(dx * dx + dy * dy);
}

/// The paper's cells, 1 where taken.
class _Grid {
  _Grid(this.pageSize, this.columns, this.rows)
    : cells = Uint8List(columns * rows);

  final Size pageSize;
  final int columns;
  final int rows;
  final Uint8List cells;

  double get cellWidth => pageSize.width / columns;
  double get cellHeight => pageSize.height / rows;

  void _mark(double left, double top, double right, double bottom) {
    if (!(left.isFinite && top.isFinite && right.isFinite && bottom.isFinite)) {
      return;
    }
    final int c0 = (left / cellWidth).floor().clamp(0, columns - 1);
    final int c1 = (right / cellWidth).floor().clamp(0, columns - 1);
    final int r0 = (top / cellHeight).floor().clamp(0, rows - 1);
    final int r1 = (bottom / cellHeight).floor().clamp(0, rows - 1);
    if (right < 0 ||
        bottom < 0 ||
        left > pageSize.width ||
        top > pageSize.height) {
      return;
    }
    for (int row = r0; row <= r1; row++) {
      for (int column = c0; column <= c1; column++) {
        cells[row * columns + column] = 1;
      }
    }
  }

  void markRect(Rect rect) {
    _mark(rect.left, rect.top, rect.right, rect.bottom);
  }

  void markBox(_Box box) {
    for (int row = box.top; row < box.bottom; row++) {
      for (int column = box.left; column < box.right; column++) {
        cells[row * columns + column] = 1;
      }
    }
  }

  /// Every cell the stroke's ink, [radius] either side of its line, falls
  /// in.
  void markStroke(List<InkVector> points, double radius) {
    if (points.isEmpty) {
      return;
    }
    final double step = math.min(cellWidth, cellHeight) / 2;
    void dot(double x, double y) {
      _mark(x - radius, y - radius, x + radius, y + radius);
    }

    dot(points.first.x, points.first.y);
    for (int i = 1; i < points.length; i++) {
      final InkVector a = points[i - 1];
      final InkVector b = points[i];
      final double length = (b - a).length;
      if (!length.isFinite) {
        continue;
      }
      final int samples = math.max(1, (length / step).ceil());
      for (int s = 1; s <= samples; s++) {
        final double t = s / samples;
        dot(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
      }
    }
  }

  void markBackground(SpaceBackground background, int threshold) {
    final Rect bounds = background.bounds;
    final int width = background.width;
    final int height = background.height;
    final Uint8List rgba = background.rgba;
    if (width <= 0 ||
        height <= 0 ||
        rgba.length < width * height * 4 ||
        bounds.isEmpty ||
        !bounds.isFinite) {
      return;
    }
    final int limit = 255 - threshold;
    final double scaleX = bounds.width / width;
    final double scaleY = bounds.height / height;
    for (int y = 0; y < height; y++) {
      final double pageY = bounds.top + (y + 0.5) * scaleY;
      if (pageY < 0 || pageY >= pageSize.height) continue;
      final int row = (pageY / cellHeight).floor();
      for (int x = 0; x < width; x++) {
        final int i = (y * width + x) * 4;
        // Transparent, or near white: blank paper.
        if (rgba[i + 3] < 128 ||
            (rgba[i] >= limit &&
                rgba[i + 1] >= limit &&
                rgba[i + 2] >= limit)) {
          continue;
        }
        final double pageX = bounds.left + (x + 0.5) * scaleX;
        if (pageX < 0 || pageX >= pageSize.width) continue;
        cells[row * columns + (pageX / cellWidth).floor()] = 1;
      }
    }
  }

  /// Grows every taken cell by [across] columns and [down] rows each way.
  void dilate(int across, int down) {
    if (across > 0) {
      final Uint8List source = Uint8List.fromList(cells);
      for (int row = 0; row < rows; row++) {
        int lastTaken = -1 << 30;
        // Left to right, then right to left, so each cell sees its nearest
        // taken neighbour on both sides.
        for (int column = 0; column < columns; column++) {
          if (source[row * columns + column] == 1) lastTaken = column;
          if (column - lastTaken <= across) cells[row * columns + column] = 1;
        }
        lastTaken = 1 << 30;
        for (int column = columns - 1; column >= 0; column--) {
          if (source[row * columns + column] == 1) lastTaken = column;
          if (lastTaken - column <= across) cells[row * columns + column] = 1;
        }
      }
    }
    if (down > 0) {
      final Uint8List source = Uint8List.fromList(cells);
      for (int column = 0; column < columns; column++) {
        int lastTaken = -1 << 30;
        for (int row = 0; row < rows; row++) {
          if (source[row * columns + column] == 1) lastTaken = row;
          if (row - lastTaken <= down) cells[row * columns + column] = 1;
        }
        lastTaken = 1 << 30;
        for (int row = rows - 1; row >= 0; row--) {
          if (source[row * columns + column] == 1) lastTaken = row;
          if (lastTaken - row <= down) cells[row * columns + column] = 1;
        }
      }
    }
  }

  /// Takes the cells within [across] columns and [down] rows of the edge.
  void markEdges(int across, int down) {
    for (int row = 0; row < rows; row++) {
      for (int column = 0; column < columns; column++) {
        if (column < across ||
            column >= columns - across ||
            row < down ||
            row >= rows - down) {
          cells[row * columns + column] = 1;
        }
      }
    }
  }

  /// The box round each group of taken cells that touch side by side.
  List<_Box> groups() {
    final Uint8List seen = Uint8List(cells.length);
    final List<int> pending = <int>[];
    final List<_Box> boxes = <_Box>[];
    for (int start = 0; start < cells.length; start++) {
      if (cells[start] == 0 || seen[start] == 1) {
        continue;
      }
      int left = columns;
      int top = rows;
      int right = 0;
      int bottom = 0;
      seen[start] = 1;
      pending.add(start);
      while (pending.isNotEmpty) {
        final int cell = pending.removeLast();
        final int row = cell ~/ columns;
        final int column = cell % columns;
        left = math.min(left, column);
        top = math.min(top, row);
        right = math.max(right, column + 1);
        bottom = math.max(bottom, row + 1);
        void visit(int next) {
          if (cells[next] == 1 && seen[next] == 0) {
            seen[next] = 1;
            pending.add(next);
          }
        }

        if (column > 0) visit(cell - 1);
        if (column < columns - 1) visit(cell + 1);
        if (row > 0) visit(cell - columns);
        if (row < rows - 1) visit(cell + columns);
      }
      boxes.add(_Box(left, top, right, bottom));
    }
    return boxes;
  }

  /// Blank boxes at least [minColumns] by [minRows]: for each row as a
  /// bottom edge, the widest box of each height that fits there.
  List<_Box> blankBoxes(int minColumns, int minRows) {
    final Int32List heights = Int32List(columns);
    final Int32List lefts = Int32List(columns);
    final Int32List rights = Int32List(columns);
    final List<int> stack = <int>[];
    final Set<int> seen = <int>{};
    final List<_Box> boxes = <_Box>[];
    for (int row = 0; row < rows; row++) {
      for (int column = 0; column < columns; column++) {
        heights[column] = cells[row * columns + column] == 0
            ? heights[column] + 1
            : 0;
      }
      stack.clear();
      for (int column = 0; column < columns; column++) {
        while (stack.isNotEmpty && heights[stack.last] >= heights[column]) {
          stack.removeLast();
        }
        lefts[column] = stack.isEmpty ? 0 : stack.last + 1;
        stack.add(column);
      }
      stack.clear();
      for (int column = columns - 1; column >= 0; column--) {
        while (stack.isNotEmpty && heights[stack.last] >= heights[column]) {
          stack.removeLast();
        }
        rights[column] = stack.isEmpty ? columns : stack.last;
        stack.add(column);
      }
      for (int column = 0; column < columns; column++) {
        final int height = heights[column];
        final int left = lefts[column];
        final int right = rights[column];
        if (height < minRows || right - left < minColumns) {
          continue;
        }
        final int top = row + 1 - height;
        final int key =
            ((left * (columns + 1) + right) * (rows + 1) + top) * (rows + 1) +
            row +
            1;
        if (seen.add(key)) {
          boxes.add(_Box(left, top, right, row + 1));
        }
      }
    }
    return boxes;
  }
}
