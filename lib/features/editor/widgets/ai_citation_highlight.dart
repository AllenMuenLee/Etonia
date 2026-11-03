import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../ai/ai_assistant_controller.dart';
import '../ai/ai_citation.dart';
import '../ink/ink_controller.dart';
import '../ink/stroke.dart';
import '../page/page_viewport.dart';

/// The highlighter's color, on the note and beside the paragraph in the chat.
const Color aiCitationHighlightColor = Color(0xFFFFE600);

/// The ring around a detail of a picture. Yellow would vanish on white paper.
const Color aiCitationRingColor = Color(0xFFE5342B);

/// The ring around [detail]: an oval through its corners, so that all of it is
/// inside. A long thin detail, such as a printed line, gets a slim oval that
/// reaches just past its ends, rather than one far longer than it.
Rect aiCitationRing(Rect detail) {
  const double clearance = 12;
  const double smallest = 28;
  final double long = math.max(detail.width, detail.height) / 2;
  final double short = math.min(detail.width, detail.height) / 2;
  if (long <= 0) {
    return Rect.fromCenter(
      center: detail.center,
      width: smallest,
      height: smallest,
    );
  }
  final double reach = math.min(
    long * math.sqrt2,
    long + short * (math.sqrt2 - 1) + clearance,
  );
  final double fit = long / reach;
  final double across = short / math.sqrt(1 - fit * fit);
  final bool wide = detail.width >= detail.height;
  return Rect.fromCenter(
    center: detail.center,
    width: math.max((wide ? reach : across) * 2, smallest),
    height: math.max((wide ? across : reach) * 2, smallest),
  );
}

/// Left before what is too big to fit in view.
const double _revealMargin = 24;

/// Scrolls the page viewport around [context], which is laid out in page
/// coordinates, so that all of [bounds] is in view, or moves nothing if it
/// already is. What is too big to fit shows from its start. Returns false when
/// there is no viewport, or nothing is laid out yet.
bool revealAiCitationBounds(BuildContext context, Rect bounds) {
  final RenderObject? box = context.findRenderObject();
  final PageViewportState? viewport = context
      .findAncestorStateOfType<PageViewportState>();
  final RenderObject? viewportBox = viewport?.context.findRenderObject();
  if (box is! RenderBox ||
      viewportBox is! RenderBox ||
      !box.hasSize ||
      !viewportBox.hasSize) {
    return false;
  }
  final Rect marked = Rect.fromPoints(
    box.localToGlobal(bounds.topLeft, ancestor: viewportBox),
    box.localToGlobal(bounds.bottomRight, ancestor: viewportBox),
  );
  final Rect shown = Offset.zero & viewportBox.size;
  if (marked.left >= shown.left &&
      marked.top >= shown.top &&
      marked.right <= shown.right &&
      marked.bottom <= shown.bottom) {
    return true;
  }
  double along(double start, double end, double extent) {
    return end - start <= extent
        ? (start + end - extent) / 2
        : start - _revealMargin;
  }

  viewport!.scrollBy(
    Offset(
      along(marked.left, marked.right, shown.width),
      along(marked.top, marked.bottom, shown.height),
    ),
  );
  return true;
}

/// The marks themselves: a highlighter under [strokes], and a ring round each
/// of [circles]. Goes under the ink, in page coordinates, and takes no touches.
class AiCitationMarks extends StatelessWidget {
  const AiCitationMarks({
    super.key,
    this.strokes = const <Stroke>[],
    this.circles = const <Rect>[],
  });

  final List<Stroke> strokes;
  final List<Rect> circles;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        key: const ValueKey<String>('ai-citation-highlight-layer'),
        painter: _CitationPainter(strokes: strokes, circles: circles),
        size: Size.infinite,
      ),
    );
  }
}

/// Marks on one page of an open note what was cited elsewhere, by [marks], and
/// brings it into view each time [marks] names this page anew.
class AiNoteMarksLayer extends StatefulWidget {
  const AiNoteMarksLayer({
    super.key,
    required this.marks,
    required this.pageIndex,
    required this.page,
  });

  final ValueListenable<AiNoteMarks?> marks;
  final int pageIndex;
  final InkController page;

