import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/theme/app_icons.dart';
import 'study_desk_controller.dart';

class StudyResizableSplit extends StatefulWidget {
  const StudyResizableSplit({
    super.key,
    required this.leading,
    required this.trailing,
  });

  final Widget leading;
  final Widget trailing;

  @override
  State<StudyResizableSplit> createState() => _StudyResizableSplitState();
}

class _StudyResizableSplitState extends State<StudyResizableSplit> {
  double _fraction = .5;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final available = constraints.maxWidth - 24;
      final minimum = (available * .35).clamp(0.0, 320.0);
      final leadingWidth = (available * _fraction).clamp(
        minimum,
        available - minimum,
      );
      final rtl = Directionality.of(context) == TextDirection.rtl;
      String paperWidth(double delta) =>
          '${((1 - ((leadingWidth + delta) / available).clamp(minimum / available, 1 - minimum / available)) * 100).round()} percent';
      void resize(double delta) => setState(() {
        _fraction = ((leadingWidth + delta) / available).clamp(
          minimum / available,
          1 - minimum / available,
        );
      });
      final colors = AppColors.of(context);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: leadingWidth, child: widget.leading),
          Semantics(
            label: 'Resize graded paper',
            value: paperWidth(0),
            increasedValue: paperWidth(-32),
            decreasedValue: paperWidth(32),
            onIncrease: () => resize(-32),
            onDecrease: () => resize(32),
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                    resize(rtl ? 32 : -32),
                const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                    resize(rtl ? -32 : 32),
                const SingleActivator(LogicalKeyboardKey.home): () =>
                    setState(() => _fraction = .5),
              },
              child: Focus(
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: Tooltip(
                    message: 'Drag to resize · Double-click to reset',
                    child: GestureDetector(
                      key: const ValueKey('study-graded-paper-resize'),
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragUpdate: (details) =>
                          resize(details.delta.dx * (rtl ? -1 : 1)),
                      onDoubleTap: () => setState(() => _fraction = .5),
                      child: SizedBox(
                        width: 24,
                        child: Center(
                          child: Container(
                            width: 4,
                            height: 40,
                            decoration: BoxDecoration(
                              color: colors.textSecondary.withValues(alpha: .4),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(child: widget.trailing),
        ],
      );
    },
  );
}

class StudySuggestedClasses extends StatelessWidget {
  const StudySuggestedClasses({
    super.key,
    required this.controller,
    this.onSelected,
    this.compact = false,
  });

  final StudyDeskController controller;
  final VoidCallback? onSelected;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final folders = controller.suggestedClassFolders;
    if (folders.isEmpty) return const SizedBox.shrink();
    final colors = AppColors.of(context);
    return Column(
      key: const ValueKey('study-suggested-classes'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Suggested classes',
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: 8),
        if (!compact) ...[
          Text(
            'Turn a library folder into your next workspace.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: 12),
        ],
        for (final folder in folders)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: ListTile(
              key: ValueKey('study-suggest-class-${folder.id}'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadii.small),
                side: BorderSide(color: colors.divider),
              ),
              leading: Icon(AppIcons.folder, size: 20, color: colors.accent),
              title: Text(
                folder.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(AppIcons.add, size: 18),
              onTap: () {
                controller.initializeSuggestedClass(folder);
                onSelected?.call();
              },
            ),
          ),
      ],
    );
  }
}

class StudySurface extends StatelessWidget {
  const StudySurface({super.key, required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final shape = RoundedSuperellipseBorder(
      borderRadius: AppBorderRadius.large,
      side: BorderSide(color: colors.divider, width: AppSizes.hairline),
    );
    return Material(
      color: colors.surface,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: onTap == null
          ? child
          : InkWell(customBorder: shape, onTap: onTap, child: child),
    );
  }
}

class StudyPageHeader extends StatelessWidget {
  const StudyPageHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.action,
    this.leading,
    this.titleStyle,
  });

  final String title;
  final String subtitle;
  final Widget? action;
  final Widget? leading;
  final TextStyle? titleStyle;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final text = Theme.of(context).textTheme;
      final colors = AppColors.of(context);
      final heading = Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: AppSpacing.md),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(title, style: titleStyle ?? text.titleLarge),
                ),
                const SizedBox(height: AppSpacing.xxs),
                Text(
                  subtitle,
                  style: text.bodySmall?.copyWith(color: colors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      );
      if (constraints.maxWidth < 600 ||
          MediaQuery.textScalerOf(context).scale(17) > 24) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            heading,
            if (action != null) ...[
              const SizedBox(height: AppSpacing.md),
              action!,
            ],
          ],
        );
      }
      return Row(
        children: [
          Expanded(child: heading),
          if (action != null) ...[
            const SizedBox(width: AppSpacing.md),
            action!,
          ],
        ],
      );
    },
  );
}

class StudyEmptyState extends StatelessWidget {
  const StudyEmptyState({
    super.key,
    required this.symbol,
    required this.title,
    required this.message,
    this.action,
  });

  final Widget symbol;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            symbol,
            const SizedBox(height: AppSpacing.lg),
            Semantics(
              header: true,
              child: Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.of(context).textSecondary,
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: AppSpacing.lg),
              action!,
            ],
          ],
        ),
      ),
    ),
  );
}
