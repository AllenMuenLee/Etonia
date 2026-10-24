import 'package:flutter/foundation.dart';

import 'library_models.dart';

/// The notes open in tabs, in tab order, and which ones are shown across split panes.
/// A window is one pane, or two side by side once a tab is dropped on the
/// window's left or right. Like two separate browser windows, each pane of a
/// split holds tabs of its own.
class OpenNotes extends ChangeNotifier {
  /// Panes side by side, at most.
  static const int maxPanes = 2;

  /// The note whose tab is being dragged toward a side of the window, if any.
  final ValueNotifier<String?> draggedTab = ValueNotifier<String?>(null);

  final List<NoteEntry> _notes = <NoteEntry>[];
  int _active = 0;
  int _splitCount = 1;
  int _focusedPane = 0;
  final List<String?> _paneNoteIds = <String?>[null, null, null, null];

  /// The pane each tab belongs to; only meaningful in a split.
  final Map<String, int> _home = <String, int>{};

  List<NoteEntry> get notes => List<NoteEntry>.unmodifiable(_notes);

  bool get isEmpty => _notes.isEmpty;

  /// The index of the tab shown in the focused pane; meaningless while [isEmpty].
  int get activeIndex => _active;

  NoteEntry? get active => _notes.isEmpty ? null : _notes[_active];

  /// Number of panes active in split view (1 or [maxPanes]).
  int get splitCount => _splitCount;

  /// Whether more than one pane is currently displayed.
  bool get isSplit => _splitCount > 1;

  /// The index of the currently focused pane (0 to [splitCount] - 1).
  int get focusedPane => _focusedPane;

  /// The note IDs currently shown in each split pane.
  List<String?> get paneNoteIds =>
      List<String?>.unmodifiable(_paneNoteIds.take(_splitCount));

  /// The [NoteEntry] in each split pane, or null if the pane is empty.
  List<NoteEntry?> get paneNotes {
    return List<NoteEntry?>.generate(_splitCount, (int i) {
      final String? id = _paneNoteIds[i];
      if (id == null) return null;
      final int idx = _indexOf(id);
      return idx >= 0 ? _notes[idx] : null;
    });
  }

  /// All unique non-null note IDs currently shown in split panes.
  List<String> get visibleNoteIds =>
      _paneNoteIds.take(_splitCount).whereType<String>().toSet().toList();

  /// The pane that is showing [id], if any.
  int? paneOf(String id) {
    for (int i = 0; i < _splitCount; i++) {
      if (_paneNoteIds[i] == id) return i;
    }
    return null;
  }

  bool isNoteInPane(String id) => paneOf(id) != null;

  /// The tabs of [pane], in tab order. With no [pane], or no split, all of
  /// them.
  List<NoteEntry> tabsOf(int? pane) {
    if (pane == null || !isSplit) return notes;
    return <NoteEntry>[
      for (final NoteEntry note in _notes)
        if (_homeOf(note.id) == pane) note,
    ];
  }

  int _homeOf(String id) => _splitCount > 1 ? (_home[id] ?? 0) : 0;

  int _indexOf(String id) => _notes.indexWhere((NoteEntry n) => n.id == id);

  /// Leaves one pane, which keeps what it shows and gains every tab.
  void _collapseTo(int pane) {
    final String? keep = _paneNoteIds[pane];
    _splitCount = 1;
    _focusedPane = 0;
    _paneNoteIds.fillRange(0, 4, null);
    _paneNoteIds[0] = keep;
    _home.clear();
  }

  void _syncPanes() {
    _splitCount = _splitCount.clamp(1, maxPanes);
    if (_notes.isEmpty) {
      _paneNoteIds.fillRange(0, 4, null);
      _home.clear();
      _splitCount = 1;
      _active = 0;
      _focusedPane = 0;
      return;
    }
    final Set<String> ids = <String>{for (final NoteEntry n in _notes) n.id};
    _home.removeWhere((String id, int _) => !ids.contains(id));
    for (final String id in ids) {
      _home.putIfAbsent(id, () => _splitCount > 1 ? _focusedPane : 0);
    }

    // A window with a pane that has no tabs left is a single pane again.
    if (_splitCount > 1) {
      for (int pane = 0; pane < _splitCount; pane++) {
        if (!_home.values.contains(pane)) {
          _collapseTo(1 - pane);
          break;
        }
      }
    }
    _focusedPane = _focusedPane.clamp(0, _splitCount - 1);

    // What a pane shows must be one of its own tabs, and shown only once.
    final Set<String> seen = <String>{};
    for (int i = 0; i < _splitCount; i++) {
      final String? id = _paneNoteIds[i];
      if (id == null ||
          !ids.contains(id) ||
          _homeOf(id) != i ||
          seen.contains(id)) {
        _paneNoteIds[i] = null;
      } else {
        seen.add(id);
      }
    }
    for (int i = 0; i < _splitCount; i++) {
      if (_paneNoteIds[i] != null) continue;
      for (final NoteEntry note in _notes) {
        if (_homeOf(note.id) == i && !seen.contains(note.id)) {
          _paneNoteIds[i] = note.id;
          seen.add(note.id);
          break;
        }
      }
    }

    // Keep _active in sync with the focused pane.
    final String? focusedId = _paneNoteIds[_focusedPane];
    final int idx = focusedId == null ? -1 : _indexOf(focusedId);
    _active = idx >= 0 ? idx : _active.clamp(0, _notes.length - 1);
  }

