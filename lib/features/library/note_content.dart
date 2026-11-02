import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../editor/document_io/document_models.dart';
import '../editor/document_io/svg_document.dart';
import '../editor/handwriting/recognized_handwriting.dart';
import '../editor/ink/ink_controller.dart';
import '../editor/ink/ink_palette.dart';
import '../editor/ink/ink_sample.dart';
import '../editor/ink/notation_playback.dart';
import '../editor/ink/stroke.dart';
import '../editor/ink/selection_transform.dart';
import '../editor/page/content_bounds.dart';
import '../editor/page/note_document.dart';
import '../editor/page/page_setup.dart';
import '../editor/sticky/sticky_note.dart';
import '../editor/text/note_text.dart';
import 'note_recording_track.dart';

/// Schema 2 adds PDF sources, images, fixed custom sizes, and Fit history.
/// Schema 3 adds AI notation playbacks and the AI assistant's conversations.
/// Schema 4 adds sticky notes per page, and highlighter strokes (a `style`
/// and `opacity` on a stroke; without them a stroke is a pen stroke).
/// Schema 5 adds searchable handwriting and its reusable normalized strokes.
/// Schema 6 adds local audio tracks and synchronized stroke/erase timing.
/// Schema 7 keeps editable SVG source inline with vector page elements.
/// Schema 8 adds editable typed text boxes. An infinite page written with a
/// `boardOrigin` has its ink in [InfiniteBoard] coordinates; one without it
/// is from before whiteboards, and its ink is moved onto the board as read.
const int storageSchema = 8;

/// A note's reading was dropped part way: no one waited for it any more.
class LoadAbandoned implements Exception {
  const LoadAbandoned();

  @override
  String toString() => 'LoadAbandoned';
}

class StorageFormatException implements Exception {
  const StorageFormatException(this.message);
  final String message;
  @override
  String toString() => 'StorageFormatException: $message';
}

void checkSchema(Map<String, Object?> json) {
  final Object? schema = json['schema'];
  if (schema is! int) {
    throw const StorageFormatException('Missing schema version.');
  }
  if (schema > storageSchema) {
    throw StorageFormatException(
      'Written by a newer version of Etonia (schema $schema).',
    );
  }
}

/// An AI notation drawn over time, again and again: which of the page's
/// strokes it draws, and when each of their points is reached.
@immutable
class StoredPlayback {
  const StoredPlayback({
    required this.strokeIndices,
    required this.timesMs,
    required this.duration,
    required this.surfaceSize,
  });

  /// Of the page's strokes, the ones still drawn by the playback.
  final List<int> strokeIndices;
  final List<List<double>> timesMs;
  final Duration duration;
  final Size surfaceSize;

  static StoredPlayback? fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      return null;
    }
    final Object? strokes = json['strokes'];
    final Object? times = json['timesMs'];
    final Object? duration = json['durationUs'];
    final Object? surface = json['surfaceSize'];
    if (strokes is! List ||
        times is! List ||
        strokes.length != times.length ||
        duration is! int ||
        surface is! List ||
        surface.length != 2) {
      return null;
    }
    return StoredPlayback(
      strokeIndices: <int>[for (final Object? index in strokes) index! as int],
      timesMs: <List<double>>[
        for (final Object? list in times)
          <double>[
            for (final Object? time in list! as List) (time! as num).toDouble(),
          ],
      ],
      duration: Duration(microseconds: duration),
      surfaceSize: StoredPage._size(surface),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'strokes': strokeIndices,
    'timesMs': timesMs,
    'durationUs': duration.inMicroseconds,
    'surfaceSize': StoredPage._sizeJson(surfaceSize),
  };
}

/// A recognized word as stored beside the page ink. [strokeIndices] keep the
/// search entry attached to its source ink; [normalizedStrokes] are a compact
/// vector copy used only when confidence is high enough for AI notation.
@immutable
class StoredRecognizedInkWord {
  const StoredRecognizedInkWord({
    required this.text,
    required this.confidence,
    this.alternatives = const <String>[],
    required this.strokeIndices,
    required this.normalizedStrokes,
    required this.aspectRatio,
    this.stickyId,
  });

  final String text;
  final double? confidence;
  final List<String> alternatives;
  final List<int> strokeIndices;
  final List<List<InkVector>> normalizedStrokes;
  final double aspectRatio;
  final String? stickyId;

