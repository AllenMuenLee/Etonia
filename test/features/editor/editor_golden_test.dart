@Tags(<String>['golden'])
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/ai/ai_assistant_controller.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/selection_transform.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/widgets/ai_assistant_panel.dart';

import '../../helpers/ai_fakes.dart';
import '../../helpers/editor_harness.dart';
import '../../helpers/pump_app.dart';

InkColor _ink(String id) {
  return InkPalette.colors.firstWhere((InkColor ink) => ink.id == id);
}

/// A few strokes of different colors and widths, and a dot. The first four
/// sit together; the last is apart. It fits every reference viewport.
List<Stroke> _page() {
  Stroke wave(double y, InkColor ink, double width) {
    return Stroke.fromPoints(
      style: StrokeStyle(ink: ink, width: width),
      points: <InkVector>[
        for (int i = 0; i <= 40; i++)
          InkVector(110 + i * 4, y + 12 * math.sin(i / 4)),
      ],
    );
  }

  return <Stroke>[
    wave(220, InkPalette.ink, 3),
    wave(260, _ink('blue'), 6),
    wave(300, _ink('red'), 2),
    Stroke.fromPoints(
      style: StrokeStyle(ink: _ink('green'), width: 12),
      points: const <InkVector>[InkVector(190, 340)],
    ),
    wave(520, _ink('purple'), 4),
  ];
}

/// Picks the Select tool and lassos the first four strokes of [_page].
Future<void> _select(WidgetTester tester, InkController controller) async {
  await tester.tap(find.byTooltip('Select'));
  await tester.pumpAndSettle();
  controller
    ..beginLasso(pointer: 1, position: const InkVector(90, 190))
    ..updateLasso(1, const InkVector(290, 190))
    ..updateLasso(1, const InkVector(290, 370))
    ..updateLasso(1, const InkVector(90, 370))
    ..endLasso(1, const InkVector(90, 190));
  await tester.pumpAndSettle();
  expect(controller.selection!.count, 4);
}

