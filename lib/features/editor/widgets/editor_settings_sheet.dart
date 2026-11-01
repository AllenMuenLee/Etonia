import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../shared/motion/motion_memory.dart';
import '../../../app/theme/app_icons.dart';
import '../../../shared/widgets/app_controls.dart';
import '../ai/ai_assistant_controller.dart';
import '../ai/ai_config.dart';

/// Opens the editor's settings as a floating card under the top bar's
/// trailing corner, beside the gear that opened it. A tap outside, or
/// Escape, closes it.
Future<void> showEditorSettings(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close settings',
    barrierColor: AppColors.of(context).shadow.withValues(alpha: 0.12),
    transitionDuration: AppMotion.resolvePaced(
      context,
      AppMotion.snappy.duration,
      MotionMemory.instance.recall(('popover', 'editor-settings')),
    ),
    pageBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
        ) {
          final MediaQueryData media = MediaQuery.of(context);
          return Padding(
            padding: EdgeInsetsDirectional.only(
              top: media.padding.top + AppSizes.appBarHeight,
              end: AppSpacing.xs + media.padding.right,
              start: AppSpacing.xs + media.padding.left,
              bottom: AppSpacing.xs + media.padding.bottom,
            ),
            child: Align(
              alignment: AlignmentDirectional.topEnd,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: EditorSettingsSheet.width,
                ),
                child: _SettingsCard(child: builder(context)),
              ),
            ),
          );
        },
    transitionBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
          Widget child,
        ) {
          final Animation<double> curved = CurvedAnimation(
            parent: animation,
            curve: AppMotion.fadeInCurve,
            reverseCurve: AppMotion.fadeOutCurve,
          );
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
              alignment: AlignmentDirectional.topEnd.resolve(
                Directionality.of(context),
              ),
              child: child,
            ),
          );
        },
  );
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    const BorderRadius radius = AppBorderRadius.large;
    return GlassSurface(
      borderRadius: radius,
      boxShadow: AppShadows.floating(colors),
      child: Material(type: MaterialType.transparency, child: child),
    );
  }
}

/// Note-editor preferences that should not take space from the conversation.
class EditorSettingsSheet extends StatelessWidget {
  const EditorSettingsSheet({
    super.key,
    required this.controller,
    this.stylusOnly,
    this.textSize,
    this.onTextSizeChanged,
    this.onChooseHandwriting,
    this.onExportPdf,
    this.onExportSvg,
  });

  static const double width = 380;

  final AiAssistantController controller;

  /// Whether fingers are kept from writing; the switch is hidden without
  /// it.
  final ValueNotifier<bool>? stylusOnly;

  /// How large the assistant writes on the note; the choice is hidden
  /// without it.
  final ValueListenable<AiTextSize>? textSize;
  final ValueChanged<AiTextSize>? onTextSizeChanged;

  /// Opens the handwriting the assistant writes in, to choose another or
  /// write the letters again; hidden without it.
  final VoidCallback? onChooseHandwriting;

  final VoidCallback? onExportPdf;
  final VoidCallback? onExportSvg;

  @override
  Widget build(BuildContext context) {
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.sm,
        AppSpacing.lg,
      ),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  'Settings',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ),
            CompactIconButton(
              tooltip: 'Close settings',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: AppIcons.close,
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsetsDirectional.only(end: AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SizedBox(height: AppSpacing.sm),
              if (onExportPdf != null) ...<Widget>[
                _ActionRow(
                  icon: AppIcons.share,
                  label: 'Export as PDF',
                  onTap: onExportPdf!,
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
              if (onExportSvg != null) ...<Widget>[
                _ActionRow(
                  icon: AppIcons.share,
                  label: 'Export page vectors as SVG',
                  onTap: onExportSvg!,
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
              if (stylusOnly != null) ...<Widget>[
                const SectionLabel('Writing'),
                ValueListenableBuilder<bool>(
                  valueListenable: stylusOnly!,
                  builder: (BuildContext context, bool value, Widget? child) {
                    return ToggleSetting(
                      label: 'Only write with stylus',
                      hint:
                          'Fingers scroll and tap but leave no ink. A mouse '
                          'still writes, as some tablets report themselves '
                          'as one.',
                      value: value,
                      onChanged: (bool enabled) => stylusOnly!.value = enabled,
                    );
                  },
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              // What the assistant may draw is chosen from the palette's AI
              // button; here is only how its writing looks.
              if (onChooseHandwriting != null) ...<Widget>[
                const SectionLabel('Assistant'),
                _ActionRow(
                  icon: AppIcons.pen,
                  label: 'Handwriting font',
                  onTap: onChooseHandwriting!,
                ),
              ],
              if (textSize != null && onTextSizeChanged != null) ...<Widget>[
                const SizedBox(height: AppSpacing.md),
                const SectionLabel('Text size'),
                ValueListenableBuilder<AiTextSize>(
                  valueListenable: textSize!,
                  builder:
                      (BuildContext context, AiTextSize size, Widget? child) {
                        return SegmentedChoice<AiTextSize>(
                          options: AiTextSize.values,
                          selected: size,
                          labelOf: (AiTextSize size) => size.label,
                          onSelected: onTextSizeChanged!,
                        );
                      },
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              const SectionLabel('Panel side'),
              ValueListenableBuilder<AiPanelPlacement>(
                valueListenable: controller.placement,
                builder:
                    (
                      BuildContext context,
                      AiPanelPlacement placement,
                      Widget? child,
                    ) {
                      return SegmentedChoice<AiPanelSide>(
                        options: const <AiPanelSide>[
                          AiPanelSide.left,
                          AiPanelSide.right,
                        ],
                        selected: placement.side,
                        labelOf: (AiPanelSide side) =>
                            side == AiPanelSide.left ? 'Left' : 'Right',
                        iconOf: (AiPanelSide side) => side == AiPanelSide.left
                            ? AppIcons.panelLeft
                            : AppIcons.panelRight,
                        onSelected: controller.setSide,
                      );
                    },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A row that does something when tapped, such as exporting.
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Material(
      color: AppGlass.muted(colors),
      borderRadius: AppBorderRadius.medium,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppBorderRadius.medium,
        child: SizedBox(
          height: AppSizes.minTouchTarget,
          child: Row(
            children: <Widget>[
              const SizedBox(width: AppSpacing.sm),
              Icon(icon, size: 20, color: colors.textSecondary),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              Icon(AppIcons.disclosure, size: 20, color: colors.textSecondary),
              const SizedBox(width: AppSpacing.xs),
            ],
          ),
        ),
      ),
    );
  }
}
