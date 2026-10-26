import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/main.dart' as app;
import 'package:integration_test/integration_test.dart';

/// Walks the app's main screens on whatever device it runs on and takes a
/// screenshot of each, so runs on iPads, iPhones and Android tablets can be
/// laid side by side. Frames run at the display's pace, as for a user, so a
/// screen recording of the run shows every animation as it plays.
///
/// Run it through `test_driver/visual_tour_driver.dart`, which writes the
/// screenshots and `report.json` to `$TOUR_OUT`. A step that cannot be done
/// is recorded in the report rather than failing the test, so one missing
/// control does not cost the screenshots after it.
///
/// Built without dart-defines, the app has no backend: nothing is signed in
/// and no AI credits are spent.
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('visual tour', (WidgetTester tester) async {
    final _Tour tour = _Tour(binding, tester);
    addTearDown(tour.dispose);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    app.main();
    await tour.step('startup_reveal', settle: false, () async {
      await tour.wait(const Duration(milliseconds: 250));
    });
    // First launch asks to sign in, then for the AI's handwriting.
    await tour.step('sign_in_prompt', () async {
      await tour.settle(const Duration(seconds: 4));
    });
    await tour.step('handwriting_prompt', () async {
      await tour.tap(find.text('Not now'));
      await tour.settle(const Duration(seconds: 2));
    });
    await tour.step('library_empty', () async {
      for (int i = 0; i < 3; i++) {
        final Finder later = find.text('Skip').evaluate().isNotEmpty
            ? find.text('Skip')
            : find.text('Not now');
        if (later.evaluate().isEmpty) break;
        await tour.tap(later);
        await tour.settle();
      }
      await tour.expectVisible(find.byTooltip('New note'));
    });

    // A note, from the empty library to ink on the page.
    await tour.step('new_note_menu', () async {
      await tour.tap(find.byTooltip('New note'));
    });
    await tour.step('new_note_dialog', () async {
      await tour.tap(find.text('Blank note'));
    });
    await tour.step('editor_blank', () async {
      await tour.tap(find.widgetWithText(FilledButton, 'Create'));
      await tour.settle(const Duration(seconds: 3));
      await tour.expectVisible(find.byType(InkCanvas));
    });
    await tour.step('editor_ink', () async {
      final Rect page = tester.getRect(find.byType(InkCanvas).first);
      final Offset origin = page.topLeft + Offset(page.width * 0.2, 160);
      // A zigzag line of "writing", a loop, and an underline.
      await tour.stroke(<Offset>[
        for (int i = 0; i <= 16; i++)
          origin + Offset(i * 14.0, i.isEven ? 0 : -26),
      ]);
      await tour.stroke(<Offset>[
        for (int i = 0; i <= 24; i++)
          origin +
              const Offset(320, -12) +
              Offset.fromDirection(i / 24 * 6.3, 26),
      ]);
      await tour.stroke(<Offset>[
        origin + const Offset(-6, 24),
        origin + const Offset(360, 24),
      ]);
    });
    await tour.step('pen_options', () async {
      await tour.tap(find.byTooltip('Pen'));
    });
    await tour.step('eraser_options', () async {
      await tour.tap(find.byTooltip('Pen'));
      await tour.tap(find.byTooltip('Eraser'));
      await tour.tap(find.byTooltip('Eraser'));
    });
    await tour.step('selection', () async {
      await tour.tap(find.byTooltip('Pen'));
      await tour.tap(find.byTooltip('Select'));
      final Rect page = tester.getRect(find.byType(InkCanvas).first);
      final Offset a = page.topLeft + Offset(page.width * 0.2 - 30, 100);
      await tour.stroke(<Offset>[
        a,
        a + const Offset(420, 0),
        a + const Offset(420, 110),
        a + const Offset(0, 110),
        a,
      ]);
      await tour.expectVisible(find.byTooltip('Copy'));
    });
    await tour.step('page_overview', () async {
      await tour.tap(find.byTooltip('Pen'));
      await tour.tap(find.byTooltip('Page overview'));
    });
    await tour.step('editor_settings', () async {
      await tour.tap(find.byTooltip('Page overview'));
      await tour.tap(find.byTooltip('Settings'));
    });
    await tour.step('ai_turn_on', () async {
      await tour.tap(find.byTooltip('Close settings'));
      await tour.tap(find.byTooltip('Turn on AI'));
    });
    await tour.step('editor_dark', () async {
      await tour.dismiss();
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tour.settle(const Duration(seconds: 2));
    });

    // The library, now with a note in it.
    await tour.step('library_dark', () async {
      await tour.tap(find.byTooltip('Back to library'));
      await tour.settle(const Duration(seconds: 2));
    });
    await tour.step('library_with_note', () async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tour.settle(const Duration(seconds: 2));
    });
    await tour.step('library_other_view', () async {
      await tour.toggleView();
    });
    await tour.step('sort_menu', () async {
      await tour.toggleView();
      await tour.tap(find.byTooltip('Sort'));
    });
    await tour.step('new_folder_dialog', () async {
      await tour.dismiss();
      await tour.tap(find.byTooltip('New folder').first);
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'Lectures',
      );
      await tour.settle();
    });
    await tour.step('library_with_folder', () async {
      await tour.tap(find.widgetWithText(FilledButton, 'Create'));
      await tour.settle(const Duration(seconds: 2));
    });
    await tour.step('account', () async {
      await tour.tap(find.byTooltip('Account'));
      await tour.settle(const Duration(seconds: 2));
    });
    await tour.step('plans', () async {
      await tour.closeStorePages();
      await tour.tap(find.byTooltip('Sort'));
      await tour.tap(find.text('Plans & AI Credits'));
      // The store is asked for prices; on a simulator it has none.
      await tour.settle(const Duration(seconds: 4));
    });

    // Landscape, where the device lets the app turn it.
    await tour.step('landscape_library', () async {
      await tour.closeStorePages();
      await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
      ]);
      await tour.settle(const Duration(seconds: 3));
    });
    await tour.step('landscape_editor', () async {
      await tour.tap(find.text('Untitled note').first);
      await tour.settle(const Duration(seconds: 3));
      await tour.expectVisible(find.byType(InkCanvas));
    });
    await tour.step('portrait_restored', () async {
      await SystemChrome.setPreferredOrientations(<DeviceOrientation>[]);
      await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
        DeviceOrientation.portraitUp,
      ]);
      await tour.settle(const Duration(seconds: 3));
      await tour.tap(find.byTooltip('Back to library'));
      await SystemChrome.setPreferredOrientations(<DeviceOrientation>[]);
    });

    // The screenshots travel to the driver in the same map.
    binding.reportData = <String, dynamic>{
      ...?binding.reportData,
      ...tour.report(),
    };
    tour.dispose();
  }, timeout: const Timeout(Duration(minutes: 10)));
}

