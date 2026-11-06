import 'package:flutter/material.dart';

import '../../../../app/theme/app_icons.dart';
import '../../../../app/theme/app_tokens.dart';
import '../../../../shared/widgets/dog_ear.dart';
import '../../../../shared/widgets/pressable.dart';
import '../study_desk_widgets.dart';
import 'study_practice_models.dart';

enum _Sort { recent, title }

class StudyMaterialLibrary extends StatefulWidget {
  const StudyMaterialLibrary({
    super.key,
    required this.decks,
    required this.papers,
    required this.section,
    required this.onSection,
    required this.onGenerateFlashcards,
    required this.onGenerateTest,
    required this.onImport,
    required this.onOpenDeck,
    required this.onOpenPaper,
    required this.onExportDeck,
    required this.onManageDeck,
    required this.sourceLabel,
    this.courseId,
    this.courseName,
    this.status,
    this.courseNames = const {},
    this.groupByCourse = false,
    this.onSavePaper,
    this.savingPaperId,
    this.onBrowseSources,
  });

  final List<StudyPracticeSet> decks;
  final List<StudyTestPaper> papers;
  final PracticeStudioSection section;
  final ValueChanged<PracticeStudioSection> onSection;
  final VoidCallback? onGenerateFlashcards;
  final VoidCallback? onGenerateTest;
  final VoidCallback onImport;
  final ValueChanged<StudyPracticeSet> onOpenDeck;
  final ValueChanged<StudyTestPaper> onOpenPaper;
  final ValueChanged<StudyPracticeSet> onExportDeck;
  final ValueChanged<StudyPracticeSet> onManageDeck;
  final ValueChanged<StudyTestPaper>? onSavePaper;
  final String Function(List<String>) sourceLabel;
  final String? courseId;
  final String? courseName;
  final String? savingPaperId;
  final Widget? status;
  final Map<String, String> courseNames;
  final bool groupByCourse;
  final void Function(List<String> noteIds, String? sessionId)? onBrowseSources;

  @override
  State<StudyMaterialLibrary> createState() => _StudyMaterialLibraryState();
}

class _StudyMaterialLibraryState extends State<StudyMaterialLibrary> {
  final _search = TextEditingController();
  _Sort _sort = _Sort.recent;
  bool _grid = true;

