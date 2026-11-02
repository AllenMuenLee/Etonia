import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../shared/memory/note_cache_pool.dart';
import '../../../shared/widgets/processing.dart';
import 'document_io_config.dart';
import 'document_models.dart';
import 'document_platform.dart';
import 'image_layer.dart';
import 'asset_byte_cache.dart';
import 'pdf_paper.dart';
import 'pdf_preview_store.dart';

/// A page the editor is about to show, for [PdfPageRenderCache.focus].
typedef PdfFocusPage = ({PdfPageSource source, Size displayedSize});

/// A cheap snapshot of the PDF rendering pipeline for tests and profile-mode
/// diagnostics. Latency samples are collected only in debug/profile builds.
@immutable
class PdfRenderDiagnostics {
  const PdfRenderDiagnostics({
    required this.cacheBytes,
    required this.sourceBytes,
    required this.cachedEntries,
    required this.queueLength,
    required this.peakQueueLength,
    required this.requests,
    required this.cacheHits,
    required this.cancelledJobs,
    required this.discardedResults,
    required this.completedJobs,
    required this.renderLatencyP50Ms,
    required this.renderLatencyP95Ms,
  });

  final int cacheBytes;
  final int sourceBytes;
  final int cachedEntries;
  final int queueLength;
  final int peakQueueLength;
  final int requests;
  final int cacheHits;
  final int cancelledJobs;
  final int discardedResults;
  final int completedJobs;
  final double renderLatencyP50Ms;
  final double renderLatencyP95Ms;

  double get cacheHitRate => requests == 0 ? 0 : cacheHits / requests;
}

/// Renders PDF pages for the screen, and for export and the clipboard.
///
/// Renders run one at a time, in order of need, so the page in view never
/// waits behind pages scrolled past. A page is shown first from a quick,
/// small render, then sharp. While the page in view keeps changing, as in a
/// scroll, only those quick renders run; once it settles, or the scroll has
/// slowed well down, see [scrollSpeed], that page and the pages next to it
/// are rendered sharp ahead of everything else.
///
/// Pages are rendered sharp at the size they are seen: smaller while the
/// column is zoomed out, see [showAtZoom]. Zoomed in past that, the part of
/// a page on screen is rendered again on its own, see [showDetail].
///
/// With a [previewStore], each quick render is kept between visits, and
/// while nothing else is rendering those of the rest of the note are made
/// ahead, see [keepPreviews]: a page scrolled to is shown at once.
///
/// How much is kept is up to [cacheScope]'s pool, shared with every open note.
class PdfPageRenderCache {
  PdfPageRenderCache({
    required this.readAsset,
    required this.rasterizer,
    this.config = const DocumentIoConfig(),
    this.previewStore,
    NoteCacheScope? cacheScope,
  }) : cacheScope =
           cacheScope ??
           NoteCachePool(maxBytes: const CacheBudget().notesBytes).scope();

  final NoteCacheScope cacheScope;
  final NoteAssetReader readAsset;
  final PdfRasterizer rasterizer;
  final DocumentIoConfig config;
  final PdfPreviewStore? previewStore;

  /// How big pages are rendered sharp, against their displayed size.
  final ValueNotifier<double> _renderScale = ValueNotifier<double>(1);

  /// The actual viewport zoom. Unlike [renderScale], this is not capped at
  /// one: deep zoom needs only the current base page, not sharp neighbours
  /// that are far outside the viewport.
  double _zoom = 1;

  static const double _deepZoom = 1.5;

  bool get _isDeepZoom => _zoom >= _deepZoom;

  /// The arguments of the last [focus], to focus again at another
  /// [renderScale].
  (List<PdfFocusPage>, double, int)? _lastFocus;

  /// The previews to make ahead, nearest the page in view first.
  List<PdfPageSource> _toKeep = const <PdfPageSource>[];

  /// Sharp renders, at the size each page is shown.
  final LinkedHashMap<String, _PdfRenderEntry> _entries =
      LinkedHashMap<String, _PdfRenderEntry>();

  /// Small renders, shown while the sharp ones are on their way.
  final LinkedHashMap<String, _PdfRenderEntry> _previews =
      LinkedHashMap<String, _PdfRenderEntry>();

  late final AssetByteCache _sources = AssetByteCache(
    read: readAsset,
    maxBytes: config.pdfSourceCacheBytes,
    scope: cacheScope,
  );
  final Map<String, _PdfRenderEntry> _pending = {};

  /// Renders waiting their turn, picked by [_priority].
  final List<_PdfRenderEntry> _queue = <_PdfRenderEntry>[];
  bool _rendering = false;

  static const bool _collectDiagnostics = kDebugMode || kProfileMode;
  static const int _maxLatencySamples = 256;
  final List<double> _renderLatencyMs = <double>[];
  int _requests = 0;
  int _cacheHits = 0;
  int _cancelledJobs = 0;
  int _discardedResults = 0;
  int _completedJobs = 0;
  int _peakQueueLength = 0;

  /// PDFs kept open by a [PdfDocumentRasterizer], by asset, most recently
  /// used last.
  final LinkedHashMap<String, Future<OpenPdf>> _documents =
      LinkedHashMap<String, Future<OpenPdf>>();
  final Map<String, NoteCacheItem> _documentItems = <String, NoteCacheItem>{};
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

