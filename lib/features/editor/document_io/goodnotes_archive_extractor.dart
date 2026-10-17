import 'dart:convert';
import 'dart:io' show ZLibDecoder;
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../ink/ink_palette.dart';
import '../ink/ink_sample.dart';
import '../ink/stroke.dart';
import '../page/page_setup.dart';
import 'document_importer.dart';
import 'document_io_config.dart';

/// The pages, paper, and editable ink of a native `.goodnotes` notebook.
@immutable
class GoodnotesArchiveExtraction {
  const GoodnotesArchiveExtraction({
    required this.title,
    required this.pdfAttachments,
    required this.pageSizes,
    required this.pdfAttachmentIndices,
    required this.pdfPageIndices,
    required this.pageStrokes,
  });

  /// The notebook's own title, or else the file's name.
  final String title;

  /// Every PDF the pages are printed on, each once.
  final List<Uint8List> pdfAttachments;

  /// In page units.
  final List<Size> pageSizes;

  /// For each page, which of [pdfAttachments] it is printed on, or null for
  /// a page of plain paper.
  final List<int?> pdfAttachmentIndices;

  /// For each page, the 0-based page of its PDF, or null.
  final List<int?> pdfPageIndices;

  final List<List<Stroke>> pageStrokes;

  /// The PDF behind a notebook printed on a single one, as most are.
  Uint8List? get pdfBytes =>
      pdfAttachments.isEmpty ? null : pdfAttachments.first;

  int get pageCount => pageSizes.length;
}

/// Reads native `.goodnotes` notebooks: a ZIP of protobuf streams, with
/// each stroke stored as LZ4-compressed (`bv41`) `tpl` curve data.
///
/// Everything is pure Dart, so it runs in a background isolate and in
/// tests alike. Anything malformed is reported as a
/// [DocumentImportException].
class GoodnotesArchiveExtractor {
  const GoodnotesArchiveExtractor();

  /// Goodnotes page units per Greatnote page unit when nothing better is
  /// known: a 1760 × 990 Goodnotes page holds a 960 × 540 pt PDF slide,
  /// which is 1280 × 720 page units.
  static const double defaultPageScale = 1280 / 1760;

  /// Whether [bytes] are a `.goodnotes` notebook rather than, say, a PDF.
  /// Only the ZIP directory is read.
  static bool isGoodnotesArchive(Uint8List bytes) {
    if (bytes.length < 4 ||
        bytes[0] != 0x50 ||
        bytes[1] != 0x4B ||
        bytes[2] != 0x03 ||
        bytes[3] != 0x04) {
      return false;
    }
    try {
      final Set<String> names = _ZipArchive(bytes).entries.keys.toSet();
      return names.contains('index.notes.pb') || names.contains('schema.pb');
    } on Object {
      return false;
    }
  }

  /// Extracts [bytes] off the UI isolate.
  ///
  /// [pdfPageSizes], when given, reports the size in page units of each
  /// page of an embedded PDF, so PDF-backed pages take exactly their PDF
  /// page's size; it may throw to reject the PDF. Without it, or for a
  /// page of plain paper, pages are sized by [defaultPageScale].
  Future<GoodnotesArchiveExtraction> extract(
    Uint8List bytes, {
    String? fileName,
    DocumentIoConfig config = const DocumentIoConfig(),
    Future<List<Size>> Function(Uint8List pdf)? pdfPageSizes,
    bool Function()? isCancelled,
  }) async {
    if (bytes.lengthInBytes > config.maxImportGoodnotesBytes) {
      throw DocumentImportException(
        'This Goodnotes file is larger than '
        '${(config.maxImportGoodnotesBytes / (1024 * 1024)).ceil()} MB',
      );
    }
    final int maxExpandedBytes = config.maxGoodnotesExpandedBytes;
    final int maxAttachmentBytes = config.maxImportPdfBytes;
    final int maxPages = config.maxImportPdfPages;
    final GoodnotesRawArchive raw;
    try {
      raw = await Isolate.run(
        () => decodeGoodnotesArchive(
          bytes,
          maxExpandedBytes: maxExpandedBytes,
          maxAttachmentBytes: maxAttachmentBytes,
          maxPages: maxPages,
        ),
      );
    } on DocumentImportException {
      rethrow;
    } on Object {
      throw const DocumentImportException(
        'This Goodnotes file could not be opened',
      );
    }
    _throwIfCancelled(isCancelled);

    final List<List<Size>?> attachmentPages = <List<Size>?>[
      for (final Uint8List pdf in raw.attachments)
        pdfPageSizes == null ? null : await pdfPageSizes(pdf),
    ];
    _throwIfCancelled(isCancelled);

    final List<Size> sizes = <Size>[];
    final List<int?> attachments = <int?>[];
    final List<int?> pdfPages = <int?>[];
    final List<List<Stroke>> strokes = <List<Stroke>>[];
    for (final GoodnotesRawPage page in raw.pages) {
      int? attachment = page.attachment;
      int? pdfPage = page.pdfPageIndex;
      Size size = page.size * defaultPageScale;
      if (attachment != null && pdfPage != null) {
        final List<Size>? known = attachmentPages[attachment];
        if (known != null) {
          if (pdfPage < known.length) {
            size = known[pdfPage];
          } else {
            // The PDF has no such page: keep the page as plain paper.
            attachment = null;
            pdfPage = null;
          }
        }
      } else {
        attachment = null;
        pdfPage = null;
      }
      sizes.add(size);
      attachments.add(attachment);
      pdfPages.add(pdfPage);
      strokes.add(
        buildGoodnotesStrokes(
          page.strokes,
          scaleX: size.width / page.size.width,
          scaleY: size.height / page.size.height,
        ),
      );
    }
    return GoodnotesArchiveExtraction(
      title:
          _cleanTitle(raw.title) ??
          _cleanTitle(
            (fileName ?? '').replaceFirst(
              RegExp(r'\.goodnotes$', caseSensitive: false),
              '',
            ),
          ) ??
          'Imported Goodnotes',
      pdfAttachments: List<Uint8List>.unmodifiable(raw.attachments),
      pageSizes: List<Size>.unmodifiable(sizes),
      pdfAttachmentIndices: List<int?>.unmodifiable(attachments),
      pdfPageIndices: List<int?>.unmodifiable(pdfPages),
      pageStrokes: List<List<Stroke>>.unmodifiable(strokes),
    );
  }

