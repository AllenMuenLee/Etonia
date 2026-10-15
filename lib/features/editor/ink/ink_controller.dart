import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' show Rect, Size;

import 'package:flutter/foundation.dart';

import 'erase_geometry.dart';
import 'eraser_settings.dart';
import 'ink_sample.dart';
import 'ink_notation.dart';
import 'ink_palette.dart';
import 'ink_selection.dart';
import 'notation_playback.dart';
import 'selection_config.dart';
import 'selection_geometry.dart';
import 'selection_transform.dart';
import 'shape_recognizer.dart';
import 'smoothing_config.dart';
import 'stroke.dart';
import '../document_io/document_models.dart';

/// In-memory ink for one editor session.
///
/// The active stroke, the completed strokes, the eraser, and the selection
/// notify separately so that a pointer move repaints only the layer it
/// changed. One pointer owns the page at a time, and it is doing exactly one
/// of writing, erasing, drawing a lasso, or transforming the selection.
///
/// The selection is kept apart from the document: it is a list of stroke
/// indices, a snapshot of those strokes, and a frame. Every method that
/// changes the stroke collection updates or clears it in the same step. A
/// committed transform, a cut, and a paste each replace the collection once
/// and notify [completedStrokesListenable] once, which is the before/after
/// pair the undo history records.
///
/// Every committed change (a stroke, a shape, an erase gesture, a transform,
/// a cut, a paste, an inserted image, an AI notation) is one step of
/// history. [undo] and [redo] move between those steps; the in-progress
/// gesture, the selection, and the clipboard are never part of it.
class InkController {
  InkController({
    this.smoothing = const SmoothingConfig(),
    this.selectionConfig = const SelectionConfig(),
    this.historyLimit = 100,
    Iterable<Stroke> strokes = const <Stroke>[],
    Iterable<NoteImageElement> images = const <NoteImageElement>[],
  }) : assert(historyLimit >= 0),
       _strokes = List<Stroke>.of(strokes),
       _images = List<NoteImageElement>.of(images) {
    _committed = _snapshot();
  }

  final SmoothingConfig smoothing;
  final SelectionConfig selectionConfig;

  /// How many steps [undo] can go back. The oldest are forgotten first.
  final int historyLimit;

  /// The document as of the last committed change: what an undo returns
  /// to once a gesture has changed [_strokes] in place.
  late _InkSnapshot _committed;
  final List<_InkSnapshot> _undoStack = <_InkSnapshot>[];
  final List<_InkSnapshot> _redoStack = <_InkSnapshot>[];

  final _Notifier _activeChanged = _Notifier();
  final _Notifier _completedChanged = _Notifier();
  final _Notifier _eraserChanged = _Notifier();
  final _Notifier _selectionChanged = _Notifier();
  final _Notifier _revisionChanged = _Notifier();
  final _Notifier _playbackChanged = _Notifier();
  final _Notifier _playbackFrame = _Notifier();
  List<Stroke> _strokes;
  List<NoteImageElement> _images;
  int _documentRevision = 0;
  ActiveStroke? _active;
  int? _activePointer;
  ShapeAdjustGesture? _shapeAdjust;
  EraseGesture? _erase;
  int _eraseGestureCount = 0;
  InkSelection? _selection;
  LassoGesture? _lasso;
  SelectionTransformGesture? _transform;
  InkClipboard? _clipboard;
  int _pasteCount = 0;
  final List<NotationPlayback> _playbacks = <NotationPlayback>[];
  Duration _notationClock = Duration.zero;
  bool _disposed = false;

  Listenable get activeStrokeListenable => _activeChanged;

  /// Fires when the document's strokes change, and once whenever the set of
  /// selected strokes changes: selected strokes are painted by the selection
  /// layer, so the completed layer has to stop or start painting them. It
  /// does not fire for lasso moves or transform previews.
  Listenable get completedStrokesListenable => _completedChanged;

  /// Fires when an erase gesture starts, moves, or ends.
  Listenable get eraserListenable => _eraserChanged;

  List<Stroke> get strokes => UnmodifiableListView<Stroke>(_strokes);
  List<NoteImageElement> get images =>
      UnmodifiableListView<NoteImageElement>(_images);

  ActiveStroke? get activeStroke => _active;

  /// The shape a held stroke became, while its pointer scales and turns it.
  ShapeAdjustGesture? get activeShape => _shapeAdjust;

  /// The erase gesture in progress, if any.
  EraseGesture? get activeErase => _erase;

  /// Fires when the lasso moves, a transform preview moves, the selection
  /// changes, or the clipboard is filled.
  Listenable get selectionListenable => _selectionChanged;

  /// The selected strokes, if any.
  InkSelection? get selection => _selection;

  /// The lasso being drawn, if any.
  LassoGesture? get activeLasso => _lasso;

  /// The move, scale, or rotation in progress, if any.
  SelectionTransformGesture? get activeTransform => _transform;

  /// What Paste would paste, if anything.
  InkClipboard? get clipboard => _clipboard;

  bool get canPaste => _clipboard != null;

  int get documentRevision => _documentRevision;

  Listenable get documentRevisionListenable => _revisionChanged;

  bool get isBusy => _isBusy;

  /// The AI notations being drawn over time, oldest first. Their strokes
  /// are already in [strokes]; while they play, they are painted by the
  /// playback layer instead of the finished-ink layer.
  List<NotationPlayback> get notationPlaybacks {
    return UnmodifiableListView<NotationPlayback>(_playbacks);
  }

  /// The most recently added of [notationPlaybacks], if any.
  NotationPlayback? get notationPlayback {
    return _playbacks.isEmpty ? null : _playbacks.last;
  }

  /// Whether [stroke] is painted by the playback layer.
  bool isPlayingStroke(Stroke stroke) {
    for (final NotationPlayback playback in _playbacks) {
      if (playback.owns(stroke)) {
        return true;
      }
    }
    return false;
  }

  /// Fires when a playback starts or finishes, or lets go of a stroke: when
  /// strokes move between the playback layer and the finished-ink layer.
  /// Never a document change.
  Listenable get notationPlaybackListenable => _playbackChanged;

  /// Fires each time the playbacks' clock moves on.
  Listenable get notationFrameListenable => _playbackFrame;

  /// The clock every playback is timed by: how long playbacks have been
  /// running, in total. Only moves forward.
  Duration get notationClock => _notationClock;

  /// Moves the playbacks' clock on to [clock]. Each playback is drawn from
  /// the moment it was added, wraps to its first frame at its duration, and
  /// repeats until [finishNotationPlayback]. Presentation only: the
  /// document, its revision, and the selection are untouched.
  void advanceNotationPlayback(Duration clock) {
    if (_disposed || clock <= _notationClock) {
      return;
    }
    _notationClock = clock;
    if (_playbacks.isEmpty) {
      return;
    }
    for (final NotationPlayback playback in _playbacks) {
      playback.advanceClockTo(clock);
    }
    _playbackFrame.notify();
  }

