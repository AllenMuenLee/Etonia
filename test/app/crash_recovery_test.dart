import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/crash_recovery.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppErrorMonitor', () {
    test('tells listeners, but not of every error in a storm', () {
      DateTime now = DateTime(2026, 11, 2, 9);
      final AppErrorMonitor monitor = AppErrorMonitor(clock: () => now);
      addTearDown(monitor.dispose);
      int told = 0;
      monitor.addListener(() => told++);

      monitor.report();
      monitor.report();
      now = now.add(const Duration(seconds: 59));
      monitor.report();
      expect(told, 1);

      now = now.add(const Duration(seconds: 1));
      monitor.report();
      expect(told, 2);
    });

    test('hears uncaught errors and keeps the handlers before it', () {
      final FlutterExceptionHandler? framework = FlutterError.onError;
      addTearDown(() => FlutterError.onError = framework);
      final List<FlutterErrorDetails> earlier = <FlutterErrorDetails>[];
      FlutterError.onError = earlier.add;

      final AppErrorMonitor monitor = AppErrorMonitor(
        minimumGap: Duration.zero,
      );
      addTearDown(monitor.dispose);
      int told = 0;
      monitor.addListener(() => told++);
      monitor.install();

      FlutterError.onError!(
        FlutterErrorDetails(exception: Exception('Build failed')),
      );
      expect(told, 1);
      expect(earlier, hasLength(1));

      // Expected ones, such as an image that won't load, are not a crash.
      FlutterError.onError!(
        FlutterErrorDetails(exception: Exception('No image'), silent: true),
      );
      expect(told, 1);
      expect(earlier, hasLength(2));
    });
  });

  group('UncleanExitMarker', () {
    late Directory directory;
    late File file;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('marker');
      file = File('${directory.path}/running.marker');
    });

    tearDown(() => directory.deleteSync(recursive: true));

    test('a first run was not a crash, and marks the app as running', () {
      final UncleanExitMarker marker = UncleanExitMarker(file);
      addTearDown(marker.dispose);
      expect(marker.begin(), isFalse);
      expect(file.existsSync(), isTrue);
    });

    test('a run that ended in front of the person was a crash', () {
      file.createSync();
      final UncleanExitMarker marker = UncleanExitMarker(file);
      addTearDown(marker.dispose);
      expect(marker.begin(), isTrue);
    });

    test('a run that went to the background first was not', () {
      final UncleanExitMarker first = UncleanExitMarker(file);
      first.begin();
      first.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(file.existsSync(), isTrue);
      first.didChangeAppLifecycleState(AppLifecycleState.hidden);
      expect(file.existsSync(), isFalse);
      first.didChangeAppLifecycleState(AppLifecycleState.paused);
      WidgetsBinding.instance.removeObserver(first);

      final UncleanExitMarker second = UncleanExitMarker(file);
      addTearDown(second.dispose);
      expect(second.begin(), isFalse);
    });

    test('coming back to the app marks it as running again', () {
      final UncleanExitMarker marker = UncleanExitMarker(file);
      addTearDown(marker.dispose);
      marker.begin();
      marker.didChangeAppLifecycleState(AppLifecycleState.paused);
      marker.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(file.existsSync(), isTrue);
    });

    test('a marker that cannot be written costs nothing', () {
      final UncleanExitMarker marker = UncleanExitMarker(
        // A file where the folder should be.
        File('${(File('${directory.path}/plain')..createSync()).path}/x'),
      );
      addTearDown(marker.dispose);
      expect(marker.begin(), isFalse);
    });
  });
}
