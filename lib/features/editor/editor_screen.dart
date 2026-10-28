import 'dart:math' as math;
import 'dart:async';
import 'dart:isolate';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import '../../app/theme/app_icons.dart';
import '../../shared/feedback/app_haptics.dart';
import '../../shared/layout/breakpoints.dart';
import '../../shared/memory/memory_pressure.dart';
import '../library/note_content.dart';
import '../library/note_repository.dart';
import '../library/note_recording_track.dart';
import 'audio/note_audio.dart';
import 'audio/stroke_replay_controller.dart';
import 'ai/ai_assistant_controller.dart';
import 'ai/ai_canvas_input.dart';
import 'ai/ai_client.dart';
import 'ai/ai_config.dart';
import 'ai/ai_notation.dart';
import 'ai/canvas_text_recognizer.dart';
import 'ai/handwriting_prediction.dart';
import 'ai/backend_ai_client.dart';
import 'ai/ink_attachment.dart';
import 'ai/note_image_renderer.dart';
import 'ai/notation_layout.dart';
import 'ai/notation_font.dart';
import 'ai/notation_space.dart';
import 'ai/selection_image_renderer.dart';
import 'ai/svg_ink_converter.dart';
import 'ai/svg_notation_styler.dart';
import 'handwriting/handwriting_calibration.dart';
import 'handwriting/handwriting_calibration_screen.dart';
import 'handwriting/handwriting_style.dart';
import 'handwriting/handwriting_indexer.dart';
import 'handwriting/ink_search.dart';
import 'handwriting/recognized_handwriting.dart';
import 'ink/eraser_settings.dart';
import 'ink/pointer_claims.dart';
import 'ink/ruler.dart';
import 'ink/ink_canvas.dart';
import 'ink/ink_controller.dart';
import 'ink/input_defaults.dart';
import 'ink/ink_notation.dart';
import 'ink/ink_sample.dart';
import 'ink/ink_selection.dart';
import 'ink/notation_playback.dart';
import 'ink/pen_settings.dart';
import 'ink/selection_config.dart';
import 'ink/shape_config.dart';
import 'ink/stroke.dart';
import 'page/note_document.dart';
import 'sticky/sticky_note.dart';
import 'text/note_text.dart';
import 'page/page_background.dart';
import 'page/page_setup.dart';
import 'page/page_viewport.dart';
import 'document_io/image_layer.dart';
import 'document_io/document_io_config.dart';
import 'document_io/document_importer.dart';
import 'document_io/document_models.dart';
import 'document_io/document_platform.dart';
import 'document_io/pdf_page_layer.dart';
import 'document_io/pdf_preview_store.dart';
import 'document_io/page_image_cache.dart';
import 'document_io/pdf_selection_image.dart';
import 'document_io/pdf_exporter.dart';
import 'document_io/svg_document.dart';
import 'document_io/svg_exporter.dart';
import 'widgets/ai_assistant_panel.dart';
import 'widgets/ai_context_glow.dart';
import 'widgets/clipboard_shortcuts.dart';
import 'widgets/editor_app_bar.dart';
import 'widgets/editor_chrome.dart';
import 'widgets/editor_settings_sheet.dart';
import 'widgets/export_options_sheet.dart';
import 'widgets/history_controls.dart';
import 'widgets/document_io_progress_dialog.dart';
import 'widgets/page_controls.dart';
import 'widgets/selection_action_bar.dart';
import 'widgets/recording_options.dart';
import 'widgets/tool_palette.dart';
import 'widgets/writing_surface_frame.dart';
import '../payment/payment_page.dart';
import '../payment/subscription_controller.dart';

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
    this.onPageShown,
    this.pdfRasterizer = const PdfrxRasterizer(),
    this.pdfPreviewStore,
    this.documentIoConfig = const DocumentIoConfig(),
    this.repository,
    this.noteId,
    this.documentPicker = const SystemDocumentPicker(),
    this.exportSink = const SystemExportSink(),
    this.onClipboardChanged,
    this.stylusOnly,
    this.enableNativeInk = true,
    this.penSettings,
    this.palettePlacement,
    this.initialNotationEnabled = true,
    this.tabs,
    this.aiCanvasConfig = const AiCanvasConfig(),
    this.textRecognizer = const PlatformCanvasTextRecognizer(),
    this.handwritingRenderer = const HandwritingImageRenderer(),
    this.initialAiActive = false,
    this.subscription,
    this.handwritingProfileStore,
    this.audioRecorder,
    this.audioPlayer,
  });

  /// The user's plan and AI credits: which models the assistant may use,
  /// and what each answer costs. Without one, nothing is metered and the
  /// panel offers no plans.
  final SubscriptionController? subscription;

  /// Persists handwriting calibration and whether its chat reminder was
  /// dismissed. Without a store (as in lightweight editor embeds), the
  /// reminder is not shown.
  final HandwritingProfileStore? handwritingProfileStore;
  final NoteAudioRecorder? audioRecorder;
  final NoteAudioPlayer? audioPlayer;

  /// How writing on the page in AI mode is told apart and read.
  final AiCanvasConfig aiCanvasConfig;

  /// Reads handwriting, on the device: the page's pen ink for search, and
  /// writing in AI mode into the chat as plain text. Tests supply a fake.
  final CanvasTextRecognizer textRecognizer;

  /// Draws that handwriting for [textRecognizer].
  final HandwritingImageRenderer handwritingRenderer;

  /// Whether AI mode is on when the editor opens. Off unless asked: the
  /// assistant's notes stay hidden until it is turned on.
  final bool initialAiActive;

  /// The open notes' tabs, shown in the top bar in place of the title.
  final Widget? tabs;

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
  /// [BackendAiClient], serving every model through the backend, and
  /// closes it when it goes.
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

  /// Called once, when the page first shown has its paper on screen: after
  /// the first frame, or for PDF paper, once it has rendered.
  final VoidCallback? onPageShown;

  /// How far the pages are zoomed when a note opens: the column of pages
  /// sits narrower than the writing area, centered in it.
  static const double openingZoom = 0.7;
  final PdfRasterizer pdfRasterizer;

  /// Keeps PDF pages' previews between visits; without it they are
  /// rendered each time.
  final PdfPreviewStore? pdfPreviewStore;
  final DocumentIoConfig documentIoConfig;
  final NoteRepository? repository;
  final String? noteId;
  final DocumentPicker documentPicker;
  final ExportSink exportSink;
  final ValueChanged<InkClipboard>? onClipboardChanged;

  /// Whether only a stylus writes, shared from outside so the choice
  /// follows the user from note to note; otherwise the screen owns one,
  /// starting at [InputDefaults.stylusOnly] (on).
  final ValueNotifier<bool>? stylusOnly;

  /// Whether the platform stylus bridge owns real stylus events. Performance
  /// tests disable it because their framework-injected stylus events never
  /// pass through the host platform's motion-event observer.
  final bool enableNativeInk;

  /// The pen, shared from outside so its settings follow the user from
  /// note to note; otherwise the screen owns one with the defaults.
  final ValueNotifier<PenSettings>? penSettings;

  /// Where the tool palette floats, shared from outside so it stays where
  /// the user dragged it; otherwise the screen owns one, across the top.
  final ValueNotifier<PalettePlacement>? palettePlacement;

  /// Whether the assistant may draw on the note when the editor opens. On,
  /// unless turned off in the editor's settings.
  final bool initialNotationEnabled;

  @override
  State<EditorScreen> createState() => EditorScreenState();
}