  /// Shows [playback], or every playback when it is null, whole, as
  /// ordinary finished ink, at once. Returns false when none of them was
  /// playing. Presentation only, like [advanceNotationPlayback].
  bool finishNotationPlayback([NotationPlayback? playback]) {
    final List<NotationPlayback> finishing = playback == null
        ? List<NotationPlayback>.of(_playbacks)
        : <NotationPlayback>[if (_playbacks.contains(playback)) playback];
    if (finishing.isEmpty) {
      return false;
    }
    for (final NotationPlayback finished in finishing) {
      _playbacks.remove(finished);
      finished.markFinished();
    }
    if (!_disposed) {
      _playbackChanged.notify();
    }
    return true;
  }

  /// Plays a notation saved with the note again: [strokes], already in
  /// [strokes] and in the order they were drawn, are drawn at [timesMs]
  /// over [duration], again and again, as when the notation was added.
  /// Presentation only. Returns false, and changes nothing, when a stroke
  /// is not on the page or the times do not fit it.
  bool restoreNotationPlayback({
    required List<Stroke> strokes,
    required List<List<double>> timesMs,
    required Duration duration,
    required Size surfaceSize,
  }) {
    if (_disposed ||
        strokes.isEmpty ||
        strokes.length != timesMs.length ||
        duration <= Duration.zero) {
      return false;
    }
    final Set<Stroke> present = HashSet<Stroke>.identity()..addAll(_strokes);
    final double durationMs =
        duration.inMicroseconds / Duration.microsecondsPerMillisecond;
    for (int i = 0; i < strokes.length; i++) {
      final List<double> times = timesMs[i];
      if (!present.contains(strokes[i]) ||
          times.length != strokes[i].points.length ||
          !_validTimes(
            GeneratedInkTrace(
              style: strokes[i].style,
              points: strokes[i].points,
              timesMs: times,
            ),
            durationMs,
          )) {
        return false;
      }
    }
    _playbacks.add(
      NotationPlayback(
        strokes,
        timesMs: timesMs,
        duration: duration,
        surfaceSize: surfaceSize,
        startedAt: _notationClock,
      ),
    );
    _playbackChanged.notify();
    _completedChanged.notify();
    return true;
  }

  /// Keeps the playbacks in step with [_strokes] after it changed: a stroke
  /// in [replaced] is followed to its replacement, any other that left the
  /// document is let go, and a playback left with nothing is finished.
  void _syncPlaybacks([Map<Stroke, Stroke>? replaced]) {
    if (_playbacks.isEmpty) {
      return;
    }
    final Set<Stroke> present = HashSet<Stroke>.identity()..addAll(_strokes);
    bool changed = false;
    for (final NotationPlayback playback in List<NotationPlayback>.of(
      _playbacks,
    )) {
      for (final Stroke stroke in List<Stroke>.of(playback.strokes)) {
        if (playback.owns(stroke) && !present.contains(stroke)) {
          playback.replace(stroke, replaced?[stroke]);
          changed = true;
        }
      }
      if (playback.isEmpty) {
        _playbacks.remove(playback);
        playback.markFinished();
      }
    }
    if (changed) {
      _playbackChanged.notify();
    }
  }

  /// The pointer that owns the page, if any.
  int? get activePointer {
    return _activePointer ??
        _shapeAdjust?.pointer ??
        _erase?.pointer ??
        selectionPointer;
  }

  /// The pointer drawing a lasso or transforming the selection, if any.
  int? get selectionPointer => _lasso?.pointer ?? _transform?.pointer;

  bool get _isBusy {
    return _active != null ||
        _shapeAdjust != null ||
        _erase != null ||
        _lasso != null ||
        _transform != null;
  }

  /// Whether [undo] would change anything.
  bool get canUndo => _undoStack.isNotEmpty;

  /// Whether [redo] would change anything.
  bool get canRedo => _redoStack.isNotEmpty;

  /// Records one committed change as a step of history, which also drops
  /// anything that could have been redone.
  void _documentChanged() {
    if (historyLimit > 0) {
      _undoStack.add(_committed);
      if (_undoStack.length > historyLimit) {
        _undoStack.removeAt(0);
      }
    }
    _redoStack.clear();
    _committed = _snapshot();
    _revisionBumped();
  }

  void _revisionBumped() {
    _documentRevision++;
    _revisionChanged.notify();
  }

  _InkSnapshot _snapshot() {
    return _InkSnapshot(
      List<Stroke>.unmodifiable(_strokes),
      List<NoteImageElement>.unmodifiable(_images),
    );
  }

  /// Puts the document back as it was before the last committed change.
  /// Returns false, and changes nothing, while a gesture is in progress or
  /// there is nothing to undo. The selection is dropped.
  bool undo() => _travel(from: _undoStack, to: _redoStack);

  /// Applies again the change [undo] last took back. Returns false, and
  /// changes nothing, while a gesture is in progress or there is nothing to
  /// redo. The selection is dropped.
  bool redo() => _travel(from: _redoStack, to: _undoStack);

  bool _travel({
    required List<_InkSnapshot> from,
    required List<_InkSnapshot> to,
  }) {
    if (_disposed || _isBusy || from.isEmpty) {
      return false;
    }
    to.add(_committed);
    _committed = from.removeLast();
    _strokes = List<Stroke>.of(_committed.strokes);
    _images = List<NoteImageElement>.of(_committed.images);
    _selection = null;
    // Strokes that came back are ordinary ink; those that left are let go.
    _syncPlaybacks();
    _revisionBumped();
    _completedChanged.notify();
    _selectionChanged.notify();
    return true;
  }

  /// Starts a stroke for [pointer]. Returns false, and changes nothing, when
  /// another pointer already owns the page, or the sample is unusable.
  bool startStroke({
    required int pointer,
    required RawInkSample sample,
    required StrokeStyle style,
  }) {
    if (_isBusy || !sample.position.isFinite) {
      return false;
    }
    _active = ActiveStroke(style: style, first: sample, config: smoothing);
    _activePointer = pointer;
    _activeChanged.notify();
    return true;
  }

  void addSamples(int pointer, Iterable<RawInkSample> samples) {
    final ActiveStroke? active = _active;
    if (active == null || pointer != _activePointer) {
      return;
    }
    bool changed = false;
    for (final RawInkSample sample in samples) {
      changed = active.add(sample) || changed;
    }
    if (changed) {
      _activeChanged.notify();
    }
  }

  /// Completes the stroke owned by [pointer], after processing any
  /// [finalSamples] delivered with the pointer-up.
  void endStroke(
    int pointer, [
    Iterable<RawInkSample> finalSamples = const <RawInkSample>[],
  ]) {
    final ActiveStroke? active = _active;
    if (active == null || pointer != _activePointer) {
      return;
    }
    finalSamples.forEach(active.add);
    finalizeActiveStroke();
  }

