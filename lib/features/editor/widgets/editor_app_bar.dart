import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/theme/app_icons.dart';

/// The slim top bar: navigation, the document title or the open notes'
/// tabs, page controls, and settings. It spans the whole width, as the
/// page does. Undo and redo float over the page instead, unless
/// [historyControls] is given.
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
    this.historyControls,
    this.pageControls,
    this.tabs,
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

  /// Sits before the page controls, after the title in focus order.
  final Widget? historyControls;

  /// Sits before the settings control, after the history controls in focus
  /// order.
  final Widget? pageControls;

  @override
  Size get preferredSize => const Size.fromHeight(AppSizes.appBarHeight);

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    // The bar spans the window, less its padding.
    final double barWidth =
        MediaQuery.sizeOf(context).width - 2 * AppSpacing.xxs;

    return Material(
      color: AppGlass.surface(colors),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: AppSizes.appBarHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxs),
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
                      _TitleButton(title: title, onPressed: onTitlePressed),
                ),
                // Shrinks, rather than overflows, in the tiniest windows,
                // leaving room for the navigation control and the title.
                trailing: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: math.max(
                      0,
                      barWidth - 2 * AppSizes.minTouchTarget,
                    ),
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (historyControls != null)
                          FocusTraversalOrder(
                            order: const NumericFocusOrder(3),
                            child: FocusTraversalGroup(child: historyControls!),
                          ),
                        if (pageControls != null)
                          FocusTraversalOrder(
                            order: const NumericFocusOrder(4),
                            child: FocusTraversalGroup(child: pageControls!),
                          ),
                        FocusTraversalOrder(
                          order: const NumericFocusOrder(5),
                          child: IconButton(
                            tooltip: 'Settings',
                            onPressed: onSettingsPressed,
                            icon: const Icon(AppIcons.settings),
                          ),
                        ),
                      ],
                    ),
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

/// Looks like an inline-editable title; renaming is not implemented yet.
class _TitleButton extends StatelessWidget {
  const _TitleButton({required this.title, required this.onPressed});

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
          borderRadius: BorderRadius.circular(AppRadii.medium),
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
