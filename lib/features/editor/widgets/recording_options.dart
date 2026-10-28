import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../shared/widgets/app_controls.dart';
import '../../library/note_recording_track.dart';
import '../audio/note_audio.dart';
import '../audio/recording_transcriber.dart';
import '../audio/stroke_replay_controller.dart';
import '../page/note_document.dart';

/// What the palette's Record button needs: the microphone, the note's
/// recordings, and what to do with them.
class RecordingToolData {
  const RecordingToolData({
    required this.recorder,
    required this.document,
    required this.replay,
    required this.onStart,
    required this.onPause,
    required this.onResume,
    required this.onStop,
    required this.onOpen,
    this.transcription,
    this.onTranscribe,
    this.onShowTranscript,
  });

  final NoteAudioRecorder recorder;

  /// Holds the recordings; listened to so a new one appears in the list.
  final NoteDocument document;
  final StrokeReplayController replay;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onStop;

  /// Opens a recording for replay.
  final ValueChanged<NoteRecordingTrack> onOpen;

  /// Which recording is being transcribed. Without it there is no
  /// transcription.
  final RecordingTranscriptionController? transcription;

  /// Transcribes a recording, at the user's request only.
  final ValueChanged<NoteRecordingTrack>? onTranscribe;
  final ValueChanged<NoteRecordingTrack>? onShowTranscript;

  Listenable get listenable => Listenable.merge(<Listenable?>[
    recorder,
    document,
    replay,
    transcription,
  ]);
}

/// The Record button's panel: start, pause, and stop a recording, and pick
/// any of the note's recordings to replay.
class RecordingOptions extends StatelessWidget {
  const RecordingOptions({super.key, required this.data, this.onChosen});

  final RecordingToolData data;

  /// Called once a recording has been chosen, to close the panel.
  final VoidCallback? onChosen;

