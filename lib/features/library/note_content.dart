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

/// Schema 2 adds PDF sources, images, fixed custom sizes, and Fit history.
/// Schema 3 adds AI notation playbacks and the AI assistant's conversations.
const int storageSchema = 3;

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
  });

  factory StoredPage.fromJson(Map<String, Object?> json) {
    final Object? extent = json['extent'];
    final Object? customSize = json['customSize'];
    final Object? fitSize = json['lastFitSize'];
    final Object? pdf = json['pdfSource'];
    final List<Object?> rawStrokes =
        (json['strokes'] as List?) ?? const <Object?>[];
    final List<Stroke> strokes = <Stroke>[
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
      for (final Stroke stroke in strokes)
        <String, Object?>{
          'ink': stroke.style.ink.id,
          'width': stroke.style.width,
          'points': <double>[
            for (final InkVector point in stroke.points) ...<double>[
              point.x,
              point.y,
            ],
          ],
        },
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
    return Stroke.fromPoints(
      style: StrokeStyle(
        ink: InkPalette.byId(json['ink'] as String? ?? '') ?? InkPalette.ink,
        width: width,
      ),
      points: points,
    );
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
          playbacks: _playbacksOf(page.ink),
        ),
    ], aiSession: document.currentAiSession);
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
    if (page.strokes.isEmpty && page.images.isEmpty) {
      return blank;
    }
    final InkController filled = InkController(
      smoothing: blank.smoothing,
      selectionConfig: blank.selectionConfig,
      strokes: page.strokes,
      images: page.images,
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
