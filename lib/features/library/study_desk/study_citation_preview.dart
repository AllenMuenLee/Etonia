import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../shared/widgets/etonia_mark.dart';
import '../../editor/document_io/document_models.dart';
import '../../editor/document_io/document_platform.dart';
import '../../editor/document_io/image_layer.dart';
import '../../editor/ink/ink_controller.dart';
import '../../editor/ink/stroke.dart';
import '../../editor/page/note_document.dart';
import '../../editor/page/page_setup.dart';
import '../../editor/widgets/ai_citation_highlight.dart';
import '../note_content.dart';
import '../note_repository.dart';
import '../note_thumbnails.dart';
import 'study_desk_controller.dart';
import 'study_desk_models.dart';

/// The Note Inspection Pane: the cited page, read-only, with what is cited on it
/// marked as in the editor and brought to the middle of the view, and the way
/// to edit the note.
class StudyCitationPreview extends StatefulWidget {
  const StudyCitationPreview({
    super.key,
    required this.controller,
    required this.citation,
    required this.onEdit,
    required this.onClose,
    this.pdfRasterizer,
  });

  final StudyDeskController controller;
  final StudyCitation citation;
  final ValueChanged<StudyCitation> onEdit;
  final VoidCallback onClose;
  final PdfRasterizer? pdfRasterizer;

  /// Left around what is cited, on each side.
  static const double margin = 24;

  /// However small what is cited, it comes no nearer than this.
  static const double maxScale = 3;

  /// Where to view a page of [page] size so that [marked] is in the middle of
  /// [view], [margin] clear of its edges. With nothing marked, the whole page's
  /// width shows from its top.
  static Matrix4 focusOn({
    required Size page,
    required Size view,
    required Rect? marked,
  }) {
    final double fitWidth = view.width / page.width;
    if (marked == null || marked.isEmpty) {
      return Matrix4.diagonal3Values(fitWidth, fitWidth, 1);
    }
    final double fitPage = math.min(fitWidth, view.height / page.height);
    final double scale = math
        .min(
          (view.width - margin * 2) / marked.width,
          (view.height - margin * 2) / marked.height,
        )
        .clamp(fitPage, math.max(fitPage, maxScale));
    return Matrix4.diagonal3Values(scale, scale, 1)..setTranslationRaw(
      view.width / 2 - marked.center.dx * scale,
      view.height / 2 - marked.center.dy * scale,
      0,
    );
  }

  @override
  State<StudyCitationPreview> createState() => _StudyCitationPreviewState();
}

class _StudyCitationPreviewState extends State<StudyCitationPreview> {
  Future<StudyPageView?>? _page;
  int _epoch = -1;
  StudyCitation? _for;

  void _readPage() {
    final StudyDeskController controller = widget.controller;
    if (identical(_for, widget.citation) && _epoch == controller.pagesEpoch) {
      return;
    }
    _for = widget.citation;
    _epoch = controller.pagesEpoch;
    _page = controller.pageFor(widget.citation);
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
    _readPage();
  }

