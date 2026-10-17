import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';

// These resolve their colors without requiring the app theme, since they
// stand in for content that may be shown on its own.
//
// Work in progress is shown as light moving through a surface, never as a
// spinner: a glow sweeping a slim track, a sheen crossing a placeholder,
// or a soft pulse around a panel that is busy.

/// Runs a repeating 0→1 cycle, or holds still under reduced motion.
mixin _LoopingAnimation<T extends StatefulWidget>
    on State<T>, SingleTickerProviderStateMixin<T> {
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
    _sync();
  }

  @override
  void didUpdateWidget(T oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final bool run = looping && !MediaQuery.disableAnimationsOf(context);
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

/// A slim progress track. With a [value] it fills to it, with a sheen
/// running over the filled part; without one, a glowing band flows along
/// it for as long as the work takes.
class ShimmerTrack extends StatefulWidget {
  const ShimmerTrack({
    super.key,
    this.value,
    this.semanticsLabel,
    this.height = AppSpacing.xxs,
  });

  /// From 0 to 1, or null when how much is left is unknown.
  final double? value;
  final String? semanticsLabel;
  final double height;

  @override
  State<ShimmerTrack> createState() => _ShimmerTrackState();
}

class _ShimmerTrackState extends State<ShimmerTrack>
    with SingleTickerProviderStateMixin, _LoopingAnimation<ShimmerTrack> {
  @override
  Duration get loopDuration => AppMotion.shimmer;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.resolve(context);
    final double? value = widget.value?.clamp(0.0, 1.0);
    return Semantics(
      label: widget.semanticsLabel,
      value: value == null ? null : '${(value * 100).round()}%',
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: CustomPaint(
          painter: _TrackPainter(
            progress: loop,
            value: value,
            track: AppGlass.muted(colors),
            accent: colors.accent,
            sheen: colors.onAccent,
          ),
        ),
      ),
    );
  }
}

class _TrackPainter extends CustomPainter {
  _TrackPainter({
    required this.progress,
    required this.value,
    required this.track,
    required this.accent,
    required this.sheen,
  }) : super(repaint: progress);

  final Animation<double> progress;
  final double? value;
  final Color track;
  final Color accent;
  final Color sheen;

  @override
  void paint(Canvas canvas, Size size) {
    final Radius radius = Radius.circular(size.height / 2);
    final Rect bounds = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(bounds, radius),
      Paint()..color = track,
    );
    final double t = progress.value;
    final double? value = this.value;
    if (value != null) {
      final Rect fill = Rect.fromLTWH(0, 0, size.width * value, size.height);
      if (fill.width <= 0) return;
      final RRect filled = RRect.fromRectAndRadius(fill, radius);
      canvas
        ..drawRRect(
          filled,
          Paint()
            ..color = accent.withValues(alpha: 0.35)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
        )
        ..drawRRect(filled, Paint()..color = accent)
        ..save()
        ..clipRRect(filled);
      _band(canvas, fill, t, sheen.withValues(alpha: 0.45));
      canvas.restore();
      return;
    }
    // The band eases in and out of each pass, so it reads as a flow rather
    // than a conveyor.
    final double eased = Curves.easeInOutSine.transform(t);
    final double band = math.max(size.width * 0.4, size.height * 8);
    final double left = -band + (size.width + band) * eased;
    final Rect glow = Rect.fromLTWH(left, 0, band, size.height);
    canvas
      ..save()
      ..clipRRect(RRect.fromRectAndRadius(bounds.inflate(6), radius));
    _band(canvas, glow, 0.5, accent.withValues(alpha: 0.45), blur: 4);
    canvas.restore();
    canvas
      ..save()
      ..clipRRect(RRect.fromRectAndRadius(bounds, radius));
    _band(canvas, glow, 0.5, accent);
    canvas.restore();
  }

  /// A soft-edged vertical band of [color], centred at [t] across [area].
  void _band(Canvas canvas, Rect area, double t, Color color, {double? blur}) {
    final double width = area.width;
    final double center = area.left + (width * 1.6) * t - width * 0.3;
    final Rect rect = Rect.fromCenter(
      center: Offset(center, area.center.dy),
      width: width,
      height: area.height,
    );
    final Paint paint = Paint()
      ..shader = LinearGradient(
        colors: <Color>[
          color.withValues(alpha: 0),
          color,
          color.withValues(alpha: 0),
        ],
      ).createShader(rect);
    if (blur != null) {
      paint.maskFilter = MaskFilter.blur(BlurStyle.normal, blur);
    }
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(_TrackPainter old) =>
      old.value != value ||
      old.track != track ||
      old.accent != accent ||
      old.sheen != sheen ||
      old.progress != progress;
}

/// Stands in for content that is still loading, such as a PDF page being
/// rendered: a quiet fill with a sheen drifting diagonally across it.
class ShimmerPlaceholder extends StatefulWidget {
  const ShimmerPlaceholder({
    super.key,
    this.borderRadius = BorderRadius.zero,
    this.semanticsLabel,
  });

  final BorderRadius borderRadius;
  final String? semanticsLabel;

  @override
  State<ShimmerPlaceholder> createState() => _ShimmerPlaceholderState();
}

class _ShimmerPlaceholderState extends State<ShimmerPlaceholder>
    with SingleTickerProviderStateMixin, _LoopingAnimation<ShimmerPlaceholder> {
  @override
  Duration get loopDuration => AppMotion.shimmer * 1.25;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.resolve(context);
    return Semantics(
      label: widget.semanticsLabel,
      child: ClipRRect(
        borderRadius: widget.borderRadius,
        child: CustomPaint(
          size: Size.infinite,
          painter: _SheenPainter(
            progress: loop,
            sheen: colors.accent.withValues(alpha: 0.06),
          ),
        ),
      ),
    );
  }
}

class _SheenPainter extends CustomPainter {
  _SheenPainter({required this.progress, required this.sheen})
    : super(repaint: progress);

  final Animation<double> progress;
  final Color sheen;

  @override
  void paint(Canvas canvas, Size size) {
    final double t = Curves.easeInOutSine.transform(progress.value);
    final double span = size.width + size.height;
    final double x = -size.height + span * t;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            sheen.withValues(alpha: 0),
            sheen,
            sheen.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromLTWH(x, 0, size.height, size.height)),
    );
  }

  @override
  bool shouldRepaint(_SheenPainter old) =>
      old.sheen != sheen || old.progress != progress;
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
    final Color accent = AppColors.resolve(context).accent;
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
                ? AppShadows.processing(accent, breath)
                : const <BoxShadow>[],
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}
