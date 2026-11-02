import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../ink/ink_painter.dart';
import '../ink/ink_sample.dart';
import '../ink/ink_selection.dart';
import '../ink/stroke.dart';
import '../document_io/document_models.dart';
import '../sticky/sticky_note.dart';
import '../sticky/sticky_note_painter.dart';
import 'ai_config.dart';

/// Where a [SnapshotBitmap]'s bytes came from in the note, so that they can
/// be read again when a saved conversation is reopened: an image asset, or
/// one page of a PDF asset rendered at [pdfPageSize].
@immutable
class SnapshotBitmapSource {
  const SnapshotBitmapSource(
    this.assetId, {
    this.pdfPageIndex,
    this.pdfPageSize,
  }) : assert((pdfPageIndex == null) == (pdfPageSize == null));

  final String assetId;
  final int? pdfPageIndex;
  final ui.Size? pdfPageSize;

  bool get isPdfPage => pdfPageIndex != null;
}

/// Encoded bitmap content painted under ink in an AI snapshot.
class SnapshotBitmap {
  const SnapshotBitmap({
    required this.bytes,
    required this.bounds,
    this.rotation = 0,
    this.affectsCrop = true,
    this.source,
  });

  /// Where [bytes] came from, when they can be read again.
  final SnapshotBitmapSource? source;

  final Uint8List bytes;
  final ui.Rect bounds;
  final double rotation;

  /// False for a page-wide PDF background, which is clipped to the crop
  /// chosen from selected content rather than expanding it to the page.
  final bool affectsCrop;

  ui.Rect get rotatedBounds {
    if (rotation == 0) return bounds;
    final double c = math.cos(rotation).abs();
    final double s = math.sin(rotation).abs();
    return ui.Rect.fromCenter(
      center: bounds.center,
      width: bounds.width * c + bounds.height * s,
      height: bounds.width * s + bounds.height * c,
    );
  }
}

/// One selected stroke as it looked when the snapshot was taken.
class SnapshotStroke {
  SnapshotStroke({
    required List<InkVector> points,
    required this.width,
    required this.color,
    required this.isDot,
    this.writing = WritingStyle.pen,
    this.widths,
  }) : points = List<InkVector>.unmodifiable(points);

  final List<InkVector> points;
  final double width;

  /// The width factor at each point, or null for an even stroke.
  final List<double>? widths;

  /// Already resolved for the snapshot's brightness.
  final ui.Color color;
  final bool isDot;
  final WritingStyle writing;
}

/// The selected ink, copied out of the document. Immutable: nothing the
/// editor does afterwards, to the ink, the selection, or the theme, reaches
/// it.
class SelectionInkSnapshot {
  SelectionInkSnapshot._({
    required this.strokes,
    required this.bitmaps,
    required this.brightness,
    required this.background,
    required this._source,
    required this._sourceImages,
    this.explicitBounds,
    List<StickyNoteElement> stickies = const <StickyNoteElement>[],
  }) : stickies = List<StickyNoteElement>.unmodifiable(stickies);

  /// Copies [selection]'s strokes, in document order, with their colors
  /// resolved for [brightness]. [background] is the writing surface's color
  /// in that theme, made opaque.
  factory SelectionInkSnapshot.of(
    InkSelection selection, {
    required ui.Brightness brightness,
    required ui.Color background,
    List<SnapshotBitmap> bitmaps = const <SnapshotBitmap>[],
  }) {
    return SelectionInkSnapshot._(
      strokes: List<SnapshotStroke>.unmodifiable(<SnapshotStroke>[
        for (final Stroke stroke in selection.strokes)
          SnapshotStroke(
            points: stroke.points,
            width: stroke.style.width,
            color: stroke.style.resolve(brightness),
            isDot: stroke.isDot,
            writing: stroke.style.writing,
            widths: stroke.widths,
          ),
      ]),
      bitmaps: List<SnapshotBitmap>.unmodifiable(bitmaps),
      brightness: brightness,
      background: background.withValues(alpha: 1),
      source: selection.strokes,
      sourceImages: selection.images,
      explicitBounds: selection.pdfBounds,
      stickies: selection.stickies,
    );
  }

