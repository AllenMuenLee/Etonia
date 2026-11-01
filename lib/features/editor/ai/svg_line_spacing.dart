import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:xml/xml.dart';

/// One piece of text an SVG notation writes, as [SvgLineSpacing] sees it:
/// the box its line takes, capitals to descenders, and the box round the
/// ink actually written; its baseline; its size, the height of a capital;
/// and whether it is pinned to the spot the model chose.
typedef SpacedText = ({
  Rect line,
  Rect ink,
  double baseline,
  double size,
  bool pinned,
});

/// Keeps the lines a model writes in an SVG notation far enough apart to
/// read at a glance and to write between.
///
/// The model places each line itself and cannot measure handwriting, so
/// lines of working and memos often come out crowded, and a fraction or a
/// sum with limits runs into the line below it. Every line that shares
/// columns with a line above and sits closer than [leading] to it is moved
/// down, and the lines below it follow as far as they must. Lines that are
/// spaced well are left where the model put them; text beside a line, on
/// the same baseline, moves with it.
abstract final class SvgLineSpacing {
  /// The clear space kept between one line's descenders and the capitals
  /// of the line below, in text sizes: lines of plain text end up two sizes
  /// apart, baseline to baseline.
  static const double leading = 0.7;

  /// The least [leading] is narrowed to when the paper is too short for it.
  static const double minLeading = 0.3;

  /// How far each of [texts] is moved down, in order; negative is up. The
  /// widest spacing, from [leading] down to [minLeading], that keeps every
  /// moved line on [paper]: lines are moved down from the top line, or,
  /// where the paper ends too soon below, up from the bottom one. Nothing
  /// moves when neither fits.
  static List<double> drops(List<SpacedText> texts, Rect paper) {
    bool fits(List<double> result) {
      for (int i = 0; i < texts.length; i++) {
        final Rect box = texts[i].line
            .expandToInclude(texts[i].ink)
            .translate(0, result[i]);
        if ((result[i] > 0 && box.bottom > paper.bottom) ||
            (result[i] < 0 && box.top < paper.top)) {
          return false;
        }
      }
      return true;
    }

    for (double gap = leading; gap >= minLeading - 1e-9; gap -= 0.1) {
      for (final bool up in <bool>[false, true]) {
        final List<double> result = _drops(texts, gap, up: up);
        if (fits(result)) return result;
      }
    }
    return List<double>.filled(texts.length, 0);
  }

  /// Moves that keep [gap] text sizes between lines, rows taken in turn
  /// from the top down, or with [up] from the bottom up.
  static List<double> _drops(
    List<SpacedText> texts,
    double gap, {
    required bool up,
  }) {
    final List<double> drops = List<double>.filled(texts.length, 0);
    final List<int> placed = <int>[];
    final List<List<int>> rows = _rows(texts);
    for (final List<int> row in up ? rows.reversed : rows) {
      double drop = 0;
      if (!row.every((int i) => texts[i].pinned)) {
        for (final int b in row) {
          final Rect moving = texts[b].line;
          for (final int a in placed) {
            final Rect still = texts[a].line.translate(0, drops[a]);
            if (still.right <= moving.left || moving.right <= still.left) {
              continue;
            }
            final double room = gap * math.max(texts[a].size, texts[b].size);
            drop = up
                ? math.min(drop, still.top - room - moving.bottom)
                : math.max(drop, still.bottom + room - moving.top);
          }
        }
      }
      for (final int i in row) {
        drops[i] = drop;
        placed.add(i);
      }
    }
    return drops;
  }

  /// [texts] grouped into rows, top row first: texts on one baseline, side
  /// by side, share a row. Two that overlap there do not.
  static List<List<int>> _rows(List<SpacedText> texts) {
    final List<int> order = <int>[for (int i = 0; i < texts.length; i++) i]
      ..sort((int a, int b) => texts[a].baseline.compareTo(texts[b].baseline));
    final List<List<int>> rows = <List<int>>[];
    for (final int i in order) {
      final SpacedText text = texts[i];
      List<int>? home;
      for (final List<int> row in rows) {
        final SpacedText first = texts[row.first];
        final double size = math.max(first.size, text.size);
        if ((first.baseline - text.baseline).abs() > 0.25 * size) continue;
        if (row.every(
          (int j) =>
              texts[j].line.right <= text.line.left ||
              text.line.right <= texts[j].line.left,
        )) {
          home = row;
          break;
        }
      }
      if (home == null) {
        rows.add(<int>[i]);
      } else {
        home.add(i);
      }
    }
    double top(List<int> row) =>
        row.map((int i) => texts[i].line.top).reduce(math.min);
    return rows..sort((List<int> a, List<int> b) => top(a).compareTo(top(b)));
  }

