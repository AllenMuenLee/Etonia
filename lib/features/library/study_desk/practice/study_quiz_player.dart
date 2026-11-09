import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../app/theme/app_icons.dart';
import '../../../../app/theme/app_tokens.dart';
import '../../../../shared/feedback/app_haptics.dart';
import '../../../../shared/widgets/app_controls.dart';
import '../../../../shared/widgets/pressable.dart';
import '../../../editor/widgets/ai_assistant_panel.dart';
import '../study_desk_models.dart';
import '../study_motion.dart';
import 'study_practice_models.dart';

/// How a quiz tells what was right.
enum StudyQuizMode {
  /// At once, after each question.
  instant('Instant Feedback'),

  /// Only at the end, after all are answered.
  exam('Exam Mode');

  const StudyQuizMode(this.label);

  final String label;
}

/// Takes a set's multiple choice questions, and records the score.
class StudyQuizPlayer extends StatefulWidget {
  const StudyQuizPlayer({
    super.key,
    required this.set,
    required this.labelOf,
    required this.onChanged,
    required this.onViewCitation,
    required this.onClose,
    this.clock = DateTime.now,
  });

  final StudyPracticeSet set;
  final String Function(StudyCitation citation) labelOf;

  /// The set with answers and the score so far in it.
  final ValueChanged<StudyPracticeSet> onChanged;
  final ValueChanged<StudyCitation> onViewCitation;
  final VoidCallback onClose;
  final DateTime Function() clock;

  @override
  State<StudyQuizPlayer> createState() => _StudyQuizPlayerState();
}

enum _Stage { setup, running, finished }

class _StudyQuizPlayerState extends State<StudyQuizPlayer> {
  late StudyPracticeSet _set = widget.set;
  _Stage _stage = _Stage.setup;
  StudyQuizMode _mode = StudyQuizMode.instant;
  bool _showTimer = false;
  int _index = 0;
  final Set<String> _flagged = <String>{};
  bool _reviewing = false;

  /// Counted by the tick rather than read from a clock: only time on the quiz.
  int _seconds = 0;
  Timer? _ticker;