  static StoredRecognizedInkWord? fromJson(
    Object? raw,
    List<Stroke> pageStrokes,
    List<StickyNoteElement> stickyNotes,
  ) {
    if (raw is! Map<String, Object?>) return null;
    final Object? text = raw['text'];
    final Object? indices = raw['strokeIndices'];
    final Object? ratio = raw['aspectRatio'];
    final Object? rawConfidence = raw['confidence'];
    final Object? rawStickyId = raw['stickyId'];
    if (rawStickyId != null && rawStickyId is! String) return null;
    final String? stickyId = rawStickyId as String?;
    final StickyNoteElement? sticky = stickyId == null
        ? null
        : stickyNotes
              .where((StickyNoteElement note) => note.id == stickyId)
              .firstOrNull;
    if (stickyId != null && sticky == null) return null;
    final int strokeCount = sticky?.strokes.length ?? pageStrokes.length;
    if (text is! String ||
        indices is! List ||
        indices.isEmpty ||
        ratio is! num ||
        !ratio.isFinite ||
        ratio <= 0) {
      return null;
    }
    final List<int> parsedIndices = <int>[];
    for (final Object? value in indices) {
      if (value is! int || value < 0 || value >= strokeCount) return null;
      parsedIndices.add(value);
    }
    double? confidence;
    if (rawConfidence is num &&
        rawConfidence.isFinite &&
        rawConfidence >= 0 &&
        rawConfidence <= 1) {
      confidence = rawConfidence.toDouble();
    }
    final List<String> alternatives = <String>[
      for (final Object? value
          in (raw['alternatives'] as List?) ?? const <Object?>[])
        if (value is String && value.trim().isNotEmpty) value.trim(),
    ];
    final List<List<InkVector>> normalized = <List<InkVector>>[];
    int points = 0;
    final Object? rawStrokes = raw['normalizedStrokes'];
    if (rawStrokes is List) {
      for (final Object? rawStroke in rawStrokes) {
        if (rawStroke is! List || rawStroke.length.isOdd) return null;
        final List<InkVector> stroke = <InkVector>[];
        for (int i = 0; i + 1 < rawStroke.length; i += 2) {
          final Object? x = rawStroke[i];
          final Object? y = rawStroke[i + 1];
          if (x is! num || y is! num || !x.isFinite || !y.isFinite) {
            return null;
          }
          final InkVector point = InkVector(x.toDouble(), y.toDouble());
          if (point.x < 0 || point.x > 1 || point.y < 0 || point.y > 1) {
            return null;
          }
          stroke.add(point);
          points++;
        }
        if (stroke.isNotEmpty) normalized.add(stroke);
      }
    }
    // Never trust an oversized or insufficiently confident stored sample.
    if (confidence == null ||
        confidence < reusableHandwritingConfidence ||
        points > RecognizedInkWord.maxReusablePoints) {
      normalized.clear();
    }
    return StoredRecognizedInkWord(
      text: text.trim(),
      confidence: confidence,
      alternatives: List<String>.unmodifiable(alternatives),
      strokeIndices: List<int>.unmodifiable(parsedIndices),
      normalizedStrokes: List<List<InkVector>>.unmodifiable(normalized),
      aspectRatio: ratio.toDouble(),
      stickyId: stickyId,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'text': text,
    if (confidence != null) 'confidence': confidence,
    if (alternatives.isNotEmpty) 'alternatives': alternatives,
    'strokeIndices': strokeIndices,
    'aspectRatio': aspectRatio,
    if (stickyId != null) 'stickyId': stickyId,
    if (normalizedStrokes.isNotEmpty)
      'normalizedStrokes': <Object?>[
        for (final List<InkVector> stroke in normalizedStrokes)
          <double>[
            for (final InkVector point in stroke) ...<double>[point.x, point.y],
          ],
      ],
  };
}

@immutable
class StoredPage {
  const StoredPage({
    required this.setup,
    required this.strokes,
    this.extent,
    this.lastFitSize,
    this.pdfSource,
    this.images = const <NoteImageElement>[],
    this.playbacks = const <StoredPlayback>[],
    this.stickyNotes = const <StickyNoteElement>[],
    this.textElements = const <NoteTextElement>[],
    this.recognizedWords = const <StoredRecognizedInkWord>[],
    this.erasedStrokeRecords = const <ErasedStrokeRecord>[],
    this.pdfMasks = const <Rect>[],
  });

  factory StoredPage.fromJson(Map<String, Object?> json) {
    return StoredPage._fromJson(json);
  }

  /// Like [StoredPage.fromJson], but its strokes are made in batches of
  /// about 4ms that yield in between, so frames keep being drawn while a
  /// long page is read. [slice] times the batch, and may be shared across
  /// pages. Once [cancelled] says so, the rest is dropped with
  /// [LoadAbandoned].
  static Future<StoredPage> fromJsonIncrementally(
    Map<String, Object?> json, {
    Stopwatch? slice,
    bool Function()? cancelled,
  }) async {
    final Stopwatch timer = slice ?? (Stopwatch()..start());
    final strokes = <Stroke>[];
    for (final rawStroke in (json['strokes'] as List?) ?? const []) {
      final stroke = _strokeFromJson(rawStroke! as Map<String, Object?>);
      if (stroke != null) strokes.add(stroke);
      if (timer.elapsedMicroseconds >= 4000) {
        await Future<void>.delayed(Duration.zero);
        if (cancelled?.call() ?? false) throw const LoadAbandoned();
        timer.reset();
      }
    }
    return StoredPage._fromJson(json, decodedStrokes: strokes);
  }

