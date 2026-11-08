import 'package:flutter/widgets.dart';

/// Keeps the on-screen keyboard from re-laying-out the Study Desk.
///
/// A `Scaffold` that resizes for the keyboard hands the whole desk a new height
/// on every frame of the keyboard's slide: the transcript, the sidebar, the
/// studio kept built behind the chat, and each answer's Markdown are measured
/// again sixty times a second, and the slide stutters.
///
/// Inside this scope the desk sees a window with no keyboard in it (no bottom
/// inset, and the full safe-area padding the keyboard would otherwise eat into
/// one frame at a time), so it keeps one size for the whole slide. What does
/// need to rise with the keyboard, the chat and its message field, reads how
/// far from [StudyKeyboardLift]. Only that, and this widget, rebuild as the
/// keyboard moves.
///
/// Put it above the desk's `Scaffold`, which must not resize for the keyboard
/// itself (`resizeToAvoidBottomInset: false`).
class StudyKeyboardScope extends StatelessWidget {
  const StudyKeyboardScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);
    final double covered = media.viewInsets.bottom - media.viewPadding.bottom;
    return _KeyboardRise(
      // What the keyboard covers of the window beyond the safe area the desk
      // already keeps clear of its bottom edge.
      lift: covered > 0 ? covered : 0,
      child: MediaQuery(
        data: media.copyWith(
          viewInsets: media.viewInsets.copyWith(bottom: 0),
          padding: media.viewPadding,
        ),
        child: child,
      ),
    );
  }
}

class _KeyboardRise extends InheritedWidget {
  const _KeyboardRise({required this.lift, required super.child});

  final double lift;

  @override
  bool updateShouldNotify(_KeyboardRise oldWidget) => oldWidget.lift != lift;
}

/// Lifts [child] clear of the keyboard: bottom padding that follows it. The
/// padding is all that changes as the keyboard moves, and [child], handed in
/// built, is not built again for it.
class StudyKeyboardLift extends StatelessWidget {
  const StudyKeyboardLift({super.key, required this.child});

  final Widget child;

  /// How far the keyboard has risen over the desk's bottom edge; 0 without a
  /// [StudyKeyboardScope], where whatever is above resizes for it instead.
  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_KeyboardRise>()?.lift ?? 0;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: of(context)),
    child: child,
  );
}
