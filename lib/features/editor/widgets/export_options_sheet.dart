import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../document_io/pdf_exporter.dart';

Future<PdfExportOptions?> showExportOptions(
  BuildContext context, {
  required bool allowCurrentPage,
}) {
  return showModalBottomSheet<PdfExportOptions>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
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
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          0,
          AppSpacing.md,
          AppSpacing.lg,
        ),
        children: <Widget>[
          Semantics(
            header: true,
            child: Text(
              'Export as PDF',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          RadioGroup<ExportPageRange>(
            groupValue: _range,
            onChanged: (ExportPageRange? value) {
              if (value != null) setState(() => _range = value);
            },
            child: Column(
              children: <Widget>[
                const RadioListTile<ExportPageRange>(
                  contentPadding: EdgeInsets.zero,
                  title: Text('All pages'),
                  value: ExportPageRange.all,
                ),
                if (widget.allowCurrentPage)
                  const RadioListTile<ExportPageRange>(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Current page'),
                    value: ExportPageRange.current,
                  ),
              ],
            ),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Include background rules'),
            value: _rules,
            onChanged: (bool value) => setState(() => _rules = value),
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(
                PdfExportOptions(range: _range, includeBackgroundRules: _rules),
              ),
              icon: const Icon(Icons.ios_share_outlined),
              label: const Text('Export'),
            ),
          ),
        ],
      ),
    );
  }
}