  /// Sets the number of split panes: one, or two when there are two notes to
  /// show. The second pane takes the first note the first is not showing.
  void setSplitCount(int count) {
    final int target = count.clamp(1, maxPanes);
    if (target == _splitCount) return;
    if (target == 1) {
      _collapseTo(_focusedPane);
    } else {
      if (_notes.length < 2) return;
      final String? shown = _paneNoteIds[0];
      final NoteEntry other = _notes.firstWhere((NoteEntry n) => n.id != shown);
      _splitCount = 2;
      _home.clear();
      _home[other.id] = 1;
      _paneNoteIds[1] = other.id;
    }
    _syncPanes();
    notifyListeners();
  }

  /// Moves [id] into the left or right pane, which a tab dropped on that
  /// side of the window asks for. A single pane becomes two: the dropped tab
  /// alone on its side, every other tab on the opposite side. In a split,
  /// the tab leaves its old pane for the one it is dropped on.
  void splitWith(String id, {required bool right}) {
    if (_indexOf(id) < 0) return;
    final int side = right ? 1 : 0;
    if (_splitCount == 1) {
      if (_notes.length < 2) return;
      final String? shown = _paneNoteIds[0];
      final String partner = shown != null && shown != id
          ? shown
          : _notes.firstWhere((NoteEntry n) => n.id != id).id;
      _splitCount = 2;
      _home.clear();
      for (final NoteEntry n in _notes) {
        _home[n.id] = n.id == id ? side : 1 - side;
      }
      _paneNoteIds.fillRange(0, 4, null);
      _paneNoteIds[side] = id;
      _paneNoteIds[1 - side] = partner;
    } else {
      final int from = _homeOf(id);
      _home[id] = side;
      _paneNoteIds[side] = id;
      if (from != side && _paneNoteIds[from] == id) _paneNoteIds[from] = null;
    }
    _focusedPane = side;
    _syncPanes();
    notifyListeners();
  }

  /// Shows [id] in [pane], which a tap on a tab in that pane's own strip
  /// asks for. The note must be one of that pane's tabs.
  void showInPane(int pane, String id) {
    if (pane < 0 || pane >= _splitCount || _indexOf(id) < 0) return;
    if (_homeOf(id) != pane) return;
    _paneNoteIds[pane] = id;
    _focusedPane = pane;
    _syncPanes();
    notifyListeners();
  }

  /// Focuses a specific pane index.
  void focusPane(int index) {
    if (index < 0 || index >= _splitCount || index == _focusedPane) return;
    _focusedPane = index;
    final String? noteId = _paneNoteIds[index];
    if (noteId != null) {
      final int idx = _indexOf(noteId);
      if (idx >= 0) _active = idx;
    }
    notifyListeners();
  }

  /// Puts a pane away. The other pane keeps what it shows and gains the
  /// tabs of the one closed.
  void closePane(int index) {
    if (_splitCount <= 1 || index < 0 || index >= _splitCount) return;
    _collapseTo(1 - index);
    _syncPanes();
    notifyListeners();
  }

  /// Shows [note], opening a tab for it after the current one if it has
  /// none yet. A new tab opens in the focused pane.
  void open(NoteEntry note) {
    final int existing = _indexOf(note.id);
    if (existing >= 0) {
      activate(existing);
      return;
    }
    final int at = _notes.isEmpty ? 0 : _active + 1;
    _notes.insert(at, note);
    _home[note.id] = _splitCount > 1 ? _focusedPane : 0;
    _paneNoteIds[_focusedPane] = note.id;
    _active = at;
    _syncPanes();
    notifyListeners();
  }

  /// Shows the tab at [index] in the pane that holds it.
  void activate(int index) {
    if (index < 0 || index >= _notes.length) {
      return;
    }
    final String id = _notes[index].id;
    final int pane = _homeOf(id);
    _paneNoteIds[pane] = id;
    _focusedPane = pane;
    _active = index;
    _syncPanes();
    notifyListeners();
  }

  /// Closes the tab for [id]. The tab after it in its pane, or else the one
  /// before, is shown when it was the shown one.
  void close(String id) {
    final int index = _indexOf(id);
    if (index < 0) {
      return;
    }
    final int? shownIn = paneOf(id);
    if (shownIn != null) {
      final List<NoteEntry> tabs = tabsOf(shownIn);
      final int at = tabs.indexWhere((NoteEntry n) => n.id == id);
      final int next = at + 1 < tabs.length ? at + 1 : at - 1;
      _paneNoteIds[shownIn] = next >= 0 ? tabs[next].id : null;
    }
    _notes.removeAt(index);
    _home.remove(id);
    _syncPanes();
    notifyListeners();
  }

  @override
  void dispose() {
    draggedTab.dispose();
    super.dispose();
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
    _syncPanes();
    notifyListeners();
  }
}
