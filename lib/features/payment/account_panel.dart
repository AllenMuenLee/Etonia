import 'package:flutter/material.dart';

import '../../app/theme/app_icons.dart';
import '../../app/theme/app_tokens.dart';
import '../../shared/widgets/processing.dart';
import 'billing_backend.dart';
import 'subscription_controller.dart';

/// Who is signed in, or the way to sign in with Google.
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
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Text(
              'Account services are not configured in this build.',
              style: text.bodyMedium?.copyWith(color: colors.textPrimary),
            ),
          );
        }
        if (widget.backend.userId != null) {
          final String email = widget.backend.email ?? 'Signed in';
          return Container(
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: AppGlass.surface(colors),
              borderRadius: AppBorderRadius.xl,
              boxShadow: AppShadows.paper(colors),
              border: Border.all(
                color: colors.glassEdge,
                width: AppSizes.hairline,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    // The first letter, in ink: the account's face.
                    ExcludeSemantics(
                      child: Container(
                        width: 52,
                        height: 52,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: colors.accent,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          email.characters.first.toUpperCase(),
                          style: text.titleLarge?.copyWith(
                            color: colors.onAccent,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            email,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.titleMedium?.copyWith(
                              color: colors.textPrimary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            'Signed in with Google',
                            style: text.bodySmall?.copyWith(
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
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
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            color: AppGlass.surface(colors),
            borderRadius: AppBorderRadius.xl,
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
                'Your notes and PDFs stay on your device. AI conversation text is sent only when you ask the assistant.',
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
                label: GentleSwitcher(
                  value: _busy,
                  alignment: Alignment.center,
                  child: Text(_busy ? 'Please wait…' : 'Continue with Google'),
                ),
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
