import 'package:flutter/foundation.dart';

import '../../app/theme/app_tokens.dart';
import '../memory/memory_pressure.dart';

/// What has been shown this session, so each transition can be paced by it.
///
/// Before a transition plays, it looks up what it is about to show with
/// [recall]: the first showing is still being read and arrives slowly and
/// smoothly ([MotionPace.first]); a later one comes from memory and arrives
/// quickly ([MotionPace.revisit]). A key is any value naming what is shown,
/// such as `('folder', id)` or `('dialog', 'rename')`.
///
/// Nothing is ever forgotten for being old or for there being many: keys
/// are let go only when the system runs low on memory, the same moment the
/// app's caches give back what they hold, so what must be read again is
/// paced as a first showing again.
class MotionMemory {
  MotionMemory._();

  static final MotionMemory instance = MotionMemory._();

  final Set<Object> _seen = <Object>{};
  bool _listening = false;

  /// Whether [key] has been shown and is still remembered.
  bool hasSeen(Object key) => _seen.contains(key);

  /// The pace to show [key] at, then remembers it as shown.
  MotionPace recall(Object key) {
    _listen();
    return _seen.add(key) ? MotionPace.first : MotionPace.revisit;
  }

  /// The pace to show [key] at, without remembering it: for a transition
  /// that may yet not play.
  MotionPace peek(Object key) =>
      _seen.contains(key) ? MotionPace.revisit : MotionPace.first;

  /// Remembers [key] as shown, as when it was loaded without a transition.
  void remember(Object key) {
    _listen();
    _seen.add(key);
  }

  /// [key]'s cache was let go: its next showing is a first one again.
  void forget(Object key) => _seen.remove(key);

  /// Forgets every key [test] accepts.
  void forgetWhere(bool Function(Object key) test) => _seen.removeWhere(test);

  void _listen() {
    if (_listening) return;
    _listening = true;
    MemoryPressure.instance.addListener(_seen.clear);
  }

  @visibleForTesting
  void reset() => _seen.clear();
}
