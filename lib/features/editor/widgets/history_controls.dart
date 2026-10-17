import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/theme/app_icons.dart';
import '../ink/ink_controller.dart';

/// Undo and Redo for the current page. Each is disabled while there is
/// nothing for it to do.
class HistoryControls extends StatelessWidget {
  const HistoryControls({
    super.key,
    required this.controller,
    required this.onUndo,
    required this.onRedo,
  });

  /// The current page's ink, whose history the buttons follow.
  final InkController controller;
  final VoidCallback onUndo;
  final VoidCallback onRedo;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller.documentRevisionListenable,
      builder: (BuildContext context, Widget? _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            IconButton(
              tooltip: 'Undo',
              onPressed: controller.canUndo ? onUndo : null,
              icon: const Icon(AppIcons.undo),
            ),
            IconButton(
              tooltip: 'Redo',
              onPressed: controller.canRedo ? onRedo : null,
              icon: const Icon(AppIcons.redo),
            ),
          ],
        );
      },
    );
  }
}

/// [HistoryControls] on a small card of their own, floating over the page
/// with the tool palette's look and exactly its [height].
class FloatingHistoryControls extends StatelessWidget {
  const FloatingHistoryControls({
    super.key,
    required this.controller,
    required this.onUndo,
    required this.onRedo,
    required this.height,
  });

  final InkController controller;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final double height;

  /// The card's width for a given [height]: two square buttons, inset.
  static double widthFor(double height) {
    final double padding = (height - AppSizes.minTouchTarget) / 2;
    return 2 * AppSizes.minTouchTarget + 2 * padding;
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'History',
      child: SizedBox(
        key: const ValueKey<String>('history-card'),
        height: height,
        width: widthFor(height),
        child: GlassSurface(
          borderRadius: BorderRadius.circular(AppRadii.large),
          boxShadow: AppShadows.floating(colors),
          child: Material(
            type: MaterialType.transparency,
            child: Center(
              child: FocusTraversalGroup(
                child: HistoryControls(
                  controller: controller,
                  onUndo: onUndo,
                  onRedo: onRedo,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
