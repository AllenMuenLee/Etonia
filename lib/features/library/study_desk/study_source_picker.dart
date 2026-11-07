import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../shared/navigation/app_sheets.dart';
import '../library_models.dart';
import 'study_desk_controller.dart';
import 'study_desk_models.dart';

/// Builds a note's small picture, which the library draws and keeps.
typedef StudyNoteThumbnailBuilder = Widget Function(NoteEntry note);

class StudyChatSources extends StatelessWidget {
  const StudyChatSources({
    super.key,
    required this.controller,
    this.onOpenSource,
    this.onAddSources,
  });
  final StudyDeskController controller;
  final ValueChanged<String>? onOpenSource;
  final VoidCallback? onAddSources;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Column(
      key: const ValueKey('study-chat-sources'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Sources for this chat',
          style: Theme.of(context).textTheme.labelMedium,
        ),
        const SizedBox(height: AppSpacing.xs),
        LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            key: const ValueKey('study-chat-source-row'),
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final source in controller.sources)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(
                      end: AppSpacing.xs,
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth,
                      ),
                      child: InputChip(
                        key: ValueKey('study-chat-source-${source.noteId}'),
                        avatar: const Icon(AppIcons.note, size: 16),
                        label: Text(
                          controller.noteOf(source.noteId)?.title ?? 'Note',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onPressed: () {
                          if (onOpenSource != null) {
                            onOpenSource!(source.noteId);
                          } else {
                            controller.focusCitation(
                              StudyCitation(
                                noteId: source.noteId,
                                pageIndex: 0,
                                revision: controller.revisionOf(source.noteId),
                              ),
                              message: -1,
                              paragraph: 0,
                            );
                          }
                        },
                        onDeleted: () => controller.removeSource(source.noteId),
                        deleteButtonTooltipMessage: 'Remove source',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        TextButton.icon(
          key: const ValueKey('study-chat-add-source'),
          onPressed:
              onAddSources ??
              () => showStudySourcePicker(context, controller: controller),
          icon: const Icon(AppIcons.add, size: 18),
          label: const Text('Add source'),
        ),
      ],
    ),
  );
}

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
  Widget build(BuildContext context) =>
      StudyChatSources(controller: controller);
}

/// Lets the user choose notes and whole folders for the desk, and makes the desk
/// add the chosen notes. Existing sources are removed only by their close button.
Future<void> showStudySourcePicker(
  BuildContext context, {
  required StudyDeskController controller,
}) async {
  final sessionId = controller.sessionId;
  final Set<String>? chosen = await showAppSheet<Set<String>>(
    context: context,
    motionKey: 'study-sources',
    builder: (BuildContext context) =>
        StudySourcePicker(controller: controller),
  );
  if (chosen == null || controller.sessionId != sessionId) return;
  final Set<String> before = <String>{
    for (final StudySourceItem item in controller.sources) item.noteId,
  };
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
        final attached = widget.controller.sources.map((s) => s.noteId).toSet();
        _chosen.removeAll(notes.where((id) => !attached.contains(id)));
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
    final attached = widget.controller.sources.any((s) => s.noteId == note.id);
    return _PickerRow(
      key: ValueKey<String>('study-pick-note-${note.id}'),
      depth: depth,
      value: _chosen.contains(note.id),
      icon: Icon(AppIcons.note, size: 18, color: colors.textSecondary),
      title: note.title,
      subtitle: attached ? 'Already added' : subtitle,
      enabled: !attached,
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
        padding: const EdgeInsets.all(AppSpacing.lg),
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
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Choose the notes you want to study.',
              style: text.bodyMedium?.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const ValueKey<String>('study-source-search'),
              controller: _search,
              onChanged: (_) => setState(() {}),
              style: text.bodyMedium?.copyWith(color: colors.textPrimary),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(AppIcons.search, size: 18),
                hintText: 'Search notes',
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        onPressed: () => setState(_search.clear),
                        icon: const Icon(AppIcons.clear, size: 18),
                      ),
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
            if (widget.controller.canSearchByMeaning)
              MergeSemantics(
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'Search by meaning',
                            style: text.bodyMedium?.copyWith(
                              color: colors.textPrimary,
                            ),
                          ),
                          Text(
                            'Finds pages by what they mean, not only the words. '
                            'Sends the notes you use to Google to index them. '
                            'Nothing is kept there.',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: text.labelSmall?.copyWith(
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      key: const ValueKey<String>('study-semantic-search'),
                      value: widget.controller.semanticSearch,
                      onChanged: (bool on) =>
                          setState(() => widget.controller.semanticSearch = on),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
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
    return Material(
      color: value == true ? colors.selected : Colors.transparent,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: !enabled ? null : (onOpen ?? toggle),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 60),
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
                      style: text.bodyMedium?.copyWith(
                        color: colors.textPrimary,
                      ),
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
                Icon(
                  AppIcons.disclosure,
                  size: 16,
                  color: colors.textSecondary,
                ),
              const SizedBox(width: AppSpacing.xs),
            ],
          ),
        ),
      ),
    );
  }
}
