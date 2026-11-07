import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:xml/xml.dart';

import '../../editor/ai/ai_citation.dart';
import '../../editor/ai/ai_config.dart';
import '../../editor/ai/selection_image_renderer.dart';
import '../../editor/ai/selection_svg_renderer.dart';
import '../../editor/document_io/document_models.dart';
import '../../editor/document_io/document_platform.dart';
import '../../editor/ink/ink_sample.dart';
import '../../editor/ink/ink_selection.dart';
import '../../editor/ink/selection_transform.dart';
import '../../editor/ink/stroke.dart';
import '../../editor/sticky/sticky_note.dart';
import '../library_models.dart';
import '../note_content.dart';
import '../note_repository.dart';
import 'study_desk_models.dart';
import 'study_desk_store.dart';
import 'study_vectors.dart';

// ---------------------------------------------------------------------------
// Stage 1: what a page is made of, and how it falls into chunks.
// ---------------------------------------------------------------------------

/// A page's content as plain data, so that working out its chunks can leave the
/// UI isolate: strokes hold paths, and text is measured, only on this one.
@immutable
class StudyPageData {
  const StudyPageData({
    required this.pageIndex,
    required this.strokes,
    required this.boxes,
    required this.words,
    this.sourceSection,
  });

  /// [pdfText] is what the PDF under the page says, if it is on one.
  factory StudyPageData.of(
    StoredPage page,
    int pageIndex, {
    List<PdfTextRun> pdfText = const <PdfTextRun>[],
    StudySourceSection? sourceSection,
  }) {
    final Map<String, ui.Rect> stickyBounds = <String, ui.Rect>{
      for (final sticky in page.stickyNotes) sticky.id: sticky.bounds,
    };
    return StudyPageData(
      pageIndex: pageIndex,
      sourceSection: sourceSection,
      strokes: <StudyStrokeData>[
        for (int i = 0; i < page.strokes.length; i++)
          StudyStrokeData.of(page.strokes[i], i),
      ],
      boxes: <StudyBoxData>[
        for (final NoteImageElement image in page.images)
          if (image.isValid)
            StudyBoxData(
              id: image.id,
              kind: StudyBoxKind.image,
              bounds: image.bounds,
              svgSource: image.vector?.source,
              text: image.vector == null ? (image.fileName ?? '') : '',
            ),
        for (final sticky in page.stickyNotes)
          if (sticky.isValid)
            StudyBoxData(
              id: sticky.id,
              kind: StudyBoxKind.sticky,
              bounds: sticky.bounds,
              inkStrokes: sticky.strokes.length,
            ),
        for (final text in page.textElements)
          if (text.isValid && text.text.trim().isNotEmpty)
            StudyBoxData(
              id: text.id,
              kind: StudyBoxKind.text,
              bounds: text.bounds,
              text: text.text.trim(),
            ),
        ..._pdfBoxes(page, pageIndex, pdfText),
      ],
      words: <StudyWordData>[
        for (final StoredRecognizedInkWord word in page.recognizedWords)
          if (word.text.isNotEmpty)
            StudyWordData(
              text: word.text,
              confidence: word.confidence,
              alternatives: word.alternatives,
              strokeIndices: word.strokeIndices,
              stickyId: word.stickyId,
              // A sticky note's strokes lie in its own space, so a word on one
              // is placed by the note itself.
              stickyBounds: word.stickyId == null
                  ? null
                  : stickyBounds[word.stickyId],
            ),
      ],
    );
  }

  /// What a PDF page brings. Its words become text like any typed on the page,
  /// so they are chunked, found, and sent the same way, costing no picture. A
  /// page with no words, a scan, is one picture: the only way to read it.
  static List<StudyBoxData> _pdfBoxes(
    StoredPage page,
    int pageIndex,
    List<PdfTextRun> text,
  ) {
    final PdfPageSource? source = page.pdfSource;
    if (source == null) return const <StudyBoxData>[];
    final ui.Size size = source.pageSize;
    if (text.isEmpty) {
      return <StudyBoxData>[
        StudyBoxData(
          id: 'pdf-page-$pageIndex',
          kind: StudyBoxKind.image,
          bounds: ui.Offset.zero & size,
        ),
      ];
    }
    return <StudyBoxData>[
      for (int i = 0; i < text.length; i++)
        if (_onPaper(text[i].bounds, size, page.pdfMasks))
          StudyBoxData(
            id: 'pdf-text-$pageIndex-$i',
            kind: StudyBoxKind.text,
            bounds: _onPage(text[i].bounds, size),
            text: text[i].text,
          ),
    ];
  }

  static ui.Rect _onPage(ui.Rect share, ui.Size size) => ui.Rect.fromLTRB(
    share.left * size.width,
    share.top * size.height,
    share.right * size.width,
    share.bottom * size.height,
  );

  /// Whether a line still shows: the user may have rubbed it out of the PDF.
  static bool _onPaper(ui.Rect share, ui.Size size, List<ui.Rect> masks) {
    final ui.Offset center = _onPage(share, size).center;
    return !masks.any((ui.Rect mask) => mask.contains(center));
  }

  final int pageIndex;
  final List<StudyStrokeData> strokes;
  final List<StudyBoxData> boxes;
  final List<StudyWordData> words;
  final StudySourceSection? sourceSection;

  /// About what this would take as JSON.
  int get estimatedBytes {
    int bytes = 64;
    for (final StudyStrokeData stroke in strokes) {
      bytes += 32 + stroke.points.length * 8;
    }
    for (final StudyBoxData box in boxes) {
      bytes += 64 + box.text.length + (box.svgSource?.length ?? 0);
    }
    for (final StudyWordData word in words) {
      bytes += 48 + word.text.length + word.strokeIndices.length * 4;
    }
    return bytes;
  }
}

@immutable
class StudyStrokeData {
  const StudyStrokeData({
    required this.index,
    required this.bounds,
    required this.points,
    this.highlighter = false,
  });

  factory StudyStrokeData.of(Stroke stroke, int index) {
    final Float32List points = Float32List(stroke.points.length * 2);
    for (int i = 0; i < stroke.points.length; i++) {
      points[i * 2] = stroke.points[i].x;
      points[i * 2 + 1] = stroke.points[i].y;
    }
    return StudyStrokeData(
      index: index,
      bounds: stroke.bounds,
      points: points,
      highlighter: stroke.style.isHighlighter,
    );
  }

  final int index;
  final ui.Rect bounds;

  /// x, then y, for each point.
  final Float32List points;
  final bool highlighter;
}

enum StudyBoxKind { image, sticky, text }

/// Anything on a page that is not page ink.
@immutable
class StudyBoxData {
  const StudyBoxData({
    required this.id,
    required this.kind,
    required this.bounds,
    this.text = '',
    this.svgSource,
    this.inkStrokes = 0,
  });

  final String id;
  final StudyBoxKind kind;
  final ui.Rect bounds;

  /// A text box's words, or a picture's file name.
  final String text;
  final String? svgSource;
  final int inkStrokes;
}

@immutable
class StudyWordData {
  const StudyWordData({
    required this.text,
    required this.confidence,
    required this.alternatives,
    required this.strokeIndices,
    this.stickyId,
    this.stickyBounds,
  });

  final String text;
  final double? confidence;
  final List<String> alternatives;
  final List<int> strokeIndices;
  final String? stickyId;
  final ui.Rect? stickyBounds;
}

/// A note to chunk, as plain data.
@immutable
class StudyNoteData {
  const StudyNoteData(this.noteId, this.pages);

  /// [pdfText] holds what the PDF under each page says, by page.
  factory StudyNoteData.of(
    String noteId,
    NoteContent content, {
    Map<int, List<PdfTextRun>> pdfText = const <int, List<PdfTextRun>>{},
    Map<int, StudySourceSection> sections = const {},
  }) => StudyNoteData(noteId, <StudyPageData>[
    for (int i = 0; i < content.pages.length; i++)
      StudyPageData.of(
        content.pages[i],
        i,
        pdfText: pdfText[i] ?? const <PdfTextRun>[],
        sourceSection: sections[i],
      ),
  ]);

  final String noteId;
  final List<StudyPageData> pages;

  int get estimatedBytes => pages.fold<int>(
    0,
    (int total, StudyPageData page) => total + page.estimatedBytes,
  );
}

/// Partitions pages into bounded 2D chunks rather than fixed runs of
/// characters, so a drawing, its labels, and a paragraph each stay whole.
abstract final class StudyChunker {
  /// What lies closer than this together is one chunk. A box is grown by this
  /// and tested against the other as it is, so words farther than this from a
  /// drawing, and within [anchorReach], stay apart and are found as its labels.
  static const double clusterGap = 32;

  /// A chunk goes no taller, so a page of dense writing makes paragraph-sized
  /// bands. A single taller thing, like a big picture, is a chunk by itself.
  static const double maxClusterHeight = 360;

  /// Words this near a drawing are taken to be its labels.
  static const double anchorReach = 64;

  /// Below this share of strokes read as words, ink is taken as a drawing.
  static const double recognizedShare = 0.45;
  static const int minDiagramStrokes = 4;
  static const double minDiagramSide = 80;

  /// Words read with less than this, on average, are shown to the model too.
  static const double confidentReading = 0.6;

  /// A note's chunks, in page order. Pure, and safe on any isolate.
  static List<StudyChunk> chunkNote(StudyNoteData note) => <StudyChunk>[
    for (final StudyPageData page in note.pages)
      ...chunkPage(note.noteId, page),
  ];