  static void _throwIfCancelled(bool Function()? isCancelled) {
    if (isCancelled?.call() ?? false) {
      throw const DocumentImportException('Import cancelled');
    }
  }

  static String? _cleanTitle(String? title) {
    final String? trimmed = title?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}

/// Strokes in page units from [raw] ones in Goodnotes units. Widths scale
/// by the mean of [scaleX] and [scaleY].
@visibleForTesting
List<Stroke> buildGoodnotesStrokes(
  List<GoodnotesRawStroke> raw, {
  required double scaleX,
  required double scaleY,
}) {
  final double scale = (scaleX + scaleY) / 2;
  final List<Stroke> strokes = <Stroke>[];
  for (final GoodnotesRawStroke stroke in raw) {
    final List<InkVector> points = <InkVector>[
      for (int i = 0; i < stroke.xy.length; i += 2)
        InkVector(stroke.xy[i] * scaleX, stroke.xy[i + 1] * scaleY),
    ];
    if (points.isEmpty) {
      continue;
    }
    final Color color = Color(stroke.argb);
    final Float64List? radii = stroke.radii;
    if (stroke.highlighter) {
      strokes.add(
        Stroke.fromPoints(
          style: StrokeStyle(
            ink: InkPalette.imported(color.withValues(alpha: 1)),
            width: math.max(stroke.width * scale, _minimumWidth),
            writing: WritingStyle.highlighter,
            opacity: color.a.clamp(0.05, 1.0),
          ),
          points: points,
        ),
      );
      continue;
    }
    if (radii == null) {
      strokes.add(
        Stroke.fromPoints(
          style: StrokeStyle(
            ink: InkPalette.imported(color),
            width: math.max(stroke.width * scale, _minimumWidth),
          ),
          points: points,
        ),
      );
      continue;
    }
    final List<double> diameters = <double>[
      for (final double radius in radii)
        math.max(2 * radius * scale, _minimumWidth),
    ];
    final List<double> sorted = List<double>.of(diameters)..sort();
    final double width = sorted[sorted.length ~/ 2];
    strokes.add(
      Stroke.fromPoints(
        style: StrokeStyle(ink: InkPalette.imported(color), width: width),
        points: points,
        widths: <double>[for (final double d in diameters) d / width],
      ),
    );
  }
  return strokes;
}

/// The thinnest line kept, in page units, so a stroke never vanishes.
const double _minimumWidth = 0.05;

// ---------------------------------------------------------------------------
// Isolate-side decoding. Everything below works on plain data, so the
// result can be sent back from a background isolate.
// ---------------------------------------------------------------------------

/// A decoded notebook, still in Goodnotes units.
@immutable
@visibleForTesting
class GoodnotesRawArchive {
  const GoodnotesRawArchive({
    required this.title,
    required this.attachments,
    required this.pages,
  });

  final String? title;
  final List<Uint8List> attachments;
  final List<GoodnotesRawPage> pages;
}

@immutable
@visibleForTesting
class GoodnotesRawPage {
  const GoodnotesRawPage({
    required this.size,
    required this.attachment,
    required this.pdfPageIndex,
    required this.strokes,
  });

  /// In Goodnotes units.
  final Size size;
  final int? attachment;
  final int? pdfPageIndex;
  final List<GoodnotesRawStroke> strokes;
}

/// A stroke's centerline, sampled from its curves, in Goodnotes units.
@immutable
@visibleForTesting
class GoodnotesRawStroke {
  const GoodnotesRawStroke({
    required this.argb,
    required this.highlighter,
    required this.xy,
    required this.width,
    this.radii,
  });

  final int argb;
  final bool highlighter;

  /// x, y pairs.
  final Float64List xy;

  /// The full width of an even stroke.
  final double width;

