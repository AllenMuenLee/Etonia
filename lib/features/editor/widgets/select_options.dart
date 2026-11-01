import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';

/// The Select tool's options: Select PDF. While it is on, a lasso on a PDF
/// page takes the paper inside it along with the ink, to copy, cut,
/// delete, or move; while off, it takes the ink alone.
///
/// Paste is not here: holding a pointer still on the page offers it.
class SelectOptions extends StatelessWidget {
  const SelectOptions({
    super.key,
    required this.selectPdf,
    required this.onSelectPdfChanged,
  });

  final bool selectPdf;
  final ValueChanged<bool> onSelectPdfChanged;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    const BorderRadius radius = AppBorderRadius.medium;

    return MergeSemantics(
      child: InkWell(
        onTap: () => onSelectPdfChanged(!selectPdf),
        borderRadius: radius,
        hoverColor: colors.textPrimary.withValues(alpha: 0.06),
        focusColor: colors.textPrimary.withValues(alpha: 0.10),
        highlightColor: colors.textPrimary.withValues(alpha: 0.12),
        child: SizedBox(
          height: AppSizes.minTouchTarget,
          child: Row(
            children: <Widget>[
              const SizedBox(width: AppSpacing.xs),
              Icon(AppIcons.pdf, size: 20, color: colors.textSecondary),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'Select PDF',
                  style: Theme.of(context).textTheme.labelLarge,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Switch(value: selectPdf, onChanged: onSelectPdfChanged),
            ],
          ),
        ),
      ),
    );
  }
}
