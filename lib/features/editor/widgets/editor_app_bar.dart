import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/theme/app_icons.dart';
import '../audio/note_audio.dart';
import '../audio/stroke_replay_controller.dart';

/// The slim top bar: navigation, the document title or the open notes'
/// tabs, and settings. It spans the whole width, as the page does. Undo and
/// redo, find, and the page controls float over the page instead.
///
/// Callbacks are placeholders until navigation and renaming exist; a null
/// callback disables its control.
class EditorAppBar extends StatelessWidget implements PreferredSizeWidget {
  const EditorAppBar({
    super.key,
    required this.title,
    required this.centerTitle,
    this.onMenuPressed,
    this.leadingIsBack = false,
    this.onTitlePressed,
    this.onSettingsPressed,
    this.onFullscreenPressed,
    this.tabs,
    this.audioPlayer,
    this.replayController,
    this.onCloseReplay,
  });

  /// The open notes, shown in place of the title when there are any.
  final Widget? tabs;

  final String title;
  final bool centerTitle;
  final VoidCallback? onMenuPressed;

  /// Shows the navigation control as a way back to the library instead of
  /// a menu.
  final bool leadingIsBack;
  final VoidCallback? onTitlePressed;
  final VoidCallback? onSettingsPressed;

  /// Puts the bar and its tabs away, leaving the page the whole screen.
  /// Without it there is no fullscreen button.
  final VoidCallback? onFullscreenPressed;
  final NoteAudioPlayer? audioPlayer;
  final StrokeReplayController? replayController;
  final VoidCallback? onCloseReplay;

  @override
  Size get preferredSize => Size.fromHeight(
    AppSizes.appBarHeight +
        ((replayController?.isActive ?? false) ? _ReplayBar.height : 0),
  );

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return GlassMaterial(
          color: AppGlass.surface(colors),
          child: SafeArea(
            bottom: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  height: AppSizes.appBarHeight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xxs,
                    ),
                    child: FocusTraversalGroup(
                      policy: OrderedTraversalPolicy(),
                      child: NavigationToolbar(
                        centerMiddle: centerTitle && tabs == null,
                        middleSpacing: AppSpacing.xxs,
                        leading: FocusTraversalOrder(
                          order: const NumericFocusOrder(1),
                          child: IconButton(
                            tooltip: leadingIsBack
                                ? 'Back to library'
                                : 'Open navigation menu',
                            onPressed: onMenuPressed,
                            icon: Icon(
                              leadingIsBack ? AppIcons.back : AppIcons.sidebar,
                            ),
                          ),
                        ),
                        middle: FocusTraversalOrder(
                          order: const NumericFocusOrder(2),
                          child:
                              tabs ??
                              EditorTitleButton(
                                title: title,
                                onPressed: onTitlePressed,
                              ),
                        ),
                        trailing: FocusTraversalOrder(
                          order: const NumericFocusOrder(3),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              IconButton(
                                tooltip: 'Settings',
                                onPressed: onSettingsPressed,
                                icon: const Icon(AppIcons.settings),
                              ),
                              // In the corner, where the page's own way back
                              // out of fullscreen then sits.
                              if (onFullscreenPressed != null)
                                IconButton(
                                  key: const ValueKey<String>(
                                    'enter-fullscreen',
                                  ),
                                  tooltip: 'Full screen',
                                  onPressed: onFullscreenPressed,
                                  icon: const Icon(AppIcons.fullscreen),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if ((replayController?.isActive ?? false) &&
                    audioPlayer != null)
                  _ReplayBar(
                    player: audioPlayer!,
                    replay: replayController!,
                    onClose: onCloseReplay,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ReplayBar extends StatelessWidget {
  const _ReplayBar({required this.player, required this.replay, this.onClose});

  static const double height = 64;
  static const List<double> speeds = <double>[0.75, 1, 1.25, 1.5, 2];
  final NoteAudioPlayer player;
  final StrokeReplayController replay;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey<String>('audio-replay-bar'),
      height: height,
      child: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[player, replay]),
        builder: (BuildContext context, Widget? _) {
          final AppColors colors = AppColors.of(context);
          final int durationMs =
              replay.track?.durationMs ?? player.duration.inMilliseconds;
          final double max = durationMs <= 0 ? 1 : durationMs.toDouble();
          final double value = player.position.inMilliseconds
              .clamp(0, max.toInt())
              .toDouble();
          return ColoredBox(
            color: colors.recordingSurface,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
              child: Row(
                children: <Widget>[
                  IconButton(
                    key: const ValueKey<String>('toggle-audio-replay'),
                    tooltip: player.isPlaying ? 'Pause replay' : 'Play replay',
                    onPressed: () =>
                        player.isPlaying ? player.pause() : player.play(),
                    icon: Icon(
                      player.isPlaying ? AppIcons.pause : AppIcons.play,
                    ),
                  ),
                  Text(
                    _formatDuration(player.position),
                    style: TextStyle(
                      color: colors.recordingForeground,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: colors.accent,
                        inactiveTrackColor: colors.scrubberTrack,
                        thumbColor: colors.accent,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 10,
                        ),
                      ),
                      child: Slider(
                        key: const ValueKey<String>('audio-replay-slider'),
                        min: 0,
                        max: max,
                        value: value,
                        onChanged: (double milliseconds) {
                          player.seek(
                            Duration(milliseconds: milliseconds.round()),
                          );
                        },
                      ),
                    ),
                  ),
                  Text(
                    _formatDuration(Duration(milliseconds: durationMs)),
                    style: TextStyle(
                      color: colors.recordingForeground,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  DropdownButtonHideUnderline(
                    child: DropdownButton<double>(
                      key: const ValueKey<String>('audio-replay-speed'),
                      value: speeds.contains(player.speed) ? player.speed : 1,
                      onChanged: (double? value) {
                        if (value != null) player.setSpeed(value);
                      },
                      items: <DropdownMenuItem<double>>[
                        for (final double speed in speeds)
                          DropdownMenuItem<double>(
                            value: speed,
                            child: Text('${speed}x'),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const ValueKey<String>('close-audio-replay'),
                    tooltip: 'Close replay',
                    onPressed: onClose,
                    icon: const Icon(AppIcons.close),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

String _formatDuration(Duration duration) {
  final int totalSeconds = duration.inSeconds.clamp(0, 99 * 60 + 59);
  final String minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
  final String seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// Looks like an inline-editable title; renaming is not implemented yet.
class EditorTitleButton extends StatelessWidget {
  const EditorTitleButton({
    super.key,
    required this.title,
    required this.onPressed,
  });

  final String title;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextStyle style = Theme.of(context).textTheme.titleMedium!;

    return Tooltip(
      message: 'Rename note',
      excludeFromSemantics: true,
      child: Semantics(
        container: true,
        button: true,
        enabled: onPressed != null,
        label: 'Note title, $title',
        child: InkWell(
          onTap: onPressed,
          borderRadius: AppBorderRadius.medium,
          hoverColor: colors.textPrimary.withValues(alpha: 0.06),
          focusColor: colors.textPrimary.withValues(alpha: 0.10),
          highlightColor: colors.textPrimary.withValues(alpha: 0.12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: AppSizes.minTouchTarget,
              minWidth: AppSizes.minTouchTarget,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              child: Align(
                widthFactor: 1,
                heightFactor: 1,
                child: ExcludeSemantics(
                  child: Text(
                    title,
                    style: onPressed == null
                        ? style.copyWith(color: colors.textSecondary)
                        : style,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
