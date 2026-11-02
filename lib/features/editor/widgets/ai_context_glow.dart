import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../ai/ai_assistant_controller.dart';
import '../ink/ink_controller.dart';

/// A selection frame around everything on [page] that the open chat has been
/// given as context, one frame for each thing chosen.
class AiContextSelection extends StatelessWidget {
  const AiContextSelection({
    super.key,
    required this.assistant,
    required this.page,
  });

  final AiAssistantController assistant;
  final InkController page;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
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
                  if (group.bounds case final Rect bounds) bounds,
            ];
            if (frames.isEmpty) return const SizedBox.expand();
            return CustomPaint(
              key: const ValueKey<String>('ai-context-selection-layer'),
              painter: _ContextSelectionPainter(
                frames: frames,
                color: colors.accent,
                handleColor: colors.writingSurface,
              ),
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

class _ContextSelectionPainter extends CustomPainter {
  _ContextSelectionPainter({
    required this.frames,
    required this.color,
    required this.handleColor,
  });

  final List<Rect> frames;
  final Color color;
  final Color handleColor;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = AppSizes.hairline
      ..color = color
      ..isAntiAlias = true;
    final Paint fill = Paint()
      ..color = handleColor
      ..isAntiAlias = true;
    final Paint handleOutline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = AppSizes.focusRingWidth
      ..color = color
      ..isAntiAlias = true;
    for (final Rect frame in frames) {
      canvas.drawRect(frame, outline);
      for (final Offset corner in <Offset>[
        frame.topLeft,
        frame.topRight,
        frame.bottomRight,
        frame.bottomLeft,
      ]) {
        canvas
          ..drawCircle(corner, 6, fill)
          ..drawCircle(corner, 6, handleOutline);
      }
    }
  }

  @override
  bool shouldRepaint(_ContextSelectionPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.handleColor != handleColor ||
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