  /// A cancelled stroke keeps the ink drawn so far.
  void cancelStroke(int pointer) {
    if (pointer == _activePointer) {
      finalizeActiveStroke();
    }
  }

  /// Commits the active stroke, if any. Later events from its pointer are
  /// ignored.
  void finalizeActiveStroke() {
    final ActiveStroke? active = _active;
    if (active == null) {
      return;
    }
    _strokes.add(active.finish());
    _documentChanged();
    _active = null;
    _activePointer = null;
    _completedChanged.notify();
    _activeChanged.notify();
  }

  /// Turns the stroke owned by [pointer] into the shape it was meant to be,
  /// when [recognizer] recognizes one, and returns that shape.
  ///
  /// The pointer then adjusts the shape instead of drawing: see
  /// [adjustShape]. The shape is shown as [activeShape] and committed in
  /// place of the stroke, with the stroke's style, when the pointer lifts,
  /// as one change: the freehand ink never reaches [strokes].
  ///
  /// Returns null, and changes nothing, when [pointer] has no stroke, the
  /// stroke is a dot, or no shape is recognized; the stroke goes on.
  RecognizedShape? convertActiveStrokeToShape(
    int pointer, {
    ShapeRecognizer recognizer = const ShapeRecognizer(),
  }) {
    final ActiveStroke? active = _active;
    if (active == null || pointer != _activePointer || active.isDot) {
      return null;
    }
    final InkVector pen = active.lastRawPosition;
    final RecognizedShape? shape = recognizer.recognize(<InkVector>[
      ...active.points,
      // The filter trails the pen; the shape should end where the pen is.
      if (pen != active.lastPoint) pen,
    ]);
    if (shape == null || !_withinLimits(shape.points)) {
      return null;
    }
    _shapeAdjust = ShapeAdjustGesture._(
      pointer: pointer,
      shape: shape,
      style: active.style,
      pivot: ShapeAdjustGesture.pivotOf(shape),
      grab: pen,
    );
    _active = null;
    _activePointer = null;
    _activeChanged.notify();
    return shape;
  }

  /// Scales and turns the shape being adjusted by [pointer] about its pivot
  /// (a closed shape's center, an open shape's start) so that the point the
  /// pen held follows the pen to [position]. Worked out from where the
  /// adjustment began, never from the previous move. Turns of a few degrees
  /// and scales within a few percent of 1 are ignored, so a shape that
  /// snapped straight stays straight while the pen settles.
  void adjustShape(int pointer, InkVector position) {
    final ShapeAdjustGesture? gesture = _shapeAdjust;
    if (gesture == null || pointer != gesture.pointer || !position.isFinite) {
      return;
    }
    final InkVector from = gesture.grab - gesture.pivot;
    final InkVector to = position - gesture.pivot;
    if (from.length < ShapeAdjustGesture.minGrabDistance ||
        to.length < ShapeAdjustGesture.minGrabDistance) {
      return;
    }
    double scale = (to.length / from.length).clamp(
      ShapeAdjustGesture.minScale,
      ShapeAdjustGesture.maxScale,
    );
    double angle = math.atan2(
      from.x * to.y - from.y * to.x,
      from.x * to.x + from.y * to.y,
    );
    if (angle.abs() < ShapeAdjustGesture.angleDeadZone) {
      angle = 0;
    }
    if ((scale - 1).abs() < ShapeAdjustGesture.scaleDeadZone) {
      scale = 1;
    }
    if (scale == gesture._scale && angle == gesture._angle) {
      return;
    }
    final double c = math.cos(angle) * scale;
    final double sn = math.sin(angle) * scale;
    final InkVector pivot = gesture.pivot;
    final List<InkVector> points = <InkVector>[
      for (final InkVector p in gesture.shape.points)
        InkVector(
          pivot.x + c * (p.x - pivot.x) - sn * (p.y - pivot.y),
          pivot.y + sn * (p.x - pivot.x) + c * (p.y - pivot.y),
        ),
    ];
    if (!_withinLimits(points)) {
      return;
    }
    gesture
      .._scale = scale
      .._angle = angle
      .._preview = Stroke.fromPoints(style: gesture.style, points: points);
    _activeChanged.notify();
  }

  /// Commits the shape adjusted by [pointer], after moving it to any
  /// [finalPosition] delivered with the pointer-up.
  void endShapeAdjust(int pointer, [InkVector? finalPosition]) {
    if (pointer != _shapeAdjust?.pointer) {
      return;
    }
    if (finalPosition != null) {
      adjustShape(pointer, finalPosition);
    }
    finalizeShapeAdjust();
  }

  /// Commits the shape being adjusted, as it is now, if there is one.
  void finalizeShapeAdjust() {
    final ShapeAdjustGesture? gesture = _shapeAdjust;
    if (gesture == null) {
      return;
    }
    _shapeAdjust = null;
    _strokes.add(gesture.preview);
    _documentChanged();
    _completedChanged.notify();
    _activeChanged.notify();
  }

  bool _withinLimits(List<InkVector> points) {
    final double limit = selectionConfig.maxCoordinate;
    for (final InkVector point in points) {
      if (!point.isFinite || point.x.abs() > limit || point.y.abs() > limit) {
        return false;
      }
    }
    return true;
  }

  /// Drops the stroke, or the shape being adjusted, owned by [pointer]
  /// without committing it. Used when what began as a stroke turns out to
  /// be a two-finger scroll.
  void discardStroke(int pointer) {
    if (pointer == _shapeAdjust?.pointer) {
      _shapeAdjust = null;
      _activeChanged.notify();
      return;
    }
    if (_active == null || pointer != _activePointer) {
      return;
    }
    _active = null;
    _activePointer = null;
    _activeChanged.notify();
  }

  /// Starts an erase gesture for [pointer] and erases under [position].
  /// Returns false, and changes nothing, when another pointer already owns
  /// the page, or the position is unusable.
  ///
  /// [settings] are captured here; later changes apply to the next gesture.
  /// Erasing moves and replaces strokes, so it drops the selection first.
  bool startErase({
    required int pointer,
    required InkVector position,
    required EraserSettings settings,
    EraserConfig config = const EraserConfig(),
  }) {
    if (_isBusy || !position.isFinite) {
      return false;
    }
    clearSelection();
    final EraseGesture erase = EraseGesture._(
      position,
      id: ++_eraseGestureCount,
      pointer: pointer,
      mode: settings.mode,
      radius: settings.mode == EraserMode.area
          ? settings.size / 2
          : config.strokeHitRadius,
      minPieceLength: config.minPieceLength,
    );
    _erase = erase;
    _eraseAlong(erase, position, position);
    _eraserChanged.notify();
    return true;
  }

