import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../shared/layout/breakpoints.dart';
import '../../../shared/memory/memory_pressure.dart';
import '../../../shared/navigation/app_sheets.dart';
import '../../../shared/widgets/app_controls.dart';
import '../../../shared/widgets/etonia_mark.dart';
import '../../../shared/widgets/hold_menu.dart';
import '../../../shared/widgets/pressable.dart';
import '../../editor/ai/ai_citation.dart';
import '../../editor/ai/ai_client.dart';
import '../../editor/document_io/document_platform.dart';
import '../../editor/widgets/ai_assistant_panel.dart';
import '../../editor/widgets/ai_routing_controls.dart';
import '../../editor/ink/pen_settings.dart';
import '../../editor/widgets/ai_citation_highlight.dart';
import 'practice/study_practice_studio_view.dart';
import 'practice/study_practice_generator.dart';
import 'practice/study_generate_test_sheet.dart';
import 'practice/study_practice_models.dart';
import 'practice/study_test_paper_player.dart';
import 'study_citation_preview.dart';
import 'study_desk_controller.dart';
import 'study_desk_models.dart';
import 'study_desk_overview.dart';
import 'study_keyboard.dart';
import 'study_motion.dart';
import 'study_desk_widgets.dart';
import 'study_source_picker.dart';
import 'study_history_sidebar.dart';
import 'study_diagram_card.dart';

/// The Study Desk's body: the notes on the desk and the chat about them, with the
/// page a citation points at beside the chat where there is room for it, and
/// over the chat where there is not.
class StudyDeskScreen extends StatefulWidget {
  const StudyDeskScreen({
    super.key,
    required this.controller,
    required this.thumbnail,
    required this.onEditCitation,
    required this.onAddSources,
    this.onOpenPlans,
    this.onLeave,
    this.pdfRasterizer,
    this.isOpenInEditor,
    this.penSettings,
    this.stylusOnly,
    this.exportSink = const SystemExportSink(),
    this.onOpenTestAsNote,
    this.onSaveTestToLibrary,
    this.arrival,
  });

  final StudyDeskController controller;
  final StudyNoteThumbnailBuilder thumbnail;

  /// Opens the cited note in the editor.
  final ValueChanged<StudyCitation> onEditCitation;
  final VoidCallback onAddSources;
  final VoidCallback? onOpenPlans;
  final VoidCallback? onLeave;
  final PdfRasterizer? pdfRasterizer;

  /// Whether a note is open in an editor tab, and so is edited there.
  final bool Function(String noteId)? isOpenInEditor;
  final ValueListenable<PenSettings>? penSettings;
  final ValueListenable<bool>? stylusOnly;
  final ExportSink exportSink;

  /// Makes a note of a test's PDF, to write the answers on, and opens it.
  final Future<void> Function(Uint8List pdf, String title)? onOpenTestAsNote;

  final Future<void> Function(Uint8List pdf, String title)? onSaveTestToLibrary;

  /// Counts the times the desk is brought in front of the library. Its toolbar,
  /// chat, and message field settle in one after another each time it changes,
  /// as the desk itself zooms in.
  final ValueListenable<int>? arrival;

  static const String composerHint = 'Ask about your notes';

  /// The widest the chat goes.
  static const double readingWidth = 760;

  @override
  State<StudyDeskScreen> createState() => _StudyDeskScreenState();
}

class _StudyDeskScreenState extends State<StudyDeskScreen> {
  late final TextEditingController _text = TextEditingController(
    text: widget.controller.draft,
  );
  late final FocusNode _composerFocus = FocusNode(
    debugLabel: 'Study composer',
    onKeyEvent: _onComposerKey,
  );
  final ScrollController _scroll = ScrollController();
  final GlobalKey _transcriptKey = GlobalKey();

  /// So that the pane keeps what is being written as the window changes shape
  /// and it moves from beside the chat to over it.
  final GlobalKey _paneKey = GlobalKey();

  /// So that the chat and the practice studio keep their state, and their
  /// place, as the pane opens and closes and moves them from one parent to
  /// another.
  final GlobalKey _mainKey = GlobalKey();

  /// Built the first time it is shown, and kept, as the chat is, after that.
  /// Also built a moment after the desk arrives ([_arrived]), while nothing is
  /// moving, so that the first move into it has no building to do.
  bool _practiceBuilt = false;
  Timer? _warmStudio;

  /// The cited paragraphs built now, to find the one being read.
  final Map<(int, int), BuildContext> _paragraphs =
      <(int, int), BuildContext>{};
  Timer? _focusDebounce;
  bool? _historyOpen;
  double _layoutWidth = 0;
  bool _smoothNextScroll = false;

  final SpeechToText _speech = SpeechToText();
  bool _listening = false;
  String _voicePrefix = '';

  int _shownMessages = 0;
  String? _shownSession;

  /// Messages before this one were there when the chat was opened or an answer
  /// had been streamed into view: they are simply there, and do not arrive.
  int _settledMessages = 0;
  bool _streamed = false;

  /// A streamed answer changes the controller for every chunk; the desk
  /// follows at a pace the screen can draw.
  /// The longer the answer, the dearer it is to read again, so the further
  /// apart: about twelve a second at first, and not under four as it grows.
  late final StudyThrottle _streaming = StudyThrottle(
    const Duration(milliseconds: 80),
    _refreshStreaming,
    gapOf: () => Duration(
      milliseconds: (80 + (_controller.partialAnswer?.length ?? 0) ~/ 12).clamp(
        80,
        250,
      ),
    ),
  );

  /// Set when the pane is shut by hand: reading on no longer opens it, though a
  /// chip does. Only where the pane sits beside the chat.
  bool _paneDismissed = false;
  bool _testSourceDismissed = false;
  int _shownReviewRevision = 0;

  StudyDeskController get _controller => widget.controller;

  bool get _sideBySide =>
      WindowSizeClass.fromWidth(_layoutWidth) == WindowSizeClass.expanded;

