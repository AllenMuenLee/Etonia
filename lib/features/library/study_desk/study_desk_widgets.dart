import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/theme/app_icons.dart';
import '../../../shared/widgets/pressable.dart';
import 'study_desk_controller.dart';

//// The chat beside the page a citation points at, with a handle between them to
/// drag.
///
/// [trailing] comes and goes. Neither side is ever laid out for each frame of
/// that: the chat takes the width it will rest at (or all of it, as the page
/// closes) the moment it changes, once, and the page is laid out once at its
/// own resting width. All that moves after is a reveal: the page slides in
/// from the edge over the room it is to take, and slides out again over what
/// it uncovers, and is let go once shut. Text that wraps, maths that is
/// typeset, and a page being written on are not measured sixty times a second.
class StudyResizableSplit extends StatefulWidget {
  const StudyResizableSplit({super.key, required this.leading, this.trailing});

  final Widget leading;
  final Widget? trailing;

  @override
  State<StudyResizableSplit> createState() => _StudyResizableSplitState();
}

class _StudyResizableSplitState extends State<StudyResizableSplit>
    with SingleTickerProviderStateMixin {
  static const double _handleWidth = 24;

  double _fraction = .5;
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    value: widget.trailing == null ? 0 : 1,
  )..addStatusListener(_settled);
  late Widget? _shown = widget.trailing;

  @override
  void didUpdateWidget(StudyResizableSplit oldWidget) {
    super.didUpdateWidget(oldWidget);
    final Widget? next = widget.trailing;
    if (next != null) {
      _shown = next;
      if (oldWidget.trailing == null || _reveal.value < 1) {
        if (MediaQuery.disableAnimationsOf(context)) {
          unawaited(
            _reveal
                .animateTo(1, duration: AppMotion.reduced)
                .orCancel
                .catchError((Object _) {}),
          );
        } else {
          unawaited(
            _reveal
                .animateWith(
                  SpringSimulation(AppMotion.sheet, _reveal.value, 1, 0),
                )
                .orCancel
                .catchError((Object _) {}),
          );
        }
      }
    } else if (_shown != null && oldWidget.trailing != null) {
      unawaited(
        _reveal
            .animateBack(
              0,
              duration: MediaQuery.disableAnimationsOf(context)
                  ? AppMotion.reduced
                  : AppMotion.glance,
              curve: AppMotion.zoomOutCurve,
            )
            .orCancel
            .catchError((Object _) {}),
      );
    }
  }

  @override
  void dispose() {
    _reveal.dispose();
    super.dispose();
  }

  void _settled(AnimationStatus status) {
    if (status == AnimationStatus.dismissed &&
        widget.trailing == null &&
        _shown != null &&
        mounted) {
      setState(() => _shown = null);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final colors = AppColors.of(context);
      final rtl = Directionality.of(context) == TextDirection.rtl;
      final double total = constraints.maxWidth;
      final available = total - _handleWidth;
      final minimum = (available * .35).clamp(0.0, 320.0);
      final restingLeading = (available * _fraction).clamp(
        minimum,
        available - minimum,
      );
      final restingTrailing = available - restingLeading;
      String paperWidth(double delta) =>
          '${((1 - ((restingLeading + delta) / available).clamp(minimum / available, 1 - minimum / available)) * 100).round()} percent';
      void resize(double delta) => setState(() {
        _fraction = ((restingLeading + delta) / available).clamp(
          minimum / available,
          1 - minimum / available,
        );
      });
      final Widget? shown = _shown;
      final bool open = widget.trailing != null;
      final Widget handle = Semantics(
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
                    width: _handleWidth,
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
      );
      final double leadingWidth = open ? restingLeading : total;
      final double restingRegion = _handleWidth + restingTrailing;
      // Laid out once, as the page's width: it is slid, never resized.
      final Widget trailingRegion = shown == null
          ? const SizedBox.shrink()
          : SizedBox(
              width: restingRegion,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  handle,
                  Expanded(
                    child: ExcludeSemantics(
                      excluding: !open,
                      child: IgnorePointer(
                        ignoring: !open,
                        child: RepaintBoundary(child: shown),
                      ),
                    ),
                  ),
                ],
              ),
            );
      return Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          PositionedDirectional(
            start: 0,
            top: 0,
            bottom: 0,
            width: leadingWidth,
            child: widget.leading,
          ),
          if (shown != null)
            AnimatedBuilder(
              animation: _reveal,
              child: trailingRegion,
              builder: (context, child) {
                final double r = _reveal.value.clamp(0.0, 1.0);
                return PositionedDirectional(
                  end: 0,
                  top: 0,
                  bottom: 0,
                  width: restingRegion * r,
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: AlignmentDirectional.centerStart,
                      minWidth: restingRegion,
                      maxWidth: restingRegion,
                      child: FadeTransition(opacity: _reveal, child: child),
                    ),
                  ),
                );
              },
            ),
        ],
      );
    },
  );
}

