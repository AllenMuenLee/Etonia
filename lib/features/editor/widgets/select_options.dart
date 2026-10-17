import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/theme/app_icons.dart';

/// The Select tool's options: Paste. Disabled when [onPaste] is null, which
/// is while nothing has been copied or cut.
class SelectOptions extends StatelessWidget {
  const SelectOptions({super.key, required this.onPaste});

  final VoidCallback? onPaste;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final bool enabled = onPaste != null;
    final BorderRadius radius = BorderRadius.circular(AppRadii.medium);

    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: 'Paste',
      child: InkWell(
        onTap: onPaste,
        borderRadius: radius,
        hoverColor: colors.textPrimary.withValues(alpha: 0.06),
        focusColor: colors.textPrimary.withValues(alpha: 0.10),
        highlightColor: colors.textPrimary.withValues(alpha: 0.12),
        child: SizedBox(
          height: AppSizes.minTouchTarget,
          child: Opacity(
            opacity: enabled ? 1 : 0.38,
            child: ExcludeSemantics(
              child: Row(
                children: <Widget>[
                  const SizedBox(width: AppSpacing.xs),
                  Icon(AppIcons.paste, size: 20, color: colors.textSecondary),
                  const SizedBox(width: AppSpacing.sm),
                  Text('Paste', style: Theme.of(context).textTheme.labelLarge),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
