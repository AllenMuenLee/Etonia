import 'package:flutter/material.dart';

import '../../app/theme/app_icons.dart';
import '../../app/theme/app_tokens.dart';
import 'payment_models.dart';
import 'subscription_controller.dart';

/// The Plans & Credits pill in the library's top bar: the credits left on
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
          ? 'Free · ${formatUsd(controller.remainingCreditsMicroUsd)}'
          : 'Plans';
    }
    if (controller.remainingCreditsMicroUsd <= 0) {
      return '${plan.title} · Upgrade';
    }
    return '${plan.title} · ${formatUsd(controller.remainingCreditsMicroUsd)}';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final AppColors colors = AppColors.of(context);
        final String label = labelFor(controller);
        if (compact) {
          return IconButton(
            key: const ValueKey<String>('library-plans-button'),
            tooltip: 'Plans & Credits',
            onPressed: onPressed,
            icon: Semantics(label: label, child: const Icon(AppIcons.plans)),
          );
        }
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
                    decoration: ShapeDecoration(
                      shape: const StadiumBorder(),
                      color: AppGlass.muted(colors),
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
