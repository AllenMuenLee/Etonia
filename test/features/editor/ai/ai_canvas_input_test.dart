import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_assistant_controller.dart';
import 'package:greatnote/features/editor/ai/ai_canvas_input.dart';
import 'package:greatnote/features/editor/ai/canvas_text_recognizer.dart';
import 'package:greatnote/features/editor/ai/handwriting_prediction.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

import '../../../helpers/ai_fakes.dart';

List<InkVector> _loop(
  InkVector center,
  double radius, {
  double turn = 1,
  int steps = 72,
}) {
  return <InkVector>[
    for (int i = 0; i <= steps; i++)
      center +
          InkVector(
            radius * math.cos(2 * math.pi * turn * i / steps),
            radius * math.sin(2 * math.pi * turn * i / steps),
          ),
  ];
}

void main() {
  group('InkController.selectEnclosed', () {
    test('selects the ink a loop encloses, or leaves the selection', () {
      final InkController controller = InkController(
        strokes: <Stroke>[
          Stroke.fromPoints(
            style: const StrokeStyle(ink: InkPalette.ink, width: 4),
            points: const <InkVector>[InkVector(290, 300), InkVector(310, 300)],
          ),
        ],
      );
      addTearDown(controller.dispose);
      expect(
        controller.selectEnclosed(_loop(const InkVector(600, 600), 60)),
        isFalse,
      );
      expect(controller.selection, isNull);
      expect(
        controller.selectEnclosed(_loop(const InkVector(300, 300), 60)),
        isTrue,
      );
      expect(controller.selection!.indices, <int>[0]);
      expect(controller.documentRevision, 0);
      expect(controller.canUndo, isFalse);
    });

    test('selects a region of PDF paper', () {
      final InkController controller = InkController();
      addTearDown(controller.dispose);
      expect(
        controller.selectEnclosed(
          _loop(const InkVector(300, 300), 60),
          selectablePdfBounds: const ui.Rect.fromLTWH(0, 0, 800, 1000),
        ),
        isTrue,
      );
      expect(controller.selection!.includesPdf, isTrue);
    });
  });

  group('AiAssistantController', () {
    test('appendToDraft adds words a single space apart', () {
      final AiAssistantController ai = AiAssistantController(
        client: FakeAiClient(),
      );
      addTearDown(ai.dispose);
      int notified = 0;
      ai.addListener(() => notified++);
      ai.appendToDraft('  hello ');
      expect(ai.draft, 'hello');
      ai.draft = 'hello   ';
      ai.appendToDraft('world');
      expect(ai.draft, 'hello world');
      ai.appendToDraft('   ');
      expect(ai.draft, 'hello world');
      expect(notified, 2);
    });

    test('show opens the panel without a context', () {
      final AiAssistantController ai = AiAssistantController(
        client: FakeAiClient(),
      );
      addTearDown(ai.dispose);
      ai.show();
      expect(ai.isOpen, isTrue);
      expect(ai.context, isNull);
    });
  });

  group('HandwritingImageRenderer', () {
    testWidgets('draws dark ink on opaque white, cropped to the strokes', (
      WidgetTester tester,
    ) async {
      final AiCanvasStroke stroke = AiCanvasStroke(<AiCanvasPoint>[
        for (int i = 0; i <= 20; i++)
          AiCanvasPoint(
            InkVector(200.0 + i * 5, 150),
            Duration(milliseconds: i),
          ),
      ]);
      final HandwritingBatch batch = (await tester.runAsync(
        () => const HandwritingImageRenderer().render(<AiCanvasStroke>[stroke]),
      ))!;
      const AiCanvasConfig config = AiCanvasConfig();
      expect(
        batch.logicalBounds,
        const ui.Rect.fromLTRB(
          200,
          150,
          300,
          150,
        ).inflate(config.recognitionPadding),
      );
      expect(batch.strokes.single, same(stroke));
      final (int width, List<int> pixels) = (await tester.runAsync(() async {
        final ui.Codec codec = await ui.instantiateImageCodec(batch.png);
        final ui.Image image = (await codec.getNextFrame()).image;
        final ByteData data = (await image.toByteData())!;
        final int width = image.width;
        image.dispose();
        return (width, data.buffer.asUint8List().toList());
      }))!;
      expect(width, batch.pixelSize.width.round());
      List<int> at(int x, int y) {
        final int i = (y * width + x) * 4;
        return pixels.sublist(i, i + 4);
      }

      // A corner is white and opaque; the middle of the line is dark.
      expect(at(1, 1), <int>[255, 255, 255, 255]);
      final double scale = batch.pixelSize.width / batch.logicalBounds.width;
      final List<int> ink = at(
        ((250 - batch.logicalBounds.left) * scale).round(),
        ((150 - batch.logicalBounds.top) * scale).round(),
      );
      expect(ink[0], lessThan(60));
      expect(ink[3], 255);
    });
  });

  group('PlatformCanvasTextRecognizer', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    HandwritingBatch batch() => HandwritingBatch(
      strokes: <AiCanvasStroke>[
        AiCanvasStroke(const <AiCanvasPoint>[
          AiCanvasPoint(InkVector(10, 10), Duration.zero),
          AiCanvasPoint(InkVector(20, 10), Duration(milliseconds: 8)),
        ]),
      ],
      png: Uint8List.fromList(<int>[1, 2, 3]),
      pixelSize: const ui.Size(40, 20),
      logicalBounds: const ui.Rect.fromLTWH(0, 0, 40, 20),
    );

    test('sends the image and strokes over the channel', () async {
      MethodCall? received;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(PlatformCanvasTextRecognizer.channel, (
            MethodCall call,
          ) async {
            received = call;
            return '  hello  ';
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              PlatformCanvasTextRecognizer.channel,
              null,
            ),
      );
      expect(
        await const PlatformCanvasTextRecognizer().recognize(batch()),
        'hello',
      );
      expect(received!.method, 'recognize');
      final Map<Object?, Object?> arguments =
          received!.arguments as Map<Object?, Object?>;
      expect(arguments['png'], <int>[1, 2, 3]);
      expect(arguments['width'], 40);
      expect(arguments['strokes'], <List<double>>[
        <double>[10, 10, 0, 20, 10, 8],
      ]);
    });

    test(
      'passes context and ranks native alternatives in reading order',
      () async {
        MethodCall? received;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(PlatformCanvasTextRecognizer.channel, (
              call,
            ) async {
              received = call;
              return {
                'segments': [
                  [
                    {'text': 'standard'},
                  ],
                  [
                    {'text': 'farm', 'confidence': 0.8},
                    {'text': 'form', 'confidence': 0.8},
                  ],
                ],
              };
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(
                PlatformCanvasTextRecognizer.channel,
                null,
              ),
        );
        final words = await const PlatformCanvasTextRecognizer().recognize(
          batch().withContext(
            HandwritingContext(
              draft: 'the',
              recentMessages: ['The standard form. A farm.'],
            ),
          ),
        );
        expect(words, 'standard form');
        final arguments = received!.arguments as Map<Object?, Object?>;
        expect(arguments['preContext'], 'the ');
        expect(arguments['customWords'], contains('standard'));
      },
    );

    test('ignores malformed candidates without adding invented text', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            PlatformCanvasTextRecognizer.channel,
            (call) async => {
              'segments': [
                null,
                [
                  4,
                  {'text': 7},
                  {'text': 'hello', 'confidence': 'bad'},
                ],
              ],
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              PlatformCanvasTextRecognizer.channel,
              null,
            ),
      );
      expect(
        await const PlatformCanvasTextRecognizer().recognize(batch()),
        'hello',
      );
    });

    test('reads nothing where recognition is unavailable', () async {
      expect(await const PlatformCanvasTextRecognizer().recognize(batch()), '');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            PlatformCanvasTextRecognizer.channel,
            (MethodCall call) async =>
                throw PlatformException(code: 'unavailable'),
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              PlatformCanvasTextRecognizer.channel,
              null,
            ),
      );
      expect(await const PlatformCanvasTextRecognizer().recognize(batch()), '');
    });
  });
}