  /// Moves the marks drawn for a piece of text along with it: under [root],
  /// a line, shape, or path lying wholly within the [zone] round a moved
  /// text's ink, such as its underline or the ring round it, is moved [by]
  /// as much as the text, and the end of a `line` that lies there, such as a
  /// leader pointing at it, follows on its own. Returns the box round what
  /// moved, where it now is, or null when nothing did.
  ///
  /// Anything transformed, or inside defs or handwriting, is left alone.
  static Rect? carry(XmlElement root, List<({Rect zone, Offset by})> moves) {
    if (moves.isEmpty) return null;
    Rect? moved;
    void grow(Rect box) {
      moved = moved == null ? box : moved!.expandToInclude(box);
    }

    for (final XmlElement element
        in root.descendants.whereType<XmlElement>().toList()) {
      if (!_movable(element)) continue;
      final List<(double, double)>? points = _points(element);
      if (points == null || points.isEmpty) continue;
      final Rect box = _box(points);
      ({Rect zone, Offset by})? home;
      for (final ({Rect zone, Offset by}) move in moves) {
        if (move.zone.contains(box.topLeft) &&
            move.zone.contains(box.bottomRight) &&
            (home == null || move.zone.height < home.zone.height)) {
          home = move;
        }
      }
      if (home != null) {
        element.setAttribute(
          'transform',
          'translate(${home.by.dx == 0 ? '0' : _text(home.by.dx)} '
              '${_text(home.by.dy)})',
        );
        grow(box.shift(home.by));
        continue;
      }
      if (element.name.local != 'line') continue;
      for (final (String x, String y) in <(String, String)>[
        ('x1', 'y1'),
        ('x2', 'y2'),
      ]) {
        final double? px = _number(element.getAttribute(x));
        final double? py = _number(element.getAttribute(y));
        if (px == null || py == null) continue;
        for (final ({Rect zone, Offset by}) move in moves) {
          if (move.zone.contains(Offset(px, py))) {
            final Offset end = Offset(px, py) + move.by;
            element.setAttribute(x, _text(end.dx));
            element.setAttribute(y, _text(end.dy));
            grow(Rect.fromPoints(end, end));
            break;
          }
        }
      }
    }
    return moved;
  }

  static bool _movable(XmlElement element) {
    if (!const <String>{
      'line',
      'polyline',
      'polygon',
      'path',
      'rect',
      'circle',
      'ellipse',
    }.contains(element.name.local)) {
      return false;
    }
    XmlElement? node = element;
    while (node != null) {
      if (node.getAttribute('transform') != null ||
          node.getAttribute('data-etonia-handwriting') != null ||
          const <String>{
            'defs',
            'marker',
            'clipPath',
            'mask',
            'pattern',
            'symbol',
          }.contains(node.name.local)) {
        return false;
      }
      node = node.parent is XmlElement ? node.parent as XmlElement : null;
    }
    return true;
  }

  /// The points that bound [element], or null when it cannot be measured,
  /// as a path with relative, arc, or one-axis commands cannot.
  static List<(double, double)>? _points(XmlElement element) {
    double? get(String name) => _number(element.getAttribute(name));
    switch (element.name.local) {
      case 'line':
        final double? x1 = get('x1'), y1 = get('y1');
        final double? x2 = get('x2'), y2 = get('y2');
        if (x1 == null || y1 == null || x2 == null || y2 == null) return null;
        return <(double, double)>[(x1, y1), (x2, y2)];
      case 'rect':
        final double x = get('x') ?? 0, y = get('y') ?? 0;
        final double? width = get('width'), height = get('height');
        if (width == null || height == null) return null;
        return <(double, double)>[(x, y), (x + width, y + height)];
      case 'circle':
        final double x = get('cx') ?? 0, y = get('cy') ?? 0;
        final double? r = get('r');
        if (r == null) return null;
        return <(double, double)>[(x - r, y - r), (x + r, y + r)];
      case 'ellipse':
        final double x = get('cx') ?? 0, y = get('cy') ?? 0;
        final double? rx = get('rx'), ry = get('ry');
        if (rx == null || ry == null) return null;
        return <(double, double)>[(x - rx, y - ry), (x + rx, y + ry)];
      case 'polyline' || 'polygon':
        return _pairs(element.getAttribute('points') ?? '');
      case 'path':
        final String data = element.getAttribute('d') ?? '';
        if (RegExp(r'[^MLCSQTZ\d\s,.eE+-]').hasMatch(data)) return null;
        return _pairs(data);
    }
    return null;
  }

  static List<(double, double)>? _pairs(String source) {
    final List<double> values = <double>[
      for (final RegExpMatch match in RegExp(
        r'[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?',
      ).allMatches(source))
        double.parse(match.group(0)!),
    ];
    if (values.isEmpty || values.length.isOdd) return null;
    return <(double, double)>[
      for (int i = 0; i < values.length; i += 2) (values[i], values[i + 1]),
    ];
  }

  static Rect _box(List<(double, double)> points) {
    double left = double.infinity, top = double.infinity;
    double right = double.negativeInfinity, bottom = double.negativeInfinity;
    for (final (double x, double y) in points) {
      left = math.min(left, x);
      top = math.min(top, y);
      right = math.max(right, x);
      bottom = math.max(bottom, y);
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  static double? _number(String? source) =>
      source == null ? null : double.tryParse(source.trim());

  static String _text(double value) =>
      double.parse(value.toStringAsFixed(4)).toString();
}
