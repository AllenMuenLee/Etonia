import 'dart:convert';
import 'dart:ui' as ui;

import 'package:xml/xml.dart';

import '../ink/ink_sample.dart';
import 'selection_image_renderer.dart';

/// Serializes the selected part of a note in the note's own coordinate space.
///
/// Native ink stays vector. A selection containing raster paper, an image, or
/// a sticky note uses the already privacy-cropped preview as one embedded PNG;
/// the transport is still a self-contained SVG and never exposes pixels
/// outside [SelectionImage.logicalBounds].
class SelectionSvgRenderer {
  const SelectionSvgRenderer({this.maxBytes = 6000000});

  final int maxBytes;

  String render({
    required SelectionInkSnapshot snapshot,
    required SelectionImage preview,
    required ui.Size pageSize,
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
      return _raster(preview, pageSize, strokes: snapshot.strokes);
    }

    final String svg = _build(pageSize, bounds, (XmlBuilder builder) {
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
      for (final SnapshotStroke stroke in snapshot.strokes) {
        _writeStroke(builder, stroke);
      }
    });
    if (utf8.encode(svg).length <= maxBytes) return svg;
    return _raster(preview, pageSize);
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
        builder.element('title', nest: 'Selected note context');
        builder.element(
          'desc',
          nest:
              'Existing user-selected note content in page logical '
              'coordinates.',
        );
        children(builder);
      },
    );
    return builder.buildDocument().rootElement.toXmlString(pretty: false);
  }

  String _raster(
    SelectionImage preview,
    ui.Size pageSize, {
    Iterable<SnapshotStroke> strokes = const <SnapshotStroke>[],
  }) {
    final ui.Rect bounds = preview.logicalBounds;
    String build(
      Iterable<SnapshotStroke> nativeInk,
    ) => _build(pageSize, bounds, (XmlBuilder builder) {
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
      for (final SnapshotStroke stroke in nativeInk) {
        _writeStroke(builder, stroke);
      }
    });
    String svg = build(strokes);
    if (utf8.encode(svg).length > maxBytes && strokes.isNotEmpty) {
      svg = build(const <SnapshotStroke>[]);
    }
    if (utf8.encode(svg).length > maxBytes) {
      throw const FormatException('Selected SVG is too large');
    }
    return svg;
  }

  static void _writeStroke(XmlBuilder builder, SnapshotStroke stroke) {
    if (stroke.points.isEmpty || !stroke.width.isFinite || stroke.width <= 0) {
      throw const FormatException('Invalid SVG stroke');
    }
    if (stroke.points.any((InkVector point) => !point.isFinite)) {
      throw const FormatException('Invalid SVG stroke');
    }
    final Map<String, String> paint = <String, String>{
      'stroke': _color(stroke.color),
      'stroke-opacity': _n(stroke.color.a),
      'stroke-width': _n(stroke.width),
      'stroke-linecap': 'round',
      'stroke-linejoin': 'round',
      'data-etonia-kind': 'existing-ink',
      'data-etonia-writing': stroke.writing.name,
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
          'data-etonia-kind': 'existing-ink',
          'data-etonia-writing': stroke.writing.name,
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
