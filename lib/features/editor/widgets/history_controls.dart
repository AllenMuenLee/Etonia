import 'package:flutter/material.dart';

import '../ink/ink_controller.dart';

/// Undo and Redo for the current page, in the top bar. Each is disabled
/// while there is nothing for it to do.
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
              icon: const Icon(Icons.undo),
            ),
            IconButton(
              tooltip: 'Redo',
              onPressed: controller.canRedo ? onRedo : null,
              icon: const Icon(Icons.redo),
            ),
          ],
        );
      },
    );
  }
}
