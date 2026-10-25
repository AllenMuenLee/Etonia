import 'dart:math' as math;
import 'dart:ui' show Color, Rect;

import 'package:xml/xml.dart';

import '../document_io/svg_document.dart';
import '../handwriting/handwriting_style.dart';
import '../ink/ink_palette.dart';
import '../ink/ink_sample.dart';
import 'ink_attachment.dart';
import 'notation_font.dart';
import 'notation_math.dart';
import 'svg_ink_snap.dart';

/// Makes model-authored SVG look like it belongs to the handwritten note.
///
/// Visible SVG text is replaced with ordinary editable SVG paths drawn by
/// Greatnote's configured handwriting system. Paints also receive semantic
/// ink IDs so they resolve like the user's ink on light and dark paper. With
/// a [InkSnapper], the free ends of its lines join the user's ink they nearly
/// reach.
abstract final class SvgNotationStyler {
  static EditableSvg apply(
    EditableSvg vector, {
    required HandwritingStyle handwriting,
    required InkColor defaultInk,
    required double penWidth,
    InkSnapper? snapper,
  }) {
    final XmlDocument document = XmlDocument.parse(vector.source);
    final XmlElement root = document.rootElement;
    final List<XmlElement> textElements = document.descendants
        .whereType<XmlElement>()
        .where(
          (XmlElement element) => element.name.local.toLowerCase() == 'text',
        )
        .toList(growable: false);

    // The model sized its declared bounds for its own text; handwriting is
    // wider or narrower, so the bounds grow to hold what was really drawn.
    Rect bounds = vector.contentBounds;
    if (snapper != null) {
      // Loose ends join the user's ink before the bounds are settled, since
      // a joined end may sit just outside the box the model declared.
      final Rect? joined = SvgInkSnap.apply(root, snapper);
      if (joined != null) bounds = bounds.expandToInclude(joined);
    }
    for (final XmlElement textElement in textElements) {
      final Rect? written = _replaceText(
        textElement,
        paper: vector.viewBox,
        handwriting: handwriting,
        defaultInk: defaultInk,
        penWidth: penWidth,
      );
      if (written != null) bounds = bounds.expandToInclude(written);
    }
    root.setAttribute(
      'data-etonia-bounds',
      '${_number(bounds.left)} ${_number(bounds.top)} '
          '${_number(bounds.width)} ${_number(bounds.height)}',
    );
    _tagSemanticPaints(root, defaultInk.id);
    root.setAttribute('data-etonia-handwriting', '1');
    return EditableSvg.parse(root.toXmlString(pretty: false));
  }

