import 'dart:ui' as ui;
import 'dart:typed_data';

import '../../../shared/memory/note_cache_pool.dart';
import 'asset_byte_cache.dart';

/// Per-editor image ownership, independent of Flutter's global image cache.
/// Consumers own clones; cache eviction cannot invalidate a painted image.
class PageImageCache {
  PageImageCache({
    required Future<Uint8List?> Function(String) readAsset,
    NoteCacheScope? cacheScope,
    int? sourceMaxBytes,
  }) : cacheScope =
           cacheScope ??
           NoteCachePool(maxBytes: const CacheBudget().notesBytes).scope() {
    _sources = AssetByteCache(
      read: readAsset,
      maxBytes: sourceMaxBytes,
      scope: this.cacheScope,
    );
  }

  /// The note's share of the memory for caches, which says how many decoded
  /// pictures are kept: each is shown at once when it is needed again, until
  /// its page's turn to go comes.
  final NoteCacheScope cacheScope;
  late final AssetByteCache _sources;
  final Map<String, _ImageEntry> _entries = {};
  final Map<String, _ImageEntry> _pending = {};
  int _generation = 0;

  int get retainedBytes =>
      _entries.values.fold(0, (sum, entry) => sum + entry.cost);
  int get sourceBytes => _sources.retainedBytes;

  /// The picture [assetId] at [width] by [height], kept for [page] of the
  /// note, or for all of its pages without one. The caller owns the clone.
  Future<ui.Image> image(
    String assetId,
    int width,
    int height, {
    Object? page,
  }) {
    final key = '$assetId:$width:$height';
    var entry = _entries[key];
    if (entry != null) {
      if (page != null) entry.item?.moveTo(page);
    } else {
      entry = _pending[key];
      if (entry == null) {
        entry = _ImageEntry(
          _decode(assetId, width, height),
          width * height * 4,
        );
        _entries[key] = entry;
        _pending[key] = entry;
        final generation = _generation;
        final created = entry;
        entry.item = cacheScope.add(
          page: page,
          bytes: entry.cost,
          inUse: () => _pending.containsKey(key),
          onPop: () {
            if (identical(_entries[key], created)) _entries.remove(key);
            created.evict();
          },
        );
        entry.loading.then<void>(
          (_) {
            if (generation != _generation) return;
            _pending.remove(key);
            created.item?.resize(created.cost);
          },
          onError: (Object _) {
            if (generation != _generation) return;
            _pending.remove(key);
            if (identical(_entries[key], created)) _entries.remove(key);
            created.item?.remove();
            created.evict();
          },
        );
      }
    }
    return entry.borrow();
  }

  Future<ui.Image> _decode(String id, int width, int height) async {
    final bytes = await _sources.load(id);
    if (bytes == null) throw StateError('Image asset missing');
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: width,
      targetHeight: height,
    );
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  /// Under memory pressure: lets go of every decoded picture not still
  /// being decoded, and of the bytes kept to decode again. Pictures on
  /// screen hold clones of their own, so none goes blank.
  void releaseMemory() {
    _entries.removeWhere((String key, _ImageEntry entry) {
      if (_pending.containsKey(key)) return false;
      entry.item?.remove();
      entry.evict();
      return true;
    });
    _sources.clear();
  }

  void clear() {
    _generation++;
    for (final entry in _entries.values) {
      entry.item?.remove();
      entry.evict();
    }
    _entries.clear();
    _pending.clear();
    _sources.clear();
  }
}

class _ImageEntry {
  _ImageEntry(Future<ui.Image> image, this.cost) {
    loading = image.then((image) {
      _image = image;
      cost = image.width * image.height * 4;
      _disposeIfUnused();
      return image;
    });
  }
  late final Future<ui.Image> loading;
  ui.Image? _image;
  NoteCacheItem? item;
  int cost;
  int _borrowers = 0;
  bool _evicted = false;

  Future<ui.Image> borrow() async {
    _borrowers++;
    try {
      return (await loading).clone();
    } finally {
      _borrowers--;
      _disposeIfUnused();
    }
  }

  void evict() {
    _evicted = true;
    _disposeIfUnused();
  }

  void _disposeIfUnused() {
    if (_evicted && _borrowers == 0) {
      _image?.dispose();
      _image = null;
    }
  }
}
