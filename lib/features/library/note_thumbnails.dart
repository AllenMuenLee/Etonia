import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../editor/document_io/document_models.dart';
import '../editor/document_io/document_platform.dart';
import '../editor/ink/ink_painter.dart';
import '../editor/ink/stroke.dart';
import '../editor/page/page_background.dart';
import '../editor/page/page_setup.dart';
import '../editor/sticky/sticky_note.dart';
import '../editor/sticky/sticky_note_painter.dart';
import '../editor/text/note_text.dart';
import 'library_models.dart';
import 'note_content.dart';
import 'note_repository.dart';

/// The colors a thumbnail is drawn in, which follow the theme.
@immutable
class ThumbnailStyle {
  const ThumbnailStyle({
    required this.brightness,
    required this.paper,
    required this.rule,
    required this.marginRule,
  });

  final Brightness brightness;
  final Color paper;
  final Color rule;
  final Color marginRule;

  @override
  bool operator ==(Object other) {
    return other is ThumbnailStyle &&
        other.brightness == brightness &&
        other.paper == paper &&
        other.rule == rule &&
        other.marginRule == marginRule;
  }

  @override
  int get hashCode => Object.hash(brightness, paper, rule, marginRule);
}

/// A note's first page, flattened into one small image: its paper, PDF,
/// pictures, and ink. Owned by whoever holds it, who disposes it.
class NoteThumbnailImage {
  NoteThumbnailImage(this.image);

  final ui.Image image;

  double get aspect => image.width / image.height;

  NoteThumbnailImage clone() => NoteThumbnailImage(image.clone());

  void dispose() => image.dispose();
}

/// Draws each note's first page once, to an image, and keeps it.
///
/// The library then only draws pictures: nothing is repainted stroke by
/// stroke as it scrolls, no PDF is rasterized twice, and no note's content
/// stays in memory once its picture is made. A note's picture is redrawn
/// when the note changes or the theme does; until then the old one stays
/// on screen.
class ThumbnailCache {
  ThumbnailCache({
    required this.repository,
    required this.rasterizer,
    this.pixelWidth = 420,
    this.capacity = 120,
    this.concurrency = 4,
    this.maxBytes = 24 * 1024 * 1024,
    this.prefetchLimit = 18,
  }) : assert(pixelWidth > 0),
       assert(capacity > 0),
       assert(concurrency > 0),
       assert(maxBytes > 0),
       assert(prefetchLimit >= 0);

  final NoteRepository repository;
  final PdfRasterizer rasterizer;

  /// How many pixels wide each picture is drawn.
  final int pixelWidth;

  /// How many notes' pictures are kept, the least recently shown dropped
  /// first.
  final int capacity;

  /// How many pictures are drawn at once.
  final int concurrency;
  final int maxBytes;

  /// How many of a folder's notes [prefetch] draws ahead: about a screen
  /// and a half of cards, which fits in [maxBytes].
  final int prefetchLimit;

  int get retainedBytes => _entries.values.fold(0, (int total, _Entry entry) {
    final ui.Image? image = entry.image.value?.image;
    return total + (image == null ? 0 : image.width * image.height * 4);
  });

  /// Borrowed until the next cache mutation. The receiving widget clones
  /// this synchronously in initState; no load/render is started here.
  NoteThumbnailImage? peek(NoteEntry note, Brightness brightness) {
    final entry = _entries[note.id];
    if (entry?.key != _keyOf(note) || entry?.style?.brightness != brightness) {
      return null;
    }
    return entry?.image.value;
  }

  final LinkedHashMap<String, _Entry> _entries =
      LinkedHashMap<String, _Entry>();

  /// Pictures asked for by a card being built, drawn before those only
  /// fetched in advance.
  final Queue<_Entry> _waiting = Queue<_Entry>();
  final Queue<_Entry> _background = Queue<_Entry>();
  int _running = 0;
  bool _disposed = false;

  /// Pictures being drawn, and whether drawing waits for the library to
  /// be shown again.
  final Set<_Entry> _drawing = <_Entry>{};
  bool _paused = false;