  /// [base] with those of [strokes] it does not already hold drawn over it,
  /// in [base]'s theme, so the image keeps one look. Null when [strokes]
  /// add nothing.
  ///
  /// The pictures, notes, and paper chosen along with them are taken in too,
  /// each with the [bitmaps] it is drawn over.
  static SelectionInkSnapshot? merged(
    SelectionInkSnapshot base,
    Iterable<Stroke> strokes, {
    Iterable<NoteImageElement> images = const <NoteImageElement>[],
    Iterable<StickyNoteElement> stickies = const <StickyNoteElement>[],
    ui.Rect? pdfBounds,
    List<SnapshotBitmap> bitmaps = const <SnapshotBitmap>[],
  }) {
    final List<Stroke> added = <Stroke>[
      for (final Stroke stroke in strokes)
        if (!base.contains(stroke)) stroke,
    ];
    final List<NoteImageElement> addedImages = <NoteImageElement>[
      for (final NoteImageElement image in images)
        if (!base._sourceImages.any(
          (NoteImageElement it) => identical(it, image),
        ))
          image,
    ];
    final List<StickyNoteElement> addedStickies = <StickyNoteElement>[
      for (final StickyNoteElement sticky in stickies)
        if (!base.stickies.any((StickyNoteElement it) => identical(it, sticky)))
          sticky,
    ];
    final ui.Rect? paper = pdfBounds == null || pdfBounds == base.explicitBounds
        ? null
        : pdfBounds;
    if (added.isEmpty &&
        addedImages.isEmpty &&
        addedStickies.isEmpty &&
        paper == null) {
      return null;
    }
    // A bitmap already drawn is not drawn twice.
    final List<SnapshotBitmap> addedBitmaps = <SnapshotBitmap>[
      for (final SnapshotBitmap bitmap in bitmaps)
        if (!base.bitmaps.any(
          (SnapshotBitmap it) =>
              it.bounds == bitmap.bounds &&
              it.source?.assetId == bitmap.source?.assetId &&
              it.source?.pdfPageIndex == bitmap.source?.pdfPageIndex,
        ))
          bitmap,
    ];
    return SelectionInkSnapshot._(
      strokes: List<SnapshotStroke>.unmodifiable(<SnapshotStroke>[
        ...base.strokes,
        for (final Stroke stroke in added)
          SnapshotStroke(
            points: stroke.points,
            width: stroke.style.width,
            color: stroke.style.resolve(base.brightness),
            isDot: stroke.isDot,
            writing: stroke.style.writing,
            widths: stroke.widths,
          ),
      ]),
      bitmaps: List<SnapshotBitmap>.unmodifiable(<SnapshotBitmap>[
        ...base.bitmaps,
        ...addedBitmaps,
      ]),
      brightness: base.brightness,
      background: base.background,
      source: List<Stroke>.unmodifiable(<Stroke>[...base._source, ...added]),
      sourceImages: List<NoteImageElement>.unmodifiable(<NoteImageElement>[
        ...base._sourceImages,
        ...addedImages,
      ]),
      explicitBounds: paper == null
          ? base.explicitBounds
          : base.explicitBounds?.expandToInclude(paper) ?? paper,
      stickies: <StickyNoteElement>[...base.stickies, ...addedStickies],
    );
  }

