import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../shared/widgets/etonia_mark.dart';
import '../../editor/document_io/document_models.dart';
import '../../editor/document_io/document_platform.dart';
import '../../editor/ai/canvas_text_recognizer.dart';
import '../../editor/document_io/image_layer.dart';
import '../../editor/ink/ink_controller.dart';
import '../../editor/ink/pen_settings.dart';
import '../../editor/ink/stroke.dart';
import '../../editor/page/note_document.dart';
import '../../editor/page/page_setup.dart';
import '../../editor/widgets/ai_citation_highlight.dart';
import '../note_content.dart';
import '../note_repository.dart';
import '../note_thumbnails.dart';
import 'study_desk_controller.dart';
import 'study_desk_models.dart';
import 'study_in_situ_editor.dart';
import 'study_in_situ_toolbar.dart';
import 'study_view_cache.dart';

/// Whether the inspection pane is showing a page or being written on.
enum _InspectionMode { preview, editing }

/// The Note Inspection Pane: the cited page, with what is cited on it marked as
/// in the editor and brought to the middle of the view. Edit Note turns the
/// pane itself into a place to write, leaving the desk where it is.
class StudyCitationPreview extends StatefulWidget {
  const StudyCitationPreview({
    super.key,
    required this.controller,
    required this.citation,
    required this.onEdit,
    required this.onClose,
    this.pdfRasterizer,
    this.isOpenInEditor,
    this.penSettings,
    this.stylusOnly,
    this.textRecognizer = const PlatformCanvasTextRecognizer(),
    this.enableNativeInk = true,
  });

  final StudyDeskController controller;
  final StudyCitation citation;

  /// Opens the note in the full editor.
  final ValueChanged<StudyCitation> onEdit;
  final VoidCallback onClose;
  final PdfRasterizer? pdfRasterizer;

  /// Whether a note is open in an editor tab. That tab holds the note in memory
  /// and would save over anything written here, so such a note is edited there.
  final bool Function(String noteId)? isOpenInEditor;

  /// The user's pen, which the pen here starts from.
  final ValueListenable<PenSettings>? penSettings;
  final ValueListenable<bool>? stylusOnly;

  /// Reads what is written here into the note's search index.
  final CanvasTextRecognizer? textRecognizer;
  final bool enableNativeInk;

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
  GlobalKey<_CitedPageState> _pageKey = GlobalKey<_CitedPageState>();
  (String, int)? _shownPage;
  StudyCitation? _shownCitation;

  Future<StudyPageView?>? _page;
  int _epoch = -1;
  StudyCitation? _for;

  _InspectionMode _mode = _InspectionMode.preview;

  /// What is being written on. While writing, the pane stays on it whatever the
  /// chat goes on to focus: the page moving away would take the pen with it.
  StudyCitation? _pinned;
  bool _saving = false;

  StudyCitation get _citation => _pinned ?? widget.citation;

