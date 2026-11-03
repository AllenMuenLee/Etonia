import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Tells listeners that an uncaught Dart error happened, which may be the
/// last chance to save and back up. Errors can repeat every frame, so it
/// tells them at most once per [minimumGap].
///
/// A native crash or the system ending the app runs no Dart at all;
/// [UncleanExitMarker] catches those on the next launch.
class AppErrorMonitor extends ChangeNotifier {
  AppErrorMonitor({
    this.minimumGap = const Duration(minutes: 1),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static final AppErrorMonitor instance = AppErrorMonitor();

  final Duration minimumGap;
  final DateTime Function() _clock;
  DateTime? _last;

  /// Listens for uncaught errors, leaving whatever handled them before to go
  /// on doing so.
  void install() {
    final FlutterExceptionHandler? framework = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      framework?.call(details);
      // Silent errors are expected ones, such as an image that won't load.
      if (!details.silent) report();
    };
    final ErrorCallback? platform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      report();
      return platform?.call(error, stack) ?? false;
    };
  }

  void report() {
    final DateTime now = _clock();
    final DateTime? last = _last;
    if (last != null && now.difference(last) < minimumGap) return;
    _last = now;
    notifyListeners();
  }
}

/// A file present while the app is in front, so finding it on launch means
/// the last run ended without going to the background: it crashed.
///
/// Being closed by the person or by the system while in the background
/// passes through the background first, so neither counts.
class UncleanExitMarker with WidgetsBindingObserver {
  UncleanExitMarker(this.file);

  final File file;
  bool _begun = false;

  /// Starts watching, and answers whether the last run crashed.
  bool begin() {
    if (_begun) return false;
    _begun = true;
    final bool crashed = _exists();
    _set(true);
    WidgetsBinding.instance.addObserver(this);
    return crashed;
  }

  bool _exists() {
    try {
      return file.existsSync();
    } on Object {
      return false;
    }
  }

  // Synchronous: the app may be suspended right after going to the
  // background, and the file is empty.
  void _set(bool present) {
    try {
      if (present) {
        file.createSync(recursive: true);
      } else if (file.existsSync()) {
        file.deleteSync();
      }
    } on Object {
      // At worst a crash goes unnoticed, or a clean exit gets a backup.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _set(true);
      case AppLifecycleState.hidden ||
          AppLifecycleState.paused ||
          AppLifecycleState.detached:
        _set(false);
      case AppLifecycleState.inactive:
        break;
    }
  }

  void dispose() {
    if (!_begun) return;
    WidgetsBinding.instance.removeObserver(this);
    _set(false);
  }
}
