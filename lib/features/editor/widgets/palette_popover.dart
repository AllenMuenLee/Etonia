import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';

/// Anchors a small panel to a palette control. The panel opens beside a
/// vertical palette and above or below a horizontal one, and is kept on
/// screen by [MenuAnchor].
class PalettePopover extends StatelessWidget {
  const PalettePopover({
    super.key,
    required this.paletteAxis,
    required this.anchorBuilder,
    required this.panelBuilder,
    this.controller,
  });

  final MenuController? controller;

  final Axis paletteAxis;

  /// Builds the control; call `toggle` to open or close the panel.
  final Widget Function(BuildContext context, VoidCallback toggle)
  anchorBuilder;

  /// Builds the panel; call `close` to dismiss it.
  final Widget Function(BuildContext context, VoidCallback close) panelBuilder;

  @override
  Widget build(BuildContext context) {
    final bool beside = paletteAxis == Axis.vertical;
    return MenuAnchor(
      controller: controller,
      animated: !MediaQuery.disableAnimationsOf(context),
      consumeOutsideTap: true,
      style: MenuStyle(
        alignment: beside
            ? AlignmentDirectional.topEnd
            : AlignmentDirectional.bottomStart,
      ),
      alignmentOffset: beside
          ? const Offset(AppSpacing.xs, 0)
          : const Offset(0, AppSpacing.xs),
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
