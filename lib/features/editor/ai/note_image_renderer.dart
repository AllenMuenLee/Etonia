import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../ink/ink_sample.dart';
import '../ink/stroke.dart';
import '../sticky/sticky_note.dart';
import 'ai_config.dart';
import 'ink_attachment.dart';
import 'notation_space.dart';
import 'selection_image_renderer.dart';

/// An immutable copy of the complete writing surface for one AI request.
class NoteInkSnapshot {
  NoteInkSnapshot({
    required List<SnapshotStroke> strokes,
    required this.logicalSize,
    required this.revision,
    required this.brightness,
    required ui.Color background,
    this.bitmaps = const <SnapshotBitmap>[],
    this.focusBounds,
    List<StickyNoteElement> stickies = const <StickyNoteElement>[],
    List<SpaceStroke> aiNotes = const <SpaceStroke>[],
  }) : strokes = List<SnapshotStroke>.unmodifiable(strokes),
       aiNotes = List<SpaceStroke>.unmodifiable(aiNotes),
       stickies = List<StickyNoteElement>.unmodifiable(stickies),
       background = background.withValues(alpha: 1);

  factory NoteInkSnapshot.of(
    Iterable<Stroke> strokes, {
    required ui.Size logicalSize,
    required int revision,
    required ui.Brightness brightness,
    required ui.Color background,
    ui.Rect? focusBounds,
    List<SnapshotBitmap> bitmaps = const <SnapshotBitmap>[],
    Iterable<StickyNoteElement> stickies = const <StickyNoteElement>[],
    Iterable<Stroke> aiNotes = const <Stroke>[],
  }) {
    return NoteInkSnapshot(
      strokes: <SnapshotStroke>[
        for (final Stroke stroke in strokes)
          SnapshotStroke(
            points: stroke.points,
            width: stroke.style.width,
            color: stroke.style.resolve(brightness),
            isDot: stroke.isDot,
            writing: stroke.style.writing,
            widths: stroke.widths,
          ),
      ],
      logicalSize: logicalSize,
      revision: revision,
      brightness: brightness,
      background: background,
      focusBounds: focusBounds,
      bitmaps: bitmaps,
      stickies: <StickyNoteElement>[
        for (final StickyNoteElement note in stickies)
          if (note.isValid) note,
      ],
      aiNotes: <SpaceStroke>[
        for (final Stroke stroke in aiNotes)
          (points: stroke.points, width: stroke.style.width),
      ],
    );
  }

  final List<SnapshotStroke> strokes;

  /// Pictures on the page. Only a page-wide background ([SnapshotBitmap.
  /// affectsCrop] false), such as a PDF page, needs its bytes: it is read
  /// for print. Any other picture is taken whole, by its box.
  final List<SnapshotBitmap> bitmaps;

  /// The page's sticky notes, in paint order, above [strokes].
  final List<StickyNoteElement> stickies;

  /// Of [strokes], those the assistant wrote and drew.
  final List<SpaceStroke> aiNotes;
  final ui.Size logicalSize;
  final int revision;
  final ui.Brightness brightness;
  final ui.Color background;

  /// The page-local logical region the selected-ink image shows: its crop,
  /// padding included, so that image maps linearly onto the note.
  final ui.Rect? focusBounds;
}

/// What the model is told about the whole note, in place of a picture of
/// it, and what returned notation is placed against: the paper's size,
/// where the selection is on it, the ink there, what is nearby, and where
/// the paper is blank. Only the selected-ink image is ever sent.
class NoteImage {
  NoteImage({
    required this.logicalSize,
    required this.revision,
    this.normalizedFocusBounds,
    this.focusInk = const <List<InkVector>>[],
    this.space,
  });

  final ui.Size logicalSize;
  final int revision;

  /// [NoteInkSnapshot.focusBounds] as note_normalized coordinates. May
  /// reach slightly past 0 or 1 where the crop's padding leaves the paper.
  final ui.Rect? normalizedFocusBounds;

  /// The ink around the selection, as note_normalized polylines cut down
  /// to their ends and corners, so the model can attach to it exactly.
  final List<List<InkVector>> focusInk;

  /// Where the paper is blank, and what is near the selection, as it was
  /// when this was made: the areas the model is told it may draw in, and
  /// where a sticky note it asks for goes. Null when it was not measured.
  final NoteFreeSpace? space;
}

enum NoteImageFailure { invalidGeometry, encodingFailed }

class NoteImageException implements Exception {
  const NoteImageException(this.failure);

  final NoteImageFailure failure;

  String get message => switch (failure) {
    NoteImageFailure.invalidGeometry =>
      'The current note could not be prepared for Notation.',
    NoteImageFailure.encodingFailed =>
      'The current note could not be prepared for Notation.',
  };
}

/// Describes a note for one request. Nothing of the page is drawn: it is
/// measured.
class NoteImageRenderer {
  const NoteImageRenderer({this.config = const AiImageConfig()});

  final AiImageConfig config;

