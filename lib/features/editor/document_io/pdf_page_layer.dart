import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../shared/widgets/processing.dart';
import 'document_io_config.dart';
import 'document_models.dart';
import 'document_platform.dart';
import 'image_layer.dart';
import 'asset_byte_cache.dart';

/// A page the editor is about to show, for [PdfPageRenderCache.focus].
typedef PdfFocusPage = ({PdfPageSource source, Size displayedSize});

/// Renders PDF pages for the screen, and for export and the clipboard.
///
/// Renders run one at a time, in order of need, so the page in view never
/// waits behind pages scrolled past. A page is shown first from a quick,
/// small render, then sharp. While the page in view keeps changing, as in a
/// scroll, only those quick renders run; once it settles, that page and the
/// pages next to it are rendered sharp ahead of everything else.
class PdfPageRenderCache {
  PdfPageRenderCache({
    required this.readAsset,
    required this.rasterizer,
    this.config = const DocumentIoConfig(),
  });

  final NoteAssetReader readAsset;
  final PdfRasterizer rasterizer;
  final DocumentIoConfig config;

  /// Sharp renders, at the size each page is shown.
  final LinkedHashMap<String, _PdfRenderEntry> _entries =
      LinkedHashMap<String, _PdfRenderEntry>();

  /// Small renders, shown while the sharp ones are on their way.
  final LinkedHashMap<String, _PdfRenderEntry> _previews =
      LinkedHashMap<String, _PdfRenderEntry>();

  late final AssetByteCache _sources = AssetByteCache(
    read: readAsset,
    maxBytes: config.pdfSourceCacheBytes,
  );
  final Map<String, _PdfRenderEntry> _pending = {};

  /// Renders waiting their turn, picked by [_priority].
  final List<_PdfRenderEntry> _queue = <_PdfRenderEntry>[];
  bool _rendering = false;

  /// PDFs kept open by a [PdfDocumentRasterizer], by asset, most recently
  /// used last.
  final LinkedHashMap<String, Future<OpenPdf>> _documents =
      LinkedHashMap<String, Future<OpenPdf>>();
  static const int _openDocuments = 2;
  Future<OpenPdf>? _documentInUse;
  final List<Future<OpenPdf>> _closeAfterRender = <Future<OpenPdf>>[];

  /// The pages from the last [focus], nearest the one in view first.
  Map<String, int> _ranks = const <String, int>{};
  int _sharpRanks = 0;
  String? _focused;
  bool _settled = true;
  Timer? _settle;
  int _generation = 0;

  static const int _unfocused = 1 << 20;

  int get retainedBytes =>
      _bytesOf(_entries.values) + _bytesOf(_previews.values);
  int get sourceBytes => _sources.retainedBytes;
  int get entryCount => _entries.length;

  static int _bytesOf(Iterable<_PdfRenderEntry> entries) =>
      entries.fold(0, (sum, entry) => sum + entry.cost);

  static String _pageKey(PdfPageSource source) =>
      '${source.assetId}:${source.pageIndex}';

  int _rankOf(PdfPageSource source) => _ranks[_pageKey(source)] ?? _unfocused;

  /// Whether anyone still needs [entry]: someone waiting on it, or the
  /// pages around the one in view.
  bool _wanted(_PdfRenderEntry entry) {
    if (entry.urgent || entry.waiters > 0) return true;
    final int rank = _rankOf(entry.source);
    return entry.preview ? rank < _ranks.length : rank < _sharpRanks;
  }

  /// Lower runs sooner; null waits. Each page's preview comes just before
  /// its sharp render, and nearer pages before further ones.
  int? _priority(_PdfRenderEntry entry) {
    if (entry.urgent) return -1;
    final int rank = _rankOf(entry.source);
    if (entry.preview) return 2 * rank;
    // A sharp render takes long enough to hold up the previews behind it.
    if (!_settled) return null;
    return 2 * rank + 1;
  }

  void _trimAll() {
    _trim(_entries, config.pdfRenderCacheSize, config.pdfRenderCacheBytes);
    _trim(_previews, 1 << 30, config.pdfPreviewCacheBytes);
    _prune();
  }

