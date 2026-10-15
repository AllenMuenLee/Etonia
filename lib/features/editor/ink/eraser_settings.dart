import 'package:flutter/foundation.dart';

/// What a pointer on the page does.
enum EditorTool { pen, eraser, select }

enum EraserMode {
  /// Removes only the ink under the eraser; crossed strokes are cut.
  area('Area'),

  /// Removes every stroke the eraser touches, whole.
  stroke('Stroke');

  const EraserMode(this.label);

  final String label;
}

/// Limits and tolerances for the eraser. All lengths are logical canvas
/// pixels, so erasing behaves the same at any device pixel ratio.
class EraserConfig {
  const EraserConfig({
    this.minSize = 8,
    this.maxSize = 80,
    this.defaultSize = 24,
    this.strokeHitRadius = 6,
    this.minPieceLength = 0.01,
  }) : assert(minSize > 0),
       assert(maxSize >= minSize),
       assert(defaultSize >= minSize && defaultSize <= maxSize),
       assert(strokeHitRadius > 0),
       assert(minPieceLength >= 0);

  /// Smallest, largest, and initial eraser diameter in area mode.
  final double minSize;
  final double maxSize;
  final double defaultSize;

  /// Eraser radius in stroke mode. Fixed, so that removing whole strokes
  /// stays precise whatever the area size is.
  final double strokeHitRadius;

  /// A piece left by an area erase is discarded when its centerline is
  /// shorter than this. The default matches the extent below which a drawn
  /// stroke is a dot, so cutting never leaves a speck behind.
  final double minPieceLength;
}

/// How the next erase gesture will behave.
@immutable
class EraserSettings {
  const EraserSettings({required this.mode, required this.size});

  EraserSettings.defaults([EraserConfig config = const EraserConfig()])
    : mode = EraserMode.area,
      size = config.defaultSize;

  final EraserMode mode;

  /// Diameter of the area eraser. Kept, but unused, in stroke mode.
  final double size;

  EraserSettings copyWith({EraserMode? mode, double? size}) {
    return EraserSettings(mode: mode ?? this.mode, size: size ?? this.size);
  }

  @override
  bool operator ==(Object other) {
    return other is EraserSettings && other.mode == mode && other.size == size;
  }

  @override
  int get hashCode => Object.hash(mode, size);
}
