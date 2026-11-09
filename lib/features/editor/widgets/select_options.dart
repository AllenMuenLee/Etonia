import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import 'tool_options_bar.dart';

/// The Select tool's options, along a [ToolOptionsBar]: Select PDF. While
/// it is on, a lasso on a PDF page takes the paper inside it along with the
/// ink, to copy, cut, delete, or move; while off, it takes the ink alone.
///
/// Paste is not here: holding a pointer still on the page offers it.
class SelectOptions extends StatelessWidget {
  const SelectOptions({
    super.key,
    required this.selectPdf,
    required this.onSelectPdfChanged,
    this.axis = Axis.horizontal,
  });

  final bool selectPdf;
  final ValueChanged<bool> onSelectPdfChanged;
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    return ToolOptionsBar(
      key: const ValueKey<String>('select-options-bar'),
      axis: axis,
      children: <Widget>[
        OptionsButton(
          key: const ValueKey<String>('select-pdf-toggle'),
          tooltip: selectPdf ? 'Select ink only' : 'Select PDF too',
          semanticLabel: 'Select PDF',
          label: 'Select PDF',
          selected: selectPdf,
          toggled: selectPdf,
          onPressed: () => onSelectPdfChanged(!selectPdf),
          child: const AppIcon(AppIcons.pdf),
        ),
      ],
    );
  }
}