class _Tour {
  _Tour(this.binding, this.tester) {
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    final FlutterExceptionHandler? report = _reportError;
    FlutterError.onError = (FlutterErrorDetails details) {
      _lastError = details;
      report?.call(details);
    };
  }

  final IntegrationTestWidgetsFlutterBinding binding;
  final WidgetTester tester;
  final List<Map<String, Object?>> _steps = <Map<String, Object?>>[];
  final List<FrameTiming> _frames = <FrameTiming>[];
  final FlutterExceptionHandler? _reportError = FlutterError.onError;
  FlutterErrorDetails? _lastError;
  bool _surfaceConverted = false;
  bool _disposed = false;

  void _onTimings(List<FrameTiming> timings) => _frames.addAll(timings);

  /// Must run before the test ends: the test checks that the error handler
  /// is its own again.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    FlutterError.onError = _reportError;
  }

  /// The app's own frames of [details]' stack, where it went wrong.
  List<String> _appFrames(FlutterErrorDetails details) {
    final List<String> lines = (details.stack ?? StackTrace.empty)
        .toString()
        .split('\n')
        .where((String line) => line.trim().isNotEmpty)
        .toList();
    final List<String> app = lines
        .where((String line) => line.contains('package:greatnote/'))
        .toList();
    return (app.isEmpty ? lines : app).take(8).toList();
  }

  /// Runs [body], then photographs the screen it left, recording whether it
  /// managed and what frames the screen drew on the way. Unless [settle] is
  /// false, animations play out before the photograph.
  Future<void> step(
    String name,
    Future<void> Function() body, {
    bool settle = true,
  }) async {
    final Stopwatch clock = Stopwatch()..start();
    _frames.clear();
    _lastError = null;
    String? error;
    try {
      await body();
      if (settle) await this.settle();
    } on Object catch (e) {
      error = '$e'.split('\n').first;
    }
    final Object? exception = tester.takeException();
    if (exception != null) {
      error ??= 'Framework exception: ${'$exception'.split('\n').first}';
    }
    final FlutterErrorDetails? details = _lastError;
    final Size size = tester.view.physicalSize / tester.view.devicePixelRatio;
    final String shot = error == null ? name : '${name}_FAILED';
    try {
      if (Platform.isAndroid && !_surfaceConverted) {
        await binding.convertFlutterSurfaceToImage();
        _surfaceConverted = true;
        await tester.pump();
      }
      await binding.takeScreenshot(shot);
    } on Object catch (e) {
      error ??= 'Screenshot failed: $e';
    }
    final List<int> spans = <int>[
      for (final FrameTiming frame in _frames) frame.totalSpan.inMicroseconds,
    ];
    _steps.add(<String, Object?>{
      'name': name,
      'screenshot': shot,
      'ok': error == null,
      'error': error,
      if (error != null) 'onScreen': _labelsOnScreen(),
      if (details != null) ...<String, Object?>{
        'flutterError': details.exceptionAsString().split('\n').first,
        'flutterErrorContext': details.context?.toDescription(),
        'stack': _appFrames(details),
      },
      'ms': clock.elapsedMilliseconds,
      'logicalWidth': size.width.round(),
      'logicalHeight': size.height.round(),
      'frames': spans.length,
      'framesOver16ms': spans.where((int us) => us > 16667).length,
      'worstFrameMs': spans.isEmpty
          ? null
          : (spans.reduce((int a, int b) => a > b ? a : b) / 1000)
                .toStringAsFixed(1),
    });
  }

  /// The tooltips and texts on screen, to tell why a control was not found.
  List<String> _labelsOnScreen() {
    final Set<String> labels = <String>{
      for (final Element e in find.byType(Tooltip).evaluate())
        if ((e.widget as Tooltip).message case final String m) 'tooltip:$m',
      for (final Element e in find.byType(Text).evaluate())
        if ((e.widget as Text).data case final String d) 'text:$d',
    };
    return labels.take(40).toList();
  }

  Map<String, Object?> report() {
    final Size size = tester.view.physicalSize;
    return <String, Object?>{
      'platform': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'physicalWidth': size.width.round(),
      'physicalHeight': size.height.round(),
      'devicePixelRatio': tester.view.devicePixelRatio,
      'steps': _steps,
      'failures': <String>[
        for (final Map<String, Object?> step in _steps)
          if (step['ok'] != true) '${step['name']}: ${step['error']}',
      ],
    };
  }

  /// Lets animations play out, giving up on ones that never end (a
  /// looping indicator) after [limit].
  Future<void> settle([Duration limit = const Duration(seconds: 2)]) async {
    try {
      await tester.pumpAndSettle(
        const Duration(milliseconds: 16),
        EnginePhase.sendSemanticsUpdate,
        limit,
      );
    } on FlutterError {
      // Still animating; the screenshot shows it mid-flight.
    }
  }

  Future<void> wait(Duration duration) => tester.pump(duration);

  Future<void> expectVisible(Finder finder) async {
    for (int i = 0; i < 50 && finder.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    if (finder.evaluate().isEmpty) {
      throw StateError('Not on screen: $finder');
    }
  }

  Future<void> tap(Finder finder) async {
    await expectVisible(finder);
    await tester.tap(finder.first, warnIfMissed: false);
    await settle();
  }

  /// Draws [path] with a mouse, at about 120 samples a second. A stylus
  /// would not do: the app takes real stylus input natively, beside
  /// Flutter, and so ignores a test's synthetic stylus events.
  Future<void> stroke(List<Offset> path) async {
    final TestGesture pen = await tester.startGesture(
      path.first,
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    int sample = 0;
    for (int leg = 1; leg < path.length; leg++) {
      for (int i = 1; i <= 4; i++) {
        await pen.moveTo(
          Offset.lerp(path[leg - 1], path[leg], i / 4)!,
          timeStamp: Duration(milliseconds: 8 * ++sample),
        );
        await tester.pump();
      }
    }
    await pen.up(timeStamp: Duration(milliseconds: 8 * (sample + 1)));
    // Left in place, the mouse would hover whatever opens beneath it.
    await pen.removePointer();
    await settle();
  }

  /// Closes a menu, popover or dialog the way a keyboard user would.
  Future<void> dismiss() async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle();
  }

  /// Shows the library as a list if it is a grid, and back.
  Future<void> toggleView() async {
    final Finder direct = find.byWidgetPredicate(
      (Widget w) =>
          w is IconButton &&
          (w.tooltip == 'Show as list' || w.tooltip == 'Show as grid'),
    );
    if (direct.evaluate().isNotEmpty) {
      await tap(direct);
      return;
    }
    // Compact layouts keep the toggle in the sort menu.
    await tap(find.byTooltip('Sort'));
    final Finder item = find.textContaining(RegExp('^Show as (list|grid)'));
    await tap(item);
  }

  /// Closes the account and plans pages, however many are open.
  Future<void> closeStorePages() async {
    for (
      int i = 0;
      i < 3 && find.byTooltip('Close').evaluate().isNotEmpty;
      i++
    ) {
      await tap(find.byTooltip('Close').last);
      await settle(const Duration(seconds: 1));
    }
  }
}
