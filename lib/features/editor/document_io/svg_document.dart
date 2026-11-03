import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

import '../ink/ink_palette.dart';

/// A validated, self-contained SVG that remains editable as vector source.
///
/// Greatnote deliberately keeps the SVG text instead of rasterizing or
/// translating it into ink strokes. Placement is owned by the note element;
/// the SVG's own viewBox and child structure survive save/export round trips.
@immutable
class EditableSvg {
  const EditableSvg._({
    required this.source,
    required this.viewBox,
    required this.contentBounds,
    required this.label,
    required this.message,
    required this.citations,
    required this.stepCount,
    required this.duration,
    required this.hasVisualContent,
  });

  static const int maxBytes = 512 * 1024;
  static const int maxNodes = 4096;
  static const int maxDepth = 40;
  static const int maxSteps = 24;
  static const Duration defaultStepDuration = Duration(milliseconds: 650);

  final String source;
  final Rect viewBox;
  final Rect contentBounds;
  final String label;

  /// Markdown stored in the response SVG's non-rendering description.
  final String? message;

  /// What the response's non-rendering citation descriptions cite, by the
  /// answer paragraph each names, from one. Their text is not yet read.
  final Map<int, String> citations;

  /// Highest `data-etonia-step` on a drawable element.
  final int stepCount;
  final Duration duration;
  final bool hasVisualContent;

  bool get isAnimated => stepCount > 0;

  /// Parses and sanitizes an SVG. External resources and executable content
  /// are rejected rather than fetched or partially retained.
  factory EditableSvg.parse(String input, {bool modelResponse = false}) {
    String source = _stripFence(input);
    if (utf8.encode(source).length > maxBytes) {
      throw const FormatException('SVG is too large');
    }
    final String lowerSource = source.toLowerCase();
    if (lowerSource.contains('<!doctype') || lowerSource.contains('<!entity')) {
      throw const FormatException('Unsafe SVG');
    }
    final XmlDocument document;
    try {
      document = XmlDocument.parse(source);
    } on Object {
      throw const FormatException('Invalid SVG');
    }
    final XmlElement root = document.rootElement;
    if (root.name.local.toLowerCase() != 'svg') {
      throw const FormatException('Invalid SVG');
    }
    if (modelResponse && root.getAttribute('data-etonia-version') != '1') {
      throw const FormatException('Unsupported SVG response');
    }

    int nodes = 0;
    int highestStep = 0;
    bool hasVisual = false;
    void inspect(XmlElement element, int depth) {
      nodes++;
      if (nodes > maxNodes || depth > maxDepth) {
        throw const FormatException('SVG is too complex');
      }
      final String name = element.name.local.toLowerCase();
      if (_blockedElements.contains(name)) {
        throw const FormatException('Unsafe SVG');
      }
      if (name == 'style') {
        final String css = element.innerText.toLowerCase();
        if (css.contains('@import') ||
            css.contains('javascript:') ||
            css.contains('data:text/html') ||
            _hasUnsafeUrl(css)) {
          throw const FormatException('Unsafe SVG');
        }
      }
      if (!_nonVisualElements.contains(name)) hasVisual = true;
      for (final XmlAttribute attribute in element.attributes) {
        final String key = attribute.name.local.toLowerCase();
        final String value = attribute.value.trim().toLowerCase();
        if (key.startsWith('on') ||
            value.contains('javascript:') ||
            value.contains('@import') ||
            value.contains('data:text/html') ||
            ((key == 'href' || key == 'src') &&
                value.isNotEmpty &&
                !value.startsWith('#')) ||
            _hasUnsafeUrl(value)) {
          throw const FormatException('Unsafe SVG');
        }
      }
      final String? rawStep = element.getAttribute('data-etonia-step');
      if (rawStep != null) {
        final int? step = int.tryParse(rawStep);
        if (step == null || step < 1 || step > maxSteps) {
          throw const FormatException('Invalid SVG animation');
        }
        if (step > highestStep) highestStep = step;
      }
      for (final XmlElement child in element.childElements) {
        inspect(child, depth + 1);
      }
    }

    inspect(root, 0);
    if (!hasVisual && !modelResponse) {
      throw const FormatException('SVG has no visible content');
    }
    if (modelResponse &&
        hasVisual &&
        root.getAttribute('data-etonia-bounds') == null) {
      throw const FormatException('SVG response has no content bounds');
    }

    final Rect viewBox = _readViewBox(root);
    final Rect contentBounds = _readBounds(root, viewBox);
    const double edgeTolerance = 0.000001;
    if (!viewBox.inflate(edgeTolerance).contains(contentBounds.topLeft) ||
        !viewBox.inflate(edgeTolerance).contains(contentBounds.bottomRight) ||
        contentBounds.isEmpty) {
      throw const FormatException('Invalid SVG bounds');
    }

    final String? message = root.childElements
        .where(
          (XmlElement node) =>
              node.name.local.toLowerCase() == 'desc' &&
              node.getAttribute('data-etonia-role') == 'message',
        )
        .map((XmlElement node) => node.innerText.trim())
        .firstOrNull;
    if (modelResponse && (message == null || message.isEmpty)) {
      throw const FormatException('SVG response has no message');
    }
    final Map<int, String> citations = <int, String>{};
    for (final XmlElement node in root.descendantElements) {
      if (node.name.local.toLowerCase() != 'desc' ||
          node.getAttribute('data-etonia-role') != 'citation') {
        continue;
      }
      // A bad number says nothing: the rest of the response is still good.
      final int? paragraph = int.tryParse(
        node.getAttribute('data-etonia-paragraph')?.trim() ?? '',
      );
      if (paragraph == null || paragraph < 1) continue;
      final String? earlier = citations[paragraph];
      citations[paragraph] = earlier == null
          ? node.innerText
          : '$earlier ${node.innerText}';
    }
    final String title =
        root.childElements
            .where(
              (XmlElement node) => node.name.local.toLowerCase() == 'title',
            )
            .map((XmlElement node) => node.innerText.trim())
            .where((String text) => text.isNotEmpty)
            .firstOrNull ??
        'Vector graphic';
    final String label = title.runes.length <= 80
        ? title
        : String.fromCharCodes(title.runes.take(80));

    Duration duration = Duration(
      milliseconds:
          int.tryParse(root.getAttribute('data-etonia-duration-ms') ?? '') ??
          defaultStepDuration.inMilliseconds * highestStep,
    );
    if (highestStep == 0) {
      duration = Duration.zero;
    } else if (duration < const Duration(milliseconds: 300) ||
        duration > const Duration(seconds: 20)) {
      throw const FormatException('Invalid SVG animation duration');
    }

    // Canonical serialization drops declarations/doctype while retaining the
    // SVG element tree and all safe metadata needed for editing and export.
    source = root.toXmlString(pretty: false);
    return EditableSvg._(
      source: source,
      viewBox: viewBox,
      contentBounds: contentBounds,
      label: label,
      message: message,
      citations: Map<int, String>.unmodifiable(citations),
      stepCount: highestStep,
      duration: duration,
      hasVisualContent: hasVisual,
    );
  }

