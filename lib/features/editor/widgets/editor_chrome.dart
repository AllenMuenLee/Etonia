import 'package:flutter/widgets.dart';

import '../ink/eraser_settings.dart';

/// What a tab keeps of the toolbar: the toolbar itself is one element for
/// the whole window, handed to whichever editor is in front, and each tab
/// keeps only this, as data, while another has it.
@immutable
class ToolbarMemo {
  const ToolbarMemo({required this.tool, required this.expanded});

  /// The tool chosen in the tab.
  final EditorTool tool;

  /// Whether the toolbar was unfolded in the tab.
  final bool expanded;

  @override
  bool operator ==(Object other) =>
      other is ToolbarMemo && other.tool == tool && other.expanded == expanded;

  @override
  int get hashCode => Object.hash(tool, expanded);
}

/// What one editor puts in the top bar when something else owns the bar.
///
/// The top bar is shared by open tabs, so each editor hands
/// over its settings instead of building a bar of its own.
@immutable
class EditorChromeEntry {
  const EditorChromeEntry({required this.onSettings});

  final VoidCallback onSettings;
}

/// Holds the [EditorChromeEntry] of every editor in a window, by note, for
/// the shared top bar to read the focused one's.
class EditorChromeHost extends ChangeNotifier {
  final Map<String, EditorChromeEntry> _entries = <String, EditorChromeEntry>{};
  final Map<String, ToolbarMemo> _toolbars = <String, ToolbarMemo>{};
  bool _disposed = false;

  EditorChromeEntry? entryFor(String? noteId) => _entries[noteId];

  /// What the tab of [noteId] last had on the toolbar, if anything. It
  /// outlives the tab's editor, which may be put away while out of view.
  ToolbarMemo? toolbarOf(String noteId) => _toolbars[noteId];

  /// Keeps [memo] for the tab of [noteId]. Nothing is redrawn for it.
  void rememberToolbar(String noteId, ToolbarMemo memo) {
    if (_disposed) return;
    _toolbars[noteId] = memo;
  }

  /// The tabs of notes not in [noteIds] are closed: what they kept goes.
  void retainToolbars(Set<String> noteIds) =>
      _toolbars.removeWhere((String id, _) => !noteIds.contains(id));

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

/// Tells an editor whether it shows the window's one toolbar. Kept apart
/// from [EditorChromeScope] so that the toolbar passing between tabs
/// rebuilds only [EditorToolbarSlot], never the editors.
class EditorToolbarScope extends InheritedWidget {
  const EditorToolbarScope({
    super.key,
    this.toolbarKey,
    this.showsToolbar = true,
    required super.child,
  });

  /// The window's toolbar, given to the editor in front: its whole element
  /// moves from editor to editor rather than being built again, and only
  /// the tab's [ToolbarMemo] changes. Null for an editor not in front.
  final GlobalKey? toolbarKey;

  /// Whether the editor shows a toolbar at all. One out of view does not:
  /// it keeps its [ToolbarMemo] instead.

  final bool showsToolbar;

  static EditorToolbarScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<EditorToolbarScope>();

  @override
  bool updateShouldNotify(EditorToolbarScope oldWidget) =>
      toolbarKey != oldWidget.toolbarKey ||
      showsToolbar != oldWidget.showsToolbar;
}

/// Tells an editor whether the window is fullscreen: the top bar and its
/// tabs put away, the page reaching the top of the screen. The editor then
/// offers [onExit] itself, as nothing else on screen can bring the bar back.
/// Always in the tree, so entering fullscreen never rebuilds an editor's
/// state from scratch.
class EditorFullscreenScope extends InheritedWidget {
  const EditorFullscreenScope({
    super.key,
    this.onExit,
    this.settled,
    required super.child,
  });

  /// Brings the top bar back; null while it is showing.
  final VoidCallback? onExit;

  /// Fires when the page has finished sliding with the bar, and has come to
  /// rest somewhere new on the screen without being laid out.
  final Listenable? settled;

  static EditorFullscreenScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<EditorFullscreenScope>();

  @override
  bool updateShouldNotify(EditorFullscreenScope oldWidget) =>
      onExit != oldWidget.onExit || settled != oldWidget.settled;
}

/// Where an editor's toolbar goes:[builder] with the window's toolbar key
/// when this editor holds it, nothing when the editor is out of view.
class EditorToolbarSlot extends StatelessWidget {
  const EditorToolbarSlot({super.key, required this.builder});

  final Widget Function(GlobalKey? toolbarKey) builder;

  @override
  Widget build(BuildContext context) {
    final EditorToolbarScope? scope = EditorToolbarScope.maybeOf(context);
    if (!(scope?.showsToolbar ?? true)) return const SizedBox.shrink();
    return builder(scope?.toolbarKey);
  }
}
