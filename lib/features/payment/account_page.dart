import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import '../../shared/widgets/app_controls.dart';
import 'account_panel.dart';
import 'billing_backend.dart';
import 'payment_page.dart';
import 'store_page_shell.dart';
import 'subscription_controller.dart';

/// Opens [AccountPage] as a full screen over the current one. [backup] is
/// the backup section's content, which the screen that owns the library
/// supplies; without it the section says backup is not available.
Future<void> showAccountPage(
  BuildContext context,
  SubscriptionController controller, {
  Widget? backup,
  bool openPlans = false,
}) {
  return showStorePage(
    context,
    AccountPage(controller: controller, backup: backup, openPlans: openPlans),
  );
}

/// Everything about the account in one place: who is signed in, the
/// subscription and its credits, and backing up to the cloud.
class AccountPage extends StatefulWidget {
  const AccountPage({
    super.key,
    required this.controller,
    this.backup,
    this.openPlans = false,
  });

  static const String title = 'Account';

  final SubscriptionController controller;
  final Widget? backup;

  /// Opens on the subscription tab, the plans, instead of the profile.
  final bool openPlans;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

/// The sections of [AccountPage], one tab each.
enum _AccountTab {
  profile('Profile'),
  subscription('Subscription'),
  backup('Backup');

  const _AccountTab(this.label);

  final String label;
}

class _AccountPageState extends State<AccountPage> {
  late _AccountTab _tab = widget.openPlans
      ? _AccountTab.subscription
      : _AccountTab.profile;
  final ScrollController _scroll = ScrollController();

  /// The tabs built so far. The one shown is built at once; the others
  /// once the page has finished coming in, so laying them out (the plans,
  /// the backup sheet) costs no frame of the move. Built, they are kept.
  late final Set<_AccountTab> _built = <_AccountTab>{_tab};

  /// The move bringing the page in, while it is under way.
  Animation<double>? _arrival;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_built.length == _AccountTab.values.length) return;
    final ModalRoute<Object?>? route = ModalRoute.of(context);
    final Animation<double>? animation = route?.animation;
    // Offstage, on its first frame while heroes are measured, a route's
    // animation reads complete before the move has begun.
    if (animation == null || (animation.isCompleted && !route!.offstage)) {
      _arrival?.removeStatusListener(_arrived);
      _arrival = null;
      _built.addAll(_AccountTab.values);
    } else if (animation != _arrival) {
      _arrival?.removeStatusListener(_arrived);
      _arrival = animation..addStatusListener(_arrived);
    }
  }

  void _arrived(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _arrival?.removeStatusListener(_arrived);
    _arrival = null;
    if (mounted) setState(() => _built.addAll(_AccountTab.values));
  }

  @override
  void dispose() {
    _arrival?.removeStatusListener(_arrived);
    _scroll.dispose();
    super.dispose();
  }

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

  void _select(_AccountTab tab) {
    if (tab == _tab) return;
    setState(() {
      _tab = tab;
      _built.add(tab);
    });
    // Each tab is read from its top.
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    return StorePageShell(
      title: AccountPage.title,
      closeKey: const ValueKey<String>('account-page-close'),
      maxWidth: 1040,
      scrollController: _scroll,
      header: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SegmentedChoice<_AccountTab>(
            key: const ValueKey<String>('account-tabs'),
            options: _AccountTab.values,
            selected: _tab,
            keyOf: (_AccountTab tab) =>
                ValueKey<String>('account-tab-${tab.name}'),
            labelOf: (_AccountTab tab) => tab.label,
            onSelected: _select,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // The tabs left are kept, so a gift code half typed or a backup
          // under way is still there on the way back.
          for (final _AccountTab tab in _AccountTab.values)
            if (_built.contains(tab))
              Visibility(
                // Keyed, so a tab built later never takes another's state.
                key: ValueKey<_AccountTab>(tab),
                visible: tab == _tab,
                maintainState: true,
                child: _tabBody(context, tab),
              ),
        ],
      ),
    );
  }

  Widget _tabBody(BuildContext context, _AccountTab tab) {
    final SubscriptionController controller = widget.controller;
    final BillingBackend? backend = controller.backend;
    return switch (tab) {
      _AccountTab.profile => _Narrow(
        child: backend == null
            ? const Text('Account services are not configured in this build.')
            : AccountPanel(backend: backend, controller: controller),
      ),
      _AccountTab.subscription => ListenableBuilder(
        listenable: controller,
        builder: (BuildContext context, Widget? _) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // The plans lead, so all three are in view on opening.
              PlansSection(controller: controller),
              const SizedBox(height: AppSpacing.xl),
              _Narrow(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    // Restore Purchases stays in reach: App Review
                    // requires it beside subscriptions.
                    CreditMeter(controller: controller),
                    if (backend?.userId != null)
                      GiftCodeCard(controller: controller),
                  ],
                ),
              ),
            ],
          );
        },
      ),
      _AccountTab.backup => _Narrow(
        child:
            widget.backup ??
            Text(
              'Backup is not available in this build.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.of(context).textSecondary,
              ),
            ),
      ),
    };
  }
}

/// A tab's content kept to a readable width in the wider page.
class _Narrow extends StatelessWidget {
  const _Narrow({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: child,
      ),
    );
  }
}
