import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../../../app/theme/app_icons.dart';
import '../../../../app/theme/app_tokens.dart';
import '../../../../shared/feedback/app_haptics.dart';
import '../../../../shared/widgets/app_controls.dart';
import '../../../editor/widgets/ai_assistant_panel.dart';
import '../study_desk_models.dart';
import '../study_desk_widgets.dart';
import 'study_practice_models.dart';

/// Goes through a set's cards one at a time: tap to turn one over, swipe right
/// when it is known, and left to see it again later.
class StudyFlashcardPlayer extends StatefulWidget {
  const StudyFlashcardPlayer({
    super.key,
    required this.set,
    required this.labelOf,
    required this.onChanged,
    required this.onViewCitation,
    required this.onClose,
    this.showCloseButton = true,
    this.onBrowseSources,
    this.clock = DateTime.now,
  });

  final StudyPracticeSet set;
  final String Function(StudyCitation citation) labelOf;

  /// The set with what has just been learned in it.
  final ValueChanged<StudyPracticeSet> onChanged;
  final ValueChanged<StudyCitation> onViewCitation;
  final VoidCallback onClose;
  final bool showCloseButton;
  final VoidCallback? onBrowseSources;
  final DateTime Function() clock;

  /// How far a card has to be dragged to count, as a share of the view's width.
  static const double swipeShare = 0.28;

  /// How fast a shorter drag has to be let go to count, in points a second.
  static const double swipeVelocity = 700;

  @override
  State<StudyFlashcardPlayer> createState() => _StudyFlashcardPlayerState();
}

