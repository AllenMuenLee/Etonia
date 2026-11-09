import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../shared/feedback/app_haptics.dart';
import '../ai/ai_client.dart';
import '../ai/ai_usage_gate.dart';

/// The one AI setting most people need: how hard the assistant thinks. The
/// Thinking button names the current level; tapping it opens a scrollable
/// meter that selects from low to medium to high effort, and an Auto button
/// that lets Etonia choose the cheapest model and effort that is good enough
/// for the question. Which models may be used is under Advanced.
class AiThinkingSelector extends StatefulWidget {
  const AiThinkingSelector({
    super.key,
    required this.controller,
    this.lastServedBy,
  });

  final AiRoutingChooser controller;

  /// The model that wrote the latest answer, shown beside the setting when
  /// the user asked to see it.
  final AiModelId? lastServedBy;

  @override
  State<AiThinkingSelector> createState() => _AiThinkingSelectorState();
}

class _AiThinkingSelectorState extends State<AiThinkingSelector> {
  /// Whether the level options are showing. They stay hidden until the
  /// Thinking button is tapped, and hide again on a second tap.
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final AiRoutingChooser controller = widget.controller;
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final AiRoutingPreferences routing = controller.routing;
    final AiModelId? served = routing.showModelUsed ? widget.lastServedBy : null;
    final String label =
        'Thinking: ${routing.effort.label}${served == null ? '' : ' · ${served.label}'}';
    final Duration duration = AppMotion.resolve(context, AppMotion.fast);

