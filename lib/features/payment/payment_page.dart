import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme/app_icons.dart';
import '../../app/theme/app_tokens.dart';
import '../../shared/widgets/app_controls.dart';
import '../../shared/widgets/processing.dart';
import '../editor/ai/ai_client.dart';
import 'payment_models.dart';
import 'store_page_shell.dart';
import 'subscription_controller.dart';

/// Opens [PaymentPage] as a full screen over the current one.
Future<void> showPaymentPage(
  BuildContext context,
  SubscriptionController controller,
) {
  unawaited(controller.backend?.trackProductEvent('paywall_viewed'));
  return showStorePage(context, PaymentPage(controller: controller));
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
    return StorePageShell(
      title: PaymentPage.title,
      closeKey: const ValueKey<String>('payment-page-close'),
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (BuildContext context, Widget? _) {
          final SubscriptionController controller = widget.controller;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const _PricingHero(),
              PlansSection(controller: controller),
              const SizedBox(height: AppSpacing.xl),
              Semantics(
                header: true,
                child: Text(
                  'Your credits',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              CreditMeter(controller: controller),
              if (controller.backend?.userId != null)
                GiftCodeCard(controller: controller),
            ],
          );
        },
      ),
    );
  }
}

/// The billing cycle toggle, the store's progress and messages, every plan
/// side by side (stacked when narrow) and what billing means. Shown on the
/// plans page and in the account's subscription tab.
class PlansSection extends StatefulWidget {
  const PlansSection({super.key, required this.controller});

  final SubscriptionController controller;

  @override
  State<PlansSection> createState() => _PlansSectionState();
}

class _PlansSectionState extends State<PlansSection> {
  BillingCycle _selectedCycle = BillingCycle.monthly;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, Widget? _) {
        final SubscriptionController controller = widget.controller;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: SegmentedChoice<BillingCycle>(
                  key: const ValueKey<String>('billing-cycle-toggle'),
                  options: BillingCycle.values,
                  selected: _selectedCycle,
                  keyOf: (BillingCycle cycle) =>
                      ValueKey<String>('billing-cycle-${cycle.name}'),
                  labelOf: (BillingCycle cycle) => switch (cycle) {
                    BillingCycle.monthly => 'Monthly',
                    BillingCycle.yearly => 'Yearly · Save 17%',
                  },
                  onSelected: (BillingCycle cycle) {
                    setState(() {
                      _selectedCycle = cycle;
                    });
                  },
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            // Rises into place when the store is asked.
            GentleSwitcher(
              value: controller.activity == StoreActivity.idle,
              child: controller.activity == StoreActivity.idle
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: StoreProgress(activity: controller.activity),
                    ),
            ),
            if (controller.errorMessage case final String error) ...<Widget>[
              StoreBanner(
                key: const ValueKey<String>('payment-error'),
                message: error,
                isError: true,
              ),
              const SizedBox(height: AppSpacing.sm),
            ] else if (controller.notice case final String notice) ...<Widget>[
              StoreBanner(message: notice),
              const SizedBox(height: AppSpacing.sm),
            ],
            if (controller.storeAvailable == false) ...<Widget>[
              const StoreBanner(
                message:
                    'The store is not available right now. Plans can '
                    'be bought once it is.',
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints box) {
                final bool wide = box.maxWidth >= PaymentPage.columnsFrom;
                final List<Widget> cards = <Widget>[
                  for (final SubscriptionPlan plan in SubscriptionPlan.values)
                    _PlanCard(
                      plan: plan,
                      controller: controller,
                      cycle: _selectedCycle,
                      fillHeight: wide,
                    ),
                ];
                if (!wide) {
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
                      for (int i = 0; i < cards.length; i++) ...<Widget>[
                        if (i > 0) const SizedBox(width: AppSpacing.md),
                        Expanded(child: cards[i]),
                      ],
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Plans renew ${_selectedCycle == BillingCycle.yearly ? 'yearly' : 'monthly'} and are billed by '
              '${_storeName(context)}. Tokens are granted in full '
              'with each renewal and are used only by metered '
              'models; Haiku and Luna never use them.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
              textAlign: TextAlign.center,
            ),
          ],
        );
      },
    );
  }

  static String _storeName(BuildContext context) {
    final TargetPlatform platform = Theme.of(context).platform;
    return platform == TargetPlatform.iOS || platform == TargetPlatform.macOS
        ? 'the App Store'
        : 'Google Play';
  }
}