  static List<StudyChunk> chunkPage(String noteId, StudyPageData page) {
    final List<_Element> elements = <_Element>[
      for (final StudyStrokeData stroke in page.strokes)
        if (stroke.bounds.isFinite) _Element.stroke(stroke),
      for (final StudyBoxData box in page.boxes)
        if (box.bounds.isFinite) _Element.box(box),
    ]..sort((_Element a, _Element b) => a.bounds.top.compareTo(b.bounds.top));
    final List<_Cluster> clusters = _clustersOf(elements);
    final Map<int, _Cluster> byStroke = <int, _Cluster>{};
    final Map<String, _Cluster> byBox = <String, _Cluster>{};
    for (final _Cluster cluster in clusters) {
      for (final _Element element in cluster.elements) {
        if (element.stroke != null) byStroke[element.stroke!.index] = cluster;
        if (element.box != null) byBox[element.box!.id] = cluster;
      }
    }
    final List<_PlacedWord> placed = <_PlacedWord>[];
    for (final StudyWordData word in page.words) {
      final _PlacedWord? one = _place(word, page, byStroke, byBox);
      if (one != null) {
        placed.add(one);
        one.cluster.words.add(one);
      }
    }
    final List<_Cluster> kept =
        clusters.where((_Cluster cluster) => cluster.hasContent).toList()
          ..sort((_Cluster a, _Cluster b) {
            final int top = a.bounds.top.compareTo(b.bounds.top);
            return top != 0 ? top : a.bounds.left.compareTo(b.bounds.left);
          });
    return <StudyChunk>[
      for (int i = 0; i < kept.length; i++)
        _chunkOf(
          noteId,
          page.pageIndex,
          i + 1,
          kept[i],
          placed,
          page.boxes,
          i == 0 ? page.sourceSection : null,
        ),
    ];
  }

  /// Unites what lies near together, walking down the page, so that each
  /// element is held against only those near it in height. A cluster stops
  /// growing at [maxClusterHeight].
  static List<_Cluster> _clustersOf(List<_Element> sorted) {
    final List<int> parent = List<int>.generate(sorted.length, (int i) => i);
    final List<ui.Rect> extent = <ui.Rect>[
      for (final _Element element in sorted) element.bounds,
    ];
    int find(int i) {
      while (parent[i] != i) {
        parent[i] = parent[parent[i]];
        i = parent[i];
      }
      return i;
    }

    for (int i = 0; i < sorted.length; i++) {
      final ui.Rect grown = sorted[i].bounds.inflate(clusterGap);
      for (int j = i + 1; j < sorted.length; j++) {
        if (sorted[j].bounds.top > grown.bottom) break;
        if (!grown.overlaps(sorted[j].bounds)) continue;
        final int a = find(i);
        final int b = find(j);
        if (a == b) continue;
        final ui.Rect both = extent[a].expandToInclude(extent[b]);
        if (both.height > maxClusterHeight) continue;
        parent[b] = a;
        extent[a] = both;
      }
    }
    final Map<int, _Cluster> clusters = <int, _Cluster>{};
    for (int i = 0; i < sorted.length; i++) {
      final int root = find(i);
      (clusters[root] ??= _Cluster(extent[root])).elements.add(sorted[i]);
    }
    return clusters.values.toList();
  }

  /// Where [word] lies: the cluster with most of its strokes.
  static _PlacedWord? _place(
    StudyWordData word,
    StudyPageData page,
    Map<int, _Cluster> byStroke,
    Map<String, _Cluster> byBox,
  ) {
    final String? sticky = word.stickyId;
    if (sticky != null) {
      final _Cluster? cluster = byBox[sticky];
      if (cluster == null) return null;
      return _PlacedWord(word, cluster, word.stickyBounds ?? cluster.bounds);
    }
    final Map<_Cluster, int> votes = <_Cluster, int>{};
    ui.Rect? bounds;
    for (final int index in word.strokeIndices) {
      if (index < 0 || index >= page.strokes.length) continue;
      final _Cluster? cluster = byStroke[index];
      if (cluster == null) continue;
      votes[cluster] = (votes[cluster] ?? 0) + 1;
      final ui.Rect rect = page.strokes[index].bounds;
      bounds = bounds?.expandToInclude(rect) ?? rect;
    }
    if (votes.isEmpty || bounds == null) return null;
    _Cluster best = votes.keys.first;
    for (final MapEntry<_Cluster, int> vote in votes.entries) {
      if (vote.value > votes[best]!) best = vote.key;
    }
    return _PlacedWord(word, best, bounds);
  }

  static StudyChunk _chunkOf(
    String noteId,
    int pageIndex,
    int chunkIndex,
    _Cluster cluster,
    List<_PlacedWord> everyWord,
    List<StudyBoxData> everyBox,
    StudySourceSection? sourceSection,
  ) {
    final List<StudyStrokeData> strokes = <StudyStrokeData>[
      for (final _Element element in cluster.elements)
        if (element.stroke != null) element.stroke!,
    ]..sort((a, b) => a.index.compareTo(b.index));
    final List<StudyBoxData> boxes = <StudyBoxData>[
      for (final _Element element in cluster.elements)
        if (element.box != null) element.box!,
    ];
    final List<StudyStrokeData> ink = strokes
        .where((StudyStrokeData stroke) => !stroke.highlighter)
        .toList();
    final Set<int> read = <int>{
      for (final _PlacedWord placed in cluster.words)
        if (placed.word.stickyId == null) ...placed.word.strokeIndices,
    };
    final int covered = ink
        .where((StudyStrokeData stroke) => read.contains(stroke.index))
        .length;
    final double share = ink.isEmpty ? 1 : covered / ink.length;
    final List<StudyBoxData> images = boxes
        .where((StudyBoxData box) => box.kind == StudyBoxKind.image)
        .toList();
    final List<StudyBoxData> stickies = boxes
        .where((StudyBoxData box) => box.kind == StudyBoxKind.sticky)
        .toList();
    // In the page's own order, not top to bottom, so that two columns in one
    // chunk stay two columns.
    final Set<String> here = <String>{for (final b in boxes) b.id};
    final List<StudyBoxData> typed = everyBox
        .where(
          (StudyBoxData box) =>
              box.kind == StudyBoxKind.text && here.contains(box.id),
        )
        .toList();
    final bool drawnInk =
        ink.length >= minDiagramStrokes &&
        share < recognizedShare &&
        cluster.bounds.width >= minDiagramSide &&
        cluster.bounds.height >= minDiagramSide;
    final bool visual = images.isNotEmpty || drawnInk;
    final StudyChunkKind kind = !visual
        ? StudyChunkKind.text
        : cluster.words.isNotEmpty
        ? StudyChunkKind.mixed
        : StudyChunkKind.diagram;

    final List<double> confidences = <double>[
      for (final _PlacedWord placed in cluster.words)
        if (placed.word.confidence case final double confidence) confidence,
    ];
    final double? meanConfidence = confidences.isEmpty
        ? null
        : confidences.reduce((double a, double b) => a + b) /
              confidences.length;
    final bool hasInk =
        ink.isNotEmpty ||
        stickies.any((StudyBoxData box) => box.inkStrokes > 0);
    final bool unreadSticky = stickies.any(
      (StudyBoxData box) =>
          box.inkStrokes > 0 &&
          !cluster.words.any((w) => w.word.stickyId == box.id),
    );
    final bool lowConfidence =
        kind == StudyChunkKind.text &&
        hasInk &&
        (share < recognizedShare ||
            unreadSticky ||
            (meanConfidence != null && meanConfidence < confidentReading));

    final List<String> svgText = <String>[
      for (final StudyBoxData image in images)
        if (image.svgSource case final String source) _svgTextOf(source),
    ];
    final List<String> anchors = <String>[];
    if (visual) {
      final ui.Rect reach = cluster.bounds.inflate(anchorReach);
      for (final _PlacedWord placed in everyWord) {
        if (reach.overlaps(placed.bounds)) anchors.add(placed.word.text);
      }
      for (final StudyBoxData box in everyBox) {
        if (box.kind == StudyBoxKind.text && reach.overlaps(box.bounds)) {
          anchors.add(box.text);
        }
      }
    }
    final List<StudyChunkLine> lines = <StudyChunkLine>[
      ..._linesOf(cluster.words),
      for (final StudyBoxData box in typed)
        for (final String line in const LineSplitter().convert(box.text))
          if (line.trim().isNotEmpty) StudyChunkLine(0, 0, line.trim()),
    ];
    final ui.Rect? other = boxes.isEmpty
        ? null
        : boxes
              .map((StudyBoxData box) => box.bounds)
              .reduce((ui.Rect a, ui.Rect b) => a.expandToInclude(b));
    return StudyChunk(
      noteId: noteId,
      pageIndex: pageIndex,
      chunkIndex: chunkIndex,
      kind: kind,
      logicalBounds: cluster.bounds,
      strokeIndices: <int>[for (final StudyStrokeData s in strokes) s.index],
      stickyIds: <String>[for (final StudyBoxData box in stickies) box.id],
      imageIds: <String>[for (final StudyBoxData box in images) box.id],
      otherBounds: other,
      lines: lines,
      handwriting: cluster.words.map((w) => w.word.text).join(' '),
      alternatives: cluster.words.expand((w) => w.word.alternatives).join(' '),
      typed: typed.map((StudyBoxData box) => box.text).join('\n'),
      anchors: anchors,
      svgText: <String>[
        ...svgText,
        for (final StudyBoxData image in images) image.text,
      ].where((String text) => text.isNotEmpty).join(' '),
      tags: visual || lowConfidence ? _structureOf(ink) : const <String>[],
      lowConfidence: lowConfidence,
      sourceSection: sourceSection,
    );
  }

