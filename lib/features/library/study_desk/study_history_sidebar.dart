import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../shared/navigation/app_dialogs.dart';
import '../../editor/document_io/document_platform.dart';
import 'study_desk_controller.dart';
import 'study_desk_models.dart';
import 'study_desk_widgets.dart';
import 'study_desk_overview.dart' show StudyMaterialKind;
import 'practice/study_practice_models.dart';

/// Shared by the library bar and the history drawer.
Future<void> showNewStudyChat(
  BuildContext context,
  StudyDeskController controller, {
  String? initialCourseId,
}) async {
  String? courseId =
      initialCourseId ??
      controller.selectedCourseId ??
      controller.currentSession.courseId;
  final selected = <String>{};
  void useCourseSources(String? id) {
    final course = controller.courses.where((c) => c.id == id).firstOrNull;
    selected.clear();
    if (course == null) return;
    selected.addAll(controller.courseNoteIds(course));
  }

  if (courseId != null) useCourseSources(courseId);
  final accepted = await showAppDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: const Text('New Study Chat'),
        content: SizedBox(
          width: 420,
          height: MediaQuery.sizeOf(context).height * .45,
          child: Column(
            children: [
              DropdownButtonFormField<String>(
                initialValue: courseId ?? '',
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Class'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('No class')),
                  for (final course in controller.courses)
                    DropdownMenuItem(
                      value: course.id,
                      child: Text(course.name),
                    ),
                ],
                onChanged: (value) => update(() {
                  courseId = value == '' ? null : value;
                  useCourseSources(courseId);
                }),
              ),
              const SizedBox(height: AppSpacing.sm),
              const Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text('Source notes'),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final note in controller.allNotes)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(note.title),
                        value: selected.contains(note.id),
                        onChanged: (checked) => update(() {
                          if (checked == true) {
                            selected.add(note.id);
                          } else {
                            selected.remove(note.id);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Start chat'),
          ),
        ],
      ),
    ),
  );
  if (accepted == true) {
    controller.newChat(courseId: courseId, noteIds: selected);
  }
}

Color studyCourseColor(String hex) => Color(
  0xFF000000 | (int.tryParse(hex.replaceFirst('#', ''), radix: 16) ?? 0x808080),
);

