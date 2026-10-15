import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import 'library_models.dart';

/// Asks for a name, with [initial] selected. Returns the cleaned name, or
/// null when cancelled or left empty.
Future<String?> askForName(
  BuildContext context, {
  required String title,
  required String action,
  String initial = '',
}) async {
  final String? result = await showDialog<String>(
    context: context,
    builder: (BuildContext context) =>
        _NameDialog(title: title, action: action, initial: initial),
  );
  return result == null ? null : cleanName(result);
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.action,
    required this.initial,
  });

  final String title;
  final String action;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _text =
      TextEditingController(text: widget.initial)
        ..selection = TextSelection(
          baseOffset: 0,
          extentOffset: widget.initial.length,
        );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    if (cleanName(_text.text) != null) {
      Navigator.of(context).pop(_text.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _text,
        autofocus: true,
        maxLength: maxNameLength,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(labelText: 'Name', counterText: ''),
        onSubmitted: (_) => _submit(),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _text,
          builder: (BuildContext context, TextEditingValue value, Widget? _) {
            return TextButton(
              onPressed: cleanName(value.text) == null ? null : _submit,
              child: Text(widget.action),
            );
          },
        ),
      ],
    );
  }
}

/// Asks the user to confirm something destructive.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
}) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) {
      return AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}

/// Where something is moved: a folder, or the top level when [folder] is
/// null.
class FolderChoice {
  const FolderChoice(this.folder);

  final Folder? folder;
}

/// Lets the user pick a folder from [folders], or the top level. Folders in
/// [excluded] are not offered. Returns null when cancelled.
Future<FolderChoice?> pickFolder(
  BuildContext context, {
  required String title,
  required List<Folder> folders,
  Set<String> excluded = const <String>{},
}) {
  final Map<String?, List<Folder>> children = <String?, List<Folder>>{};
  for (final Folder folder in folders) {
    if (!excluded.contains(folder.id)) {
      children.putIfAbsent(folder.parentId, () => <Folder>[]).add(folder);
    }
  }
  final List<(Folder, int)> rows = <(Folder, int)>[];
  void walk(String? parent, int depth) {
    final List<Folder> here = List<Folder>.of(
      children[parent] ?? const <Folder>[],
    )..sort(LibrarySort.title.compareFolders);
    for (final Folder folder in here) {
      rows.add((folder, depth));
      walk(folder.id, depth + 1);
    }
  }

  walk(null, 0);
  return showDialog<FolderChoice>(
    context: context,
    builder: (BuildContext context) {
      return SimpleDialog(
        title: Text(title),
        children: <Widget>[
          SimpleDialogOption(
            onPressed: () =>
                Navigator.of(context).pop(const FolderChoice(null)),
            child: const _FolderRow(name: 'Library', depth: 0, root: true),
          ),
          for (final (Folder folder, int depth) in rows)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(FolderChoice(folder)),
              child: _FolderRow(name: folder.name, depth: depth + 1),
            ),
        ],
      );
    },
  );
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.name,
    required this.depth,
    this.root = false,
  });

  final String name;
  final int depth;
  final bool root;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSizes.minTouchTarget),
      child: Padding(
        padding: EdgeInsetsDirectional.only(start: AppSpacing.md * depth),
        child: Row(
          children: <Widget>[
            Icon(
              root ? Icons.library_books_outlined : Icons.folder_outlined,
              size: AppSizes.icon,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
}