class _PricingHero extends StatelessWidget {
  const _PricingHero();

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.lg, bottom: AppSpacing.lg),
      child: Column(
        children: <Widget>[
          Semantics(
            header: true,
            child: Text(
              'Choose the space you need to think bigger.',
              style: text.displayMedium?.copyWith(
                color: colors.textPrimary,
                fontWeight: FontWeight.w800,
                height: 1.08,
                letterSpacing: -1,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Text(
              'Every plan includes unlimited fast AI. Upgrade for more '
              'frontier models and a larger monthly token pool.',
              style: text.bodyLarge?.copyWith(color: colors.textSecondary),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

/// The active plan, the tokens left of its allowance, and Restore.
class CreditMeter extends StatelessWidget {
  const CreditMeter({
    super.key,
    required this.controller,
    this.showRestore = true,
  });

  final SubscriptionController controller;

  /// Whether the Restore Purchases button is offered beside the plan.
  final bool showRestore;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final SubscriptionPlan? plan = controller.activePlan;
    final int included = controller.includedCreditsMicroUsd;
    final int remaining = controller.remainingCreditsMicroUsd;
    final double fraction = controller.tokenFraction;
    final String tokens = formatTokenPercent(remaining, included);
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
              if (showRestore)
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
                  'AI tokens',
                  style: text.bodyMedium?.copyWith(color: colors.textPrimary),
                ),
              ),
              Text(
                tokens,
                key: const ValueKey<String>('payment-credit-balance'),
                style: text.titleMedium?.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          TokenMeterBar(
            key: const ValueKey<String>('payment-token-bar'),
            fraction: fraction,
            height: 14,
            semanticsLabel: 'AI tokens remaining',
            semanticsValue: tokens,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            controller.hasFreeCredit
                ? 'Free tokens for Haiku, Luna, Sonnet & Sol${_freeEnds(controller)}. '
                      'Haiku and Luna are unlimited on every paid plan.'
                : 'Haiku and Luna are unlimited on every paid plan.',
            style: text.bodySmall?.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// ", expires Nov 23" for the free credit, or nothing when the end is unknown.
String _freeEnds(SubscriptionController controller) {
  final DateTime? ends = controller.freeCreditExpiresAt?.toLocal();
  if (ends == null) return ' (valid for one month)';
  const List<String> months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final String date = '${months[ends.month - 1]} ${ends.day}';
  return ends.isAfter(DateTime.now()) ? ', expire $date' : ', expired $date';
}

/// Where a gift code is entered to claim its free credit.
class GiftCodeCard extends StatefulWidget {
  const GiftCodeCard({super.key, required this.controller});

  final SubscriptionController controller;

  @override
  State<GiftCodeCard> createState() => _GiftCodeCardState();
}

class _GiftCodeCardState extends State<GiftCodeCard> {
  final TextEditingController _code = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _redeem() async {
    if (_busy || _code.text.trim().isEmpty) return;
    setState(() => _busy = true);
    await widget.controller.redeemGiftCode(_code.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (widget.controller.errorMessage == null) _code.clear();
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: _Card(
        key: const ValueKey<String>('gift-code-card'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Gift code',
              style: text.labelLarge?.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.xxs),
            Text(
              'Enter a gift code to claim \$3 of free credit. Free credit '
              'lasts one month.',
              style: text.bodySmall?.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const ValueKey<String>('gift-code-field'),
                    controller: _code,
                    enabled: !_busy,
                    textCapitalization: TextCapitalization.characters,
                    autocorrect: false,
                    enableSuggestions: false,
                    maxLength: 64,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (String _) => _redeem(),
                    decoration: const InputDecoration(
                      hintText: 'Gift code',
                      counterText: '',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                FilledButton(
                  key: const ValueKey<String>('gift-code-redeem'),
                  onPressed: _busy ? null : _redeem,
                  style: FilledButton.styleFrom(
                    backgroundColor: colors.accent,
                    foregroundColor: colors.onAccent,
                    disabledBackgroundColor: colors.surfaceMuted,
                    disabledForegroundColor: colors.textPrimary,
                    minimumSize: const Size(
                      AppSizes.minTouchTarget,
                      AppSizes.minTouchTarget,
                    ),
                  ),
                  child: Text(_busy ? 'Redeeming…' : 'Redeem'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.controller,
    required this.cycle,
    required this.fillHeight,
  });

  final SubscriptionPlan plan;
  final SubscriptionController controller;
  final BillingCycle cycle;

  /// Whether the card stretches to its neighbours' height, its button at
  /// the bottom.
  final bool fillHeight;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final SubscriptionPlan? active = controller.activePlan;
    final bool current = plan == active;
    final bool recommended = plan == SubscriptionPlan.pro1499;
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
    // The recommended plan is drawn in ink: the card is the accent and its
    // contents the paper colour.
    final Color fg = recommended ? colors.onAccent : colors.textPrimary;
    final Color muted = recommended
        ? colors.onAccent.withValues(alpha: 0.72)
        : colors.textSecondary;
    final String price = controller.priceFor(plan, cycle: cycle);
    final int slash = price.indexOf(' / ');
    return Semantics(
      container: true,
      label: recommended ? '${plan.title} plan, Recommended' : null,
      child: _Card(
        key: ValueKey<String>('plan-${plan.name}'),
        highlighted: current,
        inverted: recommended,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      plan.title,
                      style: text.titleLarge?.copyWith(
                        color: fg,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                if (recommended)
                  const _Badge(
                    key: ValueKey<String>('pro-recommended'),
                    label: 'Recommended',
                    tone: _BadgeTone.onInk,
                  )
                else if (current)
                  const _Badge(label: 'Active'),
              ],
            ),
            if (recommended && current) ...<Widget>[
              const SizedBox(height: AppSpacing.xs),
              const _Badge(label: 'Active', tone: _BadgeTone.onInk),
            ],
            const SizedBox(height: AppSpacing.sm),
            GentleSwitcher(
              value: price,
              alignment: Alignment.centerLeft,
              child: Text.rich(
                TextSpan(
                  children: <InlineSpan>[
                    TextSpan(
                      text: slash < 0 ? price : price.substring(0, slash),
                      style: text.displaySmall?.copyWith(
                        color: fg,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.8,
                      ),
                    ),
                    if (slash >= 0)
                      TextSpan(
                        text: price.substring(slash),
                        style: text.titleSmall?.copyWith(color: muted),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            _Feature(text: 'Unlimited Haiku & Luna', color: fg),
            const SizedBox(height: AppSpacing.xs),
            _Feature(text: plan.creditDescription, color: fg),
            const SizedBox(height: AppSpacing.xs),
            _Feature(
              text: plan.tokenComparisonText,
              textKey: ValueKey<String>('plan-token-comparison-${plan.name}'),
              color: fg,
              dim: muted,
              secondary: true,
            ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.xxs,
              runSpacing: AppSpacing.xxs,
              children: <Widget>[
                for (final AiModelId model in AiModelId.values)
                  _ModelChip(
                    model: model,
                    included: plan.includes(model),
                    unlimited: plan.unlimitedModels.contains(model),
                    color: fg,
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            if (fillHeight) const Spacer(),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: current || busy
                    ? null
                    : () => controller.purchase(plan, cycle: cycle),
                style: FilledButton.styleFrom(
                  backgroundColor: recommended
                      ? colors.onAccent
                      : colors.accent,
                  foregroundColor: recommended
                      ? colors.accent
                      : colors.onAccent,
                  disabledBackgroundColor: recommended
                      ? colors.onAccent.withValues(alpha: 0.18)
                      : colors.surfaceMuted,
                  disabledForegroundColor: recommended
                      ? colors.onAccent
                      : colors.textPrimary,
                  elevation: 0,
                  minimumSize: const Size(
                    AppSizes.minTouchTarget,
                    AppSizes.minTouchTarget,
                  ),
                ),
                child: Text(action, semanticsLabel: '$action, ${plan.title}'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One line of what a plan gives, led by a check.
class _Feature extends StatelessWidget {
  const _Feature({
    required this.text,
    required this.color,
    this.dim,
    this.textKey,
    this.secondary = false,
  });

  final String text;
  final Color color;
  final Color? dim;
  final Key? textKey;

  /// Set in the quieter colour: a detail of the line above.
  final bool secondary;

  @override
  Widget build(BuildContext context) {
    final TextTheme theme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(AppIcons.check, size: 16, color: color),
        ),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Text(
            text,
            key: textKey,
            style: theme.bodyMedium?.copyWith(
              color: secondary ? dim : color,
              fontWeight: secondary ? FontWeight.w400 : FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// A model and what the plan gives of it.
class _ModelChip extends StatelessWidget {
  const _ModelChip({
    required this.model,
    required this.included,
    required this.unlimited,
    required this.color,
  });

  final AiModelId model;
  final bool included;
  final bool unlimited;
  final Color color;

  @override
  Widget build(BuildContext context) {
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
          color: included ? color.withValues(alpha: 0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: color.withValues(alpha: included ? 0 : 0.28),
            width: AppSizes.hairline,
          ),
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
                size: 13,
                color: included ? color : color.withValues(alpha: 0.6),
              ),
              const SizedBox(width: AppSpacing.xxs),
              Flexible(
                child: Text(
                  '${model.label} · $detail',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: included ? color : color.withValues(alpha: 0.6),
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

/// How a [_Badge] is filled: quietly, in the accent, or in the paper colour
/// on an ink card.
enum _BadgeTone { soft, onInk }

class _Badge extends StatelessWidget {
  const _Badge({super.key, required this.label, this.tone = _BadgeTone.soft});

  final String label;
  final _BadgeTone tone;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final bool onInk = tone == _BadgeTone.onInk;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: onInk ? colors.onAccent : colors.selected,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xxs,
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: onInk ? colors.accent : colors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
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
    this.inverted = false,
  });

  final Widget child;

  /// The card of the plan the user is on: ringed in the accent.
  final bool highlighted;

  /// Drawn in ink, the accent as its fill: the recommended plan.
  final bool inverted;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    const BorderRadius radius = AppBorderRadius.xl;
    final Border border = Border.all(
      color: highlighted
          ? colors.accent
          : inverted
          ? Colors.transparent
          : colors.glassEdge,
      width: highlighted ? 2 : AppSizes.hairline,
    );
    final Widget padded = Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: inverted ? colors.accent : AppGlass.surface(colors),
        borderRadius: radius,
        border: border,
      ),
      child: child,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: inverted
            ? AppShadows.raised(colors)
            : AppShadows.paper(colors),
      ),
      child: inverted ? padded : GlassBlur(borderRadius: radius, child: padded),
    );
  }
}

class StoreProgress extends StatelessWidget {
  const StoreProgress({super.key, required this.activity});

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
          // What the store is doing, breathing until it answers.
          Breathe(
            child: GentleSwitcher(
              value: label,
              child: Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: colors.textPrimary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class StoreBanner extends StatelessWidget {
  const StoreBanner({super.key, required this.message, this.isError = false});

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
          borderRadius: AppBorderRadius.medium,
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
