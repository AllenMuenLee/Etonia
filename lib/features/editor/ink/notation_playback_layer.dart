import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'ink_controller.dart';
import 'ink_painter.dart';

/// The layer an AI notation is drawn on over time, and the clock that
/// drives it.
///
/// The clock is Flutter's frame ticker, and the time it hands the playback
/// is how long it has been running, never a count of frames, so the drawing
/// is the same at any refresh rate and after a dropped frame. It runs only
/// while the app is in the foreground and [TickerMode] allows: time spent
/// paused does not count. A frame repaints this layer alone; nothing is
/// rebuilt.
///
/// Every playback loops for as long as it lives; when the app comes back to
/// the foreground they carry on drawing. When this layer goes away, or is
/// handed another controller, the playbacks it was showing are finished, so
/// their strokes are never left hidden.
class NotationPlaybackLayer extends StatefulWidget {
  const NotationPlaybackLayer({super.key, required this.controller});

  final InkController controller;

  @override
  State<NotationPlaybackLayer> createState() => _NotationPlaybackLayerState();
}

class _NotationPlaybackLayerState extends State<NotationPlaybackLayer>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker = createTicker(_onTick);

  /// The controller's clock when the ticker last started.
  Duration _banked = Duration.zero;
  bool _tickerModeEnabled = true;
  bool _appActive = true;

  @override
  void initState() {
    super.initState();
    final AppLifecycleState? lifecycle = WidgetsBinding.instance.lifecycleState;
    _appActive = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    widget.controller.notationPlaybackListenable.addListener(_sync);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void didUpdateWidget(NotationPlaybackLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.notationPlaybackListenable.removeListener(_sync);
      oldWidget.controller.finishNotationPlayback();
      widget.controller.notationPlaybackListenable.addListener(_sync);
      _sync();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    _sync();
  }

  @override
  void dispose() {
    widget.controller.notationPlaybackListenable.removeListener(_sync);
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    widget.controller.finishNotationPlayback();
    super.dispose();
  }

  /// Starts or stops the clock for the controller's playbacks.
  void _sync() {
    final bool run =
        widget.controller.notationPlaybacks.isNotEmpty &&
        _tickerModeEnabled &&
        _appActive;
    if (run && !_ticker.isActive) {
      // Carries on from where it stopped: the time paused is not counted.
      _banked = widget.controller.notationClock;
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    widget.controller.advanceNotationPlayback(_banked + elapsed);
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: CustomPaint(
          key: const ValueKey<String>('notation-playback-layer'),
          painter: NotationPlaybackPainter(
            controller: widget.controller,
            brightness: Theme.of(context).brightness,
          ),
        ),
      ),
    );
  }
}
