import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/pen_settings.dart';
import 'package:greatnote/features/editor/ink/shape_config.dart';
import 'package:greatnote/features/editor/ink/smoothing_config.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/app/theme/app_theme.dart';

import '../../helpers/editor_harness.dart';
import '../../helpers/pump_app.dart';

const StrokeStyle _style = StrokeStyle(ink: InkPalette.ink, width: 4);

/// A straight stroke 200 px long, sampled every 4 px, with [pressure] at
/// each sample.
Stroke _draw(StrokeDynamics dynamics, {double? Function(int)? pressure}) {
  RawInkSample sample(int i) => RawInkSample(
    position: InkVector(4.0 * i, 0),
    timestamp: Duration(milliseconds: 8 * i),
    pressure: pressure?.call(i),
  );
  final ActiveStroke active = ActiveStroke(
    style: _style,
    first: sample(0),
    dynamics: dynamics,
  );
  for (int i = 1; i <= 50; i++) {
    active.add(sample(i));
  }
  return active.finish();
}

/// Draws a pen line on the page with a stylus that reports [pressure].
Future<void> _penLine(
  WidgetTester tester,
  Offset from,
  Offset to, {
  double pressure = 0.5,
}) async {
  const int pointer = 77;
  Future<void> send(PointerEvent event) async {
    tester.binding.handlePointerEvent(event);
    await tester.pump();
  }

  await send(
    PointerDownEvent(
      pointer: pointer,
      device: pointer,
      position: from,
      kind: PointerDeviceKind.stylus,
      pressure: pressure,
      pressureMin: 0,
      pressureMax: 1,
    ),
  );
  for (int i = 1; i <= 20; i++) {
    await send(
      PointerMoveEvent(
        pointer: pointer,
        device: pointer,
        timeStamp: Duration(milliseconds: 8 * i),
        position: Offset.lerp(from, to, i / 20)!,
        kind: PointerDeviceKind.stylus,
        pressure: pressure,
        pressureMin: 0,
        pressureMax: 1,
      ),
    );
  }
  await send(
    PointerUpEvent(
      pointer: pointer,
      device: pointer,
      timeStamp: const Duration(milliseconds: 176),
      position: to,
      kind: PointerDeviceKind.stylus,
      pressureMin: 0,
      pressureMax: 1,
    ),
  );
}

Future<void> _openAdvanced(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('pen-advanced-toggle')));
  await tester.pumpAndSettle();
}