  void _readPage() {
    if (_mode == _InspectionMode.editing) return;
    final StudyDeskController controller = widget.controller;
    if (_for?.noteId == widget.citation.noteId &&
        _for?.pageIndex == widget.citation.pageIndex &&
        _epoch == controller.pagesEpoch) {
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
    if (_mode == _InspectionMode.preview &&
        _epoch != widget.controller.pagesEpoch &&
        mounted) {
      setState(_readPage);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _startEditing() {
    final StudyCitation citation = widget.citation;
    // An editor tab would save over what was written here.
    if (widget.isOpenInEditor?.call(citation.noteId) ?? false) {
      widget.onEdit(citation);
      return;
    }
    setState(() {
      _pinned = citation;
      _mode = _InspectionMode.editing;
    });
  }

  void _stopEditing() {
    _pinned = null;
    _mode = _InspectionMode.preview;
    _readPage();
  }

  Future<void> _finishEditing({required bool revert}) async {
    final _CitedPageState? page = _pageKey.currentState;
    if (page == null || _saving) return;
    setState(() => _saving = true);
    try {
      await (revert ? page.revert() : page.commit());
      if (mounted) setState(_stopEditing);
    } on Object {
      // Still in hand, and the pen stays down: nothing has been lost.
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('This page could not be saved.')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final StudyCitation citation = _citation;
    final bool editing = _mode == _InspectionMode.editing;
    return ColoredBox(
      key: const ValueKey<String>('study-inspection-pane'),
      color: colors.surface,
      child: FutureBuilder<StudyPageView?>(
        // Kept as it was while the next is read, so nothing flashes.
        future: _page,
        builder: (BuildContext context, AsyncSnapshot<StudyPageView?> snap) {
          final StudyPageView? view = snap.data;
          // The same page read again stays in sight until it has been.
          final bool samePage =
              view != null &&
              view.note.id == citation.noteId &&
              view.pageIndex == citation.pageIndex;
          final bool reading = snap.connectionState != ConnectionState.done;
          if (view != null) {
            final identity = (view.note.id, view.pageIndex);
            if (_shownPage != identity) {
              _shownPage = identity;
              _pageKey = GlobalKey<_CitedPageState>();
            }
            if (samePage) _shownCitation = citation;
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _Header(
                view: view,
                citation: citation,
                title: widget.controller.noteOf(citation.noteId)?.title,
                mode: _mode,
                saving: _saving,
                // Not while reading: what is in sight may be about to change,
                // and would be saved over what it changed to.
                onEdit: view == null || reading ? null : _startEditing,
                onOpenInEditor: view == null
                    ? null
                    : () => widget.onEdit(citation),
                onDone: () => unawaited(_finishEditing(revert: false)),
                onRevert: () => unawaited(_finishEditing(revert: true)),
                onClose: widget.onClose,
              ),
              Divider(height: AppSizes.hairline, color: colors.divider),
              Expanded(
                child: AnimatedSwitcher(
                  duration: AppMotion.resolve(context, AppMotion.fadeIn),
                  switchInCurve: AppMotion.fadeInCurve,
                  switchOutCurve: AppMotion.fadeOutCurve,
                  child: reading && view == null
                      ? const Center(child: EtoniaBarsLoader(size: 32))
                      : view == null
                      ? const _PageGone()
                      : _CitedPage(
                          key: _pageKey,
                          view: view,
                          citation: samePage
                              ? citation
                              : _shownCitation ?? citation,
                          controller: widget.controller,
                          pdfRasterizer: widget.pdfRasterizer,
                          editing: editing,
                          penSettings: widget.penSettings,
                          stylusOnly: widget.stylusOnly,
                          textRecognizer: widget.textRecognizer,
                          enableNativeInk: widget.enableNativeInk,
                        ),
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
    required this.mode,
    required this.saving,
    required this.onEdit,
    required this.onOpenInEditor,
    required this.onDone,
    required this.onRevert,
    required this.onClose,
  });

  final StudyPageView? view;
  final StudyCitation citation;
  final String? title;
  final _InspectionMode mode;
  final bool saving;
  final VoidCallback? onEdit;
  final VoidCallback? onOpenInEditor;
  final VoidCallback onDone;
  final VoidCallback onRevert;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final StudyPageView? view = this.view;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: AppSpacing.xs,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact =
              constraints.maxWidth < 440 ||
              MediaQuery.textScalerOf(context).scale(17) > 24;
          final actions = Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: AppSpacing.xxs,
            runSpacing: AppSpacing.xxs,
            children: [
              if (mode == _InspectionMode.preview) ...[
                IconButton(
                  key: const ValueKey<String>('study-open-in-editor'),
                  tooltip: 'Open in Editor',
                  onPressed: onOpenInEditor,
                  icon: Icon(AppIcons.fullscreen, color: colors.textSecondary),
                ),
                OutlinedButton.icon(
                  key: const ValueKey<String>('study-edit-note'),
                  onPressed: onEdit,
                  icon: const Icon(AppIcons.pen, size: 18),
                  label: const Text('Edit Note'),
                ),
              ] else ...[
                TextButton(
                  key: const ValueKey<String>('study-edit-revert'),
                  onPressed: saving ? null : onRevert,
                  child: const Text('Revert'),
                ),
                FilledButton.icon(
                  key: const ValueKey<String>('study-edit-done'),
                  onPressed: saving ? null : onDone,
                  icon: const Icon(AppIcons.check, size: 18),
                  label: const Text('Done'),
                ),
              ],
            ],
          );
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton(
                    key: const ValueKey<String>('study-inspection-close'),
                    tooltip: 'Back to the chat',
                    onPressed: saving ? null : onClose,
                    icon: Icon(AppIcons.close, color: colors.textSecondary),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Semantics(
                          header: true,
                          child: Text(
                            view?.note.title ?? title ?? 'Note',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.titleSmall,
                          ),
                        ),
                        Text(
                          view == null
                              ? 'Page ${citation.pageIndex + 1}'
                              : 'Page ${view.pageIndex + 1} of ${view.pageCount}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!compact) ...[
                    const SizedBox(width: AppSpacing.xs),
                    actions,
                  ],
                ],
              ),
              if (compact)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: actions,
                ),
            ],
          );
        },
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
/// time what is cited changes. While [editing], it is written on.
class _CitedPage extends StatefulWidget {
  const _CitedPage({
    super.key,
    required this.view,
    required this.citation,
    required this.controller,
    required this.editing,
    this.pdfRasterizer,
    this.penSettings,
    this.stylusOnly,
    this.textRecognizer,
    this.enableNativeInk = true,
  });

  final StudyPageView view;
  final StudyCitation citation;
  final StudyDeskController controller;
  final bool editing;
  final PdfRasterizer? pdfRasterizer;
  final ValueListenable<PenSettings>? penSettings;
  final ValueListenable<bool>? stylusOnly;
  final CanvasTextRecognizer? textRecognizer;
  final bool enableNativeInk;

  @override
  State<_CitedPage> createState() => _CitedPageState();
}

class _CitedPageState extends State<_CitedPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
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
  List<Rect> _highlights = const <Rect>[];

  Uint8List? _pdf;

  // --- Writing on the page ---------------------------------------------------

  final GlobalKey<StudyInSituGesturesState> _gesturesKey =
      GlobalKey<StudyInSituGesturesState>();
  final GlobalKey _viewportKey = GlobalKey();
  final GlobalKey _toolbarKey = GlobalKey();
  final ValueNotifier<Rect> _visible = ValueNotifier<Rect>(Rect.zero);
  StudyInSituSession? _session;

  /// Whether the page as written so far has been saved, as when the app was
  /// put away: Revert then has something to take back.
  bool _flushed = false;

  void _onMove() {
    final Matrix4Tween? tween = _tween;
    if (tween == null) return;
    _transform.value = tween.transform(
      Curves.easeInOutCubic.transform(_move.value),
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
    _rings = <Rect>[
      for (final Rect r in citation.ringsOn(stored)) r.shift(_shift),
    ];
    _highlights = <Rect>[
      for (final Rect r in citation.highlights) r.shift(_shift),
    ];
  }

  void _readView() {
    final StoredPage stored = widget.view.page;
    _page = stored.framed();
    _shift = stored.isBoard
        ? -InfiniteBoard.frameOf(stored.contentBounds).topLeft
        : Offset.zero;
    _document = NoteContent(<StoredPage>[_page]).toDocument();
    _resolveMarks();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _transform.addListener(_updateVisible);
    _readView();
    if (widget.editing) _beginSession();
    unawaited(_readPdf());
  }

  @override
  void didUpdateWidget(_CitedPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool samePage =
        oldWidget.view.note.id == widget.view.note.id &&
        oldWidget.view.pageIndex == widget.view.pageIndex;
    if (!identical(oldWidget.view.page, widget.view.page) && !widget.editing) {
      // The page read again: what is on it may have changed, and the view stays
      // where the reader left it.
      _endSession();
      _document.dispose();
      _readView();
      if (!samePage) {
        _pdf = null;
        _framed = null;
        unawaited(_readPdf());
      }
    } else if (!identical(oldWidget.citation, widget.citation)) {
      _resolveMarks();
    }
    if (widget.editing && _session == null) {
      _beginSession();
    } else if (!widget.editing && _session != null) {
      _endSession();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) && _move.isAnimating) {
      _move.stop();
      final target = _tween?.end;
      if (target != null) _transform.value = target.clone();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Leaving the pane by any way but Revert keeps what was written.
    if (_session != null) unawaited(_flush());
    _endSession();
    _transform.removeListener(_updateVisible);
    _visible.dispose();
    _move.dispose();
    _transform.dispose();
    _document.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The system may not bring the app back.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (_session != null) unawaited(_flush());
    }
  }

  void _beginSession() {
    _flushed = false;
    _move.stop();
    _session = StudyInSituSession(
      document: _document,
      pen: widget.penSettings?.value,
      recognizer: widget.textRecognizer,
    );
    _session!.ink.documentRevisionListenable.addListener(_onInkChanged);
    _updateVisible();
  }

  void _endSession() {
    final StudyInSituSession? session = _session;
    if (session == null) return;
    session.ink.documentRevisionListenable.removeListener(_onInkChanged);
    session.dispose();
    _session = null;
  }

  /// Marks on strokes since erased go with them.
  void _onInkChanged() {
    if (!mounted) return;
    final Set<Stroke> present = Set<Stroke>.identity()
      ..addAll(_document.current.ink.strokes);
    final List<Stroke> remaining = _strokes.where(present.contains).toList();
    if (remaining.length != _strokes.length) {
      setState(() => _strokes = remaining);
    }
  }

  /// The page as it is written now, where it belongs in the note.
  StoredPage _writtenPage() {
    final StoredPage written = NoteContent.fromDocument(_document).pages.first;
    return _shift == Offset.zero
        ? written
        : written.translated(-_shift, extent: widget.view.page.extent);
  }

  /// Saves without leaving the page.
  Future<void> _flush() async {
    final StudyInSituSession? session = _session;
    if (session == null || !session.isDirty) return;
    session.ink.finalizeActiveGesture();
    _flushed = true;
    try {
      await widget.controller.savePage(
        widget.view.note.id,
        widget.view.pageIndex,
        _writtenPage(),
      );
    } on Object catch (error) {
      debugPrint('Could not save the page: ${error.runtimeType}');
    }
  }

  /// Saves what was written. It stays in sight, as read again in the background.
  /// Throws when it cannot be saved, and the page stays as it is.
  Future<void> commit() async {
    final StudyInSituSession? session = _session;
    if (session == null) return;
    await session.settle();
    if (!mounted || !session.isDirty) return;
    await widget.controller.savePage(
      widget.view.note.id,
      widget.view.pageIndex,
      _writtenPage(),
    );
    if (!mounted) return;
    // What the picture of the page paints from.
    setState(() => _page = NoteContent.fromDocument(_document).pages.first);
  }

  /// Puts the page back as it was before writing began.
  Future<void> revert() async {
    final StudyInSituSession? session = _session;
    if (session == null) return;
    session.ink.finalizeActiveGesture();
    if (_flushed) {
      await widget.controller.savePage(
        widget.view.note.id,
        widget.view.pageIndex,
        widget.view.page,
      );
    }
    if (!mounted) return;
    _endSession();
    setState(() {
      _document.dispose();
      _readView();
    });
  }

  void _updateVisible() {
    final Size? view = _viewSize;
    if (view == null || _session == null) return;
    final Rect shown = MatrixUtils.inverseTransformRect(
      _transform.value,
      Offset.zero & view,
    );
    _visible.value = shown;
  }

  /// Where the pen is not to be taken for writing on the page, in the window's
  /// coordinates: outside this view, and on the toolbar over it.
  List<Rect> _nativeExclusions() {
    final RenderObject? viewport = _viewportKey.currentContext
        ?.findRenderObject();
    if (viewport is! RenderBox || !viewport.attached) {
      return const <Rect>[];
    }
    final Rect view = viewport.localToGlobal(Offset.zero) & viewport.size;
    const double far = 1e6;
    final RenderObject? toolbar = _toolbarKey.currentContext
        ?.findRenderObject();
    return <Rect>[
      Rect.fromLTRB(-far, -far, far, view.top),
      Rect.fromLTRB(-far, view.bottom, far, far),
      Rect.fromLTRB(-far, view.top, view.left, view.bottom),
      Rect.fromLTRB(view.right, view.top, far, view.bottom),
      if (toolbar is RenderBox && toolbar.attached)
        toolbar.localToGlobal(Offset.zero) & toolbar.size,
    ];
  }

  /// What this note's page is made from is kept (see [StudyViewCache]), so
  /// coming back to a page, or to a note's picture, shows it at once; only the
  /// first time is read and drawn, and the page is on screen without its paper
  /// until then (the paper fades in over it).
  Object _cacheKey(Object part) => (
    identityHashCode(widget.controller.repository),
    widget.view.note.id,
    part,
  );

  Future<void> _readPdf() async {
    final PdfPageSource? source = _page.pdfSource;
    final PdfRasterizer? rasterizer = widget.pdfRasterizer;
    if (source == null || rasterizer == null) return;
    const int width = 1400;
    final Object key = _cacheKey(('pdf', source.assetId, source.pageIndex));
    final Uint8List? kept = StudyViewCache.pdfPages.peek(key);
    if (kept != null) {
      _pdf = kept;
      return;
    }
    final String noteId = widget.view.note.id;
    final Uint8List? png = await StudyViewCache.pdfPages.load(key, () async {
      final NoteAssetData asset = await widget.controller.repository.readAsset(
        noteId,
        source.assetId,
      );
      final RasterizedPdfPage page = await rasterizer.render(
        asset.bytes,
        source.pageIndex,
        pixelWidth: width,
        pixelHeight: math.max(
          1,
          (width * source.pageSize.height / source.pageSize.width).round(),
        ),
      );
      return page.png;
    });
    if (png != null && mounted && _page.pdfSource?.assetId == source.assetId) {
      setState(() => _pdf = png);
    }
  }

  Future<Uint8List?> _readAsset(String assetId) {
    final String noteId = widget.view.note.id;
    return StudyViewCache.assets.load(_cacheKey(('asset', assetId)), () async {
      final NoteAssetData asset = await widget.controller.repository.readAsset(
        noteId,
        assetId,
      );
      return asset.bytes;
    });
  }

  /// The union of what is marked.
  Rect? get _marked {
    Rect? bounds;
    void include(Rect rect) => bounds = bounds?.expandToInclude(rect) ?? rect;
    for (final Stroke stroke in _strokes) {
      include(stroke.bounds);
    }
    _rings.map(aiCitationRing).forEach(include);
    _highlights.forEach(include);
    final region = widget.citation.bounds;
    if (bounds == null && region != null) {
      include(region.shift(_shift));
    }
    return _framing(bounds);
  }

  /// What to bring into view for [marked], all that is marked. A paragraph that
  /// cites two places on a page marks both, but the view goes to the one it
  /// is about, unless both are near enough to be shown together.
  Rect? _framing(Rect? marked) {
    final Rect? focus = widget.citation.focus?.shift(_shift);
    if (marked == null || focus == null || focus.isEmpty) return marked;
    final double all = marked.width * marked.height;
    final double one = focus.width * focus.height;
    return all > one * 4 ? focus : marked;
  }

  /// Moves to what is cited, once the view's size is known, and each time the
  /// citation or the view's size changes. The first is put there at once.
  void _frame(Size pageSize, Size viewSize) {
    final citation = widget.citation;
    if (identical(_framed, widget.citation) && _viewSize == viewSize) return;
    final bool first = _framed == null;
    final bool citationChanged = !identical(_framed, widget.citation);
    _framed = widget.citation;
    _viewSize = viewSize;
    // Writing, the page stays under the pen: only the citation moves it.
    if (!citationChanged && _session != null) return;
    final Matrix4 target = StudyCitationPreview.focusOn(
      page: pageSize,
      view: viewSize,
      marked: _marked,
    );
    if (first || MediaQuery.disableAnimationsOf(context)) {
      _move.stop();
      _transform.value = target;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted || !identical(_framed, citation) || _viewSize != viewSize) {
        return;
      }
      _tween = Matrix4Tween(begin: _transform.value.clone(), end: target);
      _move
        ..duration = AppMotion.resolve(
          context,
          const Duration(milliseconds: 300),
        )
        ..forward(from: 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final Brightness brightness = Theme.of(context).brightness;
    final Size pageSize = NoteThumbnailPainter.pageSizeOf(_page);
    final InkController ink = _document.current.ink;
    final StudyInSituSession? session = _session;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _frame(pageSize, constraints.biggest);
        final Widget viewer = InteractiveViewer(
          transformationController: _transform,
          constrained: false,
          minScale: 0.1,
          maxScale: 8,
          boundaryMargin: const EdgeInsets.all(double.infinity),
          // Writing, a finger on the page is the pen's until a second arrives.
          panEnabled: session == null,
          scaleEnabled: session == null,
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
                  Image.memory(
                    pdf,
                    fit: BoxFit.fill,
                    gaplessPlayback: true,
                    // Not there, then there: the paper fades in once it has
                    // been decoded, instead of the page jumping.
                    frameBuilder: (context, child, frame, sync) => sync
                        ? child
                        : AnimatedOpacity(
                            opacity: frame == null ? 0 : 1,
                            duration: AppMotion.resolve(
                              context,
                              AppMotion.fadeIn,
                            ),
                            curve: AppMotion.fadeInCurve,
                            child: child,
                          ),
                  ),
                if (_page.images.isNotEmpty)
                  PageImageLayer(controller: ink, readAsset: _readAsset),
                AiCitationMarks(
                  strokes: _strokes,
                  circles: _rings,
                  highlights: _highlights,
                ),
                if (session == null)
                  CustomPaint(
                    painter: NoteThumbnailPainter(
                      page: _page,
                      brightness: brightness,
                      rule: colors.pageRule,
                      marginRule: colors.pageMarginRule,
                      paintBackground: false,
                    ),
                  )
                else
                  StudyInSituCanvas(
                    session: session,
                    isNavigating: () =>
                        _gesturesKey.currentState?.isMoving ?? false,
                    stylusOnly: widget.stylusOnly,
                    visible: _visible,
                    exclusionRects: _nativeExclusions,
                    enableNativeInk: widget.enableNativeInk,
                  ),
              ],
            ),
          ),
        );
        return ClipRect(
          key: _viewportKey,
          child: ColoredBox(
            color: colors.background,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Semantics(
                  label: session != null
                      ? null
                      : 'Page ${widget.view.pageIndex + 1} of '
                            '${widget.view.note.title}, with the cited part '
                            'marked',
                  image: session == null,
                  child: StudyInSituGestures(
                    key: _gesturesKey,
                    transform: _transform,
                    session: session,
                    stylusOnly: widget.stylusOnly,
                    enableNativeInk: widget.enableNativeInk,
                    onMoveStart: _move.stop,
                    child: viewer,
                  ),
                ),
                if (session != null)
                  Positioned(
                    left: AppSpacing.xs,
                    right: AppSpacing.xs,
                    bottom: AppSpacing.sm,
                    child: Center(
                      child: StudyInSituToolbar(
                        key: _toolbarKey,
                        session: session,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
