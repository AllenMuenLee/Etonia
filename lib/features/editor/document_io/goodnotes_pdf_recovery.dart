import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data' show BytesBuilder;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import '../ink/ink_palette.dart';
import '../ink/ink_sample.dart';
import '../ink/stroke.dart';
import 'document_io_config.dart';

/// Editable ink and cleaned paper recovered from a Goodnotes Android PDF.
@immutable
class GoodnotesPdfRecovery {
  const GoodnotesPdfRecovery({
    required this.backgroundPdf,
    required this.pageStrokes,
  });

  final Uint8List backgroundPdf;
  final List<List<Stroke>> pageStrokes;
}

/// Conservatively recognizes and recovers the flattened overlay emitted by
/// Goodnotes Android. Unsupported or ambiguous PDFs return null.
class GoodnotesPdfRecoverer {
  const GoodnotesPdfRecoverer();

  Future<GoodnotesPdfRecovery?> recover({
    required Uint8List bytes,
    required List<Size> pageSizes,
    required DocumentIoConfig config,
    bool Function()? isCancelled,
  }) async {
    // This parser is intentionally narrow. Large and unusual files continue
    // through the ordinary PDF import path instead of consuming duplicate
    // memory while probing.
    if (bytes.lengthInBytes > math.min(config.maxImportPdfBytes, 32 << 20) ||
        pageSizes.length > 50) {
      return null;
    }
    final _GoodnotesProbe? probe;
    try {
      probe = await Isolate.run(
        () =>
            _probeGoodnotesPdf(bytes, pageSizes, config.maxPdfRenderDimension),
      );
    } on Object {
      return null;
    }
    if (probe == null || (isCancelled?.call() ?? false)) {
      return null;
    }
    final _GoodnotesProbe matchedProbe = probe;

    try {
      if (isCancelled?.call() ?? false) return null;
      final _RawRecovery? raw = await Isolate.run(
        () => _recoverGoodnotesPdf(bytes, pageSizes, matchedProbe),
      );
      if (raw == null) {
        return null;
      }
      return GoodnotesPdfRecovery(
        backgroundPdf: raw.backgroundPdf,
        pageStrokes: <List<Stroke>>[
          for (final List<_RawStroke> page in raw.pages)
            <Stroke>[
              for (final _RawStroke stroke in page)
                Stroke.fromPoints(
                  style: StrokeStyle(
                    ink: InkPalette.imported(Color(stroke.argb)),
                    width: stroke.width,
                  ),
                  points: <InkVector>[
                    for (int i = 0; i < stroke.points.length; i += 2)
                      InkVector(stroke.points[i], stroke.points[i + 1]),
                  ],
                  widths: stroke.widths,
                ),
            ],
        ],
      );
    } on Object {
      // Recovery must never make an otherwise valid PDF unimportable.
      return null;
    }
  }
}

@immutable
class _GoodnotesProbe {
  const _GoodnotesProbe(this.pages);
  final List<_OverlayGeometry> pages;
}

@immutable
class _OverlayGeometry {
  const _OverlayGeometry(
    this.width,
    this.height,
    this.imageObject,
    this.badgeObject,
  );
  final int width;
  final int height;
  final int imageObject;
  final int badgeObject;
}

@immutable
class _RawRecovery {
  const _RawRecovery(this.backgroundPdf, this.pages);
  final Uint8List backgroundPdf;
  final List<List<_RawStroke>> pages;
}

@immutable
class _RawStroke {
  const _RawStroke({
    required this.argb,
    required this.width,
    required this.points,
    required this.widths,
  });
  final int argb;
  final double width;
  final Float64List points;
  final Float64List widths;
}

_GoodnotesProbe _probeGoodnotesPdf(
  Uint8List bytes,
  List<Size> pageSizes,
  int maxDimension,
) {
  final _NarrowPdf pdf = _NarrowPdf.parse(bytes);
  if (!RegExp(r'/Creator\s*\(PDFium\)').hasMatch(pdf.text)) {
    throw const FormatException('Not a PDFium document');
  }
  final List<_PdfObject> pages = pdf.pageObjects;
  if (pages.length != pageSizes.length || pages.isEmpty) {
    throw const FormatException('Page count mismatch');
  }

  final List<_OverlayGeometry> result = <_OverlayGeometry>[];
  Uint8List? sharedBadge;
  Uint8List? sharedBadgeMask;
  for (int i = 0; i < pages.length; i++) {
    final _PdfObject page = pages[i];
    final List<double>? media = _numbers(page.dictionary, '/MediaBox', 4);
    if (media == null) throw const FormatException('Missing page box');
    final double pointWidth = (media[2] - media[0]).abs();
    final double pointHeight = (media[3] - media[1]).abs();
    final Size expectedPoints =
        pageSizes[i] * DocumentUnits.pdfPointsPerPageUnit;
    if ((pointWidth - expectedPoints.width).abs() > 0.1 ||
        (pointHeight - expectedPoints.height).abs() > 0.1) {
      throw const FormatException('Page size mismatch');
    }
    final List<_PdfImage> images = pdf.imagesForPage(page);
    if (images.length < 2) {
      throw const FormatException('Missing Goodnotes image layers');
    }
    images.sort(
      (_PdfImage a, _PdfImage b) =>
          (b.width * b.height).compareTo(a.width * a.height),
    );
    final _PdfImage overlay = images.first;
    final double xDensity = overlay.width / pointWidth;
    final double yDensity = overlay.height / pointHeight;
    if (overlay.width > maxDimension ||
        overlay.height > maxDimension ||
        xDensity < 100 / 72 ||
        xDensity > 600 / 72 ||
        (xDensity - yDensity).abs() > xDensity * 0.02) {
      throw const FormatException('Overlay geometry mismatch');
    }
    _PdfImage? badge;
    for (final _PdfImage candidate in images.skip(1)) {
      final double aspect = candidate.width / candidate.height;
      if (aspect > 4 &&
          aspect < 7 &&
          candidate.width * candidate.height <
              overlay.width * overlay.height ~/ 20) {
        badge = candidate;
        break;
      }
    }
    if (badge == null) throw const FormatException('Missing Goodnotes badge');
    final Uint8List badgeRgb = pdf.decodeImage(badge);
    final Uint8List badgeAlpha = pdf.decodeMask(badge);
    if (sharedBadge == null) {
      sharedBadge = badgeRgb;
      sharedBadgeMask = badgeAlpha;
    } else if (!_bytesEqual(sharedBadge, badgeRgb) ||
        !_bytesEqual(sharedBadgeMask!, badgeAlpha)) {
      throw const FormatException('Goodnotes badge changed between pages');
    }
    result.add(
      _OverlayGeometry(
        overlay.width,
        overlay.height,
        overlay.object.id,
        badge.object.id,
      ),
    );
  }
  return _GoodnotesProbe(List<_OverlayGeometry>.unmodifiable(result));
}

