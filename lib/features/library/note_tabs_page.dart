import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../app/system_bars.dart';
import '../../app/theme/app_icons.dart';
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
/// Draws the one top bar every pane shares, and shows two notes side by side
/// once a tab is dropped on the left or right of the window.
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
  /// Safety pins and all visible panes take precedence over this soft budget.
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

  /// How much of a split window the left pane takes.
  double _split = 0.5;

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
    for (final String id in widget.notes.visibleNoteIds) {
      if (!_warm.contains(id)) _warm.add(id);
    }
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

    // Ensure all visible pane notes are in warm cache.
    for (final String id in widget.notes.visibleNoteIds) {
      if (!_warm.contains(id)) {
        _warm.add(id);
      }
    }

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
      final Set<String> visibleIds = widget.notes.visibleNoteIds.toSet();
      final int effectiveCapacity = math.max(capacity, visibleIds.length);

      for (final id in List<String>.of(_warm)) {
        if (_warm.length <= effectiveCapacity) break;
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
    bool inView() =>
        id == _activeId || widget.notes.visibleNoteIds.contains(id);
    if (inView()) return false;
    final lease = _leases[id];
    final prepare = lease?.prepareToEvict;
    // Missing registration means the editor has not mounted yet.
    if (prepare == null || !await prepare()) return false;
    // Saving is asynchronous: activation/close can happen meanwhile.
    if (!mounted || inView() || _leases[id] != lease) return false;
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

  /// The top bar with the tabs of [pane], or of the whole window without one.
  /// A split window has a bar over each pane, as two windows would.
  Widget _buildBar(BuildContext context, {int? pane}) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[widget.notes, _chrome]),
      builder: (BuildContext context, Widget? _) {
        final OpenNotes open = widget.notes;
        final NoteEntry? shown = pane == null
            ? open.active
            : open.paneNotes[pane];
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
            key: ValueKey<String>('note-strip-${pane ?? 'single'}'),
            notes: open,
            pane: pane,
            onRename: (String id) => _renames[id]?.call(),
            onClose: _close,
            onOpenAnother: pane == null || pane == open.splitCount - 1
                ? _back
                : null,
          ),
        );
      },
    );
  }

  /// A note's editor, told that it is [size] and that the bar above it is not
  /// its own, under [header] when the pane has a bar of its own. A press
  /// anywhere in the pane focuses it.
  Widget _scoped(
    NoteEntry note,
    Size size, {
    Widget? header,
    double headerHeight = 0,
    bool showsToolbar = true,
    bool ownsToolbar = false,
  }) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        final int? pane = widget.notes.paneOf(note.id);
        if (pane != null) widget.notes.focusPane(pane);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(height: headerHeight, child: header),
          Expanded(
            child: Builder(
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
            ),
          ),
        ],
      ),
    );
  }

  /// In a split each half carries its own bar, so it reaches the top; in
  /// fullscreen neither does, once they have slid away.
  double _paneHeaderHeight(BuildContext context) {
    return widget.notes.isSplit && (!_fullscreen || _sliding)
        ? AppSizes.appBarHeight + MediaQuery.paddingOf(context).top
        : 0;
  }

  Widget _buildPanes(BuildContext context, List<NoteEntry> notes) {
    final OpenNotes open = widget.notes;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = constraints.biggest;
        final bool split = open.isSplit;
        final double headerHeight = _paneHeaderHeight(context);
        final bool headers = headerHeight > 0;
        final Rect full = Offset.zero & size;
        final double dividerX = (size.width * _split).roundToDouble();
        final Rect left = Rect.fromLTRB(0, 0, dividerX, size.height);
        final Rect right = Rect.fromLTRB(
          dividerX + 1,
          0,
          size.width,
          size.height,
        );
        Rect rectOf(String id) {
          if (!split) return full;
          return switch (open.paneOf(id)) {
            0 => left,
            1 => right,
            _ => full,
          };
        }

        final int active = open.activeIndex;
        // The raised pane is painted last so its shadow falls on its neighbour.
        // In one-pane mode the current note is painted last, so its opaque
        // surface can slide over the outgoing note without crossfading two
        // full-resolution editors. Keys keep every editor's state when the
        // order changes.
        final List<int> order = <int>[for (int i = 0; i < notes.length; i++) i];
        if (split) {
          int rank(int i) =>
              open.paneOf(notes[i].id) == open.focusedPane ? 1 : 0;
          order.sort((int a, int b) => rank(a).compareTo(rank(b)));
        } else {
          order.sort((int a, int b) {
            if (a == active) return 1;
            if (b == active) return -1;
            return a.compareTo(b);
          });
        }
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // One keyed slot per editor, whatever the layout, so splitting
            // moves an editor and does not rebuild it.
            for (final int i in order)
              if (_warm.contains(notes[i].id))
                Positioned.fromRect(
                  key: ValueKey<String>('note-tab-page-${notes[i].id}'),
                  rect: rectOf(notes[i].id),
                  child: _TabPage(
                    visible: split
                        ? open.isNoteInPane(notes[i].id)
                        : notes[i].id == _activeId,
                    current: split
                        ? open.isNoteInPane(notes[i].id)
                        : i == active,
                    child: _FloatingPane(
                      key: ValueKey<String>('floating-pane-${notes[i].id}'),
                      split: split && open.isNoteInPane(notes[i].id),
                      raised: open.paneOf(notes[i].id) == open.focusedPane,
                      child: _scoped(
                        notes[i],
                        Size(
                          rectOf(notes[i].id).width,
                          rectOf(notes[i].id).height - headerHeight,
                        ),
                        headerHeight: headerHeight,
                        header: headers && open.paneOf(notes[i].id) != null
                            ? _buildBar(context, pane: open.paneOf(notes[i].id))
                            : null,
                        showsToolbar: split
                            ? open.isNoteInPane(notes[i].id)
                            : notes[i].id == _activeId,
                        ownsToolbar: split
                            ? open.paneOf(notes[i].id) == open.focusedPane
                            : notes[i].id == _activeId,
                      ),
                    ),
                  ),
                ),
            if (split) ...<Widget>[
              // Only the grip takes drags; a full-height strip would steal
              // the pen from whatever is written along the divider.
              Positioned(
                left: dividerX - _handleWidth / 2 + 0.5,
                top: math.max(0, (size.height - _handleHeight) / 2),
                height: math.min(_handleHeight, size.height),
                width: _handleWidth,
                child: _SplitHandle(
                  onDragStart: () {},
                  onDragUpdate: (double dx) => setState(() {
                    _split = (_split + dx / size.width).clamp(0.12, 0.88);
                  }),
                  onDragEnd: _endResize,
                  onReset: () => setState(() => _split = 0.5),
                ),
              ),
            ],
            ValueListenableBuilder<String?>(
              valueListenable: open.draggedTab,
              builder: (BuildContext context, String? dragged, Widget? _) {
                if (dragged == null) return const SizedBox.shrink();
                return Positioned.fill(
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: _DropSide(
                          key: const ValueKey<String>('drop-left'),
                          right: false,
                          onDropped: (String id) =>
                              open.splitWith(id, right: false),
                        ),
                      ),
                      Expanded(
                        child: _DropSide(
                          key: const ValueKey<String>('drop-right'),
                          right: true,
                          onDropped: (String id) =>
                              open.splitWith(id, right: true),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }

  static const double _handleWidth = 28;
  static const double _handleHeight = 72;

  /// Pulled right to an edge, a pane is put away, leaving the other the
  /// whole window; otherwise the panes stay as they were left.
  void _endResize() {
    final double split = _split;
    setState(() => _split = split.clamp(0.25, 0.75));
    if (split < 0.2 || split > 0.8) {
      widget.notes.closePane(split < 0.2 ? 0 : 1);
      setState(() => _split = 0.5);
    }
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
          paneHeader: _paneHeaderHeight(context),
        ),
        children: <Widget>[
          // A split has a bar over each half instead, and fullscreen none;
          // the slot stays so the editors below are not rebuilt when the
          // window splits or goes fullscreen.
          LayoutId(
            id: _BarOverPanes.bar,
            child: widget.notes.isSplit || (_fullscreen && !_sliding)
                ? const SizedBox.shrink()
                : _buildBar(context),
          ),
          LayoutId(id: _BarOverPanes.panes, child: _buildPanes(context, notes)),
        ],
      ),
    );
  }
}

