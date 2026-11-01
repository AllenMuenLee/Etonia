import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import '../document_io/document_models.dart';
import '../document_io/document_platform.dart';
import '../page/note_document.dart';

/// Reads the outline of the PDF asset it is given.
typedef PdfOutlineLoader =
    Future<List<PdfOutlineEntry>> Function(String assetId);

/// A chapter of a note: an entry of the outline of a PDF in it, at the note
/// page that entry opens.
@immutable
class NoteChapter {
  const NoteChapter({
    required this.id,
    required this.title,
    required this.pageIndex,
    this.children = const <NoteChapter>[],
  });

  /// Where the entry is in its PDF's outline, stable while the note's pages
  /// change around it.
  final String id;
  final String title;

  /// The note page it opens, from zero.
  final int pageIndex;
  final List<NoteChapter> children;
}

/// The chapters of [pages], from [outlines]: the outline of each PDF asset
/// in them, in the order the note first shows each PDF.
///
/// An entry opens the first note page showing its PDF page. One whose page
/// was deleted from the note, or that points nowhere, opens where its first
/// remaining section does; with none left it is dropped.
List<NoteChapter> noteChapters(
  List<NotePage> pages,
  Map<String, List<PdfOutlineEntry>> outlines,
) {
  final Map<String, int> notePageOf = <String, int>{};
  final List<String> assets = <String>[];
  for (int i = 0; i < pages.length; i++) {
    final PdfPageSource? pdf = pages[i].pdfSource;
    if (pdf == null) continue;
    if (!notePageOf.containsKey(pdf.assetId)) assets.add(pdf.assetId);
    notePageOf.putIfAbsent('${pdf.assetId}:${pdf.pageIndex}', () => i);
    notePageOf.putIfAbsent(pdf.assetId, () => i);
  }

  List<NoteChapter> resolve(
    String assetId,
    String path,
    List<PdfOutlineEntry> entries,
  ) {
    final List<NoteChapter> chapters = <NoteChapter>[];
    for (int i = 0; i < entries.length; i++) {
      final PdfOutlineEntry entry = entries[i];
      final String id = '$path.$i';
      final List<NoteChapter> children = resolve(assetId, id, entry.children);
      final int? page = entry.pageIndex == null
          ? null
          : notePageOf['$assetId:${entry.pageIndex}'];
      final int? opens = page ?? children.firstOrNull?.pageIndex;
      if (opens == null) continue;
      chapters.add(
        NoteChapter(
          id: id,
          title: entry.title.isEmpty ? 'Untitled' : entry.title,
          pageIndex: opens,
          children: children,
        ),
      );
    }
    return chapters;
  }

  return <NoteChapter>[
    for (final String assetId in assets)
      ...resolve(
        assetId,
        assetId,
        outlines[assetId] ?? const <PdfOutlineEntry>[],
      ),
  ];
}

/// The chapters at the current page of a note: the last one opening at or
/// before it, and every chapter holding that one, outermost first. Empty
/// before the first chapter.
List<NoteChapter> chapterPathAt(List<NoteChapter> chapters, int pageIndex) {
  List<NoteChapter> best = const <NoteChapter>[];
  void visit(List<NoteChapter> level, List<NoteChapter> above) {
    for (final NoteChapter chapter in level) {
      final List<NoteChapter> path = <NoteChapter>[...above, chapter];
      // Later entries win ties: a section starting on its chapter's first
      // page is nearer than the chapter.
      if (chapter.pageIndex <= pageIndex &&
          (best.isEmpty || chapter.pageIndex >= best.last.pageIndex)) {
        best = path;
      }
      visit(chapter.children, path);
    }
  }

  visit(chapters, const <NoteChapter>[]);
  return best;
}

/// The chapters of a [document], kept as its pages change: reads the
/// outline of each PDF that comes into it once, with [loadOutline], and
/// notifies when one arrives.
class NoteChapterIndex extends ChangeNotifier {
  NoteChapterIndex({required this.document, required this.loadOutline}) {
    document.addListener(_loadNew);
    _loadNew();
  }

  final NoteDocument document;
  final PdfOutlineLoader loadOutline;

  final Map<String, List<PdfOutlineEntry>> _outlines =
      <String, List<PdfOutlineEntry>>{};
  final Set<String> _asked = <String>{};
  bool _disposed = false;

  List<NoteChapter>? _chapters;
  int _chaptersRevision = -1;

  /// Empty until an outline arrives, and for a note without one.
  List<NoteChapter> get chapters {
    if (_chapters == null || _chaptersRevision != document.structureRevision) {
      _chapters = noteChapters(document.pages, _outlines);
      _chaptersRevision = document.structureRevision;
    }
    return _chapters!;
  }

