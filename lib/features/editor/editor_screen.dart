import 'dart:math' as math;
import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import '../../shared/layout/breakpoints.dart';
import '../library/note_content.dart';
import '../library/note_repository.dart';
import 'ai/ai_assistant_controller.dart';
import 'ai/ai_client.dart';
import 'ai/ai_config.dart';
import 'ai/ai_notation.dart';
import 'ai/gemini_ai_client.dart';
import 'ai/ink_attachment.dart';
import 'ai/note_image_renderer.dart';
import 'ai/notation_layout.dart';
import 'ai/selection_image_renderer.dart';
import 'ink/eraser_settings.dart';
import 'ink/ink_canvas.dart';
import 'ink/ink_controller.dart';
import 'ink/ink_notation.dart';
import 'ink/ink_sample.dart';
import 'ink/ink_selection.dart';
import 'ink/notation_playback.dart';
import 'ink/pen_settings.dart';
import 'ink/selection_config.dart';
import 'ink/shape_config.dart';
import 'ink/stroke.dart';
import 'page/note_document.dart';
import 'page/page_background.dart';
import 'page/page_setup.dart';
import 'page/page_viewport.dart';
import 'document_io/image_layer.dart';
import 'document_io/document_io_config.dart';
import 'document_io/document_importer.dart';
import 'document_io/document_models.dart';
import 'document_io/document_platform.dart';
import 'document_io/pdf_page_layer.dart';
import 'document_io/pdf_selection_image.dart';
import 'document_io/pdf_exporter.dart';
import 'widgets/ai_assistant_panel.dart';
import 'widgets/clipboard_shortcuts.dart';
import 'widgets/editor_app_bar.dart';
import 'widgets/editor_settings_sheet.dart';
import 'widgets/export_options_sheet.dart';
import 'widgets/history_controls.dart';
import 'widgets/document_io_progress_dialog.dart';
import 'widgets/page_controls.dart';
import 'widgets/selection_action_bar.dart';
import 'widgets/tool_palette.dart';
import 'widgets/writing_surface_frame.dart';

/// The editor shell: app bar, page, floating tool palette, and the AI
/// assistant panel.
///
/// The selected tool, the pen and eraser settings, the note's pages, each
/// with its ink, and the AI assistant, with its side, conversation, and
/// draft, live in this widget's state, so they survive rotation and
/// breakpoint changes for the session. One page is shown at a time; the
/// selection belongs to it, and the clipboard follows the user between
/// pages.
class EditorScreen extends StatefulWidget {
  const EditorScreen({
    super.key,
    this.document,
    this.inkController,
    this.title = 'Untitled note',
    this.onBack,
    this.onTitlePressed,
    this.penConfig = const PenConfig(),
    this.eraserConfig = const EraserConfig(),
    this.selectionConfig = const SelectionConfig(),
    this.aiClient,
    this.aiApiConfig = const AiApiConfig.fromEnvironment(),
    this.aiLayoutConfig = const AiLayoutConfig(),
    this.selectionImageRenderer = const SelectionImageRenderer(),
    this.noteImageRenderer = const NoteImageRenderer(),
    this.pageConfig = const PageConfig(),
    this.shapeConfig = const ShapeConfig(),
    this.assetReader,
    this.pdfRasterizer = const PdfrxRasterizer(),
    this.documentIoConfig = const DocumentIoConfig(),
    this.repository,
    this.noteId,
    this.documentPicker = const SystemDocumentPicker(),
    this.exportSink = const SystemExportSink(),
    this.onClipboardChanged,
    this.stylusOnly,
    this.initialNotationEnabled = true,
  });

  /// The note's pages, supplied from outside; otherwise the screen owns a
  /// document of one page, around [inkController] when given.
  final NoteDocument? document;

  /// Supplies the first page's ink from outside, when [document] is not
  /// given.
  final InkController? inkController;

  final String title;

  /// Called by the navigation control, to leave the editor.
  final VoidCallback? onBack;

  /// Called by the title, to rename the note.
  final VoidCallback? onTitlePressed;

  final PenConfig penConfig;
  final EraserConfig eraserConfig;

  /// Used by the ink state the screen owns. An [inkController] supplied
  /// from outside brings its own.
  final SelectionConfig selectionConfig;

  /// Answers the assistant's requests. Supplied by tests, and by a build
  /// that talks to its own backend; otherwise the screen makes a
  /// [GeminiAiClient] from [aiApiConfig] and closes it when it goes.
  final AiClient? aiClient;

  /// Used by the client the screen makes. Ignored with an [aiClient].
  final AiApiConfig aiApiConfig;

  final AiLayoutConfig aiLayoutConfig;

  /// Turns the selected ink into the image the assistant is shown.
  final SelectionImageRenderer selectionImageRenderer;

  final NoteImageRenderer noteImageRenderer;

  final PageConfig pageConfig;
  final ShapeConfig shapeConfig;
  final NoteAssetReader? assetReader;
  final PdfRasterizer pdfRasterizer;
  final DocumentIoConfig documentIoConfig;
  final NoteRepository? repository;
  final String? noteId;
  final DocumentPicker documentPicker;
  final ExportSink exportSink;
  final ValueChanged<InkClipboard>? onClipboardChanged;

  /// Whether only a stylus writes, shared from outside so the choice
  /// follows the user from note to note; otherwise the screen owns one,
  /// off.
  final ValueNotifier<bool>? stylusOnly;

  /// Whether the assistant may draw on the note when the editor opens. On,
  /// unless turned off in the editor's settings.
  final bool initialNotationEnabled;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  final ValueNotifier<EditorTool> _tool = ValueNotifier<EditorTool>(
    EditorTool.pen,
  );
  late final ValueNotifier<PenSettings> _penSettings =
      ValueNotifier<PenSettings>(PenSettings.defaults(widget.penConfig));
  late final ValueNotifier<EraserSettings> _eraserSettings =
      ValueNotifier<EraserSettings>(
        EraserSettings.defaults(widget.eraserConfig),
      );
  final ToolPaletteController _paletteController = ToolPaletteController();
  ValueNotifier<bool>? _ownedStylusOnly;

