import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../app/theme/app_tokens.dart';

/// One hand-drawn clip of Etonia, rendered from `Tonia.jpg` by `tool/etonia_rig`
/// at 12 frames per second. The frame counts must match the rig's
/// `ANIMATIONS` table.
///
/// The frames are drawn facing left, her pencil pointing left. [EtoniaMascot]
/// turns her round by default, so she faces right, her pencil pointing right.
enum EtoniaClip {
  /// Glancing left, right and up: the AI is searching or reading files.
  lookAround('look_around', 12),

  /// Eyes drifting up and across, a foot tapping: the AI is composing.
  think('think', 12),

  /// One bouncy hop; idle play.
  hop('hop', 12),

  /// Leaning out to the side, scribbling with the pen: the AI is writing a
  /// notation.
  write('write', 12),

  /// A scampering gallop of two bounds a second. She stays in place in the
  /// frames; [EtoniaRunner] carries her across the screen.
  run('run', 12),

  /// Springing up from behind a card and looking at the person. Plays once,
  /// then [attend] keeps going.
  popOut('pop_out', 12),

  /// Peeking over the card at the person.
  attend('attend', 12),

  /// Two hops, then a shake from left to right; two seconds, and it repeats.
  grade('grade', 24);

  const EtoniaClip(this.name, this.frames);

  /// The folder and file prefix of its frames.
  final String name;

  /// How many frames the clip has.
  final int frames;

  /// Frames per second of every clip.
  static const int fps = 12;

  /// Width / height of a frame (256 x 301 px).
  static const double aspectRatio = 256 / 301;

  Duration get duration =>
      Duration(microseconds: frames * Duration.microsecondsPerSecond ~/ fps);

  /// Where her two eyes are in the first frame of the clip, where she stands
  /// still between clips, in the frame's own 256 x 301 pixels. Empty for a
  /// clip whose first frame is not a resting pose.
  List<Rect> get restEyes => switch (this) {
    EtoniaClip.lookAround || EtoniaClip.think || EtoniaClip.hop => const <Rect>[
      Rect.fromLTRB(62, 145, 71, 209),
      Rect.fromLTRB(117, 143, 124, 208),
    ],
    EtoniaClip.write => const <Rect>[
      Rect.fromLTRB(90, 144, 99, 208),
      Rect.fromLTRB(144, 151, 153, 217),
    ],
    EtoniaClip.grade => const <Rect>[
      Rect.fromLTRB(59, 163, 68, 213),
      Rect.fromLTRB(119, 162, 126, 213),
    ],
    EtoniaClip.attend => const <Rect>[
      Rect.fromLTRB(62, 178, 71, 243),
      Rect.fromLTRB(117, 177, 125, 243),
    ],
    _ => const <Rect>[],
  };

  /// The asset of one frame.
  String frameAsset(int frame) =>
      'assets/animations/etonia_loops/ui/$name/'
      '${name}_${frame.toString().padLeft(2, '0')}.png';

  /// The still shown instead of the clip when animations are off: her rest
  /// pose, or the one she holds peeking over a card.
  String get stillAsset => switch (this) {
    EtoniaClip.popOut || EtoniaClip.attend => EtoniaClip.attend.frameAsset(0),
    _ => EtoniaClip.think.frameAsset(0),
  };
}

/// Etonia herself, playing [clip].
///
/// With [then] set the clip plays once and [then] loops after it; otherwise
/// [clip] loops. [EtoniaMascot.playlist] loops through several clips in turn.
/// With reduced motion on she holds still.
class EtoniaMascot extends StatefulWidget {
  const EtoniaMascot({
    super.key,
    required EtoniaClip this.clip,
    this.then,
    this.height = 88,
    this.mirrored = true,
    this.rest = Duration.zero,
    this.semanticsLabel,
    this.animated = true,
  }) : playlist = null;

  /// Plays [clips] one after the other, round and round.
  const EtoniaMascot.playlist({
    super.key,
    required List<EtoniaClip> this.playlist,
    this.height = 88,
    this.mirrored = true,
    this.rest = Duration.zero,
    this.semanticsLabel,
    this.animated = true,
  }) : clip = null,
       then = null;

  final EtoniaClip? clip;
  final EtoniaClip? then;
  final List<EtoniaClip>? playlist;

