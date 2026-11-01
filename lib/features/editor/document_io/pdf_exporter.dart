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
import '../ink/stroke.dart';
import '../page/page_setup.dart';
import '../sticky/sticky_note.dart';
import '../sticky/sticky_note_painter.dart';
import '../text/note_text.dart';
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
        if (!image.isVector && !assets.containsKey(image.assetId)) {
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
    // Each source PDF is parsed once for the whole export when the
    // rasterizer can keep it open, instead of once per page.
    final Map<String, Future<OpenPdf?>> openSources =
        <String, Future<OpenPdf?>>{};
    final PdfRasterizer rasterizer = this.rasterizer;
    try {
      for (int progress = 0; progress < indices.length; progress++) {
        if (cancellation?.isCancelled ?? false) {
          throw const FileSystemException('Export cancelled');
        }
        final int index = indices[progress];
        final StoredPage page = content.pages[index];
        final PdfPageSource? source = page.pdfSource;
        if (source != null) {
          final Uint8List? sourceBytes = assets[source.assetId];
          if (sourceBytes == null) {
            onProgress?.call(progress + 1, indices.length);
            continue;
          }
          final ui.Size sourcePoints =
              source.pageSize * DocumentUnits.pdfPointsPerPageUnit;
          final int pixelWidth = math.max(
            1,
            (sourcePoints.width / 72 * config.exportPdfRasterDpi).round(),
          );
          final int pixelHeight = math.max(
            1,
            (sourcePoints.height / 72 * config.exportPdfRasterDpi).round(),
          );
          try {
            final OpenPdf? open = rasterizer is PdfDocumentRasterizer
                ? await (openSources[source.assetId] ??=
                      (rasterizer as PdfDocumentRasterizer)
                          .open(sourceBytes)
                          .then<OpenPdf?>(
                            (OpenPdf pdf) => pdf,
                            onError: (Object _) => null,
                          ))
                : null;
            pdfBackgrounds[index] = open == null
                ? (await rasterizer.render(
                    sourceBytes,
                    source.pageIndex,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                  )).png
                : await _encodePng(
                    await open.renderImage(
                      source.pageIndex,
                      pixelWidth: pixelWidth,
                      pixelHeight: pixelHeight,
                    ),
                  );
          } on Object {
            // Keep the page, its images, and ink without the PDF paper.
          }
          // Let frames through between page renders on long exports.
          await Future<void>.delayed(Duration.zero);
        }
        onProgress?.call(progress + 1, indices.length);
      }
    } finally {
      for (final Future<OpenPdf?> open in openSources.values) {
        await (await open)?.dispose();
      }
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
       pdfMasks = page.pdfMasks,
       images = page.images,
       stickies = <_PreparedSticky>[
         for (final StickyNoteElement note in page.stickyNotes)
           if (note.isValid) _PreparedSticky.of(note),
       ],
       texts = <_PreparedText>[
         for (final NoteTextElement text in page.textElements)
           if (text.isValid) _PreparedText.of(text),
       ],
       strokes = <_PreparedStroke>[
         for (final stroke in page.strokes) _prepareStroke(stroke),
       ];
  final PageBackground background;

  /// Areas of the PDF paper left blank.
  final List<ui.Rect> pdfMasks;
  final List<NoteImageElement> images;
  final List<_PreparedSticky> stickies;
  final List<_PreparedText> texts;
  final List<_PreparedStroke> strokes;
  final ExportPageGeometry geometry;
  final Uint8List? pdfBackground;
}

class _PreparedText {
  const _PreparedText({
    required this.text,
    required this.x,
    required this.y,
    required this.width,
    required this.fontSize,
    required this.color,
    required this.bold,
    required this.italic,
    required this.underline,
    required this.alignment,
  });

  factory _PreparedText.of(NoteTextElement element) => _PreparedText(
    text: element.text,
    x: element.position.x,
    y: element.position.y,
    width: element.width,
    fontSize: element.settings.fontSize,
    color: element.settings.ink.resolve(Brightness.light).toARGB32(),
    bold: element.settings.bold,
    italic: element.settings.italic,
    underline: element.settings.underline,
    alignment: element.settings.alignment.name,
  );

  final String text;
  final double x;
  final double y;
  final double width;
  final double fontSize;
  final int color;
  final bool bold;
  final bool italic;
  final bool underline;
  final String alignment;
}

/// [stroke] as plain data, its points carried through [map] and its width
/// multiplied by [widthScale]: as is for page ink, onto the page for a
/// sticky note's.
_PreparedStroke _prepareStroke(
  Stroke stroke, {
  InkVector Function(InkVector point)? map,
  double widthScale = 1,
}) {
  return (
    // Opaque; the opacity is applied once, by the PDF's graphic state, so
    // overlapping highlighter marks darken as on screen.
    color: stroke.style.ink.resolve(Brightness.light).toARGB32(),
    opacity: stroke.style.opacity,
    width: stroke.style.width * widthScale,
    isDot: stroke.isDot,
    widths: stroke.widths == null ? null : Float64List.fromList(stroke.widths!),
    points: Float64List.fromList(<double>[
      for (final InkVector local in stroke.points)
        for (final InkVector point in <InkVector>[
          map?.call(local) ?? local,
        ]) ...<double>[point.x, point.y],
    ]),
  );
}

/// A sticky note as plain data, already on the page: its paper outline,
/// its pattern from [StickyPattern] (the same geometry the screen draws),
/// and its ink. The ink is clipped to the paper as vector content; nothing
/// is rasterized.
class _PreparedSticky {
  _PreparedSticky.of(
    StickyNoteElement note, [
    StickyNoteConfig config = const StickyNoteConfig(),
  ]) : paper = note.color.paper.toARGB32(),
       pattern = note.color.pattern.toARGB32(),
       ruleWidth = config.ruleWidth * note.scale,
       dotRadius = config.dotRadius * note.scale,
       outline = _outline(note, config),
       lines = _lines(note, config),
       dots = _dots(note, config),
       strokes = <_PreparedStroke>[
         for (final Stroke stroke in note.strokes)
           _prepareStroke(stroke, map: note.toPage, widthScale: note.scale),
       ];

  final int paper;
  final int pattern;
  final double ruleWidth;
  final double dotRadius;

  /// The rounded paper, on the page: a start point, then for each side a
  /// line end and a corner as one cubic curve (two controls and an end).
  final Float64List outline;

  /// x1, y1, x2, y2 for each rule.
  final Float64List lines;

  /// x, y for each dot.
  final Float64List dots;
  final List<_PreparedStroke> strokes;

  static Float64List _outline(StickyNoteElement note, StickyNoteConfig config) {
    final ui.Size local = note.localSize;
    final double w = local.width;
    final double h = local.height;
    final double r = math.min(config.cornerRadius, math.min(w, h) / 2);
    // How far a cubic's controls sit along the tangents for a quarter
    // circle.
    final double k = r * 0.5522847498;
    final List<InkVector> points = <InkVector>[
      InkVector(r, 0),
      InkVector(w - r, 0),
      InkVector(w - r + k, 0),
      InkVector(w, r - k),
      InkVector(w, r),
      InkVector(w, h - r),
      InkVector(w, h - r + k),
      InkVector(w - r + k, h),
      InkVector(w - r, h),
      InkVector(r, h),
      InkVector(r - k, h),
      InkVector(0, h - r + k),
      InkVector(0, h - r),
      InkVector(0, r),
      InkVector(0, r - k),
      InkVector(r - k, 0),
      InkVector(r, 0),
    ];
    return Float64List.fromList(<double>[
      for (final InkVector local in points)
        for (final InkVector point in <InkVector>[
          note.toPage(local),
        ]) ...<double>[point.x, point.y],
    ]);
  }

  static Float64List _lines(StickyNoteElement note, StickyNoteConfig config) {
    final StickyPattern pattern = StickyPattern.of(
      note.paper,
      note.localSize,
      config,
    );
    return Float64List.fromList(<double>[
      for (final (InkVector a, InkVector b) in pattern.lines)
        for (final InkVector point in <InkVector>[
          note.toPage(a),
          note.toPage(b),
        ]) ...<double>[point.x, point.y],
    ]);
  }

  static Float64List _dots(StickyNoteElement note, StickyNoteConfig config) {
    final StickyPattern pattern = StickyPattern.of(
      note.paper,
      note.localSize,
      config,
    );
    return Float64List.fromList(<double>[
      for (final InkVector dot in pattern.dots)
        for (final InkVector point in <InkVector>[
          note.toPage(dot),
        ]) ...<double>[point.x, point.y],
    ]);
  }
}

/// Paints [note], [scale] PDF units to a page unit: its paper, then its
/// pattern and ink clipped to the paper's rounded outline.
void _paintPreparedSticky(
  PdfGraphics canvas,
  _PreparedSticky note,
  double scale,
) {
  void outline() {
    final Float64List p = note.outline;
    canvas.moveTo(p[0] * scale, p[1] * scale);
    int i = 2;
    for (int side = 0; side < 4; side++) {
      canvas
        ..lineTo(p[i] * scale, p[i + 1] * scale)
        ..curveTo(
          p[i + 2] * scale,
          p[i + 3] * scale,
          p[i + 4] * scale,
          p[i + 5] * scale,
          p[i + 6] * scale,
          p[i + 7] * scale,
        );
      i += 8;
    }
    canvas.closePath();
  }

  canvas.saveContext();
  outline();
  canvas
    ..setFillColor(PdfColor.fromInt(note.paper))
    ..fillPath();
  outline();
  canvas.clipPath();
  if (note.lines.isNotEmpty) {
    canvas
      ..setStrokeColor(PdfColor.fromInt(note.pattern))
      ..setLineWidth(note.ruleWidth * scale);
    for (int i = 0; i + 3 < note.lines.length; i += 4) {
      canvas
        ..moveTo(note.lines[i] * scale, note.lines[i + 1] * scale)
        ..lineTo(note.lines[i + 2] * scale, note.lines[i + 3] * scale);
    }
    canvas.strokePath();
  }
  if (note.dots.isNotEmpty) {
    canvas.setFillColor(PdfColor.fromInt(note.pattern));
    for (int i = 0; i + 1 < note.dots.length; i += 2) {
      canvas.drawEllipse(
        note.dots[i] * scale,
        note.dots[i + 1] * scale,
        note.dotRadius * scale,
        note.dotRadius * scale,
      );
    }
    canvas.fillPath();
  }
  _paintPreparedStrokes(canvas, note.strokes, scale);
  canvas.restoreContext();
}

/// Flattened x, y pairs in [points].
typedef _PreparedStroke = ({
  int color,
  double opacity,
  double width,
  bool isDot,
  Float64List? widths,
  Float64List points,
});

/// Kept top-level so the isolate closure captures nothing but [prepared].
/// Encodes [image] with the engine's native PNG codec and disposes it.
Future<Uint8List> _encodePng(ui.Image image) async {
  try {
    final ByteData? png = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    if (png == null) {
      throw StateError('The PDF page could not be encoded.');
    }
    return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  } finally {
    image.dispose();
  }
}

Future<Uint8List> _generateInIsolate(_PreparedExport prepared) =>
    Isolate.run(() => _generatePdf(prepared));

Future<Uint8List> _generatePdf(_PreparedExport export) async {
  final pw.Document document = pw.Document(
    title: export.title,
    creator: 'Etonia',
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
      if (prepared.pdfBackground != null)
        for (final ui.Rect mask in prepared.pdfMasks)
          pw.Positioned(
            left: mask.left * scale,
            top: mask.top * scale,
            child: pw.Container(
              width: mask.width * scale,
              height: mask.height * scale,
              color: PdfColors.white,
            ),
          ),
      for (final element in prepared.images)
        if (element.vector != null || images[element.assetId] != null)
          pw.Positioned(
            left: (element.center.x - element.size.width / 2) * scale,
            top: (element.center.y - element.size.height / 2) * scale,
            child: pw.Transform.rotate(
              angle: element.rotation,
              child: pw.SizedBox(
                width: element.size.width * scale,
                height: element.size.height * scale,
                child: element.vector != null
                    ? pw.SvgImage(
                        svg: element.vector!.frame(
                          element.vector!.stepCount,
                          brightness: Brightness.light,
                        ),
                      )
                    : pw.Image(images[element.assetId]!, fit: pw.BoxFit.fill),
              ),
            ),
          ),
      pw.Positioned.fill(
        child: pw.CustomPaint(
          painter: (PdfGraphics canvas, PdfPoint size) {
            _paintPreparedStrokes(canvas, prepared.strokes, scale);
          },
        ),
      ),
      // Sticky notes above images and page ink.
      if (prepared.stickies.isNotEmpty)
        pw.Positioned.fill(
          child: pw.CustomPaint(
            painter: (PdfGraphics canvas, PdfPoint size) {
              for (final _PreparedSticky note in prepared.stickies) {
                _paintPreparedSticky(canvas, note, scale);
              }
            },
          ),
        ),
      for (final _PreparedText text in prepared.texts)
        pw.Positioned(
          left: text.x * scale,
          top: text.y * scale,
          child: pw.SizedBox(
            width: text.width * scale,
            child: pw.Text(
              text.text,
              textAlign: switch (text.alignment) {
                'center' => pw.TextAlign.center,
                'right' || 'end' => pw.TextAlign.right,
                _ => pw.TextAlign.left,
              },
              style: pw.TextStyle(
                color: PdfColor.fromInt(text.color),
                fontSize: text.fontSize * scale,
                fontWeight: text.bold
                    ? pw.FontWeight.bold
                    : pw.FontWeight.normal,
                fontStyle: text.italic
                    ? pw.FontStyle.italic
                    : pw.FontStyle.normal,
                decoration: text.underline
                    ? pw.TextDecoration.underline
                    : pw.TextDecoration.none,
                height: 1.3,
              ),
            ),
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

/// Draws [strokes] in order, [scale] PDF units to a page unit. A
/// translucent stroke (a highlighter) is drawn under a graphic state with
/// its opacity, once, so it composites over what is below like on screen.
void _paintPreparedStrokes(
  PdfGraphics canvas,
  List<_PreparedStroke> strokes,
  double scale,
) {
  canvas
    ..setLineCap(PdfLineCap.round)
    ..setLineJoin(PdfLineJoin.round);
  for (final _PreparedStroke stroke in strokes) {
    final Float64List points = stroke.points;
    if (points.isEmpty) continue;
    final bool translucent = stroke.opacity < 1;
    if (translucent) {
      canvas
        ..saveContext()
        ..setGraphicState(PdfGraphicState(opacity: stroke.opacity));
    }
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
    } else if (stroke.widths != null) {
      // Varying width: each segment at the mean of its ends, with round
      // caps closing the joins.
      final Float64List widths = stroke.widths!;
      for (int i = 2; i < points.length; i += 2) {
        final int at = i ~/ 2;
        canvas
          ..setLineWidth(
            stroke.width * scale * (widths[at - 1] + widths[at]) / 2,
          )
          ..moveTo(points[i - 2] * scale, points[i - 1] * scale)
          ..lineTo(points[i] * scale, points[i + 1] * scale)
          ..strokePath();
      }
    } else {
      canvas.moveTo(points[0] * scale, points[1] * scale);
      for (int i = 2; i < points.length; i += 2) {
        canvas.lineTo(points[i] * scale, points[i + 1] * scale);
      }
      canvas.strokePath();
    }
    if (translucent) {
      canvas.restoreContext();
    }
  }
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
