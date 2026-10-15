import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../document_io/document_models.dart';
import '../page/note_document.dart';
import '../page/page_background.dart';
import '../page/page_setup.dart';

/// The page indicator, `current / count`, which opens the page panel, and
/// on wider layouts previous, next, and add-page buttons beside it.
class PageControls extends StatelessWidget {
  const PageControls({
    super.key,
    required this.document,
    required this.showNavigation,
    required this.onOpenPanel,
  });

  final NoteDocument document;

  /// Whether previous, next, and add-page sit in the bar. Without them they
  /// are only in the panel.
  final bool showNavigation;

  final VoidCallback onOpenPanel;

  static String describe(int index, int count) {
    return 'Page ${index + 1} of $count';
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return ListenableBuilder(
      listenable: document,
      builder: (BuildContext context, Widget? child) {
        final int index = document.currentIndex;
        final int count = document.pageCount;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (showNavigation)
              IconButton(
                tooltip: 'Previous page',
                onPressed: document.canGoBack ? document.previousPage : null,
                icon: const Icon(Icons.chevron_left),
              ),
            Tooltip(
              message: 'Page setup',
              excludeFromSemantics: true,
              child: TextButton(
                onPressed: onOpenPanel,
                style: TextButton.styleFrom(
                  foregroundColor: colors.textPrimary,
                  minimumSize: const Size(
                    AppSizes.minTouchTarget,
                    AppSizes.minTouchTarget,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xs,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadii.medium),
                  ),
                ),
                child: Text(
                  '${index + 1} / $count',
                  semanticsLabel: describe(index, count),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            ),
            if (showNavigation) ...<Widget>[
              IconButton(
                tooltip: 'Next page',
                onPressed: document.canGoForward ? document.nextPage : null,
                icon: const Icon(Icons.chevron_right),
              ),
              IconButton(
                tooltip: 'Add page',
                onPressed: document.addPage,
                icon: const Icon(Icons.add),
              ),
            ],
          ],
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
    transitionDuration: AppMotion.resolve(context, AppMotion.fast),
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
            curve: AppMotion.standard,
          );
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
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
      final bool? confirmed = await showDialog<bool>(
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
              TextButton(
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
    final BorderRadius radius = BorderRadius.circular(AppRadii.large);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: AppShadows.floating(colors),
      ),
      child: Material(
        color: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: colors.divider, width: AppSizes.hairline),
        ),
        clipBehavior: Clip.antiAlias,
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
                          style: text.titleMedium,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Previous page',
                      onPressed: document.canGoBack
                          ? document.previousPage
                          : null,
                      icon: const Icon(Icons.chevron_left),
                    ),
                    IconButton(
                      tooltip: 'Next page',
                      onPressed: document.canGoForward
                          ? document.nextPage
                          : null,
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm,
                          ),
                        ),
                        onPressed: document.addPage,
                        icon: const Icon(Icons.add),
                        label: const Text('Add page'),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm,
                          ),
                        ),
                        onPressed: document.pageCount > 1
                            ? () => _delete(context)
                            : null,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Delete page'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Center(
                  child: PagePreview(
                    key: const ValueKey<String>('page-preview'),
                    paper: _paperFor(setup.size, setup),
                    background: setup.background,
                    config: config,
                    infinite: !pdf && setup.size == PageSize.infinite,
                    maxSize: const Size(
                      PagePanel.width - 2 * AppSpacing.md,
                      160,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                _PanelDropdown<PageSize>(
                  key: const ValueKey<String>('page-size-dropdown'),
                  label: 'Size',
                  helper: pdf
                      ? 'The size of an imported PDF page is fixed.'
                      : null,
                  value: setup.size,
                  onChanged: pdf
                      ? null
                      : (PageSize size) {
                          document.setSetup(setup.copyWith(size: size));
                        },
                  options: <PageSize>[
                    for (final PageSize size in PageSize.values)
                      if (size != PageSize.custom ||
                          setup.size == PageSize.custom)
                        size,
                  ],
                  labelOf: (PageSize size) => size.label,
                  thumbnailOf: (PageSize size) => _SizeThumbnail(
                    paper: _paperFor(size, setup),
                    icon: switch (size) {
                      PageSize.fit => Icons.fit_screen_outlined,
                      PageSize.infinite => Icons.all_inclusive,
                      _ => null,
                    },
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
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
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 2,
        enabled: onChanged != null,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.medium),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.medium),
          borderSide: BorderSide(color: colors.divider),
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          isDense: true,
          itemHeight: null,
          borderRadius: BorderRadius.circular(AppRadii.medium),
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
          border: Border.all(color: colors.textSecondary, width: 1.5),
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
                        Icons.open_in_full,
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