  /// This snapshot narrowed to the chosen source objects that remain after
  /// one or more context groups are removed. The copied stroke geometry stays
  /// paired with its original stroke, and raster assets that belonged only to
  /// removed images are left out of the next model image.
  SelectionInkSnapshot retaining({
    required Iterable<Stroke> sourceStrokes,
    required Iterable<NoteImageElement> sourceImages,
    required Iterable<StickyNoteElement> stickies,
    ui.Rect? explicitBounds,
  }) {
    final Set<Stroke> keptStrokes = Set<Stroke>.identity()
      ..addAll(sourceStrokes);
    final Set<NoteImageElement> keptImages = Set<NoteImageElement>.identity()
      ..addAll(sourceImages);
    final Set<StickyNoteElement> keptStickies =
        Set<StickyNoteElement>.identity()..addAll(stickies);
    final Set<String> removedImageAssets = <String>{
      for (final NoteImageElement image in _sourceImages)
        if (!keptImages.contains(image)) image.assetId,
    };
    final Set<String> keptImageAssets = <String>{
      for (final NoteImageElement image in _sourceImages)
        if (keptImages.contains(image)) image.assetId,
    };
    final List<SnapshotStroke> keptSnapshots = <SnapshotStroke>[];
    final List<Stroke> keptSources = <Stroke>[];
    for (int i = 0; i < _source.length && i < strokes.length; i++) {
      final Stroke source = _source[i];
      if (keptStrokes.contains(source)) {
        keptSources.add(source);
        keptSnapshots.add(strokes[i]);
      }
    }
    return SelectionInkSnapshot._(
      strokes: List<SnapshotStroke>.unmodifiable(keptSnapshots),
      bitmaps: List<SnapshotBitmap>.unmodifiable(<SnapshotBitmap>[
        for (final SnapshotBitmap bitmap in bitmaps)
          if (bitmap.source == null ||
              bitmap.source!.pdfPageIndex != null ||
              !removedImageAssets.contains(bitmap.source!.assetId) ||
              keptImageAssets.contains(bitmap.source!.assetId))
            bitmap,
      ]),
      brightness: brightness,
      background: background,
      source: List<Stroke>.unmodifiable(keptSources),
      sourceImages: List<NoteImageElement>.unmodifiable(<NoteImageElement>[
        for (final NoteImageElement image in _sourceImages)
          if (keptImages.contains(image)) image,
      ]),
      explicitBounds: explicitBounds,
      stickies: <StickyNoteElement>[
        for (final StickyNoteElement sticky in this.stickies)
          if (keptStickies.contains(sticky)) sticky,
      ],
    );
  }

  /// A snapshot saved with the note, read back: [sourceStrokes] and
  /// [sourceImages] are the note's ink it was taken from, as far as it is
  /// still there.
  factory SelectionInkSnapshot.restored({
    required List<SnapshotStroke> strokes,
    required ui.Brightness brightness,
    required ui.Color background,
    List<SnapshotBitmap> bitmaps = const <SnapshotBitmap>[],
    List<Stroke> sourceStrokes = const <Stroke>[],
    List<NoteImageElement> sourceImages = const <NoteImageElement>[],
    ui.Rect? explicitBounds,
  }) {
    return SelectionInkSnapshot._(
      strokes: List<SnapshotStroke>.unmodifiable(strokes),
      bitmaps: List<SnapshotBitmap>.unmodifiable(bitmaps),
      brightness: brightness,
      background: background.withValues(alpha: 1),
      source: List<Stroke>.unmodifiable(sourceStrokes),
      sourceImages: List<NoteImageElement>.unmodifiable(sourceImages),
      explicitBounds: explicitBounds,
    );
  }

  /// This snapshot over [bitmaps] instead of its own.
  SelectionInkSnapshot withBitmaps(List<SnapshotBitmap> bitmaps) {
    return SelectionInkSnapshot._(
      strokes: strokes,
      bitmaps: List<SnapshotBitmap>.unmodifiable(bitmaps),
      brightness: brightness,
      background: background,
      source: _source,
      sourceImages: _sourceImages,
      explicitBounds: explicitBounds,
      stickies: stickies,
    );
  }

