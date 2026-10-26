import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart'
    show
        FontStyle,
        FontWeight,
        TextAlign,
        TextDecoration,
        TextPainter,
        TextSpan,
        TextStyle;
import 'package:flutter/services.dart' show TextEditingValue, TextSelection;

import '../ink/ink_palette.dart';
import '../ink/ink_sample.dart';

enum TextListStyle { none, bullets, numbers }

const double _lineHeight = 1.3;

@immutable
class TextSettings {
  const TextSettings({
    this.fontSize = 20,
    this.ink = InkPalette.ink,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.alignment = TextAlign.left,
    this.listStyle = TextListStyle.none,
  });

  final double fontSize;
  final InkColor ink;
  final bool bold;
  final bool italic;
  final bool underline;
  final TextAlign alignment;
  final TextListStyle listStyle;

  TextStyle resolve(Brightness brightness) => TextStyle(
    color: ink.resolve(brightness),
    fontSize: fontSize,
    height: _lineHeight,
    fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
    fontStyle: italic ? FontStyle.italic : FontStyle.normal,
    decoration: underline ? TextDecoration.underline : TextDecoration.none,
  );

  TextSettings copyWith({
    double? fontSize,
    InkColor? ink,
    bool? bold,
    bool? italic,
    bool? underline,
    TextAlign? alignment,
    TextListStyle? listStyle,
  }) => TextSettings(
    fontSize: fontSize ?? this.fontSize,
    ink: ink ?? this.ink,
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    underline: underline ?? this.underline,
    alignment: alignment ?? this.alignment,
    listStyle: listStyle ?? this.listStyle,
  );

  @override
  bool operator ==(Object other) =>
      other is TextSettings &&
      other.fontSize == fontSize &&
      other.ink == ink &&
      other.bold == bold &&
      other.italic == italic &&
      other.underline == underline &&
      other.alignment == alignment &&
      other.listStyle == listStyle;

  @override
  int get hashCode =>
      Object.hash(fontSize, ink, bold, italic, underline, alignment, listStyle);
}

/// Editable typed text placed in page coordinates.
@immutable
class NoteTextElement {
  const NoteTextElement({
    required this.id,
    required this.position,
    required this.text,
    this.width = 280,
    this.settings = const TextSettings(),
  });

  static int _nextId = 0;
  static String newId() =>
      'text-${DateTime.now().microsecondsSinceEpoch}-${_nextId++}';

  final String id;
  final InkVector position;
  final String text;
  final double width;
  final TextSettings settings;

  bool get isValid =>
      id.isNotEmpty &&
      position.isFinite &&
      width.isFinite &&
      width >= 80 &&
      width <= 1200 &&
      settings.fontSize.isFinite &&
      settings.fontSize >= 8 &&
      settings.fontSize <= 144;

  static final Expando<Rect> _measured = Expando<Rect>(
    'NoteTextElement.bounds',
  );

  /// The box the text fills, wrapped lines included: where the Text tool
  /// reopens it and where its handles sit. At least one line tall, so an
  /// empty box still has somewhere to type.
  Rect get bounds => _measured[this] ??= _measure();

  Rect _measure() {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: settings.resolve(Brightness.light)),
      textAlign: settings.alignment,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);
    final double height = math.max(
      painter.height,
      settings.fontSize * _lineHeight,
    );
    painter.dispose();
    return Rect.fromLTWH(position.x, position.y, width, height);
  }

  NoteTextElement copyWith({
    String? id,
    InkVector? position,
    String? text,
    double? width,
    TextSettings? settings,
  }) => NoteTextElement(
    id: id ?? this.id,
    position: position ?? this.position,
    text: text ?? this.text,
    width: width ?? this.width,
    settings: settings ?? this.settings,
  );
}

/// The marker [style] puts before line [index] of a list.
String listMarker(TextListStyle style, int index) => switch (style) {
  TextListStyle.none => '',
  TextListStyle.bullets => '\u2022 ',
  TextListStyle.numbers => '${index + 1}. ',
};

final RegExp _bulletMarker = RegExp(r'\u2022 ?');
final RegExp _numberMarker = RegExp(r'\d+\. ?');

/// How long the [style] marker that [line] starts with is; 0 without one.
/// Only markers of [style] count, so a plain line that happens to begin
/// "1. " keeps its words.
int _markerLength(String line, TextListStyle style) => switch (style) {
  TextListStyle.none => 0,
  TextListStyle.bullets => _bulletMarker.matchAsPrefix(line)?.end ?? 0,
  TextListStyle.numbers => _numberMarker.matchAsPrefix(line)?.end ?? 0,
};

/// [text] with the markers of [from] taken off every line and those of
/// [to] put on.
String formattedText(
  String text, {
  required TextListStyle from,
  required TextListStyle to,
}) => formatListValue(
  TextEditingValue(text: text),
  from: from,
  to: to,
).text;

