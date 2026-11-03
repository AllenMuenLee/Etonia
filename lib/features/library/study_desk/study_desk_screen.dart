import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../shared/layout/breakpoints.dart';
import '../../../shared/widgets/app_controls.dart';
import '../../../shared/widgets/etonia_mark.dart';
import '../../../shared/widgets/pressable.dart';
import '../../editor/ai/ai_citation.dart';
import '../../editor/ai/ai_client.dart';
import '../../editor/document_io/document_platform.dart';
import '../../editor/widgets/ai_assistant_panel.dart';
import '../../editor/widgets/ai_citation_highlight.dart';
import 'study_citation_preview.dart';
import 'study_desk_controller.dart';
import 'study_desk_models.dart';
import 'study_source_picker.dart';

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
    this.pdfRasterizer,
  });

  final StudyDeskController controller;
  final StudyNoteThumbnailBuilder thumbnail;

  /// Opens the cited note in the editor.
  final ValueChanged<StudyCitation> onEditCitation;
  final VoidCallback onAddSources;
  final VoidCallback? onOpenPlans;
  final PdfRasterizer? pdfRasterizer;

  static const String composerHint = 'Ask about your notes';

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

  /// The cited paragraphs built now, to find the one being read.
  final Map<(int, int), BuildContext> _paragraphs =
      <(int, int), BuildContext>{};
  int _focusUpdate = 0;

  final SpeechToText _speech = SpeechToText();
  bool _listening = false;
  String _voicePrefix = '';

  int _shownMessages = 0;
  String? _shownSession;

  /// Set when the pane is shut by hand: reading on no longer opens it, though a
  /// chip does. Only where the pane sits beside the chat.
  bool _paneDismissed = false;

  StudyDeskController get _controller => widget.controller;

  bool get _sideBySide =>
      WindowSizeClass.fromWidth(MediaQuery.sizeOf(context).width) ==
      WindowSizeClass.expanded;

  @override
  void initState() {
    super.initState();
    _text.addListener(_onTextChanged);
    _controller.addListener(_onControllerChanged);
    _scroll.addListener(_scheduleFocusUpdate);
    _shownMessages = _controller.messages.length;
    _shownSession = _controller.sessionId;
    _scrollToEnd();
    unawaited(_controller.load());
  }

  @override
  void didUpdateWidget(StudyDeskScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
  }

  @override
  void dispose() {
    _text.removeListener(_onTextChanged);
    _controller.removeListener(_onControllerChanged);
    _text.dispose();
    _composerFocus.dispose();
    _scroll.dispose();
    unawaited(_speech.cancel());
    super.dispose();
  }

  void _onTextChanged() {
    _controller.draft = _text.text;
    setState(() {});
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final int count = _controller.messages.length;
    final bool newSession = _shownSession != _controller.sessionId;
    final bool grew = count > _shownMessages;
    _shownMessages = count;
    _shownSession = _controller.sessionId;
    setState(() {});
    if (newSession) {
      _paneDismissed = false;
      _paragraphs.clear();
    }
    if (grew || newSession || _controller.partialAnswer != null) _scrollToEnd();
    if (grew) _scheduleFocusUpdate();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  /// Works out the paragraph being read once the scroll is laid out. Only the
  /// latest asked for runs.
  void _scheduleFocusUpdate() {
    final int update = ++_focusUpdate;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted && update == _focusUpdate) _updateFocusedParagraph();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// As in the editor's chat, the cited paragraph nearest the line being read
  /// is the focused one. Where the pane sits beside the chat, this opens it
  /// too; over the chat, there is nothing to scroll while it is open.
  void _updateFocusedParagraph() {
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
    final StudyCitationFocus? focus = _controller.focus;
    final Widget chat = _buildChat(context);
    final Widget? pane = _controller.paneOpen && focus != null
        ? StudyCitationPreview(
            controller: _controller,
            citation: focus.citation,
            pdfRasterizer: widget.pdfRasterizer,
            onEdit: widget.onEditCitation,
            onClose: _closePane,
          )
        : null;
    return KeyedSubtree(
      key: const ValueKey<String>('study-desk-screen'),
      child: _sideBySide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(child: chat),
                if (pane != null) ...<Widget>[
                  VerticalDivider(
                    width: AppSizes.hairline,
                    color: colors.divider,
                  ),
                  Expanded(child: pane),
                ],
              ],
            )
          : Stack(fit: StackFit.expand, children: <Widget>[chat, ?pane]),
    );
  }

  Widget _buildChat(BuildContext context) {
    final StudyDeskController controller = _controller;
    final List<StudyMessage> messages = controller.messages;
    final bool hasSources = controller.sources.isNotEmpty;
    final String? partial = controller.partialAnswer;
    final AiFailure? failure = controller.failure;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        StudySourceStrip(
          controller: controller,
          thumbnail: widget.thumbnail,
        ),
        Expanded(
          child: !hasSources && messages.isEmpty
              ? _NoSources(onAddSources: widget.onAddSources)
              : ListView(
                  key: _transcriptKey,
                  controller: _scroll,
                  padding: const EdgeInsets.all(AppSpacing.md),
                  children: <Widget>[
                    for (int i = 0; i < messages.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.md),
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
                    if (partial != null && partial.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.md),
                        child: AiAnswerMarkdown(partial),
                      ),
                    if (controller.isBusy && (partial?.isEmpty ?? true))
                      _Working(state: controller.requestState),
                    if (failure != null)
                      _Failure(
                        failure: failure,
                        onRetry: () => unawaited(controller.retry()),
                        onOpenPlans:
                            failure.kind == AiFailureKind.planRequired ||
                                failure.kind ==
                                    AiFailureKind.insufficientCredits
                            ? widget.onOpenPlans
                            : null,
                      ),
                  ],
                ),
        ),
        if (controller.showStarters)
          _Starters(
            onChosen: (StudyStarter starter) => unawaited(
              controller.send(
                starter.prompt,
                label: starter.label,
                mode: starter.mode,
              ),
            ),
          ),
        _Composer(
          text: _text,
          focusNode: _composerFocus,
          controller: controller,
          listening: _listening,
          onOpenPlans: widget.onOpenPlans,
          onVoiceInput: () => unawaited(_toggleVoiceInput()),
          onSend: _text.text.trim().isNotEmpty && controller.canSend
              ? _send
              : null,
        ),
      ],
    );
  }
}

