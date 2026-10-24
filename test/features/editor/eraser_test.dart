import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/shared/widgets/app_controls.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_painter.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/pen_settings.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/widgets/eraser_options.dart';
import 'package:greatnote/features/editor/widgets/tool_palette.dart';

import '../../helpers/editor_harness.dart';
import '../../helpers/pump_app.dart';

const Duration _sampleInterval = Duration(milliseconds: 8);

/// Moves a pointer from [from] to [to] in [steps] timed samples. With the
/// pen this draws a stroke; with the eraser it erases.
Future<void> _drag(
  WidgetTester tester,
  Offset from,
  Offset to, {
  int steps = 10,
  PointerDeviceKind kind = PointerDeviceKind.stylus,
}) async {
  final TestGesture gesture = await tester.startGesture(from, kind: kind);
  for (int i = 1; i <= steps; i++) {
    await gesture.moveTo(
      Offset.lerp(from, to, i / steps)!,
      timeStamp: _sampleInterval * i,
    );
  }
  await gesture.up(timeStamp: _sampleInterval * (steps + 1));
  await tester.pump();
}

Future<void> _selectEraser(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Eraser'));
  await tester.pumpAndSettle();
}

/// Selects the eraser if needed, then opens its options.
Future<void> _openEraserOptions(WidgetTester tester) async {
  if (find.byType(EraserOptions).evaluate().isEmpty) {
    await _selectEraser(tester);
  }
  if (find.byType(EraserOptions).evaluate().isEmpty) {
    await _selectEraser(tester);
  }
  expect(find.byType(EraserOptions), findsOneWidget);
}

/// Dismisses an open popover by tapping the app bar background.
Future<void> _dismiss(WidgetTester tester) async {
  await tester.tapAt(const Offset(150, 4));
  await tester.pumpAndSettle();
}

Future<void> _setMode(WidgetTester tester, EraserMode mode) async {
  await _openEraserOptions(tester);
  await tester.tap(find.text(mode.label));
  await tester.pumpAndSettle();
  await _dismiss(tester);
}

Slider _slider(WidgetTester tester) {
  return tester.widget<Slider>(find.byType(Slider));
}

/// The selected state of a palette button, as assistive technology sees it.
bool _isSelected(WidgetTester tester, String label) {
  return isSemantics(isSelected: true).matches(
    tester.getSemantics(find.bySemanticsLabel(RegExp('^$label'))),
    <dynamic, dynamic>{},
  );
}

