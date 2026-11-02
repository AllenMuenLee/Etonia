import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../../shared/memory/note_cache_pool.dart';

/// A page of a note in the pool of what open notes keep in memory.
///
/// Coming into view, in a tab being shown, it counts as a use of the page;
/// while in view, nothing of it goes. Should its turn to go come while its
/// tab is out of view, [child] goes too, for what it shows holds on to the
/// same pictures, and is built again when the tab is shown.
class NoteCachePage extends StatefulWidget {
  const NoteCachePage({
    super.key,
    required this.scope,
    required this.page,
    this.onChanged,
    required this.child,
  });

  final NoteCacheScope scope;

  /// What the page goes by in [scope].
  final Object page;

  /// The page has come into view or gone out of it, so what it costs may be
  /// worth another look.
  final VoidCallback? onChanged;
  final Widget child;

  @override
  State<NoteCachePage> createState() => _NoteCachePageState();
}

class _NoteCachePageState extends State<NoteCachePage> {
  late NoteCachePageHold _hold;
  bool? _shown;
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    _hold = widget.scope.hold(widget.page, _onPopped);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(NoteCachePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope || oldWidget.page != widget.page) {
      _hold.release();
      _hold = widget.scope.hold(widget.page, _onPopped);
      _shown = null;
      _sync();
    }
  }

  void _sync() {
    final bool shown = TickerMode.valuesOf(context).enabled;
    if (shown == _shown) return;
    _shown = shown;
    if (shown) {
      _gone = false;
      _hold.shown = true;
      widget.scope.touch(widget.page);
    }
    widget.onChanged?.call();
    if (!shown) _hold.shown = false;
  }

  void _onPopped() {
    if (!mounted || _gone) return;
    _gone = true;
    // The pool may be trimmed from another page's build.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _hold.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _gone ? const SizedBox.expand() : widget.child;
}
