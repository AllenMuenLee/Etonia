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

  @override
  void dispose() {
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
    setState(() => _tab = tab);
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
            Visibility(
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
                    CreditMeter(controller: controller, showRestore: false),
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
