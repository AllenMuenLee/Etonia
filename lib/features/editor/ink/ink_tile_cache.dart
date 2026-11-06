import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'stroke.dart';
import 'stroke_spatial_index.dart';

class InkTileCache extends ChangeNotifier {
  InkTileCache({InkTileScheduler? scheduler})
    : _scheduler = scheduler ?? _sharedScheduler {
    _all.add(this);
  }

  static const bool profileEveryZoomFrame = bool.fromEnvironment(
    'INK_PROFILE_EVERY_ZOOM_FRAME',
  );
  static const int tilePixels = 512;
  static const double tileUnits = 256;
  static const int minPoints = int.fromEnvironment(
    'INK_TILE_MIN_POINTS',
    defaultValue: 12000,
  );
  static const int maxTiles = 96;
  static const int maxBytes = maxTiles * tilePixels * tilePixels * 4;
  static const int _gutter = 1;
  static final InkTileScheduler _sharedScheduler = InkTileScheduler();
  static final Set<InkTileCache> _all = <InkTileCache>{};
  static int _clock = 0;

  final InkTileScheduler _scheduler;
  final Map<(int, int), _Tile> _tiles = <(int, int), _Tile>{};
  Brightness? _brightness;
  StrokeSpatialIndex? _index;
  double? _scale;
  bool _disposed = false;
  bool _interacting = false;
  ValueListenable<double>? _watchedScale;
  double _watchedPixelRatio = 1;
  int? _watchedLevel;

  void watchScale(ValueListenable<double>? scale, double pixelRatio) {
    if (identical(scale, _watchedScale) && pixelRatio == _watchedPixelRatio) {
      return;
    }
    _watchedScale?.removeListener(_scaleChanged);
    _watchedScale = scale;
    _watchedPixelRatio = pixelRatio;
    _watchedLevel = scale == null ? null : _level(scale.value * pixelRatio);
    scale?.addListener(_scaleChanged);
  }

  void _scaleChanged() {
    final double? scale = _watchedScale?.value;
    if (_disposed || scale == null || !scale.isFinite || scale <= 0) return;
    final int next = _level(scale * _watchedPixelRatio);
    if (next == _watchedLevel && !profileEveryZoomFrame) return;
    _watchedLevel = next;
    notifyListeners();
  }

  int get imageCount => _tiles.values.fold<int>(
    0,
    (int total, _Tile tile) => total + tile.images.length,
  );
  int get memoryBytes => _tiles.values.fold<int>(
    0,
    (int total, _Tile tile) =>
        total +
        tile.images.values.fold<int>(
          0,
          (int sum, _TileImage image) => sum + image.bytes,
        ),
  );
  static int get totalBytes => _all.fold<int>(
    0,
    (int total, InkTileCache cache) => total + cache.memoryBytes,
  );
  @visibleForTesting
  int rasterized = 0;
  int _fallbackStrokes = 0;
  static Map<String, int> get renderingStats => <String, int>{
    'tile_images': _all.fold<int>(0, (sum, cache) => sum + cache.imageCount),
    'tile_bytes': totalBytes,
    'tile_rasters': _all.fold<int>(0, (sum, cache) => sum + cache.rasterized),
    'tile_fallback_strokes': _all.fold<int>(
      0,
      (sum, cache) => sum + cache._fallbackStrokes,
    ),
    'tile_pending_jobs': _sharedScheduler.pendingJobs,
    'tile_record_slices': _sharedScheduler.slices,
  };
  @visibleForTesting
  double? get scale => _scale;
  @visibleForTesting
  Future<void> get whenIdle => _scheduler.whenIdle;

  static bool worthwhile(List<Stroke> strokes) {
    int points = 0;
    for (final Stroke stroke in strokes) {
      points += stroke.points.length;
      if (points >= minPoints) return true;
    }
    return false;
  }

  static int _level(double scale) =>
      (math.log(scale) / math.ln2).ceil().clamp(-3, 3);
  static double _resolution(int level) => math.pow(2, level).toDouble();

