import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../ink/ink_sample.dart';
import '../ink/selection_transform.dart';
import '../ink/stroke.dart';

/// The pattern printed on a sticky note's paper.
enum StickyPaperStyle {
  blank('Blank'),
  dotted('Dotted'),
  grid('Grid'),
  lined('Lined');

  const StickyPaperStyle(this.label);

  final String label;

  /// The style stored as [name], or [lined], the default, for a name this
  /// version does not know.
  static StickyPaperStyle byName(Object? name) {
    for (final StickyPaperStyle style in values) {
      if (style.name == name) {
        return style;
      }
    }
    return lined;
  }
}

/// A sticky note's paper color. Fixed, not themed: a saved note looks and
/// exports the same in light and dark mode. Its pattern color is derived
/// from the paper, darker by a fixed amount, so it is subtle on every
/// paper but always visible.
@immutable
class StickyPaperColor {
  const StickyPaperColor({
    required this.id,
    required this.label,
    required this.paper,
  });

  final String id;
  final String label;
  final Color paper;

  /// Rules, grid lines, and dots.
  Color get pattern => Color.lerp(paper, const Color(0xFF1F2937), 0.22)!;

  /// The outline drawn just inside the edge, so a pale paper stays distinct
  /// from white page paper.
  Color get edge => Color.lerp(paper, const Color(0xFF1F2937), 0.12)!;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StickyPaperColor &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// The curated sticky-note papers.
abstract final class StickyPalette {
  static const String _customPrefix = 'custom-';

  static const StickyPaperColor yellow = StickyPaperColor(
    id: 'yellow',
    label: 'Yellow',
    paper: Color(0xFFFFF3A8),
  );

  static const List<StickyPaperColor> colors = <StickyPaperColor>[
    yellow,
    StickyPaperColor(id: 'pink', label: 'Pink', paper: Color(0xFFFFD6E5)),
    StickyPaperColor(id: 'blue', label: 'Blue', paper: Color(0xFFD3E8FF)),
    StickyPaperColor(id: 'green', label: 'Green', paper: Color(0xFFD5F2D8)),
    StickyPaperColor(id: 'neutral', label: 'Gray', paper: Color(0xFFEDEDE9)),
  ];

  /// The paper stored as [id], or null when this version does not know it.
  static StickyPaperColor? byId(Object? id) {
    if (id is! String) {
      return null;
    }
    for (final StickyPaperColor color in colors) {
      if (color.id == id) {
        return color;
      }
    }
    if (id.startsWith(_customPrefix)) {
      final String value = id.substring(_customPrefix.length);
      if (RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(value)) {
        final Color color = Color(int.parse(value, radix: 16));
        return StickyPaperColor(
          id: '$_customPrefix${value.toLowerCase()}',
          label: 'Custom (#${value.substring(2).toUpperCase()})',
          paper: color,
        );
      }
    }
    return null;
  }

  /// A user-selected custom sticky paper color picked from the color palette (色盤).
  static StickyPaperColor custom(Color color) {
    final Color customColor = Color(color.toARGB32());
    final String hex = customColor
        .toARGB32()
        .toRadixString(16)
        .padLeft(8, '0')
        .toLowerCase();
    return StickyPaperColor(
      id: '$_customPrefix$hex',
      label: 'Custom (#${hex.substring(2).toUpperCase()})',
      paper: customColor,
    );
  }

  /// The paper stored as [id], or [yellow], the documented fallback.
  static StickyPaperColor resolve(String id) => byId(id) ?? yellow;
}

/// Every sticky-note number in one place. Sizes are logical page units.
@immutable
class StickyNoteConfig {
  const StickyNoteConfig({
    this.defaultSize = const Size(240, 180),
    this.minSize = const Size(120, 90),
    this.maxSize = const Size(640, 480),
    this.cornerRadius = 12,
    this.shadowElevation = 3,
    this.contentPadding = 16,
    this.patternSpacing = 20,
    this.ruleWidth = 1,
    this.dotRadius = 1.2,
    this.hitSlop = 4,
    this.maxPatternMarks = 4000,
    this.doubleTapTimeout = const Duration(milliseconds: 350),
    this.doubleTapSlop = 24,
  });

  final Size defaultSize;
  final Size minSize;
  final Size maxSize;
  final double cornerRadius;

  /// How far the note's shadow suggests it stands off the page.
  final double shadowElevation;

  /// How far lined paper's rules keep from the left and right edges.
  final double contentPadding;

  /// Distance between rules, grid lines, and dots, in the note's own
  /// units, so the pattern scales and turns with it.
  final double patternSpacing;
  final double ruleWidth;
  final double dotRadius;

  /// How far outside its edge a pointer still counts as on a note.
  final double hitSlop;

  /// At most this many rules or dots are drawn for one note, whatever
  /// its size, so malformed input cannot make painting unbounded.
  final int maxPatternMarks;

  /// Two taps on a note this close in time and space open it for writing.
  final Duration doubleTapTimeout;
  final double doubleTapSlop;
}

/// The look a new sticky note gets, remembered for the session.
@immutable
class StickyNoteSettings {
  const StickyNoteSettings({
    this.color = StickyPalette.yellow,
    this.paper = StickyPaperStyle.lined,
  });

  final StickyPaperColor color;
  final StickyPaperStyle paper;

