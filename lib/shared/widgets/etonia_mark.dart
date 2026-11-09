import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';

/// A resolution-independent rendering of the Etonia mascot in straight,
/// architectural lines: a sheet of paper with a crisp 45-degree fold, two
/// vertical slits for serene eyes, and a straight pencil resting along the
/// fold with a two-leaf sprout at its end.
///
/// [color] is the ink of the outline and face; the paper, fold, pencil and
/// sprout take their shades from [AppColors].
class EtoniaMark extends StatelessWidget {
  const EtoniaMark({super.key, required this.size, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.resolve(context);
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _EtoniaMarkPainter(
          ink: color ?? colors.textPrimary,
          paper: colors.writingSurface,
          fold: AppColors.light.fold,
          pencil: AppColors.light.pencil,
          sprout: AppColors.light.sprout,
        ),
      ),
    );
  }
}

class _EtoniaMarkPainter extends CustomPainter {
  const _EtoniaMarkPainter({
    required this.ink,
    required this.paper,
    required this.fold,
    required this.pencil,
    required this.sprout,
  });

  final Color ink;
  final Color paper;
  final Color fold;
  final Color pencil;
  final Color sprout;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 100, size.height / 100);
    final Paint line = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    Paint fill(Color color) => Paint()..color = color;

    // The sheet, about 0.88 as wide as tall, its top-right corner folded
    // down along a straight 45-degree line.
    const double left = 12, top = 22, right = 78, bottom = 97, cut = 14;
    final Path sheet = Path()
      ..moveTo(left, top)
      ..lineTo(right - cut, top)
      ..lineTo(right, top + cut)
      ..lineTo(right, bottom)
      ..lineTo(left, bottom)
      ..close();
    canvas.drawPath(sheet, fill(paper));
    canvas.drawPath(sheet, line);

    // The folded flap, in the shade of the fold.
    final Path flap = Path()
      ..moveTo(right - cut, top)
      ..lineTo(right - cut, top + cut)
      ..lineTo(right, top + cut)
      ..close();
    canvas.drawPath(flap, fill(fold));
    canvas.drawPath(flap, line..strokeWidth = 2.8);
    line.strokeWidth = 3.8;

    // Two vertical slits for closed eyes.
    canvas.drawLine(const Offset(34, 52), const Offset(34, 72), line);
    canvas.drawLine(const Offset(56, 52), const Offset(56, 72), line);

    // The pencil, a straight bar resting along the fold, tipped in lead.
    canvas.save();
    canvas.translate(50, 14);
    canvas.rotate(0.62);
    const Rect barrel = Rect.fromLTWH(0, 0, 44, 9);
    canvas.drawRect(barrel, fill(pencil));
    final Path wood = Path()
      ..moveTo(44, 0)
      ..lineTo(54, 4.5)
      ..lineTo(44, 9)
      ..close();
    canvas.drawPath(wood, fill(fold));
    canvas.drawPath(
      Path()
        ..moveTo(50.4, 2.7)
        ..lineTo(54, 4.5)
        ..lineTo(50.4, 6.3)
        ..close(),
      fill(ink),
    );
    canvas.drawRect(barrel, line);
    canvas.drawPath(wood, line);
    canvas.restore();

    // Two tiny straight leaves at the pencil's tail.
    final Path leaves = Path()
      ..moveTo(50, 14)
      ..lineTo(40, 6)
      ..lineTo(48, 4)
      ..close()
      ..moveTo(50, 14)
      ..lineTo(50, 2)
      ..lineTo(57, 8)
      ..close();
    canvas.drawPath(leaves, fill(sprout));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_EtoniaMarkPainter oldDelegate) =>
      oldDelegate.ink != ink ||
      oldDelegate.paper != paper ||
      oldDelegate.fold != fold ||
      oldDelegate.pencil != pencil ||
      oldDelegate.sprout != sprout;
}

/// Three capsule arms that fill in sequence for branded, long-running work.
class EtoniaBarsLoader extends StatefulWidget {
  const EtoniaBarsLoader({
    super.key,
    this.size = 48,
    this.color,
    this.semanticsLabel = 'Loading',
  });

  final double size;
  final Color? color;

  /// What a screen reader says while the bars run.
  final String semanticsLabel;

  @override
  State<EtoniaBarsLoader> createState() => _EtoniaBarsLoaderState();
}

class _EtoniaBarsLoaderState extends State<EtoniaBarsLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.bars,
  );
  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context);
    if (_reduced) {
      _controller
        ..stop()
        ..value = 1;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.semanticsLabel,
    child: SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? child) => CustomPaint(
          painter: _BarsPainter(
            progress: _reduced ? 1 : _controller.value,
            color: widget.color ?? AppColors.of(context).textPrimary,
          ),
        ),
      ),
    ),
  );
}

class _BarsPainter extends CustomPainter {
  const _BarsPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double height = size.height * 0.16;
    final List<double> widths = <double>[0.78, 1, 0.86];
    for (int i = 0; i < widths.length; i++) {
      final double local = ((progress * 4) - i).clamp(0, 1);
      final double width = size.width * widths[i];
      final Rect track = Rect.fromLTWH(0, i * height * 1.65, width, height);
      canvas.drawRRect(
        RRect.fromRectAndRadius(track, Radius.circular(height / 2)),
        Paint()..color = color.withValues(alpha: 0.16),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(track.left, track.top, width * local, height),
          Radius.circular(height / 2),
        ),
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}
