import 'package:flutter/foundation.dart';

import 'ink_palette.dart';

/// Limits for the single pen. Widths are logical canvas pixels, so a stroke
/// looks the same at any device pixel ratio.
class PenConfig {
  const PenConfig({
    this.minWidth = 1,
    this.maxWidth = 20,
    this.defaultWidth = 3,
  }) : assert(minWidth > 0),
       assert(maxWidth >= minWidth),
       assert(defaultWidth >= minWidth && defaultWidth <= maxWidth);

  final double minWidth;
  final double maxWidth;
  final double defaultWidth;
}

/// What the next stroke will look like.
@immutable
class PenSettings {
  const PenSettings({required this.ink, required this.width});

  PenSettings.defaults([PenConfig config = const PenConfig()])
    : ink = InkPalette.ink,
      width = config.defaultWidth;

  final InkColor ink;
  final double width;

  PenSettings copyWith({InkColor? ink, double? width}) {
    return PenSettings(ink: ink ?? this.ink, width: width ?? this.width);
  }

  @override
  bool operator ==(Object other) {
    return other is PenSettings && other.ink == ink && other.width == width;
  }

  @override
  int get hashCode => Object.hash(ink, width);
}
