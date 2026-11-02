import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/theme/app_icons.dart';
import '../ink/pointer_claims.dart';
import 'page_setup.dart';

/// Maps page coordinates to the viewport: `page * scale + origin`.
@immutable
class PageTransform {
  const PageTransform({this.scale = 1, this.origin = Offset.zero});

  static const PageTransform identity = PageTransform();

  final double scale;
  final Offset origin;

  Offset apply(Offset page) => page * scale + origin;

  Rect applyRect(Rect page) {
    return Rect.fromPoints(apply(page.topLeft), apply(page.bottomRight));
  }

  Offset invert(Offset viewport) => (viewport - origin) / scale;

  @override
  bool operator ==(Object other) {
    return other is PageTransform &&
        other.scale == scale &&
        other.origin == origin;
  }

  @override
  int get hashCode => Object.hash(scale, origin);
}

/// Shows a note's pages as a column in the writing area, each page its own
/// sheet, [pageGap] below the one before. Each page is at its own
/// [PageGeometry]'s scale; a page narrower than the area is centered across
/// it, and a column shorter than the area is centered in it.
///
/// Writing input is never taken for scrolling: the column scrolls with two
/// fingers, a mouse wheel, or a trackpad. When two fingers start scrolling,
/// [onScrollStart] is told which pointers they are, so that a stroke the
/// first finger began can be dropped. When the column cannot scroll,
/// fingers are left alone.
///
/// The page that holds the middle of the area, after a scroll, and the page
/// a pointer goes down on, are reported; when [currentPage] changes for any
/// other reason, the column scrolls to show that page's top.
///
/// With [infinite], the one page is a whiteboard: it fills the area edge to
/// edge, with no desk, sheet edge, or overscroll round it, pans freely in
/// every direction, and zooms far out. It opens on [boardFocus].
class PageViewport extends StatefulWidget {
  const PageViewport({
    super.key,
    required this.pages,
    required this.pageKeys,
    required this.currentPage,
    required this.pageBuilder,
    this.overlayBuilder,
    this.onPageTouched,
    this.onDeskTap,
    this.onVisiblePageChanged,
    this.onScrollStart,
    this.onScrollEnd,
    this.onScrollSpeed,
    this.fingersNavigate,
    this.pointerClaims,
    this.onPullToAddPage,
    this.pullToAddDistance = 180,
    this.pageGap = AppSpacing.md,
    this.minZoom = 0.5,
    this.maxZoom = 4,
    this.initialZoom = 1,
    this.infinite = false,
    this.boardFocus,
  }) : assert(pages.length == pageKeys.length),
       assert(!infinite || pages.length == 1),
       assert(pageGap >= 0),
       assert(pullToAddDistance > 0),
       assert(minZoom > 0 && minZoom <= initialZoom && initialZoom <= maxZoom);

  /// Called when the column, scrolled to its end, is pulled up a further
  /// [pullToAddDistance] and let go: two fingers or a trackpad, or one
  /// finger while [fingersNavigate]. Without it there is no pull.
  ///
  /// On a column too short to scroll, two fingers are taken for a pull only
  /// once they move up together, so a resting palm still leaves the pen
  /// alone.
  final VoidCallback? onPullToAddPage;

  /// How far, in viewport pixels, the column is pulled past its end before
  /// letting go adds a page.
  final double pullToAddDistance;

  /// While true, fingers never write, so one finger pans the column and
  /// two pan and pinch-zoom it. [onScrollStart] receives an empty set only
  /// after a finger actually moves: there is no stroke of theirs to drop,
  /// and a resting palm must not stop the pen. A finger is ignored while a
  /// stylus is down.
  final ValueListenable<bool>? fingersNavigate;

  /// Touches a canvas has taken, such as a finger moving the ruler: they
  /// neither pan nor zoom the column.
  final PointerClaims? pointerClaims;

  /// How far a pinch can zoom the column out and in.
  final double minZoom;
  final double maxZoom;

  /// The zoom used when this viewport is first opened.
  final double initialZoom;

  /// Whether the one page is a whiteboard.
  final bool infinite;

  /// The part of a whiteboard, in page units, first brought into view:
  /// centered when it fits, else from its top-left corner. Without it, the
  /// middle of the board.
  final Rect? boardFocus;

  /// How many screen pixels one page unit of the page being built takes,
  /// as it changes with the zoom, so what is painted on that page can stay
  /// legible. Null outside a [PageViewport].
  static ValueListenable<double>? scaleOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<_PageScaleScope>()?.scale;
  }

  final List<PageGeometry> pages;

  /// The space between one page and the next, in viewport pixels.
  final double pageGap;

  /// One per page, so a page keeps its state when others are added or
  /// removed around it.
  final List<Key> pageKeys;

  final int currentPage;

  /// Builds page [index], laid out at its [PageGeometry.pageSize] in page
  /// coordinates. `visible` is the part of the page on screen. Pages far
  /// off screen are not built.
  final Widget Function(
    BuildContext context,
    int index,
    ValueListenable<Rect> visible,
  )
  pageBuilder;

  /// Builds what floats above the current page in viewport coordinates,
  /// such as action bars, which keep their size whatever the page's scale.
  final Widget Function(BuildContext context, PageTransform transform)?
  overlayBuilder;

  final ValueChanged<int>? onPageTouched;

  /// A tap, by pen or finger, on the desk around the pages rather than on
  /// a page.
  final VoidCallback? onDeskTap;
  final ValueChanged<int>? onVisiblePageChanged;
  final ValueChanged<Set<int>>? onScrollStart;
  final VoidCallback? onScrollEnd;

  /// How fast a drag or its coast is moving the column, in viewport pixels
  /// a second, as it changes.
  final ValueChanged<double>? onScrollSpeed;

  @override
  State<PageViewport> createState() => PageViewportState();
}