  /// This snapshot with [ink] drawn over its strokes in its own theme: ink
  /// that has appeared where it lies since it was taken. What it was taken
  /// from stays as it was, so [ink] never counts as chosen.
  SelectionInkSnapshot withInkOver(Iterable<Stroke> ink) {
    return SelectionInkSnapshot._(
      strokes: List<SnapshotStroke>.unmodifiable(<SnapshotStroke>[
        ...strokes,
        for (final Stroke stroke in ink)
          SnapshotStroke(
            points: stroke.points,
            width: stroke.style.width,
            color: stroke.style.resolve(brightness),
            isDot: stroke.isDot,
            writing: stroke.style.writing,
            widths: stroke.widths,
          ),
      ]),
      bitmaps: bitmaps,
      brightness: brightness,
      background: background,
      source: _source,
      sourceImages: _sourceImages,
      explicitBounds: explicitBounds,
      stickies: stickies,
    );
  }

  /// For tests and tools: a snapshot of [strokes] as given.
  @visibleForTesting
  factory SelectionInkSnapshot.fromStrokes(
    List<SnapshotStroke> strokes, {
    ui.Brightness brightness = ui.Brightness.light,
    ui.Color background = const ui.Color(0xFFFFFFFF),
    List<SnapshotBitmap> bitmaps = const <SnapshotBitmap>[],
    ui.Rect? explicitBounds,
  }) {
    return SelectionInkSnapshot._(
      strokes: List<SnapshotStroke>.unmodifiable(strokes),
      bitmaps: List<SnapshotBitmap>.unmodifiable(bitmaps),
      brightness: brightness,
      background: background.withValues(alpha: 1),
      source: const <Stroke>[],
      sourceImages: const <NoteImageElement>[],
      explicitBounds: explicitBounds,
    );
  }

  /// In document order, which is paint order.
  final List<SnapshotStroke> strokes;
  final List<SnapshotBitmap> bitmaps;

  /// Selected sticky notes, each with its own ink, drawn above [strokes].
  /// Immutable, so they are shared with the document. Not saved with a
  /// conversation: a restored snapshot has none.
  final List<StickyNoteElement> stickies;

  /// An area chosen independently of ink or placed images, such as a
  /// lassoed excerpt of immutable PDF paper.
  final ui.Rect? explicitBounds;

  /// The theme the colors were resolved for.
  final ui.Brightness brightness;

  /// Opaque fill behind the ink.
  final ui.Color background;

  /// The finished strokes this was taken from, kept only to recognise the
  /// same selection again. Finished strokes never change.
  final List<Stroke> _source;
  final List<NoteImageElement> _sourceImages;

  /// Whether [selection] is the very ink this snapshot was taken from.
  bool isOf(InkSelection selection) {
    if (selection.strokes.length != _source.length ||
        selection.images.length != _sourceImages.length ||
        selection.stickies.length != stickies.length ||
        selection.pdfBounds != explicitBounds) {
      return false;
    }
    for (int i = 0; i < _source.length; i++) {
      if (!identical(selection.strokes[i], _source[i])) {
        return false;
      }
    }
    for (int i = 0; i < _sourceImages.length; i++) {
      if (!identical(selection.images[i], _sourceImages[i])) {
        return false;
      }
    }
    for (int i = 0; i < stickies.length; i++) {
      if (!identical(selection.stickies[i], stickies[i])) {
        return false;
      }
    }
    return _source.isNotEmpty ||
        _sourceImages.isNotEmpty ||
        stickies.isNotEmpty ||
        explicitBounds != null;
  }

  /// How many of this snapshot's original strokes are in [selection].
  ///
  /// Finished strokes are immutable, so object identity is the stable link
  /// between selecting ink, clearing the lasso, and selecting that ink again.
  int sharedStrokeCount(InkSelection selection) {
    int shared = 0;
    for (final Stroke selected in selection.strokes) {
      if (contains(selected)) {
        shared++;
      }
    }
    return shared;
  }

  int sharedImageCount(InkSelection selection) {
    int shared = 0;
    for (final NoteImageElement selected in selection.images) {
      if (_sourceImages.any((source) => identical(source, selected))) shared++;
    }
    return shared;
  }

