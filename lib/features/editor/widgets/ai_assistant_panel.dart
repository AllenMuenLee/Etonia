import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../../shared/widgets/processing.dart';
import '../../../shared/widgets/etonia_mark.dart';
import '../../../shared/widgets/etonia_mascot.dart';
import '../../../shared/widgets/hold_menu.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../app/theme/app_icons.dart';
import '../../../shared/widgets/app_controls.dart';
import '../../../shared/widgets/low_token_notice.dart';
import '../ai/ai_assistant_controller.dart';
import '../ai/ai_citation.dart';
import '../ai/ai_client.dart';
import '../ai/ai_config.dart';
import '../ai/ai_usage_gate.dart';
import 'ai_routing_controls.dart';
import 'rich_answer_markdown.dart';
export 'rich_answer_markdown.dart' show AiAnswerMarkdown;
import 'ai_citation_highlight.dart';

/// The AI assistant: the selected ink the conversation is about, the
/// conversation, quick actions, and a composer. Editor preferences live in
/// Settings so this panel stays focused on the chat.
///
/// It fills whatever box it is given and scrolls inside it. Everything it
/// shows comes from [controller]; the composer's text is mirrored into
/// [AiAssistantController.draft] so that it outlives this widget.
class AiAssistantPanel extends StatefulWidget {
  const AiAssistantPanel({
    super.key,
    required this.controller,
    required this.onClose,
    required this.onNewChat,
    required this.onAddToContext,
    this.onShowOnNote,
    this.onImportToStudyDesk,
    this.config = const AiLayoutConfig(),
    this.composerKey,
    this.onOpenPlans,
    this.showHandwritingCalibrationNotice = false,
    this.onCalibrateHandwriting,
    this.onDismissHandwritingCalibrationNotice,
  });

  static const String title = 'AI assistant';
  static const String emptyState =
      'Choose a quick action or ask a question about the selected ink.';
  static const String composerHint = 'Ask a question';
  static const String handwritingCalibrationNotice =
      'Choose a handwriting for AI notes, or make your own.';

  /// Shown in place of the selection when AI mode is on with nothing chosen
  /// yet.
  static const String noContextPrompt =
      'Ask anything, and notes go in blank space on this page. Or circle a '
      'spot on the note to ask about it.';
  static const String notConfigured =
      'AI is not set up for this model. Add its key to dart_defines.json '
      '(${AiApiConfig.environmentKey}, ${AiApiConfig.claudeEnvironmentKey}, '
      'or ${AiApiConfig.openAiEnvironmentKey}) and start the app with '
      '--dart-define-from-file=dart_defines.json, or pick another model.';

  final AiAssistantController controller;
  final VoidCallback onClose;

  /// Called to use whatever the editor has selected now, resuming its
  /// conversation when one is remembered.
  final VoidCallback onNewChat;

  /// Called to add whatever the editor has selected now to the open
  /// conversation.
  final VoidCallback onAddToContext;

  /// Called to bring into view on the note what the focused paragraph is tied
  /// to, as its citation was pressed.
  final VoidCallback? onShowOnNote;
  final VoidCallback? onImportToStudyDesk;

  final AiLayoutConfig config;

  /// Given to the composer's message field, so the editor can tell where it
  /// is, as words written on the page fly into it.
  final GlobalKey? composerKey;

  /// Opens the plans and credits page. Without it, nothing offers to.
  final VoidCallback? onOpenPlans;

  /// Whether to offer calibration just above the composer. The editor owns
  /// the persisted choice, while the panel only presents it.
  final bool showHandwritingCalibrationNotice;
  final VoidCallback? onCalibrateHandwriting;
  final VoidCallback? onDismissHandwritingCalibrationNotice;

  @override
  State<AiAssistantPanel> createState() => _AiAssistantPanelState();
}

class _AiAssistantPanelState extends State<AiAssistantPanel> {
  late final TextEditingController _text = TextEditingController(
    text: widget.controller.draft,
  );
  final FocusNode _composerFocus = FocusNode(debugLabel: 'AI composer');
  final ScrollController _scroll = ScrollController();
  final GlobalKey _transcriptKey = GlobalKey();

  /// The paragraphs of the answers built now, to find the one being read.
  final Map<AiParagraphRef, BuildContext> _paragraphs =
      <AiParagraphRef, BuildContext>{};

  /// A paragraph asked for by name, which stays the one being read, however
  /// little the transcript could scroll to it, until the user scrolls.
  AiParagraphRef? _pinnedParagraph;

  /// The latest update of the paragraph being read to be asked for.
  int _focusUpdate = 0;
  final SpeechToText _speech = SpeechToText();
  int _shownMessages = 0;
  String? _shownPartial;
  AiRequestState _shownState = AiRequestState.idle;
  bool _listening = false;
  String _voicePrefix = '';

