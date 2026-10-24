import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../ai/ai_assistant_controller.dart';
import '../ink/ink_controller.dart';

/// A glowing frame around everything on [page] that the open chat has been
/// given as context, one frame for each thing chosen. It takes no presses.
class AiContextGlow extends StatelessWidget {
  const AiContextGlow({super.key, required this.assistant, required this.page});

  final AiAssistantController assistant;
  final InkController page;

  /// How far a frame stands off what it surrounds.
  static const double _inset = 8;

  @override
  Widget build(BuildContext context) {
    final Color color = AppColors.of(context).accent;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: ListenableBuilder(
          listenable: Listenable.merge(<Listenable>[
            assistant,
            assistant.placement,
          ]),
          builder: (BuildContext context, Widget? _) {
            final AiSelectionContext? chosen = assistant.context;
            if (chosen == null || !assistant.isOpen) {
              return const SizedBox.expand();
            }
            final List<Rect> frames = <Rect>[
              for (final AiContextGroup group in chosen.groups)
                if (_isOnPage(group))
                  if (group.bounds case final Rect bounds)
                    bounds.inflate(_inset),
            ];
            if (frames.isEmpty) return const SizedBox.expand();
            return CustomPaint(
              painter: _GlowPainter(frames: frames, color: color),
              size: Size.infinite,
            );
          },
        ),
      ),
    );
  }

  bool _isOnPage(AiContextGroup group) {
    final Object? owner = group.page;
    if (owner != null) return identical(owner, page);
    // Not known, as for a conversation saved with the note: found by what
    // it holds.
    if (group.strokes.isNotEmpty) {
      return page.strokes.contains(group.strokes.first);
    }
    if (group.images.isNotEmpty) {
      return page.images.contains(group.images.first);
    }
    return false;
  }
}

class _GlowPainter extends CustomPainter {
  _GlowPainter({required this.frames, required this.color});

  final List<Rect> frames;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint halo = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..color = color.withValues(alpha: 0.4)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7);
    final Paint edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = color.withValues(alpha: 0.9);
    for (final Rect frame in frames) {
      final RRect shape = RRect.fromRectAndRadius(
        frame,
        const Radius.circular(12),
      );
      canvas
        ..drawRRect(shape, halo)
        ..drawRRect(shape, edge);
    }
  }

  @override
  bool shouldRepaint(_GlowPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.frames.length != frames.length ||
        !_sameFrames(oldDelegate.frames);
  }

  bool _sameFrames(List<Rect> other) {
    for (int i = 0; i < frames.length; i++) {
      if (frames[i] != other[i]) return false;
    }
    return true;
  }
}
