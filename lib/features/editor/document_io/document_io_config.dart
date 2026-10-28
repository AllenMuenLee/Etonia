import 'package:flutter/foundation.dart';

/// Settings shared by document import, screen rendering, and PDF export.
@immutable
class DocumentIoConfig {
  const DocumentIoConfig({
    this.maxStoredImageDimension = 4096,
    this.insertedImageMaxFraction = 0.6,
    this.maxPdfRenderDimension = 4096,
    this.pdfRenderCacheSize = 7,
    this.pdfRenderCacheBytes = 160 * 1024 * 1024,
    this.pdfSourceCacheBytes = 16 * 1024 * 1024,
    this.pdfPreloadDistance = 2,
    this.pdfSharpPreloadDistance = 1,
    this.pdfPreviewDimension = 640,
    this.pdfPreviewCacheBytes = 32 * 1024 * 1024,
    this.pdfSettleDelay = const Duration(milliseconds: 120),
    this.pdfScrollSettleDelay = const Duration(milliseconds: 360),
    this.exportPdfRasterDpi = 200,
    this.maxPdfPagePoints = 14400,
  }) : assert(maxStoredImageDimension > 0),
       assert(insertedImageMaxFraction > 0 && insertedImageMaxFraction <= 1),
       assert(maxPdfRenderDimension > 0),
       assert(pdfRenderCacheSize > 2 * pdfPreloadDistance),
       assert(pdfRenderCacheBytes > 0),
       assert(pdfSourceCacheBytes >= 0),
       assert(pdfPreloadDistance >= 0),
       assert(
         pdfSharpPreloadDistance >= 0 &&
             pdfSharpPreloadDistance <= pdfPreloadDistance,
       ),
       assert(pdfPreviewDimension > 0),
       assert(pdfPreviewCacheBytes >= 0),
       assert(exportPdfRasterDpi > 0),
       assert(maxPdfPagePoints > 0);

  final int maxStoredImageDimension;
  final double insertedImageMaxFraction;
  final int maxPdfRenderDimension;
  final int pdfRenderCacheSize;

  /// Decoded pixels, including reservations for pending renders. Visible
  /// layer-owned clones may outlive eviction and are not cache-owned bytes.
  final int pdfRenderCacheBytes;
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
  final int pdfPreviewCacheBytes;

  /// How long the page in view must stay the same before the view counts as
  /// focused and sharp renders may start.
  final Duration pdfSettleDelay;

  /// How long the viewport must stay still before sharp renders start;
  /// until then only quick previews render. Longer than [pdfSettleDelay] so
  /// repeated flicks do not start expensive work in the pauses between them.
  final Duration pdfScrollSettleDelay;
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
