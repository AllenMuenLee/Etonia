import 'dart:ui' show Rect;

import 'package:xml/xml.dart';

import '../ink/ink_sample.dart';
import 'ink_attachment.dart';

/// Joins the loose ends of model-authored SVG lines to the user's ink, the
/// way [InkSnapper] does for stroke notation: a lead drawn to a component
/// touches it instead of stopping just short or running past.
///
/// Only open `line`, `polyline`, and absolute `path` elements are touched,
/// and only their two free ends. Closed shapes, transformed elements, and
/// anything inside defs or a handwriting group are left exactly as written.
abstract final class SvgInkSnap {
  /// Snaps ends under [root] and returns the box around the points that
  /// moved, or null when nothing did.
  static Rect? apply(XmlElement root, InkSnapper snapper) {
    if (snapper.isEmpty) return null;
    Rect? moved;
    for (final XmlElement element in root.descendants.whereType<XmlElement>()) {
      if (!_snappable(element)) continue;
      final List<InkVector>? ends = switch (element.name.local) {
        'line' => _snapLine(element, snapper),
        'polyline' => _snapPolyline(element, snapper),
        'path' => _snapPath(element, snapper),
        _ => null,
      };
      if (ends == null) continue;
      final Rect box = _box(ends);
      moved = moved == null ? box : moved.expandToInclude(box);
    }
    return moved;
  }

  static bool _snappable(XmlElement element) {
    if (!const <String>{
      'line',
      'polyline',
      'path',
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

  /// The points that moved, or null.
  static List<InkVector>? _snapLine(XmlElement element, InkSnapper snapper) {
    final double? x1 = _number(element.getAttribute('x1'));
    final double? y1 = _number(element.getAttribute('y1'));
    final double? x2 = _number(element.getAttribute('x2'));
    final double? y2 = _number(element.getAttribute('y2'));
    if (x1 == null || y1 == null || x2 == null || y2 == null) return null;
    final List<InkVector> before = <InkVector>[
      InkVector(x1, y1),
      InkVector(x2, y2),
    ];
    final List<InkVector> after = snapper.snapEnds(before);
    final List<InkVector> moved = _changed(before, after);
    if (moved.isEmpty) return null;
    element
      ..setAttribute('x1', _text(after.first.x))
      ..setAttribute('y1', _text(after.first.y))
      ..setAttribute('x2', _text(after.last.x))
      ..setAttribute('y2', _text(after.last.y));
    return moved;
  }

  static List<InkVector>? _snapPolyline(
    XmlElement element,
    InkSnapper snapper,
  ) {
    final List<double> values = _numbers(element.getAttribute('points') ?? '');
    if (values.length < 4 || values.length.isOdd) return null;
    final List<InkVector> before = <InkVector>[
      for (int i = 0; i < values.length; i += 2)
        InkVector(values[i], values[i + 1]),
    ];
    final List<InkVector> after = snapper.snapEnds(before);
    final List<InkVector> moved = _changed(before, after);
    if (moved.isEmpty) return null;
    element.setAttribute(
      'points',
      after.map((InkVector p) => '${_text(p.x)},${_text(p.y)}').join(' '),
    );
    return moved;
  }

  static const Map<String, int> _arity = <String, int>{
    'M': 2,
    'L': 2,
    'H': 1,
    'V': 1,
    'C': 6,
    'S': 4,
    'Q': 4,
    'T': 2,
    'A': 7,
  };

  static List<InkVector>? _snapPath(XmlElement element, InkSnapper snapper) {
    final List<_Segment>? segments = _parse(element.getAttribute('d'));
    if (segments == null || segments.length < 2) return null;
    final _Segment first = segments.first;
    final _Segment last = segments.last;
    // H and V end on a coordinate they do not state in full.
    if (last.command == 'H' || last.command == 'V') return null;
    final int end = last.args.length;
    final List<InkVector> before = <InkVector>[
      InkVector(first.args[0], first.args[1]),
      InkVector(last.args[end - 2], last.args[end - 1]),
    ];
    final List<InkVector> after = snapper.snapEnds(before);
    final List<InkVector> moved = _changed(before, after);
    if (moved.isEmpty) return null;
    first.args[0] = after.first.x;
    first.args[1] = after.first.y;
    last.args[end - 2] = after.last.x;
    last.args[end - 1] = after.last.y;
    element.setAttribute('d', segments.map((_Segment s) => s.text).join(' '));
    return moved;
  }

  /// The segments of an open, absolute path of one subpath; null for
  /// anything else (relative or closed paths, several subpaths, bad data).
  static List<_Segment>? _parse(String? data) {
    if (data == null) return null;
    final List<_Segment> segments = <_Segment>[];
    final RegExp token = RegExp(
      r'([A-Za-z])|([-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)',
    );
    String? command;
    final List<double> numbers = <double>[];
    void flush() {
      final String? name = command;
      if (name == null) return;
      final int? arity = _arity[name];
      if (arity == null || numbers.isEmpty || numbers.length % arity != 0) {
        throw const FormatException('unsupported path');
      }
      for (int i = 0; i < numbers.length; i += arity) {
        // Extra pairs after a move are implicit lines.
        segments.add(
          _Segment(i == 0 ? name : (name == 'M' ? 'L' : name), <double>[
            ...numbers.sublist(i, i + arity),
          ]),
        );
      }
      numbers.clear();
    }

    try {
      for (final RegExpMatch match in token.allMatches(data)) {
        final String? letter = match.group(1);
        if (letter != null) {
          flush();
          command = letter;
        } else {
          if (command == null) return null;
          numbers.add(double.parse(match.group(2)!));
        }
      }
      flush();
    } on FormatException {
      return null;
    }
    if (segments.first.command != 'M') return null;
    if (segments.skip(1).any((_Segment s) => s.command == 'M')) return null;
    return segments;
  }

  static List<InkVector> _changed(
    List<InkVector> before,
    List<InkVector> after,
  ) => <InkVector>[
    for (int i = 0; i < before.length; i++)
      if (before[i] != after[i]) after[i],
  ];

  static Rect _box(List<InkVector> points) {
    double left = points.first.x;
    double right = left;
    double top = points.first.y;
    double bottom = top;
    for (final InkVector point in points) {
      if (point.x < left) left = point.x;
      if (point.x > right) right = point.x;
      if (point.y < top) top = point.y;
      if (point.y > bottom) bottom = point.y;
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  static double? _number(String? source) =>
      source == null ? null : double.tryParse(source.trim());

  static List<double> _numbers(String source) => <double>[
    for (final RegExpMatch match in RegExp(
      r'[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?',
    ).allMatches(source))
      double.parse(match.group(0)!),
  ];

  static String _text(double value) =>
      double.parse(value.toStringAsFixed(4)).toString();
}

class _Segment {
  _Segment(this.command, this.args);

  final String command;
  final List<double> args;

  String get text => '$command${args.map(SvgInkSnap._text).join(' ')}';
}