  @override
  State<AiNoteMarksLayer> createState() => _AiNoteMarksLayerState();
}

class _AiNoteMarksLayerState extends State<AiNoteMarksLayer> {
  AiNoteMarks? _revealed;

  AiNoteMarks? get _here {
    final AiNoteMarks? marks = widget.marks.value;
    return marks?.pageIndex == widget.pageIndex ? marks : null;
  }

  @override
  void initState() {
    super.initState();
    widget.marks.addListener(_scheduleReveal);
    _scheduleReveal();
  }

  @override
  void didUpdateWidget(AiNoteMarksLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.marks, widget.marks)) {
      oldWidget.marks.removeListener(_scheduleReveal);
      widget.marks.addListener(_scheduleReveal);
    }
    _scheduleReveal();
  }

  @override
  void dispose() {
    widget.marks.removeListener(_scheduleReveal);
    super.dispose();
  }

  /// After the next layout, which is when the page is where it now is. Tried
  /// again on later builds until the page can tell.
  void _scheduleReveal() {
    final AiNoteMarks? marks = _here;
    if (marks == null || identical(marks, _revealed)) return;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted || !identical(_here, marks)) return;
      Rect? bounds;
      void include(Rect rect) => bounds = bounds?.expandToInclude(rect) ?? rect;
      marks
          .strokesIn(widget.page.strokes)
          .forEach((Stroke stroke) => include(stroke.bounds));
      marks.rings.map(aiCitationRing).forEach(include);
      if (bounds == null || revealAiCitationBounds(context, bounds!)) {
        _revealed = marks;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ExcludeSemantics(
        child: ListenableBuilder(
          listenable: Listenable.merge(<Listenable>[
            widget.marks,
            widget.page.documentRevisionListenable,
          ]),
          builder: (BuildContext context, Widget? _) {
            final AiNoteMarks? marks = _here;
            if (marks == null) return const SizedBox.expand();
            return AiCitationMarks(
              strokes: marks.strokesIn(widget.page.strokes),
              circles: marks.rings,
            );
          },
        ),
      ),
    );
  }
}

/// Marks on [page] what the paragraph last read in the chat is tied to:
/// highlights the ink it cites and the strokes drawn for it, and rings the
/// details of a picture or printed page it names. A picture is never
/// highlighted. Stays on whether or not the chat is open.
///
/// Goes under the ink, as a highlighter's mark does, so the ink stays as dark
/// and as readable as it was. It is never part of the ink.
class AiCitationHighlight extends StatefulWidget {
  const AiCitationHighlight({
    super.key,
    required this.assistant,
    required this.page,
  });

  final AiAssistantController assistant;
  final InkController page;

  @override
  State<AiCitationHighlight> createState() => _AiCitationHighlightState();
}

class _AiCitationHighlightState extends State<AiCitationHighlight> {
  @override
  void initState() {
    super.initState();
    widget.assistant.addNoteRevealer(widget.page, _reveal);
  }