  ValueNotifier<bool> get _stylusOnly =>
      widget.stylusOnly ?? (_ownedStylusOnly ??= ValueNotifier<bool>(false));

  /// Where on the page Paste is being offered after a hold, if anywhere.
  final ValueNotifier<Offset?> _pastePrompt = ValueNotifier<Offset?>(null);

  NoteDocument? _ownedDocument;
  late NoteDocument _document = _createDocument();

  /// The page whose ink the screen is listening to.
  InkController? _listenedInk;

  /// The writing area, which a fit page fills and an infinite page grows
  /// from.
  Size _viewportSize = Size.zero;

  /// Whether two fingers are scrolling the page, which blocks new strokes.
  bool _scrolling = false;

  AiClient? _ownedAiClient;
  late final AiAssistantController _ai = AiAssistantController(
    client:
        widget.aiClient ??
        (_ownedAiClient = GeminiAiClient(config: widget.aiApiConfig)),
    renderer: widget.selectionImageRenderer,
    captureNote: _captureNote,
    applyNotation: _applyNotation,
    notationEnabled: widget.initialNotationEnabled,
  );
  Size _surfaceSize = Size.zero;
  InkController? _notationControllerAtCapture;
  final FocusNode _editorFocus = FocusNode(debugLabel: 'Editor');

  /// Keeps the panel's state, its text field and scroll position included,
  /// when it moves between sides and between the two layouts.
  final GlobalKey _aiPanelKey = GlobalKey(debugLabel: 'AI assistant panel');
  PdfPageRenderCache? _pdfCache;
  int _pdfClipboardGeneration = 0;

  PdfPageRenderCache? get _pageRenderCache {
    final NoteAssetReader? reader = widget.assetReader;
    return reader == null
        ? null
        : (_pdfCache ??= PdfPageRenderCache(
            readAsset: reader,
            rasterizer: widget.pdfRasterizer,
            config: widget.documentIoConfig,
          ));
  }

  /// Starts rendering the PDF paper of the pages around the current one,
  /// nearest first, so paging through a PDF does not wait on each page.
  void _preloadPdfPages(
    List<NotePage> pages,
    List<PageGeometry> geometries,
    double devicePixelRatio,
  ) {
    final PdfPageRenderCache? cache = _pageRenderCache;
    if (cache == null) {
      return;
    }
    final int current = _document.currentIndex;
    final int distance = widget.documentIoConfig.pdfPreloadDistance;
    for (int step = 1; step <= distance; step++) {
      for (final int index in <int>[current + step, current - step]) {
        if (index < 0 || index >= pages.length) continue;
        final PdfPageSource? pdf = pages[index].pdfSource;
        if (pdf != null) {
          cache.preload(pdf, geometries[index].displaySize, devicePixelRatio);
        }
      }
    }
  }

  /// The shown page's ink.
  InkController get _inkController => _document.current.ink;

  NoteDocument _createDocument() {
    final NoteDocument? document = widget.document;
    if (document != null) {
      return document;
    }
    final InkController? ink = widget.inkController;
    return _ownedDocument = ink == null
        ? NoteDocument(createInk: _newInk)
        : NoteDocument.single(ink, createInk: _newInk);
  }

  InkController _newInk() {
    return InkController(selectionConfig: widget.selectionConfig);
  }

  void _attachInk(InkController ink) {
    ink.selectionListenable.addListener(_onSelectionChanged);
    ink.activeStrokeListenable.addListener(_onActiveInkChanged);
    ink.completedStrokesListenable.addListener(_growToInk);
    _listenedInk = ink;
  }

  void _detachInk(InkController ink) {
    ink.selectionListenable.removeListener(_onSelectionChanged);
    ink.activeStrokeListenable.removeListener(_onActiveInkChanged);
    ink.completedStrokesListenable.removeListener(_growToInk);
  }

  /// A page was added, removed, or shown, or its setup changed. Leaving a
  /// page ends its gesture and drops its selection; the clipboard comes
  /// along.
  void _onDocumentChanged() {
    final InkController next = _inkController;
    final InkController? previous = _listenedInk;
    if (!identical(next, previous)) {
      if (previous != null) {
        _detachInk(previous);
        final bool stillThere = _document.pages.any(
          (NotePage page) => identical(page.ink, previous),
        );
        if (stillThere) {
          previous.finalizeActiveGesture();
          previous.clearSelection();
        }
        next.takeClipboardFrom(previous);
      }
      _attachInk(next);
      _pastePrompt.value = null;
      _scrolling = false;
      _onSelectionChanged();
    }
    _growToInk();
    if (mounted) {
      setState(() {});
    }
  }

  /// Grows an infinite page to keep the stroke being drawn off its edges.
  void _onActiveInkChanged() {
    final ActiveStroke? active = _inkController.activeStroke;
    if (active == null) {
      return;
    }
    final InkVector tip = active.lastPoint;
    _growPage(
      Rect.fromCircle(
        center: Offset(tip.x, tip.y),
        radius: active.style.width / 2,
      ),
    );
  }

  /// Grows an infinite page to keep all of its ink off its edges.
  void _growToInk() {
    if (_document.current.setup.size != PageSize.infinite) {
      return;
    }
    Rect? reach;
    for (final Stroke stroke in _inkController.strokes) {
      reach = reach?.expandToInclude(stroke.bounds) ?? stroke.bounds;
    }
    if (reach != null) {
      _growPage(reach);
    }
  }

