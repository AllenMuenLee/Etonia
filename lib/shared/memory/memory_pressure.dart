import 'package:flutter/widgets.dart';

/// Lets the app's own caches give memory back when the system runs low.
///
/// The engine turns Android's `onTrimMemory`, from running low onwards,
/// background included, and iOS's memory warnings into one signal.
/// Flutter's image cache already empties on it; what the app keeps of its
/// own, decoded PDF pages and pictures, library thumbnails and the editors
/// of notes out of view, listens here. Whatever is let go is made again
/// when it is next shown.
class MemoryPressure with WidgetsBindingObserver {
  MemoryPressure._();

  static final MemoryPressure instance = MemoryPressure._();

  final List<VoidCallback> _listeners = <VoidCallback>[];

  /// Calls [listener] whenever the system is low on memory.
  void addListener(VoidCallback listener) {
    if (_listeners.isEmpty) WidgetsBinding.instance.addObserver(this);
    _listeners.add(listener);
  }

  void removeListener(VoidCallback listener) {
    if (!_listeners.remove(listener)) return;
    if (_listeners.isEmpty) WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didHaveMemoryPressure() {
    // A listener may remove itself, or another, as it lets go.
    for (final VoidCallback listener in List<VoidCallback>.of(_listeners)) {
      if (_listeners.contains(listener)) listener();
    }
  }
}