  /// Moves on whenever what is drawing is let go: a draw started before
  /// stops at its next step.
  int _epoch = 0;

  /// The user has moved on to something these pictures are not part of,
  /// such as a note: drawing stops, so it never competes with what the
  /// user now sees. Pictures waiting their turn are let go, those being
  /// drawn stop at their next step, and each is drawn when it is next
  /// asked for once [resume]d. Pictures already drawn stay.
  void pause() {
    if (_paused) return;
    _paused = true;
    cancelPending();
  }

  /// Draws again, as the library comes back into view: first what is
  /// asked for, then the notes just saved.
  void resume() {
    if (!_paused) return;
    _paused = false;
    _pump();
    _drawCaptured();
  }

  /// First pages just saved from the editor, by note, with the entry each
  /// was saved as. A note's picture is drawn from its page here, already in
  /// memory, rather than read back from disk.
  final Map<String, ({NoteEntry note, StoredPage page})> _captured =
      <String, ({NoteEntry note, StoredPage page})>{};

  /// The style pictures were last asked for in, which those of the notes
  /// just saved are drawn in.
  ThumbnailStyle? _style;

  /// [note] has just been saved with [page] as its first page. Its picture
  /// is drawn from [page] as soon as the library is in view, and stored, so
  /// a folder showing the note later only reads that picture. Nothing is
  /// drawn while [pause]d: the editor in front saves often.
  void capture(NoteEntry note, StoredPage page) {
    if (_disposed) return;
    _captured[note.id] = (note: note, page: page);
    if (!_paused) _drawCaptured();
  }

  void _drawCaptured() {
    final ThumbnailStyle? style = _style;
    if (style == null || _disposed) return;
    for (final ({NoteEntry note, StoredPage page}) captured
        in _captured.values.toList()) {
      _request(captured.note, style, background: true);
    }
  }

  /// Lets go of the pictures waiting to be drawn and of those being drawn,
  /// as when another folder is shown. Each is drawn when next asked for.
  void cancelPending() {
    _epoch++;
    for (final _Entry entry in <_Entry>[..._waiting, ..._background]) {
      entry
        ..queued = false
        ..dropped = true;
    }
    _waiting.clear();
    _background.clear();
    for (final _Entry entry in _drawing) {
      entry.dropped = true;
    }
  }

  /// The picture of [note] in [style], drawn if it is missing or stale.
  /// Its value is null until the first picture is ready; the listenable
  /// then keeps a picture, replacing it when a newer one is ready.
  ValueListenable<NoteThumbnailImage?> watch(
    NoteEntry note,
    ThumbnailStyle style,
  ) => _request(note, style, background: false).image;

  /// Starts drawing the first [prefetchLimit] of [notes] as soon as they
  /// are known, so their cards find the pictures ready when built. Cards
  /// on screen still draw ahead of these.
  void prefetch(Iterable<NoteEntry> notes, ThumbnailStyle style) {
    int left = prefetchLimit;
    for (final NoteEntry note in notes) {
      if (left-- <= 0) break;
      _request(note, style, background: true);
    }
  }

  /// What [note]'s picture is named for: the pages it shows, as saved.
  /// Its title and dates do not change it, and it reads back exactly.
  static String _keyOf(NoteEntry note) => 'r${note.revision}';

  _Entry _request(
    NoteEntry note,
    ThumbnailStyle style, {
    required bool background,
  }) {
    _style = style;
    final String key = _keyOf(note);
    _Entry? entry = _entries.remove(note.id);
    entry ??= _Entry(note.id);
    _entries[note.id] = entry;
    final bool stale =
        entry.key != key || entry.style != style || entry.dropped;
    if (stale) {
      entry
        ..key = key
        ..style = style
        ..dropped = false;
    }
    final NoteEntry? captured = _captured[note.id]?.note;
    if (captured != null &&
        (note.revision > captured.revision ||
            (!stale &&
                !entry.queued &&
                !_drawing.contains(entry) &&
                key == _keyOf(captured)))) {
      // Changed again since, or already pictured as it was saved.
      _captured.remove(note.id);
    }
    if (entry.queued) {
      if (!background && entry.background) {
        // A card wants it now: it goes ahead of the ones only fetched early.
        _background.remove(entry);
        entry.background = false;
        _waiting.add(entry);
        _pump();
      }
    } else if (stale) {
      entry
        ..queued = true
        ..background = background;
      (background ? _background : _waiting).add(entry);
      _pump();
    }
    _evict();
    return entry;
  }

