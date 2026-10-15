import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Brightness;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../library/note_content.dart';
import '../../library/note_repository.dart';
import '../ink/ink_sample.dart';
import '../page/page_setup.dart';
import 'document_io_config.dart';
import 'document_models.dart';
import 'document_platform.dart';

enum ExportPageRange { all, current }

class PdfExportOptions {
  const PdfExportOptions({
    this.range = ExportPageRange.all,
    this.includeBackgroundRules = true,
  });
  final ExportPageRange range;
  final bool includeBackgroundRules;
}

class ExportCancellationToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class ExportPageGeometry {
  const ExportPageGeometry({
    required this.logicalSize,
    required this.pointSize,
    required this.contentScale,
  });
  final ui.Size logicalSize;
  final ui.Size pointSize;
  final double contentScale;
}

/// Maps every page kind to paper points and applies the PDF 14,400 pt cap.
ExportPageGeometry exportPageGeometry(
  StoredPage page, {
  ui.Size? currentWritingArea,
  DocumentIoConfig config = const DocumentIoConfig(),
}) {
  ui.Size logical;
  ui.Size points;
  if (page.pdfSource != null) {
    logical = page.pdfSource!.pageSize;
    points = logical * DocumentUnits.pdfPointsPerPageUnit;
  } else {
    switch (page.setup.size) {
      case PageSize.a4Portrait:
        logical = PageSize.a4Portrait.fixedSize!;
        points = ui.Size(PdfPageFormat.a4.width, PdfPageFormat.a4.height);
      case PageSize.a4Landscape:
        logical = PageSize.a4Landscape.fixedSize!;
        points = ui.Size(PdfPageFormat.a4.height, PdfPageFormat.a4.width);
      case PageSize.letterPortrait:
        logical = PageSize.letterPortrait.fixedSize!;
        points = const ui.Size(612, 792);
      case PageSize.letterLandscape:
        logical = PageSize.letterLandscape.fixedSize!;
        points = const ui.Size(792, 612);
      case PageSize.square:
        logical = PageSize.square.fixedSize!;
        points = logical * DocumentUnits.pdfPointsPerPageUnit;
      case PageSize.custom:
        logical = page.setup.customSize!;
        points = logical * DocumentUnits.pdfPointsPerPageUnit;
      case PageSize.infinite:
        final ui.Size fallback = PageSize.a4Portrait.fixedSize!;
        final ui.Size extent = page.extent ?? currentWritingArea ?? fallback;
        logical = currentWritingArea == null
            ? extent
            : ui.Size(
                math.max(extent.width, currentWritingArea.width),
                math.max(extent.height, currentWritingArea.height),
              );
        points = logical * DocumentUnits.pdfPointsPerPageUnit;
      case PageSize.fit:
        logical =
            page.lastFitSize ??
            currentWritingArea ??
            PageSize.a4Portrait.fixedSize!;
        points = logical * DocumentUnits.pdfPointsPerPageUnit;
    }
  }
  final double reduction = math.min(
    1,
    config.maxPdfPagePoints / math.max(points.width, points.height),
  );
  points *= reduction;
  return ExportPageGeometry(
    logicalSize: logical,
    pointSize: points,
    contentScale: points.width / logical.width,
  );
}

String sanitizedPdfFileName(String title) {
  final String clean = title
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '')
      .trim();
  return '${clean.isEmpty ? 'Untitled note' : clean}.pdf';
}

class PdfExporter {
  const PdfExporter({
    required this.rasterizer,
    this.sink = const SystemExportSink(),
    this.config = const DocumentIoConfig(),
    this.pageConfig = const PageConfig(),
  });

  final PdfRasterizer rasterizer;
  final ExportSink sink;
  final DocumentIoConfig config;
  final PageConfig pageConfig;

