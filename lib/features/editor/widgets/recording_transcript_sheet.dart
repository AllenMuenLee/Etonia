import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../shared/navigation/app_sheets.dart';
import '../../library/note_recording_track.dart';
import 'recording_options.dart';

/// Shows [track]'s transcript. A line the recognizer timed can be tapped to
/// play the recording from there, through [onSeek].
Future<void> showRecordingTranscript(
  BuildContext context, {
  required NoteRecordingTrack track,
  ValueChanged<Duration>? onSeek,
}) {
  return showAppSheet<void>(
    context: context,
    motionKey: 'recording-transcript',
    builder: (BuildContext context) =>
        RecordingTranscriptSheet(track: track, onSeek: onSeek),
  );
}

class RecordingTranscriptSheet extends StatelessWidget {
  const RecordingTranscriptSheet({super.key, required this.track, this.onSeek});

  final NoteRecordingTrack track;
  final ValueChanged<Duration>? onSeek;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final RecordingTranscript? transcript = track.transcript;
    final List<TranscriptSegment> segments =
        transcript?.segments ?? const <TranscriptSegment>[];
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.sm,
            ),
            child: Row(
              children: <Widget>[
                AppIcon(
                  AppIcons.transcript,
                  size: 20,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey<String>('copy-transcript'),
                  tooltip: 'Copy transcript',
                  onPressed: transcript == null
                      ? null
                      : () {
                          Clipboard.setData(
                            ClipboardData(
                              text: segments
                                  .map((TranscriptSegment s) => s.text)
                                  .join('\n'),
                            ),
                          );
                          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                            const SnackBar(content: Text('Transcript copied.')),
                          );
                        },
                  icon: const AppIcon(AppIcons.copy),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView.builder(
              key: const ValueKey<String>('transcript-lines'),
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                0,
                AppSpacing.md,
                AppSpacing.lg,
              ),
              itemCount: segments.length,
              itemBuilder: (BuildContext context, int index) =>
                  _line(context, segments[index]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _line(BuildContext context, TranscriptSegment segment) {
    final AppColors colors = AppColors.of(context);
    final int? start = segment.startMs;
    final ValueChanged<Duration>? seek = onSeek;
    final Widget text = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (start != null)
            SizedBox(
              width: 52,
              child: Text(
                formatRecordingDuration(Duration(milliseconds: start)),
                style: TextStyle(
                  color: seek == null ? colors.textSecondary : colors.accent,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ),
          Expanded(child: Text(segment.text)),
        ],
      ),
    );
    if (start == null || seek == null) return text;
    return InkWell(
      borderRadius: AppBorderRadius.medium,
      onTap: () {
        Navigator.of(context).pop();
        seek(Duration(milliseconds: start));
      },
      child: Semantics(
        button: true,
        hint: 'Plays the recording from here',
        child: text,
      ),
    );
  }
}
