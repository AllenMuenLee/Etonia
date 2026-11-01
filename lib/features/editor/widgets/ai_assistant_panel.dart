import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../../shared/widgets/processing.dart';
import '../../../shared/widgets/etonia_mark.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../shared/motion/motion_memory.dart';
import '../../../app/theme/app_icons.dart';
import '../../../shared/widgets/app_controls.dart';
import '../ai/ai_assistant_controller.dart';
import '../ai/ai_client.dart';
import '../ai/ai_config.dart';
import '../ai/ai_usage_gate.dart';
import '../ai/chat_math.dart';

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
    _shownMessages = widget.controller.messages.length;
    _shownState = widget.controller.requestState;
    _scrollToEnd();
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
      _scrollToEnd();
    } else if (controller.partialAnswer != _shownPartial && _isAtEnd) {
      // Follows the answer as it is written, unless the user has scrolled
      // up to read something else.
      _scrollToEnd();
    }
    _shownPartial = controller.partialAnswer;
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
                  onOpenPlans: widget.onOpenPlans,
                ),
                const Divider(),
                Expanded(
                  child: Stack(
                    children: <Widget>[
                      Positioned.fill(
                        child: ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.all(AppSpacing.md),
                          itemCount: _bodyItemCount(controller),
                          itemBuilder: (BuildContext context, int index) =>
                              _bodyItem(context, controller, index),
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
                            shape: const StadiumBorder(),
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

  /// For a model the plan does not cover: see the plans, or ask again with
  /// one of the unlimited models.
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
      for (final AiModelId model in const <AiModelId>[
        AiModelId.haiku,
        AiModelId.luna,
      ])
        if (model != controller.selectedModel &&
            controller.models.contains(model) &&
            (controller.accessFor(model)?.canSend ?? true))
          (
            'Use ${model.label}',
            () {
              controller.selectModel(model);
              controller.retry();
            },
          ),
    ];
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
        child: _MessageBubble(message: controller.messages[messageIndex]),
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
                const EtoniaBarsLoader(
                  size: 32,
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

class _Header extends StatelessWidget {
  const _Header({
    required this.controller,
    required this.onClose,
    required this.onOpenPlans,
  });

  final AiAssistantController controller;
  final VoidCallback onClose;
  final VoidCallback? onOpenPlans;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final AiUsageGate? gate = controller.usageGate;
    final VoidCallback? openPlans = onOpenPlans;
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: AppSpacing.md,
        end: AppSpacing.xs,
        top: AppSpacing.xs,
        bottom: AppSpacing.xs,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Semantics(
                  header: true,
                  child: Text(
                    AiAssistantPanel.title,
                    style: text.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 2),
                if (controller.models.isEmpty)
                  Text(
                    controller.modelLabel,
                    style: text.labelMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                else
                  AiModelSelector(
                    controller: controller,
                    onOpenPlans: openPlans,
                  ),
              ],
            ),
          ),
          if (gate != null && openPlans != null)
            _CreditsPill(
              label: gate.creditsLabel,
              fraction: gate.tokenFraction,
              onPressed: openPlans,
            ),
          CompactIconButton(
            tooltip: 'Close AI assistant',
            onPressed: onClose,
            icon: AppIcons.close,
          ),
        ],
      ),
    );
  }
}

/// The tokens left with a lit bar, or Upgrade; opens the plans.
class _CreditsPill extends StatelessWidget {
  const _CreditsPill({
    required this.label,
    required this.fraction,
    required this.onPressed,
  });

