import 'package:flutter/foundation.dart';

/// Hardware gestures that a stylus can report to the editor.
///
/// Android pens commonly report one or two barrel buttons. Apple Pencil
/// reports double tap, and Apple Pencil Pro additionally reports squeeze.
enum StylusGesture { singlePress, doubleTap, secondaryPress, squeeze }

/// A gesture under the name its stylus family gives it.
@immutable
class StylusControl {
  const StylusControl(this.gesture, this.label, {this.hint});

  final StylusGesture gesture;
  final String label;

  /// Which styluses have it, when not all of the family's do.
  final String? hint;
}

/// The styluses a platform pairs with, and the gestures its native side can
/// report (see `NativeInkChannel` on each platform).
enum StylusFamily {
  applePencil(
    title: 'Apple Pencil',
    stylusOnlyLabel: 'Only write with Apple Pencil',
    controls: <StylusControl>[
      StylusControl(
        StylusGesture.doubleTap,
        'Double tap',
        hint: 'Pencil 2 and Pro',
      ),
      StylusControl(StylusGesture.squeeze, 'Squeeze', hint: 'Pencil Pro'),
    ],
  ),
  androidStylus(
    title: 'Stylus',
    stylusOnlyLabel: 'Only write with stylus',
    controls: <StylusControl>[
      StylusControl(StylusGesture.singlePress, 'Button press'),
      StylusControl(StylusGesture.doubleTap, 'Double press'),
      StylusControl(
        StylusGesture.secondaryPress,
        'Second button',
        hint: 'If it has one',
      ),
    ],
  );

  const StylusFamily({
    required this.title,
    required this.stylusOnlyLabel,
    required this.controls,
  });

  final String title;
  final String stylusOnlyLabel;
  final List<StylusControl> controls;

  /// The family of the device this runs on; null where no native side
  /// reports stylus gestures.
  static StylusFamily? get current {
    if (kIsWeb) return null;
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => applePencil,
      TargetPlatform.android => androidStylus,
      _ => null,
    };
  }
}

/// Safe, quick editor commands that can be assigned to a stylus gesture.
enum StylusAction {
  none('Do nothing'),
  toggleToolOptions('Show or hide tool options'),
  toggleToolbar('Show or hide toolbar'),
  togglePenEraser('Switch pen and eraser'),
  previousTool('Switch to previous tool'),
  pen('Choose pen'),
  eraser('Choose eraser'),
  highlighter('Choose highlighter'),
  select('Choose selection'),
  undo('Undo'),
  redo('Redo');

  const StylusAction(this.label);

  final String label;
}

/// The user's action for each hardware gesture.
@immutable
class StylusActionBindings {
  const StylusActionBindings({
    this.singlePress = StylusAction.toggleToolOptions,
    this.doubleTap = StylusAction.togglePenEraser,
    this.secondaryPress = StylusAction.none,
    this.squeeze = StylusAction.none,
  });

  final StylusAction singlePress;
  final StylusAction doubleTap;
  final StylusAction secondaryPress;
  final StylusAction squeeze;

  StylusAction actionFor(StylusGesture gesture) => switch (gesture) {
    StylusGesture.singlePress => singlePress,
    StylusGesture.doubleTap => doubleTap,
    StylusGesture.secondaryPress => secondaryPress,
    StylusGesture.squeeze => squeeze,
  };

  StylusActionBindings withAction(StylusGesture gesture, StylusAction action) =>
      switch (gesture) {
        StylusGesture.singlePress => copyWith(singlePress: action),
        StylusGesture.doubleTap => copyWith(doubleTap: action),
        StylusGesture.secondaryPress => copyWith(secondaryPress: action),
        StylusGesture.squeeze => copyWith(squeeze: action),
      };

  StylusActionBindings copyWith({
    StylusAction? singlePress,
    StylusAction? doubleTap,
    StylusAction? secondaryPress,
    StylusAction? squeeze,
  }) {
    return StylusActionBindings(
      singlePress: singlePress ?? this.singlePress,
      doubleTap: doubleTap ?? this.doubleTap,
      secondaryPress: secondaryPress ?? this.secondaryPress,
      squeeze: squeeze ?? this.squeeze,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is StylusActionBindings &&
        other.singlePress == singlePress &&
        other.doubleTap == doubleTap &&
        other.secondaryPress == secondaryPress &&
        other.squeeze == squeeze;
  }

  @override
  int get hashCode =>
      Object.hash(singlePress, doubleTap, secondaryPress, squeeze);
}