  /// Replaces [element] with handwriting paths and returns the box they
  /// cover, kept inside [paper]; null when the text was empty.
  static Rect? _replaceText(
    XmlElement element, {
    required Rect paper,
    required HandwritingStyle handwriting,
    required InkColor defaultInk,
    required double penWidth,
  }) {
    if (element.childElements.isNotEmpty) {
      throw const FormatException('SVG text must not use nested spans');
    }
    final String text = element.innerText.trim();
    if (text.isEmpty) {
      element.remove();
      return null;
    }
    // Text holding `$…$` LaTeX is laid out as a formula, fractions, roots and
    // scripts included, and written in the same hand as any other text.
    final NotationMath? formula = NotationMath.hasMath(text)
        ? NotationMath.parse(NotationMath.fromText(text))
        : null;
    if (formula == null && !NotationFont.canWrite(text)) {
      throw const FormatException('SVG text cannot use the handwriting font');
    }
    final double x =
        _length(element.getAttribute('x')) ??
        (throw const FormatException('SVG text needs x'));
    final double baseline =
        _length(element.getAttribute('y')) ??
        (throw const FormatException('SVG text needs y'));
    final double size =
        _length(element.getAttribute('font-size')) ??
        _styleLength(element.getAttribute('style'), 'font-size') ??
        (throw const FormatException('SVG text needs font-size'));
    if (!x.isFinite || !baseline.isFinite || size < 8 || size > 120) {
      throw const FormatException('Invalid SVG text geometry');
    }

    final double widthForText = penWidth.isFinite ? penWidth.clamp(1, 20) : 2;
    final double pad = widthForText / 2;

    List<List<InkVector>> strokes = const <List<InkVector>>[];
    double left = double.infinity;
    double right = double.negativeInfinity;
    double top = double.infinity;
    double bottom = double.negativeInfinity;
    void write(double fontSize) {
      strokes = formula == null
          ? NotationFont.write(
              text,
              origin: InkVector(0, baseline - fontSize),
              size: fontSize,
              style: handwriting,
            )
          : formula.write(
              origin: InkVector(0, baseline - formula.ascent * fontSize),
              size: fontSize,
              style: handwriting,
            );
      left = top = double.infinity;
      right = bottom = double.negativeInfinity;
      for (final List<InkVector> stroke in strokes) {
        for (final InkVector point in stroke) {
          left = math.min(left, point.x);
          right = math.max(right, point.x);
          top = math.min(top, point.y);
          bottom = math.max(bottom, point.y);
        }
      }
    }

    write(size);
    if (!left.isFinite || !top.isFinite) {
      element.remove();
      return null;
    }
    // A line longer than the paper is written smaller rather than dropped.
    final double room = paper.width - 2 * pad;
    if (right - left > room && room > 0) {
      write(size * room / (right - left) * 0.98);
    }
    final double width = right - left;
    final String anchor = element.getAttribute('text-anchor') ?? 'start';
    double shift = switch (anchor) {
      'middle' => x - left - width / 2,
      'end' => x - right,
      _ => x - left,
    };
    // Slide the line back onto the paper instead of letting it be cut off.
    if (right + shift + pad > paper.right) shift = paper.right - pad - right;
    if (left + shift - pad < paper.left) shift = paper.left + pad - left;
    final Rect written = Rect.fromLTRB(
      math.max(paper.left, left + shift - pad),
      math.max(paper.top, top - pad),
      math.min(paper.right, right + shift + pad),
      math.min(paper.bottom, bottom + pad),
    );
    final String inkId =
        _validInk(
          element.getAttribute('data-etonia-fill-ink') ??
              element.getAttribute('data-etonia-ink'),
        ) ??
        _inkForPaint(element.getAttribute('fill'), defaultInk.id) ??
        defaultInk.id;
    final InkColor ink = InkPalette.byId(inkId) ?? defaultInk;

    final Set<String> textOnly = <String>{
      'x',
      'y',
      'dx',
      'dy',
      'font-size',
      'font-family',
      'font-style',
      'font-weight',
      'text-anchor',
      'dominant-baseline',
      'fill',
      'stroke',
      'stroke-width',
      'data-etonia-ink',
      'data-etonia-fill-ink',
      'data-etonia-stroke-ink',
      'style',
    };
    final List<XmlAttribute> groupAttributes = <XmlAttribute>[
      for (final XmlAttribute attribute in element.attributes)
        if (!textOnly.contains(attribute.name.local.toLowerCase()))
          attribute.copy(),
      XmlAttribute(const XmlName.parts('data-etonia-handwriting'), '1'),
      XmlAttribute(const XmlName.parts('aria-label'), text),
    ];
    final List<XmlNode> paths = <XmlNode>[
      for (final List<InkVector> stroke in strokes)
        if (stroke.isNotEmpty)
          XmlElement(const XmlName.parts('path'), <XmlAttribute>[
            XmlAttribute(const XmlName.parts('d'), _path(stroke, dx: shift)),
            XmlAttribute(const XmlName.parts('fill'), 'none'),
            XmlAttribute(
              const XmlName.parts('stroke'),
              _color(ink.onLightPaper),
            ),
            XmlAttribute(
              const XmlName.parts('stroke-width'),
              _number(widthForText),
            ),
            XmlAttribute(const XmlName.parts('stroke-linecap'), 'round'),
            XmlAttribute(const XmlName.parts('stroke-linejoin'), 'round'),
            XmlAttribute(const XmlName.parts('data-etonia-stroke-ink'), ink.id),
          ]),
    ];
    element.replace(
      XmlElement(const XmlName.parts('g'), groupAttributes, paths, false),
    );
    return written;
  }

