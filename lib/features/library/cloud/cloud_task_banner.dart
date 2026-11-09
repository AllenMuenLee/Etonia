import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../shared/widgets/etonia_mascot.dart';
import 'cloud_task_controller.dart';
import 'goodnotes_drive_replicator.dart';

/// A slim bar in the library while a backup, restore or Goodnotes import is
/// running, so it can be seen, and stopped, from wherever the person went
/// after starting it. It takes no room when nothing is running.
class CloudTaskBanner extends StatelessWidget {
  const CloudTaskBanner({super.key, required this.tasks, this.onTap});

  final CloudTaskController tasks;

  /// Taps open the page that started the work.
  final VoidCallback? onTap;

  /// How tall Etonia is as she runs, and the width she runs back and forth in.
  static const double _runnerHeight = 56;
  static const double _runnerTrack = 160;

  static String _title(CloudTask task) => switch (task) {
    CloudTask.backUp => 'Backing up your library',
    CloudTask.restore => 'Restoring your library',
    CloudTask.replicate => 'Importing from Goodnotes',
  };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: tasks,
      builder: (BuildContext context, Widget? _) {
        final CloudTask? task = tasks.task;
        if (task == null) return const SizedBox.shrink();
        final AppColors colors = AppColors.of(context);
        final TextTheme text = Theme.of(context).textTheme;
        final String detail = tasks.cancelling
            ? 'Stopping…'
            : <String?>[
                tasks.progress?.phase,
                tasks.progress?.currentName,
              ].whereType<String>().join(' · ');
        return Semantics(
          container: true,
          liveRegion: true,
          label: '${_title(task)}. $detail',
          child: Material(
            color: colors.surfaceMuted,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.xs,
                  AppSpacing.xs,
                  AppSpacing.xs,
                ),
                child: Row(
                  children: <Widget>[
                    AppIcon(AppIcons.cloud, size: 18, color: colors.accent),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: ExcludeSemantics(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(_title(task), style: text.titleSmall),
                            if (detail.isNotEmpty)
                              Text(
                                detail,
                                style: text.bodySmall!.copyWith(
                                  color: colors.textSecondary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            const SizedBox(height: AppSpacing.xxs),
                            LinearProgressIndicator(
                              value: tasks.progress?.fraction,
                              minHeight: 3,
                            ),
                          ],
                        ),
                      ),
                    ),
                    // She runs whatever the task, and keeps to the right of
                    // the banner, between the text and Cancel.
                    const SizedBox(
                      key: ValueKey<String>('banner-runner-track'),
                      width: _runnerTrack,
                      height: _runnerHeight,
                      child: EtoniaRunner(
                        key: ValueKey<String>('banner-runner'),
                        height: _runnerHeight,
                      ),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, AppSizes.minTouchTarget),
                      ),
                      onPressed: tasks.canCancel ? tasks.cancel : null,
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// What stands for a Goodnotes file that is listed but not yet in the library:
/// a page outline, with a spinner while it is the one being loaded.
class PendingImportArt extends StatelessWidget {
  const PendingImportArt({super.key, required this.item});

  final ImportItem item;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final bool loading = item.status == ImportStatus.loading;
    return AspectRatio(
      aspectRatio: 0.75,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: AppBorderRadius.medium,
          border: Border.all(color: colors.divider, width: AppSizes.hairline),
        ),
        child: Center(
          child: loading
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : AppIcon(
                  item.requested ? AppIcons.cloudDownload : AppIcons.note,
                  size: 24,
                  color: item.requested
                      ? colors.accent
                      : colors.textSecondary.withValues(alpha: 0.6),
                ),
        ),
      ),
    );
  }
}
