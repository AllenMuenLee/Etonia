import 'dart:async';

import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

import '../../library/note_recording_track.dart';
import '../ink/ink_controller.dart';
import '../ink/stroke.dart';

/// Reconstructs recorded ink at the audio playhead without mutating the note.
class StrokeReplayController extends ChangeNotifier {
  StrokeReplayController();

  /// What ink not yet written at the playhead is drawn in.
  static const Color unwrittenColor = Color(0xFFC8C8C8);

  NoteRecordingTrack? _track;
  int _positionMs = 0;
  Stroke? _highlighted;
  Timer? _highlightTimer;

  NoteRecordingTrack? get track => _track;
  bool get isActive => _track != null;
  int get positionMs => _positionMs;
  Stroke? get highlightedStroke => _highlighted;

  void open(NoteRecordingTrack track) {
    _track = track;
    _positionMs = 0;
    _highlighted = null;
    notifyListeners();
  }

  void close() {
    if (_track == null) return;
    _track = null;
    _positionMs = 0;
    _highlighted = null;
    _highlightTimer?.cancel();
    notifyListeners();
  }

  void updatePosition(Duration position) {
    final int next = position.inMilliseconds.clamp(
      0,
      _track?.durationMs ?? position.inMilliseconds,
    );
    if (next == _positionMs) return;
    _positionMs = next;
    notifyListeners();
  }

  /// Whether [stroke] belongs to the open recording and has not begun to
  /// be written at the playhead. Such ink shows light gray.
  bool isUnwritten(Stroke stroke) {
    final NoteRecordingTrack? active = _track;
    if (active == null || stroke.recordingId != active.id) return false;
    final int? completed = stroke.completedAtMs;
    return completed != null &&
        completed > _positionMs &&
        revealProgress(stroke) <= 0;
  }

  double revealProgress(Stroke stroke) {
    final NoteRecordingTrack? active = _track;
    if (active == null || stroke.recordingId != active.id) return 1;
    final int? completed = stroke.completedAtMs;
    if (completed == null) return 1;
    final int drawingMs = (stroke.sampleDeltasMs ?? const <int>[]).fold<int>(
      0,
      (int total, int delta) => total + delta,
    );
    if (drawingMs <= 0) return _positionMs >= completed ? 1 : 0;
    final int started = completed - drawingMs;
    return ((_positionMs - started) / drawingMs).clamp(0.0, 1.0);
  }

  bool erasedStrokeIsVisible(ErasedStrokeRecord record) {
    final NoteRecordingTrack? active = _track;
    if (active == null || record.recordingId != active.id) return false;
    final int written = record.stroke.completedAtMs ?? 0;
    return written <= _positionMs && _positionMs < record.erasedAtMs;
  }

  void flash(Stroke stroke) {
    _highlightTimer?.cancel();
    _highlighted = stroke;
    notifyListeners();
    _highlightTimer = Timer(const Duration(milliseconds: 500), () {
      _highlighted = null;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    super.dispose();
  }
}
