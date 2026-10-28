import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Keeps each PDF page's small preview, encoded, between visits, so a page
/// scrolled to again, even after the app restarts, is shown at once without
/// waiting for the PDF to be rendered.
abstract interface class PdfPreviewStore {
  /// The preview stored under [key], or null.
  Future<Uint8List?> read(String key);

  Future<bool> contains(String key);

  Future<void> write(String key, Uint8List encoded);
}

/// A [PdfPreviewStore] in a directory of files, one per preview, trimmed
/// to [maxBytes] by dropping those least recently written. A preview that
/// cannot be read or written is simply rendered again.
class FilePdfPreviewStore implements PdfPreviewStore {
  FilePdfPreviewStore(this._directory, {this.maxBytes = 256 * 1024 * 1024}) {
    // Without a directory, every read and write fails on its own.
    _directory.ignore();
  }

  /// A store in the app's cache directory, which the system may clear.
  FilePdfPreviewStore.appCache({int maxBytes = 256 * 1024 * 1024})
    : this(
        getApplicationCacheDirectory().then(
          (Directory cache) => Directory('${cache.path}/pdf-previews'),
        ),
        maxBytes: maxBytes,
      );

  final Future<Directory> _directory;
  final int maxBytes;

  /// Bytes written since the directory was last measured.
  int _written = 0;
  Future<void>? _trimming;

  Future<File> _file(String key) async =>
      File('${(await _directory).path}/$key.png');

  @override
  Future<Uint8List?> read(String key) async {
    try {
      return await (await _file(key)).readAsBytes();
    } on Object {
      return null;
    }
  }

  @override
  Future<bool> contains(String key) async {
    try {
      return await (await _file(key)).exists();
    } on Object {
      return false;
    }
  }

  @override
  Future<void> write(String key, Uint8List encoded) async {
    try {
      final Directory directory = await _directory;
      await directory.create(recursive: true);
      final File file = File('${directory.path}/$key.png');
      final File temporary = File('${file.path}.tmp');
      await temporary.writeAsBytes(encoded, flush: true);
      await temporary.rename(file.path);
      _written += encoded.length;
      // Measuring the whole directory is only worth it now and then.
      if (_written > maxBytes ~/ 8) {
        _written = 0;
        _trimming ??= _trim(directory).whenComplete(() => _trimming = null);
      }
    } on Object {
      // Not kept: the page is rendered again next time.
    }
  }

  Future<void> _trim(Directory directory) async {
    final List<(File, FileStat)> files = <(File, FileStat)>[];
    int total = 0;
    await for (final FileSystemEntity entity in directory.list()) {
      if (entity is! File) continue;
      final FileStat stat = await entity.stat();
      files.add((entity, stat));
      total += stat.size;
    }
    if (total <= maxBytes) return;
    files.sort(
      ((File, FileStat) a, (File, FileStat) b) =>
          a.$2.modified.compareTo(b.$2.modified),
    );
    // Down to three quarters, so the next few writes do not trim again.
    for (final (File file, FileStat stat) in files) {
      if (total <= maxBytes * 3 ~/ 4) break;
      try {
        await file.delete();
        total -= stat.size;
      } on Object {
        // Gone already, or in use; the next trim tries again.
      }
    }
  }
}
