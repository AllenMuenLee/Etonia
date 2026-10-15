import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'document_io_config.dart';
import 'document_models.dart';
import 'document_platform.dart';
import 'image_layer.dart';

class PdfPageRenderCache {
  PdfPageRenderCache({
    required this.readAsset,
    required this.rasterizer,
    this.config = const DocumentIoConfig(),
  });

  final NoteAssetReader readAsset;
  final PdfRasterizer rasterizer;
  final DocumentIoConfig config;
  final LinkedHashMap<String, _PdfRenderEntry> _entries =
      LinkedHashMap<String, _PdfRenderEntry>();

  /// The last PDF read, so rendering its pages one after another reads the
  /// file once.
  String? _assetId;
  Future<Uint8List?>? _assetBytes;

  /// Starts rendering [source] at the size a [PdfPageLayer] would ask for,
  /// so the page is ready by the time it is shown.
  void preload(
    PdfPageSource source,
    Size displayedSize,
    double devicePixelRatio,
  ) {
    final Size pixels = _cappedPixels(displayedSize * devicePixelRatio);
    final int width = math.max(1, pixels.width.round());
    final int height = math.max(1, pixels.height.round());
    final String key = '${source.assetId}:${source.pageIndex}:$width:$height';
    if (_entries.containsKey(key)) {
      return;
    }
    final _PdfRenderEntry entry = _PdfRenderEntry(_load(source, width, height));
    // A failed preload is retried when the page is shown.
    entry.bytes.then<void>((_) {}, onError: (Object _) => _entries.remove(key));
    _entries[key] = entry;
    while (_entries.length > config.pdfRenderCacheSize) {
      _entries.remove(_entries.keys.first)?.evict();
    }
  }

  Future<Uint8List> render(
    PdfPageSource source,
    Size displayedSize,
    double devicePixelRatio,
  ) {
    final Size pixels = _cappedPixels(displayedSize * devicePixelRatio);
    final int width = math.max(1, pixels.width.round());
    final int height = math.max(1, pixels.height.round());
    final String key = '${source.assetId}:${source.pageIndex}:$width:$height';
    final _PdfRenderEntry? cached = _entries.remove(key);
    if (cached != null) {
      _entries[key] = cached;
      return cached.bytes;
    }
    final _PdfRenderEntry result = _PdfRenderEntry(
      _load(source, width, height),
    );
    _entries[key] = result;
    while (_entries.length > config.pdfRenderCacheSize) {
      _entries.remove(_entries.keys.first)?.evict();
    }
    return result.bytes;
  }

  /// A caller-owned decoded image. The cache retains its own clone and
  /// disposes it on LRU eviction; the caller must dispose the returned one.
  Future<ui.Image> renderImage(
    PdfPageSource source,
    Size displayedSize,
    double devicePixelRatio,
  ) async {
    final Size pixels = _cappedPixels(displayedSize * devicePixelRatio);
    final int width = math.max(1, pixels.width.round());
    final int height = math.max(1, pixels.height.round());
    final String key = '${source.assetId}:${source.pageIndex}:$width:$height';
    _PdfRenderEntry? entry = _entries.remove(key);
    entry ??= _PdfRenderEntry(_load(source, width, height));
    _entries[key] = entry;
    while (_entries.length > config.pdfRenderCacheSize) {
      _entries.remove(_entries.keys.first)?.evict();
    }
    return entry.borrowImage();
  }

  Size _cappedPixels(Size requested) {
    final double longest = math.max(requested.width, requested.height);
    if (longest <= config.maxPdfRenderDimension) {
      return requested;
    }
    return requested * (config.maxPdfRenderDimension / longest);
  }

  Future<Uint8List> _load(PdfPageSource source, int width, int height) async {
    if (_assetId != source.assetId) {
      _assetId = source.assetId;
      _assetBytes = readAsset(source.assetId);
    }
    final Future<Uint8List?> read = _assetBytes!;
    final Uint8List? bytes;
    try {
      bytes = await read;
    } on Object {
      if (identical(_assetBytes, read)) _assetId = null;
      rethrow;
    }
    if (bytes == null) {
      if (identical(_assetBytes, read)) _assetId = null;
      throw StateError('PDF asset missing');
    }
    return (await rasterizer.render(
      bytes,
      source.pageIndex,
      pixelWidth: width,
      pixelHeight: height,
    )).png;
  }

  void clear() {
    for (final _PdfRenderEntry entry in _entries.values) {
      entry.evict();
    }
    _entries.clear();
    _assetId = null;
    _assetBytes = null;
  }
}

class _PdfRenderEntry {
  _PdfRenderEntry(this.bytes) {
    _decoded = bytes.then(_decode);
    // A preloaded page may fail with no one waiting on it.
    _decoded.ignore();
  }

  final Future<Uint8List> bytes;
  late final Future<ui.Image> _decoded;
  ui.Image? _resolved;
  int _borrowers = 0;
  bool _evicted = false;

  Future<ui.Image> _decode(Uint8List bytes) async {
    final ui.Codec codec = await ui.instantiateImageCodec(bytes);
    try {
      return _resolved = (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  Future<ui.Image> borrowImage() async {
    _borrowers++;
    try {
      return (await _decoded).clone();
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
      await _decoded;
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
  });

  final PdfPageSource source;
  final Size displayedSize;
  final PdfPageRenderCache cache;

  @override
  State<PdfPageLayer> createState() => _PdfPageLayerState();
}

class _PdfPageLayerState extends State<PdfPageLayer> {
  ui.Image? _image;
  Object? _error;
  double? _pixelRatio;
  Object? _request;

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

  /// Renders the page for its present size. A page that is only resized,
  /// as when the AI panel opens or closes beside it, keeps showing what it
  /// had, stretched to fit, until the sharper render arrives; only another
  /// page or another cache starts from the progress indicator.
  void _load({bool keepShown = false}) {
    final Object request = Object();
    _request = request;
    _error = null;
    if (!keepShown) {
      _image?.dispose();
      _image = null;
    }
    widget.cache
        .renderImage(widget.source, widget.displayedSize, _pixelRatio ?? 1)
        .then(
          (ui.Image image) {
            if (!mounted || !identical(_request, request)) {
              image.dispose();
              return;
            }
            final ui.Image? previous = _image;
            setState(() => _image = image);
            previous?.dispose();
          },
          onError: (Object error) {
            if (mounted && identical(_request, request)) {
              setState(() => _error = error);
            }
          },
        );
  }

  @override
  void dispose() {
    _request = null;
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
          : const Center(
              child: SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
    );
  }
}