  /// How long she stands still in her rest pose after each time round a looping
  /// clip, before the next one starts. Idle play uses it so she plays in bursts
  /// instead of being busy forever on a screen nobody is working at.
  final Duration rest;

  /// Height of the drawing; the width follows the frames' aspect ratio.
  final double height;

  /// Turned round from the frames, which face left, so she faces right. Off, she
  /// faces left.
  final bool mirrored;

  /// What a screen reader says; the drawing itself carries no other meaning.
  /// Without it the drawing is skipped by screen readers.
  final String? semanticsLabel;

  /// Whether she moves at all. Off, she holds still in her rest pose, as with
  /// reduced motion.
  final bool animated;

  /// Whether she breathes while she stands still between clips. Tests that
  /// wait for the screen to settle turn it off, since a breath never ends.
  static bool idles = true;

  double get width => height * EtoniaClip.aspectRatio;

  /// What plays once, first.
  List<EtoniaClip> get _intro =>
      then == null || clip == null ? const <EtoniaClip>[] : <EtoniaClip>[clip!];

  /// What loops after it.
  List<EtoniaClip> get _loop => playlist ?? <EtoniaClip>[then ?? clip!];

  @override
  State<EtoniaMascot> createState() => _EtoniaMascotState();
}

class _EtoniaMascotState extends State<EtoniaMascot>
    with TickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);

  /// The idle loop, two breaths long, that runs only while she stands still
  /// between clips, so there is always something moving when no clip plays.
  /// She blinks a few times within it: see [_blinks].
  late final AnimationController _idle = AnimationController(
    vsync: this,
    duration: AppMotion.pulse * 2,
  );

  /// Where in the idle loop each blink starts, as a fraction of it: one on its
  /// own, then a quick double, so she blinks three times a loop.
  static const List<double> _blinks = <double>[0.12, 0.5, 0.6];

  /// How long a blink lasts, as a fraction of the idle loop (about 0.2 s).
  static const double _blinkLength = 0.042;

  bool get _blinking {
    final double t = _idle.value;
    for (final double start in _blinks) {
      if (t >= start && t < start + _blinkLength) return true;
    }
    return false;
  }

  Timer? _resting;
  bool _reduced = false;
  bool _precached = false;

  /// Which clip of the run is on: positions past the intro go round the loop.
  int _pos = 0;

  /// The frame of that clip on show.
  int _frame = 0;

  /// Frames used up by the clips finished since the ticker last started.
  int _base = 0;

  EtoniaClip _clipAt(int pos) {
    final List<EtoniaClip> intro = widget._intro;
    if (pos < intro.length) return intro[pos];
    final List<EtoniaClip> loop = widget._loop;
    return loop[(pos - intro.length) % loop.length];
  }

  void _onTick(Duration elapsed) {
    final int step =
        elapsed.inMicroseconds *
        EtoniaClip.fps ~/
        Duration.microsecondsPerSecond;
    int pos = _pos;
    int base = _base;
    while (step - base >= _clipAt(pos).frames) {
      final bool looping = pos >= widget._intro.length;
      base += _clipAt(pos).frames;
      pos++;
      if (looping && widget.rest > Duration.zero) {
        // A loop is done: stand still in the rest pose for a while.
        _ticker.stop();
        setState(() {
          _pos = pos;
          _base = 0;
          _frame = 0;
        });
        _resting = Timer(widget.rest, _resume);
        if (EtoniaMascot.idles) _idle.repeat();
        return;
      }
    }
    final int frame = step - base;
    _base = base;
    if (pos != _pos || frame != _frame) {
      setState(() {
        _pos = pos;
        _frame = frame;
      });
    }
  }

  void _resume() {
    _resting = null;
    _idle
      ..stop()
      ..value = 0;
    if (mounted && !_reduced && !_ticker.isActive) _ticker.start();
  }

  void _restart() {
    _resting?.cancel();
    _resting = null;
    _idle
      ..stop()
      ..value = 0;
    _ticker.stop();
    _pos = 0;
    _frame = 0;
    _base = 0;
    if (!_reduced) _ticker.start();
  }

  EtoniaClip get _firstClip =>
      widget._intro.isNotEmpty ? widget._intro.first : widget._loop.first;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = !widget.animated || MediaQuery.disableAnimationsOf(context);
    if (_reduced) {
      _resting?.cancel();
      _resting = null;
      _idle
        ..stop()
        ..value = 0;
      _ticker.stop();
      _pos = 0;
      _frame = 0;
      _base = 0;
    } else if (!_ticker.isActive && _resting == null) {
      _ticker.start();
    }
    if (!_precached) {
      _precached = true;
      _precacheAll();
    }
  }

  @override
  void didUpdateWidget(EtoniaMascot old) {
    super.didUpdateWidget(old);
    if (old.clip != widget.clip ||
        old.then != widget.then ||
        !listEquals(old.playlist, widget.playlist)) {
      _restart();
      _precacheAll();
    }
  }

  void _precacheAll() {
    for (final EtoniaClip clip in <EtoniaClip>{
      ...widget._intro,
      ...widget._loop,
    }) {
      _precache(clip);
    }
  }

  /// Decodes a clip ahead of its turn so its first frames don't flash empty.
  void _precache(EtoniaClip clip) {
    for (int i = 0; i < clip.frames; i++) {
      unawaited(
        precacheImage(
          AssetImage(clip.frameAsset(i)),
          context,
          onError: (Object _, StackTrace? _) {},
        ),
      );
    }
  }

  @override
  void dispose() {
    _resting?.cancel();
    _ticker.dispose();
    _idle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String asset = _reduced
        ? _firstClip.stillAsset
        : _clipAt(_pos).frameAsset(_frame);
    Widget drawing = Image(
      image: AssetImage(asset),
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      // Hold the previous frame until the next one has decoded.
      gaplessPlayback: true,
      errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
          const SizedBox.shrink(),
    );
    final bool idling = _resting != null && !_reduced && EtoniaMascot.idles;
    final List<Rect> eyes = _clipAt(_pos).restEyes;
    Widget mirror(Widget child) => widget.mirrored
        ? Transform(
            alignment: Alignment.center,
            transform: Matrix4.diagonal3Values(-1, 1, 1),
            child: child,
          )
        : child;
    if (!idling) drawing = mirror(drawing);
    // Standing still between clips, she breathes: a squash and stretch about
    // her feet, which stay where they are, and blinks now and then.
    if (idling) {
      final Widget still = drawing;
      drawing = AnimatedBuilder(
        animation: _idle,
        child: still,
        builder: (BuildContext context, Widget? child) {
          final double breath = math.sin(_idle.value * 4 * math.pi);
          Widget face = child!;
          if (eyes.isNotEmpty && _blinking) {
            face = Stack(
              fit: StackFit.expand,
              children: <Widget>[
                face,
                CustomPaint(painter: _BlinkPainter(eyes)),
              ],
            );
          }
          return Transform(
            alignment: Alignment.bottomCenter,
            transform: Matrix4.diagonal3Values(
              1 - 0.011 * breath,
              1 + 0.03 * breath,
              1,
            ),
            child: mirror(face),
          );
        },
      );
    }
    drawing = SizedBox(
      height: widget.height,
      width: widget.width,
      child: drawing,
    );
    final String? label = widget.semanticsLabel;
    if (label == null) return ExcludeSemantics(child: drawing);
    return Semantics(
      label: label,
      child: ExcludeSemantics(child: drawing),
    );
  }
}