    return Semantics(
      container: true,
      label: '$label. Change how hard the assistant thinks',
      child: ConstrainedBox(
        key: const ValueKey<String>('ai-thinking-selector'),
        constraints: const BoxConstraints(minHeight: AppSizes.minTouchTarget),
        child: AnimatedSize(
          duration: duration,
          curve: AppMotion.zoomInCurve,
          alignment: AlignmentDirectional.topStart,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
            Padding(
              padding: EdgeInsetsDirectional.only(
                bottom: _expanded ? AppSpacing.xs : 0,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Flexible(
                    child: InkWell(
                      key: const ValueKey<String>('ai-thinking-toggle'),
                      borderRadius: AppBorderRadius.small,
                      onTap: () {
                        AppHaptics.selectionClick();
                        setState(() => _expanded = !_expanded);
                      },
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          minHeight: AppSizes.minTouchTarget,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.xxs,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              AppIcon(
                                AppIcons.plans,
                                size: 14,
                                color: colors.textPrimary,
                              ),
                              const SizedBox(width: AppSpacing.xxs),
                              Flexible(
                                child: Text(
                                  label,
                                  key: const ValueKey<String>(
                                    'ai-thinking-label',
                                  ),
                                  style: text.labelMedium?.copyWith(
                                    color: colors.textPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: AppSpacing.xxs),
                              AnimatedRotation(
                                turns: _expanded ? 0.5 : 0,
                                duration: duration,
                                curve: AppMotion.zoomInCurve,
                                child: AppIcon(
                                  AppIcons.expand,
                                  size: 12,
                                  color: colors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_expanded) ...<Widget>[
                  const SizedBox(width: AppSpacing.xs),
                  Tooltip(
                    message: 'Advanced AI settings',
                    child: InkWell(
                      key: const ValueKey<String>('ai-thinking-advanced'),
                      borderRadius: AppBorderRadius.small,
                      onTap: () => showAiAdvancedSettings(context, controller),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.xs,
                          vertical: AppSpacing.xxs,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            AppIcon(
                              AppIcons.settings,
                              size: 13,
                              color: colors.textSecondary,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              'Advanced',
                              style: text.labelSmall?.copyWith(
                                color: colors.textSecondary,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  ],
                ],
              ),
            ),
            if (_expanded)
              Row(
                children: <Widget>[
                  Expanded(
                    child: _ThinkingMeter(
                      effort: routing.effort,
                      onChanged: (AiEffort effort) {
                        controller.setRouting(routing.copyWith(effort: effort));
                      },
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  _AutoButton(
                    selected: routing.effort == AiEffort.auto,
                    onPressed: () {
                      controller.setRouting(
                        routing.copyWith(effort: AiEffort.auto),
                      );
                    },
                  ),
                ],
              ),
          ],
        ),
      ),
    ),
  );
  }
}

/// A scrollable level meter with low, medium, and high thinking effort positions.
class _ThinkingMeter extends StatefulWidget {
  const _ThinkingMeter({
    required this.effort,
    required this.onChanged,
  });

  final AiEffort effort;
  final ValueChanged<AiEffort> onChanged;

  @override
  State<_ThinkingMeter> createState() => _ThinkingMeterState();
}

class _ThinkingMeterState extends State<_ThinkingMeter> {
  static const List<AiEffort> _levels = <AiEffort>[
    AiEffort.low,
    AiEffort.medium,
    AiEffort.high,
  ];

  void _updateDrag(double localX, double width) {
    if (width <= 0) return;
    final double clamped = localX.clamp(0.0, width - 1.0);
    final double fraction = clamped / width;
    final int index =
        (fraction * _levels.length).floor().clamp(0, _levels.length - 1);
    final AiEffort target = _levels[index];
    if (target != widget.effort) {
      AppHaptics.selectionClick();
      widget.onChanged(target);
    }
  }

  void _onScroll(PointerScrollEvent event) {
    final double delta = event.scrollDelta.dx != 0
        ? event.scrollDelta.dx
        : -event.scrollDelta.dy;
    if (delta.abs() < 1) return;

    final int currentIndex = widget.effort == AiEffort.auto
        ? -1
        : _levels.indexOf(widget.effort);

    if (delta > 0) {
      final int nextIndex = currentIndex < 0
          ? 1
          : (currentIndex + 1).clamp(0, _levels.length - 1);
      if (nextIndex != currentIndex || widget.effort == AiEffort.auto) {
        AppHaptics.selectionClick();
        widget.onChanged(_levels[nextIndex]);
      }
    } else {
      final int nextIndex = currentIndex < 0
          ? 0
          : (currentIndex - 1).clamp(0, _levels.length - 1);
      if (nextIndex != currentIndex || widget.effort == AiEffort.auto) {
        AppHaptics.selectionClick();
        widget.onChanged(_levels[nextIndex]);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final Duration duration = AppMotion.resolve(context, AppMotion.fast);
    final int selectedIndex = _levels.indexOf(widget.effort);
    final bool isManual = selectedIndex >= 0;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        return Listener(
          onPointerSignal: (PointerSignalEvent event) {
            if (event is PointerScrollEvent) {
              _onScroll(event);
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (DragStartDetails details) {
              _updateDrag(details.localPosition.dx, width);
            },
            onHorizontalDragUpdate: (DragUpdateDetails details) {
              _updateDrag(details.localPosition.dx, width);
            },
            child: Container(
              key: const ValueKey<String>('ai-thinking-meter'),
              height: 34,
              padding: const EdgeInsets.all(3),
              decoration: ShapeDecoration(
                color: AppGlass.muted(colors),
                shape: const RoundedRectangleBorder(
                  borderRadius: AppBorderRadius.medium,
                ),
              ),
              child: Stack(
                children: <Widget>[
                  if (isManual)
                    AnimatedAlign(
                      duration: duration,
                      curve: AppMotion.zoomInCurve,
                      alignment: Alignment(
                        -1.0 + (selectedIndex * 1.0),
                        0.0,
                      ),
                      child: FractionallySizedBox(
                        widthFactor: 1.0 / _levels.length,
                        heightFactor: 1.0,
                        child: DecoratedBox(
                          decoration: ShapeDecoration(
                            color: colors.surface,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            shadows: <BoxShadow>[
                              BoxShadow(
                                color: colors.shadow.withValues(alpha: 0.10),
                                blurRadius: 3,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  Row(
                    children: <Widget>[
                      for (int i = 0; i < _levels.length; i++)
                        Expanded(
                          child: _MeterSegment(
                            key: ValueKey<String>(
                              'ai-thinking-${_levels[i].name}',
                            ),
                            level: _levels[i],
                            bars: i + 1,
                            selected: _levels[i] == widget.effort,
                            activeBars: isManual ? (selectedIndex >= i) : false,
                            onTap: () {
                              AppHaptics.selectionClick();
                              widget.onChanged(_levels[i]);
                            },
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MeterSegment extends StatelessWidget {
  const _MeterSegment({
    super.key,
    required this.level,
    required this.bars,
    required this.selected,
    required this.activeBars,
    required this.onTap,
  });

  final AiEffort level;
  final int bars;
  final bool selected;
  final bool activeBars;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;

    final Color foreground = selected
        ? colors.textPrimary
        : colors.textSecondary;

    return Semantics(
      container: true,
      button: true,
      selected: selected,
      label: '${level.label} thinking: ${level.description}',
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              _LevelBars(
                totalBars: bars,
                active: selected || activeBars,
                color: selected ? colors.accent : colors.divider,
              ),
              const SizedBox(width: AppSpacing.xxs),
              Flexible(
                child: Text(
                  level.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelMedium?.copyWith(
                    color: foreground,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LevelBars extends StatelessWidget {
  const _LevelBars({
    required this.totalBars,
    required this.active,
    required this.color,
  });

  final int totalBars;
  final bool active;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    const List<double> heights = <double>[4.0, 7.0, 10.0];
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        for (int i = 0; i < 3; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 1.5),
          Container(
            width: 2.5,
            height: heights[i],
            decoration: BoxDecoration(
              color: i < totalBars
                  ? (active ? color : colors.divider)
                  : colors.divider.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ],
      ],
    );
  }
}

class _AutoButton extends StatelessWidget {
  const _AutoButton({
    required this.selected,
    required this.onPressed,
  });

  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final Duration duration = AppMotion.resolve(context, AppMotion.fast);

    final Color background = selected
        ? colors.accent
        : AppGlass.muted(colors);
    final Color foreground = selected
        ? colors.onAccent
        : colors.textPrimary;

    return Semantics(
      button: true,
      selected: selected,
      label: 'Auto thinking level. ${AiEffort.auto.description}',
      excludeSemantics: true,
      child: Tooltip(
        message: 'Auto: ${AiEffort.auto.description}',
        child: AnimatedContainer(
          duration: duration,
          curve: AppMotion.zoomInCurve,
          height: 34,
          child: Material(
            color: background,
            shape: RoundedRectangleBorder(
              borderRadius: AppBorderRadius.medium,
              side: selected
                  ? BorderSide.none
                  : BorderSide(color: colors.divider.withValues(alpha: 0.6)),
            ),
            elevation: selected ? 1 : 0,
            shadowColor: colors.shadow.withValues(alpha: 0.15),
            child: InkWell(
              key: const ValueKey<String>('ai-thinking-auto'),
              borderRadius: AppBorderRadius.medium,
              onTap: () {
                AppHaptics.selectionClick();
                onPressed();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: AppSpacing.xxs,
                ),
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (selected) ...<Widget>[
                        AppIcon(
                          AppIcons.check,
                          size: 13,
                          color: foreground,
                        ),
                        const SizedBox(width: AppSpacing.xxs),
                      ],
                      Text(
                        'Auto',
                        style: text.labelMedium?.copyWith(
                          color: foreground,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                    ],
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
