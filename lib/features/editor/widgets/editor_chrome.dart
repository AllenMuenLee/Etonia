import 'package:flutter/widgets.dart';

import '../audio/note_audio.dart';
import '../audio/stroke_replay_controller.dart';

/// What one editor puts in the top bar when something else owns the bar.
///
/// The bar is shared by every pane of a split window, so each editor hands
/// over its settings instead of building a bar of its own.
@immutable
class EditorChromeEntry {
  const EditorChromeEntry({
    required this.onSettings,
    required this.audioPlayer,
    required this.replayController,
    required this.onCloseReplay,
  });

  final VoidCallback onSettings;
  final NoteAudioPlayer audioPlayer;
  final StrokeReplayController replayController;
  final VoidCallback onCloseReplay;
}

/// Holds the [EditorChromeEntry] of every editor in a window, by note, for
/// the shared top bar to read the focused one's.
class EditorChromeHost extends ChangeNotifier {
  final Map<String, EditorChromeEntry> _entries = <String, EditorChromeEntry>{};
  bool _disposed = false;

  EditorChromeEntry? entryFor(String? noteId) => _entries[noteId];

  void publish(String noteId, EditorChromeEntry entry) {
    if (_disposed) return;
    _entries[noteId] = entry;
    notifyListeners();
  }

  /// Takes back [entry], unless the note has published a newer one since.
  void retract(String noteId, EditorChromeEntry entry) {
    if (_disposed || !identical(_entries[noteId], entry)) return;
    _entries.remove(noteId);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Tells an editor that its top bar is drawn by someone else, and where to
/// hand its controls.
class EditorChromeScope extends InheritedWidget {
  const EditorChromeScope({
    super.key,
    required this.host,
    required this.noteId,
    required super.child,
  });

  final EditorChromeHost host;
  final String noteId;

  static EditorChromeScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<EditorChromeScope>();

  @override
  bool updateShouldNotify(EditorChromeScope oldWidget) =>
      host != oldWidget.host || noteId != oldWidget.noteId;
}
