import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/ink/stroke_spatial_index.dart';

const StrokeStyle _style = StrokeStyle(ink: InkPalette.ink, width: 3);

Stroke _stroke(double x, double y, [double length = 40]) => Stroke.fromPoints(
  style: _style,
  points: <InkVector>[
    for (int i = 0; i < 8; i++) InkVector(x + length * i / 7, y + (i % 2) * 2),
  ],
);

List<Stroke> _scattered(math.Random random, int count, double extent) {
  return <Stroke>[
    for (int i = 0; i < count; i++)
      _stroke(random.nextDouble() * extent, random.nextDouble() * extent),
  ];
}

/// What a query must at least answer, found by looking at every stroke. Cells
/// are coarse, so the index may answer more, but never less.
Set<int> _touching(List<Stroke> strokes, Rect area) => <int>{
  for (int i = 0; i < strokes.length; i++)
    if (strokes[i].bounds.overlaps(area)) i,
};

void main() {
  group('StrokeSpatialIndex', () {
    test('finds every stroke touching an area, once and in order', () {
      final List<Stroke> strokes = _scattered(math.Random(1), 2000, 3000);
      final StrokeSpatialIndex index = StrokeSpatialIndex(strokes);
      const Rect area = Rect.fromLTWH(1000, 1000, 300, 300);
      final List<int> found = index.query(area);
      expect(found, orderedEquals(found.toSet().toList()..sort()));
      expect(found.toSet().containsAll(_touching(strokes, area)), isTrue);
      expect(found.length, lessThan(strokes.length ~/ 4));
    });

    test('a stroke too big for cells is still found', () {
      final List<Stroke> strokes = <Stroke>[
        _stroke(0, 0, 1000000),
        _stroke(500, 500),
      ];
      final StrokeSpatialIndex index = StrokeSpatialIndex(strokes);
      expect(index.query(const Rect.fromLTWH(90000, 0, 1, 1)), contains(0));
    });

    test('catches up with strokes added in place, but no other change', () {
      final List<Stroke> strokes = <Stroke>[_stroke(0, 0)];
      final StrokeSpatialIndex index = StrokeSpatialIndex(strokes);
      strokes.add(_stroke(500, 500));
      expect(index.indexes(strokes), isFalse);
      expect(index.catchUp(strokes), isTrue);
      expect(index.indexes(strokes), isTrue);
      expect(index.query(const Rect.fromLTWH(500, 500, 5, 5)), <int>[1]);

      strokes.removeLast();
      expect(index.catchUp(strokes), isFalse);
      expect(index.catchUp(<Stroke>[_stroke(0, 0)]), isFalse);
    });

    test('following splices answers as a new index would', () {
      final math.Random random = math.Random(3);
      List<Stroke> strokes = _scattered(random, 800, 2000);
      final StrokeSpatialIndex index = StrokeSpatialIndex(strokes);
      for (int round = 0; round < 200; round++) {
        final List<int> hit = <int>{
          for (int i = 0; i < 1 + random.nextInt(4); i++)
            random.nextInt(strokes.length),
        }.toList()..sort();
        final List<StrokeSplice> splices = <StrokeSplice>[
          for (final int i in hit)
            StrokeSplice(i, <Stroke>[
              for (int piece = random.nextInt(3); piece > 0; piece--)
                _stroke(random.nextDouble() * 2000, random.nextDouble() * 2000),
            ]),
        ];
        final List<Stroke> next = <Stroke>[];
        int from = 0;
        for (final StrokeSplice splice in splices) {
          next
            ..addAll(strokes.getRange(from, splice.index))
            ..addAll(splice.pieces);
          from = splice.index + 1;
        }
        next.addAll(strokes.getRange(from, strokes.length));
        strokes = next;
        index.apply(strokes, splices);

        expect(index.indexes(strokes), isTrue);
        final Rect area = Rect.fromLTWH(
          random.nextDouble() * 2000,
          random.nextDouble() * 2000,
          random.nextDouble() * 400,
          random.nextDouble() * 400,
        );
        expect(
          index.query(area),
          orderedEquals(StrokeSpatialIndex(strokes).query(area)),
        );
      }
    });
  });

  group('StrokeSpatialIndex.changedSince', () {
    test('sees a splice and an append where they happen, and only there', () {
      final List<Stroke> strokes = <Stroke>[
        _stroke(0, 0),
        _stroke(2000, 2000),
      ];
      final StrokeSpatialIndex index = StrokeSpatialIndex(strokes);
      const Rect here = Rect.fromLTWH(0, 0, 50, 50);
      const Rect there = Rect.fromLTWH(2000, 2000, 50, 50);
      const Rect elsewhere = Rect.fromLTWH(5000, 5000, 50, 50);
      final int start = index.version;
      expect(index.changedSince(start, here), isFalse);

      final List<Stroke> after = <Stroke>[strokes[1]];
      index.apply(after, <StrokeSplice>[
        const StrokeSplice(0, <Stroke>[]),
      ]);
      expect(index.changedSince(start, here), isTrue);
      expect(index.changedSince(start, there), isFalse);
      expect(index.changedSince(index.version, here), isFalse);

      final int erased = index.version;
      after.add(_stroke(5000, 5000));
      expect(index.catchUp(after), isTrue);
      expect(index.changedSince(erased, elsewhere), isTrue);
      expect(index.changedSince(erased, here), isFalse);
      expect(index.changedSince(start, here), isTrue);
    });

    test('never misses a change a query would show', () {
      final math.Random random = math.Random(21);
      List<Stroke> strokes = _scattered(random, 300, 1500);
      final StrokeSpatialIndex index = StrokeSpatialIndex(strokes);
      for (int round = 0; round < 300; round++) {
        final Rect area = Rect.fromLTWH(
          random.nextDouble() * 1500,
          random.nextDouble() * 1500,
          150,
          150,
        );
        List<Stroke> found() => <Stroke>[
          for (final int i in index.query(area))
            if (strokes[i].bounds.overlaps(area)) strokes[i],
        ];
        final List<Stroke> before = found();
        final int version = index.version;
        final int at = random.nextInt(strokes.length);
        final Stroke piece = _stroke(
          random.nextDouble() * 1500,
          random.nextDouble() * 1500,
        );
        strokes = <Stroke>[
          ...strokes.take(at),
          piece,
          ...strokes.skip(at + 1),
        ];
        index.apply(strokes, <StrokeSplice>[
          StrokeSplice(at, <Stroke>[piece]),
        ]);
        final List<Stroke> now = found();
        bool same = before.length == now.length;
        for (int i = 0; same && i < now.length; i++) {
          same = identical(before[i], now[i]);
        }
        if (!same) {
          expect(index.changedSince(version, area), isTrue);
        }
      }
    });
  });

  group('erasing through the index', () {
    /// The same erase, one new controller per move, so that each move builds
    /// its index anew and cannot be misled by one kept up to date.
    List<List<InkVector>> erasedAfresh(
      List<Stroke> strokes,
      List<InkVector> path,
      double radius,
    ) {
      List<Stroke> current = strokes;
      for (int i = 1; i < path.length; i++) {
        final InkController step = InkController(strokes: current);
        step.startErase(
          pointer: 1,
          position: path[i - 1],
          settings: EraserSettings(mode: EraserMode.area, size: radius * 2),
        );
        step.eraseTo(1, path[i]);
        step.endErase(1);
        current = step.strokes.toList();
        step.dispose();
      }
      return <List<InkVector>>[
        for (final Stroke stroke in current) stroke.points,
      ];
    }

    test('an erase leaves the same ink as one that rebuilds its index', () {
      final math.Random random = math.Random(9);
      final List<Stroke> page = _scattered(random, 600, 800);
      final List<InkVector> path = <InkVector>[
        for (int i = 0; i < 120; i++)
          InkVector(400 + 380 * math.sin(i / 11), 400 + 380 * math.cos(i / 7)),
      ];
      final InkController controller = InkController(strokes: page);
      addTearDown(controller.dispose);
      controller.startErase(
        pointer: 1,
        position: path.first,
        settings: const EraserSettings(mode: EraserMode.area, size: 30),
      );
      for (final InkVector point in path.skip(1)) {
        controller.eraseTo(1, point);
      }
      controller.endErase(1);

      final List<List<InkVector>> expected = erasedAfresh(page, path, 15);
      expect(controller.strokes.length, expected.length);
      for (int i = 0; i < expected.length; i++) {
        expect(controller.strokes[i].points, orderedEquals(expected[i]));
      }
    });

    test('an erase is one undo step, and spares the list others hold', () {
      final List<Stroke> page = _scattered(math.Random(2), 100, 400);
      final InkController controller = InkController(strokes: page);
      addTearDown(controller.dispose);
      final List<Stroke> held = controller.strokes;
      final int heldLength = held.length;
      controller.startErase(
        pointer: 1,
        position: const InkVector(0, 200),
        settings: const EraserSettings(mode: EraserMode.stroke, size: 30),
      );
      for (double x = 0; x < 400; x += 10) {
        controller.eraseTo(1, InkVector(x, 200));
      }
      controller.endErase(1);
      expect(controller.strokes.length, lessThan(heldLength));
      expect(held.length, heldLength);

      controller.undo();
      expect(controller.strokes.length, heldLength);
      expect(controller.canUndo, isFalse);
    });

    test('ink written after an erase is found by the next erase', () {
      final InkController controller = InkController(
        strokes: _scattered(math.Random(4), 50, 300),
      );
      addTearDown(controller.dispose);
      void wipe(InkVector from, InkVector to) {
        controller.startErase(
          pointer: 1,
          position: from,
          settings: const EraserSettings(mode: EraserMode.stroke, size: 30),
        );
        controller.eraseTo(1, to);
        controller.endErase(1);
      }

      wipe(const InkVector(0, 100), const InkVector(300, 100));
      controller.startStroke(
        pointer: 2,
        sample: const RawInkSample(
          position: InkVector(1000, 1000),
          timestamp: Duration.zero,
        ),
        style: _style,
      );
      controller.addSamples(2, const <RawInkSample>[
        RawInkSample(
          position: InkVector(1100, 1000),
          timestamp: Duration(milliseconds: 8),
        ),
      ]);
      controller.endStroke(2);
      final int written = controller.strokes.length;
      wipe(const InkVector(1050, 950), const InkVector(1050, 1050));
      expect(controller.strokes.length, written - 1);
    });
  });
}
