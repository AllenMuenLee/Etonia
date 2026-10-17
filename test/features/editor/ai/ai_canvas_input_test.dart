import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:fake_async/fake_async.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_assistant_controller.dart';
import 'package:greatnote/features/editor/ai/ai_canvas_input.dart';
import 'package:greatnote/features/editor/ai/canvas_text_recognizer.dart';
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

List<RawInkSample> _samples(List<InkVector> points) => <RawInkSample>[
  for (int i = 0; i < points.length; i++)
    RawInkSample(
      position: points[i],
      timestamp: Duration(milliseconds: 8 * i),
    ),
];

/// Writes [points] as one stroke into [input].
void _write(
  AiCanvasInputController input,
  InkController page,
  List<InkVector> points, {
  int pointer = 1,
}) {
  final List<RawInkSample> samples = _samples(points);
  input
    ..begin(pointer, page, samples.first)
    ..add(pointer, samples.sublist(1, samples.length - 1))
    ..end(pointer, <RawInkSample>[samples.last]);
}

List<InkVector> _letter(InkVector start) => <InkVector>[
  for (int i = 0; i <= 12; i++)
    start + InkVector(i * 2.0, 10 * math.sin(i / 2)),
];

void main() {
  group('AiCanvasGestures.contextLoop', () {
    const InkVector center = InkVector(300, 300);

    test('a closed circle around a spot is a loop', () {
      expect(AiCanvasGestures.contextLoop(_loop(center, 80)), isNotNull);
    });

    test('a loop that overshoots and crosses itself is a loop', () {
      final List<InkVector> outline = AiCanvasGestures.contextLoop(
        _loop(center, 80, turn: 1.25),
      )!;
      // Only the enclosed part, from the crossing, is kept.
      expect(outline.length, lessThan(80));
    });

    test('a nearly closed loop is a loop', () {
      expect(
        AiCanvasGestures.contextLoop(_loop(center, 80, turn: 0.95)),
        isNotNull,
      );
    });

    test('a small o, an open arc, a line, or a dot is not', () {
      expect(AiCanvasGestures.contextLoop(_loop(center, 12)), isNull);
      expect(
        AiCanvasGestures.contextLoop(_loop(center, 80, turn: 0.6)),
        isNull,
      );
      expect(
        AiCanvasGestures.contextLoop(<InkVector>[
          for (int i = 0; i < 40; i++) InkVector(100.0 + i * 10, 100),
        ]),
        isNull,
      );
      expect(
        AiCanvasGestures.contextLoop(const <InkVector>[center, center]),
        isNull,
      );
    });

    test('a long loop around a line of writing is a loop', () {
      final List<InkVector> wide = <InkVector>[
        for (int i = 0; i <= 40; i++) InkVector(100.0 + i * 10, 300),
        for (int i = 40; i >= 0; i--) InkVector(100.0 + i * 10, 360),
        const InkVector(100, 300),
      ];
      expect(AiCanvasGestures.contextLoop(wide), isNotNull);
    });

    test('a closed scribble too thin to enclose a spot is not', () {
      final List<InkVector> thin = <InkVector>[
        for (int i = 0; i <= 40; i++) InkVector(100.0 + i * 10, 300),
        for (int i = 40; i >= 0; i--) InkVector(100.0 + i * 10, 316),
        const InkVector(100, 300),
      ];
      expect(AiCanvasGestures.contextLoop(thin), isNull);
      // Tall enough, but a sliver: not round enough.
      final List<InkVector> sliver = <InkVector>[
        for (int i = 0; i <= 40; i++) InkVector(100.0 + i * 25, 300),
        const InkVector(1100, 360),
        for (int i = 40; i >= 0; i--) InkVector(100.0 + i * 25, 302),
      ];
      expect(AiCanvasGestures.contextLoop(sliver), isNull);
    });
  });

  group('AiCanvasInputController', () {
    late InkController page;

    setUp(() => page = InkController());
    tearDown(() => page.dispose());

    test('holds strokes written close together and hands them over once '
        'the pen rests', () {
      fakeAsync((FakeAsync async) {
        final List<List<AiCanvasStroke>> read = <List<AiCanvasStroke>>[];
        final AiCanvasInputController input = AiCanvasInputController(
          onHandwriting:
              (
                List<AiCanvasStroke> strokes,
                InkController _, {
                required bool openPanel,
              }) => read.add(strokes),
        );
        _write(input, page, _letter(const InkVector(100, 100)));
        expect(input.pendingStrokes, hasLength(1));
        async.elapse(const Duration(milliseconds: 500));
        _write(input, page, _letter(const InkVector(140, 100)), pointer: 2);
        async.elapse(const Duration(milliseconds: 750));
        expect(read, isEmpty);
        async.elapse(const Duration(milliseconds: 100));
        expect(read, hasLength(1));
        expect(read.single, hasLength(2));
        expect(input.isEmpty, isTrue);
        input.dispose();
      });
    });

    test('a pen down pauses the wait until it lifts', () {
      fakeAsync((FakeAsync async) {
        int batches = 0;
        final AiCanvasInputController input = AiCanvasInputController(
          onHandwriting:
              (
                List<AiCanvasStroke> _,
                InkController _, {
                required bool openPanel,
              }) => batches++,
        );
        _write(input, page, _letter(const InkVector(100, 100)));
        final List<RawInkSample> next = _samples(
          _letter(const InkVector(140, 100)),
        );
        input.begin(2, page, next.first);
        async.elapse(const Duration(seconds: 2));
        expect(batches, 0);
        input.end(2, next.sublist(1));
        async.elapse(const Duration(seconds: 1));
        expect(batches, 1);
        input.dispose();
      });
    });

    test('a loop taken as context is not handwriting', () {
      fakeAsync((FakeAsync async) {
        List<InkVector>? circled;
        int batches = 0;
        final AiCanvasInputController input = AiCanvasInputController(
          onCircle: (List<InkVector> outline, InkController _) {
            circled = outline;
            return true;
          },
          onHandwriting:
              (
                List<AiCanvasStroke> _,
                InkController _, {
                required bool openPanel,
              }) => batches++,
        );
        _write(input, page, _loop(const InkVector(300, 300), 80));
        expect(circled, isNotNull);
        expect(input.isEmpty, isTrue);
        async.elapse(const Duration(seconds: 2));
        expect(batches, 0);
        input.dispose();
      });
    });

    test('a loop after handwriting is part of the handwriting', () {
      fakeAsync((FakeAsync async) {
        int circles = 0;
        final AiCanvasInputController input = AiCanvasInputController(
          onCircle: (List<InkVector> _, InkController _) {
            circles++;
            return true;
          },
        );
        _write(input, page, _letter(const InkVector(100, 100)));
        _write(input, page, _loop(const InkVector(300, 300), 80), pointer: 2);
        expect(circles, 0);
        expect(input.pendingStrokes, hasLength(2));
        input.dispose();
      });
    });

    test('a declined loop is handwriting', () {
      final AiCanvasInputController input = AiCanvasInputController(
        onCircle: (List<InkVector> _, InkController _) => false,
      );
      _write(input, page, _loop(const InkVector(300, 300), 80));
      expect(input.pendingStrokes, hasLength(1));
      input.dispose();
    });

    test('flush hands over at once; clear reads nothing', () {
      fakeAsync((FakeAsync async) {
        final List<bool> opened = <bool>[];
        final AiCanvasInputController input = AiCanvasInputController(
          onHandwriting:
              (
                List<AiCanvasStroke> _,
                InkController _, {
                required bool openPanel,
              }) => opened.add(openPanel),
        );
        _write(input, page, _letter(const InkVector(100, 100)));
        input.flush(openPanel: false);
        expect(opened, <bool>[false]);

        _write(input, page, _letter(const InkVector(100, 100)));
        input.clear();
        async.elapse(const Duration(seconds: 2));
        expect(opened, hasLength(1));
        expect(input.isEmpty, isTrue);
        input.dispose();
      });
    });

    test('only one pointer writes at a time', () {
      final AiCanvasInputController input = AiCanvasInputController();
      final List<RawInkSample> samples = _samples(
        _letter(const InkVector(100, 100)),
      );
      expect(input.begin(1, page, samples.first), isTrue);
      expect(input.begin(2, page, samples.first), isFalse);
      input.cancel(1);
      expect(input.isEmpty, isTrue);
      input.dispose();
    });

    test('the written points are smoothed and end where the pen lifted', () {
      final AiCanvasInputController input = AiCanvasInputController();
      final List<InkVector> raw = _letter(const InkVector(100, 100));
      _write(input, page, raw);
      final List<AiCanvasPoint> points = input.pendingStrokes.single.points;
      expect(points.first.position, raw.first);
      expect(points.last.position, raw.last);
      input.dispose();
    });
  });

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