  void paint(
    Canvas canvas, {
    required Rect area,
    required double pixelsPerUnit,
    required Brightness brightness,
    required bool holdScale,
    required List<Stroke> strokes,
    required StrokeSpatialIndex index,
    required bool Function(int index, Stroke stroke) include,
    required bool includesAll,
    required void Function(Canvas canvas, Stroke stroke) paintStroke,
    Rect? pageBounds,
    Rect? focusArea,
  }) {
    assert(!_disposed);
    assert(pixelsPerUnit > 0 && pixelsPerUnit.isFinite);
    _interacting = holdScale;
    if (area.isEmpty || !area.isFinite) {
      for (final _Tile tile in _tiles.values) {
        _scheduler._cancel(tile);
      }
      return;
    }
    if (_brightness != brightness) {
      _clear();
      _brightness = brightness;
    }
    if (!identical(index, _index)) {
      _index = index;
      for (final _Tile tile in _tiles.values) {
        tile.checkedAt = -1;
      }
    }
    final int level = _level(pixelsPerUnit);
    _scale = _resolution(level);
    final int now = ++_clock;
    final Rect focus = (focusArea ?? area).intersect(area);
    Rect prefetch = area.inflate(tileUnits);
    if (pageBounds != null) prefetch = prefetch.intersect(pageBounds);
    final List<_Tile> requested = <_Tile>[];
    final Set<(int, int)> needed = <(int, int)>{};
    for (
      int y = (prefetch.top / tileUnits).floor();
      y < (prefetch.bottom / tileUnits).ceil();
      y++
    ) {
      for (
        int x = (prefetch.left / tileUnits).floor();
        x < (prefetch.right / tileUnits).ceil();
        x++
      ) {
        final (int, int) key = (x, y);
        needed.add(key);
        final _Tile tile = _tiles.putIfAbsent(key, () => _Tile(x, y));
        tile.used = now;
        final Rect reach = tile.rect.inflate(8);
        if (!includesAll ||
            tile.checkedAt < 0 ||
            index.changedSince(tile.checkedAt, reach)) {
          final List<Stroke> wanted = <Stroke>[];
          for (final int position in index.query(reach)) {
            final Stroke stroke = strokes[position];
            if (stroke.bounds.overlaps(reach) && include(position, stroke)) {
              wanted.add(stroke);
            }
          }
          if (!_same(tile.strokes, wanted)) {
            _scheduler._cancel(tile);
            tile.invalidate();
            tile.strokes = wanted;
          }
          tile.checkedAt = includesAll ? index.version : -1;
        }
        requested.add(tile);
      }
    }
    // Missing visible content precedes sharper detail and offscreen warming.
    requested.sort((_Tile a, _Tile b) {
      int priority(_Tile tile) => tile.rect.overlaps(focus) ? 0 : 1;
      final int order = priority(a).compareTo(priority(b));
      if (order != 0) return order;
      return (a.rect.center - focus.center).distanceSquared.compareTo(
        (b.rect.center - focus.center).distanceSquared,
      );
    });
    for (final _Tile tile in requested) {
      if (tile.strokes.isEmpty) continue;
      final bool shown = tile.rect.overlaps(area);
      final int? fallback = tile.closestLevel(level);
      if (shown) {
        if (fallback == null) {
          _paintDirectly(canvas, tile, paintStroke);
        } else {
          final _TileImage cached = tile.images[fallback]!;
          cached.used = now;
          final double resolution = _resolution(fallback);
          final double extent = tileUnits * resolution;
          canvas.drawImageRect(
            cached.image,
            Rect.fromLTWH(_gutter + 0.0, _gutter + 0.0, extent, extent),
            tile.rect,
            Paint()
              ..isAntiAlias = false
              ..filterQuality = !holdScale && resolution == pixelsPerUnit
                  ? FilterQuality.none
                  : FilterQuality.low,
          );
        }
      }
      // Cold tiles get a small first image; detail follows without blocking
      // the gesture. Quantized levels survive fractional scale changes.
      final int target = fallback == null ? math.min(level, 0) : level;
      if (!tile.images.containsKey(target) && !tile.failed.contains(target)) {
        _scheduler._request(
          this,
          tile,
          target,
          priority: shown ? (fallback == null ? 0 : (holdScale ? 2 : 1)) : 3,
          paintStroke: paintStroke,
        );
      }
      for (final _RasterJob job in tile.jobs.values.toList()) {
        if (job.level != target) _scheduler._cancelJob(job);
      }
    }
    for (final MapEntry<(int, int), _Tile> entry in _tiles.entries.toList()) {
      if (!needed.contains(entry.key)) {
        _scheduler._cancel(entry.value);
        if (entry.value.images.isEmpty || _tiles.length > 256) {
          _tiles.remove(entry.key)!.invalidate();
        }
      }
    }
    _scheduler._schedule();
  }