  /// Moves the eraser owned by [pointer] to [position], erasing everything
  /// it sweeps over on the way.
  void eraseTo(int pointer, InkVector position) {
    final EraseGesture? erase = _erase;
    if (erase == null ||
        pointer != erase.pointer ||
        !position.isFinite ||
        position == erase._position) {
      return;
    }
    final InkVector from = erase._position;
    erase._position = position;
    _eraseAlong(erase, from, position);
    _eraserChanged.notify();
  }

  /// Ends the erase gesture owned by [pointer], after erasing up to any
  /// [finalPosition] delivered with the pointer-up.
  void endErase(int pointer, [InkVector? finalPosition]) {
    if (pointer != _erase?.pointer) {
      return;
    }
    if (finalPosition != null) {
      eraseTo(pointer, finalPosition);
    }
    finalizeErase();
  }

  /// A cancelled erase gesture keeps what it has erased so far.
  void cancelErase(int pointer) {
    if (pointer == _erase?.pointer) {
      finalizeErase();
    }
  }

  /// Ends the erase gesture, if any. Later events from its pointer are
  /// ignored.
  void finalizeErase() {
    final EraseGesture? erase = _erase;
    if (erase == null) {
      return;
    }
    _erase = null;
    if (erase.changedInk) {
      _documentChanged();
    }
    _eraserChanged.notify();
  }

  /// Ends whichever gesture is in progress, keeping its result. Used when
  /// the layout or the tool changes mid-gesture.
  void finalizeActiveGesture() {
    finalizeActiveStroke();
    finalizeShapeAdjust();
    finalizeErase();
    finalizeSelectionGesture();
  }

  /// Starts whatever a pointer going down at [position] does with the Select
  /// tool: a rotation, a scale, or a move when it lands on the selection's
  /// frame, as decided by [SelectionFrame.hitTest], and a new lasso anywhere
  /// else. Returns false, and changes nothing, when another pointer already
  /// owns the page, or the position is unusable.
  bool beginSelectionGesture({
    required int pointer,
    required InkVector position,
  }) {
    if (_isBusy || !position.isFinite) {
      return false;
    }
    final InkSelection? current = _selection;
    final SelectionHit? hit = current?.includesPdf == true
        ? null
        : current?.frame.hitTest(
            position,
            handleHitRadius: selectionConfig.handleHitRadius,
            rotationHandleOffset: selectionConfig.rotationHandleOffset,
            tolerance: selectionConfig.geometryTolerance,
          );
    if (hit != null) {
      return beginTransform(pointer: pointer, position: position, hit: hit);
    }
    for (int i = _images.length - 1; i >= 0; i--) {
      if (_images[i].contains(
        position,
        tolerance: selectionConfig.geometryTolerance,
      )) {
        if (_setSelection(_selectionOf(const <int>[], <int>[i]))) {
          _completedChanged.notify();
        }
        _selectionChanged.notify();
        return beginTransform(
          pointer: pointer,
          position: position,
          hit: const SelectionHit.move(),
        );
      }
    }
    return beginLasso(pointer: pointer, position: position);
  }

  /// Moves the lasso or the transform owned by [pointer] to [position].
  void updateSelectionGesture(int pointer, InkVector position) {
    updateLasso(pointer, position);
    updateTransform(pointer, position);
  }

  /// Ends the lasso or the transform owned by [pointer], after moving it to
  /// any [finalPosition] delivered with the pointer-up.
  void endSelectionGesture(
    int pointer, [
    InkVector? finalPosition,
    Rect? selectablePdfBounds,
  ]) {
    endLasso(pointer, finalPosition, selectablePdfBounds);
    endTransform(pointer, finalPosition);
  }

  /// A cancelled lasso is dropped, leaving the selection as it was. A
  /// cancelled transform is committed where it had got to.
  void cancelSelectionGesture(int pointer) {
    cancelLasso(pointer);
    cancelTransform(pointer);
  }

  /// Ends the lasso or the transform in progress, if any, as a cancel would.
  /// Later events from its pointer are ignored.
  void finalizeSelectionGesture() {
    if (_lasso != null) {
      _lasso = null;
      _selectionChanged.notify();
    }
    _commitTransform();
  }

  /// Starts a lasso for [pointer] at [position]. The current selection stays
  /// until the lasso ends. Returns false, and changes nothing, when another
  /// pointer already owns the page, or the position is unusable.
  bool beginLasso({required int pointer, required InkVector position}) {
    if (_isBusy || !position.isFinite) {
      return false;
    }
    _lasso = LassoGesture._(
      position,
      pointer: pointer,
      rectangleMaxDetour: selectionConfig.rectangleMaxDetour,
      closingFraction: selectionConfig.lassoClosingFraction,
    );
    _selectionChanged.notify();
    return true;
  }

  /// Extends the lasso owned by [pointer] to [position]. The point is stored
  /// only if it is far enough from the last stored one; either way it is
  /// where the lasso now ends.
  void updateLasso(int pointer, InkVector position) {
    final LassoGesture? lasso = _lasso;
    if (lasso == null ||
        pointer != lasso.pointer ||
        !position.isFinite ||
        position == lasso._tip) {
      return;
    }
    lasso._length += (position - lasso._tip).length;
    lasso._tip = position;
    final double distance = (position - lasso._points.last).length;
    if (distance >= selectionConfig.minLassoPointSpacing && distance > 0) {
      lasso._points.add(position);
    }
    _selectionChanged.notify();
  }

  /// Ends the lasso owned by [pointer], after extending it to any
  /// [finalPosition] delivered with the pointer-up, and selects every stroke
  /// whose ink overlaps its [LassoGesture.outline]: the rectangle spanned by
  /// a straight drag, or the loop of a freeform one that nearly closes. That
  /// replaces the previous selection, so a lasso around nothing, one left
  /// open, or a tap, clears it.
  void endLasso(
    int pointer, [
    InkVector? finalPosition,
    Rect? selectablePdfBounds,
  ]) {
    final LassoGesture? lasso = _lasso;
    if (lasso == null || pointer != lasso.pointer) {
      return;
    }
    if (finalPosition != null) {
      updateLasso(pointer, finalPosition);
    }
    _lasso = null;
    final LassoRegion region = LassoRegion(
      lasso.outline,
      tolerance: selectionConfig.geometryTolerance,
    );
    final List<int> indices = selectStrokes(_strokes, region).indices;
    final List<int> imageIndices = selectImages(_images, region);
    final Rect? clippedPdfBounds = region.isEmpty || selectablePdfBounds == null
        ? null
        : Rect.fromLTRB(
            region.left,
            region.top,
            region.right,
            region.bottom,
          ).intersect(selectablePdfBounds);
    final Rect? selectedPdf =
        clippedPdfBounds == null || clippedPdfBounds.isEmpty
        ? null
        : clippedPdfBounds;
    if (_setSelection(
      indices.isEmpty && imageIndices.isEmpty && selectedPdf == null
          ? null
          : _selectionOf(indices, imageIndices, selectedPdf),
    )) {
      _completedChanged.notify();
    }
    _selectionChanged.notify();
  }