/// The desk with the history beside it: the history slides in from the edge and
/// pushes the desk over, and slides out again.
///
/// The history is laid out once, at its own width, and the desk once, at the
/// width it will rest at (all of it, as the history closes), the moment it
/// opens or shuts: from then on both only move, which costs no layout, where
/// resizing the desk for each frame would measure the chat's text and maths
/// again each time. What the history held is let go once it is shut.
class StudySidebarLayout extends StatefulWidget {
  const StudySidebarLayout({
    super.key,
    required this.open,
    required this.width,
    required this.sidebar,
    required this.main,
    this.dividerColor,
  });

  final bool open;
  final double width;
  final Widget sidebar;
  final Widget main;
  final Color? dividerColor;

  @override
  State<StudySidebarLayout> createState() => _StudySidebarLayoutState();
}

class _StudySidebarLayoutState extends State<StudySidebarLayout>
    with SingleTickerProviderStateMixin {
  late final AnimationController _run = AnimationController(
    vsync: this,
    value: widget.open ? 1 : 0,
  )..addStatusListener(_settled);
  late Widget? _shown = widget.open ? widget.sidebar : null;

  @override
  void didUpdateWidget(StudySidebarLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.open) {
      _shown = widget.sidebar;
      if (!oldWidget.open || _run.value < 1) {
        if (MediaQuery.disableAnimationsOf(context)) {
          unawaited(
            _run
                .animateTo(1, duration: AppMotion.reduced)
                .orCancel
                .catchError((Object _) {}),
          );
        } else {
          unawaited(
            _run
                .animateWith(
                  SpringSimulation(AppMotion.sheet, _run.value, 1, 0),
                )
                .orCancel
                .catchError((Object _) {}),
          );
        }
      }
    } else if (_shown != null && oldWidget.open) {
      unawaited(
        _run
            .animateBack(
              0,
              duration: MediaQuery.disableAnimationsOf(context)
                  ? AppMotion.reduced
                  : AppMotion.glance,
              curve: AppMotion.zoomOutCurve,
            )
            .orCancel
            .catchError((Object _) {}),
      );
    }
  }

  @override
  void dispose() {
    _run.dispose();
    super.dispose();
  }

  void _settled(AnimationStatus status) {
    if (status == AnimationStatus.dismissed &&
        !widget.open &&
        _shown != null &&
        mounted) {
      setState(() => _shown = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget? shown = _shown;
    final Color? divider = widget.dividerColor;
    return LayoutBuilder(
      builder: (context, constraints) {
        final double total = constraints.maxWidth;
        final double mainWidth = widget.open ? total - widget.width : total;
        return AnimatedBuilder(
          animation: _run,
          child: widget.main,
          builder: (context, main) {
            final double r = _run.value.clamp(0.0, 1.0);
            return Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                // The history comes first, as it reads, and they never overlap.
                if (shown != null)
                  PositionedDirectional(
                    start: -widget.width * (1 - r),
                    top: 0,
                    bottom: 0,
                    width: widget.width,
                    child: ExcludeSemantics(
                      excluding: !widget.open,
                      child: IgnorePointer(
                        ignoring: !widget.open,
                        child: FadeTransition(
                          opacity: _run,
                          child: DecoratedBox(
                            position: DecorationPosition.foreground,
                            decoration: BoxDecoration(
                              border: divider == null
                                  ? null
                                  : BorderDirectional(
                                      end: BorderSide(
                                        color: divider,
                                        width: AppSizes.hairline,
                                      ),
                                    ),
                            ),
                            child: RepaintBoundary(child: shown),
                          ),
                        ),
                      ),
                    ),
                  ),
                PositionedDirectional(
                  start: shown == null ? 0 : widget.width * r,
                  top: 0,
                  bottom: 0,
                  width: mainWidth,
                  child: main!,
                ),
              ],
            );
          },
        );
      },
    );
  }
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
    final Widget surface = Material(
      color: colors.surface,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: onTap == null
          ? child
          : InkWell(customBorder: shape, onTap: onTap, child: child),
    );
    // A card that can be pressed sinks under the finger and springs back.
    return onTap == null
        ? surface
        : Pressable(
            type: PressableType.card,
            borderRadius: AppBorderRadius.large,
            child: surface,
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
