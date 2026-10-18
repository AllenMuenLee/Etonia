import 'package:flutter/material.dart';

import '../../app/theme/app_icons.dart';
import '../../app/theme/app_tokens.dart';
import '../editor/ai/ai_client.dart';
import 'payment_models.dart';
import 'subscription_controller.dart';
import 'account_panel.dart';

/// Opens [PaymentPage] over the current screen.
Future<void> showPaymentPage(
  BuildContext context,
  SubscriptionController controller,
) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => PaymentPage(controller: controller),
    ),
  );
}

/// The plans, what each includes, the user's current plan and credits, and
/// buying or restoring through the platform store.
class PaymentPage extends StatefulWidget {
  const PaymentPage({super.key, required this.controller});

  static const String title = 'Plans & Credits';

  /// Plan cards sit side by side from this width; below it they stack.
  static const double columnsFrom = 720;

  final SubscriptionController controller;

  @override
  State<PaymentPage> createState() => _PaymentPageState();
}

class _PaymentPageState extends State<PaymentPage> {
  @override
  void initState() {
    super.initState();
    if (widget.controller.storeAvailable == null) {
      // After this frame: the controller's listeners may be building now.
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (mounted) {
          widget.controller.connectStore();
          widget.controller.refresh();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text(PaymentPage.title),
        backgroundColor: AppGlass.background(colors).withValues(alpha: 0.76),
        foregroundColor: colors.textPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        flexibleSpace: GlassBlur(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: colors.glassEdge,
                  width: AppSizes.hairline,
                ),
              ),
            ),
          ),
        ),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          const _PricingAtmosphere(),
          ListenableBuilder(
            listenable: widget.controller,
            builder: (BuildContext context, Widget? _) {
              final SubscriptionController controller = widget.controller;
              return SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: AppSizes.maxContentWidth,
                    ),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.md,
                        AppSpacing.lg,
                        AppSpacing.md,
                        AppSpacing.xl,
                      ),
                      children: <Widget>[
                        const _PricingHero(),
                        if (controller.backend case final backend?)
                          AccountPanel(
                            backend: backend,
                            controller: controller,
                          ),
                        _CreditMeter(controller: controller),
                        if (controller.backend != null)
                          Padding(
                            padding: const EdgeInsets.only(top: AppSpacing.sm),
                            child: Text(
                              'AI forwards only your current question and selected image. '
                              'Notes, PDFs, and chat history are not uploaded or stored in your account.',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: colors.textSecondary),
                            ),
                          ),
                        if (controller.activity !=
                            StoreActivity.idle) ...<Widget>[
                          const SizedBox(height: AppSpacing.sm),
                          _StoreProgress(activity: controller.activity),
                        ],
                        if (controller.errorMessage
                            case final String error) ...[
                          const SizedBox(height: AppSpacing.sm),
                          _Banner(
                            key: const ValueKey<String>('payment-error'),
                            message: error,
                            isError: true,
                          ),
                        ] else if (controller.notice
                            case final String notice) ...[
                          const SizedBox(height: AppSpacing.sm),
                          _Banner(message: notice),
                        ],
                        if (controller.storeAvailable == false) ...<Widget>[
                          const SizedBox(height: AppSpacing.sm),
                          const _Banner(
                            message:
                                'The store is not available right now. Plans can '
                                'be bought once it is.',
                          ),
                        ],
                        const SizedBox(height: AppSpacing.lg),
                        LayoutBuilder(
                          builder: (BuildContext context, BoxConstraints box) {
                            final List<Widget> cards = <Widget>[
                              for (final SubscriptionPlan plan
                                  in SubscriptionPlan.values)
                                _PlanCard(
                                  plan: plan,
                                  controller: controller,
                                  fillHeight:
                                      box.maxWidth >= PaymentPage.columnsFrom,
                                ),
                            ];
                            if (box.maxWidth < PaymentPage.columnsFrom) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: <Widget>[
                                  for (final Widget card in cards) ...<Widget>[
                                    card,
                                    const SizedBox(height: AppSpacing.md),
                                  ],
                                ],
                              );
                            }
                            return IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: <Widget>[
                                  for (int i = 0; i < cards.length; i++) ...[
                                    if (i > 0)
                                      const SizedBox(width: AppSpacing.md),
                                    Expanded(child: cards[i]),
                                  ],
                                ],
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          'Plans renew monthly and are billed by '
                          '${_storeName(context)}. Credits are granted in full '
                          'with each renewal and are used only by metered '
                          'models; Haiku and Luna never use them.',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.textSecondary),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  static String _storeName(BuildContext context) {
    final TargetPlatform platform = Theme.of(context).platform;
    return platform == TargetPlatform.iOS || platform == TargetPlatform.macOS
        ? 'the App Store'
        : 'Google Play';
  }
}

