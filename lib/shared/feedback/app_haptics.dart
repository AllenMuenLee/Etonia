import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What a haptic means, not how it feels. Call sites name the moment; the
/// mapping to the device's vocabulary lives in one place below.
enum AppHaptic {
  /// A tool, color, or option became the active one.
  toolSwitch,

  /// A light tap on a control that does not change mode.
  tap,

  /// Something was picked up, such as the palette lifted to be moved.
  lift,

  /// A background task finished well: an export, an import, an answer.
  success,

  /// A task failed, or an action was refused.
  error,
}

/// Plays [AppHaptic]s on the device. Replace [performer] to route them
/// elsewhere, such as a recorder in tests or a native bridge with richer
/// patterns than the platform channel offers.
abstract final class AppHaptics {
  static Future<void> Function(AppHaptic haptic) performer = platform;

  /// Set false to silence every haptic, such as from a user setting.
  static bool enabled = true;

  static void play(AppHaptic haptic) {
    if (!enabled) return;
    // Haptics are fire-and-forget: a platform without them is not an error.
    performer(haptic).catchError((Object _) {});
  }

  static void toolSwitch() => play(AppHaptic.toolSwitch);
  static void tap() => play(AppHaptic.tap);
  static void lift() => play(AppHaptic.lift);
  static void success() => play(AppHaptic.success);
  static void error() => play(AppHaptic.error);

  /// The platform channel's haptics. iOS plays the notification patterns
  /// natively; Android approximates them.
  static Future<void> platform(AppHaptic haptic) {
    return switch (haptic) {
      AppHaptic.toolSwitch => HapticFeedback.selectionClick(),
      AppHaptic.tap => HapticFeedback.lightImpact(),
      AppHaptic.lift => HapticFeedback.mediumImpact(),
      AppHaptic.success => HapticFeedback.successNotification(),
      AppHaptic.error => HapticFeedback.errorNotification(),
    };
  }

  /// Restores the defaults; for tests.
  @visibleForTesting
  static void reset() {
    performer = platform;
    enabled = true;
  }
}