/// The top bar and the panes below it, slid up by [away] as one sheet until
/// the bar has left the screen. Only their places change on each frame: the
/// panes keep their size, and their editors are not laid out again.
class _BarOverPanes extends MultiChildLayoutDelegate {
  _BarOverPanes({
    required this.away,
    required this.sliding,
    required this.statusBar,
    required this.paneHeader,
  }) : super(relayout: away);

  static const String bar = 'bar';
  static const String panes = 'panes';

  /// 0 with the bar in its place, 1 with it gone.
  final Animation<double> away;
  final bool sliding;

  /// Where the system keeps its status bar showing in fullscreen, the page
  /// stays clear of it.
  final double statusBar;

  /// The bar each pane of a split has of its own, which goes up with it.
  final double paneHeader;

  @override
  void performLayout(Size size) {
    final double barHeight = layoutChild(
      bar,
      BoxConstraints.tightFor(width: size.width),
    ).height;
    final double gone = away.value.clamp(0.0, 1.0);
    final double top = barHeight + (statusBar - paneHeader - barHeight) * gone;
    layoutChild(
      panes,
      BoxConstraints.tightFor(
        width: size.width,
        height: sliding
            ? size.height - statusBar + paneHeader
            : size.height - top,
      ),
    );
    positionChild(bar, Offset(0, -gone * barHeight));
    positionChild(panes, Offset(0, top));
  }