  @override
  void initState() {
    super.initState();
    _text.addListener(_onTextChanged);
    _controller.addListener(_onControllerChanged);
    _scroll.addListener(_scheduleFocusUpdate);
    _shownMessages = _controller.messages.length;
    _settledMessages = _shownMessages;
    _shownSession = _controller.sessionId;
    _shownReviewRevision = _controller.testReviewOpenRevision;
    _scrollToEnd();
    MemoryPressure.instance.addListener(_releaseMemory);
    widget.arrival?.addListener(_arrived);
    unawaited(_controller.load());
  }

  /// The desk has just come in front. Once its entrance has played and the
  /// frames are quiet, builds the studio kept behind the chat, so it is
  /// ready before it is asked for rather than built in the frame that moves to
  /// it.
  void _arrived() {
    _warmStudio?.cancel();
    _warmStudio = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted || _practiceBuilt) return;
      setState(() => _practiceBuilt = true);
    });
  }

  /// The system is low on memory: the studio, when nothing in it is open, is
  /// let go and built again the next time it is wanted, and what is on screen
  /// stays as it is, not arriving a second time.
  void _releaseMemory() {
    if (!mounted) return;
    _settledMessages = _controller.messages.length;
    final bool idle =
        _controller.mode != StudyDeskMode.practice &&
        _controller.activeFlashcardSetId == null &&
        _controller.activeTestPaperId == null;
    if (idle && _practiceBuilt) setState(() => _practiceBuilt = false);
  }

  @override
  void didUpdateWidget(StudyDeskScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
    if (!identical(oldWidget.arrival, widget.arrival)) {
      oldWidget.arrival?.removeListener(_arrived);
      widget.arrival?.addListener(_arrived);
    }
  }

  @override
  void dispose() {
    MemoryPressure.instance.removeListener(_releaseMemory);
    widget.arrival?.removeListener(_arrived);
    _warmStudio?.cancel();
    _text.removeListener(_onTextChanged);
    _controller.removeListener(_onControllerChanged);
    _text.dispose();
    _composerFocus.dispose();
    _scroll.dispose();
    _focusDebounce?.cancel();
    _streaming.dispose();
    _paragraphs.clear();
    unawaited(_speech.cancel());
    super.dispose();
  }

  /// Only the composer listens to the text for Send, so a keystroke does not
  /// rebuild the transcript, the sidebar, and the pane with it.
  void _onTextChanged() {
    _controller.draft = _text.text;
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final reviewOpened =
        _shownReviewRevision != _controller.testReviewOpenRevision;
    _shownReviewRevision = _controller.testReviewOpenRevision;
    if (reviewOpened) {
      _testSourceDismissed = false;
      _historyOpen = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_sideBySide) _openMarkedPaper();
      });
    }
    final int count = _controller.messages.length;
    final bool newSession = _shownSession != _controller.sessionId;
    final bool grew = count > _shownMessages;
    final bool streaming = _controller.partialAnswer?.isNotEmpty ?? false;
    if (streaming) _streamed = true;
    _shownMessages = count;
    _shownSession = _controller.sessionId;
    if (newSession) {
      _settledMessages = count;
      _streamed = false;
    } else if (grew && _streamed && !streaming) {
      // The answer that has just landed was read as it came in.
      _settledMessages = count;
      _streamed = false;
    }
    if (streaming && !grew && !newSession && !reviewOpened) {
      // Out of sight in the studio, there is no chat to redraw: it is drawn
      // once, as it then is, when it comes back.
      if (_controller.mode != StudyDeskMode.practice) _streaming();
      return;
    }
    setState(() {});
    if (newSession) {
      _text.value = TextEditingValue(text: _controller.draft);
      _paneDismissed = false;
      _testSourceDismissed = false;
      _paragraphs.clear();
    }
    if (grew || newSession || _controller.partialAnswer != null) {
      _scrollToEnd(animate: _smoothNextScroll && grew);
      if (grew) _smoothNextScroll = false;
    }
    if (grew) _scheduleFocusUpdate();
  }

  /// What the chips of [message] say now, so a renamed note changes them.
  String _labelsOf(StudyMessage message) => message.links.isEmpty
      ? ''
      : <String>[
          for (final StudyParagraphLinks link in message.links)
            for (final StudyCitation citation in link.citations)
              _controller.labelOf(citation),
        ].join('|');

  void _refreshStreaming() {
    if (!mounted) return;
    setState(() {});
    _scrollToEnd();
  }

  void _scrollToEnd({bool animate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted && _scroll.hasClients) {
        if (_controller.messages.isEmpty && _controller.partialAnswer == null) {
          _scroll.jumpTo(0);
        } else if (animate && !MediaQuery.disableAnimationsOf(context)) {
          unawaited(
            _scroll.animateTo(
              _scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
            ),
          );
        } else {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      }
    });
  }

  /// Works out the paragraph being read once the scroll is laid out. Only the
  /// latest asked for runs.
  void _scheduleFocusUpdate() {
    _focusDebounce?.cancel();
    _focusDebounce = Timer(const Duration(milliseconds: 150), () {
      if (!mounted ||
          !_scroll.hasClients ||
          _scroll.position.isScrollingNotifier.value) {
        return;
      }
      _updateFocusedParagraph();
    });
  }

  /// As in the editor's chat, the cited paragraph nearest the line being read
  /// is the focused one. Where the pane sits beside the chat, this opens it
  /// too; over the chat, there is nothing to scroll while it is open.
  void _updateFocusedParagraph() {
    // Out of sight, there is nothing being read.
    if (_controller.mode != StudyDeskMode.chat ||
        _controller.page != StudyDeskPage.workspace) {
      return;
    }
    final RenderObject? transcript = _transcriptKey.currentContext
        ?.findRenderObject();
    if (transcript is! RenderBox || !transcript.hasSize) return;
    final double readingLine = transcript.size.height / 3;
    (int, int)? nearest;
    double nearestDistance = double.infinity;
    _paragraphs.forEach(((int, int) ref, BuildContext context) {
      final RenderObject? box = context.findRenderObject();
      if (box is! RenderBox || !box.hasSize || !box.attached) return;
      final double top = box
          .localToGlobal(Offset.zero, ancestor: transcript)
          .dy;
      final double bottom = top + box.size.height;
      if (bottom < 0 || top > transcript.size.height) return;
      final double distance = readingLine < top
          ? top - readingLine
          : (readingLine > bottom ? readingLine - bottom : 0);
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = ref;
      }
    });
    final (int, int)? found = nearest;
    if (found == null) return;
    if (_controller.focus?.isOf(found.$1, found.$2) ?? false) return;
    final List<StudyMessage> messages = _controller.messages;
    if (found.$1 >= messages.length) return;
    final List<StudyCitation> citations = messages[found.$1].citationsOf(
      found.$2,
    );
    if (citations.isEmpty) return;
    _controller.focusCitation(
      citations.first,
      message: found.$1,
      paragraph: found.$2,
      open: _sideBySide && !_paneDismissed,
    );
  }

  void _openCitation(StudyCitation citation, int message, int paragraph) {
    _paneDismissed = false;
    _controller.focusCitation(citation, message: message, paragraph: paragraph);
  }

  void _closePane() {
    _paneDismissed = true;
    _controller.closePane();
  }

  /// Opens a card or question's citation in the pane, belonging to no paragraph
  /// of the chat.
  void _viewPracticeCitation(StudyCitation citation) {
    _paneDismissed = false;
    _controller.focusCitation(citation, message: -1, paragraph: 0);
  }

  KeyEventResult _onComposerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.enter) {
      return KeyEventResult.ignored;
    }
    // Shift starts a new line, and Enter ends what an input method is writing.
    if (HardwareKeyboard.instance.isShiftPressed ||
        _text.value.composing.isValid) {
      return KeyEventResult.ignored;
    }
    _send();
    return KeyEventResult.handled;
  }

  void _send() {
    final String text = _text.text.trim();
    if (text.isEmpty || !_controller.canSend) return;
    _smoothNextScroll = true;
    _text.clear();
    if (_listening) unawaited(_speech.stop());
    unawaited(_controller.send(text));
    _composerFocus.requestFocus();
  }

  Future<void> _toggleVoiceInput() async {
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    final bool available = await _speech.initialize(
      onStatus: _onSpeechStatus,
      onError: _onSpeechError,
    );
    if (!mounted) return;
    if (!available) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('Voice input is unavailable. Check microphone access.'),
        ),
      );
      return;
    }
    _voicePrefix = _text.text.trimRight();
    setState(() => _listening = true);
    await _speech.listen(
      onResult: _onSpeechResult,
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
      ),
    );
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    if (!mounted) return;
    final String words = result.recognizedWords.trim();
    final String separator = _voicePrefix.isEmpty || words.isEmpty ? '' : ' ';
    final String value = '$_voicePrefix$separator$words';
    _text.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    if (result.finalResult) _composerFocus.requestFocus();
  }

  void _onSpeechStatus(String status) {
    if (mounted && status != 'listening' && _listening) {
      setState(() => _listening = false);
    }
  }

  void _onSpeechError(SpeechRecognitionError error) {
    if (!mounted) return;
    setState(() => _listening = false);
    if (error.permanent) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('Voice input needs microphone and speech access.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final bool onCourse =
        _controller.page == StudyDeskPage.course &&
        _controller.selectedCourse != null;
    // With the whole window to itself, the chat keeps to a width lines can be
    // read at, in the middle of whatever room it has. Moving between a class,
    // a chat, and another chat plays the page in again, in place, without
    // building anything twice: slowly the first time it is shown, and as a
    // glance after.
    final Object pageScope = onCourse
        ? ('class', _controller.selectedCourseId)
        : ('chat', _controller.sessionId);
    final Widget chat = Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        key: const ValueKey<String>('study-chat-column'),
        constraints: const BoxConstraints(
          maxWidth: StudyDeskScreen.readingWidth,
        ),
        child: StudyAppear(
          playOnMount: false,
          replayKey: pageScope,
          memoryKey: ('study-page', pageScope),
          // Rises with the keyboard by padding alone: the desk around it is
          // never resized for it (see [StudyKeyboardScope]).
          child: StudyKeyboardLift(
            child: onCourse
                ? StudyDeskOverview(
                    key: ValueKey(_controller.selectedCourseId),
                    controller: _controller,
                    onOpenSource: _openSource,
                    onAddSources: widget.onAddSources,
                    composer: _composer(),
                    onCreate: (kind) => unawaited(_createMaterial(kind)),
                  )
                : _buildChat(context),
          ),
        ),
      ),
    );
    final bool practising = _controller.mode == StudyDeskMode.practice;
    if (practising) _practiceBuilt = true;
    final Widget main = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Arrives(arrival: widget.arrival, child: _workspaceToolbar()),
        Expanded(
          // Both stay built: the chat comes back scrolled as it was left, and a
          // quiz as far as it had got. Only the one in view is painted,
          // ticking, or read out.
          child: StudyScenes(
            index: practising ? 1 : 0,
            children: <Widget>[
              chat,
              if (_practiceBuilt)
                StudyPracticeStudioView(
                  controller: _controller,
                  showPlayerBackButton: false,
                  onViewCitation: _viewPracticeCitation,
                  onAddSources: widget.onAddSources,
                  onOpenPlans: widget.onOpenPlans,
                  exportSink: widget.exportSink,
                  onOpenTestAsNote: widget.onOpenTestAsNote,
                  onSaveTestToLibrary: widget.onSaveTestToLibrary,
                )
              else
                const SizedBox.shrink(),
            ],
          ),
        ),
      ],
    );
    final workspace = ListenableBuilder(
      listenable: Listenable.merge([
        _controller.citationFocusNotifier,
        _controller.citationPaneOpen,
      ]),
      child: KeyedSubtree(key: _mainKey, child: main),
      builder: (context, stableMain) {
        return LayoutBuilder(
          builder: (context, constraints) {
            _layoutWidth = constraints.maxWidth;
            final focus = _controller.focus;
            final testSource = _controller.testPaperSource;
            final Widget? pane =
                !practising &&
                    testSource != null &&
                    !_testSourceDismissed &&
                    _sideBySide
                ? _markedPaper(
                    testSource,
                    () => setState(() => _testSourceDismissed = true),
                  )
                : _controller.paneOpen && focus != null
                ? StudyCitationPreview(
                    key: _paneKey,
                    controller: _controller,
                    citation: focus.citation,
                    pdfRasterizer: widget.pdfRasterizer,
                    onEdit: widget.onEditCitation,
                    onClose: _closePane,
                    isOpenInEditor: widget.isOpenInEditor,
                    penSettings: widget.penSettings,
                    stylusOnly: widget.stylusOnly,
                  )
                : null;
            final wide = constraints.maxWidth >= 900;
            final split = constraints.maxWidth >= Breakpoints.expanded;
            final showHistory = _historyOpen ?? (wide && testSource == null);
            final sidebar = StudyHistorySidebar(
              controller: _controller,
              onClose: () => setState(() => _historyOpen = false),
              onAddSources: widget.onAddSources,
              onBack: () {
                if (!_controller.handleBack()) widget.onLeave?.call();
              },
              onCreateMaterial: (kind) => unawaited(_createMaterial(kind)),
              closeOnSelection: !wide,
              exportSink: widget.exportSink,
            );
            final Widget desk = split
                ? StudyResizableSplit(leading: stableMain!, trailing: pane)
                : stableMain!;
            final Widget content = wide
                ? StudySidebarLayout(
                    open: showHistory,
                    width: 272,
                    dividerColor: colors.divider,
                    sidebar: sidebar,
                    main: desk,
                  )
                : desk;
            return KeyedSubtree(
              key: const ValueKey<String>('study-desk-screen'),
              child: Material(
                color: colors.background,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    content,
                    if (!wide) ...[
                      Positioned.fill(
                        child: StudyPresence(
                          child: showHistory
                              ? ModalBarrier(
                                  dismissible: true,
                                  color: colors.shadow.withValues(alpha: .35),
                                  onDismiss: () =>
                                      setState(() => _historyOpen = false),
                                )
                              : null,
                        ),
                      ),
                      Positioned.fill(
                        child: StudyPresence(
                          offset: const Offset(-0.1, 0),
                          child: showHistory
                              ? Align(
                                  alignment: AlignmentDirectional.centerStart,
                                  child: SizedBox(
                                    width: constraints.maxWidth.clamp(0, 320),
                                    child: sidebar,
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ],
                    if (!split)
                      Positioned.fill(
                        child: StudyPresence(
                          offset: const Offset(0.06, 0),
                          child: pane,
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    return workspace;
  }

  Widget _workspaceToolbar() => LayoutBuilder(
    builder: (context, constraints) {
      final historyVisible = _historyOpen ?? _layoutWidth >= 900;
      // The desk is not named over its own chat: a title is only for a place
      // within it, a class or the tests and flashcards.
      final String? title =
          _controller.browsingAllMaterials &&
              _controller.mode == StudyDeskMode.practice
          ? _controller.practiceSection == PracticeStudioSection.tests
                ? 'Tests'
                : 'Flashcards'
          : _controller.selectedCourse?.name;
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        child: Row(
          children: [
            // The button makes room for itself as it comes, and gives it back
            // as it goes, so the title slides rather than jumps.
            AnimatedSize(
              duration: AppMotion.springDuration(context, AppMotion.snappy),
              curve: AppMotion.zoomInCurve,
              alignment: AlignmentDirectional.centerStart,
              child: AnimatedSwitcher(
                duration: AppMotion.resolve(context, AppMotion.fadeIn),
                reverseDuration: AppMotion.resolve(context, AppMotion.fadeOut),
                switchInCurve: AppMotion.fadeInCurve,
                switchOutCurve: AppMotion.fadeOutCurve,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: Tween<double>(
                      begin: 0.85,
                      end: 1,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: historyVisible
                    ? const SizedBox(key: ValueKey('study-history-hidden'))
                    : IconButton(
                        key: const ValueKey('study-toggle-history'),
                        tooltip: 'Open history',
                        icon: const Icon(AppIcons.sidebar),
                        onPressed: () => setState(() => _historyOpen = true),
                      ),
              ),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: AppMotion.resolve(context, AppMotion.stateFade),
                switchInCurve: AppMotion.fadeInCurve,
                switchOutCurve: AppMotion.fadeOutCurve,
                layoutBuilder: (current, previous) => Stack(
                  alignment: AlignmentDirectional.centerStart,
                  children: <Widget>[...previous, ?current],
                ),
                child: title == null
                    ? const SizedBox(
                        key: ValueKey<String>('study-title-none'),
                        height: AppSizes.minTouchTarget,
                      )
                    : Text(
                        title,
                        key: ValueKey<String>(title),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
              ),
            ),
          ],
        ),
      );
    },
  );

  void _openSource(String noteId) {
    _viewPracticeCitation(
      StudyCitation(
        noteId: noteId,
        pageIndex: 0,
        revision: _controller.revisionOf(noteId),
      ),
    );
  }

  Future<void> _createMaterial(StudyMaterialKind kind) async {
    final course = _controller.selectedCourse;
    if (MediaQuery.sizeOf(context).width < 900) _historyOpen = false;
    if (kind == StudyMaterialKind.chats) {
      if (course != null) {
        _controller.startCourseChat(course);
      } else {
        _controller.newChat(noteIds: const []);
      }
      return;
    }
    _controller.closeFlashcardSet();
    _controller.closeTestPaper();
    _controller.setPracticeSection(
      kind == StudyMaterialKind.tests
          ? PracticeStudioSection.tests
          : PracticeStudioSection.flashcards,
    );
    _controller.setMode(StudyDeskMode.practice);
    if (kind == StudyMaterialKind.tests) {
      await showAppSheet<void>(
        context: context,
        motionKey: 'study-generate-test',
        builder: (_) => StudyGenerateTestSheet(controller: _controller),
      );
    } else {
      final request = await showAppSheet<StudyPracticeRequest>(
        context: context,
        motionKey: 'study-generate',
        builder: (_) => StudyGenerateSheet(controller: _controller),
      );
      if (request != null && mounted) {
        unawaited(_controller.generatePracticeSet(request));
      }
    }
  }

  Widget _buildChat(BuildContext context) {
    final StudyDeskController controller = _controller;
    final testSource = controller.testPaperSource;
    final List<StudyMessage> messages = controller.messages;
    final String? partial = controller.partialAnswer;
    final AiFailure? failure = controller.failure;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (controller.currentSession.testPaperId != null)
          ListTile(
            key: const ValueKey('study-test-source'),
            leading: const Icon(Icons.assignment_turned_in_outlined),
            title: Text(
              controller.testPaperSource?.title ?? 'Test unavailable',
            ),
            subtitle: Text(
              testSource != null
                  ? '${testSource.totalScore?.toStringAsFixed(0) ?? 0} / ${testSource.totalPoints} points · View marked paper'
                  : 'The source test could not be loaded.',
            ),
            onTap: controller.testPaperSource == null ? null : _openMarkedPaper,
          ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification.depth == 0) {
                if (notification is ScrollStartNotification) {
                  _focusDebounce?.cancel();
                }
                if (notification is ScrollEndNotification) {
                  _scheduleFocusUpdate();
                }
              }
              return false;
            },
            child: ListView.builder(
              key: _transcriptKey,
              controller: _scroll,
              padding: const EdgeInsets.all(AppSpacing.md),
              itemCount: messages.length + 1,
              itemBuilder: (context, index) {
                final i = index;
                if (messages.isEmpty && !controller.isBusy && failure == null) {
                  return _ChatWelcome(
                    controller: controller,
                    onStarter: controller.showStarters
                        ? (starter) => unawaited(
                            controller.send(
                              starter.prompt,
                              label: starter.label,
                              mode: starter.mode,
                            ),
                          )
                        : null,
                  );
                }
                if (i < messages.length) {
                  return StudyAppear(
                    key: ValueKey<String>(
                      'study-message-${controller.sessionId}-$i',
                    ),
                    once: ('study-message', controller.sessionId, i),
                    enabled: i >= _settledMessages,
                    rise: 14,
                    // A message is made of what does not change, and costs
                    // Markdown and citations to build: it is built again only
                    // when it, or what its chips say, does.
                    child: StudyMemo(
                      deps: <Object?>[
                        messages[i],
                        i,
                        controller.sessionId,
                        controller.pagesEpoch,
                        _labelsOf(messages[i]),
                      ],
                      builder: (context) => Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.md),
                        // Held, a message offers to be changed: a question to
                        // be edited, an answer to be written again. What it
                        // offers is read when it is held, not when built.
                        child: HoldMenu(
                          actions: () => _messageActions(i),
                          child: messages[i].fromUser
                              ? _Question(text: messages[i].text)
                              : _Answer(
                                  key: ValueKey<String>(
                                    'study-answer-${controller.sessionId}-$i',
                                  ),
                                  message: messages[i],
                                  index: i,
                                  controller: controller,
                                  register:
                                      ((int, int) ref, BuildContext context) =>
                                          _paragraphs[ref] = context,
                                  unregister:
                                      ((int, int) ref, BuildContext context) {
                                        if (identical(
                                          _paragraphs[ref],
                                          context,
                                        )) {
                                          _paragraphs.remove(ref);
                                        }
                                      },
                                  onCitation: _openCitation,
                                ),
                        ),
                      ),
                    ),
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    StudyDisclose(
                      child: controller.showTestRecommendation
                          ? Card(
                              key: const ValueKey<String>(
                                'study-test-recommendation',
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Icon(AppIcons.studyDesk),
                                    Text(
                                      'Ready for a quick test on ${controller.activeTestTopic}?',
                                    ),
                                    const Text(
                                      'Generated from your notes: 4 MCQs and 1 FRQ with a handwriting canvas.',
                                    ),
                                    FilledButton(
                                      onPressed: controller.isGeneratingTest
                                          ? null
                                          : () => unawaited(
                                              _createMaterial(
                                                StudyMaterialKind.tests,
                                              ),
                                            ),
                                      child: Text(
                                        controller.isGeneratingTest
                                            ? 'Generating test…'
                                            : 'Generate Test & Start Now',
                                      ),
                                    ),
                                    if (controller.practiceFailure != null)
                                      Text(controller.practiceFailure!.message),
                                  ],
                                ),
                              ),
                            )
                          : null,
                    ),
                    // Repainted alone: each chunk of a streamed answer changes
                    // only this, not the transcript above it.
                    if (partial != null && partial.isNotEmpty)
                      RepaintBoundary(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.md),
                          child: AiAnswerMarkdown(partial),
                        ),
                      ),
                    StudyDisclose(
                      child: controller.isBusy && (partial?.isEmpty ?? true)
                          ? StudyWorkingIndicator(
                              key: const ValueKey<String>('study-working'),
                              state: controller.requestState,
                              progress: controller.requestProgress,
                            )
                          : null,
                    ),
                    StudyDisclose(
                      child: failure == null
                          ? null
                          : _Failure(
                              key: ValueKey<String>(
                                'study-failure-${failure.kind.name}',
                              ),
                              failure: failure,
                              onRetry: () => unawaited(controller.retry()),
                              onOpenPlans:
                                  failure.kind == AiFailureKind.planRequired ||
                                      failure.kind ==
                                          AiFailureKind.insufficientCredits
                                  ? widget.onOpenPlans
                                  : null,
                            ),
                    ),
                    if (controller.showStarters)
                      _Starters(
                        onChosen: (starter) => unawaited(
                          controller.send(
                            starter.prompt,
                            label: starter.label,
                            mode: starter.mode,
                          ),
                        ),
                      ),
                    _Suggestions(
                      controller: controller,
                      onChosen: (question) {
                        _text.text = question;
                        _send();
                      },
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        // The sources, and the way to add one, sit right above where the
        // question is asked, with the field. They arrive with it.
        _Arrives(
          arrival: widget.arrival,
          delay: AppMotion.staggerStep * 3,
          rise: 24,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(
                  AppSpacing.md,
                  AppSpacing.xs,
                  AppSpacing.xs,
                  0,
                ),
                child: controller.currentSession.testPaperId != null
                    ? Text(
                        'Using your completed test and grading as the source',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: AppColors.of(context).textSecondary,
                        ),
                      )
                    : StudyChatSources(
                        compact: true,
                        controller: controller,
                        onOpenSource: _openSource,
                        onAddSources: widget.onAddSources,
                      ),
              ),
              _composer(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _composer() => ListenableBuilder(
    listenable: _text,
    builder: (context, _) => _Composer(
      text: _text,
      focusNode: _composerFocus,
      controller: _controller,
      listening: _listening,
      onOpenPlans: widget.onOpenPlans,
      onVoiceInput: () => unawaited(_toggleVoiceInput()),
      onSend: _text.text.trim().isNotEmpty && _controller.canSend
          ? _send
          : null,
    ),
  );

  Widget _markedPaper(StudyTestPaper paper, VoidCallback onClose) =>
      StudyTestPaperPlayer(
        key: ValueKey('review-source-${paper.id}'),
        paper: paper,
        controller: _controller,
        manageBackNavigation: false,
        closeTooltip: 'Close graded paper',
        onClose: onClose,
        onViewCitation: _viewPracticeCitation,
        onSaveToLibrary: widget.onSaveTestToLibrary,
      );

  /// What holding the message at [index] offers.
  List<HoldMenuAction> _messageActions(int index) {
    final List<StudyMessage> messages = _controller.messages;
    if (index >= messages.length) return const <HoldMenuAction>[];
    final StudyMessage message = messages[index];
    return <HoldMenuAction>[
      if (message.fromUser && _controller.canReviseMessage(index))
        HoldMenuAction(
          label: 'Edit',
          icon: AppIcons.rename,
          onSelected: () => unawaited(_editQuestion(index)),
        ),
      if (!message.fromUser &&
          index > 0 &&
          messages[index - 1].fromUser &&
          _controller.canReviseMessage(index))
        HoldMenuAction(
          label: 'Run again',
          icon: AppIcons.restore,
          onSelected: () => unawaited(_rerunAnswer(index)),
        ),
      HoldMenuAction(
        label: 'Copy',
        icon: AppIcons.copy,
        onSelected: () =>
            unawaited(Clipboard.setData(ClipboardData(text: message.text))),
      ),
    ];
  }

  /// Asks to be told whether to go on, when changing a message takes later
  /// ones with it.
  Future<bool> _confirmDropping(int index, String action) async {
    final int after = _controller.messagesAfter(index);
    if (after == 0) return true;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(action),
        content: Text(
          after == 1
              ? 'The message after it will be removed from this chat.'
              : 'The $after messages after it will be removed from this chat.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return confirmed == true && mounted;
  }

  Future<void> _rerunAnswer(int index) async {
    if (!await _confirmDropping(index, 'Run again')) return;
    await _controller.rerunAnswer(index);
  }

  Future<void> _editQuestion(int index) async {
    final List<StudyMessage> messages = _controller.messages;
    if (index >= messages.length) return;
    final String? edited = await showDialog<String>(
      context: context,
      builder: (BuildContext context) =>
          _EditQuestionDialog(initial: messages[index].text),
    );
    if (edited == null || edited.trim().isEmpty || !mounted) return;
    if (edited.trim() == messages[index].text.trim()) return;
    if (!await _confirmDropping(index, 'Send edit')) return;
    await _controller.editQuestion(index, edited);
  }

  void _openMarkedPaper() {
    final paper = _controller.testPaperSource;
    if (paper == null) return;
    if (_sideBySide) {
      setState(() => _testSourceDismissed = false);
    } else {
      unawaited(
        showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (context) => FractionallySizedBox(
            heightFactor: 0.95,
            child: _markedPaper(paper, () => Navigator.of(context).pop()),
          ),
        ),
      );
    }
  }
}

/// Where a question is changed before it is asked again.
class _EditQuestionDialog extends StatefulWidget {
  const _EditQuestionDialog({required this.initial});

  final String initial;

  @override
  State<_EditQuestionDialog> createState() => _EditQuestionDialogState();
}

class _EditQuestionDialogState extends State<_EditQuestionDialog> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit your question'),
      content: SizedBox(
        width: 480,
        child: TextField(
          key: const ValueKey<String>('study-edit-question'),
          controller: _text,
          autofocus: true,
          minLines: 2,
          maxLines: 8,
          textInputAction: TextInputAction.newline,
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ListenableBuilder(
          listenable: _text,
          builder: (BuildContext context, Widget? _) => FilledButton(
            onPressed: _text.text.trim().isEmpty
                ? null
                : () => Navigator.of(context).pop(_text.text),
            child: const Text('Send'),
          ),
        ),
      ],
    );
  }
}

class _ChatWelcome extends StatelessWidget {
  const _ChatWelcome({required this.controller, this.onStarter});

  final StudyDeskController controller;

  final ValueChanged<StudyStarter>? onStarter;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(width: 40, height: 4, color: colors.accent),
          const SizedBox(height: 20),
          Text(
            'A LITTLE CURIOSITY GOES A LONG WAY',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colors.textSecondary,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Make space for\nyour next idea.',
            style: Theme.of(context).textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: -1.2,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Explore your notes, untangle a topic, or put what you know to the test.',
            style: TextStyle(color: colors.textSecondary),
          ),
          const SizedBox(height: 24),
          if (onStarter != null) _Starters(onChosen: onStarter!),
          if (controller.suggestedClassFolders.isNotEmpty) ...[
            const SizedBox(height: 32),
            StudySuggestedClasses(controller: controller),
          ],
        ],
      ),
    );
  }
}

/// Brings [child] in each time [arrival] counts up, [delay] after the desk
/// starts to zoom in: part of one entrance, drawn from its own layer so it
/// moves without the rest of the desk being painted again.
class _Arrives extends StatelessWidget {
  const _Arrives({
    required this.arrival,
    required this.child,
    this.delay = Duration.zero,
    this.rise = 10,
  });

  final ValueListenable<int>? arrival;
  final Widget child;
  final Duration delay;
  final double rise;

  @override
  Widget build(BuildContext context) {
    final ValueListenable<int>? arrival = this.arrival;
    if (arrival == null) return child;
    return ValueListenableBuilder<int>(
      valueListenable: arrival,
      child: child,
      builder: (BuildContext context, int count, Widget? child) => StudyAppear(
        playOnMount: false,
        replayKey: count,
        memoryKey: const ('study-arrival', 'desk'),
        delay: delay,
        rise: rise,
        child: child!,
      ),
    );
  }
}

class _Question extends StatelessWidget {
  const _Question({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme theme = Theme.of(context).textTheme;
    return Semantics(
      container: true,
      child: Container(
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          border: BorderDirectional(
            start: BorderSide(color: colors.accent, width: 3),
          ),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'YOUR QUESTION',
              style: theme.labelSmall?.copyWith(
                color: colors.textSecondary,
                letterSpacing: 1.4,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              text,
              style: theme.bodyMedium?.copyWith(color: colors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

/// An answer, a block per paragraph, each followed by what it cites.
class _Answer extends StatelessWidget {
  const _Answer({
    super.key,
    required this.message,
    required this.index,
    required this.controller,
    required this.register,
    required this.unregister,
    required this.onCitation,
  });

  final StudyMessage message;
  final int index;
  final StudyDeskController controller;
  final void Function((int, int) ref, BuildContext context) register;
  final void Function((int, int) ref, BuildContext context) unregister;
  final void Function(StudyCitation citation, int message, int paragraph)
  onCitation;

  @override
  Widget build(BuildContext context) {
    final List<String> paragraphs = parseAiAnswer(message.text);
    return Semantics(
      container: true,
      child: SelectionArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int i = 0; i < paragraphs.length; i++)
              _Paragraph(
                key: ValueKey<String>('study-paragraph-$index-${i + 1}'),
                reference: (index, i + 1),
                text: paragraphs[i],
                citations: message.citationsOf(i + 1),
                controller: controller,
                labelOf: controller.labelOf,
                register: register,
                unregister: unregister,
                onCitation: (StudyCitation citation) =>
                    onCitation(citation, index, i + 1),
              ),
          ],
        ),
      ),
    );
  }
}

class _Paragraph extends StatefulWidget {
  const _Paragraph({
    super.key,
    required this.reference,
    required this.text,
    required this.citations,
    required this.controller,
    required this.labelOf,
    required this.register,
    required this.unregister,
    required this.onCitation,
  });

  final (int, int) reference;
  final String text;
  final List<StudyCitation> citations;
  final StudyDeskController controller;
  final String Function(StudyCitation citation) labelOf;
  final void Function((int, int) ref, BuildContext context) register;
  final void Function((int, int) ref, BuildContext context) unregister;
  final ValueChanged<StudyCitation> onCitation;

  @override
  State<_Paragraph> createState() => _ParagraphState();
}

class _ParagraphState extends State<_Paragraph> {
  static const double _markWidth = 3.5;

  @override
  void initState() {
    super.initState();
    if (widget.citations.isNotEmpty) widget.register(widget.reference, context);
  }

  @override
  void dispose() {
    widget.unregister(widget.reference, context);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<(int, int)?>(
      valueListenable: widget.controller.focusedParagraphNotifier,
      child: _content(context),
      builder: (context, reference, child) {
        final bool focused = reference == widget.reference;
        // The same mark as on the note, to tell which words it belongs to.
        return AnimatedContainer(
          duration: AppMotion.resolve(
            context,
            const Duration(milliseconds: 220),
          ),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: focused
                ? aiCitationHighlightColor.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadii.small),
            border: BorderDirectional(
              start: BorderSide(
                color: focused ? aiCitationHighlightColor : Colors.transparent,
                width: _markWidth,
              ),
            ),
          ),
          child: child,
        );
      },
    );
  }

  Widget _content(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.only(
      start: AppSpacing.xs,
      bottom: AppSpacing.xs,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AiAnswerMarkdown(widget.text),
        for (final citation in widget.citations)
          for (final diagram in citation.diagramCitations)
            StudyDiagramCard(
              controller: widget.controller,
              citation: diagram,
              onPressed: () => widget.onCitation(diagram),
            ),
        if (widget.citations.isNotEmpty)
          SelectionContainer.disabled(
            child: Wrap(
              spacing: AppSpacing.xxs,
              children: <Widget>[
                for (final StudyCitation citation in widget.citations)
                  _CitationChip(
                    label: widget.labelOf(citation),
                    onPressed: () => widget.onCitation(citation),
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}

class _Suggestions extends StatelessWidget {
  const _Suggestions({required this.controller, required this.onChosen});
  final StudyDeskController controller;
  final ValueChanged<String> onChosen;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<String>>(
    valueListenable: controller.dynamicSuggestions,
    builder: (context, suggestions, _) => AnimatedSwitcher(
      duration: AppMotion.resolve(context, AppMotion.fadeIn),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.06),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: suggestions.isEmpty
          ? const SizedBox.shrink()
          : Column(
              key: ValueKey(suggestions.join('\n')),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Explore next',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                    ValueListenableBuilder<bool>(
                      valueListenable: controller.generatingSuggestions,
                      builder: (context, busy, _) => IconButton(
                        tooltip: 'Refresh suggestions',
                        onPressed: busy
                            ? null
                            : () => unawaited(controller.refreshSuggestions()),
                        icon: const Icon(Icons.refresh),
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: [
                    for (final question in suggestions)
                      Pressable(
                        type: PressableType.chip,
                        borderRadius: BorderRadius.circular(AppRadii.small),
                        child: ActionChip(
                          label: Text(question, softWrap: true),
                          onPressed: () => onChosen(question),
                        ),
                      ),
                  ],
                ),
              ],
            ),
    ),
  );
}

class _CitationChip extends StatelessWidget {
  const _CitationChip({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Tooltip(
      message: 'Show on the note',
      // A node of its own, or it would join the message's one and could not
      // be pressed by itself.
      child: Semantics(
        container: true,
        button: true,
        label: 'Show on the note: $label',
        excludeSemantics: true,
        child: Pressable(
          child: InkWell(
            onTap: onPressed,
            customBorder: const StadiumBorder(),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: AppSizes.minTouchTarget,
                minHeight: AppSizes.minTouchTarget,
              ),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                widthFactor: 1,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    shape: const StadiumBorder(),
                    color: colors.selected,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xs,
                      vertical: AppSpacing.xxs,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          AppIcons.note,
                          size: 12,
                          color: colors.textPrimary,
                        ),
                        const SizedBox(width: AppSpacing.xxs),
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: colors.textPrimary),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class StudyWorkingIndicator extends StatelessWidget {
  const StudyWorkingIndicator({super.key, required this.state, this.progress});

  final StudyRequestState state;
  final StudyRequestProgress? progress;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final work =
        progress ??
        StudyRequestProgress(
          state == StudyRequestState.searching
              ? StudyProgressPhase.searching
              : StudyProgressPhase.answering,
        );
    final label = work.label;
    final detail = work.detail;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ExcludeSemantics(
            child: EtoniaBarsLoader(size: 24, semanticsLabel: label),
          ),
          const SizedBox(width: AppSpacing.sm),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                ),
                if (detail != null)
                  Tooltip(
                    message: detail,
                    child: Text(
                      detail,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Failure extends StatelessWidget {
  const _Failure({
    super.key,
    required this.failure,
    required this.onRetry,
    this.onOpenPlans,
  });

  final AiFailure failure;
  final VoidCallback onRetry;
  final VoidCallback? onOpenPlans;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Semantics(
      liveRegion: true,
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: AppBorderRadius.medium,
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                failure.message,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: AppSpacing.xxs),
              Wrap(
                spacing: AppSpacing.xs,
                children: <Widget>[
                  if (onOpenPlans != null)
                    TextButton(
                      onPressed: onOpenPlans,
                      child: const Text('Plans & Credits'),
                    )
                  else
                    TextButton(
                      onPressed: onRetry,
                      child: const Text('Try again'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Starters extends StatelessWidget {
  const _Starters({required this.onChosen});

  final ValueChanged<StudyStarter> onChosen;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    // All in sight at once: they are what to do next, so none scrolls away.
    return Padding(
      key: const ValueKey<String>('study-starters'),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        alignment: WrapAlignment.start,
        children: <Widget>[
          for (final (int index, StudyStarter starter)
              in StudyStarter.all.indexed)
            StudyAppear(
              once: ('study-starter', starter.label),
              delay: AppMotion.staggerStep * (index * 2 + 2),
              child: Pressable(
                type: PressableType.chip,
                borderRadius: BorderRadius.circular(AppRadii.small),
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    backgroundColor: colors.surfaceMuted,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadii.small),
                    ),
                  ),
                  onPressed: () => onChosen(starter),
                  child: Text(
                    starter.label,
                    style: TextStyle(color: colors.textPrimary),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The message field, model, dictation, and Send. Enter sends; Shift with Enter
/// starts a new line.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.text,
    required this.focusNode,
    required this.controller,
    required this.listening,
    required this.onVoiceInput,
    required this.onSend,
    this.onOpenPlans,
  });

  final TextEditingController text;
  final FocusNode focusNode;
  final StudyDeskController controller;
  final bool listening;
  final VoidCallback onVoiceInput;
  final VoidCallback? onSend;
  final VoidCallback? onOpenPlans;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme theme = Theme.of(context).textTheme;
    final bool hasModels = controller.routesModels;
    return Padding(
      key: const ValueKey('study-composer-bar'),
      padding: const EdgeInsetsDirectional.fromSTEB(
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      // The bar lifts as it is written in, with a soft shadow, and no frame is
      // drawn round it, or round the field in it: the cursor says where the
      // writing is. The field eases open and shut with its lines.
      child: ListenableBuilder(
        listenable: focusNode,
        builder: (context, child) => AnimatedContainer(
          duration: AppMotion.resolve(context, AppMotion.fadeIn),
          curve: AppMotion.fadeInCurve,
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(AppRadii.medium),
            border: Border.all(color: colors.divider),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: colors.shadow.withValues(
                  alpha: focusNode.hasFocus ? .12 : 0,
                ),
                blurRadius: focusNode.hasFocus ? 18 : 0,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: child,
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xs),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedSize(
                duration: AppMotion.springDuration(context, AppMotion.snappy),
                curve: AppMotion.zoomInCurve,
                alignment: Alignment.topCenter,
                child: TextField(
                  key: const ValueKey<String>('study-composer'),
                  controller: text,
                  focusNode: focusNode,
                  minLines: 1,
                  maxLines: 5,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  textCapitalization: TextCapitalization.sentences,
                  style: theme.bodyMedium?.copyWith(color: colors.textPrimary),
                  cursorColor: colors.accent,
                  decoration: InputDecoration(
                    filled: false,
                    hintText: controller.currentSession.testPaperId != null
                        ? 'Ask about your test'
                        : StudyDeskScreen.composerHint,
                    hintMaxLines: 2,
                    hintStyle: theme.bodyMedium?.copyWith(
                      color: colors.textSecondary,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xs,
                      vertical: AppSpacing.sm,
                    ),
                    // The theme draws a focus ring round a field; here the bar
                    // is the field, and a second frame inside it is the black
                    // box that showed on touch.
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    focusedErrorBorder: InputBorder.none,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xxs),
              Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: hasModels
                          ? AiThinkingSelector(
                              controller: controller,
                              lastServedBy: controller.lastServedBy,
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                  CompactIconButton(
                    tooltip: listening
                        ? 'Stop voice input'
                        : 'Start voice input',
                    onPressed: onVoiceInput,
                    icon: listening
                        ? AppIcons.microphoneActive
                        : AppIcons.microphone,
                    background: listening ? colors.danger : colors.surfaceMuted,
                    foreground: listening
                        ? colors.onAccent
                        : colors.textPrimary,
                    size: 36,
                  ),
                  const SizedBox(width: AppSpacing.xxs),
                  CompactIconButton(
                    tooltip: 'Send',
                    onPressed: onSend,
                    icon: AppIcons.send,
                    background: colors.accent,
                    foreground: colors.onAccent,
                    size: 36,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
