import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import 'study_desk_controller.dart';
import 'study_source_tree.dart';

class StudyMaterialSources extends StatelessWidget {
  const StudyMaterialSources({
    super.key,
    required this.controller,
    required this.noteIds,
    required this.onOpenNote,
    required this.onOpenChat,
    this.sourceSessionId,
  });

  final StudyDeskController controller;
  final List<String> noteIds;
  final String? sourceSessionId;
  final ValueChanged<String> onOpenNote;
  final ValueChanged<String> onOpenChat;

  @override
  Widget build(BuildContext context) {
    final session = controller.allSessions
        .where((s) => s.id == sourceSessionId)
        .firstOrNull;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (sourceSessionId != null)
          ListTile(
            key: const ValueKey('study-material-source-chat'),
            leading: const Icon(AppIcons.studyDesk),
            title: Text(session?.title ?? 'Original conversation unavailable'),
            subtitle: const Text('Source conversation'),
            enabled: session != null,
            onTap: session == null ? null : () => onOpenChat(session.id),
          ),
        StudySourceTree(
          notes: [for (final id in noteIds) ?controller.noteOf(id)],
          folders: controller.allFolders.toList(),
          onOpenNote: onOpenNote,
        ),
        for (final id in noteIds)
          if (controller.noteOf(id) == null)
            const ListTile(
              enabled: false,
              leading: Icon(AppIcons.note),
              title: Text('Source note unavailable'),
            ),
        if (noteIds.isEmpty && sourceSessionId == null)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('This material has no linked library sources.'),
          ),
      ],
    );
  }
}