  /// The words in rows down the chunk, each row left to right.
  static List<StudyChunkLine> _linesOf(List<_PlacedWord> words) {
    final List<_PlacedWord> sorted = List<_PlacedWord>.of(words)
      ..sort(
        (_PlacedWord a, _PlacedWord b) =>
            a.bounds.center.dy.compareTo(b.bounds.center.dy),
      );
    final List<List<_PlacedWord>> rows = <List<_PlacedWord>>[];
    for (final _PlacedWord word in sorted) {
      final List<_PlacedWord>? row = rows.lastOrNull;
      final double? center = row?.first.bounds.center.dy;
      if (row != null &&
          (word.bounds.center.dy - center!).abs() <
              math.max(word.bounds.height, row.first.bounds.height) * 0.6) {
        row.add(word);
      } else {
        rows.add(<_PlacedWord>[word]);
      }
    }
    return <StudyChunkLine>[
      for (final List<_PlacedWord> row in rows) _lineOf(row),
    ];
  }

  static StudyChunkLine _lineOf(List<_PlacedWord> row) {
    row.sort(
      (_PlacedWord a, _PlacedWord b) => a.bounds.left.compareTo(b.bounds.left),
    );
    final List<int> strokes = <int>[
      for (final _PlacedWord placed in row)
        if (placed.word.stickyId == null) ...placed.word.strokeIndices,
    ];
    final String text = row.map((w) => w.word.text).join(' ');
    return strokes.isEmpty
        ? StudyChunkLine(0, 0, text)
        : StudyChunkLine(
            strokes.reduce(math.min) + 1,
            strokes.reduce(math.max) + 1,
            text,
          );
  }

  /// An SVG's `<title>`, `<desc>`, and `<text>`, which is what it says in words.
  static String _svgTextOf(String source) {
    try {
      final XmlDocument document = XmlDocument.parse(source);
      final List<String> parts = <String>[
        for (final XmlElement element
            in document.descendants.whereType<XmlElement>())
          if (const <String>{
            'title',
            'desc',
            'text',
          }.contains(element.name.local.toLowerCase()))
            element.innerText.trim(),
      ];
      final String text = parts.where((String s) => s.isNotEmpty).join(' ');
      return text.length <= _maxSvgText
          ? text
          : text.substring(0, _maxSvgText).trimRight();
    } on Object {
      return '';
    }
  }

  static const int _maxSvgText = 600;

  /// A few plain words for what [ink] looks like, from its shapes alone.
  static List<String> _structureOf(List<StudyStrokeData> ink) {
    if (ink.isEmpty) return const <String>[];
    final List<_Shape> shapes = ink.map(_Shape.of).nonNulls.toList();
    final List<_Shape> straight = shapes
        .where((_Shape shape) => shape.isStraight && shape.chord >= 40)
        .toList();
    bool box = shapes.any((_Shape shape) => shape.isClosed);
    bool curve = shapes.any(
      (_Shape shape) =>
          !shape.isClosed && !shape.isStraight && shape.chord >= 60,
    );
    int across = 0;
    int down = 0;
    for (final _Shape line in straight) {
      if (line.isLevel) across++;
      if (line.isUpright) down++;
    }
    final bool axes = across >= 1 && down >= 1;
    final bool grid = across >= 3 || down >= 3;
    // Four straight strokes, two each way, are as much a box as one closed one.
    if (!box && across >= 2 && down >= 2) box = true;
    bool arrow = false;
    for (final _Shape line in straight) {
      if (arrow) break;
      for (final _Shape other in shapes) {
        if (identical(other, line) || other.chord >= line.chord * 0.6) continue;
        if (line.hasEndNear(other)) {
          arrow = true;
          break;
        }
      }
    }
    if (!curve && !axes && !arrow && !box && straight.isEmpty) curve = true;
    return <String>[
      if (box) ...const <String>['closed-loop', 'box'],
      if (axes) ...const <String>['axes'],
      if (grid) ...const <String>['grid', 'table'],
      if (arrow) ...const <String>['arrow', 'connector'],
      if (curve) ...const <String>['curve', 'plot'],
      'strokes:${ink.length}',
    ];
  }
}

class _Element {
  _Element.stroke(StudyStrokeData this.stroke)
    : box = null,
      bounds = stroke.bounds;
  _Element.box(StudyBoxData this.box) : stroke = null, bounds = box.bounds;

  final StudyStrokeData? stroke;
  final StudyBoxData? box;
  final ui.Rect bounds;
}

class _Cluster {
  _Cluster(this.bounds);

  final ui.Rect bounds;
  final List<_Element> elements = <_Element>[];
  final List<_PlacedWord> words = <_PlacedWord>[];

  /// A highlighter by itself says nothing.
  bool get hasContent => elements.any(
    (_Element element) => element.box != null || !element.stroke!.highlighter,
  );
}

class _PlacedWord {
  _PlacedWord(this.word, this.cluster, this.bounds);

  final StudyWordData word;
  final _Cluster cluster;
  final ui.Rect bounds;
}

/// The little that is needed of a stroke's shape.
class _Shape {
  _Shape(this.x0, this.y0, this.x1, this.y1, this.length, this.span);

  static _Shape? of(StudyStrokeData stroke) {
    final Float32List p = stroke.points;
    if (p.length < 4) return null;
    double length = 0;
    for (int i = 2; i + 1 < p.length; i += 2) {
      final double dx = p[i] - p[i - 2];
      final double dy = p[i + 1] - p[i - 1];
      length += math.sqrt(dx * dx + dy * dy);
    }
    return _Shape(
      p[0],
      p[1],
      p[p.length - 2],
      p[p.length - 1],
      length,
      math.max(stroke.bounds.width, stroke.bounds.height),
    );
  }

  final double x0;
  final double y0;
  final double x1;
  final double y1;
  final double length;
  final double span;

  double get chord {
    final double dx = x1 - x0;
    final double dy = y1 - y0;
    return math.sqrt(dx * dx + dy * dy);
  }

  bool get isStraight => length > 0 && chord / length >= 0.95;

  /// Comes back to where it began, having gone somewhere.
  bool get isClosed => span >= 24 && chord <= math.max(14, length * 0.12);

  bool get isLevel => (y1 - y0).abs() <= (x1 - x0).abs() * 0.2;
  bool get isUpright => (x1 - x0).abs() <= (y1 - y0).abs() * 0.2;

  /// Whether a shorter stroke, like an arrow's head, starts or ends at an end
  /// of this one.
  bool hasEndNear(_Shape other) {
    const double near = 14;
    bool at(double ax, double ay, double bx, double by) =>
        (ax - bx).abs() <= near && (ay - by).abs() <= near;
    return at(x0, y0, other.x0, other.y0) ||
        at(x0, y0, other.x1, other.y1) ||
        at(x1, y1, other.x0, other.y0) ||
        at(x1, y1, other.x1, other.y1);
  }
}

// ---------------------------------------------------------------------------
// Chunks kept by revision.
// ---------------------------------------------------------------------------

/// Reuses each note's chunks by id and revision, with bounded memory retention
/// and an optional disk cache for entries that leave memory.
class StudyRagIndex {
  StudyRagIndex({
    required this.repository,
    this.diskCache,
    this.pdfText,
    this.pdfOutline,
    this.maxMemoryNotes = 24,
    this.maxMemoryBytes = 8 * 1024 * 1024,
  }) : assert(maxMemoryNotes >= 0),
       assert(maxMemoryBytes >= 0);

  final NoteRepository repository;
  final StudyChunkDiskCache? diskCache;

  /// Reads a PDF's words. Without one, every PDF page counts as a scan.
  final PdfTextExtractor? pdfText;
  final PdfOutlineReader? pdfOutline;

  // Estimated retained size, rather than encoded file size. Oversized notes
  // remain available to the caller and on disk without occupying this LRU.
  final int maxMemoryNotes;
  final int maxMemoryBytes;
  final Map<String, (int, List<StudyChunk>, int)> _memory = {};
  int _memoryBytes = 0;
  int _memoryEpoch = 0;
  final Map<String, int> _latestRevision = {};
  final Map<(String, int), Future<List<StudyChunk>>> _building =
      <(String, int), Future<List<StudyChunk>>>{};

  /// Notes that take at least this much are chunked off the UI isolate, as
  /// [FileNoteRepository] reads them.
  static const int offMainBytes = 8 * 1024;

  /// How many times a note had to be read: for tests to see the cache work.
  @visibleForTesting
  int reads = 0;

  /// [note]'s chunks at its current revision, kept if already worked out.
  Future<List<StudyChunk>> chunksFor(NoteEntry note) {
    final kept = _memory.remove(note.id);
    if (kept != null && kept.$1 == note.revision) {
      _memory[note.id] = kept;
      return SynchronousFuture<List<StudyChunk>>(kept.$2);
    }
    if (kept != null) _memoryBytes -= kept.$3;
    final (String, int) key = (note.id, note.revision);
    final pending = _building[key];
    if (pending != null) return pending;
    _latestRevision[note.id] = math.max(
      _latestRevision[note.id] ?? note.revision,
      note.revision,
    );
    return _building[key] = _build(note, _memoryEpoch).whenComplete(() {
      // In a block: returned, the future removed would wait on itself.
      _building.remove(key);
      if (!_building.keys.any((key) => key.$1 == note.id)) {
        _latestRevision.remove(note.id);
      }
    });
  }

  Future<List<StudyChunk>> _build(NoteEntry note, int epoch) async {
    final cached = await diskCache?.read(note.id, note.revision);
    final (chunks, complete) = cached != null
        ? (cached, true)
        : await _read(note, epoch);
    if (complete &&
        epoch == _memoryEpoch &&
        _latestRevision[note.id] == note.revision) {
      final int bytes = estimatedStudyChunkBytes(chunks);
      if (maxMemoryNotes > 0 && bytes <= maxMemoryBytes) {
        final previous = _memory.remove(note.id);
        if (previous != null) _memoryBytes -= previous.$3;
        _memory[note.id] = (note.revision, chunks, bytes);
        _memoryBytes += bytes;
        while (_memory.length > maxMemoryNotes ||
            _memoryBytes > maxMemoryBytes) {
          _memoryBytes -= _memory.remove(_memory.keys.first)!.$3;
        }
      }
    }
    return chunks;
  }

