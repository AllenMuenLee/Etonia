import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:xml/xml.dart';

import '../ink/ink_sample.dart';
import 'selection_image_renderer.dart';

/// One line of a selection SVG that a citation can name: a stroke, or a slice
/// of a picture or printed page.
class SelectionSvgLine {
  const SelectionSvgLine({
    required this.line,
    required this.bounds,
    this.strokeIndex,
    this.byAssistant = false,
  });

  /// One-based, counting the root element's line as the first.
  final int line;

  /// In page coordinates.
  final ui.Rect bounds;

  /// Its stroke's place in the snapshot's strokes; null for a slice.
  final int? strokeIndex;

  /// Whether the assistant's own notation drew it, rather than the user.
  final bool byAssistant;

  String get _kind => strokeIndex == null
      ? 'region'
      : byAssistant
      ? 'ai'
      : 'note';
}

/// A selection SVG, and what its citable lines hold.
class SelectionSvgDocument {
  const SelectionSvgDocument(this.svg, this.lines);

  final String svg;
  final List<SelectionSvgLine> lines;
}

/// Serializes the selected part of a note in the note's own coordinate space.
///
/// Every element is on a line of its own and names that line in
/// `data-etonia-line`, so that an answer can cite the lines it refers to.
///
/// Native ink stays vector. A selection containing raster paper, an image, or
/// a sticky note uses the already privacy-cropped preview as one embedded PNG,
/// cut by unpainted slices so that part of it can be cited; the transport is
/// still a self-contained SVG and never exposes pixels outside
/// [SelectionImage.logicalBounds].
class SelectionSvgRenderer {
  const SelectionSvgRenderer({this.maxBytes = 6000000});

  final int maxBytes;

  /// The root's line, the title's, and the description's come first.
  static const int _firstContentLine = 4;

  /// The tallest slice of a picture a citation can name, and the most slices.
  static const double _sliceHeight = 48;
  static const int _maxSlices = 40;

  /// The most rows [outline] writes, whatever the selection holds.
  static const int maxOutlineRows = 200;

  String render({
    required SelectionInkSnapshot snapshot,
    required SelectionImage preview,
    required ui.Size pageSize,
  }) {
    return document(
      snapshot: snapshot,
      preview: preview,
      pageSize: pageSize,
    ).svg;
  }

  /// The lines [document] would write for [snapshot], without writing its
  /// paths: all that is needed to cite when no SVG is sent.
  List<SelectionSvgLine> lineIndex({
    required SelectionInkSnapshot snapshot,
    required SelectionImage preview,
    Set<int> assistantStrokes = const <int>{},
  }) {
    return snapshot.bitmaps.isNotEmpty || snapshot.stickies.isNotEmpty
        ? _rasterLines(
            preview.logicalBounds,
            snapshot.strokes,
            assistantStrokes,
          )
        : _vectorLines(snapshot.strokes, assistantStrokes);
  }

  /// [lines] as the model that writes the words reads them: consecutive
  /// strokes written along the same line of the note share a row, so a page
  /// of handwriting costs few tokens, and each row reads as a line of the
  /// picture. Never more than [maxOutlineRows] rows.
  static String outline(List<SelectionSvgLine> lines) {
    List<_OutlineRow> rows = <_OutlineRow>[];
    for (final SelectionSvgLine line in lines) {
      if (rows.isNotEmpty && rows.last.takes(line)) {
        rows.last.add(line);
      } else {
        rows.add(_OutlineRow(line));
      }
    }
    while (rows.length > maxOutlineRows) {
      final List<_OutlineRow> next = <_OutlineRow>[];
      bool joined = false;
      for (final _OutlineRow row in rows) {
        // Each row joins at most one other on a pass, so the rows stay even.
        if (next.isNotEmpty && !joined && next.last.kind == row.kind) {
          next.last.absorb(row);
          joined = true;
        } else {
          next.add(row);
          joined = false;
        }
      }
      if (next.length == rows.length) break;
      rows = next;
    }
    return rows.map((_OutlineRow row) => row.text).join('\n');
  }

  SelectionSvgDocument document({
    required SelectionInkSnapshot snapshot,
    required SelectionImage preview,
    required ui.Size pageSize,
    Set<int> assistantStrokes = const <int>{},
  }) {
    if (!pageSize.isFinite || pageSize.isEmpty) {
      throw const FormatException('Invalid SVG page size');
    }
    final ui.Rect bounds = preview.logicalBounds;
    if (!bounds.isFinite || bounds.isEmpty) {
      throw const FormatException('Invalid SVG selection bounds');
    }

    // Raster-backed content cannot be reconstructed as paths. Embed only the
    // cropped preview, never a page-wide source bitmap. The same fallback is
    // used for an exceptionally large vector selection.
    if (snapshot.bitmaps.isNotEmpty || snapshot.stickies.isNotEmpty) {
      return _raster(
        preview,
        pageSize,
        strokes: snapshot.strokes,
        assistantStrokes: assistantStrokes,
      );
    }

    final List<SelectionSvgLine> lines = _vectorLines(
      snapshot.strokes,
      assistantStrokes,
    );
    final String svg = _build(pageSize, bounds, (XmlBuilder builder) {
      _nextLine(builder);
      builder.element(
        'rect',
        attributes: <String, String>{
          'x': _n(bounds.left),
          'y': _n(bounds.top),
          'width': _n(bounds.width),
          'height': _n(bounds.height),
          'fill': _color(snapshot.background),
          'fill-opacity': _n(snapshot.background.a),
          'data-etonia-role': 'paper',
        },
      );
      _writeLines(builder, lines, snapshot.strokes);
    });
    if (utf8.encode(svg).length <= maxBytes) {
      return SelectionSvgDocument(svg, lines);
    }
    return _raster(preview, pageSize);
  }

