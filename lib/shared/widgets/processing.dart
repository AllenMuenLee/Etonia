import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import '../motion/motion_memory.dart';

// These resolve their colors without requiring the app theme, since they
// stand in for content that may be shown on its own.
//
// Content loading uses a fixed, calm shimmer and content itself enters with
// the shared fade. Long branded work uses EtoniaBarsLoader; tiny inline waits
// remain platform activity indicators.

/// How long each kind of loading has taken lately, so the transition that
/// covers the next one can last about as long.
class LoadTimings {
  LoadTimings._();

  static final LoadTimings instance = LoadTimings._();

  /// The kinds of loading the app times.
  static const String startup = 'startup';
  static const String library = 'library';
  static const String noteOpen = 'note.open';
  static const String thumbnail = 'thumbnail';
  static const String pdfPage = 'pdf.page';
  static const String image = 'image';
  static const String aiReply = 'ai.reply';

  /// What is expected of a kind of loading not yet timed.
  static const Duration unknown = Duration(milliseconds: 300);

  /// How much the latest time counts against those before it: recent
  /// loading counts most, but one slow read does not swing the next
  /// transition.
  static const double _weight = 0.3;

  static final Stopwatch _watch = Stopwatch()..start();

  /// A monotonic clock. Tests set it to the test binding's fake clock, so
  /// timings, and the transitions planned from them, do not depend on how
  /// fast the machine running them is.
  static Duration Function() clock = () => _watch.elapsed;

  final Map<String, Duration> _typical = <String, Duration>{};

  /// How long [kind] of loading usually takes, or [fallback] before it has
  /// been timed.
  Duration expected(String kind, {Duration fallback = unknown}) =>
      _typical[kind] ?? fallback;

  /// [kind] of loading just took [took].
  void record(String kind, Duration took) {
    if (took.isNegative) return;
    final Duration? typical = _typical[kind];
    _typical[kind] = typical == null
        ? took
        : typical + (took - typical) * _weight;
  }

  @visibleForTesting
  void reset() => _typical.clear();
}

/// How something that has loaded comes into view.
enum RevealEffect {
  /// Fades in where it is: for what must stay in register with what is
  /// around it, such as a PDF page under its ink.
  fade,

  /// Fades in while coming forward from just smaller.
  zoom,

  /// Fades in while rising a little into place.
  slideUp,

  /// Fades in while sliding a little in from the leading edge.
  slideIn,
}

/// Shows [child] once there is one, arriving with the shared content fade.
///
/// While [child] is null, [placeholder], if any, drifts in with the same
/// effect over about as long as this [timing] of loading usually takes, so
/// the wait reads as the transition already under way; it fades out as
/// [child] arrives. A [child] there from the start is shown at once:
/// nothing was waited for.
class LoadingReveal extends StatefulWidget {
  const LoadingReveal({
    super.key,
    required this.child,
    this.placeholder,
    this.effect = RevealEffect.fade,
    this.timing,
    this.semanticsLabel,
    this.memoryKey,
  });

  /// What was loaded, or null while it is still on its way.
  final Widget? child;

  /// Stands in for [child] until it arrives.
  final Widget? placeholder;

  final RevealEffect effect;

  /// The [LoadTimings] kind this loading is: the transition is planned
  /// from it, and it learns how long this loading took.
  final String? timing;

  /// Read out while [child] is still on its way.
  final String? semanticsLabel;

  /// Names what [child] shows, for [MotionMemory]: the first time it is
  /// revealed it arrives slowly and smoothly, and when it has been shown
  /// before it arrives quickly. Without one the reveal keeps its token.
  final Object? memoryKey;

  @override
  State<LoadingReveal> createState() => _LoadingRevealState();
}

