import 'dart:math' as math;
import 'dart:typed_data' show Float32List;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The grain of a 2B pencil drawn along a straight edge.
///
/// Geometry is never distorted: the texture is an alpha mask of stippled
/// graphite tooth, laid over strokes that stay perfectly straight. A tile is
/// drawn once, procedurally, and every pencil stroke in the app shares it.
abstract final class PencilTexture {
  static const int _tileSize = 64;
  static ui.Image? _tile;
  static bool _failed = false;

  /// The grain tile, or null when the platform cannot make one, in which case
  /// strokes are simply left clean.
  static ui.Image? get tile {
    if (_tile != null || _failed) return _tile;
    try {
      _tile = _build();
    } on Object {
      _failed = true;
    }
    return _tile;
  }

  static ui.Image _build() {
    final math.Random random = math.Random(2);
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    const Rect bounds = Rect.fromLTWH(0, 0, 64, 64);
    // Graphite never lays down quite solid: a faint overall lift...
    canvas.drawRect(bounds, Paint()..color = const Color(0xF0FFFFFF));
    // ...with paper tooth showing through as sparse pale specks...
    Float32List specks(int count) {
      final Float32List points = Float32List(count * 2);
      for (int i = 0; i < points.length; i++) {
        points[i] = random.nextDouble() * _tileSize;
      }
      return points;
    }

    canvas.drawRawPoints(
      ui.PointMode.points,
      specks(300),
      Paint()
        ..color = const Color(0x66FFFFFF)
        ..blendMode = BlendMode.src
        ..strokeWidth = 1.1
        ..strokeCap = StrokeCap.round,
    );
    // ...and the odd fully loaded grain of lead.
    canvas.drawRawPoints(
      ui.PointMode.points,
      specks(220),
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..blendMode = BlendMode.src
        ..strokeWidth = 1,
    );
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = picture.toImageSync(_tileSize, _tileSize);
    picture.dispose();
    return image;
  }

  /// A shader of the grain, for use as a `dstIn` mask, or null if there is
  /// none.
  static ui.Shader? shader() {
    final ui.Image? image = tile;
    if (image == null) return null;
    return ui.ImageShader(
      image,
      TileMode.repeated,
      TileMode.repeated,
      Matrix4.identity().storage,
    );
  }

  /// Runs [strokes] and lays the grain over what it drew, within [bounds].
  static void paintMasked(Canvas canvas, Rect bounds, VoidCallback strokes) {
    final ui.Shader? grain = shader();
    if (grain == null) {
      strokes();
      return;
    }
    canvas.saveLayer(bounds, Paint());
    strokes();
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = grain
        ..blendMode = BlendMode.dstIn,
    );
    canvas.restore();
  }
}

/// Lays graphite grain over [child]: the straight strokes of an icon pick up
/// pencil tooth without their geometry moving.
class PencilMask extends StatelessWidget {
  const PencilMask({super.key, required this.child, this.enabled = true});

  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled || PencilTexture.tile == null) return child;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (Rect bounds) => PencilTexture.shader()!,
      child: child,
    );
  }
}

/// A stadium outline drawn in pencil: a straight, graphite-grained line.
class PencilStadiumBorder extends StadiumBorder {
  const PencilStadiumBorder({super.side});

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none) return;
    PencilTexture.paintMasked(
      canvas,
      rect.inflate(side.width),
      () => super.paint(canvas, rect, textDirection: textDirection),
    );
  }

  @override
  PencilStadiumBorder copyWith({BorderSide? side}) =>
      PencilStadiumBorder(side: side ?? this.side);

  @override
  ShapeBorder scale(double t) => PencilStadiumBorder(side: side.scale(t));
}
