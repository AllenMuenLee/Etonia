/// How input is treated before the user changes anything.
abstract final class InputDefaults {
  /// Whether only a stylus (or a mouse) writes, erases, and selects when the
  /// app starts, leaving fingers to scroll and zoom. The user can turn it
  /// off in the editor's settings.
  ///
  /// Not const so that widget tests, which draw with simulated fingers, can
  /// start with fingers writing (see `test/flutter_test_config.dart`).
  static bool stylusOnly = true;
}
