import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/input_defaults.dart';

/// Runs before every test file. Loads the icon fonts so icons render
/// as glyphs, not placeholder boxes, in golden images.
///
/// The app starts with only a stylus writing; tests draw with simulated
/// fingers, so they start with fingers writing. The tests of the default
/// itself set it back.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  InputDefaults.stylusOnly = false;
  final FontLoader icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await icons.load();
  final FontLoader cupertino =
      FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
        rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
      );
  await cupertino.load();
  await testMain();
}
