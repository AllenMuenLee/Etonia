import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';

/// The tokens below which a plan is running out, as a fraction of its
/// allowance.
const double kLowTokenFraction = 0.05;

/// One tiny line, at the end of the row just above a composer, that says the
/// month's tokens are nearly gone. It takes no room, and shows nothing, while
/// there are plenty left.
class LowTokenNotice extends StatelessWidget {
  const LowTokenNotice({super.key, required this.fraction});

  static const String message =
      'You have less than 5% of your tokens left this month';

  /// What is left of the allowance, from `0.0` to `1.0`.
  final double fraction;

  @override
  Widget build(BuildContext context) {
    if (fraction >= kLowTokenFraction) return const SizedBox.shrink();
    final AppColors colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        AppSpacing.md,
        AppSpacing.xxs,
        AppSpacing.md,
        0,
      ),
      child: Semantics(
        liveRegion: true,
        child: Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Text(
            message,
            key: const ValueKey<String>('low-token-notice'),
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
