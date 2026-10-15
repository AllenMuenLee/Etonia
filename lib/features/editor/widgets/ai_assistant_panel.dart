import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../../app/theme/app_tokens.dart';
import '../ai/ai_assistant_controller.dart';
import '../ai/ai_client.dart';
import '../ai/ai_config.dart';
import '../ai/chat_math.dart';
import '../ai/selection_image_renderer.dart';

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
  });

  static const String title = 'AI assistant';
  static const String emptyState =
      'Choose a quick action or ask a question about the selected ink.';
  static const String composerHint = 'Ask about the selected ink';
  static const String notConfigured =
      'AI is not set up. Start the app with '
      '--dart-define=${AiApiConfig.environmentKey}=<your key> to send '
      'messages.';

  final AiAssistantController controller;
  final VoidCallback onClose;

  /// Called to use whatever the editor has selected now, resuming its
  /// conversation when one is remembered.
  final VoidCallback onNewChat;

  /// Called to add whatever the editor has selected now to the open
  /// conversation.
  final VoidCallback onAddToContext;

  final AiLayoutConfig config;

  @override
  State<AiAssistantPanel> createState() => _AiAssistantPanelState();
}

class _AiAssistantPanelState extends State<AiAssistantPanel> {
  late final TextEditingController _text = TextEditingController(
    text: widget.controller.draft,
  );
  final FocusNode _composerFocus = FocusNode(debugLabel: 'AI composer');
  final ScrollController _scroll = ScrollController();
  int _shownMessages = 0;
  String? _shownPartial;
  AiRequestState _shownState = AiRequestState.idle;

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

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final AiAssistantController controller = widget.controller;
    final bool canSend = controller.canSend;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      child: Material(
        color: colors.surface,
        // Each part of the panel is its own node for a screen reader.
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          child: FocusTraversalGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _Header(
                  modelLabel: controller.modelLabel,
                  onClose: widget.onClose,
                ),
                const Divider(),
                Expanded(
                  child: Stack(
                    children: <Widget>[
                      Positioned.fill(
                        child: ListView(
                          controller: _scroll,
                          padding: const EdgeInsets.all(AppSpacing.md),
                          children: _body(context, controller),
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
                    AppSpacing.xs,
                    AppSpacing.md,
                    0,
                  ),
                  child: Wrap(
                    spacing: AppSpacing.xs,
                    children: <Widget>[
                      for (final AiQuickAction action in AiQuickAction.values)
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: colors.textPrimary,
                            side: BorderSide(
                              color: colors.divider,
                              width: AppSizes.hairline,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                AppRadii.medium,
                              ),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.sm,
                            ),
                          ),
                          onPressed: canSend
                              ? () => controller.sendQuickAction(action)
                              : null,
                          child: Text(action.label),
                        ),
                    ],
                  ),
                ),
                _Composer(
                  text: _text,
                  focusNode: _composerFocus,
                  maxLines: widget.config.composerMaxLines,
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

  List<Widget> _body(BuildContext context, AiAssistantController controller) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final AiSelectionContext? selection = controller.context;
    const Widget gap = SizedBox(height: AppSpacing.sm);

    return <Widget>[
      if (selection != null)
        _Preview(
          selection: selection,
          maxHeight: widget.config.previewMaxHeight,
        ),
      const SizedBox(height: AppSpacing.xs),
      if (!controller.isConfigured) ...<Widget>[
        gap,
        const _Notice(message: AiAssistantPanel.notConfigured),
      ],
      gap,
      if (controller.messages.isEmpty)
        Text(
          AiAssistantPanel.emptyState,
          style: text.bodyMedium?.copyWith(color: colors.textSecondary),
        ),
      for (final AiMessage message in controller.messages)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: _MessageBubble(message: message),
        ),
      // The answer as it is written. It becomes a message, and any drawing
      // is added to the note, once all of it has arrived.
      if (controller.requestState == AiRequestState.sending)
        if (controller.partialAnswer case final String partial
            when partial.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: _MessageBubble(
              key: const ValueKey<String>('ai-partial-answer'),
              message: AiMessage.model(partial),
            ),
          ),
      if (controller.requestState == AiRequestState.sending) ...<Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: LinearProgressIndicator(
            semanticsLabel: 'Waiting for the AI service',
            color: colors.accent,
            backgroundColor: colors.divider,
            borderRadius: BorderRadius.circular(AppRadii.small),
          ),
        ),
      ],
      if (controller.failure case final AiFailure failure)
        _Notice(
          message: failure.message,
          actionLabel: 'Retry',
          onAction: controller.retry,
          isError: true,
        ),
      // Room to scroll the last message out from under the selection choice.
      if (controller.selectionChanged)
        const SizedBox(height: AppSizes.minTouchTarget * 2),
    ];
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.modelLabel, required this.onClose});

  final String modelLabel;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: AppSpacing.md,
        end: AppSpacing.xxs,
        top: AppSpacing.xxs,
        bottom: AppSpacing.xxs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
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
              IconButton(
                tooltip: 'Close AI assistant',
                onPressed: onClose,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: AppSpacing.sm),
            child: Text(
              modelLabel,
              style: text.labelMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// The image the model is sent, exactly: the same bytes, never a second
/// drawing.
class _Preview extends StatelessWidget {
  const _Preview({required this.selection, required this.maxHeight});

  static const double _placeholderHeight = 72;

  final AiSelectionContext selection;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final SelectionImage? image = selection.image;
    final BorderRadius radius = BorderRadius.circular(AppRadii.medium);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return Container(
          width: double.infinity,
          height: image == null
              ? _placeholderHeight
              : math.min(
                  maxHeight,
                  constraints.maxWidth * image.height / image.width,
                ),
          clipBehavior: Clip.antiAlias,
          alignment: Alignment.center,
          padding: image == null ? const EdgeInsets.all(AppSpacing.sm) : null,
          decoration: BoxDecoration(
            color: image == null
                ? colors.background
                : selection.snapshot.background,
            borderRadius: radius,
          ),
          foregroundDecoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: colors.divider, width: AppSizes.hairline),
          ),
          child: image == null
              ? Text(
                  selection.imageError?.message ?? 'Preparing the preview',
                  style: text.labelMedium,
                  textAlign: TextAlign.center,
                )
              : Image.memory(
                  image.png,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                  semanticLabel: 'Selected ink',
                ),
        );
      },
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.medium),
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
    );
    return Semantics(
      container: true,
      explicitChildNodes: true,
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(AppRadii.medium),
          border: Border.all(color: colors.divider, width: AppSizes.hairline),
          boxShadow: AppShadows.floating(colors),
        ),
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
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool isError;

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
          color: colors.background,
          borderRadius: BorderRadius.circular(AppRadii.medium),
          border: Border.all(
            color: isError ? theme.colorScheme.error : colors.divider,
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
              if (actionLabel != null)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: colors.accent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadii.medium),
                      ),
                    ),
                    onPressed: onAction,
                    child: Text(actionLabel),
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
              start: fromUser ? AppSpacing.lg : 0,
              end: fromUser ? 0 : AppSpacing.lg,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: fromUser ? colors.selected : colors.surface,
                borderRadius: BorderRadius.circular(AppRadii.medium),
                border: Border.all(
                  color: fromUser ? colors.selected : colors.divider,
                  width: AppSizes.hairline,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: AppSpacing.xs,
                ),
                child: fromUser
                    ? Text(message.displayText, style: text.bodyMedium)
                    : SelectionArea(
                        child: GptMarkdown(
                          delimitBareMath(message.displayText),
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
    required this.text,
    required this.focusNode,
    required this.maxLines,
    required this.onSend,
  });

  final TextEditingController text;
  final FocusNode focusNode;
  final int maxLines;

  /// Null while there is nothing to send, or nothing can be sent.
  final VoidCallback? onSend;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    OutlineInputBorder border(Color color, double width) {
      return OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.medium),
        borderSide: BorderSide(color: color, width: width),
      );
    }

    void send() => onSend?.call();
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: AppSpacing.md,
        end: AppSpacing.xxs,
        top: AppSpacing.xs,
        bottom: AppSpacing.xs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                const SingleActivator(LogicalKeyboardKey.enter, control: true):
                    send,
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
                  contentPadding: const EdgeInsets.all(AppSpacing.sm),
                  enabledBorder: border(colors.divider, AppSizes.hairline),
                  focusedBorder: border(colors.focus, AppSizes.focusRingWidth),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Send',
            onPressed: onSend,
            icon: const Icon(Icons.send),
          ),
        ],
      ),
    );
  }
}
