import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_notation.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

final InkColor _blue = InkPalette.colors.firstWhere(
  (InkColor color) => color.id == 'blue',
);

GeneratedInkTrace _trace({
  List<InkVector> points = const <InkVector>[
    InkVector(20, 20),
    InkVector(40, 40),
  ],
}) {
  return GeneratedInkTrace(
    style: StrokeStyle(ink: _blue, width: 3),
    points: points,
  );
}

void main() {
  test('adds a multi-trace notation atomically as derived ink', () {
    final InkController controller = InkController();
    addTearDown(controller.dispose);
    int completed = 0;
    int revisions = 0;
    controller.completedStrokesListenable.addListener(() => completed++);
    controller.documentRevisionListenable.addListener(() => revisions++);

    final AddNotationResult result = controller.addAiNotation(
      traces: <GeneratedInkTrace>[
        _trace(),
        _trace(points: const <InkVector>[InkVector(60, 60)]),
      ],
      expectedRevision: 0,
      surfaceSize: const Size(100, 100),
    );

    expect(result, AddNotationResult.added);
    expect(controller.strokes, hasLength(2));
    expect(
      controller.strokes.every((Stroke s) => s.source == StrokeSource.derived),
      isTrue,
    );
    expect(controller.strokes[0].points, const <InkVector>[
      InkVector(20, 20),
      InkVector(40, 40),
    ]);
    expect(controller.strokes[1].isDot, isTrue);
    expect(controller.strokes[0].style.ink, same(_blue));
    expect(controller.documentRevision, 1);
    expect(completed, 1);
    expect(revisions, 1);
  });

  test('stale, busy, and invalid batches change nothing', () {
    final InkController controller = InkController();
    addTearDown(controller.dispose);
    int completed = 0;
    controller.completedStrokesListenable.addListener(() => completed++);

    expect(
      controller.addAiNotation(
        traces: <GeneratedInkTrace>[_trace()],
        expectedRevision: 1,
        surfaceSize: const Size(100, 100),
      ),
      AddNotationResult.stale,
    );
    controller.startStroke(
      pointer: 1,
      sample: const RawInkSample(
        position: InkVector(50, 50),
        timestamp: Duration.zero,
      ),
      style: const StrokeStyle(ink: InkPalette.ink, width: 3),
    );
    expect(
      controller.addAiNotation(
        traces: <GeneratedInkTrace>[_trace()],
        expectedRevision: 0,
        surfaceSize: const Size(100, 100),
      ),
      AddNotationResult.busy,
    );
    controller.cancelStroke(1);
    final int afterInput = completed;
    expect(
      controller.addAiNotation(
        traces: <GeneratedInkTrace>[
          _trace(points: const <InkVector>[InkVector(0, 50)]),
        ],
        expectedRevision: controller.documentRevision,
        surfaceSize: const Size(100, 100),
      ),
      AddNotationResult.invalid,
    );
    expect(controller.strokes, hasLength(1));
    expect(completed, afterInput);
  });

  test(
    'rejects an unregistered color even when its ID matches the palette',
    () {
      final InkController controller = InkController();
      addTearDown(controller.dispose);
      const InkColor imitation = InkColor(
        id: 'blue',
        label: 'Imitation',
        onLightPaper: Color(0xFF0000FF),
        onDarkPaper: Color(0xFF0000FF),
      );

      final AddNotationResult result = controller.addAiNotation(
        traces: <GeneratedInkTrace>[
          GeneratedInkTrace(
            style: const StrokeStyle(ink: imitation, width: 3),
            points: const <InkVector>[InkVector(20, 20)],
          ),
        ],
        expectedRevision: 0,
        surfaceSize: const Size(100, 100),
      );

      expect(result, AddNotationResult.invalid);
      expect(controller.strokes, isEmpty);
      expect(controller.documentRevision, 0);
    },
  );
}
