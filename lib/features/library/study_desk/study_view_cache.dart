import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../shared/memory/memory_pressure.dart';

/// What the Study Desk has already made of a page or a picture, kept by bytes
/// so that showing it again costs nothing, and given back when the system runs
/// low on memory.
///
/// Reading a PDF off disk and rasterizing a page of it, cutting a diagram out
/// of a note, and reading a note's images are each worth doing once: the
/// chat's diagram cards, the pane, and the page the reader returns to all ask
/// for the same few things. [load] shares one run between everyone asking at
/// once, so a card scrolled into view twice while it is still being made does
/// not make it twice either.
///
/// Over [maxBytes], the entry used longest ago goes first. Nothing bigger
/// than a third of the budget is kept at all, so one huge page cannot empty the
/// rest.
class StudyByteCache {
  StudyByteCache({required this.maxBytes}) : assert(maxBytes > 0);

  final int maxBytes;

  final LinkedHashMap<Object, Uint8List> _entries =
      LinkedHashMap<Object, Uint8List>();
  final Map<Object, Future<Uint8List?>> _making =
      <Object, Future<Uint8List?>>{};
  int _bytes = 0;
  bool _listening = false;

  int get usedBytes => _bytes;
  int get length => _entries.length;

  /// What is kept for [key], now, or null; counts as a use.
  Uint8List? peek(Object key) {
    final Uint8List? kept = _entries.remove(key);
    if (kept != null) _entries[key] = kept;
    return kept;
  }

  /// [key]'s bytes, from the cache, or from [make] (once, however many ask).
  /// Null when [make] gives none or throws: a failure is not remembered.
  Future<Uint8List?> load(Object key, Future<Uint8List?> Function() make) {
    final Uint8List? kept = peek(key);
    if (kept != null) return SynchronousFuture<Uint8List?>(kept);
    return _making[key] ??= _run(key, make);
  }

  Future<Uint8List?> _run(Object key, Future<Uint8List?> Function() make) async {
    try {
      final Uint8List? made = await make();
      if (made != null) put(key, made);
      return made;
    } on Object {
      return null;
    } finally {
      final _ = _making.remove(key);
    }
  }

  void put(Object key, Uint8List bytes) {
    _listen();
    final Uint8List? old = _entries.remove(key);
    if (old != null) _bytes -= old.length;
    if (bytes.length > maxBytes ~/ 3) return;
    _entries[key] = bytes;
    _bytes += bytes.length;
    while (_bytes > maxBytes && _entries.length > 1) {
      final Object oldest = _entries.keys.first;
      _bytes -= _entries.remove(oldest)!.length;
    }
  }

  /// Lets go of every entry for which [test] holds, as when a note is edited.
  void removeWhere(bool Function(Object key) test) {
    final List<Object> gone = _entries.keys.where(test).toList();
    for (final Object key in gone) {
      _bytes -= _entries.remove(key)!.length;
    }
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
  }

  void _listen() {
    if (_listening) return;
    _listening = true;
    MemoryPressure.instance.addListener(clear);
  }
}

/// The caches the Study Desk's views share. Keys name the repository they
/// were made from, and the note's revision, so a note that changes, or
/// another library, is never answered with what was made from the old.
abstract final class StudyViewCache {
  /// A page of a PDF, rasterized for the pane.
  static final StudyByteCache pdfPages = StudyByteCache(maxBytes: 48 << 20);

  /// A note's own images.
  static final StudyByteCache assets = StudyByteCache(maxBytes: 24 << 20);

  /// A diagram cut out of a note, for the chat.
  static final StudyByteCache crops = StudyByteCache(maxBytes: 16 << 20);

  static void clearAll() {
    pdfPages.clear();
    assets.clear();
    crops.clear();
  }
}
