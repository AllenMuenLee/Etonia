import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../../app/theme/app_icons.dart';
import '../library_models.dart';

class StudySourceTree extends StatelessWidget {
  const StudySourceTree({
    super.key,
    required this.notes,
    required this.folders,
    this.selected = const {},
    this.onSelectionChanged,
    this.onOpenNote,
    this.noteKeyPrefix = 'source-tree-note',
  });

  final List<NoteEntry> notes;
  final List<Folder> folders;
  final Set<String> selected;
  final ValueChanged<Set<String>>? onSelectionChanged;
  final ValueChanged<String>? onOpenNote;
  final String noteKeyPrefix;

  @override
  Widget build(BuildContext context) {
    final byId = {for (final folder in folders) folder.id: folder};
    final used = <String>{};
    final descendantNotes = <String, Set<String>>{};
    for (final note in notes) {
      String? id = note.folderId;
      final visited = <String>{};
      while (id != null && visited.add(id) && byId.containsKey(id)) {
        used.add(id);
        (descendantNotes[id] ??= {}).add(note.id);
        id = byId[id]!.parentId;
      }
    }
    void choose(Iterable<String> ids, bool enabled) {
      final next = {...selected};
      enabled ? next.addAll(ids) : next.removeAll(ids);
      onSelectionChanged?.call(next);
    }

    Widget noteRow(NoteEntry note) => onSelectionChanged == null
        ? ListTile(
            key: ValueKey('$noteKeyPrefix-${note.id}'),
            leading: const Icon(AppIcons.note),
            title: Text(note.title),
            onTap: () => onOpenNote?.call(note.id),
          )
        : CheckboxListTile(
            key: ValueKey('$noteKeyPrefix-${note.id}'),
            title: Text(note.title),
            secondary: const Icon(AppIcons.note),
            value: selected.contains(note.id),
            onChanged: (value) => choose([note.id], value == true),
          );

    final emitted = <String>{};
    List<Widget> branch(String? parent) {
      final children =
          folders
              .where(
                (f) =>
                    (f.parentId == parent ||
                        (parent == null && !byId.containsKey(f.parentId))) &&
                    used.contains(f.id),
              )
              .toList()
            ..sort(
              (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
            );
      final files = notes.where((n) => n.folderId == parent).toList()
        ..sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
      return [
        for (final folder in children)
          if (emitted.add(folder.id))
            (() {
              final ids = descendantNotes[folder.id] ?? const <String>{};
              final count = ids.where(selected.contains).length;
              return ExpansionTile(
                key: ValueKey('source-tree-folder-${folder.id}'),
                initiallyExpanded: true,
                leading: const Icon(AppIcons.folder),
                title: Text(folder.name),
                trailing: onSelectionChanged == null
                    ? null
                    : Checkbox(
                        tristate: true,
                        value: count == 0
                            ? false
                            : count == ids.length
                            ? true
                            : null,
                        onChanged: (_) => choose(ids, count != ids.length),
                      ),
                childrenPadding: const EdgeInsetsDirectional.only(start: 16),
                children: branch(folder.id),
              );
            })(),
        for (final note in files) noteRow(note),
      ];
    }

    return Column(
      key: const ValueKey('study-source-tree'),
      mainAxisSize: MainAxisSize.min,
      children: [
        ...branch(null),
        for (final note in notes)
          if (note.folderId != null && !emitted.contains(note.folderId))
            noteRow(note),
      ],
    );
  }
}

@Preview(name: 'Source folder tree', size: Size(420, 500))
Widget studySourceTreePreview() {
  final now = DateTime(2026, 11, 6);
  return MaterialApp(
    home: Scaffold(
      body: StudySourceTree(
        notes: [
          NoteEntry(
            id: 'equations',
            title: 'Linear equations',
            folderId: 'algebra',
            created: now,
            modified: now,
            pageCount: 3,
          ),
        ],
        folders: [
          Folder(
            id: 'math',
            name: 'Mathematics',
            parentId: null,
            created: now,
            modified: now,
          ),
          Folder(
            id: 'algebra',
            name: 'Algebra',
            parentId: 'math',
            created: now,
            modified: now,
          ),
        ],
        selected: const {'equations'},
        onSelectionChanged: (_) {},
      ),
    ),
  );
}