Future<StudyCourse?> showAddStudyClass(
  BuildContext context,
  StudyDeskController controller,
) async {
  var name = '';
  final palette = [
    ('Ink', AppColors.light.textSecondary),
    ('Lilac', AppColors.light.highlighters[3]),
    ('Sky', AppColors.light.highlighters[4]),
    ('Peach', AppColors.light.highlighters[1]),
  ];
  String hexOf(Color color) =>
      '#${color.toARGB32().toRadixString(16).substring(2)}';
  var color = hexOf(palette.first.$2);
  final folders = <String>{};
  final notes = <String>{};
  final accepted = await showAppDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: const Text('Add Class'),
        content: SizedBox(
          width: 420,
          height: MediaQuery.sizeOf(context).height * .45,
          child: Column(
            children: [
              _DialogTextField(
                label: 'Class name',
                onChanged: (value) => update(() => name = value),
              ),
              Wrap(
                spacing: AppSpacing.xs,
                children: [
                  for (final swatch in palette)
                    ChoiceChip(
                      tooltip: '${swatch.$1} class color',
                      label: Icon(
                        Icons.circle,
                        color: swatch.$2,
                        semanticLabel: swatch.$1,
                      ),
                      selected: color == hexOf(swatch.$2),
                      onSelected: (_) => update(() => color = hexOf(swatch.$2)),
                    ),
                ],
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final folder in controller.allFolders)
                      CheckboxListTile(
                        title: Text(folder.name),
                        value: folders.contains(folder.id),
                        onChanged: (value) => update(() {
                          if (value == true) {
                            folders.add(folder.id);
                          } else {
                            folders.remove(folder.id);
                          }
                        }),
                      ),
                    for (final note in controller.allNotes)
                      CheckboxListTile(
                        title: Text(note.title),
                        value: notes.contains(note.id),
                        onChanged: (value) => update(() {
                          if (value == true) {
                            notes.add(note.id);
                          } else {
                            notes.remove(note.id);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: name.trim().isEmpty
                ? null
                : () => Navigator.pop(context, true),
            child: const Text('Add'),
          ),
        ],
      ),
    ),
  );
  if (accepted == true && context.mounted) {
    final course = controller.addCourse(
      name,
      colorHex: color,
      noteIds: notes.toList(),
      folderIds: folders.toList(),
    );
    return course;
  }
  return null;
}

/// Search and chronological grouping are shared with the persistence tests.
Map<String, List<StudySession>> studyHistoryGroups(
  Iterable<StudySession> sessions, {
  String? courseId,
  String query = '',
  required DateTime now,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final words = query
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((s) => s.isNotEmpty);
  final groups = <String, List<StudySession>>{
    'Pinned': [],
    'Today': [],
    'Previous 7 Days': [],
    'Older Sessions': [],
  };
  final ordered = sessions.toList()
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  for (final session in ordered) {
    if (courseId != null && session.courseId != courseId) continue;
    final haystack =
        '${session.title} ${session.updatedAt.toLocal()} '
                '${session.messages.where((m) => m.fromUser).map((m) => m.text).join(' ')}'
            .toLowerCase();
    if (!words.every(haystack.contains)) continue;
    final date = session.updatedAt.toLocal();
    final group = session.isPinned
        ? 'Pinned'
        : !date.isBefore(today)
        ? 'Today'
        : !date.isBefore(today.subtract(const Duration(days: 7)))
        ? 'Previous 7 Days'
        : 'Older Sessions';
    groups[group]!.add(session);
  }
  return groups;
}

class StudyHistorySidebar extends StatefulWidget {
  const StudyHistorySidebar({
    super.key,
    required this.controller,
    required this.onClose,
    required this.onAddSources,
    required this.exportSink,
    this.closeOnSelection = false,
    this.onCreateMaterial,
    this.onBack,
  });
  final StudyDeskController controller;
  final VoidCallback onClose;
  final VoidCallback onAddSources;
  final ExportSink exportSink;
  final bool closeOnSelection;
  final ValueChanged<StudyMaterialKind>? onCreateMaterial;
  final VoidCallback? onBack;

  @override
  State<StudyHistorySidebar> createState() => _StudyHistorySidebarState();
}

class _StudyHistorySidebarState extends State<StudyHistorySidebar> {
  String _query = '';
  bool _searchOpen = false;

  Future<void> _addClass() async {
    final course = await showAddStudyClass(context, widget.controller);
    if (course != null && mounted) {
      widget.controller.openCourse(course);
      if (widget.closeOnSelection) widget.onClose();
    }
  }

  Future<void> _action(String action, StudySession session) async {
    final controller = widget.controller;
    switch (action) {
      case 'pin':
        controller.updateSession(session.id, isPinned: !session.isPinned);
      case 'delete':
        final confirmed = await showAppDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete conversation?'),
            content: Text(session.title),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (confirmed == true) controller.deleteSession(session.id);
      case 'rename':
        var text = session.title;
        final title = await showAppDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Rename conversation'),
            content: _DialogTextField(
              initialText: session.title,
              label: 'Title',
              onChanged: (value) => text = value,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, text.trim()),
                child: const Text('Save'),
              ),
            ],
          ),
        );
        if (title != null && title.isNotEmpty) {
          controller.updateSession(session.id, title: title);
        }
      case 'assign':
        final chosen = await showAppDialog<String>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Assign to Class'),
            children: [
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, ''),
                child: const Text('No class'),
              ),
              for (final course in controller.courses)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, course.id),
                  child: Text(course.name),
                ),
            ],
          ),
        );
        if (chosen != null) {
          controller.updateSession(
            session.id,
            courseId: chosen.isEmpty ? null : chosen,
            assignCourse: true,
          );
        }
      case 'export':
        final box = context.findRenderObject();
        final origin = box is RenderBox
            ? box.localToGlobal(Offset.zero) & box.size
            : null;
        Directory? directory;
        try {
          directory = await Directory.systemTemp.createTemp(
            'greatnote_transcript_',
          );
          final file = File.fromUri(directory.uri.resolve('transcript.md'));
          await file.writeAsString(
            controller.exportTranscript(session),
            flush: true,
          );
          await widget.exportSink.share(file, sharePositionOrigin: origin);
        } on Object {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Transcript could not be exported.'),
              ),
            );
          }
        } finally {
          if (directory != null) await directory.delete(recursive: true);
        }
    }
  }

  void _select(VoidCallback action) {
    action();
    if (widget.closeOnSelection) widget.onClose();
  }

  Widget _row(
    String title,
    IconData icon,
    VoidCallback onTap, {
    Key? key,
    bool selected = false,
    Color? iconColor,
    Widget? trailing,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs / 2),
    child: ListTile(
      key: key,
      minTileHeight: AppSizes.minTouchTarget,
      contentPadding: const EdgeInsetsDirectional.only(
        start: AppSpacing.md,
        end: AppSpacing.xxs,
      ),
      horizontalTitleGap: AppSpacing.sm,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.small),
      ),
      selected: selected,
      selectedTileColor: AppColors.of(context).selected,
      selectedColor: AppColors.of(context).textPrimary,
      leading: Icon(
        icon,
        size: 20,
        color: iconColor ?? AppColors.of(context).textSecondary,
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      trailing: trailing,
      onTap: () => _select(onTap),
    ),
  );

  Widget _sessionRow(StudySession session) => _row(
    session.title,
    session.isPinned ? Icons.push_pin_rounded : AppIcons.library,
    () => widget.controller.openSession(session.id),
    key: ValueKey('study-session-${session.id}'),
    selected:
        widget.controller.mode == StudyDeskMode.chat &&
        session.id == widget.controller.sessionId,
    trailing: PopupMenuButton<String>(
      tooltip: 'Conversation actions',
      itemBuilder: (_) => _menu(session),
      onSelected: (action) => unawaited(_action(action, session)),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final colors = AppColors.of(context);
      bool matches(String title) =>
          title.toLowerCase().contains(_query.toLowerCase());
      final sessions =
          controller.activitySessions.where((s) => matches(s.title)).toList()
            ..sort(
              (a, b) => a.isPinned == b.isPinned
                  ? b.updatedAt.compareTo(a.updatedAt)
                  : a.isPinned
                  ? -1
                  : 1,
            );
      final activity =
          [
            for (final session in sessions)
              (
                updated: session.updatedAt,
                pinned: session.isPinned,
                build: () => _sessionRow(session),
              ),
            for (final paper in controller.testPapers)
              if (matches(paper.title))
                (
                  updated: paper.updatedAt,
                  pinned: false,
                  build: () => _row(
                    paper.title,
                    AppIcons.note,
                    () => paper.isSubmitted
                        ? controller.openTestReview(paper)
                        : controller.openTestPaper(paper),
                    key: ValueKey('study-recent-test-${paper.id}'),
                  ),
                ),
            for (final deck in controller.practiceSets)
              if (deck.flashcards.isNotEmpty && matches(deck.title))
                (
                  updated: deck.updatedAt,
                  pinned: false,
                  build: () => _row(
                    deck.title,
                    AppIcons.template,
                    () => controller.openFlashcardSet(deck),
                    key: ValueKey('study-recent-deck-${deck.id}'),
                  ),
                ),
          ]..sort(
            (a, b) => a.pinned == b.pinned
                ? b.updated.compareTo(a.updated)
                : a.pinned
                ? -1
                : 1,
          );
      return Material(
        key: const ValueKey('study-navigation-sidebar'),
        color: colors.surfaceMuted,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 4, top: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Study Desk',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('study-search-history'),
                      tooltip: 'Search history',
                      isSelected: _searchOpen,
                      onPressed: () => setState(() {
                        _searchOpen = !_searchOpen;
                        if (!_searchOpen) _query = '';
                      }),
                      icon: const Icon(AppIcons.search, size: 20),
                    ),
                    IconButton(
                      tooltip: 'Close history',
                      onPressed: widget.onClose,
                      icon: const Icon(AppIcons.sidebar, size: 20),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: _row(
                  'New chat',
                  AppIcons.newNote,
                  controller.newChat,
                  key: const ValueKey('study-new-chat'),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  children: [
                    _row(
                      'Flashcards',
                      AppIcons.template,
                      () => controller.openMaterialLibrary(
                        PracticeStudioSection.flashcards,
                      ),
                      key: const ValueKey('study-nav-flashcards'),
                      selected:
                          controller.mode == StudyDeskMode.practice &&
                          controller.practiceSection ==
                              PracticeStudioSection.flashcards,
                    ),
                    _row(
                      'Tests',
                      AppIcons.note,
                      () => controller.openMaterialLibrary(
                        PracticeStudioSection.tests,
                      ),
                      key: const ValueKey('study-nav-tests'),
                      selected:
                          controller.mode == StudyDeskMode.practice &&
                          controller.practiceSection ==
                              PracticeStudioSection.tests,
                    ),
                  ],
                ),
              ),
              if (_searchOpen)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    key: const ValueKey('study-sidebar-search'),
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Search',
                      prefixIcon: Icon(AppIcons.search, size: 18),
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.all(
                          Radius.circular(AppRadii.medium),
                        ),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (value) => setState(() => _query = value),
                  ),
                ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Classes',
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(color: colors.textSecondary),
                            ),
                          ),
                          IconButton(
                            key: const ValueKey('study-add-class'),
                            tooltip: 'Add Class',
                            onPressed: _addClass,
                            icon: const Icon(AppIcons.add, size: 18),
                          ),
                        ],
                      ),
                    ),
                    for (final course in controller.courses)
                      _row(
                        course.name,
                        AppIcons.folder,
                        () => controller.openCourse(course),
                        key: ValueKey('study-class-${course.id}'),
                        iconColor: studyCourseColor(course.colorHex),
                        selected: course.id == controller.selectedCourseId,
                      ),
                    if (_query.isEmpty &&
                        controller.suggestedClassFolders.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
                        child: StudySuggestedClasses(
                          controller: controller,
                          compact: true,
                          onSelected: widget.closeOnSelection
                              ? widget.onClose
                              : null,
                        ),
                      ),
                    const SizedBox(height: 20),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        'Recent',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(color: colors.textSecondary),
                      ),
                    ),
                    for (final entry in activity) entry.build(),
                    if (activity.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          _query.isEmpty
                              ? 'Your work will appear here.'
                              : 'No results',
                          style: TextStyle(
                            color: colors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: _row(
                  'Back',
                  AppIcons.back,
                  widget.onBack ?? controller.handleBack,
                  key: const ValueKey('study-sidebar-back'),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  List<PopupMenuEntry<String>> _menu(StudySession session) => [
    const PopupMenuItem(value: 'rename', child: Text('Rename')),
    const PopupMenuItem(value: 'assign', child: Text('Assign to Class')),
    PopupMenuItem(
      value: 'pin',
      child: Text(session.isPinned ? 'Unpin' : 'Pin'),
    ),
    const PopupMenuItem(value: 'export', child: Text('Export Transcript')),
    PopupMenuItem(
      value: 'delete',
      child: Text(
        'Delete',
        style: TextStyle(color: AppColors.of(context).danger),
      ),
    ),
  ];
}

class _DialogTextField extends StatefulWidget {
  const _DialogTextField({
    required this.label,
    required this.onChanged,
    this.initialText = '',
  });
  final String label;
  final String initialText;
  final ValueChanged<String> onChanged;
  @override
  State<_DialogTextField> createState() => _DialogTextFieldState();
}

class _DialogTextFieldState extends State<_DialogTextField> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initialText,
  );
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _text,
    autofocus: true,
    maxLength: 120,
    decoration: InputDecoration(labelText: widget.label),
    onChanged: widget.onChanged,
  );
}
