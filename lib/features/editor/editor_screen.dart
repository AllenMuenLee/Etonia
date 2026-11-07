import 'dart:math' as math;
import 'dart:async';
import 'dart:isolate';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../app/theme/app_tokens.dart';
import '../../app/theme/app_icons.dart';
import '../../shared/feedback/app_haptics.dart';
import '../../shared/layout/breakpoints.dart';
import '../../shared/memory/memory_pressure.dart';
import '../library/note_content.dart';
import '../library/note_repository.dart';
import '../library/note_recording_track.dart';
import 'audio/note_audio.dart';
import 'audio/recording_transcriber.dart';
import 'audio/stroke_replay_controller.dart';
import 'ai/ai_assistant_controller.dart';
import 'ai/ai_citation.dart';
import 'ai/ai_canvas_input.dart';
import 'ai/ai_client.dart';
import 'ai/ai_config.dart';
import 'ai/ai_notation.dart';
import 'ai/live_notation.dart';
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
import 'ink/native_ink_bridge.dart';
import 'ink/notation_playback.dart';
import 'ink/pen_settings.dart';
import 'ink/selection_config.dart';
import 'ink/shape_config.dart';
import 'ink/stroke.dart';
import 'ink/stylus_actions.dart';
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
import 'page/note_cache_page.dart';
import '../../shared/memory/note_cache_pool.dart';
import 'document_io/pdf_selection_image.dart';
import 'document_io/pdf_exporter.dart';
import 'document_io/svg_document.dart';
import 'document_io/svg_exporter.dart';
import 'widgets/ai_assistant_panel.dart';
import 'widgets/ai_citation_highlight.dart';
import 'widgets/ai_context_glow.dart';
import 'widgets/clipboard_shortcuts.dart';
import 'widgets/editor_app_bar.dart';
import 'widgets/editor_chrome.dart';
import 'widgets/editor_settings_sheet.dart';
import 'widgets/export_options_sheet.dart';
import 'widgets/history_controls.dart';
import 'widgets/document_io_progress_dialog.dart';
import 'widgets/page_chapters.dart';
import 'widgets/page_controls.dart';
import 'widgets/selection_action_bar.dart';
import 'widgets/recording_options.dart';
import 'widgets/recording_transcript_sheet.dart';
import 'widgets/tool_options_bar.dart';
import 'widgets/tool_palette.dart';
import 'widgets/toolbar_layout.dart';
import 'widgets/writing_surface_frame.dart';
import '../payment/payment_page.dart';
import '../payment/subscription_controller.dart';