class _StudyFlashcardPlayerState extends State<StudyFlashcardPlayer>
    with TickerProviderStateMixin {
  /// 0 is the side first shown, 1 is turned half a circle.
  late final AnimationController _flip = AnimationController(vsync: this);

  /// How far the card is dragged, in points. Unbounded: it follows the finger.
  late final AnimationController _drag = AnimationController.unbounded(
    vsync: this,
  );

  late StudyPracticeSet _set = widget.set;
  late List<String> _queue = _startingQueue();
  int _position = 0;
  bool _showingBack = false;

  /// Whether each card starts with its answer up.
  bool _backFirst = false;
  bool _finishing = false;

  List<String> _startingQueue() {
    final List<PracticeFlashcard> left = _set.flashcards
        .where((PracticeFlashcard card) => !card.isMastered)
        .toList();
    return <String>[
      for (final PracticeFlashcard card
          in left.isEmpty ? _set.flashcards : left)
        card.id,
    ];
  }

  PracticeFlashcard? get _card {
    if (_position >= _queue.length) return null;
    final String id = _queue[_position];
    return _set.flashcards
        .where((PracticeFlashcard card) => card.id == id)
        .firstOrNull;
  }

  @override
  void dispose() {
    _flip.dispose();
    _drag.dispose();
    super.dispose();
  }

  void _turn() {
    AppHaptics.tap();
    setState(() => _showingBack = !_showingBack);
    unawaited(
      _flip.animateWith(
        SpringSimulation(
          AppMotion.spring(context, AppMotion.smooth),
          _flip.value,
          _showingBack ? 1 : 0,
          _flip.velocity,
        ),
      ),
    );
  }

  void _flipAll() {
    AppHaptics.toolSwitch();
    setState(() {
      _backFirst = !_backFirst;
      _showingBack = _backFirst;
    });
    _flip.value = _showingBack ? 1 : 0;
  }

  void _shuffle() {
    AppHaptics.toolSwitch();
    setState(() {
      final List<String> rest = _queue.sublist(_position)
        ..shuffle(math.Random());
      _queue = <String>[..._queue.sublist(0, _position), ...rest];
      _showingBack = _backFirst;
    });
    _flip.value = _showingBack ? 1 : 0;
  }

  void _restart() {
    setState(() {
      _queue = _startingQueue();
      _position = 0;
      _showingBack = _backFirst;
    });
    _flip.value = _showingBack ? 1 : 0;
    _drag.value = 0;
  }

  /// Records the answer and moves on. [mastered] marks the card known; otherwise
  /// it comes round again at the end.
  void _answer(bool mastered, {double velocity = 0}) {
    final PracticeFlashcard? card = _card;
    if (card == null || _finishing) return;
    _finishing = true;
    if (mastered) {
      AppHaptics.success();
    } else {
      AppHaptics.tap();
    }
    final List<PracticeFlashcard> flashcards = <PracticeFlashcard>[
      for (final PracticeFlashcard other in _set.flashcards)
        other.id == card.id
            ? other.copyWith(
                isMastered: mastered,
                reviewCount: other.reviewCount + 1,
              )
            : other,
    ];
    final StudyPracticeSet next = _set.copyWith(
      flashcards: flashcards,
      updatedAt: widget.clock(),
    );
    final double width = MediaQuery.sizeOf(context).width;
    setState(() => _set = next);
    widget.onChanged(next);
    unawaited(
      _drag
          .animateWith(
            SpringSimulation(
              AppMotion.spring(context, AppMotion.snappy),
              _drag.value,
              mastered ? width : -width,
              velocity,
            ),
          )
          .orCancel
          .then((void _) {
            if (mounted) _next(requeue: !mastered, id: card.id);
          }, onError: (Object _) {}),
    );
  }

  void _next({required bool requeue, required String id}) {
    setState(() {
      if (requeue) _queue = <String>[..._queue, id];
      _position++;
      _showingBack = _backFirst;
      _finishing = false;
    });
    _flip.value = _showingBack ? 1 : 0;
    _drag.value = 0;
  }

  void _onDragEnd(DragEndDetails details) {
    final double width = context.size?.width ?? 1;
    final double velocity = details.primaryVelocity ?? 0;
    final double dragged = _drag.value;
    if (dragged.abs() >= width * StudyFlashcardPlayer.swipeShare ||
        velocity.abs() >= StudyFlashcardPlayer.swipeVelocity) {
      final bool right = velocity.abs() >= StudyFlashcardPlayer.swipeVelocity
          ? velocity > 0
          : dragged > 0;
      _answer(right, velocity: velocity);
      return;
    }
    unawaited(
      _drag.animateWith(
        SpringSimulation(
          AppMotion.spring(context, AppMotion.snappy),
          dragged,
          0,
          velocity,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final PracticeFlashcard? card = _card;
    return Column(
      key: const ValueKey<String>('study-flashcard-player'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _TopBar(
          title: _set.title,
          position: _position,
          count: _queue.length,
          mastered: _set.masteredCount,
          total: _set.flashcards.length,
          onClose: widget.onClose,
          showCloseButton: widget.showCloseButton,
          onBrowseSources: widget.onBrowseSources,
          onShuffle: card == null ? null : _shuffle,
          onFlipAll: card == null ? null : _flipAll,
          backFirst: _backFirst,
        ),
        Expanded(
          child: card == null
              ? _Finished(
                  mastered: _set.masteredCount,
                  total: _set.flashcards.length,
                  onRestart: _restart,
                  onClose: widget.onClose,
                )
              : Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.xs,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: 620,
                        maxHeight: 520,
                      ),
                      child: GestureDetector(
                        key: const ValueKey<String>('flashcard-drag'),
                        behavior: HitTestBehavior.opaque,
                        onTap: _turn,
                        onHorizontalDragUpdate: (DragUpdateDetails details) =>
                            _drag.value += details.primaryDelta ?? 0,
                        onHorizontalDragEnd: _onDragEnd,
                        child: AnimatedBuilder(
                          animation: _drag,
                          builder: (BuildContext context, Widget? child) {
                            final double width = math.max(
                              1,
                              MediaQuery.sizeOf(context).width,
                            );
                            // Tilts a little as it goes, as a card in a hand.
                            return Transform.translate(
                              offset: Offset(_drag.value, 0),
                              child: Transform.rotate(
                                angle: _drag.value / width * 0.12,
                                child: child,
                              ),
                            );
                          },
                          child: _FlippingCard(
                            key: ValueKey<String>('${card.id}-$_position'),
                            flip: _flip,
                            front: _CardFace(
                              card: card,
                              back: false,
                              citationLabel: _labelOf(card),
                            ),
                            back: _CardFace(
                              card: card,
                              back: true,
                              citationLabel: _labelOf(card),
                              onViewCitation: switch (card.sourceCitation) {
                                final StudyCitation citation =>
                                  () => widget.onViewCitation(citation),
                                null => null,
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
        ),
        if (card != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.xs,
              AppSpacing.md,
              AppSpacing.md,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Flexible(
                  child: _AnswerPill(
                    key: const ValueKey<String>('flashcard-learning'),
                    label: 'Still Learning',
                    icon: AppIcons.close,
                    color: AppColors.of(context).textSecondary,
                    onPressed: () => _answer(false),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Flexible(
                  child: _AnswerPill(
                    key: const ValueKey<String>('flashcard-mastered'),
                    label: 'Mastered',
                    icon: AppIcons.check,
                    color: AppColors.of(context).accent,
                    onPressed: () => _answer(true),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String? _labelOf(PracticeFlashcard card) {
    final StudyCitation? citation = card.sourceCitation;
    return citation == null ? null : widget.labelOf(citation);
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.position,
    required this.count,
    required this.mastered,
    required this.total,
    required this.onClose,
    required this.showCloseButton,
    this.onBrowseSources,
    required this.onShuffle,
    required this.onFlipAll,
    required this.backFirst,
  });

  final String title;
  final int position;
  final int count;
  final int mastered;
  final int total;
  final VoidCallback onClose;
  final bool showCloseButton;
  final VoidCallback? onBrowseSources;
  final VoidCallback? onShuffle;
  final VoidCallback? onFlipAll;
  final bool backFirst;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final bool finished = position >= count;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xxs),
      child: Row(
        children: <Widget>[
          if (showCloseButton)
            IconButton(
              key: const ValueKey<String>('practice-player-close'),
              tooltip: 'Back to Practice Studio',
              onPressed: onClose,
              icon: const Icon(AppIcons.back),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall?.copyWith(color: colors.textPrimary),
                ),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    finished
                        ? '$mastered of $total mastered'
                        : 'Card ${position + 1} of $count · '
                              '$mastered of $total mastered',
                    key: const ValueKey<String>('flashcard-progress'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (onBrowseSources != null)
            IconButton(
              key: const ValueKey('flashcard-browse-sources'),
              tooltip: 'Browse sources',
              onPressed: onBrowseSources,
              icon: const Icon(AppIcons.folder),
            ),
          IconButton(
            key: const ValueKey<String>('flashcard-shuffle'),
            tooltip: 'Shuffle',
            onPressed: onShuffle,
            icon: Icon(AppIcons.sort, color: colors.textPrimary),
          ),
          IconButton(
            key: const ValueKey<String>('flashcard-flip-all'),
            tooltip: backFirst ? 'Show questions first' : 'Show answers first',
            onPressed: onFlipAll,
            isSelected: backFirst,
            icon: Icon(AppIcons.restore, color: colors.textPrimary),
          ),
        ],
      ),
    );
  }
}

/// A card turned by [flip] in perspective, or with reduced motion cross-faded
/// where it is.
class _FlippingCard extends StatelessWidget {
  const _FlippingCard({
    super.key,
    required this.flip,
    required this.front,
    required this.back,
  });

  final Animation<double> flip;
  final Widget front;
  final Widget back;

  @override
  Widget build(BuildContext context) {
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    return AnimatedBuilder(
      animation: flip,
      builder: (BuildContext context, Widget? _) {
        final double turned = flip.value.clamp(0.0, 1.0);
        if (reduced) {
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Opacity(
                opacity: 1 - turned,
                child: IgnorePointer(ignoring: turned > 0.5, child: front),
              ),
              Opacity(
                opacity: turned,
                child: IgnorePointer(ignoring: turned <= 0.5, child: back),
              ),
            ],
          );
        }
        final double angle = flip.value * math.pi;
        final bool backUp = turned > 0.5;
        return Transform(
          key: const ValueKey<String>('flashcard-transform'),
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.001)
            ..rotateY(angle),
          child: backUp
              // Turned once more, or the far side would read as a mirror.
              ? Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.rotationY(math.pi),
                  child: back,
                )
              : front,
        );
      },
    );
  }
}

class _CardFace extends StatelessWidget {
  const _CardFace({
    required this.card,
    required this.back,
    this.citationLabel,
    this.onViewCitation,
  });

  final PracticeFlashcard card;
  final bool back;
  final String? citationLabel;
  final VoidCallback? onViewCitation;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final Uint8List? crop = card.diagramCrop;
    return StudySurface(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xxs,
              children: <Widget>[
                if (card.topic.isNotEmpty) ValuePill(card.topic),
                if (citationLabel case final String label)
                  ValuePill(label, muted: true),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: Column(
                      mainAxisAlignment: back
                          ? MainAxisAlignment.start
                          : MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: back
                          ? <Widget>[
                              Semantics(
                                header: true,
                                child: Text(
                                  'Answer',
                                  style: text.labelMedium?.copyWith(
                                    color: colors.textSecondary,
                                  ),
                                ),
                              ),
                              const SizedBox(height: AppSpacing.xxs),
                              DefaultTextStyle.merge(
                                style: TextStyle(color: colors.textPrimary),
                                child: AiAnswerMarkdown(card.backAnswer),
                              ),
                              if (card.explanation.isNotEmpty) ...<Widget>[
                                const SizedBox(height: AppSpacing.sm),
                                DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: colors.surfaceMuted,
                                    borderRadius: AppBorderRadius.medium,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(
                                      AppSpacing.sm,
                                    ),
                                    child: AiAnswerMarkdown(card.explanation),
                                  ),
                                ),
                              ],
                            ]
                          : <Widget>[
                              Theme(
                                data: Theme.of(context).copyWith(
                                  textTheme: Theme.of(context).textTheme
                                      .copyWith(
                                        bodyMedium: text.titleLarge?.copyWith(
                                          height: 1.5,
                                        ),
                                      ),
                                ),
                                child: AiAnswerMarkdown(card.frontPrompt),
                              ),
                              if (crop != null) ...<Widget>[
                                const SizedBox(height: AppSpacing.sm),
                                ClipRRect(
                                  borderRadius: AppBorderRadius.medium,
                                  child: ColoredBox(
                                    color: colors.writingSurface,
                                    child: Image.memory(
                                      crop,
                                      fit: BoxFit.contain,
                                      height: 180,
                                      semanticLabel: 'Drawing from the note',
                                    ),
                                  ),
                                ),
                              ],
                            ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            if (back)
              if (onViewCitation != null)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: const ValueKey<String>('flashcard-view-in-note'),
                    onPressed: onViewCitation,
                    icon: const Icon(AppIcons.note, size: 18),
                    label: const Text('View in Note'),
                  ),
                )
              else
                const SizedBox.shrink()
            else
              Text(
                'Tap to flip',
                textAlign: TextAlign.center,
                style: text.bodySmall?.copyWith(color: colors.textSecondary),
              ),
          ],
        ),
      ),
    );
  }
}

class _AnswerPill extends StatelessWidget {
  const _AnswerPill({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    if (icon == AppIcons.check) {
      return FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, AppSizes.minTouchTarget),
        ),
      );
    }
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18, color: color),
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: colors.textPrimary),
      ),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, AppSizes.minTouchTarget),
        shape: const StadiumBorder(),
        side: BorderSide(color: color, width: AppSizes.hairline),
      ),
    );
  }
}

class _Finished extends StatelessWidget {
  const _Finished({
    required this.mastered,
    required this.total,
    required this.onRestart,
    required this.onClose,
  });

  final int mastered;
  final int total;
  final VoidCallback onRestart;
  final VoidCallback onClose;

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
            SizedBox.square(
              dimension: 48,
              child: StrokeDrawCheck(selected: true, color: colors.success),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              mastered == total ? 'Every card mastered' : 'Deck reviewed',
              textAlign: TextAlign.center,
              style: text.titleMedium?.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: AppSpacing.xxs),
            Text(
              '$mastered of $total mastered',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.xs,
              alignment: WrapAlignment.center,
              children: <Widget>[
                TextButton(onPressed: onClose, child: const Text('Done')),
                FilledButton(
                  key: const ValueKey<String>('flashcard-restart'),
                  onPressed: onRestart,
                  child: Text(mastered == total ? 'Go Again' : 'Keep Learning'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