  void _growPage(Rect ink) {
    final NotePage page = _document.current;
    if (page.setup.size != PageSize.infinite || _viewportSize.isEmpty) {
      return;
    }
    final Size? grown = grownPageExtent(
      current: PageGeometry.of(page.setup, page.extent, _viewportSize).pageSize,
      viewport: _viewportSize,
      ink: ink,
      config: widget.pageConfig,
    );
    if (grown != null) {
      _document.setExtent(page, grown);
    }
  }

  /// Two fingers began scrolling: whatever they started on any page is not
  /// writing, erasing, or selecting.
  void _onScrollStart(Set<int> pointers) {
    _scrolling = true;
    for (final NotePage page in _document.pages) {
      for (final int pointer in pointers) {
        page.ink
          ..discardStroke(pointer)
          ..cancelErase(pointer)
          ..cancelSelectionGesture(pointer);
      }
    }
  }

  /// One pointer owns the whole note at a time, whichever page it is on, so
  /// a palm resting on one page does not let the pen write on another.
  bool _anyPageBusy() {
    return _document.pages.any((NotePage page) => page.ink.isBusy);
  }

  /// Makes page [index] the current one, the page the selection, Paste, and
  /// the page panel act on. Not while a pointer is busy on another page:
  /// its gesture would be cut short.
  void _showPage(int index) {
    final List<NotePage> pages = _document.pages;
    for (int i = 0; i < pages.length; i++) {
      if (i != index && pages[i].ink.isBusy) {
        return;
      }
    }
    _document.goTo(index);
  }

  void _onScrollEnd() {
    _scrolling = false;
  }

  Future<void> _openPagePanel() {
    return showPagePanel(
      context,
      document: _document,
      writingArea: _viewportSize,
      config: widget.pageConfig,
    );
  }

  Future<NoteImage> _captureNote() async {
    final InkController controller = _inkController;
    final Size size = _surfaceSize;
    if (!mounted || controller.isBusy || !size.isFinite || size.isEmpty) {
      throw const NoteImageException(NoteImageFailure.invalidGeometry);
    }
    _notationControllerAtCapture = controller;
    final Brightness brightness = Theme.of(context).brightness;
    final Color background = AppColors.of(context).writingSurface;
    final Rect? focusBounds = _ai.context?.image?.logicalBounds;
    final List<SnapshotBitmap> bitmaps = <SnapshotBitmap>[];
    final NotePage page = _document.current;
    final NoteAssetReader? readAsset = widget.assetReader;
    if (readAsset != null) {
      final PdfPageSource? pdf = page.pdfSource;
      if (pdf != null && _pageRenderCache != null) {
        try {
          final Uint8List png = await _pageRenderCache!.render(pdf, size, 1);
          bitmaps.add(
            SnapshotBitmap(
              bytes: png,
              bounds: Offset.zero & pdf.pageSize,
              affectsCrop: false,
            ),
          );
        } on Object {
          // The same missing-page fallback as the editor: keep the paper.
        }
      }
      final Map<String, Uint8List> imageAssets = <String, Uint8List>{};
      for (final NoteImageElement element in controller.images) {
        try {
          final Uint8List bytes = imageAssets[element.assetId] ??=
              (await readAsset(element.assetId))!;
          bitmaps.add(
            SnapshotBitmap(
              bytes: bytes,
              bounds: Rect.fromCenter(
                center: Offset(element.center.x, element.center.y),
                width: element.size.width,
                height: element.size.height,
              ),
              rotation: element.rotation,
            ),
          );
        } on Object {
          // A missing image does not prevent the remaining note capture.
        }
      }
    }
    return widget.noteImageRenderer.render(
      NoteInkSnapshot.of(
        controller.strokes,
        logicalSize: size,
        revision: controller.documentRevision,
        brightness: brightness,
        background: background,
        focusBounds: focusBounds,
        bitmaps: bitmaps,
      ),
    );
  }

  AiNotationApplication _applyNotation(
    AiNotation notation,
    NoteImage requestContext,
  ) {
    if (!mounted ||
        !identical(_notationControllerAtCapture, _inkController) ||
        requestContext.logicalSize != _surfaceSize) {
      return const AiNotationApplication(AiNotationStatus.notAppliedStale);
    }
    // Drawn over time when the model timed it, unless the user has asked
    // for less motion: then it is the same strokes, shown at once.
    final AiNotationTimeline? timeline = MediaQuery.disableAnimationsOf(context)
        ? null
        : notation.timeline;
    final InkController controller = _inkController;
    // Leads that stop just short of, or run just past, the user's ink are
    // joined to it.
    final InkSnapper snapper = InkSnapper(<List<InkVector>>[
      for (final Stroke stroke in controller.strokes) stroke.points,
    ], reach: const AiNotationConfig().inkSnapDistance);
    // Coordinates map through the captured note's size: x * width,
    // y * height, never the screen or the image's pixels.
    final List<GeneratedInkTrace> traces;
    try {
      traces = timeline == null
          ? layoutNotation(
              notation,
              requestContext.logicalSize,
              snapper: snapper,
            )
          : layoutTimedNotation(
              notation,
              requestContext.logicalSize,
              snapper: snapper,
            );
    } on FormatException {
      return const AiNotationApplication(AiNotationStatus.notAppliedInvalid);
    }
    final AddNotationResult result = controller.addAiNotation(
      traces: traces,
      expectedRevision: requestContext.revision,
      surfaceSize: requestContext.logicalSize,
      playbackDuration: timeline == null
          ? null
          : Duration(milliseconds: timeline.durationMs),
    );
    // A notation is appended whole, one stroke per trace.
    List<Stroke> added() =>
        controller.strokes.sublist(controller.strokes.length - traces.length);
    return switch (result) {
      AddNotationResult.added => AiNotationApplication(
        AiNotationStatus.applied,
        strokes: added(),
      ),
      AddNotationResult.addedWithPlayback => AiNotationApplication(
        AiNotationStatus.animating,
        presentation: _PlaybackPresentation(
          controller,
          controller.notationPlayback!,
        ),
        strokes: added(),
      ),
      AddNotationResult.stale => const AiNotationApplication(
        AiNotationStatus.notAppliedStale,
      ),
      AddNotationResult.busy => const AiNotationApplication(
        AiNotationStatus.notAppliedBusy,
      ),
      AddNotationResult.invalid => const AiNotationApplication(
        AiNotationStatus.notAppliedInvalid,
      ),
    };
  }

