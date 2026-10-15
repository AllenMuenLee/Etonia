import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/selection_config.dart';
import 'package:greatnote/features/editor/ink/selection_transform.dart';

InkVector _v(double x, double y) => InkVector(x, y);

Matcher _near(InkVector expected, [double tolerance = 1e-9]) {
  return isA<InkVector>()
      .having((InkVector v) => v.x, 'x', closeTo(expected.x, tolerance))
      .having((InkVector v) => v.y, 'y', closeTo(expected.y, tolerance));
}

/// The position at [degrees] around [center], [radius] away.
InkVector _around(InkVector center, double degrees, [double radius = 100]) {
  final double radians = degrees * math.pi / 180;
  return center + _v(math.cos(radians), math.sin(radians)) * radius;
}

SelectionHit? _hit(SelectionFrame frame, InkVector point) {
  return frame.hitTest(point, handleHitRadius: 24, rotationHandleOffset: 32);
}

void main() {
  test('selection defaults', () {
    const SelectionConfig config = SelectionConfig();

    expect(config.minLassoPointSpacing, 2);
    expect(config.geometryTolerance, 0.001);
    expect(config.handleVisualRadius, 6);
    expect(config.handleHitRadius, 24);
    expect(config.rotationHandleOffset, 32);
    expect(config.minScale, 0.1);
    expect(config.maxScale, 10);
    expect(config.pasteOffset, _v(24, 24));
    expect(config.minStrokeWidth, 0.01);
    expect(config.maxCoordinate, 1e6);
    expect(config.rectangleMaxDetour, 1.25);
    expect(config.lassoClosingFraction, 0.2);
    expect(config.lassoDashLength, 6);
    expect(config.lassoDashGap, 4);
    expect(config.pasteHoldDuration, const Duration(milliseconds: 500));
    expect(config.pasteHoldSlop, 10);
  });

  test('the config rejects values that break its invariants', () {
    // Built at run time on purpose: a const one would not compile.
    // ignore_for_file: prefer_const_constructors
    for (final SelectionConfig Function() build in <SelectionConfig Function()>[
      () => SelectionConfig(minLassoPointSpacing: -1),
      () => SelectionConfig(geometryTolerance: double.nan),
      () => SelectionConfig(handleVisualRadius: 0),
      () => SelectionConfig(handleHitRadius: 4),
      () => SelectionConfig(rotationHandleOffset: 0),
      () => SelectionConfig(minScale: 0),
      () => SelectionConfig(minScale: 2),
      () => SelectionConfig(maxScale: 0.5),
      () => SelectionConfig(maxScale: double.infinity),
      () => SelectionConfig(minStrokeWidth: 0),
      () => SelectionConfig(maxCoordinate: double.infinity),
      () => SelectionConfig(rectangleMaxDetour: 0.9),
      () => SelectionConfig(lassoClosingFraction: 1.5),
      () => SelectionConfig(lassoDashLength: 0),
      () => SelectionConfig(lassoDashGap: 0),
      () => SelectionConfig(pasteHoldSlop: -1),
    ]) {
      expect(build, throwsAssertionError);
    }
  });

  group('move', () {
    test('applies the pointer delta to every point', () {
      final InkTransform move = SelectionTransforms.move(
        _v(10, 10),
        _v(35, -5),
      )!;

      expect(move.apply(_v(0, 0)), _v(25, -15));
      expect(move.apply(_v(100, 40)), _v(125, 25));
      expect(move.scale, 1);
      expect(move.angle, 0);
    });

    test('a pointer back at its start is the identity', () {
      expect(
        SelectionTransforms.move(_v(7, 9), _v(7, 9)),
        InkTransform.identity,
      );
    });
  });

  group('rotate', () {
    final InkVector center = _v(50, 50);

    test('a quarter and a half turn land on exact points', () {
      final InkTransform quarter = SelectionTransforms.rotate(
        center: center,
        start: _around(center, -90),
        current: _around(center, 0),
      )!;
      final InkTransform half = SelectionTransforms.rotate(
        center: center,
        start: _around(center, -90),
        current: _around(center, 90),
      )!;

      expect(quarter.angle, closeTo(math.pi / 2, 1e-12));
      expect(quarter.apply(_v(60, 50)), _near(_v(50, 60)));
      expect(quarter.apply(_v(50, 20)), _near(_v(80, 50)));
      expect(quarter.apply(center), _near(center));
      expect(half.apply(_v(60, 50)), _near(_v(40, 50)));
      expect(half.apply(_v(30, 10)), _near(_v(70, 90)));
      expect(quarter.scale, 1);
      expect(half.scale, 1);
    });

    test('sweeping across the -pi/pi seam does not jump', () {
      // The pointer starts at 170 degrees and sweeps through 180 to 190,
      // which atan2 reports as -170.
      double? previous;
      for (int degrees = 170; degrees <= 190; degrees++) {
        final InkTransform rotation = SelectionTransforms.rotate(
          center: center,
          start: _around(center, 170),
          current: _around(center, degrees.toDouble()),
        )!;
        final double turned = rotation.angle * 180 / math.pi;

        expect(turned, closeTo(degrees - 170, 1e-9));
        if (previous != null) {
          expect(turned - previous, closeTo(1, 1e-9));
        }
        previous = turned;
      }
    });

    test('a pointer on the center gives no rotation', () {
      expect(
        SelectionTransforms.rotate(
          center: center,
          start: _around(center, 0),
          current: center,
          tolerance: 0.001,
        ),
        isNull,
      );
      expect(
        SelectionTransforms.rotate(
          center: center,
          start: center,
          current: _around(center, 0),
        ),
        isNull,
      );
    });
  });

  group('scale', () {
    InkTransform? scale(InkVector current, {InkVector? start}) {
      return SelectionTransforms.scale(
        fixed: _v(10, 20),
        start: start ?? _v(110, 70),
        current: current,
        minScale: 0.1,
        maxScale: 10,
        tolerance: 0.001,
      );
    }

    test('scales by the ratio of distances, about the fixed point', () {
      final InkTransform doubled = scale(_v(210, 120))!;

      expect(doubled.scale, closeTo(2, 1e-12));
      expect(doubled.apply(_v(10, 20)), _near(_v(10, 20)));
      expect(doubled.apply(_v(110, 70)), _near(_v(210, 120)));
      // Relative positions are kept: a midpoint stays a midpoint.
      expect(doubled.apply(_v(60, 45)), _near(_v(110, 70)));
      expect(doubled.angle, 0);
    });

    test('clamps at the smallest and largest scale', () {
      expect(scale(_v(1e7, 1e7))!.scale, 10);
      expect(scale(_v(10, 20))!.scale, 0.1);
      expect(scale(_v(10.5, 20.5))!.scale, 0.1);
    });

    test('never mirrors: past the fixed point it grows again', () {
      final InkTransform beyond = scale(_v(-190, -80))!;

      expect(beyond.scale, closeTo(2, 1e-12));
      expect(beyond.a, greaterThan(0));
      expect(beyond.b, 0);
      // The grabbed corner stays on its own side of the fixed point.
      expect(beyond.apply(_v(110, 70)), _near(_v(210, 120)));
    });

    test('a pointer that started on the fixed point gives no scale', () {
      expect(scale(_v(210, 120), start: _v(10, 20)), isNull);
      expect(scale(_v(210, 120), start: _v(10.0005, 20)), isNull);
    });
  });

  test('invalid pointer positions give no transform', () {
    final InkVector bad = _v(double.nan, 0);
    final InkVector far = _v(double.infinity, 0);

    expect(SelectionTransforms.move(_v(0, 0), bad), isNull);
    expect(SelectionTransforms.move(far, _v(0, 0)), isNull);
    expect(
      SelectionTransforms.rotate(
        center: _v(0, 0),
        start: _v(1, 0),
        current: bad,
      ),
      isNull,
    );
    expect(
      SelectionTransforms.scale(
        fixed: _v(0, 0),
        start: _v(1, 0),
        current: far,
        minScale: 0.1,
        maxScale: 10,
      ),
      isNull,
    );
  });

  test('a transform depends only on the start and the current position', () {
    // The same gesture, reached through 1 and through 1000 samples.
    final InkVector start = _v(30, 40);
    final InkVector end = _v(-80, 200);
    final InkVector center = _v(10, 10);
    InkTransform? rotation;
    InkTransform? scaling;
    for (int i = 1; i <= 1000; i++) {
      final InkVector current =
          start + (end - start) * (i / 1000) + _v(math.sin(i / 3), 0);
      rotation = SelectionTransforms.rotate(
        center: center,
        start: start,
        current: i == 1000 ? end : current,
      );
      scaling = SelectionTransforms.scale(
        fixed: center,
        start: start,
        current: i == 1000 ? end : current,
        minScale: 0.1,
        maxScale: 10,
      );
    }

    expect(
      rotation,
      SelectionTransforms.rotate(center: center, start: start, current: end),
    );
    expect(
      scaling,
      SelectionTransforms.scale(
        fixed: center,
        start: start,
        current: end,
        minScale: 0.1,
        maxScale: 10,
      ),
    );
  });

  group('frame', () {
    final SelectionFrame frame = SelectionFrame.fromBounds(0, 0, 200, 100);

    test('has its corners in a fixed order and a handle above the top', () {
      expect(frame.center, _v(100, 50));
      expect(frame.corners, <InkVector>[
        _v(0, 0),
        _v(200, 0),
        _v(200, 100),
        _v(0, 100),
      ]);
      expect(frame.topCenter, _v(100, 0));
      expect(frame.rotationHandle(32), _v(100, -32));
      expect(SelectionFrame.oppositeCorner(0), 2);
      expect(SelectionFrame.oppositeCorner(3), 1);
    });

    test('keeps its orientation when rotated', () {
      final InkTransform turn = InkTransform.rotation(
        frame.center,
        math.pi / 6,
      );

      final SelectionFrame turned = frame.transformed(turn);

      // Not a new upright box around the result: same size, new angle.
      expect(turned.halfWidth, 100);
      expect(turned.halfHeight, 50);
      expect(turned.angle, closeTo(math.pi / 6, 1e-12));
      for (int i = 0; i < 4; i++) {
        expect(turned.corners[i], _near(turn.apply(frame.corners[i])));
      }
      expect(turned.rotationHandle(32), _near(turn.apply(_v(100, -32))));
    });

    test('carries its orientation through later moves and scales', () {
      final SelectionFrame turned = frame.transformed(
        InkTransform.rotation(frame.center, math.pi / 2),
      );
      final InkVector fixed = turned.corners[2];

      final SelectionFrame moved = turned.transformed(
        InkTransform.translation(_v(30, -10)),
      );
      final SelectionFrame scaled = moved.transformed(
        InkTransform.scaling(moved.corners[2], 3),
      );

      expect(moved.angle, closeTo(math.pi / 2, 1e-12));
      expect(scaled.angle, closeTo(math.pi / 2, 1e-12));
      expect(scaled.halfWidth, 300);
      expect(scaled.halfHeight, 150);
      expect(scaled.corners[2], _near(fixed + _v(30, -10)));
    });

    test('angles stay wrapped after many turns', () {
      SelectionFrame turned = frame;
      for (int i = 0; i < 100; i++) {
        turned = turned.transformed(InkTransform.rotation(frame.center, 2));
      }

      expect(turned.angle.abs(), lessThanOrEqualTo(math.pi));
      expect(turned.center, _near(frame.center, 1e-6));
    });

    test('knows what it contains, turned or not', () {
      final SelectionFrame turned = frame.transformed(
        InkTransform.rotation(frame.center, math.pi / 2),
      );

      expect(frame.contains(_v(190, 50)), isTrue);
      expect(frame.contains(_v(200.0005, 50), tolerance: 0.001), isTrue);
      expect(frame.contains(_v(201, 50)), isFalse);
      // Now 100 wide and 200 tall around the same center.
      expect(turned.contains(_v(190, 50)), isFalse);
      expect(turned.contains(_v(100, 140)), isTrue);
    });

    test('reports whether it is within a coordinate limit', () {
      expect(frame.isWithin(200), isTrue);
      expect(frame.isWithin(199), isFalse);
      expect(
        frame
            .transformed(InkTransform.translation(_v(double.nan, 0)))
            .isWithin(1e6),
        isFalse,
      );
    });
  });

  group('hit test', () {
    final SelectionFrame frame = SelectionFrame.fromBounds(0, 0, 200, 100);

    test('handles, then the interior, then nothing', () {
      expect(_hit(frame, _v(100, -32)), const SelectionHit.rotate());
      expect(_hit(frame, _v(110, -20)), const SelectionHit.rotate());
      expect(_hit(frame, _v(0, 0)), const SelectionHit.scale(0));
      expect(_hit(frame, _v(200, 0)), const SelectionHit.scale(1));
      expect(_hit(frame, _v(200, 100)), const SelectionHit.scale(2));
      expect(_hit(frame, _v(0, 100)), const SelectionHit.scale(3));
      // A handle's target is wider than its painted circle, in and out.
      expect(_hit(frame, _v(-15, -15)), const SelectionHit.scale(0));
      expect(_hit(frame, _v(15, 15)), const SelectionHit.scale(0));
      expect(_hit(frame, _v(100, 50)), const SelectionHit.move());
      expect(_hit(frame, _v(100, 0)), const SelectionHit.move());
      expect(_hit(frame, _v(-30, 50)), isNull);
      expect(_hit(frame, _v(100, 140)), isNull);
      expect(_hit(frame, _v(double.nan, 0)), isNull);
    });

    test('the nearest of several handles in reach wins', () {
      // 44 px tall: both left-hand targets cover the middle of that edge.
      final SelectionFrame low = SelectionFrame.fromBounds(0, 0, 200, 44);

      expect(_hit(low, _v(-5, 10)), const SelectionHit.scale(0));
      expect(_hit(low, _v(-5, 34)), const SelectionHit.scale(3));
    });

    test('equally near corners go to the earlier one', () {
      final SelectionFrame low = SelectionFrame.fromBounds(0, 0, 200, 44);
      final SelectionFrame narrow = SelectionFrame.fromBounds(0, 0, 40, 200);

      expect(_hit(low, _v(-5, 22)), const SelectionHit.scale(0));
      expect(_hit(low, _v(205, 22)), const SelectionHit.scale(1));
      expect(_hit(narrow, _v(20, 205)), const SelectionHit.scale(2));
      for (int run = 0; run < 3; run++) {
        expect(_hit(low, _v(-5, 22)), const SelectionHit.scale(0));
      }
    });

    test('a frame smaller than its handle targets can still be moved', () {
      // A 3 px dot: every handle target covers the whole frame.
      final SelectionFrame tiny = SelectionFrame.fromBounds(0, 0, 3, 3);

      expect(_hit(tiny, _v(1.5, 1.5)), const SelectionHit.move());
      expect(_hit(tiny, _v(0, 0)), const SelectionHit.scale(0));
      expect(_hit(tiny, _v(3, 3)), const SelectionHit.scale(2));
      expect(_hit(tiny, _v(-10, -10)), const SelectionHit.scale(0));
      expect(_hit(tiny, _v(13, 13)), const SelectionHit.scale(2));
      expect(_hit(tiny, _v(1.5, -32)), const SelectionHit.rotate());
      // Between the rotation handle and the top corners: whichever is
      // nearer.
      expect(_hit(tiny, _v(1.5, -20)), const SelectionHit.rotate());
      expect(_hit(tiny, _v(1.5, -12)), const SelectionHit.scale(0));
    });

    test('a degenerate frame gives finite, repeatable answers', () {
      const SelectionFrame point = SelectionFrame(
        center: InkVector(5, 5),
        halfWidth: 0,
        halfHeight: 0,
      );

      expect(_hit(point, _v(5, 5)), const SelectionHit.scale(0));
      expect(_hit(point, _v(5, 5)), const SelectionHit.scale(0));
      expect(_hit(point, _v(5, -27)), const SelectionHit.rotate());
      expect(_hit(point, _v(80, 80)), isNull);
      for (final InkVector corner in point.corners) {
        expect(corner.isFinite, isTrue);
      }
    });

    test('follows a turned frame', () {
      final SelectionFrame turned = frame.transformed(
        InkTransform.rotation(frame.center, math.pi / 2),
      );

      // The top edge now faces right, so the handle is out to the right.
      expect(turned.rotationHandle(32), _near(_v(182, 50)));
      expect(_hit(turned, _v(182, 50)), const SelectionHit.rotate());
      expect(_hit(turned, turned.corners[0]), const SelectionHit.scale(0));
      expect(turned.corners[0], _near(_v(150, -50)));
      expect(_hit(turned, _v(100, 120)), const SelectionHit.move());
      expect(_hit(turned, _v(10, 50)), isNull);
    });
  });
}
