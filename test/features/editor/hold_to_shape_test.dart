import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/shape_config.dart';
import 'package:greatnote/features/editor/ink/shape_recognizer.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

import '../../helpers/editor_harness.dart';

const Duration _sampleInterval = Duration(milliseconds: 8);
const ShapeConfig _config = ShapeConfig();

/// Puts the stylus down at the first of [path] and moves through the rest,
/// leaving it down.
Future<TestGesture> _trace(WidgetTester tester, List<Offset> path) async {
  final TestGesture gesture = await tester.startGesture(
    path.first,
    kind: PointerDeviceKind.stylus,
  );
  for (int i = 1; i < path.length; i++) {
    await gesture.moveTo(path[i], timeStamp: _sampleInterval * i);
  }
  await tester.pump();
  return gesture;
}

List<Offset> _circle(Offset center, double radius) {
  return <Offset>[
    for (int i = 0; i <= 72; i++)
      center +
          Offset(
                math.cos(2 * math.pi * i / 72),
                math.sin(2 * math.pi * i / 72),
              ) *
              (radius + 2 * math.sin(i / 5)),
  ];
}

Future<void> _hold(WidgetTester tester) async {
  await tester.pump(_config.holdDuration + const Duration(milliseconds: 20));
}

void main() {
  testWidgets('holding still at the end of a circle turns it into one', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    // A 100 unit circle on the page, however large it is on screen.
    final Offset center = pageToGlobal(tester, const Offset(300, 250));
    final TestGesture gesture = await _trace(
      tester,
      _circle(center, 100 * canvasScale(tester)),
    );
    expect(controller.strokes, isEmpty);

    await _hold(tester);

    // The shape is shown, not yet committed, while the pen is down.
    expect(controller.activeStroke, isNull);
    expect(controller.strokes, isEmpty);
    expect(controller.activeShape, isNotNull);
    expect(controller.isBusy, isTrue);
    await gesture.up();
    await tester.pump();

    final Stroke shape = controller.strokes.single;
    expect(controller.activeShape, isNull);
    expect(shape.source, StrokeSource.derived);
    expect(shape.style.ink, InkPalette.ink);
    expect(shape.points.first, shape.points.last);
    const InkVector c = InkVector(300, 250);
    for (final InkVector p in shape.points) {
      expect((p - c).length, closeTo(100, 6));
    }
  });

  testWidgets('after the snap, moving the pen scales and turns the shape', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    final Offset center = pageToGlobal(tester, const Offset(300, 250));
    final TestGesture gesture = await _trace(
      tester,
      _circle(center, 100 * canvasScale(tester)),
    );
    await _hold(tester);
    final ShapeAdjustGesture adjust = controller.activeShape!;
    final InkVector pivot = adjust.pivot;
    final double radius = (adjust.grab - pivot).length;

    // Out from the center to twice as far: the circle doubles, no new ink.
    final Offset pivotOnScreen = pageToGlobal(tester, Offset(pivot.x, pivot.y));
    final Offset grab = pageToGlobal(
      tester,
      Offset(adjust.grab.x, adjust.grab.y),
    );
    await gesture.moveTo(pivotOnScreen + (grab - pivotOnScreen) * 2);
    await tester.pump();
    expect(controller.activeShape!.scale, closeTo(2, 1e-6));
    expect(controller.strokes, isEmpty);
    for (final InkVector p in controller.activeShape!.preview.points) {
      expect((p - pivot).length, closeTo(2 * radius, 12));
    }
    await gesture.up();
    await tester.pump();
    expect(
      controller.strokes.single.points.first,
      isNot(adjust.shape.points.first),
    );
  });

  testWidgets('a snapped line turns and stretches on its start', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    final double scale = canvasScale(tester);
    final Offset start = pageToGlobal(tester, const Offset(100, 300));
    final TestGesture gesture = await _trace(tester, <Offset>[
      for (int i = 0; i <= 20; i++) start + Offset(i * 10.0, 0) * scale,
    ]);
    await _hold(tester);
    expect(controller.activeShape!.shape.kind, ShapeKind.line);

    // Swing the end a quarter turn down, half as far again.
    await gesture.moveTo(start + const Offset(0, 300) * scale);
    await tester.pump();
    await gesture.up();
    await tester.pump();
    final Stroke line = controller.strokes.single;
    final InkVector tail = line.points.first;
    final InkVector tip = line.points.last;
    expect(tail.x, closeTo(100, 6));
    expect(tip.x, closeTo(tail.x, 1));
    expect(tip.y - tail.y, closeTo(300, 6));
  });

  testWidgets('small wobble after the snap leaves the shape as it was', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    final Offset start = canvasRect(tester).topLeft + const Offset(100, 300);
    final TestGesture gesture = await _trace(tester, <Offset>[
      for (int i = 0; i <= 20; i++) start + Offset(i * 10.0, 0),
    ]);
    await _hold(tester);
    await gesture.moveBy(const Offset(1, 3));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    final Stroke line = controller.strokes.single;
    expect(line.points.first.y, line.points.last.y);
    expect(controller.activeShape, isNull);
  });

  testWidgets('a cancelled adjustment keeps the shape', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    final Offset center = canvasRect(tester).topLeft + const Offset(300, 250);
    final TestGesture gesture = await _trace(tester, _circle(center, 100));
    await _hold(tester);
    await gesture.cancel();
    await tester.pump();
    expect(controller.strokes, hasLength(1));
    expect(controller.isBusy, isFalse);
  });

  testWidgets('lifting without a hold keeps the freehand stroke', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    final Offset center = canvasRect(tester).topLeft + const Offset(300, 250);
    final TestGesture gesture = await _trace(tester, _circle(center, 100));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));

    expect(controller.strokes.single.source, StrokeSource.input);
  });

  testWidgets('a hold at the start of a stroke converts nothing', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    final Offset start = canvasRect(tester).topLeft + const Offset(200, 200);
    final TestGesture gesture = await _trace(tester, <Offset>[
      start,
      start + const Offset(4, 0),
    ]);
    await _hold(tester);
    expect(controller.activeStroke, isNotNull);

    await gesture.moveBy(const Offset(200, 0));
    await gesture.up();
    await tester.pump();
    expect(controller.strokes.single.source, StrokeSource.input);
  });

  testWidgets('holding a scribble leaves it as drawn', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    final Offset start = canvasRect(tester).topLeft + const Offset(300, 300);
    final math.Random random = math.Random(3);
    Offset at = start;
    final List<Offset> path = <Offset>[start];
    for (int i = 0; i < 80; i++) {
      at += Offset(
        (random.nextDouble() * 2 - 1) * 30,
        (random.nextDouble() * 2 - 1) * 30,
      );
      path.add(at);
    }
    final TestGesture gesture = await _trace(tester, path);
    await _hold(tester);
    expect(controller.activeStroke, isNotNull);
    await gesture.up();
    await tester.pump();
    expect(controller.strokes.single.source, StrokeSource.input);
  });

  testWidgets('jitter inside the slop still converts; leaving it restarts', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    final Offset start = canvasRect(tester).topLeft + const Offset(100, 300);
    final TestGesture gesture = await _trace(tester, <Offset>[
      for (int i = 0; i <= 30; i++) start + Offset(i * 10.0, 0),
    ]);

    // Most of the hold, then a move out of the slop: the wait starts over.
    await tester.pump(_config.holdDuration - const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.activeStroke, isNotNull);

    // Jitter within the slop does not.
    for (int i = 0; i < 4; i++) {
      await gesture.moveBy(Offset(i.isEven ? 2 : -2, 1));
      await tester.pump(const Duration(milliseconds: 60));
    }
    await _hold(tester);
    expect(controller.activeStroke, isNull);
    await gesture.up();
    await tester.pump();
    final Stroke line = controller.strokes.single;
    expect(line.points, hasLength(2));
    expect(line.points.first.y, line.points.last.y);
  });

  testWidgets('the eraser never converts', (WidgetTester tester) async {
    final InkController controller = await pumpEditor(tester);
    await tester.tap(find.byTooltip('Eraser'));
    await tester.pumpAndSettle();
    final Offset center = canvasRect(tester).topLeft + const Offset(300, 250);
    final TestGesture gesture = await _trace(tester, _circle(center, 100));
    await _hold(tester);
    expect(controller.activeErase, isNotNull);
    await gesture.up();
    await tester.pump();
    expect(controller.strokes, isEmpty);
  });
}
