import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../shared/navigation/app_sheets.dart';
import '../../../shared/widgets/app_controls.dart';
import 'tool_palette.dart';
import 'toolbar_layout.dart';

/// Opens the arrangement of the tool palette: its buttons in order, in
/// three groups — always on the toolbar, behind its arrow, and hidden.
/// Every change is made to [layout] at once, so the palette changes behind
/// the sheet as the user arranges it.
Future<void> showToolbarCustomizer(
  BuildContext context, {
  required ValueNotifier<ToolbarLayout> layout,
}) {
  return showAppSheet<void>(
    context: context,
    motionKey: 'toolbar-customizer',
    builder: (BuildContext context) => ToolbarCustomizer(layout: layout),
  );
}

enum _Section {
  shown('On the toolbar'),
  folded('Behind the arrow'),
  hidden('Hidden');

  const _Section(this.title);

  final String title;
}

/// One line of the arrangement: a group's heading, a group's placeholder
/// while it is empty, or a tool.
sealed class _Entry {
  const _Entry();
}

class _Heading extends _Entry {
  const _Heading(this.section);
  final _Section section;
}

class _Empty extends _Entry {
  const _Empty(this.section);
  final _Section section;
}

class _Tool extends _Entry {
  const _Tool(this.item, this.section);
  final PaletteItem item;
  final _Section section;
}

/// The palette's buttons, to be dragged into order and between groups, and
/// shown or hidden with the eye beside each.
class ToolbarCustomizer extends StatelessWidget {
  const ToolbarCustomizer({super.key, required this.layout});

  final ValueNotifier<ToolbarLayout> layout;

  static List<_Entry> _entries(ToolbarLayout layout) {
    final Map<_Section, List<PaletteItem>> groups =
        <_Section, List<PaletteItem>>{
          _Section.shown: layout.shown,
          _Section.folded: layout.folded,
          _Section.hidden: layout.hidden,
        };
    return <_Entry>[
      for (final _Section section in _Section.values) ...<_Entry>[
        _Heading(section),
        if (groups[section]!.isEmpty) _Empty(section),
        for (final PaletteItem item in groups[section]!) _Tool(item, section),
      ],
    ];
  }

  /// The layout [entries] say, each tool in the group whose heading is
  /// above it.
  static ToolbarLayout _layoutOf(List<_Entry> entries) {
    final List<PaletteItem> shown = <PaletteItem>[];
    final List<PaletteItem> folded = <PaletteItem>[];
    _Section section = _Section.shown;
    for (final _Entry entry in entries) {
      switch (entry) {
        case _Heading():
          section = entry.section;
        case _Tool():
          if (section == _Section.shown) shown.add(entry.item);
          if (section == _Section.folded) folded.add(entry.item);
        case _Empty():
          break;
      }
    }
    return ToolbarLayout(shown: shown, folded: folded);
  }

  /// Moves the entry at [from] to [to], counted with it already taken out. A
  /// tool that cannot be hidden goes back if dropped among the hidden ones.
  void _reorder(List<_Entry> entries, int from, int to) {
    final List<_Entry> moved = <_Entry>[...entries];
    final _Entry entry = moved.removeAt(from);
    moved.insert(to, entry);
    final ToolbarLayout next = _layoutOf(moved);
    if (next.hidden.any((PaletteItem item) => !item.canHide)) return;
    layout.value = next;
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return SafeArea(
      child: ValueListenableBuilder<ToolbarLayout>(
        valueListenable: layout,
        builder: (BuildContext context, ToolbarLayout current, Widget? _) {
          final List<_Entry> entries = _entries(current);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(
                  AppSpacing.md + AppSpacing.sm,
                  AppSpacing.sm,
                  AppSpacing.xs,
                  0,
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          'Customize toolbar',
                          style: text.titleLarge,
                        ),
                      ),
                    ),
                    TextButton(
                      key: const ValueKey<String>('reset-toolbar'),
                      onPressed: current == ToolbarLayout.standard
                          ? null
                          : () => layout.value = ToolbarLayout.standard,
                      child: const Text('Reset'),
                    ),
                    CompactIconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: AppIcons.close,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md + AppSpacing.sm,
                  AppSpacing.xxs,
                  AppSpacing.md,
                  AppSpacing.xs,
                ),
                child: Text(
                  'Drag tools to reorder them or move them between groups.',
                  style: text.bodySmall,
                ),
              ),
              Flexible(
                child: ReorderableListView(
                  key: const ValueKey<String>('toolbar-customizer-list'),
                  shrinkWrap: true,
                  buildDefaultDragHandles: false,
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    0,
                    AppSpacing.md,
                    AppSpacing.md,
                  ),
                  onReorderItem: (int from, int to) =>
                      _reorder(entries, from, to),
                  children: <Widget>[
                    for (int i = 0; i < entries.length; i++)
                      _entryRow(context, entries[i], i),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _entryRow(BuildContext context, _Entry entry, int index) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    switch (entry) {
      case _Heading(:final _Section section):
        return Padding(
          key: ValueKey<String>('toolbar-section-${section.name}'),
          padding: EdgeInsetsDirectional.only(
            start: AppSpacing.sm,
            top: section == _Section.shown ? AppSpacing.xs : AppSpacing.md,
          ),
          child: Semantics(header: true, child: SectionLabel(section.title)),
        );
      case _Empty(:final _Section section):
        return Padding(
          key: ValueKey<String>('toolbar-empty-${section.name}'),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.sm,
          ),
          child: Text(
            'Drag tools here.',
            style: text.bodySmall?.copyWith(color: colors.textSecondary),
          ),
        );
      case _Tool(:final PaletteItem item, :final _Section section):
        final bool hidden = section == _Section.hidden;
        return ReorderableDelayedDragStartListener(
          key: ValueKey<PaletteItem>(item),
          index: index,
          child: Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xxs),
            child: Material(
              color: AppGlass.muted(colors),
              borderRadius: AppBorderRadius.medium,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: AppSizes.minTouchTarget,
                ),
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: AppSpacing.sm,
                    end: AppSpacing.xxs,
                  ),
                  child: Row(
                    children: <Widget>[
                      Opacity(
                        opacity: hidden ? 0.45 : 1,
                        child: IconTheme.merge(
                          data: IconThemeData(
                            size: AppSizes.icon,
                            color: colors.textPrimary,
                          ),
                          child: SizedBox.square(
                            dimension: AppSizes.icon + AppSpacing.xxs,
                            child: Center(child: PaletteItemGlyph(item)),
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          item.label,
                          style: text.bodyMedium?.copyWith(
                            color: hidden ? colors.textSecondary : null,
                          ),
                        ),
                      ),
                      if (item.canHide)
                        CompactIconButton(
                          key: ValueKey<String>(
                            'toolbar-visibility-${item.name}',
                          ),
                          tooltip: hidden
                              ? 'Show ${item.label}'
                              : 'Hide ${item.label}',
                          onPressed: () => layout.value = hidden
                              ? layout.value.show(item)
                              : layout.value.hide(item),
                          icon: hidden ? AppIcons.hide : AppIcons.show,
                        ),
                      ReorderableDragStartListener(
                        index: index,
                        child: Tooltip(
                          message: 'Drag to move ${item.label}',
                          child: MouseRegion(
                            cursor: SystemMouseCursors.grab,
                            child: SizedBox.square(
                              dimension: AppSizes.minTouchTarget,
                              child: Icon(
                                AppIcons.dragHandle,
                                size: 18,
                                color: colors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
    }
  }
}
