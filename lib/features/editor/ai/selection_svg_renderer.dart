import 'dart:convert';
import 'dart:ui' as ui;

import 'package:xml/xml.dart';

import '../ink/ink_sample.dart';
import 'selection_image_renderer.dart';

/// One line of a selection SVG that a citation can name: a stroke.
class SelectionSvgLine {
  const SelectionSvgLine({
    required this.line,
    required this.strokeIndex,
    this.byAssistant = false,
  });

  /// One-based, counting the root element's line as the first.
  final int line;

  /// Its stroke's place in the snapshot's strokes.
  final int strokeIndex;

  /// Whether the assistant's own notation drew it, rather than the user.
  final bool byAssistant;
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
/// `data-etonia-line`, so that the notation model can cite the lines each
/// paragraph of the answer refers to.
///
/// Native ink stays vector. A selection containing raster paper, an image, or
/// a sticky note uses the already privacy-cropped preview as one embedded PNG;
/// the transport is still a self-contained SVG and never exposes pixels outside
/// [SelectionImage.logicalBounds]. That PNG is opaque here, so no line can name
/// a detail of it: the model circles one by looking at the picture itself.
class SelectionSvgRenderer {
  const SelectionSvgRenderer({this.maxBytes = 6000000});

  final int maxBytes;

  /// The root's line, the title's, and the description's come first.
  static const int _firstContentLine = 4;

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
    if (snapshot.holdsPicture) {
      return _raster(
        preview,
        pageSize,
        strokes: snapshot.strokes,
        assistantStrokes: assistantStrokes,
      );
    }

    final List<SelectionSvgLine> lines = _strokeLines(
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

  /// The citable lines of an SVG holding the paper or picture, then [strokes].
  static List<SelectionSvgLine> _strokeLines(
    List<SnapshotStroke> strokes,
    Set<int> assistantStrokes,
  ) {
    return <SelectionSvgLine>[
      for (int i = 0; i < strokes.length; i++)
        SelectionSvgLine(
          line: _firstContentLine + 1 + i,
          strokeIndex: i,
          byAssistant: assistantStrokes.contains(i),
        ),
    ];
  }

  static void _nextLine(XmlBuilder builder) => builder.text('\n');

  static void _writeLines(
    XmlBuilder builder,
    List<SelectionSvgLine> lines,
    List<SnapshotStroke> strokes,
  ) {
    for (final SelectionSvgLine line in lines) {
      _nextLine(builder);
      _writeStroke(builder, strokes[line.strokeIndex], line);
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
    List<SelectionSvgLine> lines = _strokeLines(strokes, assistantStrokes);
    String svg = build(strokes, lines);
    if (utf8.encode(svg).length > maxBytes && strokes.isNotEmpty) {
      lines = const <SelectionSvgLine>[];
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
