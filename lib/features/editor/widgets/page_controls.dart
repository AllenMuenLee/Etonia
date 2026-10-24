import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/theme/app_icons.dart';
import '../document_io/document_models.dart';
import '../page/note_document.dart';
import '../page/page_background.dart';
import '../page/page_setup.dart';
import '../../../shared/navigation/app_dialogs.dart';
import '../../../shared/widgets/app_controls.dart';

/// The action chosen from the Add menu; remembered so subsequent clicks
/// on the Add button trigger the action directly without asking again.
enum AddPageAction { addPage, insertPdf }

/// The floating card hanging from the top bar over the page at the right:
/// holds change page, search, and the add button.
class FloatingPageControls extends StatelessWidget {
  const FloatingPageControls({
    super.key,
    required this.height,
    required this.width,
    required this.child,
  });

  final double height;
  final double width;
  final Widget child;

  static double widthFor(
    double height, {
    required bool find,
    required bool navigation,
  }) {
    const double indicator = 72;
    const double touch = AppSizes.minTouchTarget;
    final double padding = (height - touch) / 2;
    return (navigation ? 2 * touch : 0) +
        indicator +
        (find ? touch : 0) +
        touch +
        2 * padding;
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Page controls and actions',
      child: SizedBox(
        key: const ValueKey<String>('page-controls-card'),
        height: height,
        width: width,
        child: GlassSurface(
          // Joined to the top bar and the screen's right edge: rounded only where
          // it hangs free.
          borderRadius: const BorderRadius.only(
            bottomLeft: Radius.circular(AppRadii.large),
          ),
          boxShadow: AppShadows.floating(colors),
          child: Material(
            type: MaterialType.transparency,
            child: Center(
              child: FocusTraversalGroup(
                child: FittedBox(fit: BoxFit.scaleDown, child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The page indicator, `current / count`, which opens the page panel, on
/// wider layouts previous and next beside it, search, and the round Add button.
class PageControls extends StatelessWidget {
  const PageControls({
    super.key,
    required this.document,
    required this.showNavigation,
    required this.onOpenPanel,
    this.canFind = false,
    this.onFind,
    this.lastAddAction,
    this.onAddActionChanged,
    this.onChooseImageFromGallery,
    this.onTakePhoto,
    this.onInsertPdf,
  });

  final NoteDocument document;

  /// Whether previous and next sit in the bar. Without them they are only
  /// in the panel.
  final bool showNavigation;

  final VoidCallback onOpenPanel;

  final bool canFind;

  /// Called with the search button's global bounds, so the find bubble can
  /// hang below it.
  final ValueChanged<Rect>? onFind;
  final AddPageAction? lastAddAction;
  final ValueChanged<AddPageAction>? onAddActionChanged;

  final VoidCallback? onChooseImageFromGallery;
  final VoidCallback? onTakePhoto;
  final VoidCallback? onInsertPdf;

  static String describe(int index, int count) {
    return 'Page ${index + 1} of $count';
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return ListenableBuilder(
      listenable: document,
      builder: (BuildContext context, Widget? child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (showNavigation)
              ToolbarIconButton(
                tooltip: 'Previous page',
                onPressed: document.canGoBack ? document.previousPage : null,
                icon: AppIcons.previous,
              ),
            _PageNumberSection(
              document: document,
              onOpenPanel: onOpenPanel,
              colors: colors,
            ),
            if (showNavigation)
              ToolbarIconButton(
                tooltip: 'Next page',
                onPressed: document.canGoForward ? document.nextPage : null,
                icon: AppIcons.disclosure,
              ),
            if (canFind && onFind != null)
              Builder(
                builder: (BuildContext context) => ToolbarIconButton(
                  tooltip: 'Find handwriting',
                  onPressed: () {
                    final RenderBox box =
                        context.findRenderObject()! as RenderBox;
                    onFind!(box.localToGlobal(Offset.zero) & box.size);
                  },
                  icon: AppIcons.search,
                ),
              ),
            AddMenuButton(
              onAddPage: document.addPage,
              onInsertPdf: onInsertPdf,
              lastAction: lastAddAction,
              onActionChanged: onAddActionChanged,
            ),
          ],
        );
      },
    );
  }
}

class _PageNumberSection extends StatefulWidget {
  const _PageNumberSection({
    required this.document,
    required this.onOpenPanel,
    required this.colors,
  });

  final NoteDocument document;
  final VoidCallback onOpenPanel;
  final AppColors colors;

  @override
  State<_PageNumberSection> createState() => _PageNumberSectionState();
}

class _PageNumberSectionState extends State<_PageNumberSection> {
  bool _isEditing = false;

  /// Counts rejected entries; each one shakes the field.
  int _rejected = 0;
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: '${widget.document.currentIndex + 1}',
    );
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(_PageNumberSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isEditing) {
      _controller.text = '${widget.document.currentIndex + 1}';
    }
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus && _isEditing) {
      _submit(_controller.text, retryIfInvalid: false);
    }
  }

  void _startEditing() {
    setState(() {
      _isEditing = true;
      _controller.text = '${widget.document.currentIndex + 1}';
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
    _focusNode.requestFocus();
  }

  void _submit(String text, {bool retryIfInvalid = true}) {
    final int? page = int.tryParse(text.trim());
    final bool valid =
        page != null && page >= 1 && page <= widget.document.pageCount;
    if (valid) {
      widget.document.goTo(page - 1);
    } else if (retryIfInvalid && _isEditing) {
      // Stay in the field: it shakes, and the entry is selected to retype.
      setState(() {
        _rejected++;
        _controller.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _controller.text.length,
        );
      });
      _focusNode.requestFocus();
      return;
    }
    if (mounted) {
      setState(() {
        _isEditing = false;
        _controller.text = '${widget.document.currentIndex + 1}';
      });
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final int index = widget.document.currentIndex;
    final int count = widget.document.pageCount;
    final TextStyle labelStyle = Theme.of(context).textTheme.labelLarge!
        .copyWith(
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          color: widget.colors.textPrimary,
        );

    return Stack(
      alignment: Alignment.center,
      children: <Widget>[
        Opacity(
          opacity: 0,
          child: Text(
            '${index + 1} / $count',
            semanticsLabel: PageControls.describe(index, count),
            style: labelStyle,
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (_isEditing)
              Shake(
                errorToken: _rejected == 0 ? null : _rejected,
                child: Container(
                  width: 36,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: widget.colors.selected.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(AppRadii.small),
                    border: Border.all(
                      color: widget.colors.accent,
                      width: AppSizes.hairline,
                    ),
                  ),
                  child: TextField(
                    key: const ValueKey<String>('page-number-input'),
                    controller: _controller,
                    focusNode: _focusNode,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.go,
                    textAlign: TextAlign.center,
                    style: labelStyle,
                    cursorColor: widget.colors.accent,
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                      border: InputBorder.none,
                    ),
                    onSubmitted: _submit,
                  ),
                ),
              )
            else
              Tooltip(
                message: 'Go to page',
                child: InkWell(
                  key: const ValueKey<String>('page-number-button'),
                  canRequestFocus: false,
                  onTap: _startEditing,
                  borderRadius: BorderRadius.circular(AppRadii.small),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xxs,
                      vertical: AppSpacing.xxs,
                    ),
                    child: RollingNumber(index + 1, style: labelStyle),
                  ),
                ),
              ),
            Tooltip(
              message: 'Page setup',
              excludeFromSemantics: true,
              child: TextButton(
                onPressed: widget.onOpenPanel,
                style: TextButton.styleFrom(
                  foregroundColor: widget.colors.textPrimary,
                  minimumSize: const Size(0, AppSizes.minTouchTarget),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xxs,
                  ),
                  shape: const RoundedRectangleBorder(
                    borderRadius: AppBorderRadius.medium,
                  ),
                ),
                child: Text(' / $count', style: labelStyle),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A direct toolbar action for inserting an image, with the source chosen
/// from its small menu rather than from the page Add menu.
class ImageMenuButton extends StatelessWidget {
  const ImageMenuButton({
    super.key,
    this.onChooseFromGallery,
    this.onTakePhoto,
  });

  final VoidCallback? onChooseFromGallery;
  final VoidCallback? onTakePhoto;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onChooseFromGallery != null || onTakePhoto != null;
    return MenuAnchor(
      animated: !MediaQuery.disableAnimationsOf(context),
      alignmentOffset: const Offset(0, AppSpacing.xxs),
      menuChildren: <Widget>[
        MenuItemButton(
          leadingIcon: const Icon(AppIcons.insertImage),
          onPressed: onChooseFromGallery,
          child: const Text('Choose from gallery'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(AppIcons.camera),
          onPressed: onTakePhoto,
          child: const Text('Take photo'),
        ),
      ],
      builder: (BuildContext context, MenuController menu, Widget? child) {
        return IconButton(
          key: const ValueKey<String>('insert-image-button'),
          tooltip: 'Insert image',
          onPressed: enabled
              ? () => menu.isOpen ? menu.close() : menu.open()
              : null,
          icon: const Icon(AppIcons.insertImage),
        );
      },
    );
  }
}

/// A round, accent-tinted button whose menu adds a new page or inserts a
/// PDF's pages. Once an action has been chosen, clicking it executes that
/// action directly without asking again; long press opens the menu to switch.
class AddMenuButton extends StatefulWidget {
  const AddMenuButton({
    super.key,
    required this.onAddPage,
    this.onInsertPdf,
    this.lastAction,
    this.onActionChanged,
  });

  static const double _diameter = 36;

  final VoidCallback onAddPage;
  final VoidCallback? onInsertPdf;
  final AddPageAction? lastAction;
  final ValueChanged<AddPageAction>? onActionChanged;

  @override
  State<AddMenuButton> createState() => _AddMenuButtonState();
}

class _AddMenuButtonState extends State<AddMenuButton> {
  final MenuController _menu = MenuController();
  AddPageAction? _localAction;

  AddPageAction? get _effectiveAction => widget.lastAction ?? _localAction;

  void _chooseAction(AddPageAction action) {
    setState(() {
      _localAction = action;
    });
    widget.onActionChanged?.call(action);
    switch (action) {
      case AddPageAction.addPage:
        widget.onAddPage();
      case AddPageAction.insertPdf:
        widget.onInsertPdf?.call();
    }
  }

  void _handleClick() {
    final AddPageAction? action = _effectiveAction;
    if (action != null) {
      switch (action) {
        case AddPageAction.addPage:
          widget.onAddPage();
          return;
        case AddPageAction.insertPdf:
          if (widget.onInsertPdf != null) {
            widget.onInsertPdf!();
            return;
          }
      }
    }
    if (_menu.isOpen) {
      _menu.close();
    } else {
      _menu.open();
    }
  }

  void _handleLongPress() {
    if (_menu.isOpen) {
      _menu.close();
    } else {
      _menu.open();
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return MenuAnchor(
      animated: !MediaQuery.disableAnimationsOf(context),
      controller: _menu,
      alignmentOffset: const Offset(0, AppSpacing.xxs),
      menuChildren: <Widget>[
        MenuItemButton(
          leadingIcon: const Icon(AppIcons.pdf),
          onPressed: () => _chooseAction(AddPageAction.insertPdf),
          child: const Text('Insert PDF'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(AppIcons.newNote),
          onPressed: () => _chooseAction(AddPageAction.addPage),
          child: const Text('Add blank page'),
        ),
      ],
      builder: (BuildContext context, MenuController menu, Widget? child) {
        // A full touch target around the smaller round button it shows.
        return IconButton(
          key: const ValueKey<String>('add-menu-button'),
          tooltip: 'Add',
          padding: const EdgeInsets.all(
            (AppSizes.minTouchTarget - AddMenuButton._diameter) / 2,
          ),
          onPressed: _handleClick,
          onLongPress: _handleLongPress,
          icon: Container(
            width: AddMenuButton._diameter,
            height: AddMenuButton._diameter,
            decoration: BoxDecoration(
              color: colors.selected,
              shape: BoxShape.circle,
            ),
            child: Icon(
              AppIcons.add,
              size: AppSizes.icon,
              color: colors.accent,
            ),
          ),
        );
      },
    );
  }
}

/// Opens the page panel as a card under the top bar's trailing corner,
/// beside the control that opened it. A tap outside closes it.
Future<void> showPagePanel(
  BuildContext context, {
  required NoteDocument document,
  required Size writingArea,
  PageConfig config = const PageConfig(),
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close page setup',
    barrierColor: Colors.transparent,
    transitionDuration: AppMotion.resolve(context, AppMotion.snappy.duration),
    pageBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
        ) {
          final MediaQueryData media = MediaQuery.of(context);
          // Lines up with the top bar's trailing controls, at the window's
          // edge.
          return Padding(
            padding: EdgeInsetsDirectional.only(
              top: media.padding.top + AppSizes.appBarHeight,
              end: AppSpacing.xs + media.padding.right,
              start: AppSpacing.xs + media.padding.left,
              bottom: AppSpacing.xs + media.padding.bottom,
            ),
            child: Align(
              alignment: AlignmentDirectional.topEnd,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: PagePanel.width),
                child: PagePanel(
                  document: document,
                  writingArea: writingArea,
                  config: config,
                ),
              ),
            ),
          );
        },
    transitionBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
          Widget child,
        ) {
          final Animation<double> curved = CurvedAnimation(
            parent: animation,
            curve: AppMotion.fadeInCurve,
            reverseCurve: AppMotion.fadeOutCurve,
          );
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
              alignment: AlignmentDirectional.topEnd.resolve(
                Directionality.of(context),
              ),
              child: child,
            ),
          );
        },
  );
}

/// The page panel: move between pages, add and delete them, and choose the
/// current page's size and background, with a preview of the result.
class PagePanel extends StatelessWidget {
  const PagePanel({
    super.key,
    required this.document,
    required this.writingArea,
    this.config = const PageConfig(),
  });

  static const double width = 320;

  final NoteDocument document;

  /// The editor's writing area, which a fit or infinite page takes its
  /// shape from.
  final Size writingArea;

  final PageConfig config;

  /// The shape of a page of [size], in page units.
  Size _paperFor(PageSize size, PageSetup setup) {
    final PdfPageSource? pdf = document.current.pdfSource;
    if (pdf != null) {
      return pdf.pageSize;
    }
    if (size == PageSize.custom) {
      return setup.customSize!;
    }
    return size.fixedSize ??
        (writingArea.isEmpty ? const Size(4, 3) : writingArea);
  }

  Future<void> _delete(BuildContext context) async {
    final NotePage page = document.current;
    if (page.ink.strokes.isNotEmpty ||
        page.ink.images.isNotEmpty ||
        page.pdfSource != null) {
      final bool? confirmed = await showAppDialog<bool>(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text('Delete page?'),
            content: const Text('The ink on this page will be lost.'),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.of(context).danger,
                  foregroundColor: AppColors.of(context).onAccent,
                ),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Delete'),
              ),
            ],
          );
        },
      );
      if (confirmed != true) {
        return;
      }
    }
    document.deletePage(document.currentIndex);
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final AppColors colors = AppColors.of(context);
    const BorderRadius radius = AppBorderRadius.large;
    return GlassSurface(
      borderRadius: radius,
      boxShadow: AppShadows.floating(colors),
      child: Material(
        type: MaterialType.transparency,
        child: ListenableBuilder(
          listenable: document,
          builder: (BuildContext context, Widget? child) {
            final PageSetup setup = document.current.setup;
            final bool pdf = document.current.pdfSource != null;
            return ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(AppSpacing.md),
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          PageControls.describe(
                            document.currentIndex,
                            document.pageCount,
                          ),
                          style: text.titleMedium!.copyWith(
                            fontFeatures: const <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Previous page',
                      onPressed: document.canGoBack
                          ? document.previousPage
                          : null,
                      icon: const Icon(AppIcons.previous),
                    ),
                    IconButton(
                      tooltip: 'Next page',
                      onPressed: document.canGoForward
                          ? document.nextPage
                          : null,
                      icon: const Icon(AppIcons.disclosure),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          backgroundColor: colors.selected,
                          foregroundColor: colors.accent,
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm,
                          ),
                        ),
                        onPressed: document.addPage,
                        icon: const Icon(AppIcons.add, size: 18),
                        label: const Text('Add page'),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: colors.danger,
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm,
                          ),
                        ),
                        onPressed: document.pageCount > 1
                            ? () => _delete(context)
                            : null,
                        icon: const Icon(AppIcons.delete, size: 18),
                        label: const Text('Delete page'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                // The page sits in a quiet well, as it does on the desk.
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.background,
                    borderRadius: AppBorderRadius.medium,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Center(
                      child: PagePreview(
                        key: const ValueKey<String>('page-preview'),
                        paper: _paperFor(setup.size, setup),
                        background: setup.background,
                        config: config,
                        infinite:
                            !document.isImportedPdf &&
                            setup.size == PageSize.infinite,
                        maxSize: const Size(
                          PagePanel.width - 4 * AppSpacing.md,
                          136,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                _PanelDropdown<PageSize>(
                  key: const ValueKey<String>('page-size-dropdown'),
                  label: 'Size',
                  helper: pdf
                      ? 'The size of an imported PDF page is fixed.'
                      : (document.isImportedPdf
                            ? 'Infinite canvas is not available in PDF documents.'
                            : null),
                  value: setup.size,
                  onChanged: pdf
                      ? null
                      : (PageSize size) {
                          if (document.isImportedPdf &&
                              size == PageSize.infinite) {
                            return;
                          }
                          document.setSetup(setup.copyWith(size: size));
                        },
                  options: <PageSize>[
                    for (final PageSize size in PageSize.values)
                      if ((size != PageSize.custom ||
                              setup.size == PageSize.custom) &&
                          (!document.isImportedPdf ||
                              size != PageSize.infinite))
                        size,
                  ],
                  labelOf: (PageSize size) => size.label,
                  thumbnailOf: (PageSize size) => _SizeThumbnail(
                    paper: _paperFor(size, setup),
                    icon: switch (size) {
                      PageSize.infinite => AppIcons.infinite,
                      _ => null,
                    },
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                _PanelDropdown<PageBackground>(
                  key: const ValueKey<String>('page-background-dropdown'),
                  label: 'Background',
                  value: setup.background,
                  onChanged: (PageBackground background) {
                    document.setSetup(setup.copyWith(background: background));
                  },
                  options: PageBackground.values,
                  labelOf: (PageBackground background) => background.label,
                  thumbnailOf: (PageBackground background) => PagePreview(
                    paper: const Size.square(1),
                    background: background,
                    config: config,
                    maxSize: const Size.square(_PanelDropdown.thumbnailSize),
                    ruleScale: 0.3,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// A labelled dropdown whose entries each show a small picture of what
/// they choose.
class _PanelDropdown<T> extends StatelessWidget {
  const _PanelDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.thumbnailOf,
    required this.onChanged,
    this.helper,
  });

  static const double thumbnailSize = 28;

  final String label;
  final String? helper;
  final T value;
  final List<T> options;
  final String Function(T option) labelOf;
  final Widget Function(T option) thumbnailOf;

  /// Null disables the dropdown.
  final ValueChanged<T>? onChanged;

  Widget _entry(T option) {
    return Row(
      children: <Widget>[
        SizedBox.square(
          dimension: thumbnailSize,
          child: Center(child: thumbnailOf(option)),
        ),
        const SizedBox(width: AppSpacing.sm),
        Flexible(child: Text(labelOf(option), overflow: TextOverflow.ellipsis)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    // The label sits above the field, as section labels do across the
    // app, so the field itself only shows the choice.
    final Widget field = InputDecorator(
      decoration: InputDecoration(
        helperText: helper,
        helperMaxLines: 2,
        enabled: onChanged != null,
        contentPadding: const EdgeInsets.all(AppSpacing.xs),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          isDense: true,
          itemHeight: null,
          style: text.bodyMedium,
          icon: Icon(AppIcons.expand, size: 20, color: colors.textSecondary),
          borderRadius: AppBorderRadius.large,
          dropdownColor: colors.surface,
          onChanged: onChanged == null
              ? null
              : (T? option) {
                  if (option != null && option != value) {
                    onChanged!(option);
                  }
                },
          items: <DropdownMenuItem<T>>[
            for (final T option in options)
              DropdownMenuItem<T>(value: option, child: _entry(option)),
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Padding(
          padding: const EdgeInsetsDirectional.only(
            start: AppSpacing.xxs,
            bottom: AppSpacing.xs,
          ),
          child: ExcludeSemantics(child: Text(label, style: text.labelMedium)),
        ),
        Semantics(label: label, child: field),
      ],
    );
  }
}

/// A page's outline at [paper]'s proportions, or [icon] for a page that
/// takes its shape from the screen.
class _SizeThumbnail extends StatelessWidget {
  const _SizeThumbnail({required this.paper, this.icon});

  final Size paper;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    if (icon != null) {
      return Icon(icon, size: AppSizes.icon, color: colors.textSecondary);
    }
    const double box = _PanelDropdown.thumbnailSize - 4;
    final double aspect = paper.width / paper.height;
    return SizedBox(
      width: aspect >= 1 ? box : box * aspect,
      height: aspect >= 1 ? box / aspect : box,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.writingSurface,
          borderRadius: BorderRadius.circular(2),
          border: Border.all(color: colors.textSecondary, width: 1.25),
        ),
      ),
    );
  }
}

/// A small picture of a page: [paper]'s proportions fitted in [maxSize],
/// with [background]'s rules. The rules are drawn at [ruleScale] of their
/// size on the page, or at the picture's own scale when that is larger, so
/// they stay legible in a small picture.
class PagePreview extends StatelessWidget {
  const PagePreview({
    super.key,
    required this.paper,
    required this.background,
    required this.maxSize,
    this.config = const PageConfig(),
    this.ruleScale = 0.4,
    this.infinite = false,
  });

  final Size paper;
  final PageBackground background;
  final Size maxSize;
  final PageConfig config;
  final double ruleScale;

  /// Marks a page that grows as it is written on.
  final bool infinite;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final double scale = math.min(
      maxSize.width / paper.width,
      maxSize.height / paper.height,
    );
    final Size display = paper * scale;
    final double k = math.max(scale, ruleScale);
    final PageConfig scaled = PageConfig(
      lineSpacing: config.lineSpacing * k,
      gridSpacing: config.gridSpacing * k,
      dotSpacing: config.dotSpacing * k,
      marginRuleInset: config.marginRuleInset * k,
    );
    return ExcludeSemantics(
      child: SizedBox.fromSize(
        size: display,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.writingSurface,
            borderRadius: BorderRadius.circular(AppRadii.small),
            border: Border.all(color: colors.divider, width: AppSizes.hairline),
            boxShadow: AppShadows.paper(colors),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.small),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                CustomPaint(
                  painter: PageBackgroundPainter(
                    background: background,
                    rule: colors.pageRule,
                    marginRule: colors.pageMarginRule,
                    config: scaled,
                  ),
                ),
                if (infinite)
                  Align(
                    alignment: AlignmentDirectional.bottomEnd,
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.xxs),
                      child: Icon(
                        AppIcons.grows,
                        size: 16,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
