import 'package:flutter/foundation.dart';

/// Limits shared by document import, screen rendering, and PDF export.
@immutable
class DocumentIoConfig {
  const DocumentIoConfig({
    this.maxImportPdfBytes = 200 * 1024 * 1024,
    this.maxImportPdfPages = 500,
    this.maxImageImportBytes = 50 * 1024 * 1024,
    this.maxStoredImageDimension = 4096,
    this.insertedImageMaxFraction = 0.6,
    this.maxPdfRenderDimension = 4096,
    this.pdfRenderCacheSize = 7,
    this.pdfPreloadDistance = 2,
    this.exportPdfRasterDpi = 200,
    this.maxPdfPagePoints = 14400,
  }) : assert(maxImportPdfBytes > 0),
       assert(maxImportPdfPages > 0),
       assert(maxImageImportBytes > 0),
       assert(maxStoredImageDimension > 0),
       assert(insertedImageMaxFraction > 0 && insertedImageMaxFraction <= 1),
       assert(maxPdfRenderDimension > 0),
       assert(pdfRenderCacheSize > 2 * pdfPreloadDistance),
       assert(pdfPreloadDistance >= 0),
       assert(exportPdfRasterDpi > 0),
       assert(maxPdfPagePoints > 0);

  final int maxImportPdfBytes;
  final int maxImportPdfPages;
  final int maxImageImportBytes;
  final int maxStoredImageDimension;
  final double insertedImageMaxFraction;
  final int maxPdfRenderDimension;
  final int pdfRenderCacheSize;

  /// How many pages before and after the current one have their PDF
  /// paper rendered ahead of being shown.
  final int pdfPreloadDistance;
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