void main() {
  group('settings', () {
    test('defaults: round tips, no pressure, light stabilization', () {
      final PenSettings pen = PenSettings.defaults();
      expect(pen.tipSharpness, 0);
      expect(pen.pressureSensitivity, 0);
      expect(pen.stabilization, 0.25);
      expect(pen.holdToShape, isTrue);
      expect(pen.dynamics.isNone, isTrue);
    });

    test('50% stabilization is the smoother as configured', () {
      const SmoothingConfig base = SmoothingConfig();
      expect(
        PenSettings.defaults().copyWith(stabilization: 0.5).smoothing(base),
        same(base),
      );
    });

    test('more stabilization smooths harder; 0% barely smooths', () {
      const SmoothingConfig base = SmoothingConfig();
      final PenSettings pen = PenSettings.defaults();
      double cutoff(double stabilization) =>
          pen.copyWith(stabilization: stabilization).smoothing(base).minCutoff;
      expect(cutoff(1), lessThan(base.minCutoff));
      expect(cutoff(0.25), greaterThan(base.minCutoff));
      expect(cutoff(0), greaterThan(cutoff(0.25)));
      expect(cutoff(0), closeTo(base.minCutoff * 60, 1e-9));
    });

    test('the slow-drawing steadiness fades out with the slider', () {
      const SmoothingConfig base = SmoothingConfig(slowCutoffScale: 0.25);
      final PenSettings pen = PenSettings.defaults();
      double scale(double stabilization) => pen
          .copyWith(stabilization: stabilization)
          .smoothing(base)
          .slowCutoffScale;
      expect(scale(0), 1);
      expect(scale(0.25), closeTo(0.625, 1e-9));
      expect(scale(0.5), 0.25);
      expect(scale(1), 0.25);
    });

    test('pressure at 0% leaves only the taper', () {
      final PenSettings pen = PenSettings.defaults().copyWith(
        tipSharpness: 0.5,
      );
      expect(pen.dynamics.pressure, 0);
      expect(pen.dynamics.taper, 0.5);
    });
  });

  group('stroke width', () {
    test('an even stroke has no widths and draws by its path', () {
      final Stroke stroke = _draw(StrokeDynamics.none);
      expect(stroke.widths, isNull);
      expect(stroke.outline, isNull);
    });

    test('a sharp tip narrows both ends and keeps the middle full', () {
      final Stroke stroke = _draw(const StrokeDynamics(taper: 1));
      final List<double> widths = stroke.widths!;
      expect(widths, hasLength(stroke.points.length));
      expect(widths.first, lessThan(0.3));
      expect(widths.last, lessThan(0.3));
      expect(widths[widths.length ~/ 2], 1);
      expect(stroke.outline, isNotNull);
      // Never drawn outside its bounds.
      expect(
        stroke.bounds
            .inflate(0.01)
            .contains(stroke.outline!.getBounds().topLeft),
        isTrue,
      );
    });

    test('a sharper tip narrows further', () {
      final double soft = _draw(const StrokeDynamics(taper: 0.2)).widths!.first;
      final double sharp = _draw(
        const StrokeDynamics(taper: 0.9),
      ).widths!.first;
      expect(sharp, lessThan(soft));
    });

    test('pressing harder draws wider, lighter narrower', () {
      const StrokeDynamics dynamics = StrokeDynamics(pressure: 1);
      final double hard = _draw(dynamics, pressure: (_) => 1).widths![25];
      final double light = _draw(dynamics, pressure: (_) => 0).widths![25];
      final double none = _draw(dynamics).widths![25];
      expect(hard, greaterThan(1.5));
      expect(light, lessThan(0.5));
      // A device without pressure leaves the width as set.
      expect(none, 1);
    });

    test('bounds grow to hold ink pressed wider than the set width', () {
      final Stroke stroke = _draw(
        const StrokeDynamics(pressure: 1),
        pressure: (_) => 1,
      );
      final double widest = stroke.widths!.reduce(math.max);
      expect(stroke.bounds.height, closeTo(_style.width * widest, 0.01));
    });

    test('erasing through the middle keeps each piece its widths', () {
      final Stroke stroke = _draw(const StrokeDynamics(taper: 1));
      final InkController controller = InkController(strokes: <Stroke>[stroke]);
      addTearDown(controller.dispose);
      controller
        ..startErase(
          pointer: 1,
          position: const InkVector(100, -20),
          settings: const EraserSettings(mode: EraserMode.area, size: 10),
        )
        ..endErase(1, const InkVector(100, 20));

      expect(controller.strokes, hasLength(2));
      final Stroke left = controller.strokes.first;
      final Stroke right = controller.strokes.last;
      // The tapered ends are kept; the cut ends are full width.
      expect(left.widths!.first, stroke.widths!.first);
      expect(left.widths!.last, closeTo(1, 1e-9));
      expect(right.widths!.first, closeTo(1, 1e-9));
      expect(right.widths!.last, stroke.widths!.last);
    });
  });

  group('on the page', () {
    testWidgets('a pen stroke is even by default, whatever the pressure', (
      WidgetTester tester,
    ) async {
      final InkController controller = await pumpEditor(tester);
      final Offset origin = canvasRect(tester).topLeft;
      await _penLine(
        tester,
        origin + const Offset(100, 300),
        origin + const Offset(400, 300),
        pressure: 1,
      );
      expect(controller.strokes.single.widths, isNull);
    });

    testWidgets('with sensitivity up, stylus pressure widens the line', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<PenSettings> pen = ValueNotifier<PenSettings>(
        PenSettings.defaults().copyWith(pressureSensitivity: 0.5),
      );
      addTearDown(pen.dispose);
      final InkController controller = InkController();
      addTearDown(controller.dispose);
      await pumpApp(
        tester,
        home: EditorScreen(inkController: controller, penSettings: pen),
      );
      final Offset origin = canvasRect(tester).topLeft;
      await _penLine(
        tester,
        origin + const Offset(100, 300),
        origin + const Offset(400, 300),
        pressure: 1,
      );
      final List<double> widths = controller.strokes.single.widths!;
      expect(widths[widths.length ~/ 2], greaterThan(1));
    });

    testWidgets('with Draw and hold off, holding still keeps the stroke', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<PenSettings> pen = ValueNotifier<PenSettings>(
        PenSettings.defaults().copyWith(holdToShape: false),
      );
      addTearDown(pen.dispose);
      final InkController controller = InkController();
      addTearDown(controller.dispose);
      await pumpApp(
        tester,
        home: EditorScreen(inkController: controller, penSettings: pen),
      );
      final Offset start = canvasRect(tester).topLeft + const Offset(100, 300);
      final TestGesture gesture = await tester.startGesture(
        start,
        kind: PointerDeviceKind.stylus,
      );
      for (int i = 1; i <= 20; i++) {
        await gesture.moveTo(
          start + Offset(15.0 * i, 0),
          timeStamp: Duration(milliseconds: 8 * i),
        );
      }
      await tester.pump(
        const ShapeConfig().holdDuration + const Duration(milliseconds: 50),
      );
      expect(controller.activeShape, isNull);
      expect(controller.activeStroke, isNotNull);
      await gesture.up();
      await tester.pump();
      expect(controller.strokes.single.source, StrokeSource.input);
    });
  });

  group('the pen options', () {
    testWidgets('show the basics; the advanced settings open on the left', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await pumpEditor(tester);

      expect(find.byKey(const ValueKey<String>('pen-advanced')), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('pen-advanced-toggle')),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('Advanced pen settings')),
        isSemantics(isButton: true),
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('pen-advanced-toggle')),
      );
      await tester.pumpAndSettle();
      final Finder panel = find.byKey(const ValueKey<String>('pen-advanced'));
      expect(panel, findsOneWidget);
      final Rect screen =
          Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(tester.getRect(panel).left, lessThan(screen.width / 4));
      for (final String label in <String>[
        'Tip sharpness',
        'Pressure sensitivity',
        'Stroke stabilization',
        'Draw and hold for shapes',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      // No on/off switches: 0% is off.
      expect(find.byType(Switch), findsNothing);
      expect(find.text('Off'), findsNWidgets(2));
      expect(find.text('25%'), findsOneWidget);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      handle.dispose();
    });

    testWidgets('changes reach the pen, and carry to the next note', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<PenSettings> pen = ValueNotifier<PenSettings>(
        PenSettings.defaults(),
      );
      addTearDown(pen.dispose);
      await pumpApp(tester, home: EditorScreen(penSettings: pen));
      await _openAdvanced(tester);

      Slider slider(String key) => tester.widget<Slider>(
        find.descendant(
          of: find.byKey(ValueKey<String>(key)),
          matching: find.byType(Slider),
        ),
      );

      slider('pen-pressure').onChanged!(0.6);
      await tester.pumpAndSettle();
      expect(pen.value.pressureSensitivity, 0.6);
      expect(find.text('60%'), findsOneWidget);

      slider('pen-stabilization').onChanged!(0);
      await tester.pumpAndSettle();
      expect(pen.value.stabilization, 0);

      await tester.tap(find.text('Draw and hold for shapes'));
      await tester.pumpAndSettle();
      expect(pen.value.holdToShape, isFalse);

      await tester.ensureVisible(find.text('Reset to defaults'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset to defaults'));
      await tester.pumpAndSettle();
      expect(pen.value, PenSettings.defaults());
    });
  });

  group('the eraser', () {
    test('is as big on screen at any zoom', () {
      final InkController controller = InkController();
      addTearDown(controller.dispose);
      const EraserSettings settings = EraserSettings(
        mode: EraserMode.area,
        size: 40,
      );
      controller.startErase(
        pointer: 1,
        position: const InkVector(10, 10),
        settings: settings,
        screenScale: 2,
      );
      // Twice the zoom: half as far on the page, 40 px on screen.
      expect(controller.activeErase!.radius, 10);
      controller.cancelErase(1);

      controller.startErase(
        pointer: 2,
        position: const InkVector(10, 10),
        settings: const EraserSettings(mode: EraserMode.stroke, size: 40),
        screenScale: 0.5,
      );
      expect(
        controller.activeErase!.radius,
        const EraserConfig().strokeHitRadius * 2,
      );
    });

    testWidgets('on a scaled page, its reach on the page shrinks with it', (
      WidgetTester tester,
    ) async {
      final InkController controller = InkController();
      addTearDown(controller.dispose);
      final ValueNotifier<EditorTool> tool = ValueNotifier<EditorTool>(
        EditorTool.eraser,
      );
      final ValueNotifier<PenSettings> pen = ValueNotifier<PenSettings>(
        PenSettings.defaults(),
      );
      final ValueNotifier<EraserSettings> eraser =
          ValueNotifier<EraserSettings>(
            const EraserSettings(mode: EraserMode.area, size: 40),
          );
      addTearDown(tool.dispose);
      addTearDown(pen.dispose);
      addTearDown(eraser.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Align(
            alignment: Alignment.topLeft,
            child: Transform.scale(
              scale: 4,
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 100,
                height: 100,
                child: InkCanvas(
                  controller: controller,
                  tool: tool,
                  penSettings: pen,
                  eraserSettings: eraser,
                ),
              ),
            ),
          ),
        ),
      );
      final TestGesture gesture = await tester.startGesture(
        const Offset(200, 200),
        kind: PointerDeviceKind.stylus,
      );
      await tester.pump();
      expect(controller.activeErase!.radius, closeTo(5, 1e-9));
      await gesture.up();
    });
  });
}
