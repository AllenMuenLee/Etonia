import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Host side of `integration_test/visual_tour_test.dart`: writes each
/// screenshot as `<name>.png` and the step report as `report.json` under
/// `$TOUR_OUT` (default `build/visual_tour`).
Future<void> main() {
  final Directory out = Directory(
    Platform.environment['TOUR_OUT'] ?? 'build/visual_tour',
  );
  return integrationDriver(
    onScreenshot:
        (String name, List<int> bytes, [Map<String, Object?>? args]) async {
          await out.create(recursive: true);
          await File('${out.path}/$name.png').writeAsBytes(bytes);
          return true;
        },
    responseDataCallback: (Map<String, dynamic>? data) async {
      if (data == null) {
        return;
      }
      await out.create(recursive: true);
      // The screenshots are already files; leave their bytes out.
      final Map<String, dynamic> report = Map<String, dynamic>.of(data)
        ..remove('screenshots');
      await File(
        '${out.path}/report.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    },
    writeResponseOnFailure: true,
  );
}