  @override
  void didUpdateWidget(StudyMaterialLibrary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.courseId != widget.courseId ||
        oldWidget.section != widget.section) {
      _search.clear();
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Widget _entry(_MaterialEntry entry) => _MaterialCard(
    key: ValueKey(
      entry.deck != null
          ? 'practice-deck-${entry.deck!.id}'
          : 'study-paper-${entry.paper!.id}',
    ),
    entry: entry,
    compact: !_grid,
    source: widget.sourceLabel(entry.sourceIds),
    onSources: widget.onBrowseSources == null
        ? null
        : () => widget.onBrowseSources!(
            entry.sourceIds,
            entry.deck?.sourceSessionId ?? entry.paper?.sourceSessionId,
          ),
    onOpen: () => entry.deck != null
        ? widget.onOpenDeck(entry.deck!)
        : widget.onOpenPaper(entry.paper!),
    onExport: entry.deck == null
        ? null
        : () => widget.onExportDeck(entry.deck!),
    onManage: entry.deck == null
        ? null
        : () => widget.onManageDeck(entry.deck!),
    onSave: entry.paper == null || widget.onSavePaper == null
        ? null
        : () => widget.onSavePaper!(entry.paper!),
    saving:
        entry.paper?.id == widget.savingPaperId && widget.savingPaperId != null,
  );

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final text = Theme.of(context).textTheme;
    final tests = widget.section == PracticeStudioSection.tests;
    final query = _search.text.trim().toLowerCase();
    final entries =
        [
              if (!tests)
                for (final deck in widget.decks) _MaterialEntry.deck(deck),
              if (tests)
                for (final paper in widget.papers) _MaterialEntry.paper(paper),
            ]
            .where(
              (entry) =>
                  '${entry.title} ${widget.sourceLabel(entry.sourceIds)} ${widget.courseNames[entry.courseId] ?? ''}'
                      .toLowerCase()
                      .contains(query),
            )
            .toList()
          ..sort(
            (a, b) => _sort == _Sort.recent
                ? b.updated.compareTo(a.updated)
                : a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          );
    final groups = <String?, List<_MaterialEntry>>{};
    for (final entry in entries) {
      (groups[widget.groupByCourse ? entry.courseId : null] ??= []).add(entry);
    }
    final groupIds = groups.keys.whereType<String>().toList()
      ..sort(
        (a, b) =>
            (widget.courseNames[a] ?? a).compareTo(widget.courseNames[b] ?? b),
      );
    final orderedGroups = <String?>[
      if (groups.containsKey(null)) null,
      ...groupIds,
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final inset = constraints.maxWidth >= 700
            ? AppSpacing.xl
            : AppSpacing.md;
        final width = constraints.maxWidth.clamp(0, 1180) - inset * 2;
        final columns = width >= 850
            ? 3
            : width >= 520
            ? 2
            : 1;
        final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1180),
            child: CustomScrollView(
              key: const ValueKey('study-practice-studio'),
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.all(inset),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        StudyPageHeader(
                          title: tests ? 'Tests' : 'Flashcards',
                          titleStyle: text.displaySmall,
                          subtitle:
                              'Pick up where you left off, or create something new.',
                          action: tests
                              ? Wrap(
                                  spacing: AppSpacing.xs,
                                  runSpacing: AppSpacing.xs,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    OutlinedButton.icon(
                                      key: const ValueKey(
                                        'study-material-import',
                                      ),
                                      onPressed: widget.onImport,
                                      icon: const Icon(AppIcons.pdf, size: 18),
                                      label: const Text('Import test paper'),
                                    ),
                                    FilledButton.icon(
                                      key: const ValueKey('practice-generate'),
                                      onPressed: widget.onGenerateTest,
                                      icon: const Icon(AppIcons.add, size: 18),
                                      label: const Text('Create test'),
                                    ),
                                  ],
                                )
                              : FilledButton.icon(
                                  key: const ValueKey('practice-generate'),
                                  onPressed: widget.onGenerateFlashcards,
                                  icon: const Icon(AppIcons.add, size: 18),
                                  label: const Text('Create flashcards'),
                                ),
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        TextField(
                          key: const ValueKey('study-material-search'),
                          controller: _search,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            hintText: tests ? 'Find tests' : 'Find flashcards',
                            prefixIcon: const Icon(AppIcons.search, size: 18),
                            suffixIcon: query.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'Clear search',
                                    icon: const Icon(AppIcons.clear),
                                    onPressed: () => setState(_search.clear),
                                  ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Wrap(
                          alignment: WrapAlignment.end,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: AppSpacing.xs,
                          children: [
                            PopupMenuButton<_Sort>(
                              tooltip: 'Sort study material',
                              icon: const Icon(AppIcons.sort),
                              initialValue: _sort,
                              onSelected: (sort) =>
                                  setState(() => _sort = sort),
                              itemBuilder: (_) => [
                                CheckedPopupMenuItem(
                                  value: _Sort.recent,
                                  checked: _sort == _Sort.recent,
                                  child: const Text('Recently studied'),
                                ),
                                CheckedPopupMenuItem(
                                  value: _Sort.title,
                                  checked: _sort == _Sort.title,
                                  child: const Text('Name'),
                                ),
                              ],
                            ),
                            IconButton(
                              key: const ValueKey('study-material-grid'),
                              tooltip: 'Grid view',
                              isSelected: _grid,
                              onPressed: () => setState(() => _grid = true),
                              icon: const Icon(Icons.grid_view_rounded),
                            ),
                            IconButton(
                              key: const ValueKey('study-material-list'),
                              tooltip: 'List view',
                              isSelected: !_grid,
                              onPressed: () => setState(() => _grid = false),
                              icon: const Icon(Icons.view_list_rounded),
                            ),
                          ],
                        ),
                        if (widget.status != null) ...[
                          const SizedBox(height: AppSpacing.md),
                          widget.status!,
                        ],
                      ],
                    ),
                  ),
                ),
                if (entries.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: StudyEmptyState(
                      symbol: Icon(
                        tests ? AppIcons.note : AppIcons.template,
                        size: 32,
                        color: colors.textSecondary,
                      ),
                      title: query.isNotEmpty
                          ? 'No matching material'
                          : tests
                          ? 'Your tests belong here'
                          : 'Your flashcards belong here',
                      message: query.isNotEmpty
                          ? 'Try another title or source note.'
                          : 'Choose material from your library to get started.',
                      action: query.isNotEmpty
                          ? TextButton(
                              onPressed: () => setState(_search.clear),
                              child: const Text('Clear search'),
                            )
                          : null,
                    ),
                  ),
                for (final groupId in orderedGroups) ...[
                  if (widget.groupByCourse)
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        inset,
                        AppSpacing.sm,
                        inset,
                        AppSpacing.md,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: Text(
                          groupId == null
                              ? 'Ungrouped'
                              : widget.courseNames[groupId] ?? 'Archived class',
                          key: ValueKey(
                            'study-material-group-${groupId ?? 'ungrouped'}',
                          ),
                          style: text.titleMedium,
                        ),
                      ),
                    ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      inset,
                      0,
                      inset,
                      AppSpacing.xl,
                    ),
                    sliver: _grid
                        ? SliverGrid.builder(
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: columns,
                                  mainAxisExtent: 300 + (scale - 1) * 170,
                                  mainAxisSpacing: AppSpacing.lg,
                                  crossAxisSpacing: AppSpacing.lg,
                                ),
                            itemCount: groups[groupId]!.length,
                            itemBuilder: (context, index) =>
                                _entry(groups[groupId]![index]),
                          )
                        : SliverList.separated(
                            itemCount: groups[groupId]!.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: AppSpacing.xs),
                            itemBuilder: (context, index) =>
                                _entry(groups[groupId]![index]),
                          ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MaterialEntry {
  const _MaterialEntry.deck(StudyPracticeSet value)
    : deck = value,
      paper = null;
  const _MaterialEntry.paper(StudyTestPaper value) : paper = value, deck = null;
  final StudyPracticeSet? deck;
  final StudyTestPaper? paper;
  String? get courseId => deck?.courseId ?? paper?.courseId;
  String get title => deck?.title ?? paper!.title;
  DateTime get updated => deck?.updatedAt ?? paper!.updatedAt;
  List<String> get sourceIds => deck?.sourceNoteIds ?? paper!.sourceNoteIds;
  String get preview => deck != null
      ? deck!.flashcards.first.frontPrompt
      : paper!.questions.isNotEmpty
      ? paper!.questions.first.prompt
      : paper!.instructions;
  String get kind => deck != null ? 'Flashcards' : 'Test paper';
  String get detail => deck != null
      ? '${deck!.flashcards.length} ${deck!.flashcards.length == 1 ? 'card' : 'cards'}'
      : '${paper!.questions.length} ${paper!.questions.length == 1 ? 'question' : 'questions'}';
  String get status => deck != null
      ? deck!.masteredCount == 0
            ? 'Ready to study'
            : '${deck!.masteredCount} of ${deck!.flashcards.length} mastered'
      : paper!.isSubmitted
      ? '${paper!.totalScore?.toStringAsFixed(0) ?? 0} / ${paper!.totalPoints} points'
      : paper!.answeredCount == 0
      ? 'Ready to begin'
      : '${paper!.answeredCount} answered';
}

