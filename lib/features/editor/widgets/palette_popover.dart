import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import 'tool_palette.dart';

/// Anchors a small panel to a palette control. The panel opens toward the
/// page: below a palette docked at the top, above one at the bottom, and
/// beside one on either side. [MenuAnchor] keeps it on screen.
class PalettePopover extends StatelessWidget {
  const PalettePopover({
    super.key,
    required this.paletteEdge,
    required this.anchorBuilder,
    required this.panelBuilder,
    this.controller,
    this.onChanged,
  });

  final MenuController? controller;

  /// Called after the panel opens or closes.
  final VoidCallback? onChanged;

  /// The edge the palette is docked against.
  final PaletteEdge paletteEdge;

  /// Builds the control; call `toggle` to open or close the panel.
  final Widget Function(BuildContext context, VoidCallback toggle)
  anchorBuilder;

  /// Builds the panel; call `close` to dismiss it.
  final Widget Function(BuildContext context, VoidCallback close) panelBuilder;

  @override
  Widget build(BuildContext context) {
    // Physical edges: the palette was placed on screen, not in reading
    // order.
    final (Alignment alignment, Offset offset) = switch (paletteEdge) {
      PaletteEdge.top => (Alignment.bottomLeft, const Offset(0, AppSpacing.xs)),
      // Above the control; MenuAnchor flips a panel that would leave the
      // screen at the bottom to above its anchor.
      PaletteEdge.bottom => (
        Alignment.bottomLeft,
        const Offset(0, AppSpacing.xs),
      ),
      PaletteEdge.left => (Alignment.topRight, const Offset(AppSpacing.xs, 0)),
      PaletteEdge.right => (
        Alignment.topLeft,
        const Offset(-(AppSizes.popoverWidth + AppSpacing.xs), 0),
      ),
    };
    return MenuAnchor(
      controller: controller,
      animated: !MediaQuery.disableAnimationsOf(context),
      consumeOutsideTap: true,
      onOpen: onChanged,
      onClose: onChanged,
      style: MenuStyle(alignment: alignment),
      alignmentOffset: offset,
      builder:
          (BuildContext context, MenuController controller, Widget? child) {
            return anchorBuilder(context, () {
              controller.isOpen ? controller.close() : controller.open();
            });
          },
      menuChildren: <Widget>[
        Builder(
          builder: (BuildContext context) {
            return SizedBox(
              width: AppSizes.popoverWidth,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: panelBuilder(
                  context,
                  () => MenuController.maybeOf(context)?.close(),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