  /// Forgets the notes not in [ids], such as deleted ones.
  void retainOnly(Set<String> ids) {
    _captured.removeWhere((String id, _) => !ids.contains(id));
    _entries.removeWhere((String id, _Entry entry) {
      final bool gone = !ids.contains(id);
      if (gone) entry.dispose();
      return gone;
    });
    final NoteRepository repository = this.repository;
    final ThumbnailDiskStore? store = repository is ThumbnailDiskStore
        ? repository as ThumbnailDiskStore
        : null;
    if (store != null) {
      unawaited(store.retainThumbnailNotes(ids));
    }
  }

  /// How many pictures are kept under memory pressure: about as many as
  /// a library screen shows at once, the most recently shown.
  static const int _pressuredCapacity = 32;

  /// Under memory pressure: keeps only the most recently shown pictures.
  /// Those still on screen keep clones of their own.
  void releaseMemory() {
    // Their pictures are drawn from disk instead, when next shown.
    _captured.clear();
    while (_entries.length > _pressuredCapacity) {
      _entries.remove(_entries.keys.first)!.dispose();
    }
  }

  void _evict() {
    while (_entries.length > capacity || retainedBytes > maxBytes) {
      final String oldest = _entries.keys.first;
      _entries.remove(oldest)!.dispose();
    }
  }

  void _pump() {
    while (!_disposed &&
        !_paused &&
        _running < concurrency &&
        (_waiting.isNotEmpty || _background.isNotEmpty)) {
      final _Entry entry = (_waiting.isNotEmpty ? _waiting : _background)
          .removeFirst();
      entry.queued = false;
      if (entry.disposed) continue;
      _running++;
      _drawing.add(entry);
      final String key = entry.key!;
      final ThumbnailStyle style = entry.style!;
      final int epoch = _epoch;
      unawaited(
        _draw(entry.noteId, key, style, () => epoch != _epoch || _disposed)
            .then((ui.Image? image) {
              if (image == null) return;
              // Finished after all: nothing is left to draw again.
              entry.dropped = false;
              // A newer request, or a dropped entry, wants another picture.
              if (_disposed ||
                  entry.disposed ||
                  entry.key != key ||
                  entry.style != style) {
                image.dispose();
                return;
              }
              entry.show(NoteThumbnailImage(image));
              _evict();
            })
            .catchError((Object error, StackTrace stack) {
              // Drawn again when next asked for, rather than left blank.
              entry.dropped = true;
              debugPrint('Thumbnail of ${entry.noteId} failed: $error\n$stack');
            })
            .whenComplete(() {
              _running--;
              _drawing.remove(entry);
              _pump();
            }),
      );
    }
  }

  Future<Uint8List?> _asset(String noteId, String assetId) async {
    try {
      return (await repository.readAsset(noteId, assetId)).bytes;
    } on Object {
      return null;
    }
  }

