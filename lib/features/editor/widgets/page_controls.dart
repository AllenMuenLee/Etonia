import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../shared/motion/motion_memory.dart';
import '../../../app/theme/app_icons.dart';
import '../document_io/document_models.dart';
import '../ink/ink_painter.dart';
import '../ink/stroke.dart';
import '../page/note_document.dart';
import '../page/page_background.dart';
import '../page/page_setup.dart';
import 'page_chapters.dart';
import '../../../shared/navigation/app_dialogs.dart';
import '../../../shared/widgets/app_controls.dart';

/// The action chosen from the Add menu; remembered so subsequent clicks
/// on the Add button trigger the action directly without asking again.
enum AddPageAction { addPage, insertPdf }

/// The floating card hanging from the top bar over the page at the right:
/// holds search, page creation, and page settings.
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

  static double widthFor(double height, {required bool find}) {
    const double touch = AppSizes.minTouchTarget;
    final double padding = (height - touch) / 2;
    return (find ? touch : 0) + 2 * touch + 2 * padding;
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

/// The page overview's button, in the editor's top-left cluster. Page
/// switching and the page number live in the overview it opens; it never
/// opens settings.
class PageNavigationControls extends StatelessWidget {
  const PageNavigationControls({
    super.key,
    required this.onOpenOverview,
    this.overviewOpen,
  });

  final VoidCallback onOpenOverview;

  /// Whether the overview is showing, which the grid button reflects.
  final ValueListenable<bool>? overviewOpen;

  static double widthFor() => AppSizes.minTouchTarget;

  static String describe(int index, int count) {
    return 'Page ${index + 1} of $count';
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final Widget grid = ToolbarIconButton(
      tooltip: 'Page overview',
      onPressed: onOpenOverview,
      icon: AppIcons.gridView,
    );
    if (overviewOpen == null) return grid;
    return ValueListenableBuilder<bool>(
      valueListenable: overviewOpen!,
      child: grid,
      builder: (BuildContext context, bool open, Widget? grid) {
        return Stack(
          alignment: Alignment.center,
          children: <Widget>[
            AnimatedOpacity(
              opacity: open ? 1 : 0,
              duration: AppMotion.resolve(
                context,
                open ? AppMotion.fadeIn : AppMotion.fadeOut,
              ),
              child: Container(
                width: AppSizes.paletteButtonVisual,
                height: AppSizes.paletteButtonVisual,
                decoration: BoxDecoration(
                  color: colors.selected,
                  borderRadius: AppBorderRadius.medium,
                ),
              ),
            ),
            grid!,
          ],
        );
      },
    );
  }
}

/// Page-level actions shown in the editor's top-right cluster. Page switching
/// lives in [PageNavigationControls], separate from the settings opened here.
class PageControls extends StatelessWidget {
  const PageControls({
    super.key,
    required this.document,
    required this.onOpenSettings,
    this.canFind = false,
    this.onFind,
    this.lastAddAction,
    this.onAddActionChanged,
    this.onChooseImageFromGallery,
    this.onTakePhoto,
    this.onInsertPdf,
  });

  final NoteDocument document;
  final VoidCallback onOpenSettings;

  final bool canFind;

  /// Called with the search button's global bounds, so the find bubble can
  /// hang below it.
  final ValueChanged<Rect>? onFind;
  final AddPageAction? lastAddAction;
  final ValueChanged<AddPageAction>? onAddActionChanged;

  final VoidCallback? onChooseImageFromGallery;
  final VoidCallback? onTakePhoto;
  final VoidCallback? onInsertPdf;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: document,
      builder: (BuildContext context, Widget? child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
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
            ToolbarIconButton(
              key: const ValueKey<String>('page-settings-button'),
              tooltip: 'Page settings',
              onPressed: onOpenSettings,
              icon: AppIcons.more,
            ),
          ],
        );
      },
    );
  }
}

/// The current page number as a capsule in the page overview's header: a tap
/// turns it into a field for typing the page to go to.
class _PageNumberField extends StatefulWidget {
  const _PageNumberField({required this.document});

  static const double height = 36;

  final NoteDocument document;

  @override
  State<_PageNumberField> createState() => _PageNumberFieldState();
}

