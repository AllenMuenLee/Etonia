import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/input_defaults.dart';
import 'package:greatnote/features/library/etonia_rest.dart';
import 'package:greatnote/shared/widgets/etonia_mascot.dart';
import 'package:greatnote/shared/widgets/processing.dart';
import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';

/// Runs before every test file. Loads the icon fonts so icons render
/// as glyphs, not placeholder boxes, in golden images.
///
/// The app starts with only a stylus writing; tests draw with simulated
/// fingers, so they start with fingers writing. The tests of the default
/// itself set it back.
///
/// Loading is timed on the test's fake clock, and what one test taught
/// the timings is forgotten before the next, so the transitions that cover
/// loading last the same however fast the machine is and whatever ran
/// before.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  LeakTesting.enable();
  LeakTesting.settings = LeakTesting.settings
      .withIgnored(createdByTestHelpers: true)
      .withIgnoredAll();
  TestWidgetsFlutterBinding.ensureInitialized();
  InputDefaults.stylusOnly = false;
  LoadTimings.clock = () {
    final TestWidgetsFlutterBinding binding =
        TestWidgetsFlutterBinding.instance;
    return binding.inTest
        ? Duration(microseconds: binding.clock.now().microsecondsSinceEpoch)
        : Duration.zero;
  };
  setUp(LoadTimings.instance.reset);
  // Etonia rests in a random folder of the library; the tests that look for
  // her choose where, and every other test has her out of its way.
  setUp(() => EtoniaRest.enabled = false);
  // Her breathing never ends, so tests that settle do not have it.
  setUp(() => EtoniaMascot.idles = false);
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
