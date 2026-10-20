import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'selection_image_renderer.dart';

/// Draws a coordinate grid over the selected-ink image the model is sent,
/// so that it can read off where things are in note coordinates.
///
/// Faint lines cross the picture at round note_normalized x and y values.
/// Their numbers are written only in a white margin added around the
/// picture, x along the top and bottom and y down the left and right, so no
/// number covers the user's content. One image goes out, the grid in it.
class SelectionGridRenderer {
  const SelectionGridRenderer({
    this.targetLines = 8,
    this.maxPngBytes = 3500000,
  });

  /// About how many lines cross each side.
  final int targetLines;

  /// A gridded image larger than this is not sent; the plain one is.
  final int maxPngBytes;

  static const ui.Color _paper = ui.Color(0xFFFFFFFF);
  static const ui.Color _line = ui.Color(0x593B82F6);
  static const ui.Color _frame = ui.Color(0xFF9CA3AF);
  static const ui.Color _label = ui.Color(0xFF1D4ED8);

  /// [image] with the grid, as PNG bytes, for a note [noteSize] logical
  /// units big. Falls back to [image]'s own bytes when it cannot be drawn.
  Future<Uint8List> render(SelectionImage image, ui.Size noteSize) async {
    if (!noteSize.isFinite || noteSize.isEmpty || image.scale <= 0) {
      return image.png;
    }
    ui.Image? source;
    ui.Image? gridded;
    ui.Picture? picture;
    try {
      source = await _decode(image.png);
      final ui.Rect crop = image.logicalBounds;
      final double width = source.width.toDouble();
      final double height = source.height.toDouble();
      // Pixel in the picture -> note_normalized, and back.
      double xAt(double nx) => (nx * noteSize.width - crop.left) * image.scale;
      double yAt(double ny) => (ny * noteSize.height - crop.top) * image.scale;
      final double xFrom = crop.left / noteSize.width;
      final double xTo = crop.right / noteSize.width;
      final double yFrom = crop.top / noteSize.height;
      final double yTo = crop.bottom / noteSize.height;
      final double xStep = _niceStep(xTo - xFrom);
      final double yStep = _niceStep(yTo - yFrom);
      final List<double> xs = _ticks(xFrom, xTo, xStep);
      final List<double> ys = _ticks(yFrom, yTo, yStep);

      final double fontSize = (math.max(width, height) * 0.018).clamp(
        12.0,
        24.0,
      );
      final double pad = fontSize * 0.35;
      final List<ui.Paragraph> xLabels = <ui.Paragraph>[
        for (final double x in xs) _paragraph(_format(x, xStep), fontSize),
      ];
      final List<ui.Paragraph> yLabels = <ui.Paragraph>[
        for (final double y in ys) _paragraph(_format(y, yStep), fontSize),
      ];
      double widest = _paragraph('0.000', fontSize).maxIntrinsicWidth;
      for (final ui.Paragraph label in yLabels) {
        widest = math.max(widest, label.maxIntrinsicWidth);
      }
      final double side = (widest + pad * 2).ceilToDouble();
      final double band = (fontSize * 1.3 + pad * 2).ceilToDouble();
      final int outWidth = (width + side * 2).round();
      final int outHeight = (height + band * 2).round();

      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final ui.Canvas canvas = ui.Canvas(recorder);
      canvas
        ..drawRect(
          ui.Rect.fromLTWH(0, 0, outWidth.toDouble(), outHeight.toDouble()),
          ui.Paint()..color = _paper,
        )
        ..drawImage(source, ui.Offset(side, band), ui.Paint());
      final double stroke = math.max(1, fontSize / 14);
      final ui.Paint line = ui.Paint()
        ..color = _line
        ..strokeWidth = stroke;
      final ui.Paint tick = ui.Paint()
        ..color = _frame
        ..strokeWidth = stroke;
      final double tickLength = pad;
      for (int i = 0; i < xs.length; i++) {
        final double x = side + xAt(xs[i]);
        canvas
          ..drawLine(ui.Offset(x, band), ui.Offset(x, band + height), line)
          ..drawLine(ui.Offset(x, band - tickLength), ui.Offset(x, band), tick)
          ..drawLine(
            ui.Offset(x, band + height),
            ui.Offset(x, band + height + tickLength),
            tick,
          );
        final ui.Paragraph label = xLabels[i];
        final double left = (x - label.maxIntrinsicWidth / 2).clamp(
          0.0,
          outWidth - label.maxIntrinsicWidth,
        );
        canvas
          ..drawParagraph(
            label,
            ui.Offset(left, band - tickLength - label.height),
          )
          ..drawParagraph(label, ui.Offset(left, band + height + tickLength));
      }
      for (int i = 0; i < ys.length; i++) {
        final double y = band + yAt(ys[i]);
        canvas
          ..drawLine(ui.Offset(side, y), ui.Offset(side + width, y), line)
          ..drawLine(ui.Offset(side - tickLength, y), ui.Offset(side, y), tick)
          ..drawLine(
            ui.Offset(side + width, y),
            ui.Offset(side + width + tickLength, y),
            tick,
          );
        final ui.Paragraph label = yLabels[i];
        final double top = (y - label.height / 2).clamp(
          0.0,
          outHeight - label.height,
        );
        canvas
          ..drawParagraph(
            label,
            ui.Offset(side - tickLength - label.maxIntrinsicWidth, top),
          )
          ..drawParagraph(label, ui.Offset(side + width + tickLength, top));
      }
      canvas.drawRect(
        ui.Rect.fromLTWH(side, band, width, height),
        ui.Paint()
          ..color = _frame
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = stroke,
      );
      picture = recorder.endRecording();
      gridded = await picture.toImage(outWidth, outHeight);
      final ByteData? bytes = await gridded.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (bytes == null ||
          bytes.lengthInBytes == 0 ||
          bytes.lengthInBytes > maxPngBytes) {
        return image.png;
      }
      return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
    } on Object {
      return image.png;
    } finally {
      source?.dispose();
      gridded?.dispose();
      picture?.dispose();
    }
  }

