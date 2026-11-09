import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/theme/app_icons.dart';

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
    this.backTooltip = 'Back to library',
    this.onTitlePressed,
    this.onSettingsPressed,
    this.onFullscreenPressed,
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

  /// Says where the back button leads.
  final String backTooltip;
  final VoidCallback? onTitlePressed;
  final VoidCallback? onSettingsPressed;

  /// Puts the bar and its tabs away, leaving the page the whole screen.
  /// Without it there is no fullscreen button.
  final VoidCallback? onFullscreenPressed;

  @override
  Size get preferredSize => const Size.fromHeight(AppSizes.appBarHeight);

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
                                ? backTooltip
                                : 'Open navigation menu',
                            onPressed: onMenuPressed,
                            icon: AppIcon(
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
                                icon: const AppIcon(AppIcons.settings),
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
                                  icon: const AppIcon(AppIcons.fullscreen),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
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
