import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';

/// A resolution-independent rendering of the folded E in the app icon.
class EtoniaMark extends StatelessWidget {
  const EtoniaMark({super.key, required this.size, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _EtoniaMarkPainter(color ?? AppColors.of(context).textPrimary),
    ),
  );
}

class _EtoniaMarkPainter extends CustomPainter {
  const _EtoniaMarkPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 100, size.height / 100);
    final Paint ink = Paint()..color = color;
    final Path body = Path.combine(
      PathOperation.union,
      Path()..addRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(12, 10, 25, 80),
          const Radius.circular(13),
        ),
      ),
      Path()
        ..addRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(18, 10, 54, 28),
            const Radius.circular(8),
          ),
        )
        ..addRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(18, 37, 65, 20),
            const Radius.circular(10),
          ),
        )
        ..addRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(18, 63, 68, 27),
            const Radius.circular(10),
          ),
        ),
    );
    canvas.drawPath(body, ink);
    canvas.drawPath(
      Path()
        ..moveTo(75, 10)
        ..lineTo(94, 34)
        ..lineTo(82, 34)
        ..quadraticBezierTo(75, 34, 75, 27)
        ..close(),
      ink,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_EtoniaMarkPainter oldDelegate) =>
      oldDelegate.color != color;
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
