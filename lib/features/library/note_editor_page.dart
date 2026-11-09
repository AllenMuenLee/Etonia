import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import '../../shared/layout/breakpoints.dart';
import '../../shared/memory/note_cache_pool.dart';
import '../../shared/widgets/processing.dart';
import '../editor/ai/ai_assistant_controller.dart';
import '../editor/ai/ai_citation.dart';
import '../editor/ai/ai_client.dart';
import '../editor/editor_screen.dart';
import '../editor/handwriting/handwriting_calibration.dart';
import '../editor/ink/pen_settings.dart';
import '../editor/ink/stylus_actions.dart';
import '../editor/widgets/tool_palette.dart';
import '../editor/widgets/toolbar_layout.dart';
import '../editor/document_io/document_io_config.dart';
import '../editor/document_io/document_models.dart';
import '../editor/document_io/document_platform.dart';
import '../editor/document_io/pdf_preview_store.dart';
import '../editor/page/note_document.dart';
import '../editor/widgets/editor_app_bar.dart';
import '../editor/widgets/writing_surface_frame.dart';
import '../payment/subscription_controller.dart';
import 'library_dialogs.dart';
import 'library_models.dart';
import 'note_autosaver.dart';
import 'note_content.dart';
import 'note_repository.dart';
import 'note_thumbnails.dart';
import 'note_tabs_page.dart';
import 'shared_note_clipboard.dart';

/// Opens [note] from [repository] in the editor and keeps it saved.
///
/// Shows progress while the note loads and a message if it cannot be read.
/// The editor's navigation control leaves, and its title renames the note.
/// Changes are saved by a [NoteAutosaver], and once more on the way out.
class NoteEditorPage extends StatefulWidget {
  const NoteEditorPage({
    super.key,
    required this.repository,
    required this.note,
    this.initialContent,
    this.preview,
    this.saveDelay = const Duration(milliseconds: 800),
    this.aiClient,
    this.subscription,
    this.handwritingProfileStore,
    this.documentPicker = const SystemDocumentPicker(),
    this.pdfRasterizer = const PdfrxRasterizer(),
    this.pdfPreviewStore,
    this.exportSink = const SystemExportSink(),
    this.documentIoConfig = const DocumentIoConfig(),
    this.cachePool,
    this.sharedClipboard,
    this.stylusOnly,
    this.penSettings,
    this.palettePlacement,
    this.toolOptionsShown,
    this.toolbarShown,
    this.toolbarLayout,
    this.stylusActions,
    this.initialNotationEnabled = true,
    this.tabsBuilder,
    this.onRenamed,
    this.onBack,
    this.onImportConversationToStudyDesk,
    this.noteRetriever,
    this.onSaved,
    this.arrived,
    this.citationMarks,
  });

  /// What was cited elsewhere, of whichever note. When it names this one, the
  /// note goes to that page and marks what is cited there.
  final ValueListenable<AiNoteMarks?>? citationMarks;

  /// Whether the move bringing the note into view has ended. Its heavy
  /// content is held back until then, so building it never costs a frame of
  /// the move. Without it, the content waits [noteEntrance].
  final ValueListenable<bool>? arrived;

  /// Called after each save, the last on the way out included, with the
  /// entry as saved and what was saved, while those pages are still in
  /// memory: the library draws the note's picture from them.
  final void Function(NoteEntry note, NoteContent content)? onSaved;

  /// Builds the open notes' tabs for the top bar, given how to rename this
  /// note; without it the bar shows the title alone.
  final Widget Function(VoidCallback rename)? tabsBuilder;

  /// Called with the note once it has been renamed.
  final ValueChanged<NoteEntry>? onRenamed;

  /// Leaves the editor; by default the page's route is popped.
  final VoidCallback? onBack;
  final ValueChanged<List<AiMessage>>? onImportConversationToStudyDesk;

