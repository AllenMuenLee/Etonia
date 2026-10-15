import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../ai/ai_assistant_controller.dart';

/// Note-editor preferences that should not take space from the conversation.
class EditorSettingsSheet extends StatelessWidget {
  const EditorSettingsSheet({
    super.key,
    required this.controller,
    this.stylusOnly,
    this.onInsertPdf,
    this.onInsertImage,
    this.onExportPdf,
  });

  final AiAssistantController controller;

  /// Whether fingers are kept from writing; the switch is hidden without
  /// it.
  final ValueNotifier<bool>? stylusOnly;
  final VoidCallback? onInsertPdf;
  final VoidCallback? onInsertImage;
  final VoidCallback? onExportPdf;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          0,
          AppSpacing.md,
          AppSpacing.lg,
        ),
        children: <Widget>[
          Semantics(
            header: true,
            child: Text(
              'Settings',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (onInsertPdf != null ||
              onInsertImage != null ||
              onExportPdf != null) ...<Widget>[
            if (onInsertPdf != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                minTileHeight: AppSizes.minTouchTarget,
                leading: const Icon(Icons.picture_as_pdf_outlined),
                title: const Text('Insert PDF pages'),
                onTap: onInsertPdf,
              ),
            if (onInsertImage != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                minTileHeight: AppSizes.minTouchTarget,
                leading: const Icon(Icons.add_photo_alternate_outlined),
                title: const Text('Insert image'),
                onTap: onInsertImage,
              ),
            if (onExportPdf != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                minTileHeight: AppSizes.minTouchTarget,
                leading: const Icon(Icons.ios_share_outlined),
                title: const Text('Export as PDF'),
                onTap: onExportPdf,
              ),
            const Divider(),
          ],
          if (stylusOnly != null) ...<Widget>[
            ValueListenableBuilder<bool>(
              valueListenable: stylusOnly!,
              builder: (BuildContext context, bool value, Widget? child) {
                return SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.edit_outlined),
                  title: const Text('Only write with stylus'),
                  subtitle: const Text(
                    'Fingers scroll and tap but leave no ink. A mouse still '
                    'writes, as some tablets report themselves as one.',
                  ),
                  value: value,
                  onChanged: (bool enabled) => stylusOnly!.value = enabled,
                );
              },
            ),
            const Divider(),
          ],
          AnimatedBuilder(
            animation: controller,
            builder: (BuildContext context, Widget? child) {
              return Column(
                children: <Widget>[
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Enable notation'),
                    subtitle: const Text(
                      'Allow the assistant to add static drawings to the note.',
                    ),
                    value: controller.notationEnabled,
                    onChanged: controller.setNotationEnabled,
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Enable animation'),
                    subtitle: const Text(
                      'Allow useful motion explanations to loop on the note.',
                    ),
                    value: controller.animationEnabled,
                    onChanged: controller.setAnimationEnabled,
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: AppSpacing.sm),
          Text('Panel side', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          ValueListenableBuilder<AiPanelPlacement>(
            valueListenable: controller.placement,
            builder:
                (
                  BuildContext context,
                  AiPanelPlacement placement,
                  Widget? child,
                ) {
                  return Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: SegmentedButton<AiPanelSide>(
                      segments: const <ButtonSegment<AiPanelSide>>[
                        ButtonSegment<AiPanelSide>(
                          value: AiPanelSide.left,
                          label: Text('Left'),
                          icon: Icon(Icons.align_horizontal_left),
                        ),
                        ButtonSegment<AiPanelSide>(
                          value: AiPanelSide.right,
                          label: Text('Right'),
                          icon: Icon(Icons.align_horizontal_right),
                        ),
                      ],
                      selected: <AiPanelSide>{placement.side},
                      onSelectionChanged: (Set<AiPanelSide> selected) {
                        controller.setSide(selected.single);
                      },
                    ),
                  );
                },
          ),
        ],
      ),
    );
  }
}