  Future<(List<StudyChunk>, bool)> _read(NoteEntry note, int epoch) async {
    reads++;
    final NoteContent content = await repository.loadNote(note.id);
    final (text, sections, complete) = await _pdfTextOf(note.id, content);
    final StudyNoteData data = StudyNoteData.of(
      note.id,
      content,
      pdfText: text,
      sections: sections,
    );
    final List<StudyChunk> chunks = data.estimatedBytes >= offMainBytes
        ? await compute(
            StudyChunker.chunkNote,
            data,
            debugLabel: 'study.chunkNote',
          )
        : StudyChunker.chunkNote(data);
    // What could not be read this time is not remembered as having no words.
    if (complete &&
        epoch == _memoryEpoch &&
        _latestRevision[note.id] == note.revision) {
      await diskCache?.write(note.id, note.revision, chunks);
    }
    return (chunks, complete);
  }

  /// What the PDFs under [content]'s pages say, by page of the note, and
  /// whether all of them could be read. A note's pages may come from several
  /// PDFs, and each is opened once.
  Future<(Map<int, List<PdfTextRun>>, Map<int, StudySourceSection>, bool)>
  _pdfTextOf(String noteId, NoteContent content) async {
    final PdfTextExtractor? extractor = pdfText;
    final Map<int, List<PdfTextRun>> text = <int, List<PdfTextRun>>{};
    final sections = <int, StudySourceSection>{};
    if (extractor == null) return (text, sections, true);
    final byAsset = <String, Map<int, List<int>>>{};
    for (int i = 0; i < content.pages.length; i++) {
      final PdfPageSource? source = content.pages[i].pdfSource;
      if (source == null) continue;
      ((byAsset[source.assetId] ??= {})[source.pageIndex] ??= []).add(i);
    }
    bool complete = true;
    for (final asset in byAsset.entries) {
      try {
        final NoteAssetData data = await repository.readAsset(
          noteId,
          asset.key,
        );
        final Map<int, List<PdfTextRun>> read = await extractor.extractText(
          data.bytes,
          asset.value.keys.toSet(),
        );
        for (final page in asset.value.entries) {
          final runs = read[page.key];
          if (runs == null) {
            complete = false;
            continue;
          }
          for (final notePage in page.value) {
            text[notePage] = runs;
          }
        }
        final outlineReader =
            pdfOutline ??
            (extractor is PdfOutlineReader
                ? extractor as PdfOutlineReader
                : null);
        if (outlineReader != null) {
          try {
            sections.addAll(
              _mapSections(
                await outlineReader.readOutline(data.bytes),
                asset.value,
              ),
            );
          } on Object {
            complete = false;
          }
        }
      } on Object {
        // Its pages are shown to the model as pictures instead, for now.
        complete = false;
      }
    }
    return (text, sections, complete);
  }

  static final _sectionTitle = RegExp(
    r'^(?:(?:chapter|unit|part)\s+)?(\d+|[ivxlcdm]+)\s*[:.\-–—]?\s+\S',
    caseSensitive: false,
  );

  static bool _isSectionTitle(String title) =>
      _sectionTitle.hasMatch(title) &&
      !RegExp(
        r'^chapter\s+(?:\d+|[ivxlcdm]+)\s+in\s+review\b',
        caseSensitive: false,
      ).hasMatch(title);

  static Map<int, StudySourceSection> _mapSections(
    List<PdfOutlineEntry> outline,
    Map<int, List<int>> notePages,
  ) {
    // Find chapters at one sibling level; a book may wrap them in parts.
    final members = <int, (String, int)>{};
    void visit(List<PdfOutlineEntry> siblings, int? parentEnd) {
      final hasSections = siblings.any((entry) => _isSectionTitle(entry.title));
      for (int i = 0; i < siblings.length; i++) {
        final entry = siblings[i];
        final start = entry.pageIndex;
        final end =
            siblings
                .skip(i + 1)
                .map((e) => e.pageIndex)
                .whereType<int>()
                .where((p) => start == null || p > start)
                .firstOrNull ??
            parentEnd;
        final numberedChildren = entry.children.any(
          (e) => _isSectionTitle(e.title),
        );
        if (start != null &&
            _isSectionTitle(entry.title) &&
            !numberedChildren) {
          for (final page in notePages.entries) {
            if (page.key < start || (end != null && page.key >= end)) continue;
            for (final notePage in page.value) {
              members[notePage] = (entry.title, start);
            }
          }
        } else if (!hasSections || _isSectionTitle(entry.title)) {
          visit(entry.children, end);
        }
      }
    }

    visit(outline, null);
    final pages = members.keys.toList()..sort();
    final result = <int, StudySourceSection>{};
    for (int i = 0; i < pages.length; i++) {
      final start = pages[i];
      int end = start;
      while (i + 1 < pages.length &&
          pages[i + 1] == end + 1 &&
          members[pages[i + 1]] == members[start]) {
        end = pages[++i];
      }
      result[start] = StudySourceSection(members[start]!.$1, end);
    }
    return result;
  }

  /// Lets go of everything kept for every note but [noteIds].
  Future<void> retain(Set<String> noteIds) async {
    // Also invalidate completions that were started before this pruning pass.
    _memoryEpoch++;
    _memory.removeWhere((String id, kept) {
      if (noteIds.contains(id)) return false;
      _memoryBytes -= kept.$3;
      return true;
    });
    await diskCache?.retain(noteIds);
  }

  void releaseMemory() {
    _memoryEpoch++;
    _memory.clear();
    _memoryBytes = 0;
  }
}

// ---------------------------------------------------------------------------
// Stage 2: finding what a question needs.
// ---------------------------------------------------------------------------

/// How a question's chunks are chosen.
enum StudyQueryMode {
  /// By what its words and their meaning match. A question with nothing in it
  /// to look for gets a fair spread. One that matches nothing gets only pages
  /// with no words to be ruled out by (scans, slides, drawings): pages with
  /// words that have nothing to do with it only lead an answer astray.
  search,

  /// A fair spread of every note, whatever the words.
  overview,

  /// The drawings first.
  diagrams,
}

/// One chunk that can be found, with the names that are not kept with it, since
/// renaming a note changes neither its revision nor its chunks.
@immutable
class StudySearchDocument {
  const StudySearchDocument({
    required this.chunk,
    required this.noteTitle,
    this.folderName = '',
  });

  final StudyChunk chunk;
  final String noteTitle;
  final String folderName;
}

@immutable
class StudyHit {
  const StudyHit(this.document, this.score);

  final StudySearchDocument document;
  final double score;

  StudyChunk get chunk => document.chunk;
}

/// Words in lower case. A run of Chinese, Japanese, or Korean, which has no
/// spaces to split at, gives each pair of its characters.
List<String> studyTokens(String text) {
  final List<String> tokens = <String>[];
  for (final Match match in _wordPattern.allMatches(text.toLowerCase())) {
    final String word = match[0]!;
    if (!_cjkPattern.hasMatch(word)) {
      tokens.add(word);
      continue;
    }
    final List<int> runes = word.runes.toList();
    if (runes.length == 1) tokens.add(word);
    for (int i = 0; i + 1 < runes.length; i++) {
      tokens.add(String.fromCharCodes(runes, i, i + 2));
    }
  }
  return tokens;
}

final RegExp _wordPattern = RegExp(r'[\p{L}\p{N}]+', unicode: true);
final RegExp _cjkPattern = RegExp(r'[぀-ヿ㐀-鿿가-힯]');

const Set<String> _stopWords = <String>{
  'a',
  'an',
  'and',
  'are',
  'as',
  'at',
  'be',
  'but',
  'by',
  'can',
  'could',
  'did',
  'do',
  'does',
  'for',
  'from',
  'had',
  'has',
  'have',
  'how',
  'i',
  'in',
  'into',
  'is',
  'it',
  'its',
  'me',
  'my',
  'of',
  'on',
  'or',
  'our',
  'please',
  'should',
  'tell',
  'that',
  'the',
  'their',
  'them',
  'then',
  'there',
  'these',
  'this',
  'to',
  'us',
  'was',
  'we',
  'were',
  'what',
  'when',
  'where',
  'which',
  'who',
  'why',
  'will',
  'with',
  'would',
  'you',
  'your',
};

/// Words that ask to see something drawn.
const Set<String> _visualWords = <String>{
  'diagram',
  'diagrams',
  'drawing',
  'drawings',
  'drawn',
  'draw',
  'graph',
  'graphs',
  'plot',
  'plots',
  'chart',
  'charts',
  'figure',
  'figures',
  'arrow',
  'arrows',
  'sketch',
  'sketches',
  'flow',
  'flowchart',
  'shape',
  'shapes',
  'picture',
  'pictures',
  'table',
  'tables',
  'layout',
  'svg',
  'axes',
  'axis',
  'image',
  'images',
};

/// Whether [query] asks about something drawn.
bool studyQueryAsksForVisual(String query) =>
    studyTokens(query).any(_visualWords.contains);

/// Scores chunks by BM25 over their weighted fields, plus how near their words
/// come, letter by letter, to words of the question they do not hold exactly.
abstract final class StudyRetriever {
  static const int maxChunks = 5;

  /// BM25's usual settings.
  static const double _k1 = 1.2;
  static const double _b = 0.75;

  /// Below this letter-trigram similarity, two words are simply different.
  static const double _minSimilarity = 0.55;
  static const double _fuzzyWeight = 0.6;

  /// What a chunk the question is asking to see gains.
  static const double _visualBase = 1;
  static const double _visualFactor = 1.6;

  /// Far enough below the best, a chunk is noise, however little else matched.
  static const double _relativeCutoff = 0.25;

  /// Reciprocal rank fusion's usual constant.
  static const double _fusionK = 60;