  Future<ui.Image?> _draw(
    String noteId,
    String key,
    ThumbnailStyle style,
    bool Function() cancelled,
  ) async {
    final String diskKey = '${key}_${style.brightness.name}';
    final NoteRepository repository = this.repository;
    final ThumbnailDiskStore? store = repository is ThumbnailDiskStore
        ? repository as ThumbnailDiskStore
        : null;
    // Just saved from the editor: drawn from the page in memory. Nothing for
    // it is on disk yet.
    final ({NoteEntry note, StoredPage page})? captured = _captured[noteId];
    final StoredPage? fresh = captured != null && _keyOf(captured.note) == key
        ? captured.page
        : null;
    if (store != null && fresh == null) {
      final Uint8List? cached = await store.readThumbnail(noteId, diskKey);
      if (cached != null) {
        try {
          return await _decode(cached, pixelWidth);
        } on Object {
          // Corrupt/stale cache entries are replaced by a fresh render.
        }
      }
    }
    if (cancelled()) return null;
    final StoredPage? page = fresh ?? await repository.loadFirstPage(noteId);
    if (page == null || cancelled()) return null;
    final Size paper = NoteThumbnailPainter.pageSizeOf(page);
    final double aspect = (paper.width / paper.height).clamp(0.6, 1.5);
    final int width = pixelWidth;
    final int height = math.max(1, (width / aspect).round());
    final double scale = width / paper.width;

    // What is decoded only for this picture, freed once it is drawn.
    final List<ui.Image> parts = <ui.Image>[];
    ui.Image? pdf;
    final PdfPageSource? source = page.pdfSource;
    if (source != null) {
      final Uint8List? bytes = await _asset(noteId, source.assetId);
      if (bytes != null) {
        final int pdfHeight = math.max(
          1,
          (width * source.pageSize.height / source.pageSize.width).round(),
        );
        try {
          final PdfRasterizer rasterizer = this.rasterizer;
          if (rasterizer is PdfImageRasterizer) {
            pdf = await (rasterizer as PdfImageRasterizer).renderImage(
              bytes,
              source.pageIndex,
              pixelWidth: width,
              pixelHeight: pdfHeight,
            );
          } else {
            pdf = await _decode(
              (await rasterizer.render(
                bytes,
                source.pageIndex,
                pixelWidth: width,
                pixelHeight: pdfHeight,
              )).png,
              width,
            );
          }
          parts.add(pdf);
        } on Object {
          pdf = null;
        }
      }
    }
    // Let go of part way: what was decoded for it goes too.
    bool stopped() {
      if (!cancelled()) return false;
      for (final ui.Image part in parts) {
        part.dispose();
      }
      return true;
    }

    final List<(NoteImageElement, ui.Image)> pictures =
        <(NoteImageElement, ui.Image)>[];
    for (final NoteImageElement element in page.images) {
      if (stopped()) return null;
      if ((element.center.y - element.size.height) * scale > height) continue;
      final Uint8List? bytes = await _asset(noteId, element.assetId);
      if (bytes == null) continue;
      try {
        final ui.Image decoded = await _decode(
          bytes,
          math.max(1, (element.size.width * scale).round()),
        );
        parts.add(decoded);
        pictures.add((element, decoded));
      } on Object {
        // A picture that cannot be read is left out.
      }
    }

    if (stopped()) return null;
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    final Size size = Size(width.toDouble(), height.toDouble());
    canvas.drawRect(Offset.zero & size, Paint()..color = style.paper);
    NoteThumbnailPainter(
      page: page,
      brightness: style.brightness,
      rule: style.rule,
      marginRule: style.marginRule,
      paintInk: false,
    ).paint(canvas, size);
    canvas
      ..save()
      ..clipRect(Offset.zero & size)
      ..scale(scale);
    final Paint smooth = Paint()..filterQuality = FilterQuality.medium;
    if (pdf != null && source != null) {
      canvas.drawImageRect(
        pdf,
        Offset.zero & Size(pdf.width.toDouble(), pdf.height.toDouble()),
        Offset.zero & source.pageSize,
        smooth,
      );
    }
    for (final (NoteImageElement element, ui.Image image) in pictures) {
      canvas
        ..save()
        ..translate(element.center.x, element.center.y)
        ..rotate(element.rotation)
        ..drawImageRect(
          image,
          Offset.zero & Size(image.width.toDouble(), image.height.toDouble()),
          Rect.fromCenter(
            center: Offset.zero,
            width: element.size.width,
            height: element.size.height,
          ),
          smooth,
        )
        ..restore();
    }
    canvas.restore();
    NoteThumbnailPainter(
      page: page,
      brightness: style.brightness,
      rule: style.rule,
      marginRule: style.marginRule,
      paintBackground: false,
    ).paint(canvas, size);
    final ui.Picture picture = recorder.endRecording();
    try {
      final ui.Image result = await picture.toImage(width, height);
      if (fresh != null && identical(_captured[noteId], captured)) {
        _captured.remove(noteId);
      }
      // Saved after the picture is shown, not before: the encode and write
      // are not what the user waits for.
      if (store != null) {
        final Future<void> write = _persist(
          store,
          noteId,
          diskKey,
          result.clone(),
        );
        _writes.add(write);
        unawaited(write.whenComplete(() => _writes.remove(write)));
      }
      return result;
    } finally {
      picture.dispose();
      for (final ui.Image part in parts) {
        part.dispose();
      }
    }
  }