  @override
  void didUpdateWidget(StudyCitationPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
    }
    _readPage();
  }

  /// An edited note's page reads differently: it is read again.
  void _onChanged() {
    if (_epoch != widget.controller.pagesEpoch && mounted) {
      setState(_readPage);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return ColoredBox(
      key: const ValueKey<String>('study-inspection-pane'),
      color: colors.surface,
      child: FutureBuilder<StudyPageView?>(
        // Kept as it was while the next is read, so nothing flashes.
        future: _page,
        builder: (BuildContext context, AsyncSnapshot<StudyPageView?> snap) {
          final StudyPageView? view = snap.data;
          final bool waiting = snap.connectionState != ConnectionState.done;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _Header(
                view: view,
                citation: widget.citation,
                title: widget.controller.noteOf(widget.citation.noteId)?.title,
                onEdit: view == null
                    ? null
                    : () => widget.onEdit(widget.citation),
                onClose: widget.onClose,
              ),
              Divider(height: AppSizes.hairline, color: colors.divider),
              Expanded(
                child: waiting
                    ? const Center(child: EtoniaBarsLoader(size: 32))
                    : view == null
                    ? const _PageGone()
                    : _CitedPage(
                        key: ValueKey<(String, int, int)>((
                          view.note.id,
                          view.pageIndex,
                          _epoch,
                        )),
                        view: view,
                        citation: widget.citation,
                        repository: widget.controller.repository,
                        pdfRasterizer: widget.pdfRasterizer,
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.view,
    required this.citation,
    required this.title,
    required this.onEdit,
    required this.onClose,
  });

  final StudyPageView? view;
  final StudyCitation citation;
  final String? title;
  final VoidCallback? onEdit;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final StudyPageView? view = this.view;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        AppSpacing.xxs,
        AppSpacing.xxs,
        AppSpacing.sm,
        AppSpacing.xxs,
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            key: const ValueKey<String>('study-inspection-close'),
            tooltip: 'Back to the chat',
            onPressed: onClose,
            icon: Icon(AppIcons.close, color: colors.textSecondary),
          ),
          const SizedBox(width: AppSpacing.xxs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Semantics(
                  header: true,
                  child: Text(
                    view?.note.title ?? title ?? 'Note',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleSmall?.copyWith(color: colors.textPrimary),
                  ),
                ),
                Text(
                  view == null
                      ? 'Page ${citation.pageIndex + 1}'
                      : 'Page ${view.pageIndex + 1} of ${view.pageCount}',
                  maxLines: 1,
                  style: text.bodySmall?.copyWith(color: colors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          FilledButton.tonalIcon(
            key: const ValueKey<String>('study-edit-note'),
            onPressed: onEdit,
            icon: const Icon(AppIcons.pen, size: 18),
            label: const Text('Edit Note'),
          ),
        ],
      ),
    );
  }
}

class _PageGone extends StatelessWidget {
  const _PageGone();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Text(
          'This page is no longer in the note.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: AppColors.of(context).textSecondary,
          ),
        ),
      ),
    );
  }
}

/// The page itself. Can be panned and zoomed by hand, and moves by itself each
/// time what is cited changes.
class _CitedPage extends StatefulWidget {
  const _CitedPage({
    super.key,
    required this.view,
    required this.citation,
    required this.repository,
    this.pdfRasterizer,
  });

  final StudyPageView view;
  final StudyCitation citation;
  final NoteRepository repository;
  final PdfRasterizer? pdfRasterizer;

  @override
  State<_CitedPage> createState() => _CitedPageState();
}