  @override
  void didUpdateWidget(AiCitationHighlight oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.assistant, widget.assistant) ||
        !identical(oldWidget.page, widget.page)) {
      oldWidget.assistant.removeNoteRevealer(oldWidget.page, _reveal);
      widget.assistant.addNoteRevealer(widget.page, _reveal);
    }
  }

  @override
  void dispose() {
    widget.assistant.removeNoteRevealer(widget.page, _reveal);
    super.dispose();
  }

  /// The strokes of [links] on this page now. Links keep strokes that have
  /// been replaced or erased, for an undo to bring back.
  List<Stroke> _onPage(Set<Stroke> strokes) {
    if (strokes.isEmpty) return const <Stroke>[];
    return <Stroke>[
      for (final Stroke stroke in widget.page.strokes)
        if (strokes.contains(stroke)) stroke,
    ];
  }

  /// Whether rings belong here: on the page the chat's first chosen thing lies
  /// on.
  bool get _holdsCircles {
    final AiContextGroup? group = widget.assistant.context?.groups.firstOrNull;
    if (group == null) return false;
    final Object? owner = group.page;
    if (owner != null) return identical(owner, widget.page);
    final Stroke? anchor = group.strokes.firstOrNull;
    return anchor != null && widget.page.strokes.contains(anchor);
  }

  /// Scrolls so that all that is marked here is in view. Returns false when
  /// this page cannot tell.
  bool _reveal() {
    final AiParagraphLinks? links =
        widget.assistant.paragraphFocus.value?.links;
    if (links == null || !mounted) return false;
    Rect? bounds = _holdsCircles && links.circles.isNotEmpty
        ? links.circles
              .map(aiCitationRing)
              .reduce((Rect a, Rect b) => a.expandToInclude(b))
        : null;
    for (final Stroke stroke in <Stroke>[
      ..._onPage(links.cited),
      ..._onPage(links.drawn),
    ]) {
      bounds = bounds?.expandToInclude(stroke.bounds) ?? stroke.bounds;
    }
    return bounds != null && revealAiCitationBounds(context, bounds);
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ExcludeSemantics(
        child: ListenableBuilder(
          listenable: Listenable.merge(<Listenable>[
            widget.assistant.paragraphFocus,
            widget.page.documentRevisionListenable,
            widget.page.hiddenStrokesListenable,
          ]),
          builder: (BuildContext context, Widget? _) {
            final AiParagraphLinks? links =
                widget.assistant.paragraphFocus.value?.links;
            if (links == null) return const SizedBox.expand();
            final List<Stroke> strokes = <Stroke>[
              ..._onPage(links.cited),
              ..._onPage(links.drawn),
            ].where((Stroke it) => !widget.page.isStrokeHidden(it)).toList();
            final List<Rect> circles = _holdsCircles
                ? links.circles
                : const <Rect>[];
            if (strokes.isEmpty && circles.isEmpty) {
              return const SizedBox.expand();
            }
            return AiCitationMarks(strokes: strokes, circles: circles);
          },
        ),
      ),
    );
  }
}

class _CitationPainter extends CustomPainter {
  const _CitationPainter({required this.strokes, required this.circles});

  final List<Stroke> strokes;
  final List<Rect> circles;

  /// How far the mark reaches past a stroke's own width, on each side.
  static const double _spread = 4;
  static const double _opacity = 0.75;

  /// A ring, and the pale edge that keeps it visible on a dark picture.
  static const double _ringWidth = 3;
  static const double _ringEdgeWidth = 6;

  @override
  void paint(Canvas canvas, Size size) {
    if (strokes.isNotEmpty) _paintHighlight(canvas);
    final Paint edge = Paint()
      ..color = Colors.white.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = _ringEdgeWidth
      ..isAntiAlias = true;
    final Paint ring = Paint()
      ..color = aiCitationRingColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = _ringWidth
      ..isAntiAlias = true;
    for (final Rect circle in circles) {
      final Rect oval = aiCitationRing(circle);
      canvas
        ..drawOval(oval, edge)
        ..drawOval(oval, ring);
    }
  }

  void _paintHighlight(Canvas canvas) {
    // Drawn solid in a layer that is then faded, so strokes that cross do not
    // darken where they overlap, and a whole word reads as one mark.
    Rect? bounds;
    for (final Stroke stroke in strokes) {
      final Rect mark = stroke.bounds.inflate(stroke.style.width + _spread);
      bounds = bounds?.expandToInclude(mark) ?? mark;
    }
    canvas.saveLayer(
      bounds,
      Paint()..color = aiCitationHighlightColor.withValues(alpha: _opacity),
    );
    const Color color = aiCitationHighlightColor;
    final Paint ink = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    final Paint dot = Paint()
      ..color = color
      ..isAntiAlias = true;
    for (final Stroke stroke in strokes) {
      final double width = stroke.style.width + _spread * 2;
      if (stroke.isDot || stroke.points.length < 2) {
        if (stroke.points.isNotEmpty) {
          canvas.drawCircle(
            Offset(stroke.points.first.x, stroke.points.first.y),
            width / 2,
            dot,
          );
        }
      } else {
        canvas.drawPath(stroke.path, ink..strokeWidth = width);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CitationPainter oldDelegate) {
    return oldDelegate.strokes.length != strokes.length ||
        oldDelegate.circles.length != circles.length ||
        !_same(oldDelegate.strokes, strokes) ||
        !_same(oldDelegate.circles, circles);
  }

  static bool _same(List<Object> a, List<Object> b) {
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
