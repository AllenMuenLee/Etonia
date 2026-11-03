import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../app/system_bars.dart';
import '../../app/theme/app_tokens.dart';
import '../../shared/memory/memory_pressure.dart';
import '../../shared/motion/motion_memory.dart';
import '../../shared/widgets/ignore_keyboard.dart';
import '../editor/widgets/editor_app_bar.dart';
import '../editor/widgets/editor_chrome.dart';
import 'library_models.dart';
import 'note_tab_strip.dart';
import 'open_notes.dart';

/// Cheap restoration data survives eviction; no document or bitmap lives here.
class NoteTabLease {
  int currentPage = 0;
  Future<bool> Function()? prepareToEvict;
  Future<bool> Function()? prepareToClose;
  VoidCallback? onReady;

  /// Puts the note's editor away if it safely can be, leaving a cold tab.
  Future<bool> Function()? putAway;
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

/// The editors of open notes. A tab goes cold when the memory for notes runs
/// out with nothing else of its note left to let go of, or the system runs
/// low; cold tabs keep only cheap restoration data, and sessions with
/// non-persisted state are safety-pinned until closed.
class NoteTabsPage extends StatefulWidget {
  const NoteTabsPage({
    super.key,
    required this.notes,
    required this.builder,
    this.onBack,
    this.backTooltip = 'Back to library',
    this.showing = true,
    this.warmCapacity,
  }) : assert(warmCapacity == null || warmCapacity > 0);

  final OpenNotes notes;
  final NoteTabBuilder builder;
  final VoidCallback? onBack;

  /// Says where [onBack] leads.
  final String backTooltip;

  /// Whether the notes are in front. While they are, the status bar is put
  /// away; behind the library, the window leaves fullscreen and the library
  /// has every system bar back.
  final bool showing;

  /// Recent editors kept in memory, plus sessions that cannot safely be evicted
  /// (failed saves or non-persisted editing state).
  /// Safety pins and visible editor take precedence over this soft budget.
  /// By default there is none: the note's share of the pool of what open
  /// notes keep in memory decides, and the system when it runs low.
  final int? warmCapacity;

  @override
  State<NoteTabsPage> createState() => _NoteTabsPageState();
}

class _NoteTabsPageState extends State<NoteTabsPage>
    with SingleTickerProviderStateMixin {
  String? _activeId;
  final Map<String, NoteTabLease> _leases = {};
  final List<String> _warm = [];
  final Map<String, (NoteEntry, Widget)> _children = {};
  bool _trimming = false;

  /// What each open editor offers the shared top bar, and what each tab
  /// keeps of the toolbar.
  final EditorChromeHost _chrome = EditorChromeHost();

  /// The window's one toolbar. The editor in front holds it; switching or
  /// opening a tab moves the same element over instead of building another.
  final GlobalKey _toolbarKey = GlobalKey(debugLabel: 'Shared toolbar');

  /// How each open note is renamed, as its editor page has told us.
  final Map<String, VoidCallback> _renames = {};

  /// Whether the top bar and its tabs are put away, and the navigation bar
  /// with them, leaving the page the whole screen.
  bool _fullscreen = false;

  /// How far the top bar has gone for fullscreen: 0 in its place, 1 away.
  late final AnimationController _barAway;

  /// Whether the bar and the page are on their way, one above the other. The
  /// page is then as tall as it is in fullscreen, whichever way they go, so
  /// the editors are laid out once for the move and not on each of its frames.
  bool _sliding = false;

  /// Counts the moves that have ended, for the editors: the page has then
  /// come to rest somewhere new without being laid out.
  final ValueNotifier<int> _barSettled = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _barAway = AnimationController.unbounded(vsync: this);
    _activeId = widget.notes.active?.id;
    if (_activeId != null) _warm.add(_activeId!);
    widget.notes.addListener(_onNotesChanged);
    MemoryPressure.instance.addListener(_releaseMemory);
    if (widget.showing) SystemBars.showNavigation();
  }

