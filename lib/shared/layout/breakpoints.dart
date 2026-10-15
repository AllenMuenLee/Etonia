/// Width-based layout classes. This is the only place breakpoints are defined;
/// layout never branches on device model or operating system.
enum WindowSizeClass {
  /// Below [Breakpoints.medium]: a functional phone fallback.
  compact,

  /// Small tablets and tablets in portrait.
  medium,

  /// Large tablets, typically in landscape. The primary experience.
  expanded;

  factory WindowSizeClass.fromWidth(double width) {
    if (width >= Breakpoints.expanded) {
      return WindowSizeClass.expanded;
    }
    if (width >= Breakpoints.medium) {
      return WindowSizeClass.medium;
    }
    return WindowSizeClass.compact;
  }
}

/// Lower bounds, in logical pixels, of each [WindowSizeClass].
abstract final class Breakpoints {
  static const double medium = 600;
  static const double expanded = 840;
}