_RawRecovery? _recoverGoodnotesPdf(
  Uint8List bytes,
  List<Size> pageSizes,
  _GoodnotesProbe probe,
) {
  if (probe.pages.length != pageSizes.length) {
    return null;
  }
  final _NarrowPdf pdf = _NarrowPdf.parse(bytes);
  final List<List<_RawStroke>> strokes = <List<_RawStroke>>[];
  final Map<int, Uint8List> cleanedMasks = <int, Uint8List>{};
  bool removedBadge = false;
  for (int i = 0; i < pageSizes.length; i++) {
    final _OverlayGeometry geometry = probe.pages[i];
    final _PdfImage overlay = pdf.image(geometry.imageObject);
    final Uint8List rgb = pdf.decodeImage(overlay);
    final Uint8List alpha = pdf.decodeMask(overlay);
    final _AnalyzedOverlay analyzed = _analyzeOverlay(
      rgb,
      alpha,
      geometry.width,
      geometry.height,
      pageSizes[i],
    );
    strokes.add(analyzed.strokes);
    final Uint8List cleaned = Uint8List.fromList(alpha);
    for (int pixel = 0; pixel < cleaned.length; pixel++) {
      if (analyzed.inkMask[pixel] != 0) cleaned[pixel] = 0;
    }
    cleanedMasks[overlay.maskObject] = cleaned;
    // The probe identifies the separate, repeated Goodnotes export badge.
    // Clear only its soft mask, leaving the template and nearby ink intact.
    final _PdfImage badge = pdf.image(geometry.badgeObject);
    final Uint8List badgeAlpha = pdf.decodeMask(badge);
    if (badge.maskObject == overlay.maskObject) {
      throw const FormatException('Shared overlay and badge mask');
    }
    if (badgeAlpha.any((int value) => value != 0)) {
      cleanedMasks[badge.maskObject] = Uint8List(badgeAlpha.length);
      removedBadge = true;
    }
  }
  if (!removedBadge &&
      !strokes.any((List<_RawStroke> page) => page.isNotEmpty)) {
    return null;
  }
  return _RawRecovery(
    pdf.rewriteFlateStreams(cleanedMasks),
    List<List<_RawStroke>>.unmodifiable(strokes),
  );
}

@immutable
class _AnalyzedOverlay {
  const _AnalyzedOverlay(this.strokes, this.inkMask);
  final List<_RawStroke> strokes;
  final Uint8List inkMask;
}

_AnalyzedOverlay _analyzeOverlay(
  Uint8List rgb,
  Uint8List alpha,
  int width,
  int height,
  Size pageSize,
) {
  final int count = width * height;
  if (rgb.length != count * 3 || alpha.length != count) {
    throw const FormatException('Invalid Goodnotes image dimensions');
  }
  final Uint8List visited = Uint8List(count);
  final Uint8List inkMask = Uint8List(count);
  final Int32List queue = Int32List(count);
  final List<_RawStroke> recovered = <_RawStroke>[];
  int recoveredPoints = 0;

  for (int origin = 0; origin < count; origin++) {
    if (visited[origin] != 0 || alpha[origin] < 4) continue;
    int head = 0;
    int tail = 0;
    queue[tail++] = origin;
    visited[origin] = 1;
    final List<int> pixels = <int>[];
    int minX = width;
    int minY = height;
    int maxX = 0;
    int maxY = 0;
    double effectiveArea = 0;
    double red = 0;
    double green = 0;
    double blue = 0;
    double colorSquares = 0;
    double colorWeight = 0;
    int maximumAlpha = 0;
    while (head < tail) {
      final int at = queue[head++];
      pixels.add(at);
      final int x = at % width;
      final int y = at ~/ width;
      minX = math.min(minX, x);
      maxX = math.max(maxX, x);
      minY = math.min(minY, y);
      maxY = math.max(maxY, y);
      final double weight = alpha[at] / 255;
      maximumAlpha = math.max(maximumAlpha, alpha[at]);
      effectiveArea += weight;
      if (alpha[at] >= 32) {
        final int p = at * 3;
        red += rgb[p] * weight;
        green += rgb[p + 1] * weight;
        blue += rgb[p + 2] * weight;
        colorSquares +=
            (rgb[p] * rgb[p] +
                rgb[p + 1] * rgb[p + 1] +
                rgb[p + 2] * rgb[p + 2]) *
            weight;
        colorWeight += weight;
      }
      for (int dy = -1; dy <= 1; dy++) {
        final int ny = y + dy;
        if (ny < 0 || ny >= height) continue;
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final int nx = x + dx;
          if (nx < 0 || nx >= width) continue;
          final int next = ny * width + nx;
          if (visited[next] == 0 && alpha[next] >= 4) {
            visited[next] = 1;
            queue[tail++] = next;
          }
        }
      }
    }

    final int boxWidth = maxX - minX + 1;
    final int boxHeight = maxY - minY + 1;
    final int boxArea = boxWidth * boxHeight;
    final double density = pixels.length / boxArea;
    final bool denseFixedRegion =
        boxWidth >= width * 0.12 &&
        boxHeight >= height * 0.06 &&
        (math.max(boxWidth, boxHeight) / math.min(boxWidth, boxHeight) < 6 ||
            density > 0.9) &&
        density >= 0.55;
    final bool tooLargeOrAmbiguous =
        pixels.length > 150000 || boxArea > count * 0.45;
    // A single pen centerline cannot represent a multicolored painting or
    // photo. Keep it in the PDF instead of averaging its colors into ink.
    // This is an appearance check, not OCR or a semantic text classifier.
    final double colorVariance = colorWeight == 0
        ? 0
        : colorSquares / colorWeight -
              (red * red + green * green + blue * blue) /
                  (colorWeight * colorWeight);
    if (pixels.length < 6 ||
        denseFixedRegion ||
        tooLargeOrAmbiguous ||
        colorVariance > 1200) {
      continue;
    }

    final _TracedComponent traced = _traceComponent(
      pixels,
      alpha,
      width,
      minX,
      minY,
      maxX,
      maxY,
      effectiveArea,
    );
    if (traced.paths.isEmpty || colorWeight == 0) continue;
    final double scale =
        (pageSize.width / width + pageSize.height / height) / 2;
    final int argb =
        ((traced.opacity == null
                ? maximumAlpha
                : (traced.opacity! * 255).round().clamp(1, 255)) <<
            24) |
        ((red / colorWeight).round().clamp(0, 255) << 16) |
        ((green / colorWeight).round().clamp(0, 255) << 8) |
        (blue / colorWeight).round().clamp(0, 255);
    final double strokeWidth = (traced.widthPixels * scale).clamp(0.65, 48.0);
    final List<_RawStroke> componentStrokes = <_RawStroke>[];
    for (final _ProfiledPath path in traced.paths) {
      final List<_PixelPoint> simple = path.points;
      if (simple.isEmpty) continue;
      final Float64List points = Float64List(simple.length * 2);
      final Float64List widths = Float64List(simple.length);
      for (int p = 0; p < simple.length; p++) {
        points[p * 2] = (simple[p].x + 0.5) / width * pageSize.width;
        // Decoded image rows and Greatnote page coordinates both start at
        // the top. PDF image placement already accounts for its Y axis.
        points[p * 2 + 1] = (simple[p].y + 0.5) / height * pageSize.height;
        widths[p] = (path.diameters[p] * scale).clamp(0.65, 48.0) / strokeWidth;
      }
      componentStrokes.add(
        _RawStroke(
          argb: argb,
          width: strokeWidth,
          points: points,
          widths: widths,
        ),
      );
      recoveredPoints += simple.length;
    }
    if (componentStrokes.isEmpty) continue;
    if (recovered.length + componentStrokes.length > 5000 ||
        recoveredPoints > 200000) {
      throw const FormatException('Too much recovered ink');
    }
    recovered.addAll(componentStrokes);
    for (final int pixel in pixels) {
      inkMask[pixel] = 1;
    }
  }
  return _AnalyzedOverlay(List<_RawStroke>.unmodifiable(recovered), inkMask);
}

