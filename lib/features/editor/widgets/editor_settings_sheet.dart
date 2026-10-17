import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/theme/app_icons.dart';
import '../../../shared/widgets/app_controls.dart';
import '../ai/ai_assistant_controller.dart';

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
    transitionDuration: AppMotion.resolve(context, AppMotion.fast),
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
            curve: AppMotion.standard,
          );
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
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
    final BorderRadius radius = BorderRadius.circular(AppRadii.large);
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
    this.onExportPdf,
  });

  static const double width = 380;

  final AiAssistantController controller;

  /// Whether fingers are kept from writing; the switch is hidden without
  /// it.
  final ValueNotifier<bool>? stylusOnly;
  final VoidCallback? onExportPdf;

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
              const SectionLabel('Assistant'),
              AnimatedBuilder(
                animation: controller,
                builder: (BuildContext context, Widget? child) {
                  return Column(
                    children: <Widget>[
                      ToggleSetting(
                        label: 'Enable notation',
                        hint:
                            'Allow the assistant to add static drawings to '
                            'the note.',
                        value: controller.notationEnabled,
                        onChanged: controller.setNotationEnabled,
                      ),
                      ToggleSetting(
                        label: 'Enable animation',
                        hint:
                            'Allow useful motion explanations to loop on the '
                            'note.',
                        value: controller.animationEnabled,
                        onChanged: controller.setAnimationEnabled,
                      ),
                    ],
                  );
                },
              ),
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
      borderRadius: BorderRadius.circular(AppRadii.medium),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.medium),
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
