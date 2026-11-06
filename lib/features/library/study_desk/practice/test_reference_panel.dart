import 'dart:io';

import 'package:flutter/material.dart';

import '../../../../app/theme/app_icons.dart';
import '../../../../app/theme/app_tokens.dart';

import 'study_practice_models.dart';

class TestReferencePanel extends StatefulWidget {
  const TestReferencePanel({
    super.key,
    required this.sheets,
    required this.kind,
    required this.onKindChanged,
    required this.onImport,
    required this.onClose,
    this.busy = false,
  });

  final List<TestReferenceSheet> sheets;
  final TestReferenceKind kind;
  final ValueChanged<TestReferenceKind> onKindChanged;
  final ValueChanged<TestReferenceKind> onImport;
  final VoidCallback onClose;
  final bool busy;

  @override
  State<TestReferencePanel> createState() => _TestReferencePanelState();
}

class _TestReferencePanelState extends State<TestReferencePanel> {
  int page = 0;

  @override
  void didUpdateWidget(TestReferencePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind != widget.kind || oldWidget.sheets != widget.sheets) {
      page = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final sheet = widget.sheets.where((s) => s.kind == widget.kind).firstOrNull;
    final paths = sheet?.imagePaths ?? const <String>[];
    return Material(
      key: const ValueKey('test-reference-panel'),
      color: AppColors.of(context).background,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 260;
          return Column(
            children: [
              if (compact)
                Row(
                  children: [
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<TestReferenceKind>(
                          isExpanded: true,
                          value: widget.kind,
                          items: [
                            for (final kind in TestReferenceKind.values)
                              DropdownMenuItem(
                                value: kind,
                                child: Text(kind.label),
                              ),
                          ],
                          onChanged: (kind) {
                            if (kind != null) widget.onKindChanged(kind);
                          },
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close reference sheets',
                      onPressed: widget.onClose,
                      icon: const Icon(AppIcons.close),
                    ),
                  ],
                )
              else ...[
                Row(
                  children: [
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Reference sheets',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close reference sheets',
                      onPressed: widget.onClose,
                      icon: const Icon(AppIcons.close),
                    ),
                  ],
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<TestReferenceKind>(
                    segments: [
                      for (final kind in TestReferenceKind.values)
                        ButtonSegment(value: kind, label: Text(kind.label)),
                    ],
                    selected: {widget.kind},
                    onSelectionChanged: (value) =>
                        widget.onKindChanged(value.single),
                    showSelectedIcon: false,
                  ),
                ),
              ],
              if (sheet != null && !compact)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    sheet.name,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.of(context).textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              Expanded(
                child: paths.isEmpty
                    ? Center(
                        child: TextButton.icon(
                          onPressed: widget.busy
                              ? null
                              : () => widget.onImport(widget.kind),
                          icon: const Icon(AppIcons.add),
                          label: Text(
                            'Import ${widget.kind.label.toLowerCase()}',
                          ),
                        ),
                      )
                    : InteractiveViewer(
                        key: ValueKey('${widget.kind.name}-${paths[page]}'),
                        minScale: 1,
                        maxScale: 5,
                        child: Center(
                          child: Image.file(
                            File(paths[page]),
                            cacheWidth: 1200,
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text(
                                'This sheet could not be loaded. Import it again to replace it.',
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
              if (paths.isNotEmpty)
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Previous reference page',
                      onPressed: page == 0
                          ? null
                          : () => setState(() => page--),
                      icon: const Icon(AppIcons.previous),
                    ),
                    Text('${page + 1} / ${paths.length}'),
                    IconButton(
                      tooltip: 'Next reference page',
                      onPressed: page + 1 >= paths.length
                          ? null
                          : () => setState(() => page++),
                      icon: const Icon(AppIcons.next),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Replace ${widget.kind.label.toLowerCase()}',
                      onPressed: widget.busy
                          ? null
                          : () => widget.onImport(widget.kind),
                      icon: const Icon(AppIcons.add),
                    ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}
