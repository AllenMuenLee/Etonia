import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../shared/widgets/pressable.dart';
import 'study_desk_widgets.dart';
import 'study_motion.dart';
import 'study_desk_controller.dart';
import 'study_history_sidebar.dart'
    show showChangeClassColorDialog, studyCourseColor;
import 'study_source_picker.dart';

enum StudyMaterialKind { chats, tests, flashcards }

class StudyDeskOverview extends StatelessWidget {
  const StudyDeskOverview({
    super.key,
    required this.controller,
    required this.composer,
    required this.onCreate,
    this.onOpenSource,
    this.onAddSources,
  });

  final StudyDeskController controller;
  final Widget composer;
  final ValueChanged<StudyMaterialKind> onCreate;

  final ValueChanged<String>? onOpenSource;
  final VoidCallback? onAddSources;

  @override
  Widget build(BuildContext context) {
    final course = controller.selectedCourse!;
    final colors = AppColors.of(context);
    final entries = [
      for (final chat in controller.activitySessions)
        if (chat.courseId == course.id)
          (
            id: 'chat-${chat.id}',
            title: chat.title,
            updated: chat.updatedAt,
            icon: AppIcons.chat,
            label: 'Chat',
            open: () => controller.openSession(chat.id),
          ),
      for (final paper in controller.visibleTestPapers)
        (
          id: 'test-${paper.id}',
          title: paper.title,
          updated: paper.updatedAt,
          icon: AppIcons.note,
          label: paper.isSubmitted ? 'Completed test' : 'Test',
          open: () => paper.isSubmitted
              ? controller.openTestReview(paper)
              : controller.openTestPaper(paper),
        ),
      for (final deck in controller.visiblePracticeSets)
        if (deck.flashcards.isNotEmpty)
          (
            id: 'deck-${deck.id}',
            title: deck.title,
            updated: deck.updatedAt,
            icon: AppIcons.template,
            label: 'Flashcards',
            open: () => controller.openFlashcardSet(deck),
          ),
    ]..sort((a, b) => b.updated.compareTo(a.updated));
    return LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: CustomScrollView(
            key: ValueKey('study-class-overview-${course.id}'),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(
                    top: 24,
                    left: 24,
                    right: 24,
                    bottom: AppSpacing.xs,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(2),
                          onTap: () async {
                            final newColor = await showChangeClassColorDialog(
                              context,
                              initialHex: course.colorHex,
                            );
                            if (newColor != null) {
                              controller.recolorCourse(course.id, newColor);
                            }
                          },
                          child: Tooltip(
                            message: 'Change class color',
                            child: Container(
                              width: 40,
                              height: 4,
                              decoration: BoxDecoration(
                                color: studyCourseColor(course.colorHex),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'YOUR CLASS / STUDY DESK',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colors.textSecondary,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        course.name,
                        // The UI face, like every other text; the serif
                        // display face is not used for class names.
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'A place for your notes, ideas, and next breakthroughs.',
                        style: TextStyle(color: colors.textSecondary),
                      ),
                      const SizedBox(height: 20),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                        ),
                        child: StudyChatSources(
                          controller: controller,
                          onOpenSource: onOpenSource,
                          onAddSources: onAddSources,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      composer,
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          Pressable(
                            child: OutlinedButton.icon(
                              key: const ValueKey('study-create-tests'),
                              onPressed: () =>
                                  onCreate(StudyMaterialKind.tests),
                              icon: const AppIcon(AppIcons.add, size: 18),
                              label: const Text('New test'),
                            ),
                          ),
                          Pressable(
                            child: OutlinedButton.icon(
                              key: const ValueKey('study-create-flashcards'),
                              onPressed: () =>
                                  onCreate(StudyMaterialKind.flashcards),
                              icon: const AppIcon(AppIcons.add, size: 18),
                              label: const Text('New flashcards'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Class activity',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          // The count changes in place, as a fade.
                          AnimatedSwitcher(
                            duration: AppMotion.resolve(
                              context,
                              AppMotion.stateFade,
                            ),
                            switchInCurve: AppMotion.fadeInCurve,
                            switchOutCurve: AppMotion.fadeOutCurve,
                            child: Text(
                              '${entries.length} items',
                              key: ValueKey<int>(entries.length),
                              style: TextStyle(color: colors.textSecondary),
                            ),
                          ),
                        ],
                      ),
                      StudyDisclose(
                        child: entries.isEmpty
                            ? Padding(
                                key: const ValueKey('study-overview-empty'),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 24,
                                ),
                                child: Text(
                                  'Your chats, tests, and flashcards will appear here.',
                                  style: TextStyle(color: colors.textSecondary),
                                ),
                              )
                            : null,
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                sliver: SliverList.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    // One after another the first time they are in view, and
                    // not again as they are scrolled to or rebuilt.
                    return StudyAppear(
                      key: ValueKey('study-class-appear-${entry.id}'),
                      once: ('study-overview', course.id, entry.id),
                      delay: AppMotion.staggerStep * (index.clamp(0, 8) + 3),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                        child: StudySurface(
                          onTap: entry.open,
                          child: ListTile(
                            key: ValueKey('study-class-material-${entry.id}'),
                            leading: AppIcon(
                              entry.icon,
                              size: 20,
                              color: colors.textSecondary,
                            ),
                            title: Text(
                              entry.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.md,
                              vertical: AppSpacing.xs,
                            ),
                            subtitle: Text(
                              entry.label,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: colors.textSecondary),
                            ),
                            trailing: AppIcon(
                              AppIcons.disclosure,
                              size: 16,
                              color: colors.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