  /// The fastest the scroll under way has gone, and whether it has since
  /// slowed enough to count as settled, see [scrollSpeed].
  double _peakSpeed = 0;
  bool _slowed = false;

  static const int _unfocused = 1 << 20;

  int get retainedBytes =>
      _bytesOf(_entries.values) + _bytesOf(_previews.values);
  int get sourceBytes => _sources.retainedBytes;
  int get entryCount => _entries.length;

  PdfRenderDiagnostics get diagnostics {
    final List<double> latency = List<double>.of(_renderLatencyMs)..sort();
    double percentile(double fraction) => latency.isEmpty
        ? 0
        : latency[((latency.length - 1) * fraction).round()];
    return PdfRenderDiagnostics(
      cacheBytes: retainedBytes,
      sourceBytes: sourceBytes,
      cachedEntries: _entries.length + _previews.length,
      queueLength: _queue.length + (_rendering ? 1 : 0),
      peakQueueLength: _peakQueueLength,
      requests: _requests,
      cacheHits: _cacheHits,
      cancelledJobs: _cancelledJobs,
      discardedResults: _discardedResults,
      completedJobs: _completedJobs,
      renderLatencyP50Ms: percentile(0.5),
      renderLatencyP95Ms: percentile(0.95),
    );
  }

  static int _bytesOf(Iterable<_PdfRenderEntry> entries) =>
      entries.fold(0, (sum, entry) => sum + entry.cost);

  static String _pageKey(PdfPageSource source) =>
      '${source.assetId}:${source.pageIndex}';

  int _rankOf(PdfPageSource source) => _ranks[_pageKey(source)] ?? _unfocused;

  /// How big pages are rendered sharp, against the size they are displayed
  /// at a zoom of one: never more than one, see [showAtZoom].
  ValueListenable<double> get renderScale => _renderScale;

  /// The column is zoomed to [zoom], against each page's displayed size:
  /// pages are rendered sharp no bigger than they are seen, which at the
  /// zoom a note opens at is half the pixels, to render, to hand to the
  /// engine and to keep. The scale only goes up in tenths, so a pinch does
  /// not have every page rendered again for each small step.
  void showAtZoom(double zoom) {
    if (!zoom.isFinite || zoom <= 0) return;
    final bool wasDeep = _isDeepZoom;
    _zoom = zoom;
    final double scale = ((zoom * 10 - 1e-6).ceil() / 10).clamp(0.5, 1.0);
    final bool scaleChanged = scale != _renderScale.value;
    if (!scaleChanged && wasDeep == _isDeepZoom) return;
    if (scaleChanged) _renderScale.value = scale;
    final (List<PdfFocusPage>, double, int)? last = _lastFocus;
    if (last != null) focus(last.$1, last.$2, sharpPages: last.$3);
  }

  /// Whether anyone still needs [entry]: someone waiting on it, or the
  /// pages around the one in view.
  bool _wanted(_PdfRenderEntry entry) {
    if (entry.urgent || entry.waiters > 0) return true;
    if (entry.detail != null) return false;
    final int rank = _rankOf(entry.source);
    return entry.preview ? rank < _ranks.length : rank < _sharpRanks;
  }

  /// Lower runs sooner; null waits. Each page's preview comes just before
  /// its sharp render, then the part of it zoomed in on, and nearer pages
  /// before further ones.
  int? _priority(_PdfRenderEntry entry) {
    if (entry.urgent) return -1;
    final int rank = _rankOf(entry.source);
    if (entry.preview) return 3 * rank;
    // A sharp render takes long enough to hold up the previews behind it.
    if (!_settled) return null;
    return 3 * rank + (entry.detail != null ? 2 : 1);
  }