  /// Selects the topmost image at [position], or clears the selection.
  bool selectImageAt(InkVector position) {
    if (_isBusy || !position.isFinite) {
      return false;
    }
    int? found;
    for (int i = _images.length - 1; i >= 0; i--) {
      if (_images[i].contains(
        position,
        tolerance: selectionConfig.geometryTolerance,
      )) {
        found = i;
        break;
      }
    }
    final bool changed = _setSelection(
      found == null ? null : _selectionOf(const <int>[], <int>[found]),
    );
    if (changed) {
      _completedChanged.notify();
      _selectionChanged.notify();
    }
    return found != null;
  }

  /// Adds one image below all ink and selects it as one mutation.
  bool insertImage(NoteImageElement image) {
    if (!image.isValid || _isBusy) {
      return false;
    }
    _images = <NoteImageElement>[..._images, image];
    _selection = _selectionOf(const <int>[], <int>[_images.length - 1]);
    _documentChanged();
    _completedChanged.notify();
    _selectionChanged.notify();
    return true;
  }

  /// A cancelled lasso selects nothing and leaves the selection as it was.
  void cancelLasso(int pointer) {
    if (pointer == _lasso?.pointer) {
      _lasso = null;
      _selectionChanged.notify();
    }
  }

  /// Starts the transform [hit] calls for, for [pointer] at [position].
  /// Returns false, and changes nothing, when nothing is selected, another
  /// pointer already owns the page, or the position is unusable.
  bool beginTransform({
    required int pointer,
    required InkVector position,
    required SelectionHit hit,
  }) {
    final InkSelection? selection = _selection;
    if (selection == null ||
        selection.includesPdf ||
        _isBusy ||
        !position.isFinite) {
      return false;
    }
    double thinnest = double.infinity;
    double widest = 0;
    for (final Stroke stroke in selection.strokes) {
      thinnest = math.min(thinnest, stroke.style.width);
      widest = math.max(widest, stroke.style.width);
    }
    // Images may shrink, but always retain a visible finite side.
    for (final NoteImageElement image in selection.images) {
      final double shortest = math.min(image.size.width, image.size.height);
      if (shortest > 0) {
        thinnest = math.min(thinnest, shortest);
      }
    }
    // Shrinking stops at the configured scale, or sooner if the thinnest
    // stroke would drop below the smallest width allowed. A stroke already
    // thinner than that cannot shrink at all.
    final double widthLimit = thinnest > 0
        ? math.min(1, selectionConfig.minStrokeWidth / thinnest)
        : 1;
    _transform = SelectionTransformGesture._(
      pointer: pointer,
      operation: hit.operation,
      corner: hit.corner,
      start: position,
      startFrame: selection.frame,
      minScale: math.max(selectionConfig.minScale, widthLimit),
      widestStroke: widest,
    );
    _selectionChanged.notify();
    return true;
  }

  /// Moves the transform owned by [pointer] to [position]. The preview is
  /// worked out from where the gesture started, not from the previous
  /// preview. A position that gives no valid transform changes nothing.
  void updateTransform(int pointer, InkVector position) {
    final SelectionTransformGesture? gesture = _transform;
    if (gesture == null || pointer != gesture.pointer || !position.isFinite) {
      return;
    }
    final SelectionFrame startFrame = gesture.startFrame;
    final InkTransform? transform = switch (gesture.operation) {
      SelectionOperation.move => SelectionTransforms.move(
        gesture.start,
        position,
      ),
      SelectionOperation.scale => SelectionTransforms.scale(
        fixed:
            startFrame.corners[SelectionFrame.oppositeCorner(gesture.corner!)],
        start: gesture.start,
        current: position,
        minScale: gesture._minScale,
        maxScale: selectionConfig.maxScale,
        tolerance: selectionConfig.geometryTolerance,
      ),
      SelectionOperation.rotate => SelectionTransforms.rotate(
        center: startFrame.center,
        start: gesture.start,
        current: position,
        tolerance: selectionConfig.geometryTolerance,
      ),
    };
    if (transform == null ||
        !transform.isFinite ||
        transform == gesture._transform) {
      return;
    }
    final SelectionFrame frame = startFrame.transformed(transform);
    if (!frame.isWithin(selectionConfig.maxCoordinate)) {
      return;
    }
    gesture
      .._transform = transform
      .._frame = frame;
    _selectionChanged.notify();
  }

  /// Commits the transform owned by [pointer], after moving it to any
  /// [finalPosition] delivered with the pointer-up.
  void endTransform(int pointer, [InkVector? finalPosition]) {
    if (pointer != _transform?.pointer) {
      return;
    }
    if (finalPosition != null) {
      updateTransform(pointer, finalPosition);
    }
    _commitTransform();
  }

  /// A cancelled transform keeps the change made so far.
  void cancelTransform(int pointer) {
    if (pointer == _transform?.pointer) {
      _commitTransform();
    }
  }

  /// Deselects everything, after committing any transform in progress. The
  /// document is not changed.
  void clearSelection() {
    finalizeSelectionGesture();
    if (_setSelection(null)) {
      _completedChanged.notify();
      _selectionChanged.notify();
    }
  }

  /// Puts a snapshot of the selection on the clipboard, after committing any
  /// transform in progress. The selection stays. Returns false, and changes
  /// nothing, when nothing is selected.
  bool copySelection({
    InkSelection? expectedSelection,
    Iterable<NoteImageElement> additionalImages = const <NoteImageElement>[],
  }) {
    finalizeSelectionGesture();
    final InkSelection? selection = _selection;
    if (selection == null ||
        (expectedSelection != null &&
            !identical(selection, expectedSelection))) {
      return false;
    }
    _setClipboard(selection, additionalImages: additionalImages);
    if (_clipboard!.isEmpty) {
      _clipboard = null;
      return false;
    }
    _selectionChanged.notify();
    return true;
  }

  /// Copies the selection, then removes its strokes from the document in one
  /// change and clears the selection. Returns false, and changes nothing,
  /// when nothing is selected.
  bool cutSelection({
    InkSelection? expectedSelection,
    Iterable<NoteImageElement> additionalImages = const <NoteImageElement>[],
  }) {
    finalizeSelectionGesture();
    final InkSelection? selection = _selection;
    if (selection == null ||
        (expectedSelection != null &&
            !identical(selection, expectedSelection))) {
      return false;
    }
    _setClipboard(selection, additionalImages: additionalImages);
    if (_clipboard!.isEmpty) {
      _clipboard = null;
      return false;
    }
    final List<Stroke> remaining = <Stroke>[];
    int next = 0;
    for (int i = 0; i < _strokes.length; i++) {
      if (next < selection.indices.length && selection.indices[next] == i) {
        next++;
      } else {
        remaining.add(_strokes[i]);
      }
    }
    _strokes = remaining;
    final Set<int> cutImages = selection.imageIndices.toSet();
    _images = <NoteImageElement>[
      for (int i = 0; i < _images.length; i++)
        if (!cutImages.contains(i)) _images[i],
    ];
    _syncPlaybacks();
    _selection = null;
    if (selection.indices.isNotEmpty || selection.imageIndices.isNotEmpty) {
      _documentChanged();
    }
    _completedChanged.notify();
    _selectionChanged.notify();
    return true;
  }