class PageViewportState extends State<PageViewport>
    with SingleTickerProviderStateMixin {
  final Map<Key, ValueNotifier<Rect>> _visible = <Key, ValueNotifier<Rect>>{};
  final Map<Key, ValueNotifier<double>> _scales =
      <Key, ValueNotifier<double>>{};

  /// Whether a whiteboard has been brought to its [PageViewport.boardFocus].
  bool _boardPlaced = false;

  /// What [PageViewport.pageBuilder] made for each page on screen. Scrolling
  /// rebuilds this viewport on every frame, but a page's layers do not
  /// change with it, so they are kept, and not built again, until the
  /// parent builds again or the theme changes.
  final Map<Key, Widget> _builtPages = <Key, Widget>{};
  AppColors? _builtPagesColors;
  final Map<int, Offset> _touches = <int, Offset>{};
  final Set<int> _activeTouches = <int>{};
  bool _palmGestureBlocked = false;
  Offset _offset = Offset.zero;
  Offset _maxScroll = Offset.zero;

  /// How far the column scrolls past each of its edges, along each axis.
  /// Only pages that fill the area along an axis get room there; a column
  /// already set on the desk stays put.
  Offset _room = Offset.zero;
  bool _scrolling = false;

  late final Ticker _inertiaTicker;
  Duration? _lastInertiaTick;
  Duration? _lastDragUpdate;
  Offset _dragVelocity = Offset.zero;
  FrictionSimulation? _inertiaX;
  FrictionSimulation? _inertiaY;
  double _inertiaTime = 0;
  Offset _inertiaPosition = Offset.zero;
  bool _scrollEndPending = false;
  bool _waitingForTouchRelease = false;

  /// Fingers moving the column in [PageViewport.fingersNavigate] mode.
  bool _navigating = false;
  final Set<int> _styluses = <int>{};

  /// The pinch zoom, on top of each page's own scale.
  late double _zoom;
  double _panZoomScale = 1;

  /// The page last reported, or scrolled to; a different [currentPage]
  /// means a jump.
  late int _shownPage;
  bool _jumpPending = false;

  /// Pages reported as touched or scrolled to since the parent last built
  /// this viewport. The parent makes a reported page current only when it
  /// next builds, and more pointer events may have moved the column on by
  /// then: a finger set down on the page below the middle reports that
  /// page, and the first move of the scroll it starts reports the middle
  /// one. A current page among these is the column's own report coming
  /// back, not a jump.
  final Set<int> _reported = <int>{};

  _ColumnLayout? _layout;

  /// Space kept above the first page, in viewport pixels, so that pages
  /// added below a short, centered column do not move the one on screen.
  double _lead = 0;

  /// How far the column has been pulled past its end, in viewport pixels.
  final ValueNotifier<double> _pull = ValueNotifier<double>(0);

  /// Two fingers down on a column that cannot scroll, not yet moving up
  /// together; and where their middle started.
  bool _pullCandidate = false;
  Offset _pullStart = Offset.zero;

  /// How far two fingers on a column that cannot scroll move up together
  /// before they are taken for a pull.
  static const double _pullSlop = 24;

  /// How far past each edge of the column it can be scrolled, in viewport
  /// pixels, so a page's border can be brought in from the screen's edge.
  static const double _overscroll = 48;

  /// A contact this wide is a hand or palm rather than an intentional
  /// fingertip. Flutter reports contact radii in logical pixels on both iOS
  /// and Android. Android also reports the device-specific normalized
  /// contact [PointerEvent.size], which covers devices that omit radii.
  static const double _palmRadius = 28;
  static const double _androidPalmSize = 0.28;

  /// How far the column is scrolled, in viewport pixels.
  Offset get scrollOffset => _offset;

  /// Whether two fingers are scrolling the column.
  bool get isScrolling => _scrolling || _inertiaTicker.isActive;

  /// How far the column is pinch-zoomed; 1 shows each page at its own scale.
  double get zoom => _zoom;

  bool get _fingersNavigate => widget.fingersNavigate?.value ?? false;

  bool get _canScroll => _maxScroll != Offset.zero;

  @override
  void initState() {
    super.initState();
    _zoom = widget.initialZoom;
    _shownPage = widget.currentPage;
    // Opened on a page other than the first, the column starts there.
    _jumpPending = widget.currentPage > 0;
    _inertiaTicker = createTicker(_tickInertia);
  }

  @override
  void didUpdateWidget(PageViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The editor raises the minimum to one for an infinite canvas. Apply a
    // changed bound immediately when a page is converted while this viewport
    // keeps its state.
    _zoom = _zoom.clamp(widget.minZoom, widget.maxZoom).toDouble();
    _builtPages.clear();
    final bool reported = _reported.contains(widget.currentPage);
    _reported.clear();
    if (widget.currentPage != oldWidget.currentPage &&
        widget.currentPage != _shownPage &&
        !reported) {
      _shownPage = widget.currentPage;
      _jumpPending = true;
    } else if (!reported) {
      _shownPage = widget.currentPage;
    }
  }

  @override
  void dispose() {
    _inertiaTicker.dispose();
    for (final ValueNotifier<Rect> visible in _visible.values) {
      visible.dispose();
    }
    for (final ValueNotifier<double> scale in _scales.values) {
      scale.dispose();
    }
    _pull.dispose();
    super.dispose();
  }

  /// Reports page [index] as touched, as a pointer going down on it would,
  /// so it becomes the current page without the column scrolling to it.
  void touchPage(int index) {
    if (index < 0 || index >= widget.pages.length) {
      return;
    }
    _shownPage = index;
    _reported.add(index);
    widget.onPageTouched?.call(index);
  }

  /// Scrolls by [delta] viewport pixels, within the column.
  void scrollBy(Offset delta) {
    final Offset next = _clamp(_offset + delta);
    if (next == _offset) {
      return;
    }
    setState(() => _offset = next);
    final _ColumnLayout? layout = _layout;
    if (layout == null) {
      return;
    }
    final int visible = layout.pageAt(
      _offset.dy + layout.viewport.height / 2 - layout.top,
    );
    if (visible != _shownPage) {
      _shownPage = visible;
      _reported.add(visible);
      widget.onVisiblePageChanged?.call(visible);
    }
  }

  Offset _clamp(Offset offset) {
    return Offset(
      offset.dx.clamp(-_room.dx, _maxScroll.dx + _room.dx),
      offset.dy.clamp(-_room.dy, _maxScroll.dy + _room.dy),
    );
  }

  Offset get _centroid {
    Offset sum = Offset.zero;
    for (final Offset touch in _touches.values) {
      sum += touch;
    }
    return sum / _touches.length.toDouble();
  }

  bool _isPalmSized(PointerEvent event) {
    return event.kind == PointerDeviceKind.touch &&
        (event.radiusMajor >= _palmRadius ||
            event.radiusMinor >= _palmRadius ||
            event.size >= _androidPalmSize);
  }

  void _blockNavigationForPalm() {
    if (_palmGestureBlocked) return;
    _palmGestureBlocked = true;
    _touches.clear();
    _scrolling = false;
    _navigating = false;
    _pullCandidate = false;
    _waitingForTouchRelease = false;
    _pull.value = 0;
    _stopInertia();
    _completeScroll();
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_inertiaTicker.isActive) {
      _stopInertia();
      _completeScroll();
    }
    final _ColumnLayout? layout = _layout;
    if (layout != null) {
      final Offset content =
          event.localPosition + _offset - Offset(0, layout.top);
      final int? page = layout.pageContaining(content);
      if (page != null) {
        _shownPage = page;
        _reported.add(page);
        widget.onPageTouched?.call(page);
      }
    }
    if (event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus) {
      _styluses.add(event.pointer);
      return;
    }
    if (event.kind != PointerDeviceKind.touch) {
      return;
    }
    _activeTouches.add(event.pointer);
    if (_isPalmSized(event)) {
      _blockNavigationForPalm();
      return;
    }
    if (_palmGestureBlocked) {
      return;
    }
    if (widget.pointerClaims?.contains(event.pointer) ?? false) {
      return;
    }
    _touches[event.pointer] = event.localPosition;
    if (_fingersNavigate) {
      _navigating = true;
      _beginDrag(event.timeStamp);
      return;
    }
    if (!_scrolling && _touches.length >= 2) {
      if (_canScroll || _zoom != 1) {
        _waitingForTouchRelease = false;
        _scrolling = true;
        _beginDrag(event.timeStamp);
        _scrollEndPending = true;
        widget.onScrollStart?.call(Set<int>.of(_touches.keys));
      } else if (widget.onPullToAddPage != null && !_pullCandidate) {
        _pullCandidate = true;
        _pullStart = _centroid;
      }
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_activeTouches.contains(event.pointer) && _isPalmSized(event)) {
      _blockNavigationForPalm();
    }
    if (_palmGestureBlocked) {
      return;
    }
    if (!_touches.containsKey(event.pointer)) {
      return;
    }
    final Offset before = _centroid;
    final double spreadBefore = _spread(before);
    _touches[event.pointer] = event.localPosition;
    if (_navigating && _styluses.isNotEmpty) {
      // A palm under the writing hand.
      return;
    }
    if (_pullCandidate && !_scrolling) {
      final Offset moved = _centroid - _pullStart;
      if (-moved.dy > _pullSlop && -moved.dy > moved.dx.abs()) {
        _pullCandidate = false;
        _scrolling = true;
        _beginDrag(event.timeStamp);
        _scrollEndPending = true;
        widget.onScrollStart?.call(Set<int>.of(_touches.keys));
        _trackPull(-moved.dy);
        return;
      }
    }
    if (_scrolling || _navigating) {
      final Offset after = _centroid;
      final Offset delta = before - after;
      if (_navigating && delta != Offset.zero && !_scrollEndPending) {
        _scrollEndPending = true;
        widget.onScrollStart?.call(const <int>{});
      }
      scrollBy(delta);
      _trackPull(delta.dy);
      _recordDragVelocity(delta, event.timeStamp);
      if (_touches.length >= 2 && spreadBefore > 0) {
        _zoomAround(after, _spread(after) / spreadBefore);
      }
    }
  }

  void _onPointerEnd(PointerEvent event) {
    _styluses.remove(event.pointer);
    if (event.kind == PointerDeviceKind.touch) {
      _activeTouches.remove(event.pointer);
      if (_palmGestureBlocked) {
        if (_activeTouches.isEmpty) {
          _palmGestureBlocked = false;
        }
        return;
      }
    }
    if (_touches.remove(event.pointer) == null) {
      return;
    }
    if (_touches.length < 2) {
      _pullCandidate = false;
    }
    if (_navigating && _touches.isEmpty) {
      _navigating = false;
      final bool pulled = _pull.value > 0;
      _releasePull();
      if (pulled || !_startInertia(event.timeStamp)) _completeScroll();
    }
    if (_scrolling && _touches.length < 2) {
      _scrolling = false;
      final bool pulled = _pull.value > 0;
      _releasePull();
      if (pulled) {
        _waitingForTouchRelease = false;
        _completeScroll();
      } else if (_touches.isEmpty) {
        _waitingForTouchRelease = false;
        if (!_startInertia(event.timeStamp)) _completeScroll();
      } else {
        // Do not let the content coast under the last finger. Preserve the
        // velocity briefly, then begin momentum only when that finger lifts.
        _waitingForTouchRelease = true;
      }
    } else if (_waitingForTouchRelease && _touches.isEmpty) {
      _waitingForTouchRelease = false;
      if (!_startInertia(event.timeStamp)) _completeScroll();
    }
  }

  /// Counts a scroll of [dy] toward the column's end, made while already
  /// there, as pulling it further; a scroll back eases the pull off.
  void _trackPull(double dy) {
    if (widget.onPullToAddPage == null || dy == 0) {
      return;
    }
    final bool atEnd = _offset.dy >= _maxScroll.dy + _room.dy - 0.5;
    if (dy > 0 && atEnd) {
      _pull.value += dy;
    } else if (dy < 0 && _pull.value > 0) {
      _pull.value = math.max(0, _pull.value + dy);
    }
  }

  /// Let go: a pull far enough adds a page.
  void _releasePull() {
    final bool far = _pull.value >= widget.pullToAddDistance;
    _pull.value = 0;
    if (far) {
      widget.onPullToAddPage?.call();
    }
  }

  /// The fingers' mean distance from [centroid].
  double _spread(Offset centroid) {
    if (_touches.length < 2) {
      return 0;
    }
    double sum = 0;
    for (final Offset touch in _touches.values) {
      sum += (touch - centroid).distance;
    }
    return sum / _touches.length;
  }

  /// Zooms by [factor], keeping what is under [focal] there.
  void _zoomAround(Offset focal, double factor) {
    final double next = (_zoom * factor).clamp(widget.minZoom, widget.maxZoom);
    final _ColumnLayout? previous = _layout;
    if (next == _zoom || !next.isFinite || previous == null) {
      return;
    }
    final double ratio = next / _zoom;
    final _ColumnLayout after = _ColumnLayout(
      widget.pages,
      previous.viewport,
      widget.pageGap,
      next,
      lead: _lead,
    );
    final Offset inColumn = focal + _offset - Offset(0, previous.top);
    final int page = previous.pageAt(inColumn.dy);
    final Rect from = previous.rects[page];
    final Rect to = after.rects[page];
    setState(() {
      _zoom = next;
      // Both fingers of a pinch report before the next frame lays out the
      // column. Keep the geometry and its scroll limits in step with the
      // zoom, so the next finger's pan neither maps through a stale column
      // nor is clamped to the smaller one it had, which scrolls the page.
      _adoptLayout(after);
      // Page gaps and the space centering a short column do not scale. Map
      // through the page itself so neither can turn a pure pinch into a
      // vertical scroll. This is clamped when the new column is laid out.
      _offset = Offset(
        to.left + (inColumn.dx - from.left) * ratio - focal.dx,
        after.top + to.top + (inColumn.dy - from.top) * ratio - focal.dy,
      );
    });
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent && _canScroll) {
      GestureBinding.instance.pointerSignalResolver.register(event, (
        PointerSignalEvent event,
      ) {
        scrollBy((event as PointerScrollEvent).scrollDelta);
      });
    }
  }

  void _onPanZoomStart(PointerPanZoomStartEvent event) {
    if (_inertiaTicker.isActive) {
      _stopInertia();
      _completeScroll();
    }
    _panZoomScale = 1;
    _beginDrag(event.timeStamp);
    _scrollEndPending = true;
    widget.onScrollStart?.call(const <int>{});
  }

  void _onPanZoomEnd(PointerPanZoomEndEvent event) {
    final bool pulled = _pull.value > 0;
    _releasePull();
    if (pulled || !_startInertia(event.timeStamp)) _completeScroll();
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    final Offset delta = -event.localPanDelta;
    scrollBy(delta);
    _trackPull(delta.dy);
    _recordDragVelocity(delta, event.timeStamp);
    if (event.scale > 0 && event.scale != _panZoomScale) {
      _zoomAround(event.localPosition, event.scale / _panZoomScale);
      _panZoomScale = event.scale;
    }
  }

  /// Starts a fresh velocity sample for a finger or trackpad drag.
  void _beginDrag(Duration timeStamp) {
    _dragVelocity = Offset.zero;
    _lastDragUpdate = timeStamp;
  }

  /// Blends recent samples so a lifted hand continues in the direction and
  /// speed it was travelling, without a single noisy event causing a jump.
  void _recordDragVelocity(Offset delta, Duration timeStamp) {
    final Duration? previous = _lastDragUpdate;
    _lastDragUpdate = timeStamp;
    if (previous == null) return;
    final double seconds = (timeStamp - previous).inMicroseconds / 1000000;
    if (seconds <= 0) return;
    Offset sample = delta / seconds;
    // A malformed or tightly batched pointer timestamp must not turn one
    // event into a page-sized ballistic step.
    const double maxVelocity = 8000;
    if (sample.distance > maxVelocity) {
      sample = sample / sample.distance * maxVelocity;
    }
    // A reversal transfers control immediately. Blending it with the old
    // direction can otherwise make the page coast backwards on release.
    if (_dragVelocity != Offset.zero &&
        _dragVelocity.dx * sample.dx + _dragVelocity.dy * sample.dy <= 0) {
      _dragVelocity = sample;
    } else {
      _dragVelocity = Offset.lerp(_dragVelocity, sample, 0.55)!;
    }
    widget.onScrollSpeed?.call(_dragVelocity.distance);
  }

  bool _startInertia(Duration releasedAt) {
    // A normal two-finger reposition ends exactly where it was released;
    // only a genuine flick earns a coast.
    final Duration? last = _lastDragUpdate;
    if (_dragVelocity.distance < 250 ||
        _maxScroll == Offset.zero ||
        last == null ||
        releasedAt - last > const Duration(milliseconds: 80)) {
      _dragVelocity = Offset.zero;
      return false;
    }
    // Flutter's iOS scroll simulation derives this from
    // UIScrollView.DecelerationRate.normal (0.998 per millisecond).
    const double drag = 0.135;
    const Tolerance tolerance = Tolerance(
      distance: 0.5,
      velocity: 18,
      time: 0.01,
    );
    final bool canMoveX = _dragVelocity.dx < 0
        ? _offset.dx > -_room.dx
        : _offset.dx < _maxScroll.dx + _room.dx;
    final bool canMoveY = _dragVelocity.dy < 0
        ? _offset.dy > -_room.dy
        : _offset.dy < _maxScroll.dy + _room.dy;
    _inertiaX = _dragVelocity.dx.abs() < 1 || !canMoveX
        ? null
        : FrictionSimulation(
            drag,
            _offset.dx,
            _dragVelocity.dx,
            tolerance: tolerance,
          );
    _inertiaY = _dragVelocity.dy.abs() < 1 || !canMoveY
        ? null
        : FrictionSimulation(
            drag,
            _offset.dy,
            _dragVelocity.dy,
            tolerance: tolerance,
          );
    if (_inertiaX == null && _inertiaY == null) {
      _dragVelocity = Offset.zero;
      return false;
    }
    _inertiaTime = 0;
    _inertiaPosition = _offset;
    _lastInertiaTick = null;
    _inertiaTicker.start();
    return true;
  }

  void _stopInertia() {
    if (_inertiaTicker.isActive) _inertiaTicker.stop();
    _lastInertiaTick = null;
    _inertiaX = null;
    _inertiaY = null;
    _inertiaTime = 0;
    _dragVelocity = Offset.zero;
  }

  /// A pen set down while the column only coasts on, or waits for the last
  /// finger of a pinch to lift, stops it where it is and ends the scroll,
  /// so the pen can write at once. The page's own handlers see the press
  /// before this viewport does, and a native stylus stroke before either,
  /// so they ask here first. Returns false while fingers are still moving
  /// the column: the pen waits for them.
  bool yieldToPen() {
    if (_scrolling || (_navigating && _touches.isNotEmpty)) {
      return false;
    }
    _waitingForTouchRelease = false;
    _stopInertia();
    _completeScroll();
    return true;
  }

  void _completeScroll() {
    if (!_scrollEndPending) return;
    _scrollEndPending = false;
    widget.onScrollEnd?.call();
  }

  /// Applies exponentially decaying velocity on every frame. The custom
  /// viewport needs this explicitly because it is driven by raw gestures,
  /// rather than Flutter's [Scrollable] physics.
  void _tickInertia(Duration elapsed) {
    final Duration? previous = _lastInertiaTick;
    _lastInertiaTick = elapsed;
    if (previous == null) return;
    final double elapsedSeconds = (elapsed - previous).inMicroseconds / 1000000;
    if (elapsedSeconds <= 0) return;
    // Do not catch up a stalled raster frame in one visible leap. Normal
    // 60/120 Hz frames use their exact interval; only a missed frame is
    // time-dilated, preserving continuity instead of teleporting the page.
    _inertiaTime += math.min(elapsedSeconds, 1 / 30);
    final FrictionSimulation? x = _inertiaX;
    final FrictionSimulation? y = _inertiaY;
    final Offset target = Offset(
      x?.x(_inertiaTime) ?? _inertiaPosition.dx,
      y?.x(_inertiaTime) ?? _inertiaPosition.dy,
    );
    final Offset before = _offset;
    scrollBy(target - _inertiaPosition);
    _inertiaPosition = target;
    if (_offset.dx == before.dx && target.dx != before.dx) _inertiaX = null;
    if (_offset.dy == before.dy && target.dy != before.dy) _inertiaY = null;

    final double vx = _inertiaX?.dx(_inertiaTime) ?? 0;
    final double vy = _inertiaY?.dx(_inertiaTime) ?? 0;
    _dragVelocity = Offset(vx, vy);
    widget.onScrollSpeed?.call(_dragVelocity.distance);
    if ((_inertiaX == null || _inertiaX!.isDone(_inertiaTime)) &&
        (_inertiaY == null || _inertiaY!.isDone(_inertiaTime))) {
      _stopInertia();
      _completeScroll();
    }
  }

  ValueNotifier<Rect> _visibleFor(Key key) {
    return _visible.putIfAbsent(key, () => ValueNotifier<Rect>(Rect.zero));
  }

  ValueNotifier<double> _scaleFor(Key key) {
    return _scales.putIfAbsent(key, () => ValueNotifier<double>(1));
  }

  /// The scroll offset that brings [PageViewport.boardFocus] into view on
  /// the whiteboard laid out in [layout]: centered when it fits, else with
  /// its top-left corner [_overscroll] in from the area's.
  Offset _boardOffset(_ColumnLayout layout) {
    final Size viewport = layout.viewport;
    final double scale = widget.pages.single.scale * _zoom;
    final Rect page = layout.rects.single;
    final Rect focus =
        widget.boardFocus ??
        Rect.fromCenter(
          center: Offset(page.width / scale / 2, page.height / scale / 2),
          width: 0,
          height: 0,
        );
    final Rect shown = Rect.fromLTRB(
      focus.left * scale,
      focus.top * scale,
      focus.right * scale,
      focus.bottom * scale,
    ).shift(page.topLeft + Offset(0, layout.top));
    double along(double start, double end, double extent) {
      return end - start <= extent
          ? (start + end) / 2 - extent / 2
          : start - _overscroll;
    }

    return Offset(
      along(shown.left, shown.right, viewport.width),
      along(shown.top, shown.bottom, viewport.height),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size viewport = constraints.biggest;
        final _ColumnLayout? previous = _layout;
        if (_jumpPending ||
            (previous != null && previous.viewport != viewport)) {
          _lead = 0;
        }
        _ColumnLayout layout =
            previous?.matches(
                  widget.pages,
                  viewport,
                  widget.pageGap,
                  _zoom,
                  _lead,
                ) ??
                false
            ? previous!
            : _ColumnLayout(
                widget.pages,
                viewport,
                widget.pageGap,
                _zoom,
                lead: _lead,
              );
        // The room past the column's edges is the reader's to scroll into:
        // a resize, such as the AI panel opening, that keeps the same place
        // in view lands there only if the column was already past an edge.
        bool withinEdges = false;
        if (previous != null &&
            previous.viewport != viewport &&
            previous.rects.length == layout.rects.length &&
            !_jumpPending) {
          withinEdges =
              _offset.dx >= 0 &&
              _offset.dy >= 0 &&
              _offset.dx <= _maxScroll.dx &&
              _offset.dy <= _maxScroll.dy;
          _offset = _anchoredOffset(previous, layout);
        }
        // Pages added below the one shown leave it exactly where it was on
        // screen; nothing jumps.
        final int shown = widget.currentPage;
        if (previous != null &&
            previous.viewport == viewport &&
            layout.rects.length > previous.rects.length &&
            shown < previous.rects.length &&
            !_jumpPending) {
          final double onScreen =
              previous.rects[shown].top + previous.top - _offset.dy;
          // Where the column's top must be, scrolled to its start, for
          // the page to stay put.
          final double neededTop = onScreen - layout.rects[shown].top;
          if (neededTop > layout.top) {
            _lead = neededTop;
            layout = _ColumnLayout(
              widget.pages,
              viewport,
              widget.pageGap,
              _zoom,
              lead: _lead,
            );
          }
          final double offset = layout.top - neededTop;
          _offset = Offset(_offset.dx, offset);
        }
        _adoptLayout(layout);
        if (widget.infinite) {
          _jumpPending = false;
          if (!_boardPlaced) {
            _boardPlaced = true;
            _offset = _boardOffset(layout);
          }
        } else if (_jumpPending && widget.currentPage < widget.pages.length) {
          _jumpPending = false;
          _offset = Offset(0, layout.rects[widget.currentPage].top);
        }
        _offset = _clamp(_offset);
        if (withinEdges) {
          _offset = Offset(
            _offset.dx.clamp(0, _maxScroll.dx),
            _offset.dy.clamp(0, _maxScroll.dy),
          );
        }

        // Forget the pages that are gone.
        final Set<Key> keys = widget.pageKeys.toSet();
        _visible.removeWhere((Key key, ValueNotifier<Rect> visible) {
          final bool gone = !keys.contains(key);
          if (gone) {
            visible.dispose();
          }
          return gone;
        });
        _scales.removeWhere((Key key, ValueNotifier<double> scale) {
          final bool gone = !keys.contains(key);
          if (gone) {
            scale.dispose();
          }
          return gone;
        });

        final Rect area = Offset.zero & viewport;
        // Pages within a screen of the visible area are built.
        final Rect builtArea = area.inflate(viewport.height);
        final AppColors colors = AppColors.of(context);
        if (!identical(colors, _builtPagesColors)) {
          _builtPagesColors = colors;
          _builtPages.clear();
        }
        final Set<Key> builtKeys = <Key>{};
        // A lone page that fills the area is the writing surface itself;
        // otherwise, or scrolled past an edge, each page is a sheet of its
        // own on the background.
        bool coversArea = widget.infinite;
        if (!coversArea && widget.pages.length == 1) {
          final Rect onScreen = layout.rects.single.shift(
            Offset(-_offset.dx, layout.top - _offset.dy),
          );
          coversArea =
              onScreen.left <= 0 &&
              onScreen.top <= 0 &&
              onScreen.right >= viewport.width &&
              onScreen.bottom >= viewport.height;
        }
        final bool isDark = Theme.of(context).brightness == Brightness.dark;
        final Color deskColor = Color.lerp(
          colors.background,
          colors.shadow,
          isDark ? 0.16 : 0.025,
        )!;
        final Color borderColor = Color.lerp(
          colors.divider,
          colors.shadow,
          isDark ? 0.25 : 0.10,
        )!;
        final List<BoxShadow> sheetShadows = <BoxShadow>[
          BoxShadow(
            color: colors.shadow.withValues(alpha: isDark ? 0.35 : 0.07),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
          BoxShadow(
            color: colors.shadow.withValues(alpha: isDark ? 0.30 : 0.06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ];
        final List<Widget> sheets = <Widget>[];
        final List<Widget> pages = <Widget>[];
        final List<Widget> edges = <Widget>[];
        final double columnTop = layout.top - _offset.dy;
        final int firstBuilt = layout.pageAt(builtArea.top - columnTop);
        final int lastBuilt = layout.pageAt(builtArea.bottom - columnTop);
        for (int i = firstBuilt; i <= lastBuilt; i++) {
          final PageTransform transform = _transformOf(layout, i);
          final Rect onScreen = layout.rects[i].shift(
            transform.origin - layout.rects[i].topLeft,
          );
          if (!onScreen.overlaps(builtArea)) {
            continue;
          }
          if (!coversArea) {
            sheets.add(
              Positioned.fromRect(
                rect: onScreen,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.writingSurface,
                    boxShadow: sheetShadows,
                  ),
                ),
              ),
            );
            edges.add(
              Positioned.fromRect(
                rect: onScreen,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: borderColor,
                        width: AppSizes.hairline,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
          final PageGeometry geometry = widget.pages[i];
          builtKeys.add(widget.pageKeys[i]);
          // Only the painter of the page's rules listens, so this is safe
          // during layout.
          final ValueNotifier<Rect> visible = _visibleFor(widget.pageKeys[i])
            ..value = Rect.fromPoints(
              transform.invert(Offset.zero),
              transform.invert(viewport.bottomRight(Offset.zero)),
            );
          final ValueNotifier<double> scale = _scaleFor(widget.pageKeys[i])
            ..value = transform.scale;
          pages.add(
            Positioned(
              key: widget.pageKeys[i],
              left: transform.origin.dx,
              top: transform.origin.dy,
              width: geometry.pageSize.width,
              height: geometry.pageSize.height,
              child: Transform.scale(
                scale: transform.scale,
                alignment: Alignment.topLeft,
                child: ColoredBox(
                  color: colors.writingSurface,
                  child: _PageScaleScope(
                    scale: scale,
                    child: _builtPages[widget.pageKeys[i]] ??= widget
                        .pageBuilder(context, i, visible),
                  ),
                ),
              ),
            ),
          );
        }
        _builtPages.removeWhere(
          (Key key, Widget _) => !builtKeys.contains(key),
        );
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerEnd,
          onPointerCancel: _onPointerEnd,
          onPointerSignal: _onPointerSignal,
          onPointerPanZoomStart: _onPanZoomStart,
          onPointerPanZoomUpdate: _onPanZoomUpdate,
          onPointerPanZoomEnd: _onPanZoomEnd,
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                if (!coversArea) ColoredBox(color: deskColor),
                // Below the pages, so only a tap that misses them lands.
                if (widget.onDeskTap != null)
                  GestureDetector(
                    key: const ValueKey<String>('page-desk'),
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onDeskTap,
                  ),
                ...sheets,
                ...pages,
                ...edges,
                if (widget.overlayBuilder != null &&
                    widget.currentPage < widget.pages.length)
                  widget.overlayBuilder!(
                    context,
                    _transformOf(layout, widget.currentPage),
                  ),
                if (_canScroll && !widget.infinite)
                  IgnorePointer(
                    child: CustomPaint(
                      key: const ValueKey<String>('page-scroll-indicators'),
                      painter: _ScrollIndicatorPainter(
                        offset: Offset(
                          _offset.dx.clamp(0, _maxScroll.dx),
                          _offset.dy.clamp(0, _maxScroll.dy),
                        ),
                        maxScroll: _maxScroll,
                        color: colors.textSecondary.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                if (widget.onPullToAddPage != null)
                  IgnorePointer(
                    child: _PullToAddIndicator(
                      pull: _pull,
                      distance: widget.pullToAddDistance,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Makes [layout] the column, with the scroll limits it sets.
  void _adoptLayout(_ColumnLayout layout) {
    final Size viewport = layout.viewport;
    _layout = layout;
    _maxScroll = Offset(
      math.max(0, layout.size.width - viewport.width),
      math.max(0, layout.size.height + layout.top - viewport.height),
    );
    // A whiteboard has no edge to bring in from the screen's.
    _room = widget.infinite
        ? Offset.zero
        : Offset(
            layout.rects.any((Rect rect) => rect.width >= viewport.width - 0.5)
                ? _overscroll
                : 0,
            layout.size.height >= viewport.height - 0.5 ? _overscroll : 0,
          );
  }

  /// The scroll offset in [next] that keeps the middle of the area at the
  /// same place on the same page as in [previous]. Resizing the area, as
  /// the AI panel does when it opens or closes beside the page, rescales
  /// every page fit to its width, so a pixel offset kept as it was would
  /// land somewhere else in the note, often on another page.
  Offset _anchoredOffset(_ColumnLayout previous, _ColumnLayout next) {
    final Size before = previous.viewport;
    final Size after = next.viewport;
    final double middle = _offset.dy + before.height / 2 - previous.top;
    final int page = previous.pageAt(middle);
    final Rect from = previous.rects[page];
    final Rect to = next.rects[page];
    final double down = from.height > 0 ? (middle - from.top) / from.height : 0;
    final double across = previous.size.width > 0
        ? (_offset.dx + before.width / 2) / previous.size.width
        : 0;
    return Offset(
      across * next.size.width - after.width / 2,
      to.top + down * to.height + next.top - after.height / 2,
    );
  }

  PageTransform _transformOf(_ColumnLayout layout, int index) {
    final Rect rect = layout.rects[index];
    return PageTransform(
      scale: widget.pages[index].scale * _zoom,
      origin: Offset(
        rect.left - _offset.dx,
        rect.top + layout.top - _offset.dy,
      ),
    );
  }
}

/// Hands the pages below it how far they are scaled on screen.
class _PageScaleScope extends InheritedWidget {
  const _PageScaleScope({required this.scale, required super.child});

  final ValueListenable<double> scale;

  @override
  bool updateShouldNotify(_PageScaleScope oldWidget) {
    return !identical(oldWidget.scale, scale);
  }
}

/// Rises from the bottom of the area as the column is pulled past its end:
/// "Pull up to add a page", then, pulled far enough, "Release to add a
/// page".
class _PullToAddIndicator extends StatelessWidget {
  const _PullToAddIndicator({required this.pull, required this.distance});

  final ValueListenable<double> pull;
  final double distance;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return ValueListenableBuilder<double>(
      valueListenable: pull,
      builder: (BuildContext context, double pulled, Widget? _) {
        if (pulled <= 0) {
          return const SizedBox.shrink();
        }
        final double progress = (pulled / distance).clamp(0.0, 1.0);
        final bool ready = progress >= 1;
        return Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.only(
              bottom: AppSpacing.md + AppSpacing.xl * progress,
            ),
            child: Opacity(
              opacity: 0.4 + 0.6 * progress,
              child: DecoratedBox(
                key: const ValueKey<String>('pull-to-add-page'),
                decoration: BoxDecoration(
                  color: ready ? colors.accent : colors.surface,
                  borderRadius: AppBorderRadius.large,
                  border: Border.all(
                    color: ready ? colors.accent : colors.divider,
                    width: AppSizes.hairline,
                  ),
                  boxShadow: AppShadows.floating(colors),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.xs,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        ready ? AppIcons.newNote : AppIcons.up,
                        size: AppSizes.icon,
                        color: ready ? colors.onAccent : colors.textSecondary,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Text(
                        ready
                            ? 'Release to add a page'
                            : 'Pull up to add a page',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: ready ? colors.onAccent : colors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Where each page sits in the column, in viewport pixels with the column's
/// top at zero, before scrolling.
class _ColumnLayout {
  _ColumnLayout(
    this.pages,
    this.viewport,
    this.gap,
    this.zoom, {
    this.lead = 0,
  }) {
    double y = 0;
    double right = viewport.width;
    for (final PageGeometry page in pages) {
      if (rects.isNotEmpty) {
        y += gap;
      }
      final Size display = page.displaySize * zoom;
      final double x = math.max(0, (viewport.width - display.width) / 2);
      rects.add(Rect.fromLTWH(x, y, display.width, display.height));
      y += display.height;
      right = math.max(right, x + display.width);
    }
    size = Size(right, y);
    top = math.max(y < viewport.height ? (viewport.height - y) / 2 : 0, lead);
  }

  final List<PageGeometry> pages;
  final Size viewport;
  final double gap;
  final double zoom;
  final double lead;
  final List<Rect> rects = <Rect>[];
  late final Size size;

  /// How far a column shorter than the area is moved down to center it,
  /// or the lead kept above the first page, whichever is more.
  late final double top;

  bool matches(
    List<PageGeometry> pages,
    Size viewport,
    double gap,
    double zoom,
    double lead,
  ) =>
      identical(this.pages, pages) &&
      this.viewport == viewport &&
      this.gap == gap &&
      this.zoom == zoom &&
      this.lead == lead;

  /// The page at height [y] in the column, clamped to the first and last.
  /// A gap belongs to the page below it.
  int pageAt(double y) {
    int low = 0;
    int high = rects.length;
    while (low < high) {
      final int middle = low + ((high - low) >> 1);
      if (y < rects[middle].bottom) {
        high = middle;
      } else {
        low = middle + 1;
      }
    }
    return low.clamp(0, rects.length - 1);
  }

  /// The page under [point] in the column, if any.
  int? pageContaining(Offset point) {
    if (rects.isEmpty) return null;
    final int candidate = pageAt(point.dy);
    return rects[candidate].contains(point) ? candidate : null;
  }
}

/// Slim bars at the trailing and bottom edges showing where the visible
/// part sits in the column.
class _ScrollIndicatorPainter extends CustomPainter {
  const _ScrollIndicatorPainter({
    required this.offset,
    required this.maxScroll,
    required this.color,
  });

  static const double _thickness = 3;
  static const double _inset = AppSpacing.xxs;
  static const double _minLength = AppSpacing.lg;

  final Offset offset;
  final Offset maxScroll;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()..color = color;
    const Radius radius = Radius.circular(_thickness / 2);
    if (maxScroll.dy > 0) {
      final double track = size.height - 2 * _inset;
      final double length = math.max(
        _minLength,
        track * size.height / (size.height + maxScroll.dy),
      );
      final double top = _inset + (track - length) * offset.dy / maxScroll.dy;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            size.width - _inset - _thickness,
            top,
            _thickness,
            length,
          ),
          radius,
        ),
        paint,
      );
    }
    if (maxScroll.dx > 0) {
      final double track = size.width - 2 * _inset;
      final double length = math.max(
        _minLength,
        track * size.width / (size.width + maxScroll.dx),
      );
      final double left = _inset + (track - length) * offset.dx / maxScroll.dx;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            left,
            size.height - _inset - _thickness,
            length,
            _thickness,
          ),
          radius,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_ScrollIndicatorPainter oldDelegate) {
    return oldDelegate.offset != offset ||
        oldDelegate.maxScroll != maxScroll ||
        oldDelegate.color != color;
  }
}