  factory StoredPage._fromJson(
    Map<String, Object?> json, {
    List<Stroke>? decodedStrokes,
  }) {
    final Object? extent = json['extent'];
    final Object? customSize = json['customSize'];
    final Object? fitSize = json['lastFitSize'];
    final Object? pdf = json['pdfSource'];
    final List<Object?> rawStrokes =
        (json['strokes'] as List?) ?? const <Object?>[];
    final List<Stroke> strokes =
        decodedStrokes ??
        <Stroke>[
          for (final Object? stroke in rawStrokes)
            ?_strokeFromJson(stroke! as Map<String, Object?>),
        ];
    final List<StickyNoteElement> stickyNotes = _stickyNotesFromJson(
      json['stickyNotes'],
    );
    final StoredPage page = StoredPage(
      setup: PageSetup(
        // Legacy `fit` pages become ordinary A4 paper.
        size: _byName(PageSize.values, json['size'], PageSize.a4Portrait),
        background: _byName(
          PageBackground.values,
          json['background'],
          PageBackground.blank,
        ),
        customSize: customSize is List && customSize.length == 2
            ? _size(customSize)
            : null,
      ),
      extent: extent is List && extent.length == 2 ? _size(extent) : null,
      lastFitSize: fitSize is List && fitSize.length == 2
          ? _size(fitSize)
          : null,
      pdfSource: pdf is Map<String, Object?>
          ? PdfPageSource(
              assetId: pdf['assetId']! as String,
              pageIndex: pdf['pageIndex']! as int,
              pageSize: _size(pdf['pageSize']! as List),
            )
          : null,
      images: <NoteImageElement>[
        for (final Object? image in (json['images'] as List?) ?? <Object?>[])
          _imageFromJson(image! as Map<String, Object?>),
      ],
      strokes: strokes,
      stickyNotes: stickyNotes,
      textElements: _textElementsFromJson(json['textElements']),
      // Unusable strokes are left out, which moves the indices of those
      // after them; playbacks are only kept when none was.
      playbacks: strokes.length == rawStrokes.length
          ? <StoredPlayback>[
              for (final Object? playback
                  in (json['playbacks'] as List?) ?? <Object?>[])
                ?StoredPlayback.fromJson(playback),
            ]
          : const <StoredPlayback>[],
      recognizedWords: strokes.length == rawStrokes.length
          ? <StoredRecognizedInkWord>[
              for (final Object? word
                  in (json['recognizedWords'] as List?) ?? <Object?>[])
                ?StoredRecognizedInkWord.fromJson(word, strokes, stickyNotes),
            ]
          : const <StoredRecognizedInkWord>[],
      erasedStrokeRecords: <ErasedStrokeRecord>[
        for (final Object? raw
            in (json['erasedStrokes'] as List?) ?? const <Object?>[])
          ?_erasedStrokeFromJson(raw),
      ],
      pdfMasks: <Rect>[
        for (final Object? raw
            in (json['pdfMasks'] as List?) ?? const <Object?>[])
          ?_pdfMaskFromJson(raw),
      ],
    );
    if (!page.isBoard) return page;
    // An infinite page from before whiteboards grew right and down from
    // the top-left corner: that corner becomes the middle of the board.
    final Object? origin = json['boardOrigin'];
    final Offset stored = origin is List && origin.length == 2
        ? Offset((origin[0]! as num).toDouble(), (origin[1]! as num).toDouble())
        : Offset.zero;
    final Offset shift = InfiniteBoard.origin - stored;
    return shift == Offset.zero ? page : page.translated(shift);
  }

  /// Whether this page is a whiteboard: an infinite page, its ink in
  /// [InfiniteBoard] coordinates.
  bool get isBoard => setup.size == PageSize.infinite && pdfSource == null;

  /// The box round everything on the page, or null when it is empty.
  Rect? get contentBounds => pageContentBounds(
    strokes: strokes,
    images: images,
    stickies: stickyNotes,
    texts: textElements,
  );

  /// The page as it is shown away from the editor, in thumbnails and
  /// exports: a whiteboard cut down to [InfiniteBoard.frameOf] its ink,
  /// moved to the top-left corner, with that frame as its [extent]. Any
  /// other page is itself.
  StoredPage framed() {
    if (!isBoard) return this;
    final Rect frame = InfiniteBoard.frameOf(contentBounds);
    return translated(-frame.topLeft, extent: frame.size);
  }

  /// This page with everything on it moved by [delta]. Its [extent], which
  /// only an infinite page uses, becomes [extent].
  StoredPage translated(Offset delta, {Size? extent}) {
    final InkVector by = InkVector(delta.dx, delta.dy);
    final InkTransform move = InkTransform.translation(by);
    return StoredPage(
      setup: setup,
      strokes: <Stroke>[for (final Stroke s in strokes) s.translated(by)],
      extent: extent,
      lastFitSize: lastFitSize,
      pdfSource: pdfSource,
      images: <NoteImageElement>[
        for (final NoteImageElement e in images) e.transformed(move),
      ],
      playbacks: playbacks,
      stickyNotes: <StickyNoteElement>[
        for (final StickyNoteElement e in stickyNotes) e.transformed(move),
      ],
      textElements: <NoteTextElement>[
        for (final NoteTextElement e in textElements)
          e.copyWith(position: e.position + by),
      ],
      recognizedWords: recognizedWords,
      erasedStrokeRecords: <ErasedStrokeRecord>[
        for (final ErasedStrokeRecord r in erasedStrokeRecords)
          ErasedStrokeRecord(
            stroke: r.stroke.translated(by),
            erasedAtMs: r.erasedAtMs,
            recordingId: r.recordingId,
          ),
      ],
      pdfMasks: <Rect>[for (final Rect r in pdfMasks) r.shift(delta)],
    );
  }

