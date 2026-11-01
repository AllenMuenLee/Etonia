import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// A rendered PDF page, as one image or as full-width bands stacked top to
/// bottom.
///
/// Handing a big bitmap to the engine copies it on the UI isolate, which
/// can do nothing else meanwhile: about a millisecond per megapixel, so a
/// page filling a tablet screen froze scrolling for several frames each time
/// one finished rendering. A big page is handed over in bands small enough
/// to fit between frames, and is drawn as the stack they make.
class PdfPaper {
  PdfPaper(this.bands) : assert(bands.isNotEmpty);

  PdfPaper.single(ui.Image image) : bands = <ui.Image>[image];

  final List<ui.Image> bands;

  bool get isSingle => bands.length == 1;

  int get width => bands.first.width;

  int get height =>
      bands.fold(0, (int sum, ui.Image band) => sum + band.height);

  /// Another handle on the same bands. Each handle is disposed on its own.
  PdfPaper clone() =>
      PdfPaper(<ui.Image>[for (final ui.Image band in bands) band.clone()]);

  void dispose() {
    for (final ui.Image band in bands) {
      band.dispose();
    }
  }

  /// The whole page as one image the caller owns, for export and the
  /// clipboard. Draws the bands together when there are several.
  Future<ui.Image> toImage() async {
    if (isSingle) return bands.single.clone();
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    paint(
      Canvas(recorder),
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()
        ..filterQuality = FilterQuality.none
        ..isAntiAlias = false,
    );
    final ui.Picture picture = recorder.endRecording();
    try {
      return await picture.toImage(width, height);
    } finally {
      picture.dispose();
    }
  }

  /// Draws the page stretched to [rect].
  void paint(Canvas canvas, Rect rect, Paint paint) {
    final double scale = rect.height / height;
    int top = 0;
    for (int i = 0; i < bands.length; i++) {
      final ui.Image band = bands[i];
      final double y = rect.top + top * scale;
      final double bottom = rect.top + (top + band.height) * scale;
      // Keep every band at exactly the same scale. Extending one band under
      // the next stretches it and then clips its final source row, which can
      // cut through text that happens to cross a band boundary.
      canvas.drawImageRect(
        band,
        Rect.fromLTWH(0, 0, band.width.toDouble(), band.height.toDouble()),
        Rect.fromLTRB(rect.left, y, rect.right, bottom),
        paint,
      );
      top += band.height;
    }
  }
}

/// Paints a banded [PdfPaper] over the whole of its box.
class PdfPaperPainter extends CustomPainter {
  const PdfPaperPainter(
    this.paper, {
    this.filterQuality = FilterQuality.medium,
  });

  final PdfPaper paper;
  final FilterQuality filterQuality;

  @override
  void paint(Canvas canvas, Size size) {
    paper.paint(
      canvas,
      Offset.zero & size,
      Paint()..filterQuality = filterQuality,
    );
  }

  @override
  bool shouldRepaint(PdfPaperPainter oldDelegate) =>
      !identical(oldDelegate.paper, paper) ||
      oldDelegate.filterQuality != filterQuality;
}