  /// The half-width at each point of a stroke of varying width.
  final Float64List? radii;
}

/// Decodes a whole notebook. Throws [DocumentImportException] when it is
/// too large and [FormatException] when it is malformed.
/// [maxExpandedBytes] bounds all inflated and decompressed bytes together.
@visibleForTesting
GoodnotesRawArchive decodeGoodnotesArchive(
  Uint8List bytes, {
  int maxExpandedBytes = 512 << 20,
  int maxAttachmentBytes = 200 << 20,
  int maxPages = 500,
}) {
  final _ZipArchive zip = _ZipArchive(bytes);
  final _Budget budget = _Budget(maxExpandedBytes);
  Uint8List read(String name) => zip.read(name, budget);

  if (!zip.entries.containsKey('index.notes.pb')) {
    throw const FormatException('Not a Goodnotes notebook');
  }

  // Where each attachment is stored.
  final Map<String, String> attachmentPaths = <String, String>{};
  if (zip.entries.containsKey('index.attachments.pb')) {
    for (final Uint8List message in _delimited(read('index.attachments.pb'))) {
      final _Message entry = _Message.parse(message);
      final String? id = entry.string(1);
      final String? path = entry.string(2);
      if (id != null && path != null) {
        attachmentPaths[id] = path;
      }
    }
  }

  // The page streams, in index order.
  final List<String> streamIds = <String>[];
  final Map<String, String> streamPaths = <String, String>{};
  for (final Uint8List message in _delimited(read('index.notes.pb'))) {
    final _Message entry = _Message.parse(message);
    final String? id = entry.string(1);
    final String? path = entry.string(2);
    if (id != null && path != null) {
      streamIds.add(id);
      streamPaths[id.toUpperCase()] = path;
    }
  }

  // The document's events: its title, page templates, and pages.
  String? title;
  final Map<String, _Template> templates = <String, _Template>{};
  final Map<String, _PageEvent> pageEvents = <String, _PageEvent>{};
  if (zip.entries.containsKey('index.events.pb')) {
    int order = 0;
    for (final Uint8List message in _delimited(read('index.events.pb'))) {
      final _Message event = _Message.parse(message);
      final _Message? document = event.message(30);
      final String? named = document?.message(2)?.string(1);
      if (named != null && named.trim().isNotEmpty) {
        title = named;
      }
      final _Message? template = event.message(2);
      final String? templateId = template?.string(2);
      if (template != null && templateId != null) {
        final _Message? size = template.message(8);
        final _Template known = templates[templateId] ?? _Template();
        known
          ..attachmentId = template.string(4) ?? known.attachmentId
          ..pdfPage = template.varint(5) ?? known.pdfPage
          ..width = size?.float(1) ?? known.width
          ..height = size?.float(2) ?? known.height;
        templates[templateId] = known;
      }
      final _Message? page = event.message(54);
      final String? pageId = page?.string(2);
      if (page != null && pageId != null) {
        final _PageEvent known =
            pageEvents[pageId] ?? (_PageEvent(pageId, order++));
        known
          ..templateId = page.message(3)?.string(1) ?? known.templateId
          ..sortCode = page.message(4)?.string(1) ?? known.sortCode;
        pageEvents[pageId] = known;
      }
    }
  }

  // Pages in document order, each matched to its stroke stream: a stream
  // is named for its page's ID plus one, as a 128-bit number.
  final List<_PageEvent> ordered = pageEvents.values.toList()
    ..sort((_PageEvent a, _PageEvent b) {
      final int byCode = (a.sortCode ?? '').compareTo(b.sortCode ?? '');
      return byCode != 0 ? byCode : a.order.compareTo(b.order);
    });
  final List<({String? stream, _Template? template})> pages =
      <({String? stream, _Template? template})>[];
  if (ordered.isEmpty) {
    for (final String id in streamIds) {
      pages.add((stream: id, template: null));
    }
  } else {
    final bool sameCount = ordered.length == streamIds.length;
    for (int i = 0; i < ordered.length; i++) {
      final String? next = _nextUuid(ordered[i].pageId);
      final String? stream = next != null && streamPaths.containsKey(next)
          ? next
          : streamPaths.containsKey(ordered[i].pageId.toUpperCase())
          ? ordered[i].pageId
          : sameCount
          ? streamIds[i]
          : null;
      pages.add((stream: stream, template: templates[ordered[i].templateId]));
    }
  }
  if (pages.isEmpty) {
    throw const FormatException('A notebook without pages');
  }
  if (pages.length > maxPages) {
    throw DocumentImportException(
      'This Goodnotes file has more than $maxPages pages',
    );
  }

  // Each PDF attachment, read once.
  final List<Uint8List> attachments = <Uint8List>[];
  final Map<String, int?> attachmentIndices = <String, int?>{};
  int? attachmentIndex(String? id) {
    if (id == null) {
      return null;
    }
    return attachmentIndices.putIfAbsent(id, () {
      final String? path = attachmentPaths[id];
      final _ZipEntry? entry = path == null ? null : zip.entries[path];
      if (entry == null) {
        return null;
      }
      if (entry.size > maxAttachmentBytes) {
        throw DocumentImportException(
          'The PDF in this Goodnotes file is larger than '
          '${(maxAttachmentBytes / (1024 * 1024)).ceil()} MB',
        );
      }
      final Uint8List data = read(path!);
      if (!_startsWith(data, _pdfMagic)) {
        // Only PDF paper is supported; other attachments are left out.
        return null;
      }
      attachments.add(data);
      return attachments.length - 1;
    });
  }

  // Sizes default to the first page that declares one.
  Size? declared;
  for (final ({String? stream, _Template? template}) page in pages) {
    final _Template? template = page.template;
    if (template != null && template.hasSize) {
      declared = Size(template.width!, template.height!);
      break;
    }
  }
  final Size fallbackSize =
      declared ??
      PageSize.a4Portrait.fixedSize! /
          GoodnotesArchiveExtractor.defaultPageScale;

  final List<GoodnotesRawPage> rawPages = <GoodnotesRawPage>[];
  for (final ({String? stream, _Template? template}) page in pages) {
    final _Template? template = page.template;
    final Size size = template != null && template.hasSize
        ? Size(template.width!, template.height!)
        : fallbackSize;
    final int? attachment = attachmentIndex(template?.attachmentId);
    final int? pdfPage = template?.pdfPage;
    final String? path = page.stream == null
        ? null
        : streamPaths[page.stream!.toUpperCase()];
    final Uint8List stream = path != null && zip.entries.containsKey(path)
        ? read(path)
        : Uint8List(0);
    rawPages.add(
      GoodnotesRawPage(
        size: size,
        attachment: attachment,
        pdfPageIndex: attachment != null && pdfPage != null && pdfPage >= 1
            ? pdfPage - 1
            : null,
        strokes: _decodeStrokeStream(stream, budget),
      ),
    );
  }
  return GoodnotesRawArchive(
    title: title,
    attachments: attachments,
    pages: rawPages,
  );
}

class _Template {
  String? attachmentId;
  int? pdfPage;
  double? width;
  double? height;