  @override
  bool shouldRelayout(_BarOverPanes oldDelegate) =>
      sliding != oldDelegate.sliding ||
      statusBar != oldDelegate.statusBar ||
      paneHeader != oldDelegate.paneHeader;
}

/// A pane in a split window. The one in use is raised: a soft shadow and full
/// size, while the other settles back a little, so switching panes reads as
/// lifting one page off the desk.
class _FloatingPane extends StatelessWidget {
  const _FloatingPane({
    super.key,
    required this.split,
    required this.raised,
    required this.child,
  });

  final bool split;
  final bool raised;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Duration duration = AppMotion.resolve(
      context,
      AppMotion.snappy.duration,
    );
    return TweenAnimationBuilder<double>(
      // Same widgets whether split or not, so opening a split never rebuilds
      // the editor below.
      tween: Tween<double>(end: split && raised ? 1 : 0),
      duration: duration,
      // A slight overshoot on the way up gives the lift a little spring.
      curve: split && raised ? AppMotion.popCurve : AppMotion.fadeInCurve,
      child: child,
      builder: (BuildContext context, double lift, Widget? child) {
        final double t = lift.clamp(0.0, 1.25);
        final double radius = split ? AppRadii.small : 0;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: colors.background,
            borderRadius: BorderRadius.circular(radius),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: (dark ? 0.55 : 0.22) * t),
                blurRadius: 24 * t,
                spreadRadius: 1 * t,
                offset: Offset(0, 8 * t),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: (dark ? 0.4 : 0.12) * t),
                blurRadius: 4 * t,
                offset: Offset(0, 1 * t),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: child,
          ),
        );
      },
    );
  }
}

/// The line between two panes, with a grip to pull it by.
class _SplitHandle extends StatelessWidget {
  const _SplitHandle({
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onReset,
  });

  final VoidCallback onDragStart;
  final ValueChanged<double> onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        key: const ValueKey<String>('split-handle'),
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) => onDragStart(),
        onHorizontalDragUpdate: (DragUpdateDetails d) =>
            onDragUpdate(d.delta.dx),
        onHorizontalDragEnd: (_) => onDragEnd(),
        onHorizontalDragCancel: onDragEnd,
        onDoubleTap: onReset,
        child: Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.divider,
              borderRadius: BorderRadius.circular(AppRadii.small),
            ),
            child: const SizedBox(width: 6, height: 44),
          ),
        ),
      ),
    );
  }
}

/// Half of the window, ready for a dragged tab to be let go on.
class _DropSide extends StatelessWidget {
  const _DropSide({super.key, required this.right, required this.onDropped});

  final bool right;
  final ValueChanged<String> onDropped;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return DragTarget<String>(
      onAcceptWithDetails: (DragTargetDetails<String> d) => onDropped(d.data),
      builder:
          (
            BuildContext context,
            List<String?> candidates,
            List<dynamic> rejected,
          ) {
            final bool over = candidates.isNotEmpty;
            return AnimatedContainer(
              duration: AppMotion.resolve(context, AppMotion.fadeIn),
              decoration: BoxDecoration(
                color: colors.accent.withValues(alpha: over ? 0.18 : 0.05),
                border: Border.all(
                  color: colors.accent.withValues(alpha: over ? 0.9 : 0.25),
                  width: over ? 3 : 1,
                ),
              ),
              child: Center(
                child: AnimatedOpacity(
                  duration: AppMotion.resolve(context, AppMotion.fadeIn),
                  opacity: over ? 1 : 0.5,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        right ? AppIcons.next : AppIcons.previous,
                        size: 32,
                        color: colors.accent,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        right ? 'Open on the right' : 'Open on the left',
                        style: Theme.of(
                          context,
                        ).textTheme.labelLarge!.copyWith(color: colors.accent),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
    );
  }
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