  /// Reads only the non-rendering assistant message from an SVG response.
  /// This lets callers keep a valid answer when the visible SVG is rejected.
  static String messageFromResponse(String input) {
    final String source = _stripFence(input);
    if (utf8.encode(source).length > maxBytes) {
      throw const FormatException('SVG is too large');
    }
    final String lowerSource = source.toLowerCase();
    if (lowerSource.contains('<!doctype') || lowerSource.contains('<!entity')) {
      throw const FormatException('Unsafe SVG');
    }
    final XmlDocument document;
    try {
      document = XmlDocument.parse(source);
    } on Object {
      throw const FormatException('Invalid SVG');
    }
    final XmlElement root = document.rootElement;
    if (root.name.local.toLowerCase() != 'svg') {
      throw const FormatException('Invalid SVG');
    }
    final String? message = root.childElements
        .where(
          (XmlElement node) =>
              node.name.local.toLowerCase() == 'desc' &&
              node.getAttribute('data-etonia-role') == 'message',
        )
        .map((XmlElement node) => node.innerText.trim())
        .firstOrNull;
    if (message == null || message.isEmpty) {
      throw const FormatException('SVG response has no message');
    }
    return message;
  }

  /// Returns a renderable frame. Fixed elements remain visible; stepped
  /// elements appear cumulatively. The original [source] is never changed.
  String frame(int visibleStep, {Brightness? brightness}) {
    if ((!isAnimated || visibleStep >= stepCount) && brightness == null) {
      return source;
    }
    final XmlDocument document = XmlDocument.parse(source);
    if (isAnimated && visibleStep < stepCount) {
      final List<XmlElement> elements = document.descendants
          .whereType<XmlElement>()
          .toList(growable: false)
          .reversed
          .toList(growable: false);
      for (final XmlElement element in elements) {
        final int? step = int.tryParse(
          element.getAttribute('data-etonia-step') ?? '',
        );
        if (step != null && step > visibleStep) {
          element.parent?.children.remove(element);
        }
      }
    }
    if (brightness != null) _applySemanticInk(document, brightness);
    return document.rootElement.toXmlString(pretty: false);
  }