  bool get hasSize =>
      width != null &&
      height != null &&
      width!.isFinite &&
      height!.isFinite &&
      width! > 0 &&
      height! > 0;
}

class _PageEvent {
  _PageEvent(this.pageId, this.order);
  final String pageId;
  final int order;
  String? templateId;
  String? sortCode;
}

/// [uuid] plus one, upper case, or null when it is not a UUID.
String? _nextUuid(String uuid) {
  final String hex = uuid.replaceAll('-', '');
  if (hex.length != 32 || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) {
    return null;
  }
  final BigInt next =
      (BigInt.parse(hex, radix: 16) + BigInt.one) &
      ((BigInt.one << 128) - BigInt.one);
  final String out = next.toRadixString(16).padLeft(32, '0').toUpperCase();
  return '${out.substring(0, 8)}-${out.substring(8, 12)}-'
      '${out.substring(12, 16)}-${out.substring(16, 20)}-${out.substring(20)}';
}

const List<int> _pdfMagic = <int>[0x25, 0x50, 0x44, 0x46]; // %PDF

bool _startsWith(Uint8List data, List<int> prefix) {
  if (data.length < prefix.length) {
    return false;
  }
  for (int i = 0; i < prefix.length; i++) {
    if (data[i] != prefix[i]) {
      return false;
    }
  }
  return true;
}

/// Counts every byte expanded from the archive, so a small file cannot
/// unpack into an unbounded amount of memory.
class _Budget {
  _Budget(this._remaining);
  int _remaining;

  int get remaining => _remaining;

  void take(int bytes) {
    if (bytes < 0 || bytes > _remaining) {
      throw const DocumentImportException(
        'This Goodnotes file is too large to import',
      );
    }
    _remaining -= bytes;
  }
}

// ---------------------------------------------------------------------------
// Stroke streams.
// ---------------------------------------------------------------------------

/// The live strokes of one page's stream (`notes/<UUID>`): a sequence of
/// length-delimited records, of which each stroke's last one counts.
/// Erased strokes leave a record marked deleted with no geometry.
@visibleForTesting
List<GoodnotesRawStroke> decodeGoodnotesStrokeStream(
  Uint8List stream, {
  int maxExpandedBytes = 512 << 20,
}) => _decodeStrokeStream(stream, _Budget(maxExpandedBytes));

List<GoodnotesRawStroke> _decodeStrokeStream(Uint8List stream, _Budget budget) {
  final Map<String, _Message> latest = <String, _Message>{};
  for (final Uint8List record in _delimited(stream)) {
    final _Message message = _Message.parse(record);
    final _Message? payload = message.message(7);
    if (payload == null) {
      continue;
    }
    final String id =
        payload.string(1) ?? message.string(1) ?? 'stroke-${latest.length}';
    // Re-inserted so the stroke takes its latest place in drawing order.
    latest.remove(id);
    latest[id] = payload;
  }
  final List<GoodnotesRawStroke> strokes = <GoodnotesRawStroke>[];
  for (final _Message payload in latest.values) {
    if ((payload.varint(14) ?? 0) != 0) {
      continue;
    }
    final GoodnotesRawStroke? stroke = _decodeStroke(payload, budget);
    if (stroke != null) {
      strokes.add(stroke);
    }
  }
  return strokes;
}

const String _penFormat = 'vA(v)A(u)A(u)A(v)A(v)A(u)A(u)A(u)A(u)A(v)';
const String _curveFormat = 'vuA(v)A(S(uu))A(S(uuuu))vA(f)';

GoodnotesRawStroke? _decodeStroke(_Message payload, _Budget budget) {
  final _Message? rgba = payload.message(4);
  final double r = rgba?.float(1) ?? 0;
  final double g = rgba?.float(2) ?? 0;
  final double b = rgba?.float(3) ?? 0;
  final double a = rgba?.float(4) ?? 1;
  final int argb = _argb(r, g, b, a);
  final bool highlighterFlag = (payload.varint(5) ?? 0) == 1;

  final Uint8List? packed = payload.bytes(2);
  final GoodnotesTpl? tpl = packed == null || packed.isEmpty
      ? null
      : parseGoodnotesTpl(_decompressBv4(packed, budget));
  final bool highlighter =
      highlighterFlag || a < 0.95 || tpl?.format == _curveFormat;

  final _Message? snapped = payload.message(9);
  GoodnotesRawStroke? fromSnapped(double fallbackWidth) {
    // `{1: {1: point, 1: point, ...}}`, or the points directly.
    List<_Message> points = snapped?.messages(1) ?? const <_Message>[];
    if (points.length == 1 && points.single.float(1) == null) {
      points = points.single.messages(1);
    }
    if (points.isEmpty) {
      return null;
    }
    final Float64List xy = Float64List.fromList(<double>[
      for (final _Message point in points)
        if (point.float(1) != null && point.float(2) != null) ...<double>[
          point.float(1)!,
          point.float(2)!,
        ],
    ]);
    return _finite(
      GoodnotesRawStroke(
        argb: argb,
        highlighter: highlighter,
        xy: xy,
        width: snapped?.float(15) ?? fallbackWidth,
      ),
    );
  }

  if (tpl == null) {
    return fromSnapped(1);
  }
  if (tpl.format == _penFormat) {
    final List<int> commands = tpl.ints(1);
    final List<double> start = tpl.doubles(2);
    final List<double> segments = tpl.doubles(3);
    if (commands.isEmpty || start.length < 4) {
      return fromSnapped(2);
    }
    final _Polyline line = _Polyline()..add(start[0], start[1], start[2]);
    // Each segment is a quadratic curve from the last point:
    // [controlX, controlY, controlRadius, endX, endY, endRadius, ...].
    for (int i = 0; i + 9 <= segments.length; i += 9) {
      line.quadratic(
        segments[i],
        segments[i + 1],
        segments[i + 2],
        segments[i + 3],
        segments[i + 4],
        segments[i + 5],
      );
    }
    final Float64List radii = line.radii();
    return _finite(
      GoodnotesRawStroke(
        argb: argb,
        highlighter: highlighter,
        xy: line.xy(),
        width: 2 * radii.fold<double>(0, math.max),
        radii: highlighter ? null : radii,
      ),
    );
  }
  if (tpl.format == _curveFormat) {
    final double width = tpl.number(1);
    final List<List<double>> start = tpl.structs(3);
    final List<List<double>> segments = tpl.structs(4);
    if (start.isEmpty) {
      return fromSnapped(width);
    }
    final _Polyline line = _Polyline()..add(start[0][0], start[0][1], 0);
    for (final List<double> segment in segments) {
      line.quadratic(segment[0], segment[1], 0, segment[2], segment[3], 0);
    }
    return _finite(
      GoodnotesRawStroke(
        argb: argb,
        highlighter: highlighter,
        xy: line.xy(),
        width: width,
      ),
    );
  }
  // An ink kind this reader does not know: left out rather than guessed.
  return fromSnapped(1);
}

int _argb(double r, double g, double b, double a) {
  int channel(double value) =>
      ((value.isFinite ? value : 0).clamp(0.0, 1.0) * 255).round();
  return channel(a) << 24 | channel(r) << 16 | channel(g) << 8 | channel(b);
}

GoodnotesRawStroke? _finite(GoodnotesRawStroke stroke) {
  if (stroke.xy.isEmpty ||
      stroke.xy.any((double v) => !v.isFinite) ||
      !stroke.width.isFinite ||
      (stroke.radii?.any((double v) => !v.isFinite) ?? false)) {
    return null;
  }
  return stroke;
}

/// A centerline built from quadratic curves, with a radius at each point.
class _Polyline {
  final List<double> _xy = <double>[];
  final List<double> _radii = <double>[];