  /// Evicts the pages furthest from view first and, among those, the least
  /// recently used.
  void _trim(
    LinkedHashMap<String, _PdfRenderEntry> entries,
    int maxCount,
    int maxBytes,
  ) {
    int bytes = _bytesOf(entries.values);
    while (entries.isNotEmpty &&
        (entries.length > maxCount || bytes > maxBytes)) {
      String? victim;
      int furthest = -1;
      for (final MapEntry<String, _PdfRenderEntry> entry in entries.entries) {
        final int rank = _rankOf(entry.value.source);
        if (rank > furthest) {
          furthest = rank;
          victim = entry.key;
        }
      }
      final _PdfRenderEntry evicted = entries.remove(victim)!;
      bytes -= evicted.cost;
      // Even an evicted pending render remains joinable until it resolves.
      evicted.evict();
    }
  }

  /// Drops waiting renders no one needs any more, as for pages scrolled
  /// past.
  void _prune() {
    _queue.removeWhere((_PdfRenderEntry entry) {
      if (_wanted(entry)) return false;
      entry.cancel();
      return true;
    });
  }

  /// A preview is shown stretched to whatever size its page is shown at,
  /// so each page has one, at whichever size it was first made.
  String _keyOf(
    PdfPageSource source,
    int width,
    int height, {
    required bool preview,
  }) => preview
      ? 'preview:${_pageKey(source)}'
      : 'sharp:${_pageKey(source)}:$width:$height';

  _PdfRenderEntry _entry(
    PdfPageSource source,
    int width,
    int height, {
    bool preview = false,
  }) {
    final LinkedHashMap<String, _PdfRenderEntry> tier = preview
        ? _previews
        : _entries;
    final String key = _keyOf(source, width, height, preview: preview);
    final cached = tier.remove(key);
    if (cached != null) {
      tier[key] = cached;
      return cached;
    }
    final pending = _pending[key];
    if (pending != null) return pending;
    final int generation = _generation;
    final entry = _PdfRenderEntry(source, width, height, preview: preview);
    tier[key] = entry;
    _pending[key] = entry;
    _queue.add(entry);
    entry.image.then<void>(
      (_) {
        if (generation != _generation) return;
        _pending.remove(key);
        _trimAll();
      },
      onError: (Object _) {
        if (generation != _generation) return;
        _pending.remove(key);
        if (identical(tier[key], entry)) tier.remove(key);
        entry.evict();
      },
    );
    return entry;
  }

  /// Starts the next render, if none is running.
  void _pump() {
    if (_rendering) return;
    _PdfRenderEntry? next;
    int best = 1 << 62;
    for (final _PdfRenderEntry entry in _queue) {
      final int? priority = _priority(entry);
      if (priority != null && priority < best) {
        best = priority;
        next = entry;
      }
    }
    if (next == null) return;
    final _PdfRenderEntry entry = next;
    _queue.remove(entry);
    _rendering = true;
    entry
        .start(_loadImage(entry.source, entry.width, entry.height))
        .whenComplete(() {
          _rendering = false;
          _documentInUse = null;
          for (final Future<OpenPdf> document in _closeAfterRender) {
            _close(document);
          }
          _closeAfterRender.clear();
          _pump();
        });
  }

  /// Ranks [pages], the PDF pages around the one in view, nearest first,
  /// so that they render in that order, and has each one rendered ahead of
  /// being shown: in preview, and the first [sharpPages] also sharp.
  ///
  /// The view settles once the first page stays the same for
  /// [DocumentIoConfig.pdfSettleDelay]; until then only previews render.
  void focus(
    List<PdfFocusPage> pages,
    double devicePixelRatio, {
    required int sharpPages,
  }) {
    final Map<String, int> ranks = <String, int>{};
    for (final PdfFocusPage page in pages) {
      ranks.putIfAbsent(_pageKey(page.source), () => ranks.length);
    }
    _ranks = ranks;
    _sharpRanks = sharpPages;
    final String? focused = pages.isEmpty ? null : _pageKey(pages.first.source);
    if (focused != _focused) {
      _focused = focused;
      _settled = false;
      _settle?.cancel();
      _settle = Timer(config.pdfSettleDelay, () {
        _settled = true;
        _pump();
      });
    }
    int budget = 0;
    for (int i = 0; i < pages.length; i++) {
      final PdfPageSource source = pages[i].source;
      final (int width, int height) = _pixels(
        pages[i].displayedSize,
        devicePixelRatio,
      );
      final String sharpKey = _keyOf(source, width, height, preview: false);
      final _PdfRenderEntry? sharp = _entries[sharpKey];
      final (int, int)? small = _previewPixels(width, height);
      if (small != null && !(sharp?.isReady ?? false)) {
        _entry(source, small.$1, small.$2, preview: true);
      }
      if (i < sharpPages) {
        // Speculation must not displace the pages nearer to view.
        budget += sharp?.cost ?? width * height * 4;
        if (sharp != null || budget <= config.pdfRenderCacheBytes) {
          _entry(source, width, height);
        }
      }
    }
    _trimAll();
    _pump();
  }

