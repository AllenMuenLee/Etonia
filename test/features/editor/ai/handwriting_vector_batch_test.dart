import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_canvas_input.dart';
import 'package:greatnote/features/editor/ai/canvas_text_recognizer.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';

void main() {
  test('native handwriting batches require no Dart-side PNG', () {
    final HandwritingBatch batch = const HandwritingImageRenderer().vectors(
      <AiCanvasStroke>[
        AiCanvasStroke(<AiCanvasPoint>[
          const AiCanvasPoint(InkVector(10, 20), Duration.zero),
          const AiCanvasPoint(InkVector(30, 40), Duration(milliseconds: 8)),
        ]),
      ],
    );
    expect(batch.png, isEmpty);
    expect(batch.pixelSize.width, greaterThan(0));
    expect(batch.logicalBounds.contains(const Offset(10, 20)), isTrue);
  });
}