  /// Points closer than this, in Goodnotes units, are merged.
  static const double _minimumStep = 1e-3;

  /// Curves are sampled about this often, in Goodnotes units.
  static const double _sampleSpacing = 2.5;
  static const int _maxSamples = 16;

  void add(double x, double y, double radius) {
    if (_xy.isNotEmpty) {
      final double dx = x - _xy[_xy.length - 2];
      final double dy = y - _xy[_xy.length - 1];
      if (dx * dx + dy * dy < _minimumStep * _minimumStep) {
        _radii[_radii.length - 1] = radius;
        return;
      }
    }
    _xy
      ..add(x)
      ..add(y);
    _radii.add(radius);
  }

  void quadratic(
    double cx,
    double cy,
    double cr,
    double x,
    double y,
    double r,
  ) {
    final double x0 = _xy[_xy.length - 2];
    final double y0 = _xy[_xy.length - 1];
    final double r0 = _radii.last;
    final double length =
        math.sqrt((cx - x0) * (cx - x0) + (cy - y0) * (cy - y0)) +
        math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy));
    final int samples = (length / _sampleSpacing).ceil().clamp(1, _maxSamples);
    for (int i = 1; i <= samples; i++) {
      final double t = i / samples;
      final double u = 1 - t;
      final double w0 = u * u;
      final double w1 = 2 * u * t;
      final double w2 = t * t;
      add(
        w0 * x0 + w1 * cx + w2 * x,
        w0 * y0 + w1 * cy + w2 * y,
        math.max(0, w0 * r0 + w1 * cr + w2 * r),
      );
    }
  }

  Float64List xy() => Float64List.fromList(_xy);
  Float64List radii() => Float64List.fromList(_radii);
}

// ---------------------------------------------------------------------------
// bv4 (LZ4) streams.
// ---------------------------------------------------------------------------

/// Decompresses a `bv4` stream: `bv41` LZ4 blocks and `bv4-` stored
/// blocks, ended by `bv4$`. A block may copy from earlier blocks.
@visibleForTesting
Uint8List decompressGoodnotesBv4(Uint8List data, {int maxBytes = 256 << 20}) =>
    _decompressBv4(data, _Budget(maxBytes));

