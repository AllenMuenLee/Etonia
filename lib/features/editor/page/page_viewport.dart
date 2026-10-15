import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
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
    this.onVisiblePageChanged,
    this.onScrollStart,
    this.onScrollEnd,
    this.fingersNavigate,
    this.pageGap = AppSpacing.md,
    this.minZoom = 0.5,
    this.maxZoom = 4,
  }) : assert(pages.length == pageKeys.length),
       assert(pageGap >= 0),
       assert(minZoom > 0 && minZoom <= 1 && maxZoom >= 1);

  /// While true, fingers never write, so one finger pans the column and
  /// two pan and pinch-zoom it, without [onScrollStart]: there is no stroke
  /// of theirs to drop, and a resting palm must not stop the pen. A finger
  /// is ignored while a stylus is down.
  final ValueListenable<bool>? fingersNavigate;

  /// How far a pinch can zoom the column out and in.
  final double minZoom;
  final double maxZoom;

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
  final ValueChanged<int>? onVisiblePageChanged;
  final ValueChanged<Set<int>>? onScrollStart;
  final VoidCallback? onScrollEnd;

  @override
  State<PageViewport> createState() => PageViewportState();
}

class PageViewportState extends State<PageViewport> {
  final Map<Key, ValueNotifier<Rect>> _visible = <Key, ValueNotifier<Rect>>{};
  final Map<int, Offset> _touches = <int, Offset>{};
  Offset _offset = Offset.zero;
  Offset _maxScroll = Offset.zero;
  bool _scrolling = false;

  /// Fingers moving the column in [PageViewport.fingersNavigate] mode.
  bool _navigating = false;
  final Set<int> _styluses = <int>{};

  /// The pinch zoom, on top of each page's own scale.
  double _zoom = 1;
  double _panZoomScale = 1;

  /// The page last reported, or scrolled to; a different [currentPage]
  /// means a jump.
  late int _shownPage;
  bool _jumpPending = false;

  _ColumnLayout? _layout;

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
    _shownPage = widget.currentPage;
  }

  @override
  void didUpdateWidget(PageViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentPage != _shownPage) {
      _shownPage = widget.currentPage;
      _jumpPending = true;
    }
  }

  @override
  void dispose() {
    for (final ValueNotifier<Rect> visible in _visible.values) {
      visible.dispose();
    }
    super.dispose();
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
    _touches[event.pointer] = event.localPosition;
    if (_fingersNavigate) {
      _navigating = true;
      return;
    }
    if (!_scrolling && _touches.length >= 2 && (_canScroll || _zoom != 1)) {
      _scrolling = true;
      widget.onScrollStart?.call(Set<int>.of(_touches.keys));
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
    if (_scrolling || _navigating) {
      final Offset after = _centroid;
      scrollBy(before - after);
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
    if (_navigating && _touches.isEmpty) {
      _navigating = false;
    }
    if (_scrolling && _touches.length < 2) {
      _scrolling = false;
      widget.onScrollEnd?.call();
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
    _panZoomScale = 1;
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    scrollBy(-event.localPanDelta);
    if (event.scale > 0 && event.scale != _panZoomScale) {
      _zoomAround(event.localPosition, event.scale / _panZoomScale);
      _panZoomScale = event.scale;
    }
  }

  ValueNotifier<Rect> _visibleFor(Key key) {
    return _visible.putIfAbsent(key, () => ValueNotifier<Rect>(Rect.zero));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size viewport = constraints.biggest;
        final _ColumnLayout layout = _ColumnLayout(
          widget.pages,
          viewport,
          widget.pageGap,
          _zoom,
        );
        final _ColumnLayout? previous = _layout;
        if (previous != null &&
            previous.viewport != viewport &&
            previous.rects.length == layout.rects.length &&
            !_jumpPending) {
          _offset = _anchoredOffset(previous, layout);
        }
        _layout = layout;
        _maxScroll = Offset(
          math.max(0, layout.size.width - viewport.width),
          math.max(0, layout.size.height - viewport.height),
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
            layout.size.width >= viewport.width &&
            layout.size.height >= viewport.height &&
            widget.pages.single.displaySize.width >= viewport.width;
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
                    boxShadow: AppShadows.paper(colors),
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
                        color: colors.divider,
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
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                if (!coversArea) ColoredBox(color: colors.background),
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

/// Where each page sits in the column, in viewport pixels with the column's
/// top at zero, before scrolling.
class _ColumnLayout {
  _ColumnLayout(
    List<PageGeometry> pages,
    this.viewport,
    double gap,
    double zoom,
  ) {
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
    top = y < viewport.height ? (viewport.height - y) / 2 : 0;
  }

  final Size viewport;
  final List<Rect> rects = <Rect>[];
  late final Size size;

  /// How far a column shorter than the area is moved down to center it.
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