class _LoadingRevealState extends State<LoadingReveal>
    with TickerProviderStateMixin {
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    value: widget.child == null ? 0 : 1,
  )..addStatusListener(_revealed);
  late final AnimationController _arrive = AnimationController(vsync: this);
  late final CurvedAnimation _revealCurve = CurvedAnimation(
    parent: _reveal,
    curve: AppMotion.fadeInCurve,
  );
  late final Animation<double> _leaving = ReverseAnimation(_revealCurve);

  /// Decelerates throughout, so a wait longer than planned settles to
  /// stillness instead of stopping short.
  late final CurvedAnimation _arriveCurve = CurvedAnimation(
    parent: _arrive,
    curve: AppMotion.fadeInCurve,
  );

  /// When the wait for the child began, while it goes on.
  Duration? _since;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (widget.child == null) {
      _wait();
    } else {
      // There from the start: shown at once, and remembered as shown.
      final Object? key = widget.memoryKey;
      if (key != null) MotionMemory.instance.remember(key);
    }
  }

  @override
  void didUpdateWidget(LoadingReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool had = oldWidget.child != null;
    final bool has = widget.child != null;
    if (!had && has) {
      _arrived();
    } else if (had && !has) {
      _wait();
    }
  }

  @override
  void dispose() {
    _revealCurve.dispose();
    _arriveCurve.dispose();
    _reveal.dispose();
    _arrive.dispose();
    super.dispose();
  }

  void _wait() {
    _since = LoadTimings.clock();
    _reveal.value = 0;
    _arrive.value = 0;
    if (widget.placeholder == null) return;
    final Object? key = widget.memoryKey;
    _run(
      _arrive,
      AppMotion.paced(
        AppMotion.fadeIn,
        key == null ? MotionPace.standard : MotionMemory.instance.peek(key),
      ),
    );
  }

  void _arrived() {
    final Duration? since = _since;
    _since = null;
    final Duration took = since == null
        ? Duration.zero
        : LoadTimings.clock() - since;
    final String? timing = widget.timing;
    if (timing != null && since != null) {
      LoadTimings.instance.record(timing, took);
    }
    final Object? key = widget.memoryKey;
    _run(
      _reveal,
      AppMotion.paced(
        AppMotion.fadeIn,
        key == null ? MotionPace.standard : MotionMemory.instance.recall(key),
      ),
    );
  }

  void _run(AnimationController controller, Duration duration) {
    final Duration resolved = AppMotion.resolve(context, duration);
    if (resolved == Duration.zero) {
      controller.value = 1;
    } else {
      controller.animateTo(1, duration: resolved);
    }
  }

  /// Once the child is fully in, its placeholder goes.
  void _revealed(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final Widget? child = widget.child;
    final Widget? placeholder = widget.placeholder;
    final Widget? arriving = child == null
        ? null
        : _Arrival(
            key: const ValueKey<String>('loaded'),
            animation: _revealCurve,
            effect: widget.effect,
            child: child,
          );
    if (placeholder == null) {
      return arriving ??
          Semantics(
            label: widget.semanticsLabel,
            child: const SizedBox.shrink(),
          );
    }
    // Keyed, so the child keeps its state as the placeholder goes.
    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        if (child == null || !_reveal.isCompleted)
          _Arrival(
            key: const ValueKey<String>('placeholder'),
            animation: _arriveCurve,
            effect: widget.effect,
            child: IgnorePointer(
              child: Semantics(
                label: child == null ? widget.semanticsLabel : null,
                child: ExcludeSemantics(
                  excluding: child != null,
                  child: FadeTransition(opacity: _leaving, child: placeholder),
                ),
              ),
            ),
          ),
        ?arriving,
      ],
    );
  }
}

/// [child], as far along [animation] as it has come into view by [effect].
class _Arrival extends StatelessWidget {
  const _Arrival({
    super.key,
    required this.animation,
    required this.effect,
    required this.child,
  });

  final Animation<double> animation;
  final RevealEffect effect;
  final Widget child;

  /// How far a sliding surface travels, in logical pixels: enough to read
  /// as arriving, too little to read as moving.
  static const double _rise = 14;
  static const double _slide = 22;
  static final Animatable<double> _zoom = Tween<double>(begin: 0.96, end: 1);

  @override
  Widget build(BuildContext context) {
    final Widget faded = FadeTransition(opacity: animation, child: child);
    final double toward = Directionality.of(context) == TextDirection.rtl
        ? -1
        : 1;
    return switch (effect) {
      RevealEffect.fade => faded,
      RevealEffect.zoom => ScaleTransition(
        scale: animation.drive(_zoom),
        child: faded,
      ),
      RevealEffect.slideUp => AnimatedBuilder(
        animation: animation,
        builder: (BuildContext context, Widget? child) => Transform.translate(
          offset: Offset(0, (1 - animation.value) * _rise),
          child: child,
        ),
        child: faded,
      ),
      RevealEffect.slideIn => AnimatedBuilder(
        animation: animation,
        builder: (BuildContext context, Widget? child) => Transform.translate(
          offset: Offset(-(1 - animation.value) * _slide * toward, 0),
          child: child,
        ),
        child: faded,
      ),
    };
  }
}