  /// A blank area of PDF paper stored as `[left, top, width, height]`, or
  /// null when it is unusable.
  static Rect? _pdfMaskFromJson(Object? raw) {
    if (raw is! List || raw.length != 4 || raw.any((Object? v) => v is! num)) {
      return null;
    }
    final Rect rect = Rect.fromLTWH(
      (raw[0]! as num).toDouble(),
      (raw[1]! as num).toDouble(),
      (raw[2]! as num).toDouble(),
      (raw[3]! as num).toDouble(),
    );
    return rect.isFinite && !rect.isEmpty ? rect : null;
  }

  final PageSetup setup;
  final Size? extent;
  final Size? lastFitSize;
  final PdfPageSource? pdfSource;
  final List<NoteImageElement> images;
  final List<Stroke> strokes;
  final List<StoredPlayback> playbacks;
  final List<StoredRecognizedInkWord> recognizedWords;
  final List<ErasedStrokeRecord> erasedStrokeRecords;

  /// Page-local areas of [pdfSource]'s paper left blank, because what was
  /// there was cut, deleted, or moved away.
  final List<Rect> pdfMasks;

  /// In paint order, each with its ink in its own coordinates.
  final List<StickyNoteElement> stickyNotes;

  /// Editable typed text in paint order.
  final List<NoteTextElement> textElements;

  static List<NoteTextElement> _textElementsFromJson(Object? json) {
    if (json is! List) return const <NoteTextElement>[];
    final List<NoteTextElement> elements = <NoteTextElement>[];
    final Set<String> ids = <String>{};
    for (final Object? raw in json) {
      if (raw is! Map<String, Object?>) continue;
      final Object? id = raw['id'];
      final Object? position = raw['position'];
      final Object? text = raw['text'];
      final Object? width = raw['width'];
      final Object? fontSize = raw['fontSize'];
      if (id is! String ||
          id.isEmpty ||
          ids.contains(id) ||
          position is! List ||
          position.length != 2 ||
          text is! String ||
          width is! num ||
          fontSize is! num ||
          position[0] is! num ||
          position[1] is! num) {
        continue;
      }
      final InkColor ink = raw['color'] is String
          ? InkPalette.byId(raw['color']! as String) ?? InkPalette.ink
          : InkPalette.ink;
      final NoteTextElement element = NoteTextElement(
        id: id,
        position: InkVector(
          (position[0]! as num).toDouble(),
          (position[1]! as num).toDouble(),
        ),
        text: text,
        width: width.toDouble(),
        settings: TextSettings(
          fontSize: fontSize.toDouble(),
          ink: ink,
          bold: raw['bold'] == true,
          italic: raw['italic'] == true,
          underline: raw['underline'] == true,
          alignment: _byName(
            TextAlign.values,
            raw['alignment'],
            TextAlign.left,
          ),
          listStyle: _byName(
            TextListStyle.values,
            raw['listStyle'],
            TextListStyle.none,
          ),
        ),
      );
      if (element.isValid) {
        ids.add(id);
        elements.add(element);
      }
    }
    return elements;
  }

  /// Reads the sticky notes of a page, as far as they are usable. A page
  /// written before sticky notes has none. A malformed note is skipped,
  /// a usable one is repaired: an unknown color or paper keeps its stored
  /// id or falls back to lined, a size outside the configured range is
  /// clamped, a taken id is replaced, and unusable strokes are left out.
  static List<StickyNoteElement> _stickyNotesFromJson(
    Object? json, [
    StickyNoteConfig config = const StickyNoteConfig(),
  ]) {
    if (json is! List) {
      return const <StickyNoteElement>[];
    }
    final List<StickyNoteElement> notes = <StickyNoteElement>[];
    final Set<String> ids = <String>{};
    int skipped = 0;
    for (final Object? raw in json) {
      final StickyNoteElement? note = _stickyFromJson(raw, config);
      if (note == null) {
        skipped++;
        continue;
      }
      String id = note.id;
      for (int n = 1; ids.contains(id); n++) {
        id = '${note.id}-$n';
      }
      ids.add(id);
      notes.add(id == note.id ? note : note.copyWith(id: id));
    }
    if (skipped > 0) {
      debugPrint('Note storage: skipped $skipped unusable sticky note(s).');
    }
    return notes;
  }

  static StickyNoteElement? _stickyFromJson(
    Object? json,
    StickyNoteConfig config,
  ) {
    if (json is! Map<String, Object?>) {
      return null;
    }
    double? number(Object? value) =>
        value is num && value.isFinite ? value.toDouble() : null;
    final Object? id = json['id'];
    final Object? center = json['center'];
    final Object? size = json['size'];
    if (id is! String ||
        id.isEmpty ||
        center is! List ||
        center.length != 2 ||
        size is! List ||
        size.length != 2) {
      return null;
    }
    final double? x = number(center[0]);
    final double? y = number(center[1]);
    final double? width = number(size[0]);
    final double? height = number(size[1]);
    final double rotation = number(json['rotation']) ?? 0;
    final double scale = number(json['scale']) ?? 1;
    if (x == null ||
        y == null ||
        width == null ||
        height == null ||
        !(width > 0) ||
        !(height > 0) ||
        !(scale > 0)) {
      return null;
    }
    // Clamped into range, keeping the shape where it can, and the ink's
    // scale with it.
    final double grow = math.max(
      1,
      math.max(config.minSize.width / width, config.minSize.height / height),
    );
    final double shrink = math.min(
      1,
      math.min(config.maxSize.width / width, config.maxSize.height / height),
    );
    final double factor = grow > 1 ? grow : shrink;
    final List<Stroke> strokes = <Stroke>[];
    final Object? rawStrokes = json['strokes'];
    if (rawStrokes is List) {
      for (final Object? raw in rawStrokes) {
        Stroke? stroke;
        try {
          stroke = strokeFromJson(raw);
        } on Object {
          stroke = null;
        }
        if (stroke == null) {
          continue;
        }
        strokes.add(stroke);
      }
    }
    final Object? colorId = json['color'];
    return StickyNoteElement(
      id: id,
      center: InkVector(x, y),
      size: Size(width * factor, height * factor),
      rotation: rotation,
      scale: scale * factor,
      // An unknown color keeps its id, so a newer version's color survives
      // a save here; it is drawn as yellow.
      colorId: colorId is String && colorId.isNotEmpty
          ? colorId
          : StickyPalette.yellow.id,
      paper: StickyPaperStyle.byName(json['paper']),
      strokes: strokes,
      minimized: json['minimized'] == true,
    );
  }

