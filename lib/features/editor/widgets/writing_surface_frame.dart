import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';

/// The page area: a paper-colored surface that spans the whole writing
/// region, edge to edge. [child] is clipped to it.
class WritingSurfaceFrame extends StatelessWidget {
  const WritingSurfaceFrame({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);

    return Semantics(
      container: true,
      label: 'Writing surface',
      child: ColoredBox(
        color: colors.writingSurface,
        child: ClipRect(child: child),
      ),
    );
  }
}
