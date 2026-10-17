import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// How far a cloud operation has come: what it is doing, how many of its
/// items are done, and the one it is on.
@immutable
class CloudProgress {
  const CloudProgress({
    required this.phase,
    required this.completedItems,
    required this.totalItems,
    this.currentName,
  });

  final String phase;
  final int completedItems;
  final int totalItems;
  final String? currentName;

  /// From 0 to 1, or null while the total is not known.
  double? get fraction =>
      totalItems <= 0 ? null : (completedItems / totalItems).clamp(0.0, 1.0);
}

/// Thrown when the user cancels a cloud operation.
class CloudCancelledException implements Exception {
  const CloudCancelledException();

  @override
  String toString() => 'Cancelled';
}

/// What Greatnote remembers about Google Drive between launches: when the
/// library was last backed up, and which Drive files have been imported
/// as which notes.
abstract class CloudStateStore {
  Future<Map<String, Object?>> read();

  Future<void> write(Map<String, Object?> state);

  /// Reads, changes, and writes back.
  Future<void> update(void Function(Map<String, Object?> state) change) async {
    final Map<String, Object?> state = await read();
    change(state);
    await write(state);
  }
}

class InMemoryCloudStateStore extends CloudStateStore {
  Map<String, Object?> _state = <String, Object?>{};

  @override
  Future<Map<String, Object?>> read() async =>
      jsonDecode(jsonEncode(_state)) as Map<String, Object?>;

  @override
  Future<void> write(Map<String, Object?> state) async {
    _state = jsonDecode(jsonEncode(state)) as Map<String, Object?>;
  }
}

/// Keeps the state in one JSON file, written to a temporary file and
/// renamed over the old one. A file that cannot be read counts as empty.
class FileCloudStateStore extends CloudStateStore {
  FileCloudStateStore(this.file);

  final File file;

  @override
  Future<Map<String, Object?>> read() async {
    try {
      if (!await file.exists()) return <String, Object?>{};
      final Object? decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, Object?> ? decoded : <String, Object?>{};
    } on Object {
      return <String, Object?>{};
    }
  }

  @override
  Future<void> write(Map<String, Object?> state) async {
    await file.parent.create(recursive: true);
    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(state), flush: true);
    await temporary.rename(file.path);
  }
}
