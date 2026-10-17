import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import 'library_models.dart';
import 'note_tab_strip.dart';
import 'open_notes.dart';

/// Cheap restoration data survives eviction; no document or bitmap lives here.
class NoteTabLease {
  int currentPage = 0;
  Future<bool> Function()? prepareToEvict;
  Future<bool> Function()? prepareToClose;
  VoidCallback? onReady;
}

class NoteTabScope extends InheritedWidget {
  const NoteTabScope({super.key, required this.lease, required super.child});
  final NoteTabLease lease;

  static NoteTabLease? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NoteTabScope>()?.lease;

  @override
  bool updateShouldNotify(NoteTabScope oldWidget) => lease != oldWidget.lease;
}

/// What one tab shows: its note's editor, given the tabs for its top bar,
/// how to leave for the library, and what to do once it is renamed.
typedef NoteTabBuilder =
    Widget Function(
      NoteEntry note,
      Widget Function(VoidCallback rename) tabs,
      VoidCallback onBack,
      ValueChanged<NoteEntry> onRenamed,
    );

/// A small LRU of warm editors. Cold tabs keep only cheap restoration data;
/// sessions with non-persisted state are safety-pinned until closed.
class NoteTabsPage extends StatefulWidget {
  const NoteTabsPage({
    super.key,
    required this.notes,
    required this.builder,
    this.onBack,
    this.warmCapacity = 3,
  }) : assert(warmCapacity > 0);

  final OpenNotes notes;
  final NoteTabBuilder builder;
  final VoidCallback? onBack;

  /// Three recent editors, plus the outgoing transition and sessions that
  /// cannot safely be evicted (failed saves or non-persisted editing state).
  /// Safety pins deliberately take precedence over this soft budget.
  final int warmCapacity;

  @override
  State<NoteTabsPage> createState() => _NoteTabsPageState();
}

class _NoteTabsPageState extends State<NoteTabsPage> {
  String? _activeId;
  String? _outgoingId;
  Timer? _transition;
  final Map<String, NoteTabLease> _leases = {};
  final List<String> _warm = [];
  final Map<String, (NoteEntry, Widget)> _children = {};
  bool _trimming = false;

  @override
  void initState() {
    super.initState();
    _activeId = widget.notes.active?.id;
    if (_activeId != null) _warm.add(_activeId!);
    widget.notes.addListener(_onNotesChanged);
  }

  @override
  void dispose() {
    _transition?.cancel();
    widget.notes.removeListener(_onNotesChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(NoteTabsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.builder != widget.builder) _children.clear();
  }

  Widget _editorFor(NoteEntry note) {
    final cached = _children[note.id];
    if (cached != null && cached.$1 == note) return cached.$2;
    final child = widget.builder(note, _tabs, _back, widget.notes.update);
    _children[note.id] = (note, child);
    return child;
  }

  void _onNotesChanged() {
    if (!mounted) {
      return;
    }
    if (widget.notes.isEmpty) {
      _transition?.cancel();
      setState(() {
        _activeId = null;
        _outgoingId = null;
        _warm.clear();
        _leases.clear();
        _children.clear();
      });
      _back();
      return;
    }
    final ids = widget.notes.notes.map((note) => note.id).toSet();
    _warm.removeWhere((id) => !ids.contains(id));
    _leases.removeWhere((id, _) => !ids.contains(id));
    _children.removeWhere((id, _) => !ids.contains(id));
    final String? activeId = widget.notes.active?.id;
    if (activeId != _activeId) {
      final bool previousStillOpen = widget.notes.notes.any(
        (NoteEntry note) => note.id == _activeId,
      );
      _outgoingId = previousStillOpen ? _activeId : null;
      _activeId = activeId;
      _warm.remove(activeId);
      if (activeId != null) _warm.add(activeId);
      _transition?.cancel();
      final Duration duration = AppMotion.resolve(context, AppMotion.medium);
      if (_outgoingId != null && duration > Duration.zero) {
        _transition = Timer(duration, () {
          if (mounted) {
            setState(() => _outgoingId = null);
            unawaited(_trim());
          }
        });
      } else {
        _outgoingId = null;
      }
    }
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_trim());
    });
  }

  Future<void> _trim() async {
    if (_trimming) return;
    _trimming = true;
    try {
      for (final id in List<String>.of(_warm)) {
        if (_warm.length <= widget.warmCapacity) break;
        if (id == _activeId || id == _outgoingId) continue;
        final lease = _leases[id];
        final prepare = lease?.prepareToEvict;
        // Missing registration means the editor has not mounted yet.
        if (prepare == null || !await prepare()) continue;
        if (!mounted) return;
        // Saving is asynchronous: activation/close can happen meanwhile.
        if (id == _activeId || id == _outgoingId || _leases[id] != lease) {
          continue;
        }
        setState(() {
          _warm.remove(id);
          _children.remove(id);
        });
      }
    } finally {
      _trimming = false;
    }
  }

  void _queueTrim() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_trim());
    });
  }

  void _back() {
    if (widget.onBack != null) {
      widget.onBack!();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Widget _tabs(VoidCallback rename) {
    return NoteTabStrip(
      notes: widget.notes,
      onRename: rename,
      onClose: (NoteEntry note) async {
        final prepare = _leases[note.id]?.prepareToClose;
        if (prepare != null && !await prepare()) return;
        if (mounted) widget.notes.close(note.id);
      },
      onOpenAnother: _back,
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<NoteEntry> notes = widget.notes.notes;
    if (notes.isEmpty) {
      return const SizedBox.shrink();
    }
    final int active = widget.notes.activeIndex;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        for (int i = 0; i < notes.length; i++)
          if (_warm.contains(notes[i].id))
            _TabPage(
              key: ValueKey<String>('note-tab-page-${notes[i].id}'),
              visible: notes[i].id == _activeId || notes[i].id == _outgoingId,
              active: i == active,
              direction: i < active ? -0.025 : 0.025,
              child: NoteTabScope(
                lease: _leases.putIfAbsent(
                  notes[i].id,
                  () => NoteTabLease()..onReady = _queueTrim,
                ),
                // The tab strip listens to OpenNotes itself. Switching tabs
                // need not rebuild the warm editor or schedule PDF preloads.
                child: _editorFor(notes[i]),
              ),
            ),
      ],
    );
  }
}

class _TabPage extends StatelessWidget {
  const _TabPage({
    super.key,
    required this.visible,
    required this.active,
    required this.direction,
    required this.child,
  });

  final bool visible;
  final bool active;
  final double direction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Duration duration = AppMotion.resolve(context, AppMotion.medium);
    return Offstage(
      offstage: !visible,
      child: IgnorePointer(
        ignoring: !active,
        // A keyed page keeps each editor's page, history, and assistant alive
        // while its tab is faded just out of view.
        child: TickerMode(
          enabled: visible,
          child: ExcludeFocus(
            excluding: !active,
            child: ExcludeSemantics(
              excluding: !active,
              child: AnimatedSlide(
                offset: active ? Offset.zero : Offset(direction, 0),
                duration: duration,
                curve: AppMotion.standard,
                child: AnimatedOpacity(
                  opacity: active ? 1 : 0,
                  duration: duration,
                  curve: AppMotion.standard,
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