  Future<NoteImage> render(NoteInkSnapshot snapshot) async {
    final ui.Size size = snapshot.logicalSize;
    if (!size.isFinite || size.width <= 0 || size.height <= 0) {
      throw const NoteImageException(NoteImageFailure.invalidGeometry);
    }
    for (final SnapshotStroke stroke in snapshot.strokes) {
      if (stroke.points.isEmpty ||
          !stroke.width.isFinite ||
          stroke.width <= 0) {
        throw const NoteImageException(NoteImageFailure.invalidGeometry);
      }
      for (final InkVector point in stroke.points) {
        if (!point.isFinite) {
          throw const NoteImageException(NoteImageFailure.invalidGeometry);
        }
      }
    }
    for (final SnapshotBitmap bitmap in snapshot.bitmaps) {
      if (!bitmap.bounds.isFinite ||
          bitmap.bounds.isEmpty ||
          !bitmap.rotation.isFinite ||
          (!bitmap.affectsCrop && bitmap.bytes.isEmpty)) {
        throw const NoteImageException(NoteImageFailure.invalidGeometry);
      }
    }
    final NoteFreeSpace space;
    try {
      space = await _measureSpace(snapshot);
    } on Object {
      throw const NoteImageException(NoteImageFailure.encodingFailed);
    }
    return NoteImage(
      logicalSize: size,
      revision: snapshot.revision,
      normalizedFocusBounds: _normalized(snapshot.focusBounds, size),
      focusInk: _focusInk(snapshot),
      space: space,
    );
  }

  /// Where the paper in [snapshot] is blank. A page-wide background, such
  /// as a PDF page, is read pixel by pixel for print; any other picture,
  /// and every sticky note, takes its whole box.
  Future<NoteFreeSpace> _measureSpace(NoteInkSnapshot snapshot) async {
    final List<SpaceBackground> backgrounds = <SpaceBackground>[];
    final List<ui.Rect> blocks = <ui.Rect>[
      for (final StickyNoteElement note in snapshot.stickies) note.bounds,
    ];
    for (final SnapshotBitmap bitmap in snapshot.bitmaps) {
      if (bitmap.affectsCrop) {
        blocks.add(bitmap.rotatedBounds);
        continue;
      }
      final SpaceBackground? background = await _readBackground(bitmap);
      if (background == null) {
        // Unreadable print could be anywhere: none of it is blank.
        blocks.add(bitmap.bounds);
      } else {
        backgrounds.add(background);
      }
    }
    return NoteFreeSpace.measure(
      pageSize: snapshot.logicalSize,
      strokes: <SpaceStroke>[
        for (final SnapshotStroke stroke in snapshot.strokes)
          (
            points: stroke.points,
            width:
                stroke.width *
                (stroke.widths == null
                    ? 1
                    : stroke.widths!.fold<double>(1, math.max)),
          ),
      ],
      blocks: blocks,
      backgrounds: backgrounds,
      aiNotes: snapshot.aiNotes,
      focus: snapshot.focusBounds,
      config: config.space,
    );
  }

  Future<SpaceBackground?> _readBackground(SnapshotBitmap bitmap) async {
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(bitmap.bytes);
      image = (await codec.getNextFrame()).image;
      final ByteData? pixels = await image.toByteData();
      if (pixels == null) {
        return null;
      }
      return SpaceBackground(
        bounds: bitmap.bounds,
        width: image.width,
        height: image.height,
        rgba: pixels.buffer.asUint8List(
          pixels.offsetInBytes,
          pixels.lengthInBytes,
        ),
      );
    } on Object {
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  /// The ink reaching into [NoteInkSnapshot.focusBounds], simplified and
  /// note_normalized. Empty without a focus.
  List<List<InkVector>> _focusInk(NoteInkSnapshot snapshot) {
    final ui.Rect? focus = snapshot.focusBounds;
    if (focus == null || !focus.isFinite || focus.isEmpty) {
      return const <List<InkVector>>[];
    }
    final ui.Size size = snapshot.logicalSize;
    return <List<InkVector>>[
      for (final List<InkVector> outline in inkOutlines(
        <List<InkVector>>[
          for (final SnapshotStroke stroke in snapshot.strokes) stroke.points,
        ],
        focus,
        tolerance:
            config.focusInkTolerance * math.max(focus.width, focus.height),
        maxPoints: config.focusInkMaxPoints,
      ))
        <InkVector>[
          for (final InkVector point in outline)
            InkVector(point.x / size.width, point.y / size.height),
        ],
    ];
  }

  /// Not clamped: the selected-ink image's crop can run past the paper by
  /// its padding, and the model maps that image onto the note linearly.
  static ui.Rect? _normalized(ui.Rect? bounds, ui.Size size) {
    if (bounds == null || !bounds.isFinite) {
      return null;
    }
    return ui.Rect.fromLTRB(
      bounds.left / size.width,
      bounds.top / size.height,
      bounds.right / size.width,
      bounds.bottom / size.height,
    );
  }
}
