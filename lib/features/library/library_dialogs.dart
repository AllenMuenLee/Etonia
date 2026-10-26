import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import '../../app/theme/app_icons.dart';
import '../../shared/widgets/app_controls.dart';
import '../editor/page/page_background.dart';
import '../editor/page/page_setup.dart';
import '../editor/widgets/color_palette_dialog.dart';
import 'library_models.dart';
import '../../shared/navigation/app_dialogs.dart';

/// How wide a dialog that asks for a name is.
const double _fieldDialogWidth = 360;

/// Asks for a name, with [initial] selected. Returns the cleaned name, or
/// null when cancelled or left empty.
Future<String?> askForName(
  BuildContext context, {
  required String title,
  required String action,
  String initial = '',
}) async {
  final String? result = await showAppDialog<String>(
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
      content: SizedBox(
        width: _fieldDialogWidth,
        child: TextField(
          controller: _text,
          autofocus: true,
          maxLength: maxNameLength,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(hintText: 'Name', counterText: ''),
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _text,
          builder: (BuildContext context, TextEditingValue value, Widget? _) {
            return FilledButton(
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
  final bool? confirmed = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext context) {
      final AppColors colors = AppColors.of(context);
      return AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _fieldDialogWidth),
          child: Text(message),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: colors.danger,
              foregroundColor: colors.onAccent,
            ),
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
  return showAppDialog<FolderChoice>(
    context: context,
    builder: (BuildContext context) {
      return SimpleDialog(
        title: Text(title),
        titlePadding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.sm,
        ),
        contentPadding: const EdgeInsets.fromLTRB(
          AppSpacing.xs,
          0,
          AppSpacing.xs,
          AppSpacing.sm,
        ),
        children: <Widget>[
          SizedBox(
            width: _fieldDialogWidth,
            child: _FolderRow(
              name: 'Library',
              depth: 0,
              root: true,
              onTap: () => Navigator.of(context).pop(const FolderChoice(null)),
            ),
          ),
          for (final (Folder folder, int depth) in rows)
            _FolderRow(
              name: folder.name,
              depth: depth + 1,
              color: folder.color,
              onTap: () => Navigator.of(context).pop(FolderChoice(folder)),
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
    required this.onTap,
    this.root = false,
    this.color = FolderColor.accent,
  });

  final String name;
  final int depth;
  final bool root;
  final FolderColor color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: AppBorderRadius.medium,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppSizes.minTouchTarget),
        child: Padding(
          padding: EdgeInsetsDirectional.only(
            start: AppSpacing.md + AppSpacing.lg * depth,
            end: AppSpacing.md,
          ),
          child: Row(
            children: <Widget>[
              Icon(
                root ? AppIcons.library : AppIcons.folder,
                size: 20,
                color: root
                    ? colors.textSecondary
                    : resolveFolderColor(context, color),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium!.copyWith(fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// [color] as shown in the current theme.
Color resolveFolderColor(BuildContext context, FolderColor color) {
  final AppColors colors = AppColors.of(context);
  // Folders sit on a pale desk; the palette is deepened so they read as
  // objects there, the neutral most of all as it is the pale one.
  Color deepen(Color base, double amount) =>
      Color.lerp(base, Colors.black, amount)!;
  return switch (color) {
    FolderColor.accent || FolderColor.gray => deepen(colors.surfaceMuted, 0.4),
    FolderColor.yellow => deepen(colors.highlighters[0], 0.18),
    FolderColor.orange => deepen(colors.highlighters[1], 0.18),
    FolderColor.red || FolderColor.pink => deepen(colors.highlighters[2], 0.18),
    FolderColor.purple => deepen(colors.highlighters[3], 0.18),
    FolderColor.teal => deepen(colors.highlighters[4], 0.18),
    FolderColor.green => deepen(colors.highlighters[5], 0.18),
  };
}

/// A folder's name and color, as entered.
class FolderDraft {
  const FolderDraft(this.name, this.color);

  final String name;
  final FolderColor color;
}

/// Asks for a folder's name and color. Returns null when cancelled.
Future<FolderDraft?> askForFolder(
  BuildContext context, {
  required String title,
  required String action,
  String initialName = '',
  FolderColor initialColor = FolderColor.accent,
}) async {
  final FolderDraft? result = await showAppDialog<FolderDraft>(
    context: context,
    builder: (BuildContext context) => _FolderDialog(
      title: title,
      action: action,
      initialName: initialName,
      initialColor: initialColor,
    ),
  );
  if (result == null) {
    return null;
  }
  final String? name = cleanName(result.name);
  return name == null ? null : FolderDraft(name, result.color);
}

class _FolderDialog extends StatefulWidget {
  const _FolderDialog({
    required this.title,
    required this.action,
    required this.initialName,
    required this.initialColor,
  });

  final String title;
  final String action;
  final String initialName;
  final FolderColor initialColor;

  @override
  State<_FolderDialog> createState() => _FolderDialogState();
}

class _FolderDialogState extends State<_FolderDialog> {
  late final TextEditingController _text =
      TextEditingController(text: widget.initialName)
        ..selection = TextSelection(
          baseOffset: 0,
          extentOffset: widget.initialName.length,
        );
  late FolderColor _color = widget.initialColor;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    if (cleanName(_text.text) != null) {
      Navigator.of(context).pop(FolderDraft(_text.text, _color));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      // With the keyboard up on a small phone, the colors scroll.
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            width: _fieldDialogWidth,
            child: TextField(
              controller: _text,
              autofocus: true,
              maxLength: maxNameLength,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                hintText: 'Name',
                counterText: '',
              ),
              onSubmitted: (_) => _submit(),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          const SectionLabel('Color'),
          FolderColorPicker(
            selected: _color,
            onSelected: (FolderColor color) => setState(() => _color = color),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _text,
          builder: (BuildContext context, TextEditingValue value, Widget? _) {
            return FilledButton(
              onPressed: cleanName(value.text) == null ? null : _submit,
              child: Text(widget.action),
            );
          },
        ),
      ],
    );
  }
}

/// Asks for a folder's color. Returns null when cancelled.
Future<FolderColor?> pickFolderColor(
  BuildContext context, {
  required String title,
  required FolderColor initial,
}) {
  return showAppDialog<FolderColor>(
    context: context,
    builder: (BuildContext context) {
      return AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: _fieldDialogWidth,
          child: FolderColorPicker(
            selected: initial,
            onSelected: (FolderColor color) => Navigator.of(context).pop(color),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      );
    },
  );
}

/// A row of color swatches, the chosen one ringed and checked. Includes
/// a color palette button (色盤) to pick or match colors.
class FolderColorPicker extends StatelessWidget {
  const FolderColorPicker({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final FolderColor selected;
  final ValueChanged<FolderColor> onSelected;

  Future<void> _openPalette(BuildContext context) async {
    final Map<FolderColor, Color> folderColors = <FolderColor, Color>{
      for (final FolderColor color in FolderColor.values)
        color: resolveFolderColor(context, color),
    };
    final Color current =
        folderColors[selected] ?? AppColors.of(context).accent;
    final Color? picked = await showColorPaletteDialog(
      context,
      initialColor: current,
      title: 'Folder color',
    );
    if (picked != null) {
      FolderColor closest = FolderColor.accent;
      double minDistance = double.infinity;
      for (final MapEntry<FolderColor, Color> entry in folderColors.entries) {
        final Color c = entry.value;
        final double dr = c.r - picked.r;
        final double dg = c.g - picked.g;
        final double db = c.b - picked.b;
        final double dist = dr * dr + dg * dg + db * db;
        if (dist < minDistance) {
          minDistance = dist;
          closest = entry.key;
        }
      }
      onSelected(closest);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      runSpacing: AppSpacing.xxs,
      children: <Widget>[
        for (final FolderColor color in FolderColor.values)
          Semantics(
            button: true,
            inMutuallyExclusiveGroup: true,
            selected: color == selected,
            label: color.label,
            onTap: () => onSelected(color),
            excludeSemantics: true,
            child: Tooltip(
              message: color.label,
              excludeFromSemantics: true,
              child: InkResponse(
                key: ValueKey<String>('folder-color-${color.name}'),
                onTap: () => onSelected(color),
                radius: AppSizes.minTouchTarget / 2,
                child: SizedBox.square(
                  dimension: AppSizes.minTouchTarget,
                  child: Center(
                    child: AnimatedContainer(
                      duration: AppMotion.resolve(context, AppMotion.fadeIn),
                      curve: AppMotion.fadeInCurve,
                      width: 38,
                      height: 38,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: resolveFolderColor(
                            context,
                            color,
                          ).withValues(alpha: color == selected ? 1 : 0),
                          width: AppSizes.focusRingWidth,
                        ),
                      ),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: resolveFolderColor(context, color),
                          shape: BoxShape.circle,
                        ),
                        child: color == selected
                            ? const Icon(
                                AppIcons.check,
                                size: 16,
                                color: Colors.white,
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ColorPaletteButton(
          onTap: () => _openPalette(context),
          tooltip: 'Folder color palette',
          size: 28,
        ),
      ],
    );
  }
}

/// The page sizes offered for a new note, in the order shown.
const List<PageSize> templateSizes = <PageSize>[
  PageSize.a4Portrait,
  PageSize.a4Landscape,
  PageSize.letterPortrait,
  PageSize.letterLandscape,
  PageSize.square,
  PageSize.infinite,
];

/// The name and paper chosen before a note is created.
class NoteDraft {
  const NoteDraft(this.name, this.setup);

  final String name;
  final PageSetup setup;
}

/// Asks for a new note's name and template. Returns null when cancelled.
Future<NoteDraft?> pickNoteTemplate(
  BuildContext context, {
  PageSetup initial = const PageSetup(),
  String initialName = 'Untitled note',
}) {
  return showAppDialog<NoteDraft>(
    context: context,
    builder: (BuildContext context) =>
        _TemplateDialog(initial: initial, initialName: initialName),
  );
}

class _TemplateDialog extends StatefulWidget {
  const _TemplateDialog({required this.initial, required this.initialName});

  final PageSetup initial;
  final String initialName;

  @override
  State<_TemplateDialog> createState() => _TemplateDialogState();
}

class _TemplateDialogState extends State<_TemplateDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.initialName)
        ..selection = TextSelection(
          baseOffset: 0,
          extentOffset: widget.initialName.length,
        );
  late PageSize _size = templateSizes.contains(widget.initial.size)
      ? widget.initial.size
      : PageSize.a4Portrait;
  late PageBackground _background = widget.initial.background;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final String? name = cleanName(_name.text);
    if (name != null) {
      Navigator.of(
        context,
      ).pop(NoteDraft(name, PageSetup(size: _size, background: _background)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New note'),
      scrollable: true,
      content: SizedBox(
        width: 4 * _TemplateTile.width + 3 * AppSpacing.sm,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const SectionLabel('File name'),
            const SizedBox(height: AppSpacing.xs),
            TextField(
              key: const ValueKey<String>('new-note-name'),
              controller: _name,
              autofocus: true,
              maxLength: maxNameLength,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                hintText: 'Note name',
                counterText: '',
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: AppSpacing.lg),
            const SectionLabel('Paper'),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: <Widget>[
                for (final PageBackground background in PageBackground.values)
                  _TemplateTile(
                    key: ValueKey<String>('template-paper-${background.name}'),
                    label: background.label,
                    selected: background == _background,
                    onTap: () => setState(() => _background = background),
                    preview: _PaperPreview(
                      background: background,
                      aspect: 0.75,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            const SectionLabel('Page size'),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: <Widget>[
                for (final PageSize size in templateSizes)
                  _TemplateTile(
                    key: ValueKey<String>('template-size-${size.name}'),
                    label: size.label,
                    selected: size == _size,
                    onTap: () => setState(() => _size = size),
                    preview: _PaperPreview(
                      background: _background,
                      aspect: _aspectOf(size),
                      icon: switch (size) {
                        PageSize.infinite => AppIcons.infinite,
                        _ => null,
                      },
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _name,
          builder: (BuildContext context, TextEditingValue value, Widget? _) {
            return FilledButton(
              onPressed: cleanName(value.text) == null ? null : _submit,
              child: const Text('Create'),
            );
          },
        ),
      ],
    );
  }

  /// Width over height of a page of [size]; a screen-shaped guess for the
  /// sizes that follow the screen.
  static double _aspectOf(PageSize size) {
    final Size? fixed = size.fixedSize;
    return fixed == null ? 4 / 3 : fixed.width / fixed.height;
  }
}

/// One choice in the template dialog: a small picture of the paper and
/// its name, ringed in the accent color when chosen.
class _TemplateTile extends StatelessWidget {
  const _TemplateTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.preview,
  });

  static const double width = 100;

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget preview;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    const BorderRadius radius = AppBorderRadius.medium;
    return Semantics(
      button: true,
      inMutuallyExclusiveGroup: true,
      selected: selected,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: AnimatedContainer(
          duration: AppMotion.resolve(context, AppMotion.fadeIn),
          curve: AppMotion.fadeInCurve,
          width: width,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xs,
            AppSpacing.sm,
            AppSpacing.xs,
            AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: selected ? colors.selected : colors.background,
            borderRadius: radius,
            border: Border.all(
              color: selected
                  ? colors.accent
                  : colors.accent.withValues(alpha: 0),
              width: AppSizes.focusRingWidth,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(height: 60, child: Center(child: preview)),
              const SizedBox(height: AppSpacing.xs),
              SizedBox(
                height: 30,
                child: Center(
                  child: Text(
                    label,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelMedium!.copyWith(
                      color: selected ? colors.accent : colors.textPrimary,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      height: 1.2,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A miniature page: its proportions and its printed rules.
class _PaperPreview extends StatelessWidget {
  const _PaperPreview({
    required this.background,
    required this.aspect,
    this.icon,
  });

  final PageBackground background;

  /// Width over height.
  final double aspect;

  /// Marks a page that follows the screen rather than having a size.
  final IconData? icon;

  /// The preview shows a page this many times smaller than it is.
  static const double _reduction = 4;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return AspectRatio(
      aspectRatio: aspect,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(2),
          boxShadow: AppShadows.paper(colors),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: ColoredBox(
            color: colors.writingSurface,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                FittedBox(
                  fit: BoxFit.cover,
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 64 * aspect * _reduction,
                    height: 64 * _reduction,
                    child: CustomPaint(
                      painter: PageBackgroundPainter(
                        background: background,
                        rule: colors.pageRule,
                        marginRule: colors.pageMarginRule,
                      ),
                    ),
                  ),
                ),
                if (icon != null)
                  Center(
                    child: Icon(icon, size: 20, color: colors.textSecondary),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