Uint8List _decompressBv4(Uint8List data, _Budget budget) {
  final ByteData view = ByteData.sublistView(data);
  // First pass: sizes, so the output is allocated once.
  int total = 0;
  int offset = 0;
  while (true) {
    final int magic = _bv4Magic(data, offset);
    if (magic == 0x24) {
      break;
    }
    if (magic == 0x31) {
      _need(data, offset, 12);
      final int size = view.getUint32(offset + 4, Endian.little);
      final int compressed = view.getUint32(offset + 8, Endian.little);
      _need(data, offset + 12, compressed);
      total += size;
      offset += 12 + compressed;
    } else {
      _need(data, offset, 8);
      final int size = view.getUint32(offset + 4, Endian.little);
      _need(data, offset + 8, size);
      total += size;
      offset += 8 + size;
    }
    if (total > budget.remaining) {
      break; // Too large; refused just below.
    }
  }
  budget.take(total);
  final Uint8List out = Uint8List(total);
  int written = 0;
  offset = 0;
  while (true) {
    final int magic = _bv4Magic(data, offset);
    if (magic == 0x24) {
      break;
    }
    if (magic == 0x31) {
      final int size = view.getUint32(offset + 4, Endian.little);
      final int compressed = view.getUint32(offset + 8, Endian.little);
      final int end = _lz4Block(
        data,
        offset + 12,
        offset + 12 + compressed,
        out,
        written,
        written + size,
      );
      if (end != written + size) {
        throw const FormatException('An LZ4 block of the wrong size');
      }
      written = end;
      offset += 12 + compressed;
    } else {
      final int size = view.getUint32(offset + 4, Endian.little);
      out.setRange(written, written + size, data, offset + 8);
      written += size;
      offset += 8 + size;
    }
  }
  return out;
}

/// The fourth byte of the block magic at [offset]: `1`, `-`, or `$`.
int _bv4Magic(Uint8List data, int offset) {
  _need(data, offset, 4);
  if (data[offset] != 0x62 ||
      data[offset + 1] != 0x76 ||
      data[offset + 2] != 0x34) {
    throw const FormatException('Not a bv4 block');
  }
  final int kind = data[offset + 3];
  if (kind != 0x31 && kind != 0x2D && kind != 0x24) {
    throw const FormatException('An unknown bv4 block');
  }
  return kind;
}

void _need(Uint8List data, int offset, int length) {
  if (offset < 0 || length < 0 || offset + length > data.length) {
    throw const FormatException('Truncated data');
  }
}

/// Decodes one raw LZ4 block from `src[start, end)` into `out` from
/// [position] up to [limit], returning where it stopped. Matches may reach
/// back to the start of [out].
int _lz4Block(
  Uint8List src,
  int start,
  int end,
  Uint8List out,
  int position,
  int limit,
) {
  int i = start;
  int o = position;
  while (i < end) {
    final int token = src[i++];
    int literals = token >> 4;
    if (literals == 15) {
      int extra;
      do {
        if (i >= end) {
          throw const FormatException('Truncated LZ4 literal length');
        }
        extra = src[i++];
        literals += extra;
      } while (extra == 255);
    }
    if (i + literals > end || o + literals > limit) {
      throw const FormatException('LZ4 literals out of bounds');
    }
    out.setRange(o, o + literals, src, i);
    i += literals;
    o += literals;
    if (i >= end) {
      break; // The last sequence is literals alone.
    }
    if (i + 2 > end) {
      throw const FormatException('Truncated LZ4 offset');
    }
    final int distance = src[i] | src[i + 1] << 8;
    i += 2;
    if (distance == 0 || distance > o) {
      throw const FormatException('LZ4 offset out of bounds');
    }
    int match = token & 15;
    if (match == 15) {
      int extra;
      do {
        if (i >= end) {
          throw const FormatException('Truncated LZ4 match length');
        }
        extra = src[i++];
        match += extra;
      } while (extra == 255);
    }
    match += 4;
    if (o + match > limit) {
      throw const FormatException('LZ4 match out of bounds');
    }
    // Byte by byte: a match may overlap the bytes it is producing.
    int from = o - distance;
    for (int k = 0; k < match; k++) {
      out[o++] = out[from++];
    }
  }
  return o;
}

// ---------------------------------------------------------------------------
// tpl containers.
// ---------------------------------------------------------------------------

/// A parsed `tpl` container: its format string and the top-level values
/// it describes. `v` is a uint16 [int]; `u` and `f` are float32 [double]s;
/// `A(...)` is a [List] and `S(...)` a [List] of its members.
@immutable
@visibleForTesting
class GoodnotesTpl {
  const GoodnotesTpl(this.format, this.values);
  final String format;
  final List<Object> values;

  double number(int index) => (values[index] as num).toDouble();

  List<int> ints(int index) => (values[index] as List<Object>).cast<int>();

  List<double> doubles(int index) =>
      (values[index] as List<Object>).cast<double>();

  List<List<double>> structs(int index) => <List<double>>[
    for (final Object item in values[index] as List<Object>)
      (item as List<Object>).cast<double>(),
  ];
}

@visibleForTesting
GoodnotesTpl parseGoodnotesTpl(Uint8List data) {
  _need(data, 0, 8);
  if (data[0] != 0x74 || data[1] != 0x70 || data[2] != 0x6C || data[3] != 0) {
    throw const FormatException('Not a tpl container');
  }
  final ByteData view = ByteData.sublistView(data);
  final int length = view.getUint32(4, Endian.little);
  if (length > data.length || length < 8) {
    throw const FormatException('A tpl container of the wrong size');
  }
  int end = 8;
  while (end < length && data[end] != 0) {
    end++;
  }
  if (end >= length) {
    throw const FormatException('An unterminated tpl format');
  }
  final String format = ascii.decode(data.sublist(8, end));
  final List<_TplType> types = _TplType.parse(format);
  final _TplReader reader = _TplReader(view, end + 1, length);
  return GoodnotesTpl(format, <Object>[
    for (final _TplType type in types) reader.read(type),
  ]);
}

class _TplType {
  const _TplType(this.kind, [this.members = const <_TplType>[]]);

