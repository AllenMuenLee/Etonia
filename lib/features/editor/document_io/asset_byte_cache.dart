import 'dart:typed_data';

import '../../../shared/memory/note_cache_pool.dart';

/// One note's encoded assets. Borrowed bytes are immutable Dart objects;
/// eviction releases our reference without invalidating an active reader.
class AssetByteCache {
  AssetByteCache({required this.read, this.maxBytes, this.scope});

  final Future<Uint8List?> Function(String) read;

  /// How many bytes are kept, if limited, on top of what the note's share
  /// of the pool allows.
  final int? maxBytes;

  /// The note's share of the memory for caches; without one only [maxBytes]
  /// limits what is kept.
  final NoteCacheScope? scope;
  final Map<String, Uint8List> _entries = {};
  final Map<String, NoteCacheItem> _items = {};
  final Map<String, Future<Uint8List?>> _pending = {};
  int _generation = 0;
  int retainedBytes = 0;

  Future<Uint8List?> load(String id) {
    final cached = _entries.remove(id);
    if (cached != null) {
      _entries[id] = cached;
      return Future.value(cached);
    }
    return _pending.putIfAbsent(id, () {
      final generation = _generation;
      return Future<Uint8List?>.sync(() => read(id))
          .then((bytes) {
            final int? maxBytes = this.maxBytes;
            if (generation == _generation &&
                bytes != null &&
                (maxBytes == null || bytes.length <= maxBytes)) {
              _entries[id] = bytes;
              retainedBytes += bytes.length;
              while (maxBytes != null && retainedBytes > maxBytes) {
                final String oldest = _entries.keys.first;
                _items.remove(oldest)?.remove();
                retainedBytes -= _entries.remove(oldest)!.length;
              }
              final NoteCacheScope? scope = this.scope;
              if (scope != null && _entries.containsKey(id)) {
                _items[id] = scope.add(
                  bytes: bytes.length,
                  onPop: () {
                    _items.remove(id);
                    retainedBytes -= _entries.remove(id)?.length ?? 0;
                  },
                );
              }
            }
            return bytes;
          })
          .whenComplete(() {
            if (generation == _generation) _pending.remove(id);
          });
    });
  }

  void clear() {
    _generation++;
    for (final NoteCacheItem item in _items.values) {
      item.remove();
    }
    _items.clear();
    _entries.clear();
    _pending.clear();
    retainedBytes = 0;
  }
}