  /// A round step, 1, 2, or 5 times a power of ten, that crosses [span]
  /// about [targetLines] times.
  double _niceStep(double span) {
    if (!span.isFinite || span <= 0) return 0.1;
    final double raw = span / targetLines;
    final double power = math
        .pow(10, (math.log(raw) / math.ln10).floor())
        .toDouble();
    for (final double multiple in const <double>[1, 2, 5, 10]) {
      if (power * multiple >= raw) return power * multiple;
    }
    return power * 10;
  }

  /// Multiples of [step] from [from] to [to].
  List<double> _ticks(double from, double to, double step) {
    final List<double> ticks = <double>[];
    for (
      int i = (from / step).ceil();
      i * step <= to + step * 1e-9 && ticks.length < 64;
      i++
    ) {
      ticks.add(i * step);
    }
    return ticks;
  }

  /// [value] with as many decimals as [step] needs: 0.4, 0.45, 0.425.
  String _format(double value, double step) {
    final int decimals = math.max(
      1,
      -((math.log(step) / math.ln10) + 1e-9).floor(),
    );
    return value.toStringAsFixed(math.min(decimals, 4));
  }

  ui.Paragraph _paragraph(String text, double fontSize) {
    final ui.ParagraphBuilder builder =
        ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: fontSize, maxLines: 1))
          ..pushStyle(
            ui.TextStyle(
              color: _label,
              fontSize: fontSize,
              fontWeight: ui.FontWeight.w600,
            ),
          )
          ..addText(text);
    return builder.build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
  }

  Future<ui.Image> _decode(Uint8List bytes) async {
    final ui.Codec codec = await ui.instantiateImageCodec(bytes);
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }
}
