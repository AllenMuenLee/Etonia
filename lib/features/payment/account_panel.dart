import 'package:flutter/material.dart';

import '../../app/theme/app_icons.dart';
import '../../app/theme/app_tokens.dart';
import 'billing_backend.dart';
import 'subscription_controller.dart';

class AccountPanel extends StatefulWidget {
  const AccountPanel({
    super.key,
    required this.backend,
    required this.controller,
  });
  final BillingBackend backend;
  final SubscriptionController controller;
  @override
  State<AccountPanel> createState() => _AccountPanelState();
}

class _AccountPanelState extends State<AccountPanel> {
  bool _busy = false;
  String? _message;

  Future<void> _run(Future<void> Function() operation) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await operation();
    } on Object {
      if (mounted) {
        setState(
          () => _message = 'Could not complete sign-in. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: widget.backend,
      builder: (BuildContext context, Widget? _) {
        if (!widget.backend.isConfigured) {
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: Text(
              'Account services are not configured in this build.',
              style: text.bodyMedium?.copyWith(color: colors.textPrimary),
            ),
          );
        }
        if (widget.backend.userId != null) {
          return Container(
            margin: const EdgeInsets.only(bottom: AppSpacing.md),
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppGlass.surface(colors),
              borderRadius: BorderRadius.circular(AppRadii.xl),
              boxShadow: AppShadows.paper(colors),
              border: Border.all(
                color: colors.glassEdge,
                width: AppSizes.hairline,
              ),
            ),
            child: Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              children: <Widget>[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      AppIcons.account,
                      size: AppSizes.icon,
                      color: colors.textPrimary,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Flexible(
                      child: Text(
                        widget.backend.email ?? 'Signed in',
                        style: text.titleMedium?.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: <Widget>[
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _run(widget.controller.refresh),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: colors.textPrimary,
                        side: BorderSide(color: colors.divider),
                        minimumSize: const Size(
                          AppSizes.minTouchTarget,
                          AppSizes.minTouchTarget,
                        ),
                      ),
                      child: const Text('Refresh'),
                    ),
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _run(widget.backend.signOut),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: colors.textPrimary,
                        side: BorderSide(color: colors.divider),
                        minimumSize: const Size(
                          AppSizes.minTouchTarget,
                          AppSizes.minTouchTarget,
                        ),
                      ),
                      child: const Text('Sign out'),
                    ),
                  ],
                ),
              ],
            ),
          );
        }
        return Container(
          margin: const EdgeInsets.only(bottom: AppSpacing.md),
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: AppGlass.surface(colors),
            borderRadius: BorderRadius.circular(AppRadii.xl),
            boxShadow: AppShadows.paper(colors),
            border: Border.all(
              color: colors.glassEdge,
              width: AppSizes.hairline,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Sign in with Google to manage your subscription, AI credits, and Drive backup.',
                style: text.titleMedium?.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: AppSpacing.xxs),
              Text(
                'Your notes, PDFs, and chat history stay on your device.',
                style: text.bodySmall?.copyWith(color: colors.textSecondary),
              ),
              if (_message != null) ...<Widget>[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  _message!,
                  style: text.bodyMedium?.copyWith(color: colors.danger),
                ),
              ],
              const SizedBox(height: AppSpacing.sm),
              FilledButton.icon(
                key: const ValueKey<String>('sign-in-google'),
                onPressed: _busy
                    ? null
                    : () => _run(widget.backend.signInWithGoogle),
                icon: const Icon(AppIcons.account, size: 18),
                label: Text(_busy ? 'Please wait…' : 'Continue with Google'),
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
              ),
            ],
          ),
        );
      },
    );
  }
}
