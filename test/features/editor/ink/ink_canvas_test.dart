import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

import '../../../helpers/editor_harness.dart';
import '../../../helpers/pump_app.dart';

const Duration _sampleInterval = Duration(milliseconds: 8);

/// Draws a straight stroke from [from] to [to] in [steps] timed samples.
Future<void> _drawLine(
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

void _expectFinite(Stroke stroke) {
  for (final InkVector point in stroke.points) {
    expect(point.isFinite, isTrue);
  }
}

void main() {
  testWidgets('drawing shows ink during the stroke and keeps it after', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    final Offset from = pageToGlobal(tester, const Offset(100, 200));
    final Offset to = pageToGlobal(tester, const Offset(400, 200));
    final Offset middle = Offset.lerp(from, to, 0.5)!;

    final TestGesture gesture = await tester.startGesture(
      from,
      kind: PointerDeviceKind.stylus,
    );
    for (int i = 1; i <= 10; i++) {
      await gesture.moveTo(
        Offset.lerp(from, to, i / 10)!,
        timeStamp: _sampleInterval * i,
      );
    }
    await tester.pump();

    // Mid-stroke: nothing is committed, yet the ink is already on screen.
    expect(controller.strokes, isEmpty);
    expect(controller.activeStroke!.pointCount, 11);
    expect(
      (await captureScreen(tester)).at(middle),
      isSameColorAs(InkPalette.ink.onLightPaper),
    );

    await gesture.up(timeStamp: _sampleInterval * 11);
    await tester.pump();

    expect(controller.activeStroke, isNull);
    final Stroke stroke = controller.strokes.single;
    expect(stroke.isDot, isFalse);
    expect(stroke.rawSamples.length, 12);
    // Samples are stored in canvas-local coordinates.
    expect(stroke.points.first.x, closeTo(100, 1e-6));
    expect(stroke.points.first.y, closeTo(200, 1e-6));
    expect(stroke.points.last.x, closeTo(400, 1e-6));
    expect(stroke.points.last.y, closeTo(200, 1e-6));
    expect(stroke.rawSamples.first.deviceKind, InkDeviceKind.stylus);
    final ScreenPixels pixels = await captureScreen(tester);
    expect(pixels.at(middle), isSameColorAs(InkPalette.ink.onLightPaper));
    expect(
      pixels.at(middle + const Offset(0, 40)),
      isSameColorAs(AppColors.light.writingSurface),
    );
  });

  testWidgets('finger and mouse can draw; a secondary click cannot', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    final Offset origin = canvasRect(tester).topLeft + const Offset(80, 80);

    await _drawLine(
      tester,
      origin,
      origin + const Offset(100, 0),
      kind: PointerDeviceKind.touch,
    );
    await _drawLine(
      tester,
      origin + const Offset(0, 50),
      origin + const Offset(100, 50),
      kind: PointerDeviceKind.mouse,
    );
    expect(
      controller.strokes.map((Stroke s) => s.rawSamples.first.deviceKind),
      <InkDeviceKind>[InkDeviceKind.touch, InkDeviceKind.mouse],
    );

    final TestGesture rightClick = await tester.startGesture(
      origin + const Offset(0, 100),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await rightClick.moveBy(const Offset(50, 0));
    await rightClick.up();
    await tester.pump();

    expect(controller.strokes.length, 2);
  });

  testWidgets('a tap leaves a round dot', (WidgetTester tester) async {
    final InkController controller = await pumpEditor(tester);
    final Offset position = pageToGlobal(tester, const Offset(150, 150));

    await tester.tapAt(position, kind: PointerDeviceKind.stylus);
    await tester.pump();

    final Stroke dot = controller.strokes.single;
    expect(dot.isDot, isTrue);
    expect(dot.points.single.x, closeTo(150, 1e-6));
    expect(dot.points.single.y, closeTo(150, 1e-6));
    final ScreenPixels pixels = await captureScreen(tester);
    expect(pixels.at(position), isSameColorAs(InkPalette.ink.onLightPaper));
    // Default width is 3, so the dot ends well within 4 px of its center.
    for (final Offset offset in const <Offset>[
      Offset(4, 0),
      Offset(-4, 0),
      Offset(0, 4),
      Offset(0, -4),
    ]) {
      expect(
        pixels.at(position + offset),
        isSameColorAs(AppColors.light.writingSurface),
      );
    }
  });

  testWidgets('only one pointer writes; a second one is ignored', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    final double scale = canvasScale(tester);
    final Offset origin = pageToGlobal(tester, const Offset(100, 100));

    final TestGesture pen = await tester.startGesture(
      origin,
      kind: PointerDeviceKind.stylus,
    );
    await pen.moveBy(const Offset(40, 0) * scale, timeStamp: _sampleInterval);
    final int penPointer = controller.activePointer!;
    final int pointsBefore = controller.activeStroke!.pointCount;

    // A palm lands, moves, and lifts while the pen is down.
    final TestGesture palm = await tester.startGesture(
      origin + const Offset(200, 300),
      kind: PointerDeviceKind.touch,
    );
    await palm.moveBy(const Offset(30, 30), timeStamp: _sampleInterval * 2);
    await palm.up(timeStamp: _sampleInterval * 3);

    expect(controller.activePointer, penPointer);
    expect(controller.activeStroke!.pointCount, pointsBefore);
    expect(controller.strokes, isEmpty);

    await pen.moveBy(
      const Offset(40, 0) * scale,
      timeStamp: _sampleInterval * 4,
    );
    await pen.up(timeStamp: _sampleInterval * 5);
    await tester.pump();

    final Stroke stroke = controller.strokes.single;
    expect(stroke.rawSamples.first.deviceKind, InkDeviceKind.stylus);
    for (final RawInkSample sample in stroke.rawSamples) {
      expect(sample.position.y, closeTo(100, 1e-6));
    }
    expect(stroke.points.last.x, closeTo(180, 1e-6));
  });

  testWidgets('ink is clipped to the writing surface', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    final Rect canvas = canvasRect(tester);
    final Offset inside = pageToGlobal(tester, const Offset(200, 120));
    final double x = inside.dx;
    // Ends inside the app bar, above the page.
    final Offset outside = Offset(x, canvas.top - 30);
    final Color chrome = (await captureScreen(
      tester,
    )).at(Offset(x, canvas.top - 15));

    await _drawLine(tester, inside, outside, steps: 15);

    // The stroke itself runs past the edge...
    final Stroke stroke = controller.strokes.single;
    expect(stroke.points.last.y, lessThan(0));
    _expectFinite(stroke);
    // ...but only the part on the page is painted.
    expect(
      find.descendant(
        of: find.byType(InkCanvas),
        matching: find.byType(ClipRect),
      ),
      findsOneWidget,
    );
    final ScreenPixels pixels = await captureScreen(tester);
    expect(
      pixels.at(Offset(x, canvas.top + 60)),
      isSameColorAs(InkPalette.ink.onLightPaper),
    );
    expect(pixels.at(Offset(x, canvas.top - 15)), isSameColorAs(chrome));
  });

  testWidgets('color and width changes apply only to later strokes', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    final Offset origin = canvasRect(tester).topLeft + const Offset(100, 100);
    final InkColor blue = InkPalette.colors.firstWhere(
      (InkColor ink) => ink.id == 'blue',
    );

    await _drawLine(tester, origin, origin + const Offset(200, 0));

    await tester.tap(find.byTooltip('Pen'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('ink-swatch-blue')));
    await tester.pumpAndSettle();
    tester.widget<Slider>(find.byType(Slider)).onChanged!(10);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(150, 4));
    await tester.pumpAndSettle();

    final Offset second = origin + const Offset(0, 100);
    await _drawLine(tester, second, second + const Offset(200, 0));

    expect(controller.strokes.length, 2);
    expect(controller.strokes[0].style.ink, InkPalette.ink);
    expect(controller.strokes[0].style.width, 3);
    expect(controller.strokes[1].style.ink, blue);
    expect(controller.strokes[1].style.width, 10);
    final ScreenPixels pixels = await captureScreen(tester);
    expect(
      pixels.at(origin + const Offset(100, 0)),
      isSameColorAs(InkPalette.ink.onLightPaper),
    );
    expect(
      pixels.at(second + const Offset(100, 0)),
      isSameColorAs(blue.onLightPaper),
    );
    // 10 px wide: still ink 4 px off the center line, unlike the first one.
    expect(
      pixels.at(second + const Offset(100, 4)),
      isSameColorAs(blue.onLightPaper),
    );
    expect(
      pixels.at(origin + const Offset(100, 4)),
      isSameColorAs(AppColors.light.writingSurface),
    );
  });

  testWidgets('cancelling a pointer keeps valid state', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    final Offset origin = canvasRect(tester).topLeft + const Offset(100, 100);

    final TestGesture gesture = await tester.startGesture(
      origin,
      kind: PointerDeviceKind.stylus,
    );
    await gesture.moveBy(const Offset(30, 10), timeStamp: _sampleInterval);
    await gesture.moveBy(const Offset(5, 40), timeStamp: _sampleInterval * 2);
    await gesture.cancel(timeStamp: _sampleInterval * 3);
    await tester.pump();

    expect(controller.activeStroke, isNull);
    expect(controller.activePointer, isNull);
    _expectFinite(controller.strokes.single);
    expect(tester.takeException(), isNull);

    // The canvas still accepts a new stroke.
    await _drawLine(tester, origin, origin + const Offset(0, 80));
    expect(controller.strokes.length, 2);
  });

  testWidgets('rotating mid-stroke finalizes it before the new layout', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(
      tester,
      viewport: TestViewport.tabletPortrait,
    );
    final Offset origin = pageToGlobal(tester, const Offset(100, 100));

    final TestGesture gesture = await tester.startGesture(
      origin,
      kind: PointerDeviceKind.stylus,
    );
    await gesture.moveBy(
      const Offset(60, 0) * canvasScale(tester),
      timeStamp: _sampleInterval,
    );
    expect(controller.activeStroke, isNotNull);

    setViewportSize(tester, TestViewport.tabletPortrait.size.flipped);
    await tester.pumpAndSettle();

    expect(controller.activeStroke, isNull);
    final Stroke stroke = controller.strokes.single;
    expect(stroke.points.last.x, closeTo(160, 1e-6));

    // The pointer that was down no longer writes.
    await gesture.moveBy(const Offset(60, 60), timeStamp: _sampleInterval * 2);
    await gesture.up(timeStamp: _sampleInterval * 3);
    await tester.pump();

    expect(controller.strokes.single, same(stroke));
    expect(tester.takeException(), isNull);
  });

  testWidgets('pointer samples repaint the canvas without rebuilding widgets', (
    WidgetTester tester,
  ) async {
    await pumpEditor(tester);
    final Offset origin = canvasRect(tester).topLeft + const Offset(100, 100);
    final TestGesture gesture = await tester.startGesture(
      origin,
      kind: PointerDeviceKind.stylus,
    );
    await tester.pump();

    int rebuilds = 0;
    debugOnRebuildDirtyWidget = (Element element, bool builtOnce) => rebuilds++;
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    for (int i = 1; i <= 20; i++) {
      await gesture.moveBy(const Offset(6, 2), timeStamp: _sampleInterval * i);
      await tester.pump();
    }
    debugOnRebuildDirtyWidget = null;
    await gesture.up();

    expect(rebuilds, 0);
  });

  testWidgets('ink stays legible when the theme switches to dark', (
    WidgetTester tester,
  ) async {
    await pumpEditor(tester, themeMode: ThemeMode.dark);
    final Offset origin = canvasRect(tester).topLeft + const Offset(100, 100);

    await _drawLine(tester, origin, origin + const Offset(200, 0));

    final ScreenPixels pixels = await captureScreen(tester);
    expect(
      pixels.at(origin + const Offset(100, 0)),
      isSameColorAs(InkPalette.ink.onDarkPaper),
    );
    expect(
      pixels.at(origin + const Offset(100, 40)),
      isSameColorAs(AppColors.dark.writingSurface),
    );
  });
}
