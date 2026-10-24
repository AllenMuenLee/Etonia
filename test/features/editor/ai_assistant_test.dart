import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_icons.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/features/editor/ai/ai_assistant_controller.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/ai_config.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/handwriting/handwriting_calibration.dart';
import 'package:greatnote/features/editor/handwriting/handwriting_style.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/ink_selection.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/widgets/ai_context_glow.dart';
import 'package:greatnote/features/editor/widgets/ai_assistant_panel.dart';
import 'package:greatnote/features/editor/widgets/ai_options.dart';
import 'package:greatnote/features/editor/widgets/editor_settings_sheet.dart';
import 'package:greatnote/features/editor/widgets/tool_palette.dart';
import 'package:greatnote/features/editor/widgets/writing_surface_frame.dart';
import 'package:greatnote/shared/widgets/etonia_mark.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../helpers/ai_fakes.dart';
import '../../helpers/editor_harness.dart';
import '../../helpers/pump_app.dart';

const Rect _pair = Rect.fromLTRB(100, 170, 240, 270);
const Rect _third = Rect.fromLTRB(100, 470, 240, 530);

Stroke _line(double y) {
  return Stroke.fromPoints(
    style: const StrokeStyle(ink: InkPalette.ink, width: 4),
    points: <InkVector>[
      for (double x = 120; x <= 220; x += 20) InkVector(x, y),
    ],
  );
}

/// Two lines close together and a third well below them. It fits every
/// reference viewport.
List<Stroke> _page() => <Stroke>[_line(200), _line(240), _line(500)];

/// Picks the Select tool and selects the ink in [box].
Future<InkSelection> _select(
  WidgetTester tester,
  InkController controller, [
  Rect box = _pair,
]) async {
  if (_tool(tester) != EditorTool.select) {
    await tester.tap(find.byTooltip('Select'));
    await tester.pumpAndSettle();
  }
  final InkSelection selection = selectInk(controller, box);
  await tester.pumpAndSettle();
  return selection;
}

/// Presses AI and waits for the selection image.
Future<void> _openAi(WidgetTester tester) async {
  await tester.tap(find.byTooltip('AI assistant'));
  await tester.pumpAndSettle();
  await settleAi(tester);
}

/// The editor with [_page] on it, the first two lines selected, and the
/// assistant open.
Future<(InkController, FakeAiClient)> _pumpOpen(
  WidgetTester tester, {
  TestViewport viewport = TestViewport.tabletLandscape,
  ThemeMode themeMode = ThemeMode.light,
  HandwritingProfileStore? handwritingProfileStore,
}) async {
  final FakeAiClient client = FakeAiClient();
  final InkController controller = await pumpEditor(
    tester,
    viewport: viewport,
    themeMode: themeMode,
    strokes: _page(),
    aiClient: client,
    handwritingProfileStore: handwritingProfileStore,
  );
  await _select(tester, controller);
  await _openAi(tester);
  return (controller, client);
}

EditorTool _tool(WidgetTester tester) {
  return tester.widget<ToolPalette>(find.byType(ToolPalette)).tool.value;
}

AiAssistantController _assistant(WidgetTester tester) {
  return tester
      .widget<AiAssistantPanel>(find.byType(AiAssistantPanel))
      .controller;
}

Rect _panelRect(WidgetTester tester) {
  return tester.getRect(find.byType(AiAssistantPanel));
}

Rect _surfaceRect(WidgetTester tester) {
  return tester.getRect(find.byType(WritingSurfaceFrame));
}

Rect _paletteRect(WidgetTester tester) {
  return tester.getRect(find.byType(ToolPalette));
}

Finder _sendButton() => find.widgetWithIcon(IconButton, AppIcons.send);

/// Whether the editor under a sheet is hidden from the keyboard and from
/// screen readers.
bool _editorExcluded(WidgetTester tester) {
  final Finder scaffold = find.byType(Scaffold);
  return tester
          .widget<ExcludeSemantics>(
            find
                .ancestor(of: scaffold, matching: find.byType(ExcludeSemantics))
                .first,
          )
          .excluding &&
      tester
          .widget<ExcludeFocus>(
            find
                .ancestor(of: scaffold, matching: find.byType(ExcludeFocus))
                .first,
          )
          .excluding;
}

Finder _quickAction(String label) {
  return find.widgetWithText(OutlinedButton, label);
}

/// Whether keyboard focus is on, or inside, the widget found by [finder].
bool _hasFocus(WidgetTester tester, Finder finder) {
  final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null || finder.evaluate().isEmpty) {
    return false;
  }
  final Element target = tester.element(finder.first);
  bool found = focused == target;
  focused.visitAncestorElements((Element ancestor) {
    found = found || ancestor == target;
    return !found;
  });
  return found;
}

Future<void> _chord(
  WidgetTester tester,
  LogicalKeyboardKey modifier,
  LogicalKeyboardKey key,
) async {
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(modifier);
  await tester.pump();
}

