import 'dart:async';

import 'package:flutter/services.dart';

/// The system's bars as the app wants them: all of them in the library; in
/// a note, the navigation bar only, the status bar with its time and battery
/// put away; and in fullscreen, none.
abstract final class SystemBars {
  /// How long a bar pulled back by a swipe stays before it goes again.
  static const Duration _peek = Duration(seconds: 2);

  static Timer? _rehide;

  /// Whether some bar is meant to be hidden, so that one a swipe brings
  /// back should go again.
  static bool _hiding = false;

  /// Watches for swipes that bring a hidden bar back, and shows every bar,
  /// as the app opens in the library.
  static void install() {
    unawaited(SystemChrome.setSystemUIChangeCallback(_onChanged));
    showAll();
  }

  /// Every bar, as in the library.
  static void showAll() {
    _hiding = false;
    _rehide?.cancel();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  }

  /// Only the navigation bar, as in a note.
  static void showNavigation() {
    _hiding = true;
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: const <SystemUiOverlay>[SystemUiOverlay.bottom],
      ),
    );
  }

  /// Every bar away, for fullscreen.
  static void hideAll() {
    _hiding = true;
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
  }

  static Future<void> _onChanged(bool barsVisible) async {
    _rehide?.cancel();
    if (!barsVisible || !_hiding) return;
    // Whichever mode was asked for last comes back.
    _rehide = Timer(_peek, SystemChrome.restoreSystemUIOverlays);
  }
}