  /// `v`, `u`, `f`, `A`, or `S`.
  final String kind;
  final List<_TplType> members;

  /// Bytes taken by one value, for a fixed-size type.
  int? get fixedSize => switch (kind) {
    'v' => 2,
    'u' || 'f' => 4,
    'S' => members.fold<int?>(
      0,
      (int? sum, _TplType m) =>
          sum == null || m.fixedSize == null ? null : sum + m.fixedSize!,
    ),
    _ => null,
  };

  static List<_TplType> parse(String format) {
    int i = 0;
    List<_TplType> sequence(int depth) {
      if (depth > 8) {
        throw const FormatException('A tpl format nested too deeply');
      }
      final List<_TplType> types = <_TplType>[];
      while (i < format.length && format[i] != ')') {
        final String c = format[i++];
        switch (c) {
          case 'v' || 'u' || 'f':
            types.add(_TplType(c));
          case 'A' || 'S':
            if (i >= format.length || format[i] != '(') {
              throw const FormatException('A malformed tpl format');
            }
            i++;
            final List<_TplType> members = sequence(depth + 1);
            if (i >= format.length || format[i] != ')') {
              throw const FormatException('A malformed tpl format');
            }
            i++;
            types.add(_TplType(c, members));
          default:
            throw FormatException('An unknown tpl type "$c"');
        }
      }
      return types;
    }

    final List<_TplType> types = sequence(0);
    if (i != format.length) {
      throw const FormatException('A malformed tpl format');
    }
    return types;
  }
}

class _TplReader {
  _TplReader(this._view, this._offset, this._end);
  final ByteData _view;
  int _offset;
  final int _end;

  void _need(int bytes) {
    if (_offset + bytes > _end) {
      throw const FormatException('Truncated tpl data');
    }
  }

  Object read(_TplType type) {
    switch (type.kind) {
      case 'v':
        _need(2);
        final int value = _view.getUint16(_offset, Endian.little);
        _offset += 2;
        return value;
      case 'u' || 'f':
        _need(4);
        final double value = _view.getFloat32(_offset, Endian.little);
        _offset += 4;
        return value;
      case 'S':
        return <Object>[for (final _TplType m in type.members) read(m)];
      default: // 'A'
        _need(4);
        final int count = _view.getUint32(_offset, Endian.little);
        _offset += 4;
        final _TplType element = type.members.length == 1
            ? type.members.single
            : _TplType('S', type.members);
        // Never allocate for more items than the bytes left could hold.
        final int itemSize = math.max(1, element.fixedSize ?? 4);
        if (count > (_end - _offset) ~/ itemSize) {
          throw const FormatException('A tpl array longer than its data');
        }
        return <Object>[for (int k = 0; k < count; k++) read(element)];
    }
  }
}

// ---------------------------------------------------------------------------
// Protocol buffers.
// ---------------------------------------------------------------------------

/// The messages of a stream of varint-length-delimited messages.
List<Uint8List> _delimited(Uint8List data) {
  final List<Uint8List> messages = <Uint8List>[];
  int offset = 0;
  while (offset < data.length) {
    final (int length, int next) = _varint(data, offset);
    if (length > data.length - next) {
      throw const FormatException('A truncated protobuf message');
    }
    messages.add(Uint8List.sublistView(data, next, next + length));
    offset = next + length;
  }
  return messages;
}

(int, int) _varint(Uint8List data, int offset) {
  int result = 0;
  int shift = 0;
  while (true) {
    if (offset >= data.length) {
      throw const FormatException('A truncated varint');
    }
    final int byte = data[offset++];
    if (shift < 63) {
      result |= (byte & 0x7F) << shift;
    }
    if (byte < 0x80) {
      return (result, offset);
    }
    shift += 7;
    if (shift >= 70) {
      throw const FormatException('A malformed varint');
    }
  }
}

/// One protobuf message's fields, decoded without a schema.
class _Message {
  _Message._(this._fields);

  factory _Message.parse(Uint8List data) {
    final Map<int, List<Object>> fields = <int, List<Object>>{};
    int offset = 0;
    while (offset < data.length) {
      final (int key, int next) = _varint(data, offset);
      offset = next;
      final int field = key >> 3;
      final Object value;
      switch (key & 7) {
        case 0:
          final (int v, int after) = _varint(data, offset);
          value = v;
          offset = after;
        case 1:
          _need(data, offset, 8);
          value = Uint8List.sublistView(data, offset, offset + 8);
          offset += 8;
        case 2:
          final (int length, int after) = _varint(data, offset);
          if (length > data.length - after) {
            throw const FormatException('A truncated protobuf field');
          }
          value = Uint8List.sublistView(data, after, after + length);
          offset = after + length;
        case 5:
          _need(data, offset, 4);
          value = ByteData.sublistView(
            data,
            offset,
            offset + 4,
          ).getFloat32(0, Endian.little);
          offset += 4;
        default:
          throw const FormatException('An unsupported protobuf wire type');
      }
      (fields[field] ??= <Object>[]).add(value);
    }
    return _Message._(fields);
  }

  final Map<int, List<Object>> _fields;

  Object? _first(int field) => _fields[field]?.first;

  int? varint(int field) {
    final Object? value = _first(field);
    return value is int ? value : null;
  }

  double? float(int field) {
    final Object? value = _first(field);
    return value is double ? value : null;
  }

  Uint8List? bytes(int field) {
    final Object? value = _first(field);
    return value is Uint8List ? value : null;
  }

  String? string(int field) {
    final Uint8List? value = bytes(field);
    if (value == null) {
      return null;
    }
    try {
      return utf8.decode(value);
    } on FormatException {
      return null;
    }
  }