  /// Shows [source] at [displayedSize]: [onImage] gets a quick preview
  /// first, unless the sharp render is ready, then the sharp one. Each
  /// image is the caller's to dispose. Cancel the ticket once the page no
  /// longer needs its paper.
  PdfPageTicket show(
    PdfPageSource source,
    Size displayedSize,
    double devicePixelRatio, {
    required void Function(ui.Image image, bool sharp) onImage,
    required void Function(Object error) onError,
  }) {
    final (int width, int height) = _pixels(displayedSize, devicePixelRatio);
    final PdfPageTicket ticket = PdfPageTicket._(this);
    final _PdfRenderEntry sharp = _entry(source, width, height);
    final (int, int)? small = _previewPixels(width, height);
    final _PdfRenderEntry? preview = small == null || sharp.isReady
        ? null
        : _entry(source, small.$1, small.$2, preview: true);
    for (final _PdfRenderEntry entry in <_PdfRenderEntry>[sharp, ?preview]) {
      entry.waiters++;
      ticket._held.add(entry);
    }
    _trimAll();
    _pump();
    preview?.borrowImage().then(
      (ui.Image image) {
        if (ticket._cancelled || ticket._sharpShown) {
          image.dispose();
          return;
        }
        onImage(image, false);
      },
      // The sharp render reports failures.
      onError: (Object _) {},
    );
    sharp.borrowImage().then(
      (ui.Image image) {
        if (ticket._cancelled) {
          image.dispose();
          return;
        }
        ticket._sharpShown = true;
        _release(ticket);
        onImage(image, true);
      },
      onError: (Object error) {
        if (!ticket._cancelled) onError(error);
      },
    );
    return ticket;
  }

  void _release(PdfPageTicket ticket) {
    for (final _PdfRenderEntry entry in ticket._held) {
      entry.waiters--;
    }
    ticket._held.clear();
    _prune();
    _pump();
  }

  Future<Uint8List> render(
    PdfPageSource source,
    Size displayedSize,
    double devicePixelRatio,
  ) {
    final (int width, int height) = _pixels(displayedSize, devicePixelRatio);
    final _PdfRenderEntry entry = _entry(source, width, height)..urgent = true;
    final result = entry.bytes;
    _trimAll();
    _pump();
    return result;
  }

  /// A caller-owned decoded image. The cache retains its own clone and
  /// disposes it on LRU eviction; the caller must dispose the returned one.
  Future<ui.Image> renderImage(
    PdfPageSource source,
    Size displayedSize,
    double devicePixelRatio,
  ) async {
    final (int width, int height) = _pixels(displayedSize, devicePixelRatio);
    final _PdfRenderEntry entry = _entry(source, width, height)..urgent = true;
    final result = entry.borrowImage();
    _trimAll();
    _pump();
    return result;
  }

  (int, int) _pixels(Size displayedSize, double devicePixelRatio) {
    final Size pixels = _cappedPixels(displayedSize * devicePixelRatio);
    return (
      math.max(1, pixels.width.round()),
      math.max(1, pixels.height.round()),
    );
  }

  /// The size of a page's preview; null where the sharp render is small
  /// enough to be quick itself.
  (int, int)? _previewPixels(int width, int height) {
    final int longest = math.max(width, height);
    if (longest * 2 <= config.pdfPreviewDimension * 3) return null;
    final double scale = config.pdfPreviewDimension / longest;
    return (
      math.max(1, (width * scale).round()),
      math.max(1, (height * scale).round()),
    );
  }

  Size _cappedPixels(Size requested) {
    final double longest = math.max(requested.width, requested.height);
    if (longest <= config.maxPdfRenderDimension) {
      return requested;
    }
    return requested * (config.maxPdfRenderDimension / longest);
  }

