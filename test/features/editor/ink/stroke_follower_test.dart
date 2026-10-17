import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/ink/stroke_follower.dart';

/// A horizontal line along y = 0, from x = 0 to x = 400.
final List<List<InkVector>> _line = <List<InkVector>>[
  <InkVector>[for (double x = 0; x <= 400; x += 10) InkVector(x, 0)],
];

StrokeFollower _follower() =>
    StrokeFollower(_line, captureRadius: 10, releaseRadius: 26);

RawInkSample _at(double x, double y, int i) => RawInkSample(
  position: InkVector(x, y),
  timestamp: Duration(milliseconds: 8 * i),
);

void main() {
  test('pen-down near a stroke follows immediately without movement', () {
    final StrokeFollower follower = _follower();
    const RawInkSample sample = RawInkSample(
      position: InkVector(40, 6),
      timestamp: Duration(milliseconds: 100),
      deviceKind: InkDeviceKind.touch,
      pressure: 0.7,
    );

    final RawInkSample drawn = follower.follow(sample);

    expect(follower.isFollowing, isTrue);
    expect(drawn.position, const InkVector(40, 0));
    expect(drawn.timestamp, sample.timestamp);
    expect(drawn.deviceKind, sample.deviceKind);
    expect(drawn.pressure, sample.pressure);
    // Repeated samples and tiny movements must not drop the initial capture.
    follower.follow(sample);
    follower.follow(_at(40.5, 6, 13));
    expect(follower.isFollowing, isTrue);
  });

  test('pen-down outside the capture radius does not attach', () {
    final StrokeFollower follower = _follower();
    final RawInkSample sample = _at(40, 11, 0);

    expect(follower.follow(sample), same(sample));
    expect(follower.isFollowing, isFalse);
  });

  test('moving across the stroke releases a pen-down capture', () {
    final StrokeFollower follower = _follower();
    follower.follow(_at(40, 6, 0));
    expect(follower.isFollowing, isTrue);

    follower.follow(_at(40, 3, 1));
    expect(follower.isFollowing, isFalse);
  });

  test('drawn close alongside a stroke, the pen settles onto it', () {
    final StrokeFollower follower = _follower();
    late InkVector drawn;
    for (int i = 0; i < 30; i++) {
      drawn = follower.follow(_at(20 + 4.0 * i, 6, i)).position;
    }
    expect(follower.isFollowing, isTrue);
    expect(drawn.y.abs(), lessThan(0.1));
  });

  test('leaving the stroke, the line eases off it without a jump', () {
    final StrokeFollower follower = _follower();
    int i = 0;
    for (; i < 30; i++) {
      follower.follow(_at(20 + 4.0 * i, 6, i));
    }
    // Drifts away at a shallow angle.
    double previousY = 0;
    double rawY = 6;
    double biggestStep = 0;
    for (int k = 0; k < 40; k++, i++) {
      rawY += 1;
      final InkVector drawn = follower
          .follow(_at(20 + 4.0 * i, rawY, i))
          .position;
      biggestStep = biggestStep < (drawn.y - previousY).abs()
          ? (drawn.y - previousY).abs()
          : biggestStep;
      previousY = drawn.y;
    }
    expect(follower.isFollowing, isFalse);
    // Back on the pen once well clear.
    expect(previousY, closeTo(rawY, 0.5));
    // No step much larger than the pen's own 1 px drift, give or take the
    // easing.
    expect(biggestStep, lessThan(3));
  });

  test('crossing a stroke does not catch the pen', () {
    final StrokeFollower follower = _follower();
    for (int i = 0; i < 20; i++) {
      final double y = -40 + 4.0 * i;
      final InkVector drawn = follower.follow(_at(200, y, i)).position;
      expect(drawn.y, closeTo(y, 1e-9));
    }
  });

  test('far from any ink, the pen is left alone', () {
    final StrokeFollower follower = _follower();
    for (int i = 0; i < 20; i++) {
      final InkVector drawn = follower
          .follow(_at(20 + 4.0 * i, 60, i))
          .position;
      expect(drawn, InkVector(20 + 4.0 * i, 60));
    }
  });

  test('a stroke drawn with a follower lands on the ink it traced', () {
    final InkController ink = InkController();
    addTearDown(ink.dispose);
    const StrokeStyle style = StrokeStyle(ink: InkPalette.ink, width: 3);
    ink.startStroke(pointer: 1, sample: _at(0, 0, 0), style: style);
    ink.addSamples(1, <RawInkSample>[
      for (int i = 1; i <= 40; i++) _at(10.0 * i, 0, i),
    ]);
    ink.endStroke(1);

    ink.startStroke(
      pointer: 2,
      sample: _at(40, 5, 100),
      style: style,
      follower: StrokeFollower(
        <List<InkVector>>[ink.strokes.single.points],
        captureRadius: 10,
        releaseRadius: 26,
      ),
    );
    ink.addSamples(2, <RawInkSample>[
      for (int i = 1; i <= 60; i++) _at(40 + 4.0 * i, 5, 100 + i),
    ]);
    ink.endStroke(2);

    final List<InkVector> traced = ink.strokes.last.points;
    expect(traced.first, const InkVector(40, 0));
    expect(traced.last.y.abs(), lessThan(0.5));
  });
}