  /// How near a chunk's meaning must be to the question's to be found by
  /// meaning alone (cosine), for its words and for its picture. A question
  /// against a picture is always less alike than against words.
  @visibleForTesting
  static const double textFloor = 0.55;
  @visibleForTesting
  static const double imageFloor = 0.30;

  /// Below these a chunk whose words match is still left out.
  @visibleForTesting
  static const double textLowFloor = 0.35;
  @visibleForTesting
  static const double imageLowFloor = 0.15;

  /// The chunks for [query], best first, at most [limit]. The text budget is
  /// the assembler's to apply.
  static List<StudyHit> retrieve(
    List<StudySearchDocument> documents,
    String query, {
    StudyQueryMode mode = StudyQueryMode.search,
    int limit = maxChunks,
    StudyVectorSignal? vectors,
  }) {
    if (documents.isEmpty || limit <= 0) return const <StudyHit>[];
    if (mode == StudyQueryMode.overview) {
      return _spread(documents, limit);
    }
    final bool wantsVisual =
        mode == StudyQueryMode.diagrams || studyQueryAsksForVisual(query);
    final List<String> terms = <String>{
      for (final String token in studyTokens(query))
        if (!_stopWords.contains(token)) token,
    }.toList();
    final List<_Fields> fields = documents.map(_Fields.of).toList();
    final double averageLength =
        fields.fold<double>(0, (double sum, _Fields f) => sum + f.length) /
        fields.length;
    final Map<String, int> frequency = <String, int>{};
    for (final _Fields field in fields) {
      for (final String term in field.weights.keys) {
        frequency[term] = (frequency[term] ?? 0) + 1;
      }
    }
    double idf(String term) {
      final int df = frequency[term] ?? 0;
      return math.log(1 + (documents.length - df + 0.5) / (df + 0.5));
    }

    final Map<String, Map<String, double>> near = _nearWords(
      terms,
      frequency.keys,
    );
    final List<StudyHit> hits = <StudyHit>[];
    for (int i = 0; i < documents.length; i++) {
      final _Fields field = fields[i];
      double score = 0;
      for (final String term in terms) {
        final double? weight = field.weights[term];
        if (weight != null) {
          final double norm =
              1 - _b + _b * field.length / math.max(averageLength, 1);
          score += idf(term) * weight * (_k1 + 1) / (weight + _k1 * norm);
          continue;
        }
        double best = 0;
        String? bestWord;
        near[term]?.forEach((String word, double similarity) {
          if (similarity > best && field.weights.containsKey(word)) {
            best = similarity;
            bestWord = word;
          }
        });
        if (bestWord != null) score += _fuzzyWeight * best * idf(bestWord!);
      }
      if (wantsVisual && documents[i].chunk.kind != StudyChunkKind.text) {
        score = (score + _visualBase) * _visualFactor;
      }
      if (score > 0) hits.add(StudyHit(documents[i], score));
    }
    // Nothing to look for in the question: it names no subject, so any fair
    // sample serves as well as another.
    if (terms.isEmpty && vectors == null) return _spread(documents, limit);
    hits.sort(_byScore);
    final double floor = hits.isEmpty ? 0 : hits.first.score * _relativeCutoff;
    final List<StudyHit> byWords = <StudyHit>[
      for (final StudyHit hit in hits)
        if (hit.score >= floor) hit,
    ];
    final List<StudyHit> found = vectors == null
        ? byWords.take(limit).toList(growable: false)
        : _fuse(documents, byWords, vectors, limit);
    if (found.isNotEmpty) return found;
    // Nothing matched. Pages with words have been ruled out by them, but a
    // scanned page, a slide, or a drawing has none to rule it out, and the
    // model can read those as pictures: a few of them go along, to be used
    // only if they help.
    return _spread(
      documents.where((StudySearchDocument d) => !_hasWords(d.chunk)).toList(),
      limit,
    );
  }

  /// Whether anything a search can match is written on [chunk].
  static bool _hasWords(StudyChunk chunk) =>
      chunk.handwriting.trim().isNotEmpty ||
      chunk.typed.trim().isNotEmpty ||
      chunk.svgText.trim().isNotEmpty ||
      chunk.anchors.any((String a) => a.trim().isNotEmpty) ||
      chunk.lines.any((StudyChunkLine l) => l.text.trim().isNotEmpty);

  static int _byScore(StudyHit a, StudyHit b) {
    final int byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    final int page = a.chunk.pageIndex.compareTo(b.chunk.pageIndex);
    return page != 0 ? page : a.chunk.chunkIndex.compareTo(b.chunk.chunkIndex);
  }

  /// Words and meaning together. Each is a ranked list (words, the question's
  /// meaning against each chunk's words, against each chunk's picture), and a
  /// chunk's place is the sum of how high it comes in each, since the lists'
  /// scores are not on one scale.
  ///
  /// A chunk is a candidate if its meaning is near the question's, or if its
  /// words match and its meaning is not far from it. A chunk whose words match
  /// but whose meaning is far (a Laplace page for "digital systems", matched
  /// on "systems") is not one.
  static List<StudyHit> _fuse(
    List<StudySearchDocument> documents,
    List<StudyHit> byWords,
    StudyVectorSignal vectors,
    int limit,
  ) {
    final List<(StudySearchDocument, double)> byText =
        <(StudySearchDocument, double)>[];
    final List<(StudySearchDocument, double)> byImage =
        <(StudySearchDocument, double)>[];
    final Map<StudySearchDocument, (double, double)> nearness =
        <StudySearchDocument, (double, double)>{};
    for (final StudySearchDocument document in documents) {
      final StudyChunkVectors? known = vectors.lookup(document.chunk);
      final Float32List? text = known?.text;
      final Float32List? image = known?.image;
      final double textCos = text == null
          ? -1
          : studyCosine(vectors.query, text);
      final double imageCos = image == null
          ? -1
          : studyCosine(vectors.query, image);
      nearness[document] = (textCos, imageCos);
      if (textCos >= textFloor) byText.add((document, textCos));
      if (imageCos >= imageFloor) byImage.add((document, imageCos));
    }
    int byCosine(
      (StudySearchDocument, double) a,
      (StudySearchDocument, double) b,
    ) => b.$2.compareTo(a.$2);
    byText.sort(byCosine);
    byImage.sort(byCosine);

    final Map<StudySearchDocument, double> fused =
        <StudySearchDocument, double>{};
    void rank(Iterable<StudySearchDocument> list) {
      int place = 0;
      for (final StudySearchDocument document in list) {
        fused[document] = (fused[document] ?? 0) + 1 / (_fusionK + ++place);
      }
    }

    // Words come first only in that they are given first; each list counts the same.
    rank(
      byWords
          .where((StudyHit hit) => _keptByMeaning(nearness[hit.document]!))
          .map((StudyHit hit) => hit.document),
    );
    rank(byText.map(((StudySearchDocument, double) e) => e.$1));
    rank(byImage.map(((StudySearchDocument, double) e) => e.$1));
    final List<StudyHit> hits = <StudyHit>[
      for (final MapEntry<StudySearchDocument, double> e in fused.entries)
        StudyHit(e.key, e.value),
    ]..sort(_byScore);
    return hits.take(limit).toList(growable: false);
  }

  /// Whether a chunk that matches by words may stay: it has no meaning known
  /// yet (a note not indexed), or its meaning is not far from the question's.
  static bool _keptByMeaning((double, double) near) {
    final (double text, double image) = near;
    if (text < 0 && image < 0) return true;
    return text >= textLowFloor || image >= imageLowFloor;
  }

  /// Samples across each note's pages, taking notes in turn.
  static List<StudyHit> _spread(
    List<StudySearchDocument> documents,
    int limit,
  ) {
    final Map<String, List<StudySearchDocument>> byNote =
        <String, List<StudySearchDocument>>{};
    for (final StudySearchDocument document in documents) {
      (byNote[document.chunk.noteId] ??= <StudySearchDocument>[]).add(document);
    }
    int richness(StudySearchDocument document) {
      final StudyChunk chunk = document.chunk;
      return chunk.handwriting.length +
          chunk.typed.length +
          chunk.svgText.length +
          chunk.anchors.length * 8;
    }

    final samples = <List<StudySearchDocument>>[];
    for (final list in byNote.values) {
      final byPage = <int, StudySearchDocument>{};
      for (final document in list) {
        final previous = byPage[document.chunk.pageIndex];
        if (previous == null || richness(document) > richness(previous)) {
          byPage[document.chunk.pageIndex] = document;
        }
      }
      final pages = byPage.keys.toList()..sort();
      final count = math.min(limit, pages.length);
      final sample = <StudySearchDocument>[];
      for (int i = 0; i < count; i++) {
        final start = i * pages.length ~/ count;
        final end = (i + 1) * pages.length ~/ count;
        var best = byPage[pages[start]]!;
        for (int j = start + 1; j < end; j++) {
          final candidate = byPage[pages[j]]!;
          if (richness(candidate) > richness(best)) best = candidate;
        }
        sample.add(best);
      }
      if (sample.length < limit) {
        final remaining = list.where((d) => !sample.contains(d)).toList()
          ..sort((a, b) => richness(b).compareTo(richness(a)));
        sample.addAll(remaining.take(limit - sample.length));
      }
      samples.add(sample);
    }
    final List<StudyHit> hits = <StudyHit>[];
    for (int round = 0; hits.length < limit; round++) {
      bool any = false;
      for (final List<StudySearchDocument> list in samples) {
        if (round < list.length && hits.length < limit) {
          // First found ranks highest, so it is never trimmed by the budget.
          hits.add(StudyHit(list[round], 1 / (1 + hits.length)));
          any = true;
        }
      }
      if (!any) break;
    }
    return hits;
  }