/// Swaps what it shows with a quick fade and a short rise. Only the newest
/// outgoing child is kept, so values that change quickly, such as a count
/// of pages, never pile up on each other.
class GentleSwitcher extends StatelessWidget {
  const GentleSwitcher({
    super.key,
    required this.value,
    required this.child,
    this.alignment = AlignmentDirectional.centerStart,
  });

  /// What [child] shows: a new value switches.
  final Object? value;
  final Widget child;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: AppMotion.resolve(context, AppMotion.snappy.duration),
      switchInCurve: AppMotion.fadeInCurve,
      switchOutCurve: AppMotion.fadeOutCurve,
      layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
        alignment: alignment,
        children: <Widget>[if (previous.isNotEmpty) previous.last, ?current],
      ),
      transitionBuilder: (Widget child, Animation<double> animation) =>
          _Arrival(
            animation: animation,
            effect: RevealEffect.slideUp,
            child: child,
          ),
      child: KeyedSubtree(key: ValueKey<Object?>(value), child: child),
    );
  }
}

/// Runs a repeating 0–1 cycle, or holds still under reduced motion.
mixin _LoopingAnimation<T extends StatefulWidget> on State<T>, TickerProvider {
  late final AnimationController loop = AnimationController(
    vsync: this,
    duration: loopDuration,
  );

  Duration get loopDuration;

  /// Whether the loop should run at all.
  bool get looping => true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    syncLoop();
  }

  @override
  void didUpdateWidget(T oldWidget) {
    super.didUpdateWidget(oldWidget);
    syncLoop();
  }

  void syncLoop() {
    final bool run =
        looping &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context);
    if (run && !loop.isAnimating) {
      loop.repeat();
    } else if (!run && loop.isAnimating) {
      loop
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    loop.dispose();
    super.dispose();
  }
}

/// From 1 down to [low] and back once per cycle, eased at both ends.
class _Breath extends Animatable<double> {
  const _Breath(this.low);

  final double low;

  @override
  double transform(double t) =>
      low + (1 - low) * (0.5 + 0.5 * math.cos(t * 2 * math.pi));
}

/// While [active], breathes [child]'s opacity softly, for a status that
/// stays up while work runs on, such as waiting on the store.
class Breathe extends StatefulWidget {
  const Breathe({super.key, this.active = true, required this.child});

  final bool active;
  final Widget child;

  @override
  State<Breathe> createState() => _BreatheState();
}

class _BreatheState extends State<Breathe>
    with SingleTickerProviderStateMixin, _LoopingAnimation<Breathe> {
  late final Animation<double> _opacity = loop.drive(const _Breath(0.5));

  @override
  Duration get loopDuration => AppMotion.pulse;

  @override
  bool get looping => widget.active;

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _opacity, child: widget.child);
}

/// Holds the place of something on its way, such as the assistant's
/// reply: a few quiet lines, as text will stand there, that slide up into
/// place one after another over about as long as the wait usually takes,
/// then breathe softly until they are replaced. How long they stood is
/// learned as that [timing], for next time.
class PendingLines extends StatefulWidget {
  const PendingLines({
    super.key,
    this.lines = const <double>[0.86, 0.58],
    this.timing,
    this.semanticsLabel,
  });

  /// How much of the width each line takes.
  final List<double> lines;
  final String? timing;
  final String? semanticsLabel;

  @override
  State<PendingLines> createState() => _PendingLinesState();
}