  StickyNoteSettings copyWith({
    StickyPaperColor? color,
    StickyPaperStyle? paper,
  }) {
    return StickyNoteSettings(
      color: color ?? this.color,
      paper: paper ?? this.paper,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is StickyNoteSettings &&
      other.color == color &&
      other.paper == paper;

  @override
  int get hashCode => Object.hash(color, paper);
}

/// A handwritten sticky note on a page: paper with a pattern, and ink of
/// its own, which moves, scales, and turns with it.
///
/// Its frame is [center], [size], and [rotation] in page units. Its ink is
/// in the note's own coordinates: (0, 0) at the unrotated top-left corner,
/// [localSize] at the bottom-right. One local unit is [scale] page units,
/// so resizing the note changes [scale] and [size] together and never
/// rewrites a child stroke.
@immutable
class StickyNoteElement {
  StickyNoteElement({
    required this.id,
    required this.center,
    required this.size,
    this.rotation = 0,
    this.scale = 1,
    required this.colorId,
    this.paper = StickyPaperStyle.lined,
    List<Stroke> strokes = const <Stroke>[],
  }) : strokes = List<Stroke>.unmodifiable(strokes);

  final String id;
  final InkVector center;

  /// Unrotated, in page units.
  final Size size;

  /// Radians, clockwise on screen.
  final double rotation;

  /// Page units per local unit.
  final double scale;

  /// A [StickyPaperColor.id]; unknown ids render as yellow.
  final String colorId;
  final StickyPaperStyle paper;

  /// The note's ink, in local coordinates, in paint order.
  final List<Stroke> strokes;

  StickyPaperColor get color => StickyPalette.resolve(colorId);

  /// The note's extent in its own units.
  Size get localSize => Size(size.width / scale, size.height / scale);

  /// "Yellow lined sticky note", for assistive technology.
  String get label => '${color.label} ${paper.label.toLowerCase()} sticky note';

  bool get isValid =>
      id.isNotEmpty &&
      center.isFinite &&
      size.isFinite &&
      size.width > 0 &&
      size.height > 0 &&
      rotation.isFinite &&
      scale.isFinite &&
      scale > 0;

  /// [local] on the page.
  InkVector toPage(InkVector local) {
    final double c = math.cos(rotation);
    final double s = math.sin(rotation);
    final double x = local.x * scale - size.width / 2;
    final double y = local.y * scale - size.height / 2;
    return InkVector(center.x + c * x - s * y, center.y + s * x + c * y);
  }

  /// [page] in the note's own coordinates.
  InkVector toLocal(InkVector page) {
    final double c = math.cos(rotation);
    final double s = math.sin(rotation);
    final InkVector d = page - center;
    final double x = c * d.x + s * d.y;
    final double y = -s * d.x + c * d.y;
    return InkVector(
      (x + size.width / 2) / scale,
      (y + size.height / 2) / scale,
    );
  }

  /// The four corners on the page, clockwise from the top-left.
  List<InkVector> get corners {
    final Size local = localSize;
    return <InkVector>[
      toPage(InkVector.zero),
      toPage(InkVector(local.width, 0)),
      toPage(InkVector(local.width, local.height)),
      toPage(InkVector(0, local.height)),
    ];
  }

  /// The upright box around the paper.
  Rect get bounds {
    final List<InkVector> points = corners;
    double left = double.infinity;
    double top = double.infinity;
    double right = double.negativeInfinity;
    double bottom = double.negativeInfinity;
    for (final InkVector p in points) {
      left = math.min(left, p.x);
      top = math.min(top, p.y);
      right = math.max(right, p.x);
      bottom = math.max(bottom, p.y);
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  /// Whether [point] is on the paper: inside its rotated rounded
  /// rectangle, grown by [tolerance] page units.
  bool contains(
    InkVector point, {
    double tolerance = 0,
    double cornerRadius = 0,
  }) {
    final double c = math.cos(rotation);
    final double s = math.sin(rotation);
    final InkVector d = point - center;
    // Distance from the middle, folded into one quadrant.
    final double x = (c * d.x + s * d.y).abs();
    final double y = (-s * d.x + c * d.y).abs();
    final double hw = size.width / 2;
    final double hh = size.height / 2;
    if (x > hw + tolerance || y > hh + tolerance) {
      return false;
    }
    final double r = math.min(cornerRadius * scale, math.min(hw, hh));
    if (r <= 0 || x <= hw - r || y <= hh - r) {
      return true;
    }
    final double dx = x - (hw - r);
    final double dy = y - (hh - r);
    return math.sqrt(dx * dx + dy * dy) <= r + tolerance;
  }

  /// This note carried along by [transform]: a similarity, so its ink,
  /// in local coordinates, comes along untouched.
  StickyNoteElement transformed(InkTransform transform) {
    final double factor = transform.scale;
    return copyWith(
      center: transform.apply(center),
      size: Size(size.width * factor, size.height * factor),
      rotation: rotation + transform.angle,
      scale: scale * factor,
    );
  }

  StickyNoteElement copyWith({
    String? id,
    InkVector? center,
    Size? size,
    double? rotation,
    double? scale,
    String? colorId,
    StickyPaperStyle? paper,
    List<Stroke>? strokes,
  }) {
    return StickyNoteElement(
      id: id ?? this.id,
      center: center ?? this.center,
      size: size ?? this.size,
      rotation: rotation ?? this.rotation,
      scale: scale ?? this.scale,
      colorId: colorId ?? this.colorId,
      paper: paper ?? this.paper,
      strokes: strokes ?? this.strokes,
    );
  }

  /// A unique id for a new note.
  static String newId() {
    _idCount++;
    final String time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final String random = _random.nextInt(1 << 32).toRadixString(36);
    return 'sticky-$time-$_idCount-$random';
  }

  static int _idCount = 0;
  static final math.Random _random = math.Random();
}
