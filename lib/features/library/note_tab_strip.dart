import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import '../../app/theme/app_icons.dart';
import 'library_models.dart';
import 'open_notes.dart';

/// The open notes as a row of tabs across the top bar. Tapping a tab shows
/// its note, tapping the shown tab renames it, and each tab closes with its
/// own button. The row scrolls sideways when there are more than fit.
/// Holding a tab and dragging it to the left or right of the window shows
/// its note beside the one shown.
class NoteTabStrip extends StatelessWidget {
  const NoteTabStrip({
    super.key,
    required this.notes,
    required this.onRename,
    required this.onClose,
    this.onOpenAnother,
    this.pane,
  });

  final OpenNotes notes;

  /// The pane this strip belongs to, in a split window; null for the one
  /// strip of a window with a single pane.
  final int? pane;
  final ValueChanged<String> onRename;
  final ValueChanged<NoteEntry> onClose;

  /// Goes to the library to open another note beside these.
  final VoidCallback? onOpenAnother;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: notes,
      builder: (BuildContext context, Widget? _) {
        // A pane's strip holds that pane's own tabs, as a window of its own.
        final List<NoteEntry> open = notes.tabsOf(pane);
        final String? shownHere = pane == null || !notes.isSplit
            ? notes.active?.id
            : notes.paneNoteIds[pane!];
        return Semantics(
          container: true,
          explicitChildNodes: true,
          label: 'Open notes',
          child: SizedBox(
            height: AppSizes.minTouchTarget,
            child: Row(
              children: <Widget>[
                Flexible(
                  child: ListView.separated(
                    key: ValueKey<String>('note-tabs-${pane ?? 'single'}'),
                    scrollDirection: Axis.horizontal,
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: open.length,
                    separatorBuilder: (BuildContext context, int _) =>
                        const SizedBox(width: AppSpacing.xxs),
                    itemBuilder: (BuildContext context, int index) {
                      final NoteEntry note = open[index];
                      final bool active = note.id == shownHere;
                      return _NoteTab(
                        key: ValueKey<String>('note-tab-${note.id}'),
                        noteId: note.id,
                        title: note.title,
                        active: active,
                        shown: false,
                        onPressed: active
                            ? () => onRename(note.id)
                            : pane == null || !notes.isSplit
                            ? () => notes.activate(
                                notes.notes.indexWhere(
                                  (NoteEntry n) => n.id == note.id,
                                ),
                              )
                            : () => notes.showInPane(pane!, note.id),
                        onClose: () => onClose(note),
                        onDragStarted: () => notes.draggedTab.value = note.id,
                        onDragEnded: () => notes.draggedTab.value = null,
                      );
                    },
                  ),
                ),
                if (onOpenAnother != null)
                  IconButton(
                    tooltip: 'Open another note',
                    onPressed: onOpenAnother,
                    icon: const Icon(AppIcons.add, size: 20),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _NoteTab extends StatelessWidget {
  const _NoteTab({
    super.key,
    required this.noteId,
    required this.title,
    required this.active,
    this.shown = false,
    required this.onPressed,
    required this.onClose,
    required this.onDragStarted,
    required this.onDragEnded,
  });

  static const double _maxWidth = 220;

  final String noteId;
  final String title;
  final bool active;

  /// Whether its note is in a pane without being the one in focus.
  final bool shown;
  final VoidCallback onPressed;
  final VoidCallback onClose;
  final VoidCallback onDragStarted;
  final VoidCallback onDragEnded;

  @override
  Widget build(BuildContext context) {
    return LongPressDraggable<String>(
      data: noteId,
      delay: const Duration(milliseconds: 250),
      onDragStarted: onDragStarted,
      onDragEnd: (DraggableDetails _) => onDragEnded(),
      feedback: Material(
        color: Colors.transparent,
        child: _DragChip(title: title),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: _tab(context)),
      child: _tab(context),
    );
  }

  Widget _tab(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextStyle style = Theme.of(context).textTheme.labelLarge!.copyWith(
      color: active ? colors.textPrimary : colors.textSecondary,
      fontWeight: FontWeight.w600,
    );
    final BorderRadius radius = BorderRadius.circular(999);
    return AnimatedContainer(
      duration: AppMotion.resolve(context, AppMotion.snappy.duration),
      curve: AppMotion.fadeInCurve,
      constraints: const BoxConstraints(maxWidth: _maxWidth),
      decoration: BoxDecoration(
        // A selected capsule behind the title; its text never changes weight.
        color: active ? colors.selected : colors.selected.withValues(alpha: 0),
        borderRadius: radius,
        border: Border.all(
          color: shown ? colors.divider : colors.divider.withValues(alpha: 0),
          width: AppSizes.hairline,
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Flexible(
              child: Tooltip(
                message: active ? 'Rename note' : title,
                excludeFromSemantics: true,
                child: Semantics(
                  button: true,
                  selected: active,
                  label: active ? 'Note title, $title' : 'Show $title',
                  excludeSemantics: true,
                  child: InkWell(
                    onTap: onPressed,
                    borderRadius: radius,
                    hoverColor: colors.textPrimary.withValues(alpha: 0.06),
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: AppSpacing.sm,
                        end: AppSpacing.xxs,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Flexible(
                            child: Align(
                              widthFactor: 1,
                              child: AnimatedDefaultTextStyle(
                                duration: AppMotion.resolve(
                                  context,
                                  AppMotion.snappy.duration,
                                ),
                                curve: AppMotion.fadeInCurve,
                                style: style,
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
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
            ),
            IconButton(
              tooltip: 'Close $title',
              onPressed: onClose,
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              style: IconButton.styleFrom(
                foregroundColor: colors.textSecondary,
                minimumSize: const Size.square(28),
                fixedSize: const Size.square(28),
                padding: EdgeInsets.zero,
              ),
              icon: const Icon(AppIcons.close),
            ),
            const SizedBox(width: 2),
          ],
        ),
      ),
    );
  }
}

/// What follows the finger while a tab is dragged.
class _DragChip extends StatelessWidget {
  const _DragChip({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppGlass.surface(colors),
        borderRadius: AppBorderRadius.medium,
        border: Border.all(color: colors.accent),
        boxShadow: AppShadows.floating(colors),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
      ),
    );
  }
}
