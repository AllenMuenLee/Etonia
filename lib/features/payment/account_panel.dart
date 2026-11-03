import 'package:flutter/material.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../app/theme/app_icons.dart';
import '../../app/theme/app_tokens.dart';
import '../../shared/widgets/processing.dart';
import '../library/library_dialogs.dart';
import 'billing_backend.dart';
import 'subscription_controller.dart';

/// Who is signed in, or the ways to sign in: Google, and Apple on Apple
/// devices.
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

  Future<void> _run(
    Future<void> Function() operation, {
    String failure = 'Could not complete sign-in. Please try again.',
  }) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await operation();
    } on Object {
      if (mounted) setState(() => _message = failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteAccount() async {
    final bool confirmed = await confirmAction(
      context,
      title: 'Delete your account?',
      message:
          'Your account, plan record and AI credits are deleted from Etonia '
          'for good. Notes on this device are kept.\n\n'
          'An App Store subscription is not cancelled by this: cancel it in '
          'Settings, under your name, then Subscriptions.',
      action: 'Delete account',
    );
    if (!confirmed || !mounted) return;
    await _run(
      widget.backend.deleteAccount,
      failure: 'Could not delete your account. Please try again.',
    );
    if (mounted && _message == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Your account was deleted')),
      );
    }
  }

  Widget? _messageText(TextTheme text, AppColors colors) {
    final String? message = _message;
    if (message == null) return null;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Text(
        message,
        style: text.bodyMedium?.copyWith(color: colors.danger),
      ),
    );
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
                            widget.backend.signInMethod == SignInMethod.apple
                                ? 'Signed in with Apple'
                                : 'Signed in with Google',
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
                    TextButton(
                      key: const ValueKey<String>('delete-account'),
                      onPressed: _busy ? null : _deleteAccount,
                      style: TextButton.styleFrom(
                        foregroundColor: colors.danger,
                        minimumSize: const Size(
                          AppSizes.minTouchTarget,
                          AppSizes.minTouchTarget,
                        ),
                      ),
                      child: const Text('Delete account'),
                    ),
                  ],
                ),
                ?_messageText(text, colors),
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
                widget.backend.canSignInWithApple
                    ? 'Sign in to manage your subscription and AI credits. '
                          'Back up your notes to iCloud or Google Drive from '
                          'the Backup tab.'
                    : 'Sign in with Google to manage your subscription, AI credits, and Drive backup.',
                style: text.titleMedium?.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: AppSpacing.xxs),
              Text(
                'Your notes and PDFs stay on your device. AI conversation text is sent only when you ask the assistant.',
                style: text.bodySmall?.copyWith(color: colors.textSecondary),
              ),
              ?_messageText(text, colors),
              const SizedBox(height: AppSpacing.sm),
              if (widget.backend.canSignInWithApple) ...<Widget>[
                // Apple's own button, as its guidelines ask, in the theme's
                // ink.
                SizedBox(
                  height: AppSizes.minTouchTarget,
                  child: SignInWithAppleButton(
                    key: const ValueKey<String>('sign-in-apple'),
                    onPressed: () {
                      if (!_busy) _run(widget.backend.signInWithApple);
                    },
                    style: Theme.of(context).brightness == Brightness.dark
                        ? SignInWithAppleButtonStyle.white
                        : SignInWithAppleButtonStyle.black,
                    borderRadius: const BorderRadius.all(
                      Radius.circular(AppSizes.minTouchTarget / 2),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
              ],
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
