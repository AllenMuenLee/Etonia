import 'package:flutter/foundation.dart';

/// Settings shared by document import, screen rendering, and PDF export.
@immutable
class DocumentIoConfig {
  const DocumentIoConfig({
    this.maxStoredImageDimension = 4096,
    this.insertedImageMaxFraction = 0.6,
    this.maxPdfRenderDimension = 4096,
    this.pdfSourceCacheBytes = 16 * 1024 * 1024,
    this.pdfPreloadDistance = 2,
    this.pdfSharpPreloadDistance = 1,
    this.pdfPreviewDimension = 640,
    this.pdfSettleDelay = const Duration(milliseconds: 120),
    this.pdfScrollSettleDelay = const Duration(milliseconds: 360),
    this.pdfSlowScrollFraction = 0.3,
    this.exportPdfRasterDpi = 200,
    this.maxPdfPagePoints = 14400,
  }) : assert(maxStoredImageDimension > 0),
       assert(insertedImageMaxFraction > 0 && insertedImageMaxFraction <= 1),
       assert(maxPdfRenderDimension > 0),
       assert(pdfSourceCacheBytes >= 0),
       assert(pdfPreloadDistance >= 0),
       assert(
         pdfSharpPreloadDistance >= 0 &&
             pdfSharpPreloadDistance <= pdfPreloadDistance,
       ),
       assert(pdfPreviewDimension > 0),
       assert(pdfSlowScrollFraction >= 0 && pdfSlowScrollFraction <= 1),
       assert(exportPdfRasterDpi > 0),
       assert(maxPdfPagePoints > 0);

  final int maxStoredImageDimension;
  final double insertedImageMaxFraction;
  final int maxPdfRenderDimension;
  final int pdfSourceCacheBytes;

  /// How many pages before and after the current one have their PDF
  /// paper rendered ahead of being shown.
  final int pdfPreloadDistance;

  /// How many of those pages on each side are rendered sharp as well as in
  /// preview, once the view settles.
  final int pdfSharpPreloadDistance;

  /// The longest side, in pixels, of the quick render a PDF page shows
  /// while its sharp one is on the way.
  final int pdfPreviewDimension;

  /// How long the page in view must stay the same before the view counts as
  /// focused and sharp renders may start.
  final Duration pdfSettleDelay;

  /// How long the viewport must stay still before sharp renders start;
  /// until then only quick previews render. Longer than [pdfSettleDelay] so
  /// repeated flicks do not start expensive work in the pauses between them.
  final Duration pdfScrollSettleDelay;

  /// A scroll slowed to this fraction of its fastest, as a fling coasting
  /// out, counts as settled: sharp renders start without waiting for it to
  /// stop.
  final double pdfSlowScrollFraction;
  final double exportPdfRasterDpi;
  final double maxPdfPagePoints;
}

/// Greatnote pages use 96 units/inch; PDF uses 72 points/inch.
abstract final class DocumentUnits {
  static const double pageUnitsPerInch = 96;
  static const double pdfPointsPerInch = 72;
  static const double pageUnitsPerPdfPoint =
      pageUnitsPerInch / pdfPointsPerInch;
  static const double pdfPointsPerPageUnit =
      pdfPointsPerInch / pageUnitsPerInch;
}
