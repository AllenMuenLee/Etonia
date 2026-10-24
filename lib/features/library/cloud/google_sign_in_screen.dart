import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../shared/widgets/processing.dart';
import 'google_drive_client.dart';

/// Shows the Google sign-in screen and returns the account signed in, or
/// null when the user went on without one.
Future<GoogleDriveAccount?> showGoogleSignIn(
  BuildContext context, {
  required GoogleDriveClient client,
}) {
  return Navigator.of(context).push<GoogleDriveAccount?>(
    MaterialPageRoute<GoogleDriveAccount?>(
      fullscreenDialog: true,
      builder: (BuildContext context) => GoogleSignInScreen(client: client),
    ),
  );
}

/// The first thing shown to someone not signed in: one sign-in that is
/// both their Google account and Google Drive, for backing up their notes.
class GoogleSignInScreen extends StatefulWidget {
  const GoogleSignInScreen({super.key, required this.client});

  final GoogleDriveClient client;

  @override
  State<GoogleSignInScreen> createState() => _GoogleSignInScreenState();
}

class _GoogleSignInScreenState extends State<GoogleSignInScreen> {
  bool _busy = false;
  String? _problem;

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final GoogleDriveAccount? account = await widget.client.signIn();
      if (!mounted) return;
      if (account == null) {
        setState(() => _problem = 'Sign-in was cancelled');
        return;
      }
      Navigator.of(context).pop(account);
    } on GoogleDriveException catch (error) {
      if (mounted) setState(() => _problem = error.message);
    } on Object {
      if (mounted) setState(() => _problem = "Couldn't sign in to Google");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Icon(AppIcons.cloud, size: 48, color: colors.accent),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    'Sign in to Etonia',
                    textAlign: TextAlign.center,
                    style: text.titleLarge!.copyWith(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Sign in with your Google account and connect Google '
                    'Drive, so your notes are backed up and your plan '
                    'follows you.',
                    textAlign: TextAlign.center,
                    style: text.bodyMedium!.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  FilledButton(
                    key: const ValueKey<String>('google-sign-in'),
                    onPressed: _busy ? null : _signIn,
                    child: GentleSwitcher(
                      value: _busy,
                      alignment: Alignment.center,
                      child: Text(
                        _busy ? 'Signing in…' : 'Sign in with Google',
                      ),
                    ),
                  ),
                  if (_problem != null) ...<Widget>[
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      _problem!,
                      textAlign: TextAlign.center,
                      style: text.bodySmall!.copyWith(color: colors.danger),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.xs),
                  TextButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('Not now'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
