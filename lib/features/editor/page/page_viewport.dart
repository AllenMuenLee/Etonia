import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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
    this.fingersNavigate,
    this.pointerClaims,
    this.onPullToAddPage,
    this.pullToAddDistance = 180,
    this.pageGap = AppSpacing.md,
    this.minZoom = 0.5,
    this.maxZoom = 4,
    this.initialZoom = 1,
  }) : assert(pages.length == pageKeys.length),
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
  /// two pan and pinch-zoom it, without [onScrollStart]: there is no stroke
  /// of theirs to drop, and a resting palm must not stop the pen. A finger
  /// is ignored while a stylus is down.
  final ValueListenable<bool>? fingersNavigate;

  /// Touches a canvas has taken, such as a finger moving the ruler: they
  /// neither pan nor zoom the column.
  final PointerClaims? pointerClaims;

  /// How far a pinch can zoom the column out and in.
  final double minZoom;
  final double maxZoom;

  /// The zoom used when this viewport is first opened.
  final double initialZoom;

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

  @override
  State<PageViewport> createState() => PageViewportState();
}

class PageViewportState extends State<PageViewport>
    with SingleTickerProviderStateMixin {
  final Map<Key, ValueNotifier<Rect>> _visible = <Key, ValueNotifier<Rect>>{};
  final Map<int, Offset> _touches = <int, Offset>{};
  Offset _offset = Offset.zero;
  Offset _maxScroll = Offset.zero;
  bool _scrolling = false;

  late final Ticker _inertiaTicker;
  Duration? _lastInertiaTick;
  Duration? _lastDragUpdate;
  Offset _dragVelocity = Offset.zero;

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

  /// How far the column is scrolled, in viewport pixels.
  Offset get scrollOffset => _offset;

  /// Whether two fingers are scrolling the column.
  bool get isScrolling => _scrolling;

  /// How far the column is pinch-zoomed; 1 shows each page at its own scale.
  double get zoom => _zoom;

  bool get _fingersNavigate => widget.fingersNavigate?.value ?? false;

  bool get _canScroll => _maxScroll != Offset.zero;

  @override
  void initState() {
    super.initState();
    _zoom = widget.initialZoom;
    _shownPage = widget.currentPage;
    _inertiaTicker = createTicker(_tickInertia);
  }

  @override
  void didUpdateWidget(PageViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The editor raises the minimum to one for an infinite canvas. Apply a
    // changed bound immediately when a page is converted while this viewport
    // keeps its state.
    _zoom = _zoom.clamp(widget.minZoom, widget.maxZoom).toDouble();
    if (widget.currentPage != oldWidget.currentPage &&
        widget.currentPage != _shownPage) {
      _shownPage = widget.currentPage;
      _jumpPending = true;
    } else {
      _shownPage = widget.currentPage;
    }
  }

  @override
  void dispose() {
    _inertiaTicker.dispose();
    for (final ValueNotifier<Rect> visible in _visible.values) {
      visible.dispose();
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
      widget.onVisiblePageChanged?.call(visible);
    }
  }

  Offset _clamp(Offset offset) {
    return Offset(
      offset.dx.clamp(0, _maxScroll.dx),
      offset.dy.clamp(0, _maxScroll.dy),
    );
  }

  Offset get _centroid {
    Offset sum = Offset.zero;
    for (final Offset touch in _touches.values) {
      sum += touch;
    }
    return sum / _touches.length.toDouble();
  }

  void _onPointerDown(PointerDownEvent event) {
    _stopInertia();
    final _ColumnLayout? layout = _layout;
    if (layout != null) {
      final Offset content =
          event.localPosition + _offset - Offset(0, layout.top);
      final int? page = layout.pageContaining(content);
      if (page != null) {
        _shownPage = page;
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
        _scrolling = true;
        _beginDrag(event.timeStamp);
        widget.onScrollStart?.call(Set<int>.of(_touches.keys));
      } else if (widget.onPullToAddPage != null && !_pullCandidate) {
        _pullCandidate = true;
        _pullStart = _centroid;
      }
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
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
        widget.onScrollStart?.call(Set<int>.of(_touches.keys));
        _trackPull(-moved.dy);
        return;
      }
    }
    if (_scrolling || _navigating) {
      final Offset after = _centroid;
      final Offset delta = before - after;
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
      if (!pulled) _startInertia();
    }
    if (_scrolling && _touches.length < 2) {
      _scrolling = false;
      final bool pulled = _pull.value > 0;
      _releasePull();
      if (!pulled) _startInertia();
      widget.onScrollEnd?.call();
    }
  }

  /// Counts a scroll of [dy] toward the column's end, made while already
  /// there, as pulling it further; a scroll back eases the pull off.
  void _trackPull(double dy) {
    if (widget.onPullToAddPage == null || dy == 0) {
      return;
    }
    final bool atEnd = _offset.dy >= _maxScroll.dy - 0.5;
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
    if (next == _zoom || !next.isFinite) {
      return;
    }
    final double ratio = next / _zoom;
    final double top = _layout?.top ?? 0;
    setState(() {
      _zoom = next;
      // Clamped to the zoomed column when it is next laid out.
      _offset = (_offset + focal - Offset(0, top)) * ratio - focal;
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
    _stopInertia();
    _panZoomScale = 1;
    _beginDrag(event.timeStamp);
  }

  void _onPanZoomEnd(PointerPanZoomEndEvent event) {
    final bool pulled = _pull.value > 0;
    _releasePull();
    if (!pulled) _startInertia();
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
    final Offset sample = delta / seconds;
    _dragVelocity = Offset.lerp(_dragVelocity, sample, 0.38)!;
  }

  void _startInertia() {
    // A normal two-finger reposition ends exactly where it was released;
    // only a genuine flick earns a coast.
    if (_dragVelocity.distance < 800 || _maxScroll == Offset.zero) {
      return;
    }
    _lastInertiaTick = null;
    _inertiaTicker.start();
  }

  void _stopInertia() {
    if (_inertiaTicker.isActive) _inertiaTicker.stop();
    _lastInertiaTick = null;
    _dragVelocity = Offset.zero;
  }

  /// Applies exponentially decaying velocity on every frame. The custom
  /// viewport needs this explicitly because it is driven by raw gestures,
  /// rather than Flutter's [Scrollable] physics.
  void _tickInertia(Duration elapsed) {
    final Duration? previous = _lastInertiaTick;
    _lastInertiaTick = elapsed;
    if (previous == null) return;
    final double seconds = (elapsed - previous).inMicroseconds / 1000000;
    if (seconds <= 0) return;

    final Offset before = _offset;
    scrollBy(_dragVelocity * seconds);
    if (_offset.dx == before.dx) _dragVelocity = Offset(0, _dragVelocity.dy);
    if (_offset.dy == before.dy) _dragVelocity = Offset(_dragVelocity.dx, 0);

    // A 4.8 / s decay gives a short, natural coast without carrying past
    // the next few pages. It also remains stable on a delayed frame.
    _dragVelocity *= math.exp(-4.8 * seconds);
    if (_dragVelocity.distance < 18) _stopInertia();
  }

  ValueNotifier<Rect> _visibleFor(Key key) {
    return _visible.putIfAbsent(key, () => ValueNotifier<Rect>(Rect.zero));
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
        _ColumnLayout layout = _ColumnLayout(
          widget.pages,
          viewport,
          widget.pageGap,
          _zoom,
          lead: _lead,
        );
        if (previous != null &&
            previous.viewport != viewport &&
            previous.rects.length == layout.rects.length &&
            !_jumpPending) {
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
        _layout = layout;
        _maxScroll = Offset(
          math.max(0, layout.size.width - viewport.width),
          math.max(0, layout.size.height + layout.top - viewport.height),
        );
        if (_jumpPending && widget.currentPage < widget.pages.length) {
          _jumpPending = false;
          _offset = Offset(0, layout.rects[widget.currentPage].top);
        }
        _offset = _clamp(_offset);

        // Forget the pages that are gone.
        final Set<Key> keys = widget.pageKeys.toSet();
        _visible.removeWhere((Key key, ValueNotifier<Rect> visible) {
          final bool gone = !keys.contains(key);
          if (gone) {
            visible.dispose();
          }
          return gone;
        });

        final Rect area = Offset.zero & viewport;
        // Pages within a screen of the visible area are built.
        final Rect builtArea = area.inflate(viewport.height);
        final AppColors colors = AppColors.of(context);
        // A lone page that fills the area is the writing surface itself;
        // otherwise each page is a sheet of its own on the background.
        final bool coversArea =
            widget.pages.length == 1 &&
            layout.rects.single.width >= viewport.width &&
            layout.rects.single.height >= viewport.height;
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
        for (int i = 0; i < widget.pages.length; i++) {
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
          // Only the painter of the page's rules listens, so this is safe
          // during layout.
          final ValueNotifier<Rect> visible = _visibleFor(widget.pageKeys[i])
            ..value = Rect.fromPoints(
              transform.invert(Offset.zero),
              transform.invert(viewport.bottomRight(Offset.zero)),
            );
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
                  child: widget.pageBuilder(context, i, visible),
                ),
              ),
            ),
          );
        }
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
                if (_canScroll)
                  IgnorePointer(
                    child: CustomPaint(
                      key: const ValueKey<String>('page-scroll-indicators'),
                      painter: _ScrollIndicatorPainter(
                        offset: _offset,
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
    List<PageGeometry> pages,
    this.viewport,
    double gap,
    double zoom, {
    double lead = 0,
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

  final Size viewport;
  final List<Rect> rects = <Rect>[];
  late final Size size;

  /// How far a column shorter than the area is moved down to center it,
  /// or the lead kept above the first page, whichever is more.
  late final double top;

  /// The page at height [y] in the column, clamped to the first and last.
  /// A gap belongs to the page below it.
  int pageAt(double y) {
    for (int i = 0; i < rects.length; i++) {
      if (y < rects[i].bottom) {
        return i;
      }
    }
    return rects.length - 1;
  }

  /// The page under [point] in the column, if any.
  int? pageContaining(Offset point) {
    for (int i = 0; i < rects.length; i++) {
      if (rects[i].contains(point)) {
        return i;
      }
    }
    return null;
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
