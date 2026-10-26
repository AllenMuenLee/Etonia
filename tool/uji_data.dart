// Reading UJI Pen Characters v2 (Prat, Castro, Llorens, Marzal & Vilar,
// CC BY 4.0) and laying its writers' letters out as the app does, shared by
// the tools that evaluate and learn from it.

import 'dart:io';
import 'dart:math' as math;

import 'package:greatnote/features/editor/handwriting/handwriting_calibration.dart';
import 'package:greatnote/features/editor/handwriting/stroke_runs.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';

typedef UjiStrokes = List<List<InkVector>>;

/// Every writer's letters, by writer, then repetition (1 or 2), then
/// character.
Map<String, Map<int, Map<String, UjiStrokes>>> readUji(File file) {
  final List<String> lines = file.readAsLinesSync();
  final Map<String, Map<int, Map<String, UjiStrokes>>> writers =
      <String, Map<int, Map<String, UjiStrokes>>>{};
  for (int i = 0; i < lines.length; i++) {
    final RegExpMatch? word = RegExp(
      r'^WORD (.) (\S+)-(\d\d)$',
    ).firstMatch(lines[i]);
    if (word == null) continue;
    final String letter = word.group(1)!;
    final String writer = word.group(2)!;
    final int repetition = int.parse(word.group(3)!);
    final int count = int.parse(lines[++i].trim().split(RegExp(r'\s+')).last);
    final UjiStrokes strokes = <List<InkVector>>[];
    for (int s = 0; s < count; s++) {
      final List<String> fields = lines[++i].trim().split(RegExp(r'\s+'));
      final int points = int.parse(fields[1]);
      strokes.add(<InkVector>[
        for (int p = 0; p < points; p++)
          InkVector(
            double.parse(fields[3 + p * 2]),
            double.parse(fields[4 + p * 2]),
          ),
      ]);
    }
    ((writers[writer] ??= <int, Map<String, UjiStrokes>>{})[repetition] ??=
            <String, UjiStrokes>{})[letter] =
        strokes;
  }
  return writers;
}

/// Where a writer's letters stand, in the dataset's units: their baseline
/// and capital height.
typedef UjiScale = ({double baseline, double capHeight});

UjiScale ujiScale(Map<String, UjiStrokes> samples) {
  final List<double> feet = <double>[
    for (final String letter in 'aehiorsvwAERD'.split(''))
      if (samples[letter] case final UjiStrokes strokes) ujiBox(strokes).bottom,
  ]..sort();
  final double baseline = median(feet);
  final List<double> heights = <double>[
    for (final String letter in 'AERD'.split(''))
      if (samples[letter] case final UjiStrokes strokes)
        baseline - ujiBox(strokes).top,
  ]..removeWhere((double height) => height <= 0);
  return (baseline: baseline, capHeight: median(heights));
}

/// The letters of [page] of [customFontPages] in their boxes, or only
/// those of them in [only], as a writer would write them on the pad.
UjiStrokes calibrationPage(
  Map<String, UjiStrokes> samples,
  UjiScale scale, {
  int page = 0,
  String? only,
}) {
  final List<String> rows = customFontPages[page];
  return <List<InkVector>>[
    for (int row = 0; row < rows.length; row++)
      for (int column = 0; column < rows[row].length; column++)
        if ((only == null || only.contains(rows[row][column])) &&
            samples.containsKey(rows[row][column]))
          for (final List<InkVector> stroke in samples[rows[row][column]]!)
            <InkVector>[
              for (final InkVector p in stroke)
                InkVector(
                  column * calibrationCell +
                      0.15 +
                      (p.x - ujiBox(samples[rows[row][column]]!).left) /
                          scale.capHeight,
                  row * calibrationRowGap +
                      (p.y - scale.baseline) / scale.capHeight,
                ),
            ],
  ];
}

/// [strokes] in the font's grid: from x = 0, baseline at y = 10, a capital
/// 10 tall.
UjiStrokes gridGlyph(UjiStrokes strokes, UjiScale scale) {
  final double left = ujiBox(strokes).left;
  return <List<InkVector>>[
    for (final List<InkVector> stroke in strokes)
      <InkVector>[
        for (final InkVector p in stroke)
          InkVector(
            (p.x - left) * 10 / scale.capHeight,
            10 + (p.y - scale.baseline) * 10 / scale.capHeight,
          ),
      ],
  ];
}

/// Symmetric Chamfer distance after translation and uniform height scaling,
/// as a share of glyph height. A match stays within 16% of the other trace;
/// this allows normal within-writer variation while still rejecting a
/// different topology (for example an r with the full right leg of an n).
double shapeDistance(UjiStrokes a, UjiStrokes b) {
  List<InkVector> normalized(UjiStrokes strokes) {
    final UjiBox box = ujiBox(strokes);
    final double scale = 1 / math.max(box.height, 1e-6);
    return <InkVector>[
      for (final List<InkVector> stroke in strokes)
        ...resampled(<InkVector>[
          for (final InkVector p in stroke)
            InkVector((p.x - box.left) * scale, (p.y - box.top) * scale),
        ], 0.025),
    ];
  }

  final List<InkVector> x = normalized(a);
  final List<InkVector> y = normalized(b);
  double directed(List<InkVector> from, List<InkVector> to) =>
      from.fold<double>(0, (double sum, InkVector p) {
        double nearest = double.infinity;
        for (final InkVector q in to) {
          nearest = math.min(nearest, (p - q).length);
        }
        return sum + nearest;
      }) /
      from.length;
  return (directed(x, y) + directed(y, x)) / 2;
}

double median(List<double> values) {
  values.sort();
  final int middle = values.length ~/ 2;
  return values.length.isOdd
      ? values[middle]
      : (values[middle - 1] + values[middle]) / 2;
}

UjiBox ujiBox(UjiStrokes strokes) {
  double left = double.infinity;
  double top = double.infinity;
  double right = double.negativeInfinity;
  double bottom = double.negativeInfinity;
  for (final List<InkVector> stroke in strokes) {
    for (final InkVector p in stroke) {
      left = math.min(left, p.x);
      top = math.min(top, p.y);
      right = math.max(right, p.x);
      bottom = math.max(bottom, p.y);
    }
  }
  return UjiBox(left, top, right, bottom);
}

class UjiBox {
  const UjiBox(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get height => bottom - top;
}