class _NoSources extends StatelessWidget {
  const _NoSources({required this.onAddSources});

  final VoidCallback onAddSources;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(AppIcons.studyDesk, size: 48, color: colors.textSecondary),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Study from your own notes',
              textAlign: TextAlign.center,
              style: text.titleMedium?.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Add notes or whole folders, then ask about them. Answers point '
              'to the exact place on the page.',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton.icon(
              key: const ValueKey<String>('study-empty-add-sources'),
              onPressed: onAddSources,
              icon: const Icon(AppIcons.add, size: 18),
              label: const Text('Add Sources'),
            ),
          ],
        ),
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
      child: Align(
        alignment: AlignmentDirectional.centerEnd,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(start: AppSpacing.xl),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.selected,
              borderRadius: AppBorderRadius.large,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm + 2,
                vertical: AppSpacing.xs,
              ),
              child: Text(
                text,
                style: theme.bodyMedium?.copyWith(color: colors.textPrimary),
              ),
            ),
          ),
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
                focused: controller.focus?.isOf(index, i + 1) ?? false,
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
    required this.focused,
    required this.labelOf,
    required this.register,
    required this.unregister,
    required this.onCitation,
  });

  final (int, int) reference;
  final String text;
  final List<StudyCitation> citations;
  final bool focused;
  final String Function(StudyCitation citation) labelOf;
  final void Function((int, int) ref, BuildContext context) register;
  final void Function((int, int) ref, BuildContext context) unregister;
  final ValueChanged<StudyCitation> onCitation;

  @override
  State<_Paragraph> createState() => _ParagraphState();
}

class _ParagraphState extends State<_Paragraph> {
  static const double _markWidth = 3;

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
    final bool focused = widget.focused;
    // The same mark as on the note, to tell which words it belongs to.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: focused
            ? aiCitationHighlightColor.withValues(alpha: 0.22)
            : null,
        border: BorderDirectional(
          start: BorderSide(
            color: focused ? aiCitationHighlightColor : Colors.transparent,
            width: _markWidth,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(
          start: AppSpacing.xs,
          bottom: AppSpacing.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            AiAnswerMarkdown(widget.text),
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
      ),
    );
  }
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

class _Working extends StatelessWidget {
  const _Working({required this.state});

  final StudyRequestState state;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final String label = state == StudyRequestState.searching
        ? 'Searching your notes…'
        : 'Reading what it found…';
    return Row(
      children: <Widget>[
        EtoniaBarsLoader(size: 24, semanticsLabel: label),
        const SizedBox(width: AppSpacing.sm),
        Flexible(
          child: Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
          ),
        ),
      ],
    );
  }
}

class _Failure extends StatelessWidget {
  const _Failure({
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
    return SizedBox(
      key: const ValueKey<String>('study-starters'),
      height: AppSizes.minTouchTarget,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        children: <Widget>[
          for (final StudyStarter starter in StudyStarter.all)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: AppSpacing.xs),
              child: ActionChip(
                label: Text(
                  starter.label,
                  style: TextStyle(color: colors.textPrimary),
                ),
                backgroundColor: colors.surfaceMuted,
                onPressed: () => onChosen(starter),
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
    final bool hasModels = controller.models.isNotEmpty;
    OutlineInputBorder border(Color color, double width) => OutlineInputBorder(
      borderRadius: AppBorderRadius.circular(AppRadii.large + 6),
      borderSide: BorderSide(color: color, width: width),
    );
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.xs,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (hasModels)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: AiModelSelector(
                controller: controller,
                onOpenPlans: onOpenPlans,
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
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
                    hintText: controller.activeCount == 0
                        ? 'Add or tick a note to ask about it'
                        : StudyDeskScreen.composerHint,
                    hintMaxLines: 1,
                    hintStyle: theme.bodyMedium?.copyWith(
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
              const SizedBox(width: AppSpacing.xxs),
              CompactIconButton(
                tooltip: listening ? 'Stop voice input' : 'Start voice input',
                onPressed: onVoiceInput,
                icon: listening
                    ? AppIcons.microphoneActive
                    : AppIcons.microphone,
                background: listening ? colors.danger : AppGlass.muted(colors),
                foreground: listening ? colors.onAccent : colors.textPrimary,
                size: 40,
              ),
              const SizedBox(width: AppSpacing.xxs),
              CompactIconButton(
                tooltip: 'Send',
                onPressed: onSend,
                icon: AppIcons.send,
                background: colors.accent,
                foreground: colors.onAccent,
                size: 40,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
