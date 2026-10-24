import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/handwriting/ink_search.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

const StrokeStyle _style = StrokeStyle(ink: InkPalette.ink, width: 2);

Stroke _stroke(List<InkVector> points) =>
    Stroke.fromPoints(style: _style, points: points);

void main() {
  group('InkSearch text', () {
    test('finds native alternatives and small transcription errors', () {
      final InkSearchRegion region = InkSearchRegion(
        strokes: const <List<InkVector>>[],
        texts: const <String>['form', 'from'],
        confidence: 0.72,
      );

      final List<InkSearchMatch> exactAlternative = InkSearch.find(
        regions: <InkSearchRegion>[region],
        text: 'from',
      );
      final List<InkSearchMatch> fuzzy = InkSearch.find(
        regions: <InkSearchRegion>[region],
        text: 'frm',
      );

      expect(exactAlternative, hasLength(1));
      expect(exactAlternative.single.textScore, greaterThan(0.8));
      expect(fuzzy, hasLength(1));
    });

    test('normalizes common math aliases', () {
      expect(InkSearch.normalizeSearchText(r'\int'), '∫');
      expect(InkSearch.normalizeSearchText('alpha'), 'α');
      expect(InkSearch.normalizeSearchText('square root'), '√');
    });

    test('joins adjacent recognized words into searchable phrases', () {
      final List<InkSearchRegion> words = <InkSearchRegion>[
        InkSearchRegion(
          strokes: const <List<InkVector>>[
            <InkVector>[InkVector(0, 0), InkVector(10, 10)],
          ],
          texts: const <String>['electric'],
        ),
        InkSearchRegion(
          strokes: const <List<InkVector>>[
            <InkVector>[InkVector(14, 0), InkVector(24, 10)],
          ],
          texts: const <String>['field'],
        ),
      ];
      final List<InkSearchRegion> phrases = InkSearch.lineSequences(words);

      expect(phrases, hasLength(1));
      expect(phrases.single.texts.single, 'electric field');
      expect(
        InkSearch.find(regions: phrases, text: 'electic field'),
        isNotEmpty,
      );
    });
  });

  group('InkSearch geometry', () {
    const List<List<InkVector>> circuit = <List<InkVector>>[
      <InkVector>[InkVector(0, 20), InkVector(20, 20)],
      <InkVector>[
        InkVector(20, 20),
        InkVector(25, 15),
        InkVector(30, 25),
        InkVector(35, 15),
        InkVector(40, 25),
        InkVector(45, 20),
      ],
      <InkVector>[InkVector(45, 20), InkVector(70, 20)],
      <InkVector>[
        InkVector(70, 20),
        InkVector(70, 55),
        InkVector(0, 55),
        InkVector(0, 20),
      ],
    ];

    test('matches translated and scaled drawings', () {
      final List<List<InkVector>> transformed = <List<InkVector>>[
        for (final List<InkVector> stroke in circuit)
          <InkVector>[
            for (final InkVector point in stroke)
              InkVector(100 + point.x * 2, 80 + point.y * 2),
          ],
      ];

      final double same = InkSearch.strokeSimilarity(circuit, transformed);
      final double different = InkSearch.strokeSimilarity(
        circuit,
        const <List<InkVector>>[
          <InkVector>[InkVector(0, 0), InkVector(70, 55)],
        ],
      );

      expect(same, greaterThan(0.85));
      expect(same, greaterThan(different));
    });

    test('retains an unrecognized diagram as a shape result', () {
      final InkSearchRegion diagram = InkSearchRegion(strokes: circuit);
      final List<InkSearchMatch> matches = InkSearch.find(
        regions: <InkSearchRegion>[diagram],
        strokes: circuit,
      );

      expect(matches, hasLength(1));
      expect(matches.single.textScore, 0);
      expect(matches.single.shapeScore, greaterThan(0.9));
    });

    test('connects circuit strokes written separately', () {
      final List<Stroke> strokes = <Stroke>[
        for (final List<InkVector> points in circuit) _stroke(points),
      ];
      final List<InkSearchRegion> regions = InkSearch.connectedRegions(strokes);

      expect(regions, hasLength(1));
      expect(regions.single.strokes, hasLength(circuit.length));
    });
  });
}
