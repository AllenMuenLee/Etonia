import 'package:flutter/material.dart';

import '../../app/theme/app_icons.dart';
import '../../app/theme/app_tokens.dart';
import '../../shared/widgets/app_controls.dart';
import 'payment_models.dart';
import 'subscription_controller.dart';

/// The Plans & Credits pill in the library's top bar: the tokens left on
/// the active plan, or what to do without one. Opens [onPressed].
class PlansButton extends StatelessWidget {
  const PlansButton({
    super.key,
    required this.controller,
    required this.onPressed,
    this.compact = false,
  });

  final SubscriptionController controller;
  final VoidCallback onPressed;

  /// Just the icon, where the bar has no room for the words.
  final bool compact;

  /// What the pill says for [controller] as it stands.
  static String labelFor(SubscriptionController controller) {
    final SubscriptionPlan? plan = controller.activePlan;
    if (plan == null) {
      return controller.hasFreeCredit && controller.remainingCreditsMicroUsd > 0
          ? 'Free · ${formatTokenPercent(controller.remainingCreditsMicroUsd, controller.includedCreditsMicroUsd)}'
          : 'Plans';
    }
    if (controller.remainingCreditsMicroUsd <= 0) {
      return '${plan.title} · Upgrade';
    }
    return '${plan.title} · ${formatTokenPercent(controller.remainingCreditsMicroUsd, controller.includedCreditsMicroUsd)}';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final AppColors colors = AppColors.of(context);
        final bool dark = Theme.of(context).brightness == Brightness.dark;
        final String label = labelFor(controller);
        final bool hasTokens =
            (controller.activePlan != null || controller.hasFreeCredit) &&
            controller.remainingCreditsMicroUsd > 0;
        if (compact) {
          return IconButton(
            key: const ValueKey<String>('library-plans-button'),
            tooltip: 'Plans & Credits',
            onPressed: onPressed,
            icon: Semantics(label: label, child: const Icon(AppIcons.plans)),
          );
        }
        final Color baseSurface = AppGlass.muted(colors);
        return Tooltip(
          message: 'Plans & Credits',
          child: Semantics(
            button: true,
            label: 'Plans & Credits, $label',
            excludeSemantics: true,
            child: InkWell(
              key: const ValueKey<String>('library-plans-button'),
              onTap: onPressed,
              customBorder: const StadiumBorder(),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minWidth: AppSizes.minTouchTarget,
                  minHeight: AppSizes.minTouchTarget,
                ),
                child: Center(
                  widthFactor: 1,
                  child: DecoratedBox(
                    decoration: hasTokens
                        ? BoxDecoration(
                            borderRadius: BorderRadius.circular(999),
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: <Color>[
                                Color.alphaBlend(
                                  Colors.white.withValues(
                                    alpha: dark ? 0.08 : 0.55,
                                  ),
                                  baseSurface,
                                ),
                                baseSurface,
                                Color.alphaBlend(
                                  colors.shadow.withValues(
                                    alpha: dark ? 0.18 : 0.05,
                                  ),
                                  baseSurface,
                                ),
                              ],
                              stops: const <double>[0.0, 0.52, 1.0],
                            ),
                            border: Border.all(
                              color: colors.glassEdge,
                              width: AppSizes.hairline,
                            ),
                            boxShadow: <BoxShadow>[
                              BoxShadow(
                                color: colors.shadow.withValues(alpha: 0.07),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          )
                        : ShapeDecoration(
                            shape: const StadiumBorder(),
                            color: baseSurface,
                          ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: AppSpacing.xxs + 2,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            AppIcons.plans,
                            size: 16,
                            color: colors.textPrimary,
                          ),
                          const SizedBox(width: AppSpacing.xxs),
                          Text(
                            label,
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(color: colors.textPrimary),
                          ),
                          if (hasTokens) ...<Widget>[
                            const SizedBox(width: AppSpacing.xs),
                            TokenMeterBar(
                              key: const ValueKey<String>('library-token-bar'),
                              fraction: controller.tokenFraction,
                              width: 36,
                              height: 7,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