/// Her eyes shut: each is wiped out with the paper of her face and a short
/// line drawn across where it was. [eyes] are in the frame's 256 x 301 pixels.
class _BlinkPainter extends CustomPainter {
  const _BlinkPainter(this.eyes);

  final List<Rect> eyes;

  static const Color _paper = Color(0xFFFFF9ED);
  static const Color _ink = Color(0xFF2B2830);

  @override
  void paint(Canvas canvas, Size size) {
    final double sx = size.width / 256;
    final double sy = size.height / 301;
    final Paint wipe = Paint()..color = _paper;
    final Paint lid = Paint()
      ..color = _ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, 2.2 * sy)
      ..strokeCap = StrokeCap.round;
    for (final Rect eye in eyes) {
      final Rect scaled = Rect.fromLTRB(
        eye.left * sx,
        eye.top * sy,
        eye.right * sx,
        eye.bottom * sy,
      );
      canvas.drawRect(scaled.inflate(2 * sx), wipe);
      final double y = scaled.top + scaled.height * 0.62;
      canvas.drawLine(
        Offset(scaled.center.dx - 4.5 * sx, y),
        Offset(scaled.center.dx + 4.5 * sx, y),
        lid,
      );
    }
  }

  @override
  bool shouldRepaint(_BlinkPainter old) => !listEquals(old.eyes, eyes);
}