  /// Adds the clipboard's strokes above the existing ink, in one change, and
  /// selects them. With [at], the copies are centered on that point.
  /// Without it, each paste from the same clipboard lands one more
  /// [SelectionConfig.pasteOffset] away from the copied ink. Any gesture in
  /// progress is ended first.
  ///
  /// Returns false, and changes nothing, when the clipboard is empty or the
  /// paste would land out of range.
  bool paste({InkVector? at}) {
    final InkClipboard? clipboard = _clipboard;
    if (clipboard == null) {
      return false;
    }
    final InkTransform transform = InkTransform.translation(
      at == null
          ? selectionConfig.pasteOffset * (_pasteCount + 1).toDouble()
          : at - clipboard.frame.center,
    );
    final SelectionFrame frame = clipboard.frame.transformed(transform);
    if (!transform.isFinite || !frame.isWithin(selectionConfig.maxCoordinate)) {
      return false;
    }
    finalizeActiveGesture();
    final List<Stroke> pasted = <Stroke>[
      for (final ClipboardStroke stroke in clipboard.strokes)
        Stroke.fromPoints(
          style: stroke.style,
          points: stroke.points.map(transform.apply).toList(),
        ),
    ];
    final List<NoteImageElement> pastedImages = <NoteImageElement>[
      for (int i = 0; i < clipboard.images.length; i++)
        clipboard.images[i]
            .copyWith(
              id: '${clipboard.images[i].id}-paste-${_pasteCount + 1}-$i',
            )
            .transformed(transform),
    ];
    final int first = _strokes.length;
    final int firstImage = _images.length;
    _strokes = <Stroke>[..._strokes, ...pasted];
    _images = <NoteImageElement>[..._images, ...pastedImages];
    _documentChanged();
    _selection = InkSelection(
      indices: <int>[for (int i = 0; i < pasted.length; i++) first + i],
      strokes: pasted,
      imageIndices: <int>[
        for (int i = 0; i < pastedImages.length; i++) firstImage + i,
      ],
      images: pastedImages,
      frame: frame,
    );
    if (at == null) {
      _pasteCount++;
    }
    _completedChanged.notify();
    _selectionChanged.notify();
    return true;
  }

  /// Takes [other]'s clipboard, so that ink copied on one page can be
  /// pasted on another.
  void takeClipboardFrom(InkController other) {
    if (identical(other._clipboard, _clipboard)) {
      return;
    }
    _clipboard = other._clipboard;
    _pasteCount = 0;
    _selectionChanged.notify();
  }

  /// Installs a session clipboard restored by the note owner.
  void takeClipboard(InkClipboard? clipboard) {
    if (identical(clipboard, _clipboard)) {
      return;
    }
    _clipboard = clipboard;
    _pasteCount = 0;
    _selectionChanged.notify();
  }

  InkSelection _selectionOf(
    List<int> indices, [
    List<int> imageIndices = const <int>[],
    Rect? pdfBounds,
  ]) {
    final List<Stroke> strokes = <Stroke>[
      for (final int index in indices) _strokes[index],
    ];
    final List<NoteImageElement> images = <NoteImageElement>[
      for (final int index in imageIndices) _images[index],
    ];
    return InkSelection(
      indices: indices,
      strokes: strokes,
      imageIndices: imageIndices,
      images: images,
      pdfBounds: pdfBounds,
      frame: frameAroundContent(strokes, images, pdfBounds: pdfBounds),
    );
  }

  /// Returns whether the set of selected strokes changed, which is when the
  /// completed layer must repaint.
  bool _setSelection(InkSelection? next) {
    final bool changed =
        !listEquals(_selection?.indices, next?.indices) ||
        !listEquals(_selection?.imageIndices, next?.imageIndices) ||
        _selection?.pdfBounds != next?.pdfBounds;
    _selection = next;
    return changed;
  }

  /// A new clipboard starts a new paste cascade.
  void _setClipboard(
    InkSelection selection, {
    Iterable<NoteImageElement> additionalImages = const <NoteImageElement>[],
  }) {
    _clipboard = InkClipboard.of(selection, additionalImages: additionalImages);
    _pasteCount = 0;
  }

  /// Ends the transform in progress, if any, and applies its preview to the
  /// selected strokes. Each is replaced at its own index by a stroke built
  /// from its transformed points, so order and stacking do not change. A
  /// preview that moves nothing leaves the document untouched.
  void _commitTransform() {
    final SelectionTransformGesture? gesture = _transform;
    final InkSelection? selection = _selection;
    if (gesture == null) {
      return;
    }
    _transform = null;
    final InkTransform transform = gesture._transform;
    if (selection == null || _isIdentity(transform, gesture)) {
      _selectionChanged.notify();
      return;
    }
    final List<Stroke> strokes = List<Stroke>.of(_strokes);
    final List<Stroke> transformed = <Stroke>[];
    final List<NoteImageElement> transformedImages = <NoteImageElement>[];
    final Map<Stroke, Stroke> replaced = HashMap<Stroke, Stroke>.identity();
    for (int i = 0; i < selection.count; i++) {
      final Stroke stroke = selection.strokes[i];
      final Stroke replacement = Stroke.fromPoints(
        // Pen limits apply to new strokes, not to transformed ink.
        style: transform.scale == 1
            ? stroke.style
            : StrokeStyle(
                ink: stroke.style.ink,
                width: stroke.style.width * transform.scale,
              ),
        points: stroke.points.map(transform.apply).toList(),
      );
      strokes[selection.indices[i]] = replacement;
      transformed.add(replacement);
      replaced[stroke] = replacement;
    }
    _strokes = strokes;
    final List<NoteImageElement> images = List<NoteImageElement>.of(_images);
    for (int i = 0; i < selection.imageCount; i++) {
      final NoteImageElement replacement = selection.images[i].transformed(
        transform,
      );
      if (!replacement.isValid) {
        _selectionChanged.notify();
        return;
      }
      images[selection.imageIndices[i]] = replacement;
      transformedImages.add(replacement);
    }
    _images = images;
    // Moved notation ink keeps being drawn where it now is.
    _syncPlaybacks(replaced);
    _documentChanged();
    _selection = InkSelection(
      indices: selection.indices,
      strokes: transformed,
      imageIndices: selection.imageIndices,
      images: transformedImages,
      pdfBounds: selection.pdfBounds,
      frame: gesture._frame,
    );
    _completedChanged.notify();
    _selectionChanged.notify();
  }