  void _loadNew() {
    for (final NotePage page in document.pages) {
      final String? assetId = page.pdfSource?.assetId;
      if (assetId == null || !_asked.add(assetId)) continue;
      loadOutline(assetId).then<void>((List<PdfOutlineEntry> outline) {
        if (_disposed || outline.isEmpty) return;
        _outlines[assetId] = outline;
        _chapters = null;
        notifyListeners();
      }, onError: (Object _) {});
    }
  }

  @override
  void dispose() {
    _disposed = true;
    document.removeListener(_loadNew);
    super.dispose();
  }
}

/// A note's [chapters] as an outline, sections indented under the chapter
/// holding them, each with the page it opens. Selecting one goes to its
/// page and calls [onSelected]. The chapter at the current page is marked,
/// and the chapters holding it start open.
class PageChapterList extends StatefulWidget {
  const PageChapterList({
    super.key,
    required this.document,
    required this.chapters,
    this.onSelected,
  });

  final NoteDocument document;
  final List<NoteChapter> chapters;
  final VoidCallback? onSelected;

  @override
  State<PageChapterList> createState() => _PageChapterListState();
}

class _PageChapterListState extends State<PageChapterList> {
  late final Set<String> _open = <String>{
    for (final NoteChapter chapter in chapterPathAt(
      widget.chapters,
      widget.document.currentIndex,
    ))
      chapter.id,
  };

  void _toggle(NoteChapter chapter) {
    setState(() {
      if (!_open.remove(chapter.id)) _open.add(chapter.id);
    });
  }

  void _select(NoteChapter chapter) {
    widget.document.goTo(chapter.pageIndex);
    widget.onSelected?.call();
  }

  @override
  Widget build(BuildContext context) {
    final List<NoteChapter> path = chapterPathAt(
      widget.chapters,
      widget.document.currentIndex,
    );
    final String? current = path.lastOrNull?.id;
    final List<(NoteChapter, int)> rows = <(NoteChapter, int)>[];
    void add(List<NoteChapter> level, int depth) {
      for (final NoteChapter chapter in level) {
        rows.add((chapter, depth));
        if (_open.contains(chapter.id)) add(chapter.children, depth + 1);
      }
    }

    add(widget.chapters, 0);
    return ListView.builder(
      key: const ValueKey<String>('page-overview-chapters'),
      shrinkWrap: true,
      padding: const EdgeInsetsDirectional.only(end: AppSpacing.xs),
      itemCount: rows.length,
      itemBuilder: (BuildContext context, int index) {
        final (NoteChapter chapter, int depth) = rows[index];
        return _ChapterRow(
          chapter: chapter,
          depth: depth,
          selected: chapter.id == current,
          open: _open.contains(chapter.id),
          onTap: () => _select(chapter),
          onToggle: chapter.children.isEmpty ? null : () => _toggle(chapter),
        );
      },
    );
  }
}

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    required this.chapter,
    required this.depth,
    required this.selected,
    required this.open,
    required this.onTap,
    required this.onToggle,
  });

  final NoteChapter chapter;
  final int depth;
  final bool selected;
  final bool open;
  final VoidCallback onTap;
  final VoidCallback? onToggle;

  static const double _toggleWidth = 32;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final Color foreground = selected ? colors.accent : colors.textPrimary;
    final VoidCallback? onToggle = this.onToggle;
    return Semantics(
      selected: selected,
      child: InkWell(
        key: ValueKey<String>('page-chapter-${chapter.id}'),
        onTap: onTap,
        borderRadius: AppBorderRadius.medium,
        child: AnimatedContainer(
          duration: AppMotion.resolve(context, AppMotion.snappy.duration),
          constraints: const BoxConstraints(minHeight: AppSizes.minTouchTarget),
          padding: EdgeInsetsDirectional.only(
            start: depth * AppSpacing.md,
            end: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: selected ? colors.selected : null,
            borderRadius: AppBorderRadius.medium,
          ),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: _toggleWidth,
                height: AppSizes.minTouchTarget,
                child: onToggle == null
                    ? null
                    : Semantics(
                        container: true,
                        button: true,
                        excludeSemantics: true,
                        label: open ? 'Collapse sections' : 'Expand sections',
                        onTap: onToggle,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: onToggle,
                          child: AnimatedRotation(
                            turns: open ? 0.25 : 0,
                            duration: AppMotion.resolve(
                              context,
                              AppMotion.snappy.duration,
                            ),
                            child: Icon(
                              AppIcons.disclosure,
                              size: 14,
                              color: colors.textSecondary,
                            ),
                          ),
                        ),
                      ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                  child: Text(
                    chapter.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: (depth == 0 ? text.bodyMedium : text.bodySmall)
                        ?.copyWith(color: foreground),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Semantics(
                label: 'page ${chapter.pageIndex + 1}',
                excludeSemantics: true,
                child: Text(
                  '${chapter.pageIndex + 1}',
                  style: text.labelMedium?.copyWith(
                    color: selected ? colors.accent : colors.textSecondary,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
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
