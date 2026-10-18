import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// Words read from handwriting, flying from where they were written on the
/// page into the chat's composer: they lift off at the handwriting's size,
/// arc over to [target], shrink to the composer's [style], and fade as they
/// land. [onArrived] is called once they have landed.
///
/// Shown in an overlay, over everything, and never takes a touch. [from]
/// and [target] are in the coordinates of the box it fills. [target] is
/// asked every frame, so the words follow a composer that is still sliding
/// in; when it answers null they keep to where it last was.
class FlyingWords extends StatefulWidget {
  const FlyingWords({
    super.key,
    required this.text,
    required this.from,
    required this.target,
    required this.style,
    required this.color,
    required this.duration,
    required this.curve,
    required this.onArrived,
  });

  final String text;
  final Rect from;
  final Offset? Function() target;

  /// How the words look once they have landed.
  final TextStyle style;

  /// Their color, and the glow around them while they fly.
  final Color color;
  final Duration duration;
  final Curve curve;
  final VoidCallback onArrived;

  /// The size the words lift off at, for handwriting [height] tall.
  static double startSize(double height) => (height * 0.55).clamp(18, 56);

  @override
  State<FlyingWords> createState() => _FlyingWordsState();
}

class _FlyingWordsState extends State<FlyingWords>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flight =
      AnimationController(vsync: this, duration: widget.duration)
        ..addStatusListener((AnimationStatus status) {
          if (status == AnimationStatus.completed) {
            widget.onArrived();
          }
        })
        ..forward();

  Offset? _lastTarget;

  @override
  void dispose() {
    _flight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _flight,
        builder: (BuildContext context, Widget? _) {
          final double t = widget.curve.transform(_flight.value);
          final Offset start = widget.from.center;
          final Offset end = _lastTarget =
              widget.target() ?? _lastTarget ?? start;
          // Over an arc that rises above both ends, as if tossed.
          final Offset control = Offset(
            (start.dx + end.dx) / 2,
            math.min(start.dy, end.dy) - 80,
          );
          final double u = 1 - t;
          final Offset at =
              start * (u * u) + control * (2 * u * t) + end * (t * t);
          final double endSize = widget.style.fontSize ?? 14;
          final double size = lerpDouble(
            FlyingWords.startSize(widget.from.height),
            endSize,
            t,
          )!;
          // Pops in quickly, holds, and fades into the composer's text.
          final double raw = _flight.value;
          final double opacity = raw < 0.08
              ? raw / 0.08
              : raw > 0.8
              ? (1 - raw) / 0.2
              : 1;
          return Stack(
            children: <Widget>[
              Positioned(
                left: at.dx,
                top: at.dy,
                child: FractionalTranslation(
                  // Centered on the handwriting; lands with its start at the
                  // end of the composer's text.
                  translation: Offset(lerpDouble(-0.5, 0, t)!, -0.5),
                  child: Opacity(
                    opacity: opacity.clamp(0.0, 1.0),
                    child: Text(
                      widget.text,
                      maxLines: 1,
                      softWrap: false,
                      style: widget.style.copyWith(
                        fontSize: size,
                        color: widget.color,
                        fontWeight: FontWeight.w600,
                        shadows: <Shadow>[
                          Shadow(
                            color: widget.color.withValues(alpha: 0.55 * u),
                            blurRadius: 14 * u + 2,
                          ),
                        ],
                      ),
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