@immutable
class _PixelPoint {
  const _PixelPoint(this.x, this.y);
  final double x;
  final double y;
}

@immutable
class _TracedComponent {
  const _TracedComponent(this.paths, this.widthPixels, {this.opacity});
  final List<_ProfiledPath> paths;
  final double widthPixels;
  final double? opacity;
}

class _ProfiledPath {
  const _ProfiledPath(this.points, this.diameters);
  final List<_PixelPoint> points;
  final List<double> diameters;
}

_TracedComponent _traceComponent(
  List<int> pixels,
  Uint8List alpha,
  int pageWidth,
  int minX,
  int minY,
  int maxX,
  int maxY,
  double effectiveArea,
) {
  final int width = maxX - minX + 3;
  final int height = maxY - minY + 3;
  final Uint8List mask = Uint8List(width * height);
  double centerX = 0;
  double centerY = 0;
  double centerWeight = 0;
  int peakAlpha = 0;
  for (final int pixel in pixels) {
    final int x = pixel % pageWidth;
    final int y = pixel ~/ pageWidth;
    if (alpha[pixel] >= 12) {
      mask[(y - minY + 1) * width + x - minX + 1] = 1;
    }
    final double weight = alpha[pixel] / 255;
    centerX += x * weight;
    centerY += y * weight;
    centerWeight += weight;
    peakAlpha = math.max(peakAlpha, alpha[pixel]);
  }
  final bool textured =
      pixels
          .where(
            (int pixel) => alpha[pixel] >= 12 && alpha[pixel] < peakAlpha * 0.7,
          )
          .length >
      pixels.length * 0.25;
  if (textured) _closeTextureMask(mask, width, height);
  // Pencil grain is an appearance detail, not a network of pen movements.
  // Fill only tiny enclosed holes within this component. Separate marks and
  // open gaps are never joined, and larger counters/loops remain open.
  _fillGrainHoles(mask, width, height);
  final Float32List distance = _inkDistances(mask, width, height);
  final Uint8List skeleton = Uint8List.fromList(mask);
  _thin(skeleton, width, height);
  final List<List<int>> indices = _prunedSkeleton(
    skeleton,
    distance,
    width,
    height,
  );
  // A heavily fragmented centerline is not a trustworthy replacement for
  // textured ink. The caller leaves its original PDF pixels untouched.
  if (indices.length > 64 ||
      (indices.length > 8 &&
          indices.where((p) => p.length <= 3).length > indices.length ~/ 3)) {
    return const _TracedComponent(<_ProfiledPath>[], 1);
  }
  final List<List<_PixelPoint>> paths = <List<_PixelPoint>>[];
  double totalLength = 0;
  for (final List<int> path in indices) {
    if (path.length < 2) continue;
    final List<_PixelPoint> points = <_PixelPoint>[];
    for (final int index in path) {
      points.add(
        _PixelPoint(index % width + minX - 1.0, index ~/ width + minY - 1.0),
      );
    }
    for (int i = 1; i < points.length; i++) {
      totalLength += math.sqrt(
        math.pow(points[i].x - points[i - 1].x, 2) +
            math.pow(points[i].y - points[i - 1].y, 2),
      );
    }
    paths.add(points);
  }
  if (paths.isEmpty && centerWeight > 0) {
    paths.add(<_PixelPoint>[
      _PixelPoint(centerX / centerWeight, centerY / centerWeight),
    ]);
  }
  final int supportArea = mask.where((int pixel) => pixel != 0).length;
  final double widthPixels = totalLength <= 0
      ? 2 * math.sqrt(effectiveArea / math.pi)
      : supportArea / totalLength;
  final List<_ProfiledPath> profiled = <_ProfiledPath>[
    for (final List<_PixelPoint> path in paths)
      _profilePath(
        path,
        mask,
        distance,
        width,
        height,
        minX - 1,
        minY - 1,
        widthPixels,
      ),
  ];
  return _TracedComponent(
    profiled,
    widthPixels.clamp(1.0, 132.0),
    opacity: textured && supportArea > 0
        ? (effectiveArea / supportArea).clamp(0.0, 1.0)
        : null,
  );
}