  /// Drops waiting renders no one needs any more, as for pages scrolled
  /// past.
  void _prune() {
    _queue.removeWhere((_PdfRenderEntry entry) {
      if (_wanted(entry)) return false;
      if (_collectDiagnostics) _cancelledJobs++;
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
    if (_collectDiagnostics) _requests++;
    final LinkedHashMap<String, _PdfRenderEntry> tier = preview
        ? _previews
        : _entries;
    final String key = _keyOf(source, width, height, preview: preview);
    final cached = tier[key];
    if (cached != null) {
      if (_collectDiagnostics) _cacheHits++;
      return cached;
    }
    final pending = _pending[key];
    if (pending != null) {
      if (_collectDiagnostics) _cacheHits++;
      return pending;
    }
    final int generation = _generation;
    final entry = _PdfRenderEntry(
      source,
      width,
      height,
      preview: preview,
      onDiscarded: _recordDiscardedResult,
    );
    tier[key] = entry;
    _pending[key] = entry;
    // Even a popped pending render remains joinable until it resolves.
    entry.item = cacheScope.add(
      page: source,
      bytes: entry.cost,
      inUse: () => entry.waiters > 0,
      onPop: () {
        if (identical(tier[key], entry)) tier.remove(key);
        entry.evict();
      },
    );
    if (preview && previewStore != null) {
      unawaited(_previewFromStore(entry));
    } else {
      _queue.add(entry);
      _recordQueueLength();
    }
    entry.image.then<void>(
      (_) {
        if (generation != _generation) return;
        _pending.remove(key);
        entry.item?.resize(entry.cost);
      },
      onError: (Object _) {
        if (generation != _generation) return;
        _pending.remove(key);
        if (identical(tier[key], entry)) tier.remove(key);
        _letGo(entry);
      },
    );
    return entry;
  }

  /// Lets go of [entry] for good.
  void _letGo(_PdfRenderEntry entry) {
    entry.item?.remove();
    entry.evict();
  }

  /// Where [source]'s preview is kept in [previewStore]. A preview is shown
  /// stretched whatever its size, so the size is not part of it; the
  /// preview size is, so that another one is not taken for it.
  String _storeKey(PdfPageSource source) =>
      '${source.assetId}-${source.pageIndex}-${config.pdfPreviewDimension}';

  /// Shows [entry], a preview, from [previewStore], or else has it rendered
  /// in its turn and kept there.
  Future<void> _previewFromStore(_PdfRenderEntry entry) async {
    final int generation = _generation;
    final Uint8List? stored = await previewStore!.read(_storeKey(entry.source));
    if (stored != null) {
      try {
        // Only the encoded bytes are copied here; the engine decodes them
        // elsewhere.
        final ui.Codec codec = await ui.instantiateImageCodec(stored);
        try {
          final ui.Image image = (await codec.getNextFrame()).image;
          await entry.start(Future<PdfPaper>.value(PdfPaper.single(image)));
          return;
        } finally {
          codec.dispose();
        }
      } on Object {
        // Rendered again, and kept anew.
      }
    }
    if (generation != _generation || !_wanted(entry)) {
      if (_collectDiagnostics) _cancelledJobs++;
      entry.cancel();
      return;
    }
    _queue.add(entry);
    _recordQueueLength();
    _pump();
  }

  /// Keeps [entry]'s preview in [previewStore] once it is rendered.
  Future<void> _keepPreview(_PdfRenderEntry entry) async {
    final PdfPreviewStore? store = previewStore;
    if (store == null) return;
    try {
      final ui.Image image = await entry.borrowImage();
      try {
        await _store(store, entry.source, image);
      } finally {
        image.dispose();
      }
    } on Object {
      // Not kept: rendered again next time.
    }
  }

  Future<void> _store(
    PdfPreviewStore store,
    PdfPageSource source,
    ui.Image image,
  ) async {
    final ByteData? png = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    if (png == null) return;
    await store.write(
      _storeKey(source),
      png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
    );
  }

  /// Has the previews of [sources] made and kept in [previewStore], nearest
  /// first, while nothing else is rendering, so that the rest of the note
  /// is shown at once when scrolled to, even on a later visit. Replaces the
  /// ones asked for before.
  void keepPreviews(List<PdfPageSource> sources) {
    if (previewStore == null) return;
    _toKeep = sources;
    _pump();
  }

  /// Makes and keeps the next of [_toKeep] not kept already.
  Future<void> _keepNextPreview() async {
    final PdfPreviewStore store = previewStore!;
    final int generation = _generation;
    while (_toKeep.isNotEmpty && generation == _generation) {
      final PdfPageSource source = _toKeep.first;
      _toKeep = _toKeep.sublist(1);
      // Kept once rendered, or read from the store.
      if (_previews.containsKey('preview:${_pageKey(source)}')) continue;
      if (await store.contains(_storeKey(source))) continue;
      final Size page = source.pageSize;
      final double longest = math.max(page.width, page.height);
      if (longest <= 0) continue;
      final double scale = config.pdfPreviewDimension / longest;
      final PdfPaper paper = await _loadPaper(
        source,
        math.max(1, (page.width * scale).round()),
        math.max(1, (page.height * scale).round()),
      );
      try {
        final ui.Image image = await paper.toImage();
        try {
          await _store(store, source, image);
        } finally {
          image.dispose();
        }
      } finally {
        paper.dispose();
      }
      return;
    }
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
    if (next == null) {
      // Only once the view has settled: a scroll needs the renderer free.
      if (_settled && _toKeep.isNotEmpty && previewStore != null) {
        _rendering = true;
        _measureRender(
          _keepNextPreview(),
        ).catchError((Object _) {}).whenComplete(_renderDone);
      }
      return;
    }
    final _PdfRenderEntry entry = next;
    _queue.remove(entry);
    _rendering = true;
    entry
        .start(
          _measureRender(
            _loadPaper(
              entry.source,
              entry.width,
              entry.height,
              detail: entry.detail,
            ),
          ),
        )
        .whenComplete(_renderDone);
    if (entry.preview) unawaited(_keepPreview(entry));
  }

  void _renderDone() {
    _rendering = false;
    _documentInUse = null;
    for (final Future<OpenPdf> document in _closeAfterRender) {
      _close(document);
    }
    _closeAfterRender.clear();
    _pump();
  }

  Future<T> _measureRender<T>(Future<T> operation) {
    if (!_collectDiagnostics) return operation;
    final Stopwatch stopwatch = Stopwatch()..start();
    return operation.whenComplete(() {
      stopwatch.stop();
      _completedJobs++;
      if (_renderLatencyMs.length == _maxLatencySamples) {
        _renderLatencyMs.removeAt(0);
      }
      _renderLatencyMs.add(stopwatch.elapsedMicroseconds / 1000);
    });
  }

  void _recordQueueLength() {
    if (_collectDiagnostics && _queue.length > _peakQueueLength) {
      _peakQueueLength = _queue.length;
    }
  }

  void _recordDiscardedResult() {
    if (_collectDiagnostics) _discardedResults++;
  }

  /// Starts reading and parsing the PDF of [source], so that its first render
  /// does not wait on that.
  void warm(PdfPageSource source) {
    final PdfRasterizer rasterizer = this.rasterizer;
    if (rasterizer is! PdfDocumentRasterizer) return;
    final Future<OpenPdf> opening = _open(
      source.assetId,
      rasterizer as PdfDocumentRasterizer,
    );
    // A failure surfaces through the render that needs the document.
    opening.then<void>((_) {}, onError: (Object _) {});
  }

  /// The viewport moved. Keep expensive sharp renders out of scrolling;
  /// previews may continue rendering, then sharp work resumes once the view
  /// has stayed still for [DocumentIoConfig.pdfScrollSettleDelay].
  /// A scroll slowed past [scrollSpeed]'s threshold has settled already.
  void viewMoved() {
    if (_slowed) return;
    _settleAfter(config.pdfScrollSettleDelay);
  }

  /// The view is scrolling at [speed], in any unit, as long as it is the
  /// same one throughout a scroll. Once it slows to
  /// [DocumentIoConfig.pdfSlowScrollFraction] of the fastest it went, the
  /// view counts as settled and sharp renders start as it coasts to a stop;
  /// should it speed up again, they wait again.
  void scrollSpeed(double speed) {
    if (!speed.isFinite) return;
    if (speed > _peakSpeed) _peakSpeed = speed;
    final bool slowed =
        _peakSpeed > 0 && speed <= _peakSpeed * config.pdfSlowScrollFraction;
    if (slowed == _slowed) return;
    _slowed = slowed;
    if (!slowed) return;
    _settle?.cancel();
    _settle = null;
    _settled = true;
    _pump();
  }

  /// The scroll from [scrollSpeed] ended; the next one is measured afresh.
  /// Its last movement reaches the pages in the frame after, so a scroll
  /// that ended slowed stays settled through it.
  void scrollEnded() {
    _peakSpeed = 0;
    if (!_slowed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Unless another scroll has started meanwhile.
      if (_peakSpeed == 0) _slowed = false;
    });
  }

  void _settleAfter(Duration delay) {
    _settled = false;
    _settle?.cancel();
    _settle = Timer(delay, () {
      _settled = true;
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
    _lastFocus = (pages, devicePixelRatio, sharpPages);
    final Map<String, int> ranks = <String, int>{};
    for (final PdfFocusPage page in pages) {
      ranks.putIfAbsent(_pageKey(page.source), () => ranks.length);
    }
    _ranks = ranks;
    // At deep zoom neighbouring pages are multiple viewports away. Keeping
    // their full-size rasters can reserve tens of megabytes each without
    // improving anything on screen; their small previews remain available.
    _sharpRanks = _isDeepZoom ? math.min(1, sharpPages) : sharpPages;
    final String? focused = pages.isEmpty ? null : _pageKey(pages.first.source);
    if (focused != _focused) {
      _focused = focused;
      if (!_slowed) _settleAfter(config.pdfSettleDelay);
    }
    int budget = 0;
    for (int i = 0; i < pages.length; i++) {
      final PdfPageSource source = pages[i].source;
      final (int width, int height) = _pixels(
        pages[i].displayedSize * _renderScale.value,
        devicePixelRatio,
      );
      final String sharpKey = _keyOf(source, width, height, preview: false);
      final _PdfRenderEntry? sharp = _entries[sharpKey];
      final (int, int)? small = _previewPixels(width, height);
      if (small != null && !(sharp?.isReady ?? false)) {
        _entry(source, small.$1, small.$2, preview: true);
      }
      if (i < _sharpRanks) {
        // Speculation must not displace the pages nearer to view.
        budget += sharp?.cost ?? width * height * 4;
        if (sharp != null || budget <= cacheScope.maxBytes) {
          _entry(source, width, height);
        }
      }
    }
    if (_isDeepZoom) {
      final Set<String> wanted = <String>{};
      for (int i = 0; i < math.min(_sharpRanks, pages.length); i++) {
        final (int width, int height) = _pixels(
          pages[i].displayedSize * _renderScale.value,
          devicePixelRatio,
        );
        wanted.add(_keyOf(pages[i].source, width, height, preview: false));
      }
      _entries.removeWhere((String key, _PdfRenderEntry entry) {
        if (wanted.contains(key) || entry.waiters > 0 || entry.urgent) {
          return false;
        }
        _letGo(entry);
        return true;
      });
    }
    // Of these, those furthest from view are the first to go.
    for (final PdfFocusPage page in pages.reversed) {
      cacheScope.touchPage(page.source);
    }
    _prune();
    _pump();
  }

  /// Shows [source] at [displayedSize], rendered at [renderScale]: [onImage]
  /// gets a quick preview first, unless the sharp render is ready, then the
  /// sharp one. Each paper is the caller's to dispose. Cancel the ticket
  /// once the page no longer needs its paper.
  PdfPageTicket show(
    PdfPageSource source,
    Size displayedSize,
    double devicePixelRatio, {
    required void Function(PdfPaper paper, bool sharp) onImage,
    required void Function(Object error) onError,
  }) {
    final (int width, int height) = _pixels(
      displayedSize * _renderScale.value,
      devicePixelRatio,
    );
    final PdfPageTicket ticket = PdfPageTicket._(this);
    cacheScope.touchPage(source);
    final _PdfRenderEntry sharp = _entry(source, width, height);
    final (int, int)? small = _previewPixels(width, height);
    final _PdfRenderEntry? preview = small == null || sharp.isReady
        ? null
        : _entry(source, small.$1, small.$2, preview: true);
    for (final _PdfRenderEntry entry in <_PdfRenderEntry>[sharp, ?preview]) {
      entry.waiters++;
      ticket._held.add(entry);
    }
    _prune();
    _pump();
    preview?.borrowPaper().then(
      (PdfPaper paper) {
        if (ticket._cancelled || ticket._sharpShown) {
          paper.dispose();
          return;
        }
        onImage(paper, false);
      },
      // The sharp render reports failures.
      onError: (Object _) {},
    );
    sharp.borrowPaper().then(
      (PdfPaper paper) {
        if (ticket._cancelled) {
          paper.dispose();
          return;
        }
        ticket._sharpShown = true;
        _release(ticket);
        onImage(paper, true);
      },
      onError: (Object error) {
        if (!ticket._cancelled) onError(error);
      },
    );
    return ticket;
  }

  /// Renders [region] of [source], in the pixels of the page rendered whole
  /// at [fullWidth] by [fullHeight], for a page zoomed in past its sharp
  /// paper; after the sharp renders of the pages nearer to view, and only
  /// once the view settles. [onImage] gets the paper, which is the caller's
  /// to dispose; nothing is kept. Cancel the ticket once it is not wanted.
  PdfPageTicket showDetail(
    PdfPageSource source, {
    required int fullWidth,
    required int fullHeight,
    required PdfPixelRegion region,
    required void Function(PdfPaper paper) onImage,
  }) {
    final PdfPageTicket ticket = PdfPageTicket._(this);
    final _PdfRenderEntry entry = _PdfRenderEntry(
      source,
      fullWidth,
      fullHeight,
      preview: false,
      detail: region,
      onDiscarded: _recordDiscardedResult,
    );
    entry.waiters++;
    ticket._held.add(entry);
    _queue.add(entry);
    _recordQueueLength();
    entry.image.then<void>((PdfPaper paper) {
      if (ticket._cancelled) {
        paper.dispose();
        return;
      }
      _release(ticket);
      onImage(paper);
    }, onError: (Object _) {});
    _pump();
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
    cacheScope.touchPage(source);
    final _PdfRenderEntry entry = _entry(source, width, height)..urgent = true;
    final result = entry.bytes;
    _prune();
    _pump();
    return result;
  }

  /// A caller-owned decoded image. The cache retains its own clone and
  /// disposes it when its page's turn to go comes; the caller must dispose
  /// the returned one.
  Future<ui.Image> renderImage(
    PdfPageSource source,
    Size displayedSize,
    double devicePixelRatio,
  ) async {
    final (int width, int height) = _pixels(displayedSize, devicePixelRatio);
    cacheScope.touchPage(source);
    final _PdfRenderEntry entry = _entry(source, width, height)..urgent = true;
    final result = entry.borrowImage();
    _prune();
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

  /// Renders [source] whole at [width] by [height], or only its [detail]
  /// region of it.
  Future<PdfPaper> _loadPaper(
    PdfPageSource source,
    int width,
    int height, {
    PdfPixelRegion? detail,
  }) async {
    final PdfRasterizer rasterizer = this.rasterizer;
    if (rasterizer is PdfDocumentRasterizer) {
      final Future<OpenPdf> opening = _open(
        source.assetId,
        rasterizer as PdfDocumentRasterizer,
      );
      _documentInUse = opening;
      final OpenPdf open = await opening;
      if (detail != null) {
        if (open is! PdfRegionRenderer) {
          throw UnsupportedError('Parts of PDF pages cannot be rendered.');
        }
        return (open as PdfRegionRenderer).renderRegion(
          source.pageIndex,
          fullWidth: width,
          fullHeight: height,
          region: detail,
        );
      }
      if (open is PdfBandRenderer) {
        return (open as PdfBandRenderer).renderPaper(
          source.pageIndex,
          pixelWidth: width,
          pixelHeight: height,
        );
      }
      return PdfPaper.single(
        await open.renderImage(
          source.pageIndex,
          pixelWidth: width,
          pixelHeight: height,
        ),
      );
    }
    if (detail != null) {
      throw UnsupportedError('Parts of PDF pages cannot be rendered.');
    }
    final Uint8List? bytes = await _sources.load(source.assetId);
    if (bytes == null) {
      throw StateError('PDF asset missing');
    }
    if (rasterizer is PdfImageRasterizer) {
      return PdfPaper.single(
        await (rasterizer as PdfImageRasterizer).renderImage(
          bytes,
          source.pageIndex,
          pixelWidth: width,
          pixelHeight: height,
        ),
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
      return PdfPaper.single((await codec.getNextFrame()).image);
    } finally {
      codec.dispose();
    }
  }

  /// The outline of each PDF asked for, read once.
  final Map<String, Future<List<PdfOutlineEntry>>> _outlines =
      <String, Future<List<PdfOutlineEntry>>>{};

  /// The outline of the PDF [assetId], its chapters: empty when it has
  /// none, cannot be read, or the [rasterizer] does not read outlines.
  Future<List<PdfOutlineEntry>> outline(String assetId) {
    final PdfRasterizer rasterizer = this.rasterizer;
    if (rasterizer is! PdfOutlineReader) {
      return Future<List<PdfOutlineEntry>>.value(const <PdfOutlineEntry>[]);
    }
    return _outlines[assetId] ??= () async {
      try {
        final Uint8List? bytes = await _sources.load(assetId);
        if (bytes == null) return const <PdfOutlineEntry>[];
        return await (rasterizer as PdfOutlineReader).readOutline(bytes);
      } on Object {
        // Asked again next time, in case the asset was not there yet.
        unawaited(_outlines.remove(assetId));
        return const <PdfOutlineEntry>[];
      }
    }();
  }

  /// The PDF [assetId], parsed once and kept open for the pages after.
  Future<OpenPdf> _open(String assetId, PdfDocumentRasterizer rasterizer) {
    final Future<OpenPdf>? cached = _documents.remove(assetId);
    if (cached != null) {
      _documents[assetId] = cached;
      return cached;
    }
    late final Future<OpenPdf> opening;
    opening = () async {
      final Uint8List? bytes = await _sources.load(assetId);
      if (bytes == null) {
        throw StateError('PDF asset missing');
      }
      if (identical(_documents[assetId], opening)) {
        // An open PDF holds on to its bytes.
        _documentItems[assetId] = cacheScope.add(
          bytes: bytes.length,
          inUse: () => identical(_documents[assetId], _documentInUse),
          onPop: () {
            _documentItems.remove(assetId);
            final Future<OpenPdf>? document = _documents.remove(assetId);
            if (document != null) _closeWhenIdle(document);
          },
        );
      }
      return rasterizer.open(bytes);
    }();
    _documents[assetId] = opening;
    opening.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_documents[assetId], opening)) {
          _documentItems.remove(assetId)?.remove();
          _documents.remove(assetId);
        }
      },
    );
    while (_documents.length > _openDocuments) {
      final String oldest = _documents.keys.first;
      _documentItems.remove(oldest)?.remove();
      _closeWhenIdle(_documents.remove(oldest)!);
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

  /// Under memory pressure: lets go of every finished render no page is
  /// waiting on, of the PDF bytes kept to render again, and of the PDFs
  /// kept open, once any render using one is done. Pages on screen hold
  /// clones of their own, so none goes blank; a page scrolled back to is
  /// rendered again.
  void releaseMemory() {
    for (final LinkedHashMap<String, _PdfRenderEntry> tier
        in <LinkedHashMap<String, _PdfRenderEntry>>[_entries, _previews]) {
      tier.removeWhere((String _, _PdfRenderEntry entry) {
        // Borrowers hold clones; an image is disposed once theirs are made.
        if (!entry.isReady || entry.waiters > 0) return false;
        _letGo(entry);
        return true;
      });
    }
    _sources.clear();
    _closeDocuments();
  }

  void _closeDocuments() {
    for (final NoteCacheItem item in _documentItems.values) {
      item.remove();
    }
    _documentItems.clear();
    for (final Future<OpenPdf> document in _documents.values) {
      _closeWhenIdle(document);
    }
    _documents.clear();
  }

  void clear() {
    _generation++;
    _settle?.cancel();
    _settle = null;
    _focused = null;
    _settled = true;
    _peakSpeed = 0;
    _slowed = false;
    _ranks = const <String, int>{};
    _sharpRanks = 0;
    _lastFocus = null;
    _toKeep = const <PdfPageSource>[];
    for (final _PdfRenderEntry entry in _queue) {
      if (!entry.urgent) entry.cancel();
    }
    _queue.removeWhere((_PdfRenderEntry entry) => !entry.urgent);
    for (final _PdfRenderEntry entry in <_PdfRenderEntry>[
      ..._entries.values,
      ..._previews.values,
    ]) {
      _letGo(entry);
    }
    _entries.clear();
    _previews.clear();
    _pending.clear();
    _sources.clear();
    _outlines.clear();
    _closeDocuments();
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
  _PdfRenderEntry(
    this.source,
    this.width,
    this.height, {
    required this.preview,
    this.detail,
    this.onDiscarded,
  }) : cost = detail == null
           ? width * height * 4
           : detail.width * detail.height * 4 {
    image = _done.future.then((PdfPaper resolved) {
      _resolved = resolved;
      cost = resolved.width * resolved.height * 4;
      return resolved;
    });
    // A preloaded page may fail with no one waiting on it.
    image.ignore();
  }

  final PdfPageSource source;

  /// The size of the page rendered whole, or of the page [detail] is part
  /// of.
  final int width;
  final int height;
  final bool preview;
  final VoidCallback? onDiscarded;

  /// The only part of the page rendered, for a page zoomed in on.
  final PdfPixelRegion? detail;
  final Completer<PdfPaper> _done = Completer<PdfPaper>();

  /// Pages being shown that wait on this render.
  int waiters = 0;

  /// Asked for by export, the clipboard, or another caller that cannot
  /// cancel: it runs first and is never dropped.
  bool urgent = false;

  late final Future<PdfPaper> image;
  Future<Uint8List>? _bytes;
  PdfPaper? _resolved;

  /// Its place in the note's share of the pool, while it has one.
  NoteCacheItem? item;
  int _borrowers = 0;
  bool _evicted = false;
  int cost;

  bool get isReady => _resolved != null;

  Future<void> start(Future<PdfPaper> loading) {
    return loading.then(
      (PdfPaper resolved) {
        if (_done.isCompleted) {
          onDiscarded?.call();
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
      final ui.Image whole = await (await image).toImage();
      try {
        return await _encodePng(whole);
      } finally {
        whole.dispose();
      }
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

  Future<PdfPaper> borrowPaper() async {
    _borrowers++;
    try {
      return (await image).clone();
    } finally {
      _borrowers--;
      if (_evicted) unawaited(_disposeWhenUnused());
    }
  }

  /// The whole page as one image the caller owns.
  Future<ui.Image> borrowImage() async {
    _borrowers++;
    try {
      return await (await image).toImage();
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
    this.visible,
    this.onShown,
  });

  final PdfPageSource source;

  /// The page's size on screen at a zoom of one.
  final Size displayedSize;
  final PdfPageRenderCache cache;

  /// The part of the page on screen, in this layer's coordinates. Once it
  /// stops changing, the page tells [cache] how far it is zoomed, and, if
  /// zoomed in past its sharp paper, has the part on screen rendered as
  /// sharp as it is seen. Without it, the page is rendered at its displayed
  /// size.
  final ValueListenable<Rect>? visible;

  /// Called once the page first shows its paper, or that it has none.
  final VoidCallback? onShown;

  @override
  State<PdfPageLayer> createState() => _PdfPageLayerState();
}

class _PdfPageLayerState extends State<PdfPageLayer> {
  PdfPaper? _paper;
  bool _sharp = false;
  Object? _error;
  double? _pixelRatio;
  PdfPageTicket? _ticket;

  /// The part on screen of a page zoomed in past its sharp paper, rendered
  /// on its own: where it lies on the page, and how many of its pixels
  /// there are to a unit of the page.
  PdfPaper? _detail;
  Rect _detailRect = Rect.zero;
  double _detailDensity = 0;
  PdfPageTicket? _detailTicket;
  Timer? _settle;

  /// Zoomed in this much past the sharp paper, the part on screen is
  /// rendered on its own.
  static const double _detailThreshold = 1.15;

  /// The most pixels rendered for the part on screen: a little more than a
  /// tablet's screen.
  static const int _maxDetailPixels = 10 * 1024 * 1024;

  @override
  void initState() {
    super.initState();
    widget.cache.renderScale.addListener(_rescaled);
    widget.visible?.addListener(_moved);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final double ratio = MediaQuery.devicePixelRatioOf(context);
    if (_pixelRatio != ratio) {
      _pixelRatio = ratio;
      _load(keepShown: true);
      _moved(viewportMoved: false);
    }
  }

  @override
  void didUpdateWidget(PdfPageLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cache != widget.cache) {
      oldWidget.cache.renderScale.removeListener(_rescaled);
      widget.cache.renderScale.addListener(_rescaled);
    }
    if (oldWidget.visible != widget.visible) {
      oldWidget.visible?.removeListener(_moved);
      widget.visible?.addListener(_moved);
    }
    if (oldWidget.source != widget.source || oldWidget.cache != widget.cache) {
      _load();
    } else if (oldWidget.displayedSize != widget.displayedSize) {
      _load(keepShown: true);
      _moved();
    }
  }

  void _rescaled() => _load(keepShown: true);

  /// The page moved on screen, or was zoomed: once it stays put, see how
  /// big it is seen.
  void _moved({bool viewportMoved = true}) {
    if (widget.visible == null) return;
    if (viewportMoved) widget.cache.viewMoved();
    _settle?.cancel();
    _settle = Timer(widget.cache.config.pdfSettleDelay, _settled);
  }

  void _settled() {
    if (!mounted) return;
    final RenderObject? box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final Size size = box.size;
    if (size.isEmpty || widget.displayedSize.isEmpty) return;
    // Logical pixels on screen to a unit of this page, across: the scales
    // are flat, so the depth axis, left at one, says nothing.
    final Float64List transform = box.getTransformTo(null).storage;
    final double onScreen = math.sqrt(
      transform[0] * transform[0] + transform[1] * transform[1],
    );
    widget.cache.showAtZoom(onScreen * size.width / widget.displayedSize.width);
    _sharpen(size, onScreen * (_pixelRatio ?? 1));
  }

  /// Has the part of the page on screen rendered on its own, if the page
  /// is seen at [needed] device pixels to a unit of the page, well past
  /// its sharp paper; and lets go of that part once it is not.
  void _sharpen(Size size, double needed) {
    final PdfPaper? paper = _paper;
    // The sharp paper comes first; sharpening is tried again once it does.
    if (paper == null || !_sharp) return;
    if (needed <= paper.width / size.width * _detailThreshold) {
      _dropDetail();
      return;
    }
    final Rect page = Offset.zero & size;
    final Rect seen = widget.visible!.value.intersect(page);
    if (seen.width <= 0 || seen.height <= 0) return;
    // A margin, so a little panning does not uncover the blurrier paper.
    final Rect region = seen.inflate(seen.shortestSide / 16).intersect(page);
    double density = needed;
    final double pixels = region.width * region.height * density * density;
    if (pixels > _maxDetailPixels) {
      density *= math.sqrt(_maxDetailPixels / pixels);
    }
    if (_detail != null &&
        _detailDensity >= density * 0.95 &&
        _detailDensity <= density * 1.5 &&
        _detailRect.contains(seen.topLeft) &&
        _detailRect.contains(seen.bottomRight - const Offset(1e-6, 1e-6))) {
      return;
    }
    final int fullWidth = math.max(1, (size.width * density).round());
    final int fullHeight = math.max(1, (size.height * density).round());
    final int left = (region.left * density).floor().clamp(0, fullWidth - 1);
    final int top = (region.top * density).floor().clamp(0, fullHeight - 1);
    final int right = (region.right * density).ceil().clamp(
      left + 1,
      fullWidth,
    );
    final int bottom = (region.bottom * density).ceil().clamp(
      top + 1,
      fullHeight,
    );
    // Exactly where the pixels lie on the page.
    final double unitsPerPixel = size.width / fullWidth;
    final Rect rect = Rect.fromLTRB(
      left * unitsPerPixel,
      top * size.height / fullHeight,
      right * unitsPerPixel,
      bottom * size.height / fullHeight,
    );
    _detailTicket?.cancel();
    late final PdfPageTicket ticket;
    ticket = widget.cache.showDetail(
      widget.source,
      fullWidth: fullWidth,
      fullHeight: fullHeight,
      region: (x: left, y: top, width: right - left, height: bottom - top),
      onImage: (PdfPaper detail) {
        if (!mounted || !identical(_detailTicket, ticket)) {
          detail.dispose();
          return;
        }
        final PdfPaper? previous = _detail;
        setState(() {
          _detail = detail;
          _detailRect = rect;
          _detailDensity = fullWidth / size.width;
        });
        previous?.dispose();
      },
    );
    _detailTicket = ticket;
  }

  void _dropDetail() {
    _detailTicket?.cancel();
    _detailTicket = null;
    final PdfPaper? detail = _detail;
    if (detail == null) return;
    setState(() => _detail = null);
    detail.dispose();
  }

  /// Renders the page for its present size: blurry at first, then sharp. A
  /// page that is only resized, as when the AI panel opens or closes beside
  /// it, keeps showing what it had, stretched to fit, until the new render
  /// arrives; only another page or another cache starts from blank paper.
  void _load({bool keepShown = false}) {
    _ticket?.cancel();
    _error = null;
    if (!keepShown) {
      _paper?.dispose();
      _paper = null;
      _sharp = false;
      _detailTicket?.cancel();
      _detailTicket = null;
      _detail?.dispose();
      _detail = null;
    }
    late final PdfPageTicket ticket;
    ticket = widget.cache.show(
      widget.source,
      widget.displayedSize,
      _pixelRatio ?? 1,
      onImage: (PdfPaper paper, bool sharp) {
        // A preview never replaces sharp paper, even stretched paper.
        if (!mounted || !identical(_ticket, ticket) || (_sharp && !sharp)) {
          paper.dispose();
          return;
        }
        final PdfPaper? previous = _paper;
        setState(() {
          _paper = paper;
          _sharp = sharp;
        });
        previous?.dispose();
        widget.onShown?.call();
        // Sharp paper may now be enough, or the part on screen sharper.
        if (sharp) _moved(viewportMoved: false);
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
    widget.cache.renderScale.removeListener(_rescaled);
    widget.visible?.removeListener(_moved);
    _settle?.cancel();
    _ticket?.cancel();
    _ticket = null;
    _paper?.dispose();
    _detailTicket?.cancel();
    _detail?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      label: 'Page ${widget.source.pageIndex + 1}, from PDF',
      // The page fades in where it lies, so it never shifts under its ink;
      // a sharper render later replaces it without fading again.
      child: LoadingReveal(
        timing: LoadTimings.pdfPage,
        semanticsLabel: 'Loading PDF page',
        child: _paper != null
            ? Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  _paper!.isSingle
                      ? RawImage(
                          image: _paper!.bands.single,
                          fit: BoxFit.fill,
                          filterQuality: FilterQuality.medium,
                        )
                      : CustomPaint(painter: PdfPaperPainter(_paper!)),
                  if (_detail != null)
                    Positioned.fromRect(
                      rect: _detailRect,
                      // Drawn at about its own size.
                      child: CustomPaint(
                        painter: PdfPaperPainter(
                          _detail!,
                          filterQuality: FilterQuality.low,
                        ),
                      ),
                    ),
                ],
              )
            : _error != null
            ? const Center(child: Text('PDF page unavailable'))
            : null,
      ),
    );
  }
}

/// Blank paper over the areas of a PDF page whose content was cut, deleted,
/// or moved away. It lies just above [PdfPageLayer], below images and ink.
class PdfMaskLayer extends StatelessWidget {
  const PdfMaskLayer({super.key, required this.masks, required this.changes});

  /// The page-local areas to leave blank.
  final ValueGetter<List<Rect>> masks;

  /// Fires when [masks] may have changed.
  final Listenable changes;

  /// The color of blank PDF paper, which is painted as it is in either
  /// theme.
  static const Color paper = Color(0xFFFFFFFF);

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(painter: _PdfMaskPainter(masks, changes)),
      ),
    );
  }
}

class _PdfMaskPainter extends CustomPainter {
  _PdfMaskPainter(this.masks, Listenable changes) : super(repaint: changes);

  final ValueGetter<List<Rect>> masks;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint fill = Paint()..color = PdfMaskLayer.paper;
    for (final Rect mask in masks()) {
      canvas.drawRect(mask, fill);
    }
  }

  @override
  bool shouldRepaint(_PdfMaskPainter oldDelegate) => true;
}
