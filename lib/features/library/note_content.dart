import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../editor/document_io/document_models.dart';
import '../editor/ink/ink_controller.dart';
import '../editor/ink/ink_palette.dart';
import '../editor/ink/ink_sample.dart';
import '../editor/ink/notation_playback.dart';
import '../editor/ink/stroke.dart';
import '../editor/page/note_document.dart';
import '../editor/page/page_setup.dart';
import '../editor/sticky/sticky_note.dart';

/// Schema 2 adds PDF sources, images, fixed custom sizes, and Fit history.
/// Schema 3 adds AI notation playbacks and the AI assistant's conversations.
/// Schema 4 adds sticky notes per page, and highlighter strokes (a `style`
/// and `opacity` on a stroke; without them a stroke is a pen stroke).
const int storageSchema = 4;

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
      'Written by a newer version of Greatnote (schema $schema).',
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
  });

  factory StoredPage.fromJson(Map<String, Object?> json) {
    return StoredPage._fromJson(json);
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
    return StoredPage(
      setup: PageSetup(
        size: _byName(PageSize.values, json['size'], PageSize.fit),
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
      stickyNotes: _stickyNotesFromJson(json['stickyNotes']),
      // Unusable strokes are left out, which moves the indices of those
      // after them; playbacks are only kept when none was.
      playbacks: strokes.length == rawStrokes.length
          ? <StoredPlayback>[
              for (final Object? playback
                  in (json['playbacks'] as List?) ?? <Object?>[])
                ?StoredPlayback.fromJson(playback),
            ]
          : const <StoredPlayback>[],
    );
  }

  final PageSetup setup;
  final Size? extent;
  final Size? lastFitSize;
  final PdfPageSource? pdfSource;
  final List<NoteImageElement> images;
  final List<Stroke> strokes;
  final List<StoredPlayback> playbacks;

  /// In paint order, each with its ink in its own coordinates.
  final List<StickyNoteElement> stickyNotes;

  /// Reads the sticky notes of a page, as far as they are usable. A page
  /// written before sticky notes has none. A malformed note is skipped,
  /// a usable one is repaired: an unknown color or paper keeps its stored
  /// id or falls back to lined, a size outside the configured range is
  /// clamped, a taken id is replaced, and unusable strokes are left out.
  /// Counts beyond the configured limits are not read.
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
      if (notes.length >= config.maxStickyNotesPerPage) {
        skipped++;
        continue;
      }
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
    int points = 0;
    final Object? rawStrokes = json['strokes'];
    if (rawStrokes is List) {
      for (final Object? raw in rawStrokes) {
        if (strokes.length >= config.maxStrokesPerNote) {
          break;
        }
        Stroke? stroke;
        try {
          stroke = strokeFromJson(raw);
        } on Object {
          stroke = null;
        }
        if (stroke == null) {
          continue;
        }
        points += stroke.points.length;
        if (points > config.maxPointsPerNote) {
          break;
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
      };

  Map<String, Object?> toJson() => <String, Object?>{
    'playbacks': <Object?>[
      for (final StoredPlayback playback in playbacks) playback.toJson(),
    ],
    'size': setup.size.name,
    'background': setup.background.name,
    'customSize': _sizeJson(setup.customSize),
    'extent': _sizeJson(extent),
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
        },
    ],
    'strokes': <Object?>[
      for (final Stroke stroke in strokes) strokeToJson(stroke),
    ],
    if (stickyNotes.isNotEmpty)
      'stickyNotes': <Object?>[
        for (final StickyNoteElement note in stickyNotes) _stickyToJson(note),
      ],
  };

  /// One stroke as stored. Pen strokes carry no style field, as before
  /// highlighters existed.
  static Map<String, Object?> strokeToJson(Stroke stroke) => <String, Object?>{
    'ink': stroke.style.ink.id,
    'width': stroke.style.width,
    if (stroke.style.isHighlighter) ...<String, Object?>{
      'style': stroke.style.writing.name,
      'opacity': stroke.style.opacity,
    },
    'points': <double>[
      for (final InkVector point in stroke.points) ...<double>[
        point.x,
        point.y,
      ],
    ],
    if (stroke.widths != null)
      'widths': <double>[
        for (final double factor in stroke.widths!)
          (factor * 1000).roundToDouble() / 1000,
      ],
  };

  static List<double>? _sizeJson(Size? size) =>
      size == null ? null : <double>[size.width, size.height];

  static Size _size(List<Object?> values) =>
      Size((values[0] as num).toDouble(), (values[1] as num).toDouble());

  static NoteImageElement _imageFromJson(Map<String, Object?> json) {
    final List<Object?> center = json['center']! as List<Object?>;
    return NoteImageElement(
      id: json['id']! as String,
      assetId: json['assetId']! as String,
      pixelSize: _size(json['pixelSize']! as List),
      center: InkVector(
        (center[0] as num).toDouble(),
        (center[1] as num).toDouble(),
      ),
      size: _size(json['size']! as List),
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
      fileName: json['fileName'] as String?,
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
    final double opacity = writing == WritingStyle.pen
        ? 1
        : rawOpacity is num && rawOpacity > 0 && rawOpacity <= 1
        ? rawOpacity.toDouble()
        : StrokeStyle.defaultHighlighterOpacity;
    return Stroke.fromPoints(
      // A highlighter is even along its length.
      widths: writing == WritingStyle.pen ? widths : null,
      style: StrokeStyle(
        ink: InkPalette.byId(json['ink'] as String? ?? '') ?? InkPalette.ink,
        width: width,
        writing: writing,
        opacity: opacity,
      ),
      points: points,
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
  const NoteContent(this.pages, {this.aiSession});

  NoteContent.blank([PageSetup setup = const PageSetup()])
    : pages = <StoredPage>[StoredPage(setup: setup, strokes: const <Stroke>[])],
      aiSession = null;

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
    return NoteContent(
      pages,
      aiSession: ai is Map<String, Object?> ? ai : null,
    );
  }

  factory NoteContent.fromDocument(NoteDocument document) {
    return NoteContent(<StoredPage>[
      for (final NotePage page in document.pages)
        StoredPage(
          setup: page.setup,
          extent: page.extent,
          lastFitSize: page.lastFitSize,
          pdfSource: page.pdfSource,
          images: List<NoteImageElement>.of(page.ink.images),
          strokes: List<Stroke>.of(page.ink.strokes),
          stickyNotes: List<StickyNoteElement>.of(page.ink.stickyNotes),
          playbacks: _playbacksOf(page.ink),
        ),
    ], aiSession: document.currentAiSession);
  }

  /// UI-native Paths cannot cross isolates. Materialize large notes here in
  /// short batches, yielding between strokes so a page shell can keep drawing.
  /// No partially hydrated document is exposed to editing or autosave.
  static Future<NoteContent> fromJsonIncrementally(
    Map<String, Object?> json,
  ) async {
    checkSchema(json);
    final pages = <StoredPage>[];
    final slice = Stopwatch()..start();
    for (final rawPage in (json['pages'] as List?) ?? const []) {
      final page = rawPage! as Map<String, Object?>;
      final strokes = <Stroke>[];
      for (final rawStroke in (page['strokes'] as List?) ?? const []) {
        final stroke = StoredPage._strokeFromJson(
          rawStroke! as Map<String, Object?>,
        );
        if (stroke != null) strokes.add(stroke);
        if (slice.elapsedMicroseconds >= 4000) {
          await Future<void>.delayed(Duration.zero);
          slice.reset();
        }
      }
      pages.add(StoredPage._fromJson(page, decodedStrokes: strokes));
    }
    if (pages.isEmpty) return NoteContent.blank();
    final ai = json['ai'];
    return NoteContent(
      pages,
      aiSession: ai is Map<String, Object?> ? ai : null,
    );
  }

  final List<StoredPage> pages;

  /// The AI assistant's conversations about this note, as the editor wrote
  /// them. Null when there are none.
  final Map<String, Object?>? aiSession;

  NoteDocument toDocument({InkController Function()? createInk}) {
    final InkController Function() create = createInk ?? InkController.new;
    return NoteDocument(
      createInk: create,
      pages: <NotePage>[
        for (final StoredPage page in pages)
          NotePage(
            ink: _inkWith(create, page),
            setup: page.setup,
            extent: page.extent,
            lastFitSize: page.lastFitSize,
            pdfSource: page.pdfSource,
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
        page.stickyNotes.isEmpty) {
      return blank;
    }
    final InkController filled = InkController(
      smoothing: blank.smoothing,
      selectionConfig: blank.selectionConfig,
      stickyConfig: blank.stickyConfig,
      strokes: page.strokes,
      images: page.images,
      stickyNotes: page.stickyNotes,
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
    'pages': <Object?>[for (final StoredPage page in pages) page.toJson()],
    'ai': ?aiSession,
  };
}