void _closeTextureMask(Uint8List mask, int width, int height) {
  // One-pixel closing repairs grain notches at a pencil edge as well as
  // pinholes. It is local to one connected mark, never a page-wide dilation
  // that could glue separate strokes together.
  final Uint8List dilated = Uint8List(mask.length);
  for (int y = 1; y < height - 1; y++) {
    for (int x = 1; x < width - 1; x++) {
      if (mask[y * width + x] == 0) continue;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          dilated[(y + dy) * width + x + dx] = 1;
        }
      }
    }
  }
  for (int y = 1; y < height - 1; y++) {
    for (int x = 1; x < width - 1; x++) {
      bool full = true;
      for (int dy = -1; dy <= 1 && full; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dilated[(y + dy) * width + x + dx] == 0) {
            full = false;
            break;
          }
        }
      }
      if (full) mask[y * width + x] = 1;
    }
  }
}

void _fillGrainHoles(Uint8List mask, int width, int height) {
  final Uint8List seen = Uint8List(mask.length);
  final Int32List queue = Int32List(mask.length);
  for (int start = 0; start < mask.length; start++) {
    if (mask[start] != 0 || seen[start] != 0) continue;
    int head = 0;
    int tail = 1;
    queue[0] = start;
    seen[start] = 1;
    bool border = false;
    while (head < tail) {
      final int at = queue[head++];
      final int x = at % width;
      final int y = at ~/ width;
      if (x == 0 || y == 0 || x == width - 1 || y == height - 1) border = true;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          final int nx = x + dx;
          final int ny = y + dy;
          if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
          final int next = ny * width + nx;
          if (mask[next] == 0 && seen[next] == 0) {
            seen[next] = 1;
            queue[tail++] = next;
          }
        }
      }
    }
    if (!border && tail <= 4) {
      for (int i = 0; i < tail; i++) {
        mask[queue[i]] = 1;
      }
    }
  }
}

// Two bounded chamfer passes estimate local radius for spur pruning.
Float32List _inkDistances(Uint8List mask, int width, int height) {
  final Float32List distance = Float32List(mask.length);
  for (int i = 0; i < mask.length; i++) {
    if (mask[i] != 0) distance[i] = 100000;
  }
  for (int pass = 0; pass < 2; pass++) {
    final int step = pass == 0 ? 1 : -1;
    for (
      int y = pass == 0 ? 1 : height - 2;
      y > 0 && y < height - 1;
      y += step
    ) {
      for (
        int x = pass == 0 ? 1 : width - 2;
        x > 0 && x < width - 1;
        x += step
      ) {
        final int at = y * width + x;
        if (mask[at] == 0) continue;
        distance[at] = math.min(
          distance[at],
          math.min(
            math.min(distance[at - step] + 1, distance[at - step * width] + 1),
            math.min(
                  distance[at - step * width - 1],
                  distance[at - step * width + 1],
                ) +
                math.sqrt2,
          ),
        );
      }
    }
  }
  return distance;
}

List<List<int>> _prunedSkeleton(
  Uint8List mask,
  Float32List distance,
  int width,
  int height,
) {
  List<List<int>> paths = _traceSkeleton(mask, width, height);
  for (int pass = 0; pass < 3; pass++) {
    final Map<int, int> degree = <int, int>{};
    for (final List<int> path in paths) {
      for (final int end in <int>[path.first, path.last]) {
        degree[end] = (degree[end] ?? 0) + 1;
      }
    }
    bool changed = false;
    for (final List<int> path in paths) {
      final bool startsAtJunction =
          degree[path.first]! >= 3 && degree[path.last] == 1;
      final bool endsAtJunction =
          degree[path.last]! >= 3 && degree[path.first] == 1;
      if (!startsAtJunction && !endsAtJunction) continue;
      final int junction = startsAtJunction ? path.first : path.last;
      double length = 0;
      for (int i = 1; i < path.length; i++) {
        final int dx = path[i] % width - path[i - 1] % width;
        final int dy = path[i] ~/ width - path[i - 1] ~/ width;
        length += math.sqrt((dx * dx + dy * dy).toDouble());
      }
      if (length > (distance[junction] * 1.25).clamp(1.5, 6.0)) continue;
      for (final int at in path) {
        if (at != junction) mask[at] = 0;
      }
      changed = true;
    }
    if (!changed) break;
    paths = _traceSkeleton(mask, width, height);
  }
  return paths;
}

_ProfiledPath _profilePath(
  List<_PixelPoint> path,
  Uint8List mask,
  Float32List distance,
  int width,
  int height,
  int originX,
  int originY,
  double averageWidth,
) {
  if (path.length == 1) return _ProfiledPath(path, <double>[averageWidth]);
  final List<_PixelPoint> smooth = _smoothCenterline(path, averageWidth);
  // Geometry simplification can reduce a straight pressure stroke to two
  // endpoints. Resample before measuring width so its thick middle survives.
  final List<_PixelPoint> samples = <_PixelPoint>[smooth.first];
  for (int i = 1; i < smooth.length; i++) {
    final _PixelPoint a = smooth[i - 1];
    final _PixelPoint b = smooth[i];
    final int steps = math.max(
      1,
      (math.sqrt(math.pow(b.x - a.x, 2) + math.pow(b.y - a.y, 2)) / 1.5).ceil(),
    );
    for (int j = 1; j <= steps; j++) {
      samples.add(
        _PixelPoint(
          a.x + (b.x - a.x) * j / steps,
          a.y + (b.y - a.y) * j / steps,
        ),
      );
    }
  }
  final bool closed =
      samples.first.x == samples.last.x && samples.first.y == samples.last.y;
  final int count = closed ? samples.length - 1 : samples.length;
  bool inside(double x, double y) {
    final int ix = (x - originX).round();
    final int iy = (y - originY).round();
    return ix >= 0 &&
        ix < width &&
        iy >= 0 &&
        iy < height &&
        mask[iy * width + ix] != 0;
  }

  final List<double> diameters = <double>[];
  for (int i = 0; i < count; i++) {
    final _PixelPoint at = samples[i];
    final _PixelPoint before =
        samples[closed ? (i - 2 + count) % count : math.max(0, i - 2)];
    final _PixelPoint after =
        samples[closed ? (i + 2) % count : math.min(count - 1, i + 2)];
    final double dx = after.x - before.x;
    final double dy = after.y - before.y;
    final double length = math.sqrt(dx * dx + dy * dy);
    if (length == 0 || !inside(at.x, at.y)) {
      diameters.add(1);
      continue;
    }
    double reach(int sign) {
      for (double r = 0.25; r <= 66; r += 0.25) {
        if (!inside(
          at.x - sign * dy / length * r,
          at.y + sign * dx / length * r,
        )) {
          return r;
        }
      }
      return 66;
    }

    // At a crossing, a normal ray can run along the other stroke. Bound it
    // by the local radius so an intersection cannot create a huge ink blob.
    final int pixel =
        (at.y - originY).round() * width + (at.x - originX).round();
    final double limit = math.max(1, (2 * distance[pixel] - 1) * 1.3);
    diameters.add(
      (reach(1) + reach(-1) - 0.25).clamp(1.0, math.min(132.0, limit)),
    );
  }
  return _ProfiledPath(
    samples,
    _smoothWidthProfile(samples, diameters, closed: closed),
  );
}