  /// Finds what this note says about a question, for the assistant when
  /// nothing is selected. The note is saved first, so it is found as it is.
  final AiNoteRetriever? noteRetriever;

  final NoteRepository repository;
  final NoteEntry note;

  /// The note's content, already read; the editor then shows it on its
  /// first frame. Without it the content is read first.
  final NoteContent? initialContent;

  /// The note's first page as the library pictures it: shown where the
  /// page will be while the note slides in and loads.
  final NoteThumbnailImage? preview;

  final Duration saveDelay;

  /// Passed to the editor; tests supply one.
  final AiClient? aiClient;

  /// Passed to the editor, to meter its AI.
  final SubscriptionController? subscription;

  /// Passed to the editor for the chat's calibration reminder.
  final HandwritingProfileStore? handwritingProfileStore;
  final DocumentPicker documentPicker;
  final PdfRasterizer pdfRasterizer;

  /// Passed to the editor, to keep PDF pages' previews between visits.
  final PdfPreviewStore? pdfPreviewStore;
  final ExportSink exportSink;
  final DocumentIoConfig documentIoConfig;

  /// The memory all open notes keep things in; this note has a share of it
  /// for as long as it is open.
  final NoteCachePool? cachePool;
  final SharedNoteClipboard? sharedClipboard;

  /// Passed to the editor, so the choice carries from note to note.
  final ValueNotifier<bool>? stylusOnly;

  /// Passed to the editor, so the pen and where its palette floats carry
  /// from note to note.
  final ValueNotifier<PenSettings>? penSettings;
  final ValueNotifier<PalettePlacement>? palettePlacement;

  /// Passed to the editor, so showing or hiding the tool options bar
  /// carries from note to note.
  final ValueNotifier<bool>? toolOptionsShown;

  /// Passed to the editor so toolbar visibility and hardware shortcuts
  /// carry from note to note.
  final ValueNotifier<bool>? toolbarShown;

  /// Passed to the editor so the palette's arrangement carries from note
  /// to note.
  final ValueNotifier<ToolbarLayout>? toolbarLayout;
  final ValueNotifier<StylusActionBindings>? stylusActions;

  /// Passed to the editor.
  final bool initialNotationEnabled;

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> {
  NoteDocument? _document;
  NoteAutosaver? _autosaver;
  Object? _error;
  NoteThumbnailImage? _preview;
  late String _title = widget.note.title;
  final GlobalKey<EditorScreenState> _editor = GlobalKey<EditorScreenState>();
  NoteTabLease? _lease;
  bool _hydrating = true;
  late final NoteCacheScope? _cacheScope = widget.cachePool?.scope();

  /// Asked to be put away, the note said no. It can be asked again once it
  /// has saved.
  bool _putAwayRefused = false;

  /// Charges the note's document to its share of the pool: it is the last
  /// of the note to go, once the tab can do without it.
  void _chargeDocument() {
    final NoteDocument? document = _document;
    if (document == null) return;
    _cacheScope?.setDocument(
      bytes: document.memoryBytes,
      canPutAway: () =>
          !_hydrating &&
          !_putAwayRefused &&
          _lease?.putAway != null &&
          !(_editor.currentState?.requiresRetention ?? true),
      putAway: () async {
        final bool done = await _lease?.putAway?.call() ?? false;
        if (done || !mounted) return;
        _putAwayRefused = true;
        _chargeDocument();
      },
    );
  }

  /// The marks, if they are for this note.
  AiNoteMarks? get _marksHere {
    final AiNoteMarks? marks = widget.citationMarks?.value;
    return marks?.noteId == widget.note.id ? marks : null;
  }

  /// Only this note's, so another note open beside it marks nothing.
  late final ValueNotifier<AiNoteMarks?> _ownMarks =
      ValueNotifier<AiNoteMarks?>(_marksHere);

  void _onCitationMarks() {
    final AiNoteMarks? marks = _marksHere;
    _ownMarks.value = marks;
    if (marks != null) _document?.goTo(marks.pageIndex);
  }

  /// The note's content, read but held back until the page has slid in:
  /// building the editor mid-slide would stall the slide.
  NoteContent? _pending;
  bool _entered = false;
  Timer? _enter;
  bool _waitingToArrive = false;

  /// The move has ended: the content is built now, at rest.
  void _onArrived() {
    final ValueListenable<bool>? arrived = widget.arrived;
    if (arrived == null || !arrived.value || _entered) return;
    arrived.removeListener(_onArrived);
    _waitingToArrive = false;
    _entered = true;
    _showPending();
  }

  /// Whether the picture of the page still lies over the editor, until
  /// the editor's own page is on screen, and whether it is fading out.
  bool _covered = true;
  bool _uncovering = false;
  Timer? _uncoverLimit;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ValueListenable<bool>? arrived = widget.arrived;
    if (!_entered && arrived != null) {
      if (arrived.value) {
        _entered = true;
      } else if (!_waitingToArrive) {
        _waitingToArrive = true;
        arrived.addListener(_onArrived);
      }
    } else if (!_entered && _enter == null) {
      final Duration slide = AppMotion.resolve(context, noteEntrance());
      if (slide == Duration.zero) {
        _entered = true;
      } else {
        _enter = Timer(slide, () {
          _entered = true;
          _showPending();
        });
      }
    }
    final lease = NoteTabScope.of(context);
    if (lease != _lease) {
      _lease?.prepareToEvict = null;
      _lease?.prepareToClose = null;
      _lease = lease;
      lease?.prepareToEvict = _prepareToEvict;
      lease?.prepareToClose = _prepareToClose;
      if (lease != null) {
        if (_marksHere case final AiNoteMarks marks) {
          lease.currentPage = marks.pageIndex;
        }
        _document?.goTo(lease.currentPage);
      }
    }
  }

