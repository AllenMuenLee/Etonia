import 'dart:typed_data';
import 'dart:ui';

import 'package:image/image.dart' as image;

/// A rectangular PDF-page excerpt encoded as a PNG for the image clipboard.
class PdfSelectionImage {
  const PdfSelectionImage({
    required this.png,
    required this.pixelSize,
    required this.logicalBounds,
  });

  final Uint8List png;
  final Size pixelSize;
  final Rect logicalBounds;
}

/// Crops a rendered PDF page using page-local logical coordinates.
///
/// Pixel edges expand outwards, so the requested area is never clipped by
/// rounding. The returned logical bounds remain exact and determine the size
/// and position of the image when it is pasted back onto a note.
///
/// The page-local [blanks], areas of the paper left blank, come out as
/// blank paper.
PdfSelectionImage cropPdfSelection(
  Uint8List renderedPage,
  Size pageSize,
  Rect selection, {
  List<Rect> blanks = const <Rect>[],
}) {
  if (!pageSize.isFinite ||
      pageSize.isEmpty ||
      !selection.isFinite ||
      selection.isEmpty) {
    throw const FormatException('Invalid PDF selection');
  }
  final Rect bounds = selection.intersect(Offset.zero & pageSize);
  if (bounds.isEmpty) {
    throw const FormatException('PDF selection is outside the page');
  }
  final image.Image? decoded = image.decodeImage(renderedPage);
  if (decoded == null || decoded.width <= 0 || decoded.height <= 0) {
    throw const FormatException('PDF page could not be decoded');
  }
  final double scaleX = decoded.width / pageSize.width;
  final double scaleY = decoded.height / pageSize.height;
  final int left = (bounds.left * scaleX).floor().clamp(0, decoded.width - 1);
  final int top = (bounds.top * scaleY).floor().clamp(0, decoded.height - 1);
  final int right = (bounds.right * scaleX).ceil().clamp(
    left + 1,
    decoded.width,
  );
  final int bottom = (bounds.bottom * scaleY).ceil().clamp(
    top + 1,
    decoded.height,
  );
  final image.Image cropped = image.copyCrop(
    decoded,
    x: left,
    y: top,
    width: right - left,
    height: bottom - top,
  );
  for (final Rect blank in blanks) {
    final int x1 = (blank.left * scaleX).floor() - left;
    final int y1 = (blank.top * scaleY).floor() - top;
    final int x2 = (blank.right * scaleX).ceil() - left;
    final int y2 = (blank.bottom * scaleY).ceil() - top;
    if (x2 <= 0 || y2 <= 0 || x1 >= cropped.width || y1 >= cropped.height) {
      continue;
    }
    image.fillRect(
      cropped,
      x1: x1.clamp(0, cropped.width - 1),
      y1: y1.clamp(0, cropped.height - 1),
      x2: (x2 - 1).clamp(0, cropped.width - 1),
      y2: (y2 - 1).clamp(0, cropped.height - 1),
      color: image.ColorRgb8(255, 255, 255),
      alphaBlend: false,
    );
  }
  return PdfSelectionImage(
    png: Uint8List.fromList(image.encodePng(cropped)),
    pixelSize: Size(cropped.width.toDouble(), cropped.height.toDouble()),
    logicalBounds: bounds,
  );
}