/// Removes isolated width spikes, then bounds thickness change by distance
/// along the trace. The limit is in bitmap pixels per bitmap pixel, so it
/// survives page scaling and doesn't depend on uneven sampling density.
List<double> _smoothWidthProfile(
  List<_PixelPoint> points,
  List<double> diameters, {
  required bool closed,
  double maxChangePerPixel = 0.35,
}) {
  final int count = diameters.length;
  if (count == 0) return <double>[];
  int index(int i) => closed ? i % count : i.clamp(0, count - 1);
  final List<double> median = <double>[];
  for (int i = 0; i < count; i++) {
    final List<double> window = <double>[
      for (int j = -2; j <= 2; j++) diameters[index(i + j)],
    ]..sort();
    median.add(window[2]);
  }
  final List<double> filtered = <double>[];
  for (int i = 0; i < count; i++) {
    double sum = 0;
    for (int j = -2; j <= 2; j++) {
      sum += median[index(i + j)] * (3 - j.abs());
    }
    filtered.add(sum / 9);
  }

  void limit(int at, int neighbor) {
    final double dx = points[at].x - points[neighbor].x;
    final double dy = points[at].y - points[neighbor].y;
    final double allowance = maxChangePerPixel * math.sqrt(dx * dx + dy * dy);
    filtered[at] = math.min(filtered[at], filtered[neighbor] + allowance);
  }

  // Both directions prevent a thick-to-thin jump as well as a thin-to-thick
  // one. Only reduce peaks: do not widen narrow tips to hide a discontinuity.
  // Two circuits propagate constraints across the arbitrary seam of a loop.
  for (int pass = 0; pass < (closed ? 2 : 1); pass++) {
    for (int i = closed ? 0 : 1; i < count; i++) {
      limit(i, index(i - 1));
    }
    for (int i = closed ? count - 1 : count - 2; i >= 0; i--) {
      limit(i, index(i + 1));
    }
  }
  if (closed) filtered.add(filtered.first);
  return filtered;
}

void _thin(Uint8List mask, int width, int height) {
  final List<int> remove = <int>[];
  bool changed = true;
  int iteration = 0;
  while (changed && iteration++ < 96) {
    changed = false;
    for (int pass = 0; pass < 2; pass++) {
      remove.clear();
      for (int y = 1; y < height - 1; y++) {
        for (int x = 1; x < width - 1; x++) {
          final int at = y * width + x;
          if (mask[at] == 0) continue;
          final int p2 = mask[at - width];
          final int p3 = mask[at - width + 1];
          final int p4 = mask[at + 1];
          final int p5 = mask[at + width + 1];
          final int p6 = mask[at + width];
          final int p7 = mask[at + width - 1];
          final int p8 = mask[at - 1];
          final int p9 = mask[at - width - 1];
          final int neighbors = p2 + p3 + p4 + p5 + p6 + p7 + p8 + p9;
          if (neighbors < 2 || neighbors > 6) continue;
          final List<int> ring = <int>[p2, p3, p4, p5, p6, p7, p8, p9, p2];
          int transitions = 0;
          for (int i = 0; i < 8; i++) {
            if (ring[i] == 0 && ring[i + 1] != 0) transitions++;
          }
          if (transitions != 1) continue;
          final bool keep = pass == 0
              ? p2 * p4 * p6 != 0 || p4 * p6 * p8 != 0
              : p2 * p4 * p8 != 0 || p2 * p6 * p8 != 0;
          if (!keep) remove.add(at);
        }
      }
      if (remove.isNotEmpty) {
        changed = true;
        for (final int at in remove) {
          mask[at] = 0;
        }
      }
    }
  }
}

List<List<int>> _traceSkeleton(Uint8List mask, int width, int height) {
  List<int> neighbors(int at) {
    final int x = at % width;
    final int y = at ~/ width;
    final List<int> result = <int>[];
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final int nx = x + dx;
        final int ny = y + dy;
        if (nx >= 0 && nx < width && ny >= 0 && ny < height) {
          final int next = ny * width + nx;
          if (mask[next] == 0) continue;
          // A diagonal beside an orthogonal connection is a redundant graph
          // edge, not a real fork in the centerline. Keeping it turns every
          // antialiased staircase into hundreds of two-pixel branches.
          if (dx != 0 && dy != 0) {
            final bool horizontal = mask[y * width + nx] != 0;
            final bool vertical = mask[ny * width + x] != 0;
            if (horizontal || vertical) continue;
          }
          result.add(next);
        }
      }
    }
    return result;
  }

  int edge(int a, int b) => a < b ? a * mask.length + b : b * mask.length + a;
  final Set<int> used = <int>{};
  final List<List<int>> paths = <List<int>>[];

  void walk(int start, int first) {
    final List<int> path = <int>[start];
    int previous = start;
    int current = first;
    used.add(edge(previous, current));
    path.add(current);
    while (true) {
      final List<int> next = neighbors(current);
      if (next.length != 2) break;
      final int candidate = next[0] == previous ? next[1] : next[0];
      final int key = edge(current, candidate);
      if (used.contains(key)) break;
      previous = current;
      current = candidate;
      used.add(key);
      path.add(current);
    }
    paths.add(path);
  }

  for (int at = 0; at < mask.length; at++) {
    if (mask[at] == 0) continue;
    final List<int> next = neighbors(at);
    if (next.length == 2) continue;
    for (final int neighbor in next) {
      if (!used.contains(edge(at, neighbor))) walk(at, neighbor);
    }
  }
  for (int at = 0; at < mask.length; at++) {
    if (mask[at] == 0) continue;
    for (final int neighbor in neighbors(at)) {
      if (!used.contains(edge(at, neighbor))) walk(at, neighbor);
    }
  }
  return paths;
}

