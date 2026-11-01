import 'dart:typed_data';

/// One note's encoded assets. Borrowed bytes are immutable Dart objects;
/// eviction releases our reference without invalidating an active reader.
class AssetByteCache {
  AssetByteCache({required this.read, this.maxBytes});

  final Future<Uint8List?> Function(String) read;

  /// How many bytes are kept, if limited. By default every asset read is
  /// kept until [clear], which the owner calls when memory runs low.
  final int? maxBytes;
  final Map<String, Uint8List> _entries = {};
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
                retainedBytes -= _entries.remove(_entries.keys.first)!.length;
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
    _entries.clear();
    _pending.clear();
    retainedBytes = 0;
  }
}