  void _paintDirectly(
    Canvas canvas,
    _Tile tile,
    void Function(Canvas canvas, Stroke stroke) paintStroke,
  ) {
    if (tile.fallback == null) {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas recording = Canvas(recorder);
      for (final Stroke stroke in tile.strokes) {
        _fallbackStrokes++;
        paintStroke(recording, stroke);
      }
      tile.fallback = recorder.endRecording();
    }
    canvas
      ..save()
      ..clipRect(tile.rect, doAntiAlias: false)
      ..drawPicture(tile.fallback!)
      ..restore();
  }

  static bool _same(List<Stroke> a, List<Stroke> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  bool _accepts(_RasterJob job) =>
      !_disposed &&
      !job.cancelled &&
      identical(_tiles[(job.tile.x, job.tile.y)], job.tile) &&
      job.tile.revision == job.revision;

  void _accept(_RasterJob job, ui.Image image) {
    if (!_accepts(job)) {
      image.dispose();
      return;
    }
    final int bytes = image.width * image.height * 4;
    _makeRoom(bytes);
    job.tile.images.remove(job.level)?.image.dispose();
    job.tile.images[job.level] = _TileImage(image, ++_clock);
    job.tile.fallback?.dispose();
    job.tile.fallback = null;
    rasterized++;
    notifyListeners();
  }

  static void _makeRoom(int bytes) {
    while (totalBytes + bytes > maxBytes) {
      _Tile? oldestTile;
      int? oldestLevel;
      int oldestUse = 0x7fffffffffffffff;
      for (final InkTileCache cache in _all) {
        for (final _Tile tile in cache._tiles.values) {
          for (final MapEntry<int, _TileImage> entry in tile.images.entries) {
            if (entry.value.used < oldestUse) {
              oldestUse = entry.value.used;
              oldestTile = tile;
              oldestLevel = entry.key;
            }
          }
        }
      }
      if (oldestTile == null) break;
      oldestTile.images.remove(oldestLevel)!.image.dispose();
    }
  }

  void _clear() {
    for (final _Tile tile in _tiles.values) {
      _scheduler._cancel(tile);
      tile.invalidate();
    }
    _tiles.clear();
    _scale = null;
  }

  void clear() {
    if (_disposed) return;
    _clear();
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _watchedScale?.removeListener(_scaleChanged);
    _watchedScale = null;
    _all.remove(this);
    _clear();
    super.dispose();
  }
}

class InkTileScheduler {
  InkTileScheduler({
    void Function(VoidCallback)? scheduleWork,
    Future<ui.Image> Function(ui.Picture, int, int)? rasterize,
  }) : _scheduleWork = scheduleWork ?? _afterFrame,
       _rasterizeImage = rasterize ?? _toImage;

  static Future<ui.Image> _toImage(ui.Picture picture, int width, int height) =>
      picture.toImage(width, height);
  final Future<ui.Image> Function(ui.Picture, int, int) _rasterizeImage;

