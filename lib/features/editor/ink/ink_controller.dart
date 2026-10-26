import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

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
import 'scribble_erase.dart';
import 'selection_transform.dart';
import 'shape_recognizer.dart';
import 'smoothing_config.dart';
import 'stroke.dart';
import 'stroke_spatial_index.dart';
import '../document_io/document_models.dart';
import '../sticky/sticky_note.dart';
import '../text/note_text.dart';

@immutable
class InkRecordingContext {
  const InkRecordingContext({
    required this.recordingId,
    required this.elapsedMs,
  });

  final String recordingId;
  final int elapsedMs;
}

@immutable
class ErasedStrokeRecord {
  const ErasedStrokeRecord({
    required this.stroke,
    required this.erasedAtMs,
    required this.recordingId,
  });

  final Stroke stroke;
  final int erasedAtMs;
  final String recordingId;

  String get strokeId => stroke.id;
}

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
    this.smoothing = const SmoothingConfig(slowCutoffScale: 0.25),
    this.selectionConfig = const SelectionConfig(),
    this.stickyConfig = const StickyNoteConfig(),
    this.historyLimit = 100,
    Iterable<Stroke> strokes = const <Stroke>[],
    Iterable<NoteImageElement> images = const <NoteImageElement>[],
    Iterable<StickyNoteElement> stickyNotes = const <StickyNoteElement>[],
    Iterable<NoteTextElement> textElements = const <NoteTextElement>[],
    Iterable<ErasedStrokeRecord> erasedStrokeRecords =
        const <ErasedStrokeRecord>[],
  }) : assert(historyLimit >= 0),
       _strokes = List<Stroke>.of(strokes),
       _images = List<NoteImageElement>.of(images),
       _stickies = List<StickyNoteElement>.of(stickyNotes),
       _texts = List<NoteTextElement>.of(textElements),
       _erasedStrokeRecords = List<ErasedStrokeRecord>.of(erasedStrokeRecords) {
    _committed = _snapshot();
  }

  final SmoothingConfig smoothing;
  final SelectionConfig selectionConfig;
  final StickyNoteConfig stickyConfig;

  /// How many steps [undo] can go back. The oldest are forgotten first.
  final int historyLimit;

  /// The document as of the last committed change: what an undo returns
  /// to once a gesture has changed [_strokes] in place.
  late _InkSnapshot _committed;
  late InkHistory _history = InkHistory(limit: historyLimit);

  final _Notifier _activeChanged = _Notifier();
  final _Notifier _completedChanged = _Notifier();
  final _Notifier _eraserChanged = _Notifier();
  final _Notifier _selectionChanged = _Notifier();
  final _Notifier _revisionChanged = _Notifier();
  final _Notifier _playbackChanged = _Notifier();
  final _Notifier _playbackFrame = _Notifier();
  final _Notifier _svgAnimationChanged = _Notifier();
  final _Notifier _hiddenChanged = _Notifier();
  final _Notifier _stickyEditChanged = _Notifier();
  final _Notifier _textEditChanged = _Notifier();
  final Set<Stroke> _hidden = HashSet<Stroke>.identity();
  final List<ValueChanged<Map<Stroke, Stroke>>> _replacementListeners =
      <ValueChanged<Map<Stroke, Stroke>>>[];
  List<Stroke> _strokes;
  final List<ErasedStrokeRecord> _erasedStrokeRecords;
  StrokeSpatialIndex? _strokeIndex;
  final Map<String, (List<Stroke>, StrokeSpatialIndex)> _stickyStrokeIndices =
      <String, (List<Stroke>, StrokeSpatialIndex)>{};
  List<NoteImageElement> _images;

  /// The page's sticky notes, in paint order: above images and completed page ink.
  List<StickyNoteElement> _stickies;

  /// Typed text boxes, in paint order above ink and sticky notes.
  List<NoteTextElement> _texts;
  String? _editingTextId;
  bool _textEditHasHistoryStep = false;

  /// Whether the open text box was made by this editing session: it is not
  /// in the history until something is typed into it or it is styled.
  bool _textEditInserted = false;

  /// How many steps of history the open box has made this session.
  int _textEditSteps = 0;

  /// The sticky note open for writing, if any: strokes and erasing that
  /// start on it go to its own ink.
  String? _editingStickyId;

  /// The sticky note the active stroke is drawn into, if any.
  String? _activeStickyId;

  /// The sticky note the latest finished stroke was written on, if any.
  String? _lastStrokeStickyId;
  StickyPlacementGesture? _placement;
  StickyDragGesture? _stickyDrag;
  int _documentRevision = 0;
  ActiveStroke? _active;

  /// How the active stroke may scribble ink out, when the pen asks for it.
  ScribbleConfig? _scribble;
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
  bool _svgAnimationsEnabled = true;

  Listenable get activeStrokeListenable => _activeChanged;

  /// Fires when the document's strokes change, and once whenever the set of
  /// selected strokes changes: selected strokes are painted by the selection
  /// layer, so the completed layer has to stop or start painting them. It
  /// does not fire for lasso moves or transform previews.
  Listenable get completedStrokesListenable => _completedChanged;

  /// Fires when an erase gesture starts, moves, or ends.
  Listenable get eraserListenable => _eraserChanged;

  List<Stroke> get strokes => UnmodifiableListView<Stroke>(_strokes);
  List<ErasedStrokeRecord> get erasedStrokeRecords =>
      UnmodifiableListView<ErasedStrokeRecord>(_erasedStrokeRecords);

  /// Supplied by the editor. Null while no recording is running or it is
  /// paused, so ordinary ink remains untimed.
  ValueGetter<InkRecordingContext?>? recordingContext;
  List<NoteImageElement> get images =>
      UnmodifiableListView<NoteImageElement>(_images);

  /// The page's sticky notes, in paint order.
  List<StickyNoteElement> get stickyNotes =>
      UnmodifiableListView<StickyNoteElement>(_stickies);

  List<NoteTextElement> get textElements =>
      UnmodifiableListView<NoteTextElement>(_texts);

  /// Fires when typed text changes, or a text box opens or closes. Strokes
  /// and erasing never fire it, so the text layer stays put while they run.
  Listenable get textEditingListenable => _textEditChanged;

  NoteTextElement? get editingText => _textById(_editingTextId);

  /// Fires when a sticky note opens for writing or closes.
  Listenable get stickyEditingListenable => _stickyEditChanged;

  /// The sticky note open for writing, if any.
  StickyNoteElement? get editingSticky => _stickyById(_editingStickyId);

  /// The sticky note the active stroke is being drawn into, if any. The
  /// stroke's points are in its local coordinates.
  StickyNoteElement? get activeStrokeSticky => _stickyById(_activeStickyId);

  /// The sticky note the latest finished stroke was written on, if any.
  StickyNoteElement? get lastWrittenSticky => _stickyById(_lastStrokeStickyId);

  /// The sticky note being placed, while its pointer is down.
  StickyPlacementGesture? get activePlacement => _placement;

  /// The sticky note being dragged, while its pointer is down.
  StickyDragGesture? get activeStickyDrag => _stickyDrag;

  /// The most recently committed page stroke, if any.
  Stroke? get lastStroke => _strokes.isEmpty ? null : _strokes.last;

  StickyNoteElement? _stickyById(String? id) {
    if (id == null) {
      return null;
    }
    for (final StickyNoteElement note in _stickies) {
      if (note.id == id) {
        return note;
      }
    }
    return null;
  }

  NoteTextElement? _textById(String? id) {
    if (id == null) return null;
    for (final NoteTextElement text in _texts) {
      if (text.id == id) return text;
    }
    return null;
  }

  int _textIndex(String id) =>
      _texts.indexWhere((NoteTextElement text) => text.id == id);

  NoteTextElement? textAt(InkVector position) {
    if (!position.isFinite) return null;
    for (int i = _texts.length - 1; i >= 0; i--) {
      if (_texts[i].bounds
          .inflate(8)
          .contains(Offset(position.x, position.y))) {
        return _texts[i];
      }
    }
    return null;
  }

  int _stickyIndex(String id) {
    for (int i = 0; i < _stickies.length; i++) {
      if (_stickies[i].id == id) {
        return i;
      }
    }
    return -1;
  }

  /// The topmost sticky note under [position], if any.
  StickyNoteElement? stickyAt(InkVector position) {
    if (!position.isFinite) {
      return null;
    }
    for (int i = _stickies.length - 1; i >= 0; i--) {
      if (_stickies[i].contains(
        position,
        tolerance: stickyConfig.hitSlop,
        cornerRadius: stickyConfig.cornerRadius,
      )) {
        return _stickies[i];
      }
    }
    return null;
  }

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

  /// Whether [stroke] is hidden from view by [setStrokesHidden].
  bool isStrokeHidden(Stroke stroke) => _hidden.contains(stroke);

  bool get hasHiddenStrokes => _hidden.isNotEmpty;

  /// Fires when strokes are hidden or shown again.
  Listenable get hiddenStrokesListenable => _hiddenChanged;

  /// Hides [strokes], or shows them again. Presentation only, like a
  /// playback: they stay in the document, its revision and history are
  /// untouched, and they are saved and exported as usual. While hidden they
  /// are not painted, and the eraser and the lasso pass over them.
  void setStrokesHidden(Iterable<Stroke> strokes, bool hidden) {
    if (_disposed) {
      return;
    }
    bool changed = false;
    for (final Stroke stroke in strokes) {
      changed =
          (hidden ? _hidden.add(stroke) : _hidden.remove(stroke)) || changed;
    }
    if (changed) {
      _hiddenChanged.notify();
      _completedChanged.notify();
      _selectionChanged.notify();
    }
  }

  /// Calls [listener] with each stroke a committed transform replaced, and
  /// its replacement, before anything hears of the change.
  void addStrokeReplacementListener(
    ValueChanged<Map<Stroke, Stroke>> listener,
  ) {
    _replacementListeners.add(listener);
  }

  void removeStrokeReplacementListener(
    ValueChanged<Map<Stroke, Stroke>> listener,
  ) {
    _replacementListeners.remove(listener);
  }

  /// Fires when a playback starts or finishes, or lets go of a stroke: when
  /// strokes move between the playback layer and the finished-ink layer.
  /// Never a document change.
  Listenable get notationPlaybackListenable => _playbackChanged;

  /// Fires each time the playbacks' clock moves on.
  Listenable get notationFrameListenable => _playbackFrame;

  Listenable get svgAnimationListenable => _svgAnimationChanged;
  bool get svgAnimationsEnabled => _svgAnimationsEnabled;

  void setSvgAnimationsEnabled(bool enabled) {
    if (_disposed || enabled == _svgAnimationsEnabled) return;
    _svgAnimationsEnabled = enabled;
    _svgAnimationChanged.notify();
  }

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
        _placement?.pointer ??
        _stickyDrag?.pointer ??
        selectionPointer;
  }

  /// The pointer drawing a lasso or transforming the selection, if any.
  int? get selectionPointer => _lasso?.pointer ?? _transform?.pointer;

  bool get _isBusy {
    return _active != null ||
        _shapeAdjust != null ||
        _erase != null ||
        _lasso != null ||
        _transform != null ||
        _placement != null ||
        _stickyDrag != null;
  }

  /// Whether [undo] would change anything.
  bool get canUndo => _history.canUndo;

  /// Whether [redo] would change anything.
  bool get canRedo => _history.canRedo;

  /// The history this page's changes are recorded in. Pages of one document
  /// share it, so undo and redo walk their changes in the order they were
  /// made, whichever page each was on.
  InkHistory get history => _history;

  /// Records this page's changes in [history] from now on. The page's own
  /// earlier steps are not carried over.
  set history(InkHistory history) {
    if (identical(history, _history)) return;
    _history.forget(this);
    _history = history;
  }

  /// Records one committed change as a step of history, which also drops
  /// anything that could have been redone.
  ///
  /// With [amendLast], the change is folded into the last step instead.
  void _documentChanged({bool amendLast = false}) {
    _history._record(this, _committed, amend: amendLast);
    _committed = _snapshot();
    _revisionBumped();
  }

  void _revisionBumped() {
    _strokeIndex = null;
    _stickyStrokeIndices.clear();
    _documentRevision++;
    _revisionChanged.notify();
  }

  _InkSnapshot _snapshot() {
    return _InkSnapshot(
      List<Stroke>.unmodifiable(_strokes),
      List<NoteImageElement>.unmodifiable(_images),
      List<StickyNoteElement>.unmodifiable(_stickies),
      List<NoteTextElement>.unmodifiable(_texts),
    );
  }

  /// Puts the document back as it was before the last committed change.
  /// Returns false, and changes nothing, while a gesture is in progress or
  /// there is nothing to undo. The selection is dropped.
  bool undo() => !_isBusy && _history.undo() != null;

  /// Applies again the change [undo] last took back. Returns false, and
  /// changes nothing, while a gesture is in progress or there is nothing to
  /// redo. The selection is dropped.
  bool redo() => !_isBusy && _history.redo() != null;

  /// Puts this page back to [snapshot], one of its own steps of history.
  void _restore(_InkSnapshot snapshot) {
    _committed = snapshot;
    _strokes = List<Stroke>.of(_committed.strokes);
    _images = List<NoteImageElement>.of(_committed.images);
    _stickies = List<StickyNoteElement>.of(_committed.stickies);
    _texts = List<NoteTextElement>.of(_committed.texts);
    _editingTextId = null;
    _textEditHasHistoryStep = false;
    _textEditInserted = false;
    _textEditSteps = 0;
    _selection = null;
    // A note open for writing that went away is closed.
    if (_editingStickyId != null && _stickyById(_editingStickyId) == null) {
      _setEditingSticky(null);
    }
    // Strokes that came back are ordinary ink; those that left are let go.
    _syncPlaybacks();
    _revisionBumped();
    _completedChanged.notify();
    _selectionChanged.notify();
    _textEditChanged.notify();
  }

  /// Starts a stroke for [pointer]. Returns false, and changes nothing, when
  /// another pointer already owns the page, or the sample is unusable.
  ///
  /// [dynamics] vary the stroke's width along it; [smoothingConfig], when
  /// given, replaces [smoothing] for this stroke. With [scribbleErase], a
  /// stroke that ends up a scribble over ink erases that ink instead of
  /// being added: see [ScribbleErase.targets].
  ///
  /// With [intoSticky], the stroke is drawn into that sticky note's own
  /// ink: every sample, this one and later ones, is taken into the note's
  /// local coordinates before smoothing, and the width is set so the line
  /// looks as wide on the page as a page stroke would. A stroke that
  /// wanders off the note is still received; it is clipped when painted.
  bool startStroke({
    required int pointer,
    required RawInkSample sample,
    required StrokeStyle style,
    StrokeDynamics dynamics = StrokeDynamics.none,
    SmoothingConfig? smoothingConfig,
    ScribbleConfig? scribbleErase,
    StickyNoteElement? intoSticky,
  }) {
    if (_isBusy || !sample.position.isFinite) {
      return false;
    }
    final StickyNoteElement? sticky = intoSticky == null
        ? null
        : _stickyById(intoSticky.id);
    if (intoSticky != null && sticky == null) {
      return false;
    }
    _activeStickyId = sticky?.id;
    _scribble = scribbleErase;
    final RawInkSample first = sticky == null
        ? sample
        : _toSticky(sticky, sample);
    _active = ActiveStroke(
      style: sticky == null
          ? style
          : style.withWidth(style.width / sticky.scale),
      first: first,
      config: smoothingConfig ?? smoothing,
      dynamics: dynamics,
    );
    _activePointer = pointer;
    _activeChanged.notify();
    return true;
  }

  /// [sample] in [sticky]'s local coordinates.
  static RawInkSample _toSticky(StickyNoteElement sticky, RawInkSample sample) {
    return RawInkSample(
      position: sticky.toLocal(sample.position),
      timestamp: sample.timestamp,
      deviceKind: sample.deviceKind,
      pressure: sample.pressure,
    );
  }

  /// [sample] as the active stroke takes it: in the sticky note's
  /// coordinates when it is drawn into one.
  RawInkSample _forActive(RawInkSample sample) {
    final StickyNoteElement? sticky = activeStrokeSticky;
    return sticky == null ? sample : _toSticky(sticky, sample);
  }

  void addSamples(int pointer, Iterable<RawInkSample> samples) {
    final ActiveStroke? active = _active;
    if (active == null || pointer != _activePointer) {
      return;
    }
    bool changed = false;
    for (final RawInkSample sample in samples) {
      changed = active.add(_forActive(sample)) || changed;
    }
    if (changed) {
      _activeChanged.notify();
    }
  }

  /// Completes the stroke owned by [pointer], after processing any
  /// [finalSamples] delivered with the pointer-up. Returns how many strokes
  /// it scribbled out, in which case it was not added itself.
  int endStroke(
    int pointer, [
    Iterable<RawInkSample> finalSamples = const <RawInkSample>[],
  ]) {
    final ActiveStroke? active = _active;
    if (active == null || pointer != _activePointer) {
      return 0;
    }
    for (final RawInkSample sample in finalSamples) {
      active.add(_forActive(sample));
    }
    return finalizeActiveStroke();
  }

  /// A cancelled stroke keeps the ink drawn so far.
  void cancelStroke(int pointer) {
    if (pointer == _activePointer) {
      finalizeActiveStroke();
    }
  }

  /// Commits the active stroke, if any. Later events from its pointer are
  /// ignored.
  ///
  /// A stroke begun with a scribble config that scribbles ink out erases
  /// that ink instead, as one change, and is not added. Returns how many
  /// strokes it erased.
  int finalizeActiveStroke() {
    final ActiveStroke? active = _active;
    if (active == null) {
      return 0;
    }
    final String? stickyId = _activeStickyId;
    _lastStrokeStickyId = stickyId;
    final ScribbleConfig? scribble = _scribble;
    final InkRecordingContext? timeline = recordingContext?.call();
    final Stroke stroke = active.finish(
      completedAtMs: timeline?.elapsedMs,
      recordingId: timeline?.recordingId,
    );
    _active = null;
    _scribble = null;
    _activePointer = null;
    _activeStickyId = null;
    int erased = 0;
    if (stickyId == null) {
      final List<int> out = _scribbledOut(stroke, _strokes, scribble);
      if (out.isEmpty) {
        _strokes.add(stroke);
      } else {
        _recordErasedStrokes(<Stroke>[
          for (final int index in out) _strokes[index],
        ], timeline);
        clearSelection();
        _strokes = _without(_strokes, out);
        // Scribbled-out notation ink is let go, like erased ink.
        _syncPlaybacks();
        erased = out.length;
      }
      _documentChanged();
    } else {
      final int index = _stickyIndex(stickyId);
      // A note that went away mid-stroke takes the stroke with it.
      if (index >= 0) {
        final StickyNoteElement note = _stickies[index];
        final List<int> out = _scribbledOut(stroke, note.strokes, scribble);
        _recordErasedStrokes(<Stroke>[
          for (final int erasedIndex in out) note.strokes[erasedIndex],
        ], timeline);
        erased = out.length;
        _stickies = List<StickyNoteElement>.of(_stickies)
          ..[index] = note.copyWith(
            strokes: out.isEmpty
                ? <Stroke>[...note.strokes, stroke]
                : _without(note.strokes, out),
          );
        _documentChanged();
      }
    }
    _completedChanged.notify();
    _activeChanged.notify();
    return erased;
  }

  /// The indices of the visible strokes in [strokes] that [stroke]
  /// scribbles out under [config]; none without a config.
  List<int> _scribbledOut(
    Stroke stroke,
    List<Stroke> strokes,
    ScribbleConfig? config,
  ) {
    if (config == null) {
      return const <int>[];
    }
    return ScribbleErase.targets(
      stroke,
      strokes,
      config: config,
      skip: _hidden.contains,
      candidateIndices: identical(strokes, _strokes)
          ? _index.query(stroke.bounds)
          : null,
    );
  }

  static List<Stroke> _without(List<Stroke> strokes, List<int> indices) {
    final Set<int> drop = indices.toSet();
    return <Stroke>[
      for (int i = 0; i < strokes.length; i++)
        if (!drop.contains(i)) strokes[i],
    ];
  }

  void _recordErasedStrokes(
    Iterable<Stroke> strokes,
    InkRecordingContext? timeline,
  ) {
    if (timeline == null) return;
    for (final Stroke stroke in strokes) {
      _erasedStrokeRecords.add(
        ErasedStrokeRecord(
          stroke: stroke,
          erasedAtMs: timeline.elapsedMs,
          recordingId: timeline.recordingId,
        ),
      );
    }
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
    if (active == null ||
        pointer != _activePointer ||
        active.isDot ||
        // Only a pen stroke becomes a shape; a highlighter stays freehand.
        active.style.isHighlighter ||
        // Shapes are adjusted in page coordinates; a sticky note's ink is
        // in its own, so it stays freehand too.
        _activeStickyId != null) {
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
    _scribble = null;
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
    final InkRecordingContext? timeline = recordingContext?.call();
    final Stroke preview = gesture.preview;
    _strokes.add(
      Stroke.fromPoints(
        style: preview.style,
        points: preview.points,
        widths: preview.widths,
        completedAtMs: timeline?.elapsedMs,
        recordingId: timeline?.recordingId,
      ),
    );
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
    if (pointer == _placement?.pointer) {
      cancelStickyPlacement(pointer);
      return;
    }
    if (_active == null || pointer != _activePointer) {
      return;
    }
    _active = null;
    _scribble = null;
    _activePointer = null;
    _activeStickyId = null;
    _activeChanged.notify();
  }

  /// Starts an erase gesture for [pointer] and erases under [position].
  /// Returns false, and changes nothing, when another pointer already owns
  /// the page, or the position is unusable.
  ///
  /// [settings] are captured here; later changes apply to the next gesture.
  /// Erasing moves and replaces strokes, so it drops the selection first.
  ///
  /// The eraser's size is on screen: [screenScale] is how many screen
  /// pixels one canvas pixel covers, so a zoomed-in page is erased by an
  /// eraser that looks, and reaches, as far as it does unzoomed.
  bool startErase({
    required int pointer,
    required InkVector position,
    required EraserSettings settings,
    EraserConfig config = const EraserConfig(),
    double screenScale = 1,
    StickyNoteElement? inSticky,
  }) {
    final double scale = screenScale.isFinite && screenScale > 0
        ? screenScale
        : 1;
    if (_isBusy || !position.isFinite) {
      return false;
    }
    final StickyNoteElement? sticky = inSticky == null
        ? null
        : _stickyById(inSticky.id);
    clearSelection();
    final EraseGesture erase = EraseGesture._(
      position,
      id: ++_eraseGestureCount,
      pointer: pointer,
      mode: settings.mode,
      radius:
          (settings.mode == EraserMode.area
              ? settings.size / 2
              : config.strokeHitRadius) /
          scale,
      minPieceLength: config.minPieceLength,
      scale: scale,
      stickyId: sticky?.id,
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
    // A sticky note is placed only by a pointer that lifts.
    final StickyPlacementGesture? placement = _placement;
    if (placement != null) {
      cancelStickyPlacement(placement.pointer);
    }
    final StickyDragGesture? drag = _stickyDrag;
    if (drag != null) {
      endStickyDrag(drag.pointer);
    }
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
    // Sticky notes lie above images, so they are hit first.
    final StickyNoteElement? sticky = stickyAt(position);
    if (sticky != null) {
      final int index = _stickyIndex(sticky.id);
      if (_setSelection(
        _selectionOf(const <int>[], const <int>[], null, <int>[index]),
      )) {
        _completedChanged.notify();
      }
      _selectionChanged.notify();
      return beginTransform(
        pointer: pointer,
        position: position,
        hit: const SelectionHit.move(),
      );
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
    bool keepPaper = false,
  ]) {
    endLasso(pointer, finalPosition, selectablePdfBounds, keepPaper);
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
  /// open, or a tap, clears it. With [keepPaper], PDF paper inside the
  /// outline is selected along with the ink, not only when the outline
  /// stands clear of it.
  void endLasso(
    int pointer, [
    InkVector? finalPosition,
    Rect? selectablePdfBounds,
    bool keepPaper = false,
  ]) {
    final LassoGesture? lasso = _lasso;
    if (lasso == null || pointer != lasso.pointer) {
      return;
    }
    if (finalPosition != null) {
      updateLasso(pointer, finalPosition);
    }
    _lasso = null;
    final InkSelection? enclosed = _enclosedBy(
      lasso.outline,
      selectablePdfBounds,
      includePdfWithForeground: keepPaper,
    );
    if (_setSelection(enclosed)) {
      _completedChanged.notify();
    }
    _selectionChanged.notify();
  }

  /// Selects everything [outline] encloses, as a lasso drawn along it
  /// would, without a lasso gesture: used when a loop drawn in AI mode
  /// circles a spot. Returns whether anything was selected; when nothing
  /// was, the selection is left as it was. Not while a pointer is busy.
  bool selectEnclosed(List<InkVector> outline, {Rect? selectablePdfBounds}) {
    if (_isBusy || _disposed) {
      return false;
    }
    final InkSelection? enclosed = _enclosedBy(
      outline,
      selectablePdfBounds,
      includePdfWithForeground: true,
    );
    if (enclosed == null) {
      return false;
    }
    if (_setSelection(enclosed)) {
      _completedChanged.notify();
    }
    _selectionChanged.notify();
    return true;
  }

  /// Selects every stroke, image, sticky note, or PDF excerpt enclosed by
  /// [outline], replacing the previous selection, or clears the selection when
  /// [outline] encloses nothing. With [keepPaper], PDF paper inside the
  /// outline is selected along with the ink.
  bool selectWithOutline(
    List<InkVector> outline, {
    Rect? selectablePdfBounds,
    bool keepPaper = false,
  }) {
    if (_disposed || _isBusy) {
      return false;
    }
    final InkSelection? enclosed = _enclosedBy(
      outline,
      selectablePdfBounds,
      includePdfWithForeground: keepPaper,
    );
    if (_setSelection(enclosed)) {
      _completedChanged.notify();
    }
    _selectionChanged.notify();
    return enclosed != null;
  }

  /// Adds [additionalStrokes] from [strokes] to the current selection, or
  /// creates a selection for them when none is active.
  void includeStrokesInSelection(Iterable<Stroke> additionalStrokes) {
    if (_disposed || _isBusy) {
      return;
    }
    final Set<Stroke> wanted = HashSet<Stroke>.identity()
      ..addAll(additionalStrokes);
    if (wanted.isEmpty) {
      return;
    }
    final InkSelection? current = _selection;
    final Set<int> indexSet = <int>{...?current?.indices};
    for (int i = 0; i < _strokes.length; i++) {
      if (!_hidden.contains(_strokes[i]) && wanted.contains(_strokes[i])) {
        indexSet.add(i);
      }
    }
    if (indexSet.isEmpty &&
        (current == null ||
            (current.imageIndices.isEmpty &&
                current.stickyIndices.isEmpty &&
                current.pdfBounds == null))) {
      return;
    }
    final List<int> indices = indexSet.toList()..sort();
    final InkSelection next = _selectionOf(
      indices,
      current?.imageIndices ?? const <int>[],
      current?.pdfBounds,
      current?.stickyIndices ?? const <int>[],
    );
    if (_setSelection(next)) {
      _completedChanged.notify();
    }
    _selectionChanged.notify();
  }

  /// Replaces the current selection's frame with [frame], so pages sharing a
  /// cross-page selection share the same bounding frame in their own
  /// coordinates.
  void setSelectionFrame(SelectionFrame frame) {
    final InkSelection? current = _selection;
    if (current == null || _disposed) {
      return;
    }
    _selection = InkSelection(
      indices: current.indices,
      strokes: current.strokes,
      imageIndices: current.imageIndices,
      images: current.images,
      stickyIndices: current.stickyIndices,
      stickies: current.stickies,
      pdfBounds: current.pdfBounds,
      frame: frame,
    );
    _selectionChanged.notify();
  }

  /// Selects the topmost sticky note or image containing [position], if any.
  bool selectStickyOrImageAt(InkVector position) {
    if (_disposed || _isBusy || !position.isFinite) {
      return false;
    }
    final StickyNoteElement? sticky = stickyAt(position);
    if (sticky != null) {
      final int index = _stickyIndex(sticky.id);
      if (_setSelection(
        _selectionOf(const <int>[], const <int>[], null, <int>[index]),
      )) {
        _completedChanged.notify();
      }
      _selectionChanged.notify();
      return true;
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
        return true;
      }
    }
    return false;
  }

  /// What a lasso along [outline] selects, or null for nothing.
  InkSelection? _enclosedBy(
    List<InkVector> outline,
    Rect? selectablePdfBounds, {
    bool includePdfWithForeground = false,
  }) {
    final LassoRegion region = LassoRegion(
      outline,
      tolerance: selectionConfig.geometryTolerance,
    );
    final Rect lassoBounds = Rect.fromLTRB(
      region.left,
      region.top,
      region.right,
      region.bottom,
    ).inflate(region.tolerance);
    final List<int> indices = <int>[
      for (final int index in selectStrokes(
        _strokes,
        region,
        candidateIndices: region.isEmpty
            ? const <int>[]
            : _index.query(lassoBounds),
      ).indices)
        if (!_hidden.contains(_strokes[index])) index,
    ];
    final List<int> imageIndices = selectImages(_images, region);
    final List<int> stickyIndices = selectStickyNotes(_stickies, region);
    final Rect? clippedPdfBounds = region.isEmpty || selectablePdfBounds == null
        ? null
        : Rect.fromLTRB(
            region.left,
            region.top,
            region.right,
            region.bottom,
          ).intersect(selectablePdfBounds);
    // With the Select tool, foreground objects must remain independently
    // editable on PDF-backed pages. AI selection opts into keeping the paper
    // too, because it needs the visual context behind the selected ink.
    final bool selectedForeground =
        indices.isNotEmpty ||
        imageIndices.isNotEmpty ||
        stickyIndices.isNotEmpty;
    // A selection drawn well clear of the ink inside it means the paper
    // too; one hugging the ink means the ink alone.
    final bool clearOfForeground =
        selectedForeground &&
        clippedPdfBounds != null &&
        _outlineClearOf(outline, <Rect>[
          for (final int index in indices) _strokes[index].bounds,
          for (final int index in imageIndices) _images[index].bounds,
          for (final int index in stickyIndices) _stickies[index].bounds,
        ], selectionConfig.pdfSelectionMargin);
    final Rect? selectedPdf =
        (!includePdfWithForeground &&
                selectedForeground &&
                !clearOfForeground) ||
            clippedPdfBounds == null ||
            clippedPdfBounds.isEmpty
        ? null
        : clippedPdfBounds;
    return indices.isEmpty &&
            imageIndices.isEmpty &&
            stickyIndices.isEmpty &&
            selectedPdf == null
        ? null
        : _selectionOf(indices, imageIndices, selectedPdf, stickyIndices);
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

  /// Adds [note] above the other sticky notes, as one change, and opens it
  /// for writing. Returns false, and changes nothing, while a gesture is in
  /// progress, or for a note that is not valid or whose id is taken.
  bool insertStickyNote(StickyNoteElement note) {
    if (_isBusy || !note.isValid || _stickyById(note.id) != null) {
      return false;
    }
    final bool hadSelection = _selection != null;
    _stickies = <StickyNoteElement>[..._stickies, note];
    _selection = null;
    _documentChanged();
    _setEditingSticky(note.id);
    _completedChanged.notify();
    if (hadSelection) {
      _selectionChanged.notify();
    }
    return true;
  }

  /// Adds a text box at [position] and opens the keyboard editor for it.
  /// The empty box is not a change yet: its first edit is one step of
  /// history, and left empty it goes without a trace.
  bool insertText(
    InkVector position,
    TextSettings settings, {
    required Rect pageBounds,
  }) {
    if (_isBusy || !position.isFinite || pageBounds.isEmpty) return false;
    finishTextEditing();
    const double preferredWidth = 280;
    const double edgeInset = 12;
    final double available = math.max(
      80,
      pageBounds.right - position.x - edgeInset,
    );
    final double width = math.min(preferredWidth, available);
    final InkVector topLeft = InkVector(
      position.x.clamp(pageBounds.left + edgeInset, pageBounds.right - 80),
      position.y.clamp(pageBounds.top + edgeInset, pageBounds.bottom - 40),
    );
    final NoteTextElement element = NoteTextElement(
      id: NoteTextElement.newId(),
      position: topLeft,
      text: '',
      width: width,
      settings: settings,
    );
    _texts = <NoteTextElement>[..._texts, element];
    _editingTextId = element.id;
    _textEditHasHistoryStep = false;
    _textEditInserted = true;
    _textEditSteps = 0;
    _selection = null;
    _completedChanged.notify();
    _textEditChanged.notify();
    _selectionChanged.notify();
    return true;
  }

  /// Reopens an existing text box. Its first actual edit gets its own undo
  /// step; merely tapping it does not change the document.
  bool editText(String id) {
    if (_isBusy || _textById(id) == null) return false;
    if (_editingTextId == id) return true;
    finishTextEditing();
    _editingTextId = id;
    _textEditHasHistoryStep = false;
    _textEditInserted = false;
    _textEditSteps = 0;
    _textEditChanged.notify();
    return true;
  }

  /// Applies typing or formatting to the open text box.
  bool updateEditingText({String? text, TextSettings? settings}) =>
      _changeEditingText(
        (NoteTextElement current) =>
            current.copyWith(text: text, settings: settings),
      );

  /// Moves the open text box to [position] and gives it [width], clamped
  /// into [pageBounds]. With [commit] false it only shows the change, as a
  /// handle is dragged; the commit that ends the drag is one change.
  bool setEditingTextFrame({
    InkVector? position,
    double? width,
    required Rect pageBounds,
    bool commit = true,
  }) {
    final NoteTextElement? current = editingText;
    if (_disposed || current == null || pageBounds.isEmpty) return false;
    final double nextWidth = (width ?? current.width).clamp(
      80.0,
      math.max(80.0, math.min(1200.0, pageBounds.width)),
    );
    final InkVector at = position ?? current.position;
    final InkVector nextPosition = InkVector(
      at.x.clamp(
        pageBounds.left,
        math.max(pageBounds.left, pageBounds.right - nextWidth),
      ),
      at.y.clamp(
        pageBounds.top,
        math.max(pageBounds.top, pageBounds.bottom - 24),
      ),
    );
    if (!commit) {
      final int index = _textIndex(current.id);
      _texts = List<NoteTextElement>.of(_texts)
        ..[index] = current.copyWith(position: nextPosition, width: nextWidth);
      _completedChanged.notify();
      _textEditChanged.notify();
      return true;
    }
    // The drag's preview already moved the box: what changes is measured
    // against the document as last committed.
    final NoteTextElement? committed = _committed.texts
        .where((NoteTextElement text) => text.id == current.id)
        .firstOrNull;
    final NoteTextElement next = current.copyWith(
      position: nextPosition,
      width: nextWidth,
    );
    final int index = _textIndex(current.id);
    if (committed == null) {
      // A box not typed into yet is not in the document: moving it is no
      // change either.
      _texts = List<NoteTextElement>.of(_texts)..[index] = next;
      _completedChanged.notify();
      _textEditChanged.notify();
      return true;
    }
    if (committed.position == next.position &&
        committed.width == next.width &&
        committed.text == next.text &&
        committed.settings == next.settings) {
      _texts = List<NoteTextElement>.of(_texts)..[index] = committed;
      _completedChanged.notify();
      _textEditChanged.notify();
      return false;
    }
    // Each drag is a step of its own, apart from the typing around it.
    return _changeEditingText((_) => next, force: true, newStep: true);
  }

  /// Removes the open text box, as one change. An empty box made by this
  /// session goes without a trace.
  bool deleteEditingText() {
    final int index = _textIndex(_editingTextId ?? '');
    if (_disposed || _isBusy || index < 0) return false;
    final bool empty = _texts[index].text.trim().isEmpty;
    _texts = List<NoteTextElement>.of(_texts)..removeAt(index);
    if (!empty || !_dropAbandonedTextStep()) {
      _documentChanged();
    }
    _editingTextId = null;
    _textEditHasHistoryStep = false;
    _textEditInserted = false;
    _textEditSteps = 0;
    _completedChanged.notify();
    _textEditChanged.notify();
    return true;
  }

  /// Applies [change] to the open box. Typing and styling in a row are one
  /// step of history; with [newStep] the change is a step of its own, and
  /// the typing after it starts another.
  bool _changeEditingText(
    NoteTextElement Function(NoteTextElement current) change, {
    bool force = false,
    bool newStep = false,
  }) {
    final int index = _textIndex(_editingTextId ?? '');
    if (_disposed || index < 0) return false;
    final NoteTextElement current = _texts[index];
    final NoteTextElement next = change(current);
    if (!force &&
        next.text == current.text &&
        next.settings == current.settings &&
        next.position == current.position &&
        next.width == current.width) {
      return false;
    }
    _texts = List<NoteTextElement>.of(_texts)..[index] = next;
    final bool amend = !newStep && _textEditHasHistoryStep;
    _documentChanged(amendLast: amend);
    if (!amend) _textEditSteps++;
    _textEditHasHistoryStep = !newStep;
    _completedChanged.notify();
    _textEditChanged.notify();
    return true;
  }

  /// Called with the open box, left empty, already taken out of [_texts]:
  /// takes back without a trace what it left in the history, when it is a
  /// box this session made and nothing else happened to it. Returns whether
  /// it did; the page is then as it was before the box.
  bool _dropAbandonedTextStep() {
    final String? id = _editingTextId;
    if (!_committed.texts.any((NoteTextElement text) => text.id == id)) {
      // Never typed into: the document never had it.
      _completedChanged.notify();
      return true;
    }
    if (!_textEditInserted ||
        _textEditSteps != 1 ||
        !_history._lastIsOf(this, 1)) {
      return false;
    }
    _committed = _history._dropLast(1);
    _texts = List<NoteTextElement>.of(_committed.texts);
    _revisionBumped();
    return true;
  }

  /// Closes the text editor, dropping a text box that was left empty.
  void finishTextEditing() {
    final int index = _textIndex(_editingTextId ?? '');
    if (_editingTextId == null) return;
    if (index >= 0 && _texts[index].text.trim().isEmpty) {
      _texts = List<NoteTextElement>.of(_texts)..removeAt(index);
      if (!_dropAbandonedTextStep()) {
        _documentChanged(amendLast: _textEditHasHistoryStep);
      }
      _completedChanged.notify();
    }
    _editingTextId = null;
    _textEditHasHistoryStep = false;
    _textEditInserted = false;
    _textEditSteps = 0;
    _textEditChanged.notify();
  }

  /// Gives the sticky note [id] another paper color or pattern, as one
  /// change; its ink is never recolored. Returns false when nothing would
  /// change.
  bool setStickyAppearance(
    String id, {
    StickyPaperColor? color,
    StickyPaperStyle? paper,
  }) {
    final int index = _stickyIndex(id);
    if (_disposed || index < 0) {
      return false;
    }
    final StickyNoteElement note = _stickies[index];
    final StickyNoteElement next = note.copyWith(
      colorId: color?.id,
      paper: paper,
    );
    if (next.colorId == note.colorId && next.paper == note.paper) {
      return false;
    }
    _stickies = List<StickyNoteElement>.of(_stickies)..[index] = next;
    final InkSelection? selection = _selection;
    if (selection != null && selection.stickyIndices.contains(index)) {
      _selection = _selectionOf(
        selection.indices,
        selection.imageIndices,
        selection.pdfBounds,
        selection.stickyIndices,
      );
      _selectionChanged.notify();
    }
    _documentChanged();
    _completedChanged.notify();
    return true;
  }

  /// Opens the sticky note [id] for writing: strokes and erasing that start
  /// on it then go to its own ink. With [removingTap], the dot the first
  /// tap of a double tap left on the note, when it is the latest change,
  /// is taken back without a trace in the history.
  bool enterStickyEditing(String id, {Stroke? removingTap}) {
    if (_disposed || _isBusy || _stickyById(id) == null) {
      return false;
    }
    if (removingTap != null &&
        _history._lastIsOf(this, 1) &&
        (identical(_stickyById(id)?.strokes.lastOrNull, removingTap) ||
            (identical(_strokes.lastOrNull, removingTap) &&
                identical(_committed.strokes.lastOrNull, removingTap)))) {
      _committed = _history._dropLast(1);
      _strokes = List<Stroke>.of(_committed.strokes);
      _stickies = List<StickyNoteElement>.of(_committed.stickies);
      _syncPlaybacks();
      _revisionBumped();
      _completedChanged.notify();
    }
    clearSelection();
    _setEditingSticky(id);
    return true;
  }

  /// Closes the sticky note open for writing, if any.
  void exitStickyEditing() => _setEditingSticky(null);

  void _setEditingSticky(String? id) {
    if (_editingStickyId == id) {
      return;
    }
    _editingStickyId = id;
    if (!_disposed) {
      _stickyEditChanged.notify();
      _completedChanged.notify();
    }
  }

  /// Starts placing a sticky note with [settings] for [pointer] at
  /// [position]: it is shown there, kept within [pageBounds], until the
  /// pointer lifts. With [growsDown], as on an infinite page, only the top
  /// and left edges hold it in. Returns false, and changes nothing, when
  /// another pointer owns the page.
  bool beginStickyPlacement({
    required int pointer,
    required InkVector position,
    required Rect pageBounds,
    StickyNoteSettings settings = const StickyNoteSettings(),
    bool growsDown = false,
  }) {
    if (_isBusy || !position.isFinite || !pageBounds.isFinite) {
      return false;
    }
    clearSelection();
    _placement = StickyPlacementGesture._(
      pointer: pointer,
      settings: settings,
      size: stickyConfig.defaultSize,
      pageBounds: pageBounds,
      growsDown: growsDown,
      position: position,
    );
    _activeChanged.notify();
    return true;
  }

  void updateStickyPlacement(int pointer, InkVector position) {
    final StickyPlacementGesture? placement = _placement;
    if (placement == null ||
        pointer != placement.pointer ||
        !position.isFinite) {
      return;
    }
    final InkVector next = StickyPlacementGesture._clamp(
      position,
      placement.size,
      placement.pageBounds,
      placement.growsDown,
    );
    if (next == placement._center) {
      return;
    }
    placement._center = next;
    _activeChanged.notify();
  }

  /// Inserts the note placed by [pointer], opened for writing, and returns
  /// it; null when [pointer] was not placing one.
  StickyNoteElement? endStickyPlacement(int pointer, [InkVector? position]) {
    final StickyPlacementGesture? placement = _placement;
    if (placement == null || pointer != placement.pointer) {
      return null;
    }
    if (position != null) {
      updateStickyPlacement(pointer, position);
    }
    _placement = null;
    _activeChanged.notify();
    final StickyNoteElement note = placement.preview(StickyNoteElement.newId());
    return insertStickyNote(note) ? note : null;
  }

  /// Drops the placement of [pointer], inserting nothing.
  void cancelStickyPlacement(int pointer) {
    if (pointer == _placement?.pointer) {
      _placement = null;
      _activeChanged.notify();
    }
  }

  /// Takes hold of the topmost sticky note under [position] for [pointer],
  /// to drag it around [pageBounds] (only its top-left edges with
  /// [growsDown]). Returns false, and changes nothing, when there is no
  /// note there or another pointer owns the page.
  bool beginStickyDrag({
    required int pointer,
    required InkVector position,
    required Rect pageBounds,
    bool growsDown = false,
  }) {
    if (_isBusy || !position.isFinite || !pageBounds.isFinite) {
      return false;
    }
    final StickyNoteElement? note = stickyAt(position);
    if (note == null) {
      return false;
    }
    clearSelection();
    _stickyDrag = StickyDragGesture._(
      pointer: pointer,
      original: note,
      grab: position - note.center,
      pageBounds: pageBounds,
      growsDown: growsDown,
    );
    _activeChanged.notify();
    return true;
  }

  /// Moves the note [pointer] holds so it stays under the pointer where it
  /// was taken hold of, kept on the page.
  void updateStickyDrag(int pointer, InkVector position) {
    final StickyDragGesture? drag = _stickyDrag;
    if (drag == null || pointer != drag.pointer || !position.isFinite) {
      return;
    }
    final int index = _stickyIndex(drag.original.id);
    if (index < 0) {
      return;
    }
    final Rect bounds = drag.original.bounds;
    final InkVector center = StickyPlacementGesture._clamp(
      position - drag.grab,
      bounds.size,
      drag.pageBounds,
      drag.growsDown,
    );
    if (center == _stickies[index].center) {
      return;
    }
    drag._moved = center != drag.original.center;
    _stickies = List<StickyNoteElement>.of(_stickies)
      ..[index] = _stickies[index].copyWith(center: center);
    _completedChanged.notify();
  }

  /// Lets go of the note [pointer] holds: a move is one change of history,
  /// and the note is left open, so the Sticky note tool's options restyle
  /// it. Returns the note, or null when [pointer] held none.
  StickyNoteElement? endStickyDrag(int pointer, [InkVector? position]) {
    final StickyDragGesture? drag = _stickyDrag;
    if (drag == null || pointer != drag.pointer) {
      return null;
    }
    if (position != null) {
      updateStickyDrag(pointer, position);
    }
    _stickyDrag = null;
    if (drag._moved) {
      _documentChanged();
    }
    _activeChanged.notify();
    _setEditingSticky(drag.original.id);
    return _stickyById(drag.original.id);
  }

  /// Puts the note [pointer] holds back where it was taken from.
  void cancelStickyDrag(int pointer) {
    final StickyDragGesture? drag = _stickyDrag;
    if (drag == null || pointer != drag.pointer) {
      return;
    }
    _stickyDrag = null;
    final int index = _stickyIndex(drag.original.id);
    if (index >= 0 && drag._moved) {
      _stickies = List<StickyNoteElement>.of(_stickies)
        ..[index] = drag.original;
      _completedChanged.notify();
    }
    _activeChanged.notify();
  }

  /// A cancelled lasso selects nothing and leaves the selection as it was.
  void cancelLasso(int pointer) {
    if (pointer == _lasso?.pointer) {
      _lasso = null;
      _selectionChanged.notify();
    }
  }

  /// Scale limits and widest stroke width for the current selection.
  (double minScale, double maxScale, double widestStroke)
  selectionScaleLimits() {
    final InkSelection? selection = _selection;
    if (selection == null) {
      return (selectionConfig.minScale, selectionConfig.maxScale, 0);
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
    // A sticky note stays within its configured size; one already outside
    // it may not move further out.
    double stickyMin = 0;
    double stickyMax = double.infinity;
    for (final StickyNoteElement note in selection.stickies) {
      final Size min = stickyConfig.minSize;
      final Size max = stickyConfig.maxSize;
      stickyMin = math.max(
        stickyMin,
        math.min(
          1,
          math.max(min.width / note.size.width, min.height / note.size.height),
        ),
      );
      stickyMax = math.min(
        stickyMax,
        math.max(
          1,
          math.min(max.width / note.size.width, max.height / note.size.height),
        ),
      );
    }
    final double minScale = math.min(
      1,
      math.max(math.max(selectionConfig.minScale, widthLimit), stickyMin),
    );
    final double maxScale = math.max(
      minScale,
      math.min(selectionConfig.maxScale, stickyMax),
    );
    return (minScale, maxScale, widest);
  }

  /// Starts the transform [hit] calls for, for [pointer] at [position].
  /// Returns false, and changes nothing, when nothing is selected, another
  /// pointer already owns the page, or the position is unusable.
  bool beginTransform({
    required int pointer,
    required InkVector position,
    required SelectionHit hit,
    double? minScaleOverride,
    double? maxScaleOverride,
    double? widestStrokeOverride,
  }) {
    final InkSelection? selection = _selection;
    if (selection == null ||
        selection.includesPdf ||
        _isBusy ||
        !position.isFinite) {
      return false;
    }
    final (double localMin, double localMax, double localWidest) =
        selectionScaleLimits();
    final double minScale = minScaleOverride ?? localMin;
    _transform = SelectionTransformGesture._(
      pointer: pointer,
      operation: hit.operation,
      corner: hit.corner,
      start: position,
      startFrame: selection.frame,
      minScale: minScale,
      // Never below the minimum, so the clamp between them is well formed.
      maxScale: math.max(minScale, maxScaleOverride ?? localMax),
      widestStroke: widestStrokeOverride ?? localWidest,
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
        maxScale: gesture._maxScale,
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

  /// Puts [selection] on this controller's clipboard. Used when a cross-page
  /// selection combines items from multiple pages into one clipboard.
  bool copyCombinedSelection(
    InkSelection selection, {
    Iterable<NoteImageElement> additionalImages = const <NoteImageElement>[],
  }) {
    finalizeSelectionGesture();
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
    _removeSelected(selection);
    return true;
  }

  /// Removes the selection's strokes, images, and sticky notes, each sticky
  /// with all of its ink, in one change, and clears the selection. The
  /// clipboard is untouched. Returns false, and changes nothing, when
  /// nothing removable is selected.
  bool deleteSelection({InkSelection? expectedSelection}) {
    finalizeSelectionGesture();
    final InkSelection? selection = _selection;
    if (selection == null ||
        (expectedSelection != null &&
            !identical(selection, expectedSelection)) ||
        (selection.count == 0 &&
            selection.imageCount == 0 &&
            selection.stickyCount == 0)) {
      return false;
    }
    _removeSelected(selection);
    return true;
  }

  void _removeSelected(InkSelection selection) {
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
    final Set<int> cutStickies = selection.stickyIndices.toSet();
    _stickies = <StickyNoteElement>[
      for (int i = 0; i < _stickies.length; i++)
        if (!cutStickies.contains(i)) _stickies[i],
    ];
    if (_editingStickyId != null && _stickyById(_editingStickyId) == null) {
      _setEditingSticky(null);
    }
    _syncPlaybacks();
    _selection = null;
    if (selection.indices.isNotEmpty ||
        selection.imageIndices.isNotEmpty ||
        selection.stickyIndices.isNotEmpty) {
      _documentChanged();
    }
    _completedChanged.notify();
    _selectionChanged.notify();
  }

  /// Removes the sticky note [id], with all its ink, as one change.
  bool deleteStickyNote(String id) {
    final int index = _stickyIndex(id);
    if (_disposed || _isBusy || index < 0) {
      return false;
    }
    _removeSelected(
      _selectionOf(const <int>[], const <int>[], null, <int>[index]),
    );
    return true;
  }

  /// Copies the selection in place, one paste offset away, and selects the
  /// copies, without touching the clipboard. One change.
  bool duplicateSelection() {
    finalizeSelectionGesture();
    final InkSelection? selection = _selection;
    if (selection == null || selection.includesPdf) {
      return false;
    }
    final InkClipboard copy = InkClipboard.of(selection);
    if (copy.isEmpty) {
      return false;
    }
    return _pasteFrom(
      copy,
      InkTransform.translation(selectionConfig.pasteOffset),
    );
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
    if (!_pasteFrom(clipboard, transform)) {
      return false;
    }
    if (at == null) {
      _pasteCount++;
    }
    return true;
  }

  /// Adds [clipboard]'s content moved by [transform] above what is there,
  /// in one change, and selects it. Pasted sticky notes get fresh ids.
  bool _pasteFrom(InkClipboard clipboard, InkTransform transform) {
    final SelectionFrame frame = clipboard.frame.transformed(transform);
    if (!transform.isFinite || !frame.isWithin(selectionConfig.maxCoordinate)) {
      return false;
    }
    finalizeActiveGesture();
    final List<StickyNoteElement> pastedStickies = <StickyNoteElement>[
      for (final StickyNoteElement note in clipboard.stickies)
        note.copyWith(id: StickyNoteElement.newId()).transformed(transform),
    ];
    final List<Stroke> pasted = <Stroke>[
      for (final ClipboardStroke stroke in clipboard.strokes)
        Stroke.fromPoints(
          style: stroke.style,
          points: stroke.points.map(transform.apply).toList(),
          widths: stroke.widths,
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
    final int firstSticky = _stickies.length;
    _strokes = <Stroke>[..._strokes, ...pasted];
    _images = <NoteImageElement>[..._images, ...pastedImages];
    _stickies = <StickyNoteElement>[..._stickies, ...pastedStickies];
    _documentChanged();
    _selection = InkSelection(
      indices: <int>[for (int i = 0; i < pasted.length; i++) first + i],
      strokes: pasted,
      imageIndices: <int>[
        for (int i = 0; i < pastedImages.length; i++) firstImage + i,
      ],
      images: pastedImages,
      stickyIndices: <int>[
        for (int i = 0; i < pastedStickies.length; i++) firstSticky + i,
      ],
      stickies: pastedStickies,
      frame: frame,
    );
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

  /// Lets go of the selection [pointer] is moving, for another page to take
  /// up with [receiveSelection]: what is selected is removed in one change
  /// and returned as it looks in the move's preview. The clipboard is
  /// untouched. Returns null, and changes nothing, unless [pointer] is
  /// moving a selection.
  InkClipboard? releaseSelection(int pointer) {
    final SelectionTransformGesture? gesture = _transform;
    final InkSelection? selection = _selection;
    if (gesture == null ||
        gesture.pointer != pointer ||
        gesture.operation != SelectionOperation.move ||
        selection == null ||
        selection.includesPdf) {
      return null;
    }
    final InkTransform transform = gesture._transform;
    final List<NoteImageElement> images = <NoteImageElement>[
      for (final NoteImageElement image in selection.images)
        image.transformed(transform),
    ];
    final List<StickyNoteElement> stickies = <StickyNoteElement>[
      for (final StickyNoteElement note in selection.stickies)
        note.transformed(transform),
    ];
    if (images.any((NoteImageElement image) => !image.isValid) ||
        stickies.any((StickyNoteElement note) => !note.isValid)) {
      return null;
    }
    final InkClipboard content = InkClipboard.of(
      InkSelection(
        indices: selection.indices,
        // A move only translates, so each stroke keeps its style.
        strokes: <Stroke>[
          for (final Stroke stroke in selection.strokes)
            Stroke.fromPoints(
              style: stroke.style,
              points: stroke.points.map(transform.apply).toList(),
              widths: stroke.widths,
            ),
        ],
        imageIndices: selection.imageIndices,
        images: images,
        stickyIndices: selection.stickyIndices,
        stickies: stickies,
        frame: gesture._frame,
      ),
    );
    if (content.isEmpty) {
      return null;
    }
    _transform = null;
    _removeSelected(selection);
    // Passing through, it leaves this page's history as it found it.
    if (gesture._carriedIn && _history._lastIsOf(this, 2)) {
      _history._dropLast(2);
    }
    return content;
  }

  /// Takes up [content] let go by another page's [releaseSelection],
  /// shifted by [offset] into this page's coordinates, selects it, and goes
  /// on moving it with [pointer] from [position]. The arrival and the rest
  /// of the move are one change. Returns false, and changes nothing, when
  /// another pointer owns the page or the content would land out of range.
  bool receiveSelection(
    InkClipboard content, {
    required InkVector offset,
    required int pointer,
    required InkVector position,
  }) {
    if (_disposed || _isBusy || !position.isFinite) {
      return false;
    }
    if (!_pasteFrom(content, InkTransform.translation(offset))) {
      return false;
    }
    if (beginTransform(
      pointer: pointer,
      position: position,
      hit: const SelectionHit.move(),
    )) {
      _transform!._carriedIn = true;
    }
    return true;
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
    List<int> stickyIndices = const <int>[],
  ]) {
    final List<Stroke> strokes = <Stroke>[
      for (final int index in indices) _strokes[index],
    ];
    final List<NoteImageElement> images = <NoteImageElement>[
      for (final int index in imageIndices) _images[index],
    ];
    final List<StickyNoteElement> stickies = <StickyNoteElement>[
      for (final int index in stickyIndices) _stickies[index],
    ];
    return InkSelection(
      indices: indices,
      strokes: strokes,
      imageIndices: imageIndices,
      images: images,
      stickyIndices: stickyIndices,
      stickies: stickies,
      pdfBounds: pdfBounds,
      frame: frameAroundContent(
        strokes,
        images,
        pdfBounds: pdfBounds,
        stickies: stickies,
      ),
    );
  }

  /// Returns whether the set of selected strokes changed, which is when the
  /// completed layer must repaint.
  bool _setSelection(InkSelection? next) {
    final bool changed =
        !listEquals(_selection?.indices, next?.indices) ||
        !listEquals(_selection?.imageIndices, next?.imageIndices) ||
        !listEquals(_selection?.stickyIndices, next?.stickyIndices) ||
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
            : stroke.style.withWidth(stroke.style.width * transform.scale),
        points: stroke.points.map(transform.apply).toList(),
        widths: stroke.widths,
        id: stroke.id,
        completedAtMs: stroke.completedAtMs,
        recordingId: stroke.recordingId,
        sampleDeltasMs: stroke.sampleDeltasMs,
      );
      strokes[selection.indices[i]] = replacement;
      transformed.add(replacement);
      replaced[stroke] = replacement;
      // Hidden ink moved along with the selection stays hidden. The stroke
      // it replaces stays hidden too, for an undo to bring back.
      if (_hidden.contains(stroke)) {
        _hidden.add(replacement);
      }
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
    // A sticky note's frame moves; its ink, in its own coordinates, comes
    // along untouched.
    final List<StickyNoteElement> stickies = List<StickyNoteElement>.of(
      _stickies,
    );
    final List<StickyNoteElement> transformedStickies = <StickyNoteElement>[];
    for (int i = 0; i < selection.stickyCount; i++) {
      final StickyNoteElement replacement = selection.stickies[i].transformed(
        transform,
      );
      if (!replacement.isValid) {
        _selectionChanged.notify();
        return;
      }
      stickies[selection.stickyIndices[i]] = replacement;
      transformedStickies.add(replacement);
    }
    _stickies = stickies;
    // Moved notation ink keeps being drawn where it now is.
    _syncPlaybacks(replaced);
    for (final ValueChanged<Map<Stroke, Stroke>> listener
        in List<ValueChanged<Map<Stroke, Stroke>>>.of(_replacementListeners)) {
      listener(replaced);
    }
    _documentChanged(amendLast: gesture._carriedIn);
    _selection = InkSelection(
      indices: selection.indices,
      strokes: transformed,
      imageIndices: selection.imageIndices,
      images: transformedImages,
      stickyIndices: selection.stickyIndices,
      stickies: transformedStickies,
      pdfBounds: selection.pdfBounds,
      frame: gesture._frame,
    );
    _completedChanged.notify();
    _selectionChanged.notify();
  }

  /// Whether the transform in progress has not moved or scaled beyond the
  /// geometry tolerance.
  bool get isActiveTransformIdentity {
    final SelectionTransformGesture? gesture = _transform;
    if (gesture == null) {
      return true;
    }
    return _isIdentity(gesture._transform, gesture);
  }

  /// Drops the active transform preview without changing the document.
  void discardActiveTransform() {
    if (_transform != null) {
      _transform = null;
      _selectionChanged.notify();
    }
  }

  /// Applies the result of a cross-page selection transform to this page in a
  /// single history step.
  void commitCrossPageTransform({
    Map<int, Stroke> stayingStrokes = const <int, Stroke>{},
    Set<int> leavingStrokeIndices = const <int>{},
    List<Stroke> arrivingStrokes = const <Stroke>[],
    Set<Stroke> arrivingHiddenStrokes = const <Stroke>{},
    Map<int, NoteImageElement> stayingImages = const <int, NoteImageElement>{},
    Set<int> leavingImageIndices = const <int>{},
    List<NoteImageElement> arrivingImages = const <NoteImageElement>[],
    Map<int, StickyNoteElement> stayingStickies =
        const <int, StickyNoteElement>{},
    Set<int> leavingStickyIndices = const <int>{},
    List<StickyNoteElement> arrivingStickies = const <StickyNoteElement>[],
    SelectionFrame? selectionFrame,
  }) {
    _transform = null;
    final List<Stroke> nextStrokes = <Stroke>[];
    final List<int> selectedStrokeIndices = <int>[];
    final List<Stroke> selectedStrokes = <Stroke>[];
    final Map<Stroke, Stroke> replaced = HashMap<Stroke, Stroke>.identity();
    for (int i = 0; i < _strokes.length; i++) {
      if (leavingStrokeIndices.contains(i)) {
        continue;
      }
      final Stroke? replacement = stayingStrokes[i];
      if (replacement != null) {
        final Stroke oldStroke = _strokes[i];
        selectedStrokeIndices.add(nextStrokes.length);
        selectedStrokes.add(replacement);
        nextStrokes.add(replacement);
        replaced[oldStroke] = replacement;
        if (_hidden.contains(oldStroke)) {
          _hidden.add(replacement);
        }
      } else {
        nextStrokes.add(_strokes[i]);
      }
    }
    for (final Stroke arriving in arrivingStrokes) {
      selectedStrokeIndices.add(nextStrokes.length);
      selectedStrokes.add(arriving);
      nextStrokes.add(arriving);
      if (arrivingHiddenStrokes.contains(arriving)) {
        _hidden.add(arriving);
      }
    }
    _strokes = nextStrokes;

    final List<NoteImageElement> nextImages = <NoteImageElement>[];
    final List<int> selectedImageIndices = <int>[];
    final List<NoteImageElement> selectedImages = <NoteImageElement>[];
    for (int i = 0; i < _images.length; i++) {
      if (leavingImageIndices.contains(i)) {
        continue;
      }
      final NoteImageElement? replacement = stayingImages[i];
      if (replacement != null) {
        selectedImageIndices.add(nextImages.length);
        selectedImages.add(replacement);
        nextImages.add(replacement);
      } else {
        nextImages.add(_images[i]);
      }
    }
    for (final NoteImageElement arriving in arrivingImages) {
      selectedImageIndices.add(nextImages.length);
      selectedImages.add(arriving);
      nextImages.add(arriving);
    }
    _images = nextImages;

    final List<StickyNoteElement> nextStickies = <StickyNoteElement>[];
    final List<int> selectedStickyIndices = <int>[];
    final List<StickyNoteElement> selectedStickies = <StickyNoteElement>[];
    for (int i = 0; i < _stickies.length; i++) {
      if (leavingStickyIndices.contains(i)) {
        continue;
      }
      final StickyNoteElement? replacement = stayingStickies[i];
      if (replacement != null) {
        selectedStickyIndices.add(nextStickies.length);
        selectedStickies.add(replacement);
        nextStickies.add(replacement);
      } else {
        nextStickies.add(_stickies[i]);
      }
    }
    for (final StickyNoteElement arriving in arrivingStickies) {
      selectedStickyIndices.add(nextStickies.length);
      selectedStickies.add(arriving);
      nextStickies.add(arriving);
    }
    _stickies = nextStickies;

    if (_editingStickyId != null && _stickyById(_editingStickyId) == null) {
      _setEditingSticky(null);
    }
    _syncPlaybacks(replaced);
    if (replaced.isNotEmpty) {
      for (final ValueChanged<Map<Stroke, Stroke>> listener
          in List<ValueChanged<Map<Stroke, Stroke>>>.of(
            _replacementListeners,
          )) {
        listener(replaced);
      }
    }
    final bool changed =
        stayingStrokes.isNotEmpty ||
        leavingStrokeIndices.isNotEmpty ||
        arrivingStrokes.isNotEmpty ||
        stayingImages.isNotEmpty ||
        leavingImageIndices.isNotEmpty ||
        arrivingImages.isNotEmpty ||
        stayingStickies.isNotEmpty ||
        leavingStickyIndices.isNotEmpty ||
        arrivingStickies.isNotEmpty;
    if (changed) {
      _documentChanged();
    }
    if (selectedStrokes.isEmpty &&
        selectedImages.isEmpty &&
        selectedStickies.isEmpty) {
      _selection = null;
    } else {
      _selection = InkSelection(
        indices: selectedStrokeIndices,
        strokes: selectedStrokes,
        imageIndices: selectedImageIndices,
        images: selectedImages,
        stickyIndices: selectedStickyIndices,
        stickies: selectedStickies,
        frame:
            selectionFrame ??
            frameAroundContent(
              selectedStrokes,
              selectedImages,
              stickies: selectedStickies,
            ),
      );
    }
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
    final List<Stroke>? strokes = _generatedStrokes(
      traces,
      surfaceSize,
      limits,
    );
    if (strokes == null ||
        (durationMs != null &&
            traces.any(
              (GeneratedInkTrace trace) => !_validTimes(trace, durationMs),
            ))) {
      return AddNotationResult.invalid;
    }
    final List<Stroke> additions = strokes;
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

  /// Adds [note], a new sticky note carrying a complete, prevalidated AI
  /// notation in its own coordinates, above the other sticky notes, as one
  /// change. Unlike [insertStickyNote], it is not opened for writing. Its
  /// ink must lie on its paper, and it must lie on the [surfaceSize] page.
  AddNotationResult addAiStickyNote({
    required StickyNoteElement note,
    required int expectedRevision,
    required Size surfaceSize,
    GeneratedInkLimits limits = const GeneratedInkLimits(),
  }) {
    if (expectedRevision != _documentRevision) {
      return AddNotationResult.stale;
    }
    if (_isBusy) {
      return AddNotationResult.busy;
    }
    final Rect bounds = note.bounds;
    if (!note.isValid ||
        _stickyById(note.id) != null ||
        note.strokes.isEmpty ||
        note.strokes.length > limits.maxTraces ||
        bounds.left < 0 ||
        bounds.top < 0 ||
        bounds.right > surfaceSize.width ||
        bounds.bottom > surfaceSize.height) {
      return AddNotationResult.invalid;
    }
    final bool hadSelection = _selection != null;
    _stickies = <StickyNoteElement>[..._stickies, note];
    _selection = null;
    _documentChanged();
    _completedChanged.notify();
    if (hadSelection) {
      _selectionChanged.notify();
    }
    return AddNotationResult.added;
  }

  /// [traces] as strokes, or null when any breaks [limits] or reaches
  /// past [area], from the origin to its size.
  List<Stroke>? _generatedStrokes(
    List<GeneratedInkTrace> traces,
    Size area,
    GeneratedInkLimits limits,
  ) {
    int totalPoints = 0;
    final List<Stroke> strokes = <Stroke>[];
    for (final GeneratedInkTrace trace in traces) {
      final double width = trace.style.width;
      final List<double>? widths = trace.widths;
      if (!identical(InkPalette.byId(trace.style.ink.id), trace.style.ink) ||
          !width.isFinite ||
          width < limits.minWidth ||
          width > limits.maxWidth ||
          trace.points.isEmpty ||
          trace.points.length > limits.maxPointsPerTrace ||
          (widths != null &&
              (widths.length != trace.points.length ||
                  widths.any(
                    (double factor) =>
                        !factor.isFinite ||
                        factor <= 0 ||
                        width * factor > limits.maxWidth,
                  )))) {
        return null;
      }
      totalPoints += trace.points.length;
      if (totalPoints > limits.maxTotalPoints) {
        return null;
      }
      final double widest = widths == null
          ? 1
          : widths.fold<double>(0, math.max);
      final double half = width * widest / 2;
      for (final InkVector point in trace.points) {
        if (!point.isFinite ||
            point.x - half < 0 ||
            point.y - half < 0 ||
            point.x + half > area.width ||
            point.y + half > area.height ||
            point.x + half > selectionConfig.maxCoordinate ||
            point.y + half > selectionConfig.maxCoordinate) {
          return null;
        }
      }
      strokes.add(
        Stroke.fromPoints(
          style: trace.style,
          points: trace.points,
          widths: widths,
        ),
      );
    }
    return strokes;
  }

  /// [traces], laid out in a sticky note's own coordinates over [localSize],
  /// as that note's strokes, or null when any breaks [limits] or leaves
  /// its paper.
  List<Stroke>? generatedStickyStrokes(
    List<GeneratedInkTrace> traces,
    Size localSize, {
    GeneratedInkLimits limits = const GeneratedInkLimits(),
  }) {
    if (traces.isEmpty || traces.length > limits.maxTraces) {
      return null;
    }
    return _generatedStrokes(traces, localSize, limits);
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

  /// Applies [erase] over the capsule swept from [from] to [to]: to the
  /// page's ink, or, for an erase begun on a sticky note open for writing,
  /// to that note's ink only. Sticky paper is never erased.
  void _eraseAlong(EraseGesture erase, InkVector from, InkVector to) {
    final String? stickyId = erase.stickyId;
    if (stickyId != null) {
      final int index = _stickyIndex(stickyId);
      if (index < 0) {
        return;
      }
      final StickyNoteElement note = _stickies[index];
      final List<Stroke>? result = _eraseIn(
        note.strokes,
        erase,
        note.toLocal(from),
        note.toLocal(to),
        erase.radius / note.scale,
        spatialIndex: _stickyIndexFor(note),
      );
      if (result != null) {
        _stickies = List<StickyNoteElement>.of(_stickies)
          ..[index] = note.copyWith(strokes: result);
        _stickyStrokeIndices.remove(note.id);
        erase._changedInk = true;
        _completedChanged.notify();
      }
      return;
    }
    final List<Stroke>? result = _eraseIn(
      _strokes,
      erase,
      from,
      to,
      erase.radius,
    );
    if (result != null) {
      _strokes = result;
      _strokeIndex = null;
      // Cut-off pieces of notation ink stay put, as ordinary ink.
      _syncPlaybacks();
      erase._changedInk = true;
      _completedChanged.notify();
    }
    final List<int> erasedVectors = <int>[
      for (int i = 0; i < _images.length; i++)
        if (_images[i].isVector &&
            _segmentTouchesRect(
              from,
              to,
              _images[i].bounds.inflate(erase.radius),
            ))
          i,
    ];
    if (erasedVectors.isNotEmpty) {
      final Set<int> removed = erasedVectors.toSet();
      _images = <NoteImageElement>[
        for (int i = 0; i < _images.length; i++)
          if (!removed.contains(i)) _images[i],
      ];
      _selection = null;
      erase._changedInk = true;
      _completedChanged.notify();
      _selectionChanged.notify();
    }
  }

  /// [strokes] after an eraser of [radius] sweeps from [from] to [to], or
  /// null when none of them is touched.
  List<Stroke>? _eraseIn(
    List<Stroke> strokes,
    EraseGesture erase,
    InkVector from,
    InkVector to,
    double radius, {
    StrokeSpatialIndex? spatialIndex,
  }) {
    // The box around the capsule. Stroke bounds already include half the
    // stroke width, so a stroke that fails this test is out of reach.
    final double left = math.min(from.x, to.x) - radius;
    final double right = math.max(from.x, to.x) + radius;
    final double top = math.min(from.y, to.y) - radius;
    final double bottom = math.max(from.y, to.y) + radius;

    final StrokeSpatialIndex? index =
        spatialIndex ?? (identical(strokes, _strokes) ? _index : null);
    final Iterable<int>? candidates = index?.query(
      Rect.fromLTRB(left, top, right, bottom),
    );
    final Iterator<int>? candidate = candidates?.iterator;
    bool hasCandidate = candidate?.moveNext() ?? false;

    // Stays null, and the collection untouched, until a stroke changes.
    List<Stroke>? result;
    for (int i = 0; i < strokes.length; i++) {
      final Stroke stroke = strokes[i];
      final Rect bounds = stroke.bounds;
      List<Stroke>? replacement;
      final bool shouldTest =
          candidate == null || (hasCandidate && candidate.current == i);
      if (candidate != null && shouldTest) {
        hasCandidate = candidate.moveNext();
      }
      if (shouldTest &&
          !_hidden.contains(stroke) &&
          bounds.left <= right &&
          bounds.right >= left &&
          bounds.top <= bottom &&
          bounds.bottom >= top) {
        replacement = _erased(stroke, erase, from, to, radius);
      }
      if (replacement == null) {
        result?.add(stroke);
      } else {
        (result ??= strokes.sublist(0, i)).addAll(replacement);
      }
    }
    return result;
  }

  /// The index of [_strokes], rebuilt whenever the collection is replaced or
  /// grows in place, so it never answers with stale document indices.
  StrokeSpatialIndex get _index {
    final StrokeSpatialIndex? index = _strokeIndex;
    if (index != null && index.indexes(_strokes)) {
      return index;
    }
    return _strokeIndex = StrokeSpatialIndex(_strokes);
  }

  StrokeSpatialIndex _stickyIndexFor(StickyNoteElement note) {
    final cached = _stickyStrokeIndices[note.id];
    if (cached != null &&
        identical(cached.$1, note.strokes) &&
        cached.$2.indexes(note.strokes)) {
      return cached.$2;
    }
    final StrokeSpatialIndex index = StrokeSpatialIndex(note.strokes);
    _stickyStrokeIndices[note.id] = (note.strokes, index);
    return index;
  }

  /// What is left of [stroke] after the eraser sweeps from [from] to [to]:
  /// null when it is untouched, otherwise its replacement, possibly empty.
  List<Stroke>? _erased(
    Stroke stroke,
    EraseGesture erase,
    InkVector from,
    InkVector to,
    double radius,
  ) {
    final double reach = radius + stroke.style.width / 2;
    if (stroke.isDot) {
      final bool hit = EraseGeometry.pointTouchesCapsule(
        stroke.points.first,
        from,
        to,
        reach,
      );
      if (hit) _recordEraseTombstone(stroke, erase);
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
        if (hit) _recordEraseTombstone(stroke, erase);
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
        _recordEraseTombstone(stroke, erase);
        return <Stroke>[
          for (final List<InkVector> piece in pieces)
            Stroke.fromPoints(
              style: stroke.style,
              points: piece,
              widths: stroke.widthsAlong(piece),
              completedAtMs: stroke.completedAtMs,
              recordingId: stroke.recordingId,
              sampleDeltasMs: stroke.sampleDeltasMs,
            ),
        ];
    }
  }

  void _recordEraseTombstone(Stroke stroke, EraseGesture erase) {
    final InkRecordingContext? timeline = recordingContext?.call();
    if (timeline == null || !erase._recordedStrokeIds.add(stroke.id)) return;
    _recordErasedStrokes(<Stroke>[stroke], timeline);
  }

  void dispose() {
    _disposed = true;
    _history.forget(this);
    // Whoever waits on the playback hears that it has ended.
    finishNotationPlayback();
    _activeChanged.dispose();
    _completedChanged.dispose();
    _eraserChanged.dispose();
    _selectionChanged.dispose();
    _revisionChanged.dispose();
    _playbackChanged.dispose();
    _playbackFrame.dispose();
    _svgAnimationChanged.dispose();
    _hiddenChanged.dispose();
    _stickyEditChanged.dispose();
    _textEditChanged.dispose();
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
    required this._maxScale,
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
  final double _maxScale;
  final double _widestStroke;
  InkTransform _transform = InkTransform.identity;
  SelectionFrame _frame;

  /// Whether the selection arrived from another page with this move, so
  /// that the arrival and the move are one change.
  bool _carriedIn = false;

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
    this.scale = 1,
    this.stickyId,
  });

  /// The sticky note whose ink this gesture erases, or null for the page.
  final String? stickyId;

  /// Unique within the controller, and increasing.
  final int id;

  final int pointer;
  final EraserMode mode;

  /// Radius of the eraser disc: half the eraser size in area mode, the
  /// fixed hit radius in stroke mode.
  final double radius;

  final double minPieceLength;

  /// Screen scale captured when the gesture began.
  final double scale;

  InkVector _position;
  bool _changedInk = false;
  final Set<String> _recordedStrokeIds = <String>{};

  /// Where the eraser is now.
  InkVector get position => _position;

  /// Whether this gesture has removed any ink so far.
  bool get changedInk => _changedInk;
}

/// The page's strokes and images at one step of history. Strokes and
/// images are immutable, so a snapshot shares them with the document.
/// The changes made to a document's pages, in order: what undo and redo
/// walk. Pages record into one history, so a change on one page is undone
/// before the changes made on another page before it.
class InkHistory extends ChangeNotifier {
  InkHistory({this.limit = 100}) : assert(limit >= 0);

  /// How many steps undo can go back. The oldest are forgotten first.
  final int limit;

  final List<_HistoryStep> _undoSteps = <_HistoryStep>[];
  final List<_HistoryStep> _redoSteps = <_HistoryStep>[];

  bool get canUndo => _undoSteps.isNotEmpty;
  bool get canRedo => _redoSteps.isNotEmpty;

  /// The page whose change is undone next, if any.
  InkController? get nextUndoPage => _undoSteps.lastOrNull?.page;

  /// Takes back the latest change. Returns the page it was on, or null,
  /// changing nothing, when there is nothing to undo or that page is busy.
  InkController? undo() => _travel(from: _undoSteps, to: _redoSteps);

  /// Makes again the change [undo] last took back. Returns the page it is
  /// on, or null, changing nothing, when there is nothing to redo.
  InkController? redo() => _travel(from: _redoSteps, to: _undoSteps);

  InkController? _travel({
    required List<_HistoryStep> from,
    required List<_HistoryStep> to,
  }) {
    if (from.isEmpty) return null;
    final InkController page = from.last.page;
    if (page._disposed || page._isBusy) return null;
    final _HistoryStep step = from.removeLast();
    to.add(_HistoryStep(page, page._committed));
    page._restore(step.snapshot);
    notifyListeners();
    return page;
  }

  void _record(InkController page, _InkSnapshot before, {required bool amend}) {
    if (!amend && limit > 0) {
      _undoSteps.add(_HistoryStep(page, before));
      if (_undoSteps.length > limit) _undoSteps.removeAt(0);
    }
    _redoSteps.clear();
    notifyListeners();
  }

  bool _lastIsOf(InkController page, int count) {
    if (_undoSteps.length < count) return false;
    for (int i = 1; i <= count; i++) {
      if (!identical(_undoSteps[_undoSteps.length - i].page, page)) {
        return false;
      }
    }
    return true;
  }

  /// Forgets the latest [count] steps, returning the snapshot of the
  /// oldest of them.
  _InkSnapshot _dropLast(int count) {
    late _InkSnapshot oldest;
    for (int i = 0; i < count; i++) {
      oldest = _undoSteps.removeLast().snapshot;
    }
    return oldest;
  }

  /// Forgets every step on [page], as when it is gone.
  void forget(InkController page) {
    final int before = _undoSteps.length + _redoSteps.length;
    _undoSteps.removeWhere((_HistoryStep step) => identical(step.page, page));
    _redoSteps.removeWhere((_HistoryStep step) => identical(step.page, page));
    if (before != _undoSteps.length + _redoSteps.length) notifyListeners();
  }
}

/// Whether no part of the closed [outline] comes within [margin] of any of
/// [bounds].
bool _outlineClearOf(
  List<InkVector> outline,
  List<Rect> bounds,
  double margin,
) {
  if (outline.length < 2) return false;
  for (final Rect rect in bounds) {
    final Rect near = rect.inflate(margin);
    for (int i = 0; i < outline.length; i++) {
      final InkVector a = outline[i];
      final InkVector b = outline[(i + 1) % outline.length];
      if (_segmentTouchesRect(a, b, near)) return false;
    }
  }
  return true;
}

/// Whether the segment from [a] to [b] meets [rect] (Liang-Barsky).
bool _segmentTouchesRect(InkVector a, InkVector b, Rect rect) {
  double t0 = 0;
  double t1 = 1;
  final double dx = b.x - a.x;
  final double dy = b.y - a.y;
  bool clip(double p, double q) {
    if (p == 0) return q >= 0;
    final double t = q / p;
    if (p < 0) {
      if (t > t1) return false;
      if (t > t0) t0 = t;
    } else {
      if (t < t0) return false;
      if (t < t1) t1 = t;
    }
    return true;
  }

  return clip(-dx, a.x - rect.left) &&
      clip(dx, rect.right - a.x) &&
      clip(-dy, a.y - rect.top) &&
      clip(dy, rect.bottom - a.y);
}

class _HistoryStep {
  const _HistoryStep(this.page, this.snapshot);

  final InkController page;

  /// The page as it was before the change, or after it for a redo.
  final _InkSnapshot snapshot;
}

class _InkSnapshot {
  const _InkSnapshot(this.strokes, this.images, this.stickies, this.texts);

  final List<Stroke> strokes;
  final List<NoteImageElement> images;
  final List<StickyNoteElement> stickies;
  final List<NoteTextElement> texts;
}

/// A sticky note being placed: shown where it would land while its pointer
/// is down, inserted when it lifts.
class StickyPlacementGesture {
  StickyPlacementGesture._({
    required this.pointer,
    required this.settings,
    required this.size,
    required this.pageBounds,
    required this.growsDown,
    required InkVector position,
  }) : _center = _clamp(position, size, pageBounds, growsDown);

  final int pointer;
  final StickyNoteSettings settings;

  /// The note's size on the page.
  final Size size;

  /// The page the note must stay on.
  final Rect pageBounds;

  /// Whether the page grows to the right and down to make room, as an
  /// infinite page does, so only its top-left edges hold the note in.
  final bool growsDown;

  InkVector _center;

  /// Where the note would be centered: the pointer, moved just far enough
  /// to keep the whole note on the page.
  InkVector get center => _center;

  /// The note this placement would insert.
  StickyNoteElement preview(String id) {
    return StickyNoteElement(
      id: id,
      center: _center,
      size: size,
      colorId: settings.color.id,
      paper: settings.paper,
    );
  }

  static InkVector _clamp(
    InkVector position,
    Size size,
    Rect page,
    bool growsDown,
  ) {
    double axis(double value, double start, double end, double half) {
      final double low = start + half;
      final double high = growsDown ? double.infinity : end - half;
      if (high < low) {
        return (start + end) / 2;
      }
      return value.clamp(low, high);
    }

    return InkVector(
      axis(position.x, page.left, page.right, size.width / 2),
      axis(position.y, page.top, page.bottom, size.height / 2),
    );
  }
}

/// A sticky note being dragged to a new spot by its pointer. The note on
/// the page follows as it moves; the history records the move once it
/// lifts.
class StickyDragGesture {
  StickyDragGesture._({
    required this.pointer,
    required this.original,
    required this.grab,
    required this.pageBounds,
    required this.growsDown,
  });

  final int pointer;

  /// The note as it was when taken hold of.
  final StickyNoteElement original;

  /// Where the pointer took hold, from the note's center.
  final InkVector grab;

  final Rect pageBounds;
  final bool growsDown;

  bool _moved = false;

  /// Whether the note has left where it was taken from.
  bool get moved => _moved;
}

class _Notifier extends ChangeNotifier {
  void notify() => notifyListeners();
}