  int sharedPdfCount(InkSelection selection) {
    return explicitBounds != null && selection.pdfBounds == explicitBounds
        ? 1
        : 0;
  }

  /// Whether [stroke] is one of the strokes this was taken from.
  bool contains(Stroke stroke) {
    return _source.any((Stroke source) => identical(source, stroke));
  }

  /// The note's strokes and images this was taken from.
  List<Stroke> get sourceStrokes => _source;
  List<NoteImageElement> get sourceImages => _sourceImages;

  /// The number of strokes originally captured for this snapshot.
  int get sourceStrokeCount => _source.length;
  int get sourceImageCount => _sourceImages.length;
  int get sourceContentCount =>
      sourceStrokeCount +
      sourceImageCount +
      stickies.length +
      (explicitBounds == null ? 0 : 1);
}

/// The selection as a PNG, with the numbers it was made from.
class SelectionImage {
  SelectionImage({
    required this.png,
    required this.width,
    required this.height,
    required this.scale,
    required this.logicalBounds,
  });

  final Uint8List png;

  /// Physical pixels.
  final int width;
  final int height;

  /// Physical pixels per logical pixel.
  final double scale;

  /// The cropped region of the page: the ink's bounds plus the padding.
  final ui.Rect logicalBounds;
}

enum SelectionImageFailure {
  /// Nothing to draw.
  empty,

  /// A coordinate or width that is not a finite number, or no width at all.
  invalidGeometry,

  /// Too big to shrink into the size limit and stay legible.
  tooLarge,

  /// The platform could not encode the image.
  encodingFailed,
}

/// Why a selection could not be turned into an image.
class SelectionImageException implements Exception {
  const SelectionImageException(this.failure);

  final SelectionImageFailure failure;

  /// What the user is told.
  String get message {
    return switch (failure) {
      SelectionImageFailure.empty => 'There is no selected ink to send.',
      SelectionImageFailure.invalidGeometry =>
        'The selected ink could not be turned into an image.',
      SelectionImageFailure.tooLarge =>
        'The selection is too large to send. Select a smaller area.',
      SelectionImageFailure.encodingFailed =>
        'The selected ink could not be turned into an image.',
    };
  }

  @override
  String toString() => 'SelectionImageException(${failure.name})';
}

/// Where and how big the image of a snapshot is. Worked out before anything
/// is allocated.
class SelectionImageLayout {
  const SelectionImageLayout({
    required this.logicalBounds,
    required this.scale,
    required this.width,
    required this.height,
  });

  final ui.Rect logicalBounds;
  final double scale;
  final int width;
  final int height;
}

/// Draws a [SelectionInkSnapshot] to PNG bytes, off screen.
///
/// The crop is the union of the strokes' rendered bounds, grown by
/// [AiImageConfig.padding]. It is drawn at [AiImageConfig.pixelRatio], or
/// less when that would make a side longer than
/// [AiImageConfig.maxDimension]. Only the snapshot's strokes are drawn, in
/// order, over its opaque background, through the editor's own stroke
/// painting. The bytes are returned and kept nowhere else.
class SelectionImageRenderer {
  const SelectionImageRenderer({
    this.config = const AiImageConfig(),
    this.debugOnImage,
  });

  final AiImageConfig config;

  /// Told about each native image as it is made, so a test can check that
  /// it was released.
  @visibleForTesting
  final ValueChanged<ui.Image>? debugOnImage;

