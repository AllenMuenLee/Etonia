import 'package:flutter/material.dart';

import '../../app/theme/app_icons.dart';
import '../../app/theme/app_tokens.dart';
import 'library_models.dart';
import 'open_notes.dart';

/// The open notes as a row of tabs across the top bar. Tapping a tab shows
/// its note, tapping the shown tab renames it, and each tab closes with its
/// own button. The row scrolls sideways when there are more than fit.
class NoteTabStrip extends StatelessWidget {
  const NoteTabStrip({
    super.key,
    required this.notes,
    required this.onRename,
    required this.onClose,
    this.onOpenAnother,
  });

  final OpenNotes notes;
  final ValueChanged<String> onRename;
  final ValueChanged<NoteEntry> onClose;

  /// Goes to the library to open another note beside these.
  final VoidCallback? onOpenAnother;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: notes,
      builder: (BuildContext context, Widget? _) {
        final List<NoteEntry> open = notes.notes;
        final String? shownHere = notes.active?.id;
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
                    key: const ValueKey<String>('note-tabs-single'),
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
                        onPressed: active
                            ? () => onRename(note.id)
                            : () => notes.activate(index),
                        onClose: () => onClose(note),
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
    required this.onPressed,
    required this.onClose,
  });

  static const double _maxWidth = 220;

  final String noteId;
  final String title;
  final bool active;
  final VoidCallback onPressed;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
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
        color: active ? colors.selected : colors.selected.withValues(alpha: 0),
        borderRadius: radius,
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