  static Map<String, Object?> _stickyToJson(StickyNoteElement note) =>
      <String, Object?>{
        'id': note.id,
        'center': <double>[note.center.x, note.center.y],
        'size': _sizeJson(note.size),
        'rotation': note.rotation,
        'scale': note.scale,
        'color': note.colorId,
        'paper': note.paper.name,
        'strokes': <Object?>[
          for (final Stroke stroke in note.strokes) strokeToJson(stroke),
        ],
        if (note.minimized) 'minimized': true,
      };

  Map<String, Object?> toJson() => <String, Object?>{
    'playbacks': <Object?>[
      for (final StoredPlayback playback in playbacks) playback.toJson(),
    ],
    'size': setup.size.name,
    'background': setup.background.name,
    'customSize': _sizeJson(setup.customSize),
    'extent': _sizeJson(extent),
    if (isBoard)
      'boardOrigin': <double>[InfiniteBoard.origin.dx, InfiniteBoard.origin.dy],
    'lastFitSize': _sizeJson(lastFitSize),
    'pdfSource': pdfSource == null
        ? null
        : <String, Object?>{
            'assetId': pdfSource!.assetId,
            'pageIndex': pdfSource!.pageIndex,
            'pageSize': _sizeJson(pdfSource!.pageSize),
          },
    'images': <Object?>[
      for (final NoteImageElement image in images)
        <String, Object?>{
          'id': image.id,
          'assetId': image.assetId,
          'pixelSize': _sizeJson(image.pixelSize),
          'center': <double>[image.center.x, image.center.y],
          'size': _sizeJson(image.size),
          'rotation': image.rotation,
          'fileName': image.fileName,
          if (image.vector != null) 'svg': image.vector!.source,
          if (image.aiGenerated) 'aiGenerated': true,
        },
    ],
    'strokes': <Object?>[
      for (final Stroke stroke in strokes) strokeToJson(stroke),
    ],
    if (recognizedWords.isNotEmpty)
      'recognizedWords': <Object?>[
        for (final StoredRecognizedInkWord word in recognizedWords)
          word.toJson(),
      ],
    if (stickyNotes.isNotEmpty)
      'stickyNotes': <Object?>[
        for (final StickyNoteElement note in stickyNotes) _stickyToJson(note),
      ],
    if (textElements.isNotEmpty)
      'textElements': <Object?>[
        for (final NoteTextElement element in textElements)
          <String, Object?>{
            'id': element.id,
            'position': <double>[element.position.x, element.position.y],
            'text': element.text,
            'width': element.width,
            'fontSize': element.settings.fontSize,
            'color': element.settings.ink.id,
            if (element.settings.bold) 'bold': true,
            if (element.settings.italic) 'italic': true,
            if (element.settings.underline) 'underline': true,
            'alignment': element.settings.alignment.name,
            'listStyle': element.settings.listStyle.name,
          },
      ],
    if (pdfMasks.isNotEmpty)
      'pdfMasks': <Object?>[
        for (final Rect mask in pdfMasks)
          <double>[mask.left, mask.top, mask.width, mask.height],
      ],
    if (erasedStrokeRecords.isNotEmpty)
      'erasedStrokes': <Object?>[
        for (final ErasedStrokeRecord record in erasedStrokeRecords)
          <String, Object?>{
            'stroke': strokeToJson(record.stroke),
            'erasedAtMs': record.erasedAtMs,
            'recId': record.recordingId,
          },
      ],
  };