  static const int maxStrokesPerSlice = 64;
  static const Duration recordingBudget = Duration(milliseconds: 2);
  final void Function(VoidCallback) _scheduleWork;
  final List<_RasterJob> _queue = <_RasterJob>[];
  _RasterJob? _recording;
  bool _scheduled = false;
  bool _rasterizing = false;
  Completer<void>? _idle;
  int _sequence = 0;

  Future<void> get whenIdle => _idle?.future ?? Future<void>.value();
  @visibleForTesting
  int slices = 0;
  @visibleForTesting
  int largestSlice = 0;
  @visibleForTesting
  int get pendingJobs => _queue.length + (_recording == null ? 0 : 1);

  static void _afterFrame(VoidCallback work) {
    SchedulerBinding.instance.addPostFrameCallback((_) => work());
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _request(
    InkTileCache owner,
    _Tile tile,
    int level, {
    required int priority,
    required void Function(Canvas canvas, Stroke stroke) paintStroke,
  }) {
    final _RasterJob? existing = tile.jobs[level];
    if (existing != null) {
      existing.priority = priority;
      return;
    }
    final _RasterJob job = _RasterJob(
      owner,
      tile,
      level,
      priority,
      ++_sequence,
      paintStroke,
    );
    tile.jobs[level] = job;
    _queue.add(job);
    _idle ??= Completer<void>();
    _schedule();
  }

  void _cancel(_Tile tile) {
    for (final _RasterJob job in tile.jobs.values.toList()) {
      _cancelJob(job);
    }
  }

  void _cancelJob(_RasterJob job) {
    job.cancelled = true;
    if (identical(job.tile.jobs[job.level], job)) {
      job.tile.jobs.remove(job.level);
    }
    _queue.remove(job);
    if (!(_rasterizing && identical(_recording, job))) {
      job.disposeRecording();
      if (identical(_recording, job)) _recording = null;
    }
    _completeIfIdle();
  }

  bool _runnable(_RasterJob job) =>
      InkTileCache.profileEveryZoomFrame ||
      !job.owner._interacting ||
      job.priority == 0;

  void _schedule() {
    if (_scheduled || _rasterizing) return;
    if ((_recording == null || !_runnable(_recording!)) &&
        !_queue.any(_runnable)) {
      if (_recording != null) {
        _queue.add(_recording!);
        _recording = null;
      }
      _completeIfIdle();
      return;
    }
    _idle ??= Completer<void>();
    _scheduled = true;
    _scheduleWork(() {
      _scheduled = false;
      _runSlice();
    });
  }

  void _runSlice() {
    if (_rasterizing) return;
    if (_recording != null &&
        (!_runnable(_recording!) ||
            _queue.any(
              (_RasterJob waiting) =>
                  _runnable(waiting) && waiting.priority < _recording!.priority,
            ))) {
      _queue.add(_recording!);
      _recording = null;
    }
    if (_recording == null && _queue.isNotEmpty) {
      _queue.sort((_RasterJob a, _RasterJob b) {
        final int order = a.priority.compareTo(b.priority);
        return order == 0 ? a.sequence.compareTo(b.sequence) : order;
      });
      final int next = _queue.indexWhere(_runnable);
      if (next >= 0) _recording = _queue.removeAt(next);
    }
    final _RasterJob? job = _recording;
    if (job == null) {
      _completeIfIdle();
      return;
    }
    if (!job.owner._accepts(job)) {
      _cancelJob(job);
      _schedule();
      return;
    }
    final Stopwatch watch = Stopwatch()..start();
    int count = 0;
    job.begin();
    try {
      if (job.cursor == 0 && job.tile.fallback != null) {
        job.canvas!.drawPicture(job.tile.fallback!);
        job.cursor = job.tile.strokes.length;
        count = 1;
      }
      while (job.cursor < job.tile.strokes.length &&
          count < maxStrokesPerSlice &&
          watch.elapsed < recordingBudget) {
        job.paintStroke(job.canvas!, job.tile.strokes[job.cursor++]);
        count++;
      }
    } catch (error, stack) {
      _failed(job, error, stack);
      return;
    }
    slices++;
    largestSlice = math.max(largestSlice, count);
    if (job.cursor < job.tile.strokes.length) {
      _schedule();
      return;
    }
    _rasterizing = true;
    unawaited(_rasterize(job));
  }

  Future<void> _rasterize(_RasterJob job) async {
    final ui.Picture picture = job.recorder!.endRecording();
    job.recorder = null;
    job.canvas = null;
    try {
      final int size =
          (InkTileCache.tileUnits * InkTileCache._resolution(job.level))
              .round() +
          InkTileCache._gutter * 2;
      final ui.Image image = await _rasterizeImage(picture, size, size);
      job.owner._accept(job, image);
    } catch (error, stack) {
      _failed(job, error, stack);
    } finally {
      picture.dispose();
      if (identical(job.tile.jobs[job.level], job)) {
        job.tile.jobs.remove(job.level);
      }
      _recording = null;
      _rasterizing = false;
      _completeIfIdle();
      _schedule();
    }
  }

  void _failed(_RasterJob job, Object error, StackTrace stack) {
    if (job.owner._accepts(job)) job.tile.failed.add(job.level);
    _cancelJob(job);
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'ink tile rendering',
      ),
    );
    _schedule();
  }