  /// Whether the composer had the keyboard when the panel was lifted out of
  /// the tree to be put somewhere else in it.
  bool _refocusComposer = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(_onTextChanged);
    widget.controller.addListener(_onControllerChanged);
    _scroll.addListener(_scheduleFocusUpdate);
    _shownMessages = widget.controller.messages.length;
    _shownState = widget.controller.requestState;
    _scrollToEnd();
    _takeComposerRequest();
    _scheduleFocusUpdate();
  }

  /// Works out the paragraph being read after the next layout, which is when
  /// everything the scroll moved is where it now is. Only the latest asked for
  /// runs: a jump made after a frame, as [_scrollToEnd] makes, is laid out by
  /// the frame after it, and an update already waiting would see the old place.
  void _scheduleFocusUpdate() {
    final int update = ++_focusUpdate;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted && update == _focusUpdate) _updateFocusedParagraph();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Makes the paragraph nearest the line being read, of those on show and
  /// tied to something on the note, the focused one.
  void _updateFocusedParagraph() {
    final AiAssistantController controller = widget.controller;
    final AiParagraphRef? pinned = _pinnedParagraph;
    if (pinned != null) {
      controller.focusParagraph(pinned);
      return;
    }
    final RenderObject? transcript = _transcriptKey.currentContext
        ?.findRenderObject();
    if (transcript is! RenderBox || !transcript.hasSize) return;
    final double height = transcript.size.height;
    final double readingLine = _readingLineIn(height);
    AiParagraphRef? nearest;
    double nearestDistance = double.infinity;
    for (final MapEntry<AiParagraphRef, BuildContext> entry
        in _paragraphs.entries) {
      final AiParagraphRef ref = entry.key;
      final AiParagraphLinks? links = controller
          .answerLinks(ref.message)
          ?.paragraphs[ref.paragraph];
      if (links == null || links.isEmpty) continue;
      final RenderObject? box = entry.value.findRenderObject();
      if (box is! RenderBox || !box.hasSize || !box.attached) continue;
      final double top = box
          .localToGlobal(Offset.zero, ancestor: transcript)
          .dy;
      final double bottom = top + box.size.height;
      if (bottom <= 0 || top >= height) continue;
      final double distance = readingLine < top
          ? top - readingLine
          : readingLine > bottom
          ? readingLine - bottom
          : 0;
      if (distance < nearestDistance) {
        nearest = ref;
        nearestDistance = distance;
      }
    }
    controller.focusParagraph(nearest);
  }

  /// How far down the transcript the line being read is taken to be.
  static const double _readingLine = 0.4;

  /// Where the line being read is in a transcript [height] tall. Near either
  /// end of the scroll it runs out to that edge, so that scrolling all the way
  /// passes it over every paragraph, however short those at the ends are.
  double _readingLineIn(double height) {
    final double resting = height * _readingLine;
    if (!_scroll.hasClients || !_scroll.position.hasContentDimensions) {
      return resting;
    }
    final double before = _scroll.position.extentBefore;
    final double after = _scroll.position.extentAfter;
    final double range = before + after;
    if (range <= 0) return resting;
    // Too little scroll to come to rest in between.
    if (range < height) return height * before / range;
    if (before < resting) return before;
    if (after < height - resting) return height - after;
    return resting;
  }

  /// The most steps taken towards a paragraph not built yet, each about a
  /// transcript's height.
  static const int _maxStepsToParagraph = 60;

  /// Scrolls the transcript to [ref]. A long transcript builds only what is
  /// near what it shows, so it is walked towards a paragraph not built yet.
  Future<void> _scrollToParagraph(AiParagraphRef ref) async {
    _pinnedParagraph = ref;
    for (int step = 0; step < _maxStepsToParagraph; step++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || _pinnedParagraph != ref || !_scroll.hasClients) return;
      final BuildContext? built = _paragraphs[ref];
      if (built != null && built.mounted) {
        await Scrollable.ensureVisible(
          built,
          alignment: _readingLine,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
        return;
      }
      final bool isAbove = _paragraphs.keys.every(
        (AiParagraphRef shown) => shown.message > ref.message,
      );
      final ScrollPosition position = _scroll.position;
      final double next =
          (position.pixels +
                  (isAbove ? -1 : 1) * position.viewportDimension * 0.9)
              .clamp(position.minScrollExtent, position.maxScrollExtent);
      if (next == position.pixels) return;
      _scroll.jumpTo(next);
    }
  }

  /// The citation under a paragraph was pressed: reads that paragraph, and
  /// shows what it is tied to on the note.
  void _showParagraphOnNote(AiParagraphRef ref) {
    _pinnedParagraph = ref;
    widget.controller.focusParagraph(ref);
    widget.onShowOnNote?.call();
  }

  void _registerParagraph(AiParagraphRef ref, BuildContext context) {
    _paragraphs[ref] = context;
    _scheduleFocusUpdate();
  }

  /// Forgets [context] as [ref]'s paragraph. Leaves one built in its place: a
  /// finished answer's paragraphs are built before those it streamed as go.
  void _unregisterParagraph(AiParagraphRef ref, BuildContext context) {
    if (identical(_paragraphs[ref], context)) _paragraphs.remove(ref);
    _scheduleFocusUpdate();
  }

  /// Puts the caret in the composer, after the frame that lays it out, if
  /// the editor has asked for it.
  void _takeComposerRequest() {
    if (!widget.controller.takeComposerRequest()) return;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted) _composerFocus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(AiAssistantPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _text.text = widget.controller.draft;
    }
  }

  @override
  void deactivate() {
    _refocusComposer = _composerFocus.hasFocus;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    // Moving between the layouts takes the focus away; give it back, so
    // typing carries on.
    if (_refocusComposer) {
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (mounted) {
          _composerFocus.requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    unawaited(_speech.cancel());
    _text.dispose();
    _composerFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final bool hadText = widget.controller.draft.trim().isNotEmpty;
    widget.controller.draft = _text.text;
    // Only the Send button depends on the text, and only on whether there
    // is any.
    if (hadText != _text.text.trim().isNotEmpty) {
      setState(() {});
    }
  }

  void _onControllerChanged() {
    final AiAssistantController controller = widget.controller;
    _takeComposerRequest();
    // Words written on the page arrive in the draft; the caret follows them.
    if (controller.draft != _text.text) {
      _text.value = TextEditingValue(
        text: controller.draft,
        selection: TextSelection.collapsed(offset: controller.draft.length),
      );
    }
    if (controller.messages.length != _shownMessages ||
        controller.requestState != _shownState) {
      _shownMessages = controller.messages.length;
      _shownState = controller.requestState;
      _pinnedParagraph = null;
      _scrollToEnd();
    } else if (controller.partialAnswer != _shownPartial && _isAtEnd) {
      // Follows the answer as it is written, unless the user has scrolled
      // up to read something else.
      _scrollToEnd();
    }
    _shownPartial = controller.partialAnswer;
    // After any scroll to the end above: selecting a drawing goes to its words.
    if (controller.takeParagraphToShow() case final AiParagraphRef ref) {
      unawaited(_scrollToParagraph(ref));
    }
    _scheduleFocusUpdate();
    setState(() {});
  }

  /// Whether the transcript is scrolled to, or nearly to, its end.
  bool get _isAtEnd {
    return !_scroll.hasClients ||
        _scroll.position.extentAfter <= AppSizes.minTouchTarget;
  }

  /// Brings the newest message, the progress bar, or the error into view.
  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _send() {
    if (widget.controller.send(_text.text)) {
      _text.clear();
    }
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
    final AiAssistantController controller = widget.controller;
    final bool canSend = controller.canSend;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      child: GlassMaterial(
        color: AppGlass.surface(colors),
        // Each part of the panel is its own node for a screen reader.
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          child: FocusTraversalGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _Header(
                  controller: controller,
                  onClose: widget.onClose,
                  onImportToStudyDesk: widget.onImportToStudyDesk,
                ),
                const Divider(),
                Expanded(
                  child: Stack(
                    children: <Widget>[
                      Positioned.fill(
                        child: NotificationListener<UserScrollNotification>(
                          onNotification: (UserScrollNotification _) {
                            _pinnedParagraph = null;
                            _scheduleFocusUpdate();
                            return false;
                          },
                          child: ListView.builder(
                            key: _transcriptKey,
                            controller: _scroll,
                            padding: const EdgeInsets.all(AppSpacing.md),
                            itemCount: _bodyItemCount(controller),
                            itemBuilder: (BuildContext context, int index) =>
                                _bodyItem(context, controller, index),
                          ),
                        ),
                      ),
                      // Floats just above the composer, over the transcript.
                      if (controller.selectionChanged)
                        PositionedDirectional(
                          start: AppSpacing.md,
                          end: AppSpacing.md,
                          bottom: AppSpacing.sm,
                          child: _SelectionChoice(
                            resumes: controller.selectionHasChat,
                            onAddToContext: widget.onAddToContext,
                            onNewChat: widget.onNewChat,
                          ),
                        ),
                    ],
                  ),
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.sm,
                    AppSpacing.md,
                    0,
                  ),
                  child: Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: <Widget>[
                      for (final AiQuickAction action in AiQuickAction.values)
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: colors.textPrimary,
                            backgroundColor: AppGlass.muted(colors),
                            side: BorderSide.none,
                            minimumSize: const Size(0, 36),
                            shape: const RoundedRectangleBorder(borderRadius: AppBorderRadius.medium),
                            textStyle: Theme.of(context).textTheme.labelLarge,
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.md - 2,
                            ),
                          ),
                          // Each acts on chosen ink.
                          onPressed: canSend && controller.hasSelection
                              ? () => controller.sendQuickAction(action)
                              : null,
                          child: Text(action.label),
                        ),
                    ],
                  ),
                ),
                // Only once the month's tokens are nearly gone.
                if (controller.usageGate case final AiUsageGate gate)
                  LowTokenNotice(fraction: gate.tokenFraction),
                _Composer(
                  fieldKey: widget.composerKey,
                  text: _text,
                  focusNode: _composerFocus,
                  maxLines: widget.config.composerMaxLines,
                  listening: _listening,
                  processing:
                      widget.controller.requestState == AiRequestState.sending,
                  onVoiceInput: canSend ? _toggleVoiceInput : null,
                  onSend: canSend && _text.text.trim().isNotEmpty
                      ? _send
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// For a model the plan does not cover, or when credits are spent:
  /// see the plans, or ask again with one of the unlimited models if
  /// the token count is at 0.
  List<(String, VoidCallback)> _accessActions(
    AiAssistantController controller,
    AiFailure failure,
  ) {
    if (failure.kind != AiFailureKind.planRequired &&
        failure.kind != AiFailureKind.insufficientCredits) {
      return const <(String, VoidCallback)>[];
    }
    final VoidCallback? openPlans = widget.onOpenPlans;
    return <(String, VoidCallback)>[
      if (openPlans != null) ('See plans', openPlans),
    ];
  }

  /// How the paragraphs of message [index] join up with the note.
  _AnswerLinking _answerLinking(AiAssistantController controller, int index) {
    return _AnswerLinking(
      message: index,
      links: controller.answerLinks(index),
      focus: controller.paragraphFocus,
      register: _registerParagraph,
      unregister: _unregisterParagraph,
      onShow: _showParagraphOnNote,
    );
  }

  int _bodyItemCount(AiAssistantController controller) {
    final bool hasPartial =
        controller.requestState == AiRequestState.sending &&
        (controller.partialAnswer?.trim().isNotEmpty ?? false);
    return 3 +
        (controller.isConfigured ? 0 : 2) +
        (controller.context != null && controller.messages.isEmpty ? 1 : 0) +
        controller.messages.length +
        (hasPartial ? 1 : 0) +
        (controller.requestState == AiRequestState.sending ? 1 : 0) +
        (controller.failure == null ? 0 : 1) +
        (widget.showHandwritingCalibrationNotice ? 1 : 0) +
        (controller.selectionChanged ? 1 : 0);
  }

  /// What holding the message at [index] offers, as things stand now.
  List<HoldMenuAction> _messageActions(int index) {
    final AiAssistantController controller = widget.controller;
    final List<AiMessage> messages = controller.messages;
    if (index >= messages.length) return const <HoldMenuAction>[];
    final AiMessage message = messages[index];
    final bool revisable = controller.canReviseMessage(index);
    return <HoldMenuAction>[
      if (revisable && message.role == AiRole.user)
        HoldMenuAction(
          label: 'Edit',
          icon: AppIcons.rename,
          onSelected: () => unawaited(_editMessage(index)),
        ),
      if (revisable &&
          message.role == AiRole.model &&
          index > 0 &&
          messages[index - 1].role == AiRole.user)
        HoldMenuAction(
          label: 'Run again',
          icon: AppIcons.restore,
          onSelected: () => unawaited(_rerunMessage(index)),
        ),
      HoldMenuAction(
        label: 'Copy',
        icon: AppIcons.copy,
        onSelected: () => unawaited(
          Clipboard.setData(ClipboardData(text: message.displayText)),
        ),
      ),
    ];
  }

  /// Asks whether to go on, when changing a message takes later ones with it.
  Future<bool> _confirmDropping(int index, String action) async {
    final int after = widget.controller.messagesAfter(index);
    if (after == 0) return true;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(action),
        content: Text(
          after == 1
              ? 'The message after it will be removed from this chat. '
                    'Notes it drew on the page stay.'
              : 'The $after messages after it will be removed from this chat. '
                    'Notes they drew on the page stay.',
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

  Future<void> _rerunMessage(int index) async {
    if (!await _confirmDropping(index, 'Run again')) return;
    widget.controller.rerunMessage(index);
  }

  Future<void> _editMessage(int index) async {
    final List<AiMessage> messages = widget.controller.messages;
    if (index >= messages.length) return;
    final String? edited = await showDialog<String>(
      context: context,
      builder: (BuildContext context) =>
          _EditMessageDialog(initial: messages[index].displayText),
    );
    if (edited == null || edited.trim().isEmpty || !mounted) return;
    if (edited.trim() == messages[index].displayText.trim()) return;
    if (!await _confirmDropping(index, 'Send edit')) return;
    widget.controller.editMessage(index, edited);
  }

  Widget _bodyItem(
    BuildContext context,
    AiAssistantController controller,
    int index,
  ) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final AiSelectionContext? selection = controller.context;
    const Widget gap = SizedBox(height: AppSpacing.sm);

    int cursor = 0;
    if (index == cursor++) {
      // What the chat is about is framed on the page; only a failure to
      // prepare it is told here.
      return selection != null
          ? (selection.imageError == null
                ? const SizedBox.shrink()
                : Text(
                    selection.imageError!.message,
                    style: text.bodyMedium?.copyWith(color: colors.danger),
                  ))
          : Text(
              AiAssistantPanel.noContextPrompt,
              key: const ValueKey<String>('ai-no-context-prompt'),
              style: text.bodyMedium?.copyWith(color: colors.textSecondary),
            );
    }
    if (index == cursor++) {
      return const SizedBox(height: AppSpacing.xs);
    }
    if (!controller.isConfigured) {
      if (index == cursor++) return gap;
      if (index == cursor++) {
        return const _Notice(message: AiAssistantPanel.notConfigured);
      }
    }
    if (index == cursor++) return gap;
    if (selection != null && controller.messages.isEmpty) {
      if (index == cursor++) {
        return Text(
          AiAssistantPanel.emptyState,
          style: text.bodyMedium?.copyWith(color: colors.textSecondary),
        );
      }
    }

    final int messageIndex = index - cursor;
    if (messageIndex >= 0 && messageIndex < controller.messages.length) {
      return Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        // Held, a message offers to be changed: yours to be edited, the
        // assistant's to be written again.
        child: HoldMenu(
          actions: () => _messageActions(messageIndex),
          child: _MessageBubble(
            message: controller.messages[messageIndex],
            answer: _answerLinking(controller, messageIndex),
          ),
        ),
      );
    }
    cursor += controller.messages.length;

    // The answer as it is written. In a two-phase request its completed text
    // remains visible here while the notation model finishes separately.
    final String? partial = controller.requestState == AiRequestState.sending
        ? controller.partialAnswer
        : null;
    if (partial != null && partial.trim().isNotEmpty) {
      if (index == cursor++) {
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: _MessageBubble(
            key: const ValueKey<String>('ai-partial-answer'),
            message: AiMessage.model(partial),
          ),
        );
      }
    }
    if (controller.requestState == AiRequestState.sending) {
      if (index == cursor++) {
        if (controller.isLoadingNotation) {
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Row(
              children: <Widget>[
                // Etonia leans into her pen and writes while the notation
                // model is working.
                const EtoniaMascot(
                  clip: EtoniaClip.write,
                  height: 64,
                  semanticsLabel: 'Notation is loading',
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Notation is loading…',
                    style: text.bodyMedium?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        // Where the answer will be written, until its first words arrive.
        return const Padding(
          padding: EdgeInsets.only(bottom: AppSpacing.sm),
          child: EtoniaBarsLoader(
            size: 40,
            semanticsLabel: 'Waiting for the AI service',
          ),
        );
      }
    }
    if (controller.failure case final AiFailure failure) {
      if (index == cursor++) {
        return _Notice(
          message: failure.message,
          actionLabel: 'Retry',
          onAction: controller.retry,
          isError: true,
          extraActions: _accessActions(controller, failure),
        );
      }
    }
    // Last in the transcript, so it sits just above the composer, and on a
    // short screen scrolls instead of pushing the composer off the panel.
    if (widget.showHandwritingCalibrationNotice && index == cursor++) {
      return Padding(
        key: const ValueKey<String>('handwriting-calibration-notice'),
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: _Notice(
          message: AiAssistantPanel.handwritingCalibrationNotice,
          actionLabel: 'Choose',
          onAction: widget.onCalibrateHandwriting,
          extraActions: <(String, VoidCallback)>[
            if (widget.onDismissHandwritingCalibrationNotice != null)
              (
                "Don't show again",
                widget.onDismissHandwritingCalibrationNotice!,
              ),
          ],
        ),
      );
    }
    if (controller.selectionChanged && index == cursor) {
      // Room to scroll the last message out from under the selection choice.
      return const SizedBox(height: AppSizes.minTouchTarget * 2);
    }
    throw RangeError.index(index, controller.messages, 'index');
  }
}

/// Where a message is changed before it is sent again.
class _EditMessageDialog extends StatefulWidget {
  const _EditMessageDialog({required this.initial});

  final String initial;

  @override
  State<_EditMessageDialog> createState() => _EditMessageDialogState();
}

class _EditMessageDialogState extends State<_EditMessageDialog> {
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
      title: const Text('Edit your message'),
      content: SizedBox(
        width: 420,
        child: TextField(
          key: const ValueKey<String>('ai-edit-message'),
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

class _Header extends StatelessWidget {
  const _Header({
    required this.controller,
    required this.onClose,
    this.onImportToStudyDesk,
  });

  final AiAssistantController controller;
  final VoidCallback onClose;
  final VoidCallback? onImportToStudyDesk;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: AppSpacing.md,
        end: AppSpacing.xs,
        top: AppSpacing.xs,
        bottom: AppSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // The title, the Study Desk button and Close share one line, so the
          // button's icon sits at the height of the title's words.
          Row(
            children: <Widget>[
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    AiAssistantPanel.title,
                    style: text.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (onImportToStudyDesk != null)
                IconButton(
                  key: const ValueKey('ai-import-to-study-desk'),
                  tooltip: 'Import conversation into Study Desk',
                  onPressed:
                      controller.messages.isEmpty ||
                          controller.requestState == AiRequestState.sending
                      ? null
                      : onImportToStudyDesk,
                  icon: const AppIcon(AppIcons.studyDesk),
                ),
              CompactIconButton(
                tooltip: 'Close AI assistant',
                onPressed: onClose,
                icon: AppIcons.close,
              ),
            ],
          ),
          if (!controller.routesModels)
            Text(
              controller.modelLabel,
              style: text.labelMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            )
          else
            AiThinkingSelector(
              controller: controller,
              lastServedBy: controller.lastServedBy,
            ),
        ],
      ),
    );
  }
}

/// Offered over the composer when ink outside the conversation is selected:
/// add it to this conversation, or talk about it in a chat of its own.
class _SelectionChoice extends StatelessWidget {
  const _SelectionChoice({
    required this.resumes,
    required this.onAddToContext,
    required this.onNewChat,
  });

  static const String message = 'New selection';

  /// Whether the selection already has a remembered conversation, which
  /// the second choice goes back to instead of starting one.
  final bool resumes;
  final VoidCallback onAddToContext;
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final ThemeData theme = Theme.of(context);
    final ButtonStyle style = TextButton.styleFrom(
      foregroundColor: colors.accentText,
      shape: const RoundedRectangleBorder(borderRadius: AppBorderRadius.medium),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
    );
    return Semantics(
      container: true,
      explicitChildNodes: true,
      liveRegion: true,
      child: GlassSurface(
        borderRadius: AppBorderRadius.large,
        boxShadow: AppShadows.floating(colors),
        child: Padding(
          padding: const EdgeInsetsDirectional.only(
            start: AppSpacing.sm,
            end: AppSpacing.xxs,
            top: AppSpacing.xxs,
            bottom: AppSpacing.xxs,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsetsDirectional.only(
                  top: AppSpacing.xxs,
                  end: AppSpacing.xs,
                ),
                child: Text(message, style: theme.textTheme.labelLarge),
              ),
              // Side by side when they fit, one above the other otherwise.
              OverflowBar(
                alignment: MainAxisAlignment.end,
                overflowAlignment: OverflowBarAlignment.end,
                children: <Widget>[
                  TextButton(
                    style: style,
                    onPressed: onAddToContext,
                    child: const Text('Add to context'),
                  ),
                  TextButton(
                    style: style,
                    onPressed: onNewChat,
                    child: Text(resumes ? 'Open its chat' : 'New chat'),
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

/// A line of status with, optionally, one thing to do about it.
class _Notice extends StatelessWidget {
  const _Notice({
    required this.message,
    this.actionLabel,
    this.onAction,
    this.isError = false,
    this.extraActions = const <(String, VoidCallback)>[],
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool isError;

  /// Offered before [actionLabel], such as switching model.
  final List<(String, VoidCallback)> extraActions;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final ThemeData theme = Theme.of(context);
    final String? actionLabel = this.actionLabel;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isError
              ? Color.alphaBlend(
                  colors.danger.withValues(alpha: 0.08),
                  colors.surface,
                )
              : colors.surfaceMuted,
          borderRadius: AppBorderRadius.large,
          border: Border.all(
            color: isError
                ? colors.danger.withValues(alpha: 0.35)
                : Colors.transparent,
            width: AppSizes.hairline,
          ),
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.only(
            start: AppSpacing.sm,
            end: AppSpacing.xxs,
            top: AppSpacing.xs,
            bottom: AppSpacing.xxs,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsetsDirectional.only(
                  end: AppSpacing.xs,
                  bottom: AppSpacing.xxs,
                ),
                child: Text(message, style: theme.textTheme.bodyMedium),
              ),
              if (actionLabel != null || extraActions.isNotEmpty)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    children: <Widget>[
                      for (final (String label, VoidCallback? action)
                          in <(String, VoidCallback?)>[
                            ...extraActions,
                            if (actionLabel != null) (actionLabel, onAction),
                          ])
                        TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: colors.accentText,
                            shape: const RoundedRectangleBorder(
                              borderRadius: AppBorderRadius.medium,
                            ),
                          ),
                          onPressed: action,
                          child: Text(label),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One message: who wrote it, then what they wrote. The user's sit at the
/// trailing edge on a tinted fill; the assistant's at the leading edge,
/// outlined, with its Markdown and formulas rendered and selectable.
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({super.key, required this.message, this.answer});

  final AiMessage message;

  /// How its paragraphs join up with the note.
  final _AnswerLinking? answer;

  /// The answer's words: one block, or, once anything in it is tied to the
  /// note, a block for each paragraph with its citation after it.
  Widget _answer(BuildContext context, TextTheme text) {
    Widget markdown(String source) => AiAnswerMarkdown(source);

    final _AnswerLinking? answer = this.answer;
    final AiAnswerLinks? links = answer?.links;
    if (answer == null || links == null || links.isEmpty) {
      return markdown(stripAiCitations(message.displayText));
    }
    final List<String> paragraphs = parseAiAnswer(message.displayText);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < paragraphs.length; i++)
          _LinkedParagraph(
            ref: AiParagraphRef(answer.message, i + 1),
            answer: answer,
            links: links.paragraphs[i + 1],
            child: markdown(paragraphs[i]),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final bool fromUser = message.role == AiRole.user;
    // One node for a screen reader: the writer, then the words.
    return Semantics(
      container: true,
      child: Column(
        crossAxisAlignment: fromUser
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: <Widget>[
          Text(fromUser ? 'You' : 'Assistant', style: text.labelMedium),
          const SizedBox(height: AppSpacing.xxs),
          Padding(
            padding: EdgeInsetsDirectional.only(
              start: fromUser ? AppSpacing.xl : 0,
            ),
            // The user's words on a tinted bubble; the assistant's set
            // straight on the panel, like a page.
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: fromUser ? colors.selected : null,
                borderRadius: const BorderRadiusDirectional.only(
                  topStart: Radius.circular(AppRadii.large),
                  topEnd: Radius.circular(AppRadii.small),
                  bottomStart: Radius.circular(AppRadii.large),
                  bottomEnd: Radius.circular(AppRadii.large),
                ).resolve(Directionality.of(context)),
              ),
              child: Padding(
                padding: fromUser
                    ? const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm + 2,
                        vertical: AppSpacing.xs,
                      )
                    : EdgeInsets.zero,
                child: fromUser
                    ? Text(message.displayText, style: text.bodyMedium)
                    : SelectionArea(child: _answer(context, text)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What the paragraphs of one answer need to join up with the note.
class _AnswerLinking {
  const _AnswerLinking({
    required this.message,
    required this.links,
    required this.focus,
    required this.register,
    required this.unregister,
    required this.onShow,
  });

  /// The message's index among the conversation's messages.
  final int message;
  final AiAnswerLinks? links;
  final ValueListenable<AiParagraphFocus?> focus;
  final void Function(AiParagraphRef ref, BuildContext context) register;
  final void Function(AiParagraphRef ref, BuildContext context) unregister;
  final void Function(AiParagraphRef ref) onShow;
}

/// One paragraph of an answer tied to the note: marked while it is the one
/// being read, and followed by its citation when it has anything to show.
class _LinkedParagraph extends StatefulWidget {
  const _LinkedParagraph({
    required this.ref,
    required this.answer,
    required this.links,
    required this.child,
  });

  final AiParagraphRef ref;
  final _AnswerLinking answer;
  final AiParagraphLinks? links;
  final Widget child;

  @override
  State<_LinkedParagraph> createState() => _LinkedParagraphState();
}

class _LinkedParagraphState extends State<_LinkedParagraph> {
  @override
  void initState() {
    super.initState();
    widget.answer.register(widget.ref, context);
  }

  @override
  void didUpdateWidget(_LinkedParagraph oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ref != widget.ref) {
      oldWidget.answer.unregister(oldWidget.ref, context);
      widget.answer.register(widget.ref, context);
    }
  }

  @override
  void dispose() {
    widget.answer.unregister(widget.ref, context);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AiParagraphLinks? links = widget.links;
    final bool hasLinks = links != null && !links.isEmpty;
    return ValueListenableBuilder<AiParagraphFocus?>(
      key: ValueKey<String>(
        'ai-paragraph-${widget.ref.message}-${widget.ref.paragraph}',
      ),
      valueListenable: widget.answer.focus,
      builder: (BuildContext context, AiParagraphFocus? focus, Widget? child) {
        final bool focused = focus?.ref == widget.ref;
        // The same mark as on the note, to tell which words it belongs to.
        return DecoratedBox(
          decoration: BoxDecoration(
            color: focused
                ? aiCitationHighlightColor.withValues(alpha: 0.22)
                : null,
            border: BorderDirectional(
              start: BorderSide(
                color: focused ? aiCitationHighlightColor : Colors.transparent,
                width: _CitationChip.markWidth,
              ),
            ),
          ),
          child: child,
        );
      },
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: AppSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            widget.child,
            if (hasLinks)
              SelectionContainer.disabled(
                child: _CitationChip(
                  label: links.label,
                  onPressed: () => widget.answer.onShow(widget.ref),
                ),
              )
            else
              const SizedBox(height: AppSpacing.xs),
          ],
        ),
      ),
    );
  }
}

/// The lines of the selection a paragraph refers to. Pressing it shows them
/// on the note.
class _CitationChip extends StatelessWidget {
  const _CitationChip({required this.label, required this.onPressed});

  /// The bar beside the paragraph being read.
  static const double markWidth = 3;

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
        child: InkWell(
          onTap: onPressed,
          customBorder: const RoundedRectangleBorder(borderRadius: AppBorderRadius.medium),
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
                  shape: const RoundedRectangleBorder(borderRadius: AppBorderRadius.medium),
                  color: colors.selected,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xs,
                    vertical: 2,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      AppIcon(
                        AppIcons.note,
                        size: 12,
                        color: colors.textSecondary,
                      ),
                      const SizedBox(width: AppSpacing.xxs),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: colors.textSecondary),
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
    );
  }
}

/// The message field and Send. Enter starts a new line; Ctrl or Cmd with
/// Enter sends.
class _Composer extends StatelessWidget {
  const _Composer({
    this.fieldKey,
    required this.text,
    required this.focusNode,
    required this.maxLines,
    required this.listening,
    required this.processing,
    required this.onVoiceInput,
    required this.onSend,
  });

  final Key? fieldKey;
  final TextEditingController text;
  final FocusNode focusNode;
  final int maxLines;
  final bool listening;

  /// Whether an answer is on its way; the field breathes a soft glow.
  final bool processing;

  /// Starts or stops dictation into the message field.
  final VoidCallback? onVoiceInput;

  /// Null while there is nothing to send, or nothing can be sent.
  final VoidCallback? onSend;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    OutlineInputBorder border(Color color, double width) {
      return OutlineInputBorder(
        borderRadius: AppBorderRadius.circular(AppRadii.large + 6),
        borderSide: BorderSide(color: color, width: width),
      );
    }

    void send() => onSend?.call();
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: AppSpacing.md,
        end: AppSpacing.xs,
        top: AppSpacing.sm,
        bottom: AppSpacing.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            key: fieldKey,
            child: AmbientGlow(
              active: processing,
              borderRadius: AppBorderRadius.circular(AppRadii.large + 6),
              child: CallbackShortcuts(
                bindings: <ShortcutActivator, VoidCallback>{
                  const SingleActivator(
                    LogicalKeyboardKey.enter,
                    control: true,
                  ): send,
                  const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                      send,
                },
                child: TextField(
                  controller: text,
                  focusNode: focusNode,
                  minLines: 1,
                  maxLines: maxLines,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  textCapitalization: TextCapitalization.sentences,
                  style: textTheme.bodyMedium,
                  cursorColor: colors.accent,
                  decoration: InputDecoration(
                    hintText: AiAssistantPanel.composerHint,
                    hintMaxLines: 1,
                    hintStyle: textTheme.bodyMedium?.copyWith(
                      color: colors.textSecondary,
                    ),
                    isDense: true,
                    constraints: const BoxConstraints(
                      minHeight: AppSizes.minTouchTarget,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: AppSpacing.sm,
                    ),
                    border: border(Colors.transparent, AppSizes.hairline),
                    enabledBorder: border(
                      Colors.transparent,
                      AppSizes.hairline,
                    ),
                    focusedBorder: border(
                      colors.focus,
                      AppSizes.focusRingWidth,
                    ),
                  ),
                ),
              ),
            ),
          ),
          CompactIconButton(
            tooltip: listening ? 'Stop voice input' : 'Start voice input',
            onPressed: onVoiceInput,
            icon: listening ? AppIcons.microphoneActive : AppIcons.microphone,
            glyphSize: 15,
            background: listening ? colors.danger : AppGlass.muted(colors),
            foreground: listening ? colors.onAccent : colors.textPrimary,
          ),
          CompactIconButton(
            tooltip: 'Send',
            onPressed: onSend,
            icon: AppIcons.send,
            glyphSize: 15,
            background: colors.accent,
            foreground: colors.onAccent,
          ),
        ],
      ),
    );
  }
}
