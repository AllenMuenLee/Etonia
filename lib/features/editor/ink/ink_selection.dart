import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'ink_sample.dart';
import 'selection_geometry.dart';
import 'selection_transform.dart';
import 'stroke.dart';
import '../document_io/document_models.dart';
import '../sticky/sticky_note.dart';

/// The topmost stroke whose rendered centerline is within [tolerance] of
/// [position]. The stroke's own half-width is added to the hit radius.
Stroke? hitTestStroke(
  List<Stroke> strokes,
  InkVector position, {
  double tolerance = 16,
}) {
  if (!position.isFinite || tolerance < 0 || !tolerance.isFinite) return null;
  for (int index = strokes.length - 1; index >= 0; index--) {
    final Stroke stroke = strokes[index];
    final double reach = tolerance + stroke.style.width / 2;
    if (!stroke.bounds
        .inflate(tolerance)
        .contains(Offset(position.x, position.y))) {
      continue;
    }
    if (stroke.isDot) {
      if ((stroke.points.first - position).length <= reach) return stroke;
      continue;
    }
    for (int i = 0; i + 1 < stroke.points.length; i++) {
      final InkVector a = stroke.points[i];
      final InkVector delta = stroke.points[i + 1] - a;
      final double lengthSquared = delta.dot(delta);
      final double t = lengthSquared == 0
          ? 0
          : ((position - a).dot(delta) / lengthSquared).clamp(0.0, 1.0);
      if ((a + delta * t - position).length <= reach) return stroke;
    }
  }
  return null;
}

/// The strokes picked by a lasso, and how many got past the bounds check.
class StrokeSelectionResult {
  const StrokeSelectionResult({
    required this.indices,
    required this.candidates,
  });

  /// Indices of the overlapping strokes, each once, in document order.
  final List<int> indices;

  /// Strokes whose bounds reached the lasso's bounds, and so had their
  /// points examined.
  final int candidates;
}

/// Finds the [strokes] whose rendered ink overlaps [region]. A stroke whose
/// cached bounds miss the region's bounds is rejected without its points
/// being read.
StrokeSelectionResult selectStrokes(
  List<Stroke> strokes,
  LassoRegion region, {
  Iterable<int>? candidateIndices,
}) {
  final List<int> indices = <int>[];
  int candidates = 0;
  if (!region.isEmpty) {
    for (final int i
        in candidateIndices ?? Iterable<int>.generate(strokes.length)) {
      final Stroke stroke = strokes[i];
      final Rect bounds = stroke.bounds;
      if (!region.overlapsBounds(
        bounds.left,
        bounds.top,
        bounds.right,
        bounds.bottom,
      )) {
        continue;
      }
      candidates++;
      if (region.overlapsInk(
        stroke.points,
        width: stroke.style.width,
        isDot: stroke.isDot,
      )) {
        indices.add(i);
      }
    }
  }
  return StrokeSelectionResult(indices: indices, candidates: candidates);
}

/// Image indices whose rotated rectangles overlap [region], in paint order.
List<int> selectImages(List<NoteImageElement> images, LassoRegion region) {
  return <int>[
    for (int i = 0; i < images.length; i++)
      if (region.overlapsBounds(
            images[i].bounds.left,
            images[i].bounds.top,
            images[i].bounds.right,
            images[i].bounds.bottom,
          ) &&
          region.overlapsPolygon(images[i].corners))
        i,
  ];
}

/// The upright frame around the rendered bounds of [strokes], which must not
/// be empty.
SelectionFrame frameAround(Iterable<Stroke> strokes) {
  double left = double.infinity;
  double top = double.infinity;
  double right = double.negativeInfinity;
  double bottom = double.negativeInfinity;
  for (final Stroke stroke in strokes) {
    final Rect bounds = stroke.bounds;
    left = math.min(left, bounds.left);
    top = math.min(top, bounds.top);
    right = math.max(right, bounds.right);
    bottom = math.max(bottom, bounds.bottom);
  }
  return SelectionFrame.fromBounds(left, top, right, bottom);
}

/// Sticky-note indices whose rotated paper overlaps [region], in paint
/// order.
List<int> selectStickyNotes(List<StickyNoteElement> notes, LassoRegion region) {
  return <int>[
    for (int i = 0; i < notes.length; i++)
      if (region.overlapsBounds(
            notes[i].bounds.left,
            notes[i].bounds.top,
            notes[i].bounds.right,
            notes[i].bounds.bottom,
          ) &&
          region.overlapsPolygon(notes[i].corners))
        i,
  ];
}

/// The frame around [strokes], [images], [stickies], and [pdfBounds]. One
/// sticky note on its own gets a frame that turns with it, so its handles
/// sit on its corners.
SelectionFrame frameAroundContent(
  Iterable<Stroke> strokes,
  Iterable<NoteImageElement> images, {
  Rect? pdfBounds,
  Iterable<StickyNoteElement> stickies = const <StickyNoteElement>[],
}) {
  if (strokes.isEmpty &&
      images.isEmpty &&
      pdfBounds == null &&
      stickies.length == 1) {
    final StickyNoteElement note = stickies.first;
    final Size paper = note.paperSize;
    return SelectionFrame(
      center: note.paperCenter,
      halfWidth: paper.width / 2,
      halfHeight: paper.height / 2,
      angle: note.rotation,
    );
  }
  double left = double.infinity;
  double top = double.infinity;
  double right = double.negativeInfinity;
  double bottom = double.negativeInfinity;
  for (final Stroke stroke in strokes) {
    left = math.min(left, stroke.bounds.left);
    top = math.min(top, stroke.bounds.top);
    right = math.max(right, stroke.bounds.right);
    bottom = math.max(bottom, stroke.bounds.bottom);
  }
  for (final NoteImageElement image in images) {
    left = math.min(left, image.bounds.left);
    top = math.min(top, image.bounds.top);
    right = math.max(right, image.bounds.right);
    bottom = math.max(bottom, image.bounds.bottom);
  }
  for (final StickyNoteElement note in stickies) {
    final Rect bounds = note.bounds;
    left = math.min(left, bounds.left);
    top = math.min(top, bounds.top);
    right = math.max(right, bounds.right);
    bottom = math.max(bottom, bounds.bottom);
  }
  if (pdfBounds != null) {
    left = math.min(left, pdfBounds.left);
    top = math.min(top, pdfBounds.top);
    right = math.max(right, pdfBounds.right);
    bottom = math.max(bottom, pdfBounds.bottom);
  }
  return SelectionFrame.fromBounds(left, top, right, bottom);
}

