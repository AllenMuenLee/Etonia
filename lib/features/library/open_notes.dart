import 'package:flutter/foundation.dart';

import 'library_models.dart';

/// The notes open in tabs, in tab order, and which one is shown. They stay
/// open on the way back to the library, so opening another note adds a tab
/// beside them.
class OpenNotes extends ChangeNotifier {
  final List<NoteEntry> _notes = <NoteEntry>[];
  int _active = 0;

  List<NoteEntry> get notes => List<NoteEntry>.unmodifiable(_notes);

  bool get isEmpty => _notes.isEmpty;

  /// The index of the tab shown; meaningless while [isEmpty].
  int get activeIndex => _active;

  NoteEntry? get active => _notes.isEmpty ? null : _notes[_active];

  int _indexOf(String id) => _notes.indexWhere((NoteEntry n) => n.id == id);

  /// Shows [note], opening a tab for it after the current one if it has
  /// none yet.
  void open(NoteEntry note) {
    final int existing = _indexOf(note.id);
    if (existing >= 0) {
      _active = existing;
    } else {
      final int at = _notes.isEmpty ? 0 : _active + 1;
      _notes.insert(at, note);
      _active = at;
    }
    notifyListeners();
  }

  void activate(int index) {
    if (index < 0 || index >= _notes.length || index == _active) {
      return;
    }
    _active = index;
    notifyListeners();
  }

  /// Closes the tab for [id]. The tab after it, or else the one before,
  /// is shown when it was the shown one.
  void close(String id) {
    final int index = _indexOf(id);
    if (index < 0) {
      return;
    }
    _notes.removeAt(index);
    if (index < _active || _active >= _notes.length) {
      _active = (_active - 1).clamp(0, _notes.length);
    }
    if (_notes.isEmpty) {
      _active = 0;
    }
    notifyListeners();
  }

  /// Keeps a tab's note up to date, as when it is renamed.
  void update(NoteEntry note) {
    final int index = _indexOf(note.id);
    if (index < 0) {
      return;
    }
    _notes[index] = note;
    notifyListeners();
  }

  /// Forgets notes that no longer exist, as when they were deleted.
  void retainWhere(bool Function(NoteEntry note) keep) {
    final NoteEntry? shown = active;
    _notes.retainWhere(keep);
    final int index = shown == null ? -1 : _indexOf(shown.id);
    _active = index >= 0 ? index : 0;
    notifyListeners();
  }
}