  List<PracticeMultipleChoice> get _questions => _set.multipleChoiceQuestions;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _start() {
    final StudyPracticeSet fresh = _set.copyWith(
      multipleChoiceQuestions: <PracticeMultipleChoice>[
        for (final PracticeMultipleChoice question in _questions)
          question.cleared(),
      ],
      updatedAt: widget.clock(),
    );
    setState(() {
      _set = fresh;
      _stage = _Stage.running;
      _index = 0;
      _seconds = 0;
      _flagged.clear();
      _reviewing = false;
    });
    widget.onChanged(fresh);
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (Timer _) {
      // The display only changes if it is shown.
      if (_showTimer && mounted) {
        setState(() => _seconds++);
      } else {
        _seconds++;
      }
    });
  }

  void _select(PracticeMultipleChoice question, String optionId) {
    if (_mode == StudyQuizMode.instant && question.isAnswered) return;
    final PracticeMultipleChoice answered = question.answered(
      optionId,
      graded: _mode == StudyQuizMode.instant,
    );
    final StudyPracticeSet next = _set.copyWith(
      multipleChoiceQuestions: <PracticeMultipleChoice>[
        for (final PracticeMultipleChoice other in _questions)
          other.id == question.id ? answered : other,
      ],
      updatedAt: widget.clock(),
    );
    if (_mode == StudyQuizMode.instant) {
      if (answered.isCorrect) {
        AppHaptics.success();
      } else {
        AppHaptics.error();
      }
    } else {
      AppHaptics.tap();
    }
    setState(() => _set = next);
    widget.onChanged(next);
  }

  void _finish() {
    _ticker?.cancel();
    final int correct = _questions
        .where((PracticeMultipleChoice question) => question.isCorrect)
        .length;
    final double score = _questions.isEmpty ? 0 : correct / _questions.length;
    final StudyPracticeSet next = _set
        .copyWith(
          multipleChoiceQuestions: [for (final q in _questions) q.graded()],
        )
        .withQuizScore(score, widget.clock());
    AppHaptics.success();
    setState(() {
      _set = next;
      _stage = _Stage.finished;
    });
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: const ValueKey<String>('study-quiz-player'),
      child: switch (_stage) {
        _Stage.setup => _setup(context),
        _Stage.running => _running(context),
        _Stage.finished => _Summary(
          set: _set,
          seconds: _seconds,
          labelOf: widget.labelOf,
          onViewCitation: widget.onViewCitation,
          onAgain: _start,
          onClose: widget.onClose,
        ),
      },
    );
  }

  Widget _setup(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: IconButton(
            key: const ValueKey<String>('practice-player-close'),
            tooltip: 'Back to Practice Studio',
            onPressed: widget.onClose,
            icon: const AppIcon(AppIcons.back),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      _set.title,
                      textAlign: TextAlign.center,
                      style: text.titleLarge?.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xxs),
                    Text(
                      _questions.length == 1
                          ? '1 question'
                          : '${_questions.length} questions',
                      textAlign: TextAlign.center,
                      style: text.bodyMedium?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    SegmentedChoice<StudyQuizMode>(
                      options: StudyQuizMode.values,
                      selected: _mode,
                      labelOf: (StudyQuizMode mode) => mode.label,
                      keyOf: (StudyQuizMode mode) =>
                          ValueKey<String>('quiz-mode-${mode.name}'),
                      onSelected: (StudyQuizMode mode) =>
                          setState(() => _mode = mode),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      _mode == StudyQuizMode.instant
                          ? 'See the answer and why after each question.'
                          : 'Answer all, flag any to come back to, then submit '
                                'for your score.',
                      textAlign: TextAlign.center,
                      style: text.bodySmall?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    ToggleSetting(
                      key: const ValueKey<String>('quiz-timer-toggle'),
                      label: 'Show timer',
                      value: _showTimer,
                      onChanged: (bool value) =>
                          setState(() => _showTimer = value),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    FilledButton(
                      key: const ValueKey<String>('quiz-start'),
                      onPressed: _questions.isEmpty ? null : _start,
                      child: const Text('Start Quiz'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _running(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final PracticeMultipleChoice question = _questions[_index];
    final bool instant = _mode == StudyQuizMode.instant;
    final bool revealed = instant && question.isAnswered;
    final bool last = _index == _questions.length - 1;
    final int answered = _questions
        .where((PracticeMultipleChoice q) => q.isAnswered)
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(AppSpacing.xxs),
          child: Row(
            children: <Widget>[
              IconButton(
                key: const ValueKey<String>('practice-player-close'),
                tooltip: 'Back to Practice Studio',
                onPressed: widget.onClose,
                icon: const AppIcon(AppIcons.back),
              ),
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    'Question ${_index + 1} of ${_questions.length}',
                    key: const ValueKey<String>('quiz-progress'),
                    style: text.titleSmall?.copyWith(color: colors.textPrimary),
                  ),
                ),
              ),
              if (_showTimer)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xs,
                  ),
                  child: ValuePill(_clock(_seconds), muted: true),
                ),
              if (!instant)
                IconButton(
                  key: const ValueKey<String>('quiz-flag'),
                  tooltip: _flagged.contains(question.id)
                      ? 'Remove flag'
                      : 'Flag for review',
                  isSelected: _flagged.contains(question.id),
                  onPressed: () => setState(() {
                    if (!_flagged.remove(question.id)) {
                      _flagged.add(question.id);
                    }
                  }),
                  icon: AppIcon(
                    AppIcons.warning,
                    color: _flagged.contains(question.id)
                        ? colors.danger
                        : colors.textSecondary,
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: ClipRRect(
            borderRadius: AppBorderRadius.circular(AppRadii.small),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: answered / _questions.length),
              duration: AppMotion.springDuration(context, AppMotion.smooth),
              curve: AppMotion.zoomInCurve,
              builder: (BuildContext context, double value, Widget? _) =>
                  LinearProgressIndicator(
                    key: const ValueKey<String>('quiz-progress-bar'),
                    value: value,
                    minHeight: 6,
                    color: colors.accent,
                    backgroundColor: colors.surfaceMuted,
                    semanticsLabel: 'Questions answered',
                  ),
            ),
          ),
        ),
        Expanded(
          child: _reviewing
              ? StudyAppear(
                  key: const ValueKey<String>('quiz-review-appear'),
                  child: _Review(
                    questions: _questions,
                    flagged: _flagged,
                    onOpen: (int index) => setState(() {
                      _index = index;
                      _reviewing = false;
                    }),
                  ),
                )
              : StudyAppear(
                  key: ValueKey<String>('quiz-question-appear-$_index'),
                  rise: 14,
                  child: SingleChildScrollView(
                    key: ValueKey<String>('quiz-question-$_index'),
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 680),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            AiAnswerMarkdown(question.question),
                            const SizedBox(height: AppSpacing.md),
                            for (final PracticeChoiceOption option
                                in question.options)
                              Padding(
                                padding: const EdgeInsets.only(
                                  bottom: AppSpacing.xs,
                                ),
                                child: _OptionPill(
                                  key: ValueKey<String>(
                                    'quiz-option-${option.id}',
                                  ),
                                  option: option,
                                  state: _stateOf(question, option, revealed),
                                  onPressed: revealed
                                      ? null
                                      : () => _select(question, option.id),
                                ),
                              ),
                            AnimatedSize(
                              duration: AppMotion.springDuration(
                                context,
                                AppMotion.smooth,
                              ),
                              curve: AppMotion.zoomInCurve,
                              alignment: Alignment.topCenter,
                              child: revealed
                                  ? _Explanation(
                                      question: question,
                                      labelOf: widget.labelOf,
                                      onViewCitation: widget.onViewCitation,
                                    )
                                  : const SizedBox(width: double.infinity),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.xs,
            AppSpacing.md,
            AppSpacing.md,
          ),
          child: _reviewing
              ? Wrap(
                  alignment: WrapAlignment.end,
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: <Widget>[
                    TextButton(
                      onPressed: () => setState(() => _reviewing = false),
                      child: const Text('Back to Questions'),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    FilledButton(
                      key: const ValueKey<String>('quiz-submit'),
                      onPressed: _finish,
                      child: const Text('Submit Exam'),
                    ),
                  ],
                )
              : Wrap(
                  alignment: WrapAlignment.end,
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: <Widget>[
                    if (_index > 0 && !instant)
                      TextButton(
                        key: const ValueKey<String>('quiz-previous'),
                        onPressed: () => setState(() => _index--),
                        child: const Text('Previous'),
                      ),
                    if (!instant)
                      TextButton(
                        key: const ValueKey<String>('quiz-review'),
                        onPressed: () => setState(() => _reviewing = true),
                        child: const Text('Review'),
                      ),
                    const SizedBox(width: AppSpacing.xs),
                    if (last)
                      FilledButton(
                        key: const ValueKey<String>('quiz-finish'),
                        onPressed: instant
                            ? (question.isAnswered ? _finish : null)
                            : () => setState(() => _reviewing = true),
                        child: Text(instant ? 'See Score' : 'Review & Submit'),
                      )
                    else
                      FilledButton(
                        key: const ValueKey<String>('quiz-next'),
                        onPressed: instant && !question.isAnswered
                            ? null
                            : () => setState(() => _index++),
                        child: const Text('Next'),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  _OptionState _stateOf(
    PracticeMultipleChoice question,
    PracticeChoiceOption option,
    bool revealed,
  ) {
    final bool selected = question.userSelectedOptionId == option.id;
    if (!revealed) return selected ? _OptionState.selected : _OptionState.idle;
    if (option.id == question.correctOptionId) return _OptionState.correct;
    return selected ? _OptionState.wrong : _OptionState.idle;
  }
}

String _clock(int seconds) {
  final int minutes = seconds ~/ 60;
  return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
}

enum _OptionState { idle, selected, correct, wrong }

class _OptionPill extends StatelessWidget {
  const _OptionPill({
    super.key,
    required this.option,
    required this.state,
    required this.onPressed,
  });

  final PracticeChoiceOption option;
  final _OptionState state;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final (Color fill, Color border, Color ink) = switch (state) {
      _OptionState.idle => (colors.surface, colors.divider, colors.textPrimary),
      _OptionState.selected => (colors.accent, colors.accent, colors.onAccent),
      // Tinted, not filled, so the words stay as dark as all the others; the
      // border and the mark carry it as well as the colour does.
      _OptionState.correct => (
        Color.alphaBlend(
          colors.success.withValues(alpha: 0.16),
          colors.surface,
        ),
        colors.success,
        colors.textPrimary,
      ),
      _OptionState.wrong => (
        Color.alphaBlend(colors.danger.withValues(alpha: 0.16), colors.surface),
        colors.danger,
        colors.textPrimary,
      ),
    };
    final String status = switch (state) {
      _OptionState.correct => ', correct answer',
      _OptionState.wrong => ', your answer, incorrect',
      _OptionState.selected => ', selected',
      _OptionState.idle => '',
    };
    const BorderRadius radius = AppBorderRadius.large;
    return Semantics(
      button: true,
      selected: state == _OptionState.selected,
      label: 'Option ${option.id}: ${option.text}$status',
      excludeSemantics: true,
      // Once answered it takes no press, and is still there to be read: nothing
      // that would dim it, as a disabled control is dimmed.
      child: Pressable(
        borderRadius: radius,
        child: Material(
          color: fill,
          shape: RoundedSuperellipseBorder(
            borderRadius: radius,
            side: BorderSide(color: border, width: AppSizes.hairline),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: AppSizes.minTouchTarget,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
                child: Row(
                  children: <Widget>[
                    Text(
                      option.id,
                      style: text.labelLarge?.copyWith(
                        color: ink,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: IconTheme.merge(
                        data: IconThemeData(color: ink),
                        child: DefaultTextStyle.merge(
                          style: TextStyle(color: ink),
                          child: _OptionText(option.text, color: ink),
                        ),
                      ),
                    ),
                    if (state == _OptionState.correct) ...<Widget>[
                      const SizedBox(width: AppSpacing.xs),
                      _Mark(icon: AppIcons.check, color: colors.success),
                    ] else if (state == _OptionState.wrong) ...<Widget>[
                      const SizedBox(width: AppSpacing.xs),
                      _Mark(icon: AppIcons.close, color: colors.danger),
                    ],
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

/// A check or a cross, popping in as the answer is shown.
class _Mark extends StatelessWidget {
  const _Mark({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween<double>(begin: 0, end: 1),
    duration: AppMotion.resolve(context, AppMotion.checkDraw),
    curve: AppMotion.popCurve,
    builder: (BuildContext context, double value, Widget? child) =>
        Transform.scale(scale: value, child: child),
    child: AppIcon(icon, size: 18, color: color),
  );
}

/// An option's words: plain where they are plain, so its colour holds on a
/// selected pill, and through the Markdown reader only where they need it.
class _OptionText extends StatelessWidget {
  const _OptionText(this.text, {required this.color});

  final String text;
  final Color color;

  static final RegExp _markup = RegExp(r'[$*_`\\]');

  @override
  Widget build(BuildContext context) {
    if (_markup.hasMatch(text)) {
      return Theme(
        data: Theme.of(context).copyWith(
          textTheme: Theme.of(
            context,
          ).textTheme.apply(bodyColor: color, displayColor: color),
        ),
        child: AiAnswerMarkdown(text),
      );
    }
    return Text(
      text,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: color),
    );
  }
}

class _Explanation extends StatelessWidget {
  const _Explanation({
    required this.question,
    required this.labelOf,
    required this.onViewCitation,
  });

  final PracticeMultipleChoice question;
  final String Function(StudyCitation citation) labelOf;
  final ValueChanged<StudyCitation> onViewCitation;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final StudyCitation? citation = question.sourceCitation;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: DecoratedBox(
        key: const ValueKey<String>('quiz-explanation'),
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: AppBorderRadius.large,
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Semantics(
                liveRegion: true,
                child: Text(
                  question.isCorrect
                      ? 'Correct'
                      : 'The answer is ${question.correctOptionId}',
                  style: text.titleSmall?.copyWith(color: colors.textPrimary),
                ),
              ),
              if (question.explanation.isNotEmpty) ...<Widget>[
                const SizedBox(height: AppSpacing.xxs),
                AiAnswerMarkdown(question.explanation),
              ],
              if (citation != null)
                TextButton.icon(
                  key: const ValueKey<String>('quiz-view-in-note'),
                  onPressed: () => onViewCitation(citation),
                  icon: const AppIcon(AppIcons.note, size: 18),
                  label: Text(
                    labelOf(citation),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Every question at a glance, before an exam is handed in.
class _Review extends StatelessWidget {
  const _Review({
    required this.questions,
    required this.flagged,
    required this.onOpen,
  });

  final List<PracticeMultipleChoice> questions;
  final Set<String> flagged;
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return ListView.builder(
      key: const ValueKey<String>('quiz-review-list'),
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount: questions.length,
      itemBuilder: (BuildContext context, int index) {
        final PracticeMultipleChoice question = questions[index];
        return ListTile(
          onTap: () => onOpen(index),
          title: Text(
            'Question ${index + 1}',
            style: TextStyle(color: colors.textPrimary),
          ),
          subtitle: Text(
            question.isAnswered
                ? 'Answered ${question.userSelectedOptionId}'
                : 'Not answered',
            style: TextStyle(color: colors.textSecondary),
          ),
          trailing: flagged.contains(question.id)
              ? AppIcon(
                  AppIcons.warning,
                  color: colors.danger,
                  semanticLabel: 'Flagged',
                )
              : null,
        );
      },
    );
  }
}

/// How a finished quiz went, question by question.
class _Summary extends StatelessWidget {
  const _Summary({
    required this.set,
    required this.seconds,
    required this.labelOf,
    required this.onViewCitation,
    required this.onAgain,
    required this.onClose,
  });

  final StudyPracticeSet set;
  final int seconds;
  final String Function(StudyCitation citation) labelOf;
  final ValueChanged<StudyCitation> onViewCitation;
  final VoidCallback onAgain;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final List<PracticeMultipleChoice> questions = set.multipleChoiceQuestions;
    final int correct = questions
        .where((PracticeMultipleChoice question) => question.isCorrect)
        .length;
    final int percent = questions.isEmpty
        ? 0
        : (correct / questions.length * 100).round();
    return ListView(
      key: const ValueKey<String>('quiz-summary'),
      padding: const EdgeInsets.all(AppSpacing.md),
      children: <Widget>[
        const SizedBox(height: AppSpacing.md),
        Center(
          child: SizedBox.square(
            dimension: 48,
            child: StrokeDrawCheck(selected: true, color: colors.success),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Semantics(
          liveRegion: true,
          child: Text(
            '$percent%',
            key: const ValueKey<String>('quiz-score'),
            textAlign: TextAlign.center,
            style: text.displaySmall?.copyWith(color: colors.textPrimary),
          ),
        ),
        Text(
          '$correct of ${questions.length} correct · ${_clock(seconds)}',
          textAlign: TextAlign.center,
          style: text.bodyMedium?.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: AppSpacing.xs,
          children: <Widget>[
            TextButton(
              key: const ValueKey<String>('practice-player-close'),
              onPressed: onClose,
              child: const Text('Done'),
            ),
            FilledButton(
              key: const ValueKey<String>('quiz-again'),
              onPressed: onAgain,
              child: const Text('Try Again'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        for (int i = 0; i < questions.length; i++)
          ExpansionTile(
            key: ValueKey<String>('quiz-result-$i'),
            shape: const Border(),
            collapsedShape: const Border(),
            leading: AppIcon(
              questions[i].isCorrect ? AppIcons.check : AppIcons.close,
              color: questions[i].isCorrect ? colors.success : colors.danger,
              semanticLabel: questions[i].isCorrect ? 'Correct' : 'Incorrect',
            ),
            title: AiAnswerMarkdown(questions[i].question),
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: _Explanation(
                  question: questions[i],
                  labelOf: labelOf,
                  onViewCitation: onViewCitation,
                ),
              ),
            ],
          ),
      ],
    );
  }
}
