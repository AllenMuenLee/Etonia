import 'dart:async';

import 'package:flutter/widgets.dart';

import 'google_drive_backup_service.dart';
import 'google_drive_client.dart';

/// Backs the library up to Google Drive on its own, every [interval], while
/// the app runs.
///
/// A backup is made when the last one is at least [interval] old and the
/// library has changed since this scheduler last backed it up. Nothing is
/// tried until the user has connected Google Drive on this device, and a
/// session is only ever restored without asking. Failures are left for the
/// next turn.
///
/// [backUpSoon] asks for one ahead of the schedule, on leaving an edited note
/// or when the app may be going down. Turning automatic backup off stops
/// those too.
class AutoBackupScheduler with WidgetsBindingObserver {
  AutoBackupScheduler({
    required this.backup,
    required this.client,
    required this.library,
    DateTime Function()? clock,
    this.minimumDelay = const Duration(seconds: 30),
    this.soonDelay = const Duration(seconds: 2),
  }) : _clock = clock ?? DateTime.now;

  static const Duration defaultInterval = Duration(minutes: 15);

  /// [Duration.zero] turns automatic backup off.
  static const Duration off = Duration.zero;

  /// The intervals offered, shortest first, then off.
  static const List<Duration> choices = <Duration>[
    Duration(minutes: 5),
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(hours: 1),
    Duration(hours: 4),
    Duration(days: 1),
    off,
  ];

  static const String _intervalKey = 'autoBackupMinutes';

  final GoogleDriveBackupService backup;
  final GoogleDriveClient client;

  /// Notifies when the library changes.
  final Listenable library;

  /// The least wait before a check, so one does not run straight after
  /// launch or on every return to the app.
  final Duration minimumDelay;

  /// How long [backUpSoon] waits, so several requests make one backup.
  final Duration soonDelay;
  final DateTime Function() _clock;

  /// How often to back up; [off] when it does not.
  final ValueNotifier<Duration> interval = ValueNotifier<Duration>(
    defaultInterval,
  );

  Timer? _timer;
  Timer? _soonTimer;
  Future<void>? _intervalRead;

  /// Asked for another while one was running.
  bool _soonAgain = false;
  bool _started = false;
  bool _disposed = false;
  bool _running = false;

  /// Whether the library may have changed since the last automatic backup.
  /// Changes from before launch are not known, so it starts true.
  bool _dirty = true;

  static String describe(Duration interval) {
    if (interval == off) return 'Off';
    if (interval.inDays >= 1 && interval.inHours % 24 == 0) {
      return interval.inDays == 1
          ? 'Once a day'
          : 'Every ${interval.inDays} days';
    }
    if (interval.inHours >= 1 && interval.inMinutes % 60 == 0) {
      return interval.inHours == 1
          ? 'Every hour'
          : 'Every ${interval.inHours} hours';
    }
    return interval.inMinutes == 1
        ? 'Every minute'
        : 'Every ${interval.inMinutes} minutes';
  }

  /// Reads the chosen interval and starts the schedule.
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    library.addListener(_markDirty);
    WidgetsBinding.instance.addObserver(this);
    await (_intervalRead = _readInterval());
    await reschedule();
  }

  Future<void> _readInterval() async {
    final Object? minutes = (await backup.state.read())[_intervalKey];
    if (_disposed) return;
    if (minutes is int && minutes >= 0) {
      interval.value = Duration(minutes: minutes);
    }
  }

  /// Backs up in [soonDelay] rather than when next due, if the library has
  /// changed since the last automatic backup.
  void backUpSoon() {
    if (_disposed || !_started) return;
    if (_running) {
      _soonAgain = true;
      return;
    }
    _soonTimer?.cancel();
    _soonTimer = Timer(soonDelay, _backUpNow);
  }

  Future<void> _backUpNow() async {
    _soonTimer = null;
    await _intervalRead;
    if (_disposed || _running || interval.value == off || !_dirty) return;
    await _backUpIfConnected();
    if (_disposed) return;
    if (_soonAgain) {
      _soonAgain = false;
      backUpSoon();
    }
    // A turn that came up during this one found it busy.
    if (_timer == null) await reschedule();
  }

  /// Backs up, when this destination is the one chosen and can be reached
  /// without asking.
  Future<void> _backUpIfConnected() async {
    if (!await backup.isLinked()) return;
    final GoogleDriveAccount? account =
        client.currentAccount ?? await client.restoreSession();
    if (_disposed || _running || account == null) return;
    _running = true;
    // Changes made while it runs are for the next one.
    _dirty = false;
    try {
      await backup.backUp();
    } on Object {
      _dirty = true;
    } finally {
      _running = false;
    }
  }

  /// Backs up every [every] from now on, or stops for [off].
  Future<void> setInterval(Duration every) async {
    interval.value = every;
    await backup.state.update((Map<String, Object?> values) {
      values[_intervalKey] = every.inMinutes;
    });
    await reschedule();
  }

  /// Times the next check from when the last backup was made.
  Future<void> reschedule() async {
    _timer?.cancel();
    _timer = null;
    if (_disposed || !_started || interval.value == off) return;
    final DateTime? last = await backup.lastBackupAt();
    if (_disposed) return;
    final Duration due = last == null
        ? Duration.zero
        : last.add(interval.value).difference(_clock());
    _wait(due);
  }

  void _wait(Duration delay) {
    _timer?.cancel();
    if (_disposed || interval.value == off) return;
    _timer = Timer(delay < minimumDelay ? minimumDelay : delay, _check);
  }

  void _markDirty() => _dirty = true;

  Future<void> _check() async {
    _timer = null;
    if (_disposed) return;
    final Duration every = interval.value;
    if (every == off) return;
    if (_running) {
      _wait(every);
      return;
    }
    final DateTime? last = await backup.lastBackupAt();
    if (_disposed) return;
    if (last != null) {
      final Duration age = _clock().difference(last);
      if (age < every) {
        _wait(every - age);
        return;
      }
    }
    if (!_dirty && last != null) {
      _wait(every);
      return;
    }
    await _backUpIfConnected();
    if (_disposed) return;
    _wait(every);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Timers do not run while the app is suspended; catch up on return.
    if (state == AppLifecycleState.resumed && !_running) {
      reschedule();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _soonTimer?.cancel();
    _soonTimer = null;
    if (_started) {
      library.removeListener(_markDirty);
      WidgetsBinding.instance.removeObserver(this);
    }
    interval.dispose();
  }
}