  /// One stroke as stored. Plain pen strokes carry no style field, as before
  /// the other writing styles existed.
  ///
  /// Coordinates go into one typed buffer per stroke, not a boxed number
  /// each: every save writes every stroke of the note, and typed data
  /// crosses to the isolate that encodes a large note as a single copy.
  /// It is written out as the same JSON list.
  static Map<String, Object?> strokeToJson(Stroke stroke) {
    final List<InkVector> points = stroke.points;
    final Float64List flat = Float64List(points.length * 2);
    for (int i = 0; i < points.length; i++) {
      flat[2 * i] = points[i].x;
      flat[2 * i + 1] = points[i].y;
    }
    final List<double>? factors = stroke.widths;
    Float64List? widths;
    if (factors != null) {
      widths = Float64List(factors.length);
      for (int i = 0; i < factors.length; i++) {
        widths[i] = (factors[i] * 1000).roundToDouble() / 1000;
      }
    }
    return <String, Object?>{
      'ink': stroke.style.ink.id,
      'width': stroke.style.width,
      if (stroke.style.writing != WritingStyle.pen)
        'style': stroke.style.writing.name,
      if (stroke.style.isHighlighter) 'opacity': stroke.style.opacity,
      'points': flat,
      'widths': ?widths,
      if (stroke.completedAtMs != null || stroke.recordingId != null)
        'id': stroke.id,
      if (stroke.completedAtMs != null) 'cAt': stroke.completedAtMs,
      if (stroke.recordingId != null) 'recId': stroke.recordingId,
      if (stroke.sampleDeltasMs != null)
        'sampleDeltasMs': stroke.sampleDeltasMs,
    };
  }

  static ErasedStrokeRecord? _erasedStrokeFromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final Stroke? stroke = strokeFromJson(raw['stroke']);
    final Object? erasedAt = raw['erasedAtMs'];
    final Object? recordingId = raw['recId'];
    if (stroke == null ||
        erasedAt is! int ||
        erasedAt < 0 ||
        recordingId is! String ||
        recordingId.isEmpty) {
      return null;
    }
    return ErasedStrokeRecord(
      stroke: stroke,
      erasedAtMs: erasedAt,
      recordingId: recordingId,
    );
  }

  static List<double>? _sizeJson(Size? size) =>
      size == null ? null : <double>[size.width, size.height];

  static Size _size(List<Object?> values) =>
      Size((values[0] as num).toDouble(), (values[1] as num).toDouble());

  static NoteImageElement _imageFromJson(Map<String, Object?> json) {
    final List<Object?> center = json['center']! as List<Object?>;
    final Object? rawSvg = json['svg'];
    final EditableSvg? vector = rawSvg is String
        ? EditableSvg.parse(rawSvg)
        : null;
    return NoteImageElement(
      id: json['id']! as String,
      assetId: json['assetId'] as String? ?? '',
      pixelSize: _size(json['pixelSize']! as List),
      center: InkVector(
        (center[0] as num).toDouble(),
        (center[1] as num).toDouble(),
      ),
      size: _size(json['size']! as List),
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
      fileName: json['fileName'] as String?,
      vector: vector,
      aiGenerated: json['aiGenerated'] == true,
    );
  }

  static Stroke? _strokeFromJson(Map<String, Object?> json) {
    final List<Object?> flat = (json['points'] as List?) ?? const <Object?>[];
    final List<InkVector> points = <InkVector>[
      for (int i = 0; i + 1 < flat.length; i += 2)
        InkVector(
          (flat[i]! as num).toDouble(),
          (flat[i + 1]! as num).toDouble(),
        ),
    ];
    final double width = (json['width'] as num?)?.toDouble() ?? 0;
    if (points.isEmpty ||
        !(width > 0) ||
        points.any((InkVector point) => !point.isFinite)) {
      return null;
    }
    // Width factors that do not match the points, or are not usable, are
    // dropped: the stroke is then drawn at an even width.
    final List<Object?>? rawWidths = json['widths'] as List?;
    List<double>? widths = rawWidths == null
        ? null
        : <double>[
            for (final Object? factor in rawWidths)
              factor is num ? factor.toDouble() : double.nan,
          ];
    if (widths != null &&
        (widths.length != points.length ||
            widths.any((double factor) => !(factor >= 0 && factor.isFinite)))) {
      widths = null;
    }
    // A stroke with no style, or one this version does not know, is a pen
    // stroke; a highlighter keeps its opacity when it is usable.
    final WritingStyle writing = _byName(
      WritingStyle.values,
      json['style'],
      WritingStyle.pen,
    );
    final Object? rawOpacity = json['opacity'];
    final double opacity = writing != WritingStyle.highlighter
        ? 1
        : rawOpacity is num && rawOpacity > 0 && rawOpacity <= 1
        ? rawOpacity.toDouble()
        : StrokeStyle.defaultHighlighterOpacity;
    return Stroke.fromPoints(
      // A highlighter is even along its length.
      widths: writing == WritingStyle.highlighter ? null : widths,
      style: StrokeStyle(
        ink: InkPalette.byId(json['ink'] as String? ?? '') ?? InkPalette.ink,
        width: width,
        writing: writing,
        opacity: opacity,
      ),
      points: points,
      id: json['id'] is String ? json['id']! as String : null,
      completedAtMs: json['cAt'] is int && (json['cAt']! as int) >= 0
          ? json['cAt']! as int
          : null,
      recordingId: json['recId'] is String ? json['recId']! as String : null,
      sampleDeltasMs: json['sampleDeltasMs'] is List
          ? <int>[
              for (final Object? value in json['sampleDeltasMs']! as List)
                if (value is int && value >= 0) value,
            ]
          : null,
    );
  }

  /// [strokeFromJson] for other stored structures, such as sticky notes.
  static Stroke? strokeFromJson(Object? json) {
    return json is Map<String, Object?> ? _strokeFromJson(json) : null;
  }

  static T _byName<T extends Enum>(List<T> values, Object? name, T fallback) {
    for (final T value in values) {
      if (value.name == name) {
        return value;
      }
    }
    return fallback;
  }
}