  /// The citable lines of an SVG holding the paper, then [strokes].
  static List<SelectionSvgLine> _vectorLines(
    List<SnapshotStroke> strokes,
    Set<int> assistantStrokes,
  ) {
    return <SelectionSvgLine>[
      for (int i = 0; i < strokes.length; i++)
        SelectionSvgLine(
          line: _firstContentLine + 1 + i,
          bounds: _boundsOf(strokes[i]),
          strokeIndex: i,
          byAssistant: assistantStrokes.contains(i),
        ),
    ];
  }

  /// The citable lines of an SVG holding the picture, slices of it, then
  /// [strokes].
  static List<SelectionSvgLine> _rasterLines(
    ui.Rect bounds,
    List<SnapshotStroke> strokes,
    Set<int> assistantStrokes,
  ) {
    final int slices = (bounds.height / _sliceHeight).ceil().clamp(
      1,
      _maxSlices,
    );
    final double height = bounds.height / slices;
    return <SelectionSvgLine>[
      for (int i = 0; i < slices; i++)
        SelectionSvgLine(
          line: _firstContentLine + 1 + i,
          bounds: ui.Rect.fromLTWH(
            bounds.left,
            bounds.top + height * i,
            bounds.width,
            height,
          ),
        ),
      for (int i = 0; i < strokes.length; i++)
        SelectionSvgLine(
          line: _firstContentLine + 1 + slices + i,
          bounds: _boundsOf(strokes[i]),
          strokeIndex: i,
          byAssistant: assistantStrokes.contains(i),
        ),
    ];
  }

  static ui.Rect _boundsOf(SnapshotStroke stroke) {
    if (stroke.points.isEmpty) return ui.Rect.zero;
    double left = stroke.points.first.x;
    double right = left;
    double top = stroke.points.first.y;
    double bottom = top;
    for (final InkVector point in stroke.points) {
      if (point.x < left) left = point.x;
      if (point.x > right) right = point.x;
      if (point.y < top) top = point.y;
      if (point.y > bottom) bottom = point.y;
    }
    return ui.Rect.fromLTRB(
      left,
      top,
      right,
      bottom,
    ).inflate(stroke.width.isFinite ? stroke.width / 2 : 0);
  }

  static void _nextLine(XmlBuilder builder) => builder.text('\n');

  static void _writeLines(
    XmlBuilder builder,
    List<SelectionSvgLine> lines,
    List<SnapshotStroke> strokes,
  ) {
    for (final SelectionSvgLine line in lines) {
      _nextLine(builder);
      final int? index = line.strokeIndex;
      if (index == null) {
        builder.element(
          'rect',
          attributes: <String, String>{
            'x': _n(line.bounds.left),
            'y': _n(line.bounds.top),
            'width': _n(line.bounds.width),
            'height': _n(line.bounds.height),
            'fill': 'none',
            'stroke': 'none',
            'data-etonia-role': 'region',
            'data-etonia-line': '${line.line}',
          },
        );
      } else {
        _writeStroke(builder, strokes[index], line);
      }
    }
  }

  String _build(
    ui.Size pageSize,
    ui.Rect bounds,
    void Function(XmlBuilder builder) children,
  ) {
    final XmlBuilder builder = XmlBuilder();
    builder.element(
      'svg',
      attributes: <String, String>{
        'xmlns': 'http://www.w3.org/2000/svg',
        'viewBox': '0 0 ${_n(pageSize.width)} ${_n(pageSize.height)}',
        'width': _n(pageSize.width),
        'height': _n(pageSize.height),
        'data-etonia-version': '1',
        'data-etonia-coordinate-space': 'note',
        'data-etonia-selection-bounds': <double>[
          bounds.left,
          bounds.top,
          bounds.width,
          bounds.height,
        ].map(_n).join(' '),
      },
      nest: () {
        _nextLine(builder);
        builder.element('title', nest: 'Selected note context');
        _nextLine(builder);
        builder.element(
          'desc',
          nest:
              'Existing user-selected note content in page logical '
              'coordinates.',
        );
        children(builder);
        _nextLine(builder);
      },
    );
    return builder.buildDocument().rootElement.toXmlString(pretty: false);
  }