void main() {
  group('the AI action', () {
    testWidgets('follows Copy and Cut, with a visible AI label', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final InkController controller = await pumpEditor(
        tester,
        strokes: _page(),
      );
      expect(find.byTooltip('AI assistant'), findsNothing);

      await _select(tester, controller);

      final Rect copy = tester.getRect(find.byTooltip('Copy'));
      final Rect cut = tester.getRect(find.byTooltip('Cut'));
      final Rect ai = tester.getRect(find.byTooltip('AI assistant'));
      expect(copy.right, lessThanOrEqualTo(cut.left));
      expect(cut.right, lessThanOrEqualTo(ai.left));
      expect(copy.top, ai.top);
      expect(ai.width, greaterThanOrEqualTo(AppSizes.minTouchTarget));
      expect(ai.height, greaterThanOrEqualTo(AppSizes.minTouchTarget));
      // The words, not an icon.
      expect(
        find.descendant(
          of: find.byTooltip('AI assistant'),
          matching: find.text('AI'),
        ),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('AI assistant')),
        isSemantics(
          label: 'AI assistant',
          isButton: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      // Nearest the frame's top-right corner: the frame's right edge is at
      // 222, and its handles reach 6 further. The palette floats across
      // the top, clear of it.
      final Rect palette = _paletteRect(tester);
      final Rect bar = Rect.fromLTRB(
        tester.getRect(find.byTooltip('Copy')).left - AppSpacing.xxs,
        ai.top,
        ai.right + AppSpacing.xxs,
        ai.bottom,
      );
      expect(
        bar.right,
        closeTo(pageToGlobal(tester, const Offset(222 + 6, 0)).dx, 1e-6),
      );
      expect(bar.overlaps(palette), isFalse);
      expect(
        ai.bottom,
        lessThan(pageToGlobal(tester, const Offset(0, 198)).dy),
      );
      handle.dispose();
    });

    testWidgets('is hidden while the selection is being reshaped', (
      WidgetTester tester,
    ) async {
      final InkController controller = await pumpEditor(
        tester,
        strokes: _page(),
      );
      await _select(tester, controller);

      controller.beginSelectionGesture(
        pointer: 3,
        position: const InkVector(170, 220),
      );
      await tester.pump();
      expect(find.byTooltip('AI assistant'), findsNothing);

      controller.endSelectionGesture(3, const InkVector(190, 230));
      await tester.pump();
      expect(find.byTooltip('AI assistant'), findsOneWidget);

      controller.beginLasso(pointer: 4, position: const InkVector(400, 400));
      await tester.pump();
      expect(find.byTooltip('AI assistant'), findsNothing);
      controller.cancelLasso(4);
      await tester.pump();
      expect(find.byTooltip('AI assistant'), findsOneWidget);

      controller.clearSelection();
      await tester.pump();
      expect(find.byTooltip('AI assistant'), findsNothing);
    });

    testWidgets('is the trailing action in right-to-left layouts too', (
      WidgetTester tester,
    ) async {
      setViewportSize(tester, TestViewport.tabletLandscape.size);
      final InkController controller = InkController(strokes: _page());
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          builder: (BuildContext context, Widget? child) {
            return Directionality(
              textDirection: TextDirection.rtl,
              child: child!,
            );
          },
          home: EditorScreen(
            inkController: controller,
            aiClient: FakeAiClient(),
            initialNotationEnabled: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _select(tester, controller);

      final Rect copy = tester.getRect(find.byTooltip('Copy'));
      final Rect cut = tester.getRect(find.byTooltip('Cut'));
      final Rect ai = tester.getRect(find.byTooltip('AI assistant'));
      expect(ai.right, lessThanOrEqualTo(cut.left));
      expect(cut.right, lessThanOrEqualTo(copy.left));
      // At the frame's top-left corner, which is the trailing one here.
      expect(
        ai.left,
        closeTo(
          pageToGlobal(tester, const Offset(118 - 6, 0)).dx + AppSpacing.xxs,
          1e-6,
        ),
      );

      // The setting's Left and Right still mean the screen's physical edges.
      await _openAi(tester);
      expect(_panelRect(tester).left, 0);
      _assistant(tester).setSide(AiPanelSide.right);
      await tester.pumpAndSettle();
      expect(_panelRect(tester).right, TestViewport.tabletLandscape.size.width);
      _assistant(tester).setSide(AiPanelSide.left);
      await tester.pumpAndSettle();
      expect(_panelRect(tester).left, 0);
      // The palette lies across the top of what the panel leaves, clear of
      // the card in the corner.
      final Rect card = tester.getRect(
        find.byKey(const ValueKey<String>('history-card')),
      );
      expect(card.left, _surfaceRect(tester).left);
      expect(_paletteRect(tester).left, greaterThanOrEqualTo(card.right));
      expect(
        _paletteRect(tester).right,
        lessThanOrEqualTo(_surfaceRect(tester).right),
      );
      expect(_surfaceRect(tester).left, _panelRect(tester).right);
      expect(
        _surfaceRect(tester).right,
        TestViewport.tabletLandscape.size.width,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('opens the panel and changes nothing else', (
      WidgetTester tester,
    ) async {
      final FakeAiClient client = FakeAiClient();
      final InkController controller = await pumpEditor(
        tester,
        strokes: _page(),
        aiClient: client,
      );
      final InkSelection selection = await _select(tester, controller);
      final List<Stroke> before = List<Stroke>.of(controller.strokes);
      int inkChanges = 0;
      int selectionChanges = 0;
      controller.completedStrokesListenable.addListener(() => inkChanges++);
      controller.selectionListenable.addListener(() => selectionChanges++);

      // A pointer held on the button, then dragged, starts nothing on the
      // canvas underneath.
      final TestGesture press = await tester.startGesture(
        tester.getCenter(find.byTooltip('AI assistant')),
      );
      await press.moveBy(const Offset(4, 30));
      expect(controller.activePointer, isNull);
      expect(controller.activeLasso, isNull);
      expect(controller.activeTransform, isNull);
      await press.cancel();
      await tester.pumpAndSettle();
      expect(find.byType(AiAssistantPanel), findsNothing);

      await _openAi(tester);

      expect(find.byType(AiAssistantPanel), findsOneWidget);
      expect(find.text('AI assistant'), findsOneWidget);
      expect(find.text('Fake model'), findsOneWidget);
      expect(find.text(AiAssistantPanel.emptyState), findsOneWidget);
      expect(find.text('Enable notation'), findsNothing);
      expect(find.text('Enable animation'), findsNothing);
      expect(find.text('Panel side'), findsNothing);
      // Nothing was sent, and nothing in the editor moved.
      expect(client.requests, isEmpty);
      // The palette's AI mode comes on with it.
      expect(_tool(tester), EditorTool.ai);
      expect(controller.strokes, before);
      expect(controller.selection, same(selection));
      expect(controller.canPaste, isFalse);
      expect(controller.activePointer, isNull);
      expect(inkChanges, 0);
      expect(selectionChanges, 0);
      // What the chat is about is framed on the page, not pictured in it.
      final AiSelectionContext context = _assistant(tester).context!;
      expect(context.snapshot.isOf(selection), isTrue);
      expect(find.byType(AiContextGlow), findsWidgets);
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('layout', () {
    testWidgets(
      'an unsaved handwriting calibration is offered above the composer',
      (WidgetTester tester) async {
        final InMemoryHandwritingProfileStore store =
            InMemoryHandwritingProfileStore();
        await _pumpOpen(tester, handwritingProfileStore: store);

        final Finder notice = find.byKey(
          const ValueKey<String>('handwriting-calibration-notice'),
        );
        expect(notice, findsOneWidget);
        expect(
          find.text(AiAssistantPanel.handwritingCalibrationNotice),
          findsOneWidget,
        );
        expect(
          tester.getRect(notice).bottom,
          lessThanOrEqualTo(tester.getRect(find.byType(TextField)).top),
        );
        expect(find.widgetWithText(TextButton, 'Choose'), findsOneWidget);
        expect(
          find.widgetWithText(TextButton, "Don't show again"),
          findsOneWidget,
        );

        await tester.tap(find.widgetWithText(TextButton, "Don't show again"));
        await tester.pumpAndSettle();

        expect(notice, findsNothing);
        expect(store.state?.style, isNull);
        expect(store.state?.skipped, isFalse);
        expect(store.state?.chatReminderDismissed, isTrue);

        await tester.pumpWidget(const SizedBox.shrink());
        await _pumpOpen(tester, handwritingProfileStore: store);
        expect(notice, findsNothing);
      },
    );

    testWidgets('skipping calibration still leaves the little reminder', (
      WidgetTester tester,
    ) async {
      await _pumpOpen(
        tester,
        handwritingProfileStore: InMemoryHandwritingProfileStore(
          const HandwritingCalibrationState(skipped: true),
        ),
      );

      expect(
        find.byKey(const ValueKey<String>('handwriting-calibration-notice')),
        findsOneWidget,
      );
    });

    testWidgets('a saved handwriting calibration needs no reminder', (
      WidgetTester tester,
    ) async {
      final InMemoryHandwritingProfileStore store =
          InMemoryHandwritingProfileStore(
            const HandwritingCalibrationState(style: HandwritingStyle.standard),
          );
      await _pumpOpen(tester, handwritingProfileStore: store);

      expect(
        find.byKey(const ValueKey<String>('handwriting-calibration-notice')),
        findsNothing,
      );
    });

    testWidgets('the chat reminder opens handwriting calibration', (
      WidgetTester tester,
    ) async {
      await _pumpOpen(
        tester,
        handwritingProfileStore: InMemoryHandwritingProfileStore(),
      );

      await tester.tap(find.widgetWithText(TextButton, 'Choose'));
      await tester.pumpAndSettle();

      expect(find.text("Choose the AI's handwriting"), findsOneWidget);
    });

    testWidgets('the AI tool holds notation and animation; editor settings '
        'hold the panel side', (WidgetTester tester) async {
      await _pumpOpen(tester);
      final AiAssistantController assistant = _assistant(tester);

      await tester.tap(find.byTooltip('AI settings'));
      await tester.pumpAndSettle();
      expect(find.byType(AiOptions), findsOneWidget);
      // The harness opens the editor with Notation off.
      expect(assistant.notationEnabled, isFalse);
      // On at every launch.
      expect(assistant.animationEnabled, isTrue);

      await tester.tap(find.text('Enable notation'));
      await tester.tap(find.text('Enable animation'));
      await tester.pump();
      expect(assistant.notationEnabled, isTrue);
      expect(assistant.animationEnabled, isFalse);
      await tester.tap(find.byTooltip('AI settings'));
      await tester.pumpAndSettle();
      expect(find.byType(AiOptions), findsNothing);

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.byType(EditorSettingsSheet), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Panel side'), findsOneWidget);
      expect(find.text('Enable notation'), findsNothing);
      expect(find.text('Enable animation'), findsNothing);

      await tester.tap(find.text('Left'));
      await tester.pumpAndSettle();
      expect(assistant.side, AiPanelSide.left);

      Navigator.of(tester.element(find.byType(EditorSettingsSheet))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(EditorSettingsSheet), findsNothing);
      expect(find.text('Panel side'), findsNothing);
    });

    for (final TestViewport viewport in <TestViewport>[
      TestViewport.tabletLandscape,
      TestViewport.tabletPortrait,
    ]) {
      testWidgets('${viewport.name}: the panel sits beside the editor', (
        WidgetTester tester,
      ) async {
        await pumpEditor(tester, viewport: viewport);
        final Rect surfaceBefore = _surfaceRect(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        await _pumpOpen(tester, viewport: viewport);
        final Size screen = viewport.size;

        // On the left to begin with, 360 wide, below the app bar.
        Rect panel = _panelRect(tester);
        expect(panel.width, 360);
        expect(panel.left, 0);
        expect(panel.top, surfaceBefore.top);
        expect(panel.bottom, screen.height);
        expect(_assistant(tester).side, AiPanelSide.left);
        // The page fills what the panel leaves, edge to edge.
        expect(_surfaceRect(tester).left, panel.right);
        expect(_surfaceRect(tester).right, surfaceBefore.right);
        expect(_paletteRect(tester).left, greaterThan(panel.right));
        expect(
          _surfaceRect(tester).intersect(_paletteRect(tester)),
          _paletteRect(tester),
        );
        expect(_paletteRect(tester).size, ToolPalette.sizeFor(Axis.horizontal));

        _assistant(tester).setSide(AiPanelSide.right);
        await tester.pump();
        // Mid-move frames are clean too.
        await tester.pump(const Duration(milliseconds: 60));
        expect(tester.takeException(), isNull);
        await tester.pumpAndSettle();

        panel = _panelRect(tester);
        expect(panel.right, screen.width);
        expect(panel.width, 360);
        expect(_surfaceRect(tester).right, panel.left);
        expect(_surfaceRect(tester).left, surfaceBefore.left);
        expect(_paletteRect(tester).overlaps(panel), isFalse);

        _assistant(tester).setSide(AiPanelSide.left);
        await tester.pumpAndSettle();

        expect(_panelRect(tester).left, 0);
        expect(_surfaceRect(tester).left, _panelRect(tester).right);

        // Closed, the editor has the whole width back.
        await tester.tap(find.byTooltip('Close AI assistant'));
        await tester.pumpAndSettle();
        expect(find.byType(AiAssistantPanel), findsNothing);
        expect(_surfaceRect(tester), surfaceBefore);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a side change animates, unless motion is reduced', (
      WidgetTester tester,
    ) async {
      AnimatedPositioned panel() {
        return tester.widget<AnimatedPositioned>(
          find.byKey(const ValueKey<String>('ai-panel-beside')),
        );
      }

      await _pumpOpen(tester);
      expect(panel().duration, AppMotion.snappy.duration);
      expect(panel().curve, AppMotion.fadeInCurve);
      _assistant(tester).setSide(AiPanelSide.left);
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpAndSettle();

      await tester.pumpWidget(const SizedBox.shrink());
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await _pumpOpen(tester);

      expect(panel().duration, AppMotion.reduced);
      _assistant(tester).setSide(AiPanelSide.left);
      await tester.pump();
      expect(_panelRect(tester).left, 0);
    });

    testWidgets('dragging its edge resizes only the panel until let go', (
      WidgetTester tester,
    ) async {
      await _pumpOpen(tester);
      _assistant(tester).setSide(AiPanelSide.right);
      await tester.pumpAndSettle();
      final Rect surfaceBefore = _surfaceRect(tester);
      final Rect panelBefore = _panelRect(tester);
      expect(panelBefore.width, 360);
      final Finder handle = find.byWidgetPredicate(
        (Widget widget) =>
            widget is MouseRegion &&
            widget.cursor == SystemMouseCursors.resizeColumn,
      );

      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(handle),
      );
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-60, 0));
      await tester.pump();

      // The panel follows the finger; the page keeps its layout meanwhile.
      expect(_panelRect(tester).left, lessThan(panelBefore.left));
      expect(_panelRect(tester).right, panelBefore.right);
      expect(_surfaceRect(tester), surfaceBefore);

      await gesture.moveBy(const Offset(200, 0));
      await tester.pump();
      // Narrower than it began, the uncovered strip is still desk.
      expect(_panelRect(tester).width, lessThan(panelBefore.width));
      expect(_surfaceRect(tester), surfaceBefore);

      await gesture.moveBy(const Offset(-100, 0));
      await tester.pump();
      final double dragged = _panelRect(tester).width;
      await gesture.up();
      await tester.pumpAndSettle();

      expect(_panelRect(tester).width, dragged);
      expect(_surfaceRect(tester).right, _panelRect(tester).left);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'compact: a side sheet over the editor, closed by its barrier',
      (WidgetTester tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        final FakeAiClient client = FakeAiClient();
        final InkController controller = await pumpEditor(
          tester,
          viewport: TestViewport.compact,
          strokes: _page(),
          aiClient: client,
        );
        await _select(tester, controller);
        final Rect surfaceBefore = _surfaceRect(tester);
        final Rect paletteBefore = _paletteRect(tester);
        await _openAi(tester);
        final Size screen = TestViewport.compact.size;
        // Opens on the left; Right is chosen to begin with here.
        expect(_panelRect(tester).left, 0);
        _assistant(tester).setSide(AiPanelSide.right);
        await tester.pumpAndSettle();

        // 88% of 390, from the right edge, over an untouched editor.
        Rect panel = _panelRect(tester);
        expect(panel.width, closeTo(390 * 0.88, 1e-9));
        expect(panel.right, screen.width);
        expect(panel.top, 0);
        expect(panel.bottom, screen.height);
        expect(_surfaceRect(tester), surfaceBefore);
        expect(_paletteRect(tester), paletteBefore);
        expect(
          tester.getSemantics(find.bySemanticsLabel('Dismiss AI assistant')),
          isSemantics(
            label: 'Dismiss AI assistant',
            isButton: true,
            hasTapAction: true,
          ),
        );
        // The editor underneath is out of reach while the sheet is up.
        expect(_editorExcluded(tester), isTrue);
        await tester.tapAt(const Offset(20, 20));
        await tester.pumpAndSettle();
        expect(find.byType(AiAssistantPanel), findsNothing);
        expect(_hasFocus(tester, find.byType(EditorScreen)), isTrue);
        expect(_editorExcluded(tester), isFalse);
        // Closing the chat turns AI mode off, giving back the tool before.
        expect(_tool(tester), EditorTool.select);
        expect(controller.selection, isNotNull);
        expect(controller.strokes, hasLength(3));

        // From the left edge when Left is chosen.
        await _openAi(tester);
        _assistant(tester).setSide(AiPanelSide.left);
        await tester.pumpAndSettle();
        panel = _panelRect(tester);
        expect(panel.left, 0);
        expect(panel.width, closeTo(390 * 0.88, 1e-9));
        expect(_surfaceRect(tester), surfaceBefore);
        await tester.tapAt(Offset(screen.width - 10, 400));
        await tester.pumpAndSettle();
        expect(find.byType(AiAssistantPanel), findsNothing);

        // A press on the sheet itself does not close it, or reach the page.
        await _openAi(tester);
        await tester.tapAt(_panelRect(tester).center);
        await tester.pumpAndSettle();
        expect(find.byType(AiAssistantPanel), findsOneWidget);
        expect(controller.activePointer, isNull);
        expect(client.requests, isEmpty);
        expect(tester.takeException(), isNull);
        handle.dispose();
      },
    );

    testWidgets('never wider than the screen allows', (
      WidgetTester tester,
    ) async {
      const AiLayoutConfig config = AiLayoutConfig();
      expect(config.sheetWidth(390), closeTo(343.2, 1e-9));
      expect(config.sheetWidth(599), 360);
      expect(config.sheetWidth(320), closeTo(281.6, 1e-9));
      expect(config.inlineWidth(1194), 360);
      expect(config.inlineWidth(640), 360);
      expect(config.inlineWidth(600), 320);
      expect(config.inlineWidth(500), 220);
      expect(config.inlineWidth(100), 0);
      // A width the user dragged to is kept within bounds.
      expect(config.inlineWidth(1194, preferred: 500), 500);
      expect(config.inlineWidth(1194, preferred: 100), 280);
      expect(config.inlineWidth(1194, preferred: 2000), 720);
      expect(config.inlineWidth(900, preferred: 700), 620);

      // Small and short windows, with the panel open, do not overflow.
      await _pumpOpen(tester, viewport: TestViewport.compact);
      for (final Size size in const <Size>[
        Size(320, 480),
        Size(844, 390),
        Size(600, 400),
        Size(280, 420),
      ]) {
        setViewportSize(tester, size);
        await tester.pumpAndSettle();
        expect(find.byType(AiAssistantPanel), findsOneWidget, reason: '$size');
        expect(tester.takeException(), isNull, reason: '$size');
      }
    });
  });

  group('conversation', () {
    testWidgets(
      'Explain this sends the prompt and the image, then follows up',
      (WidgetTester tester) async {
        final (InkController controller, FakeAiClient client) = await _pumpOpen(
          tester,
        );
        final List<Stroke> before = List<Stroke>.of(controller.strokes);
        final AiAssistantController assistant = _assistant(tester);
        expect(find.text('Explain this'), findsOneWidget);
        expect(find.text('Grade this'), findsOneWidget);
        expect(find.byType(EtoniaBarsLoader), findsNothing);

        await tester.tap(_quickAction('Explain this'));
        await tester.pump();

        final AiRequest first = client.requests.single;
        expect(first.messages.single.text, AiPrompts.explain);
        expect(
          first.systemInstruction,
          AiPrompts.systemFor(notationEnabled: false),
        );
        expect(first.imagePng, same(assistant.context!.image!.png));
        expect(first.imagePng.sublist(0, 4), <int>[0x89, 0x50, 0x4E, 0x47]);
        // In the transcript as the user's message, with the answer's place
        // held, and nothing more can be sent meanwhile.
        expect(find.text('Explain this'), findsNWidgets(2));
        expect(find.text('You'), findsOneWidget);
        expect(find.byType(EtoniaBarsLoader), findsOneWidget);
        expect(find.text(AiAssistantPanel.emptyState), findsNothing);
        for (final String label in <String>['Explain this', 'Grade this']) {
          expect(
            tester.widget<OutlinedButton>(_quickAction(label)).onPressed,
            isNull,
          );
        }
        await tester.tap(_quickAction('Grade this'));
        await tester.pump();
        expect(client.requests, hasLength(1));

        client.answer('It shows two parallel lines.');
        await tester.pumpAndSettle();

        expect(find.byType(EtoniaBarsLoader), findsNothing);
        expect(find.text('Assistant'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(GptMarkdown),
            matching: find.text('It shows two parallel lines.'),
          ),
          findsOneWidget,
        );
        // The quick actions are still offered.
        expect(
          tester.widget<OutlinedButton>(_quickAction('Grade this')).onPressed,
          isNotNull,
        );

        // A typed follow-up, trimmed, in the same conversation.
        await tester.enterText(find.byType(TextField), '  Why parallel?  ');
        await tester.pump();
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();

        expect(
          <String>[
            for (final AiMessage message in client.requests[1].messages)
              '${message.role.name}: ${message.text}',
          ],
          <String>[
            'user: ${AiPrompts.explain}',
            'model: It shows two parallel lines.',
            'user: Why parallel?',
          ],
        );
        expect(client.requests[1].imagePng, same(first.imagePng));
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '',
        );
        expect(find.text('Why parallel?'), findsOneWidget);
        client.answer('They never meet.');
        await tester.pumpAndSettle();
        expect(find.text('They never meet.'), findsOneWidget);
        expect(find.text('Assistant'), findsNWidgets(2));

        // None of it touched the ink.
        expect(controller.strokes, before);
        expect(controller.selection!.indices, <int>[0, 1]);
        expect(controller.canPaste, isFalse);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('an answer has its Markdown and formulas rendered', (
      WidgetTester tester,
    ) async {
      final (_, FakeAiClient client) = await _pumpOpen(tester);
      await tester.tap(_quickAction('Explain this'));
      await tester.pump();

      client.answer(
        '## Result\n\n'
        'The slope is **two**, so \$y = 2x + 1\$.\n\n'
        '- first point\n'
        '- second point\n\n'
        '![a picture](https://example.com/picture.png)',
      );
      await tester.pumpAndSettle();

      final Finder answer = find.byType(GptMarkdown);
      Finder inAnswer(Pattern text) {
        return find.descendant(
          of: answer,
          matching: find.textContaining(text, findRichText: true),
        );
      }

      // The words are there; the markup is not.
      expect(inAnswer('Result'), findsWidgets);
      expect(inAnswer('two'), findsWidgets);
      expect(inAnswer('first point'), findsWidgets);
      expect(inAnswer('##'), findsNothing);
      expect(inAnswer('**'), findsNothing);
      expect(inAnswer('- first'), findsNothing);
      // The formula is typeset, not shown as source.
      expect(inAnswer(r'$'), findsNothing);
      expect(
        find.descendant(
          of: answer,
          matching: find.byWidgetPredicate(
            (Widget widget) => widget.runtimeType.toString() == 'Math',
          ),
        ),
        findsOneWidget,
      );
      // A linked image is never fetched.
      expect(inAnswer('[image]'), findsOneWidget);
      expect(
        find.descendant(of: answer, matching: find.byType(Image)),
        findsNothing,
      );
      // It can be selected, and the user's own words are left as typed.
      expect(
        find.ancestor(of: answer, matching: find.byType(SelectionArea)),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), 'Is **this** bold?');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      expect(find.text('Is **this** bold?'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the answer is shown live, then kept once', (
      WidgetTester tester,
    ) async {
      final (InkController controller, FakeAiClient client) = await _pumpOpen(
        tester,
      );
      final int strokes = controller.strokes.length;
      _assistant(tester).setNotationEnabled(true);
      await tester.pump();
      await tester.tap(_quickAction('Explain this'));
      await tester.pump();
      // The note image is drawn before the request goes out.
      await settleAi(tester);
      expect(client.requests.single.notationEnabled, isTrue);
      final Finder live = find.byKey(
        const ValueKey<String>('ai-partial-answer'),
      );
      expect(live, findsNothing);

      client.stream('Two **parallel**');
      // One frame to show it, one for the transcript to follow it.
      await tester.pump();
      await tester.pump();

      expect(live, findsOneWidget);
      expect(
        find.descendant(
          of: live,
          matching: find.textContaining('parallel', findRichText: true),
        ),
        findsWidgets,
      );
      expect(find.byType(EtoniaBarsLoader), findsOneWidget);
      expect(find.textContaining('Drawing'), findsNothing);

      // The words are all in; the drawing is still coming.
      client.stream('Two **parallel** lines.', isComplete: true);
      await tester.pump();
      expect(find.textContaining('Drawing'), findsNothing);
      expect(controller.strokes, hasLength(strokes));

      client.answer('Two **parallel** lines.');
      await tester.pumpAndSettle();

      expect(live, findsNothing);
      expect(find.textContaining('Drawing'), findsNothing);
      expect(find.byType(EtoniaBarsLoader), findsNothing);
      expect(find.text('Assistant'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty message cannot be sent', (WidgetTester tester) async {
      final (_, FakeAiClient client) = await _pumpOpen(tester);

      expect(tester.widget<IconButton>(_sendButton()).onPressed, isNull);
      await tester.enterText(find.byType(TextField), '   \n ');
      await tester.pump();
      expect(tester.widget<IconButton>(_sendButton()).onPressed, isNull);
      await tester.tap(find.byTooltip('Send'));
      await _chord(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.enter,
      );

      expect(client.requests, isEmpty);
      expect(find.text('You'), findsNothing);
    });

    testWidgets('Ctrl or Cmd with Enter sends from the keyboard', (
      WidgetTester tester,
    ) async {
      final (_, FakeAiClient client) = await _pumpOpen(tester);

      for (final (LogicalKeyboardKey modifier, String text)
          in <(LogicalKeyboardKey, String)>[
            (LogicalKeyboardKey.controlLeft, 'With control'),
            (LogicalKeyboardKey.metaLeft, 'With command'),
          ]) {
        await tester.enterText(find.byType(TextField), text);
        await tester.pump();
        await _chord(tester, modifier, LogicalKeyboardKey.enter);

        expect(client.requests.last.messages.last.text, text);
        // Focus stays in the field for the next message.
        expect(_hasFocus(tester, find.byType(TextField)), isTrue);
        client.answer('Reply');
        await tester.pumpAndSettle();
      }
      expect(client.requests, hasLength(2));
    });

    testWidgets('a failure is shown in place, and Retry sends once more', (
      WidgetTester tester,
    ) async {
      final (InkController controller, FakeAiClient client) = await _pumpOpen(
        tester,
      );
      final List<Stroke> before = List<Stroke>.of(controller.strokes);
      await tester.tap(_quickAction('Grade this'));
      await tester.pump();
      client.answer('Looks right.');
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Are you sure?');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();

      client.fail(AiFailureKind.timeout);
      await tester.pumpAndSettle();

      expect(
        find.text('The AI service took too long to respond.'),
        findsOneWidget,
      );
      expect(find.byType(EtoniaBarsLoader), findsNothing);
      // What was already said is still there, and so is the ink.
      expect(find.text('Looks right.'), findsOneWidget);
      expect(find.text('Are you sure?'), findsOneWidget);
      expect(controller.strokes, before);
      expect(controller.selection!.indices, <int>[0, 1]);
      expect(_tool(tester), EditorTool.ai);
      // Nothing was retried on its own.
      expect(client.requests, hasLength(2));

      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pump();

      expect(client.requests, hasLength(3));
      expect(client.requests[2].messages, hasLength(3));
      expect(
        find.text('The AI service took too long to respond.'),
        findsNothing,
      );
      expect(find.byType(EtoniaBarsLoader), findsOneWidget);
      expect(find.text('Are you sure?'), findsOneWidget);
      client.answer('Yes.');
      await tester.pumpAndSettle();

      expect(find.text('Yes.'), findsOneWidget);
      expect(find.text('You'), findsNWidgets(2));
      expect(find.text('Assistant'), findsNWidgets(2));
      expect(find.widgetWithText(TextButton, 'Retry'), findsNothing);
    });

    for (final AiFailureKind kind in AiFailureKind.values) {
      testWidgets('${kind.name} gets a message of its own and a Retry', (
        WidgetTester tester,
      ) async {
        final (_, FakeAiClient client) = await _pumpOpen(tester);
        await tester.tap(_quickAction('Explain this'));
        await tester.pump();

        client.fail(kind);
        await tester.pumpAndSettle();

        expect(find.text(AiFailure(kind).message), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
        expect(find.text('Explain this'), findsNWidgets(2));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('without a key the panel explains, and cannot send', (
      WidgetTester tester,
    ) async {
      final InkController controller = await pumpEditor(
        tester,
        strokes: _page(),
      );
      await _select(tester, controller);
      await _openAi(tester);

      expect(find.text(AiAssistantPanel.notConfigured), findsOneWidget);
      expect(AiAssistantPanel.notConfigured, contains('GEMINI_API_KEY'));
      expect(AiAssistantPanel.notConfigured, contains('Claude_API_KEY'));
      expect(AiAssistantPanel.notConfigured, contains('Openai_API_KEY'));
      // The editor's own client serves every model, starting on Sol.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('ai-model-selector')),
          matching: find.text('Sol'),
        ),
        findsOneWidget,
      );
      for (final String label in <String>['Explain this', 'Grade this']) {
        expect(
          tester.widget<OutlinedButton>(_quickAction(label)).onPressed,
          isNull,
        );
      }
      await tester.enterText(find.byType(TextField), 'Hello');
      await tester.pump();
      expect(tester.widget<IconButton>(_sendButton()).onPressed, isNull);
      // The rest of the panel still works.
      expect(_assistant(tester).context!.image, isNotNull);
      _assistant(tester).setSide(AiPanelSide.left);
      await tester.pumpAndSettle();
      expect(_panelRect(tester).left, 0);
      expect(tester.takeException(), isNull);
    });
  });

  group('selection changes', () {
    testWidgets('are announced, and never swap the image by themselves', (
      WidgetTester tester,
    ) async {
      final (InkController controller, FakeAiClient client) = await _pumpOpen(
        tester,
      );
      final AiAssistantController assistant = _assistant(tester);
      final AiSelectionContext context = assistant.context!;
      await tester.tap(_quickAction('Explain this'));
      await tester.pump();
      expect(find.text('New selection'), findsNothing);

      // A lasso under way is not a new selection yet.
      controller.beginLasso(pointer: 5, position: const InkVector(100, 470));
      await tester.pump();
      expect(find.text('New selection'), findsNothing);
      controller.endLasso(5, const InkVector(240, 530));
      await tester.pump();

      expect(controller.selection!.indices, <int>[2]);
      expect(find.text('New selection'), findsOneWidget);
      expect(assistant.context, same(context));
      expect(find.byType(Image), findsNothing);
      expect(find.text('Explain this'), findsNWidgets(2));

      // The answer still belongs to the open conversation.
      client.answer('About the first two lines.');
      await tester.pumpAndSettle();
      expect(find.text('About the first two lines.'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'More');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();

      await tester.ensureVisible(find.widgetWithText(TextButton, 'New chat'));
      await tester.tap(find.widgetWithText(TextButton, 'New chat'));
      await tester.pump();
      await settleAi(tester);

      // A new conversation about the new ink; the old request is dropped.
      expect(find.text('New selection'), findsNothing);
      expect(assistant.context, isNot(same(context)));
      expect(assistant.context!.snapshot.isOf(controller.selection!), isTrue);
      expect(assistant.messages, isEmpty);
      expect(find.text(AiAssistantPanel.emptyState), findsOneWidget);
      expect(find.byType(EtoniaBarsLoader), findsNothing);
      client.answer('Late answer', index: 1);
      await tester.pumpAndSettle();
      expect(find.text('Late answer'), findsNothing);
      expect(client.requests, hasLength(2));

      await tester.tap(_quickAction('Grade this'));
      await tester.pump();
      expect(client.requests[2].messages.single.text, AiPrompts.grade);
      expect(client.requests[2].imagePng, isNot(client.requests[0].imagePng));
      expect(client.requests[2].imagePng, same(assistant.context!.image!.png));
    });

    testWidgets('Add to context keeps the conversation and widens its ink', (
      WidgetTester tester,
    ) async {
      final (InkController controller, FakeAiClient client) = await _pumpOpen(
        tester,
      );
      final AiAssistantController assistant = _assistant(tester);
      final AiSelectionContext context = assistant.context!;
      await tester.tap(_quickAction('Explain this'));
      await tester.pump();
      client.answer('Two lines.');
      await tester.pumpAndSettle();

      // In AI mode ink is picked by circling it, not with the Select tool,
      // which would turn AI mode off.
      selectInk(controller, _third);
      await tester.pumpAndSettle();
      expect(find.text('New selection'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Add to context'));
      await tester.pump();
      await settleAi(tester);

      expect(find.text('New selection'), findsNothing);
      expect(assistant.context, isNot(same(context)));
      expect(assistant.context!.snapshot.strokes, hasLength(3));
      expect(find.text('Two lines.'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'And the third?');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      expect(client.requests[1].messages, hasLength(3));
      expect(client.requests[1].imagePng, same(assistant.context!.image!.png));
      expect(tester.takeException(), isNull);
    });

    testWidgets('drawing, erasing, and clearing leave the conversation alone', (
      WidgetTester tester,
    ) async {
      final (InkController controller, FakeAiClient client) = await _pumpOpen(
        tester,
      );
      final AiAssistantController assistant = _assistant(tester);
      final AiSelectionContext context = assistant.context!;
      await tester.tap(_quickAction('Explain this'));
      await tester.pump();
      client.answer('Two lines.');
      await tester.pumpAndSettle();

      // Leaving Select clears the selection.
      await tester.tap(find.byTooltip('Pen'));
      await tester.pumpAndSettle();
      expect(controller.selection, isNull);
      await tester.dragFrom(
        pageToGlobal(tester, const Offset(300, 300)),
        const Offset(80, 40),
      );
      await tester.pumpAndSettle();
      expect(controller.strokes, hasLength(4));
      await tester.tap(find.byTooltip('Eraser'));
      await tester.pumpAndSettle();
      await tester.dragFrom(
        pageToGlobal(tester, const Offset(170, 180)),
        const Offset(0, 40),
      );
      await tester.pumpAndSettle();
      expect(controller.strokes.length, isNot(4));

      expect(find.byType(AiAssistantPanel), findsOneWidget);
      expect(find.text('New selection'), findsNothing);
      expect(assistant.context, same(context));
      expect(find.text('Two lines.'), findsOneWidget);
      // Follow-ups still go with the image captured at the start.
      await tester.enterText(find.byType(TextField), 'And?');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      expect(client.requests[1].imagePng, same(context.image!.png));
      expect(client.requests[1].messages, hasLength(3));
    });
  });

  group('session state', () {
    testWidgets(
      'closing and reopening keeps the conversation, sending nothing',
      (WidgetTester tester) async {
        final (InkController controller, FakeAiClient client) = await _pumpOpen(
          tester,
        );
        final AiSelectionContext context = _assistant(tester).context!;
        await tester.tap(_quickAction('Explain this'));
        await tester.pump();
        _assistant(tester).setSide(AiPanelSide.left);
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'unsent draft');
        await tester.pump();

        await tester.tap(find.byTooltip('Close AI assistant'));
        await tester.pump();
        expect(find.byType(AiAssistantPanel), findsNothing);
        // The answer comes in while the panel is closed.
        client.answer('Kept answer');
        await tester.pumpAndSettle();
        expect(controller.selection!.indices, <int>[0, 1]);

        await _openAi(tester);

        final AiAssistantController assistant = _assistant(tester);
        expect(assistant.context, same(context));
        expect(assistant.side, AiPanelSide.left);
        expect(_panelRect(tester).left, 0);
        expect(find.text('Kept answer'), findsOneWidget);
        expect(find.text('Explain this'), findsNWidgets(2));
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'unsent draft',
        );
        expect(client.requests, hasLength(1));
      },
    );

    testWidgets('survives rotation and every breakpoint', (
      WidgetTester tester,
    ) async {
      final (InkController controller, FakeAiClient client) = await _pumpOpen(
        tester,
        viewport: TestViewport.tabletPortrait,
      );
      final AiAssistantController assistant = _assistant(tester);
      final AiSelectionContext context = assistant.context!;
      await tester.tap(_quickAction('Explain this'));
      await tester.pump();
      client.answer('The answer');
      await tester.pumpAndSettle();
      _assistant(tester).setSide(AiPanelSide.left);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'draft in progress');
      await tester.pump();
      expect(_hasFocus(tester, find.byType(TextField)), isTrue);

      for (final Size size in const <Size>[
        Size(1280, 800),
        Size(390, 844),
        Size(844, 390),
        Size(800, 1280),
        Size(1194, 834),
      ]) {
        setViewportSize(tester, size);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        expect(tester.takeException(), isNull, reason: '$size');
        await tester.pumpAndSettle();

        expect(find.byType(AiAssistantPanel), findsOneWidget, reason: '$size');
        expect(_assistant(tester), same(assistant), reason: '$size');
        expect(assistant.isOpen, isTrue, reason: '$size');
        expect(assistant.side, AiPanelSide.left, reason: '$size');
        expect(_panelRect(tester).left, 0, reason: '$size');
        expect(assistant.context, same(context), reason: '$size');
        expect(assistant.messages, hasLength(2), reason: '$size');
        // The transcript builds only what is in view, and a short window
        // shows little of it.
        if (size.height >= 800) {
          expect(find.text('The answer'), findsOneWidget, reason: '$size');
          expect(find.text('Explain this'), findsNWidgets(2), reason: '$size');
        }
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'draft in progress',
          reason: '$size',
        );
        // The field is still the one being typed in.
        expect(
          _hasFocus(tester, find.byType(TextField)),
          isTrue,
          reason: '$size',
        );
        expect(controller.selection!.indices, <int>[0, 1], reason: '$size');
        if (size.width >= 600) {
          expect(_panelRect(tester).width, 360, reason: '$size');
          expect(
            _surfaceRect(tester).overlaps(_panelRect(tester)),
            isFalse,
            reason: '$size',
          );
          expect(
            _paletteRect(tester).overlaps(_panelRect(tester)),
            isFalse,
            reason: '$size',
          );
        }
        expect(tester.takeException(), isNull, reason: '$size');
      }
      expect(client.requests, hasLength(1));

      // And the conversation carries on afterwards.
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      expect(client.requests[1].messages.last.text, 'draft in progress');
      expect(client.requests[1].imagePng, same(context.image!.png));
    });

    testWidgets('changing side keeps the field focused and its text', (
      WidgetTester tester,
    ) async {
      await _pumpOpen(tester);
      await tester.enterText(find.byType(TextField), 'typing');
      await tester.pump();

      _assistant(tester).setSide(AiPanelSide.left);
      await tester.pumpAndSettle();
      _assistant(tester).setSide(AiPanelSide.right);
      await tester.pumpAndSettle();

      expect(_hasFocus(tester, find.byType(TextField)), isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'typing',
      );
    });

    testWidgets('a later theme change leaves the captured image as it was', (
      WidgetTester tester,
    ) async {
      final FakeAiClient client = FakeAiClient();
      final InkController controller = InkController(strokes: _page());
      addTearDown(controller.dispose);
      Future<void> pump(ThemeMode mode) {
        return pumpApp(
          tester,
          themeMode: mode,
          home: EditorScreen(
            inkController: controller,
            aiClient: client,
            initialNotationEnabled: false,
          ),
        );
      }

      await pump(ThemeMode.light);
      await _select(tester, controller);
      await _openAi(tester);
      final AiSelectionContext context = _assistant(tester).context!;
      expect(context.snapshot.brightness, Brightness.light);
      expect(context.snapshot.background, AppColors.light.writingSurface);

      await pump(ThemeMode.dark);
      await tester.tap(find.byTooltip('Close AI assistant'));
      await tester.pumpAndSettle();
      await _openAi(tester);

      expect(_assistant(tester).context, same(context));
      expect(_assistant(tester).context!.snapshot.brightness, Brightness.light);

      // A new capture takes the theme of the moment. Ink is picked in AI mode
      // by circling it, as the Select tool would turn AI mode off.
      selectInk(controller, _third);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'New chat'));
      await tester.pump();
      await settleAi(tester);
      expect(_assistant(tester).context!.snapshot.brightness, Brightness.dark);
      expect(
        _assistant(tester).context!.snapshot.background,
        AppColors.dark.writingSurface,
      );
    });

    testWidgets('disposing the editor mid-request is safe', (
      WidgetTester tester,
    ) async {
      final (_, FakeAiClient client) = await _pumpOpen(tester);
      await tester.tap(_quickAction('Explain this'));
      await tester.pump();

      await tester.pumpWidget(const SizedBox.shrink());
      client.answer('Too late');
      await tester.pump();

      expect(tester.takeException(), isNull);
      // The client was the test's, so it is the test's to close.
      expect(client.closed, isFalse);
    });
  });

  group('keyboard and screen readers', () {
    testWidgets('clipboard shortcuts stay with the text field', (
      WidgetTester tester,
    ) async {
      final (InkController controller, _) = await _pumpOpen(tester);
      await tester.enterText(find.byType(TextField), 'some text');
      await tester.pump();
      final TextEditingController text = tester
          .widget<TextField>(find.byType(TextField))
          .controller!;
      text.selection = const TextSelection(baseOffset: 0, extentOffset: 4);

      for (final LogicalKeyboardKey modifier in <LogicalKeyboardKey>[
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.metaLeft,
      ]) {
        for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
          LogicalKeyboardKey.keyC,
          LogicalKeyboardKey.keyX,
          LogicalKeyboardKey.keyV,
        ]) {
          await _chord(tester, modifier, key);
        }
      }

      // None of them copied, cut, or pasted ink.
      expect(controller.canPaste, isFalse);
      expect(controller.strokes, hasLength(3));
      expect(controller.selection!.indices, <int>[0, 1]);

      // Escape closes the panel and hands the keyboard back to the editor.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AiAssistantPanel), findsNothing);
      await _chord(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.keyC,
      );
      expect(controller.canPaste, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('every control has a label, a role, and a 48 px target', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final (_, FakeAiClient client) = await _pumpOpen(tester);

      expect(
        tester.getSemantics(find.text('AI assistant')),
        isSemantics(label: 'AI assistant', isHeader: true),
      );
      expect(
        tester.getSemantics(find.byTooltip('Close AI assistant')),
        isSemantics(
          tooltip: 'Close AI assistant',
          isButton: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      expect(find.bySemanticsLabel('Selected ink'), findsNothing);
      expect(
        find.bySemanticsLabel(AiAssistantPanel.emptyState),
        findsOneWidget,
      );
      for (final String label in <String>['Explain this', 'Grade this']) {
        expect(
          tester.getSemantics(_quickAction(label)),
          isSemantics(
            label: label,
            isButton: true,
            isEnabled: true,
            hasTapAction: true,
          ),
        );
      }
      expect(
        tester.getSemantics(find.byType(TextField)),
        isSemantics(isTextField: true, isMultiline: true),
      );
      // Send says that it is unavailable until there is something to send.
      expect(
        tester.getSemantics(find.byTooltip('Send')),
        isSemantics(tooltip: 'Send', isButton: true, isEnabled: false),
      );
      await tester.enterText(find.byType(TextField), 'Question');
      await tester.pump();
      expect(
        tester.getSemantics(find.byTooltip('Send')),
        isSemantics(
          tooltip: 'Send',
          isButton: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      for (final Finder control in <Finder>[
        find.byTooltip('Close AI assistant'),
        find.byTooltip('Send'),
        _quickAction('Explain this'),
        _quickAction('Grade this'),
        find.byType(TextField),
      ]) {
        final Size size = tester.getSize(control);
        expect(size.width, greaterThanOrEqualTo(AppSizes.minTouchTarget));
        expect(size.height, greaterThanOrEqualTo(AppSizes.minTouchTarget));
      }

      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      expect(
        find.bySemanticsLabel('Waiting for the AI service'),
        findsOneWidget,
      );
      // A message is read out with who wrote it.
      expect(tester.getSemantics(find.text('Question')).label, 'You\nQuestion');
      client.fail(AiFailureKind.server);
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel(const AiFailure(AiFailureKind.server).message),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(find.widgetWithText(TextButton, 'Retry')),
        isSemantics(
          label: 'Retry',
          isButton: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pump();
      client.answer('An answer');
      await tester.pumpAndSettle();
      // The assistant's message too.
      expect(
        tester.getSemantics(find.text('An answer')).label,
        'Assistant\nAn answer',
      );
      expect(tester.takeException(), isNull);
      handle.dispose();
    });

    testWidgets('Tab reaches every control, and Enter presses it', (
      WidgetTester tester,
    ) async {
      final (_, FakeAiClient client) = await _pumpOpen(tester);
      await tester.enterText(find.byType(TextField), 'Typed');
      await tester.pump();
      final Map<String, Finder> controls = <String, Finder>{
        'close': find.byTooltip('Close AI assistant'),
        'explain': _quickAction('Explain this'),
        'grade': _quickAction('Grade this'),
        'composer': find.byType(TextField),
        'send': find.byTooltip('Send'),
      };

      final List<String> visited = <String>[];
      for (int i = 0; i < 40; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        for (final MapEntry<String, Finder> control in controls.entries) {
          if (_hasFocus(tester, control.value) &&
              !visited.contains(control.key)) {
            visited.add(control.key);
          }
        }
      }
      expect(visited, unorderedEquals(controls.keys));
      // In reading order within the panel.
      final int start = visited.indexOf('close');
      final List<String> order = <String>[
        ...visited.sublist(start),
        ...visited.sublist(0, start),
      ];
      expect(order, controls.keys.toList());

      for (int i = 0; i < 40 && !_hasFocus(tester, controls['grade']!); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(client.requests.single.messages.single.text, AiPrompts.grade);
      client.fail(AiFailureKind.network);
      await tester.pumpAndSettle();

      final Finder retry = find.widgetWithText(TextButton, 'Retry');
      for (int i = 0; i < 40 && !_hasFocus(tester, retry); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(_hasFocus(tester, retry), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(client.requests, hasLength(2));
    });

    testWidgets('the compact sheet keeps Tab inside itself', (
      WidgetTester tester,
    ) async {
      await _pumpOpen(tester, viewport: TestViewport.compact);

      for (int i = 0; i < 30; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(
          _hasFocus(tester, find.byType(AiAssistantPanel)),
          isTrue,
          reason: 'after $i tabs',
        );
      }
      for (final String tooltip in <String>['Pen', 'Eraser', 'Copy']) {
        expect(_hasFocus(tester, find.byTooltip(tooltip)), isFalse);
      }
    });
  });
}