  static const double _listHeight = 220;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: data.listenable,
      builder: (BuildContext context, Widget? _) {
        final List<NoteRecordingTrack> tracks = data.document.recordings;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const SectionLabel('Record'),
            _controls(context),
            const SizedBox(height: AppSpacing.md),
            const SectionLabel('Recordings'),
            if (tracks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Text(
                  'No recordings yet',
                  key: const ValueKey<String>('no-recordings'),
                  style: TextStyle(color: AppColors.of(context).textSecondary),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: _listHeight),
                // Not a ListView: the menu measures its panel, which a
                // viewport cannot answer.
                child: SingleChildScrollView(
                  primary: false,
                  key: const ValueKey<String>('recordings-list'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (final NoteRecordingTrack track in tracks.reversed)
                        _row(context, track),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _controls(BuildContext context) {
    final NoteAudioRecorder recorder = data.recorder;
    final AppColors colors = AppColors.of(context);
    if (recorder.state == NoteAudioRecorderState.idle) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey<String>('start-audio-recording'),
          onPressed: data.onStart,
          icon: const Icon(AppIcons.microphone),
          label: const Text('Record audio & strokes'),
        ),
      );
    }
    final bool paused = recorder.state == NoteAudioRecorderState.paused;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.recordingSurface,
        borderRadius: AppBorderRadius.medium,
      ),
      child: Row(
        children: <Widget>[
          RecordingPulse(running: !paused),
          Expanded(
            child: Text(
              formatRecordingDuration(
                Duration(milliseconds: recorder.currentElapsedMs),
              ),
              key: const ValueKey<String>('recording-elapsed'),
              style: TextStyle(
                color: colors.recordingForeground,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            key: const ValueKey<String>('pause-resume-recording'),
            tooltip: paused ? 'Resume recording' : 'Pause recording',
            onPressed: paused ? data.onResume : data.onPause,
            icon: Icon(paused ? AppIcons.play : AppIcons.pause),
          ),
          IconButton(
            key: const ValueKey<String>('stop-audio-recording'),
            tooltip: 'Stop and save recording',
            onPressed: recorder.state == NoteAudioRecorderState.stopping
                ? null
                : data.onStop,
            icon: const Icon(AppIcons.stop),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, NoteRecordingTrack track) {
    final AppColors colors = AppColors.of(context);
    final bool open = data.replay.track?.id == track.id;
    final bool recording = data.recorder.state != NoteAudioRecorderState.idle;
    return ListTile(
      key: ValueKey<String>('recording-${track.id}'),
      dense: true,
      selected: open,
      selectedColor: colors.accent,
      enabled: !recording,
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      leading: Icon(open ? AppIcons.pause : AppIcons.play),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        formatRecordingDuration(Duration(milliseconds: track.durationMs)),
      ),
      trailing: _transcriptControl(track, recording: recording),
      onTap: () {
        data.onOpen(track);
        onChosen?.call();
      },
    );
  }

  /// Transcribe, its progress while it runs, or the transcript once made.
  Widget? _transcriptControl(
    NoteRecordingTrack track, {
    required bool recording,
  }) {
    final RecordingTranscriptionController? transcription = data.transcription;
    final ValueChanged<NoteRecordingTrack>? onTranscribe = data.onTranscribe;
    if (transcription == null || onTranscribe == null) return null;
    if (transcription.activeId == track.id) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(
              key: ValueKey<String>('transcribing-${track.id}'),
              strokeWidth: 2,
              value: transcription.progress,
            ),
          ),
          IconButton(
            key: ValueKey<String>('stop-transcribing-${track.id}'),
            tooltip: 'Stop transcribing',
            onPressed: transcription.cancel,
            icon: const Icon(AppIcons.stop),
          ),
        ],
      );
    }
    if (track.transcript != null && data.onShowTranscript != null) {
      return IconButton(
        key: ValueKey<String>('show-transcript-${track.id}'),
        tooltip: 'Show transcript',
        onPressed: () {
          data.onShowTranscript!(track);
          onChosen?.call();
        },
        icon: const Icon(AppIcons.transcript),
      );
    }
    return IconButton(
      key: ValueKey<String>('transcribe-${track.id}'),
      tooltip: 'Transcribe',
      // Never while recording: the recognizer would compete with the ink.
      onPressed: recording || transcription.isBusy
          ? null
          : () => onTranscribe(track),
      icon: const Icon(AppIcons.transcribe),
    );
  }
}

String formatRecordingDuration(Duration duration) {
  final int totalSeconds = duration.inSeconds.clamp(0, 99 * 60 + 59);
  final String minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
  final String seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// The glyph on the Record button: a microphone, or the pulsing dot and
/// the elapsed time while recording.
class RecordingGlyph extends StatelessWidget {
  const RecordingGlyph({super.key, required this.recorder});

  final NoteAudioRecorder recorder;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: recorder,
      builder: (BuildContext context, Widget? _) {
        if (recorder.state == NoteAudioRecorderState.idle) {
          return const Icon(AppIcons.microphone);
        }
        return RecordingPulse(
          running: recorder.state == NoteAudioRecorderState.recording,
          margin: EdgeInsets.zero,
        );
      },
    );
  }
}

class RecordingPulse extends StatefulWidget {
  const RecordingPulse({
    super.key,
    required this.running,
    this.margin = const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
  });

  final bool running;
  final EdgeInsets margin;

  @override
  State<RecordingPulse> createState() => _RecordingPulseState();
}

class _RecordingPulseState extends State<RecordingPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.pulse,
  );

  void _sync() {
    final bool animate =
        widget.running && !MediaQuery.disableAnimationsOf(context);
    if (animate && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!animate && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(RecordingPulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color color = AppColors.of(context).danger;
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) => Container(
        key: const ValueKey<String>('recording-pulse'),
        width: 12,
        height: 12,
        margin: widget.margin,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: color.withValues(alpha: 0.25 + _controller.value * 0.35),
              blurRadius: 4 + _controller.value * 7,
              spreadRadius: _controller.value * 2,
            ),
          ],
        ),
      ),
    );
  }
}