  /// The crop and pixel size for [snapshot]. Throws a
  /// [SelectionImageException] for geometry that cannot be drawn.
  SelectionImageLayout layout(SelectionInkSnapshot snapshot) {
    if (snapshot.strokes.isEmpty &&
        snapshot.stickies.isEmpty &&
        !snapshot.bitmaps.any((bitmap) => bitmap.affectsCrop) &&
        snapshot.explicitBounds == null) {
      throw const SelectionImageException(SelectionImageFailure.empty);
    }
    double left = double.infinity;
    double top = double.infinity;
    double right = double.negativeInfinity;
    double bottom = double.negativeInfinity;
    final ui.Rect? explicitBounds = snapshot.explicitBounds;
    if (explicitBounds != null) {
      if (!explicitBounds.isFinite || explicitBounds.isEmpty) {
        throw const SelectionImageException(
          SelectionImageFailure.invalidGeometry,
        );
      }
      left = explicitBounds.left;
      top = explicitBounds.top;
      right = explicitBounds.right;
      bottom = explicitBounds.bottom;
    }
    for (final SnapshotStroke stroke in snapshot.strokes) {
      if (stroke.points.isEmpty) {
        throw const SelectionImageException(SelectionImageFailure.empty);
      }
      if (!stroke.width.isFinite || stroke.width <= 0) {
        throw const SelectionImageException(
          SelectionImageFailure.invalidGeometry,
        );
      }
      final double half = stroke.width / 2;
      for (final InkVector point in stroke.points) {
        if (!point.isFinite) {
          throw const SelectionImageException(
            SelectionImageFailure.invalidGeometry,
          );
        }
        left = math.min(left, point.x - half);
        top = math.min(top, point.y - half);
        right = math.max(right, point.x + half);
        bottom = math.max(bottom, point.y + half);
      }
    }
    for (final StickyNoteElement note in snapshot.stickies) {
      if (!note.isValid) {
        throw const SelectionImageException(
          SelectionImageFailure.invalidGeometry,
        );
      }
      final ui.Rect bounds = note.bounds;
      left = math.min(left, bounds.left);
      top = math.min(top, bounds.top);
      right = math.max(right, bounds.right);
      bottom = math.max(bottom, bounds.bottom);
    }
    for (final SnapshotBitmap bitmap in snapshot.bitmaps) {
      if (!bitmap.bounds.isFinite ||
          bitmap.bounds.isEmpty ||
          !bitmap.rotation.isFinite ||
          bitmap.bytes.isEmpty) {
        throw const SelectionImageException(
          SelectionImageFailure.invalidGeometry,
        );
      }
      if (bitmap.affectsCrop) {
        final ui.Rect bounds = bitmap.rotatedBounds;
        left = math.min(left, bounds.left);
        top = math.min(top, bounds.top);
        right = math.max(right, bounds.right);
        bottom = math.max(bottom, bounds.bottom);
      }
    }
    final ui.Rect bounds = ui.Rect.fromLTRB(
      left - config.padding,
      top - config.padding,
      right + config.padding,
      bottom + config.padding,
    );
    if (!bounds.isFinite || bounds.width <= 0 || bounds.height <= 0) {
      throw const SelectionImageException(
        SelectionImageFailure.invalidGeometry,
      );
    }
    final double scale = math.min(
      config.pixelRatio,
      config.maxDimension / math.max(bounds.width, bounds.height),
    );
    if (!scale.isFinite || scale <= 0) {
      throw const SelectionImageException(
        SelectionImageFailure.invalidGeometry,
      );
    }
    return SelectionImageLayout(
      logicalBounds: bounds,
      scale: scale,
      width: _pixels(bounds.width * scale),
      height: _pixels(bounds.height * scale),
    );
  }

  int _pixels(double length) {
    return length.ceil().clamp(1, config.maxDimension);
  }