  static void _tagSemanticPaints(XmlElement root, String defaultInk) {
    for (final XmlElement element in root.descendants.whereType<XmlElement>()) {
      if (element.name.local.toLowerCase() == 'style') continue;
      final String? common = _validInk(element.getAttribute('data-etonia-ink'));
      if (element.getAttribute('data-etonia-stroke-ink') == null) {
        final String? ink =
            common ?? _inkForPaint(element.getAttribute('stroke'), defaultInk);
        if (ink != null) element.setAttribute('data-etonia-stroke-ink', ink);
      }
      final String? stroke = element.getAttribute('stroke');
      if (stroke != null && stroke != 'none') {
        if (element.getAttribute('stroke-linecap') == null) {
          element.setAttribute('stroke-linecap', 'round');
        }
        if (element.getAttribute('stroke-linejoin') == null) {
          element.setAttribute('stroke-linejoin', 'round');
        }
      }
      if (element.getAttribute('data-etonia-fill-ink') == null) {
        final String? ink =
            common ?? _inkForPaint(element.getAttribute('fill'), defaultInk);
        if (ink != null) element.setAttribute('data-etonia-fill-ink', ink);
      }
    }
  }

  static String? _validInk(String? id) =>
      id != null && InkPalette.byId(id) != null ? id : null;

  static String? _inkForPaint(String? paint, String defaultInk) {
    if (paint == null) return null;
    final String value = paint.trim().toLowerCase();
    if (value == 'none' || value.startsWith('url(')) return null;
    const Map<String, String> named = <String, String>{
      'blue': 'blue',
      'red': 'red',
      'green': 'green',
      'orange': 'orange',
      'purple': 'purple',
      'teal': 'teal',
      'gray': 'graphite',
      'grey': 'graphite',
    };
    if (named[value] case final String ink) return ink;
    if (<String>{
      'black',
      'currentcolor',
      '#000',
      '#000000',
      '#111',
      '#111111',
      '#0f172a',
      'rgb(0,0,0)',
      'rgb(0, 0, 0)',
    }.contains(value)) {
      return defaultInk;
    }
    for (final InkColor ink in InkPalette.colors) {
      if (value == _color(ink.onLightPaper) ||
          value == _color(ink.onDarkPaper)) {
        return ink.id;
      }
    }
    return null;
  }

  static double? _styleLength(String? style, String property) {
    if (style == null) return null;
    final RegExpMatch? match = RegExp(
      '(?:^|;)\\s*${RegExp.escape(property)}\\s*:\\s*([^;]+)',
      caseSensitive: false,
    ).firstMatch(style);
    return _length(match?.group(1));
  }

  static double? _length(String? source) {
    if (source == null) return null;
    final RegExpMatch? match = RegExp(
      r'^\s*([-+]?(?:\d+(?:\.\d*)?|\.\d+))(?:px|pt)?(?:\s+.*)?$',
      caseSensitive: false,
    ).firstMatch(source);
    return match == null ? null : double.tryParse(match.group(1)!);
  }

  static String _path(List<InkVector> points, {required double dx}) {
    final StringBuffer path = StringBuffer();
    for (int i = 0; i < points.length; i++) {
      final InkVector point = points[i];
      path.write(
        '${i == 0 ? 'M' : ' L'}${_number(point.x + dx)} ${_number(point.y)}',
      );
    }
    return '$path';
  }

  static String _number(double value) =>
      double.parse(value.toStringAsFixed(4)).toString();

  static String _color(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';
}