/// The editor shell: app bar, page, floating tool palette, and the AI
/// assistant panel.
///
/// The pages and their layout the PDF paper was last focused with.
typedef _PdfFocusInputs = ({
  List<NotePage> pages,
  List<PageGeometry> geometries,
  double pixelRatio,
});

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
    this.onImportConversationToStudyDesk,
    this.onTitlePressed,
    this.penConfig = const PenConfig(),
    this.eraserConfig = const EraserConfig(),
    this.selectionConfig = const SelectionConfig(),
    this.aiClient,
    this.citationMarks,
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
    this.cacheScope,
    this.repository,
    this.noteId,
    this.documentPicker = const SystemDocumentPicker(),
    this.exportSink = const SystemExportSink(),
    this.onClipboardChanged,
    this.stylusOnly,
    this.enableNativeInk = true,
    this.penSettings,
    this.palettePlacement,
    this.toolOptionsShown,
    this.toolbarShown,
    this.toolbarLayout,
    this.stylusActions,
    this.onAiSessionRetired,
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
    this.recordingTranscriber,
    this.pageUnderlayBuilder,
    this.pageOverlayBuilder,
    this.inputExclusions,
    this.readOnly = false,
    this.allowPageManagement = true,
    this.showAppBar = true,
  });

  final Widget Function(BuildContext context, int index)? pageUnderlayBuilder;
  final Widget Function(BuildContext context, int index)? pageOverlayBuilder;
  final ValueGetter<List<Rect>>? inputExclusions;
  final bool readOnly;
  final bool allowPageManagement;
  final bool showAppBar;

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

  /// Turns a saved recording into text when the user asks; the platform's
  /// on-device recognizer when null.
  final RecordingTranscriber? recordingTranscriber;

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
  final ValueChanged<List<AiMessage>>? onImportConversationToStudyDesk;

  /// Called by the title, to rename the note.
  final VoidCallback? onTitlePressed;

  final PenConfig penConfig;
  final EraserConfig eraserConfig;

  /// Used by the ink state the screen owns. An [inkController] supplied
  /// from outside brings its own.
  final SelectionConfig selectionConfig;

  /// Answers the assistant's requests. Supplied by tests, and by a build
  /// that talks to its own backend; otherwise the screen makes a
  /// What was cited of this note from outside it, to mark on its page and bring
  /// into view. Null for a note opened any other way.
  final ValueListenable<AiNoteMarks?>? citationMarks;

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

  /// How far out a whiteboard zooms, to take in a whole map of ink at once.
  static const double boardMinZoom = 0.1;
  final PdfRasterizer pdfRasterizer;

  /// Keeps PDF pages' previews between visits; without it they are
  /// rendered each time.
  final PdfPreviewStore? pdfPreviewStore;
  final DocumentIoConfig documentIoConfig;

  /// This note's share of the memory all open notes keep things in; without
  /// one the editor has a pool to itself.
  final NoteCacheScope? cacheScope;
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

  /// Whether the chosen tool's options bar shows beside the palette,
  /// shared from outside so that showing or hiding it holds from note to
  /// note; otherwise the screen owns one, showing it.
  final ValueNotifier<bool>? toolOptionsShown;

  /// Whether the floating tool palette is visible, shared across notes.
  final ValueNotifier<bool>? toolbarShown;

  /// Which buttons the tool palette shows, in what order, shared across
  /// notes; otherwise the screen owns one, as the palette comes.
  final ValueNotifier<ToolbarLayout>? toolbarLayout;

  /// Hardware stylus shortcuts shared across notes.
  final ValueNotifier<StylusActionBindings>? stylusActions;

  /// Saves the assistant's conversations with the note, as they are once an
  /// answer that was still on its way when the editor closed has arrived.
  /// Without it, such an answer is let go.
  final Future<void> Function(Map<String, Object?> session)? onAiSessionRetired;

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
  EditorTool _previousTool = EditorTool.pen;
  EditorTool _observedTool = EditorTool.pen;

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

  ValueNotifier<bool>? _ownedToolOptionsShown;

  ValueNotifier<bool> get _toolOptionsShown =>
      widget.toolOptionsShown ??
      (_ownedToolOptionsShown ??= ValueNotifier<bool>(true));

  ValueNotifier<bool>? _ownedToolbarShown;

  ValueNotifier<bool> get _toolbarShown =>
      widget.toolbarShown ?? (_ownedToolbarShown ??= ValueNotifier<bool>(true));

  ValueNotifier<ToolbarLayout>? _ownedToolbarLayout;

  ValueNotifier<ToolbarLayout> get _toolbarLayout =>
      widget.toolbarLayout ??
      (_ownedToolbarLayout ??= ValueNotifier<ToolbarLayout>(
        ToolbarLayout.standard,
      ));

  ToolbarLayout get _paletteTools => _toolbarLayout.value;

  ValueNotifier<StylusActionBindings>? _ownedStylusActions;

  ValueNotifier<StylusActionBindings> get _stylusActions =>
      widget.stylusActions ??
      (_ownedStylusActions ??= ValueNotifier<StylusActionBindings>(
        const StylusActionBindings(),
      ));

  /// Where the palette's center is held while it is dragged, in the
  /// body's coordinates; null when it is docked.
  final ValueNotifier<Offset?> _paletteDragCenter = ValueNotifier<Offset?>(
    null,
  );

  /// The maximum Y coordinate the top of the note may reach when scrolled
  /// down, in viewport pixels.
  final ValueNotifier<double> _topScrollLimit = ValueNotifier<double>(0);

  /// The region the palette was last laid out in, which a drag snaps to.
  Rect _paletteRegion = Rect.zero;
  EditorLayout? _lastLayout;

  /// Hands the shared top bar this editor's settings, when the bar is not
  /// this editor's own.
  EditorChromeScope? _chromeScope;
  Listenable? _fullscreenSettled;
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

  List<Rect> _nativeExclusionRects() {
    final EditorLayout? layout = _lastLayout;
    if (layout == null) return const <Rect>[];
    // An open menu hangs over the page wherever it likes, and its size is
    // not known here: while one is open, the pen is left to Flutter, which
    // lets the menu take the press.
    if (_paletteController.hasOpenPopover || _pageOverviewCovers) {
      return const <Rect>[Rect.fromLTRB(-1e6, -1e6, 1e6, 1e6)];
    }
    final Size paletteSize = ToolPalette.sizeFor(
      layout.paletteAxis,
      expanded: _paletteExpanded,
      tools: _paletteTools,
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
      ...?widget.inputExclusions?.call(),
      if (_toolbarShown.value) paletteRect.shift(origin),
      if (_pageOverviewOpen.value) _pageOverviewRect.shift(origin),
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

  /// Select's one option: whether a lasso takes the PDF paper inside it
  /// along with the ink, to copy, cut, delete, or move.
  final ValueNotifier<bool> _selectPdf = ValueNotifier<bool>(false);

  /// The ruler laid on the pages, shown from the palette's extension.
  final RulerController _ruler = RulerController();

  /// Touches a canvas has taken for the ruler, which the page
  /// view must not also scroll with.
  final PointerClaims _pointerClaims = PointerClaims();

  /// Whether the palette is unfolded: the screen lays out around its size.
  bool get _paletteExpanded => _paletteController.expanded.value;

  void _onToolbarShownChanged() {
    _onToolbarStateChanged();
    if (mounted) setState(() {});
  }

  void _onToolbarStateChanged() {
    final EditorLayout? layout = _lastLayout;
    if (layout != null) {
      _updateTopScrollLimit(layout);
    }
  }

  void _updateTopScrollLimit(EditorLayout layout) {
    final double limit = _computeTopScrollLimit(layout);
    if (_topScrollLimit.value == limit) return;
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _topScrollLimit.value != limit) {
          _topScrollLimit.value = limit;
        }
      });
    } else {
      _topScrollLimit.value = limit;
    }
  }

  double _computeTopScrollLimit(EditorLayout layout) {
    const double margin = AppSpacing.md;
    double limit = layout.history.bottom + margin;

    if (_toolbarShown.value && layout.paletteEdge == PaletteEdge.top) {
      final double toolbarHeight = ToolPalette.sizeFor(
        Axis.horizontal,
        expanded: _paletteExpanded,
        tools: _paletteTools,
      ).height;
      final double toolbarBottom = layout.paletteOrigin.dy + toolbarHeight;
      limit = math.max(limit, toolbarBottom + margin);

      final bool hasSubtoolbar = ToolPalette.showsOptions(
        _tool.value,
        _toolOptionsShown,
      );
      if (hasSubtoolbar) {
        final double subtoolbarBottom =
            toolbarBottom + ToolPalette.optionsGap + ToolOptionsBar.thickness;
        limit = math.max(limit, subtoolbarBottom + margin);
      }
    }

    return limit;
  }

  void _claimStylusGestures() {
    if (!mounted || !TickerMode.getValuesNotifier(context).value.enabled) {
      return;
    }
    NativeInkBridge.instance.claimStylusGestures(_onStylusGesture);
  }

  void _onStylusGesture(StylusGesture gesture) {
    if (!mounted || !TickerMode.getValuesNotifier(context).value.enabled) {
      return;
    }
    final StylusAction action = _stylusActions.value.actionFor(gesture);
    switch (action) {
      case StylusAction.none:
        return;
      case StylusAction.toggleToolOptions:
        _toolOptionsShown.value = !_toolOptionsShown.value;
        return;
      case StylusAction.toggleToolbar:
        if (_toolbarShown.value) _paletteController.closeAll();
        _toolbarShown.value = !_toolbarShown.value;
        return;
      case StylusAction.togglePenEraser:
        _tool.value = _tool.value == EditorTool.eraser
            ? EditorTool.pen
            : EditorTool.eraser;
        return;
      case StylusAction.previousTool:
        _tool.value = _previousTool;
        return;
      case StylusAction.pen:
        _penSettings.value = _penSettings.value.copyWith(
          style: WritingStyle.pen,
        );
        _tool.value = EditorTool.pen;
        return;
      case StylusAction.eraser:
        _tool.value = EditorTool.eraser;
        return;
      case StylusAction.highlighter:
        _penSettings.value = _penSettings.value.copyWith(
          style: WritingStyle.highlighter,
        );
        _tool.value = EditorTool.pen;
        return;
      case StylusAction.select:
        _tool.value = EditorTool.select;
        return;
      case StylusAction.undo:
        _undo();
        return;
      case StylusAction.redo:
        _redo();
        return;
    }
  }

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
    if (widget.readOnly || _scrolling || _anyPageBusy()) {
      return true;
    }
    final ToolPaletteController palette = _paletteController;
    if (_tool.value == EditorTool.sticky && palette.stickyMenu.isOpen) {
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
  late final RecordingTranscriptionController _transcription =
      RecordingTranscriptionController(
        transcriber:
            widget.recordingTranscriber ?? PlatformRecordingTranscriber(),
      );
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
    previewNotation: _previewNotation,
    endNotationPreview: _endNotationPreview,
    inkInArea: _inkInArea,
    shownPage: () => _inkController,
    notationEnabled: widget.initialNotationEnabled,
  );

  /// Waits for the pen to rest before the open chat's image is drawn again
  /// over the ink just written.
  Timer? _aiContextTimer;
  Size _surfaceSize = Size.zero;
  InkController? _notationControllerAtCapture;

  /// The request whose notation is being shown as it is written, the page it
  /// is on, and what draws it. One at a time: whichever finishes first changes
  /// the note, and so leaves the other nothing to add.
  NoteImage? _liveNotationRequest;
  InkController? _liveNotationController;
  LiveNotationPainter? _liveNotationPainter;
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

  /// A scope of our own has to be closed with the editor.
  NoteCacheScope? _ownedCacheScope;
  NoteCacheScope get _cacheScope =>
      widget.cacheScope ??
      (_ownedCacheScope ??= NoteCachePool(
        maxBytes: const CacheBudget().notesBytes,
      ).scope());

  /// What the paths of each page's ink are charged as, while they are kept.
  final Map<NotePage, NoteCacheItem> _inkItems = <NotePage, NoteCacheItem>{};

  /// Charges the paths of [page]'s ink, which painting the page builds. They
  /// go with the page when its turn comes.
  void _keepInkOf(NotePage page) {
    final int bytes = page.inkGeometryBytes;
    final NoteCacheItem? item = _inkItems[page];
    if (item != null) {
      item.resize(bytes);
      return;
    }
    _inkItems[page] = _cacheScope.add(
      page: page.cacheKey,
      bytes: bytes,
      onPop: () {
        _inkItems.remove(page);
        page.releaseInkGeometry();
      },
    );
  }

  /// The user has come to page [index]. A note working in a tab out of view
  /// has not been used for that.
  void _pageUsed(int index) {
    if (!mounted || !TickerMode.getValuesNotifier(context).value.enabled) {
      return;
    }
    final List<NotePage> pages = _document.pages;
    if (index < 0 || index >= pages.length) return;
    _cacheScope.touch(pages[index].cacheKey);
    _keepInkOf(pages[index]);
  }

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
            cacheScope: _cacheScope,
          ));
  }

  /// The outline of the PDF [assetId], for the page overview's chapters.
  Future<List<PdfOutlineEntry>> _loadPdfOutline(String assetId) =>
      _pageRenderCache?.outline(assetId) ??
      Future<List<PdfOutlineEntry>>.value(const <PdfOutlineEntry>[]);

  /// The note's chapters, read as soon as the note opens rather than when the
  /// overview first does, by when the PDF's pages have the renderer busy.
  /// Null without assets to read them from.
  NoteChapterIndex? _chapterIndex;

  void _indexChapters() {
    _chapterIndex?.dispose();
    _chapterIndex = widget.assetReader == null
        ? null
        : NoteChapterIndex(document: _document, loadOutline: _loadPdfOutline);
  }

  /// What the PDF paper was last focused with, to focus it again on another
  /// page as a scroll passes it, without building.
  _PdfFocusInputs? _pdfFocusInputs;
  int? _lastPdfFocusedPage;
  int _pdfScrollDirection = 1;

  /// Has the PDF paper of [current], by default the current page, and the
  /// pages around it rendered nearest first: [current] and those next to it
  /// sharp, further ones in preview, so paging through a PDF does not wait
  /// on each page.
  void _focusPdfPages(
    List<NotePage> pages,
    List<PageGeometry> geometries,
    double devicePixelRatio, {
    int? current,
  }) {
    final PdfPageRenderCache? cache = _pageRenderCache;
    if (cache == null) {
      return;
    }
    _pdfFocusInputs = (
      pages: pages,
      geometries: geometries,
      pixelRatio: devicePixelRatio,
    );
    current ??= _scrolledTo ?? _document.currentIndex;
    final int? previousFocus = _lastPdfFocusedPage;
    if (previousFocus != null && previousFocus != current) {
      _pdfScrollDirection = current.compareTo(previousFocus);
    }
    _lastPdfFocusedPage = current;
    final DocumentIoConfig config = widget.documentIoConfig;
    final List<PdfFocusPage> focus = <PdfFocusPage>[];
    int sharpPages = 0;
    for (int step = 0; step <= config.pdfPreloadDistance; step++) {
      final List<int> candidates = step == 0
          ? <int>[current]
          : _pdfScrollDirection < 0
          ? <int>[current - step, current + step]
          : <int>[current + step, current - step];
      for (final int index in candidates) {
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
      final List<int> candidates = step == 0
          ? <int>[current]
          : _pdfScrollDirection < 0
          ? <int>[current - step, current + step]
          : <int>[current + step, current - step];
      for (final int index in candidates) {
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

  Future<Uint8List> _readRecording(NoteRecordingTrack track) async {
    final NoteRepository? repository = widget.repository;
    final String? noteId = widget.noteId;
    if (repository != null && noteId != null) {
      return (await repository.readAsset(noteId, track.assetPath)).bytes;
    }
    return File(track.assetPath).readAsBytes();
  }

  /// Transcribes [track] on the device. Only ever started by the user, and
  /// never while a recording is being made.
  Future<void> _transcribeRecording(NoteRecordingTrack track) async {
    if (_audioRecorder.state != NoteAudioRecorderState.idle) return;
    try {
      final RecordingTranscript transcript = await _transcription.transcribe(
        track,
        readAudio: () => _readRecording(track),
      );
      if (!mounted) return;
      if (!_document.setRecordingTranscript(track.id, transcript)) return;
      _rebuildChrome();
      final NoteRecordingTrack transcribed = _document.recordings.firstWhere(
        (NoteRecordingTrack item) => item.id == track.id,
      );
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text('${track.title} is transcribed.'),
          action: SnackBarAction(
            label: 'Show',
            onPressed: () => _showTranscript(transcribed),
          ),
        ),
      );
    } on TranscriptionFailure catch (failure) {
      if (!mounted || failure.kind == TranscriptionFailureKind.cancelled) {
        return;
      }
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(failure.message)));
    }
  }

  void _showTranscript(NoteRecordingTrack track) {
    if (!mounted) return;
    unawaited(
      showRecordingTranscript(
        context,
        track: track,
        onSeek: (Duration position) => unawaited(_playFrom(track, position)),
      ),
    );
  }

  /// Replays [track] from [position], opening it first if it is not open.
  Future<void> _playFrom(NoteRecordingTrack track, Duration position) async {
    if (_audioRecorder.state != NoteAudioRecorderState.idle) return;
    if (_strokeReplay.track?.id != track.id) {
      await _openReplay(track);
      if (_strokeReplay.track?.id != track.id) return;
    }
    await _audioPlayer.seek(position);
    await _audioPlayer.play();
  }

  Future<void> _openReplay(NoteRecordingTrack track) async {
    try {
      final Uint8List bytes = await _readRecording(track);
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
    ink.completedStrokesListenable.addListener(_appendPageNearEnd);
    ink.completedStrokesListenable.addListener(_onInkForRecognition);
    ink.completedStrokesListenable.addListener(_onInkForAiContext);
    ink.eraserListenable.addListener(_onEraserForInk);
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
    // Left in the middle of an erase. Only the words of this page need it;
    // the rest is about whichever page is current, which may be another now.
    if (_inkChangedInErase) {
      _inkChangedInErase = false;
      final NotePage? page = _pageFor(ink);
      if (page != null) _document.reconcileRecognizedWords(page);
    }
    ink.eraserListenable.removeListener(_onEraserForInk);
    ink.selectionListenable.removeListener(_onSelectionChanged);
    ink.completedStrokesListenable.removeListener(_appendPageNearEnd);
    ink.completedStrokesListenable.removeListener(_onInkForRecognition);
    ink.completedStrokesListenable.removeListener(_onInkForAiContext);
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
    // Ink that only moved, as when a page becomes a whiteboard, is not new
    // ink: it is not read again.
    final List<Stroke> moved = <Stroke>[
      for (final MapEntry<Stroke, Stroke> entry in replacements.entries)
        if (_knownPageStrokes.remove(entry.key)) entry.value,
    ];
    _knownPageStrokes.addAll(moved);
    final NotePage? page = _pageFor(_inkController);
    if (page != null) {
      _document.reconcileRecognizedWords(page, replacements: replacements);
    }
  }

  /// Whether ink changed during the erase under way, which [_onEraserForInk]
  /// answers for when it ends. An eraser changes the page on nearly every
  /// move, and what follows from a change looks at every stroke on the page:
  /// too much for each move, and needed only for where the erase ends up. It
  /// makes no ink to read, and nothing that can reach further down the page.
  bool _inkChangedInErase = false;

  /// Leaves the rest of a change to the end of an erase, if one is under way.
  bool _deferToEndOfErase() {
    if (_inkController.activeErase == null) return false;
    _inkChangedInErase = true;
    return true;
  }

  void _onEraserForInk() {
    if (!_inkChangedInErase || _inkController.activeErase != null) return;
    _inkChangedInErase = false;
    _appendPageNearEnd();
    _onInkForRecognition();
  }

  void _onInkForRecognition() {
    _handwritingFindTarget.value = null;
    if (_deferToEndOfErase()) return;
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
      if (previous != null) {
        final NotePage? left = _pageFor(previous);
        // Its ink may have changed while it was written on.
        if (left != null) _keepInkOf(left);
        _pageUsed(_document.currentIndex);
      }
      _pastePrompt.value = null;
      _scrolling = false;
      _onSelectionChanged();
    }
    if (mounted) {
      setState(() {});
    }
  }

  /// Two fingers began scrolling: whatever they started on any page is not
  /// writing, erasing, or selecting.
  /// The part of the current whiteboard on screen, in page units, while one
  /// is shown.
  ValueListenable<Rect>? _boardVisible;

  /// Where something placed "in view", such as an inserted picture, goes:
  /// the whole of a paper page, or the part of a whiteboard on screen.
  Rect get _visiblePart {
    final Rect page = Offset.zero & _surfaceSize;
    final Rect? board = _document.current.setup.size == PageSize.infinite
        ? _boardVisible?.value
        : null;
    if (board == null || board.isEmpty) return page;
    return board.intersect(page);
  }

  void _onScrollStart(Set<int> pointers) {
    // Native wet ink is painted in a root-view overlay, not inside the page
    // transform, so a stroke still being drawn cannot go along with the page.
    // Finished strokes are not cleared here: the press that began this scroll
    // already told each canvas to draw them, and clearing them before that
    // reaches the screen would blink them off.
    if (widget.enableNativeInk) {
      NativeInkBridge.instance.clearLivePreview();
    }
    _scrolling = true;
    _scrollSettle?.cancel();
    _scrolledTo = null;
    for (final int pointer in pointers) {
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

  /// The page scrolled to the middle of the area, made current once the
  /// scroll settles: making a page current rebuilds the whole editor, which
  /// a fling past a page every few frames could not afford. Meanwhile only
  /// the PDF paper follows, rendered around the page in view.
  int? _scrolledTo;
  Timer? _scrollSettle;

  void _onScrolledToPage(int index) {
    if (_scrolledTo != index) _pageUsed(index);
    _scrolledTo = index;
    final _PdfFocusInputs? inputs = _pdfFocusInputs;
    if (inputs != null && index < inputs.pages.length) {
      _focusPdfPages(
        inputs.pages,
        inputs.geometries,
        inputs.pixelRatio,
        current: index,
      );
    }
    _scrollSettle?.cancel();
    // A page becoming current rebuilds the editor. Keep that work, and any
    // programmatic page-top jump it could be mistaken for, out of a drag or
    // ballistic coast. PageViewport calls _onScrollEnd after inertia ends.
    if (_scrolling) return;
    // Pointer-signal wheels have no end callback. A short inactivity window
    // commits them; touch and trackpad momentum take the explicit
    // _onScrollEnd path above instead.
    _scrollSettle = Timer(const Duration(milliseconds: 100), () {
      final int? settled = _scrolledTo;
      _scrolledTo = null;
      if (mounted && settled != null) _showPage(settled);
    });
  }

  /// A page touched becomes current at once, ahead of any scroll settling.
  void _onPageTouched(int index) {
    _claimStylusGestures();
    _scrollSettle?.cancel();
    _scrolledTo = null;
    _showPage(index);
  }

  /// A scroll slowing down has the PDF paper in view rendered sharp before
  /// it stops.
  void _onScrollSpeed(double speed) => _pdfCache?.scrollSpeed(speed);

  void _onScrollEnd() {
    _pdfCache?.scrollEnded();
    _scrolling = false;
    _scrollSettle?.cancel();
    final int? settled = _scrolledTo;
    _scrolledTo = null;
    if (mounted && settled != null) _showPage(settled);
  }

  /// The column was pulled up past its last page: a new page goes after
  /// it, below, and the view stays where it is.
  void _addPageAtEnd() {
    if (!widget.allowPageManagement || widget.readOnly || _anyPageBusy()) {
      return;
    }
    _document.appendPage();
  }

  /// Writing down into the last page past [PageConfig.appendPageAt] of its
  /// height adds an empty page after it. The view does not move: scrolling
  /// on finds the new page waiting, with no pull to make. An infinite page
  /// grows instead.
  void _appendPageNearEnd() {
    if (!widget.allowPageManagement || widget.readOnly) return;
    if (_deferToEndOfErase()) return;
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

  /// Whether the page overview shows, down the left side of the editor.
  late final ValueNotifier<bool> _pageOverviewOpen = ValueNotifier<bool>(false)
    ..addListener(_onPageOverviewChanged);

  /// Whether pages or chapters show in the overview, kept between openings.
  final ValueNotifier<PageOverviewView> _pageOverviewView =
      ValueNotifier<PageOverviewView>(PageOverviewView.pages);

  /// Where the open overview is, in the body's coordinates.
  Rect _pageOverviewRect = Rect.zero;

  /// Whether the open overview lies over the page, there being no room
  /// beside it: it then takes the pen from the native layer, as a popover
  /// does, and closes once a page is chosen.
  bool _pageOverviewCovers = false;

  void _onPageOverviewChanged() {
    setState(() {});
    // Once laid out: the native layer asks where the overview is.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _paletteController.popoverChanged.notify();
    });
  }

  void _togglePageOverview() {
    _pageOverviewOpen.value = !_pageOverviewOpen.value;
  }

  void _closePageOverview() => _pageOverviewOpen.value = false;

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
    final Rect? focusBounds = _ai.context?.logicalBounds;
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
        // Asked about nothing: the notes go in this page's blank space.
        focusOnFreeSpace: focusBounds == null,
        bitmaps: bitmaps,
        stickies: controller.stickyNotes,
        aiNotes: _ai.notationStrokesIn(controller.strokes),
      ),
    );
  }

  /// The strokes more than half of whose points lie in [area], on [page]
  /// when it is one of the note's pages, else on the page holding any of
  /// [anchors].
  Iterable<Stroke> _inkInArea(
    Rect area,
    Object? page,
    Iterable<Stroke> anchors,
  ) {
    InkController? ink;
    for (final NotePage notePage in _document.pages) {
      if (identical(notePage.ink, page)) {
        ink = notePage.ink;
        break;
      }
    }
    if (ink == null) {
      final Set<Stroke> known = Set<Stroke>.identity()..addAll(anchors);
      for (final NotePage notePage in _document.pages) {
        if (notePage.ink.strokes.any(known.contains)) {
          ink = notePage.ink;
          break;
        }
      }
    }
    if (ink == null) return const <Stroke>[];
    return <Stroke>[
      for (final Stroke stroke in ink.strokes)
        if (area.overlaps(stroke.bounds) &&
            stroke.points
                        .where((InkVector p) => area.contains(Offset(p.x, p.y)))
                        .length *
                    2 >
                stroke.points.length)
          stroke,
    ];
  }

  /// Draws the open chat's image again once the pen rests, so it shows what
  /// was just written, or erased, where its ink lies.
  void _onInkForAiContext() {
    if (!_ai.isOpen) return;
    _aiContextTimer?.cancel();
    _aiContextTimer = Timer(
      const Duration(milliseconds: 400),
      _ai.refreshContextImage,
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
    // The assistant never writes over, or crowds, the ink on the page: the
    // user's notes or its own earlier ones.
    final NotationClearance clearance = _notationClearance(
      controller,
      requestContext.logicalSize,
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

  /// Keeps what a notation writes clear of every stroke on [controller]'s
  /// page, a paper [size] big.
  NotationClearance _notationClearance(InkController controller, Size size) {
    return NotationClearance(
      pageSize: size,
      ink: <SpaceStroke>[
        for (final Stroke stroke in controller.strokes)
          (points: stroke.points, width: stroke.style.width),
      ],
    );
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
    if (!_svgFitsPage(vector, requestContext.logicalSize)) {
      return const AiNotationApplication(AiNotationStatus.notAppliedInvalid);
    }
    final SvgInkConversion conversion;
    try {
      conversion = _svgInk(
        vector,
        controller,
        requestContext.logicalSize,
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
      limits: _svgInkLimits,
    );
    List<Stroke> added() {
      final List<Stroke> strokes = controller.strokes.sublist(
        controller.strokes.length - conversion.traces.length,
      );
      if (!_showAiNotes) controller.setStrokesHidden(strokes, true);
      return strokes;
    }

    // One stroke per trace, in order, so each keeps its trace's paragraph.
    final List<int?> paragraphs = <int?>[
      for (final GeneratedInkTrace trace in conversion.traces)
        trace.answerParagraph,
    ];
    return switch (result) {
      AddNotationResult.added => AiNotationApplication(
        AiNotationStatus.applied,
        strokes: added(),
        paragraphs: paragraphs,
      ),
      AddNotationResult.addedWithPlayback => AiNotationApplication(
        AiNotationStatus.animating,
        presentation: _PlaybackPresentation(
          controller,
          controller.notationPlayback!,
        ),
        strokes: added(),
        paragraphs: paragraphs,
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

  static const GeneratedInkLimits _svgInkLimits = GeneratedInkLimits(
    maxPointsPerTrace: 8192,
    maxTotalPoints: 250000,
    maxPlaybackDuration: Duration(seconds: 20),
  );

  /// Whether [vector] is drawn in the coordinates of a page [size] big, and
  /// stays on it.
  static bool _svgFitsPage(EditableSvg vector, Size size) {
    final Rect page = Offset.zero & size;
    final Rect viewBox = vector.viewBox;
    final Rect bounds = vector.contentBounds;
    const double tolerance = 0.01;
    return (viewBox.left).abs() <= tolerance &&
        (viewBox.top).abs() <= tolerance &&
        (viewBox.width - page.width).abs() <= tolerance &&
        (viewBox.height - page.height).abs() <= tolerance &&
        page.inflate(tolerance).contains(bounds.topLeft) &&
        page.inflate(tolerance).contains(bounds.bottomRight) &&
        !bounds.isEmpty;
  }

  /// [vector] as ink in the user's hand and pen. Throws a [FormatException]
  /// when it cannot be.
  SvgInkConversion _svgInk(
    EditableSvg vector,
    InkController controller,
    Size size, {
    required bool animate,
  }) {
    final StrokeStyle userPenStyle = _penSettings.value.strokeStyle();
    final EditableSvg styled = SvgNotationStyler.apply(
      vector,
      handwriting:
          HandwritingCalibration.current.value ?? HandwritingStyle.standard,
      defaultInk: userPenStyle.ink,
      penWidth: userPenStyle.width,
      snapper: InkSnapper(<List<InkVector>>[
        for (final Stroke stroke in controller.strokes) stroke.points,
      ], reach: const AiNotationConfig().inkSnapDistance),
      // Its writing keeps some space from the user's notes, and its own.
      clearance: _notationClearance(controller, size),
      maxTextSize: HandwritingCalibration.textSize.value.max,
    );
    return SvgInkConverter.convert(
      styled,
      defaultInk: userPenStyle.ink,
      defaultWidth: userPenStyle.width,
      animate: animate,
      skipInvalidElements: true,
    );
  }

  void _previewNotation(String svg, NoteImage request) {
    if (!mounted) return;
    if (_liveNotationRequest == null) {
      _liveNotationRequest = request;
      _liveNotationController = _notationControllerAtCapture;
      _liveNotationPainter = LiveNotationPainter(
        (String document) => _drawLiveNotation(document, request),
      );
    }
    if (identical(_liveNotationRequest, request)) {
      _liveNotationPainter?.add(svg);
    }
  }

  /// Shows [document] the way [_applySvgNotation] would add it, static, for
  /// as long as it could still be added. Any timed notation plays from the
  /// start once it has been.
  void _drawLiveNotation(String document, NoteImage request) {
    final InkController? controller = _liveNotationController;
    if (controller == null || !mounted) return;
    if (!identical(controller, _inkController) ||
        controller.documentRevision != request.revision ||
        request.logicalSize != _surfaceSize ||
        !_showAiNotes) {
      controller.clearNotationPreview();
      return;
    }
    final EditableSvg vector = EditableSvg.parse(document);
    if (!_svgFitsPage(vector, request.logicalSize)) return;
    final SvgInkConversion conversion = _svgInk(
      vector,
      controller,
      request.logicalSize,
      animate: false,
    );
    controller.showNotationPreview(
      traces: conversion.traces,
      surfaceSize: request.logicalSize,
      limits: _svgInkLimits,
    );
  }

  void _endNotationPreview(NoteImage request) {
    if (!identical(_liveNotationRequest, request)) return;
    _liveNotationPainter?.close();
    _liveNotationController?.clearNotationPreview();
    _liveNotationPainter = null;
    _liveNotationController = null;
    _liveNotationRequest = null;
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
    if (widget.readOnly) return;
    if (_inkController.canPaste) {
      _tool.value = EditorTool.select;
      _selectionCarry.clearSelection(except: _inkController);
      _inkController.paste();
    }
  }

  void _undo() {
    if (widget.readOnly) return;
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
    if (widget.readOnly) return;
    _pastePrompt.value = null;
    _document.redo();
  }

  /// Pastes with the copies centered where the pointer was held.
  void _pasteAt(Offset position) {
    if (widget.readOnly) return;
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
    if (widget.readOnly) return;
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
  /// adds that excerpt to the ordinary in-app image clipboard. Cut leaves
  /// the paper blank where the excerpt was.
  Future<void> _copyPdfSelection(
    InkSelection selection, {
    required bool cut,
  }) async {
    final NoteRepository? repository = widget.repository;
    final String? noteId = widget.noteId;
    if (repository == null || noteId == null) {
      _showPdfCopyError();
      return;
    }
    final int generation = ++_pdfClipboardGeneration;
    final InkController controller = _inkController;
    NoteImageElement? image;
    try {
      image = await _pdfExcerpt(
        controller,
        selection,
        wanted: () =>
            mounted &&
            generation == _pdfClipboardGeneration &&
            identical(selection, controller.selection) &&
            identical(controller, _inkController),
      );
      if (image == null) {
        return;
      }
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
        await repository.removeAsset(noteId, image.assetId);
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
      if (image != null) {
        try {
          await repository.removeAsset(noteId, image.assetId);
        } on Object {
          // Asset cleanup is retried when the note closes.
        }
      }
      if (mounted && generation == _pdfClipboardGeneration) {
        _showPdfCopyError();
      }
    }
  }

  /// Renders the PDF paper [selection] holds on [controller]'s page, the
  /// current one, and stores it as an image of the note, placed where that
  /// paper lies. Areas of the paper already left blank stay blank. Returns
  /// null, keeping nothing stored, once [wanted] stops being true. Throws
  /// when the excerpt cannot be made.
  Future<NoteImageElement?> _pdfExcerpt(
    InkController controller,
    InkSelection selection, {
    required bool Function() wanted,
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
      throw StateError('This PDF selection cannot be rendered');
    }
    final List<Rect> blanks = List<Rect>.of(controller.pdfMasks);
    final double pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final Uint8List page = await cache.render(
      source,
      source.pageSize,
      pixelRatio,
    );
    final PdfSelectionImage excerpt = await Isolate.run(
      () => cropPdfSelection(
        page,
        source.pageSize,
        requestedBounds,
        blanks: blanks,
      ),
    );
    if (!wanted()) {
      return null;
    }
    final String assetId = await repository.storeAsset(
      noteId,
      excerpt.png,
      kind: NoteAssetKind.image,
      extension: 'png',
      fileName: 'PDF page ${source.pageIndex + 1} excerpt.png',
    );
    if (!wanted()) {
      await repository.removeAsset(noteId, assetId);
      return null;
    }
    final Rect bounds = excerpt.logicalBounds;
    return NoteImageElement(
      id: NoteImageElement.newId('pdf-excerpt'),
      assetId: assetId,
      pixelSize: excerpt.pixelSize,
      center: InkVector(bounds.center.dx, bounds.center.dy),
      size: bounds.size,
      fileName: 'PDF page ${source.pageIndex + 1} excerpt.png',
    );
  }

  /// The PDF selection whose paper is being readied to be moved, if any.
  InkSelection? _pdfLiftSelection;

  /// The image readied for [_pdfLiftSelection], and the page it is for.
  ({InkController controller, NoteImageElement image})? _pdfLift;

  /// With Select PDF on, readies the PDF paper of a fresh selection on the
  /// current page to be moved: a drag on it then lifts it off the page at
  /// once, with no wait for the paper to be rendered.
  void _preparePdfLift() {
    final InkController controller = _inkController;
    final InkSelection? selection = controller.selection;
    if (identical(selection, _pdfLiftSelection)) {
      return;
    }
    _discardPdfLift();
    if (!_selectPdf.value || selection == null || !selection.includesPdf) {
      return;
    }
    _pdfLiftSelection = selection;
    // A lift that moved nothing hands its image back to the page.
    final NoteImageElement? ready = controller.pendingPdfLift;
    if (controller.canLiftPdfSelection && ready != null) {
      _pdfLift = (controller: controller, image: ready);
      return;
    }
    unawaited(_readyPdfLift(controller, selection));
  }

  Future<void> _readyPdfLift(
    InkController controller,
    InkSelection selection,
  ) async {
    try {
      final NoteImageElement? image = await _pdfExcerpt(
        controller,
        selection,
        wanted: () =>
            mounted &&
            identical(_pdfLiftSelection, selection) &&
            identical(controller.selection, selection),
      );
      if (image == null) {
        return;
      }
      controller.preparePdfLift(selection, image);
      _pdfLift = (controller: controller, image: image);
    } on Object {
      // The paper can still be copied, cut, or deleted; it just cannot be
      // moved.
    }
  }

  /// Lets go of the readied PDF paper, and of its stored image unless it
  /// was lifted onto the page.
  void _discardPdfLift() {
    _pdfLiftSelection = null;
    final ({InkController controller, NoteImageElement image})? lift = _pdfLift;
    _pdfLift = null;
    final NoteRepository? repository = widget.repository;
    final String? noteId = widget.noteId;
    if (lift == null ||
        repository == null ||
        noteId == null ||
        !identical(lift.controller.pendingPdfLift, lift.image)) {
      return;
    }
    lift.controller.forgetPdfLift();
    unawaited(
      repository.removeAsset(noteId, lift.image.assetId).catchError((Object _) {
        // Asset cleanup is retried when the note closes.
      }),
    );
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
    if (tool != _observedTool) {
      _previousTool = _observedTool;
      _observedTool = tool;
    }
    if (tool != EditorTool.ai) {
      _writingTool = tool;
    }
    _onToolbarStateChanged();
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
  void _useCurrentSelection() {
    unawaited(() async {
      await _captureForAi(open: false);
      if (mounted) _ai.requestComposer();
    }());
  }

  /// Adds the current selection to the open conversation's ink.
  Future<void> _addSelectionToAi() async {
    final InkSelection? selection = _stableSelection();
    if (selection == null) return;
    final InkController page = _inkController;
    final List<SnapshotBitmap> bitmaps = await _selectionBitmaps(selection);
    if (!mounted || !identical(selection, _stableSelection())) return;
    _ai.addToContext(selection, bitmaps: bitmaps, page: page);
    _ai.requestComposer();
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
      if (_ai.selectionChanged) {
        // A second context is only a proposal until the user chooses how it
        // belongs. Keep the keyboard down while those choices are visible.
        _editorFocus.requestFocus();
      } else {
        _ai.requestComposer();
      }
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

  /// Something chosen with the AI tool, which selects as the Select tool
  /// does, becomes what the assistant is asked about. A [tap] on a context
  /// frame instead takes that group out of the conversation.
  void _onAiSelection(InkVector? tap, InkController page) {
    if (!mounted || (tap != null && _removeAiContextAt(tap, page))) return;
    unawaited(_captureForAi(open: true, ask: true));
  }

  /// Removes the context group framed at [position], if there is one.
  bool _removeAiContextAt(InkVector position, InkController page) {
    final AiSelectionContext? context = _ai.context;
    if (context == null || context.isPage) return false;
    final List<AiContextGroup> groups = context.groups;
    for (int i = groups.length - 1; i >= 0; i--) {
      final AiContextGroup group = groups[i];
      final Object? owner = group.page;
      final bool onPage = owner != null
          ? identical(owner, page)
          : (group.strokes.isNotEmpty &&
                    page.strokes.contains(group.strokes.first)) ||
                (group.images.isNotEmpty &&
                    page.images.contains(group.images.first));
      final Rect? bounds = group.bounds;
      if (onPage &&
          bounds != null &&
          bounds
              .inflate(page.selectionConfig.handleHitRadius)
              .contains(Offset(position.x, position.y))) {
        _ai.removeContext(group);
        _selectionCarry.clearSelection();
        _editorFocus.requestFocus();
        return true;
      }
    }
    return false;
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
          stylusActions: _stylusActions,
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
        visiblePage: _visiblePart,
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
      final Rect frame = _document.current.frame(_surfaceSize);
      await SvgExporter(sink: widget.exportSink).exportAndShare(
        title: widget.title,
        pageSize: frame.size,
        origin: frame.topLeft,
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
      final bool wasPending = _ai.selectionChanged;
      _ai.updateCurrentSelection(
        _selectionCarry.combinedSelectionFor(controller),
      );
      if (!wasPending && _ai.selectionChanged) {
        // The selection choice must be made before the composer becomes the
        // active destination for typing.
        _editorFocus.requestFocus();
      }
      _preparePdfLift();
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
    _indexChapters();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // PDF paper reports itself once rendered.
      if (mounted &&
          (_document.current.pdfSource == null || _pageRenderCache == null)) {
        _pageShown();
      }
      _claimStylusGestures();
    });
    _attachInk(_inkController);
    _selectionCarry.addListener(_onSelectionChanged);
    _selectPdf.addListener(_preparePdfLift);
    _document.addListener(_onDocumentChanged);
    _ai.addListener(_onAiChanged);
    _ai.paragraphFocus.addListener(_onParagraphFocusChanged);
    _palettePlacement.addListener(_onPalettePlacementChanged);
    _toolbarShown.addListener(_onToolbarShownChanged);
    _toolOptionsShown.addListener(_onToolbarStateChanged);
    _toolbarLayout.addListener(_onPalettePlacementChanged);
    _paletteController.expanded.addListener(_onPalettePlacementChanged);
    _paletteController.expanded.addListener(_rememberToolbar);
    _tool.addListener(_rememberToolbar);
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

  /// The page slid with the top bar without being laid out: the native pen
  /// surface has to hear where it now is, or strokes land off from the pen.
  void _onFullscreenSettled() => _paletteController.popoverChanged.notify();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final Listenable? settled = EditorFullscreenScope.maybeOf(context)?.settled;
    if (settled != _fullscreenSettled) {
      _fullscreenSettled?.removeListener(_onFullscreenSettled);
      settled?.addListener(_onFullscreenSettled);
      _fullscreenSettled = settled;
    }
    final EditorChromeScope? scope = EditorChromeScope.maybeOf(context);
    final EditorChromeScope? previous = _chromeScope;
    // Only a different window or note takes the bar back; the toolbar
    // passing to or from this editor does not.
    if (scope?.host != previous?.host || scope?.noteId != previous?.noteId) {
      _retractChrome();
      _chromeScope = scope;
      _restoreToolbar();
    } else {
      _chromeScope = scope;
    }
  }

  /// Takes up what this tab had on the shared toolbar, kept while its
  /// editor was put away. No haptic: nothing was chosen just now.
  void _restoreToolbar() {
    final EditorChromeScope? scope = _chromeScope;
    final ToolbarMemo? memo = scope?.host.toolbarOf(scope.noteId);
    if (memo == null) return;
    if (memo.tool != EditorTool.ai && memo.tool != _tool.value) {
      _tool.removeListener(AppHaptics.toolSwitch);
      _tool.value = memo.tool;
      _tool.addListener(AppHaptics.toolSwitch);
    }
    _paletteController.expanded.value = memo.expanded;
  }

  /// Keeps what this tab has on the shared toolbar, for when it is shown
  /// again after its editor was put away.
  void _rememberToolbar() {
    final EditorChromeScope? scope = _chromeScope;
    scope?.host.rememberToolbar(
      scope.noteId,
      ToolbarMemo(
        tool: _tool.value,
        expanded: _paletteController.expanded.value,
      ),
    );
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

  void _onPalettePlacementChanged() {
    _onToolbarStateChanged();
    setState(() {});
  }

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
      tools: _paletteTools,
    );
    // Commit the dock while the drag position still owns the visual origin.
    // Releasing it afterwards lets the palette's paint translation ease
    // from the exact drop point to the committed edge without a jump.
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
    if (oldWidget.toolbarLayout != widget.toolbarLayout) {
      (oldWidget.toolbarLayout ?? _ownedToolbarLayout)?.removeListener(
        _onPalettePlacementChanged,
      );
      _toolbarLayout.addListener(_onPalettePlacementChanged);
    }
    if (oldWidget.toolbarShown != widget.toolbarShown) {
      (oldWidget.toolbarShown ?? _ownedToolbarShown)?.removeListener(
        _onToolbarShownChanged,
      );
      _toolbarShown.addListener(_onToolbarShownChanged);
    }
    if (oldWidget.toolOptionsShown != widget.toolOptionsShown) {
      (oldWidget.toolOptionsShown ?? _ownedToolOptionsShown)?.removeListener(
        _onToolbarStateChanged,
      );
      _toolOptionsShown.addListener(_onToolbarStateChanged);
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
      _lastPdfFocusedPage = null;
      _pdfScrollDirection = 1;
      _document.addListener(_onDocumentChanged);
      _adoptAiSession();
      _setAiNotesHidden(!_showAiNotes);
      _onDocumentChanged();
      _indexChapters();
      owned?.dispose();
    } else if (oldWidget.assetReader != widget.assetReader ||
        oldWidget.pdfRasterizer != widget.pdfRasterizer ||
        oldWidget.documentIoConfig != widget.documentIoConfig) {
      _indexChapters();
    }
  }

  @override
  void dispose() {
    _scrollSettle?.cancel();
    _fullscreenSettled?.removeListener(_onFullscreenSettled);
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
    _transcription.dispose();
    _findEntry?.remove();
    _findEntry = null;
    _findDrag.dispose();
    _retractChrome();
    _indexingGeneration++;
    _indexingTimer?.cancel();
    _aiContextTimer?.cancel();
    final InkController? listened = _listenedInk;
    if (listened != null) {
      _detachInk(listened);
    }
    _selectionCarry
      ..removeListener(_onSelectionChanged)
      ..dispose();
    _discardPdfLift();
    _selectPdf.dispose();
    _releaseAiSession();
    _document.removeListener(_onDocumentChanged);
    _ai.removeListener(_onAiChanged);
    _ai.paragraphFocus.removeListener(_onParagraphFocusChanged);
    _toolOptionsShown.removeListener(_onToolbarStateChanged);
    _topScrollLimit.dispose();
    _palettePlacement.removeListener(_onPalettePlacementChanged);
    _toolbarShown.removeListener(_onToolbarShownChanged);
    _toolbarLayout.removeListener(_onPalettePlacementChanged);
    _ownedToolbarLayout?.dispose();
    NativeInkBridge.instance.releaseStylusGestures(_onStylusGesture);
    _paletteController.expanded
      ..removeListener(_onPalettePlacementChanged)
      ..dispose();
    _ruler.dispose();
    // An answer still on its way is waited for, and saved with the note: the
    // client it is coming through is closed once it has.
    final AiClient? ownedClient = _ownedAiClient;
    _ai.retire(
      session: _document.aiSession,
      save: widget.onAiSessionRetired,
      release: ownedClient?.close,
    );
    _editorFocus.dispose();
    _ownedDocument?.dispose();
    _tool
      ..removeListener(AppHaptics.toolSwitch)
      ..removeListener(_onToolChanged)
      ..dispose();
    _aiActive.dispose();
    _ownedPenSettings?.dispose();
    _ownedPalettePlacement?.dispose();
    _ownedToolOptionsShown?.dispose();
    _ownedToolbarShown?.dispose();
    _ownedStylusActions?.dispose();
    _paletteDragCenter.dispose();
    _eraserSettings.dispose();
    _stickySettings.dispose();
    _textSettings.dispose();
    _pageOverviewOpen.dispose();
    _pageOverviewView.dispose();
    _chapterIndex?.dispose();
    _pastePrompt.dispose();
    _handwritingFindTarget.dispose();
    _ownedStylusOnly?.dispose();
    MemoryPressure.instance.removeListener(_releaseMemory);
    _pdfCache?.clear();
    _imageCache?.clear();
    for (final NoteCacheItem item in _inkItems.values) {
      item.remove();
    }
    _ownedCacheScope?.close();
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
          // On a phone the overview fills the screen, so back closes it.
          final bool overviewFills =
              _pageOverviewOpen.value && sizeClass == WindowSizeClass.compact;
          return PopScope(
            canPop: !sheet && !overviewFills,
            onPopInvokedWithResult: (bool didPop, Object? _) {
              if (didPop) return;
              if (sheet) {
                _closeAi();
              } else {
                _closePageOverview();
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

  /// The paragraph whose ink was last brought into view on its own.
  AiParagraphRef? _revealedParagraph;

  /// Keeps the ink of the paragraph being read in view as the chat moves on
  /// to another, unless a pen or a hand is at work on the note: that is left
  /// where it is, and only the mark changes.
  void _onParagraphFocusChanged() {
    final AiParagraphRef? ref = _ai.paragraphFocus.value?.ref;
    if (ref == _revealedParagraph) return;
    _revealedParagraph = ref;
    if (ref == null || !_ai.isOpen || _scrolling || _anyPageBusy()) return;
    // The mark is laid out with the next frame.
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted && _ai.isOpen && !_scrolling && !_anyPageBusy()) {
        _showFocusedParagraphOnNote();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Brings into view what the paragraph being read is tied to, going to its
  /// page only when that page is too far away to scroll to. Moves nothing if
  /// it is all in view already.
  void _showFocusedParagraphOnNote() {
    final AiParagraphFocus? focus = _ai.paragraphFocus.value;
    if (focus == null) return;
    final List<NotePage> pages = _document.pages;
    final Set<Stroke> tied = Set<Stroke>.identity()
      ..addAll(focus.links.cited)
      ..addAll(focus.links.drawn);
    int? target;
    for (int i = 0; i < pages.length && target == null; i++) {
      if (pages[i].ink.strokes.any(tied.contains)) target = i;
    }
    if (target == null && focus.links.circles.isNotEmpty) {
      final Object? owner = _ai.context?.groups.firstOrNull?.page;
      final int index = pages.indexWhere(
        (NotePage page) => identical(page.ink, owner),
      );
      if (index >= 0) target = index;
    }
    if (target == null) return;
    final InkController page = pages[target].ink;
    if (_ai.revealOnNote(page)) return;
    _showPage(target);
    // The page is laid out where it now is by the next frame.
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted) _ai.revealOnNote(page);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Widget _buildAssistantPanel() {
    return AiAssistantPanel(
      key: _aiPanelKey,
      controller: _ai,
      config: widget.aiLayoutConfig,
      onClose: _closeAi,
      onNewChat: _useCurrentSelection,
      onAddToContext: _addSelectionToAi,
      onShowOnNote: _showFocusedParagraphOnNote,
      onImportToStudyDesk: widget.onImportConversationToStudyDesk == null
          ? null
          : () => widget.onImportConversationToStudyDesk!(
              List<AiMessage>.of(_ai.messages),
            ),
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
    final VoidCallback? exitFullscreen = EditorFullscreenScope.maybeOf(
      context,
    )?.onExit;
    return Scaffold(
      // The keyboard only ever serves the assistant's composer, which lifts
      // itself clear of it. Resizing the body would lay the page out again
      // on every frame of the keyboard's slide and make it stutter.
      resizeToAvoidBottomInset: false,
      // Under tabs, the bar is theirs, and shared by every pane.
      appBar: !widget.showAppBar || _chromeScope != null
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
            final AiLayoutConfig aiLayout = widget.aiLayoutConfig;
            final bool overviewOpen = _pageOverviewOpen.value;
            // Beside the page when both have room, with the assistant's
            // narrowest panel too if it is open; otherwise over them.
            final bool overviewCovers =
                overviewOpen &&
                (sizeClass == WindowSizeClass.compact ||
                    size.width -
                            PageOverviewPanel.width -
                            (panelSide == null ? 0 : aiLayout.minPanelWidth) <
                        aiLayout.minEditorWidth);
            // How much of the left side it takes from what is beside it.
            final double overviewInset = overviewOpen && !overviewCovers
                ? PageOverviewPanel.width
                : 0;
            _pageOverviewCovers = overviewCovers;
            _pageOverviewRect = !overviewOpen
                ? Rect.zero
                : Rect.fromLTWH(
                    0,
                    0,
                    sizeClass == WindowSizeClass.compact
                        ? size.width
                        : PageOverviewPanel.width,
                    size.height,
                  );
            final double panelWidth = panelSide == null
                ? 0
                : aiLayout.inlineWidth(
                    size.width - overviewInset,
                    preferred: _aiPanelWidth,
                  );
            // What the panels leave for the page and the palette.
            final Rect region = Rect.fromLTWH(
              overviewInset + (panelSide == AiPanelSide.left ? panelWidth : 0),
              0,
              size.width - overviewInset - panelWidth,
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
              exitFullscreen: exitFullscreen != null,
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
              paletteTools: _paletteTools,
            );
            _lastLayout = layout;
            _updateTopScrollLimit(layout);
            final List<NotePage> pages = _document.pages;
            final int current = _document.currentIndex;
            final bool infiniteCanvas =
                pages[current].setup.size == PageSize.infinite;
            // A whiteboard is shown alone. Paper pages are a column, without
            // any whiteboard among them, which is opened from the overview.
            final List<int> shown = infiniteCanvas
                ? <int>[current]
                : <int>[
                    for (int i = 0; i < pages.length; i++)
                      if (pages[i].setup.size != PageSize.infinite) i,
                  ];
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
            final Rect paletteOnPage = _toolbarShown.value
                ? ((layout.paletteOrigin - layout.surface.topLeft) &
                          ToolPalette.sizeFor(
                            layout.paletteAxis,
                            expanded: _paletteExpanded,
                            tools: _paletteTools,
                          ))
                      .expandToInclude(historyOnPage)
                : historyOnPage;
            final BorderSide edge = BorderSide(
              color: colors.divider,
              width: AppSizes.hairline,
            );
            return Stack(
              key: _bodyKey,
              // The body's constraints are loose: without this, the empty
              // toolbar slot would size the Stack to nothing and clip the
              // whole editor away.
              fit: StackFit.expand,
              children: <Widget>[
                Positioned.fromRect(
                  rect: layout.surface,
                  child: RepaintBoundary(
                    child: WritingSurfaceFrame(
                      child: PageViewport(
                        // Each whiteboard opens fresh, on its ink.
                        key: infiniteCanvas
                            ? ValueKey<Object>((
                                'page-viewport-board',
                                pages[current],
                              ))
                            : const ValueKey<String>('page-viewport'),
                        topScrollLimit: infiniteCanvas ? null : _topScrollLimit,
                        pages: <PageGeometry>[
                          for (final int i in shown) geometries[i],
                        ],
                        pageKeys: <Key>[
                          for (final int i in shown) ObjectKey(pages[i]),
                        ],
                        currentPage: math.max(0, shown.indexOf(current)),
                        infinite: infiniteCanvas,
                        // On its ink, or where ink starts on an empty one.
                        boardFocus: infiniteCanvas
                            ? pages[current].contentBounds ??
                                  (InfiniteBoard.origin & Size.zero)
                            : null,
                        minZoom: infiniteCanvas
                            ? EditorScreen.boardMinZoom
                            : 0.5,
                        initialZoom: infiniteCanvas
                            ? 1
                            : EditorScreen.openingZoom,
                        onPageTouched: (int slot) =>
                            _onPageTouched(shown[slot]),
                        onDeskTap: _selectionCarry.clearSelection,
                        onVisiblePageChanged: (int slot) =>
                            _onScrolledToPage(shown[slot]),
                        onScrollStart: _onScrollStart,
                        onScrollEnd: _onScrollEnd,
                        onScrollSpeed: _onScrollSpeed,
                        fingersNavigate: _stylusOnly,
                        pointerClaims: _pointerClaims,
                        // A whiteboard has no end to pull past.
                        onPullToAddPage:
                            infiniteCanvas || !widget.allowPageManagement
                            ? null
                            : _addPageAtEnd,
                        pullToAddDistance: 180,
                        pageBuilder:
                            (
                              BuildContext context,
                              int slot,
                              ValueListenable<Rect> visible,
                            ) {
                              final int index = shown[slot];
                              final NotePage page = pages[index];
                              if (infiniteCanvas) _boardVisible = visible;
                              return NoteCachePage(
                                scope: _cacheScope,
                                page: page.cacheKey,
                                onChanged: () => _keepInkOf(page),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: <Widget>[
                                    PageBackgroundLayer(
                                      background: page.setup.background,
                                      visible: visible,
                                      config: widget.pageConfig,
                                    ),
                                    if (page.pdfSource != null &&
                                        _pageRenderCache != null)
                                      RepaintBoundary(
                                        // Tool changes update input/text layers
                                        // above the paper. At high zoom the PDF
                                        // is a screen-sized raster; keep those
                                        // updates from painting it again.
                                        child: PdfPageLayer(
                                          source: page.pdfSource!,
                                          displayedSize:
                                              geometries[index].displaySize,
                                          cache: _pageRenderCache!,
                                          visible: visible,
                                          onShown:
                                              index == _document.currentIndex
                                              ? _pageShown
                                              : null,
                                        ),
                                      ),
                                    if (page.pdfSource != null)
                                      PdfMaskLayer(
                                        masks: () => page.ink.pdfMasks,
                                        changes:
                                            page.ink.documentRevisionListenable,
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
                                                cacheScope: _cacheScope,
                                              ),
                                        cachePage: page.cacheKey,
                                        controller: page.ink,
                                        readAsset: widget.assetReader,
                                        maxDecodeDimension: widget
                                            .documentIoConfig
                                            .maxStoredImageDimension,
                                        carry: _selectionCarry,
                                      ),
                                    // On the paper, under the ink.
                                    if (widget.pageUnderlayBuilder != null)
                                      widget.pageUnderlayBuilder!(
                                        context,
                                        index,
                                      ),
                                    AiCitationHighlight(
                                      assistant: _ai,
                                      page: page.ink,
                                    ),
                                    if (widget.citationMarks
                                        case final ValueListenable<AiNoteMarks?>
                                            marks)
                                      AiNoteMarksLayer(
                                        marks: marks,
                                        pageIndex: index,
                                        page: page.ink,
                                      ),
                                    _InkInputRegion(
                                      exclusions: widget.inputExclusions,
                                      child: InkCanvas(
                                        controller: page.ink,
                                        visible: visible,
                                        enableNativeInk:
                                            widget.enableNativeInk &&
                                            !widget.readOnly,
                                        tool: _tool,
                                        penSettings: _penSettings,
                                        eraserSettings: _eraserSettings,
                                        penConfig: widget.penConfig,
                                        eraserConfig: widget.eraserConfig,
                                        shapeConfig: widget.shapeConfig,
                                        isInputBlocked: _isPageInputBlocked,
                                        // A pen set down while the page still
                                        // coasts from a pinch or fling stops it
                                        // there and writes, rather than being
                                        // dropped as part of the scroll.
                                        onStylusDown: () {
                                          if (_scrolling) {
                                            context
                                                .findAncestorStateOfType<
                                                  PageViewportState
                                                >()
                                                ?.yieldToPen();
                                          }
                                        },
                                        pastePrompt: _pastePrompt,
                                        stylusOnly: _stylusOnly,
                                        ruler: _ruler,
                                        pointerClaims: _pointerClaims,
                                        aiActive: _aiActive,
                                        onAiSelection: (InkVector? tap) =>
                                            _onAiSelection(tap, page.ink),
                                        selectablePdfBounds:
                                            page.pdfSource == null
                                            ? null
                                            : Offset.zero &
                                                  page.pdfSource!.pageSize,
                                        selectPdf: _selectPdf,
                                        stickySettings: _stickySettings,
                                        onStickyPlaced: _onStickyPlaced,
                                        textSettings: _textSettings,
                                        onTextSelected:
                                            (TextSettings settings) {
                                              _textSettings.value = settings;
                                            },
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
                                            ?.touchPage(slot),
                                      ),
                                    ),
                                    if (widget.pageOverlayBuilder != null)
                                      widget.pageOverlayBuilder!(
                                        context,
                                        index,
                                      ),
                                    AiContextSelection(
                                      assistant: _ai,
                                      page: page.ink,
                                    ),
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
                                ),
                              );
                            },
                        // Above the current page, so their presses stay off
                        // it, and never scaled with it.
                        overlayBuilder:
                            (BuildContext context, PageTransform transform) {
                              return Stack(
                                fit: StackFit.expand,
                                children: <Widget>[
                                  // What the AI tool chooses is asked about
                                  // in the chat, so it offers no actions here.
                                  ValueListenableBuilder<EditorTool>(
                                    valueListenable: _tool,
                                    builder:
                                        (
                                          BuildContext context,
                                          EditorTool tool,
                                          Widget? bar,
                                        ) {
                                          return tool == EditorTool.ai
                                              ? const SizedBox.shrink()
                                              : bar!;
                                        },
                                    child: SelectionActionBar(
                                      controller: _inkController,
                                      crossPageListenable: _selectionCarry,
                                      selectionResolver: _stableSelection,
                                      onAiPressed: widget.allowPageManagement
                                          ? _openAi
                                          : null,
                                      onCopy: _copy,
                                      onCut: _cut,
                                      onDuplicate: () => _selectionCarry
                                          .duplicateSelection(_inkController),
                                      onDelete: (_) => _selectionCarry
                                          .deleteSelection(_inkController),
                                      transform: transform,
                                      obstruction: paletteOnPage,
                                    ),
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
                if (!widget.readOnly)
                  _PaintTranslatedPositioned(
                    key: const ValueKey<String>('history-position'),
                    origin: layout.history.topLeft,
                    child: FloatingHistoryControls(
                      height: layout.history.height,
                      width: layout.history.width,
                      children: <Widget>[
                        HistoryControls(
                          controller: _inkController,
                          onUndo: _undo,
                          onRedo: _redo,
                        ),
                        if (widget.allowPageManagement)
                          PageNavigationControls(
                            onOpenOverview: _togglePageOverview,
                            overviewOpen: _pageOverviewOpen,
                          ),
                      ],
                    ),
                  ),
                if (widget.allowPageManagement)
                  _PaintTranslatedPositioned(
                    key: const ValueKey<String>('page-controls-position'),
                    origin: layout.pageControls.topLeft,
                    child: FloatingPageControls(
                      height: layout.pageControls.height,
                      width: layout.pageControls.width,
                      child: PageControls(
                        document: _document,
                        onOpenSettings: _openPageSettings,
                        canFind: _canFind,
                        onFind: _openHandwritingFind,
                        onInsertPdf: _canUseDocumentIo ? _insertPdf : null,
                        onExitFullscreen: exitFullscreen,
                      ),
                    ),
                  ),
                // Only the toolbar listens to which editor shows it, so
                // switching tabs never builds this editor again.
                EditorToolbarSlot(
                  builder: (GlobalKey? toolbarKey) {
                    _claimStylusGestures();
                    if (!_toolbarShown.value || widget.readOnly) {
                      return const SizedBox.shrink();
                    }
                    return _PalettePositioner(
                      historyWidth: historyWidth,
                      pageControlsWidth: pageControlsWidth,
                      center: _paletteDragCenter,
                      sizeClass: sizeClass,
                      region: region,
                      placement: _palettePlacement.value,
                      isAiOpen: isAiOpen,
                      expanded: _paletteExpanded,
                      tools: _paletteTools,
                      builder:
                          (
                            PaletteEdge edge,
                            double growsBefore,
                            double optionsMaxLength,
                          ) => ToolPalette(
                            // The window's one toolbar while this editor is in
                            // front: moved here, not built again.
                            key: toolbarKey,
                            edge: edge,
                            growsBefore: growsBefore,
                            optionsMaxLength: optionsMaxLength,
                            onDragStart: () => _onPaletteDragStart(
                              layout.paletteOrigin +
                                  ToolPalette.sizeFor(
                                    layout.paletteAxis,
                                    expanded: _paletteExpanded,
                                    tools: _paletteTools,
                                  ).center(Offset.zero),
                            ),
                            onDragUpdate: _onPaletteDragUpdate,
                            onDragEnd: _onPaletteDragEnd,
                            onMoveTo: _movePaletteTo,
                            dense: sizeClass == WindowSizeClass.medium,
                            tool: _tool,
                            penSettings: _penSettings,
                            eraserSettings: _eraserSettings,
                            selectPdf: _selectPdf,
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
                              transcription: _transcription,
                              onTranscribe: (NoteRecordingTrack track) =>
                                  unawaited(_transcribeRecording(track)),
                              onShowTranscript: _showTranscript,
                            ),
                            textSettings: _textSettings,
                            onTextSettingsChanged: _onTextSettingsChanged,
                            optionsShown: _toolOptionsShown,
                            layout: _toolbarLayout,
                            stickySettings: _stickySettings,
                            onStickySettingsChanged: _onStickySettingsChanged,
                            stickyTargetLabel: () =>
                                _inkController.editingSticky?.label,
                            onChooseImageFromGallery: _canUseDocumentIo
                                ? () =>
                                      _insertImage(DocumentImageSource.gallery)
                                : null,
                            onTakePhoto: _canUseDocumentIo
                                ? () => _insertImage(DocumentImageSource.camera)
                                : null,
                          ),
                    );
                  },
                ),
                // What a narrowing panel uncovers before the page is laid
                // out again: more of the desk the page sits on.
                if (panelSide != null && _resizingAiPanel)
                  Positioned(
                    key: const ValueKey<String>('ai-panel-resize-desk'),
                    top: 0,
                    bottom: 0,
                    left: panelSide == AiPanelSide.left
                        ? overviewInset
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
                                ? overviewInset
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
                                  size.width - overviewInset,
                                ),
                                onDragEnd: _endAiPanelResize,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (overviewOpen)
                  Positioned.fromRect(
                    key: const ValueKey<String>('page-overview-position'),
                    rect: _pageOverviewRect,
                    child: PageOverviewSidebar(
                      onClose: _closePageOverview,
                      child: PageOverviewPanel(
                        document: _document,
                        writingArea: _viewportSize,
                        config: widget.pageConfig,
                        chapters: _chapterIndex,
                        view: _pageOverviewView,
                        onSelected: overviewCovers ? _closePageOverview : null,
                        onClose: overviewCovers ? _closePageOverview : null,
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
    // A minimized note's ink is hidden, so the note itself is what was found.
    _paintHighlight(
      canvas,
      sticky.minimized ? Offset.zero & sticky.paperLocalSize : target.bounds,
      scale: sticky.scale,
    );
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
/// Moves a fixed-footprint overlay without relaying out the editor stack on
/// every animation frame. Transform also moves hit testing with the visual.
class _PaintTranslatedPositioned extends StatelessWidget {
  const _PaintTranslatedPositioned({
    super.key,
    required this.origin,
    required this.child,
  });

  final Offset origin;
  final Widget child;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 0,
    top: 0,
    child: TweenAnimationBuilder<Offset>(
      tween: Tween<Offset>(begin: origin, end: origin),
      duration: AppMotion.resolve(context, AppMotion.snappy.duration),
      curve: AppMotion.fadeInCurve,
      builder: (BuildContext context, Offset value, Widget? child) =>
          Transform.translate(offset: value, child: child),
      child: child,
    ),
  );
}

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
    this.tools = ToolbarLayout.standard,
  });
  final bool expanded;
  final ToolbarLayout tools;
  final double historyWidth;
  final double pageControlsWidth;
  final ValueListenable<Offset?> center;
  final WindowSizeClass sizeClass;
  final Rect region;
  final PalettePlacement placement;
  final Widget Function(
    PaletteEdge edge,
    double growsBefore,
    double optionsMaxLength,
  )
  builder;
  final bool isAiOpen;

  @override
  State<_PalettePositioner> createState() => _PalettePositionerState();
}

class _PalettePositionerState extends State<_PalettePositioner> {
  PaletteEdge? _edge;
  bool _builtDragged = false;
  Widget? _palette;

  @override
  void didUpdateWidget(_PalettePositioner oldWidget) {
    super.didUpdateWidget(oldWidget);
    _palette = null;
  }

  /// How much of its growth the palette takes toward its start as it unfolds
  /// docked against [edge]: as far as its docked origin moves back.
  double _growsBefore(PaletteEdge edge) {
    double dockedAlong({required bool expanded}) {
      final Offset origin = EditorLayout.compute(
        widget.sizeClass,
        widget.region,
        PalettePlacement(edge: edge, along: widget.placement.along),
        historyWidth: widget.historyWidth,
        pageControlsWidth: widget.pageControlsWidth,
        isAiOpen: widget.isAiOpen,
        paletteExpanded: expanded,
        paletteTools: widget.tools,
      ).paletteOrigin;
      return edge.axis == Axis.horizontal ? origin.dx : origin.dy;
    }

    final double growth = ToolPalette.unfoldGrowth(
      edge.axis,
      tools: widget.tools,
    );
    if (growth == 0) return 0.5;
    final double back =
        dockedAlong(expanded: false) - dockedAlong(expanded: true);
    return (back / growth).clamp(0.0, 1.0);
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
        paletteTools: widget.tools,
      );
      final Axis axis = layout.paletteAxis;
      final bool across = axis == Axis.horizontal;
      final double growsBefore = _growsBefore(layout.paletteEdge);
      // Where the palette would lie folded, whether it is or not: the options
      // bar goes by this, so folding and unfolding leave it where it is.
      final double back = widget.expanded
          ? growsBefore * ToolPalette.unfoldGrowth(axis, tools: widget.tools)
          : 0;
      final Offset docked =
          layout.paletteOrigin + (across ? Offset(back, 0) : Offset(0, back));
      final Size paletteSize = ToolPalette.sizeFor(axis, tools: widget.tools);
      final double margin = EditorLayout.marginFor(widget.sizeClass);
      // The options bar is centered on the folded palette, as long as the
      // region has room for on both sides, and scrolls beyond that.
      final double middle = across
          ? docked.dx + paletteSize.width / 2
          : docked.dy + paletteSize.height / 2;
      final double half = across
          ? math.min(middle - widget.region.left, widget.region.right - middle)
          : math.min(middle - widget.region.top, widget.region.bottom - middle);
      final double room = math.max(
        paletteSize.longestSide,
        2 * (half - margin),
      );
      // Reuse the entire control subtree until the edge or editor inputs
      // change. Each move updates only Stack parent data and compositing.
      final bool dragged = center != null;
      if (_palette == null ||
          _edge != layout.paletteEdge ||
          (_builtDragged && !dragged)) {
        _edge = layout.paletteEdge;
        _builtDragged = dragged;
        _palette = RepaintBoundary(
          child: widget.builder(
            _edge!,
            growsBefore,
            // Only docked: a dragged palette relays out no options.
            dragged ? double.infinity : room,
          ),
        );
      }
      // The palette's footprint never participates in surrounding layout.
      // Animate only its paint transform so a dock/drop does not lay out the
      // editor Stack, page, ink, or PDF on every animation tick.
      return Positioned(
        left: 0,
        top: 0,
        child: _PaletteAnchor(
          edge: layout.paletteEdge,
          paletteSize: paletteSize,
          child: TweenAnimationBuilder<Offset>(
            key: const ValueKey<String>('tool-palette-position'),
            tween: Tween<Offset>(begin: docked, end: docked),
            duration: center == null
                ? AppMotion.resolve(context, AppMotion.bouncy.duration)
                : Duration.zero,
            curve: AppMotion.fadeInCurve,
            builder: (BuildContext context, Offset origin, Widget? child) =>
                Transform.translate(offset: origin, child: child),
            child: _palette,
          ),
        ),
      );
    },
  );
}

/// Holds the palette, folded, where it is docked while the room for it to
/// unfold and the options bar beside it, both centered on it, make the whole
/// longer than the palette: lays [child] out at whatever size it takes, then
/// moves it back by as much as the folded palette sits from its top-left
/// corner.
class _PaletteAnchor extends SingleChildRenderObjectWidget {
  const _PaletteAnchor({
    required this.edge,
    required this.paletteSize,
    super.child,
  });

  final PaletteEdge edge;
  final Size paletteSize;

  @override
  _RenderPaletteAnchor createRenderObject(BuildContext context) =>
      _RenderPaletteAnchor(edge, paletteSize);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderPaletteAnchor renderObject,
  ) {
    renderObject
      ..edge = edge
      ..paletteSize = paletteSize;
  }
}

class _RenderPaletteAnchor extends RenderProxyBox {
  _RenderPaletteAnchor(this._edge, this._paletteSize);

  PaletteEdge get edge => _edge;
  PaletteEdge _edge;
  set edge(PaletteEdge value) {
    if (value == _edge) return;
    _edge = value;
    markNeedsPaint();
  }

  Size get paletteSize => _paletteSize;
  Size _paletteSize;
  set paletteSize(Size value) {
    if (value == _paletteSize) return;
    _paletteSize = value;
    markNeedsPaint();
  }

  /// How far the child is moved back: by where the palette sits in it,
  /// centered across a bar along the top or bottom, or down a side, and
  /// after a bar on the page side of it at the bottom or right.
  Offset get _shift {
    final Size whole = child?.size ?? Size.zero;
    final double dx = switch (_edge) {
      PaletteEdge.top ||
      PaletteEdge.bottom => (whole.width - _paletteSize.width) / 2,
      PaletteEdge.left => 0,
      PaletteEdge.right => whole.width - _paletteSize.width,
    };
    final double dy = switch (_edge) {
      PaletteEdge.left ||
      PaletteEdge.right => (whole.height - _paletteSize.height) / 2,
      PaletteEdge.top => 0,
      PaletteEdge.bottom => whole.height - _paletteSize.height,
    };
    return Offset(-math.max(0.0, dx), -math.max(0.0, dy));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final RenderBox? child = this.child;
    if (child != null) context.paintChild(child, offset + _shift);
  }

  // The child hangs out of this box's own bounds, as a transform's does:
  // it is hit where it is painted.
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      hitTestChildren(result, position: position);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final RenderBox? child = this.child;
    if (child == null) return false;
    return result.addWithPaintOffset(
      offset: _shift,
      position: position,
      hitTest: (BoxHitTestResult result, Offset transformed) =>
          child.hitTest(result, position: transformed),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final Offset shift = _shift;
    transform.translateByDouble(shift.dx, shift.dy, 0, 1);
  }
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
    ToolbarLayout tools = ToolbarLayout.standard,
  }) {
    final Size palette = ToolPalette.sizeFor(
      placement.edge.axis,
      expanded: expanded,
      tools: tools,
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
    ToolbarLayout tools = ToolbarLayout.standard,
  }) {
    final Offset origin = placement.originIn(
      region,
      margin,
      expanded: expanded,
      tools: tools,
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
      tools: tools,
    )) {
      return Offset(origin.dx, math.max(origin.dy, leftCard.bottom + margin));
    }
    if (isAiOpen) {
      final Size paletteSize = ToolPalette.sizeFor(
        placement.edge.axis,
        expanded: expanded,
        tools: tools,
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
    ToolbarLayout paletteTools = ToolbarLayout.standard,
  }) {
    final double margin = marginFor(sizeClass);
    final Rect history = _historyRect(region, historyWidth);
    final Rect pageControls = _pageControlsRect(region, pageControlsWidth);
    if (dragCenter != null) {
      final PaletteEdge edge = PalettePlacement.nearestEdge(region, dragCenter);
      final Size size = ToolPalette.sizeFor(
        edge.axis,
        expanded: paletteExpanded,
        tools: paletteTools,
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
        tools: paletteTools,
      ),
    );
  }
}

class _InkInputRegion extends SingleChildRenderObjectWidget {
  const _InkInputRegion({required this.exclusions, required super.child});
  final ValueGetter<List<Rect>>? exclusions;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _InkInputRegionBox(exclusions);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant _InkInputRegionBox renderObject,
  ) {
    renderObject.exclusions = exclusions;
  }
}

class _InkInputRegionBox extends RenderProxyBox {
  _InkInputRegionBox(this.exclusions);
  ValueGetter<List<Rect>>? exclusions;
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final areas = exclusions;
    if (areas != null) {
      final global = localToGlobal(position);
      if (areas().any((rect) => rect.contains(global))) return false;
    }
    return super.hitTest(result, position: position);
  }
}
