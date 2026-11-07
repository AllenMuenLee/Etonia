import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../shared/motion/motion_memory.dart';
import '../ai/ai_client.dart';
import '../ai/ai_usage_gate.dart';

/// The one AI setting most people need: how hard the assistant thinks. Auto
/// lets Etonia choose the cheapest model and effort that is good enough for
/// the question. Which models may be used is under Advanced.
class AiThinkingSelector extends StatelessWidget {
  const AiThinkingSelector({
    super.key,
    required this.controller,
    this.lastServedBy,
  });

  final AiRoutingChooser controller;

  /// The model that wrote the latest answer, shown beside the setting when
  /// the user asked to see it.
  final AiModelId? lastServedBy;

  static const Object _advanced = Object();

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final AiRoutingPreferences routing = controller.routing;
    final AiModelId? served = routing.showModelUsed ? lastServedBy : null;
    final String label =
        'Thinking: ${routing.effort.label}${served == null ? '' : ' · ${served.label}'}';
    return PopupMenuButton<Object>(
      popUpAnimationStyle: AppMotion.pacedPopupStyle(
        MotionMemory.instance.peek(('popup', 'ai-thinking')),
      ),
      onOpened: () => MotionMemory.instance.remember(('popup', 'ai-thinking')),
      key: const ValueKey<String>('ai-thinking-selector'),
      tooltip: 'How hard the assistant thinks',
      initialValue: routing.effort,
      onSelected: (Object choice) {
        if (choice is AiEffort) {
          controller.setRouting(routing.copyWith(effort: choice));
        } else {
          showAiAdvancedSettings(context, controller);
        }
      },
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 320),
      itemBuilder: (BuildContext context) {
        return <PopupMenuEntry<Object>>[
          for (final AiEffort effort in AiEffort.values)
            PopupMenuItem<Object>(
              key: ValueKey<String>('ai-thinking-${effort.name}'),
              value: effort,
              child: _EffortOption(
                effort: effort,
                selected: effort == routing.effort,
              ),
            ),
          const PopupMenuDivider(),
          PopupMenuItem<Object>(
            key: const ValueKey<String>('ai-thinking-advanced'),
            value: _advanced,
            child: Row(
              children: <Widget>[
                const SizedBox(width: 24),
                Icon(AppIcons.settings, size: 16, color: colors.textPrimary),
                const SizedBox(width: AppSpacing.xs),
                Text(
                  'Advanced',
                  style: text.bodyLarge?.copyWith(color: colors.textPrimary),
                ),
              ],
            ),
          ),
        ];
      },
      child: Semantics(
        button: true,
        label: '$label. Change how hard the assistant thinks',
        excludeSemantics: true,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSizes.minTouchTarget),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            widthFactor: 1,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                shape: const StadiumBorder(),
                color: AppGlass.muted(colors),
              ),
              child: Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: AppSpacing.sm,
                  end: AppSpacing.xs,
                  top: AppSpacing.xxs + 2,
                  bottom: AppSpacing.xxs + 2,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(AppIcons.plans, size: 14, color: colors.textPrimary),
                    const SizedBox(width: AppSpacing.xxs),
                    Flexible(
                      child: Text(
                        label,
                        key: const ValueKey<String>('ai-thinking-label'),
                        style: text.labelLarge?.copyWith(
                          color: colors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(AppIcons.model, size: 14, color: colors.textPrimary),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EffortOption extends StatelessWidget {
  const _EffortOption({required this.effort, required this.selected});

  final AiEffort effort;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 24,
          child: selected
              ? Icon(AppIcons.check, size: 16, color: colors.accent)
              : null,
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                effort.label,
                style: text.bodyLarge?.copyWith(
                  color: colors.textPrimary,
                  fontWeight: selected ? FontWeight.w600 : null,
                ),
              ),
              Text(
                effort.description,
                style: text.bodySmall?.copyWith(color: colors.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Opens the Advanced settings: a switch for each provider and each model,
/// and whether answers say which model wrote them.
Future<void> showAiAdvancedSettings(
  BuildContext context,
  AiRoutingChooser controller,
) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) =>
        AiAdvancedSettings(controller: controller),
  );
}

class AiAdvancedSettings extends StatelessWidget {
  const AiAdvancedSettings({super.key, required this.controller});

  final AiRoutingChooser controller;

  static String _accessText(AiModelAccess? access) {
    return switch (access) {
      AiModelAccess.unlimited => 'Included in your plan',
      AiModelAccess.metered => 'Uses your credits',
      AiModelAccess.outOfCredits => 'Credits used up',
      AiModelAccess.locked => 'Needs a higher plan',
      AiModelAccess.noPlan => 'Needs a plan',
      null => '',
    };
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final AppColors colors = AppColors.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 640),
        child: ListenableBuilder(
          listenable: controller,
          builder: (BuildContext context, Widget? _) {
            final AiRoutingPreferences routing = controller.routing;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: AppSpacing.md,
                    end: AppSpacing.xs,
                    top: AppSpacing.sm,
                  ),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          'Advanced AI settings',
                          style: text.titleLarge,
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Done'),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView(
                    key: const ValueKey<String>('ai-advanced-settings'),
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.md,
                      0,
                      AppSpacing.md,
                      AppSpacing.md,
                    ),
                    shrinkWrap: true,
                    children: <Widget>[
                      Text(
                        'Etonia picks the cheapest model that is good enough '
                        'for each question. Turn off a model, or a whole '
                        'provider, to keep it from ever seeing your notes.',
                        style: text.bodyMedium?.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      SwitchListTile(
                        key: const ValueKey<String>('ai-show-model-used'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Show the model used'),
                        subtitle: const Text(
                          'Names the model beside Thinking.',
                        ),
                        value: routing.showModelUsed,
                        onChanged: (bool value) => controller.setRouting(
                          routing.copyWith(showModelUsed: value),
                        ),
                      ),
                      for (final AiProvider provider
                          in AiProvider.values) ...<Widget>[
                        const Divider(),
                        SwitchListTile(
                          key: ValueKey<String>('ai-provider-${provider.name}'),
                          contentPadding: EdgeInsets.zero,
                          title: Text(provider.label, style: text.titleMedium),
                          value: routing.isProviderEnabled(provider),
                          onChanged: (bool value) => controller.setRouting(
                            routing.withProvider(provider, enabled: value),
                          ),
                        ),
                        for (final AiModelId model in AiModelId.values)
                          if (model.provider == provider)
                            SwitchListTile(
                              key: ValueKey<String>('ai-model-${model.name}'),
                              contentPadding: const EdgeInsetsDirectional.only(
                                start: AppSpacing.md,
                              ),
                              dense: true,
                              title: Text(model.label),
                              subtitle: Text(
                                '${model.summary} · '
                                '${_accessText(controller.accessFor(model))}',
                              ),
                              value: routing.isEnabled(model),
                              onChanged: (bool value) => controller.setRouting(
                                routing.withModel(model, enabled: value),
                              ),
                            ),
                      ],
                      if (routing.allowedModels.isEmpty) ...<Widget>[
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          'Every model is off. Turn one on to use AI.',
                          key: const ValueKey<String>('ai-no-model-warning'),
                          style: text.bodyMedium?.copyWith(
                            color: colors.danger,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