  Future<ui.Image> _loadImage(
    PdfPageSource source,
    int width,
    int height,
  ) async {
    final PdfRasterizer rasterizer = this.rasterizer;
    if (rasterizer is PdfDocumentRasterizer) {
      final Future<OpenPdf> opening = _open(
        source.assetId,
        rasterizer as PdfDocumentRasterizer,
      );
      _documentInUse = opening;
      return (await opening).renderImage(
        source.pageIndex,
        pixelWidth: width,
        pixelHeight: height,
      );
    }
    final Uint8List? bytes = await _sources.load(source.assetId);
    if (bytes == null) {
      throw StateError('PDF asset missing');
    }
    if (rasterizer is PdfImageRasterizer) {
      return (rasterizer as PdfImageRasterizer).renderImage(
        bytes,
        source.pageIndex,
        pixelWidth: width,
        pixelHeight: height,
      );
    }
    final Uint8List png = (await rasterizer.render(
      bytes,
      source.pageIndex,
      pixelWidth: width,
      pixelHeight: height,
    )).png;
    final ui.Codec codec = await ui.instantiateImageCodec(png);
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  /// The PDF [assetId], parsed once and kept open for the pages after.
  Future<OpenPdf> _open(String assetId, PdfDocumentRasterizer rasterizer) {
    final Future<OpenPdf>? cached = _documents.remove(assetId);
    if (cached != null) {
      _documents[assetId] = cached;
      return cached;
    }
    final Future<OpenPdf> opening = () async {
      final Uint8List? bytes = await _sources.load(assetId);
      if (bytes == null) {
        throw StateError('PDF asset missing');
      }
      return rasterizer.open(bytes);
    }();
    _documents[assetId] = opening;
    opening.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_documents[assetId], opening)) {
          _documents.remove(assetId);
        }
      },
    );
    while (_documents.length > _openDocuments) {
      _closeWhenIdle(_documents.remove(_documents.keys.first)!);
    }
    return opening;
  }

  void _closeWhenIdle(Future<OpenPdf> document) {
    if (identical(document, _documentInUse)) {
      _closeAfterRender.add(document);
    } else {
      _close(document);
    }
  }

  static void _close(Future<OpenPdf> document) {
    document.then<void>(
      (OpenPdf open) => open.dispose(),
      onError: (Object _) {},
    );
  }

  void clear() {
    _generation++;
    _settle?.cancel();
    _settle = null;
    _focused = null;
    _settled = true;
    _ranks = const <String, int>{};
    _sharpRanks = 0;
    for (final _PdfRenderEntry entry in _queue) {
      if (!entry.urgent) entry.cancel();
    }
    _queue.removeWhere((_PdfRenderEntry entry) => !entry.urgent);
    for (final _PdfRenderEntry entry in <_PdfRenderEntry>[
      ..._entries.values,
      ..._previews.values,
    ]) {
      entry.evict();
    }
    _entries.clear();
    _previews.clear();
    _pending.clear();
    _sources.clear();
    for (final Future<OpenPdf> document in _documents.values) {
      _closeWhenIdle(document);
    }
    _documents.clear();
  }
}

/// A page shown through [PdfPageRenderCache.show].
class PdfPageTicket {
  PdfPageTicket._(this._cache);

  final PdfPageRenderCache _cache;
  final List<_PdfRenderEntry> _held = <_PdfRenderEntry>[];
  bool _cancelled = false;
  bool _sharpShown = false;

  /// The page no longer needs its paper: renders no one else is waiting
  /// for are dropped, unless already under way.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cache._release(this);
  }
}

class _PdfRenderCancelled implements Exception {
  const _PdfRenderCancelled();
}

class _PdfRenderEntry {
  _PdfRenderEntry(this.source, this.width, this.height, {required this.preview})
    : cost = width * height * 4 {
    image = _done.future.then((ui.Image resolved) {
      _resolved = resolved;
      cost = resolved.width * resolved.height * 4;
      return resolved;
    });
    // A preloaded page may fail with no one waiting on it.
    image.ignore();
  }

  final PdfPageSource source;
  final int width;
  final int height;
  final bool preview;
  final Completer<ui.Image> _done = Completer<ui.Image>();

  /// Pages being shown that wait on this render.
  int waiters = 0;

  /// Asked for by export, the clipboard, or another caller that cannot
  /// cancel: it runs first and is never dropped.
  bool urgent = false;

  late final Future<ui.Image> image;
  Future<Uint8List>? _bytes;
  ui.Image? _resolved;
  int _borrowers = 0;
  bool _evicted = false;
  int cost;

  bool get isReady => _resolved != null;