void main() {
  test('eraser defaults: area mode, 24 px, range 8-80, 6 px hit radius', () {
    const EraserConfig config = EraserConfig();
    final EraserSettings settings = EraserSettings.defaults();

    expect(config.minSize, 8);
    expect(config.maxSize, 80);
    expect(config.strokeHitRadius, 6);
    expect(config.minPieceLength, 0.01);
    expect(settings.mode, EraserMode.area);
    expect(settings.size, 24);
    expect(
      settings.copyWith(mode: EraserMode.stroke),
      const EraserSettings(mode: EraserMode.stroke, size: 24),
    );
  });

  for (final TestViewport viewport in TestViewport.values) {
    group(viewport.name, () {
      testWidgets('exactly one of pen and eraser is selected', (
        WidgetTester tester,
      ) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        await pumpEditor(tester, viewport: viewport);

        expect(_isSelected(tester, 'Pen'), isTrue);
        expect(_isSelected(tester, 'Eraser'), isFalse);

        await _selectEraser(tester);

        expect(_isSelected(tester, 'Pen'), isFalse);
        expect(_isSelected(tester, 'Eraser'), isTrue);
        // The first press only selects; it does not open the options.
        expect(find.byType(EraserOptions), findsNothing);

        await tester.tap(find.byTooltip('Pen'));
        await tester.pumpAndSettle();

        expect(_isSelected(tester, 'Pen'), isTrue);
        expect(_isSelected(tester, 'Eraser'), isFalse);
        expect(tester.takeException(), isNull);
        handle.dispose();
      });

      testWidgets('the options popover switches mode and changes size', (
        WidgetTester tester,
      ) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        await pumpEditor(tester, viewport: viewport);

        await _openEraserOptions(tester);

        final Rect screen = Offset.zero & viewport.size;
        final Rect options = tester.getRect(find.byType(EraserOptions));
        expect(screen.contains(options.topLeft), isTrue);
        expect(screen.contains(options.bottomRight), isTrue);
        final Slider slider = _slider(tester);
        expect(slider.min, 8);
        expect(slider.max, 80);
        expect(slider.value, 24);
        // The current mode is under the sliding thumb and has a selected
        // state, not only a color.
        expect(
          tester
              .widget<SelectionCapsule>(
                find.descendant(
                  of: find.byType(EraserOptions),
                  matching: find.byType(SelectionCapsule),
                ),
              )
              .index,
          EraserMode.values.indexOf(EraserMode.area),
        );
        expect(
          tester.getSemantics(find.bySemanticsLabel('Area')),
          isSemantics(label: 'Area', isButton: true, isSelected: true),
        );
        expect(
          tester.getSemantics(find.bySemanticsLabel('Stroke')),
          isSemantics(label: 'Stroke', isButton: true, isSelected: false),
        );

        EraserPreviewPainter preview() {
          final CustomPaint paint = tester.widget<CustomPaint>(
            find.byKey(const ValueKey<String>('eraser-size-preview')),
          );
          return paint.painter! as EraserPreviewPainter;
        }

        expect(preview().size, 24);

        // Drag the thumb to the far end of the track.
        final Rect track = tester.getRect(find.byType(Slider));
        await tester.dragFrom(
          Offset(track.left + 30, track.center.dy),
          Offset(track.width, 0),
        );
        await tester.pumpAndSettle();

        expect(_slider(tester).value, 80);
        expect(preview().size, 80);
        expect(find.text('80 px'), findsOneWidget);
        expect(find.bySemanticsLabel('Eraser, Area, 80 px'), findsOneWidget);

        await tester.tap(find.text('Stroke'));
        await tester.pumpAndSettle();

        expect(
          tester
              .widget<SelectionCapsule>(
                find.descendant(
                  of: find.byType(EraserOptions),
                  matching: find.byType(SelectionCapsule),
                ),
              )
              .index,
          EraserMode.values.indexOf(EraserMode.stroke),
        );
        expect(find.bySemanticsLabel('Eraser, Stroke'), findsOneWidget);
        // The popover stays open so the size can be set after the mode.
        expect(find.byType(EraserOptions), findsOneWidget);
        expect(tester.takeException(), isNull);
        handle.dispose();
      });
    });
  }

  testWidgets(
    'the size slider is disabled in stroke mode and keeps its value',
    (WidgetTester tester) async {
      await pumpEditor(tester);
      await _openEraserOptions(tester);
      _slider(tester).onChanged!(40);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Stroke'));
      await tester.pumpAndSettle();

      expect(_slider(tester).onChanged, isNull);
      expect(_slider(tester).value, 40);
      expect(find.text('40 px'), findsOneWidget);

      await tester.tap(find.text('Area'));
      await tester.pumpAndSettle();

      expect(_slider(tester).onChanged, isNotNull);
      expect(_slider(tester).value, 40);
      expect(find.bySemanticsLabel('Eraser, Area, 40 px'), findsOneWidget);
    },
  );

  testWidgets('area mode cuts the stroke under the eraser, live', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(
      tester,
      penConfig: const PenConfig(strokeWidthScale: 1),
    );
    Offset at(double x, double y) => pageToGlobal(tester, Offset(x, y));
    final Offset from = at(100, 200);
    final Offset to = at(400, 200);
    await _drag(tester, from, to);
    final StrokeStyle style = controller.strokes.single.style;
    await _selectEraser(tester);

    // Down beside the stroke, then across it; finger input erases too.
    final Offset middle = at(250, 200);
    final TestGesture gesture = await tester.startGesture(
      middle - const Offset(0, 50),
      kind: PointerDeviceKind.touch,
    );
    expect(controller.strokes.single.source, StrokeSource.input);
    for (int i = 1; i <= 10; i++) {
      await gesture.moveBy(const Offset(0, 10), timeStamp: _sampleInterval * i);
    }
    await tester.pump();

    // Still mid-gesture: the cut is already made and already on screen.
    expect(controller.activeErase, isNotNull);
    expect(controller.strokes.length, 2);
    expect(
      (await captureScreen(tester)).at(middle + const Offset(6, 0)),
      isSameColorAs(AppColors.light.writingSurface),
    );

    await gesture.up(timeStamp: _sampleInterval * 11);
    await tester.pump();

    // No new ink was drawn, and the two pieces keep their look.
    expect(controller.activeErase, isNull);
    expect(controller.activeStroke, isNull);
    expect(controller.strokes.length, 2);
    for (final Stroke piece in controller.strokes) {
      expect(piece.source, StrokeSource.derived);
      expect(piece.style, same(style));
    }
    // The eraser is 24 px across on screen, whatever the zoom, plus half
    // the 3 px stroke either side.
    final double reach = 12 / canvasScale(tester) + 1.5;
    expect(controller.strokes[0].points.first.x, closeTo(100, 1e-6));
    expect(controller.strokes[0].points.first.y, closeTo(200, 1e-6));
    expect(controller.strokes[0].points.last.x, closeTo(250 - reach, 1e-6));
    expect(controller.strokes[1].points.first.x, closeTo(250 + reach, 1e-6));
    expect(controller.strokes[1].points.last.x, closeTo(400, 1e-6));
    final ScreenPixels pixels = await captureScreen(tester);
    expect(pixels.at(middle), isSameColorAs(AppColors.light.writingSurface));
    for (final double x in <double>[150, 230, 270, 350]) {
      expect(
        pixels.at(at(x, 200)),
        isSameColorAs(InkPalette.ink.onLightPaper),
        reason: 'x = $x',
      );
    }
  });

  testWidgets('a fast flick still cuts the stroke it jumps over', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    final Offset origin = canvasRect(tester).topLeft;
    await _drag(
      tester,
      origin + const Offset(100, 200),
      origin + const Offset(400, 200),
    );
    await _selectEraser(tester);

    // Two samples, 300 px apart, on either side of the stroke.
    await _drag(
      tester,
      origin + const Offset(250, 50),
      origin + const Offset(250, 350),
      steps: 1,
    );

    expect(controller.strokes.length, 2);
  });

  testWidgets('stroke mode removes every stroke it touches, whole', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(
      tester,
      penConfig: const PenConfig(strokeWidthScale: 1),
    );
    final Offset origin = canvasRect(tester).topLeft;
    for (final double y in <double>[200, 260, 400]) {
      await _drag(tester, origin + Offset(100, y), origin + Offset(400, y));
    }
    final Stroke untouched = controller.strokes[2];
    await _setMode(tester, EraserMode.stroke);

    await _drag(
      tester,
      origin + const Offset(250, 150),
      origin + const Offset(250, 300),
      kind: PointerDeviceKind.mouse,
    );

    expect(controller.strokes.single, same(untouched));
    final ScreenPixels pixels = await captureScreen(tester);
    expect(
      pixels.at(origin + const Offset(120, 200)),
      isSameColorAs(AppColors.light.writingSurface),
    );
    expect(
      pixels.at(origin + const Offset(120, 400)),
      isSameColorAs(InkPalette.ink.onLightPaper),
    );
  });

  testWidgets('a tap with the eraser removes a dot and draws nothing', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    final Offset position = canvasRect(tester).topLeft + const Offset(150, 150);
    await tester.tapAt(position, kind: PointerDeviceKind.stylus);
    await tester.pump();
    expect(controller.strokes.single.isDot, isTrue);
    await _selectEraser(tester);

    // Once on empty paper, once on the dot.
    await tester.tapAt(position + const Offset(200, 0));
    await tester.pump();
    expect(controller.strokes.length, 1);
    await tester.tapAt(position + const Offset(5, 5));
    await tester.pump();

    expect(controller.strokes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching back to the pen draws with the same color and width', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(
      tester,
      penConfig: const PenConfig(strokeWidthScale: 1),
    );
    final Offset origin = canvasRect(tester).topLeft;
    final InkColor blue = InkPalette.colors.firstWhere(
      (InkColor ink) => ink.id == 'blue',
    );
    // The pen starts selected, so one press opens its options.
    await tester.tap(find.byTooltip('Pen'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('ink-swatch-blue')));
    await tester.pumpAndSettle();
    _slider(tester).onChanged!(10);
    await tester.pumpAndSettle();
    await _dismiss(tester);
    await _drag(
      tester,
      origin + const Offset(100, 200),
      origin + const Offset(400, 200),
    );

    // Erase with every option changed along the way.
    await _openEraserOptions(tester);
    _slider(tester).onChanged!(60);
    await tester.pumpAndSettle();
    await _dismiss(tester);
    await _drag(
      tester,
      origin + const Offset(250, 100),
      origin + const Offset(250, 300),
    );
    expect(controller.strokes.length, 2);
    await _setMode(tester, EraserMode.stroke);

    await tester.tap(find.byTooltip('Pen'));
    await tester.pumpAndSettle();
    await _drag(
      tester,
      origin + const Offset(100, 400),
      origin + const Offset(400, 400),
    );

    expect(controller.strokes.length, 3);
    final Stroke drawn = controller.strokes.last;
    expect(drawn.source, StrokeSource.input);
    expect(drawn.style.ink, blue);
    expect(drawn.style.width, 10);
    expect(find.bySemanticsLabel('Pen, Blue, 10 px'), findsOneWidget);
  });

  testWidgets('pen color and width live in the pen, not beside the eraser', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await pumpEditor(tester);
    await _selectEraser(tester);

    // Pressing the pen while the eraser is selected selects the pen; the
    // pen's options open on the next press, and leave the eraser alone.
    await tester.tap(find.byTooltip('Pen'));
    await tester.pumpAndSettle();
    expect(_isSelected(tester, 'Pen'), isTrue);
    await tester.tap(find.byTooltip('Pen'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('ink-swatch-red')));
    await tester.pumpAndSettle();
    _slider(tester).onChanged!(7);
    await tester.pumpAndSettle();
    await _dismiss(tester);

    expect(find.bySemanticsLabel('Pen, Red, 7 px'), findsOneWidget);
    expect(find.bySemanticsLabel('Eraser, Area, 24 px'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('the tap that dismisses the eraser options erases nothing', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    final Rect canvas = canvasRect(tester);
    await _drag(
      tester,
      canvas.center - const Offset(100, 0),
      canvas.center + const Offset(100, 0),
    );
    final Stroke stroke = controller.strokes.single;
    await _openEraserOptions(tester);
    final ToolPaletteController palette = tester
        .widget<ToolPalette>(find.byType(ToolPalette))
        .controller!;
    expect(palette.hasOpenPopover, isTrue);

    // Right on the stroke.
    await tester.tapAt(canvas.center);
    await tester.pumpAndSettle();

    expect(find.byType(EraserOptions), findsNothing);
    expect(palette.hasOpenPopover, isFalse);
    expect(controller.strokes.single, same(stroke));
    expect(controller.activeErase, isNull);

    // The next touch does erase.
    await tester.tapAt(canvas.center);
    await tester.pump();
    expect(controller.strokes.length, 2);
  });

  testWidgets('an inverted stylus erases while the pen stays selected', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final InkController controller = await pumpEditor(
      tester,
      penConfig: const PenConfig(strokeWidthScale: 1),
    );
    Offset at(double x, double y) => pageToGlobal(tester, Offset(x, y));
    await _drag(tester, at(100, 200), at(400, 200));

    await _drag(
      tester,
      at(250, 150),
      at(250, 250),
      kind: PointerDeviceKind.invertedStylus,
    );

    // It used the current eraser settings: area mode at 24 px.
    expect(controller.strokes.length, 2);
    expect(
      controller.strokes[0].points.last.x,
      closeTo(250 - 12 / canvasScale(tester) - 1.5, 1e-6),
    );
    expect(_isSelected(tester, 'Pen'), isTrue);
    expect(_isSelected(tester, 'Eraser'), isFalse);

    // The tip still writes.
    await _drag(tester, at(100, 300), at(400, 300));
    expect(controller.strokes.length, 3);
    expect(controller.strokes.last.source, StrokeSource.input);
    handle.dispose();
  });

  testWidgets('the indicator shows only while erasing, at the eraser size', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    final Offset position = pageToGlobal(tester, const Offset(300, 300));
    // Sizes are on screen; the eraser's reach on the page is that over the
    // zoom.
    final double scale = canvasScale(tester);
    await _openEraserOptions(tester);
    _slider(tester).onChanged!(40);
    await tester.pumpAndSettle();
    await _dismiss(tester);
    final Matcher paper = isSameColorAs(AppColors.light.writingSurface);
    const List<Offset> directions = <Offset>[
      Offset(1, 0),
      Offset(-1, 0),
      Offset(0, 1),
      Offset(0, -1),
    ];

    /// Whether an outline of [radius] is drawn around [center].
    Future<bool> hasRing(Offset center, double radius) async {
      final ScreenPixels pixels = await captureScreen(tester);
      expect(pixels.at(center), paper);
      return directions.every((Offset direction) {
        // The 1 px outline straddles two pixels; either may carry it.
        return <double>[radius - 1, radius].any((double distance) {
          return !paper.matches(pixels.at(center + direction * distance), {});
        });
      });
    }

    expect(await hasRing(position, 20), isFalse);
    expect(
      find.byKey(const ValueKey<String>('eraser-indicator')),
      findsOneWidget,
    );

    final TestGesture gesture = await tester.startGesture(position);
    await tester.pump();

    expect(controller.activeErase!.mode, EraserMode.area);
    expect(controller.activeErase!.radius, closeTo(20 / scale, 1e-9));
    expect(await hasRing(position, 20), isTrue);
    expect(await hasRing(position, 12), isFalse);

    // It follows the pointer.
    await gesture.moveBy(const Offset(90, 30), timeStamp: _sampleInterval);
    await tester.pump();
    expect(controller.activeErase!.position.x, closeTo(300 + 90 / scale, 1e-6));
    expect(controller.activeErase!.position.y, closeTo(300 + 30 / scale, 1e-6));
    expect(await hasRing(position, 20), isFalse);
    expect(await hasRing(position + const Offset(90, 30), 20), isTrue);

    await gesture.up(timeStamp: _sampleInterval * 2);
    await tester.pump();
    expect(await hasRing(position + const Offset(90, 30), 20), isFalse);

    // Stroke mode shows the small hit radius instead.
    await _setMode(tester, EraserMode.stroke);
    final TestGesture second = await tester.startGesture(position);
    await tester.pump();
    expect(controller.activeErase!.radius, closeTo(6 / scale, 1e-9));
    expect(await hasRing(position, 6), isTrue);
    expect(await hasRing(position, 20), isFalse);
    await second.cancel();
    await tester.pump();
    expect(await hasRing(position, 6), isFalse);
  });

  testWidgets('the indicator is clipped, unlabelled, and themed', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final InkController controller = await pumpEditor(
      tester,
      themeMode: ThemeMode.dark,
    );
    await _selectEraser(tester);
    final CustomPaint layer = tester.widget<CustomPaint>(
      find.byKey(const ValueKey<String>('eraser-indicator')),
    );
    final EraserIndicatorPainter painter =
        layer.painter! as EraserIndicatorPainter;
    expect(painter.color, AppColors.dark.textPrimary);
    expect(painter.haloColor, AppColors.dark.writingSurface);
    expect(
      contrastRatio(painter.color, AppColors.dark.writingSurface),
      greaterThan(3),
    );
    expect(
      contrastRatio(
        AppColors.light.textPrimary,
        AppColors.light.writingSurface,
      ),
      greaterThan(3),
    );

    // Dragged off the top of the page, over the app bar, from beside the
    // palette floating across the top.
    final Offset inside = pageToGlobal(tester, const Offset(40, 40));
    // Where the ring's top would be, off the page: it shows what was there.
    final Offset outside = inside + const Offset(0, -60 - 11);
    final Color chrome = (await captureScreen(tester)).at(outside);
    final TestGesture gesture = await tester.startGesture(
      inside,
      kind: PointerDeviceKind.stylus,
    );
    await gesture.moveBy(const Offset(0, -60), timeStamp: _sampleInterval);
    await tester.pump();

    expect(controller.activeErase!.position.y, lessThan(0));
    expect((await captureScreen(tester)).at(outside), isSameColorAs(chrome));
    // Nothing about the indicator reaches the semantics tree.
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('Writing surface'))
          .childrenCount,
      0,
    );
    await gesture.up();
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  testWidgets('eraser moves repaint without rebuilding widgets', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    final Offset origin = canvasRect(tester).topLeft;
    await _drag(
      tester,
      origin + const Offset(100, 200),
      origin + const Offset(400, 200),
    );
    await _selectEraser(tester);
    final TestGesture gesture = await tester.startGesture(
      origin + const Offset(120, 150),
    );
    await tester.pump();

    int rebuilds = 0;
    debugOnRebuildDirtyWidget = (Element element, bool builtOnce) => rebuilds++;
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    for (int i = 1; i <= 20; i++) {
      await gesture.moveBy(
        Offset(40, i.isOdd ? 100 : -100),
        timeStamp: _sampleInterval * i,
      );
      await tester.pump();
    }
    debugOnRebuildDirtyWidget = null;
    await gesture.up();

    expect(rebuilds, 0);
    expect(controller.strokes.length, greaterThan(5));
  });

  testWidgets('changing the tool mid-gesture ends that gesture first', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    final Offset origin = canvasRect(tester).topLeft;

    // The pen is down when a second pointer presses the eraser button.
    final TestGesture pen = await tester.startGesture(
      origin + const Offset(100, 200),
      kind: PointerDeviceKind.stylus,
    );
    await pen.moveBy(const Offset(300, 0), timeStamp: _sampleInterval);
    await _selectEraser(tester);

    expect(controller.activeStroke, isNull);
    final Stroke stroke = controller.strokes.single;
    // The rest of that gesture neither writes nor erases.
    await pen.moveBy(const Offset(-150, 0), timeStamp: _sampleInterval * 2);
    await pen.up(timeStamp: _sampleInterval * 3);
    await tester.pump();
    expect(controller.strokes.single, same(stroke));

    // And the other way round.
    final TestGesture eraser = await tester.startGesture(
      origin + const Offset(250, 100),
    );
    await tester.tap(find.byTooltip('Pen'));
    await tester.pumpAndSettle();
    expect(controller.activeErase, isNull);
    await eraser.moveBy(const Offset(0, 200), timeStamp: _sampleInterval);
    await eraser.up(timeStamp: _sampleInterval * 2);
    await tester.pump();

    expect(controller.strokes.single, same(stroke));
    expect(controller.activeStroke, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling an erase keeps what was erased', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    final Offset origin = canvasRect(tester).topLeft;
    await _drag(
      tester,
      origin + const Offset(100, 200),
      origin + const Offset(400, 200),
    );
    await _selectEraser(tester);

    final TestGesture gesture = await tester.startGesture(
      origin + const Offset(250, 150),
    );
    await gesture.moveBy(const Offset(0, 100), timeStamp: _sampleInterval);
    await gesture.cancel(timeStamp: _sampleInterval * 2);
    await tester.pump();

    expect(controller.activeErase, isNull);
    expect(controller.activePointer, isNull);
    expect(controller.strokes.length, 2);
    expect(tester.takeException(), isNull);

    // The canvas still accepts a new erase gesture.
    await _drag(
      tester,
      origin + const Offset(150, 150),
      origin + const Offset(150, 250),
    );
    expect(controller.strokes.length, 3);
  });

  testWidgets('rotating mid-erase ends the gesture and keeps the result', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(
      tester,
      viewport: TestViewport.tabletPortrait,
    );
    final Offset origin = canvasRect(tester).topLeft;
    for (final double y in <double>[200, 400]) {
      await _drag(tester, origin + Offset(100, y), origin + Offset(400, y));
    }
    await _selectEraser(tester);

    final TestGesture gesture = await tester.startGesture(
      origin + const Offset(250, 150),
    );
    await gesture.moveBy(const Offset(0, 100), timeStamp: _sampleInterval);
    expect(controller.activeErase, isNotNull);
    expect(controller.strokes.length, 3);

    setViewportSize(tester, TestViewport.tabletPortrait.size.flipped);
    await tester.pumpAndSettle();

    expect(controller.activeErase, isNull);
    // The pointer that was down no longer erases.
    await gesture.moveBy(const Offset(0, 200), timeStamp: _sampleInterval * 2);
    await gesture.up(timeStamp: _sampleInterval * 3);
    await tester.pump();

    expect(controller.strokes.length, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tool, mode, and size survive rotation and breakpoint changes', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final InkController controller = await pumpEditor(
      tester,
      viewport: TestViewport.tabletPortrait,
    );
    await _openEraserOptions(tester);
    _slider(tester).onChanged!(52);
    await tester.pumpAndSettle();
    await _dismiss(tester);

    const List<Size> sizes = <Size>[
      Size(1280, 800),
      Size(390, 844),
      Size(1194, 834),
    ];
    for (final Size size in sizes) {
      setViewportSize(tester, size);
      await tester.pumpAndSettle();

      expect(_isSelected(tester, 'Eraser'), isTrue, reason: '$size');
      expect(_isSelected(tester, 'Pen'), isFalse, reason: '$size');
      expect(
        find.bySemanticsLabel('Eraser, Area, 52 px'),
        findsOneWidget,
        reason: '$size',
      );
      expect(tester.takeException(), isNull);
    }

    await _setMode(tester, EraserMode.stroke);
    for (final Size size in sizes) {
      setViewportSize(tester, size);
      await tester.pumpAndSettle();

      expect(_isSelected(tester, 'Eraser'), isTrue, reason: '$size');
      expect(
        find.bySemanticsLabel('Eraser, Stroke'),
        findsOneWidget,
        reason: '$size',
      );
    }
    // The size came through stroke mode and the rebuilds intact.
    await _openEraserOptions(tester);
    expect(_slider(tester).value, 52);
    await _dismiss(tester);
    final Offset position = canvasRect(tester).center;
    final TestGesture gesture = await tester.startGesture(position);
    expect(controller.activeErase!.mode, EraserMode.stroke);
    await gesture.up();
    handle.dispose();
  });

  test('eraser edge does not become thicker when zoomed in', () {
    final InkController controller = InkController();
    controller.startErase(
      pointer: 1,
      position: const InkVector(100, 100),
      settings: const EraserSettings(mode: EraserMode.area, size: 24),
      screenScale: 2.0,
    );

    final _IndicatorRecordingCanvas canvas = _IndicatorRecordingCanvas();
    final EraserIndicatorPainter painter = EraserIndicatorPainter(
      controller: controller,
      color: const Color(0xFF000000),
      haloColor: const Color(0xFFFFFFFF),
      scale: 2.0,
    );
    painter.paint(canvas, const Size(500, 500));

    expect(canvas.strokes, hasLength(2));
    // Halo width (normally 3.0) is scaled down by 2.0 to 1.5 so on-screen width is 3.0.
    expect(canvas.strokes[0].$2, closeTo(1.5, 1e-9));
    // Outline width (normally 1.0) is scaled down by 2.0 to 0.5 so on-screen width is 1.0.
    expect(canvas.strokes[1].$2, closeTo(0.5, 1e-9));
    controller.dispose();
  });
}

class _IndicatorRecordingCanvas extends Fake implements Canvas {
  final List<(double radius, double strokeWidth)> strokes = [];

  @override
  void drawCircle(Offset c, double radius, Paint paint) {
    strokes.add((radius, paint.strokeWidth));
  }
}