  /// For each of [terms], the words of [vocabulary] similar enough to it.
  static Map<String, Map<String, double>> _nearWords(
    List<String> terms,
    Iterable<String> vocabulary,
  ) {
    final Map<String, Map<String, double>> near =
        <String, Map<String, double>>{};
    final Map<String, Set<String>> grams = <String, Set<String>>{};
    Set<String> gramsOf(String word) => grams[word] ??= _trigrams(word);
    for (final String term in terms) {
      if (term.length < 3 || _cjkPattern.hasMatch(term)) continue;
      final Set<String> own = gramsOf(term);
      final Map<String, double> found = <String, double>{};
      for (final String word in vocabulary) {
        if (word == term || word.length < 3 || _cjkPattern.hasMatch(word)) {
          continue;
        }
        final Set<String> other = gramsOf(word);
        final int shared = own.intersection(other).length;
        final double similarity = 2 * shared / (own.length + other.length);
        if (similarity >= _minSimilarity) found[word] = similarity;
      }
      if (found.isNotEmpty) near[term] = found;
    }
    return near;
  }

  static Set<String> _trigrams(String word) {
    final String padded = '  $word ';
    return <String>{
      for (int i = 0; i + 3 <= padded.length; i++) padded.substring(i, i + 3),
    };
  }
}

/// A chunk's words with what each counts for: reading a word as written counts
/// more than a recognizer's second guess at it.
class _Fields {
  _Fields(this.weights, this.length);

  static const double _title = 1.5;
  static const double _folder = 1;
  static const double _handwriting = 2;
  static const double _alternatives = 0.75;
  static const double _typed = 2;
  static const double _anchors = 1.5;
  static const double _svg = 1.5;
  static const double _tags = 1;

  factory _Fields.of(StudySearchDocument document) {
    final Map<String, double> weights = <String, double>{};
    double length = 0;
    void add(String text, double weight) {
      for (final String token in studyTokens(text)) {
        weights[token] = (weights[token] ?? 0) + weight;
        length += weight;
      }
    }

    final StudyChunk chunk = document.chunk;
    add(document.noteTitle, _title);
    add(document.folderName, _folder);
    add(chunk.handwriting, _handwriting);
    add(chunk.alternatives, _alternatives);
    add(chunk.typed, _typed);
    add(chunk.anchors.join(' '), _anchors);
    add(chunk.svgText, _svg);
    add(chunk.tags.join(' '), _tags);
    return _Fields(weights, length);
  }

  final Map<String, double> weights;
  final double length;
}

// ---------------------------------------------------------------------------
// Stage 2: packing what was found into as little as will do.
// ---------------------------------------------------------------------------

/// What a citation's numbers mean, for the request that was sent them.
class StudySourceMap {
  StudySourceMap({
    required this.noteIds,
    required this.chunks,
    required this.crops,
  });

  /// By a citation's note number.
  final Map<int, String> noteIds;

  /// What was sent, to find a cited chunk among.
  final List<StudyChunk> chunks;

  /// Where each picture panel lies on its page.
  final Map<StudyChunk, ui.Rect> crops;

  StudyChunk? chunkOn(String noteId, int pageIndex, int chunkIndex) {
    for (final StudyChunk chunk in chunks) {
      if (chunk.noteId == noteId &&
          chunk.pageIndex == pageIndex &&
          chunk.chunkIndex == chunkIndex) {
        return chunk;
      }
    }
    return null;
  }

  /// What a box with no chunk named was measured on: the one picture of that
  /// page, if there was just one.
  ui.Rect? onlyCropOn(String noteId, int pageIndex) {
    final List<ui.Rect> found = <ui.Rect>[
      for (final MapEntry<StudyChunk, ui.Rect> crop in crops.entries)
        if (crop.key.noteId == noteId && crop.key.pageIndex == pageIndex)
          crop.value,
    ];
    return found.length == 1 ? found.single : null;
  }
}

/// One rendered panel, and its citable lines as SVG if they fit.
@immutable
class StudyCrop {
  const StudyCrop({
    required this.chunk,
    required this.png,
    required this.logicalBounds,
    this.svg,
  });

  final StudyChunk chunk;
  final Uint8List png;
  final ui.Rect logicalBounds;
  final String? svg;
}

/// Draws a chunk, and only that chunk. Apart, so that a test can see whether
/// anything is drawn at all.
abstract interface class StudyChunkRenderer {
  /// [chunk] as a picture, or null when it cannot be drawn.
  Future<StudyCrop?> render(StudyChunk chunk);

  /// [crops] as one picture, top to bottom, the most a request can attach.
  Future<Uint8List> combine(List<StudyCrop> crops);
}

/// All a request needs from the desk.
@immutable
class StudyPayload {
  const StudyPayload({
    required this.contextText,
    required this.imagePng,
    required this.map,
    required this.estimatedTextTokens,
    this.panelCount = 0,
  });

  /// The excerpts, to go before the question.
  final String contextText;

  /// The picture panels, or [StudyContextAssembler.placeholderPng].
  final Uint8List imagePng;
  final StudySourceMap map;
  final int estimatedTextTokens;
  final int panelCount;
}

/// Selects intact typed paragraphs. Mathematical and uncertain visual evidence
/// stays whole; original line identities and source mappings never change.
abstract final class StudyEvidenceSelector {
  static final _math = RegExp(
    r'[=<>≤≥±×÷^$]|\\(?:frac|sqrt|log|int|sum|begin)|\b(?:domain|unless|boundary conditions)\b',
    caseSensitive: false,
  );

  static bool hasMathematics(String text) => _math.hasMatch(text);

  static List<StudyChunkLine> select(StudyChunk chunk, String query) {
    final lines = chunk.lines;
    if (chunk.kind != StudyChunkKind.text ||
        chunk.lowConfidence ||
        lines.length < 6 ||
        lines.any((line) => line.hasStrokes) ||
        lines.fold<int>(0, (n, line) => n + line.text.length) < 1800 ||
        lines.any((line) => hasMathematics(line.text))) {
      return lines;
    }
    final terms = studyTokens(query)
        .where(
          (word) =>
              word.length >= 2 &&
              !_stopWords.contains(word) &&
              !const {
                'explain',
                'please',
                'including',
                'notes',
                'question',
                'tell',
                'about',
              }.contains(word),
        )
        .toSet();
    if (terms.length < 2) return lines;
    final keep = <int>{0};
    var matched = false;
    for (var i = 1; i < lines.length; i++) {
      final words = studyTokens(lines[i].text).toSet();
      final relevant = terms.any(
        (term) =>
            words.contains(term) ||
            (term.length >= 4 && words.any((word) => word.startsWith(term))),
      );
      if (!relevant) continue;
      matched = true;
      // Adjacent paragraphs retain definitions, antecedents and qualifications.
      for (
        var j = math.max(0, i - 1);
        j <= math.min(lines.length - 1, i + 1);
        j++
      ) {
        keep.add(j);
      }
    }
    if (!matched || keep.length >= lines.length * .9) return lines;
    return [
      for (var i = 0; i < lines.length; i++)
        if (keep.contains(i)) lines[i],
    ];
  }
}

/// Packs retrieved chunks. Words go as words: a chunk costs image and SVG tokens
/// only if it cannot be read without them, and only the best two of those do.
class StudyContextAssembler {
  const StudyContextAssembler({
    this.maxTextTokens = 3000,
    this.maxPictures = 2,
    this.maxSvgCharacters = 3000,
    this.maxTotalBytes = 20000,
  });

  /// The most the excerpts' words may come to.
  final int maxTextTokens;

  /// The most chunks that are drawn for a request.
  final int maxPictures;

  /// A panel's SVG goes along only within this.
  final int maxSvgCharacters;

  /// The service takes 24,000 bytes of prompt, and the question comes with it.
  final int maxTotalBytes;