@immutable
class NoteContent {
  const NoteContent(
    this.pages, {
    this.aiSession,
    this.isImportedPdf = false,
    this.recordings = const <NoteRecordingTrack>[],
  });

  NoteContent.blank([PageSetup setup = const PageSetup()])
    : pages = <StoredPage>[StoredPage(setup: setup, strokes: const <Stroke>[])],
      aiSession = null,
      isImportedPdf = false,
      recordings = const <NoteRecordingTrack>[];

  factory NoteContent.fromJson(Map<String, Object?> json) {
    checkSchema(json);
    final List<StoredPage> pages = <StoredPage>[
      for (final Object? page in (json['pages'] as List?) ?? <Object?>[])
        StoredPage.fromJson(page! as Map<String, Object?>),
    ];
    if (pages.isEmpty) {
      return NoteContent.blank();
    }
    final Object? ai = json['ai'];
    final bool isImportedPdf =
        json['isImportedPdf'] == true ||
        pages.any((StoredPage page) => page.pdfSource != null);
    return NoteContent(
      pages,
      aiSession: ai is Map<String, Object?> ? ai : null,
      isImportedPdf: isImportedPdf,
      recordings: <NoteRecordingTrack>[
        for (final Object? raw
            in (json['recordings'] as List?) ?? const <Object?>[])
          ?NoteRecordingTrack.fromJson(raw),
      ],
    );
  }

  factory NoteContent.fromDocument(NoteDocument document) {
    return NoteContent(
      <StoredPage>[
        for (final NotePage page in document.pages)
          StoredPage(
            setup: page.setup,
            extent: page.extent,
            lastFitSize: page.lastFitSize,
            pdfSource: page.pdfSource,
            images: List<NoteImageElement>.of(page.ink.images),
            strokes: List<Stroke>.of(page.ink.strokes),
            stickyNotes: List<StickyNoteElement>.of(page.ink.stickyNotes),
            textElements: List<NoteTextElement>.of(page.ink.textElements),
            playbacks: _playbacksOf(page.ink),
            recognizedWords: _recognizedWordsOf(page),
            erasedStrokeRecords: List<ErasedStrokeRecord>.of(
              page.ink.erasedStrokeRecords,
            ),
            pdfMasks: List<Rect>.of(page.ink.pdfMasks),
          ),
      ],
      aiSession: document.currentAiSession,
      isImportedPdf: document.isImportedPdf,
      recordings: List<NoteRecordingTrack>.of(document.recordings),
    );
  }

  /// UI-native Paths cannot cross isolates. Materialize large notes here in
  /// short batches, yielding between strokes so a page shell can keep drawing.
  /// No partially hydrated document is exposed to editing or autosave.
  ///
  /// Once [cancelled] says so, the rest is dropped with [LoadAbandoned].
  static Future<NoteContent> fromJsonIncrementally(
    Map<String, Object?> json, {
    bool Function()? cancelled,
  }) async {
    checkSchema(json);
    final pages = <StoredPage>[];
    final slice = Stopwatch()..start();
    for (final rawPage in (json['pages'] as List?) ?? const []) {
      pages.add(
        await StoredPage.fromJsonIncrementally(
          rawPage! as Map<String, Object?>,
          slice: slice,
          cancelled: cancelled,
        ),
      );
    }
    if (pages.isEmpty) return NoteContent.blank();
    final ai = json['ai'];
    final bool isImportedPdf =
        json['isImportedPdf'] == true ||
        pages.any((StoredPage page) => page.pdfSource != null);
    return NoteContent(
      pages,
      aiSession: ai is Map<String, Object?> ? ai : null,
      isImportedPdf: isImportedPdf,
      recordings: <NoteRecordingTrack>[
        for (final Object? raw
            in (json['recordings'] as List?) ?? const <Object?>[])
          ?NoteRecordingTrack.fromJson(raw),
      ],
    );
  }

  final List<StoredPage> pages;

  /// The AI assistant's conversations about this note, as the editor wrote
  /// them. Null when there are none.
  final Map<String, Object?>? aiSession;

  /// Whether this note was imported from a PDF.
  final bool isImportedPdf;

  final List<NoteRecordingTrack> recordings;

  NoteDocument toDocument({InkController Function()? createInk}) {
    final InkController Function() create = createInk ?? InkController.new;
    return NoteDocument(
      createInk: create,
      recordings: recordings,
      isImportedPdf:
          isImportedPdf || pages.any((StoredPage p) => p.pdfSource != null),
      pages: <NotePage>[
        for (final StoredPage page in pages)
          NotePage(
            ink: _inkWith(create, page),
            setup: page.setup,
            extent: page.extent,
            lastFitSize: page.lastFitSize,
            pdfSource: page.pdfSource,
            recognizedWords: _restoreRecognizedWords(page),
          ),
      ],
    )..aiSession = aiSession;
  }

  /// The strokes each of [ink]'s playbacks still draws, by their place on
  /// the page.
  static List<StoredPlayback> _playbacksOf(InkController ink) {
    if (ink.notationPlaybacks.isEmpty) {
      return const <StoredPlayback>[];
    }
    final Map<Stroke, int> indices = Map<Stroke, int>.identity();
    for (int i = 0; i < ink.strokes.length; i++) {
      indices[ink.strokes[i]] = i;
    }
    return <StoredPlayback>[
      for (final NotationPlayback playback in ink.notationPlaybacks)
        if (_storedPlayback(playback, indices) case final StoredPlayback kept)
          kept,
    ];
  }