  /// Pasted ink arrives selected, so pasting switches to the Select tool.
  /// Nothing happens while the clipboard is empty.
  void _paste() {
    if (_inkController.canPaste) {
      _tool.value = EditorTool.select;
      _inkController.paste();
    }
  }

  void _undo() {
    _pastePrompt.value = null;
    _inkController.undo();
  }

  void _redo() {
    _pastePrompt.value = null;
    _inkController.redo();
  }

  /// Pastes with the copies centered where the pointer was held.
  void _pasteAt(Offset position) {
    _pastePrompt.value = null;
    _inkController.paste(at: InkVector(position.dx, position.dy));
  }

  void _copy() {
    final InkSelection? selection = _stableSelection();
    if (selection?.includesPdf == true) {
      unawaited(_copyPdfSelection(selection!, cut: false));
      return;
    }
    _pdfClipboardGeneration++;
    if (_inkController.copySelection()) {
      final InkClipboard? clipboard = _inkController.clipboard;
      if (clipboard != null) widget.onClipboardChanged?.call(clipboard);
    }
  }

  void _cut() {
    final InkSelection? selection = _stableSelection();
    if (selection?.includesPdf == true) {
      unawaited(_copyPdfSelection(selection!, cut: true));
      return;
    }
    _pdfClipboardGeneration++;
    if (_inkController.cutSelection()) {
      final InkClipboard? clipboard = _inkController.clipboard;
      if (clipboard != null) widget.onClipboardChanged?.call(clipboard);
    }
  }

  /// Rasterizes immutable PDF paper only when Copy or Cut is requested, then
  /// adds that excerpt to the ordinary in-app image clipboard.
  Future<void> _copyPdfSelection(
    InkSelection selection, {
    required bool cut,
  }) async {
    final NoteRepository? repository = widget.repository;
    final String? noteId = widget.noteId;
    final PdfPageSource? source = _document.current.pdfSource;
    final PdfPageRenderCache? cache = _pageRenderCache;
    final Rect? requestedBounds = selection.pdfBounds;
    if (repository == null ||
        noteId == null ||
        source == null ||
        cache == null ||
        requestedBounds == null) {
      _showPdfCopyError();
      return;
    }
    final int generation = ++_pdfClipboardGeneration;
    final InkController controller = _inkController;
    final double pixelRatio = MediaQuery.devicePixelRatioOf(context);
    String? assetId;
    try {
      final Uint8List page = await cache.render(
        source,
        source.pageSize,
        pixelRatio,
      );
      final PdfSelectionImage excerpt = await Isolate.run(
        () => cropPdfSelection(page, source.pageSize, requestedBounds),
      );
      if (!mounted ||
          generation != _pdfClipboardGeneration ||
          !identical(selection, controller.selection) ||
          !identical(controller, _inkController)) {
        return;
      }
      assetId = await repository.storeAsset(
        noteId,
        excerpt.png,
        kind: NoteAssetKind.image,
        extension: 'png',
        fileName: 'PDF page ${source.pageIndex + 1} excerpt.png',
      );
      if (!mounted ||
          generation != _pdfClipboardGeneration ||
          !identical(selection, controller.selection) ||
          !identical(controller, _inkController)) {
        await repository.removeAsset(noteId, assetId);
        return;
      }
      final Rect bounds = excerpt.logicalBounds;
      final NoteImageElement image = NoteImageElement(
        id: 'pdf-excerpt-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
        assetId: assetId,
        pixelSize: excerpt.pixelSize,
        center: InkVector(bounds.center.dx, bounds.center.dy),
        size: bounds.size,
        fileName: 'PDF page ${source.pageIndex + 1} excerpt.png',
      );
      final bool copied = cut
          ? controller.cutSelection(
              expectedSelection: selection,
              additionalImages: <NoteImageElement>[image],
            )
          : controller.copySelection(
              expectedSelection: selection,
              additionalImages: <NoteImageElement>[image],
            );
      if (!copied) {
        await repository.removeAsset(noteId, assetId);
        return;
      }
      final InkClipboard? clipboard = controller.clipboard;
      if (clipboard != null) widget.onClipboardChanged?.call(clipboard);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              cut
                  ? 'PDF excerpt cut as an image.'
                  : 'PDF excerpt copied as an image.',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } on Object {
      if (assetId != null) {
        try {
          await repository.removeAsset(noteId, assetId);
        } on Object {
          // Asset cleanup is retried when the note closes.
        }
      }
      if (mounted && generation == _pdfClipboardGeneration) {
        _showPdfCopyError();
      }
    }
  }

