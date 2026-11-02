import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../editor/widgets/toolbar_layout.dart';

/// Keeps the tool palette's arrangement between launches, in one JSON file
/// beside the library. A file that cannot be read counts as none.
class ToolbarLayoutStore {
  ToolbarLayoutStore(this.file);

  final File file;

  /// The last write, so writes land one after another, in order.
  Future<void> _writing = Future<void>.value();

  Future<ToolbarLayout?> read() async {
    try {
      if (!await file.exists()) return null;
      return ToolbarLayout.fromJson(jsonDecode(await file.readAsString()));
    } on Object {
      return null;
    }
  }

  /// Writes [layout] to a temporary file and renames it over the old one.
  Future<void> write(ToolbarLayout layout) {
    return _writing = _writing.then((_) async {
      try {
        await file.parent.create(recursive: true);
        final File temporary = File('${file.path}.tmp');
        await temporary.writeAsString(jsonEncode(layout.toJson()), flush: true);
        await temporary.rename(file.path);
      } on Object {
        // Not kept this time; the arrangement still holds until closed.
      }
    });
  }
}