List<_PixelPoint> _smoothCenterline(
  List<_PixelPoint> points,
  double widthPixels,
) {
  if (points.length < 3) return points;
  final bool closed =
      points.first.x == points.last.x && points.first.y == points.last.y;
  final int count = closed ? points.length - 1 : points.length;
  final int radius = (widthPixels * 0.6).round().clamp(2, 4);
  final List<_PixelPoint> filtered = <_PixelPoint>[];
  // Average the pixel staircase before simplification; otherwise a one-pixel
  // sideways step can become a false sharp corner between long segments.
  // Wrap closed loops, and keep open endpoints/junctions anchored.
  for (int i = 0; i < count; i++) {
    final int window = closed
        ? radius
        : math.min(radius, math.min(i, count - 1 - i));
    double x = 0;
    double y = 0;
    double total = 0;
    for (int offset = -window; offset <= window; offset++) {
      final _PixelPoint point = points[(i + offset + count) % count];
      final double weight = (window + 1 - offset.abs()).toDouble();
      x += point.x * weight;
      y += point.y * weight;
      total += weight;
    }
    filtered.add(_PixelPoint(x / total, y / total));
  }
  if (closed) filtered.add(filtered.first);
  // Work in bitmap units so page scaling doesn't change recovery quality.
  List<_PixelPoint> result = _simplify(filtered, 0.35);
  if (result.length < 3) return result;
  if (closed) result = result.sublist(0, result.length - 1);
  for (int pass = 0; pass < 2; pass++) {
    final List<_PixelPoint> rounded = <_PixelPoint>[];
    for (int i = 0; i < result.length; i++) {
      final _PixelPoint point = result[i];
      if (!closed && (i == 0 || i == result.length - 1)) {
        // Endpoints also anchor intersections shared by multiple strokes.
        rounded.add(point);
        continue;
      }
      final _PixelPoint before =
          result[(i - 1 + result.length) % result.length];
      final _PixelPoint after = result[(i + 1) % result.length];
      final double ax = point.x - before.x;
      final double ay = point.y - before.y;
      final double bx = after.x - point.x;
      final double by = after.y - point.y;
      final double lengths = math.sqrt(
        (ax * ax + ay * ay) * (bx * bx + by * by),
      );
      if (lengths == 0 ||
          ((ax * bx + ay * by) / lengths < 0.5 &&
              ax * ax + ay * ay >= 9 &&
              bx * bx + by * by >= 9)) {
        // Keep deliberate sharp corners (letters, arrows, diagrams).
        rounded.add(point);
      } else {
        // Limit corner cutting so long segments cannot shrink a large loop.
        final double incoming = math.min(
          0.25,
          1 / math.sqrt(ax * ax + ay * ay),
        );
        final double outgoing = math.min(
          0.25,
          1 / math.sqrt(bx * bx + by * by),
        );
        rounded
          ..add(_PixelPoint(point.x - ax * incoming, point.y - ay * incoming))
          ..add(_PixelPoint(point.x + bx * outgoing, point.y + by * outgoing));
      }
    }
    result = rounded;
  }
  if (closed) result.add(result.first);
  return result;
}

List<_PixelPoint> _simplify(List<_PixelPoint> points, double epsilon) {
  if (points.length <= 2) return points;
  final Uint8List keep = Uint8List(points.length)
    ..[0] = 1
    ..[points.length - 1] = 1;
  final List<(int, int)> stack = <(int, int)>[(0, points.length - 1)];
  while (stack.isNotEmpty) {
    final (int first, int last) = stack.removeLast();
    final _PixelPoint a = points[first];
    final _PixelPoint b = points[last];
    double greatest = 0;
    int index = -1;
    for (int i = first + 1; i < last; i++) {
      final double distance = _segmentDistance(points[i], a, b);
      if (distance > greatest) {
        greatest = distance;
        index = i;
      }
    }
    if (index >= 0 && greatest > epsilon) {
      keep[index] = 1;
      stack
        ..add((first, index))
        ..add((index, last));
    }
  }
  return <_PixelPoint>[
    for (int i = 0; i < points.length; i++)
      if (keep[i] != 0) points[i],
  ];
}

