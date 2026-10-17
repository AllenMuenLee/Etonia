import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/ai_config.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/notation_playback.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/widgets/ai_assistant_panel.dart';
import 'package:greatnote/features/editor/widgets/editor_settings_sheet.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the app launches into the editor and accepts a stroke', (
    WidgetTester tester,
  ) async {
    final InkController controller = InkController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      GreatnoteApp(home: EditorScreen(inkController: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Untitled note'), findsOneWidget);
    expect(find.byTooltip('Pen'), findsOneWidget);
    expect(find.byTooltip('Eraser'), findsOneWidget);
    expect(find.byTooltip('Select'), findsOneWidget);

    final Offset center = tester.getCenter(find.byType(InkCanvas));
    final TestGesture gesture = await tester.startGesture(
      center - const Offset(60, 0),
      kind: PointerDeviceKind.stylus,
    );
    for (int i = 1; i <= 12; i++) {
      await gesture.moveBy(
        const Offset(10, 0),
        timeStamp: Duration(milliseconds: 8 * i),
      );
      await tester.pump();
    }
    await gesture.up(timeStamp: const Duration(milliseconds: 104));
    await tester.pumpAndSettle();

    expect(controller.strokes.length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ink can be lassoed, moved, copied, and pasted', (
    WidgetTester tester,
  ) async {
    final InkController controller = InkController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      GreatnoteApp(home: EditorScreen(inkController: controller)),
    );
    await tester.pumpAndSettle();
    final Offset center = tester.getCenter(find.byType(InkCanvas));

    Future<void> drag(List<Offset> path) async {
      final TestGesture gesture = await tester.startGesture(
        path.first,
        kind: PointerDeviceKind.stylus,
      );
      int sample = 0;
      for (int leg = 1; leg < path.length; leg++) {
        for (int i = 1; i <= 6; i++) {
          await gesture.moveTo(
            Offset.lerp(path[leg - 1], path[leg], i / 6)!,
            timeStamp: Duration(milliseconds: 8 * ++sample),
          );
          await tester.pump();
        }
      }
      await gesture.up(timeStamp: Duration(milliseconds: 8 * (sample + 1)));
      await tester.pumpAndSettle();
    }

    await drag(<Offset>[
      center - const Offset(40, 0),
      center + const Offset(40, 0),
    ]);
    expect(controller.strokes.length, 1);
    final double drawnAt = controller.strokes.single.points.first.y;

    await tester.tap(find.byTooltip('Select'));
    await tester.pumpAndSettle();
    await drag(<Offset>[
      center + const Offset(-70, -30),
      center + const Offset(70, -30),
      center + const Offset(70, 30),
      center + const Offset(-70, 30),
      center + const Offset(-70, -30),
    ]);
    expect(controller.selection?.count, 1);
    // No ink was drawn by the lasso.
    expect(controller.strokes.length, 1);

    await drag(<Offset>[center, center + const Offset(0, 60)]);
    expect(
      controller.strokes.single.points.first.y,
      closeTo(drawnAt + 60, 1e-6),
    );

    await tester.tap(find.byTooltip('Copy'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Select'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste'));
    await tester.pumpAndSettle();

    expect(controller.strokes.length, 2);
    expect(controller.selection?.indices, <int>[1]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selected ink can be sent to the assistant and answered', (
    WidgetTester tester,
  ) async {
    final _CannedAiClient client = _CannedAiClient();
    final InkController controller = InkController(
      strokes: <Stroke>[
        Stroke.fromPoints(
          style: const StrokeStyle(ink: InkPalette.ink, width: 4),
          points: const <InkVector>[InkVector(120, 200), InkVector(220, 200)],
        ),
      ],
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      GreatnoteApp(
        home: EditorScreen(inkController: controller, aiClient: client),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Select'));
    await tester.pumpAndSettle();
    controller
      ..beginLasso(pointer: 90, position: const InkVector(100, 180))
      ..endLasso(90, const InkVector(240, 220));
    await tester.pumpAndSettle();
    expect(controller.selection?.count, 1);

    await tester.tap(find.byTooltip('AI assistant'));
    await tester.pumpAndSettle();
    expect(find.byType(AiAssistantPanel), findsOneWidget);
    // Opening sends nothing.
    expect(client.requests, isEmpty);

    // The real renderer, on the device's own engine.
    final Finder explain = find.widgetWithText(OutlinedButton, 'Explain this');
    for (
      int i = 0;
      i < 50 && tester.widget<OutlinedButton>(explain).onPressed == null;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(explain);
    await tester.pumpAndSettle();

    final AiRequest request = client.requests.single;
    expect(request.messages.single.text, AiPrompts.explain);
    expect(request.imagePng.sublist(0, 4), <int>[0x89, 0x50, 0x4E, 0x47]);
    expect(find.text('A canned answer.'), findsOneWidget);

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    expect(find.byType(EditorSettingsSheet), findsOneWidget);
    // Animation is already on.
    await tester.tap(find.text('Enable notation'));
    await tester.tap(find.text('Left'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(EditorSettingsSheet))).pop();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(AiAssistantPanel)).dx, 0);

    await tester.enterText(find.byType(TextField), 'Mark it');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    // Whole-note rasterization is intentionally real in this smoke test and
    // can take longer on a physical device than under flutter_tester.
    for (int i = 0; i < 500 && controller.notationPlayback == null; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(client.requests, hasLength(2));
    final AiRequest notationRequest = client.requests.last;
    expect(notationRequest.notationEnabled, isTrue);
    expect(notationRequest.animationEnabled, isTrue);
    expect(notationRequest.noteImage, isNotNull);
    expect(notationRequest.noteImage!.png.sublist(0, 4), <int>[
      0x89,
      0x50,
      0x4E,
      0x47,
    ]);
    expect(
      tester
          .widget<AiAssistantPanel>(find.byType(AiAssistantPanel))
          .controller
          .messages
          .last
          .notationStatus,
      AiNotationStatus.animating,
    );
    expect(controller.strokes, hasLength(2));
    expect(controller.strokes.last.source, StrokeSource.derived);
    expect(controller.notationPlayback, isNotNull);
    expect(
      controller.notationPlayback!.revealAt(0).state,
      TraceRevealState.partial,
    );
    expect(find.textContaining('Drawing…'), findsNothing);

    // A controlled pump reaches a partial frame without depending on the
    // device's refresh rate, then crossing the duration starts another loop.
    await tester.pump(const Duration(milliseconds: 700));
    expect(controller.notationPlayback, isNotNull);
    expect(
      controller.notationPlayback!.revealAt(0).state,
      TraceRevealState.partial,
    );
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pump();
    expect(controller.notationPlayback, isNotNull);
    expect(find.text('Finish now'), findsNothing);

    final Object playback = controller.notationPlayback!;
    final Duration beforeClose = controller.notationPlayback!.clockElapsed;
    await tester.tap(find.byTooltip('Close AI assistant'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 1300));
    expect(find.byType(AiAssistantPanel), findsNothing);
    // Closing the chat leaves AI mode on, and its notation shown.
    expect(find.byTooltip('Turn off AI'), findsOneWidget);
    expect(controller.isStrokeHidden(controller.strokes.last), isFalse);
    expect(controller.notationPlayback, same(playback));
    expect(controller.notationPlayback!.clockElapsed, greaterThan(beforeClose));

    // The animated stroke stays selectable and erasable like any other
    // stroke; selecting it does not stop it, and erasing it ends the loop.
    final Size surface = tester.getSize(find.byType(InkCanvas));
    final Stroke notation = controller.strokes.last;
    controller
      ..clearSelection()
      ..beginLasso(
        pointer: 91,
        position: InkVector(surface.width * 0.40, surface.height * 0.38),
      )
      ..endLasso(91, InkVector(surface.width * 0.60, surface.height * 0.58));
    await tester.pump();
    expect(controller.selection?.strokes, contains(same(notation)));
    expect(controller.notationPlayback, same(playback));

    controller
      ..clearSelection()
      ..startErase(
        pointer: 92,
        position: notation.points[1],
        settings: const EraserSettings(mode: EraserMode.stroke, size: 24),
      )
      ..endErase(92);
    await tester.pump();
    expect(controller.strokes.length, 1);
    expect(controller.strokes, isNot(contains(same(notation))));
    expect(controller.notationPlayback, isNull);
    expect(tester.takeException(), isNull);
  });
}

/// Answers at once, without a network.
class _CannedAiClient implements AiClient {
  final List<AiRequest> requests = <AiRequest>[];

  @override
  bool get isConfigured => true;

  @override
  String get modelLabel => 'Canned';

  @override
  Future<AiResult> send(
    AiRequest request, {
    AiPartialCallback? onPartial,
  }) async {
    requests.add(request);
    if (request.notationEnabled) {
      return AiSuccess.response(
        AiAssistantResponse(
          message: 'I showed the current flow.',
          notation: AiNotation(
            label: 'Canned current flow',
            items: <AiNotationItem>[
              AiNotationStroke(
                ink: 'green',
                width: 3,
                points: const <AiNotationPoint>[
                  AiNotationPoint(0.45, 0.50),
                  AiNotationPoint(0.49, 0.54),
                  AiNotationPoint(0.56, 0.44),
                ],
              ),
            ],
            timeline: AiNotationTimeline(
              durationMs: 1800,
              items: const <AiItemTiming>[AiItemTiming(0, 1500)],
            ),
          ),
        ),
      );
    }
    return const AiSuccess('A canned answer.');
  }

  @override
  void close() {}
}
