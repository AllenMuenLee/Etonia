import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/pen_settings.dart';
import 'package:greatnote/features/editor/ink/pointer_claims.dart';
import 'package:greatnote/features/editor/ink/ruler.dart';
import 'package:greatnote/features/editor/ink/ruler_gesture.dart';
import 'package:greatnote/features/editor/ink/ruler_layer.dart';
import 'package:greatnote/shared/feedback/app_haptics.dart';

const RulerConfig _config = RulerConfig();

RulerState _state({
  Offset center = const Offset(200, 200),
  double degrees = 0,
  RulerUnit unit = RulerUnit.centimeters,
}) {
  return RulerState(
    center: center,
    rotationRadians: degrees * math.pi / 180,
    unit: unit,
    isVisible: true,
  );
}

double _rad(double degrees) => degrees * math.pi / 180;

void main() {
  group('geometry', () {
    test('wraps angles into [-pi, pi]', () {
      expect(
        RulerGeometry.normalize(3 * math.pi / 2),
        closeTo(-math.pi / 2, 1e-9),
      );
      expect(
        RulerGeometry.normalize(-3 * math.pi / 2),
        closeTo(math.pi / 2, 1e-9),
      );
      expect(RulerGeometry.normalize(0.3), closeTo(0.3, 1e-12));
      expect(
        const RulerState(
          center: Offset.zero,
          rotationRadians: 0,
        ).copyWith(rotationRadians: 5 * math.pi).rotationRadians.abs(),
        closeTo(math.pi, 1e-9),
      );
    });

    test('reads its angle in degrees from 0 to 360', () {
      expect(_state(degrees: 45).degrees, closeTo(45, 1e-9));
      expect(_state(degrees: -90).degrees, closeTo(270, 1e-9));
    });

    test('moves between the page and its own frame', () {
      final RulerGeometry geometry = RulerGeometry(
        _state(center: const Offset(100, 50), degrees: 90),
      );

      // Turned a quarter, the ruler's x axis points down the page.
      final Offset local = geometry.toLocal(const Offset(100, 90));
      expect(local.dx, closeTo(40, 1e-9));
      expect(local.dy, closeTo(0, 1e-9));
      final Offset back = geometry.toPage(const Offset(40, 0));
      expect(back.dx, closeTo(100, 1e-9));
      expect(back.dy, closeTo(90, 1e-9));

      final RulerGeometry tilted = RulerGeometry(
        _state(center: const Offset(10, 20), degrees: 33),
      );
      const Offset page = Offset(77, -12);
      final Offset round = tilted.toPage(tilted.toLocal(page));
      expect(round.dx, closeTo(page.dx, 1e-9));
      expect(round.dy, closeTo(page.dy, 1e-9));
    });

    test('knows the body from the page around it', () {
      final RulerGeometry level = RulerGeometry(_state());
      expect(level.containsBody(const Offset(200, 200)), isTrue);
      expect(level.containsBody(const Offset(21, 231)), isTrue);
      expect(level.containsBody(const Offset(19, 200)), isFalse);
      expect(level.containsBody(const Offset(200, 233)), isFalse);

      final RulerGeometry upright = RulerGeometry(_state(degrees: 90));
      expect(upright.containsBody(const Offset(200, 30)), isTrue);
      expect(upright.containsBody(const Offset(300, 200)), isFalse);
      expect(upright.containsDial(const Offset(215, 200), 22), isTrue);
      expect(upright.containsDial(const Offset(230, 200), 22), isFalse);
    });

    test('drops a point onto an edge', () {
      final RulerGeometry geometry = RulerGeometry(_state());

      final RulerProjection top = geometry.project(
        const Offset(150, 160),
        RulerEdge.top,
      );
      expect(top.point, const Offset(150, 168));
      expect(top.distance, closeTo(8, 1e-9));
      expect(top.along, closeTo(150 - 20, 1e-9));

      final RulerProjection bottom = geometry.project(
        const Offset(150, 240),
        RulerEdge.bottom,
      );
      expect(bottom.point, const Offset(150, 232));
      expect(bottom.distance, closeTo(8, 1e-9));
    });

    test('drops a point onto a turned edge, along its direction', () {
      final RulerGeometry geometry = RulerGeometry(_state(degrees: 45));
      final Offset start = geometry.edgeStart(RulerEdge.top);
      final Offset end = geometry.edgeEnd(RulerEdge.top);
      final RulerProjection projection = geometry.project(
        geometry.toPage(const Offset(30, -50)),
        RulerEdge.top,
      );

      // On the line through the edge's ends.
      final Offset direction = (end - start) / (end - start).distance;
      final Offset offset = projection.point - start;
      final double cross = offset.dx * direction.dy - offset.dy * direction.dx;
      expect(cross.abs(), lessThan(1e-9));
      expect(projection.distance, closeTo(18, 1e-9));
    });

    test('finds the edge a point is near, within its ends and a cap', () {
      final RulerGeometry geometry = RulerGeometry(_state());

      expect(geometry.edgeNear(const Offset(100, 150), 22, 12), RulerEdge.top);
      expect(
        geometry.edgeNear(const Offset(100, 250), 22, 12),
        RulerEdge.bottom,
      );
      // 30 px from an edge is too far; the middle of the body is 32 from both.
      expect(geometry.edgeNear(const Offset(100, 200), 22, 12), isNull);
      expect(geometry.edgeNear(const Offset(100, 130), 22, 12), isNull);
      // Past the left end by less than the cap, and by more.
      expect(geometry.edgeNear(const Offset(10, 168), 22, 12), RulerEdge.top);
      expect(geometry.edgeNear(const Offset(5, 168), 22, 12), isNull);
    });

    test('measures in its unit', () {
      final RulerGeometry metric = RulerGeometry(_state());
      final RulerGeometry inches = RulerGeometry(
        _state(unit: RulerUnit.inches),
      );

      expect(metric.measure(37.8, _config), closeTo(1, 1e-9));
      expect(inches.measure(96, _config), closeTo(1, 1e-9));
    });
  });

  group('angle detents', () {
    test('pull the angle to a detent within 1.8 degrees', () {
      for (final double degrees in <double>[
        0,
        30,
        45,
        60,
        90,
        120,
        135,
        150,
        180,
      ]) {
        final ({double radians, double? detent}) snapped =
            RulerGeometry.snapAngle(_rad(degrees + 1.7), _config);
        expect(
          snapped.radians,
          closeTo(RulerGeometry.normalize(_rad(degrees)), 1e-9),
          reason: '$degrees',
        );
        expect(snapped.detent, isNotNull);

        final ({double radians, double? detent}) below =
            RulerGeometry.snapAngle(_rad(degrees - 1.7), _config);
        expect(
          below.radians,
          closeTo(RulerGeometry.normalize(_rad(degrees)), 1e-9),
        );
      }
    });

    test('leave an angle beyond the radius as it is', () {
      final ({double radians, double? detent}) free = RulerGeometry.snapAngle(
        _rad(38),
        _config,
      );

      expect(free.detent, isNull);
      expect(free.radians, closeTo(_rad(38), 1e-9));
      expect(
        RulerGeometry.snapAngle(_rad(47.0), _config).detent,
        isNull,
        reason: '2 degrees from 45 is out of reach',
      );
    });

    test(
      'also click half a turn on, where the ruler lies along the same line',
      () {
        expect(
          RulerGeometry.snapAngle(_rad(226), _config).radians,
          closeTo(RulerGeometry.normalize(_rad(225)), 1e-9),
        );
        expect(
          RulerGeometry.snapAngle(_rad(-89), _config).radians,
          closeTo(-math.pi / 2, 1e-9),
        );
        expect(
          RulerGeometry.snapAngle(_rad(269), _config).radians,
          closeTo(-math.pi / 2, 1e-9),
        );
      },
    );
  });

  group('gestures', () {
    test('one finger on the body moves the ruler', () {
      final RulerGestureTracker tracker = RulerGestureTracker(_config);
      final RulerState state = _state();

      expect(tracker.grabAt(state, const Offset(120, 190)), RulerGrab.body);
      tracker.begin(1, const Offset(120, 190), state, RulerGrab.body);
      final RulerState? moved = tracker.move(1, const Offset(150, 230));

      expect(moved!.center, const Offset(230, 240));
      expect(moved.rotationRadians, 0);
    });

    test('the dial is taken ahead of the body, and misses off the ruler', () {
      final RulerGestureTracker tracker = RulerGestureTracker(_config);
      final RulerState state = _state();

      expect(tracker.grabAt(state, const Offset(210, 200)), RulerGrab.dial);
      expect(tracker.grabAt(state, const Offset(200, 300)), isNull);
    });

    test('one finger on the dial turns the ruler about its center', () {
      final RulerGestureTracker tracker = RulerGestureTracker(_config);
      final RulerState state = _state();

      tracker.begin(1, const Offset(210, 200), state, RulerGrab.dial);
      final RulerState? turned = tracker.move(1, const Offset(200, 210));

      expect(turned!.center, const Offset(200, 200));
      expect(turned.rotationRadians, closeTo(math.pi / 2, 1e-9));
    });

    test('two fingers move and turn it together', () {
      final RulerGestureTracker tracker = RulerGestureTracker(_config);
      final RulerState state = _state();

      tracker.begin(1, const Offset(150, 200), state, RulerGrab.body);
      expect(tracker.join(2, const Offset(250, 200)), isTrue);
      // The second finger swings from the right of the first to below it, a
      // quarter turn, and the pair's middle moves by (-50, 50).
      final RulerState? turned = tracker.move(2, const Offset(150, 300));

      expect(turned!.rotationRadians, closeTo(math.pi / 2, 1e-9));
      expect(turned.center.dx, closeTo(200 - 50, 1e-9));
      expect(turned.center.dy, closeTo(200 + 50, 1e-9));
    });

    test('a third finger does not join', () {
      final RulerGestureTracker tracker = RulerGestureTracker(_config);
      tracker.begin(1, const Offset(150, 200), _state(), RulerGrab.body);

      expect(tracker.join(2, const Offset(250, 200)), isTrue);
      expect(tracker.join(3, const Offset(300, 200)), isFalse);
    });

    test('the finger left carries on moving it when the other lifts', () {
      final RulerGestureTracker tracker = RulerGestureTracker(_config);
      tracker.begin(1, const Offset(150, 200), _state(), RulerGrab.body);
      tracker.join(2, const Offset(250, 200));
      tracker.end(2);

      expect(tracker.isActive, isTrue);
      final RulerState? moved = tracker.move(1, const Offset(160, 200));
      expect(moved!.center.dx, closeTo(210, 1e-9));

      tracker.end(1);
      expect(tracker.isActive, isFalse);
    });

    test('clicks once on entering a detent, not on every move within it', () {
      final RulerGestureTracker tracker = RulerGestureTracker(_config);
      final RulerState state = _state();
      // A dial finger turning the ruler through 45 degrees.
      tracker.begin(1, const Offset(220, 200), state, RulerGrab.dial);

      Offset at(double degrees) => Offset(
        200 + 20 * math.cos(_rad(degrees)),
        200 + 20 * math.sin(_rad(degrees)),
      );

      tracker.move(1, at(40));
      expect(tracker.didSnap, isFalse);
      final RulerState? entered = tracker.move(1, at(44));
      expect(tracker.didSnap, isTrue);
      expect(entered!.rotationRadians, closeTo(_rad(45), 1e-9));
      tracker.move(1, at(45.5));
      expect(tracker.didSnap, isFalse, reason: 'already in the detent');
      // The fingers' own angle is kept: out the other side, free again.
      final RulerState? out = tracker.move(1, at(50));
      expect(out!.rotationRadians, closeTo(_rad(50), 1e-9));
    });
  });

  group('guide', () {
    RulerGuide? begin(Offset start, {double degrees = 0}) {
      return RulerGuide.begin(
        RulerGeometry(_state(degrees: degrees)),
        _config,
        start,
      );
    }

    test('only catches a stroke that begins within the threshold', () {
      expect(begin(const Offset(100, 150)), isNotNull);
      expect(begin(const Offset(100, 146)), isNotNull);
      expect(begin(const Offset(100, 145)), isNull);
      expect(begin(const Offset(100, 200)), isNull);
    });

    test('holds every sample on the edge', () {
      final RulerGuide guide = begin(const Offset(60, 170))!;

      for (final Offset raw in <Offset>[
        const Offset(60, 170),
        const Offset(100, 185),
        const Offset(150, 160),
        const Offset(220, 176),
      ]) {
        final Offset snapped = guide.apply(raw);
        expect(snapped.dy, closeTo(168, 1e-9));
        expect(snapped.dx, closeTo(raw.dx, 1e-9));
      }
      expect(guide.isEngaged, isTrue);
      expect(guide.distance, closeTo(160, 1e-9));
    });

    test('keeps a turned stroke on the turned edge', () {
      final RulerGeometry geometry = RulerGeometry(_state(degrees: 30));
      final RulerGuide guide = RulerGuide.begin(
        geometry,
        _config,
        geometry.toPage(const Offset(-100, -25)),
      )!;
      final List<Offset> points = <Offset>[
        for (int i = 0; i <= 10; i++)
          guide.apply(
            geometry.toPage(Offset(-100 + i * 20, -25 + (i % 3) * 4)),
          ),
      ];

      for (final Offset point in points) {
        expect(geometry.toLocal(point).dy, closeTo(-32, 1e-9));
      }
    });

    test('lets go once the pen moves 1.5 thresholds away, and stays free', () {
      final RulerGuide guide = begin(const Offset(60, 170))!;

      // 30 px from the edge: between the threshold and 1.5 times it.
      final Offset fading = guide.apply(const Offset(100, 138));
      expect(fading.dy, greaterThan(138));
      expect(fading.dy, lessThan(168));
      expect(guide.isEngaged, isTrue);

      // 34 px from the edge, past 33: free, and the sample is untouched.
      const Offset away = Offset(140, 134);
      expect(guide.apply(away), away);
      expect(guide.isEngaged, isFalse);

      // Back at the edge it does not catch again.
      const Offset back = Offset(180, 169);
      expect(guide.apply(back), back);
    });

    test('fades the snap out smoothly across the release band', () {
      double pull(double distance) {
        final RulerGuide guide = begin(const Offset(60, 170))!;
        return guide.apply(Offset(100, 168 - distance)).dy;
      }

      // Fully on the edge to 22, free past 33, easing between.
      expect(pull(22), closeTo(168, 1e-9));
      final double mid = pull(27.5);
      expect(mid, closeTo(((168) + (168 - 27.5)) / 2, 1e-9));
      expect(pull(32.9), closeTo(168 - 32.9, 0.5));
      expect(pull(33.1), closeTo(168 - 33.1, 1e-9));
    });

    test('stops at the ends of the edge', () {
      final RulerGuide guide = begin(const Offset(60, 170))!;

      final Offset beyond = guide.apply(const Offset(500, 170));

      // 12 px past the right end at most.
      expect(beyond.dx, closeTo(380 + 12, 1e-9));
      expect(guide.isEngaged, isTrue);
    });
  });

  group('controller', () {
    test('shows and hides, and keeps a ruler per page', () {
      final RulerController controller = RulerController();
      final Object pageA = Object();
      final Object pageB = Object();
      int notified = 0;
      controller.addListener(() => notified++);

      expect(controller.isVisible, isFalse);
      controller.toggle();
      expect(controller.isVisible, isTrue);
      controller.toggle();
      expect(controller.isVisible, isFalse);
      expect(notified, 2);

      expect(controller.hasPose(pageA), isFalse);
      controller.place(
        pageA,
        _state(center: const Offset(10, 20), degrees: 45),
      );
      expect(controller.hasPose(pageA), isTrue);
      expect(controller.hasPose(pageB), isFalse);

      final RulerState a = controller.stateFor(pageA, Offset.zero);
      final RulerState b = controller.stateFor(pageB, const Offset(5, 5));
      expect(a.center, const Offset(10, 20));
      expect(a.rotationRadians, closeTo(_rad(45), 1e-9));
      expect(b.center, const Offset(5, 5));
      expect(b.rotationRadians, 0);
      expect(a.length, 360);
      expect(a.thickness, 64);
    });

    test('does not notify when a page is put down where it already was', () {
      final RulerController controller = RulerController();
      final Object page = Object();
      controller.place(page, _state());
      int notified = 0;
      controller.addListener(() => notified++);

      controller.place(page, _state());

      expect(notified, 0);
    });

    test('keeps its unit and lock across all pages', () {
      final RulerController controller = RulerController();
      controller.unit = RulerUnit.inches;
      controller.isLocked = true;

      final RulerState state = controller.stateFor(Object(), Offset.zero);

      expect(state.unit, RulerUnit.inches);
      expect(state.isLocked, isTrue);
    });
  });

  group('on the canvas', () {
    late InkController ink;
    late ValueNotifier<EditorTool> tool;
    late RulerController ruler;
    late PointerClaims claims;
    late ValueNotifier<EraserSettings> eraser;

    setUp(() {
      ink = InkController();
      tool = ValueNotifier<EditorTool>(EditorTool.pen);
      ruler = RulerController();
      claims = PointerClaims();
      eraser = ValueNotifier<EraserSettings>(EraserSettings.defaults());
    });

    tearDown(() {
      ink.dispose();
      tool.dispose();
      ruler.dispose();
      eraser.dispose();
    });

    Future<void> pumpCanvas(
      WidgetTester tester, {
      RulerState? at,
      bool stylusOnly = true,
    }) async {
      final ValueNotifier<PenSettings> pen = ValueNotifier<PenSettings>(
        PenSettings.defaults(),
      );
      addTearDown(pen.dispose);
      if (at != null) {
        ruler.isVisible = true;
        ruler.place(ink, at);
      }
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              height: 400,
              child: InkCanvas(
                controller: ink,
                tool: tool,
                penSettings: pen,
                eraserSettings: eraser,
                enableNativeInk: false,
                stylusOnly: ValueNotifier<bool>(stylusOnly),
                ruler: ruler,
                pointerClaims: claims,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> draw(
      WidgetTester tester,
      Offset from,
      Offset to, {
      int steps = 12,
      PointerDeviceKind kind = PointerDeviceKind.stylus,
    }) async {
      final TestGesture gesture = await tester.startGesture(from, kind: kind);
      for (int i = 1; i <= steps; i++) {
        await gesture.moveTo(
          Offset.lerp(from, to, i / steps)!,
          timeStamp: Duration(milliseconds: 8 * i),
        );
      }
      await gesture.up(timeStamp: Duration(milliseconds: 8 * (steps + 1)));
      await tester.pump();
    }

    /// The most any point strays from the line through the first and last.
    double deviation(List<InkVector> points) {
      final InkVector a = points.first;
      final InkVector b = points.last;
      final double length = math.sqrt(
        (b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y),
      );
      double worst = 0;
      for (final InkVector p in points) {
        final double cross =
            ((p.x - a.x) * (b.y - a.y) - (p.y - a.y) * (b.x - a.x)).abs();
        worst = math.max(worst, cross / length);
      }
      return worst;
    }

    testWidgets(
      'a stylus begun near the edge draws a perfectly straight stroke',
      (WidgetTester tester) async {
        await pumpCanvas(tester, at: _state());

        // From 6 px above the top edge, wandering up and down while it goes.
        final TestGesture gesture = await tester.startGesture(
          const Offset(60, 162),
          kind: PointerDeviceKind.stylus,
        );
        for (int i = 1; i <= 20; i++) {
          await gesture.moveTo(
            Offset(60.0 + i * 12, 162 + (i.isEven ? 14 : -10)),
            timeStamp: Duration(milliseconds: 8 * i),
          );
        }
        await gesture.up(timeStamp: const Duration(milliseconds: 200));
        await tester.pump();

        expect(ink.strokes, hasLength(1));
        final List<InkVector> points = ink.strokes.single.points;
        expect(points.length, greaterThan(5));
        expect(deviation(points), lessThan(1e-6));
        for (final InkVector point in points) {
          expect(point.y, closeTo(168, 1e-6));
        }
        // R squared of a fit through them is exactly 1: they are one line.
        expect(points.map((InkVector p) => p.y).toSet().length, 1);
      },
    );

    testWidgets('the stroke follows a ruler turned to 45 degrees', (
      WidgetTester tester,
    ) async {
      await pumpCanvas(tester, at: _state(degrees: 45));
      final RulerGeometry geometry = RulerGeometry(_state(degrees: 45));
      final Offset from = geometry.toPage(const Offset(-120, -36));
      final Offset to = geometry.toPage(const Offset(140, -20));

      await draw(tester, from, to, steps: 16);

      expect(ink.strokes, hasLength(1));
      expect(deviation(ink.strokes.single.points), lessThan(1e-6));
      for (final InkVector point in ink.strokes.single.points) {
        expect(
          geometry.toLocal(Offset(point.x, point.y)).dy,
          closeTo(-32, 1e-6),
        );
      }
    });

    testWidgets('the bottom edge guides too', (WidgetTester tester) async {
      await pumpCanvas(tester, at: _state());

      await draw(tester, const Offset(60, 240), const Offset(300, 250));

      for (final InkVector point in ink.strokes.single.points) {
        expect(point.y, closeTo(232, 1e-6));
      }
    });

    testWidgets('a stroke begun away from the ruler is never touched', (
      WidgetTester tester,
    ) async {
      await pumpCanvas(tester, at: _state());
      const Offset from = Offset(60, 100);
      const Offset to = Offset(300, 190);

      // It crosses the ruler's top edge on the way, and is left alone.
      await draw(tester, from, to, steps: 20);

      final List<InkVector> points = ink.strokes.single.points;
      expect(points.first.y, closeTo(100, 1));
      expect(points.last.y, closeTo(190, 1));
      expect(deviation(points), lessThan(1.5));
      expect(points.map((InkVector p) => p.y).toSet().length, greaterThan(3));
      // Not the straight line along the edge.
      expect(points.any((InkVector p) => (p.y - 168).abs() > 5), isTrue);
    });

    testWidgets('lets go when the pen moves decisively away', (
      WidgetTester tester,
    ) async {
      await pumpCanvas(tester, at: _state());

      final TestGesture gesture = await tester.startGesture(
        const Offset(60, 170),
        kind: PointerDeviceKind.stylus,
      );
      for (int i = 1; i <= 10; i++) {
        await gesture.moveTo(
          Offset(60.0 + i * 10, 170),
          timeStamp: Duration(milliseconds: 8 * i),
        );
      }
      // Now up and away, 90 px above the edge.
      for (int i = 1; i <= 10; i++) {
        await gesture.moveTo(
          Offset(160.0 + i * 10, 170 - i * 9),
          timeStamp: Duration(milliseconds: 80 + 8 * i),
        );
      }
      await gesture.up(timeStamp: const Duration(milliseconds: 200));
      await tester.pump();

      final List<InkVector> points = ink.strokes.single.points;
      expect(points.first.y, closeTo(168, 1e-6));
      expect(points.last.y, lessThan(100), reason: 'drew away freely');
    });

    testWidgets('a hidden ruler leaves strokes alone', (
      WidgetTester tester,
    ) async {
      await pumpCanvas(tester, at: _state());
      ruler.isVisible = false;
      await tester.pump();

      await draw(tester, const Offset(60, 162), const Offset(300, 176));

      final List<InkVector> points = ink.strokes.single.points;
      expect(points.first.y, closeTo(162, 1));
      expect(points.last.y, closeTo(176, 1));
    });

    testWidgets('the eraser runs along the edge too', (
      WidgetTester tester,
    ) async {
      await pumpCanvas(tester, at: _state());
      tool.value = EditorTool.eraser;
      await tester.pump();

      final TestGesture gesture = await tester.startGesture(
        const Offset(60, 160),
        kind: PointerDeviceKind.stylus,
      );
      await gesture.moveTo(
        const Offset(150, 150),
        timeStamp: const Duration(milliseconds: 8),
      );

      expect(ink.activeErase, isNotNull);
      expect(ink.activeErase!.position.y, closeTo(168, 1e-6));
      expect(ink.activeErase!.position.x, closeTo(150, 1e-6));
      await gesture.up();
    });

    testWidgets('shows the distance drawn while a stroke runs along the edge', (
      WidgetTester tester,
    ) async {
      await pumpCanvas(tester, at: _state());
      final ValueListenable<RulerReadout?> readout = tester
          .widget<RulerLayer>(find.byType(RulerLayer))
          .readout;
      expect(readout.value, isNull);

      final TestGesture gesture = await tester.startGesture(
        const Offset(60, 170),
        kind: PointerDeviceKind.stylus,
      );
      await gesture.moveTo(
        const Offset(60.0 + 37.8 * 3, 170),
        timeStamp: const Duration(milliseconds: 8),
      );
      await tester.pump();

      final RulerReadout? live = readout.value;
      expect(live, isNotNull);
      expect(live!.edge, RulerEdge.top);
      expect(live.distance, closeTo(37.8 * 3, 1e-6));
      expect(
        RulerGeometry(_state()).measure(live.distance, _config),
        closeTo(3, 1e-9),
      );
      expect(live.tip.dy, closeTo(168, 1e-6));

      await gesture.up(timeStamp: const Duration(milliseconds: 20));
      await tester.pump();
      expect(readout.value, isNull);
    });

    testWidgets('a finger on the body moves the ruler, and draws nothing', (
      WidgetTester tester,
    ) async {
      await pumpCanvas(tester, at: _state());

      final TestGesture finger = await tester.startGesture(
        const Offset(100, 190),
      );
      expect(claims.isEmpty, isFalse, reason: 'the page view must not pan');
      await finger.moveBy(const Offset(40, 60));
      await tester.pump();
      await finger.up();
      await tester.pump();

      final RulerState moved = ruler.stateFor(ink, Offset.zero);
      expect(moved.center, const Offset(240, 260));
      expect(ink.strokes, isEmpty);
      expect(ink.canUndo, isFalse);
      expect(claims.isEmpty, isTrue);
    });

    testWidgets('a mouse on the body moves it too', (
      WidgetTester tester,
    ) async {
      await pumpCanvas(tester, at: _state());

      await draw(
        tester,
        const Offset(100, 190),
        const Offset(120, 190),
        kind: PointerDeviceKind.mouse,
      );

      expect(ruler.stateFor(ink, Offset.zero).center, const Offset(220, 200));
      expect(ink.strokes, isEmpty);
    });

    testWidgets('a stylus on the body draws instead of moving it', (
      WidgetTester tester,
    ) async {
      await pumpCanvas(tester, at: _state());

      await draw(tester, const Offset(100, 200), const Offset(300, 210));

      expect(ruler.stateFor(ink, Offset.zero).center, const Offset(200, 200));
      expect(ink.strokes, hasLength(1));
    });

    testWidgets('a finger beside the ruler is left to the page', (
      WidgetTester tester,
    ) async {
      await pumpCanvas(tester, at: _state());

      final TestGesture finger = await tester.startGesture(
        const Offset(100, 320),
      );
      expect(claims.isEmpty, isTrue);
      await finger.up();
    });

    testWidgets('a finger on the dial turns it, and clicks into a detent', (
      WidgetTester tester,
    ) async {
      final List<AppHaptic> haptics = <AppHaptic>[];
      AppHaptics.performer = (AppHaptic haptic) async => haptics.add(haptic);
      addTearDown(AppHaptics.reset);
      await pumpCanvas(tester, at: _state());

      final TestGesture finger = await tester.startGesture(
        const Offset(220, 200),
      );
      for (final double degrees in <double>[10, 25, 40, 44, 45]) {
        await finger.moveTo(
          Offset(
            200 + 20 * math.cos(_rad(degrees)),
            200 + 20 * math.sin(_rad(degrees)),
          ),
        );
      }
      await finger.up();
      await tester.pump();

      final RulerState turned = ruler.stateFor(ink, Offset.zero);
      expect(turned.rotationRadians, closeTo(_rad(45), 1e-9));
      expect(turned.degrees, closeTo(45, 1e-9));
      expect(haptics, <AppHaptic>[AppHaptic.toolSwitch]);
    });

    testWidgets('two fingers turn it', (WidgetTester tester) async {
      await pumpCanvas(tester, at: _state());

      final TestGesture first = await tester.startGesture(
        const Offset(120, 200),
      );
      final TestGesture second = await tester.startGesture(
        const Offset(280, 200),
      );
      await second.moveTo(const Offset(120, 360));
      await tester.pump();
      await first.up();
      await second.up();

      final RulerState turned = ruler.stateFor(ink, Offset.zero);
      expect(turned.rotationRadians, closeTo(math.pi / 2, 1e-9));
      expect(ink.strokes, isEmpty);
    });

    testWidgets('a locked ruler is left where it is', (
      WidgetTester tester,
    ) async {
      await pumpCanvas(tester, at: _state());
      ruler.isLocked = true;

      await draw(
        tester,
        const Offset(100, 190),
        const Offset(150, 190),
        kind: PointerDeviceKind.touch,
      );

      expect(ruler.stateFor(ink, Offset.zero).center, const Offset(200, 200));
    });

    testWidgets('the ruler stays on its page through a rebuild', (
      WidgetTester tester,
    ) async {
      await pumpCanvas(
        tester,
        at: _state(degrees: 30, center: const Offset(150, 120)),
      );

      // Torn down and built again, as when the device turns.
      await tester.pumpWidget(const SizedBox());
      await pumpCanvas(tester);

      final RulerState again = ruler.stateFor(ink, Offset.zero);
      expect(again.center, const Offset(150, 120));
      expect(again.rotationRadians, closeTo(_rad(30), 1e-9));
    });

    testWidgets('showing it puts it down where the page is seen', (
      WidgetTester tester,
    ) async {
      await pumpCanvas(tester);
      expect(ruler.hasPose(ink), isFalse);

      ruler.toggle();
      await tester.pump();

      expect(ruler.hasPose(ink), isTrue);
      expect(ruler.stateFor(ink, Offset.zero).center, const Offset(200, 200));
    });

    testWidgets('moving it repaints its own layer and not the ink', (
      WidgetTester tester,
    ) async {
      await pumpCanvas(tester, at: _state());
      final RenderRepaintBoundary inkLayer = tester
          .renderObject<RenderRepaintBoundary>(
            find
                .ancestor(
                  of: find.byWidgetPredicate(
                    (Widget w) =>
                        w is CustomPaint &&
                        w.painter.runtimeType.toString() ==
                            'CompletedStrokesPainter',
                  ),
                  matching: find.byType(RepaintBoundary),
                )
                .first,
          );
      final RenderRepaintBoundary rulerLayer = tester
          .renderObject<RenderRepaintBoundary>(
            find
                .descendant(
                  of: find.byType(RulerLayer),
                  matching: find.byType(RepaintBoundary),
                )
                .first,
          );
      int paints(RenderRepaintBoundary b) =>
          b.debugSymmetricPaintCount + b.debugAsymmetricPaintCount;
      final int inkBefore = paints(inkLayer);
      final int rulerBefore = paints(rulerLayer);

      final TestGesture finger = await tester.startGesture(
        const Offset(100, 190),
      );
      for (int i = 1; i <= 6; i++) {
        await finger.moveBy(const Offset(8, 4));
        await tester.pump();
      }
      await finger.up();

      expect(paints(inkLayer), inkBefore);
      expect(paints(rulerLayer), greaterThan(rulerBefore));
    });

    testWidgets('lies above the ink, ignoring touches itself', (
      WidgetTester tester,
    ) async {
      await pumpCanvas(tester, at: _state());

      expect(
        find.descendant(
          of: find.byType(InkCanvas),
          matching: find.byType(RulerLayer),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(RulerLayer),
          matching: find.byType(IgnorePointer),
        ),
        findsWidgets,
      );
    });
  });

  group('paper', () {
    test('keeps the ruler out of what is exported and thumbnailed', () {
      // The ruler lives only in the editor's canvas widgets. The exporter
      // and the thumbnail painter draw a page from its ink and know of no
      // ruler, so none is drawn into a PDF or a picture.
      final List<File> files = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.dart'))
          .where((File f) {
            final String name = f.path.replaceAll('\\', '/');
            return name.contains('document_io/pdf_exporter') ||
                name.toLowerCase().contains('thumbnail');
          })
          .toList();
      expect(files, isNotEmpty);
      for (final File file in files) {
        final String source = file.readAsStringSync().toLowerCase();
        expect(source, isNot(contains('ruler')), reason: file.path);
        expect(source, isNot(contains('laser')), reason: file.path);
      }
    });

    test('is never part of the ink a page saves', () {
      final InkController ink = InkController();
      addTearDown(ink.dispose);
      final RulerController ruler = RulerController()..isVisible = true;
      ruler.place(ink, _state());

      expect(ink.strokes, isEmpty);
      expect(ink.canUndo, isFalse);
    });
  });
}