double _segmentDistance(_PixelPoint p, _PixelPoint a, _PixelPoint b) {
  final double dx = b.x - a.x;
  final double dy = b.y - a.y;
  if (dx == 0 && dy == 0) {
    return math.sqrt(math.pow(p.x - a.x, 2) + math.pow(p.y - a.y, 2));
  }
  final double t = (((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy))
      .clamp(0.0, 1.0);
  final double x = a.x + t * dx;
  final double y = a.y + t * dy;
  return math.sqrt(math.pow(p.x - x, 2) + math.pow(p.y - y, 2));
}

class _PdfImage {
  const _PdfImage({
    required this.object,
    required this.width,
    required this.height,
    required this.maskObject,
  });
  final _PdfObject object;
  final int width;
  final int height;
  final int maskObject;
}

class _PdfObject {
  const _PdfObject({
    required this.id,
    required this.dictionary,
    required this.stream,
  });
  final int id;
  final String dictionary;
  final Uint8List? stream;
}

class _NarrowPdf {
  _NarrowPdf._(
    this.text,
    this.objects,
    this.rawObjects,
    this.rootObject,
    this.infoObject,
  );

  factory _NarrowPdf.parse(Uint8List bytes) {
    final String text = latin1.decode(bytes, allowInvalid: true);
    final int marker = text.lastIndexOf('startxref');
    if (marker < 0) throw const FormatException('No PDF xref');
    final RegExpMatch? start = RegExp(
      r'startxref\s+(\d+)',
    ).firstMatch(text.substring(marker));
    if (start == null) throw const FormatException('Invalid PDF xref');
    final int xref = int.parse(start.group(1)!);
    if (xref < 0 || xref >= bytes.length || !text.startsWith('xref', xref)) {
      throw const FormatException('Unsupported PDF xref');
    }
    final int trailer = text.indexOf('trailer', xref);
    if (trailer < 0) throw const FormatException('Invalid PDF trailer');
    final String trailerDictionary = text.substring(trailer, marker);
    final int? rootObject = _reference(trailerDictionary, '/Root');
    if (rootObject == null) throw const FormatException('Missing PDF root');
    final int? infoObject = _reference(trailerDictionary, '/Info');
    final List<String> lines = text
        .substring(xref + 4, trailer)
        .trim()
        .split(RegExp(r'\r?\n'));
    final Map<int, int> offsets = <int, int>{};
    int line = 0;
    while (line < lines.length) {
      final RegExpMatch? header = RegExp(
        r'^\s*(\d+)\s+(\d+)\s*$',
      ).firstMatch(lines[line++]);
      if (header == null) throw const FormatException('Invalid xref section');
      final int first = int.parse(header.group(1)!);
      final int count = int.parse(header.group(2)!);
      for (int i = 0; i < count; i++) {
        if (line >= lines.length) throw const FormatException('Short xref');
        final RegExpMatch? entry = RegExp(
          r'^\s*(\d{10})\s+\d{5}\s+([nf])',
        ).firstMatch(lines[line++]);
        if (entry == null) throw const FormatException('Invalid xref entry');
        if (entry.group(2) == 'n') {
          offsets[first + i] = int.parse(entry.group(1)!);
        }
      }
    }
    final List<MapEntry<int, int>> ordered = offsets.entries.toList()
      ..sort(
        (MapEntry<int, int> a, MapEntry<int, int> b) =>
            a.value.compareTo(b.value),
      );
    final Map<int, _PdfObject> objects = <int, _PdfObject>{};
    final Map<int, Uint8List> rawObjects = <int, Uint8List>{};
    for (int i = 0; i < ordered.length; i++) {
      final int id = ordered[i].key;
      final int offset = ordered[i].value;
      if (id == 0 || offset <= 0 || offset >= xref) continue;
      final int end = i + 1 < ordered.length
          ? math.min(ordered[i + 1].value, xref)
          : xref;
      if (end <= offset || end > bytes.length) continue;
      final String objectText = text.substring(offset, end);
      if (!RegExp('^$id\\s+0\\s+obj').hasMatch(objectText)) continue;
      rawObjects[id] = Uint8List.sublistView(bytes, offset, end);
      final int dictStart = objectText.indexOf('<<');
      if (dictStart < 0) continue;
      final int streamKeyword = objectText.indexOf('stream', dictStart);
      final int dictLimit = streamKeyword < 0
          ? objectText.length
          : streamKeyword;
      final int dictEnd = objectText.lastIndexOf('>>', dictLimit);
      if (dictEnd < dictStart) continue;
      final String dictionary = objectText.substring(dictStart, dictEnd + 2);
      Uint8List? stream;
      if (streamKeyword >= 0) {
        final RegExpMatch? length = RegExp(
          r'/Length\s+(\d+)',
        ).firstMatch(dictionary);
        if (length == null) {
          throw const FormatException('Indirect stream length');
        }
        int dataStart = offset + streamKeyword + 6;
        if (bytes[dataStart] == 13) dataStart++;
        if (bytes[dataStart] == 10) dataStart++;
        final int dataLength = int.parse(length.group(1)!);
        if (dataLength < 0 || dataStart + dataLength > end) {
          throw const FormatException('Invalid stream length');
        }
        stream = Uint8List.sublistView(
          bytes,
          dataStart,
          dataStart + dataLength,
        );
      }
      objects[id] = _PdfObject(id: id, dictionary: dictionary, stream: stream);
    }
    return _NarrowPdf._(text, objects, rawObjects, rootObject, infoObject);
  }

  final String text;
  final Map<int, _PdfObject> objects;
  final Map<int, Uint8List> rawObjects;
  final int rootObject;
  final int? infoObject;

  List<_PdfObject> get pageObjects {
    final List<_PdfObject> pages = <_PdfObject>[
      for (final _PdfObject object in objects.values)
        if (RegExp(r'/Type\s*/Page(?!s)').hasMatch(object.dictionary)) object,
    ]..sort((_PdfObject a, _PdfObject b) => a.id.compareTo(b.id));
    return pages;
  }

  List<_PdfImage> imagesForPage(_PdfObject page) {
    final int? resources = _reference(page.dictionary, '/Resources');
    if (resources == null) throw const FormatException('Inline resources');
    final _PdfObject resource = objects[resources]!;
    final String? xobjects = _nestedDictionary(resource.dictionary, '/XObject');
    if (xobjects == null) return const <_PdfImage>[];
    return <_PdfImage>[
      for (final RegExpMatch match in RegExp(
        r'/[A-Za-z0-9_.]+\s+(\d+)\s+\d+\s+R',
      ).allMatches(xobjects))
        if (_tryImage(int.parse(match.group(1)!)) case final _PdfImage image)
          image,
    ];
  }

  _PdfImage image(int objectId) =>
      _tryImage(objectId) ?? (throw const FormatException('Missing image'));

  _PdfImage? _tryImage(int objectId) {
    final _PdfObject? object = objects[objectId];
    if (object == null ||
        !RegExp(r'/Subtype\s*/Image').hasMatch(object.dictionary) ||
        !RegExp(r'/ColorSpace\s*/DeviceRGB').hasMatch(object.dictionary) ||
        !RegExp(r'/BitsPerComponent\s+8').hasMatch(object.dictionary) ||
        !RegExp(r'/Filter\s*/FlateDecode').hasMatch(object.dictionary)) {
      return null;
    }
    final int? width = _integer(object.dictionary, '/Width');
    final int? height = _integer(object.dictionary, '/Height');
    final int? mask = _reference(object.dictionary, '/SMask');
    if (width == null ||
        height == null ||
        mask == null ||
        object.stream == null) {
      return null;
    }
    return _PdfImage(
      object: object,
      width: width,
      height: height,
      maskObject: mask,
    );
  }

  Uint8List decodeImage(_PdfImage image) =>
      _inflate(image.object, image.width * image.height * 3);

  Uint8List decodeMask(_PdfImage image) {
    final _PdfObject? mask = objects[image.maskObject];
    if (mask == null ||
        !RegExp(r'/Subtype\s*/Image').hasMatch(mask.dictionary) ||
        !RegExp(r'/ColorSpace\s*/DeviceGray').hasMatch(mask.dictionary) ||
        !RegExp(r'/BitsPerComponent\s+8').hasMatch(mask.dictionary) ||
        !RegExp(r'/Filter\s*/FlateDecode').hasMatch(mask.dictionary) ||
        _integer(mask.dictionary, '/Width') != image.width ||
        _integer(mask.dictionary, '/Height') != image.height) {
      throw const FormatException('Invalid image mask');
    }
    return _inflate(mask, image.width * image.height);
  }

  Uint8List _inflate(_PdfObject object, int expected) {
    if (expected <= 0 || expected > 64 << 20 || object.stream == null) {
      throw const FormatException('Unreasonable image');
    }
    final List<int> decoded = ZLibDecoder().convert(object.stream!);
    if (decoded.length != expected) {
      throw const FormatException('Unexpected decoded image size');
    }
    return Uint8List.fromList(decoded);
  }

  /// Rewrites decoded Flate streams and rebuilds a classic xref table. All
  /// other objects are copied byte-for-byte, retaining the vector template,
  /// fixed images and graphics state from the source PDF.
  Uint8List rewriteFlateStreams(Map<int, Uint8List> replacements) {
    if (replacements.isEmpty ||
        replacements.keys.any((int id) => !objects.containsKey(id))) {
      throw const FormatException('Invalid PDF stream replacement');
    }
    final int maxObject = rawObjects.keys.reduce(math.max);
    final List<int> offsets = List<int>.filled(maxObject + 1, 0);
    final BytesBuilder output = BytesBuilder();
    output.add(latin1.encode('%PDF-1.7\r\n%\u00a1\u00b3\u00c5\u00d7\r\n'));
    for (int id = 1; id <= maxObject; id++) {
      final Uint8List? raw = rawObjects[id];
      if (raw == null) continue;
      offsets[id] = output.length;
      final Uint8List? replacement = replacements[id];
      if (replacement == null) {
        output.add(raw);
        continue;
      }
      final _PdfObject object = objects[id]!;
      if (object.stream == null ||
          !RegExp(r'/Filter\s*/FlateDecode').hasMatch(object.dictionary)) {
        throw const FormatException('Unsupported replacement stream');
      }
      final Uint8List compressed = Uint8List.fromList(
        ZLibEncoder().convert(replacement),
      );
      final String dictionary = object.dictionary.replaceFirst(
        RegExp(r'/Length\s+\d+'),
        '/Length ${compressed.length}',
      );
      output
        ..add(latin1.encode('$id 0 obj\r\n$dictionary\r\nstream\r\n'))
        ..add(compressed)
        ..add(latin1.encode('\r\nendstream\r\nendobj\r\n'));
    }
    final int xref = output.length;
    output
      ..add(latin1.encode('xref\r\n0 ${maxObject + 1}\r\n'))
      ..add(latin1.encode('0000000000 65535 f\r\n'));
    for (int id = 1; id <= maxObject; id++) {
      final int offset = offsets[id];
      output.add(
        latin1.encode(
          offset == 0
              ? '0000000000 00000 f\r\n'
              : '${offset.toString().padLeft(10, '0')} 00000 n\r\n',
        ),
      );
    }
    output.add(
      latin1.encode(
        'trailer\r\n<</Root $rootObject 0 R'
        '${infoObject == null ? '' : '/Info $infoObject 0 R'}'
        '/Size ${maxObject + 1}>>\r\nstartxref\r\n$xref\r\n%%EOF\r\n',
      ),
    );
    return output.toBytes();
  }
}

int? _integer(String dictionary, String key) {
  final RegExpMatch? match = RegExp(
    '${RegExp.escape(key)}\\s+(\\d+)',
  ).firstMatch(dictionary);
  return match == null ? null : int.parse(match.group(1)!);
}

int? _reference(String dictionary, String key) {
  final RegExpMatch? match = RegExp(
    '${RegExp.escape(key)}\\s+(\\d+)\\s+\\d+\\s+R',
  ).firstMatch(dictionary);
  return match == null ? null : int.parse(match.group(1)!);
}

List<double>? _numbers(String dictionary, String key, int count) {
  final int keyAt = dictionary.indexOf(key);
  if (keyAt < 0) return null;
  final int start = dictionary.indexOf('[', keyAt + key.length);
  final int end = start < 0 ? -1 : dictionary.indexOf(']', start + 1);
  if (start < 0 || end < 0) return null;
  final List<double> values = RegExp(r'-?(?:\d+\.?\d*|\.\d+)')
      .allMatches(dictionary.substring(start + 1, end))
      .map((RegExpMatch value) => double.parse(value.group(0)!))
      .toList();
  return values.length == count ? values : null;
}

String? _nestedDictionary(String dictionary, String key) {
  final int keyAt = dictionary.indexOf(key);
  if (keyAt < 0) return null;
  final int start = dictionary.indexOf('<<', keyAt + key.length);
  if (start < 0) return null;
  int depth = 0;
  for (int i = start; i + 1 < dictionary.length; i++) {
    final String pair = dictionary.substring(i, i + 2);
    if (pair == '<<') {
      depth++;
      i++;
    } else if (pair == '>>') {
      depth--;
      if (depth == 0) return dictionary.substring(start, i + 2);
      i++;
    }
  }
  return null;
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

@visibleForTesting
List<double> smoothRecoveredWidthsForTest({
  required List<InkVector> points,
  required List<double> diameters,
  bool closed = false,
}) => _smoothWidthProfile(
  <_PixelPoint>[
    for (final InkVector point in points) _PixelPoint(point.x, point.y),
  ],
  diameters,
  closed: closed,
);

@visibleForTesting
List<Stroke> traceGoodnotesOverlayForTest({
  required Uint8List rgb,
  required Uint8List alpha,
  required int width,
  required int height,
  required Size pageSize,
}) {
  final _AnalyzedOverlay analyzed = _analyzeOverlay(
    rgb,
    alpha,
    width,
    height,
    pageSize,
  );
  return <Stroke>[
    for (final _RawStroke stroke in analyzed.strokes)
      Stroke.fromPoints(
        style: StrokeStyle(
          ink: InkPalette.imported(Color(stroke.argb)),
          width: stroke.width,
        ),
        points: <InkVector>[
          for (int i = 0; i < stroke.points.length; i += 2)
            InkVector(stroke.points[i], stroke.points[i + 1]),
        ],
        widths: stroke.widths,
      ),
  ];
}

@visibleForTesting
int probeGoodnotesPdfForTest({
  required Uint8List bytes,
  required List<Size> pageSizes,
  int maxDimension = 4096,
}) => _probeGoodnotesPdf(bytes, pageSizes, maxDimension).pages.length;

@visibleForTesting
List<Size> probeGoodnotesImageSizesForTest({
  required Uint8List bytes,
  required List<Size> pageSizes,
  int maxDimension = 4096,
}) => <Size>[
  for (final _OverlayGeometry page in _probeGoodnotesPdf(
    bytes,
    pageSizes,
    maxDimension,
  ).pages)
    Size(page.width.toDouble(), page.height.toDouble()),
];

@visibleForTesting
List<int> recoverGoodnotesPdfForTest({
  required Uint8List bytes,
  required List<Size> pageSizes,
}) {
  final _GoodnotesProbe probe = _probeGoodnotesPdf(bytes, pageSizes, 4096);
  final _RawRecovery? recovery = _recoverGoodnotesPdf(bytes, pageSizes, probe);
  if (recovery == null) throw const FormatException('No recovered strokes');
  return <int>[for (final List<_RawStroke> page in recovery.pages) page.length];
}
