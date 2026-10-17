import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

void main() {
  test('a gentle turn leaves no gap on the outside of the bend', () {
    // About a 6 degree turn down at (100, 0), gentle enough to get no disc.
    final Path outline = buildInkOutline(
      const <InkVector>[InkVector(0, 0), InkVector(100, 0), InkVector(200, 10)],
      const <double>[1, 1, 1],
      20,
    );
    // Just past the joint, near the top edge: past the first segment's end
    // and before the second segment's start.
    expect(outline.contains(const Offset(100.5, -9.5)), isTrue);
    // The inside of the bend, and the middle, stay covered.
    expect(outline.contains(const Offset(100, 9)), isTrue);
    expect(outline.contains(const Offset(100, 0)), isTrue);
    // Nothing spills past the stroke's edge.
    expect(outline.contains(const Offset(100, -11)), isFalse);
  });

  test('a turn back on itself keeps its overlaps filled', () {
    final Path outline = buildInkOutline(
      const <InkVector>[
        InkVector(0, 0),
        InkVector(50, 2),
        InkVector(100, 0),
        InkVector(150, 2),
      ],
      const <double>[0.6, 1, 0.8, 0.5],
      16,
    );
    for (double x = 0; x <= 150; x += 2.5) {
      final double y = x <= 50
          ? x / 25
          : x <= 100
          ? 2 - (x - 50) / 25
          : (x - 100) / 25;
      expect(outline.contains(Offset(x, y)), isTrue, reason: 'at $x');
    }
  });
}