class _PageNumberFieldState extends State<_PageNumberField> {
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
  void didUpdateWidget(_PageNumberField oldWidget) {
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
    final AppColors colors = AppColors.of(context);
    final int index = widget.document.currentIndex;
    final int count = widget.document.pageCount;
    final TextStyle labelStyle = Theme.of(context).textTheme.labelLarge!
        .copyWith(
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          color: colors.textPrimary,
        );
    const BorderRadius capsule = BorderRadius.all(
      Radius.circular(_PageNumberField.height / 2),
    );
    // Wide enough for the longest number, so the capsule keeps its width
    // as the page changes and while typing.
    final TextPainter widest = TextPainter(
      text: TextSpan(text: '$count', style: labelStyle),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final double numberWidth = math.max(AppSpacing.lg, widest.width);
    widest.dispose();

    final Widget number = _isEditing
        ? Shake(
            errorToken: _rejected == 0 ? null : _rejected,
            child: SizedBox(
              width: numberWidth + AppSpacing.xs,
              child: TextField(
                key: const ValueKey<String>('page-number-input'),
                controller: _controller,
                focusNode: _focusNode,
                autofocus: true,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.go,
                textAlign: TextAlign.center,
                style: labelStyle.copyWith(color: colors.accent),
                cursorColor: colors.accent,
                // The capsule is the field's only edge.
                decoration: const InputDecoration(
                  isDense: true,
                  filled: false,
                  contentPadding: EdgeInsets.zero,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
                onSubmitted: _submit,
              ),
            ),
          )
        : SizedBox(
            width: numberWidth + AppSpacing.xs,
            child: Center(child: RollingNumber(index + 1, style: labelStyle)),
          );

    return Semantics(
      button: !_isEditing,
      label: PageNavigationControls.describe(index, count),
      hint: _isEditing ? null : 'Go to page',
      child: Tooltip(
        message: 'Go to page',
        excludeFromSemantics: true,
        child: InkWell(
          key: const ValueKey<String>('page-number-button'),
          canRequestFocus: false,
          onTap: _isEditing ? null : _startEditing,
          borderRadius: capsule,
          child: SizedBox(
            height: AppSizes.minTouchTarget,
            child: Center(
              child: AnimatedContainer(
                duration: AppMotion.resolve(context, AppMotion.stateFade),
                height: _PageNumberField.height,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                decoration: BoxDecoration(
                  color: _isEditing ? colors.selected : colors.background,
                  borderRadius: capsule,
                  border: Border.all(
                    color: _isEditing ? colors.accent : colors.divider,
                    width: AppSizes.hairline,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    number,
                    ExcludeSemantics(
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(
                          end: AppSpacing.xxs,
                        ),
                        child: Text(
                          '/ $count',
                          style: labelStyle.copyWith(
                            color: colors.textSecondary,
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

/// Hangs the page overview under [child], the top-left card that holds its
/// button. Unlike a dialog it leaves the top bar and the cards across the top
/// usable while it shows, so stepping through pages there updates the grid in
/// place and the grid button closes it again. A press on the page, Escape, or
/// choosing a page closes it too.
class PageOverviewAnchor extends StatefulWidget {
  const PageOverviewAnchor({
    super.key,
    required this.open,
    required this.document,
    required this.writingArea,
    this.config = const PageConfig(),
    this.loadOutline,
    required this.child,
  });

  final ValueNotifier<bool> open;
  final NoteDocument document;
  final Size writingArea;
  final PageConfig config;

  /// Reads the outline of a PDF in the note, to choose pages by chapter.
  /// Without it the overview shows pages only.
  final PdfOutlineLoader? loadOutline;
  final Widget child;

  @override
  State<PageOverviewAnchor> createState() => _PageOverviewAnchorState();
}

class _PageOverviewAnchorState extends State<PageOverviewAnchor>
    with SingleTickerProviderStateMixin {
  final LayerLink _link = LayerLink();
  final OverlayPortalController _portal = OverlayPortalController();
  // Made in initState, not lazily: an overview never opened would otherwise
  // first create its ticker in dispose, from a deactivated context.
  late final AnimationController _reveal;
  late final CurvedAnimation _curved;
  late final Animation<double> _scale;

  /// Whether pages or chapters show, kept between openings.
  final ValueNotifier<PageOverviewView> _view = ValueNotifier<PageOverviewView>(
    PageOverviewView.pages,
  );

  /// The note's chapters, read when the overview first opens.
  NoteChapterIndex? _chapters;

  @override
  void initState() {
    super.initState();
    _reveal = AnimationController(vsync: this)
      ..addStatusListener(_onRevealStatus);
    _curved = CurvedAnimation(
      parent: _reveal,
      curve: AppMotion.fadeInCurve,
      reverseCurve: AppMotion.fadeOutCurve,
    );
    _scale = Tween<double>(begin: 0.94, end: 1).animate(_curved);
    widget.open.addListener(_sync);
    if (widget.open.value) {
      _indexChapters();
      _reveal.value = 1;
      _portal.show();
    }
  }

  @override
  void didUpdateWidget(PageOverviewAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document != widget.document ||
        oldWidget.loadOutline != widget.loadOutline) {
      _chapters?.dispose();
      _chapters = null;
      if (widget.open.value) _indexChapters();
    }
    if (oldWidget.open != widget.open) {
      oldWidget.open.removeListener(_sync);
      widget.open.addListener(_sync);
      _sync();
    }
  }

  void _indexChapters() {
    final PdfOutlineLoader? loadOutline = widget.loadOutline;
    if (loadOutline == null || _chapters != null) return;
    _chapters = NoteChapterIndex(
      document: widget.document,
      loadOutline: loadOutline,
    );
  }

  void _sync() {
    if (widget.open.value) {
      _indexChapters();
      _reveal.duration = AppMotion.resolve(context, AppMotion.snappy.duration);
      _portal.show();
      _reveal.forward();
    } else if (_reveal.isDismissed) {
      _portal.hide();
    } else {
      _reveal.reverseDuration = AppMotion.resolve(context, AppMotion.fadeOut);
      _reveal.reverse();
    }
  }

  void _onRevealStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && _portal.isShowing) {
      _portal.hide();
    }
  }

  void _close() => widget.open.value = false;

  @override
  void dispose() {
    widget.open.removeListener(_sync);
    _chapters?.dispose();
    _view.dispose();
    _curved.dispose();
    _reveal.dispose();
    super.dispose();
  }

  Widget _buildOverlay(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);
    final RenderObject? anchor = this.context.findRenderObject();
    // Where the card ends, in the overlay's coordinates: the page starts
    // below it.
    final Offset corner = anchor is RenderBox && anchor.hasSize
        ? anchor.localToGlobal(anchor.size.bottomLeft(Offset.zero))
        : Offset(0, media.padding.top + AppSizes.appBarHeight);
    const double gap = AppSpacing.xs;
    final double maxWidth = math.min(
      PageOverviewPanel.width,
      media.size.width - corner.dx - 2 * gap - media.padding.right,
    );
    final double maxHeight =
        media.size.height - corner.dy - 2 * gap - media.padding.bottom;
    return ValueListenableBuilder<bool>(
      valueListenable: widget.open,
      builder: (BuildContext context, bool open, Widget? panel) {
        // While it fades out, presses already reach what is beneath.
        return IgnorePointer(ignoring: !open, child: panel);
      },
      child: Stack(
        children: <Widget>[
          // Only the page closes it: the top bar and the cards beside this
          // one stay live. The press that closes it leaves no mark.
          Positioned(
            left: 0,
            right: 0,
            top: corner.dy,
            bottom: 0,
            child: Semantics(
              label: 'Close page overview',
              onTap: _close,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (_) => _close(),
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            child: CompositedTransformFollower(
              link: _link,
              targetAnchor: Alignment.bottomLeft,
              offset: const Offset(gap, gap),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: math.max(0, maxWidth),
                  maxHeight: math.max(0, maxHeight),
                ),
                child: CallbackShortcuts(
                  bindings: <ShortcutActivator, VoidCallback>{
                    const SingleActivator(LogicalKeyboardKey.escape): _close,
                  },
                  child: Focus(
                    autofocus: true,
                    skipTraversal: true,
                    child: FadeTransition(
                      opacity: _curved,
                      child: ScaleTransition(
                        scale: _scale,
                        alignment: Alignment.topLeft,
                        // The panel's tooltips get an overlay of their own,
                        // inside the follower: Flutter cannot place one
                        // across a CompositedTransformFollower, so hovering
                        // an arrow with a mouse or a pencil threw.
                        child: Overlay.wrap(
                          alwaysSizeToContent: true,
                          clipBehavior: Clip.none,
                          child: PageOverviewPanel(
                            document: widget.document,
                            writingArea: widget.writingArea,
                            config: widget.config,
                            chapters: _chapters,
                            view: _view,
                            onSelected: _close,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: _buildOverlay,
      child: CompositedTransformTarget(link: _link, child: widget.child),
    );
  }
}

/// What the page overview lists: every page, or the chapters of the PDFs in
/// the note.
enum PageOverviewView { pages, chapters }

/// A grid of the note's pages under a header with the page number, which can
/// be typed into to go to a page. Selecting a thumbnail changes the current
/// page and calls [onSelected], so the overview can close and the page is
/// immediately usable.
///
/// When the note has [chapters], from the outline of a PDF in it, the
/// header offers them too, to go to a chapter rather than a page; [view]
/// holds which shows.
class PageOverviewPanel extends StatefulWidget {
  const PageOverviewPanel({
    super.key,
    required this.document,
    required this.writingArea,
    this.config = const PageConfig(),
    this.chapters,
    this.view,
    this.onSelected,
  });

  static const double width = 360;

  final NoteDocument document;
  final Size writingArea;
  final PageConfig config;
  final NoteChapterIndex? chapters;

  /// Owned by the panel when not given.
  final ValueNotifier<PageOverviewView>? view;
  final VoidCallback? onSelected;

  @override
  State<PageOverviewPanel> createState() => _PageOverviewPanelState();
}

class _PageOverviewPanelState extends State<PageOverviewPanel> {
  ValueNotifier<PageOverviewView>? _ownView;

  ValueNotifier<PageOverviewView> get _view =>
      widget.view ??
      (_ownView ??= ValueNotifier<PageOverviewView>(PageOverviewView.pages));

  NoteDocument get document => widget.document;

  @override
  void dispose() {
    _ownView?.dispose();
    super.dispose();
  }

  Size _paperFor(NotePage page) {
    final PdfPageSource? pdf = page.pdfSource;
    if (pdf != null) return pdf.pageSize;
    final PageSetup setup = page.setup;
    if (setup.size == PageSize.custom) return setup.customSize!;
    final Size writingArea = widget.writingArea;
    return setup.size.fixedSize ??
        page.extent ??
        (writingArea.isEmpty ? const Size(4, 3) : writingArea);
  }

  void _select(int index) {
    document.goTo(index);
    widget.onSelected?.call();
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final NoteChapterIndex? chapterIndex = widget.chapters;
    // Opaque: it hangs over the palette, whose buttons would otherwise show
    // through its header like controls of its own.
    return GlassSurface(
      color: colors.surface,
      borderRadius: AppBorderRadius.large,
      boxShadow: AppShadows.floating(colors),
      child: Material(
        type: MaterialType.transparency,
        child: ListenableBuilder(
          listenable: Listenable.merge(<Listenable?>[
            document,
            chapterIndex,
            _view,
          ]),
          builder: (BuildContext context, Widget? child) {
            final List<NoteChapter> chapters =
                chapterIndex?.chapters ?? const <NoteChapter>[];
            final PageOverviewView view = chapters.isEmpty
                ? PageOverviewView.pages
                : _view.value;
            return Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.xs,
                AppSpacing.xs,
                AppSpacing.md,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text('Pages', style: text.titleMedium),
                        ),
                      ),
                      // The arrows flank the number they change; stepping
                      // keeps the overview open, so the grid follows along.
                      ToolbarIconButton(
                        tooltip: 'Previous page',
                        onPressed: document.canGoBack
                            ? document.previousPage
                            : null,
                        icon: AppIcons.previous,
                      ),
                      _PageNumberField(document: document),
                      ToolbarIconButton(
                        tooltip: 'Next page',
                        onPressed: document.canGoForward
                            ? document.nextPage
                            : null,
                        icon: AppIcons.disclosure,
                      ),
                    ],
                  ),
                  if (chapters.isNotEmpty) ...<Widget>[
                    const SizedBox(height: AppSpacing.xs),
                    Padding(
                      padding: const EdgeInsetsDirectional.only(
                        end: AppSpacing.xs,
                      ),
                      child: SegmentedChoice<PageOverviewView>(
                        options: PageOverviewView.values,
                        selected: view,
                        labelOf: (PageOverviewView option) => switch (option) {
                          PageOverviewView.pages => 'Pages',
                          PageOverviewView.chapters => 'Chapters',
                        },
                        iconOf: (PageOverviewView option) => switch (option) {
                          PageOverviewView.pages => AppIcons.gridView,
                          PageOverviewView.chapters => AppIcons.listView,
                        },
                        keyOf: (PageOverviewView option) =>
                            ValueKey<String>('page-overview-${option.name}'),
                        onSelected: (PageOverviewView option) =>
                            _view.value = option,
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.xs),
                  Flexible(
                    child: view == PageOverviewView.chapters
                        ? PageChapterList(
                            document: document,
                            chapters: chapters,
                            onSelected: widget.onSelected,
                          )
                        : GridView.builder(
                            key: const ValueKey<String>('page-overview-grid'),
                            shrinkWrap: true,
                            // The header's capsule reaches nearer the edge than
                            // the thumbnails do.
                            padding: const EdgeInsetsDirectional.only(
                              end: AppSpacing.xs,
                            ),
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 148,
                                  mainAxisExtent: 174,
                                  crossAxisSpacing: AppSpacing.sm,
                                  mainAxisSpacing: AppSpacing.sm,
                                ),
                            itemCount: document.pageCount,
                            itemBuilder: (BuildContext context, int index) {
                              final NotePage page = document.pages[index];
                              final Size paper = _paperFor(page);
                              final bool selected =
                                  index == document.currentIndex;
                              return Semantics(
                                button: true,
                                selected: selected,
                                label: PageNavigationControls.describe(
                                  index,
                                  document.pageCount,
                                ),
                                child: InkWell(
                                  key: ValueKey<String>(
                                    'page-thumbnail-$index',
                                  ),
                                  onTap: () => _select(index),
                                  borderRadius: AppBorderRadius.medium,
                                  child: AnimatedContainer(
                                    duration: AppMotion.resolve(
                                      context,
                                      AppMotion.snappy.duration,
                                    ),
                                    padding: const EdgeInsets.all(
                                      AppSpacing.xs,
                                    ),
                                    decoration: BoxDecoration(
                                      color: selected ? colors.selected : null,
                                      borderRadius: AppBorderRadius.medium,
                                      border: Border.all(
                                        color: selected
                                            ? colors.accent
                                            : colors.divider,
                                        width: selected ? 2 : AppSizes.hairline,
                                      ),
                                    ),
                                    child: Column(
                                      children: <Widget>[
                                        Expanded(
                                          child: Center(
                                            child: PagePreview(
                                              paper: paper,
                                              background: page.setup.background,
                                              config: widget.config,
                                              infinite:
                                                  !document.isImportedPdf &&
                                                  page.setup.size ==
                                                      PageSize.infinite,
                                              maxSize: const Size(116, 132),
                                              child: _PageInkPreview(
                                                page: page,
                                                paper: paper,
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: AppSpacing.xs),
                                        Text(
                                          '${index + 1}',
                                          style: text.labelMedium?.copyWith(
                                            color: selected
                                                ? colors.accent
                                                : colors.textPrimary,
                                            fontFeatures: const <FontFeature>[
                                              FontFeature.tabularFigures(),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Opens page settings as a card under the top bar's trailing corner,
/// beside the ellipsis button. A tap outside closes it.
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
    transitionDuration: AppMotion.resolvePaced(
      context,
      AppMotion.snappy.duration,
      MotionMemory.instance.recall(('popover', 'page-setup')),
    ),
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

/// Page editing controls: add or delete a page and choose the current page's
/// size and background, with a preview of the result.
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
        motionKey: 'delete-page',
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
    // Opaque, as the page overview is: it covers the cards across the top.
    return GlassSurface(
      color: colors.surface,
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
                          'Page settings',
                          style: text.titleMedium!.copyWith(
                            fontFeatures: const <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Text(
                      PageNavigationControls.describe(
                        document.currentIndex,
                        document.pageCount,
                      ),
                      style: text.labelMedium?.copyWith(
                        color: colors.textSecondary,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
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
    this.child,
  });

  final Size paper;
  final PageBackground background;
  final Size maxSize;
  final PageConfig config;
  final double ruleScale;
  final Widget? child;

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
                ?child,
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

/// The handwriting layer inside one page-overview thumbnail. It listens only
/// to that page, so editing another page does not repaint every preview.
class _PageInkPreview extends StatelessWidget {
  const _PageInkPreview({required this.page, required this.paper});

  final NotePage page;
  final Size paper;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: page.ink.documentRevisionListenable,
      builder: (BuildContext context, Widget? child) {
        return CustomPaint(
          painter: _PageInkPreviewPainter(
            strokes: List<Stroke>.of(page.ink.strokes),
            paper: paper,
            brightness: Theme.of(context).brightness,
            revision: page.ink.documentRevision,
          ),
        );
      },
    );
  }
}

class _PageInkPreviewPainter extends CustomPainter {
  const _PageInkPreviewPainter({
    required this.strokes,
    required this.paper,
    required this.brightness,
    required this.revision,
  });

  final List<Stroke> strokes;
  final Size paper;
  final Brightness brightness;
  final int revision;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || paper.isEmpty) return;
    final double scale = size.width / paper.width;
    canvas
      ..save()
      ..scale(scale);
    for (final Stroke stroke in strokes) {
      paintInkStroke(
        canvas,
        color: stroke.style.resolve(brightness),
        width: stroke.style.width,
        path: stroke.path,
        origin: stroke.points.first,
        isDot: stroke.isDot,
        outline: stroke.outline,
        writing: stroke.style.writing,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PageInkPreviewPainter oldDelegate) {
    return oldDelegate.paper != paper ||
        oldDelegate.brightness != brightness ||
        oldDelegate.revision != revision;
  }
}