  /// Appends one complete, prevalidated AI notation as a single mutation.
  /// No pointer gesture is interrupted and no subset is ever applied.
  ///
  /// With [playbackDuration], every trace must carry its times, and the
  /// notation is drawn over that long, again and again: the strokes are
  /// added at once, as usual, but painted by a new [notationPlayback] until
  /// it is finished. Playbacks already running keep running. Without it,
  /// any times are ignored and the strokes show at once.
  AddNotationResult addAiNotation({
    required List<GeneratedInkTrace> traces,
    required int expectedRevision,
    required Size surfaceSize,
    Duration? playbackDuration,
    GeneratedInkLimits limits = const GeneratedInkLimits(),
  }) {
    if (expectedRevision != _documentRevision) {
      return AddNotationResult.stale;
    }
    if (_isBusy) {
      return AddNotationResult.busy;
    }
    if (!surfaceSize.isFinite ||
        surfaceSize.width <= 0 ||
        surfaceSize.height <= 0 ||
        traces.isEmpty ||
        traces.length > limits.maxTraces) {
      return AddNotationResult.invalid;
    }
    if (playbackDuration != null &&
        (playbackDuration <= Duration.zero ||
            playbackDuration > limits.maxPlaybackDuration)) {
      return AddNotationResult.invalid;
    }
    final double? durationMs = playbackDuration == null
        ? null
        : playbackDuration.inMicroseconds / Duration.microsecondsPerMillisecond;
    int totalPoints = 0;
    final List<Stroke> additions = <Stroke>[];
    for (final GeneratedInkTrace trace in traces) {
      final double width = trace.style.width;
      if (!identical(InkPalette.byId(trace.style.ink.id), trace.style.ink) ||
          !width.isFinite ||
          width < limits.minWidth ||
          width > limits.maxWidth ||
          trace.points.isEmpty ||
          trace.points.length > limits.maxPointsPerTrace) {
        return AddNotationResult.invalid;
      }
      totalPoints += trace.points.length;
      if (totalPoints > limits.maxTotalPoints) {
        return AddNotationResult.invalid;
      }
      final double half = width / 2;
      for (final InkVector point in trace.points) {
        if (!point.isFinite ||
            point.x - half < 0 ||
            point.y - half < 0 ||
            point.x + half > surfaceSize.width ||
            point.y + half > surfaceSize.height ||
            point.x + half > selectionConfig.maxCoordinate ||
            point.y + half > selectionConfig.maxCoordinate) {
          return AddNotationResult.invalid;
        }
      }
      if (durationMs != null && !_validTimes(trace, durationMs)) {
        return AddNotationResult.invalid;
      }
      additions.add(
        Stroke.fromPoints(style: trace.style, points: trace.points),
      );
    }
    // In place before anything hears of the new strokes, so that no frame
    // can paint them whole before they are drawn. Earlier playbacks keep
    // going alongside it.
    final NotationPlayback? playback = playbackDuration == null
        ? null
        : NotationPlayback(
            additions,
            timesMs: <List<double>>[
              for (final GeneratedInkTrace trace in traces) trace.timesMs!,
            ],
            duration: playbackDuration,
            surfaceSize: surfaceSize,
            startedAt: _notationClock,
          );
    if (playback != null) {
      _playbacks.add(playback);
    }
    _strokes = <Stroke>[..._strokes, ...additions];
    _documentChanged();
    if (playback != null) {
      _playbackChanged.notify();
    }
    _completedChanged.notify();
    return playback == null
        ? AddNotationResult.added
        : AddNotationResult.addedWithPlayback;
  }

  /// Whether [trace] has a time for each point, each within the playback's
  /// [durationMs], and none earlier than the one before.
  static bool _validTimes(GeneratedInkTrace trace, double durationMs) {
    final List<double>? times = trace.timesMs;
    if (times == null || times.length != trace.points.length) {
      return false;
    }
    double previous = 0;
    for (final double time in times) {
      if (!time.isFinite || time < previous || time > durationMs) {
        return false;
      }
      previous = time;
    }
    return true;
  }

  /// Whether [transform] leaves the frame's corners, and the stroke widths,
  /// within the geometry tolerance of where they were.
  bool _isIdentity(InkTransform transform, SelectionTransformGesture gesture) {
    final double tolerance = selectionConfig.geometryTolerance;
    if (((transform.scale - 1) * gesture._widestStroke).abs() > tolerance) {
      return false;
    }
    for (final InkVector corner in gesture.startFrame.corners) {
      if ((transform.apply(corner) - corner).length > tolerance) {
        return false;
      }
    }
    return true;
  }

  /// Applies [erase] over the capsule swept from [from] to [to].
  void _eraseAlong(EraseGesture erase, InkVector from, InkVector to) {
    final double radius = erase.radius;
    // The box around the capsule. Stroke bounds already include half the
    // stroke width, so a stroke that fails this test is out of reach.
    final double left = math.min(from.x, to.x) - radius;
    final double right = math.max(from.x, to.x) + radius;
    final double top = math.min(from.y, to.y) - radius;
    final double bottom = math.max(from.y, to.y) + radius;

    // Stays null, and the collection untouched, until a stroke changes.
    List<Stroke>? result;
    for (int i = 0; i < _strokes.length; i++) {
      final Stroke stroke = _strokes[i];
      final Rect bounds = stroke.bounds;
      List<Stroke>? replacement;
      if (bounds.left <= right &&
          bounds.right >= left &&
          bounds.top <= bottom &&
          bounds.bottom >= top) {
        replacement = _erased(stroke, erase, from, to);
      }
      if (replacement == null) {
        result?.add(stroke);
      } else {
        (result ??= _strokes.sublist(0, i)).addAll(replacement);
      }
    }
    if (result != null) {
      _strokes = result;
      // Cut-off pieces of notation ink stay put, as ordinary ink.
      _syncPlaybacks();
      erase._changedInk = true;
      _completedChanged.notify();
    }
  }

  /// What is left of [stroke] after the eraser sweeps from [from] to [to]:
  /// null when it is untouched, otherwise its replacement, possibly empty.
  List<Stroke>? _erased(
    Stroke stroke,
    EraseGesture erase,
    InkVector from,
    InkVector to,
  ) {
    final double reach = erase.radius + stroke.style.width / 2;
    if (stroke.isDot) {
      final bool hit = EraseGeometry.pointTouchesCapsule(
        stroke.points.first,
        from,
        to,
        reach,
      );
      return hit ? const <Stroke>[] : null;
    }
    switch (erase.mode) {
      case EraserMode.stroke:
        final bool hit = EraseGeometry.polylineTouchesCapsule(
          stroke.points,
          from,
          to,
          reach,
        );
        return hit ? const <Stroke>[] : null;
      case EraserMode.area:
        final List<List<InkVector>>? pieces = EraseGeometry.cutPolyline(
          stroke.points,
          from,
          to,
          reach,
          minPieceLength: erase.minPieceLength,
        );
        if (pieces == null) {
          return null;
        }
        return <Stroke>[
          for (final List<InkVector> piece in pieces)
            Stroke.fromPoints(style: stroke.style, points: piece),
        ];
    }
  }