  final String label;
  final double fraction;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final bool upgrade = label == 'Upgrade';
    final Color foreground = upgrade ? colors.onAccent : colors.textPrimary;
    final Color baseSurface = AppGlass.muted(colors);
    return Tooltip(
      message: 'Plans & Credits',
      child: Semantics(
        button: true,
        label: upgrade ? 'Upgrade plan' : 'AI tokens, $label',
        excludeSemantics: true,
        child: InkWell(
          key: const ValueKey<String>('ai-credits-pill'),
          onTap: onPressed,
          customBorder: const StadiumBorder(),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: AppSizes.minTouchTarget,
              minHeight: AppSizes.minTouchTarget,
            ),
            child: Center(
              widthFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: upgrade ? colors.accent : null,
                  gradient: upgrade
                      ? null
                      : LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: <Color>[
                            Color.alphaBlend(
                              Colors.white.withValues(
                                alpha: dark ? 0.08 : 0.55,
                              ),
                              baseSurface,
                            ),
                            baseSurface,
                            Color.alphaBlend(
                              colors.shadow.withValues(
                                alpha: dark ? 0.18 : 0.05,
                              ),
                              baseSurface,
                            ),
                          ],
                          stops: const <double>[0.0, 0.52, 1.0],
                        ),
                  border: upgrade
                      ? null
                      : Border.all(
                          color: colors.glassEdge,
                          width: AppSizes.hairline,
                        ),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: (upgrade ? colors.accent : colors.shadow)
                          .withValues(alpha: upgrade ? 0.24 : 0.07),
                      blurRadius: upgrade ? 10 : 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: upgrade ? AppSpacing.xxs + 2 : AppSpacing.xxs + 1,
                  ),
                  child: upgrade
                      ? Text(
                          label,
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                color: foreground,
                                fontWeight: FontWeight.w600,
                              ),
                        )
                      : IntrinsicWidth(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              Text(
                                label,
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: foreground,
                                      fontWeight: FontWeight.w600,
                                      fontFeatures: const <FontFeature>[
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                              ),
                              const SizedBox(height: 3),
                              TokenMeterBar(
                                key: const ValueKey<String>('ai-token-bar'),
                                fraction: fraction,
                                height: 6,
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

/// The model the next message goes to, as a button that lists every model
/// to switch to: what each is for, and what the plan gives of it.
class AiModelSelector extends StatelessWidget {
  const AiModelSelector({
    super.key,
    required this.controller,
    this.onOpenPlans,
  });

  final AiAssistantController controller;
  final VoidCallback? onOpenPlans;

  static bool _alwaysUnlimited(AiModelId model) =>
      model == AiModelId.haiku || model == AiModelId.luna;

  /// Relative token-credit consumption shown beside [model].
  static String badgeFor(AiModelId model) => 'x${model.tokenMultiplier}';

  /// Whether [model] shows a lock: the plan does not include it.
  static bool isLocked(AiModelId model, AiModelAccess? access) {
    return !_alwaysUnlimited(model) &&
        (access == AiModelAccess.locked || access == AiModelAccess.noPlan);
  }

  void _choose(AiModelId model) {
    final VoidCallback? openPlans = onOpenPlans;
    // A model the plan lacks leads to the plans that have it.
    if (openPlans != null && isLocked(model, controller.accessFor(model))) {
      openPlans();
      return;
    }
    controller.selectModel(model);
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final AiModelId? selected = controller.selectedModel;
    final String label = selected?.label ?? controller.modelLabel;
    return PopupMenuButton<AiModelId>(
      popUpAnimationStyle: AppMotion.pacedPopupStyle(
        MotionMemory.instance.peek(('popup', 'ai-model')),
      ),
      onOpened: () => MotionMemory.instance.remember(('popup', 'ai-model')),
      key: const ValueKey<String>('ai-model-selector'),
      tooltip: 'Choose model',
      initialValue: selected,
      onSelected: _choose,
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 320),
      itemBuilder: (BuildContext context) {
        return <PopupMenuEntry<AiModelId>>[
          for (final AiModelId model in controller.models)
            PopupMenuItem<AiModelId>(
              key: ValueKey<String>('ai-model-${model.name}'),
              value: model,
              enabled: controller.isModelConfigured(model),
              child: _ModelOption(
                model: model,
                selected: model == selected,
                configured: controller.isModelConfigured(model),
                access: controller.accessFor(model),
              ),
            ),
        ];
      },
      child: Semantics(
        button: true,
        label: 'Model: $label. Choose model',
        excludeSemantics: true,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSizes.minTouchTarget),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            widthFactor: 1,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                shape: const StadiumBorder(),
                color: AppGlass.muted(colors),
              ),
              child: Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: AppSpacing.sm,
                  end: AppSpacing.xs,
                  top: AppSpacing.xxs + 2,
                  bottom: AppSpacing.xxs + 2,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(AppIcons.plans, size: 14, color: colors.textPrimary),
                    const SizedBox(width: AppSpacing.xxs),
                    Flexible(
                      child: Text(
                        label,
                        key: const ValueKey<String>('ai-model-label'),
                        style: text.labelLarge?.copyWith(
                          color: colors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(AppIcons.model, size: 14, color: colors.textPrimary),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One model in the picker: a check by the chosen one, its name, its
/// provider and what it is for, and what the plan gives of it.
class _ModelOption extends StatelessWidget {
  const _ModelOption({
    required this.model,
    required this.selected,
    required this.configured,
    required this.access,
  });

  final AiModelId model;
  final bool selected;
  final bool configured;
  final AiModelAccess? access;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final String badge = AiModelSelector.badgeFor(model);
    final bool locked = AiModelSelector.isLocked(model, access);
    return Row(
      children: <Widget>[
        SizedBox(
          width: 24,
          child: selected
              ? Icon(AppIcons.check, size: 16, color: colors.accent)
              : null,
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                model.label,
                style: text.bodyLarge?.copyWith(
                  color: colors.textPrimary,
                  fontWeight: selected ? FontWeight.w600 : null,
                ),
              ),
              Text(
                configured
                    ? '${model.provider.label} · ${model.summary}'
                    : '${model.provider.label} · No API key',
                style: text.bodySmall?.copyWith(color: colors.textSecondary),
              ),
            ],
          ),
        ),
        DecoratedBox(
          decoration: ShapeDecoration(
            shape: const StadiumBorder(),
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
                if (locked) ...<Widget>[
                  Icon(
                    AppIcons.lock,
                    key: ValueKey<String>('ai-model-lock-${model.name}'),
                    size: 12,
                    color: colors.textPrimary,
                    semanticLabel: 'Locked',
                  ),
                  const SizedBox(width: 2),
                ],
                Text(
                  badge,
                  style: text.labelSmall?.copyWith(color: colors.textPrimary),
                ),
              ],
            ),
          ),
        ),
      ],
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
      foregroundColor: colors.accent,
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
                            foregroundColor: colors.accent,
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
  const _MessageBubble({super.key, required this.message});

  final AiMessage message;

  /// Stands in for an image the answer links to.
  static Widget _imagePlaceholder(
    BuildContext context,
    String url,
    double? width,
    double? height,
  ) {
    return Text('[image]', style: Theme.of(context).textTheme.labelMedium);
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
                    : SelectionArea(
                        child: GptMarkdown(
                          delimitBareMath(
                            normalizeInlineMath(message.displayText),
                          ),
                          style: text.bodyMedium,
                          textDirection: Directionality.of(context),
                          useDollarSignsForLatex: true,
                          // An answer never makes the app fetch anything.
                          imageBuilder: _imagePlaceholder,
                        ),
                      ),
              ),
            ),
          ),
        ],
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
    );
  }
}
