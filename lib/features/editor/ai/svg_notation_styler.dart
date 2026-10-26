import 'dart:math' as math;
import 'dart:ui' show Color, Rect;

import 'package:xml/xml.dart';

import '../document_io/svg_document.dart';
import '../handwriting/handwriting_style.dart';
import '../ink/ink_palette.dart';
import '../ink/ink_sample.dart';
import 'chat_math.dart';
import 'ink_attachment.dart';
import 'notation_font.dart';
import 'notation_math.dart';
import 'svg_ink_snap.dart';
import 'svg_line_spacing.dart';

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
    double maxTextSize = double.infinity,
  }) {
    final XmlDocument document = XmlDocument.parse(vector.source);
    final XmlElement root = document.rootElement;
    _enforceAnimationSemantics(root);
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
    final List<_Written> written = <_Written>[
      for (final XmlElement textElement in textElements)
        if (_measureText(
              textElement,
              paper: vector.viewBox,
              handwriting: handwriting,
              penWidth: penWidth,
              maxTextSize: maxTextSize,
            )
            case final _Written text)
          text,
    ];
    // Crowded lines are spaced out, and their underlines, rings, and
    // leaders go with them.
    final List<double> drops = SvgLineSpacing.drops(<SpacedText>[
      for (final _Written text in written)
        (
          line: text.line,
          ink: text.ink.inflate(text.pad),
          baseline: text.baseline,
          size: text.size,
          pinned: text.pinned,
        ),
    ], vector.viewBox);
    final Rect? carried =
        SvgLineSpacing.carry(root, <({Rect zone, double drop})>[
          for (int i = 0; i < written.length; i++)
            if (drops[i] != 0)
              (
                zone: written[i].ink.inflate(written[i].size * 0.8),
                drop: drops[i],
              ),
        ]);
    if (carried != null) bounds = bounds.expandToInclude(carried);
    for (int i = 0; i < written.length; i++) {
      bounds = bounds.expandToInclude(
        _writeText(
          written[i],
          drop: drops[i],
          paper: vector.viewBox,
          defaultInk: defaultInk,
        ),
      );
    }
    bounds = bounds.intersect(vector.viewBox);
    root.setAttribute(
      'data-etonia-bounds',
      '${_number(bounds.left)} ${_number(bounds.top)} '
          '${_number(bounds.width)} ${_number(bounds.height)}',
    );
    _tagSemanticPaints(root, defaultInk.id);
    root.setAttribute('data-etonia-handwriting', '1');
    return EditableSvg.parse(root.toXmlString(pretty: false));
  }

  /// Makes animation opt-in for changing subject matter and never for text.
  ///
  /// Provider steps without the explicit motion declaration are discarded.
  /// This turns an over-eager model's reveal effects into ordinary static ink
  /// before the notation reaches playback.
  static void _enforceAnimationSemantics(XmlElement root) {
    for (final XmlElement element in <XmlElement>[
      root,
      ...root.descendants.whereType<XmlElement>(),
    ]) {
      final String name = element.name.local.toLowerCase();
      final bool explicitlyStatic =
          element.getAttribute('data-etonia-static') == '1';
      final bool eligibleMotion =
          element.getAttribute('data-etonia-motion') == '1';
      if (name == 'text' || explicitlyStatic || !eligibleMotion) {
        element.attributes.removeWhere(
          (XmlAttribute attribute) =>
              attribute.name.local.toLowerCase() == 'data-etonia-step',
        );
      }
      if (name == 'text' || explicitlyStatic) {
        element.attributes.removeWhere(
          (XmlAttribute attribute) =>
              attribute.name.local.toLowerCase() == 'data-etonia-motion',
        );
      }
    }
  }

  /// Lays out [element]'s text in handwriting where the model put it, slid
  /// onto [paper]; null, with the element removed, when it was empty.
  static _Written? _measureText(
    XmlElement element, {
    required Rect paper,
    required HandwritingStyle handwriting,
    required double penWidth,
    required double maxTextSize,
  }) {
    if (element.childElements.isNotEmpty) {
      throw const FormatException('SVG text must not use nested spans');
    }
    final String text = element.innerText.trim();
    if (text.isEmpty) {
      element.remove();
      return null;
    }
    // Normalize both contract-perfect `$…$` and bare LaTeX that a model
    // occasionally emits. Explicit delimiters also count for simple formulas
    // such as `$x = 2$`, which contain no command, script, or brace.
    final String mathText = delimitBareMath(text);
    final NotationMath? formula =
        NotationMath.hasMath(mathText) ||
            NotationMath.hasDelimitedMath(mathText)
        ? NotationMath.parse(NotationMath.fromText(mathText))
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

    // Models write larger than asked; the writer's size setting is a cap.
    double fontSize = math.min(size, maxTextSize);
    write(fontSize);
    if (!left.isFinite || !top.isFinite) {
      element.remove();
      return null;
    }
    // A line longer than the paper is written smaller rather than dropped.
    final double room = paper.width - 2 * pad;
    if (right - left > room && room > 0) {
      fontSize = fontSize * room / (right - left) * 0.98;
      write(fontSize);
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
    // The room the line takes, capitals to descenders, whichever letters
    // it happens to have, so lines are spaced to an even rhythm.
    final double lineTop = formula == null
        ? baseline - fontSize
        : baseline - formula.ascent * fontSize;
    final double lineHeight = formula == null
        ? NotationFont.height(text, fontSize)
        : formula.height * fontSize;
    return _Written(
      element: element,
      text: text,
      strokes: strokes,
      shift: shift,
      ink: Rect.fromLTRB(left + shift, top, right + shift, bottom),
      line: Rect.fromLTRB(
        left + shift,
        math.min(top, lineTop),
        right + shift,
        math.max(bottom, lineTop + lineHeight),
      ),
      baseline: baseline,
      size: fontSize,
      pad: pad,
      penWidth: widthForText,
      pinned:
          element.getAttribute('data-etonia-fixed') != null ||
          (formula == null &&
              !text.contains(RegExp(r'\s')) &&
              text.runes.length <= 3),
    );
  }

  /// Replaces [text]'s element with its handwriting paths, moved [drop]
  /// down, and returns the box they cover, kept inside [paper].
  static Rect _writeText(
    _Written text, {
    required double drop,
    required Rect paper,
    required InkColor defaultInk,
  }) {
    final XmlElement element = text.element;
    final double pad = text.pad;
    final Rect written = Rect.fromLTRB(
      math.max(paper.left, text.ink.left - pad),
      math.max(paper.top, text.ink.top + drop - pad),
      math.min(paper.right, text.ink.right + pad),
      math.min(paper.bottom, text.ink.bottom + drop + pad),
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
      'data-etonia-fixed',
      'data-etonia-step',
      'data-etonia-motion',
      'data-etonia-static',
      'style',
    };
    final List<XmlAttribute> groupAttributes = <XmlAttribute>[
      for (final XmlAttribute attribute in element.attributes)
        if (!textOnly.contains(attribute.name.local.toLowerCase()))
          attribute.copy(),
      XmlAttribute(const XmlName.parts('data-etonia-handwriting'), '1'),
      // Text and formulas convey fixed information. This also cancels a step
      // inherited from an animated parent group in the native-ink converter.
      XmlAttribute(const XmlName.parts('data-etonia-static'), '1'),
      XmlAttribute(const XmlName.parts('aria-label'), text.text),
    ];
    final List<XmlNode> paths = <XmlNode>[
      for (final List<InkVector> stroke in text.strokes)
        if (stroke.isNotEmpty)
          XmlElement(const XmlName.parts('path'), <XmlAttribute>[
            XmlAttribute(
              const XmlName.parts('d'),
              _path(stroke, dx: text.shift, dy: drop),
            ),
            XmlAttribute(const XmlName.parts('fill'), 'none'),
            XmlAttribute(
              const XmlName.parts('stroke'),
              _color(ink.onLightPaper),
            ),
            XmlAttribute(
              const XmlName.parts('stroke-width'),
              _number(text.penWidth),
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

  static String _path(
    List<InkVector> points, {
    required double dx,
    required double dy,
  }) {
    final StringBuffer path = StringBuffer();
    for (int i = 0; i < points.length; i++) {
      final InkVector point = points[i];
      path.write(
        '${i == 0 ? 'M' : ' L'}${_number(point.x + dx)} '
        '${_number(point.y + dy)}',
      );
    }
    // A dot, such as an i's: a bare move paints nothing, so it is drawn as
    // a segment too short to see past its round caps.
    if (points.length == 1) {
      path.write(
        ' L${_number(points.single.x + dx + 0.01)} '
        '${_number(points.single.y + dy)}',
      );
    }
    return '$path';
  }

  static String _number(double value) =>
      double.parse(value.toStringAsFixed(4)).toString();

  static String _color(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';
}

/// A piece of SVG text laid out in handwriting, before it replaces its
/// element.
class _Written {
  const _Written({
    required this.element,
    required this.text,
    required this.strokes,
    required this.shift,
    required this.ink,
    required this.line,
    required this.baseline,
    required this.size,
    required this.pad,
    required this.penWidth,
    required this.pinned,
  });

  final XmlElement element;
  final String text;

  /// The handwriting, before [shift].
  final List<List<InkVector>> strokes;

  /// How far right the strokes go to sit where the model anchored them.
  final double shift;

  /// The box round the ink, after [shift], without the pen's width.
  final Rect ink;

  /// The box the line takes, capitals to descenders, after [shift].
  final Rect line;
  final double baseline;

  /// The height of a capital it is written at.
  final double size;

  /// Half the pen's width, which the ink reaches past [ink] by.
  final double pad;
  final double penWidth;

  /// Whether it stays exactly where the model put it, as a short label on
  /// a figure must.
  final bool pinned;
}
