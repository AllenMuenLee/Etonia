import 'package:flutter/foundation.dart';

import 'library_models.dart';

/// The notes open in tabs, in tab order.
class OpenNotes extends ChangeNotifier {
  final List<NoteEntry> _notes = <NoteEntry>[];
  int _active = 0;

  List<NoteEntry> get notes => List<NoteEntry>.unmodifiable(_notes);

  bool get isEmpty => _notes.isEmpty;

  /// The index of the tab shown; meaningless while [isEmpty].
  int get activeIndex => _active;

  NoteEntry? get active => _notes.isEmpty ? null : _notes[_active];

  /// The note ID currently visible, if any.
  List<String> get visibleNoteIds =>
      active != null ? <String>[active!.id] : const <String>[];

  int _indexOf(String id) => _notes.indexWhere((NoteEntry n) => n.id == id);

  /// Shows [note], opening a tab for it after the current one if it has
  /// none yet.
  void open(NoteEntry note) {
    final int existing = _indexOf(note.id);
    if (existing >= 0) {
      activate(existing);
      return;
    }
    final int at = _notes.isEmpty ? 0 : _active + 1;
    _notes.insert(at, note);
    _active = at;
    notifyListeners();
  }

  /// Shows the tab at [index].
  void activate(int index) {
    if (index < 0 || index >= _notes.length) {
      return;
    }
    _active = index;
    notifyListeners();
  }

  /// Closes the tab for [id]. The tab after it, or else the one before, is shown
  /// when it was the shown one.
  void close(String id) {
    final int index = _indexOf(id);
    if (index < 0) {
      return;
    }
    _notes.removeAt(index);
    if (_notes.isEmpty) {
      _active = 0;
    } else if (_active >= _notes.length) {
      _active = _notes.length - 1;
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
    _notes.retainWhere(keep);
    if (_notes.isEmpty) {
      _active = 0;
    } else if (_active >= _notes.length) {
      _active = _notes.length - 1;
    }
    notifyListeners();
  }
}
