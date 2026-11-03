import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../shared/navigation/app_sheets.dart';
import '../library_models.dart';
import 'study_desk_controller.dart';
import 'study_desk_models.dart';

/// Builds a note's small picture, which the library draws and keeps.
typedef StudyNoteThumbnailBuilder = Widget Function(NoteEntry note);

/// The notes on the desk, along the top of the chat: each can be left out of
/// questions with its checkbox, without taking it off the desk.
class StudySourceStrip extends StatelessWidget {
  const StudySourceStrip({
    super.key,
    required this.controller,
    required this.thumbnail,
  });

  final StudyDeskController controller;
  final StudyNoteThumbnailBuilder thumbnail;

  static const double height = 76;

  @override
  Widget build(BuildContext context) {
    final List<StudySourceItem> sources = controller.sources;
    if (sources.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      key: const ValueKey<String>('study-source-strip'),
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        itemCount: sources.length,
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(width: AppSpacing.xs),
        itemBuilder: (BuildContext context, int index) {
          final StudySourceItem source = sources[index];
          final NoteEntry note = controller.noteOf(source.noteId)!;
          return _SourceCard(
            key: ValueKey<String>('study-source-${note.id}'),
            note: note,
            folder: controller.folderOf(note.folderId)?.name,
            enabled: source.enabled,
            thumbnail: thumbnail(note),
            onChanged: (bool enabled) =>
                controller.setSourceEnabled(note.id, enabled),
            onRemove: () => controller.removeSource(note.id),
          );
        },
      ),
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    super.key,
    required this.note,
    required this.folder,
    required this.enabled,
    required this.thumbnail,
    required this.onChanged,
    required this.onRemove,
  });

  final NoteEntry note;
  final String? folder;
  final bool enabled;
  final Widget thumbnail;
  final ValueChanged<bool> onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Material(
      color: enabled ? colors.selected : colors.surfaceMuted,
      borderRadius: AppBorderRadius.medium,
      child: InkWell(
        borderRadius: AppBorderRadius.medium,
        onTap: () => onChanged(!enabled),
        child: SizedBox(
          width: 212,
          child: Row(
            children: <Widget>[
              Semantics(
                checked: enabled,
                label: '${note.title}, in the questions',
                child: Checkbox(
                  value: enabled,
                  onChanged: (bool? value) => onChanged(value ?? false),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              Opacity(
                opacity: enabled ? 1 : 0.5,
                child: SizedBox(
                  width: 32,
                  height: 44,
                  child: ExcludeSemantics(child: thumbnail),
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      note.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelLarge?.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    Text(
                      folder ?? 'Library',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelSmall?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Take ${note.title} off the desk',
                onPressed: onRemove,
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                icon: Icon(AppIcons.close, color: colors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lets the user choose notes and whole folders for the desk, and makes the desk
/// hold what was chosen. A note left ticked keeps its place in or out of context.
Future<void> showStudySourcePicker(
  BuildContext context, {
  required StudyDeskController controller,
}) async {
  final Set<String>? chosen = await showAppSheet<Set<String>>(
    context: context,
    motionKey: 'study-sources',
    builder: (BuildContext context) =>
        StudySourcePicker(controller: controller),
  );
  if (chosen == null) return;
  final Set<String> before = <String>{
    for (final StudySourceItem item in controller.sources) item.noteId,
  };
  for (final String id in before.difference(chosen)) {
    controller.removeSource(id);
  }
  controller.addNotes(chosen.difference(before));
}

/// The Add Sources sheet: search, the folder tree to filter by, and a checkbox
/// for each note and whole folder.
class StudySourcePicker extends StatefulWidget {
  const StudySourcePicker({super.key, required this.controller});

  final StudyDeskController controller;

  @override
  State<StudySourcePicker> createState() => _StudySourcePickerState();
}

class _StudySourcePickerState extends State<StudySourcePicker> {
  final TextEditingController _search = TextEditingController();
  late final Set<String> _chosen = <String>{
    for (final StudySourceItem item in widget.controller.sources) item.noteId,
  };

  /// The folder shown; null for the whole library.
  String? _folder;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String get _query => _search.text.trim().toLowerCase();

  /// Whether all of [notes] are chosen: true, false, or null for some.
  bool? _stateOf(List<String> notes) {
    if (notes.isEmpty) return false;
    final int chosen = notes.where(_chosen.contains).length;
    return chosen == 0 ? false : (chosen == notes.length ? true : null);
  }

  void _setAll(List<String> notes, bool on) {
    setState(() {
      if (on) {
        _chosen.addAll(notes);
      } else {
        _chosen.removeAll(notes);
      }
    });
  }

  List<Widget> _tree(BuildContext context) {
    final StudyDeskController controller = widget.controller;
    final List<NoteEntry> notes = controller.allNotes.toList()
      ..sort(LibrarySort.title.compareNotes);
    final String query = _query;
    if (query.isNotEmpty) {
      return <Widget>[
        for (final NoteEntry note in notes)
          if (_matches(note, query))
            _noteRow(note, 0, controller.folderOf(note.folderId)?.name),
      ];
    }
    final Map<String?, List<Folder>> children = <String?, List<Folder>>{};
    for (final Folder folder in controller.allFolders) {
      (children[folder.parentId] ??= <Folder>[]).add(folder);
    }
    final List<Widget> rows = <Widget>[];
    void walk(String? parent, int depth) {
      final List<Folder> here = List<Folder>.of(
        children[parent] ?? const <Folder>[],
      )..sort(LibrarySort.title.compareFolders);
      for (final Folder folder in here) {
        rows.add(_folderRow(folder, depth));
        walk(folder.id, depth + 1);
      }
      for (final NoteEntry note in notes) {
        if (note.folderId == parent) rows.add(_noteRow(note, depth, null));
      }
    }

    walk(_folder, 0);
    return rows;
  }

  bool _matches(NoteEntry note, String query) =>
      note.title.toLowerCase().contains(query) ||
      note.searchText.toLowerCase().contains(query) ||
      (widget.controller
              .folderOf(note.folderId)
              ?.name
              .toLowerCase()
              .contains(query) ??
          false);

  Widget _folderRow(Folder folder, int depth) {
    final List<String> notes = widget.controller.notesInSubtree(folder.id);
    final AppColors colors = AppColors.of(context);
    return _PickerRow(
      key: ValueKey<String>('study-pick-folder-${folder.id}'),
      depth: depth,
      value: _stateOf(notes),
      tristate: true,
      enabled: notes.isNotEmpty,
      icon: Icon(AppIcons.folder, size: 18, color: colors.textSecondary),
      title: folder.name,
      subtitle: notes.length == 1 ? '1 note' : '${notes.length} notes',
      onChanged: (bool on) => _setAll(notes, on),
      onOpen: () => setState(() => _folder = folder.id),
    );
  }

  Widget _noteRow(NoteEntry note, int depth, String? subtitle) {
    final AppColors colors = AppColors.of(context);
    return _PickerRow(
      key: ValueKey<String>('study-pick-note-${note.id}'),
      depth: depth,
      value: _chosen.contains(note.id),
      icon: Icon(AppIcons.note, size: 18, color: colors.textSecondary),
      title: note.title,
      subtitle: subtitle,
      onChanged: (bool on) => _setAll(<String>[note.id], on),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final StudyDeskController controller = widget.controller;
    final String? folderId = _folder;
    final Folder? folder = controller.folderOf(folderId);
    final List<String> inFolder = folderId == null
        ? const <String>[]
        : controller.notesInSubtree(folderId);
    final List<Widget> rows = _tree(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          key: const ValueKey<String>('study-source-picker'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Semantics(
              header: true,
              child: Text(
                'Add Sources',
                style: text.titleLarge?.copyWith(color: colors.textPrimary),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              key: const ValueKey<String>('study-source-search'),
              controller: _search,
              onChanged: (_) => setState(() {}),
              style: text.bodyMedium?.copyWith(color: colors.textPrimary),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(AppIcons.search, size: 18),
                hintText: 'Search notes',
                hintStyle: text.bodyMedium?.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
            if (folder != null && _query.isEmpty) ...<Widget>[
              const SizedBox(height: AppSpacing.xs),
              Row(
                children: <Widget>[
                  IconButton(
                    tooltip: 'All notes',
                    onPressed: () => setState(() => _folder = folder.parentId),
                    icon: Icon(AppIcons.back, color: colors.textSecondary),
                  ),
                  Expanded(
                    child: Text(
                      folder.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleSmall?.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  TextButton(
                    key: const ValueKey<String>('study-select-folder'),
                    onPressed: inFolder.isEmpty
                        ? null
                        : () => _setAll(inFolder, _stateOf(inFolder) != true),
                    child: Text(
                      _stateOf(inFolder) == true
                          ? 'Deselect folder'
                          : 'Select folder',
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.xs),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Text(
                        _query.isEmpty ? 'No notes yet.' : 'No notes found.',
                        style: text.bodyMedium?.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    )
                  : ListView(children: rows),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: AppSpacing.xs),
                FilledButton(
                  key: const ValueKey<String>('study-source-done'),
                  onPressed: () => Navigator.of(context).pop(_chosen),
                  child: Text(
                    _chosen.length == 1
                        ? 'Use 1 note'
                        : 'Use ${_chosen.length} notes',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PickerRow extends StatelessWidget {
  const _PickerRow({
    super.key,
    required this.depth,
    required this.value,
    required this.icon,
    required this.title,
    required this.onChanged,
    this.subtitle,
    this.tristate = false,
    this.enabled = true,
    this.onOpen,
  });

  final int depth;
  final bool? value;
  final bool tristate;
  final bool enabled;
  final Widget icon;
  final String title;
  final String? subtitle;
  final ValueChanged<bool> onChanged;

  /// Filters to this folder.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    void toggle() => onChanged(value != true);
    return InkWell(
      borderRadius: AppBorderRadius.medium,
      onTap: !enabled ? null : (onOpen ?? toggle),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppSizes.minTouchTarget),
        child: Row(
          children: <Widget>[
            SizedBox(width: AppSpacing.md * depth),
            Checkbox(
              value: value,
              tristate: tristate,
              onChanged: enabled ? (_) => toggle() : null,
            ),
            icon,
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(color: colors.textPrimary),
                  ),
                  if (subtitle case final String subtitle)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelSmall?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
            if (onOpen != null)
              Icon(AppIcons.disclosure, size: 16, color: colors.textSecondary),
            const SizedBox(width: AppSpacing.xs),
          ],
        ),
      ),
    );
  }
}