  Future<Uint8List> buildPdf({
    required String noteId,
    required String title,
    required NoteContent content,
    required NoteRepository repository,
    PdfExportOptions options = const PdfExportOptions(),
    int currentPage = 0,
    ui.Size? currentWritingArea,
    ExportCancellationToken? cancellation,
    void Function(int completed, int total)? onProgress,
  }) async {
    final List<int> indices = options.range == ExportPageRange.current
        ? <int>[currentPage.clamp(0, content.pages.length - 1)]
        : <int>[for (int i = 0; i < content.pages.length; i++) i];
    final Map<String, Uint8List> assets = <String, Uint8List>{};
    for (final StoredPage page in content.pages) {
      for (final image in page.images) {
        if (!assets.containsKey(image.assetId)) {
          try {
            assets[image.assetId] = (await repository.readAsset(
              noteId,
              image.assetId,
            )).bytes;
          } on Object {
            // A missing image affects only that element.
          }
        }
      }
      final String? pdfAsset = page.pdfSource?.assetId;
      if (pdfAsset != null && !assets.containsKey(pdfAsset)) {
        try {
          assets[pdfAsset] = (await repository.readAsset(
            noteId,
            pdfAsset,
          )).bytes;
        } on Object {
          // A missing PDF affects only that page's paper layer.
        }
      }
    }
    final Map<int, Uint8List> pdfBackgrounds = <int, Uint8List>{};
    for (int progress = 0; progress < indices.length; progress++) {
      if (cancellation?.isCancelled ?? false) {
        throw const FileSystemException('Export cancelled');
      }
      final int index = indices[progress];
      final StoredPage page = content.pages[index];
      if (page.pdfSource != null) {
        final Uint8List? sourceBytes = assets[page.pdfSource!.assetId];
        if (sourceBytes == null) {
          onProgress?.call(progress + 1, indices.length);
          continue;
        }
        final ui.Size sourcePoints =
            page.pdfSource!.pageSize * DocumentUnits.pdfPointsPerPageUnit;
        try {
          final RasterizedPdfPage rendered = await rasterizer.render(
            sourceBytes,
            page.pdfSource!.pageIndex,
            pixelWidth: math.max(
              1,
              (sourcePoints.width / 72 * config.exportPdfRasterDpi).round(),
            ),
            pixelHeight: math.max(
              1,
              (sourcePoints.height / 72 * config.exportPdfRasterDpi).round(),
            ),
          );
          pdfBackgrounds[index] = rendered.png;
        } on Object {
          // Keep the page, its images, and ink without the PDF paper.
        }
      }
      onProgress?.call(progress + 1, indices.length);
    }
    final _PreparedExport prepared = _PreparedExport(
      title: title,
      pages: <_PreparedPage>[
        for (final int index in indices)
          _PreparedPage.of(
            content.pages[index],
            geometry: exportPageGeometry(
              content.pages[index],
              currentWritingArea: index == currentPage
                  ? currentWritingArea
                  : null,
              config: config,
            ),
            pdfBackground: pdfBackgrounds[index],
          ),
      ],
      assets: assets,
      includeRules: options.includeBackgroundRules,
      pageConfig: pageConfig,
    );
    return _generateInIsolate(prepared);
  }

  Future<File> exportAndShare({
    required String noteId,
    required String title,
    required NoteContent content,
    required NoteRepository repository,
    PdfExportOptions options = const PdfExportOptions(),
    int currentPage = 0,
    ui.Size? currentWritingArea,
    ExportCancellationToken? cancellation,
    void Function(int completed, int total)? onProgress,
    ui.Rect? sharePositionOrigin,
  }) async {
    final Uint8List bytes = await buildPdf(
      noteId: noteId,
      title: title,
      content: content,
      repository: repository,
      options: options,
      currentPage: currentPage,
      currentWritingArea: currentWritingArea,
      cancellation: cancellation,
      onProgress: onProgress,
    );
    final Directory root = await getTemporaryDirectory();
    final Directory directory = Directory('${root.path}/greatnote-exports');
    await directory.create(recursive: true);
    await for (final FileSystemEntity entity in directory.list()) {
      if (entity is File) {
        await entity.delete();
      }
    }
    final File file = File('${directory.path}/${sanitizedPdfFileName(title)}');
    try {
      await file.writeAsBytes(bytes, flush: true);
      if (cancellation?.isCancelled ?? false) {
        throw const FileSystemException('Export cancelled');
      }
      await sink.share(file, sharePositionOrigin: sharePositionOrigin);
      return file;
    } on Object {
      if (await file.exists()) {
        await file.delete();
      }
      rethrow;
    }
  }
}

class _PreparedExport {
  const _PreparedExport({
    required this.title,
    required this.pages,
    required this.assets,
    required this.includeRules,
    required this.pageConfig,
  });
  final String title;
  final List<_PreparedPage> pages;
  final Map<String, Uint8List> assets;
  final bool includeRules;
  final PageConfig pageConfig;
}

/// Everything one page needs, as plain data: a [Stroke] holds a `dart:ui`
/// `Path`, which cannot cross into the PDF isolate.
class _PreparedPage {
  _PreparedPage.of(
    StoredPage page, {
    required this.geometry,
    this.pdfBackground,
  }) : background = page.setup.background,
       images = page.images,
       strokes = <_PreparedStroke>[
         for (final stroke in page.strokes)
           (
             color: stroke.style.ink.resolve(Brightness.light).toARGB32(),
             width: stroke.style.width,
             isDot: stroke.isDot,
             points: Float64List.fromList(<double>[
               for (final InkVector point in stroke.points) ...<double>[
                 point.x,
                 point.y,
               ],
             ]),
           ),
       ];
  final PageBackground background;
  final List<NoteImageElement> images;
  final List<_PreparedStroke> strokes;
  final ExportPageGeometry geometry;
  final Uint8List? pdfBackground;
}

/// Flattened x, y pairs in [points].
typedef _PreparedStroke = ({
  int color,
  double width,
  bool isDot,
  Float64List points,
});

/// Kept top-level so the isolate closure captures nothing but [prepared].
Future<Uint8List> _generateInIsolate(_PreparedExport prepared) =>
    Isolate.run(() => _generatePdf(prepared));