/// Etonia running back and forth along the bottom edge of the space she is
/// given, feet on the edge, turning round at each side.
///
/// She moves in steps, a frame at a time, by exactly the distance the rig slid
/// her planted foot back (see `RUN_STEP` in `tool/etonia_rig/animations.py`),
/// so the foot stays put on the edge instead of skating. Place it with a
/// [Positioned.fill] or give it the space; it takes none of its own and
/// ignores touches.
class EtoniaRunner extends StatefulWidget {
  const EtoniaRunner({super.key, this.height = 64, this.reach});

  final double height;

  /// How far along the space she may go, from its left edge, before she turns
  /// back; the whole width when null.
  final double? reach;

  /// What she covers in one second, in drawing heights: 12 frames of 520 rig
  /// pixels on a 2920 pixel tall frame.
  static const double heightsPerSecond = 520 * 12 / 2920;

  /// Where the drawn art starts and ends across a frame, as fractions of its
  /// width, whichever way she faces (the pencil's tip is the far end).
  static const double _artStart = 0.057;
  static const double _artEnd = 0.943;

  @override
  State<EtoniaRunner> createState() => _EtoniaRunnerState();
}

class _EtoniaRunnerState extends State<EtoniaRunner>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  bool _reduced = false;
  int _step = 0;
  bool _precached = false;

  void _onTick(Duration elapsed) {
    final int step =
        elapsed.inMicroseconds *
        EtoniaClip.fps ~/
        Duration.microsecondsPerSecond;
    if (step != _step) setState(() => _step = step);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context);
    if (_reduced) {
      _ticker.stop();
    } else if (!_ticker.isActive) {
      _ticker.start();
    }
    if (!_precached) {
      _precached = true;
      for (int i = 0; i < EtoniaClip.run.frames; i++) {
        unawaited(
          precacheImage(
            AssetImage(EtoniaClip.run.frameAsset(i)),
            context,
            onError: (Object _, StackTrace? _) {},
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Someone who asked for less motion is not chased across the screen.
    if (_reduced) return const SizedBox.shrink();
    final double h = widget.height;
    final double w = h * EtoniaClip.aspectRatio;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) {
            // The whole drawing, art and all, stays on screen both ways round.
            final double minLeft = -EtoniaRunner._artStart * w;
            final double span = widget.reach == null
                ? box.maxWidth
                : math.min(box.maxWidth, widget.reach!);
            final double track = span - w * EtoniaRunner._artEnd - minLeft;
            if (!track.isFinite || track <= 0) return const SizedBox.shrink();
            final double distance =
                _step * EtoniaRunner.heightsPerSecond * h / EtoniaClip.fps;
            final double lap = distance % (2 * track);
            final bool rightwards = lap < track;
            final double along = rightwards ? lap : 2 * track - lap;
            return Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                Positioned(
                  left: minLeft + along,
                  // The feet stop a little short of the frame's bottom.
                  bottom: -0.026 * h,
                  child: EtoniaMascot(
                    clip: EtoniaClip.run,
                    height: h,
                    // The frames are drawn facing left, so she is turned to
                    // face right when she runs that way.
                    mirrored: rightwards,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Puts Etonia behind the top edge of the card below it: [peeking] she springs
/// up from behind it and looks at the person, and keeps looking. Everything of
/// her below the card's edge is hidden, so no card needs to be told about her.
///
/// The frames end with her lower body, mouth included, behind the card; the
/// clip is cut at [hiddenFraction] of the frame's height.
class EtoniaPeek extends StatelessWidget {
  const EtoniaPeek({
    super.key,
    this.height = 96,
    this.semanticsLabel = 'Etonia has a test ready',
  });

  final double height;
  final String? semanticsLabel;

  /// Where the card's edge cuts her, as a fraction of the frame's height.
  static const double hiddenFraction = 0.84;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Align(
        alignment: Alignment.topCenter,
        heightFactor: hiddenFraction,
        child: EtoniaMascot(
          clip: EtoniaClip.popOut,
          then: EtoniaClip.attend,
          // She keeps looking at the person, with a breather between looks.
          rest: const Duration(seconds: 2),
          height: height,
          semanticsLabel: semanticsLabel,
        ),
      ),
    );
  }
}