  void dispose() {
    _disposed = true;
    // Whoever waits on the playback hears that it has ended.
    finishNotationPlayback();
    _activeChanged.dispose();
    _completedChanged.dispose();
    _eraserChanged.dispose();
    _selectionChanged.dispose();
    _revisionChanged.dispose();
    _playbackChanged.dispose();
    _playbackFrame.dispose();
  }
}

/// What a selection drag is drawing.
enum LassoShape {
  /// A nearly straight drag: the rectangle with the drag's start and end as
  /// opposite corners.
  rectangle,

  /// A loop drawn by hand.
  freeform,
}

/// The selection drag in progress, from pointer-down to pointer-up.
class LassoGesture {
  LassoGesture._(
    InkVector origin, {
    required this.pointer,
    required this._rectangleMaxDetour,
    required this._closingFraction,
  }) : _tip = origin {
    _points.add(origin);
  }

  final int pointer;
  final double _rectangleMaxDetour;
  final double _closingFraction;
  final List<InkVector> _points = <InkVector>[];
  InkVector _tip;
  double _length = 0;

  /// The stored points, in order, starting where the pointer went down.
  List<InkVector> get points => UnmodifiableListView<InkVector>(_points);

  /// Where the pointer is now. Not always a stored point.
  InkVector get tip => _tip;

  /// How far the pointer has travelled.
  double get length => _length;

  /// A rectangle while the path is close to the straight line from its
  /// start to [tip]; a freeform loop once it has wandered further.
  LassoShape get shape {
    final double direct = (_tip - _points.first).length;
    return _length <= direct * _rectangleMaxDetour
        ? LassoShape.rectangle
        : LassoShape.freeform;
  }

  /// Whether a freeform loop ends near enough to its start to enclose an
  /// area.
  bool get isClosed {
    return (_tip - _points.first).length <= _length * _closingFraction;
  }

  /// The region this drag would select if it ended now: the rectangle's
  /// four corners, the loop's points up to [tip], or nothing for a loop
  /// that is still open. The edge from the last point back to the first is
  /// implied.
  List<InkVector> get outline {
    final InkVector origin = _points.first;
    switch (shape) {
      case LassoShape.rectangle:
        return <InkVector>[
          origin,
          InkVector(_tip.x, origin.y),
          _tip,
          InkVector(origin.x, _tip.y),
        ];
      case LassoShape.freeform:
        if (!isClosed) {
          return const <InkVector>[];
        }
        // The tip, even when it was too close to the last point to be
        // stored.
        return <InkVector>[..._points, if (_tip != _points.last) _tip];
    }
  }
}

/// One move, scale, or rotation of the selection, from pointer-down to
/// pointer-up. Until it ends, the document is untouched and [transform] is
/// only a preview.
class SelectionTransformGesture {
  SelectionTransformGesture._({
    required this.pointer,
    required this.operation,
    required this.corner,
    required this.start,
    required this.startFrame,
    required this._minScale,
    required this._widestStroke,
  }) : _frame = startFrame;

  final int pointer;
  final SelectionOperation operation;

  /// The grabbed corner of [startFrame]; null unless scaling.
  final int? corner;

  /// Where the pointer went down.
  final InkVector start;

  /// The selection's frame when the gesture began.
  final SelectionFrame startFrame;

  final double _minScale;
  final double _widestStroke;
  InkTransform _transform = InkTransform.identity;
  SelectionFrame _frame;

  /// The preview: what the gesture would do to the selection if it ended
  /// now.
  InkTransform get transform => _transform;

  /// [startFrame] carried along by [transform].
  SelectionFrame get frame => _frame;
}

/// A recognized shape being scaled and turned by the pointer that drew it,
/// from the hold that recognized it to pointer-up. Until then the document
/// is untouched and [preview] is what would be committed.
class ShapeAdjustGesture {
  ShapeAdjustGesture._({
    required this.pointer,
    required this.shape,
    required this.style,
    required this.pivot,
    required this.grab,
  }) : _preview = Stroke.fromPoints(style: style, points: shape.points);

  /// Closer to the pivot than this, the pen cannot say how to scale or turn.
  static const double minGrabDistance = 8;
  static const double minScale = 0.05;
  static const double maxScale = 20;

  /// Turns smaller than this, in radians, are taken as none.
  static const double angleDeadZone = 4 * math.pi / 180;

  /// Scales this close to 1 are taken as 1.
  static const double scaleDeadZone = 0.02;

  /// Where a shape turns and scales about: a closed shape's center, an open
  /// shape's start, so a line or an arrow pivots on its tail and its end
  /// follows the pen.
  static InkVector pivotOf(RecognizedShape shape) {
    final List<InkVector> points = shape.points;
    final bool closed = points.length > 2 && points.first == points.last;
    if (!closed) {
      return points.first;
    }
    double x = 0;
    double y = 0;
    final int count = points.length - 1;
    for (int i = 0; i < count; i++) {
      x += points[i].x;
      y += points[i].y;
    }
    return InkVector(x / count, y / count);
  }

  final int pointer;

  /// The shape as recognized.
  final RecognizedShape shape;

  final StrokeStyle style;
  final InkVector pivot;

  /// Where the pen was when the shape was recognized.
  final InkVector grab;

  double _scale = 1;
  double _angle = 0;
  Stroke _preview;

  /// The scale applied so far.
  double get scale => _scale;

  /// The turn applied so far, in radians.
  double get angle => _angle;

  /// The shape, scaled and turned.
  Stroke get preview => _preview;
}

/// One erase gesture, from pointer-down to pointer-up.
///
/// Every change the eraser makes between [InkController.startErase] and the
/// end of the gesture belongs to this object, which makes it the unit a
/// future undo history would record.
class EraseGesture {
  EraseGesture._(
    this._position, {
    required this.id,
    required this.pointer,
    required this.mode,
    required this.radius,
    required this.minPieceLength,
  });

  /// Unique within the controller, and increasing.
  final int id;

  final int pointer;
  final EraserMode mode;

  /// Radius of the eraser disc: half the eraser size in area mode, the
  /// fixed hit radius in stroke mode.
  final double radius;

  final double minPieceLength;

  InkVector _position;
  bool _changedInk = false;

  /// Where the eraser is now.
  InkVector get position => _position;

  /// Whether this gesture has removed any ink so far.
  bool get changedInk => _changedInk;
}

/// The page's strokes and images at one step of history. Strokes and
/// images are immutable, so a snapshot shares them with the document.
class _InkSnapshot {
  const _InkSnapshot(this.strokes, this.images);

  final List<Stroke> strokes;
  final List<NoteImageElement> images;
}

class _Notifier extends ChangeNotifier {
  void notify() => notifyListeners();
}