  SelectionSvgDocument _raster(
    SelectionImage preview,
    ui.Size pageSize, {
    List<SnapshotStroke> strokes = const <SnapshotStroke>[],
    Set<int> assistantStrokes = const <int>{},
  }) {
    final ui.Rect bounds = preview.logicalBounds;
    String build(
      List<SnapshotStroke> nativeInk,
      List<SelectionSvgLine> lines,
    ) => _build(pageSize, bounds, (XmlBuilder builder) {
      _nextLine(builder);
      builder.element(
        'image',
        attributes: <String, String>{
          'x': _n(bounds.left),
          'y': _n(bounds.top),
          'width': _n(bounds.width),
          'height': _n(bounds.height),
          'preserveAspectRatio': 'none',
          'href': 'data:image/png;base64,${base64Encode(preview.png)}',
          'data-etonia-role': 'selected-raster-context',
        },
      );
      // Native note ink remains machine-readable geometry even when a bitmap
      // has to sit under it. Overpainting the same opaque paths does not alter
      // the visual crop.
      _writeLines(builder, lines, nativeInk);
    });
    List<SelectionSvgLine> lines = _rasterLines(
      bounds,
      strokes,
      assistantStrokes,
    );
    String svg = build(strokes, lines);
    if (utf8.encode(svg).length > maxBytes && strokes.isNotEmpty) {
      lines = _rasterLines(bounds, const <SnapshotStroke>[], const <int>{});
      svg = build(const <SnapshotStroke>[], lines);
    }
    if (utf8.encode(svg).length > maxBytes) {
      throw const FormatException('Selected SVG is too large');
    }
    return SelectionSvgDocument(svg, lines);
  }

  static void _writeStroke(
    XmlBuilder builder,
    SnapshotStroke stroke,
    SelectionSvgLine line,
  ) {
    if (stroke.points.isEmpty || !stroke.width.isFinite || stroke.width <= 0) {
      throw const FormatException('Invalid SVG stroke');
    }
    if (stroke.points.any((InkVector point) => !point.isFinite)) {
      throw const FormatException('Invalid SVG stroke');
    }
    final Map<String, String> source = <String, String>{
      'data-etonia-kind': 'existing-ink',
      'data-etonia-writing': stroke.writing.name,
      'data-etonia-line': '${line.line}',
      if (line.byAssistant) 'data-etonia-author': 'assistant',
    };
    final Map<String, String> paint = <String, String>{
      'stroke': _color(stroke.color),
      'stroke-opacity': _n(stroke.color.a),
      'stroke-width': _n(stroke.width),
      'stroke-linecap': 'round',
      'stroke-linejoin': 'round',
      ...source,
    };
    if (stroke.isDot || stroke.points.length == 1) {
      final InkVector point = stroke.points.first;
      builder.element(
        'circle',
        attributes: <String, String>{
          'cx': _n(point.x),
          'cy': _n(point.y),
          'r': _n(stroke.width / 2),
          'fill': _color(stroke.color),
          'fill-opacity': _n(stroke.color.a),
          ...source,
        },
      );
      return;
    }
    final StringBuffer path = StringBuffer();
    for (int i = 0; i < stroke.points.length; i++) {
      final InkVector point = stroke.points[i];
      path.write('${i == 0 ? 'M' : ' L'}${_n(point.x)} ${_n(point.y)}');
    }
    builder.element(
      'path',
      attributes: <String, String>{...paint, 'fill': 'none', 'd': '$path'},
    );
  }

  static String _color(ui.Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';

  static String _n(double value) =>
      value.toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '');
}

/// Consecutive citable lines the outline gives one row.
class _OutlineRow {
  _OutlineRow(SelectionSvgLine line)
    : first = line.line,
      last = line.line,
      kind = line._kind,
      bounds = line.bounds;

  final int first;
  int last;
  final String kind;
  ui.Rect bounds;

  /// Whether [line] goes on along the same written line. Slices of a picture
  /// keep rows of their own, so that part of it can be cited.
  bool takes(SelectionSvgLine line) {
    if (line._kind != kind || kind == 'region' || line.line != last + 1) {
      return false;
    }
    final double overlap =
        math.min(bounds.bottom, line.bounds.bottom) -
        math.max(bounds.top, line.bounds.top);
    return overlap >= math.min(bounds.height, line.bounds.height) * 0.3;
  }

  void add(SelectionSvgLine line) {
    last = line.line;
    bounds = bounds.expandToInclude(line.bounds);
  }

  void absorb(_OutlineRow row) {
    last = row.last;
    bounds = bounds.expandToInclude(row.bounds);
  }

  String get text {
    final String lines = first == last ? 'L$first' : 'L$first-L$last';
    return '$lines $kind ${bounds.left.round()} ${bounds.top.round()} '
        '${bounds.width.round()} ${bounds.height.round()}';
  }
}