  final Set<Future<void>> _writes = <Future<void>>{};

  /// Completes once the pictures drawn so far are saved to disk.
  @visibleForTesting
  Future<void> settleWrites() => Future.wait(_writes.toList());

  /// Writes [image] to [store] and disposes it.
  static Future<void> _persist(
    ThumbnailDiskStore store,
    String noteId,
    String diskKey,
    ui.Image image,
  ) async {
    try {
      final ByteData? encoded = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (encoded != null) {
        await store.writeThumbnail(
          noteId,
          diskKey,
          encoded.buffer.asUint8List(
            encoded.offsetInBytes,
            encoded.lengthInBytes,
          ),
        );
      }
    } on Object {
      // Disk caching is opportunistic; the in-memory image is valid.
    } finally {
      image.dispose();
    }
  }

  static Future<ui.Image> _decode(Uint8List bytes, int targetWidth) async {
    final ui.Codec codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: targetWidth,
    );
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  void dispose() {
    _disposed = true;
    for (final _Entry entry in _entries.values) {
      entry.dispose();
    }
    _entries.clear();
    _captured.clear();
    _waiting.clear();
    _background.clear();
  }
}

class _Entry {
  _Entry(this.noteId);

  final String noteId;
  String? key;
  ThumbnailStyle? style;
  bool queued = false;

  /// Queued by [ThumbnailCache.prefetch], with no card asking yet.
  bool background = false;
  bool disposed = false;

  /// Let go of before its picture was drawn: drawn when next asked for.
  bool dropped = false;
  final ValueNotifier<NoteThumbnailImage?> image =
      ValueNotifier<NoteThumbnailImage?>(null);

  void show(NoteThumbnailImage next) {
    final NoteThumbnailImage? previous = image.value;
    image.value = next;
    // Whoever showed the old picture holds a clone of their own.
    previous?.dispose();
  }

  void dispose() {
    if (disposed) return;
    disposed = true;
    // Views hold clones, so release our handle immediately, even if the app
    // is backgrounded and will not produce another frame.
    image.value?.dispose();
    image.dispose();
  }
}

/// Shows a [ThumbnailCache] picture, keeping a clone of its own so the
/// cache can drop its copy at any time. Fades the first picture in.
class ThumbnailView extends StatefulWidget {
  const ThumbnailView({
    super.key,
    required this.image,
    required this.placeholderAspect,
    required this.builder,
  });

  final ValueListenable<NoteThumbnailImage?> image;

  /// The shape shown before the first picture is ready.
  final double placeholderAspect;

  /// Frames the picture, or null before it is ready, at [aspect].
  final Widget Function(BuildContext context, ui.Image? image, double aspect)
  builder;

  @override
  State<ThumbnailView> createState() => _ThumbnailViewState();
}

class _ThumbnailViewState extends State<ThumbnailView> {
  NoteThumbnailImage? _shown;

  @override
  void initState() {
    super.initState();
    widget.image.addListener(_update);
    _take();
  }

