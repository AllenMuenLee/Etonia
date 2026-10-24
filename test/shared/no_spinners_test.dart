import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Loading is covered by transitions ([LoadingReveal] and the rest of
/// `shared/widgets/processing.dart`), never shown as a bar or a spinner.
void main() {
  test('the app shows no progress bars or spinners', () {
    final RegExp indicator = RegExp(
      r'\b(LinearProgressIndicator|CircularProgressIndicator|'
      r'RefreshProgressIndicator|CupertinoActivityIndicator|'
      r'RefreshIndicator)\s*[(.]',
    );
    final List<String> found = <String>[
      for (final FileSystemEntity entity in Directory(
        'lib',
      ).listSync(recursive: true))
        if (entity is File && entity.path.endsWith('.dart'))
          for (final (int index, String line)
              in entity.readAsLinesSync().indexed)
            if (indicator.hasMatch(line)) '${entity.path}:${index + 1}',
    ];
    expect(found, isEmpty);
  });
}
