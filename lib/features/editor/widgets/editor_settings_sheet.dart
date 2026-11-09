import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../shared/motion/motion_memory.dart';
import '../../../app/theme/app_icons.dart';
import '../../../shared/widgets/app_controls.dart';
import '../ai/ai_assistant_controller.dart';
import '../ai/ai_config.dart';
import '../ink/stylus_actions.dart';

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
                constraints: BoxConstraints(
                  maxWidth: EditorSettingsSheet.width,
                  maxHeight:
                      media.size.height -
                      media.padding.vertical -
                      AppSizes.appBarHeight -
                      AppSpacing.xs * 2,
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
    this.stylusActions,
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

  /// Hardware stylus shortcuts shared by every open note.
  final ValueNotifier<StylusActionBindings>? stylusActions;

  final VoidCallback? onExportPdf;
  final VoidCallback? onExportSvg;

  @override
  Widget build(BuildContext context) {
    final StylusFamily? family = StylusFamily.current;
    final List<StylusControl> stylusControls = stylusActions == null
        ? const <StylusControl>[]
        : family?.controls ?? const <StylusControl>[];
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.only(top: AppSpacing.xs, bottom: AppSpacing.md),
      children: <Widget>[
        Padding(
          padding: const EdgeInsetsDirectional.only(
            start: AppSpacing.md + AppSpacing.sm,
            end: AppSpacing.xs,
          ),
          child: Row(
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
        ),
        if (stylusOnly != null || stylusControls.isNotEmpty)
          _SettingsGroup(
            title: family?.title ?? StylusFamily.androidStylus.title,
            children: <Widget>[
              if (stylusOnly != null)
                ValueListenableBuilder<bool>(
                  valueListenable: stylusOnly!,
                  builder: (BuildContext context, bool value, Widget? child) {
                    return ToggleSetting(
                      label:
                          family?.stylusOnlyLabel ??
                          StylusFamily.androidStylus.stylusOnlyLabel,
                      hint: 'Fingers scroll and tap but leave no ink.',
                      value: value,
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: AppSpacing.xs,
                      ),
                      onChanged: (bool enabled) => stylusOnly!.value = enabled,
                    );
                  },
                ),
              for (final StylusControl control in stylusControls)
                ValueListenableBuilder<StylusActionBindings>(
                  valueListenable: stylusActions!,
                  builder:
                      (
                        BuildContext context,
                        StylusActionBindings bindings,
                        Widget? child,
                      ) {
                        return _StylusActionRow(
                          control: control,
                          action: bindings.actionFor(control.gesture),
                          onChanged: (StylusAction action) {
                            stylusActions!.value = bindings.withAction(
                              control.gesture,
                              action,
                            );
                          },
                        );
                      },
                ),
            ],
          ),
        // What the assistant may draw is chosen from the palette's AI button;
        // here is only how its writing looks and where its panel sits.
        _SettingsGroup(
          title: 'Assistant',
          children: <Widget>[
            if (onChooseHandwriting != null)
              _ActionRow(
                label: 'Handwriting font',
                onTap: onChooseHandwriting!,
              ),
            if (textSize != null && onTextSizeChanged != null)
              _ChoiceRow(
                label: 'Text size',
                control: ValueListenableBuilder<AiTextSize>(
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
              ),
            _ChoiceRow(
              label: 'Panel side',
              control: ValueListenableBuilder<AiPanelPlacement>(
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
            ),
          ],
        ),
        if (onExportPdf != null || onExportSvg != null)
          _SettingsGroup(
            title: 'Export',
            children: <Widget>[
              if (onExportPdf != null)
                _ActionRow(label: 'Export as PDF', onTap: onExportPdf!),
              if (onExportSvg != null)
                _ActionRow(label: 'Export page as SVG', onTap: onExportSvg!),
            ],
          ),
      ],
    );
  }
}

/// A headed, grouped list: the rows share one quiet surface, with hairlines
/// between them.
class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsetsDirectional.only(start: AppSpacing.sm),
            child: Semantics(header: true, child: SectionLabel(title)),
          ),
          Material(
            color: AppGlass.muted(colors),
            borderRadius: AppBorderRadius.medium,
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (int i = 0; i < children.length; i++) ...<Widget>[
                  if (i > 0)
                    Divider(
                      height: AppSizes.hairline,
                      thickness: AppSizes.hairline,
                      indent: AppSpacing.sm,
                      color: colors.divider,
                    ),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A row of a [_SettingsGroup]: its name, its [value] if it shows one, and an
/// [icon] saying what a tap does.
class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.label,
    this.hint,
    this.value,
    required this.icon,
  });

  final String label;
  final String? hint;
  final String? value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final String? value = this.value;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSizes.minTouchTarget),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              flex: 2,
              child: SettingText(label: label, hint: hint),
            ),
            if (value != null) ...<Widget>[
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                flex: 3,
                child: Text(
                  value,
                  textAlign: TextAlign.end,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
            const SizedBox(width: AppSpacing.xxs),
            AppIcon(icon, size: 14, color: colors.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// A stylus gesture and what it does; the row opens the list of actions.
class _StylusActionRow extends StatelessWidget {
  const _StylusActionRow({
    required this.control,
    required this.action,
    required this.onChanged,
  });

  final StylusControl control;
  final StylusAction action;
  final ValueChanged<StylusAction> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return PopupMenuButton<StylusAction>(
      key: ValueKey<String>('stylus-${control.gesture.name}-action'),
      popUpAnimationStyle: AppMotion.pacedPopupStyle(
        MotionMemory.instance.peek(('popup', 'stylus-action')),
      ),
      onOpened: () =>
          MotionMemory.instance.remember(('popup', 'stylus-action')),
      tooltip: 'Choose action for ${control.label}',
      initialValue: action,
      onSelected: onChanged,
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 240),
      itemBuilder: (BuildContext context) {
        return <PopupMenuEntry<StylusAction>>[
          for (final StylusAction option in StylusAction.values)
            PopupMenuItem<StylusAction>(
              value: option,
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: AppSpacing.lg,
                    child: option == action
                        ? AppIcon(
                            AppIcons.check,
                            size: 16,
                            color: colors.accent,
                          )
                        : null,
                  ),
                  Expanded(child: Text(option.label)),
                ],
              ),
            ),
        ];
      },
      child: Semantics(
        button: true,
        label: '${control.label}: ${action.label}',
        hint: control.hint,
        excludeSemantics: true,
        child: _SettingsRow(
          label: control.label,
          hint: control.hint,
          value: action.label,
          icon: AppIcons.expand,
        ),
      ),
    );
  }
}

/// A setting chosen from a few options: on one line where it fits, the
/// options under the name where it does not.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({required this.label, required this.control});

  static const double _controlWidth = 200;

  final String label;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      child: OverflowBar(
        alignment: MainAxisAlignment.spaceBetween,
        overflowSpacing: AppSpacing.xs,
        overflowAlignment: OverflowBarAlignment.start,
        children: <Widget>[
          SizedBox(
            height: AppSizes.minTouchTarget - 4,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: 1,
              child: SettingText(label: label),
            ),
          ),
          SizedBox(
            width: MediaQuery.textScalerOf(context).scale(_controlWidth),
            child: control,
          ),
        ],
      ),
    );
  }
}

/// A row that does something when tapped, such as exporting.
class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: _SettingsRow(label: label, icon: AppIcons.disclosure),
    );
  }
}