class EditorScreenState extends State<EditorScreen>
    with WidgetsBindingObserver {
  /// These session details do not round-trip through note storage. Keep the
  /// editor alive rather than silently dropping history, selection, or work.
  bool get requiresRetention =>
      _audioRecorder.state != NoteAudioRecorderState.idle ||
      _documentIoPending != 0 ||
      _ai.placement.value.isOpen ||
      _ai.hasPendingWork ||
      _ai.draft.isNotEmpty ||
      _document.pages.any(
        (page) =>
            page.ink.isBusy ||
            page.ink.canUndo ||
            page.ink.canRedo ||
            page.ink.selection != null ||
            page.ink.clipboard != null,
      );

  int _documentIoPending = 0;
  final ValueNotifier<EditorTool> _tool = ValueNotifier<EditorTool>(
    EditorTool.pen,
  );
  ValueNotifier<PenSettings>? _ownedPenSettings;

  /// Whether AI mode is on: the palette's AI button. It is on exactly while
  /// the chat is open, and the assistant's notes show then if the settings
  /// say so.
  late final ValueNotifier<bool> _aiActive = ValueNotifier<bool>(
    widget.initialAiActive,
  );

  /// The tool AI mode hands the page back to when it is turned off.
  EditorTool _writingTool = EditorTool.pen;

  /// What is drawn on the page with the AI tool: a glowing loop around
  /// something, which is never ink.
  late final AiCanvasInputController _aiInput = AiCanvasInputController(
    config: widget.aiCanvasConfig,
    onCircle: _onAiCircle,
  );

  /// Ordinary pen ink waiting for on-device recognition.
  final List<(Stroke, String?)> _indexingPending = <(Stroke, String?)>[];
  final Set<Stroke> _knownPageStrokes = Set<Stroke>.identity();
  Timer? _indexingTimer;
  int _indexingGeneration = 0;

  HandwritingIndexer get _handwritingIndexer => HandwritingIndexer(
    recognizer: widget.textRecognizer,
    renderer: widget.handwritingRenderer,
  );

  ValueNotifier<PenSettings> get _penSettings =>
      widget.penSettings ??
      (_ownedPenSettings ??= ValueNotifier<PenSettings>(
        PenSettings.defaults(widget.penConfig),
      ));

  ValueNotifier<PalettePlacement>? _ownedPalettePlacement;

  ValueNotifier<PalettePlacement> get _palettePlacement =>
      widget.palettePlacement ??
      (_ownedPalettePlacement ??= ValueNotifier<PalettePlacement>(
        const PalettePlacement(),
      ));

  /// Where the palette's center is held while it is dragged, in the
  /// body's coordinates; null when it is docked.
  final ValueNotifier<Offset?> _paletteDragCenter = ValueNotifier<Offset?>(
    null,
  );

  /// The region the palette was last laid out in, which a drag snaps to.
  Rect _paletteRegion = Rect.zero;
  EditorLayout? _lastLayout;

  /// Hands the shared top bar this editor's settings, when the bar is not
  /// this editor's own.
  EditorChromeScope? _chromeScope;
  EditorChromeEntry? _chromeEntry;

  void _publishChrome() {
    final EditorChromeScope? scope = _chromeScope;
    if (scope == null || _chromeEntry != null) return;
    final EditorChromeEntry entry = EditorChromeEntry(
      onSettings: _openSettings,
      audioPlayer: _audioPlayer,
      replayController: _strokeReplay,
      onCloseReplay: () => unawaited(_closeReplay()),
    );
    _chromeEntry = entry;
    // After this frame: publishing lays the shared bar out again.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_chromeEntry, entry)) return;
      scope.host.publish(scope.noteId, entry);
    });
  }

  void _refreshChrome() {
    final EditorChromeScope? scope = _chromeScope;
    final EditorChromeEntry? entry = _chromeEntry;
    if (scope != null && entry != null) scope.host.publish(scope.noteId, entry);
  }

  void _rebuildChrome() {
    _retractChrome();
    _publishChrome();
  }

  /// Whether there is ink to find, including diagrams with no transcription.
  bool get _canFind => _document.pages.any(
    (NotePage page) =>
        page.ink.strokes.isNotEmpty ||
        page.ink.stickyNotes.any(
          (StickyNoteElement note) => note.strokes.isNotEmpty,
        ),
  );

  /// The remembered add action (addPage or insertPdf).
  AddPageAction? _lastAddAction;

  List<Rect> _nativeExclusionRects() {
    final EditorLayout? layout = _lastLayout;
    if (layout == null) return const <Rect>[];
    // An open menu hangs over the page wherever it likes, and its size is
    // not known here: while one is open, the pen is left to Flutter, which
    // lets the menu take the press.
    if (_paletteController.hasOpenPopover || _pageOverviewOpen.value) {
      return const <Rect>[Rect.fromLTRB(-1e6, -1e6, 1e6, 1e6)];
    }
    final Size paletteSize = ToolPalette.sizeFor(
      layout.paletteAxis,
      expanded: _paletteExpanded,
    );
    final Rect paletteRect = layout.paletteOrigin & paletteSize;
    final double topMargin = layout.surface.top;
    // The layout is in the body's coordinates; the native side hears the
    // pen in the window's.
    final RenderObject? body = _bodyKey.currentContext?.findRenderObject();
    final Offset origin = body is RenderBox && body.attached
        ? body.localToGlobal(Offset.zero)
        : Offset.zero;
    return <Rect>[
      paletteRect.shift(origin),
      layout.history.shift(origin),
      layout.pageControls.shift(origin),
      if (topMargin > 0)
        Rect.fromLTWH(0, 0, layout.surface.right, topMargin).shift(origin),
    ];
  }

  final GlobalKey _bodyKey = GlobalKey();

  late final ValueNotifier<EraserSettings> _eraserSettings =
      ValueNotifier<EraserSettings>(
        EraserSettings.defaults(widget.eraserConfig),
      );
  final ToolPaletteController _paletteController = ToolPaletteController();

  /// The ruler laid on the pages, shown from the palette's extension.
  final RulerController _ruler = RulerController();

  /// Touches a canvas has taken for the ruler, which the page
  /// view must not also scroll with.
  final PointerClaims _pointerClaims = PointerClaims();

  /// Whether the palette is unfolded: the screen lays out around its size.
  bool get _paletteExpanded => _paletteController.expanded.value;

  /// The look of the next sticky note: yellow and lined until the user
  /// chooses otherwise, then remembered for the session.
  final ValueNotifier<StickyNoteSettings> _stickySettings =
      ValueNotifier<StickyNoteSettings>(const StickyNoteSettings());

  final ValueNotifier<TextSettings> _textSettings = ValueNotifier<TextSettings>(
    const TextSettings(),
  );

  void _onTextSettingsChanged(TextSettings next) {
    _textSettings.value = next;
    final NoteTextElement? editing = _inkController.editingText;
    _inkController.updateEditingText(
      text: editing == null
          ? null
          : formattedText(
              editing.text,
              from: editing.settings.listStyle,
              to: next.listStyle,
            ),
      settings: next,
    );
  }

  /// A choice in the sticky note options: it sets the look of the next
  /// note, and restyles the note open for writing, as one step of history.
  void _onStickySettingsChanged(StickyNoteSettings next) {
    final StickyNoteSettings previous = _stickySettings.value;
    _stickySettings.value = next;
    final StickyNoteElement? target = _inkController.editingSticky;
    if (target != null) {
      _inkController.setStickyAppearance(
        target.id,
        color: next.color.id == previous.color.id ? null : next.color,
        paper: next.paper == previous.paper ? null : next.paper,
      );
    }
  }

  /// Whether a press on the page is dropped. A press that dismisses a
  /// popover leaves no mark, except for the Sticky note tool's options,
  /// which stay out of the way of placing a note: they close and the press
  /// places it.
  bool _isPageInputBlocked() {
    if (_scrolling || _anyPageBusy()) {
      return true;
    }
    final ToolPaletteController palette = _paletteController;
    if (_tool.value == EditorTool.sticky &&
        palette.stickyMenu.isOpen &&
        !palette.penMenu.isOpen &&
        !palette.eraserMenu.isOpen &&
        !palette.selectMenu.isOpen) {
      palette.stickyMenu.close();
      return false;
    }
    return palette.hasOpenPopover;
  }

  /// A sticky note was placed: the writing tool comes back, in the style
  /// it had, for writing on it straight away.
  void _onStickyPlaced() {
    _paletteController.stickyMenu.close();
    _tool.value = EditorTool.pen;
  }

  ValueNotifier<bool>? _ownedStylusOnly;

  ValueNotifier<bool> get _stylusOnly =>
      widget.stylusOnly ??
      (_ownedStylusOnly ??= ValueNotifier<bool>(InputDefaults.stylusOnly));

  /// Lets a selection be moved from one page onto another.
  final SelectionCarry _selectionCarry = SelectionCarry();

  /// Where on the page Paste is being offered after a hold, if anywhere.
  final ValueNotifier<Offset?> _pastePrompt = ValueNotifier<Offset?>(null);

  /// The high-confidence handwriting result currently chosen in Find.
  final ValueNotifier<_HandwritingFindTarget?> _handwritingFindTarget =
      ValueNotifier<_HandwritingFindTarget?>(null);

  NoteDocument? _ownedDocument;
  late NoteDocument _document = _createDocument();

  late final bool _ownsAudioRecorder = widget.audioRecorder == null;
  late final NoteAudioRecorder _audioRecorder =
      widget.audioRecorder ?? PlatformNoteAudioRecorder();
  late final bool _ownsAudioPlayer = widget.audioPlayer == null;
  late final NoteAudioPlayer _audioPlayer =
      widget.audioPlayer ?? PlatformNoteAudioPlayer();
  final StrokeReplayController _strokeReplay = StrokeReplayController();
  Future<void>? _stoppingRecording;

  InkRecordingContext? _activeRecordingContext() {
    if (!_audioRecorder.isRecording) return null;
    final String? id = _audioRecorder.activeRecordingId;
    return id == null
        ? null
        : InkRecordingContext(
            recordingId: id,
            elapsedMs: _audioRecorder.currentElapsedMs,
          );
  }

  void _syncRecordingContexts() {
    for (final NotePage page in _document.pages) {
      page.ink.recordingContext = _activeRecordingContext;
    }
  }

  /// The page whose ink the screen is listening to.
  InkController? _listenedInk;

  /// The writing area, which a fit page fills and an infinite page grows
  /// from.
  Size _viewportSize = Size.zero;

  /// Whether two fingers are scrolling the page, which blocks new strokes.
  bool _scrolling = false;

  AiClient? _ownedAiClient;
  late final AiAssistantController _ai = AiAssistantController(
    client: widget.aiClient ?? (_ownedAiClient = BackendAiClient()),
    renderer: widget.selectionImageRenderer,
    usageGate: widget.subscription,
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
  final GlobalKey _aiComposerKey = GlobalKey(debugLabel: 'AI composer');

  /// Width the user dragged the panel beside the editor to, or null for
  /// the configured default.
  double? _aiPanelWidth;

  /// Whether the panel's edge is being dragged, so it follows the finger
  /// instead of animating to each new width.
  bool _resizingAiPanel = false;

  /// The panel's width under the finger while its edge is dragged. Only the
  /// panel follows it; the page keeps its layout until the drag ends, so a
  /// drag never lays out the page, its ink and its PDF paper on each frame.
  final ValueNotifier<double> _aiPanelDragWidth = ValueNotifier<double>(0);

  bool _showHandwritingCalibrationNotice = false;
  HandwritingCalibrationState? _handwritingCalibrationState;
  int _handwritingCalibrationLoad = 0;

  PdfPageRenderCache? _pdfCache;
  PageImageCache? _imageCache;
  bool _reportedPageShown = false;

  void _pageShown() {
    if (_reportedPageShown) return;
    _reportedPageShown = true;
    widget.onPageShown?.call();
  }

  int _pdfClipboardGeneration = 0;

  PdfPageRenderCache? get _pageRenderCache {
    final NoteAssetReader? reader = widget.assetReader;
    return reader == null
        ? null
        : (_pdfCache ??= PdfPageRenderCache(
            readAsset: reader,
            rasterizer: widget.pdfRasterizer,
            config: widget.documentIoConfig,
            previewStore: widget.pdfPreviewStore,
          ));
  }

  /// Has the PDF paper of the current page and the pages around it rendered
  /// nearest first: the current page and those next to it sharp, further
  /// ones in preview, so paging through a PDF does not wait on each page.
  void _focusPdfPages(
    List<NotePage> pages,
    List<PageGeometry> geometries,
    double devicePixelRatio,
  ) {
    final PdfPageRenderCache? cache = _pageRenderCache;
    if (cache == null) {
      return;
    }
    final int current = _document.currentIndex;
    final DocumentIoConfig config = widget.documentIoConfig;
    final List<PdfFocusPage> focus = <PdfFocusPage>[];
    int sharpPages = 0;
    for (int step = 0; step <= config.pdfPreloadDistance; step++) {
      for (final int index in <int>{current + step, current - step}) {
        if (index < 0 || index >= pages.length) continue;
        final PdfPageSource? pdf = pages[index].pdfSource;
        if (pdf == null) continue;
        focus.add((source: pdf, displayedSize: geometries[index].displaySize));
        if (step <= config.pdfSharpPreloadDistance) sharpPages++;
      }
    }
    cache.focus(focus, devicePixelRatio, sharpPages: sharpPages);
    // The rest of the note's previews are made ahead, nearest first, for
    // scrolling there later.
    final List<PdfPageSource> rest = <PdfPageSource>[];
    for (int step = 0; step < pages.length; step++) {
      for (final int index in <int>{current + step, current - step}) {
        if (index < 0 || index >= pages.length) continue;
        final PdfPageSource? pdf = pages[index].pdfSource;
        if (pdf != null) rest.add(pdf);
      }
    }
    cache.keepPreviews(rest);
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
    return InkController(selectionConfig: widget.selectionConfig)
      ..recordingContext = _activeRecordingContext;
  }

  Future<void> _startRecording() async {
    if (_strokeReplay.isActive) await _closeReplay();
    _selectionCarry.clearSelection();
    final bool started = await _audioRecorder.start();
    if (!mounted) return;
    if (!started) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Microphone permission is required.')),
      );
      return;
    }
    setState(() {});
  }

  Future<void> _pauseRecording() => _audioRecorder.pause();
  Future<void> _resumeRecording() => _audioRecorder.resume();

  Future<void> finalizeRecording() {
    return _stoppingRecording ??= _stopRecording().whenComplete(() {
      _stoppingRecording = null;
    });
  }

  Future<void> _stopRecording() async {
    final RecordedNoteAudio? recorded = await _audioRecorder.stop();
    if (recorded == null) return;
    try {
      final List<int> bytes = await File(recorded.path).readAsBytes();
      final NoteRepository? repository = widget.repository;
      final String? noteId = widget.noteId;
      final String assetPath = repository != null && noteId != null
          ? await repository.storeAsset(
              noteId,
              Uint8List.fromList(bytes),
              kind: NoteAssetKind.audio,
              extension: 'm4a',
              fileName: '${recorded.id}.m4a',
            )
          : recorded.path;
      final NoteRecordingTrack track = NoteRecordingTrack(
        id: recorded.id,
        title: 'Recording ${_document.recordings.length + 1}',
        assetPath: assetPath,
        durationMs: recorded.duration.inMilliseconds,
        createdAt: recorded.createdAt,
      );
      _document.addRecording(track);
      await _audioPlayer.loadBytes(recorded.id, Uint8List.fromList(bytes));
      _strokeReplay.open(track);
      _rebuildChrome();
      if (mounted) setState(() {});
    } on Object {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text("Couldn't save the recording.")),
        );
      }
    } finally {
      final File temporary = File(recorded.path);
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _openReplay(NoteRecordingTrack track) async {
    try {
      final Uint8List bytes;
      final NoteRepository? repository = widget.repository;
      final String? noteId = widget.noteId;
      if (repository != null && noteId != null) {
        bytes = (await repository.readAsset(noteId, track.assetPath)).bytes;
      } else {
        bytes = await File(track.assetPath).readAsBytes();
      }
      await _audioPlayer.loadBytes(track.id, bytes);
      _selectionCarry.clearSelection();
      _strokeReplay.open(track);
      _refreshChrome();
      if (mounted) setState(() {});
    } on Object {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text("Couldn't open the recording.")),
        );
      }
    }
  }

  Future<void> _closeReplay() async {
    await _audioPlayer.pause();
    _strokeReplay.close();
    _refreshChrome();
    if (mounted) setState(() {});
  }

  /// Removes a recording manifest entry and its private audio asset.
  Future<void> deleteRecording(String recordingId) async {
    final NoteRecordingTrack? removed = _document.removeRecording(recordingId);
    if (removed == null) return;
    if (_strokeReplay.track?.id == recordingId) await _closeReplay();
    final NoteRepository? repository = widget.repository;
    final String? noteId = widget.noteId;
    if (repository != null && noteId != null) {
      await repository.removeAsset(noteId, removed.assetPath);
    }
    _rebuildChrome();
    if (mounted) setState(() {});
  }

  void _onAudioPlayerChanged() {
    if (_strokeReplay.isActive) {
      _strokeReplay.updatePosition(_audioPlayer.position);
    }
  }

  void _seekToStroke(Stroke stroke) {
    final int? completed = stroke.completedAtMs;
    if (completed == null) return;
    _strokeReplay.flash(stroke);
    unawaited(
      _audioPlayer
          .seek(Duration(milliseconds: math.max(0, completed - 500)))
          .then((_) => _audioPlayer.play()),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _audioRecorder.isRecording) {
      unawaited(_audioRecorder.pause());
    }
  }

  void _attachInk(InkController ink) {
    ink.recordingContext = _activeRecordingContext;
    ink.selectionListenable.addListener(_onSelectionChanged);
    ink.activeStrokeListenable.addListener(_onActiveInkChanged);
    ink.completedStrokesListenable.addListener(_growToInk);
    ink.completedStrokesListenable.addListener(_appendPageNearEnd);
    ink.completedStrokesListenable.addListener(_onInkForRecognition);
    ink.addStrokeReplacementListener(_ai.followReplacedStrokes);
    ink.addStrokeReplacementListener(_followRecognizedStrokes);
    final List<(Stroke, String?)> locations = _strokeLocations(ink);
    _knownPageStrokes
      ..clear()
      ..addAll(locations.map(((Stroke, String?) value) => value.$1));
    _listenedInk = ink;
    // Notes saved before schema 5 have no text index. Backfill their pen ink
    // lazily when a real platform recognizer is available.
    final NotePage? page = _pageFor(ink);
    if (page != null &&
        widget.textRecognizer is PlatformCanvasTextRecognizer &&
        page.recognizedWords.isEmpty) {
      _indexingPending.addAll(<(Stroke, String?)>[
        for (final (Stroke stroke, String? stickyId) in locations)
          if (stroke.source == StrokeSource.input &&
              !stroke.style.isHighlighter)
            (stroke, stickyId),
      ]);
      if (_indexingPending.isNotEmpty) {
        _indexingTimer?.cancel();
        _indexingTimer = Timer(
          widget.aiCanvasConfig.recognitionDelay,
          () => _flushHandwritingRecognition(page),
        );
      }
    }
  }

  void _detachInk(InkController ink) {
    ink.selectionListenable.removeListener(_onSelectionChanged);
    ink.activeStrokeListenable.removeListener(_onActiveInkChanged);
    ink.completedStrokesListenable.removeListener(_growToInk);
    ink.completedStrokesListenable.removeListener(_appendPageNearEnd);
    ink.completedStrokesListenable.removeListener(_onInkForRecognition);
    ink.removeStrokeReplacementListener(_ai.followReplacedStrokes);
    ink.removeStrokeReplacementListener(_followRecognizedStrokes);
  }

  NotePage? _pageFor(InkController ink) {
    for (final NotePage page in _document.pages) {
      if (identical(page.ink, ink)) return page;
    }
    return null;
  }

  List<(Stroke, String?)> _strokeLocations(InkController ink) =>
      <(Stroke, String?)>[
        for (final Stroke stroke in ink.strokes) (stroke, null),
        for (final StickyNoteElement note in ink.stickyNotes)
          for (final Stroke stroke in note.strokes) (stroke, note.id),
      ];

  void _followRecognizedStrokes(Map<Stroke, Stroke> replacements) {
    final NotePage? page = _pageFor(_inkController);
    if (page != null) {
      _document.reconcileRecognizedWords(page, replacements: replacements);
    }
  }

  void _onInkForRecognition() {
    _handwritingFindTarget.value = null;
    final InkController ink = _inkController;
    final NotePage? page = _pageFor(ink);
    if (page == null) return;
    _document.reconcileRecognizedWords(page);
    final List<(Stroke, String?)> locations = _strokeLocations(ink);
    final List<(Stroke, String?)> additions = <(Stroke, String?)>[
      for (final (Stroke stroke, String? stickyId) in locations)
        if (!_knownPageStrokes.contains(stroke) &&
            stroke.source == StrokeSource.input &&
            !stroke.style.isHighlighter)
          (stroke, stickyId),
    ];
    _knownPageStrokes
      ..clear()
      ..addAll(locations.map(((Stroke, String?) value) => value.$1));
    if (additions.isEmpty) return;
    _indexingPending.addAll(additions);
    _indexingTimer?.cancel();
    _indexingTimer = Timer(
      widget.aiCanvasConfig.recognitionDelay,
      () => _flushHandwritingRecognition(page),
    );
  }

  void _flushHandwritingRecognition(NotePage page) {
    _indexingTimer?.cancel();
    _indexingTimer = null;
    if (_indexingPending.isEmpty) return;
    final List<(Stroke, String?)> locations = _strokeLocations(page.ink);
    final Set<Stroke> present = Set<Stroke>.identity()
      ..addAll(locations.map(((Stroke, String?) value) => value.$1));
    final List<(Stroke, String?)> pending = <(Stroke, String?)>[
      for (final (Stroke stroke, String? stickyId) in _indexingPending)
        if (present.contains(stroke)) (stroke, stickyId),
    ];
    _indexingPending.clear();
    if (pending.isEmpty) return;
    final int generation = _indexingGeneration;
    final String prior = _document.recognizedWords
        .where((RecognizedInkWord word) => word.isSearchable)
        .map((RecognizedInkWord word) => word.text)
        .join(' ');
    unawaited(() async {
      final List<RecognizedInkWord> words = <RecognizedInkWord>[];
      for (final String? stickyId
          in pending.map(((Stroke, String?) value) => value.$2).toSet()) {
        words.addAll(
          await _handwritingIndexer.recognize(
            <Stroke>[
              for (final (Stroke stroke, String? source) in pending)
                if (source == stickyId) stroke,
            ],
            context: HandwritingContext(draft: prior),
            stickyId: stickyId,
          ),
        );
      }
      if (!mounted || generation != _indexingGeneration) return;
      for (final RecognizedInkWord word in words) {
        final Set<Stroke> stillPresent = Set<Stroke>.identity()
          ..addAll(
            _strokeLocations(page.ink)
                .where(((Stroke, String?) value) => value.$2 == word.stickyId)
                .map(((Stroke, String?) value) => value.$1),
          );
        if (word.sourceStrokes.every(stillPresent.contains)) {
          _document.addRecognizedWord(page, word);
        }
      }
    }());
  }

  /// A page was added, removed, or shown, or its setup changed. Leaving a
  /// page ends its gesture and drops its selection; the clipboard comes
  /// along.
  void _onDocumentChanged() {
    _syncRecordingContexts();
    final InkController next = _inkController;
    final InkController? previous = _listenedInk;
    if (!identical(next, previous)) {
      if (previous != null) {
        final NotePage? previousPage = _pageFor(previous);
        if (previousPage != null) _flushHandwritingRecognition(previousPage);
        _detachInk(previous);
        final bool stillThere = _document.pages.any(
          (NotePage page) => identical(page.ink, previous),
        );
        if (stillThere) {
          if (!_selectionCarry.sharesSelection(previous, next)) {
            _selectionCarry.clearSelection(except: next);
            previous.finalizeActiveGesture();
            previous.clearSelection();
          }
          previous.exitStickyEditing();
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
    for (final StickyNoteElement note in _inkController.stickyNotes) {
      reach = reach?.expandToInclude(note.bounds) ?? note.bounds;
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
    for (final int pointer in pointers) {
      _aiInput.cancel(pointer);
      _selectionCarry.cancelPointer(pointer);
    }
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
    if (index < 0 || index >= pages.length) {
      return;
    }
    final InkController target = pages[index].ink;
    for (int i = 0; i < pages.length; i++) {
      if (i != index &&
          pages[i].ink.isBusy &&
          !_selectionCarry.sharesSelection(pages[i].ink, target)) {
        return;
      }
    }
    _document.goTo(index);
  }

  void _onScrollEnd() {
    _scrolling = false;
  }

  /// The column was pulled up past its last page: a new page goes after
  /// it, below, and the view stays where it is.
  void _addPageAtEnd() {
    if (_anyPageBusy()) {
      return;
    }
    _document.appendPage();
  }

  /// Writing down into the last page past [PageConfig.appendPageAt] of its
  /// height adds an empty page after it. The view does not move: scrolling
  /// on finds the new page waiting, with no pull to make. An infinite page
  /// grows instead.
  void _appendPageNearEnd() {
    if (_document.currentIndex != _document.pageCount - 1 ||
        _viewportSize.isEmpty) {
      return;
    }
    final NotePage page = _document.current;
    if (page.setup.size == PageSize.infinite) {
      return;
    }
    final double height = PageGeometry.of(
      page.setup,
      page.extent,
      _viewportSize,
      pdfPageSize: page.pdfSource?.pageSize,
    ).pageSize.height;
    double lowest = double.negativeInfinity;
    for (final Stroke stroke in page.ink.strokes) {
      lowest = math.max(lowest, stroke.bounds.bottom);
    }
    for (final StickyNoteElement note in page.ink.stickyNotes) {
      lowest = math.max(lowest, note.bounds.bottom);
    }
    if (lowest >= height * widget.pageConfig.appendPageAt) {
      _document.appendPage();
    }
  }

  /// Whether the page overview hangs under the top-left card.
  late final ValueNotifier<bool> _pageOverviewOpen = ValueNotifier<bool>(false)
    // Over the page, it takes the pen from the native layer, as a popover
    // does.
    ..addListener(_paletteController.popoverChanged.notify);

  void _togglePageOverview() {
    _pageOverviewOpen.value = !_pageOverviewOpen.value;
  }

  Future<void> _openPageSettings() {
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
    }
    // A picture takes its whole box, so only where it is matters.
    for (final NoteImageElement element in controller.images) {
      bitmaps.add(
        SnapshotBitmap(
          bytes: Uint8List(0),
          bounds: Rect.fromCenter(
            center: Offset(element.center.x, element.center.y),
            width: element.size.width,
            height: element.size.height,
          ),
          rotation: element.rotation,
        ),
      );
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
        stickies: controller.stickyNotes,
        aiNotes: _ai.notationStrokesIn(controller.strokes),
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
    if (notation.vector case final vector?) {
      return _applySvgNotation(vector, requestContext);
    }
    final AiStickySize? sticky = notation.sticky;
    if (sticky != null) {
      return _applyStickyNotation(notation, sticky, requestContext);
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
    // The assistant never writes over its own earlier notes.
    final NotationClearance clearance = NotationClearance(
      pageSize: requestContext.logicalSize,
      earlierNotes: <SpaceStroke>[
        for (final Stroke stroke in _ai.notationStrokesIn(controller.strokes))
          (points: stroke.points, width: stroke.style.width),
      ],
    );
    try {
      final HandwritingSampleLibrary handwriting = HandwritingSampleLibrary(
        _document.recognizedWords,
        calibration: HandwritingCalibration.current.value,
      );
      traces = timeline == null
          ? layoutNotation(
              notation,
              requestContext.logicalSize,
              snapper: snapper,
              clearance: clearance,
              handwriting: handwriting,
            )
          : layoutTimedNotation(
              notation,
              requestContext.logicalSize,
              snapper: snapper,
              clearance: clearance,
              handwriting: handwriting,
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
    // A notation is appended whole, one stroke per trace. While the notes
    // are hidden, it arrives hidden, as the rest of them are.
    List<Stroke> added() {
      final List<Stroke> strokes = controller.strokes.sublist(
        controller.strokes.length - traces.length,
      );
      if (!_showAiNotes) {
        controller.setStrokesHidden(strokes, true);
      }
      return strokes;
    }

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

  AiNotationApplication _applySvgNotation(
    EditableSvg vector,
    NoteImage requestContext,
  ) {
    final InkController controller = _inkController;
    if (controller.documentRevision != requestContext.revision) {
      return const AiNotationApplication(AiNotationStatus.notAppliedStale);
    }
    if (controller.isBusy) {
      return const AiNotationApplication(AiNotationStatus.notAppliedBusy);
    }
    final Rect page = Offset.zero & requestContext.logicalSize;
    final Rect viewBox = vector.viewBox;
    final Rect bounds = vector.contentBounds;
    const double tolerance = 0.01;
    if ((viewBox.left).abs() > tolerance ||
        (viewBox.top).abs() > tolerance ||
        (viewBox.width - page.width).abs() > tolerance ||
        (viewBox.height - page.height).abs() > tolerance ||
        !page.inflate(tolerance).contains(bounds.topLeft) ||
        !page.inflate(tolerance).contains(bounds.bottomRight) ||
        bounds.isEmpty) {
      return const AiNotationApplication(AiNotationStatus.notAppliedInvalid);
    }
    final StrokeStyle userPenStyle = _penSettings.value.strokeStyle();
    final EditableSvg styled;
    try {
      styled = SvgNotationStyler.apply(
        vector,
        handwriting:
            HandwritingCalibration.current.value ?? HandwritingStyle.standard,
        defaultInk: userPenStyle.ink,
        penWidth: userPenStyle.width,
        snapper: InkSnapper(<List<InkVector>>[
          for (final Stroke stroke in controller.strokes) stroke.points,
        ], reach: const AiNotationConfig().inkSnapDistance),
        maxTextSize: HandwritingCalibration.textSize.value.max,
      );
    } on FormatException {
      return const AiNotationApplication(AiNotationStatus.notAppliedInvalid);
    }
    final SvgInkConversion conversion;
    try {
      conversion = SvgInkConverter.convert(
        styled,
        defaultInk: userPenStyle.ink,
        defaultWidth: userPenStyle.width,
        animate:
            controller.svgAnimationsEnabled &&
            !MediaQuery.disableAnimationsOf(context),
      );
    } on FormatException {
      return const AiNotationApplication(AiNotationStatus.notAppliedInvalid);
    }
    final AddNotationResult result = controller.addAiNotation(
      traces: conversion.traces,
      expectedRevision: requestContext.revision,
      surfaceSize: requestContext.logicalSize,
      playbackDuration: conversion.playbackDuration,
      limits: const GeneratedInkLimits(
        maxPointsPerTrace: 8192,
        maxTotalPoints: 250000,
        maxPlaybackDuration: Duration(seconds: 20),
      ),
    );
    List<Stroke> added() {
      final List<Stroke> strokes = controller.strokes.sublist(
        controller.strokes.length - conversion.traces.length,
      );
      if (!_showAiNotes) controller.setStrokesHidden(strokes, true);
      return strokes;
    }

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

  /// The paper of the assistant's sticky notes, told apart from the user's
  /// yellow ones.
  static const String _aiStickyColor = 'blue';

  /// Adds [notation] on a new sticky note of [size], for a note with no
  /// room left to draw on. It goes where the request's measured free space
  /// says it covers least, beside the selection, shrunk if the page is
  /// too small. It is drawn at once: a sticky note's ink has no playback.
  AiNotationApplication _applyStickyNotation(
    AiNotation notation,
    AiStickySize size,
    NoteImage requestContext,
  ) {
    final InkController controller = _inkController;
    final Size pageSize = requestContext.logicalSize;
    final Size wanted = Size(size.width, size.height);
    final Rect? focus = requestContext.normalizedFocusBounds;
    // Measured now when the capture was not: the revision is checked, so
    // the page is as it was.
    final NoteFreeSpace space =
        requestContext.space ??
        NoteFreeSpace.measure(
          pageSize: pageSize,
          strokes: <SpaceStroke>[
            for (final Stroke stroke in controller.strokes)
              (points: stroke.points, width: stroke.style.width),
          ],
          blocks: <Rect>[
            for (final StickyNoteElement note in controller.stickyNotes)
              note.bounds,
          ],
          focus: focus == null
              ? null
              : Rect.fromLTRB(
                  focus.left * pageSize.width,
                  focus.top * pageSize.height,
                  focus.right * pageSize.width,
                  focus.bottom * pageSize.height,
                ),
        );
    final Rect placed = space.placeSticky(wanted);
    // Laid out inside the paper's padding, in the note's own units.
    final double padding = controller.stickyConfig.contentPadding;
    final Size inner = Size(
      math.max(1, wanted.width - 2 * padding),
      math.max(1, wanted.height - 2 * padding),
    );
    final List<GeneratedInkTrace> traces;
    try {
      final HandwritingSampleLibrary handwriting = HandwritingSampleLibrary(
        _document.recognizedWords,
        calibration: HandwritingCalibration.current.value,
      );
      traces = <GeneratedInkTrace>[
        for (final GeneratedInkTrace trace in layoutNotation(
          notation,
          inner,
          handwriting: handwriting,
        ))
          GeneratedInkTrace(
            style: trace.style,
            points: <InkVector>[
              for (final InkVector point in trace.points)
                InkVector(point.x + padding, point.y + padding),
            ],
            widths: trace.widths,
          ),
      ];
    } on FormatException {
      return const AiNotationApplication(AiNotationStatus.notAppliedInvalid);
    }
    final List<Stroke>? strokes = controller.generatedStickyStrokes(
      traces,
      wanted,
    );
    if (strokes == null) {
      return const AiNotationApplication(AiNotationStatus.notAppliedInvalid);
    }
    // Shrunk only on a page too small for it; otherwise exactly its size.
    final double ratio = placed.width / wanted.width;
    final double scale = (ratio - 1).abs() < 1e-6 ? 1 : ratio;
    final AddNotationResult result = controller.addAiStickyNote(
      note: StickyNoteElement(
        id: StickyNoteElement.newId(),
        center: InkVector(placed.center.dx, placed.center.dy),
        size: wanted * scale,
        scale: scale,
        colorId: _aiStickyColor,
        paper: StickyPaperStyle.blank,
        strokes: strokes,
      ),
      expectedRevision: requestContext.revision,
      surfaceSize: pageSize,
    );
    return switch (result) {
      AddNotationResult.added || AddNotationResult.addedWithPlayback =>
        const AiNotationApplication(AiNotationStatus.applied),
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
      _selectionCarry.clearSelection(except: _inkController);
      _inkController.paste();
    }
  }

  void _undo() {
    _pastePrompt.value = null;
    _document.undo();
  }

  OverlayEntry? _findEntry;

  /// Where the user has dragged the find panel from its resting spot.
  final ValueNotifier<Offset> _findDrag = ValueNotifier<Offset>(Offset.zero);

  void _closeHandwritingFind() {
    _findEntry?.remove();
    _findEntry = null;
    _handwritingFindTarget.value = null;
  }

  /// Floats the find panel over the note without a barrier, so the page
  /// stays scrollable while searching; the find button toggles it.
  void _openHandwritingFind(Rect anchor) {
    if (_findEntry != null) {
      _closeHandwritingFind();
      return;
    }
    _handwritingFindTarget.value = null;
    _findDrag.value = Offset.zero;
    _findEntry = OverlayEntry(
      builder: (BuildContext context) {
        final Size screen = MediaQuery.sizeOf(context);
        final double width = math.min(340, screen.width - 16);
        final double left = (anchor.right - width).clamp(
          8,
          math.max(8, screen.width - width - 8),
        );
        return ValueListenableBuilder<Offset>(
          valueListenable: _findDrag,
          builder: (BuildContext context, Offset drag, Widget? child) {
            return Stack(
              children: <Widget>[
                Positioned(
                  left: (left + drag.dx).clamp(
                    8,
                    math.max(8, screen.width - width - 8),
                  ),
                  top: (anchor.bottom + 6 + drag.dy).clamp(
                    8,
                    math.max(8, screen.height - 120),
                  ),
                  width: width,
                  child: child!,
                ),
              ],
            );
          },
          child: _HandwritingFindDialog(
            document: _document,
            recognizer: widget.textRecognizer,
            renderer: widget.handwritingRenderer,
            onDrag: (Offset delta) => _findDrag.value += delta,
            onTargetChanged: (_HandwritingFindTarget? target) {
              if (mounted) _handwritingFindTarget.value = target;
            },
          ),
        );
      },
    );
    Overlay.of(context).insert(_findEntry!);
  }

  void _redo() {
    _pastePrompt.value = null;
    _document.redo();
  }

  /// Pastes with the copies centered where the pointer was held.
  void _pasteAt(Offset position) {
    _pastePrompt.value = null;
    _selectionCarry.clearSelection(except: _inkController);
    _inkController.paste(at: InkVector(position.dx, position.dy));
  }

  void _copy() {
    final InkSelection? selection = _stableSelection();
    if (selection?.includesPdf == true) {
      unawaited(_copyPdfSelection(selection!, cut: false));
      return;
    }
    _pdfClipboardGeneration++;
    if (_selectionCarry.copySelection(_inkController)) {
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
    if (_selectionCarry.cutSelection(_inkController)) {
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
    AppHaptics.error();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('This PDF selection could not be copied.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Opens the assistant on the current selection, if there is one, from the
  /// selection's AI button or the palette's, and turns AI mode on with it.
  /// Nothing is sent.
  void _openAi() {
    final bool hadSelection = _stableSelection() != null;
    _setAiActive(true, openChat: !hadSelection);
    if (hadSelection) {
      // The chat opens on the selection once it is captured, and opens
      // anyway if the capture comes to nothing.
      unawaited(
        _captureForAi(open: true).whenComplete(() {
          if (mounted && _aiActive.value) _ai.show();
        }),
      );
    }
  }

  /// Turns AI mode on or off. On, the assistant's notes show and the chat
  /// opens when [openChat] says; off, the chat closes and the notes hide
  /// unless Show notes in chat is on.
  void _setAiActive(bool active, {bool openChat = true}) {
    if (active) {
      _aiActive.value = true;
      _setAiNotesHidden(!_showAiNotes);
      if (_tool.value != EditorTool.ai) {
        _tool.value = EditorTool.ai;
      }
      if (openChat) {
        _ai.show();
      }
      return;
    }
    if (!_aiActive.value) {
      return;
    }
    _aiActive.value = false;
    _setAiNotesHidden(!_showAiNotes);
    if (_ai.isOpen) {
      _ai.close();
      // The panel takes its text field with it.
      _editorFocus.requestFocus();
    }
    if (_tool.value == EditorTool.ai) {
      _tool.value = _writingTool;
    }
  }

  /// Keeps track of the tool AI mode gives back.
  void _onToolChanged() {
    final EditorTool tool = _tool.value;
    if (tool != EditorTool.ai) {
      _writingTool = tool;
    }
  }

  /// A press anywhere in the chat, on its text or its composer, takes up the
  /// AI tool, so no other tool stays on beside it.
  void _selectAiTool() {
    if (_aiActive.value && _tool.value != EditorTool.ai) {
      _tool.value = EditorTool.ai;
    }
  }

  /// Whether the assistant's notes show now: always if Show notes in chat is
  /// on; otherwise only while AI mode is active.
  bool get _showAiNotes => _ai.showNotesInChat || _aiActive.value;

  /// Shows or hides every AI-generated stroke, on every page.
  void _setAiNotesHidden(bool hidden) {
    for (final NotePage page in _document.pages) {
      final List<Stroke> notes = _ai
          .notationStrokesIn(page.ink.strokes)
          .toList(growable: false);
      if (notes.isNotEmpty) {
        page.ink.setStrokesHidden(notes, hidden);
      }
    }
  }

  /// Switches to the current selection, resuming a matching conversation.
  void _useCurrentSelection() => unawaited(_captureForAi(open: false));

  /// Adds the current selection to the open conversation's ink.
  Future<void> _addSelectionToAi() async {
    final InkSelection? selection = _stableSelection();
    if (selection == null) return;
    final InkController page = _inkController;
    final List<SnapshotBitmap> bitmaps = await _selectionBitmaps(selection);
    if (!mounted || !identical(selection, _stableSelection())) return;
    _ai.addToContext(selection, bitmaps: bitmaps, page: page);
  }

  /// Hands [capture] the selection and the page's look, unless a gesture is
  /// still reshaping the selection or nothing is selected.
  ///
  /// With [ask], a chat already open is kept, and offers the selection as
  /// more context or as a chat of its own.
  Future<void> _captureForAi({required bool open, bool ask = false}) async {
    final InkSelection? selection = _stableSelection();
    if (selection == null) return;
    final InkController page = _inkController;
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
        page: page,
        ask: ask,
      );
    } else {
      _ai.useSelection(
        selection,
        brightness: brightness,
        background: background,
        snapshot: snapshot,
        page: page,
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

  /// A loop drawn in AI mode around something on the page: what it
  /// encloses is selected and becomes what the assistant is asked about.
  void _onAiCircle(List<InkVector> outline, Object page) {
    if (!mounted || !identical(page, _inkController)) return;
    final PdfPageSource? pdf = _document.current.pdfSource;
    final bool selected = _inkController.selectEnclosed(
      outline,
      selectablePdfBounds: pdf == null ? null : Offset.zero & pdf.pageSize,
    );
    if (selected) unawaited(_captureForAi(open: true));
  }

  /// Closing the chat turns AI mode off with it.
  void _closeAi() => _setAiActive(false);

  Future<void> _openSettings() {
    return showEditorSettings(
      context,
      builder: (BuildContext context) {
        return EditorSettingsSheet(
          controller: _ai,
          stylusOnly: _stylusOnly,
          textSize: HandwritingCalibration.textSize,
          onTextSizeChanged: _setAiTextSize,
          onChooseHandwriting: widget.handwritingProfileStore == null
              ? null
              : () {
                  Navigator.of(context).pop();
                  _calibrateHandwritingFromChat();
                },
          onExportPdf: _canUseDocumentIo
              ? () {
                  Navigator.of(context).pop();
                  _exportPdf();
                }
              : null,
          onExportSvg: _canUseDocumentIo
              ? () {
                  Navigator.of(context).pop();
                  _exportSvg();
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
    AppHaptics.error();
    final String message = error is DocumentImportException
        ? error.message
        : 'The document operation could not be completed.';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _insertPdf() async {
    _documentIoPending++;
    try {
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
      _onIoFinished(result);
    } finally {
      _documentIoPending--;
    }
  }

  Future<void> _insertImage(DocumentImageSource source) async {
    _documentIoPending++;
    try {
      final PickedDocument? picked = await widget.documentPicker.pickImage(
        source,
      );
      if (picked == null || !mounted) return;
      await _importer.insertImage(
        repository: widget.repository!,
        noteId: widget.noteId!,
        controller: _inkController,
        picked: picked,
        visiblePage: Offset.zero & _surfaceSize,
      );
      _tool.value = EditorTool.select;
      AppHaptics.success();
    } on Object catch (error) {
      if (mounted) _showIoError(error);
    } finally {
      _documentIoPending--;
    }
  }

  Future<void> _insertSvg() async {
    if (widget.documentPicker is! SvgDocumentPicker) return;
    final SvgDocumentPicker picker = widget.documentPicker as SvgDocumentPicker;
    _documentIoPending++;
    try {
      final PickedDocument? picked = await picker.pickSvg();
      if (picked == null || !mounted) return;
      await _importer.insertSvg(
        controller: _inkController,
        picked: picked,
        visiblePage: Offset.zero & _surfaceSize,
      );
      _tool.value = EditorTool.select;
      AppHaptics.success();
    } on Object catch (error) {
      if (mounted) _showIoError(error);
    } finally {
      _documentIoPending--;
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
    _onIoFinished(result);
    if (!result.cancelled && result.error == null) {
      unawaited(
        widget.subscription?.backend?.trackProductEvent(
          'note_exported',
          detail: 'pdf',
        ),
      );
    }
  }

  Future<void> _exportSvg() async {
    _documentIoPending++;
    try {
      _inkController.finalizeActiveGesture();
      _inkController.finishNotationPlayback();
      await SvgExporter(sink: widget.exportSink).exportAndShare(
        title: widget.title,
        pageSize: _surfaceSize,
        controller: _inkController,
        brightness: Theme.of(context).brightness,
      );
      unawaited(
        widget.subscription?.backend?.trackProductEvent(
          'note_exported',
          detail: 'svg',
        ),
      );
      if (mounted) AppHaptics.success();
    } on Object catch (error) {
      if (mounted) _showIoError(error);
    } finally {
      _documentIoPending--;
    }
  }

  void _onIoFinished(DocumentIoProgressResult result) {
    if (result.cancelled) return;
    if (result.error case final Object error) {
      _showIoError(error);
    } else {
      AppHaptics.success();
    }
  }

  /// The selection, or null while a lasso or a transform is under way.
  InkSelection? _stableSelection() {
    return _selectionCarry.combinedSelectionFor(_inkController);
  }

  void _onSelectionChanged() {
    final InkController controller = _inkController;
    if (controller.activeLasso == null &&
        controller.activeTransform == null &&
        !_selectionCarry.isGesturing) {
      _ai.updateCurrentSelection(
        _selectionCarry.combinedSelectionFor(controller),
      );
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

  /// Turning Animation off stops every notation still looping on the note,
  /// and the notes follow Show notes in chat as soon as it changes.
  void _onAiChanged() {
    _inkController.setSvgAnimationsEnabled(_ai.animationEnabled);
    if (!_ai.animationEnabled) {
      _inkController.finishNotationPlayback();
    }
    if (_ai.showNotesInChat != _aiNotesInChatSeen) {
      _aiNotesInChatSeen = _ai.showNotesInChat;
      _setAiNotesHidden(!_showAiNotes);
    }
    final AiRequestState state = _ai.requestState;
    if (_aiRequestState == AiRequestState.sending &&
        state != AiRequestState.sending) {
      if (state == AiRequestState.failed) {
        AppHaptics.error();
      } else if (_ai.messages.lastOrNull?.role == AiRole.model) {
        AppHaptics.success();
      }
    }
    _aiRequestState = state;
  }

  /// The request state last seen, to feel when an answer lands or fails.
  AiRequestState _aiRequestState = AiRequestState.idle;

  /// Show notes in chat as last seen, to act only when it changes.
  late bool _aiNotesInChatSeen = _ai.showNotesInChat;

  /// The system is low on memory: rendered PDF pages and decoded pictures
  /// not on screen go, to be made again when shown.
  void _releaseMemory() {
    _pdfCache?.releaseMemory();
    _imageCache?.releaseMemory();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _audioPlayer.addListener(_onAudioPlayerChanged);
    _syncRecordingContexts();
    MemoryPressure.instance.addListener(_releaseMemory);
    // Reading and parsing the PDF is most of the wait for its first page, so
    // it starts now rather than when the first page asks to be drawn.
    final PdfPageSource? firstPdf = _document.current.pdfSource;
    if (firstPdf != null) _pageRenderCache?.warm(firstPdf);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // PDF paper reports itself once rendered.
      if (mounted &&
          (_document.current.pdfSource == null || _pageRenderCache == null)) {
        _pageShown();
      }
    });
    _attachInk(_inkController);
    _selectionCarry.addListener(_onSelectionChanged);
    _document.addListener(_onDocumentChanged);
    _ai.addListener(_onAiChanged);
    _palettePlacement.addListener(_onPalettePlacementChanged);
    _paletteController.expanded.addListener(_onPalettePlacementChanged);
    _tool.addListener(AppHaptics.toolSwitch);
    _tool.addListener(_onToolChanged);
    _adoptAiSession();
    _loadHandwritingCalibrationNotice();
    if (_aiActive.value) {
      _tool.value = EditorTool.ai;
      _ai.show();
    }
    _setAiNotesHidden(!_showAiNotes);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final EditorChromeScope? scope = EditorChromeScope.maybeOf(context);
    if (scope != _chromeScope) {
      _retractChrome();
      _chromeScope = scope;
    }
  }

  void _retractChrome() {
    final EditorChromeScope? scope = _chromeScope;
    final EditorChromeEntry? entry = _chromeEntry;
    _chromeEntry = null;
    if (scope == null || entry == null) return;
    // The bar is laid out again by this; not while the tree is torn down.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => scope.host.retract(scope.noteId, entry),
    );
  }

  void _onPalettePlacementChanged() => setState(() {});

  void _onPaletteDragStart(Offset center) {
    _paletteController.closeAll();
    _paletteDragCenter.value = center;
  }

  void _onPaletteDragUpdate(Offset delta) {
    final Offset? center = _paletteDragCenter.value;
    if (center != null) {
      _paletteDragCenter.value = center + delta;
    }
  }

  /// Docks the palette against the edge nearest where it was let go:
  /// there along it, or at its middle when let go near that.
  void _onPaletteDragEnd() {
    final Offset? center = _paletteDragCenter.value;
    if (center == null) {
      return;
    }
    final double margin = EditorLayout.marginFor(
      WindowSizeClass.fromWidth(MediaQuery.sizeOf(context).width),
    );
    _palettePlacement.value = PalettePlacement.nearest(
      _paletteRegion,
      center,
      margin,
      expanded: _paletteExpanded,
    );
    // Commit the dock while the drag position still owns the visual origin.
    // Releasing it afterwards lets AnimatedPositioned ease from the exact
    // drop point to the committed edge without an intermediate jump.
    _paletteDragCenter.value = null;
  }

  void _movePaletteTo(PaletteEdge edge) {
    _palettePlacement.value = PalettePlacement(edge: edge);
  }

  @override
  void didUpdateWidget(EditorScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ai.usageGate = widget.subscription;
    if (oldWidget.handwritingProfileStore != widget.handwritingProfileStore) {
      _loadHandwritingCalibrationNotice();
    }
    if (oldWidget.palettePlacement != widget.palettePlacement) {
      (oldWidget.palettePlacement ?? _ownedPalettePlacement)?.removeListener(
        _onPalettePlacementChanged,
      );
      _palettePlacement.addListener(_onPalettePlacementChanged);
    }
    if (oldWidget.assetReader != widget.assetReader ||
        oldWidget.pdfRasterizer != widget.pdfRasterizer ||
        oldWidget.documentIoConfig != widget.documentIoConfig) {
      _pdfCache?.clear();
      _pdfCache = null;
      _imageCache?.clear();
      _imageCache = null;
    }
    if (oldWidget.document != widget.document ||
        oldWidget.inkController != widget.inkController) {
      _indexingGeneration++;
      _indexingTimer?.cancel();
      _indexingPending.clear();
      _handwritingFindTarget.value = null;
      _releaseAiSession();
      _document.removeListener(_onDocumentChanged);
      final NoteDocument? owned = _ownedDocument;
      _ownedDocument = null;
      _document = _createDocument();
      _document.addListener(_onDocumentChanged);
      _adoptAiSession();
      _aiInput.clear();
      _setAiNotesHidden(!_showAiNotes);
      _onDocumentChanged();
      owned?.dispose();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _audioPlayer.removeListener(_onAudioPlayerChanged);
    _strokeReplay.dispose();
    _aiPanelDragWidth.dispose();
    if (_ownsAudioRecorder) {
      if (_audioRecorder.state == NoteAudioRecorderState.idle) {
        _audioRecorder.dispose();
      } else {
        unawaited(_audioRecorder.stop().whenComplete(_audioRecorder.dispose));
      }
    }
    if (_ownsAudioPlayer) _audioPlayer.dispose();
    _findEntry?.remove();
    _findEntry = null;
    _findDrag.dispose();
    _retractChrome();
    _indexingGeneration++;
    _indexingTimer?.cancel();
    final InkController? listened = _listenedInk;
    if (listened != null) {
      _detachInk(listened);
    }
    _selectionCarry
      ..removeListener(_onSelectionChanged)
      ..dispose();
    _releaseAiSession();
    _document.removeListener(_onDocumentChanged);
    _ai.removeListener(_onAiChanged);
    _palettePlacement.removeListener(_onPalettePlacementChanged);
    _paletteController.expanded
      ..removeListener(_onPalettePlacementChanged)
      ..dispose();
    _ruler.dispose();
    _ai.dispose();
    _ownedAiClient?.close();
    _editorFocus.dispose();
    _ownedDocument?.dispose();
    _tool
      ..removeListener(AppHaptics.toolSwitch)
      ..removeListener(_onToolChanged)
      ..dispose();
    _aiInput.dispose();
    _aiActive.dispose();
    _ownedPenSettings?.dispose();
    _ownedPalettePlacement?.dispose();
    _paletteDragCenter.dispose();
    _eraserSettings.dispose();
    _stickySettings.dispose();
    _textSettings.dispose();
    _pageOverviewOpen.dispose();
    _pastePrompt.dispose();
    _handwritingFindTarget.dispose();
    _ownedStylusOnly?.dispose();
    MemoryPressure.instance.removeListener(_releaseMemory);
    _pdfCache?.clear();
    _imageCache?.clear();
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
    return FocusScope(
      onFocusChange: (bool focused) {
        // Not mid-stroke: a press on the page drops the composer's focus
        // into this scope, which must not take the pen away.
        if (focused && !_inkController.isBusy) _selectAiTool();
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (PointerDownEvent _) => _selectAiTool(),
        child: _buildAssistantPanel(),
      ),
    );
  }

  Widget _buildAssistantPanel() {
    return AiAssistantPanel(
      key: _aiPanelKey,
      controller: _ai,
      config: widget.aiLayoutConfig,
      onClose: _closeAi,
      onNewChat: _useCurrentSelection,
      onAddToContext: _addSelectionToAi,
      composerKey: _aiComposerKey,
      onOpenPlans: widget.subscription == null ? null : _openPlans,
      showHandwritingCalibrationNotice: _showHandwritingCalibrationNotice,
      onCalibrateHandwriting: _calibrateHandwritingFromChat,
      onDismissHandwritingCalibrationNotice:
          _dismissHandwritingCalibrationNotice,
    );
  }

  Future<void> _loadHandwritingCalibrationNotice() async {
    final int load = ++_handwritingCalibrationLoad;
    final HandwritingProfileStore? store = widget.handwritingProfileStore;
    final HandwritingCalibrationState? state = await store?.read();
    if (!mounted || load != _handwritingCalibrationLoad) return;
    _handwritingCalibrationState = state;
    final bool show =
        store != null &&
        state?.style == null &&
        !(state?.chatReminderDismissed ?? false);
    if (_showHandwritingCalibrationNotice != show) {
      setState(() => _showHandwritingCalibrationNotice = show);
    }
  }

  Future<void> _calibrateHandwritingFromChat() async {
    final HandwritingProfileStore? store = widget.handwritingProfileStore;
    if (store == null) return;
    await showHandwritingCalibration(context, store: store);
    if (mounted) await _loadHandwritingCalibrationNotice();
  }

  /// Writes the assistant's text [size] from now on, and keeps it.
  Future<void> _setAiTextSize(AiTextSize size) async {
    HandwritingCalibration.textSize.value = size;
    final HandwritingProfileStore? store = widget.handwritingProfileStore;
    if (store == null) return;
    try {
      final HandwritingCalibrationState saved =
          await store.read() ?? const HandwritingCalibrationState();
      await store.write(saved.copyWith(textSize: size));
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text("Couldn't save that preference.")),
      );
    }
  }

  Future<void> _dismissHandwritingCalibrationNotice() async {
    final HandwritingProfileStore? store = widget.handwritingProfileStore;
    if (store == null) return;
    ++_handwritingCalibrationLoad;
    final HandwritingCalibrationState? previous = _handwritingCalibrationState;
    final HandwritingCalibrationState dismissed =
        (previous ?? const HandwritingCalibrationState()).copyWith(
          chatReminderDismissed: true,
        );
    _handwritingCalibrationState = dismissed;
    setState(() => _showHandwritingCalibrationNotice = false);
    try {
      await store.write(dismissed);
    } on Object {
      if (!mounted) return;
      _handwritingCalibrationState = previous;
      setState(() => _showHandwritingCalibrationNotice = true);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text("Couldn't save that preference.")),
      );
    }
  }

  void _openPlans() {
    final SubscriptionController? subscription = widget.subscription;
    if (subscription != null) {
      showPaymentPage(context, subscription);
    }
  }

  void _startAiPanelResize(double width) {
    _aiPanelDragWidth.value = width;
    setState(() {
      _resizingAiPanel = true;
      _aiPanelWidth = width;
    });
  }

  /// Widens the dragged panel by [delta], within what the config allows and
  /// what an editor [available] pixels wide can spare.
  void _resizeAiPanel(double delta, double available) {
    final AiLayoutConfig config = widget.aiLayoutConfig;
    final double widest = math.max(
      config.minPanelWidth,
      math.min(config.maxPanelWidth, available - config.minEditorWidth),
    );
    _aiPanelDragWidth.value = (_aiPanelDragWidth.value + delta)
        .clamp(config.minPanelWidth, widest)
        .toDouble();
  }

  /// Lays the page out once, around where the panel was let go.
  void _endAiPanelResize() {
    if (!_resizingAiPanel) return;
    setState(() {
      _resizingAiPanel = false;
      _aiPanelWidth = _aiPanelDragWidth.value;
    });
  }

  /// The panel over the editor, against [side], above a barrier that
  /// closes it.
  List<Widget> _buildSheet(BuildContext context, AiPanelSide side) {
    final AppColors colors = AppColors.of(context);
    final Size screen = MediaQuery.sizeOf(context);
    final double width = widget.aiLayoutConfig.sheetWidth(screen.width);
    final Duration duration = AppMotion.resolve(
      context,
      AppMotion.snappy.duration,
    );
    final Duration entrance = AppMotion.resolve(
      context,
      AppMotion.smooth.duration,
    );
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
            // Dims the editor gradually rather than all at once.
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 0.32),
              duration: entrance,
              curve: AppMotion.fadeInCurve,
              builder: (BuildContext context, double alpha, Widget? _) {
                return ColoredBox(
                  color: colors.shadow.withValues(alpha: alpha),
                );
              },
            ),
          ),
        ),
      ),
      AnimatedPositioned(
        key: const ValueKey<String>('ai-panel-sheet'),
        duration: duration,
        curve: AppMotion.fadeInCurve,
        top: 0,
        bottom: 0,
        left: side == AiPanelSide.left ? 0 : screen.width - width,
        width: width,
        // Glides in from its edge when it opens, fading up as it comes.
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 1, end: 0),
          duration: entrance,
          curve: AppMotion.fadeInCurve,
          builder: (BuildContext context, double hidden, Widget? child) {
            return FractionalTranslation(
              translation: Offset(
                side == AiPanelSide.left ? -hidden : hidden,
                0,
              ),
              child: Opacity(
                opacity: (1 - hidden * 1.5).clamp(0.0, 1.0),
                child: child,
              ),
            );
          },
          child: GlassSurface(
            boxShadow: AppShadows.floating(colors),
            // Keeps the composer above the on-screen keyboard.
            child: _KeyboardInset(
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
    // What the body's SafeArea already keeps clear at the bottom; constant
    // while the keyboard moves, unlike the padding.
    final double bottomSafeArea = MediaQuery.viewPaddingOf(context).bottom;
    if (panelSide == null && _resizingAiPanel) {
      // Closed under the finger: its handle went with it, and never ended
      // the drag.
      _resizingAiPanel = false;
      _aiPanelWidth = _aiPanelDragWidth.value;
    }
    _publishChrome();
    return Scaffold(
      // The keyboard only ever serves the assistant's composer, which lifts
      // itself clear of it. Resizing the body would lay the page out again
      // on every frame of the keyboard's slide and make it stutter.
      resizeToAvoidBottomInset: false,
      // Under tabs, the bar is theirs, and shared by every pane.
      appBar: _chromeScope != null
          ? null
          : EditorAppBar(
              title: widget.title,
              centerTitle: sizeClass == WindowSizeClass.expanded,
              onMenuPressed: widget.onBack ?? () {},
              leadingIsBack: widget.onBack != null,
              onTitlePressed: widget.onTitlePressed ?? () {},
              onSettingsPressed: _openSettings,
              tabs: widget.tabs,
              audioPlayer: _audioPlayer,
              replayController: _strokeReplay,
              onCloseReplay: () => unawaited(_closeReplay()),
            ),
      body: SafeArea(
        top: false,
        // The keyboard eats into the bottom padding as it rises; keeping
        // the view padding instead spares the page a layout on each frame.
        maintainBottomViewPadding: true,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final Size size = constraints.biggest;
            final double panelWidth = panelSide == null
                ? 0
                : widget.aiLayoutConfig.inlineWidth(
                    size.width,
                    preferred: _aiPanelWidth,
                  );
            // What the panel leaves for the page and the palette.
            final Rect region = Rect.fromLTWH(
              panelSide == AiPanelSide.left ? panelWidth : 0,
              0,
              size.width - panelWidth,
              size.height,
            );
            _paletteRegion = region;
            final double historyWidth =
                FloatingHistoryControls.widthFor(
                  ToolPalette.sizeFor(Axis.horizontal).height,
                ) +
                PageNavigationControls.widthFor();
            final double pageControlsWidth = FloatingPageControls.widthFor(
              ToolPalette.sizeFor(Axis.horizontal).height,
              find: _canFind,
            );
            final bool isAiOpen = panelSide != null;
            final EditorLayout layout = EditorLayout.compute(
              sizeClass,
              region,
              _palettePlacement.value,
              historyWidth: historyWidth,
              pageControlsWidth: pageControlsWidth,
              isAiOpen: isAiOpen,
              paletteExpanded: _paletteExpanded,
            );
            _lastLayout = layout;
            final List<NotePage> pages = _document.pages;
            final bool infiniteCanvas =
                pages[_document.currentIndex].setup.size == PageSize.infinite;
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
              if (mounted) _focusPdfPages(pages, geometries, pixelRatio);
            });
            // The palette floats over the page; the page's own floating
            // bars keep clear of it. In the page area's coordinates.
            // What floats over the page, for its own floating bars to clear:
            // the card and the palette.
            final Rect historyOnPage = layout.history.shift(
              -layout.surface.topLeft,
            );
            final Rect paletteOnPage =
                ((layout.paletteOrigin - layout.surface.topLeft) &
                        ToolPalette.sizeFor(
                          layout.paletteAxis,
                          expanded: _paletteExpanded,
                        ))
                    .expandToInclude(historyOnPage);
            final BorderSide edge = BorderSide(
              color: colors.divider,
              width: AppSizes.hairline,
            );
            return Stack(
              key: _bodyKey,
              children: <Widget>[
                Positioned.fromRect(
                  rect: layout.surface,
                  child: RepaintBoundary(
                    child: WritingSurfaceFrame(
                      child: PageViewport(
                        key: const ValueKey<String>('page-viewport'),
                        pages: geometries,
                        pageKeys: <Key>[
                          for (final NotePage page in pages) ObjectKey(page),
                        ],
                        currentPage: _document.currentIndex,
                        // Infinite canvas is the writing surface itself. It
                        // must never shrink enough to reveal a desk edge.
                        minZoom: infiniteCanvas ? 1 : 0.5,
                        initialZoom: infiniteCanvas
                            ? 1
                            : EditorScreen.openingZoom,
                        onPageTouched: _showPage,
                        onDeskTap: _selectionCarry.clearSelection,
                        onVisiblePageChanged: _showPage,
                        onScrollStart: _onScrollStart,
                        onScrollEnd: _onScrollEnd,
                        fingersNavigate: _stylusOnly,
                        pointerClaims: _pointerClaims,
                        onPullToAddPage: _addPageAtEnd,
                        pullToAddDistance: 180,
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
                                      visible: visible,
                                      onShown: index == _document.currentIndex
                                          ? _pageShown
                                          : null,
                                    ),
                                  if (widget.assetReader != null ||
                                      page.ink.images.any(
                                        (NoteImageElement image) =>
                                            image.isVector,
                                      ))
                                    PageImageLayer(
                                      cache: widget.assetReader == null
                                          ? null
                                          : _imageCache ??= PageImageCache(
                                              readAsset: widget.assetReader!,
                                            ),
                                      controller: page.ink,
                                      readAsset: widget.assetReader,
                                      maxDecodeDimension: widget
                                          .documentIoConfig
                                          .maxStoredImageDimension,
                                      carry: _selectionCarry,
                                    ),
                                  InkCanvas(
                                    controller: page.ink,
                                    visible: visible,
                                    enableNativeInk: widget.enableNativeInk,
                                    tool: _tool,
                                    penSettings: _penSettings,
                                    eraserSettings: _eraserSettings,
                                    penConfig: widget.penConfig,
                                    eraserConfig: widget.eraserConfig,
                                    shapeConfig: widget.shapeConfig,
                                    isInputBlocked: _isPageInputBlocked,
                                    pastePrompt: _pastePrompt,
                                    stylusOnly: _stylusOnly,
                                    ruler: _ruler,
                                    pointerClaims: _pointerClaims,
                                    aiActive: _aiActive,
                                    aiInput: _aiInput,
                                    selectablePdfBounds: page.pdfSource == null
                                        ? null
                                        : Offset.zero &
                                              page.pdfSource!.pageSize,
                                    stickySettings: _stickySettings,
                                    onStickyPlaced: _onStickyPlaced,
                                    textSettings: _textSettings,
                                    onTextSelected: (TextSettings settings) {
                                      _textSettings.value = settings;
                                    },
                                    pageGrows:
                                        page.setup.size == PageSize.infinite,
                                    carry: _selectionCarry,
                                    exclusionRects: _nativeExclusionRects,
                                    exclusionsChanged:
                                        _paletteController.popoverChanged,
                                    replay: _strokeReplay,
                                    onReplayStrokeTapped: _seekToStroke,
                                    // The page the selection is on is the
                                    // current one; the view stays put.
                                    onSelectionCarried: () => context
                                        .findAncestorStateOfType<
                                          PageViewportState
                                        >()
                                        ?.touchPage(index),
                                  ),
                                  AiContextGlow(assistant: _ai, page: page.ink),
                                  ValueListenableBuilder<
                                    _HandwritingFindTarget?
                                  >(
                                    valueListenable: _handwritingFindTarget,
                                    builder:
                                        (
                                          BuildContext context,
                                          _HandwritingFindTarget? target,
                                          Widget? _,
                                        ) {
                                          if (target == null ||
                                              !identical(target.page, page)) {
                                            return const SizedBox.shrink();
                                          }
                                          return IgnorePointer(
                                            child: ExcludeSemantics(
                                              child: CustomPaint(
                                                key: ValueKey<String>(
                                                  'handwriting-search-highlight-$index',
                                                ),
                                                painter:
                                                    _HandwritingFindHighlightPainter(
                                                      page: page,
                                                      target: target,
                                                      color: AppColors.of(
                                                        context,
                                                      ).accent,
                                                    ),
                                              ),
                                            ),
                                          );
                                        },
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
                                    crossPageListenable: _selectionCarry,
                                    selectionResolver: _stableSelection,
                                    onAiPressed: _openAi,
                                    onCopy: _copy,
                                    onCut: _cut,
                                    onDuplicate: () => _selectionCarry
                                        .duplicateSelection(_inkController),
                                    onDelete: (_) => _selectionCarry
                                        .deleteSelection(_inkController),
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
                ),
                AnimatedPositioned(
                  key: const ValueKey<String>('history-position'),
                  duration: AppMotion.resolve(
                    context,
                    AppMotion.snappy.duration,
                  ),
                  curve: AppMotion.fadeInCurve,
                  left: layout.history.left,
                  top: layout.history.top,
                  child: PageOverviewAnchor(
                    open: _pageOverviewOpen,
                    document: _document,
                    writingArea: _viewportSize,
                    config: widget.pageConfig,
                    child: FloatingHistoryControls(
                      height: layout.history.height,
                      width: layout.history.width,
                      children: <Widget>[
                        HistoryControls(
                          controller: _inkController,
                          onUndo: _undo,
                          onRedo: _redo,
                        ),
                        PageNavigationControls(
                          onOpenOverview: _togglePageOverview,
                          overviewOpen: _pageOverviewOpen,
                        ),
                      ],
                    ),
                  ),
                ),
                AnimatedPositioned(
                  key: const ValueKey<String>('page-controls-position'),
                  duration: AppMotion.resolve(
                    context,
                    AppMotion.snappy.duration,
                  ),
                  curve: AppMotion.fadeInCurve,
                  left: layout.pageControls.left,
                  top: layout.pageControls.top,
                  child: FloatingPageControls(
                    height: layout.pageControls.height,
                    width: layout.pageControls.width,
                    child: PageControls(
                      document: _document,
                      onOpenSettings: _openPageSettings,
                      canFind: _canFind,
                      onFind: _openHandwritingFind,
                      lastAddAction: _lastAddAction,
                      onAddActionChanged: (AddPageAction action) {
                        setState(() => _lastAddAction = action);
                      },
                      onInsertPdf: _canUseDocumentIo ? _insertPdf : null,
                    ),
                  ),
                ),
                _PalettePositioner(
                  historyWidth: historyWidth,
                  pageControlsWidth: pageControlsWidth,
                  center: _paletteDragCenter,
                  sizeClass: sizeClass,
                  region: region,
                  placement: _palettePlacement.value,
                  isAiOpen: isAiOpen,
                  expanded: _paletteExpanded,
                  builder: (PaletteEdge edge) => ToolPalette(
                    edge: edge,
                    onDragStart: () => _onPaletteDragStart(
                      layout.paletteOrigin +
                          ToolPalette.sizeFor(
                            layout.paletteAxis,
                            expanded: _paletteExpanded,
                          ).center(Offset.zero),
                    ),
                    onDragUpdate: _onPaletteDragUpdate,
                    onDragEnd: _onPaletteDragEnd,
                    onMoveTo: _movePaletteTo,
                    dense: sizeClass == WindowSizeClass.medium,
                    tool: _tool,
                    penSettings: _penSettings,
                    eraserSettings: _eraserSettings,
                    clipboardListenable: _inkController.selectionListenable,
                    canPaste: () => _inkController.canPaste,
                    onPaste: _paste,
                    aiActive: _aiActive,
                    onTurnOnAi: _openAi,
                    assistant: _ai,
                    penConfig: widget.penConfig,
                    eraserConfig: widget.eraserConfig,
                    controller: _paletteController,
                    ruler: _ruler,
                    recording: RecordingToolData(
                      recorder: _audioRecorder,
                      document: _document,
                      replay: _strokeReplay,
                      onStart: () => unawaited(_startRecording()),
                      onPause: () => unawaited(_pauseRecording()),
                      onResume: () => unawaited(_resumeRecording()),
                      onStop: () => unawaited(finalizeRecording()),
                      onOpen: (NoteRecordingTrack track) =>
                          unawaited(_openReplay(track)),
                    ),
                    textSettings: _textSettings,
                    onTextSettingsChanged: _onTextSettingsChanged,
                    stickySettings: _stickySettings,
                    onStickySettingsChanged: _onStickySettingsChanged,
                    stickyTargetLabel: () =>
                        _inkController.editingSticky?.label,
                    onChooseImageFromGallery: _canUseDocumentIo
                        ? () => _insertImage(DocumentImageSource.gallery)
                        : null,
                    onTakePhoto: _canUseDocumentIo
                        ? () => _insertImage(DocumentImageSource.camera)
                        : null,
                    onChooseSvg:
                        _canUseDocumentIo &&
                            widget.documentPicker is SvgDocumentPicker
                        ? _insertSvg
                        : null,
                  ),
                ),
                // What a narrowing panel uncovers before the page is laid
                // out again: more of the desk the page sits on.
                if (panelSide != null && _resizingAiPanel)
                  Positioned(
                    key: const ValueKey<String>('ai-panel-resize-desk'),
                    top: 0,
                    bottom: 0,
                    left: panelSide == AiPanelSide.left
                        ? 0
                        : size.width - panelWidth,
                    width: panelWidth,
                    child: ColoredBox(color: colors.writingSurface),
                  ),
                if (panelSide != null)
                  ValueListenableBuilder<double>(
                    valueListenable: _aiPanelDragWidth,
                    builder:
                        (
                          BuildContext context,
                          double dragWidth,
                          Widget? panel,
                        ) {
                          final double width = _resizingAiPanel
                              ? dragWidth
                              : panelWidth;
                          return AnimatedPositioned(
                            key: const ValueKey<String>('ai-panel-beside'),
                            duration: _resizingAiPanel
                                ? Duration.zero
                                : AppMotion.resolve(
                                    context,
                                    AppMotion.snappy.duration,
                                  ),
                            curve: AppMotion.fadeInCurve,
                            top: 0,
                            bottom: 0,
                            left: panelSide == AiPanelSide.left
                                ? 0
                                : size.width - width,
                            width: width,
                            child: panel!,
                          );
                        },
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
                      // Eases in from its edge when it opens, instead of
                      // appearing all at once.
                      child: TweenAnimationBuilder<double>(
                        tween: Tween<double>(begin: 1, end: 0),
                        duration: AppMotion.resolve(
                          context,
                          AppMotion.smooth.duration,
                        ),
                        curve: AppMotion.fadeInCurve,
                        builder:
                            (
                              BuildContext context,
                              double hidden,
                              Widget? child,
                            ) {
                              return FractionalTranslation(
                                translation: Offset(
                                  (panelSide == AiPanelSide.left ? -1 : 1) *
                                      hidden *
                                      0.12,
                                  0,
                                ),
                                child: Opacity(
                                  opacity: 1 - hidden,
                                  child: child,
                                ),
                              );
                            },
                        child: Stack(
                          children: <Widget>[
                            Positioned.fill(
                              child: _KeyboardInset(
                                consumed: bottomSafeArea,
                                child: _buildPanel(),
                              ),
                            ),
                            Positioned(
                              top: 0,
                              bottom: 0,
                              left: panelSide == AiPanelSide.right ? 0 : null,
                              right: panelSide == AiPanelSide.left ? 0 : null,
                              child: _PanelResizeHandle(
                                active: _resizingAiPanel,
                                onDragStart: () =>
                                    _startAiPanelResize(panelWidth),
                                onDragUpdate: (double dx) => _resizeAiPanel(
                                  panelSide == AiPanelSide.right ? -dx : dx,
                                  size.width,
                                ),
                                onDragEnd: _endAiPanelResize,
                              ),
                            ),
                          ],
                        ),
                      ),
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

/// The strip along the AI panel's inner edge that resizes it when dragged.
class _PanelResizeHandle extends StatefulWidget {
  const _PanelResizeHandle({
    required this.active,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  /// Whether it is being dragged.
  final bool active;
  final VoidCallback onDragStart;

  /// Called with how far the pointer moved to the right.
  final ValueChanged<double> onDragUpdate;
  final VoidCallback onDragEnd;

  static const double width = 12;

  @override
  State<_PanelResizeHandle> createState() => _PanelResizeHandleState();
}

class _PanelResizeHandleState extends State<_PanelResizeHandle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => widget.onDragStart(),
        onHorizontalDragUpdate: (DragUpdateDetails details) =>
            widget.onDragUpdate(details.delta.dx),
        onHorizontalDragEnd: (_) => widget.onDragEnd(),
        onHorizontalDragCancel: widget.onDragEnd,
        child: SizedBox(
          width: _PanelResizeHandle.width,
          child: Center(
            child: AnimatedContainer(
              duration: AppMotion.resolve(context, AppMotion.fadeIn),
              // Always faintly there, since touch screens can't hover.
              width: _hovered || widget.active ? 4 : 3,
              height: 40,
              decoration: BoxDecoration(
                color: widget.active
                    ? colors.accent
                    : (_hovered ? colors.textSecondary : colors.divider),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HandwritingFindTarget {
  const _HandwritingFindTarget({
    required this.page,
    required this.bounds,
    this.stickyId,
  });

  final NotePage page;
  final Rect bounds;
  final String? stickyId;
}

class _HandwritingFindHighlightPainter extends CustomPainter {
  const _HandwritingFindHighlightPainter({
    required this.page,
    required this.target,
    required this.color,
  });

  final NotePage page;
  final _HandwritingFindTarget target;
  final Color color;

  void _paintHighlight(Canvas canvas, Rect bounds, {double scale = 1}) {
    if (bounds.isEmpty || !bounds.isFinite) return;
    final RRect highlight = RRect.fromRectAndRadius(
      bounds.inflate(4 / scale),
      Radius.circular(5 / scale),
    );
    canvas
      ..drawRRect(highlight, Paint()..color = color.withValues(alpha: 0.18))
      ..drawRRect(
        highlight,
        Paint()
          ..color = color.withValues(alpha: 0.95)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 / scale
          ..isAntiAlias = true,
      );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (target.stickyId == null) {
      _paintHighlight(canvas, target.bounds);
      return;
    }
    final StickyNoteElement? sticky = page.ink.stickyNotes
        .where((StickyNoteElement note) => note.id == target.stickyId)
        .firstOrNull;
    if (sticky == null || !sticky.isValid) return;
    final Size local = sticky.localSize;
    canvas
      ..save()
      ..translate(sticky.center.x, sticky.center.y)
      ..rotate(sticky.rotation)
      ..scale(sticky.scale)
      ..translate(-local.width / 2, -local.height / 2);
    _paintHighlight(canvas, target.bounds, scale: sticky.scale);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HandwritingFindHighlightPainter oldDelegate) =>
      oldDelegate.page != page ||
      oldDelegate.target != target ||
      oldDelegate.color != color;
}

class _HandwritingFindDialog extends StatefulWidget {
  const _HandwritingFindDialog({
    required this.document,
    required this.recognizer,
    required this.renderer,
    required this.onTargetChanged,
    required this.onDrag,
  });

  final NoteDocument document;
  final CanvasTextRecognizer recognizer;
  final HandwritingImageRenderer renderer;
  final ValueChanged<Offset> onDrag;
  final ValueChanged<_HandwritingFindTarget?> onTargetChanged;

  @override
  State<_HandwritingFindDialog> createState() => _HandwritingFindDialogState();
}

class _HandwritingFindDialogState extends State<_HandwritingFindDialog> {
  final TextEditingController _query = TextEditingController();
  final List<List<InkVector>> _drawnQuery = <List<InkVector>>[];
  String _drawnReading = '';
  int _recognitionGeneration = 0;
  int _selected = 0;
  Timer? _pause;
  List<_InkFindMatch> _found = const <_InkFindMatch>[];

  /// How long the pen must rest before the drawn query is searched.
  static const Duration _drawPause = Duration(milliseconds: 800);

  List<_InkFindMatch> _search() {
    final String typed = _query.text.trim();
    final String text = <String>[
      typed,
      if (_drawnReading.isNotEmpty) _drawnReading,
    ].join(' ').trim();
    List<List<InkVector>> queryInk = _drawnQuery;
    if (queryInk.isEmpty && typed.isNotEmpty) {
      final String symbol = InkSearch.normalizeSearchText(typed);
      if (symbol.runes.length <= 3 && NotationFont.canWrite(symbol)) {
        queryInk = NotationFont.write(symbol, origin: InkVector.zero, size: 40);
      }
    }
    if (text.isEmpty && queryInk.isEmpty) return const <_InkFindMatch>[];
    final List<_InkFindMatch> found = <_InkFindMatch>[];
    for (
      int pageIndex = 0;
      pageIndex < widget.document.pages.length;
      pageIndex++
    ) {
      final NotePage page = widget.document.pages[pageIndex];
      final List<InkSearchRegion> words = <InkSearchRegion>[
        for (final RecognizedInkWord word in page.recognizedWords)
          InkSearchRegion(
            strokes: <List<InkVector>>[
              for (final Stroke stroke in word.sourceStrokes) stroke.points,
            ],
            texts: <String>[word.text, ...word.alternatives],
            confidence: word.confidence,
            stickyId: word.stickyId,
          ),
      ];
      final List<InkSearchRegion> regions = <InkSearchRegion>[
        ...words,
        ...InkSearch.lineSequences(words),
        ...InkSearch.connectedRegions(page.ink.strokes),
        for (final StickyNoteElement sticky in page.ink.stickyNotes)
          ...InkSearch.connectedRegions(sticky.strokes, stickyId: sticky.id),
      ];
      for (final InkSearchMatch match in InkSearch.find(
        regions: regions,
        text: text,
        strokes: queryInk,
      )) {
        found.add(_InkFindMatch(pageIndex, match));
      }
    }
    found.sort((_InkFindMatch a, _InkFindMatch b) {
      final int score = b.match.score.compareTo(a.match.score);
      return score == 0 ? a.page.compareTo(b.page) : score;
    });
    return found.take(100).toList();
  }

  void _showMatch(List<_InkFindMatch> found, int index) {
    if (found.isEmpty) {
      widget.onTargetChanged(null);
      return;
    }
    final _InkFindMatch hit = found[index];
    widget.document.goTo(hit.page);
    widget.onTargetChanged(
      _HandwritingFindTarget(
        page: widget.document.pages[hit.page],
        bounds: hit.match.region.bounds,
        stickyId: hit.match.region.stickyId,
      ),
    );
  }

  void _refresh() {
    setState(() {
      _selected = 0;
      _found = _search();
    });
    _showMatch(_found, 0);
  }

  void _onQueryChanged(String _) => _refresh();

  /// A new stroke began: whatever was waiting on the pause is stale.
  void _onStrokeStart() {
    _pause?.cancel();
    _recognitionGeneration++;
  }

  void _onInkChanged(List<List<InkVector>> strokes) {
    _pause?.cancel();
    final int generation = ++_recognitionGeneration;
    if (strokes.isEmpty) {
      _drawnQuery.clear();
      _drawnReading = '';
      _refresh();
      return;
    }
    _pause = Timer(_drawPause, () async {
      if (!mounted || generation != _recognitionGeneration) return;
      _drawnQuery
        ..clear()
        ..addAll(strokes.map(List<InkVector>.of));
      _drawnReading = '';
      _refresh();
      int micros = 0;
      final List<AiCanvasStroke> canvasStrokes = <AiCanvasStroke>[
        for (final List<InkVector> stroke in strokes)
          AiCanvasStroke(<AiCanvasPoint>[
            for (final InkVector point in stroke)
              AiCanvasPoint(point, Duration(microseconds: micros += 8000)),
          ]),
      ];
      final HandwritingBatch batch =
          widget.recognizer is PlatformCanvasTextRecognizer
          ? widget.renderer.vectors(canvasStrokes)
          : await widget.renderer.render(canvasStrokes);
      final String reading = await widget.recognizer.recognize(batch);
      if (!mounted || generation != _recognitionGeneration) return;
      _drawnReading = reading.trim();
      _refresh();
    });
  }

  @override
  void dispose() {
    _pause?.cancel();
    _recognitionGeneration++;
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<_InkFindMatch> found = _found;
    final int selected = found.isEmpty ? 0 : _selected % found.length;
    return Material(
      elevation: 8,
      borderRadius: AppBorderRadius.medium,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (DragUpdateDetails details) =>
                  widget.onDrag(details.delta),
              child: SizedBox(
                height: 20,
                width: double.infinity,
                child: Center(
                  child: Container(
                    key: const ValueKey<String>('find-drag-handle'),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(context).dividerColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
            TextField(
              controller: _query,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                hintText: 'Type a word, phrase, or symbol',
                prefixIcon: Icon(AppIcons.search),
              ),
              onChanged: _onQueryChanged,
              onSubmitted: (_) => _showMatch(found, selected),
            ),
            const SizedBox(height: AppSpacing.sm),
            _InkSearchPad(
              onStrokeStart: _onStrokeStart,
              onChanged: _onInkChanged,
            ),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    _query.text.trim().isEmpty
                        ? _drawnQuery.isEmpty
                              ? 'Type above or write/draw below.'
                              : _drawnReading.isEmpty
                              ? 'Searching by ink shape.'
                              : 'Searching shape and “$_drawnReading”'
                        : found.isEmpty
                        ? 'No similar ink found.'
                        : '${selected + 1} of ${found.length} · Page ${found[selected].page + 1} · ${(found[selected].match.score * 100).round()}%',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (found.length > 1)
                  IconButton(
                    tooltip: 'Previous match',
                    onPressed: () {
                      final int previous =
                          (selected - 1 + found.length) % found.length;
                      setState(() => _selected = previous);
                      _showMatch(found, previous);
                    },
                    icon: const Icon(Icons.chevron_left),
                  ),
                if (found.isNotEmpty)
                  IconButton(
                    tooltip: 'Next match',
                    onPressed: () {
                      final int next = (selected + 1) % found.length;
                      setState(() => _selected = next);
                      _showMatch(found, next);
                    },
                    icon: const Icon(Icons.chevron_right),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InkFindMatch {
  const _InkFindMatch(this.page, this.match);

  final int page;
  final InkSearchMatch match;
}

class _InkSearchPad extends StatefulWidget {
  const _InkSearchPad({required this.onChanged, this.onStrokeStart});

  final ValueChanged<List<List<InkVector>>> onChanged;
  final VoidCallback? onStrokeStart;

  @override
  State<_InkSearchPad> createState() => _InkSearchPadState();
}

class _InkSearchPadState extends State<_InkSearchPad> {
  final List<List<InkVector>> _strokes = <List<InkVector>>[];
  final Map<int, List<InkVector>> _active = <int, List<InkVector>>{};

  void _down(PointerDownEvent event) {
    final List<InkVector> stroke = <InkVector>[
      InkVector(event.localPosition.dx, event.localPosition.dy),
    ];
    _active[event.pointer] = stroke;
    widget.onStrokeStart?.call();
    setState(() => _strokes.add(stroke));
  }

  void _move(PointerMoveEvent event) {
    final List<InkVector>? stroke = _active[event.pointer];
    if (stroke == null) return;
    final InkVector point = InkVector(
      event.localPosition.dx,
      event.localPosition.dy,
    );
    if ((point - stroke.last).length < 1) return;
    setState(() => stroke.add(point));
  }

  void _up(PointerEvent event) {
    _active.remove(event.pointer);
    widget.onChanged(<List<InkVector>>[
      for (final List<InkVector> stroke in _strokes) List<InkVector>.of(stroke),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 96,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _down,
                onPointerMove: _move,
                onPointerUp: _up,
                onPointerCancel: _up,
                child: CustomPaint(
                  key: const ValueKey<String>('ink-search-pad'),
                  painter: _InkSearchPadPainter(_strokes),
                  child: _strokes.isEmpty
                      ? const Center(child: Text('Write or draw to search'))
                      : null,
                ),
              ),
            ),
          ),
          if (_strokes.isNotEmpty)
            Positioned(
              right: 4,
              top: 4,
              child: IconButton(
                tooltip: 'Clear drawing',
                onPressed: () {
                  setState(() {
                    _active.clear();
                    _strokes.clear();
                  });
                  widget.onChanged(const <List<InkVector>>[]);
                },
                icon: const Icon(Icons.close),
              ),
            ),
        ],
      ),
    );
  }
}

class _InkSearchPadPainter extends CustomPainter {
  const _InkSearchPadPainter(this.strokes);

  final List<List<InkVector>> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = Colors.black87
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (final List<InkVector> stroke in strokes) {
      if (stroke.isEmpty) continue;
      final Path path = Path()..moveTo(stroke.first.x, stroke.first.y);
      for (final InkVector point in stroke.skip(1)) {
        path.lineTo(point.x, point.y);
      }
      if (stroke.length == 1) path.lineTo(stroke.first.x, stroke.first.y);
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_InkSearchPadPainter oldDelegate) => true;
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

/// Pads [child] clear of the on-screen keyboard, less the [consumed] bottom
/// already kept clear above it. It reads the keyboard itself, so only it
/// and [child] rebuild as the keyboard slides, never the page.
class _KeyboardInset extends StatelessWidget {
  const _KeyboardInset({required this.child, this.consumed = 0});

  final Widget child;
  final double consumed;

  @override
  Widget build(BuildContext context) {
    final double keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: math.max(0, keyboard - consumed)),
      child: child,
    );
  }
}

/// Where the page and palette sit inside the region the AI panel leaves
/// them. The page fills the whole region, edge to edge; the palette floats
/// above it, docked against the edge its [PalettePlacement] names, or,
/// while it is dragged, centered where it is held and lying along the
/// edge nearest to it.
class _PalettePositioner extends StatefulWidget {
  const _PalettePositioner({
    required this.center,
    required this.sizeClass,
    required this.region,
    required this.placement,
    required this.historyWidth,
    required this.pageControlsWidth,
    required this.builder,
    this.isAiOpen = false,
    this.expanded = false,
  });
  final bool expanded;
  final double historyWidth;
  final double pageControlsWidth;
  final ValueListenable<Offset?> center;
  final WindowSizeClass sizeClass;
  final Rect region;
  final PalettePlacement placement;
  final Widget Function(PaletteEdge) builder;
  final bool isAiOpen;

  @override
  State<_PalettePositioner> createState() => _PalettePositionerState();
}

class _PalettePositionerState extends State<_PalettePositioner> {
  PaletteEdge? _edge;
  Widget? _palette;

  @override
  void didUpdateWidget(_PalettePositioner oldWidget) {
    super.didUpdateWidget(oldWidget);
    _palette = null;
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Offset?>(
    valueListenable: widget.center,
    builder: (context, center, _) {
      final layout = EditorLayout.compute(
        widget.sizeClass,
        widget.region,
        widget.placement,
        historyWidth: widget.historyWidth,
        pageControlsWidth: widget.pageControlsWidth,
        dragCenter: center,
        isAiOpen: widget.isAiOpen,
        paletteExpanded: widget.expanded,
      );
      // Reuse the entire control subtree until the edge or editor inputs
      // change. Each move updates only Stack parent data and compositing.
      if (_palette == null || _edge != layout.paletteEdge) {
        _edge = layout.paletteEdge;
        _palette = RepaintBoundary(child: widget.builder(_edge!));
      }
      return AnimatedPositioned(
        key: const ValueKey<String>('tool-palette-position'),
        duration: center == null
            ? AppMotion.resolve(context, AppMotion.bouncy.duration)
            : Duration.zero,
        curve: AppMotion.fadeInCurve,
        left: layout.paletteOrigin.dx,
        top: layout.paletteOrigin.dy,
        child: _palette!,
      );
    },
  );
}

class EditorLayout {
  const EditorLayout({
    required this.surface,
    required this.paletteOrigin,
    required this.paletteEdge,
    required this.history,
    required this.pageControls,
  });

  final Rect surface;
  final Offset paletteOrigin;
  final PaletteEdge paletteEdge;

  /// Where Undo, Redo, current-page information, and the page overview hang:
  /// in the top-left corner.
  final Rect history;

  /// Where search, add, and the page-settings ellipsis hang: in the top-right
  /// corner.
  final Rect pageControls;

  static Rect _historyRect(Rect region, double width) {
    final double height = ToolPalette.sizeFor(Axis.horizontal).height;
    return region.topLeft & Size(math.min(width, region.width), height);
  }

  static Rect _pageControlsRect(Rect region, double width) {
    final double height = ToolPalette.sizeFor(Axis.horizontal).height;
    final double clampedWidth = math.min(width, region.width);
    return Rect.fromLTWH(
      region.right - clampedWidth,
      region.top,
      clampedWidth,
      height,
    );
  }

  /// Whether the palette and both cards can lie across the top.
  static bool _fitsBeside(
    Rect region,
    double margin,
    PalettePlacement placement,
    double historyWidth,
    double pageControlsWidth, {
    bool expanded = false,
  }) {
    final Size palette = ToolPalette.sizeFor(
      placement.edge.axis,
      expanded: expanded,
    );
    return palette.width + historyWidth + pageControlsWidth + 4 * margin <=
        region.width;
  }

  /// Where the docked palette sits: centered or as its placement says, clear of
  /// the cards at the corners. With no room beside both cards, as on a phone,
  /// it goes on the row below.
  static Offset _dockedOrigin(
    Rect region,
    double margin,
    PalettePlacement placement,
    double historyWidth,
    double pageControlsWidth, {
    bool isAiOpen = false,
    bool expanded = false,
  }) {
    final Offset origin = placement.originIn(
      region,
      margin,
      expanded: expanded,
    );
    if (placement.edge != PaletteEdge.top) {
      return origin;
    }
    final Rect leftCard = _historyRect(region, historyWidth);
    final Rect rightCard = _pageControlsRect(region, pageControlsWidth);
    if (!_fitsBeside(
      region,
      margin,
      placement,
      historyWidth,
      pageControlsWidth,
      expanded: expanded,
    )) {
      return Offset(origin.dx, math.max(origin.dy, leftCard.bottom + margin));
    }
    if (isAiOpen) {
      final Size paletteSize = ToolPalette.sizeFor(
        placement.edge.axis,
        expanded: expanded,
      );
      final double middleX = (leftCard.right + rightCard.left) / 2;
      final double centeredX = middleX - paletteSize.width / 2;
      final double clampedX = centeredX.clamp(
        leftCard.right + margin,
        math.max(
          leftCard.right + margin,
          rightCard.left - paletteSize.width - margin,
        ),
      );
      return Offset(clampedX, origin.dy);
    }
    final double minClear = leftCard.right + margin;
    return origin.dx >= minClear ? origin : Offset(minClear, origin.dy);
  }

  Axis get paletteAxis => paletteEdge.axis;

  /// How far the docked palette keeps from its edge.
  static double marginFor(WindowSizeClass sizeClass) {
    return switch (sizeClass) {
      WindowSizeClass.expanded => AppSpacing.xs,
      WindowSizeClass.medium => AppSpacing.xs,
      WindowSizeClass.compact => AppSpacing.xxs,
    };
  }

  static EditorLayout compute(
    WindowSizeClass sizeClass,
    Rect region,
    PalettePlacement placement, {
    required double historyWidth,
    required double pageControlsWidth,
    Offset? dragCenter,
    bool isAiOpen = false,
    bool paletteExpanded = false,
  }) {
    final double margin = marginFor(sizeClass);
    final Rect history = _historyRect(region, historyWidth);
    final Rect pageControls = _pageControlsRect(region, pageControlsWidth);
    if (dragCenter != null) {
      final PaletteEdge edge = PalettePlacement.nearestEdge(region, dragCenter);
      final Size size = ToolPalette.sizeFor(
        edge.axis,
        expanded: paletteExpanded,
      );
      final Offset origin = dragCenter - size.center(Offset.zero);
      return EditorLayout(
        surface: region,
        history: history,
        pageControls: pageControls,
        paletteEdge: edge,
        paletteOrigin: Offset(
          origin.dx.clamp(
            region.left,
            math.max(region.left, region.right - size.width),
          ),
          origin.dy.clamp(
            region.top,
            math.max(region.top, region.bottom - size.height),
          ),
        ),
      );
    }
    return EditorLayout(
      surface: region,
      history: history,
      pageControls: pageControls,
      paletteEdge: placement.edge,
      paletteOrigin: _dockedOrigin(
        region,
        margin,
        placement,
        historyWidth,
        pageControlsWidth,
        isAiOpen: isAiOpen,
        expanded: paletteExpanded,
      ),
    );
  }
}
