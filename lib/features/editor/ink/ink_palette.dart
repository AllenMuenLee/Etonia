import 'package:flutter/material.dart';

/// A named ink. It carries one color per theme so that strokes stay legible
/// when the page switches between light and dark paper.
@immutable
class InkColor {
  const InkColor({
    required this.id,
    required this.label,
    required this.onLightPaper,
    required this.onDarkPaper,
  });

  final String id;
  final String label;
  final Color onLightPaper;
  final Color onDarkPaper;

  Color resolve(Brightness brightness) {
    return brightness == Brightness.dark ? onDarkPaper : onLightPaper;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InkColor && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// The curated inks. Every color keeps at least 3:1 contrast against the
/// writing surface in both themes (enforced by a test).
abstract final class InkPalette {
  static const String _importedPrefix = 'imported-';
  static const String _customPrefix = 'custom-';

  static const InkColor ink = InkColor(
    id: 'ink',
    label: 'Black',
    // The app's slate, so ink and type are one color.
    onLightPaper: Color(0xFF0F172A),
    onDarkPaper: Color(0xFFE2E8F0),
  );

  static const List<InkColor> colors = <InkColor>[
    ink,
    InkColor(
      id: 'graphite',
      label: 'Graphite',
      onLightPaper: Color(0xFF5F6368),
      onDarkPaper: Color(0xFFA8ADB3),
    ),
    InkColor(
      id: 'blue',
      label: 'Blue',
      onLightPaper: Color(0xFF1F5FD1),
      onDarkPaper: Color(0xFF7FA8FF),
    ),
    InkColor(
      id: 'red',
      label: 'Red',
      onLightPaper: Color(0xFFC62F2F),
      onDarkPaper: Color(0xFFFF8A80),
    ),
    InkColor(
      id: 'green',
      label: 'Green',
      onLightPaper: Color(0xFF1E7B46),
      onDarkPaper: Color(0xFF6FCF97),
    ),
    InkColor(
      id: 'orange',
      label: 'Orange',
      onLightPaper: Color(0xFFB85C00),
      onDarkPaper: Color(0xFFFFB15C),
    ),
    InkColor(
      id: 'purple',
      label: 'Purple',
      onLightPaper: Color(0xFF7B3FC4),
      onDarkPaper: Color(0xFFC3A2FF),
    ),
    InkColor(
      id: 'teal',
      label: 'Teal',
      onLightPaper: Color(0xFF0F7C82),
      onDarkPaper: Color(0xFF5CCFD6),
    ),
  ];

  static const InkColor highlighterYellow = InkColor(
    id: 'hl-yellow',
    label: 'Yellow',
    onLightPaper: Color(0xFFFFD60A),
    onDarkPaper: Color(0xFFFFE04D),
  );

  /// The highlighter's inks: bright, opaque bases drawn translucent by the
  /// stroke's opacity, so one mark stays see-through on any paper, light,
  /// dark, or imported.
  static const List<InkColor> highlighterColors = <InkColor>[
    highlighterYellow,
    InkColor(
      id: 'hl-green',
      label: 'Green',
      onLightPaper: Color(0xFF34C759),
      onDarkPaper: Color(0xFF5EE07F),
    ),
    InkColor(
      id: 'hl-pink',
      label: 'Pink',
      onLightPaper: Color(0xFFFF4F9A),
      onDarkPaper: Color(0xFFFF7AB4),
    ),
    InkColor(
      id: 'hl-blue',
      label: 'Blue',
      onLightPaper: Color(0xFF30A2FF),
      onDarkPaper: Color(0xFF63B9FF),
    ),
    InkColor(
      id: 'hl-orange',
      label: 'Orange',
      onLightPaper: Color(0xFFFF9F0A),
      onDarkPaper: Color(0xFFFFB443),
    ),
    InkColor(
      id: 'hl-purple',
      label: 'Purple',
      onLightPaper: Color(0xFFAF52DE),
      onDarkPaper: Color(0xFFC77DF0),
    ),
  ];

  /// Resolves the stable ID used by persisted/domain data and AI notation.
  static InkColor? byId(String id) {
    for (final InkColor color in colors) {
      if (color.id == id) {
        return color;
      }
    }
    for (final InkColor color in highlighterColors) {
      if (color.id == id) {
        return color;
      }
    }
    if (id.startsWith(_importedPrefix)) {
      final String value = id.substring(_importedPrefix.length);
      if (RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(value)) {
        final Color color = Color(int.parse(value, radix: 16));
        return InkColor(
          id: '$_importedPrefix${value.toLowerCase()}',
          label: 'Imported',
          onLightPaper: color,
          onDarkPaper: color,
        );
      }
    }
    if (id.startsWith(_customPrefix)) {
      final String value = id.substring(_customPrefix.length);
      if (RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(value)) {
        final Color color = Color(int.parse(value, radix: 16));
        return InkColor(
          id: '$_customPrefix${value.toLowerCase()}',
          label: 'Custom (#${value.substring(2).toUpperCase()})',
          onLightPaper: color,
          onDarkPaper: color,
        );
      }
    }
    return null;
  }

  /// A user-selected custom color picked from the color palette (色盤).
  /// Its stable ID lets it survive the ordinary note JSON format.
  static InkColor custom(Color color) {
    final Color customColor = Color(color.toARGB32());
    final String hex = customColor
        .toARGB32()
        .toRadixString(16)
        .padLeft(8, '0')
        .toLowerCase();
    return InkColor(
      id: '$_customPrefix$hex',
      label: 'Custom (#${hex.substring(2).toUpperCase()})',
      onLightPaper: customColor,
      onDarkPaper: customColor,
    );
  }

  /// A PDF-recovered color that is not constrained to the pen palette.
  /// Its stable ID lets it survive the ordinary note JSON format.
  static InkColor imported(Color color) {
    final Color imported = Color(color.toARGB32());
    return InkColor(
      id: '$_importedPrefix${imported.toARGB32().toRadixString(16).padLeft(8, '0')}',
      label: 'Imported',
      onLightPaper: imported,
      onDarkPaper: imported,
    );
  }
}
