import 'package:flutter/material.dart';

import '../../app/theme/app_icons.dart';
import '../../app/theme/app_tokens.dart';

/// Opens [page] as a full screen that rises over the current one, the way the
/// plans and the account are shown.
Future<void> showStorePage(BuildContext context, Widget page) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => page),
  );
}

/// The frame of the plans and account pages: a quiet header with the title
/// and a close button, over a column of content that scrolls and stays a
/// readable width.
class StorePageShell extends StatelessWidget {
  const StorePageShell({
    super.key,
    required this.title,
    required this.child,
    this.closeKey,
    this.maxWidth = AppSizes.maxContentWidth,
    this.header,
    this.scrollController,
  });

  final String title;
  final Widget child;
  final Key? closeKey;
  final double maxWidth;

  /// Stays under the title while [child] scrolls, such as a row of tabs.
  final Widget? header;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.xs,
                AppSpacing.md,
                0,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.titleMedium?.copyWith(
                              color: colors.textSecondary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        key: closeKey,
                        icon: const Icon(AppIcons.close, size: 20),
                        color: colors.textPrimary,
                        tooltip: 'Close',
                        style: IconButton.styleFrom(
                          backgroundColor: colors.selected,
                        ),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (header != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.xs,
                  AppSpacing.md,
                  0,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    child: header,
                  ),
                ),
              ),
            Expanded(
              child: SingleChildScrollView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.sm,
                  AppSpacing.md,
                  AppSpacing.xl,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    child: child,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