  static List<StoredRecognizedInkWord> _recognizedWordsOf(NotePage page) {
    if (page.recognizedWords.isEmpty) {
      return const <StoredRecognizedInkWord>[];
    }
    Map<Stroke, int>? indicesFor(RecognizedInkWord word) {
      final List<Stroke> strokes;
      if (word.stickyId == null) {
        strokes = page.ink.strokes;
      } else {
        final StickyNoteElement? sticky = page.ink.stickyNotes
            .where((StickyNoteElement note) => note.id == word.stickyId)
            .firstOrNull;
        if (sticky == null) return null;
        strokes = sticky.strokes;
      }
      return Map<Stroke, int>.identity()..addEntries(<MapEntry<Stroke, int>>[
        for (int i = 0; i < strokes.length; i++) MapEntry(strokes[i], i),
      ]);
    }

    return <StoredRecognizedInkWord>[
      for (final RecognizedInkWord word in page.recognizedWords)
        if (indicesFor(word) case final Map<Stroke, int> indices)
          if (word.sourceStrokes.every(indices.containsKey))
            StoredRecognizedInkWord(
              text: word.text,
              confidence: word.confidence,
              alternatives: word.alternatives,
              strokeIndices: <int>[
                for (final Stroke stroke in word.sourceStrokes)
                  indices[stroke]!,
              ],
              normalizedStrokes: word.normalizedStrokes,
              aspectRatio: word.aspectRatio,
              stickyId: word.stickyId,
            ),
    ];
  }

  static List<RecognizedInkWord> _restoreRecognizedWords(StoredPage page) =>
      <RecognizedInkWord>[
        for (final StoredRecognizedInkWord word in page.recognizedWords)
          RecognizedInkWord(
            text: word.text,
            confidence: word.confidence,
            alternatives: word.alternatives,
            sourceStrokes: <Stroke>[
              for (final int index in word.strokeIndices)
                (word.stickyId == null
                    ? page.strokes
                    : page.stickyNotes
                          .firstWhere(
                            (StickyNoteElement note) =>
                                note.id == word.stickyId,
                          )
                          .strokes)[index],
            ],
            normalizedStrokes: word.normalizedStrokes,
            aspectRatio: word.aspectRatio,
            stickyId: word.stickyId,
          ),
      ];

  static StoredPlayback? _storedPlayback(
    NotationPlayback playback,
    Map<Stroke, int> indices,
  ) {
    final List<int> strokeIndices = <int>[];
    final List<List<double>> times = <List<double>>[];
    for (int i = 0; i < playback.strokes.length; i++) {
      final Stroke stroke = playback.strokes[i];
      final int? index = indices[stroke];
      if (index != null && playback.owns(stroke)) {
        strokeIndices.add(index);
        times.add(List<double>.of(playback.timesAt(i)));
      }
    }
    return strokeIndices.isEmpty
        ? null
        : StoredPlayback(
            strokeIndices: strokeIndices,
            timesMs: times,
            duration: playback.duration,
            surfaceSize: playback.surfaceSize,
          );
  }

  static InkController _inkWith(
    InkController Function() create,
    StoredPage page,
  ) {
    final InkController blank = create();
    if (page.strokes.isEmpty &&
        page.images.isEmpty &&
        page.stickyNotes.isEmpty &&
        page.textElements.isEmpty &&
        page.pdfMasks.isEmpty) {
      return blank;
    }
    final InkController filled = InkController(
      smoothing: blank.smoothing,
      selectionConfig: blank.selectionConfig,
      stickyConfig: blank.stickyConfig,
      strokes: page.strokes,
      images: page.images,
      stickyNotes: page.stickyNotes,
      textElements: page.textElements,
      erasedStrokeRecords: page.erasedStrokeRecords,
      pdfMasks: page.pdfMasks,
    );
    blank.dispose();
    for (final StoredPlayback playback in page.playbacks) {
      if (playback.strokeIndices.any(
        (int i) => i < 0 || i >= page.strokes.length,
      )) {
        continue;
      }
      filled.restoreNotationPlayback(
        strokes: <Stroke>[
          for (final int i in playback.strokeIndices) filled.strokes[i],
        ],
        timesMs: playback.timesMs,
        duration: playback.duration,
        surfaceSize: playback.surfaceSize,
      );
    }
    return filled;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': storageSchema,
    if (isImportedPdf) 'isImportedPdf': true,
    'pages': <Object?>[for (final StoredPage page in pages) page.toJson()],
    if (recordings.isNotEmpty)
      'recordings': <Object?>[
        for (final NoteRecordingTrack recording in recordings)
          recording.toJson(),
      ],
    'ai': ?aiSession,
  };

  /// Text recognized from ink, used by the library index without loading
  /// stroke geometry during every search.
  String get searchableText => <String>[
    for (final StoredPage page in pages) ...<String>[
      for (final StoredRecognizedInkWord word in page.recognizedWords)
        if (word.confidence != null &&
            word.confidence! >= searchableHandwritingConfidence)
          word.text,
      for (final NoteTextElement element in page.textElements) element.text,
    ],
  ].join(' ');
}
