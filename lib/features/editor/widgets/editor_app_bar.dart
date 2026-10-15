import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';

/// The slim top bar: navigation, document title, undo and redo, page
/// controls, and overflow. It spans the whole width, as the page does.
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
    this.onMorePressed,
    this.historyControls,
    this.pageControls,
  });

  final String title;
  final bool centerTitle;
  final VoidCallback? onMenuPressed;

  /// Shows the navigation control as a way back to the library instead of
  /// a menu.
  final bool leadingIsBack;
  final VoidCallback? onTitlePressed;
  final VoidCallback? onMorePressed;

  /// Sits before the page controls, after the title in focus order.
  final Widget? historyControls;

  /// Sits before the overflow control, after the history controls in focus
  /// order.
  final Widget? pageControls;

  @override
  Size get preferredSize => const Size.fromHeight(AppSizes.appBarHeight);

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);

    return Material(
      color: colors.background,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: AppSizes.appBarHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxs),
            child: FocusTraversalGroup(
              policy: OrderedTraversalPolicy(),
              child: NavigationToolbar(
                centerMiddle: centerTitle,
                middleSpacing: AppSpacing.xxs,
                leading: FocusTraversalOrder(
                  order: const NumericFocusOrder(1),
                  child: IconButton(
                    tooltip: leadingIsBack
                        ? 'Back to library'
                        : 'Open navigation menu',
                    onPressed: onMenuPressed,
                    icon: Icon(leadingIsBack ? Icons.arrow_back : Icons.menu),
                  ),
                ),
                middle: FocusTraversalOrder(
                  order: const NumericFocusOrder(2),
                  child: _TitleButton(title: title, onPressed: onTitlePressed),
                ),
                trailing: Row(
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
                        tooltip: 'More options',
                        onPressed: onMorePressed,
                        icon: const Icon(Icons.more_horiz),
                      ),
                    ),
                  ],
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
