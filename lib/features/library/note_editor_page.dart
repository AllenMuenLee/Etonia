import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import '../../shared/layout/breakpoints.dart';
import '../editor/ai/ai_assistant_controller.dart';
import '../editor/ai/ai_client.dart';
import '../editor/editor_screen.dart';
import '../editor/ink/pen_settings.dart';
import '../editor/widgets/tool_palette.dart';
import '../editor/document_io/document_io_config.dart';
import '../editor/document_io/document_models.dart';
import '../editor/document_io/document_platform.dart';
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
    this.documentPicker = const SystemDocumentPicker(),
    this.pdfRasterizer = const PdfrxRasterizer(),
    this.exportSink = const SystemExportSink(),
    this.documentIoConfig = const DocumentIoConfig(),
    this.sharedClipboard,
    this.stylusOnly,
    this.penSettings,
    this.palettePlacement,
    this.initialNotationEnabled = true,
    this.tabsBuilder,
    this.onRenamed,
    this.onBack,
  });

  /// Builds the open notes' tabs for the top bar, given how to rename this
  /// note; without it the bar shows the title alone.
  final Widget Function(VoidCallback rename)? tabsBuilder;

  /// Called with the note once it has been renamed.
  final ValueChanged<NoteEntry>? onRenamed;

  /// Leaves the editor; by default the page's route is popped.
  final VoidCallback? onBack;

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
  final DocumentPicker documentPicker;
  final PdfRasterizer pdfRasterizer;
  final ExportSink exportSink;
  final DocumentIoConfig documentIoConfig;
  final SharedNoteClipboard? sharedClipboard;

  /// Passed to the editor, so the choice carries from note to note.
  final ValueNotifier<bool>? stylusOnly;

  /// Passed to the editor, so the pen and where its palette floats carry
  /// from note to note.
  final ValueNotifier<PenSettings>? penSettings;
  final ValueNotifier<PalettePlacement>? palettePlacement;

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

  /// The note's content, read but held back until the page has slid in:
  /// building the editor mid-slide would stall the slide.
  NoteContent? _pending;
  bool _entered = false;
  Timer? _enter;

  /// Whether the picture of the page still lies over the editor, until
  /// the editor's own page is on screen, and whether it is fading out.
  bool _covered = true;
  bool _uncovering = false;
  Timer? _uncoverLimit;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_entered && _enter == null) {
      final Duration slide = AppMotion.resolve(context, AppMotion.gentle);
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
      if (lease != null) _document?.goTo(lease.currentPage);
    }
  }

  Future<bool> _prepareToEvict() async {
    if (_hydrating ||
        _document == null ||
        (_editor.currentState?.requiresRetention ?? true)) {
      return false;
    }
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
      final NoteContent content = await widget.repository.loadNote(
        widget.note.id,
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
    document.goTo(_lease?.currentPage ?? 0);
    _autosaver = NoteAutosaver(
      document: document,
      delay: widget.saveDelay,
      save: (NoteContent content) {
        return widget.repository.saveNote(widget.note.id, content);
      },
      onError: _onSaveFailed,
    );
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
    _autosaver?.flush();
    if (widget.onBack != null) {
      widget.onBack!();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    _lease?.prepareToEvict = null;
    _lease?.prepareToClose = null;
    _enter?.cancel();
    _uncoverLimit?.cancel();
    _preview?.dispose();
    // Read the pages before they go; the save finishes on its own.
    _autosaver?.flush();
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
    super.dispose();
  }

  static Set<String> _referencedAssets(NoteContent content) => <String>{
    for (final StoredPage page in content.pages)
      if (page.pdfSource != null) page.pdfSource!.assetId,
    for (final StoredPage page in content.pages)
      for (final image in page.images) image.assetId,
    // What saved AI conversations were drawn over, read again on reopening.
    ...AiAssistantController.referencedAssets(content.aiSession),
  };

  @override
  Widget build(BuildContext context) {
    final NoteDocument? document = _document;
    if (document != null) {
      final Widget editor = EditorScreen(
        key: _editor,
        document: document,
        title: _title,
        onBack: _leave,
        onTitlePressed: _rename,
        tabs: widget.tabsBuilder?.call(_rename),
        aiClient: widget.aiClient,
        subscription: widget.subscription,
        repository: widget.repository,
        noteId: widget.note.id,
        documentPicker: widget.documentPicker,
        pdfRasterizer: widget.pdfRasterizer,
        exportSink: widget.exportSink,
        documentIoConfig: widget.documentIoConfig,
        stylusOnly: widget.stylusOnly,
        penSettings: widget.penSettings,
        palettePlacement: widget.palettePlacement,
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
                duration: AppMotion.resolve(context, AppMotion.fast),
                onEnd: () {
                  if (mounted && _uncovering) setState(_uncovered);
                },
                child: Scaffold(
                  backgroundColor: Colors.transparent,
                  appBar: const PreferredSize(
                    preferredSize: Size.fromHeight(AppSizes.appBarHeight),
                    child: SizedBox.shrink(),
                  ),
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
      appBar: EditorAppBar(
        title: _title,
        centerTitle: sizeClass == WindowSizeClass.expanded,
        onMenuPressed: _leave,
        leadingIsBack: true,
        onTitlePressed: _rename,
        tabs: widget.tabsBuilder?.call(_rename),
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