  static void _applySemanticInk(XmlDocument document, Brightness brightness) {
    for (final XmlElement element
        in document.descendants.whereType<XmlElement>()) {
      final String? common = element.getAttribute('data-etonia-ink');
      final String? strokeInk =
          element.getAttribute('data-etonia-stroke-ink') ?? common;
      final String? fillInk =
          element.getAttribute('data-etonia-fill-ink') ?? common;
      final String? stroke = element.getAttribute('stroke');
      if (strokeInk != null && stroke != null && stroke != 'none') {
        final InkColor? ink = InkPalette.byId(strokeInk);
        if (ink != null) {
          element.setAttribute('stroke', _color(ink.resolve(brightness)));
        }
      }
      final String? fill = element.getAttribute('fill');
      if (fillInk != null && fill != null && fill != 'none') {
        final InkColor? ink = InkPalette.byId(fillInk);
        if (ink != null) {
          element.setAttribute('fill', _color(ink.resolve(brightness)));
        }
      }
    }
  }

  static String _color(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';

  /// Crops the root viewBox to the declared content bounds. This makes the
  /// object-level selection frame match what the user sees while preserving
  /// every child and its coordinates.
  EditableSvg croppedToContent() {
    if (contentBounds == viewBox) return this;
    final XmlDocument document = XmlDocument.parse(source);
    final XmlElement root = document.rootElement;
    root.setAttribute('viewBox', _rectText(contentBounds));
    root.setAttribute('width', _number(contentBounds.width));
    root.setAttribute('height', _number(contentBounds.height));
    root.setAttribute('data-etonia-bounds', _rectText(contentBounds));
    return EditableSvg._(
      source: root.toXmlString(pretty: false),
      viewBox: contentBounds,
      contentBounds: contentBounds,
      label: label,
      message: message,
      citations: citations,
      stepCount: stepCount,
      duration: duration,
      hasVisualContent: hasVisualContent,
    );
  }

  static String _stripFence(String value) {
    String source = value.trim().replaceFirst('\uFEFF', '');
    if (!source.startsWith('```')) return source;
    final int line = source.indexOf('\n');
    source = line < 0 ? '' : source.substring(line + 1).trimRight();
    if (source.endsWith('```')) {
      source = source.substring(0, source.length - 3);
    }
    return source.trim();
  }

  static Rect _readViewBox(XmlElement root) {
    final List<double>? viewBox = _numbers(root.getAttribute('viewBox'));
    if (viewBox != null && viewBox.length == 4) {
      final Rect rect = Rect.fromLTWH(
        viewBox[0],
        viewBox[1],
        viewBox[2],
        viewBox[3],
      );
      if (rect.isFinite && rect.width > 0 && rect.height > 0) return rect;
    }
    final double? width = _dimension(root.getAttribute('width'));
    final double? height = _dimension(root.getAttribute('height'));
    if (width != null && height != null && width > 0 && height > 0) {
      return Rect.fromLTWH(0, 0, width, height);
    }
    throw const FormatException('SVG needs a finite viewBox');
  }

  static Rect _readBounds(XmlElement root, Rect fallback) {
    final List<double>? values = _numbers(
      root.getAttribute('data-etonia-bounds'),
    );
    if (values == null) return fallback;
    if (values.length != 4) throw const FormatException('Invalid SVG bounds');
    return Rect.fromLTWH(values[0], values[1], values[2], values[3]);
  }

  static List<double>? _numbers(String? text) {
    if (text == null) return null;
    final List<String> parts = text
        .trim()
        .split(RegExp(r'[\s,]+'))
        .where((String part) => part.isNotEmpty)
        .toList(growable: false);
    final List<double> values = <double>[];
    for (final String part in parts) {
      final double? value = double.tryParse(part);
      if (value == null || !value.isFinite) return null;
      values.add(value);
    }
    return values;
  }

  static double? _dimension(String? text) {
    if (text == null) return null;
    return double.tryParse(text.trim().replaceFirst(RegExp(r'px$'), ''));
  }

  static String _number(double value) =>
      double.parse(value.toStringAsFixed(6)).toString();

  static bool _hasUnsafeUrl(String value) {
    for (final RegExpMatch match in RegExp(
      r'url\(\s*([^)]*?)\s*\)',
      caseSensitive: false,
    ).allMatches(value)) {
      final String target = (match.group(1) ?? '').trim().replaceAll(
        RegExp(r'''^["']|["']$'''),
        '',
      );
      if (!target.startsWith('#')) return true;
    }
    return false;
  }

  static String _rectText(Rect rect) => <double>[
    rect.left,
    rect.top,
    rect.width,
    rect.height,
  ].map(_number).join(' ');

  static const Set<String> _blockedElements = <String>{
    'script',
    'foreignobject',
    'iframe',
    'object',
    'embed',
    'audio',
    'video',
    'image',
  };

  static const Set<String> _nonVisualElements = <String>{
    'svg',
    'title',
    'desc',
    'metadata',
    'defs',
    'style',
    'g',
    'a',
    'symbol',
    'switch',
    'lineargradient',
    'radialgradient',
    'stop',
    'clippath',
    'mask',
    'pattern',
    'marker',
    'filter',
    'animate',
    'animatetransform',
    'animatemotion',
    'set',
  };
}