  Future<bool> _prepareToEvict() async {
    if (_hydrating ||
        _document == null ||
        (_editor.currentState?.requiresRetention ?? true)) {
      return false;
    }
    await _editor.currentState?.finalizeRecording();
    await _autosaver?.flush();
    if (!mounted ||
        _autosaver!.isDirty ||
        (_editor.currentState?.requiresRetention ?? true)) {
      return false;
    }
    _lease?.currentPage = _document!.currentIndex;
    return true;
  }

  Future<bool> _prepareToClose() async {
    await _editor.currentState?.finalizeRecording();
    await _autosaver?.flush();
    return mounted && !(_autosaver?.isDirty ?? false);
  }

  // Stable reader identity prevents tab-strip rebuilds from clearing the PDF
  // cache and re-reading every visible image.
  Future<Uint8List?> _readAsset(String assetId) async {
    try {
      return (await widget.repository.readAsset(widget.note.id, assetId)).bytes;
    } on Object {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    widget.citationMarks?.addListener(_onCitationMarks);
    _preview = widget.preview?.clone();
    final NoteContent? content = widget.initialContent;
    if (content != null) {
      // Already read: shown at once, with nothing to cover.
      _entered = true;
      _uncovered();
      _show(content);
      unawaited(_afterShown());
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final Duration since = LoadTimings.clock();
      final NoteContent content = await widget.repository.loadNote(
        widget.note.id,
      );
      // So the next note slides in for about as long as it takes to read.
      LoadTimings.instance.record(
        LoadTimings.noteOpen,
        LoadTimings.clock() - since,
      );
      if (!mounted) {
        return;
      }
      _pending = content;
      _showPending();
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = error);
      }
    }
  }

  /// Builds the editor once the note is read and the page has slid in.
  void _showPending() {
    final NoteContent? content = _pending;
    if (!mounted || !_entered || content == null) return;
    _pending = null;
    setState(() => _show(content));
    unawaited(_afterShown());
    // Uncovered when the editor's page is on screen, or else soon anyway.
    _uncoverLimit = Timer(const Duration(milliseconds: 1500), _uncover);
  }

  /// The editor's page is on screen: the picture over it fades away.
  void _uncover() {
    _uncoverLimit?.cancel();
    if (!mounted || !_covered || _uncovering) return;
    // A tab out of view does not animate: there is no fade to wait for.
    // Read without depending on it: a warm tab must not rebuild on showing.
    if (!TickerMode.getValuesNotifier(context).value.enabled) {
      setState(_uncovered);
      return;
    }
    setState(() => _uncovering = true);
  }

  void _uncovered() {
    _covered = false;
    _uncovering = false;
    _preview?.dispose();
    _preview = null;
  }

  /// Makes the editor's document from [content].
  void _show(NoteContent content) {
    final NoteDocument document = content.toDocument();
    _document = document;
    document.goTo(_marksHere?.pageIndex ?? _lease?.currentPage ?? 0);
    _autosaver = NoteAutosaver(
      document: document,
      delay: widget.saveDelay,
      save: (NoteContent content) async {
        final NoteEntry saved = await widget.repository.saveNote(
          widget.note.id,
          content,
        );
        widget.onSaved?.call(saved, content);
        if (mounted) {
          _putAwayRefused = false;
          _chargeDocument();
        }
      },
      onError: _onSaveFailed,
    );
    _chargeDocument();
  }

  /// The save made as this page closes, which a late answer is added after.
  Future<void>? _closingSave;

  /// Where an answer is written when it arrives after the note was closed: it
  /// goes in the note as it was saved, beside the question it answers.
  late final Future<void> Function(Map<String, Object?> session)
  _retiredAiSaver = _makeRetiredAiSaver();

  Future<void> Function(Map<String, Object?> session) _makeRetiredAiSaver() {
    // Taken now: this page is gone by the time the answer comes.
    final NoteRepository repository = widget.repository;
    final String noteId = widget.note.id;
    final void Function(NoteEntry note, NoteContent content)? onSaved =
        widget.onSaved;
    return (Map<String, Object?> session) async {
      try {
        await _closingSave;
      } on Object {
        // The note's own save failing leaves what is read below as it was.
      }
      final NoteContent stored = await repository.loadNote(noteId);
      final NoteContent updated = NoteContent(
        stored.pages,
        aiSession: session,
        isImportedPdf: stored.isImportedPdf,
        recordings: stored.recordings,
      );
      final NoteEntry saved = await repository.saveNote(noteId, updated);
      onSaved?.call(saved, updated);
    };
  }

  /// Materialize the shared clipboard after the first frame. Do not clean
  /// assets against the loaded snapshot: imports/edits may already have
  /// started by the time this asynchronous work finishes.
  Future<void> _afterShown() async {
    try {
      final clipboard = await widget.sharedClipboard?.materialize(
        widget.repository,
        widget.note.id,
      );
      final NoteDocument? document = _document;
      if (!mounted || document == null) {
        return;
      }
      if (clipboard != null) {
        for (final NotePage page in document.pages) {
          page.ink.takeClipboard(clipboard);
        }
      }
    } on Object {
      // The shared clipboard can be retried on the next open.
    } finally {
      _hydrating = false;
      if (mounted) _lease?.onReady?.call();
    }
  }

  void _onSaveFailed(Object error) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text("Couldn't save this note. It will be tried again."),
      ),
    );
  }

  Future<void> _rename() async {
    final String? title = await askForName(
      context,
      title: 'Rename note',
      action: 'Rename',
      initial: _title,
    );
    if (title == null || title == _title || !mounted) {
      return;
    }
    await widget.repository.renameNote(widget.note.id, title);
    if (mounted) {
      setState(() => _title = title);
      widget.onRenamed?.call(widget.note.copyWith(title: title));
    }
  }

  void _leave() {
    unawaited(_leaveAfterFinalizingAudio());
  }

  Future<void> _leaveAfterFinalizingAudio() async {
    await _editor.currentState?.finalizeRecording();
    await _autosaver?.flush();
    if (!mounted) return;
    if (widget.onBack != null) {
      widget.onBack!();
    } else {
      await Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    widget.citationMarks?.removeListener(_onCitationMarks);
    _ownMarks.dispose();
    // Left before the note was read: the rest of the reading is let go.
    if (_document == null && _pending == null && _error == null) {
      widget.repository.abandonLoad(widget.note.id);
    }
    _lease?.prepareToEvict = null;
    _lease?.prepareToClose = null;
    _enter?.cancel();
    if (_waitingToArrive) widget.arrived?.removeListener(_onArrived);
    _uncoverLimit?.cancel();
    _preview?.dispose();
    // Read the pages before they go; the save finishes on its own.
    _closingSave = _autosaver?.flush();
    _autosaver?.dispose();
    final NoteDocument? document = _document;
    if (document != null) {
      final NoteContent content = NoteContent.fromDocument(document);
      final Set<String> referenced = _referencedAssets(content);
      for (final NotePage page in document.pages) {
        for (final NoteImageElement image
            in page.ink.clipboard?.images ?? const <NoteImageElement>[]) {
          referenced.add(image.assetId);
        }
      }
      widget.repository.cleanupAssets(widget.note.id, referenced);
      document.dispose();
    }
    _cacheScope?.close();
    super.dispose();
  }

  static Set<String> _referencedAssets(NoteContent content) => <String>{
    for (final StoredPage page in content.pages)
      if (page.pdfSource != null) page.pdfSource!.assetId,
    for (final StoredPage page in content.pages)
      for (final image in page.images) image.assetId,
    // What saved AI conversations were drawn over, read again on reopening.
    ...AiAssistantController.referencedAssets(content.aiSession),
    for (final recording in content.recordings) recording.assetPath,
  };

  @override
  Widget build(BuildContext context) {
    final NoteDocument? document = _document;
    // Under tabs this also tells them how to rename this note.
    final Widget? tabs = widget.tabsBuilder?.call(_rename);
    if (document != null) {
      final Widget editor = EditorScreen(
        key: _editor,
        document: document,
        title: _title,
        onBack: _leave,
        onImportConversationToStudyDesk:
            widget.onImportConversationToStudyDesk == null
            ? null
            : (messages) async {
                await _editor.currentState?.finalizeRecording();
                await _autosaver?.flush();
                if (mounted) widget.onImportConversationToStudyDesk!(messages);
              },
        noteRetriever: widget.noteRetriever == null
            ? null
            : (String question, {int reservedTextBytes = 0}) async {
                await _autosaver?.flush();
                if (!mounted) return null;
                return widget.noteRetriever!(
                  question,
                  reservedTextBytes: reservedTextBytes,
                );
              },
        onTitlePressed: _rename,
        tabs: tabs,
        aiClient: widget.aiClient,
        citationMarks: widget.citationMarks == null ? null : _ownMarks,
        subscription: widget.subscription,
        handwritingProfileStore: widget.handwritingProfileStore,
        repository: widget.repository,
        noteId: widget.note.id,
        documentPicker: widget.documentPicker,
        pdfRasterizer: widget.pdfRasterizer,
        pdfPreviewStore: widget.pdfPreviewStore,
        exportSink: widget.exportSink,
        documentIoConfig: widget.documentIoConfig,
        cacheScope: _cacheScope,
        stylusOnly: widget.stylusOnly,
        penSettings: widget.penSettings,
        palettePlacement: widget.palettePlacement,
        toolOptionsShown: widget.toolOptionsShown,
        toolbarShown: widget.toolbarShown,
        toolbarLayout: widget.toolbarLayout,
        stylusActions: widget.stylusActions,
        onAiSessionRetired: _retiredAiSaver,
        initialNotationEnabled: widget.initialNotationEnabled,
        assetReader: _readAsset,
        onPageShown: _uncover,
        onClipboardChanged: (clipboard) {
          widget.sharedClipboard?.capture(
            widget.repository,
            widget.note.id,
            clipboard,
          );
        },
      );
      if (!_covered) return editor;
      // The picture lies just where the editor's page is, so nothing moves
      // as it fades. Writing reaches the editor through it.
      return Stack(
        fit: StackFit.expand,
        children: <Widget>[
          editor,
          IgnorePointer(
            child: ExcludeSemantics(
              child: AnimatedOpacity(
                opacity: _uncovering ? 0 : 1,
                duration: AppMotion.resolve(context, AppMotion.fadeIn),
                onEnd: () {
                  if (mounted && _uncovering) setState(_uncovered);
                },
                child: Scaffold(
                  backgroundColor: Colors.transparent,
                  body: SafeArea(top: false, child: _openingPage(context)),
                ),
              ),
            ),
          ),
        ],
      );
    }
    final WindowSizeClass sizeClass = WindowSizeClass.fromWidth(
      MediaQuery.sizeOf(context).width,
    );
    // The editor as it will be, its page pictured, so the note slides in
    // looking open while it is read.
    return Scaffold(
      // Under tabs, the bar is theirs, and already there.
      appBar: NoteTabScope.of(context) != null
          ? null
          : EditorAppBar(
              title: _title,
              centerTitle: sizeClass == WindowSizeClass.expanded,
              onMenuPressed: _leave,
              leadingIsBack: true,
              onTitlePressed: _rename,
              tabs: tabs,
            ),
      body: SafeArea(
        top: false,
        child: _error == null
            ? _openingPage(context)
            : Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Text(
                    "This note couldn't be opened.",
                    style: Theme.of(context).textTheme.bodyLarge,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
      ),
    );
  }

  /// The note's first page, from its picture, where the editor shows it:
  /// at [EditorScreen.openingZoom] of the writing area's width, centered
  /// across it, at the top of the pages below it, or centered down it when
  /// they are all shorter than the area.
  Widget _openingPage(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    // Only the first page is pictured.
    final NoteThumbnailImage? picture = (_lease?.currentPage ?? 0) == 0
        ? _preview
        : null;
    return WritingSurfaceFrame(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Size area = constraints.biggest;
          final double aspect = picture?.aspect ?? 3 / 4;
          final double width = area.width * EditorScreen.openingZoom;
          final Size page = Size(width, width / aspect);
          final int count = math.max(1, widget.note.pageCount);
          final double column =
              page.height * count + AppSpacing.md * (count - 1);
          final double top = column < area.height
              ? (area.height - column) / 2
              : 0;
          final bool coversArea =
              count == 1 &&
              page.width >= area.width &&
              page.height >= area.height;
          return Stack(
            children: <Widget>[
              if (!coversArea)
                Positioned.fill(child: ColoredBox(color: colors.background)),
              Positioned(
                left: (area.width - page.width) / 2,
                top: top,
                width: page.width,
                height: page.height,
                child: Semantics(
                  label: 'Opening note',
                  child: DecoratedBox(
                    key: const ValueKey<String>('note-opening-page'),
                    decoration: BoxDecoration(
                      color: colors.writingSurface,
                      boxShadow: coversArea ? null : AppShadows.paper(colors),
                      border: coversArea
                          ? null
                          : Border.all(
                              color: colors.divider,
                              width: AppSizes.hairline,
                            ),
                    ),
                    child: picture == null
                        ? null
                        : CustomPaint(
                            painter: PagePicturePainter(picture.image),
                            size: Size.infinite,
                          ),
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

/// The shared visual duration for opening a note: the same move as going
/// into a folder.
Duration noteEntrance() => AppMotion.zoom;

/// Stretches [image], a note's pictured page, over the whole canvas.
class PagePicturePainter extends CustomPainter {
  const PagePicturePainter(this.image);

  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Offset.zero & Size(image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(PagePicturePainter oldDelegate) =>
      image != oldDelegate.image;
}
