import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../shared/widgets/app_controls.dart';
import '../ink/ink_controller.dart';

/// Undo and Redo for the whole note. Each is disabled while there is
/// nothing for it to do.
class HistoryControls extends StatelessWidget {
  const HistoryControls({
    super.key,
    required this.controller,
    required this.onUndo,
    required this.onRedo,
  });

  /// The current page's ink, whose history, shared by every page, the
  /// buttons follow.
  final InkController controller;
  final VoidCallback onUndo;
  final VoidCallback onRedo;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        controller.documentRevisionListenable,
        controller.history,
      ]),
      builder: (BuildContext context, Widget? _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ToolbarIconButton(
              tooltip: 'Undo',
              onPressed: controller.canUndo ? onUndo : null,
              icon: AppIcons.undo,
            ),
            ToolbarIconButton(
              tooltip: 'Redo',
              onPressed: controller.canRedo ? onRedo : null,
              icon: AppIcons.redo,
            ),
          ],
        );
      },
    );
  }
}

/// One small card of controls hanging from the top bar over the page at the
/// left, with the tool palette's look and exactly its [height]: Undo and Redo.
class FloatingHistoryControls extends StatelessWidget {
  const FloatingHistoryControls({
    super.key,
    required this.height,
    required this.width,
    required this.children,
  });

  final double height;
  final double width;
  final List<Widget> children;

  /// The card's width for a given [height]: Undo and Redo.
  static double widthFor(
    double height, {
    bool find = false,
    bool navigation = false,
  }) {
    const double touch = AppSizes.minTouchTarget;
    final double padding = (height - touch) / 2;
    return 2 * touch + 2 * padding;
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
        width: width,
        child: GlassSurface(
          // Joined to the top bar and the screen's left edge: rounded only where
          // it hangs free.
          borderRadius: const BorderRadius.only(
            bottomRight: Radius.circular(AppRadii.large),
          ),
          boxShadow: AppShadows.floating(colors),
          child: Material(
            type: MaterialType.transparency,
            child: Center(
              child: FocusTraversalGroup(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: children,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
