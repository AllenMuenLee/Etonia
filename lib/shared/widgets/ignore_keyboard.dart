import 'package:flutter/widgets.dart';

/// While [ignoring], shows [child] the window as if the on-screen keyboard
/// were down: no bottom inset, and the full safe-area padding beneath it.
///
/// For a screen kept mounted out of view. Offstage widgets are still laid
/// out, so without this every frame of the keyboard's slide would lay out
/// every hidden screen again, and the one in view would stutter.
class IgnoreKeyboard extends StatelessWidget {
  const IgnoreKeyboard({
    super.key,
    required this.ignoring,
    required this.child,
  });

  final bool ignoring;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);
    // Always a MediaQuery, so the child keeps its state as this toggles.
    // The padding is what the keyboard leaves of the view padding, so with
    // the keyboard gone it is all of it. Only this widget rebuilds as the
    // keyboard moves; what is below sees nothing change.
    return MediaQuery(
      data: ignoring
          ? media.copyWith(
              viewInsets: EdgeInsets.zero,
              padding: media.viewPadding,
            )
          : media,
      child: child,
    );
  }
}