/// Soft pools of colored light give the translucent cards something to frost.
class _PricingAtmosphere extends StatelessWidget {
  const _PricingAtmosphere();

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  colors.accent.withValues(alpha: dark ? 0.12 : 0.08),
                  colors.background.withValues(alpha: 0.18),
                  colors.selected.withValues(alpha: dark ? 0.30 : 0.58),
                ],
                stops: const <double>[0, 0.52, 1],
              ),
            ),
          ),
          Positioned(
            top: -190,
            right: -110,
            width: 520,
            height: 520,
            child: _LightBloom(
              color: colors.accent.withValues(alpha: dark ? 0.22 : 0.15),
            ),
          ),
          Positioned(
            top: 250,
            left: -220,
            width: 500,
            height: 500,
            child: _LightBloom(
              color: colors.selected.withValues(alpha: dark ? 0.42 : 0.70),
            ),
          ),
        ],
      ),
    );
  }
}

class _LightBloom extends StatelessWidget {
  const _LightBloom({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: <Color>[color, color.withValues(alpha: 0)],
          stops: const <double>[0, 1],
        ),
      ),
    );
  }
}

class _PricingHero extends StatelessWidget {
  const _PricingHero();

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.lg),
      child: Column(
        children: <Widget>[
          const _Badge(
            label: 'Flexible plans, unlimited essentials',
            leading: AppIcons.plans,
          ),
          const SizedBox(height: AppSpacing.sm),
          Semantics(
            header: true,
            child: Text(
              'Choose the space you need to think bigger.',
              style: text.displaySmall?.copyWith(
                color: colors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Text(
              'Every plan includes unlimited fast AI. Upgrade for more '
              'frontier models and a larger monthly credit pool.',
              style: text.bodyLarge?.copyWith(color: colors.textSecondary),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

/// The active plan, the credits left of its allowance, and Restore.
class _CreditMeter extends StatelessWidget {
  const _CreditMeter({required this.controller});

  final SubscriptionController controller;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final SubscriptionPlan? plan = controller.activePlan;
    final int included = controller.includedCreditsMicroUsd;
    final int remaining = controller.remainingCreditsMicroUsd;
    final double fraction = included == 0
        ? 0
        : (remaining / included).clamp(0, 1).toDouble();
    final String credits = '${formatUsd(remaining)} / ${formatUsd(included)}';
    return _Card(
      key: const ValueKey<String>('payment-credit-meter'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: <Widget>[
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    'Current subscription',
                    style: text.labelLarge?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  Semantics(
                    header: true,
                    child: Text(
                      plan == null
                          ? (controller.hasFreeCredit ? 'Free' : 'No plan')
                          : '${plan.title} · ${controller.priceFor(plan)}',
                      style: text.titleLarge?.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              OutlinedButton.icon(
                onPressed: controller.activity == StoreActivity.idle
                    ? controller.restorePurchases
                    : null,
                icon: const Icon(AppIcons.restore, size: 18),
                label: const Text('Restore Purchases'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: colors.textPrimary,
                  side: BorderSide(color: colors.divider),
                  minimumSize: const Size(
                    AppSizes.minTouchTarget,
                    AppSizes.minTouchTarget,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'AI credits',
                  style: text.bodyMedium?.copyWith(color: colors.textPrimary),
                ),
              ),
              Text(
                credits,
                key: const ValueKey<String>('payment-credit-balance'),
                style: text.titleMedium?.copyWith(
                  color: colors.textPrimary,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Semantics(
            label: 'AI credits remaining',
            value: credits,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.small),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 8,
                color: colors.accent,
                backgroundColor: colors.surfaceMuted,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            controller.hasFreeCredit
                ? 'One-time free credit for Haiku, Luna, Sonnet & Sol. '
                      'Haiku and Luna are unlimited on every paid plan.'
                : 'Haiku and Luna are unlimited on every paid plan.',
            style: text.bodySmall?.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.controller,
    required this.fillHeight,
  });

  final SubscriptionPlan plan;
  final SubscriptionController controller;

  /// Whether the card stretches to its neighbours' height, its button at
  /// the bottom.
  final bool fillHeight;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final SubscriptionPlan? active = controller.activePlan;
    final bool current = plan == active;
    final bool recommended = plan == SubscriptionPlan.pro1299;
    final bool busy = controller.activity != StoreActivity.idle;
    final bool buying =
        controller.activity == StoreActivity.purchasing &&
        controller.pendingPlan == plan;
    final String action = buying
        ? 'Purchasing…'
        : current
        ? 'Current Plan'
        : active == null
        ? 'Subscribe'
        : plan.index > active.index
        ? 'Upgrade'
        : 'Switch Plan';
    return Semantics(
      container: true,
      label: recommended ? '${plan.title} plan, Recommended' : null,
      child: _Card(
        key: ValueKey<String>('plan-${plan.name}'),
        highlighted: current,
        emphasized: recommended,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      plan.title,
                      style: text.titleLarge?.copyWith(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                if (recommended)
                  const _Badge(
                    key: ValueKey<String>('pro-recommended'),
                    label: 'Recommended',
                    leading: AppIcons.plans,
                    strong: true,
                  )
                else if (current)
                  const _Badge(label: 'Active'),
              ],
            ),
            if (recommended && current) ...<Widget>[
              const SizedBox(height: AppSpacing.xs),
              const _Badge(label: 'Active'),
            ],
            const SizedBox(height: AppSpacing.xxs),
            Text(
              controller.priceFor(plan),
              style: text.headlineSmall?.copyWith(
                color: colors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            const _Badge(
              label: 'Unlimited Haiku & Luna',
              leading: AppIcons.check,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              plan.creditDescription,
              style: text.bodyMedium?.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.xxs,
              runSpacing: AppSpacing.xxs,
              children: <Widget>[
                for (final AiModelId model in AiModelId.values)
                  _ModelChip(
                    model: model,
                    included: plan.includes(model),
                    unlimited: plan.unlimitedModels.contains(model),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            if (fillHeight) const Spacer(),
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadii.medium),
                boxShadow: recommended && !current
                    ? <BoxShadow>[
                        BoxShadow(
                          color: colors.accent.withValues(alpha: 0.24),
                          blurRadius: 18,
                          spreadRadius: -6,
                          offset: const Offset(0, 8),
                        ),
                      ]
                    : const <BoxShadow>[],
              ),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: current || busy
                      ? null
                      : () => controller.purchase(plan),
                  style: FilledButton.styleFrom(
                    backgroundColor: colors.accent,
                    foregroundColor: colors.onAccent,
                    disabledBackgroundColor: colors.surfaceMuted,
                    disabledForegroundColor: colors.textPrimary,
                    elevation: 0,
                    minimumSize: const Size(
                      AppSizes.minTouchTarget,
                      AppSizes.minTouchTarget,
                    ),
                  ),
                  child: Text(action, semanticsLabel: '$action, ${plan.title}'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A model and what the plan gives of it.
class _ModelChip extends StatelessWidget {
  const _ModelChip({
    required this.model,
    required this.included,
    required this.unlimited,
  });

  final AiModelId model;
  final bool included;
  final bool unlimited;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final String detail = unlimited
        ? 'Unlimited'
        : included
        ? 'Credits'
        : 'Locked';
    return Semantics(
      label: '${model.label}, $detail',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: included ? colors.surfaceMuted : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadii.medium),
          border: Border.all(color: colors.divider),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xs,
            vertical: AppSpacing.xxs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                included ? AppIcons.check : AppIcons.lock,
                size: 14,
                color: colors.textPrimary,
              ),
              const SizedBox(width: AppSpacing.xxs),
              Flexible(
                child: Text(
                  '${model.label} · $detail',
                  style: Theme.of(
                    context,
                  ).textTheme.labelMedium?.copyWith(color: colors.textPrimary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    super.key,
    required this.label,
    this.leading,
    this.strong = false,
  });

  final String label;
  final IconData? leading;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: strong ? colors.accent : colors.selected,
        borderRadius: BorderRadius.circular(AppRadii.xl),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xxs,
        ),
        child: Wrap(
          spacing: AppSpacing.xxs,
          runSpacing: AppSpacing.xxs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            if (leading != null)
              Icon(
                leading,
                size: 14,
                color: strong ? colors.onAccent : colors.textPrimary,
              ),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: strong ? colors.onAccent : colors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    super.key,
    required this.child,
    this.highlighted = false,
    this.emphasized = false,
  });

  final Widget child;
  final bool highlighted;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final BorderRadius radius = BorderRadius.circular(AppRadii.xl);
    final Color glass = AppGlass.surface(colors);
    final Color litGlass = Color.alphaBlend(
      colors.accent.withValues(alpha: emphasized ? 0.13 : 0.035),
      glass,
    );
    final List<BoxShadow> shadows = <BoxShadow>[
      ...(emphasized ? AppShadows.raised(colors) : AppShadows.paper(colors)),
      if (emphasized)
        BoxShadow(
          color: colors.accent.withValues(alpha: 0.18),
          blurRadius: 36,
          spreadRadius: -12,
          offset: const Offset(0, 16),
        ),
    ];
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: radius, boxShadow: shadows),
      child: GlassBlur(
        borderRadius: radius,
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[
                Color.alphaBlend(
                  Colors.white.withValues(
                    alpha: Theme.of(context).brightness == Brightness.dark
                        ? 0.035
                        : 0.26,
                  ),
                  litGlass,
                ),
                litGlass,
                glass,
              ],
              stops: const <double>[0, 0.38, 1],
            ),
            borderRadius: radius,
            border: Border.all(
              color: highlighted || emphasized
                  ? colors.accent.withValues(alpha: highlighted ? 0.96 : 0.68)
                  : colors.glassEdge,
              width: highlighted
                  ? 2
                  : emphasized
                  ? 1.5
                  : AppSizes.hairline,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _StoreProgress extends StatelessWidget {
  const _StoreProgress({required this.activity});

  final StoreActivity activity;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final String label = switch (activity) {
      StoreActivity.loading => 'Loading plans from the store…',
      StoreActivity.purchasing => 'Waiting for the store to confirm…',
      StoreActivity.restoring => 'Restoring purchases…',
      StoreActivity.idle => '',
    };
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: AppSpacing.xxs),
          LinearProgressIndicator(
            color: colors.accent,
            backgroundColor: colors.surfaceMuted,
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.message, this.isError = false});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: isError
              ? Color.alphaBlend(
                  colors.danger.withValues(alpha: 0.10),
                  colors.surface,
                )
              : colors.surfaceMuted,
          borderRadius: BorderRadius.circular(AppRadii.medium),
          border: Border.all(
            color: isError ? colors.danger : colors.divider,
            width: AppSizes.hairline,
          ),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              isError ? AppIcons.warning : AppIcons.check,
              size: 18,
              color: isError ? colors.danger : colors.textPrimary,
            ),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Text(
                message,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: colors.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
