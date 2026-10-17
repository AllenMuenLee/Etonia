import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart' as driver;
import 'package:integration_test/integration_test_driver.dart';

/// Host side of `integration_test/ink_performance_test.dart`: turns each
/// recorded `<scenario>_timeline` into a frame-timing summary named
/// `<scenario>_performance` under `build/`.
Future<void> main() {
  return integrationDriver(
    responseDataCallback: (Map<String, dynamic>? data) async {
      if (data == null) {
        return;
      }
      final Object? loadingMetrics = data['loading_palette_metrics'];
      if (loadingMetrics != null) {
        await Directory('build').create(recursive: true);
        await File('build/loading_palette_metrics.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert(loadingMetrics),
        );
      }
      final Object? notationMetrics = data['ai_notation_metrics'];
      if (notationMetrics != null) {
        await Directory('build').create(recursive: true);
        await File('build/ai_notation_metrics.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert(notationMetrics),
        );
      }
      const String suffix = '_timeline';
      for (final MapEntry<String, dynamic> entry in data.entries) {
        if (!entry.key.endsWith(suffix)) {
          continue;
        }
        final String scenario = entry.key.substring(
          0,
          entry.key.length - suffix.length,
        );
        final driver.Timeline timeline = driver.Timeline.fromJson(
          entry.value as Map<String, dynamic>,
        );
        final driver.TimelineSummary summary = driver.TimelineSummary.summarize(
          timeline,
        );
        await summary.writeTimelineToFile(
          '${scenario}_performance',
          pretty: true,
          includeSummary: true,
        );
      }
    },
  );
}