/// Rewrites [value] so every line carries the marker of [to], taking off
/// the markers of [from] first. The caret, selection and composing region
/// keep their place in the words.
///
/// With [deleted], an edit that broke a marker (backspace into "\u2022 ") joins
/// that line onto the one above, as backspace at the start of a list item
/// does in other editors, instead of the marker growing back.
TextEditingValue formatListValue(
  TextEditingValue value, {
  required TextListStyle from,
  required TextListStyle to,
  bool deleted = false,
}) {
  if (from == TextListStyle.none && to == TextListStyle.none) return value;
  String text = value.text;
  TextEditingValue current = value;
  if (deleted && from != TextListStyle.none && value.selection.isCollapsed) {
    final int caret = value.selection.extentOffset;
    final int lineStart = caret <= 0
        ? 0
        : text.lastIndexOf('\n', caret - 1) + 1;
    if (lineStart > 0) {
      final int lineEnd = text.indexOf('\n', lineStart);
      final String line = text.substring(
        lineStart,
        lineEnd < 0 ? text.length : lineEnd,
      );
      final int marker = _markerLength(line, from);
      final bool broken =
          marker > 0 && !line.substring(0, marker).endsWith(' ');
      if (broken && caret - lineStart <= marker) {
        text =
            text.substring(0, lineStart - 1) +
            text.substring(lineStart + marker);
        current = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: lineStart - 1),
        );
      }
    }
  }
  if (text.isEmpty) return current;

  final List<String> lines = text.split('\n');
  final List<int> oldStarts = <int>[];
  final List<int> newStarts = <int>[];
  final List<int> oldMarkers = <int>[];
  final List<int> newMarkers = <int>[];
  final StringBuffer out = StringBuffer();
  int oldStart = 0;
  for (int i = 0; i < lines.length; i++) {
    final String line = lines[i];
    final int old = _markerLength(line, from);
    final String marker = listMarker(to, i);
    if (i > 0) out.write('\n');
    oldStarts.add(oldStart);
    newStarts.add(out.length);
    oldMarkers.add(old);
    newMarkers.add(marker.length);
    out
      ..write(marker)
      ..write(line.substring(old));
    oldStart += line.length + 1;
  }

  int map(int offset) {
    if (offset < 0) return offset;
    int i = lines.length - 1;
    while (i > 0 && oldStarts[i] > offset) {
      i--;
    }
    final int column = offset - oldStarts[i];
    return newStarts[i] +
        (column <= oldMarkers[i]
            ? newMarkers[i]
            : column - oldMarkers[i] + newMarkers[i]);
  }

  final TextSelection selection = current.selection;
  return TextEditingValue(
    text: out.toString(),
    selection: selection.isValid
        ? selection.copyWith(
            baseOffset: map(selection.baseOffset),
            extentOffset: map(selection.extentOffset),
          )
        : selection,
    composing: current.composing.isValid
        ? TextRange(
            start: map(current.composing.start),
            end: map(current.composing.end),
          )
        : current.composing,
  );
}

/// The handles that wrap the text box open in the Text tool, in page
/// coordinates: a small capsule above its left corner holds a grip that
/// moves it and a button that deletes it, and a tab on its right edge sets
/// its width.
enum TextFrameHandle { move, resize }

abstract final class TextFrame {
  /// How far the frame stands off the words.
  static const double outset = 8;

  /// One half of the capsule above the box.
  static const Size _button = Size(36, 30);
  static const double _gap = 6;

  /// The thin outline drawn around the open box.
  static Rect frame(Rect bounds) => bounds.inflate(outset);

  /// The capsule above the box's left corner: the grip, then delete.
  static Rect toolbar(Rect bounds) =>
      moveHandle(bounds).expandToInclude(deleteHandle(bounds));

  static Rect moveHandle(Rect bounds) => Rect.fromLTWH(
    bounds.left - outset,
    bounds.top - outset - _gap - _button.height,
    _button.width,
    _button.height,
  );

  static Rect deleteHandle(Rect bounds) =>
      moveHandle(bounds).translate(_button.width, 0);

  static Rect resizeHandle(Rect bounds) => Rect.fromCenter(
    center: Offset(bounds.right + outset, bounds.center.dy),
    width: 24,
    height: 40,
  );

  /// Everything the open box and its handles cover: a press here works the
  /// box rather than starting a new one.
  static Rect chrome(Rect bounds) => frame(bounds)
      .expandToInclude(toolbar(bounds))
      .expandToInclude(resizeHandle(bounds))
      .inflate(4);

  /// The handle at [point] that is dragged, if any. Handles answer a little
  /// beyond their drawn size, for fingers.
  static TextFrameHandle? handleAt(Rect bounds, Offset point) {
    final Rect move = moveHandle(bounds);
    // Not past its right side, where delete sits beside it.
    if (Rect.fromLTRB(
      move.left - 6,
      move.top - 6,
      move.right,
      move.bottom + 6,
    ).contains(point)) {
      return TextFrameHandle.move;
    }
    if (resizeHandle(bounds).inflate(6).contains(point)) {
      return TextFrameHandle.resize;
    }
    return null;
  }
}
