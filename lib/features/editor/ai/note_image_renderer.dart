import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../ink/ink_painter.dart';
import '../ink/ink_sample.dart';
import '../ink/stroke.dart';
import '../sticky/sticky_note.dart';
import '../sticky/sticky_note_painter.dart';
import 'ai_config.dart';
import 'ink_attachment.dart';
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
  }) : strokes = List<SnapshotStroke>.unmodifiable(strokes),
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
  }) {
    return NoteInkSnapshot(
      strokes: <SnapshotStroke>[
        for (final Stroke stroke in strokes)
          SnapshotStroke(
            points: stroke.points,
            width: stroke.style.width,
            color: stroke.style.resolve(brightness),
            isDot: stroke.isDot,
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
    );
  }

  final List<SnapshotStroke> strokes;
  final List<SnapshotBitmap> bitmaps;

  /// The page's sticky notes, in paint order, under [strokes].
  final List<StickyNoteElement> stickies;
  final ui.Size logicalSize;
  final int revision;
  final ui.Brightness brightness;
  final ui.Color background;

  /// The page-local logical region the selected-ink image shows: its crop,
  /// padding included, so that image maps linearly onto the note.
  final ui.Rect? focusBounds;
}

/// The exact whole-note PNG and metadata used to place returned notation.
class NoteImage {
  NoteImage({
    required this.png,
    required this.width,
    required this.height,
    required this.scale,
    required this.logicalSize,
    required this.revision,
    this.normalizedFocusBounds,
    this.gridDivisions = 0,
    this.focusInk = const <List<InkVector>>[],
  });

  final Uint8List png;
  final int width;
  final int height;
  final double scale;
  final ui.Size logicalSize;
  final int revision;

  /// [NoteInkSnapshot.focusBounds] as note_normalized coordinates. May
  /// reach slightly past 0 or 1 where the crop's padding leaves the paper.
  final ui.Rect? normalizedFocusBounds;

  /// The image carries a labelled grid line every 1/[gridDivisions] of the
  /// paper, or none when this is 0. See [AiImageConfig.noteGridDivisions].
  final int gridDivisions;

  /// The ink around the selection, as note_normalized polylines cut down
  /// to their ends and corners, so the model can attach to it exactly.
  final List<List<InkVector>> focusInk;
}

enum NoteImageFailure { invalidGeometry, tooLarge, encodingFailed }

class NoteImageException implements Exception {
  const NoteImageException(this.failure);

  final NoteImageFailure failure;

  String get message => switch (failure) {
    NoteImageFailure.invalidGeometry =>
      'The current note could not be prepared for Notation.',
    NoteImageFailure.tooLarge =>
      'The current note is too large to send in Notation mode.',
    NoteImageFailure.encodingFailed =>
      'The current note could not be prepared for Notation.',
  };
}

class NoteImageRenderer {
  const NoteImageRenderer({
    this.config = const AiImageConfig(),
    this.debugOnImage,
  });

  final AiImageConfig config;
  @visibleForTesting
  final ValueChanged<ui.Image>? debugOnImage;

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
          bitmap.bytes.isEmpty) {
        throw const NoteImageException(NoteImageFailure.invalidGeometry);
      }
    }
    final double scale = math.min(
      config.pixelRatio,
      config.maxDimension / math.max(size.width, size.height),
    );
    if (!scale.isFinite || scale < config.minPixelRatio) {
      throw const NoteImageException(NoteImageFailure.tooLarge);
    }
    final int width = (size.width * scale).ceil().clamp(1, config.maxDimension);
    final int height = (size.height * scale).ceil().clamp(
      1,
      config.maxDimension,
    );
    final int divisions = config.noteGridDivisions < 2
        ? 0
        : config.noteGridDivisions;
    final List<ui.Image> decoded = <ui.Image>[];
    try {
      for (final SnapshotBitmap bitmap in snapshot.bitmaps) {
        decoded.add(await _decodeImage(bitmap.bytes));
      }
      return await _renderDecoded(
        snapshot,
        scale,
        width,
        height,
        divisions,
        decoded,
      );
    } on NoteImageException {
      rethrow;
    } on Object {
      throw const NoteImageException(NoteImageFailure.encodingFailed);
    } finally {
      for (final ui.Image image in decoded) {
        image.dispose();
      }
    }
  }

  Future<NoteImage> _renderDecoded(
    NoteInkSnapshot snapshot,
    double scale,
    int width,
    int height,
    int divisions,
    List<ui.Image> decoded,
  ) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder)
      ..drawRect(
        ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        ui.Paint()..color = snapshot.background,
      );
    if (divisions > 0) {
      _paintGrid(canvas, width, height, divisions, snapshot.brightness);
    }
    canvas.scale(scale);
    for (int i = 0; i < snapshot.bitmaps.length; i++) {
      final SnapshotBitmap bitmap = snapshot.bitmaps[i];
      final ui.Image image = decoded[i];
      final ui.Rect bounds = bitmap.bounds;
      canvas.save();
      canvas
        ..translate(bounds.center.dx, bounds.center.dy)
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
            width: bounds.width,
            height: bounds.height,
          ),
          ui.Paint()..filterQuality = ui.FilterQuality.medium,
        );
      canvas.restore();
    }
    for (final StickyNoteElement note in snapshot.stickies) {
      paintStickyNote(canvas, note);
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
        outline: stroke.widths == null
            ? null
            : buildInkOutline(stroke.points, stroke.widths!, stroke.width),
      );
    }
    final ui.Picture picture = recorder.endRecording();
    ui.Image? image;
    try {
      image = await picture.toImage(width, height);
      debugOnImage?.call(image);
      final ByteData? bytes = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (bytes == null || bytes.lengthInBytes == 0) {
        throw const NoteImageException(NoteImageFailure.encodingFailed);
      }
      return NoteImage(
        png: bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        width: width,
        height: height,
        scale: scale,
        logicalSize: snapshot.logicalSize,
        revision: snapshot.revision,
        normalizedFocusBounds: _normalized(
          snapshot.focusBounds,
          snapshot.logicalSize,
        ),
        gridDivisions: divisions,
        focusInk: _focusInk(snapshot),
      );
    } on NoteImageException {
      rethrow;
    } on Object {
      throw const NoteImageException(NoteImageFailure.encodingFailed);
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

  /// Faint lines across the paper at every 1/[divisions] of it, and fainter
  /// ones halfway between, in image pixels and under the ink. Each main
  /// line is labelled with its note_normalized coordinate: x along the top
  /// edge, y along the left.
  void _paintGrid(
    ui.Canvas canvas,
    int width,
    int height,
    int divisions,
    ui.Brightness brightness,
  ) {
    final ui.Color tone = brightness == ui.Brightness.dark
        ? const ui.Color(0xFFFFFFFF)
        : const ui.Color(0xFF000000);
    final ui.Paint major = ui.Paint()
      ..color = tone.withValues(alpha: 0.2)
      ..strokeWidth = 1;
    final ui.Paint minor = ui.Paint()
      ..color = tone.withValues(alpha: 0.08)
      ..strokeWidth = 1;
    final int steps = divisions * 2;
    for (int i = 1; i < steps; i++) {
      final ui.Paint paint = i.isEven ? major : minor;
      // Centered on a pixel, so each line is one crisp pixel wide.
      final double x = (width * i / steps).floorToDouble() + 0.5;
      final double y = (height * i / steps).floorToDouble() + 0.5;
      canvas
        ..drawLine(ui.Offset(x, 0), ui.Offset(x, height.toDouble()), paint)
        ..drawLine(ui.Offset(0, y), ui.Offset(width.toDouble(), y), paint);
    }
    final ui.Color label = tone.withValues(alpha: 0.6);
    for (int i = 1; i < divisions; i++) {
      final String value = double.parse(
        (i / divisions).toStringAsFixed(3),
      ).toString();
      _paintLabel(
        canvas,
        'x$value',
        ui.Offset((width * i / divisions).floorToDouble() + 3, 2),
        label,
      );
      _paintLabel(
        canvas,
        'y$value',
        ui.Offset(3, (height * i / divisions).floorToDouble() + 2),
        label,
      );
    }
  }

  void _paintLabel(
    ui.Canvas canvas,
    String text,
    ui.Offset offset,
    ui.Color color,
  ) {
    final ui.ParagraphBuilder builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(fontSize: config.noteGridLabelSize),
          )
          ..pushStyle(ui.TextStyle(color: color))
          ..addText(text);
    final ui.Paragraph paragraph = builder.build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
    canvas.drawParagraph(paragraph, offset);
    paragraph.dispose();
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