Future<Uint8List> _generatePdf(_PreparedExport export) async {
  final pw.Document document = pw.Document(
    title: export.title,
    creator: 'Greatnote',
  );
  final Map<String, pw.ImageProvider> images = <String, pw.ImageProvider>{};
  for (final MapEntry<String, Uint8List> asset in export.assets.entries) {
    try {
      images[asset.key] = pw.MemoryImage(asset.value);
    } on Object {
      // A corrupt image affects only that element.
    }
  }
  for (final _PreparedPage prepared in export.pages) {
    final double scale = prepared.geometry.contentScale;
    final List<pw.Widget> layers = <pw.Widget>[
      pw.Positioned.fill(child: pw.Container(color: PdfColors.white)),
      if (export.includeRules && prepared.background != PageBackground.blank)
        pw.Positioned.fill(
          child: pw.CustomPaint(
            painter: (PdfGraphics canvas, PdfPoint size) {
              _paintRules(
                canvas,
                prepared.background,
                scale,
                export.pageConfig,
                size,
              );
            },
          ),
        ),
      if (prepared.pdfBackground != null)
        pw.Positioned.fill(
          child: pw.Image(
            pw.MemoryImage(prepared.pdfBackground!),
            fit: pw.BoxFit.fill,
          ),
        ),
      for (final element in prepared.images)
        if (images[element.assetId] != null)
          pw.Positioned(
            left: (element.center.x - element.size.width / 2) * scale,
            top: (element.center.y - element.size.height / 2) * scale,
            child: pw.Transform.rotate(
              angle: element.rotation,
              child: pw.SizedBox(
                width: element.size.width * scale,
                height: element.size.height * scale,
                child: pw.Image(images[element.assetId]!, fit: pw.BoxFit.fill),
              ),
            ),
          ),
      pw.Positioned.fill(
        child: pw.CustomPaint(
          painter: (PdfGraphics canvas, PdfPoint size) {
            canvas
              ..setLineCap(PdfLineCap.round)
              ..setLineJoin(PdfLineJoin.round);
            for (final _PreparedStroke stroke in prepared.strokes) {
              final Float64List points = stroke.points;
              if (points.isEmpty) continue;
              canvas
                ..setColor(PdfColor.fromInt(stroke.color))
                ..setLineWidth(stroke.width * scale);
              if (stroke.isDot || points.length == 2) {
                canvas
                  ..drawEllipse(
                    points[0] * scale,
                    points[1] * scale,
                    stroke.width * scale / 2,
                    stroke.width * scale / 2,
                  )
                  ..fillPath();
              } else {
                canvas.moveTo(points[0] * scale, points[1] * scale);
                for (int i = 2; i < points.length; i += 2) {
                  canvas.lineTo(points[i] * scale, points[i + 1] * scale);
                }
                canvas.strokePath();
              }
            }
          },
        ),
      ),
    ];
    document.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(
          prepared.geometry.pointSize.width,
          prepared.geometry.pointSize.height,
          marginAll: 0,
        ),
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Stack(fit: pw.StackFit.expand, children: layers),
      ),
    );
  }
  return document.save();
}

void _paintRules(
  PdfGraphics canvas,
  PageBackground background,
  double scale,
  PageConfig config,
  PdfPoint outputSize,
) {
  final double width = outputSize.x;
  final double height = outputSize.y;
  canvas
    ..setStrokeColor(const PdfColor.fromInt(0x2E64748B))
    ..setLineWidth(math.max(0.5, scale));
  void vertical(double x) {
    canvas
      ..moveTo(x * scale, 0)
      ..lineTo(x * scale, height)
      ..strokePath();
  }

  void horizontal(double y) {
    canvas
      ..moveTo(0, y * scale)
      ..lineTo(width, y * scale)
      ..strokePath();
  }

  switch (background) {
    case PageBackground.blank:
      return;
    case PageBackground.lined:
      for (
        double y = config.lineSpacing * 2;
        y * scale <= height;
        y += config.lineSpacing
      ) {
        horizontal(y);
      }
      canvas.setStrokeColor(const PdfColor.fromInt(0x4DB85C5C));
      vertical(config.marginRuleInset);
    case PageBackground.grid:
      for (
        double y = config.gridSpacing;
        y * scale <= height;
        y += config.gridSpacing
      ) {
        horizontal(y);
      }
      for (
        double x = config.gridSpacing;
        x * scale <= width;
        x += config.gridSpacing
      ) {
        vertical(x);
      }
    case PageBackground.dotted:
      canvas.setFillColor(const PdfColor.fromInt(0x5964748B));
      for (
        double y = config.dotSpacing;
        y * scale <= height;
        y += config.dotSpacing
      ) {
        for (
          double x = config.dotSpacing;
          x * scale <= width;
          x += config.dotSpacing
        ) {
          canvas
            ..drawEllipse(x * scale, y * scale, 1.5 * scale, 1.5 * scale)
            ..fillPath();
        }
      }
  }
}
