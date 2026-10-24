import 'dart:ui' as ui;
import 'dart:typed_data';

import 'asset_byte_cache.dart';

/// Per-editor image ownership, independent of Flutter's global image cache.
/// Consumers own clones; cache eviction cannot invalidate a painted image.
class PageImageCache {
  PageImageCache({
    required Future<Uint8List?> Function(String) readAsset,
    this.maxBytes = 32 * 1024 * 1024,
    int sourceMaxBytes = 8 * 1024 * 1024,
  }) : _sources = AssetByteCache(read: readAsset, maxBytes: sourceMaxBytes);

  final int maxBytes;
  final AssetByteCache _sources;
  final Map<String, _ImageEntry> _entries = {};
  final Map<String, _ImageEntry> _pending = {};
  int _generation = 0;

  int get retainedBytes =>
      _entries.values.fold(0, (sum, entry) => sum + entry.cost);
  int get sourceBytes => _sources.retainedBytes;

  Future<ui.Image> image(String assetId, int width, int height) {
    final key = '$assetId:$width:$height';
    var entry = _entries.remove(key);
    if (entry != null) {
      _entries[key] = entry;
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
        entry.loading.then<void>(
          (_) {
            if (generation != _generation) return;
            _pending.remove(key);
            _trim();
          },
          onError: (Object _) {
            if (generation != _generation) return;
            _pending.remove(key);
            if (identical(_entries[key], created)) _entries.remove(key);
            created.evict();
          },
        );
      }
    }
    final borrowed = entry.borrow();
    _trim();
    return borrowed;
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

  void _trim() {
    while (retainedBytes > maxBytes) {
      _entries.remove(_entries.keys.first)!.evict();
    }
  }

  /// Under memory pressure: lets go of every decoded picture not still
  /// being decoded, and of the bytes kept to decode again. Pictures on
  /// screen hold clones of their own, so none goes blank.
  void releaseMemory() {
    _entries.removeWhere((String key, _ImageEntry entry) {
      if (_pending.containsKey(key)) return false;
      entry.evict();
      return true;
    });
    _sources.clear();
  }

  void clear() {
    _generation++;
    for (final entry in _entries.values) {
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