  @override
  void dispose() {
    MemoryPressure.instance.removeListener(_releaseMemory);
    widget.notes.removeListener(_onNotesChanged);
    _chrome.dispose();
    _barAway.dispose();
    _barSettled.dispose();
    if (widget.showing) SystemBars.showAll();
    super.dispose();
  }

  @override
  void didUpdateWidget(NoteTabsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.builder != widget.builder) _children.clear();
    if (widget.showing != oldWidget.showing) {
      if (widget.showing) {
        SystemBars.showNavigation();
      } else {
        _bringBarBackAtOnce();
        SystemBars.showAll();
      }
    }
  }

  void _enterFullscreen() {
    if (_fullscreen) return;
    setState(() => _fullscreen = true);
    _slideBar(away: true);
    SystemBars.hideAll();
  }

  /// A method, not a closure, so each build hands the editors an equal
  /// callback and none is rebuilt for it.
  void _exitFullscreen() {
    if (!_fullscreen) return;
    setState(() => _fullscreen = false);
    _slideBar(away: false);
    if (widget.showing) SystemBars.showNavigation();
  }

  /// Moves the bar and the page together, keeping the speed of a move that
  /// is turned back halfway. With motion reduced they are simply there.
  void _slideBar({required bool away}) {
    final double target = away ? 1 : 0;
    if (MediaQuery.disableAnimationsOf(context)) {
      _sliding = false;
      _barAway.value = target;
      return;
    }
    _sliding = true;
    _barAway
        .animateWith(
          SpringSimulation(
            AppMotion.smooth,
            _barAway.value,
            target,
            _barAway.velocity,
          ),
        )
        .then((_) {
          if (!mounted) return;
          // A spring stops just short of its end; the page rests on it.
          _barAway.value = target;
          setState(() => _sliding = false);
          _barSettled.value++;
        });
  }

  /// Out of fullscreen with no move, for the page going out of view anyway.
  void _bringBarBackAtOnce() {
    _fullscreen = false;
    _sliding = false;
    _barAway.stop();
    _barAway.value = 0;
  }

  Widget _editorFor(NoteEntry note) {
    final cached = _children[note.id];
    if (cached != null && cached.$1 == note) return cached.$2;
    final child = widget.builder(
      note,
      (rename) => _tabsFor(note, rename),
      _back,
      widget.notes.update,
    );
    _children[note.id] = (note, child);
    return child;
  }

  /// The top bar is ours; the editor page only says how to rename its note.
  Widget _tabsFor(NoteEntry note, VoidCallback rename) {
    _renames[note.id] = rename;
    return const SizedBox.shrink();
  }

  Future<void> _close(NoteEntry entry) async {
    final prepare = _leases[entry.id]?.prepareToClose;
    if (prepare != null && !await prepare()) return;
    if (mounted) widget.notes.close(entry.id);
  }

  void _leave() {
    final String? id = widget.notes.active?.id;
    final prepare = id == null ? null : _leases[id]?.prepareToClose;
    if (prepare != null) unawaited(prepare());
    _back();
  }

  void _onNotesChanged() {
    if (!mounted) {
      return;
    }
    if (widget.notes.isEmpty) {
      setState(() {
        _activeId = null;
        _warm.clear();
        _leases.clear();
        _renames.clear();
        _children.clear();
      });
      _back();
      return;
    }
    final ids = widget.notes.notes.map((note) => note.id).toSet();
    _warm.removeWhere((id) => !ids.contains(id));
    _renames.removeWhere((id, _) => !ids.contains(id));
    _leases.removeWhere((id, _) => !ids.contains(id));
    _children.removeWhere((id, _) => !ids.contains(id));
    _chrome.retainToolbars(ids);

    final String? activeId = widget.notes.active?.id;
    if (activeId != _activeId) {
      _activeId = activeId;
      _warm.remove(activeId);
      if (activeId != null) _warm.add(activeId);
    }
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_trim());
    });
  }

  /// The system is low on memory: only the editors on screen stay warm.
  /// Those that cannot yet be put away safely stay too.
  void _releaseMemory() => unawaited(_trim(warmCapacity: 0));

  Future<void> _trim({int? warmCapacity}) async {
    if (_trimming) return;
    _trimming = true;
    try {
      final int? capacity = warmCapacity ?? widget.warmCapacity;
      // Without a budget nothing is put away until memory runs low.
      if (capacity == null) return;
      const int effectiveCapacity = 1;
      final int targetCapacity = math.max(capacity, effectiveCapacity);

      for (final id in List<String>.of(_warm)) {
        if (_warm.length <= targetCapacity) break;
        await _putAway(id);
        if (!mounted) return;
      }
    } finally {
      _trimming = false;
    }
  }

  /// Takes the editor of the note [id] out of memory, if it is out of view
  /// and has nothing unsaved. Its tab stays, and reads the note again when
  /// it is shown.
  Future<bool> _putAway(String id) async {
    if (id == _activeId) return false;
    final lease = _leases[id];
    final prepare = lease?.prepareToEvict;
    // Missing registration means the editor has not mounted yet.
    if (prepare == null || !await prepare()) return false;
    // Saving is asynchronous: activation/close can happen meanwhile.
    if (!mounted || id == _activeId || _leases[id] != lease) return false;
    MotionMemory.instance.forget(('note', id));
    setState(() {
      _warm.remove(id);
      _children.remove(id);
    });
    return true;
  }

  void _queueTrim() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_trim());
    });
  }

  void _back() {
    if (_fullscreen) {
      setState(_bringBarBackAtOnce);
      if (widget.showing) SystemBars.showNavigation();
    }
    if (widget.onBack != null) {
      widget.onBack!();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  /// The top bar with the open tabs.
  Widget _buildBar(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[widget.notes, _chrome]),
      builder: (BuildContext context, Widget? _) {
        final NoteEntry? shown = widget.notes.active;
        final EditorChromeEntry? entry = _chrome.entryFor(shown?.id);
        return EditorAppBar(
          title: shown?.title ?? '',
          centerTitle: false,
          onMenuPressed: _leave,
          leadingIsBack: true,
          backTooltip: widget.backTooltip,
          onSettingsPressed: entry?.onSettings,
          onFullscreenPressed: _enterFullscreen,
          audioPlayer: entry?.audioPlayer,
          replayController: entry?.replayController,
          onCloseReplay: entry?.onCloseReplay,
          tabs: NoteTabStrip(
            key: const ValueKey<String>('note-strip-single'),
            notes: widget.notes,
            onRename: (String id) => _renames[id]?.call(),
            onClose: _close,
            onOpenAnother: _back,
          ),
        );
      },
    );
  }

  /// A note's editor, told that it is [size].
  Widget _scoped(
    NoteEntry note,
    Size size, {
    bool showsToolbar = true,
    bool ownsToolbar = false,
  }) {
    return Builder(
      builder: (BuildContext context) {
        final MediaQueryData media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            size: size,
            padding: media.padding.copyWith(top: 0),
            viewPadding: media.viewPadding.copyWith(top: 0),
          ),
          child: NoteTabScope(
            lease: _leases.putIfAbsent(
              note.id,
              () => NoteTabLease()
                ..onReady = _queueTrim
                ..putAway = () => _putAway(note.id),
            ),
            child: EditorChromeScope(
              host: _chrome,
              noteId: note.id,
              child: EditorFullscreenScope(
                onExit: _fullscreen ? _exitFullscreen : null,
                settled: _barSettled,
                child: EditorToolbarScope(
                  toolbarKey: ownsToolbar ? _toolbarKey : null,
                  showsToolbar: showsToolbar,
                  child: _editorFor(note),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPages(BuildContext context, List<NoteEntry> notes) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = constraints.biggest;
        final Rect full = Offset.zero & size;
        final int active = widget.notes.activeIndex;

        final List<int> order = <int>[for (int i = 0; i < notes.length; i++) i];
        order.sort((int a, int b) {
          if (a == active) return 1;
          if (b == active) return -1;
          return a.compareTo(b);
        });

        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            for (final int i in order)
              if (_warm.contains(notes[i].id))
                Positioned.fromRect(
                  key: ValueKey<String>('note-tab-page-${notes[i].id}'),
                  rect: full,
                  child: _TabPage(
                    visible: notes[i].id == _activeId,
                    current: i == active,
                    child: _scoped(
                      notes[i],
                      size,
                      showsToolbar: notes[i].id == _activeId,
                      ownsToolbar: notes[i].id == _activeId,
                    ),
                  ),
                ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<NoteEntry> notes = widget.notes.notes;
    if (notes.isEmpty) {
      return const SizedBox.shrink();
    }
    return Material(
      color: AppColors.of(context).background,
      child: CustomMultiChildLayout(
        delegate: _BarOverPanes(
          away: _barAway,
          sliding: _sliding,
          statusBar: MediaQuery.paddingOf(context).top,
        ),
        children: <Widget>[
          LayoutId(
            id: _BarOverPanes.bar,
            child: _fullscreen && !_sliding
                ? const SizedBox.shrink()
                : _buildBar(context),
          ),
          LayoutId(id: _BarOverPanes.panes, child: _buildPages(context, notes)),
        ],
      ),
    );
  }
}

/// The top bar and the pages below it, slid up by [away] as one sheet until
/// the bar has left the screen. Only their places change on each frame: the
/// page keeps its size, and the editors are not laid out again.
class _BarOverPanes extends MultiChildLayoutDelegate {
  _BarOverPanes({
    required this.away,
    required this.sliding,
    required this.statusBar,
  }) : super(relayout: away);

  static const String bar = 'bar';
  static const String panes = 'panes';

  /// 0 with the bar in its place, 1 with it gone.
  final Animation<double> away;
  final bool sliding;

  /// Where the system keeps its status bar showing in fullscreen, the page
  /// stays clear of it.
  final double statusBar;

  @override
  void performLayout(Size size) {
    final double barHeight = layoutChild(
      bar,
      BoxConstraints.tightFor(width: size.width),
    ).height;
    final double gone = away.value.clamp(0.0, 1.0);
    final double top = barHeight + (statusBar - barHeight) * gone;
    layoutChild(
      panes,
      BoxConstraints.tightFor(
        width: size.width,
        height: sliding ? size.height - statusBar : size.height - top,
      ),
    );
    positionChild(bar, Offset(0, -gone * barHeight));
    positionChild(panes, Offset(0, top));
  }

  @override
  bool shouldRelayout(_BarOverPanes oldDelegate) =>
      sliding != oldDelegate.sliding || statusBar != oldDelegate.statusBar;
}

class _TabPage extends StatelessWidget {
  const _TabPage({
    required this.visible,
    required this.current,
    required this.child,
  });

  final bool visible;

  /// Whether the page is one to see and use, not one fading away.
  final bool current;
  final Widget child;

  @override
  Widget build(BuildContext context) => Offstage(
    offstage: !visible,
    child: IgnorePointer(
      ignoring: !current,
      // A keyed page keeps each editor's page, history, and assistant alive
      // while its tab is put just out of view.
      child: TickerMode(
        enabled: visible,
        child: ExcludeFocus(
          excluding: !current,
          child: ExcludeSemantics(
            excluding: !current,
            // Keep a warm editor as one stable layer. Sliding an entire
            // PDF/image/ink scene rerasterizes or composites a screen-sized
            // texture for several frames on mobile GPUs; an immediate tab
            // hand-off is both clearer and reliably cheaper.
            child: RepaintBoundary(
              child: IgnoreKeyboard(ignoring: !current, child: child),
            ),
          ),
        ),
      ),
    ),
  );
}
