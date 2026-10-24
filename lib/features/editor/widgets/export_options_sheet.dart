import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/theme/app_icons.dart';
import '../../../shared/widgets/app_controls.dart';
import '../../../shared/navigation/app_sheets.dart';
import '../document_io/pdf_exporter.dart';

Future<PdfExportOptions?> showExportOptions(
  BuildContext context, {
  required bool allowCurrentPage,
}) {
  return showAppSheet<PdfExportOptions>(
    context: context,
    builder: (BuildContext context) =>
        _ExportOptionsSheet(allowCurrentPage: allowCurrentPage),
  );
}

class _ExportOptionsSheet extends StatefulWidget {
  const _ExportOptionsSheet({required this.allowCurrentPage});
  final bool allowCurrentPage;

  @override
  State<_ExportOptionsSheet> createState() => _ExportOptionsSheetState();
}

class _ExportOptionsSheetState extends State<_ExportOptionsSheet> {
  ExportPageRange _range = ExportPageRange.all;
  bool _rules = true;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return SafeArea(
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              0,
              AppSpacing.lg,
              AppSpacing.lg,
            ),
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(AppIcons.share, size: 20, color: colors.textSecondary),
                  const SizedBox(width: AppSpacing.sm),
                  Semantics(
                    header: true,
                    child: Text(
                      'Export as PDF',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              if (widget.allowCurrentPage) ...<Widget>[
                const SectionLabel('Pages'),
                SegmentedChoice<ExportPageRange>(
                  options: const <ExportPageRange>[
                    ExportPageRange.all,
                    ExportPageRange.current,
                  ],
                  selected: _range,
                  labelOf: (ExportPageRange range) =>
                      range == ExportPageRange.all
                      ? 'All pages'
                      : 'Current page',
                  onSelected: (ExportPageRange range) =>
                      setState(() => _range = range),
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
              ToggleSetting(
                label: 'Include background rules',
                hint: 'Print the lines, grid, or dots under the ink.',
                value: _rules,
                onChanged: (bool value) => setState(() => _rules = value),
              ),
              const SizedBox(height: AppSpacing.lg),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(AppSizes.minTouchTarget),
                ),
                onPressed: () => Navigator.of(context).pop(
                  PdfExportOptions(
                    range: _range,
                    includeBackgroundRules: _rules,
                  ),
                ),
                child: const Text('Export'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