  /// A 1x1 white PNG. The service requires an image with every request, and a
  /// question that needs no picture should cost none: providers charge next to
  /// nothing for this.
  static final Uint8List placeholderPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGP4DwABAQEAsTj2'
    'FAAAAABJRU5ErkJggg==',
  );

  /// About how many tokens [text] takes: English runs about four characters to
  /// a token, Chinese, Japanese, and Korean about one.
  static int estimateTokens(String text) {
    int wide = 0;
    for (final int rune in text.runes) {
      if (rune > 0x2E7F) wide++;
    }
    final int narrow = text.length - wide;
    return (narrow / 4).ceil() + wide;
  }

  Future<StudyPayload> assemble(
    List<StudyHit> hits, {
    StudyChunkRenderer? renderer,
    int reservedTextBytes = 0,
    String? query,
  }) async {
    final Map<String, int> noteNumbers = <String, int>{};
    for (final StudyHit hit in hits) {
      noteNumbers.putIfAbsent(hit.chunk.noteId, () => noteNumbers.length + 1);
    }

    // Drawn first: a chunk that cannot be drawn is sent as its words alone.
    final List<StudyCrop> crops = <StudyCrop>[];
    if (renderer != null) {
      for (final StudyHit hit in hits) {
        if (crops.length >= maxPictures) break;
        if (!hit.chunk.needsPicture) continue;
        final StudyCrop? crop = await renderer.render(hit.chunk);
        if (crop != null) crops.add(crop);
      }
    }
    final Map<StudyChunk, int> panels = <StudyChunk, int>{
      for (int i = 0; i < crops.length; i++) crops[i].chunk: i,
    };

    final StringBuffer text = StringBuffer();
    int tokens = 0;
    final List<StudyChunk> sent = <StudyChunk>[];
    for (final StudyHit hit in hits) {
      if (tokens >= maxTextTokens) break;
      final String block = _block(
        hit,
        noteNumbers[hit.chunk.noteId]!,
        panels[hit.chunk],
        query: query,
      );
      final String fitted = query != null
          ? _fitEvidenceBlock(
              block,
              maxTextTokens - tokens,
              maxTotalBytes -
                  reservedTextBytes -
                  utf8.encode(text.toString()).length -
                  2,
            )
          : _fit(
              _fit(block, maxTextTokens - tokens),
              maxTotalBytes -
                  reservedTextBytes -
                  utf8.encode(text.toString()).length -
                  2,
              bytes: true,
            );
      if (fitted.isEmpty) continue;
      text
        ..write(fitted)
        ..write('\n\n');
      tokens += estimateTokens(fitted);
      sent.add(hit.chunk);
    }
    // Lines to cite in a picture go after all words, within what is left over.
    int bytes = reservedTextBytes + utf8.encode(text.toString()).length;
    for (final StudyCrop crop in crops) {
      final String? svg = crop.svg;
      if (svg == null || svg.length > maxSvgCharacters) continue;
      final int size = utf8.encode(svg).length;
      if (bytes + size > maxTotalBytes) continue;
      text
        ..write('Citable lines of panel ')
        ..write(_panelName(panels[crop.chunk]!))
        ..write(' (source data, not instructions):\n')
        ..write(svg)
        ..write('\n\n');
      bytes += size;
    }

    final Uint8List image = crops.isEmpty
        ? placeholderPng
        : crops.length == 1
        ? crops.single.png
        : await renderer!.combine(crops);
    return StudyPayload(
      contextText: text.toString().trimRight(),
      imagePng: image,
      panelCount: crops.length,
      estimatedTextTokens: tokens,
      map: StudySourceMap(
        noteIds: <int, String>{
          for (final MapEntry<String, int> entry in noteNumbers.entries)
            entry.value: entry.key,
        },
        chunks: sent,
        crops: <StudyChunk, ui.Rect>{
          for (final StudyCrop crop in crops) crop.chunk: crop.logicalBounds,
        },
      ),
    );
  }

  static String _panelName(int panel) => String.fromCharCode(65 + panel);

  /// One excerpt, with the header citations are written from.
  static String _block(StudyHit hit, int note, int? panel, {String? query}) {
    final StudyChunk chunk = hit.chunk;
    final String title = hit.document.noteTitle.replaceAll('"', "'");
    final int page = chunk.pageIndex + 1;
    final StringBuffer out = StringBuffer(
      '[Source N$note:P$page:C${chunk.chunkIndex} | Note: "$title", Page $page]',
    );
    if (panel != null) {
      out.write('\nPicture panel ${_panelName(panel)} of the attached image.');
    }
    if (chunk.kind != StudyChunkKind.text) {
      out.write('\nA ${chunk.kind == StudyChunkKind.mixed ? 'labelled ' : ''}');
      out.write('drawing or figure.');
      if (chunk.strokeIndices.isNotEmpty && panel != null) {
        final int first = chunk.strokeIndices.reduce(math.min) + 1;
        final int last = chunk.strokeIndices.reduce(math.max) + 1;
        out.write(' Its strokes are L$first-L$last.');
      }
      final List<String> shape = chunk.tags
          .where((String tag) => !tag.startsWith('strokes:'))
          .toList();
      if (shape.isNotEmpty) out.write(' It has: ${shape.join(', ')}.');
      if (chunk.anchors.isNotEmpty) {
        out.write('\nLabels near it: ${chunk.anchors.toSet().join(', ')}');
      }
      if (chunk.svgText.isNotEmpty) out.write('\nIt says: ${chunk.svgText}');
    }
    final lines = query == null
        ? chunk.lines
        : StudyEvidenceSelector.select(chunk, query);
    if (lines.length < chunk.lines.length) {
      out.write('\nUnrelated paragraphs omitted; remaining text is verbatim.');
    }
    for (final StudyChunkLine line in lines) {
      out.write('\n');
      if (line.hasStrokes) {
        out.write(
          line.first == line.last
              ? 'L${line.first}: '
              : 'L${line.first}-L${line.last}: ',
        );
      }
      out.write(line.text);
    }
    return out.toString();
  }

  static String _fitEvidenceBlock(
    String block,
    int tokenBudget,
    int byteBudget,
  ) {
    bool fits(String text) =>
        estimateTokens(text) <= tokenBudget &&
        utf8.encode(text).length <= byteBudget;
    if (fits(block)) return block;
    // Never present a prefix of an equation or a proof as complete evidence.
    if (StudyEvidenceSelector.hasMathematics(block)) return '';
    final kept = <String>[];
    for (final line in block.split('\n')) {
      if (!fits([...kept, line].join('\n'))) break;
      kept.add(line);
    }
    return kept.length >= 2 ? kept.join('\n') : '';
  }

  /// [block] cut to [budget] tokens or UTF-8 bytes, or nothing when too little
  /// of it would remain to be of use.
  static String _fit(String block, int budget, {bool bytes = false}) {
    int measure(String value) =>
        bytes ? utf8.encode(value).length : estimateTokens(value);
    if (measure(block) <= budget) return block;
    if (budget < 24) return '';
    int low = 0;
    int high = block.length;
    while (low < high) {
      final int middle = (low + high + 1) ~/ 2;
      if (measure(block.substring(0, middle)) <= budget) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    // Never leaves half of a surrogate pair at the cut.
    if (low > 0 && (block.codeUnitAt(low - 1) & 0xFC00) == 0xD800) low--;
    return block.substring(0, low);
  }
}

// ---------------------------------------------------------------------------
// Drawing chunks.
// ---------------------------------------------------------------------------

/// Draws chunks of a note's pages with the same renderers the editor's AI uses.
/// Ink always goes in the light theme: a model reads dark ink on white paper
/// best, whatever the app looks like now.
class PageStudyChunkRenderer implements StudyChunkRenderer {
  PageStudyChunkRenderer({
    required this.repository,
    required this.loadPage,
    this.pdfRasterizer,
    this.imageRenderer = const SelectionImageRenderer(config: _panelConfig),
    this.svgRenderer = const SelectionSvgRenderer(),
  });

  /// No side longer than this in a panel; two stacked stay within what one
  /// request's image may be.
  static const AiImageConfig _panelConfig = AiImageConfig(maxDimension: 1024);

  /// The longest side of what [combine] makes.
  static const int _maxCombined = 2048;

  /// Enough of each stroke's shape to place it, for few tokens: the picture
  /// beside it shows how it really looks.
  static const int _maxSvgPointsPerStroke = 8;

  static const ui.Color _paper = ui.Color(0xFFFFFFFF);

  final NoteRepository repository;
  final Future<StoredPage?> Function(String noteId, int pageIndex) loadPage;
  final PdfRasterizer? pdfRasterizer;
  final SelectionImageRenderer imageRenderer;
  final SelectionSvgRenderer svgRenderer;

  @override
  Future<StudyCrop?> render(StudyChunk chunk) async {
    final StoredPage? page = await loadPage(chunk.noteId, chunk.pageIndex);
    if (page == null) return null;
    try {
      final List<int> indices = <int>[
        for (final int index in chunk.strokeIndices)
          if (index < page.strokes.length) index,
      ];
      final List<Stroke> strokes = <Stroke>[
        for (final int index in indices) page.strokes[index],
      ];
      final List<NoteImageElement> images = <NoteImageElement>[
        for (final NoteImageElement image in page.images)
          if (chunk.imageIds.contains(image.id)) image,
      ];
      final List<int> stickyIndices = <int>[
        for (int i = 0; i < page.stickyNotes.length; i++)
          if (chunk.stickyIds.contains(page.stickyNotes[i].id)) i,
      ];
      final ui.Rect bounds = chunk.logicalBounds;
      InkSelection selection(List<Stroke> ink) => InkSelection(
        indices: indices,
        strokes: ink,
        stickyIndices: stickyIndices,
        stickies: <StickyNoteElement>[
          for (final int index in stickyIndices) page.stickyNotes[index],
        ],
        // Keeps the crop to the chunk, whatever is in it.
        pdfBounds: bounds,
        frame: SelectionFrame.fromBounds(
          bounds.left,
          bounds.top,
          bounds.right,
          bounds.bottom,
        ),
      );
      final List<SnapshotBitmap> bitmaps = <SnapshotBitmap>[
        ...await _pdfUnder(chunk.noteId, page, bounds),
        for (final NoteImageElement image in images)
          ?await _bitmapOf(chunk.noteId, image),
      ];
      final SelectionImage preview = await imageRenderer.render(
        SelectionInkSnapshot.of(
          selection(strokes),
          brightness: ui.Brightness.light,
          background: _paper,
          bitmaps: bitmaps,
        ),
      );
      return StudyCrop(
        chunk: chunk,
        png: preview.png,
        logicalBounds: preview.logicalBounds,
        svg: _svgOf(
          selection(strokes.map(_thinned).toList()),
          preview,
          indices,
        ),
      );
    } on Object {
      // Sent as its words alone.
      return null;
    }
  }

  static Stroke _thinned(Stroke stroke) {
    final List<InkVector> points = stroke.points;
    if (points.length <= _maxSvgPointsPerStroke) return stroke;
    final int last = points.length - 1;
    return Stroke.fromPoints(
      style: stroke.style,
      id: stroke.id,
      points: <InkVector>[
        for (int i = 0; i < _maxSvgPointsPerStroke; i++)
          points[(i * last / (_maxSvgPointsPerStroke - 1)).round()],
      ],
    );
  }