void main() {
  for (final (String name, TestViewport viewport, ThemeMode themeMode)
      in <(String, TestViewport, ThemeMode)>[
        ('tablet_portrait_light', TestViewport.tabletPortrait, ThemeMode.light),
        (
          'tablet_landscape_light',
          TestViewport.tabletLandscape,
          ThemeMode.light,
        ),
        ('tablet_landscape_dark', TestViewport.tabletLandscape, ThemeMode.dark),
        ('compact_light', TestViewport.compact, ThemeMode.light),
      ]) {
    testWidgets('editor: $name', (WidgetTester tester) async {
      // pumpApp fixes the surface size and pixel ratio and settles animation.
      await pumpApp(tester, viewport: viewport, themeMode: themeMode);

      await expectLater(
        find.byType(GreatnoteApp),
        matchesGoldenFile('goldens/editor_$name.png'),
      );
    });
  }

  for (final (String name, TestViewport viewport, ThemeMode themeMode)
      in <(String, TestViewport, ThemeMode)>[
        (
          'tablet_landscape_light',
          TestViewport.tabletLandscape,
          ThemeMode.light,
        ),
        ('tablet_landscape_dark', TestViewport.tabletLandscape, ThemeMode.dark),
        ('compact_light', TestViewport.compact, ThemeMode.light),
      ]) {
    testWidgets('eraser options: $name', (WidgetTester tester) async {
      await pumpApp(tester, viewport: viewport, themeMode: themeMode);
      // The first press selects the eraser, the second opens its options.
      await tester.tap(find.byTooltip('Eraser'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Eraser'));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(GreatnoteApp),
        matchesGoldenFile('goldens/eraser_options_$name.png'),
      );
    });
  }

  for (final (String name, TestViewport viewport, ThemeMode themeMode)
      in <(String, TestViewport, ThemeMode)>[
        (
          'tablet_landscape_light',
          TestViewport.tabletLandscape,
          ThemeMode.light,
        ),
        ('tablet_landscape_dark', TestViewport.tabletLandscape, ThemeMode.dark),
        ('compact_light', TestViewport.compact, ThemeMode.light),
      ]) {
    testWidgets('selection: $name', (WidgetTester tester) async {
      final InkController controller = await pumpEditor(
        tester,
        viewport: viewport,
        themeMode: themeMode,
        strokes: _page(),
      );
      await _select(tester, controller);

      await expectLater(
        find.byType(GreatnoteApp),
        matchesGoldenFile('goldens/selection_$name.png'),
      );
    });
  }

  for (final (String name, ThemeMode themeMode) in <(String, ThemeMode)>[
    ('tablet_landscape_light', ThemeMode.light),
    ('tablet_landscape_dark', ThemeMode.dark),
  ]) {
    testWidgets('selection, turned and scaled: $name', (
      WidgetTester tester,
    ) async {
      final InkController controller = await pumpEditor(
        tester,
        themeMode: themeMode,
        strokes: _page(),
      );
      await _select(tester, controller);
      // A sixth of a turn from the rotation handle, then half as big again
      // from the bottom-right corner.
      SelectionFrame frame = controller.selection!.frame;
      final InkVector handle = frame.rotationHandle(
        controller.selectionConfig.rotationHandleOffset,
      );
      controller
        ..beginSelectionGesture(pointer: 1, position: handle)
        ..endSelectionGesture(
          1,
          InkTransform.rotation(frame.center, math.pi / 6).apply(handle),
        );
      frame = controller.selection!.frame;
      final InkVector fixed = frame.corners[0];
      controller
        ..beginSelectionGesture(pointer: 1, position: frame.corners[2])
        ..endSelectionGesture(1, fixed + (frame.corners[2] - fixed) * 1.5);
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(GreatnoteApp),
        matchesGoldenFile('goldens/selection_transformed_$name.png'),
      );
    });
  }

  testWidgets('lasso in progress: tablet_landscape_light', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester, strokes: _page());
    await tester.tap(find.byTooltip('Select'));
    await tester.pumpAndSettle();
    controller.beginLasso(pointer: 1, position: const InkVector(100, 200));
    for (int i = 1; i <= 60; i++) {
      final double turn = i / 80 * 2 * math.pi;
      controller.updateLasso(
        1,
        InkVector(
          190 - 90 * math.cos(turn) + 20 * math.sin(3 * turn),
          280 - 90 * math.sin(turn) * 1.1 + 80 * math.sin(turn / 2),
        ),
      );
    }
    await tester.pump();

    await expectLater(
      find.byType(GreatnoteApp),
      matchesGoldenFile('goldens/selection_lasso_tablet_landscape_light.png'),
    );
    controller.cancelLasso(1);
  });

  testWidgets('rectangle in progress: tablet_landscape_dark', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(
      tester,
      themeMode: ThemeMode.dark,
      strokes: _page(),
    );
    await tester.tap(find.byTooltip('Select'));
    await tester.pumpAndSettle();
    controller
      ..beginLasso(pointer: 1, position: const InkVector(90, 190))
      ..updateLasso(1, const InkVector(200, 290))
      ..updateLasso(1, const InkVector(300, 370));
    await tester.pump();

    await expectLater(
      find.byType(GreatnoteApp),
      matchesGoldenFile(
        'goldens/selection_rectangle_tablet_landscape_dark.png',
      ),
    );
    controller.cancelLasso(1);
  });

  testWidgets('paste offered after a hold: tablet_landscape_light', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester, strokes: _page());
    await _select(tester, controller);
    controller.copySelection();
    final Offset spot = canvasRect(tester).topLeft + const Offset(520, 420);
    final TestGesture gesture = await tester.startGesture(spot);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(GreatnoteApp),
      matchesGoldenFile('goldens/paste_prompt_tablet_landscape_light.png'),
    );
  });

  for (final (String name, TestViewport viewport, ThemeMode themeMode)
      in <(String, TestViewport, ThemeMode)>[
        (
          'tablet_landscape_light',
          TestViewport.tabletLandscape,
          ThemeMode.light,
        ),
        ('compact_dark', TestViewport.compact, ThemeMode.dark),
      ]) {
    testWidgets('select options: $name', (WidgetTester tester) async {
      await pumpApp(tester, viewport: viewport, themeMode: themeMode);
      // The first press selects the tool, the second opens its options.
      // Nothing has been copied, so Paste is disabled.
      await tester.tap(find.byTooltip('Select'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Select'));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(GreatnoteApp),
        matchesGoldenFile('goldens/select_options_$name.png'),
      );
    });
  }

  for (final (
        String name,
        TestViewport viewport,
        ThemeMode themeMode,
        String side,
      )
      in <(String, TestViewport, ThemeMode, String)>[
        (
          'right_tablet_landscape_light',
          TestViewport.tabletLandscape,
          ThemeMode.light,
          'Right',
        ),
        (
          'left_tablet_landscape_dark',
          TestViewport.tabletLandscape,
          ThemeMode.dark,
          'Left',
        ),
        (
          'left_tablet_portrait_light',
          TestViewport.tabletPortrait,
          ThemeMode.light,
          'Left',
        ),
        ('sheet_compact_light', TestViewport.compact, ThemeMode.light, 'Right'),
        ('sheet_compact_dark', TestViewport.compact, ThemeMode.dark, 'Left'),
      ]) {
    // The assistant open on a selection, with an answered question and a
    // second one that failed.
    testWidgets('AI assistant: $name', (WidgetTester tester) async {
      final FakeAiClient client = FakeAiClient();
      final InkController controller = await pumpEditor(
        tester,
        viewport: viewport,
        themeMode: themeMode,
        strokes: _page(),
        aiClient: client,
      );
      await _select(tester, controller);
      await tester.tap(find.byTooltip('AI assistant'));
      await tester.pumpAndSettle();
      await settleAi(tester);
      tester
          .widget<AiAssistantPanel>(find.byType(AiAssistantPanel))
          .controller
          .setSide(side == 'Left' ? AiPanelSide.left : AiPanelSide.right);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Explain this'));
      await tester.pump();
      client.answer('Three waves and a dot.');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Grade this'));
      await tester.pump();
      client.fail(AiFailureKind.timeout);
      await tester.pumpAndSettle();
      await settleAi(tester);

      await expectLater(
        find.byType(GreatnoteApp),
        matchesGoldenFile('goldens/ai_assistant_$name.png'),
      );
    });
  }

  testWidgets('AI assistant, just opened: tablet_landscape_light', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(
      tester,
      strokes: _page(),
      aiClient: FakeAiClient(),
    );
    await _select(tester, controller);
    await tester.tap(find.byTooltip('AI assistant'));
    await tester.pumpAndSettle();
    await settleAi(tester);

    await expectLater(
      find.byType(GreatnoteApp),
      matchesGoldenFile(
        'goldens/ai_assistant_empty_tablet_landscape_light.png',
      ),
    );
  });

  for (final (String name, ThemeMode themeMode) in <(String, ThemeMode)>[
    ('tablet_landscape_light', ThemeMode.light),
    ('tablet_landscape_dark', ThemeMode.dark),
  ]) {
    // AI mode on from the palette, with nothing chosen yet, and a glowing
    // stroke being written on the page for the assistant.
    testWidgets('AI mode, writing: $name', (WidgetTester tester) async {
      await pumpEditor(
        tester,
        themeMode: themeMode,
        strokes: _page(),
        aiClient: FakeAiClient(),
      );
      await tester.tap(find.byTooltip('Turn on AI'));
      await tester.pumpAndSettle();
      final RenderBox canvas = tester.renderObject<RenderBox>(
        find.byType(InkCanvas).first,
      );
      final TestGesture gesture = await tester.createGesture(
        kind: PointerDeviceKind.stylus,
      );
      await gesture.down(
        canvas.localToGlobal(const Offset(120, 420)),
        timeStamp: Duration.zero,
      );
      for (int i = 1; i <= 40; i++) {
        await gesture.moveTo(
          canvas.localToGlobal(Offset(120 + i * 6, 420 + 24 * math.sin(i / 5))),
          timeStamp: Duration(milliseconds: 8 * i),
        );
      }
      await tester.pump();

      await expectLater(
        find.byType(GreatnoteApp),
        matchesGoldenFile('goldens/ai_mode_writing_$name.png'),
      );
      await gesture.cancel();
      await tester.pump();
    });
  }

  testWidgets('editor settings: tablet_landscape_light', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(
      tester,
      strokes: _page(),
      aiClient: FakeAiClient(),
    );
    await _select(tester, controller);
    await tester.tap(find.byTooltip('AI assistant'));
    await tester.pumpAndSettle();
    await settleAi(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(GreatnoteApp),
      matchesGoldenFile('goldens/editor_settings_tablet_landscape_light.png'),
    );
  });

  testWidgets('AI options: tablet_landscape_light', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(
      tester,
      strokes: _page(),
      aiClient: FakeAiClient(),
    );
    await _select(tester, controller);
    await tester.tap(find.byTooltip('AI assistant'));
    await tester.pumpAndSettle();
    await settleAi(tester);
    await tester.tap(find.byTooltip('AI settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enable notation'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(GreatnoteApp),
      matchesGoldenFile('goldens/ai_options_tablet_landscape_light.png'),
    );
  });
}
