import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import '../audio/note_audio.dart';
import '../audio/stroke_replay_controller.dart';
import 'recording_options.dart';
import 'tool_options_bar.dart';

/// A time on a bar, in a slot of a fixed size so the bar does not shift as
/// the digits change.
class _BarTime extends StatelessWidget {
  const _BarTime({super.key, required this.duration, required this.axis});

  final Duration duration;
  final Axis axis;

  static const double _along = 40;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final bool across = axis == Axis.horizontal;
    return SizedBox(
      width: across ? _along : AppSizes.minTouchTarget,
      height: across ? AppSizes.minTouchTarget : 22,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            formatRecordingDuration(duration),
            maxLines: 1,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}

/// The time played over the whole, stacked in one small slot, so the
/// scrubber keeps the room.
class _BarTimes extends StatelessWidget {
  const _BarTimes({
    required this.played,
    required this.whole,
    required this.axis,
  });

  final Duration played;
  final Duration whole;
  final Axis axis;

  /// What it takes of the bar, along it.
  static const double along = 40;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    TextStyle style(Color color) => TextStyle(
      color: color,
      fontSize: 12,
      height: 1.15,
      fontWeight: FontWeight.w600,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    final bool across = axis == Axis.horizontal;
    return SizedBox(
      width: across ? along : AppSizes.minTouchTarget,
      height: across ? AppSizes.minTouchTarget : along,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                formatRecordingDuration(played),
                maxLines: 1,
                style: style(colors.textPrimary),
              ),
              Text(
                formatRecordingDuration(whole),
                maxLines: 1,
                style: style(colors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The sub toolbar while a recording is being made: how long it has run,
/// and pause or resume and stop.
class RecordingBar extends StatelessWidget {
  const RecordingBar({
    super.key,
    required this.recorder,
    required this.onPause,
    required this.onResume,
    required this.onStop,
    this.axis = Axis.horizontal,
  });

  final NoteAudioRecorder recorder;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onStop;
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: recorder,
      builder: (BuildContext context, Widget? _) {
        final bool paused = recorder.state == NoteAudioRecorderState.paused;
        final bool stopping = recorder.state == NoteAudioRecorderState.stopping;
        return ToolOptionsBar(
          key: const ValueKey<String>('recording-bar'),
          axis: axis,
          children: <Widget>[
            _BarTime(
              key: const ValueKey<String>('recording-elapsed'),
              duration: Duration(milliseconds: recorder.currentElapsedMs),
              axis: axis,
            ),
            OptionsButton(
              key: const ValueKey<String>('pause-resume-recording'),
              tooltip: paused ? 'Resume recording' : 'Pause recording',
              onPressed: stopping ? null : (paused ? onResume : onPause),
              child: AppIcon(paused ? AppIcons.play : AppIcons.pause),
            ),
            OptionsButton(
              key: const ValueKey<String>('stop-audio-recording'),
              tooltip: 'Stop and save recording',
              onPressed: stopping ? null : onStop,
              child: const AppIcon(AppIcons.stop),
            ),
          ],
        );
      },
    );
  }
}

/// The sub toolbar while a recording is open for replay: play and pause, a
/// scrubber between the time played and the whole, the speed, and close.
class ReplayBar extends StatelessWidget {
  const ReplayBar({
    super.key,
    required this.player,
    required this.replay,
    this.onClose,
    this.axis = Axis.horizontal,
  });

  static const List<double> speeds = <double>[0.75, 1, 1.25, 1.5, 2];

  /// The shortest the scrubber is made, however narrow the bar.
  static const double _leastTrack = 56;

  final NoteAudioPlayer player;
  final StrokeReplayController replay;
  final VoidCallback? onClose;
  final Axis axis;

  static String describeSpeed(double speed) =>
      '${speed == speed.roundToDouble() ? speed.toInt() : speed}x';

  @override
  Widget build(BuildContext context) {
    final bool across = axis == Axis.horizontal;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // The scrubber takes whatever the other controls leave, so the bar
        // fits the palette it is attached to where it can.
        final double length = across
            ? constraints.maxWidth
            : constraints.maxHeight;
        const double others = 3 * AppSizes.minTouchTarget + _BarTimes.along;
        final double track = length.isFinite
            ? (length - 2 * ToolOptionsBar.endPadding - others).clamp(
                _leastTrack,
                OptionsSlider.defaultLength * 2,
              )
            : OptionsSlider.defaultLength;
        return ListenableBuilder(
          listenable: Listenable.merge(<Listenable>[player, replay]),
          builder: (BuildContext context, Widget? _) {
            final int durationMs =
                replay.track?.durationMs ?? player.duration.inMilliseconds;
            final double max = durationMs <= 0 ? 1 : durationMs.toDouble();
            final double value = player.position.inMilliseconds
                .clamp(0, max.toInt())
                .toDouble();
            final double speed = speeds.contains(player.speed)
                ? player.speed
                : 1;
            return ToolOptionsBar(
              key: const ValueKey<String>('audio-replay-bar'),
              axis: axis,
              children: <Widget>[
                OptionsButton(
                  key: const ValueKey<String>('toggle-audio-replay'),
                  tooltip: player.isPlaying ? 'Pause replay' : 'Play replay',
                  onPressed: () =>
                      player.isPlaying ? player.pause() : player.play(),
                  child: AppIcon(
                    player.isPlaying ? AppIcons.pause : AppIcons.play,
                  ),
                ),
                _BarTimes(
                  played: player.position,
                  whole: Duration(milliseconds: durationMs),
                  axis: axis,
                ),
                OptionsSlider(
                  key: const ValueKey<String>('audio-replay-slider'),
                  axis: axis,
                  length: track,
                  value: value,
                  min: 0,
                  max: max,
                  semanticFormatterCallback: (double milliseconds) =>
                      formatRecordingDuration(
                        Duration(milliseconds: milliseconds.round()),
                      ),
                  onChanged: (double milliseconds) =>
                      player.seek(Duration(milliseconds: milliseconds.round())),
                ),
                OptionsButton(
                  key: const ValueKey<String>('audio-replay-speed'),
                  tooltip: 'Playback speed, ${describeSpeed(speed)}',
                  onPressed: () => player.setSpeed(
                    speeds[(speeds.indexOf(speed) + 1) % speeds.length],
                  ),
                  child: Text(
                    describeSpeed(speed),
                    maxLines: 1,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                OptionsButton(
                  key: const ValueKey<String>('close-audio-replay'),
                  tooltip: 'Close replay',
                  onPressed: onClose,
                  child: const AppIcon(AppIcons.close),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