class _PendingLinesState extends State<PendingLines>
    with TickerProviderStateMixin, _LoopingAnimation<PendingLines> {
  late final AnimationController _arrive = AnimationController(vsync: this);
  late final Animation<double> _breath = loop.drive(const _Breath(0.55));

  /// Each line starts a little after the one above it.
  late final List<CurvedAnimation> _lineArrivals = <CurvedAnimation>[
    for (int i = 0; i < widget.lines.length; i++)
      CurvedAnimation(
        parent: _arrive,
        curve: Interval(
          i / (widget.lines.length + 1),
          (i + 2) / (widget.lines.length + 1),
          curve: AppMotion.fadeInCurve,
        ),
      ),
  ];
  final Duration _since = LoadTimings.clock();
  bool _started = false;

  @override
  Duration get loopDuration => AppMotion.shimmer;

  // Breathing waits for the lines to have arrived.
  @override
  bool get looping => _arrive.isCompleted;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final Duration duration = AppMotion.resolve(context, AppMotion.shimmer);
    if (duration == Duration.zero) {
      _arrive.value = 1;
    } else {
      _arrive.animateTo(1, duration: duration).whenComplete(() {
        if (mounted) syncLoop();
      });
    }
  }

  @override
  void dispose() {
    final String? timing = widget.timing;
    if (timing != null) {
      LoadTimings.instance.record(timing, LoadTimings.clock() - _since);
    }
    for (final CurvedAnimation arrival in _lineArrivals) {
      arrival.dispose();
    }
    _arrive.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color fill = AppColors.resolve(context).surfaceMuted;
    return Semantics(
      label: widget.semanticsLabel,
      child: FadeTransition(
        opacity: _breath,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int i = 0; i < _lineArrivals.length; i++)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: _Arrival(
                  animation: _lineArrivals[i],
                  effect: RevealEffect.slideUp,
                  child: FractionallySizedBox(
                    alignment: AlignmentDirectional.centerStart,
                    widthFactor: widget.lines[i],
                    child: AnimatedBuilder(
                      animation: loop,
                      builder: (BuildContext context, Widget? child) =>
                          Container(
                            height: AppSpacing.sm,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(999),
                              gradient: LinearGradient(
                                begin: Alignment(-2 + loop.value * 4, 0),
                                end: Alignment(-1 + loop.value * 4, 0),
                                colors: <Color>[
                                  fill,
                                  AppColors.resolve(context).surface,
                                  fill,
                                ],
                                stops: const <double>[0, 0.5, 1],
                              ),
                            ),
                          ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// How far work has come, as a figure rather than a bar: the percentage
/// rises into place as it changes, and nothing shows while the total is
/// not known yet.
class ProgressCount extends StatelessWidget {
  const ProgressCount({
    super.key,
    required this.value,
    this.semanticsLabel,
    this.style,
  });

  /// From 0 to 1, or null while how much is left is unknown.
  final double? value;
  final String? semanticsLabel;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final double? value = this.value;
    final int? percent = value == null
        ? null
        : (value.clamp(0.0, 1.0) * 100).floor();
    return Semantics(
      label: semanticsLabel,
      value: percent == null ? null : '$percent%',
      child: ExcludeSemantics(
        child: GentleSwitcher(
          value: percent,
          child: Text(
            percent == null ? '' : '$percent%',
            style: (style ?? DefaultTextStyle.of(context).style).copyWith(
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}

/// While [active], breathes a soft accent glow around [child], for a panel
/// whose work runs in the background, such as the assistant waiting on an
/// answer.
class AmbientGlow extends StatefulWidget {
  const AmbientGlow({
    super.key,
    required this.active,
    required this.child,
    this.borderRadius = BorderRadius.zero,
  });

  final bool active;
  final BorderRadius borderRadius;
  final Widget child;

  @override
  State<AmbientGlow> createState() => _AmbientGlowState();
}

class _AmbientGlowState extends State<AmbientGlow>
    with SingleTickerProviderStateMixin, _LoopingAnimation<AmbientGlow> {
  @override
  Duration get loopDuration => AppMotion.pulse;

  @override
  bool get looping => widget.active;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.resolve(context);
    return AnimatedBuilder(
      animation: loop,
      // Always a DecoratedBox, so the child keeps its state as the glow
      // comes and goes.
      builder: (BuildContext context, Widget? child) {
        // Reduced motion holds the glow at its middle strength.
        final double breath = loop.isAnimating
            ? 0.5 - 0.5 * math.cos(loop.value * 2 * math.pi)
            : 0.5;
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            boxShadow: widget.active
                ? <BoxShadow>[
                    BoxShadow(
                      color: colors.highlighters[3].withValues(
                        alpha: 0.14 + breath * 0.10,
                      ),
                      blurRadius: 22 + breath * 8,
                      spreadRadius: -4,
                    ),
                    BoxShadow(
                      color: colors.highlighters[4].withValues(
                        alpha: 0.10 + (1 - breath) * 0.10,
                      ),
                      blurRadius: 28,
                      spreadRadius: -7,
                      offset: const Offset(8, 0),
                    ),
                    BoxShadow(
                      color: colors.highlighters[1].withValues(alpha: 0.10),
                      blurRadius: 24,
                      spreadRadius: -8,
                      offset: const Offset(-8, 2),
                    ),
                  ]
                : const <BoxShadow>[],
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}