  /// Draws [snapshot]. Throws a [SelectionImageException] when it cannot be
  /// drawn.
  Future<SelectionImage> render(SelectionInkSnapshot snapshot) async {
    SelectionImageLayout layout = this.layout(snapshot);
    final List<ui.Image> decoded = <ui.Image>[];
    try {
      for (final SnapshotBitmap bitmap in snapshot.bitmaps) {
        decoded.add(await _decodeImage(bitmap.bytes));
      }
      while (true) {
        final SelectionImage image = await _renderDecoded(
          snapshot,
          layout,
          decoded,
        );
        if (image.png.lengthInBytes <= config.maxPngBytes) {
          return image;
        }
        // Leave images already under the transport target byte-for-byte
        // alone. Oversized PNGs are reduced a little at a time until they
        // fit; even an enormous logical selection is still sendable.
        final double scale = layout.scale * 0.9;
        final ui.Rect bounds = layout.logicalBounds;
        final int width = _pixels(bounds.width * scale);
        final int height = _pixels(bounds.height * scale);
        if (width == layout.width && height == layout.height) {
          return image;
        }
        layout = SelectionImageLayout(
          logicalBounds: bounds,
          scale: scale,
          width: width,
          height: height,
        );
      }
    } on SelectionImageException {
      rethrow;
    } on Object {
      throw const SelectionImageException(SelectionImageFailure.encodingFailed);
    } finally {
      for (final ui.Image image in decoded) {
        image.dispose();
      }
    }
  }

  Future<SelectionImage> _renderDecoded(
    SelectionInkSnapshot snapshot,
    SelectionImageLayout layout,
    List<ui.Image> decoded,
  ) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);
    final ui.Rect bounds = layout.logicalBounds;
    canvas
      ..drawRect(
        ui.Rect.fromLTWH(
          0,
          0,
          layout.width.toDouble(),
          layout.height.toDouble(),
        ),
        ui.Paint()..color = snapshot.background,
      )
      ..scale(layout.scale)
      ..translate(-bounds.left, -bounds.top);
    for (int i = 0; i < snapshot.bitmaps.length; i++) {
      final SnapshotBitmap bitmap = snapshot.bitmaps[i];
      final ui.Image image = decoded[i];
      canvas.save();
      canvas
        ..translate(bitmap.bounds.center.dx, bitmap.bounds.center.dy)
        ..rotate(bitmap.rotation)
        ..drawImageRect(
          image,
          ui.Rect.fromLTWH(
            0,
            0,
            image.width.toDouble(),
            image.height.toDouble(),
          ),
          ui.Rect.fromCenter(
            center: ui.Offset.zero,
            width: bitmap.bounds.width,
            height: bitmap.bounds.height,
          ),
          ui.Paint()..filterQuality = ui.FilterQuality.high,
        );
      canvas.restore();
    }
    for (final SnapshotStroke stroke in snapshot.strokes) {
      final InkVector origin = stroke.points.first;
      final ui.Path path = ui.Path()..moveTo(origin.x, origin.y);
      for (int i = 1; i < stroke.points.length; i++) {
        path.lineTo(stroke.points[i].x, stroke.points[i].y);
      }
      paintInkStroke(
        canvas,
        color: stroke.color,
        width: stroke.width,
        path: path,
        origin: origin,
        isDot: stroke.isDot,
        writing: stroke.writing,
        outline: stroke.widths == null
            ? null
            : buildInkOutline(stroke.points, stroke.widths!, stroke.width),
      );
    }
    // Sticky notes above page strokes.
    for (final StickyNoteElement note in snapshot.stickies) {
      paintStickyNote(canvas, note);
    }
    final ui.Picture picture = recorder.endRecording();
    ui.Image? image;
    try {
      image = await picture.toImage(layout.width, layout.height);
      debugOnImage?.call(image);
      final ByteData? bytes = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (bytes == null || bytes.lengthInBytes == 0) {
        throw const SelectionImageException(
          SelectionImageFailure.encodingFailed,
        );
      }
      return SelectionImage(
        png: bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        width: layout.width,
        height: layout.height,
        scale: layout.scale,
        logicalBounds: bounds,
      );
    } on SelectionImageException {
      rethrow;
    } on Object {
      throw const SelectionImageException(SelectionImageFailure.encodingFailed);
    } finally {
      image?.dispose();
      picture.dispose();
    }
  }

  Future<ui.Image> _decodeImage(Uint8List bytes) async {
    final ui.Codec codec = await ui.instantiateImageCodec(bytes);
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }
}
