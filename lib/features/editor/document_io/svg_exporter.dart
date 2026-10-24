import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';

import '../ink/ink_controller.dart';
import '../ink/ink_sample.dart';
import '../ink/stroke.dart';
import 'document_models.dart';
import 'document_platform.dart';

/// Exports page ink and retained SVG objects as an ordinary editable SVG.
class SvgExporter {
  const SvgExporter({this.sink = const SystemExportSink()});

  final ExportSink sink;

  String build({
    required String title,
    required Size pageSize,
    required InkController controller,
    Brightness brightness = Brightness.light,
  }) {
    if (!pageSize.isFinite || pageSize.isEmpty) {
      throw const FormatException('Invalid SVG page size');
    }
    final XmlBuilder builder = XmlBuilder();
    builder.element(
      'svg',
      attributes: <String, String>{
        'xmlns': 'http://www.w3.org/2000/svg',
        'viewBox': '0 0 ${_n(pageSize.width)} ${_n(pageSize.height)}',
        'width': _n(pageSize.width),
        'height': _n(pageSize.height),
        'data-etonia-version': '1',
      },
      nest: () {
        builder.element('title', nest: title);
        builder.element(
          'desc',
          attributes: <String, String>{'data-etonia-role': 'message'},
          nest: 'Editable vector page exported by Etonia.',
        );
        for (final NoteImageElement image in controller.images) {
          if (image.vector case final vector?) {
            final XmlElement source = XmlDocument.parse(
              vector.source,
            ).rootElement;
            final double degrees = image.rotation * 180 / math.pi;
            builder.element(
              'g',
              attributes: <String, String>{
                'data-etonia-object-id': image.id,
                'transform':
                    'rotate(${_n(degrees)} ${_n(image.center.x)} ${_n(image.center.y)})',
              },
              nest: () {
                builder.element(
                  'svg',
                  attributes: <String, String>{
                    'x': _n(image.center.x - image.size.width / 2),
                    'y': _n(image.center.y - image.size.height / 2),
                    'width': _n(image.size.width),
                    'height': _n(image.size.height),
                    'viewBox': <double>[
                      vector.viewBox.left,
                      vector.viewBox.top,
                      vector.viewBox.width,
                      vector.viewBox.height,
                    ].map(_n).join(' '),
                  },
                  nest: () {
                    for (final XmlNode child in source.children) {
                      builder.xml(child.toXmlString(pretty: false));
                    }
                  },
                );
              },
            );
          }
        }
        for (final Stroke stroke in controller.strokes) {
          _writeStroke(builder, stroke, brightness);
        }
      },
    );
    return builder.buildDocument().rootElement.toXmlString(pretty: true);
  }

  Future<File> exportAndShare({
    required String title,
    required Size pageSize,
    required InkController controller,
    Brightness brightness = Brightness.light,
    Rect? sharePositionOrigin,
  }) async {
    final String source = build(
      title: title,
      pageSize: pageSize,
      controller: controller,
      brightness: brightness,
    );
    final Directory root = await getTemporaryDirectory();
    final Directory directory = Directory('${root.path}/greatnote-exports');
    await directory.create(recursive: true);
    final File file = File('${directory.path}/${sanitizedSvgFileName(title)}');
    await file.writeAsString(source, flush: true);
    await sink.share(file, sharePositionOrigin: sharePositionOrigin);
    return file;
  }

  static void _writeStroke(
    XmlBuilder builder,
    Stroke stroke,
    Brightness brightness,
  ) {
    final Color color = stroke.style.resolve(brightness);
    final String paint =
        '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';
    final Map<String, String> attributes = <String, String>{
      'data-etonia-kind': 'ink',
      'data-etonia-stroke-id': stroke.id,
      'fill': 'none',
      'stroke': paint,
      'data-etonia-stroke-ink': stroke.style.ink.id,
      'stroke-opacity': _n(color.a),
      'stroke-width': _n(stroke.style.width),
      'stroke-linecap': 'round',
      'stroke-linejoin': 'round',
    };
    if (stroke.points.length == 1) {
      final InkVector point = stroke.points.single;
      builder.element(
        'circle',
        attributes: <String, String>{
          ...attributes,
          'fill': paint,
          'stroke': 'none',
          'cx': _n(point.x),
          'cy': _n(point.y),
          'r': _n(stroke.style.width / 2),
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
      attributes: <String, String>{...attributes, 'd': '$path'},
    );
  }

  static String _n(double value) =>
      double.parse(value.toStringAsFixed(4)).toString();
}

String sanitizedSvgFileName(String title) {
  final String clean = title
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '')
      .trim();
  return '${clean.isEmpty ? 'Untitled note' : clean}.svg';
}