class _CitedPageState extends State<_CitedPage>
    with SingleTickerProviderStateMixin {
  final TransformationController _transform = TransformationController();
  late final AnimationController _move = AnimationController(vsync: this)
    ..addListener(_onMove);
  Matrix4Tween? _tween;
  Size? _viewSize;
  StudyCitation? _framed;

  /// The page cut to its ink, for a whiteboard; and where its ink moved from.
  late StoredPage _page;
  Offset _shift = Offset.zero;
  late NoteDocument _document;

  /// What is cited on the page, in the place it is drawn at here.
  List<Stroke> _strokes = const <Stroke>[];
  List<Rect> _rings = const <Rect>[];

  Uint8List? _pdf;
  final Map<String, Uint8List> _assets = <String, Uint8List>{};

  void _onMove() {
    final Matrix4Tween? tween = _tween;
    if (tween == null) return;
    _transform.value = tween.transform(
      AppMotion.zoomInCurve.transform(_move.value),
    );
  }

  void _resolveMarks() {
    final StudyCitation citation = widget.citation;
    final StoredPage stored = widget.view.page;
    final Set<Stroke> cited = citation
        .strokesOn(stored, widget.view.note.revision)
        .toSet();
    final List<int> indices = <int>[
      for (int i = 0; i < stored.strokes.length; i++)
        if (cited.contains(stored.strokes[i])) i,
    ];
    _strokes = <Stroke>[for (final int i in indices) _page.strokes[i]];
    _rings = <Rect>[for (final Rect r in citation.rings) r.shift(_shift)];
  }

  @override
  void initState() {
    super.initState();
    final StoredPage stored = widget.view.page;
    _page = stored.framed();
    if (stored.isBoard) {
      _shift = -InfiniteBoard.frameOf(stored.contentBounds).topLeft;
    }
    _document = NoteContent(<StoredPage>[_page]).toDocument();
    _resolveMarks();
    unawaited(_readPdf());
  }

  @override
  void didUpdateWidget(_CitedPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.citation, widget.citation)) _resolveMarks();
  }

  @override
  void dispose() {
    _move.dispose();
    _transform.dispose();
    _document.dispose();
    super.dispose();
  }

  Future<void> _readPdf() async {
    final PdfPageSource? source = _page.pdfSource;
    final PdfRasterizer? rasterizer = widget.pdfRasterizer;
    if (source == null || rasterizer == null) return;
    try {
      final NoteAssetData asset = await widget.repository.readAsset(
        widget.view.note.id,
        source.assetId,
      );
      const int width = 1400;
      final RasterizedPdfPage page = await rasterizer.render(
        asset.bytes,
        source.pageIndex,
        pixelWidth: width,
        pixelHeight: math.max(
          1,
          (width * source.pageSize.height / source.pageSize.width).round(),
        ),
      );
      if (mounted) setState(() => _pdf = page.png);
    } on Object {
      // The ink stays readable without its paper.
    }
  }

  Future<Uint8List?> _readAsset(String assetId) async {
    final Uint8List? kept = _assets[assetId];
    if (kept != null) return kept;
    try {
      final NoteAssetData asset = await widget.repository.readAsset(
        widget.view.note.id,
        assetId,
      );
      return _assets[assetId] = asset.bytes;
    } on Object {
      return null;
    }
  }

  /// The union of what is marked.
  Rect? get _marked {
    Rect? bounds;
    void include(Rect rect) => bounds = bounds?.expandToInclude(rect) ?? rect;
    for (final Stroke stroke in _strokes) {
      include(stroke.bounds);
    }
    _rings.map(aiCitationRing).forEach(include);
    return bounds;
  }

  /// Moves to what is cited, once the view's size is known, and each time the
  /// citation or the view's size changes. The first is put there at once.
  void _frame(Size pageSize, Size viewSize) {
    if (identical(_framed, widget.citation) && _viewSize == viewSize) return;
    final bool first = _framed == null;
    _framed = widget.citation;
    _viewSize = viewSize;
    final Matrix4 target = StudyCitationPreview.focusOn(
      page: pageSize,
      view: viewSize,
      marked: _marked,
    );
    if (first) {
      _transform.value = target;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      _tween = Matrix4Tween(begin: _transform.value.clone(), end: target);
      _move
        ..duration = AppMotion.resolve(context, AppMotion.zoom)
        ..forward(from: 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final Brightness brightness = Theme.of(context).brightness;
    final Size pageSize = NoteThumbnailPainter.pageSizeOf(_page);
    final InkController ink = _document.current.ink;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _frame(pageSize, constraints.biggest);
        return ClipRect(
          child: ColoredBox(
            color: colors.background,
            child: Semantics(
              label:
                  'Page ${widget.view.pageIndex + 1} of '
                  '${widget.view.note.title}, with the cited part marked',
              image: true,
              child: InteractiveViewer(
                transformationController: _transform,
                constrained: false,
                minScale: 0.1,
                maxScale: 8,
                boundaryMargin: const EdgeInsets.all(double.infinity),
                onInteractionStart: (_) => _move.stop(),
                child: SizedBox.fromSize(
                  size: pageSize,
                  child: Stack(
                    key: const ValueKey<String>('study-cited-page'),
                    fit: StackFit.expand,
                    children: <Widget>[
                      CustomPaint(
                        painter: NoteThumbnailPainter(
                          page: _page,
                          brightness: brightness,
                          rule: colors.pageRule,
                          marginRule: colors.pageMarginRule,
                          paintInk: false,
                        ),
                        child: ColoredBox(color: colors.writingSurface),
                      ),
                      if (_pdf case final Uint8List pdf)
                        Image.memory(pdf, fit: BoxFit.fill),
                      if (_page.images.isNotEmpty)
                        PageImageLayer(controller: ink, readAsset: _readAsset),
                      AiCitationMarks(strokes: _strokes, circles: _rings),
                      CustomPaint(
                        painter: NoteThumbnailPainter(
                          page: _page,
                          brightness: brightness,
                          rule: colors.pageRule,
                          marginRule: colors.pageMarginRule,
                          paintBackground: false,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