  void _completeIfIdle() {
    if (!_queue.any(_runnable) && _recording == null && !_rasterizing) {
      _idle?.complete();
      _idle = null;
    }
  }
}

class _Tile {
  _Tile(this.x, this.y);
  final int x;
  final int y;
  Rect get rect => Rect.fromLTWH(
    x * InkTileCache.tileUnits,
    y * InkTileCache.tileUnits,
    InkTileCache.tileUnits,
    InkTileCache.tileUnits,
  );
  List<Stroke> strokes = const <Stroke>[];
  ui.Picture? fallback;
  final Map<int, _TileImage> images = <int, _TileImage>{};
  final Map<int, _RasterJob> jobs = <int, _RasterJob>{};
  final Set<int> failed = <int>{};
  int checkedAt = -1;
  int revision = 0;
  int used = 0;

  int? closestLevel(int level) {
    int? best;
    for (final int candidate in images.keys) {
      if (best == null ||
          (candidate - level).abs() < (best - level).abs() ||
          ((candidate - level).abs() == (best - level).abs() &&
              candidate > best)) {
        best = candidate;
      }
    }
    return best;
  }

  void invalidate() {
    revision++;
    fallback?.dispose();
    fallback = null;
    for (final _TileImage image in images.values) {
      image.image.dispose();
    }
    images.clear();
    failed.clear();
  }
}

class _TileImage {
  _TileImage(this.image, this.used);
  final ui.Image image;
  int used;
  int get bytes => image.width * image.height * 4;
}

class _RasterJob {
  _RasterJob(
    this.owner,
    this.tile,
    this.level,
    this.priority,
    this.sequence,
    this.paintStroke,
  ) : revision = tile.revision;
  final InkTileCache owner;
  final _Tile tile;
  final int level;
  int priority;
  final int sequence;
  final int revision;
  final void Function(Canvas canvas, Stroke stroke) paintStroke;
  bool cancelled = false;
  int cursor = 0;
  ui.PictureRecorder? recorder;
  Canvas? canvas;

  void begin() {
    if (recorder != null) return;
    recorder = ui.PictureRecorder();
    canvas = Canvas(recorder!)
      ..translate(
        InkTileCache._gutter - tile.rect.left * InkTileCache._resolution(level),
        InkTileCache._gutter - tile.rect.top * InkTileCache._resolution(level),
      )
      ..scale(InkTileCache._resolution(level));
  }

  void disposeRecording() {
    recorder?.endRecording().dispose();
    recorder = null;
    canvas = null;
  }
}