class _MaterialCard extends StatelessWidget {
  const _MaterialCard({
    super.key,
    required this.entry,
    required this.source,
    required this.onOpen,
    this.onExport,
    this.onManage,
    this.onSave,
    this.onSources,
    this.saving = false,
    this.compact = false,
  });
  final _MaterialEntry entry;
  final String source;
  final VoidCallback onOpen;
  final VoidCallback? onExport;
  final VoidCallback? onManage;
  final VoidCallback? onSave;
  final VoidCallback? onSources;
  final bool saving;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final text = Theme.of(context).textTheme;
    final deck = entry.deck;
    final paper = entry.paper;
    if (compact) {
      return StudySurface(
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          leading: Icon(deck != null ? AppIcons.template : AppIcons.note),
          title: Text(
            entry.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${entry.detail} | ${entry.status}\n$source',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: onOpen,
          trailing: PopupMenuButton<String>(
            tooltip: deck != null ? 'Deck actions' : 'Test actions',
            onSelected: (action) {
              switch (action) {
                case 'open':
                  onOpen();
                case 'export':
                  onExport?.call();
                case 'manage':
                  onManage?.call();
                case 'save':
                  onSave?.call();
                case 'sources':
                  onSources?.call();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'open', child: Text('Open')),
              if (onSources != null)
                const PopupMenuItem(
                  value: 'sources',
                  child: Text('Browse sources'),
                ),
              if (onExport != null)
                const PopupMenuItem(
                  value: 'export',
                  child: Text('Export Test PDF'),
                ),
              if (onManage != null)
                const PopupMenuItem(
                  value: 'manage',
                  child: Text('Edit / Manage'),
                ),
              if (onSave != null)
                PopupMenuItem(
                  value: 'save',
                  enabled: !saving,
                  child: const Text('Add to library or folder'),
                ),
            ],
          ),
        ),
      );
    }
    return Pressable(
      child: StudySurface(
        onTap: onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                color: colors.surfaceMuted.withValues(alpha: .45),
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.md,
                  AppSpacing.lg,
                  0,
                ),
                child: _MaterialPreview(entry: entry),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.xs,
                AppSpacing.xxs,
                AppSpacing.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${entry.kind} · ${entry.detail}',
                          style: text.labelMedium,
                        ),
                      ),
                      PopupMenuButton<String>(
                        key: ValueKey(
                          deck != null
                              ? 'practice-deck-menu-${deck.id}'
                              : 'study-paper-menu-${paper!.id}',
                        ),
                        tooltip: deck != null ? 'Deck actions' : 'Test actions',
                        icon: Icon(
                          AppIcons.more,
                          color: colors.textSecondary,
                          size: 20,
                        ),
                        onSelected: (action) {
                          switch (action) {
                            case 'open':
                              onOpen();
                            case 'export':
                              onExport?.call();
                            case 'manage':
                              onManage?.call();
                            case 'save':
                              onSave?.call();
                            case 'sources':
                              onSources?.call();
                          }
                        },
                        itemBuilder: (_) => [
                          if (onSources != null)
                            const PopupMenuItem(
                              value: 'sources',
                              child: Text('Browse sources'),
                            ),
                          PopupMenuItem(
                            value: 'open',
                            child: Text(
                              deck != null
                                  ? 'Practice Flashcards'
                                  : paper!.isSubmitted
                                  ? 'Review Graded Paper'
                                  : 'Take Test',
                            ),
                          ),
                          if (deck != null) ...[
                            const PopupMenuItem(
                              value: 'export',
                              child: Text('Export Test PDF'),
                            ),
                            const PopupMenuItem(
                              value: 'manage',
                              child: Text('Edit / Manage'),
                            ),
                          ],
                          if (paper != null && onSave != null)
                            PopupMenuItem(
                              key: ValueKey('study-save-paper-${paper.id}'),
                              value: 'save',
                              enabled: !saving,
                              child: Text(
                                saving
                                    ? 'Preparing PDF…'
                                    : 'Add to library or folder',
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsetsDirectional.only(
                      end: AppSpacing.sm,
                    ),
                    child: Text(
                      entry.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleMedium,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xxs),
                  InkWell(
                    onTap: onSources,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        source,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          entry.status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.labelMedium,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Text(
                        paper?.isSubmitted == true
                            ? 'Review'
                            : deck != null
                            ? 'Study'
                            : 'Start',
                        style: text.labelLarge,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Icon(
                        AppIcons.forward,
                        color: colors.textPrimary,
                        size: 16,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MaterialPreview extends StatelessWidget {
  const _MaterialPreview({required this.entry});
  final _MaterialEntry entry;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final text = Theme.of(context).textTheme;
    final content = Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.deck != null ? 'QUESTION 01' : 'QUESTION 1',
            style: text.labelSmall?.copyWith(letterSpacing: 1),
          ),
          const SizedBox(height: AppSpacing.sm),
          Expanded(
            child: Text(
              entry.preview.replaceAll(RegExp(r'[#*_`$]'), ''),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: text.bodyMedium?.copyWith(color: colors.textPrimary),
            ),
          ),
        ],
      ),
    );
    return ExcludeSemantics(
      child: entry.deck != null
          ? Stack(
              children: [
                Positioned(
                  top: 0,
                  left: AppSpacing.sm,
                  right: AppSpacing.sm,
                  bottom: AppSpacing.sm,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.divider,
                      borderRadius: AppBorderRadius.medium,
                    ),
                  ),
                ),
                Positioned(
                  top: AppSpacing.xxs,
                  left: AppSpacing.xxs,
                  right: AppSpacing.xxs,
                  bottom: AppSpacing.xxs,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surfaceMuted,
                      borderRadius: AppBorderRadius.medium,
                    ),
                  ),
                ),
                Positioned.fill(
                  top: AppSpacing.xs,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: AppBorderRadius.medium,
                    ),
                    child: content,
                  ),
                ),
              ],
            )
          : DogEar(
              radius: AppRadii.medium,
              backgroundColor: colors.surface,
              child: content,
            ),
    );
  }
}