/// The selected strokes. Immutable: every change to the selection, or to a
/// selected stroke, makes a new one.
class InkSelection {
  InkSelection({
    required List<int> indices,
    required List<Stroke> strokes,
    List<int> imageIndices = const <int>[],
    List<NoteImageElement> images = const <NoteImageElement>[],
    List<int> stickyIndices = const <int>[],
    List<StickyNoteElement> stickies = const <StickyNoteElement>[],
    this.pdfBounds,
    required this.frame,
  }) : assert(indices.length == strokes.length),
       assert(imageIndices.length == images.length),
       assert(stickyIndices.length == stickies.length),
       assert(
         indices.isNotEmpty ||
             imageIndices.isNotEmpty ||
             stickyIndices.isNotEmpty ||
             pdfBounds != null,
       ),
       indices = List<int>.unmodifiable(indices),
       strokes = List<Stroke>.unmodifiable(strokes),
       imageIndices = List<int>.unmodifiable(imageIndices),
       images = List<NoteImageElement>.unmodifiable(images),
       stickyIndices = List<int>.unmodifiable(stickyIndices),
       stickies = List<StickyNoteElement>.unmodifiable(stickies);

  /// Where the selected strokes are in the document, ascending. Selection
  /// goes by position, never by comparing geometry.
  final List<int> indices;

  /// The document's strokes at [indices], in the same order. A transform
  /// gesture previews and commits from these.
  final List<Stroke> strokes;
  final List<int> imageIndices;
  final List<NoteImageElement> images;

  /// Where the selected sticky notes are on the page, ascending, and the
  /// notes themselves, each with its own ink.
  final List<int> stickyIndices;
  final List<StickyNoteElement> stickies;

  /// The page-local rectangle of PDF paper enclosed by the lasso. The PDF
  /// remains immutable; Copy or Cut rasterizes this rectangle and puts the
  /// resulting image on the clipboard.
  final Rect? pdfBounds;

  /// The frame drawn around the selection. Upright at first; it keeps the
  /// orientation given to it by rotating.
  final SelectionFrame frame;

  int get count => indices.length;
  int get imageCount => imageIndices.length;
  int get stickyCount => stickyIndices.length;
  bool get includesPdf => pdfBounds != null;
}

/// One stroke on the clipboard: its look and its points, and nothing that
/// belongs to the document.
class ClipboardStroke {
  ClipboardStroke._(this.style, this.points, this.widths);

  factory ClipboardStroke.of(Stroke stroke) {
    return ClipboardStroke._(
      stroke.style,
      List<InkVector>.unmodifiable(stroke.points),
      stroke.widths,
    );
  }

  final StrokeStyle style;
  final List<InkVector> points;

  /// The width factor at each point, or null for an even stroke.
  final List<double>? widths;
}

/// Ink copied or cut in this editor session. It is a snapshot in Greatnote's
/// own stroke model, kept in memory and never offered to other applications.
class InkClipboard {
  InkClipboard._(
    this.strokes,
    this.images,
    this.frame, [
    this.stickies = const <StickyNoteElement>[],
  ]);

  /// Snapshots [selection] as it is now.
  factory InkClipboard.of(
    InkSelection selection, {
    Iterable<NoteImageElement> additionalImages = const <NoteImageElement>[],
  }) {
    return InkClipboard._(
      List<ClipboardStroke>.unmodifiable(
        selection.strokes.map(ClipboardStroke.of),
      ),
      List<NoteImageElement>.unmodifiable(<NoteImageElement>[
        ...additionalImages,
        ...selection.images,
      ]),
      selection.frame,
      List<StickyNoteElement>.unmodifiable(selection.stickies),
    );
  }

  /// The copied strokes, in document order.
  final List<ClipboardStroke> strokes;
  final List<NoteImageElement> images;

  /// The copied selection's frame.
  final SelectionFrame frame;

  /// The copied sticky notes, with their ink; pasted with fresh ids.
  final List<StickyNoteElement> stickies;

  /// Rebuilds this clipboard for another note, replacing source asset ids
  /// with ids of assets copied into that note. An image whose bytes could
  /// not be copied is omitted; independent ink remains available to paste.
  InkClipboard remapImageAssets(Map<String, String> assetIds) {
    return InkClipboard._(
      strokes,
      List<NoteImageElement>.unmodifiable(<NoteImageElement>[
        for (final NoteImageElement image in images)
          if (image.isVector)
            image
          else if (assetIds[image.assetId] case final String assetId)
            image.copyWith(assetId: assetId),
      ]),
      frame,
      stickies,
    );
  }

  bool get isEmpty => strokes.isEmpty && images.isEmpty && stickies.isEmpty;
}