  _Message? message(int field) {
    final Uint8List? value = bytes(field);
    if (value == null) {
      return null;
    }
    try {
      return _Message.parse(value);
    } on FormatException {
      return null;
    }
  }

  List<_Message> messages(int field) => <_Message>[
    for (final Object value in _fields[field] ?? const <Object>[])
      if (value is Uint8List) _Message.parse(value),
  ];
}

// ---------------------------------------------------------------------------
// ZIP archives.
// ---------------------------------------------------------------------------

class _ZipEntry {
  const _ZipEntry({
    required this.method,
    required this.compressedSize,
    required this.size,
    required this.localHeader,
  });
  final int method;
  final int compressedSize;
  final int size;
  final int localHeader;
}

/// A read-only ZIP archive held in memory: stored and deflated entries,
/// without ZIP64 or encryption.
class _ZipArchive {
  _ZipArchive(this._data) : _view = ByteData.sublistView(_data) {
    final int directoryEnd = _findEndOfDirectory();
    final int count = _view.getUint16(directoryEnd + 10, Endian.little);
    final int directorySize = _view.getUint32(directoryEnd + 12, Endian.little);
    int offset = _view.getUint32(directoryEnd + 16, Endian.little);
    if (offset == 0xFFFFFFFF || count == 0xFFFF) {
      throw const FormatException('ZIP64 archives are not supported');
    }
    if (offset + directorySize > directoryEnd) {
      throw const FormatException('A corrupt ZIP directory');
    }
    for (int i = 0; i < count; i++) {
      _need(_data, offset, 46);
      if (_view.getUint32(offset, Endian.little) != 0x02014B50) {
        throw const FormatException('A corrupt ZIP directory entry');
      }
      final int flags = _view.getUint16(offset + 8, Endian.little);
      final int method = _view.getUint16(offset + 10, Endian.little);
      final int compressed = _view.getUint32(offset + 20, Endian.little);
      final int size = _view.getUint32(offset + 24, Endian.little);
      final int nameLength = _view.getUint16(offset + 28, Endian.little);
      final int extraLength = _view.getUint16(offset + 30, Endian.little);
      final int commentLength = _view.getUint16(offset + 32, Endian.little);
      final int local = _view.getUint32(offset + 42, Endian.little);
      _need(_data, offset + 46, nameLength);
      final String name = utf8.decode(
        _data.sublist(offset + 46, offset + 46 + nameLength),
        allowMalformed: true,
      );
      if (flags & 1 != 0) {
        throw const FormatException('Encrypted ZIP entries are not supported');
      }
      entries[name] = _ZipEntry(
        method: method,
        compressedSize: compressed,
        size: size,
        localHeader: local,
      );
      offset += 46 + nameLength + extraLength + commentLength;
    }
  }

  final Uint8List _data;
  final ByteData _view;
  final Map<String, _ZipEntry> entries = <String, _ZipEntry>{};

  int _findEndOfDirectory() {
    final int last = _data.length - 22;
    final int first = math.max(0, last - 0xFFFF);
    for (int i = last; i >= first; i--) {
      if (_view.getUint32(i, Endian.little) == 0x06054B50) {
        return i;
      }
    }
    throw const FormatException('Not a ZIP archive');
  }

  Uint8List read(String name, _Budget budget) {
    final _ZipEntry? entry = entries[name];
    if (entry == null) {
      throw FormatException('Missing $name');
    }
    final int header = entry.localHeader;
    _need(_data, header, 30);
    if (_view.getUint32(header, Endian.little) != 0x04034B50) {
      throw const FormatException('A corrupt ZIP entry');
    }
    final int start =
        header +
        30 +
        _view.getUint16(header + 26, Endian.little) +
        _view.getUint16(header + 28, Endian.little);
    _need(_data, start, entry.compressedSize);
    final Uint8List compressed = Uint8List.sublistView(
      _data,
      start,
      start + entry.compressedSize,
    );
    budget.take(entry.size);
    switch (entry.method) {
      case 0:
        if (entry.compressedSize != entry.size) {
          throw const FormatException('A corrupt stored ZIP entry');
        }
        return Uint8List.fromList(compressed);
      case 8:
        return _inflate(compressed, entry.size);
      default:
        throw const FormatException('An unsupported ZIP compression method');
    }
  }

  /// Inflates [compressed], stopping as soon as it grows past [size], the
  /// size the directory declares, so a forged size cannot unpack a bomb.
  static Uint8List _inflate(Uint8List compressed, int size) {
    final _BoundedSink sink = _BoundedSink(size);
    final ByteConversionSink input = ZLibDecoder(
      raw: true,
    ).startChunkedConversion(sink);
    const int chunk = 64 * 1024;
    for (int i = 0; i < compressed.length; i += chunk) {
      input.add(
        Uint8List.sublistView(
          compressed,
          i,
          math.min(compressed.length, i + chunk),
        ),
      );
    }
    input.close();
    final Uint8List out = sink.takeBytes();
    if (out.length != size) {
      throw const FormatException('A ZIP entry of the wrong size');
    }
    return out;
  }
}

class _BoundedSink implements Sink<List<int>> {
  _BoundedSink(this._limit);
  final int _limit;
  final BytesBuilder _builder = BytesBuilder(copy: true);

  @override
  void add(List<int> data) {
    if (_builder.length + data.length > _limit) {
      throw const DocumentImportException(
        'This Goodnotes file is too large to import',
      );
    }
    _builder.add(data);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _builder.takeBytes();
}