  @override
  void didUpdateWidget(ThumbnailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) {
      oldWidget.image.removeListener(_update);
      widget.image.addListener(_update);
      _take();
    }
  }

  void _take() {
    final NoteThumbnailImage? next = widget.image.value;
    _shown?.dispose();
    _shown = next?.clone();
  }

  void _update() => setState(_take);

  @override
  void dispose() {
    widget.image.removeListener(_update);
    _shown?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final NoteThumbnailImage? shown = _shown;
    return widget.builder(
      context,
      shown?.image,
      shown?.aspect ?? widget.placeholderAspect,
    );
  }
}

/// Paints the top of a stored page, as wide as the size it is given.
class NoteThumbnailPainter extends CustomPainter {
  const NoteThumbnailPainter({
    required this.page,
    required this.brightness,
    required this.rule,
    required this.marginRule,
    this.paintBackground = true,
    this.paintInk = true,
  });

  /// The smallest page a fit or infinite page is shown as, so a few lines
  /// of ink do not fill the card.
  static const Size _minimumPage = Size(640, 480);

  final StoredPage page;
  final Brightness brightness;
  final Color rule;
  final Color marginRule;
  final bool paintBackground;
  final bool paintInk;

  static Size pageSizeOf(StoredPage page) {
    if (page.pdfSource != null) return page.pdfSource!.pageSize;
    if (page.setup.size == PageSize.custom) return page.setup.customSize!;
    final Size? fixed = page.setup.size.fixedSize;
    if (fixed != null) {
      return fixed;
    }
    double right = page.extent?.width ?? _minimumPage.width;
    double bottom = page.extent?.height ?? _minimumPage.height;
    for (final Stroke stroke in page.strokes) {
      right = math.max(right, stroke.bounds.right);
      bottom = math.max(bottom, stroke.bounds.bottom);
    }
    for (final StickyNoteElement note in page.stickyNotes) {
      right = math.max(right, note.bounds.right);
      bottom = math.max(bottom, note.bounds.bottom);
    }
    for (final NoteTextElement text in page.textElements) {
      right = math.max(right, text.bounds.right);
      bottom = math.max(bottom, text.bounds.bottom);
    }
    return Size(right, bottom);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final Size pageSize = pageSizeOf(page);
    if (size.isEmpty || pageSize.isEmpty) {
      return;
    }
    // The top of the page, as wide as the picture.
    final double scale = size.width / pageSize.width;
    canvas
      ..save()
      ..clipRect(Offset.zero & size)
      ..scale(scale);
    final Size visible = Size(pageSize.width, size.height / scale);
    if (paintBackground) {
      PageBackgroundPainter(
        background: page.setup.background,
        rule: rule,
        marginRule: marginRule,
      ).paint(canvas, visible);
    }
    if (paintInk) {
      for (final Stroke stroke in page.strokes) {
        if (stroke.bounds.top > visible.height) {
          continue;
        }
        paintInkStroke(
          canvas,
          color: stroke.style.resolve(brightness),
          width: stroke.style.width,
          path: stroke.path,
          origin: stroke.points.first,
          isDot: stroke.isDot,
          outline: stroke.outline,
          writing: stroke.style.writing,
        );
      }
      // Sticky notes, with their own ink, above the page's ink.
      for (final StickyNoteElement note in page.stickyNotes) {
        if (note.bounds.top > visible.height) {
          continue;
        }
        paintStickyNote(canvas, note);
      }
      for (final NoteTextElement element in page.textElements) {
        if (element.bounds.top > visible.height) continue;
        final TextPainter painter = TextPainter(
          text: TextSpan(
            text: element.text,
            style: element.settings.resolve(brightness),
          ),
          textAlign: element.settings.alignment,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: element.width);
        painter
          ..paint(canvas, Offset(element.position.x, element.position.y))
          ..dispose();
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(NoteThumbnailPainter oldDelegate) {
    return oldDelegate.page != page ||
        oldDelegate.brightness != brightness ||
        oldDelegate.rule != rule ||
        oldDelegate.marginRule != marginRule ||
        oldDelegate.paintBackground != paintBackground ||
        oldDelegate.paintInk != paintInk;
  }
}