  void _showPdfCopyError() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('This PDF selection could not be copied.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Opens the assistant on the current selection. Nothing is sent.
  void _openAi() => unawaited(_captureForAi(open: true));

  /// Switches to the current selection, resuming a matching conversation.
  void _useCurrentSelection() => unawaited(_captureForAi(open: false));

  /// Adds the current selection to the open conversation's ink.
  void _addSelectionToAi() {
    final InkSelection? selection = _stableSelection();
    if (selection != null) {
      _ai.addToContext(selection);
    }
  }

  /// Hands [capture] the selection and the page's look, unless a gesture is
  /// still reshaping the selection or nothing is selected.
  Future<void> _captureForAi({required bool open}) async {
    final InkSelection? selection = _stableSelection();
    if (selection == null) return;
    final Brightness brightness = Theme.of(context).brightness;
    final Color background = AppColors.of(context).writingSurface;
    final List<SnapshotBitmap> bitmaps = await _selectionBitmaps(selection);
    if (!mounted || !identical(selection, _stableSelection())) return;
    final SelectionInkSnapshot snapshot = SelectionInkSnapshot.of(
      selection,
      brightness: brightness,
      background: background,
      bitmaps: bitmaps,
    );
    if (open) {
      _ai.open(
        selection,
        brightness: brightness,
        background: background,
        snapshot: snapshot,
      );
    } else {
      _ai.useSelection(
        selection,
        brightness: brightness,
        background: background,
        snapshot: snapshot,
      );
    }
  }

  Future<List<SnapshotBitmap>> _selectionBitmaps(InkSelection selection) async {
    final List<SnapshotBitmap> bitmaps = <SnapshotBitmap>[];
    final NoteAssetReader? readAsset = widget.assetReader;
    if (readAsset == null) return bitmaps;
    final PdfPageSource? pdf = _document.current.pdfSource;
    if (pdf != null && _pageRenderCache != null) {
      try {
        bitmaps.add(
          SnapshotBitmap(
            bytes: await _pageRenderCache!.render(pdf, _surfaceSize, 1),
            bounds: Offset.zero & pdf.pageSize,
            affectsCrop: false,
            source: SnapshotBitmapSource(
              pdf.assetId,
              pdfPageIndex: pdf.pageIndex,
              pdfPageSize: pdf.pageSize,
            ),
          ),
        );
      } on Object {
        // Selection capture remains useful without its PDF paper.
      }
    }
    final Map<String, Uint8List> assets = <String, Uint8List>{};
    for (final NoteImageElement element in selection.images) {
      try {
        final Uint8List bytes = assets[element.assetId] ??= (await readAsset(
          element.assetId,
        ))!;
        bitmaps.add(
          SnapshotBitmap(
            bytes: bytes,
            bounds: Rect.fromCenter(
              center: Offset(element.center.x, element.center.y),
              width: element.size.width,
              height: element.size.height,
            ),
            rotation: element.rotation,
            source: SnapshotBitmapSource(element.assetId),
          ),
        );
      } on Object {
        // A missing image does not hide selected ink.
      }
    }
    return bitmaps;
  }

  void _closeAi() {
    _ai.close();
    // The panel takes its text field with it.
    _editorFocus.requestFocus();
  }

  Future<void> _openSettings() {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext context) {
        return EditorSettingsSheet(
          controller: _ai,
          stylusOnly: _stylusOnly,
          onInsertPdf: _canUseDocumentIo
              ? () {
                  Navigator.of(context).pop();
                  _insertPdf();
                }
              : null,
          onInsertImage: _canUseDocumentIo
              ? () {
                  Navigator.of(context).pop();
                  _insertImage();
                }
              : null,
          onExportPdf: _canUseDocumentIo
              ? () {
                  Navigator.of(context).pop();
                  _exportPdf();
                }
              : null,
        );
      },
    );
  }

  bool get _canUseDocumentIo =>
      widget.repository != null && widget.noteId != null;

  DocumentImporter get _importer => DocumentImporter(
    rasterizer: widget.pdfRasterizer,
    config: widget.documentIoConfig,
  );

  void _showIoError(Object error) {
    if (!mounted) return;
    final String message = error is DocumentImportException
        ? error.message
        : 'The document operation could not be completed.';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _insertPdf() async {
    final PickedDocument? picked = await widget.documentPicker.pickPdf();
    if (picked == null || !mounted) return;
    final ImportCancellationToken cancellation = ImportCancellationToken();
    final DocumentIoProgressResult result = await showDocumentIoProgress(
      context,
      title: 'Importing PDF',
      onCancel: cancellation.cancel,
      operation: (_) => _importer.insertPdfPages(
        repository: widget.repository!,
        noteId: widget.noteId!,
        document: _document,
        picked: picked,
        cancellation: cancellation,
      ),
    );
    if (result.error != null && !result.cancelled) {
      _showIoError(result.error!);
    }
  }

  Future<void> _insertImage() async {
    final PickedDocument? picked = await widget.documentPicker.pickImage();
    if (picked == null || !mounted) return;
    try {
      await _importer.insertImage(
        repository: widget.repository!,
        noteId: widget.noteId!,
        controller: _inkController,
        picked: picked,
        visiblePage: Offset.zero & _surfaceSize,
      );
      _tool.value = EditorTool.select;
    } on Object catch (error) {
      _showIoError(error);
    }
  }

  Future<void> _exportPdf() async {
    final PdfExportOptions? options = await showExportOptions(
      context,
      allowCurrentPage: true,
    );
    if (options == null || !mounted) return;
    _inkController.finalizeActiveGesture();
    _inkController.finishNotationPlayback();
    final ExportCancellationToken cancellation = ExportCancellationToken();
    final DocumentIoProgressResult result = await showDocumentIoProgress(
      context,
      title: 'Exporting PDF',
      onCancel: cancellation.cancel,
      operation: (report) =>
          PdfExporter(
            rasterizer: widget.pdfRasterizer,
            sink: widget.exportSink,
            config: widget.documentIoConfig,
            pageConfig: widget.pageConfig,
          ).exportAndShare(
            noteId: widget.noteId!,
            title: widget.title,
            content: NoteContent.fromDocument(_document),
            repository: widget.repository!,
            options: options,
            currentPage: _document.currentIndex,
            currentWritingArea: _viewportSize,
            cancellation: cancellation,
            onProgress: report,
          ),
    );
    if (result.error != null && !result.cancelled) {
      _showIoError(result.error!);
    }
  }

  /// The selection, or null while a lasso or a transform is under way.
  InkSelection? _stableSelection() {
    final InkController controller = _inkController;
    final bool gesturing =
        controller.activeLasso != null || controller.activeTransform != null;
    return gesturing ? null : controller.selection;
  }

  void _onSelectionChanged() {
    final InkController controller = _inkController;
    if (controller.activeLasso == null && controller.activeTransform == null) {
      _ai.updateCurrentSelection(controller.selection);
    }
  }

  /// Where each of the note's strokes and images is now.
  AiInkIndex _inkIndex() {
    return AiInkIndex(<(List<Stroke>, List<NoteImageElement>)>[
      for (final NotePage page in _document.pages)
        (page.ink.strokes, page.ink.images),
    ]);
  }

  Map<String, Object?>? _writeAiSession() => _ai.toJson(_inkIndex());

  /// Takes the conversations saved with [_document] back into the
  /// assistant, and from now on saves them with it.
  void _adoptAiSession() {
    final Map<String, Object?>? saved = _document.aiSession;
    if (saved != null) {
      _ai.restore(saved, _inkIndex(), loadBitmap: _loadSnapshotBitmap);
    }
    _document.aiSessionWriter = _writeAiSession;
    _ai.sessionListenable.addListener(_document.aiSessionChanged);
  }

  /// Leaves [_document] holding the conversations as they are now, for
  /// saving after the editor has gone.
  void _releaseAiSession() {
    _ai.sessionListenable.removeListener(_document.aiSessionChanged);
    _document
      ..aiSession = _writeAiSession()
      ..aiSessionWriter = null;
  }

  /// Reads a bitmap a saved conversation's image was drawn over.
  Future<Uint8List?> _loadSnapshotBitmap(SnapshotBitmapSource source) async {
    final NoteAssetReader? readAsset = widget.assetReader;
    if (readAsset == null) {
      return null;
    }
    final int? pageIndex = source.pdfPageIndex;
    if (pageIndex == null) {
      return readAsset(source.assetId);
    }
    final PdfPageRenderCache? cache = _pageRenderCache;
    if (cache == null) {
      return null;
    }
    final PdfPageSource pdf = PdfPageSource(
      assetId: source.assetId,
      pageIndex: pageIndex,
      pageSize: source.pdfPageSize!,
    );
    return cache.render(pdf, pdf.pageSize, 1);
  }

  /// Turning Animation off stops every notation still looping on the note.
  void _onAiChanged() {
    if (!_ai.animationEnabled) {
      _inkController.finishNotationPlayback();
    }
  }

  @override
  void initState() {
    super.initState();
    _attachInk(_inkController);
    _document.addListener(_onDocumentChanged);
    _ai.addListener(_onAiChanged);
    _adoptAiSession();
  }

  @override
  void didUpdateWidget(EditorScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assetReader != widget.assetReader ||
        oldWidget.pdfRasterizer != widget.pdfRasterizer ||
        oldWidget.documentIoConfig != widget.documentIoConfig) {
      _pdfCache?.clear();
      _pdfCache = null;
    }
    if (oldWidget.document != widget.document ||
        oldWidget.inkController != widget.inkController) {
      _releaseAiSession();
      _document.removeListener(_onDocumentChanged);
      final NoteDocument? owned = _ownedDocument;
      _ownedDocument = null;
      _document = _createDocument();
      _document.addListener(_onDocumentChanged);
      _adoptAiSession();
      _onDocumentChanged();
      owned?.dispose();
    }
  }

  @override
  void dispose() {
    final InkController? listened = _listenedInk;
    if (listened != null) {
      _detachInk(listened);
    }
    _releaseAiSession();
    _document.removeListener(_onDocumentChanged);
    _ai.removeListener(_onAiChanged);
    _ai.dispose();
    _ownedAiClient?.close();
    _editorFocus.dispose();
    _ownedDocument?.dispose();
    _tool.dispose();
    _penSettings.dispose();
    _eraserSettings.dispose();
    _pastePrompt.dispose();
    _ownedStylusOnly?.dispose();
    _pdfCache?.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final WindowSizeClass sizeClass = WindowSizeClass.fromWidth(
      MediaQuery.sizeOf(context).width,
    );

    return ClipboardShortcuts(
      focusNode: _editorFocus,
      onCopy: _copy,
      onCut: _cut,
      onPaste: _paste,
      onUndo: _undo,
      onRedo: _redo,
      child: ValueListenableBuilder<AiPanelPlacement>(
        valueListenable: _ai.placement,
        builder: (BuildContext context, AiPanelPlacement placement, Widget? _) {
          // Beside the editor on tablets; over it, as a modal sheet, on
          // compact widths.
          final bool sheet =
              placement.isOpen && sizeClass == WindowSizeClass.compact;
          return PopScope(
            canPop: !sheet,
            onPopInvokedWithResult: (bool didPop, Object? _) {
              if (!didPop) {
                _closeAi();
              }
            },
            child: Stack(
              children: <Widget>[
                ExcludeFocus(
                  excluding: sheet,
                  child: ExcludeSemantics(
                    excluding: sheet,
                    child: _buildScaffold(
                      context,
                      sizeClass,
                      placement.isOpen && !sheet ? placement.side : null,
                    ),
                  ),
                ),
                if (sheet) ..._buildSheet(context, placement.side),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildPanel() {
    return AiAssistantPanel(
      key: _aiPanelKey,
      controller: _ai,
      config: widget.aiLayoutConfig,
      onClose: _closeAi,
      onNewChat: _useCurrentSelection,
      onAddToContext: _addSelectionToAi,
    );
  }

  /// The panel over the editor, against [side], above a barrier that
  /// closes it.
  List<Widget> _buildSheet(BuildContext context, AiPanelSide side) {
    final AppColors colors = AppColors.of(context);
    final Size screen = MediaQuery.sizeOf(context);
    final double width = widget.aiLayoutConfig.sheetWidth(screen.width);
    final Duration duration = AppMotion.resolve(context, AppMotion.medium);
    return <Widget>[
      Positioned.fill(
        child: Semantics(
          container: true,
          button: true,
          label: 'Dismiss AI assistant',
          onTap: _closeAi,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTap: _closeAi,
            child: ColoredBox(color: colors.shadow.withValues(alpha: 0.32)),
          ),
        ),
      ),
      AnimatedPositioned(
        key: const ValueKey<String>('ai-panel-sheet'),
        duration: duration,
        curve: AppMotion.standard,
        top: 0,
        bottom: 0,
        left: side == AiPanelSide.left ? 0 : screen.width - width,
        width: width,
        // Slides in from its edge when it opens.
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 1, end: 0),
          duration: duration,
          curve: AppMotion.standard,
          builder: (BuildContext context, double hidden, Widget? child) {
            return FractionalTranslation(
              translation: Offset(
                side == AiPanelSide.left ? -hidden : hidden,
                0,
              ),
              child: child,
            );
          },
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface,
              boxShadow: AppShadows.floating(colors),
            ),
            child: Padding(
              // Keeps the composer above the on-screen keyboard.
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: SafeArea(
                child: FocusScope(autofocus: true, child: _buildPanel()),
              ),
            ),
          ),
        ),
      ),
    ];
  }

  /// [panelSide] is where the assistant sits beside the editor, or null
  /// when it is closed or shown as a sheet instead.
  Widget _buildScaffold(
    BuildContext context,
    WindowSizeClass sizeClass,
    AiPanelSide? panelSide,
  ) {
    final AppColors colors = AppColors.of(context);
    return Scaffold(
      appBar: EditorAppBar(
        title: widget.title,
        centerTitle: sizeClass == WindowSizeClass.expanded,
        onMenuPressed: widget.onBack ?? () {},
        leadingIsBack: widget.onBack != null,
        onTitlePressed: widget.onTitlePressed ?? () {},
        onMorePressed: _openSettings,
        historyControls: HistoryControls(
          controller: _inkController,
          onUndo: _undo,
          onRedo: _redo,
        ),
        pageControls: PageControls(
          document: _document,
          showNavigation: sizeClass != WindowSizeClass.compact,
          onOpenPanel: _openPagePanel,
        ),
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final Size size = constraints.biggest;
            final double panelWidth = panelSide == null
                ? 0
                : widget.aiLayoutConfig.inlineWidth(size.width);
            // What the panel leaves for the page and the palette.
            final Rect region = Rect.fromLTWH(
              panelSide == AiPanelSide.left ? panelWidth : 0,
              0,
              size.width - panelWidth,
              size.height,
            );
            final _EditorLayout layout = _EditorLayout.compute(
              sizeClass,
              region,
              Directionality.of(context),
            );
            final List<NotePage> pages = _document.pages;
            final List<PageGeometry> geometries = <PageGeometry>[
              for (final NotePage page in pages)
                PageGeometry.of(
                  page.setup,
                  page.extent,
                  layout.surface.size,
                  pdfPageSize: page.pdfSource?.pageSize,
                ),
            ];
            _viewportSize = layout.surface.size;
            _surfaceSize = geometries[_document.currentIndex].pageSize;
            final double pixelRatio = MediaQuery.devicePixelRatioOf(context);
            // After the frame, so the shown page's paper is asked for first.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _preloadPdfPages(pages, geometries, pixelRatio);
            });
            final NotePage currentPage = _document.current;
            if (currentPage.setup.size == PageSize.fit &&
                currentPage.lastFitSize != layout.surface.size) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  _document.recordFitSize(currentPage, layout.surface.size);
                }
              });
            }
            // The palette floats over the page; the page's own floating
            // bars keep clear of it. In the page area's coordinates.
            final Rect paletteOnPage =
                (layout.paletteOrigin - layout.surface.topLeft) &
                ToolPalette.sizeFor(layout.paletteAxis);
            final BorderSide edge = BorderSide(
              color: colors.divider,
              width: AppSizes.hairline,
            );
            return Stack(
              children: <Widget>[
                Positioned.fromRect(
                  rect: layout.surface,
                  child: WritingSurfaceFrame(
                    child: PageViewport(
                      key: const ValueKey<String>('page-viewport'),
                      pages: geometries,
                      pageKeys: <Key>[
                        for (final NotePage page in pages) ObjectKey(page),
                      ],
                      currentPage: _document.currentIndex,
                      onPageTouched: _showPage,
                      onVisiblePageChanged: _showPage,
                      onScrollStart: _onScrollStart,
                      onScrollEnd: _onScrollEnd,
                      fingersNavigate: _stylusOnly,
                      pageBuilder:
                          (
                            BuildContext context,
                            int index,
                            ValueListenable<Rect> visible,
                          ) {
                            final NotePage page = pages[index];
                            return Stack(
                              fit: StackFit.expand,
                              children: <Widget>[
                                PageBackgroundLayer(
                                  background: page.setup.background,
                                  visible: visible,
                                  config: widget.pageConfig,
                                ),
                                if (page.pdfSource != null &&
                                    _pageRenderCache != null)
                                  PdfPageLayer(
                                    source: page.pdfSource!,
                                    displayedSize:
                                        geometries[index].displaySize,
                                    cache: _pageRenderCache!,
                                  ),
                                if (widget.assetReader != null)
                                  PageImageLayer(
                                    controller: page.ink,
                                    readAsset: widget.assetReader!,
                                    maxDecodeDimension: widget
                                        .documentIoConfig
                                        .maxStoredImageDimension,
                                  ),
                                InkCanvas(
                                  controller: page.ink,
                                  tool: _tool,
                                  penSettings: _penSettings,
                                  eraserSettings: _eraserSettings,
                                  eraserConfig: widget.eraserConfig,
                                  shapeConfig: widget.shapeConfig,
                                  isInputBlocked: () =>
                                      _paletteController.hasOpenPopover ||
                                      _scrolling ||
                                      _anyPageBusy(),
                                  pastePrompt: _pastePrompt,
                                  stylusOnly: _stylusOnly,
                                  selectablePdfBounds: page.pdfSource == null
                                      ? null
                                      : Offset.zero & page.pdfSource!.pageSize,
                                ),
                              ],
                            );
                          },
                      // Above the current page, so their presses stay off
                      // it, and never scaled with it.
                      overlayBuilder:
                          (BuildContext context, PageTransform transform) {
                            return Stack(
                              fit: StackFit.expand,
                              children: <Widget>[
                                SelectionActionBar(
                                  controller: _inkController,
                                  onAiPressed: _openAi,
                                  onCopy: _copy,
                                  onCut: _cut,
                                  transform: transform,
                                  obstruction: paletteOnPage,
                                ),
                                PastePrompt(
                                  anchor: _pastePrompt,
                                  onPaste: _pasteAt,
                                  transform: transform,
                                  obstruction: paletteOnPage,
                                ),
                              ],
                            );
                          },
                    ),
                  ),
                ),
                AnimatedPositioned(
                  duration: AppMotion.resolve(context, AppMotion.medium),
                  curve: AppMotion.standard,
                  left: layout.paletteOrigin.dx,
                  top: layout.paletteOrigin.dy,
                  child: ToolPalette(
                    axis: layout.paletteAxis,
                    dense: sizeClass == WindowSizeClass.medium,
                    tool: _tool,
                    penSettings: _penSettings,
                    eraserSettings: _eraserSettings,
                    clipboardListenable: _inkController.selectionListenable,
                    canPaste: () => _inkController.canPaste,
                    onPaste: _paste,
                    penConfig: widget.penConfig,
                    eraserConfig: widget.eraserConfig,
                    controller: _paletteController,
                  ),
                ),
                if (panelSide != null)
                  AnimatedPositioned(
                    key: const ValueKey<String>('ai-panel-beside'),
                    duration: AppMotion.resolve(context, AppMotion.medium),
                    curve: AppMotion.standard,
                    top: 0,
                    bottom: 0,
                    left: panelSide == AiPanelSide.left
                        ? 0
                        : size.width - panelWidth,
                    width: panelWidth,
                    child: DecoratedBox(
                      position: DecorationPosition.foreground,
                      decoration: BoxDecoration(
                        border: Border(
                          top: edge,
                          left: panelSide == AiPanelSide.right
                              ? edge
                              : BorderSide.none,
                          right: panelSide == AiPanelSide.left
                              ? edge
                              : BorderSide.none,
                        ),
                      ),
                      child: _buildPanel(),
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

/// An AI notation's playback, as the assistant sees it: done once it has
/// been drawn whole the first time, though it keeps looping. Finishing it
/// shows that one playback whole; the others are left alone.
class _PlaybackPresentation implements AiNotationPresentation {
  _PlaybackPresentation(this._controller, this._playback);

  final InkController _controller;
  final NotationPlayback _playback;

  @override
  Future<void> get done => _playback.done;

  @override
  void finish() => _controller.finishNotationPlayback(_playback);
}

/// Where the page and palette sit for a given size class, inside the region
/// the AI panel leaves them. The page fills the whole region, edge to edge;
/// the palette floats above it, near the leading edge on tablets and along
/// the bottom on compact widths.
class _EditorLayout {
  const _EditorLayout({
    required this.surface,
    required this.paletteOrigin,
    required this.paletteAxis,
  });

  final Rect surface;
  final Offset paletteOrigin;
  final Axis paletteAxis;

  static _EditorLayout compute(
    WindowSizeClass sizeClass,
    Rect region,
    TextDirection direction,
  ) {
    final Size size = region.size;
    _EditorLayout layout = _computeLtr(sizeClass, size);
    if (direction == TextDirection.rtl) {
      final Size palette = ToolPalette.sizeFor(layout.paletteAxis);
      layout = _EditorLayout(
        paletteAxis: layout.paletteAxis,
        paletteOrigin: Offset(
          size.width - layout.paletteOrigin.dx - palette.width,
          layout.paletteOrigin.dy,
        ),
        surface: Rect.fromLTRB(
          size.width - layout.surface.right,
          layout.surface.top,
          size.width - layout.surface.left,
          layout.surface.bottom,
        ),
      );
    }
    return _EditorLayout(
      paletteAxis: layout.paletteAxis,
      paletteOrigin: layout.paletteOrigin + region.topLeft,
      surface: layout.surface.shift(region.topLeft),
    );
  }

  static _EditorLayout _computeLtr(WindowSizeClass sizeClass, Size size) {
    final double margin = switch (sizeClass) {
      WindowSizeClass.expanded => AppSpacing.lg,
      WindowSizeClass.medium => AppSpacing.sm,
      WindowSizeClass.compact => AppSpacing.xs,
    };
    final Rect surface = Offset.zero & size;

    if (sizeClass == WindowSizeClass.compact) {
      final Size palette = ToolPalette.sizeFor(Axis.horizontal);
      return _EditorLayout(
        paletteAxis: Axis.horizontal,
        paletteOrigin: Offset(
          (size.width - palette.width) / 2,
          // Never above the top, even on windows too small for the chrome.
          math.max(0, size.height - margin - palette.height),
        ),
        surface: surface,
      );
    }

    return _EditorLayout(
      paletteAxis: Axis.vertical,
      paletteOrigin: Offset(margin, margin),
      surface: surface,
    );
  }
}