  Future<void> start(Future<ui.Image> loading) {
    return loading.then(
      (ui.Image resolved) {
        if (_done.isCompleted) {
          resolved.dispose();
        } else {
          _done.complete(resolved);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!_done.isCompleted) _done.completeError(error, stack);
      },
    );
  }

  void cancel() {
    if (!_done.isCompleted) {
      _done.completeError(const _PdfRenderCancelled());
    }
  }

  Future<Uint8List> get bytes => _bytes ??= _borrowEncodedImage();

  Future<Uint8List> _borrowEncodedImage() async {
    _borrowers++;
    try {
      // Await encoding before releasing the borrow: toByteData still needs
      // the native image while its asynchronous encoding is in progress.
      return await _encodePng(await image);
    } finally {
      // Export/AI own the returned bytes. Never retain a second PNG copy.
      _bytes = null;
      _borrowers--;
      if (_evicted) unawaited(_disposeWhenUnused());
    }
  }

  Future<Uint8List> _encodePng(ui.Image image) async {
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    if (data == null) throw StateError('PDF page could not be encoded.');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  Future<ui.Image> borrowImage() async {
    _borrowers++;
    try {
      return (await image).clone();
    } finally {
      _borrowers--;
      if (_evicted) unawaited(_disposeWhenUnused());
    }
  }

  void evict() {
    _evicted = true;
    unawaited(_disposeWhenUnused());
  }

  Future<void> _disposeWhenUnused() async {
    if (_borrowers != 0) return;
    try {
      await image;
    } on Object {
      return;
    }
    if (_borrowers == 0 && _evicted) {
      _resolved?.dispose();
      _resolved = null;
    }
  }
}

class PdfPageLayer extends StatefulWidget {
  const PdfPageLayer({
    super.key,
    required this.source,
    required this.displayedSize,
    required this.cache,
    this.onShown,
  });

  final PdfPageSource source;
  final Size displayedSize;
  final PdfPageRenderCache cache;

  /// Called once the page first shows its paper, or that it has none.
  final VoidCallback? onShown;

  @override
  State<PdfPageLayer> createState() => _PdfPageLayerState();
}

class _PdfPageLayerState extends State<PdfPageLayer> {
  ui.Image? _image;
  bool _sharp = false;
  Object? _error;
  double? _pixelRatio;
  PdfPageTicket? _ticket;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final double ratio = MediaQuery.devicePixelRatioOf(context);
    if (_pixelRatio != ratio) {
      _pixelRatio = ratio;
      _load(keepShown: true);
    }
  }

  @override
  void didUpdateWidget(PdfPageLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source || oldWidget.cache != widget.cache) {
      _load();
    } else if (oldWidget.displayedSize != widget.displayedSize) {
      _load(keepShown: true);
    }
  }

  /// Renders the page for its present size: blurry at first, then sharp. A
  /// page that is only resized, as when the AI panel opens or closes beside
  /// it, keeps showing what it had, stretched to fit, until the new render
  /// arrives; only another page or another cache starts from the progress
  /// indicator.
  void _load({bool keepShown = false}) {
    _ticket?.cancel();
    _error = null;
    if (!keepShown) {
      _image?.dispose();
      _image = null;
      _sharp = false;
    }
    late final PdfPageTicket ticket;
    ticket = widget.cache.show(
      widget.source,
      widget.displayedSize,
      _pixelRatio ?? 1,
      onImage: (ui.Image image, bool sharp) {
        // A preview never replaces sharp paper, even stretched paper.
        if (!mounted || !identical(_ticket, ticket) || (_sharp && !sharp)) {
          image.dispose();
          return;
        }
        final ui.Image? previous = _image;
        setState(() {
          _image = image;
          _sharp = sharp;
        });
        previous?.dispose();
        widget.onShown?.call();
      },
      onError: (Object error) {
        if (mounted && identical(_ticket, ticket)) {
          setState(() => _error = error);
          widget.onShown?.call();
        }
      },
    );
    _ticket = ticket;
  }

  @override
  void dispose() {
    _ticket?.cancel();
    _ticket = null;
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      label: 'Page ${widget.source.pageIndex + 1}, from PDF',
      child: _image != null
          ? RawImage(
              image: _image,
              fit: BoxFit.fill,
              filterQuality: FilterQuality.medium,
            )
          : _error != null
          ? const Center(child: Text('PDF page unavailable'))
          : const ShimmerPlaceholder(semanticsLabel: 'Loading PDF page'),
    );
  }
}