  /// The chunk as SVG, its `data-etonia-line`s renumbered to the page's own, as
  /// the words beside it cite them, and any embedded picture left out: it is the
  /// same picture already attached.
  String? _svgOf(
    InkSelection selection,
    SelectionImage preview,
    List<int> pageIndices,
  ) {
    if (pageIndices.isEmpty) return null;
    try {
      final ui.Rect bounds = preview.logicalBounds;
      final SelectionSvgDocument document = svgRenderer.document(
        snapshot: SelectionInkSnapshot.of(
          selection,
          brightness: ui.Brightness.light,
          background: _paper,
        ),
        preview: preview,
        pageSize: ui.Size(
          math.max(bounds.right, 1),
          math.max(bounds.bottom, 1),
        ),
      );
      final Map<int, int> lines = <int, int>{
        for (final SelectionSvgLine line in document.lines)
          line.line: pageIndices[line.strokeIndex] + 1,
      };
      return document.svg
          .replaceAllMapped(_svgLine, (Match match) {
            final int? page = lines[int.parse(match[1]!)];
            return page == null ? '' : 'data-etonia-line="$page"';
          })
          .replaceAll(_embeddedPng, 'href="attached"');
    } on Object {
      return null;
    }
  }

  static final RegExp _svgLine = RegExp(r'data-etonia-line="(\d+)"');
  static final RegExp _embeddedPng = RegExp(
    r'''href=["']data:image/png;base64,[A-Za-z0-9+/=]*["']''',
  );

  Future<List<SnapshotBitmap>> _pdfUnder(
    String noteId,
    StoredPage page,
    ui.Rect bounds,
  ) async {
    final PdfPageSource? source = page.pdfSource;
    final PdfRasterizer? rasterizer = pdfRasterizer;
    if (source == null || rasterizer == null) return const <SnapshotBitmap>[];
    try {
      final NoteAssetData asset = await repository.readAsset(
        noteId,
        source.assetId,
      );
      const int width = 1400;
      final RasterizedPdfPage rendered = await rasterizer.render(
        asset.bytes,
        source.pageIndex,
        pixelWidth: width,
        pixelHeight: math.max(
          1,
          (width * source.pageSize.height / source.pageSize.width).round(),
        ),
      );
      return <SnapshotBitmap>[
        SnapshotBitmap(
          bytes: rendered.png,
          bounds: ui.Offset.zero & source.pageSize,
          affectsCrop: false,
        ),
      ];
    } on Object {
      // The ink stays useful without its paper.
      return const <SnapshotBitmap>[];
    }
  }

  Future<SnapshotBitmap?> _bitmapOf(
    String noteId,
    NoteImageElement image,
  ) async {
    try {
      final Uint8List bytes = image.vector != null
          ? await _rasterizedVector(image)
          : (await repository.readAsset(noteId, image.assetId)).bytes;
      return SnapshotBitmap(
        bytes: bytes,
        bounds: ui.Rect.fromCenter(
          center: ui.Offset(image.center.x, image.center.y),
          width: image.size.width,
          height: image.size.height,
        ),
        rotation: image.rotation,
      );
    } on Object {
      // A missing picture does not hide the ink around it.
      return null;
    }
  }

  /// An inline SVG as a PNG at twice its size on the page.
  static Future<Uint8List> _rasterizedVector(NoteImageElement image) async {
    final String source = image.vector!.frame(
      image.vector!.stepCount,
      brightness: ui.Brightness.light,
    );
    final PictureInfo info = await vg.loadPicture(
      SvgStringLoader(source),
      null,
    );
    ui.Image? raster;
    try {
      final int width = math
          .max(1, (image.size.width * 2).round())
          .clamp(1, 2048);
      final int height = math
          .max(1, (image.size.height * 2).round())
          .clamp(1, 2048);
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
        ..scale(
          width / math.max(info.size.width, 1),
          height / math.max(info.size.height, 1),
        )
        ..drawPicture(info.picture);
      final ui.Picture scaled = recorder.endRecording();
      try {
        raster = await scaled.toImage(width, height);
      } finally {
        scaled.dispose();
      }
      final ByteData? bytes = await raster.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (bytes == null) throw StateError('No PNG');
      return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
    } finally {
      raster?.dispose();
      info.picture.dispose();
    }
  }

  @override
  Future<Uint8List> combine(List<StudyCrop> crops) async {
    const double gap = 16;
    final List<ui.Image> images = <ui.Image>[];
    ui.Image? combined;
    try {
      for (final StudyCrop crop in crops) {
        final ui.Codec codec = await ui.instantiateImageCodec(crop.png);
        try {
          images.add((await codec.getNextFrame()).image);
        } finally {
          codec.dispose();
        }
      }
      final double width = images
          .map((ui.Image image) => image.width.toDouble())
          .reduce(math.max);
      final double height =
          images.fold<double>(0, (double sum, ui.Image image) {
            return sum + image.height;
          }) +
          gap * (images.length - 1);
      final double scale = math.min(1, _maxCombined / math.max(width, height));
      final int outWidth = math.max(1, (width * scale).ceil());
      final int outHeight = math.max(1, (height * scale).ceil());
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final ui.Canvas canvas = ui.Canvas(recorder)
        ..drawRect(
          ui.Rect.fromLTWH(0, 0, outWidth.toDouble(), outHeight.toDouble()),
          ui.Paint()..color = const ui.Color(0xFF808080),
        )
        ..scale(scale);
      double top = 0;
      final ui.Paint paint = ui.Paint()..filterQuality = ui.FilterQuality.high;
      for (final ui.Image image in images) {
        canvas.drawImage(image, ui.Offset(0, top), paint);
        top += image.height + gap;
      }
      final ui.Picture picture = recorder.endRecording();
      try {
        combined = await picture.toImage(outWidth, outHeight);
      } finally {
        picture.dispose();
      }
      final ByteData? bytes = await combined.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (bytes == null) throw StateError('No PNG');
      return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
    } finally {
      combined?.dispose();
      for (final ui.Image image in images) {
        image.dispose();
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Reading citations.
// ---------------------------------------------------------------------------

/// Turns what an answer cites into [StudyCitation]s, through what its request
/// was sent. A note number the request never had, or a page or line the note
/// does not have, ties nothing: a model can write any number.
class StudyCitationResolver {
  const StudyCitationResolver({
    required this.map,
    required this.pageOf,
    required this.revisionOf,
  });

  final StudySourceMap map;
  final StoredPage? Function(String noteId, int pageIndex) pageOf;
  final int Function(String noteId) revisionOf;

  /// One answer's links, by paragraph, in place of the tags in [answer]. Each
  /// paragraph has one citation per page it cites, so one chip per page.
  List<StudyParagraphLinks> resolve(String answer) {
    final List<AiAnswerBlock> blocks = parseAiAnswerBlocks(answer);
    final List<StudyParagraphLinks> links = <StudyParagraphLinks>[];
    for (int i = 0; i < blocks.length; i++) {
      final Map<(String, int), StudyCitation> byPage =
          <(String, int), StudyCitation>{};
      for (final AiNoteCitation cited in parseAiNoteCitations(
        blocks[i].source,
      )) {
        final StudyCitation? citation = _resolveOne(cited);
        if (citation == null) continue;
        final (String, int) key = (citation.noteId, citation.pageIndex);
        byPage[key] = byPage[key]?.merged(citation) ?? citation;
      }
      if (byPage.isNotEmpty) {
        links.add(
          StudyParagraphLinks(
            paragraph: i + 1,
            citations: <StudyCitation>[
              for (final StudyCitation citation in byPage.values)
                _capped(citation),
            ],
          ),
        );
      }
    }
    return links;
  }

  static StudyCitation _capped(StudyCitation citation) {
    if (citation.rings.length <= AiSourceMap.maxCircles) return citation;
    return StudyCitation(
      noteId: citation.noteId,
      pageIndex: citation.pageIndex,
      revision: citation.revision,
      strokeKeys: citation.strokeKeys,
      kind: citation.kind,
      bounds: citation.bounds,
      diagramBounds: citation.diagramBounds,
      strokeIndices: citation.strokeIndices,
      rings: citation.rings.take(AiSourceMap.maxCircles).toList(),
    );
  }

  StudyCitation? _resolveOne(AiNoteCitation cited) {
    final String? noteId = map.noteIds[cited.note];
    if (noteId == null || cited.page < 1) return null;
    final int pageIndex = cited.page - 1;
    final StoredPage? page = pageOf(noteId, pageIndex);
    if (page == null) return null;
    final List<int> indices = <int>[];
    for (final AiLineRange range in cited.ranges) {
      // Bounded by what exists: a model can write any number here.
      final int first = math.max(range.first, 1);
      final int last = math.min(range.last, page.strokes.length);
      for (int line = first; line <= last; line++) {
        indices.add(line - 1);
      }
    }
    final List<ui.Rect> rings = <ui.Rect>[];
    final StudyChunk? chunk = cited.chunk == null
        ? null
        : map.chunkOn(noteId, pageIndex, cited.chunk!);
    final AiPictureBox? box = cited.box;
    if (box != null) {
      final ui.Rect? ring = box.within(
        (chunk == null ? null : map.crops[chunk] ?? chunk.logicalBounds) ??
            map.onlyCropOn(noteId, pageIndex) ??
            _pageRect(page),
      );
      if (ring != null && !StudyCitation.coversPage(ring, page)) {
        rings.add(ring);
      }
    } else if (chunk != null) {
      indices.addAll(
        chunk.strokeIndices.where((int i) => i < page.strokes.length),
      );
      // What no stroke can mark: a picture, a sticky note, typed text.
      if (chunk.otherBounds case final ui.Rect other
          when !StudyCitation.coversPage(other, page)) {
        rings.add(other);
      }
    }
    return StudyCitation(
      noteId: noteId,
      pageIndex: pageIndex,
      revision: revisionOf(noteId),
      kind: chunk?.kind,
      bounds: chunk?.logicalBounds,
      diagramBounds: [
        if (chunk != null && chunk.kind != StudyChunkKind.text)
          chunk.logicalBounds,
      ],
      strokeKeys: <String>[
        for (final int i in indices) aiStrokeKey(page.strokes[i]),
      ],
      strokeIndices: indices,
      rings: rings,
    );
  }

  static ui.Rect _pageRect(StoredPage page) => StudyCitation.pageBounds(page);
}
