import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/shared/layout/breakpoints.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/page/page_viewport.dart';
import 'package:greatnote/features/editor/widgets/editor_app_bar.dart';
import 'package:greatnote/features/editor/widgets/palette_button.dart';
import 'package:greatnote/features/editor/widgets/tool_palette.dart';
import 'package:greatnote/features/editor/widgets/writing_surface_frame.dart';

import '../../helpers/pump_app.dart';

Rect _paletteRect(WidgetTester tester) {
  return tester.getRect(find.byType(ToolPalette));
}

Rect _surfaceRect(WidgetTester tester) {
  return tester.getRect(find.byType(WritingSurfaceFrame));
}

ToolPalette _palette(WidgetTester tester) {
  return tester.widget<ToolPalette>(find.byType(ToolPalette));
}

void main() {
  group('undo, redo, and the page controls', () {
    for (final TestViewport viewport in <TestViewport>[
      TestViewport.tabletLandscape,
      TestViewport.tabletPortrait,
      TestViewport.compact,
    ]) {
      testWidgets(
        '${viewport.name}: history card hanging at the left, page controls at the right',
        (WidgetTester tester) async {
          await pumpApp(tester, viewport: viewport);
          final Rect palette = _paletteRect(tester);
          final Rect surface = _surfaceRect(tester);
          final Finder card = find.byKey(
            const ValueKey<String>('history-card'),
          );
          final Rect history = tester.getRect(card);

          expect(history.height, palette.height);
          // Joined to the bar, and to the screen's left edge.
          expect(history.top, surface.top);
          expect(history.left, surface.left);
          expect(history.overlaps(palette), isFalse);
          if (viewport == TestViewport.compact) {
            // No room beside the card: the palette has the row below it.
            expect(palette.top, greaterThanOrEqualTo(history.bottom));
          } else {
            expect(palette.left, greaterThanOrEqualTo(history.right));
          }
          // Not in the top bar.
          expect(
            find.descendant(
              of: find.byType(EditorAppBar),
              matching: find.byTooltip('Undo'),
            ),
            findsNothing,
          );
          // In the left card: undo, then redo.
          final Rect undo = tester.getRect(
            find.descendant(of: card, matching: find.byTooltip('Undo')),
          );
          final Rect redo = tester.getRect(
            find.descendant(of: card, matching: find.byTooltip('Redo')),
          );
          expect(undo.right, lessThanOrEqualTo(redo.left + 0.5));
          expect(history.contains(undo.center), isTrue);
          expect(history.contains(redo.center), isTrue);

          // The page grid lives with the top-left controls, separate from
          // page editing; the page number shows in the grid, not here.
          expect(
            find.byKey(const ValueKey<String>('page-number-button')),
            findsNothing,
          );
          expect(
            find.descendant(
              of: card,
              matching: find.byTooltip('Page overview'),
            ),
            findsOneWidget,
          );

          // On the right: page controls card hanging from the top bar.
          final Finder pageCard = find.byKey(
            const ValueKey<String>('page-controls-card'),
          );
          final Rect pageControls = tester.getRect(pageCard);
          expect(pageControls.height, palette.height);
          expect(pageControls.top, surface.top);
          expect(pageControls.right, surface.right);
          expect(pageControls.overlaps(palette), isFalse);

          final Rect add = tester.getRect(
            find.descendant(of: pageCard, matching: find.byTooltip('Add')),
          );
          expect(pageControls.contains(add.center), isTrue);
          expect(
            find.descendant(
              of: pageCard,
              matching: find.byTooltip('Page settings'),
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  });

  group('breakpoints', () {
    testWidgets('expanded: palette centered across the top, centered title', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);
      final Size screen = TestViewport.tabletLandscape.size;
      final Rect palette = _paletteRect(tester);
      final Rect surface = _surfaceRect(tester);

      expect(_palette(tester).edge, PaletteEdge.top);
      expect(_palette(tester).axis, Axis.horizontal);
      expect(_palette(tester).dense, isFalse);
      expect(surface.left, 0);
      expect(surface.right, screen.width);
      expect(surface.bottom, screen.height);
      expect(palette.top, surface.top + AppSpacing.xs);
      expect(palette.center.dx, closeTo(screen.width / 2, 0.5));
      expect(
        tester.getCenter(find.text('Untitled note')).dx,
        closeTo(screen.width / 2, 1),
      );
      expect(tester.takeException(), isNull);
    });

    test(
      'when AI chat is opened, toolbar is centered between top left and top right boxes',
      () {
        const Rect region = Rect.fromLTWH(0, 0, 900, 600);
        const double historyWidth = 100;
        const double pageControlsWidth = 260;
        final EditorLayout layout = EditorLayout.compute(
          WindowSizeClass.expanded,
          region,
          const PalettePlacement(edge: PaletteEdge.top),
          historyWidth: historyWidth,
          pageControlsWidth: pageControlsWidth,
          isAiOpen: true,
        );
        final double leftEdgeOfRightBox = layout.pageControls.left;
        final double rightEdgeOfLeftBox = layout.history.right;
        final double middleBetweenBoxes =
            (leftEdgeOfRightBox + rightEdgeOfLeftBox) / 2;
        final double paletteCenter =
            layout.paletteOrigin.dx +
            ToolPalette.sizeFor(Axis.horizontal).width / 2;
        expect(paletteCenter, closeTo(middleBetweenBoxes, 0.5));
      },
    );

    testWidgets('medium: dense palette and smaller margins', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, viewport: TestViewport.tabletPortrait);
      final Size screen = TestViewport.tabletPortrait.size;
      final Rect palette = _paletteRect(tester);
      final Rect surface = _surfaceRect(tester);

      expect(_palette(tester).axis, Axis.horizontal);
      expect(_palette(tester).dense, isTrue);
      expect(surface.left, 0);
      expect(surface.right, screen.width);
      expect(palette.top, surface.top + AppSpacing.xs);
      // The title sits beside the menu button, not in the middle.
      expect(
        tester.getCenter(find.text('Untitled note')).dx,
        lessThan(screen.width / 3),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('compact: palette across the top of the page too', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, viewport: TestViewport.compact);
      final Size screen = TestViewport.compact.size;
      final Rect palette = _paletteRect(tester);
      final Rect surface = _surfaceRect(tester);

      expect(_palette(tester).axis, Axis.horizontal);
      expect(surface.bottom, screen.height);
      // On the row below the card hanging from the bar.
      final Rect card = tester.getRect(
        find.byKey(const ValueKey<String>('history-card')),
      );
      expect(palette.top, card.bottom + AppSpacing.xxs);
      expect(palette.center.dx, closeTo(screen.width / 2, 0.5));
      expect(palette.left, greaterThanOrEqualTo(surface.left));
      expect(tester.takeException(), isNull);
    });

    for (final TestViewport viewport in TestViewport.values) {
      testWidgets('${viewport.name}: the page spans the whole screen', (
        WidgetTester tester,
      ) async {
        await pumpApp(tester, viewport: viewport);
        final Size screen = viewport.size;
        final Rect surface = _surfaceRect(tester);
        final double appBarBottom = tester
            .getRect(find.byType(EditorAppBar))
            .bottom;

        expect(
          surface,
          Rect.fromLTRB(0, appBarBottom, screen.width, screen.height),
        );
        expect(
          _paletteRect(tester).size,
          ToolPalette.sizeFor(_palette(tester).axis),
        );
        // The palette floats above the page, inside it.
        expect(surface.intersect(_paletteRect(tester)), _paletteRect(tester));
      });
    }

    testWidgets('very wide windows still fill the width', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, size: const Size(2200, 1000));

      final Rect surface = _surfaceRect(tester);
      expect(surface.left, 0);
      expect(surface.right, 2200);
      expect(_paletteRect(tester).center.dx, closeTo(1100, 0.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('tiny windows do not overflow', (WidgetTester tester) async {
      await pumpApp(tester, viewport: TestViewport.compact);
      for (final Size size in const <Size>[
        Size(320, 480),
        Size(280, 300),
        Size(600, 240),
      ]) {
        setViewportSize(tester, size);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$size');
      }
    });

    testWidgets('right-to-left keeps the palette centered across the top', (
      WidgetTester tester,
    ) async {
      setViewportSize(tester, TestViewport.tabletLandscape.size);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          builder: (BuildContext context, Widget? child) {
            return Directionality(
              textDirection: TextDirection.rtl,
              child: child!,
            );
          },
          home: const EditorScreen(),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        _paletteRect(tester).center.dx,
        closeTo(_surfaceRect(tester).center.dx, 0.5),
      );
      expect(_palette(tester).edge, PaletteEdge.top);
      expect(tester.takeException(), isNull);
    });
  });

  group('dragging the palette', () {
    testWidgets('delivered moves rebuild neither editor nor viewport', (
      tester,
    ) async {
      await pumpApp(tester);
      final palette = _palette(tester);
      final previous = debugOnRebuildDirtyWidget;
      var shellBuilds = 0;
      var viewportBuilds = 0;
      var paletteBuilds = 0;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        if (element.widget is EditorScreen) shellBuilds++;
        if (element.widget is PageViewport) viewportBuilds++;
        if (element.widget is ToolPalette) paletteBuilds++;
        previous?.call(element, builtOnce);
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previous);
      palette.onDragStart!();
      await tester.pumpAndSettle();
      final before = _paletteRect(tester);
      for (var i = 0; i < 30; i++) {
        _palette(tester).onDragUpdate!(const Offset(1, 1));
        await tester.pump();
        expect(
          _paletteRect(tester).topLeft,
          before.topLeft + Offset(i + 1, i + 1),
        );
      }
      expect(shellBuilds, 0);
      expect(viewportBuilds, 0);
      expect(paletteBuilds, 0);
      _palette(tester).onDragEnd!();
      await tester.pumpAndSettle();
    });
    testWidgets('drag writes shared placement once at drop', (tester) async {
      final placement = ValueNotifier<PalettePlacement>(
        const PalettePlacement(),
      );
      addTearDown(placement.dispose);
      var writes = 0;
      placement.addListener(() => writes++);
      await pumpApp(tester, home: EditorScreen(palettePlacement: placement));
      _palette(tester).onDragStart!();
      for (var i = 0; i < 20; i++) {
        _palette(tester).onDragUpdate!(const Offset(-10, 0));
        await tester.pump();
      }
      expect(writes, 0);
      _palette(tester).onDragEnd!();
      await tester.pumpAndSettle();
      expect(writes, 1);
      final saved = placement.value;
      await tester.pumpWidget(const SizedBox());
      await pumpApp(tester, home: EditorScreen(palettePlacement: placement));
      expect(placement.value, saved);
      _palette(tester).onMoveTo!(PaletteEdge.right);
      await tester.pumpAndSettle();
      expect(placement.value.edge, PaletteEdge.right);
      expect(writes, 2);
      await tester.pumpWidget(const SizedBox());
    });
    final Finder grip = find.byKey(const ValueKey<String>('palette-surface'));

    /// Holds the palette's bare surface until it lifts.
    Future<TestGesture> lift(WidgetTester tester) async {
      final TestGesture drag = await tester.startGesture(
        tester.getTopLeft(grip) + const Offset(16, 24),
      );
      await tester.pump(
        ToolPalette.liftDelay + const Duration(milliseconds: 50),
      );
      return drag;
    }

    testWidgets('pressed, it lights up; held, it lifts; let go, it settles', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);
      double scale() => tester
          .widget<AnimatedScale>(
            find.descendant(of: grip, matching: find.byType(AnimatedScale)),
          )
          .scale;
      final TestGesture drag = await tester.startGesture(
        tester.getTopLeft(grip) + const Offset(16, 24),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(scale(), 1);
      await tester.pump(
        ToolPalette.liftDelay - const Duration(milliseconds: 150),
      );
      expect(scale(), greaterThan(1));
      await drag.up();
      await tester.pumpAndSettle();
      expect(scale(), 1);
    });

    testWidgets('a quick drag across the surface does not move it', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);
      final Rect before = _paletteRect(tester);
      final TestGesture drag = await tester.startGesture(
        tester.getTopLeft(grip) + const Offset(16, 24),
      );
      await drag.moveBy(const Offset(0, 300));
      await drag.up();
      await tester.pumpAndSettle();
      expect(_paletteRect(tester), before);
    });

    for (final (String name, Offset to, PaletteEdge edge)
        in <(String, Offset, PaletteEdge)>[
          ('left', const Offset(40, 500), PaletteEdge.left),
          ('right', const Offset(1150, 400), PaletteEdge.right),
          ('bottom', const Offset(400, 820), PaletteEdge.bottom),
        ]) {
      testWidgets('let go near the $name, it docks there and turns', (
        WidgetTester tester,
      ) async {
        await pumpApp(tester);
        final TestGesture drag = await lift(tester);
        await drag.moveBy(const Offset(0, 40));
        await drag.moveTo(to);
        await tester.pump();
        // Already lying along the edge it is nearest while held.
        expect(_palette(tester).edge, edge);
        await drag.up();
        await tester.pumpAndSettle();

        final Rect palette = _paletteRect(tester);
        final Rect surface = _surfaceRect(tester);
        expect(_palette(tester).edge, edge);
        expect(
          _palette(tester).axis,
          edge == PaletteEdge.bottom ? Axis.horizontal : Axis.vertical,
        );
        switch (edge) {
          case PaletteEdge.left:
            expect(palette.left, surface.left + AppSpacing.xs);
          case PaletteEdge.right:
            expect(palette.right, surface.right - AppSpacing.xs);
          case PaletteEdge.bottom:
            expect(palette.bottom, surface.bottom - AppSpacing.xs);
          case PaletteEdge.top:
            break;
        }
        expect(surface.intersect(palette), palette);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('let go far along an edge, it stays where it was let go', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);
      final TestGesture drag = await lift(tester);
      await drag.moveBy(const Offset(300, 0));
      await drag.up();
      await tester.pumpAndSettle();

      expect(_palette(tester).edge, PaletteEdge.top);
      expect(
        _paletteRect(tester).center.dx,
        closeTo(_surfaceRect(tester).center.dx + 300, 1),
      );
    });

    testWidgets('let go near the middle of an edge, it settles there', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);
      final TestGesture drag = await lift(tester);
      await drag.moveBy(const Offset(-300, 0));
      await tester.pump();
      // Back to just short of the middle.
      await drag.moveBy(const Offset(250, 0));
      await tester.pump();
      expect(
        _paletteRect(tester).center.dx,
        closeTo(_surfaceRect(tester).center.dx - 50, 1),
      );
      await drag.up();
      await tester.pumpAndSettle();

      expect(
        _paletteRect(tester).center.dx,
        closeTo(_surfaceRect(tester).center.dx, 0.5),
      );
    });

    testWidgets('a tap on a tool still selects it, without lifting', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);
      final Rect before = _paletteRect(tester);
      await tester.tap(find.byTooltip('Eraser'));
      await tester.pumpAndSettle();

      expect(_palette(tester).tool.value, EditorTool.eraser);
      expect(_paletteRect(tester), before);
    });

    testWidgets('held on a tool, the palette lifts too', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);
      final TestGesture drag = await tester.startGesture(
        tester.getCenter(find.byTooltip('Eraser')),
      );
      await tester.pump(
        ToolPalette.liftDelay + const Duration(milliseconds: 50),
      );
      await drag.moveTo(const Offset(40, 500));
      await drag.up();
      await tester.pumpAndSettle();

      expect(_palette(tester).edge, PaletteEdge.left);
      expect(_palette(tester).tool.value, EditorTool.pen);
    });

    testWidgets('dragging does not draw on the page', (
      WidgetTester tester,
    ) async {
      final InkController ink = InkController();
      addTearDown(ink.dispose);
      await pumpApp(tester, home: EditorScreen(inkController: ink));
      final TestGesture drag = await lift(tester);
      await drag.moveBy(const Offset(0, 200));
      await drag.moveBy(const Offset(-300, 100));
      await drag.up();
      await tester.pumpAndSettle();

      expect(ink.strokes, isEmpty);
    });

    testWidgets('assistive technology can dock it at each edge', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await pumpApp(tester);
      final SemanticsNode node = tester.getSemantics(grip);
      final SemanticsData data = node.getSemanticsData();
      expect(data.label, contains('Move tools'));
      final int action = data.customSemanticsActionIds!.firstWhere(
        (int id) =>
            CustomSemanticsAction.getAction(id)!.label ==
            'Move tools to the right',
      );
      node.owner!.performAction(node.id, SemanticsAction.customAction, action);
      await tester.pumpAndSettle();

      expect(_palette(tester).edge, PaletteEdge.right);
      semantics.dispose();
    });
  });

  group('orientation', () {
    testWidgets('rotating back and forth never overflows', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, viewport: TestViewport.tabletPortrait);
      expect(_palette(tester).dense, isTrue);

      setViewportSize(tester, TestViewport.tabletPortrait.size.flipped);
      await tester.pump();
      // Mid-transition frames must be clean too.
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(_palette(tester).dense, isFalse);
      expect(_palette(tester).axis, Axis.horizontal);

      setViewportSize(tester, TestViewport.tabletPortrait.size);
      await tester.pumpAndSettle();
      expect(_palette(tester).dense, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('compact rotation keeps the palette docked, without overflow', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, viewport: TestViewport.compact);
      expect(_palette(tester).axis, Axis.horizontal);

      setViewportSize(tester, TestViewport.compact.size.flipped);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();

      expect(_palette(tester).edge, PaletteEdge.top);
      expect(_surfaceRect(tester).left, 0);
      expect(
        _surfaceRect(tester).intersect(_paletteRect(tester)),
        _paletteRect(tester),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('palette relocation honors reduced motion', (
      WidgetTester tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await pumpApp(tester, viewport: TestViewport.compact);

      setViewportSize(tester, TestViewport.compact.size.flipped);
      await tester.pump();

      expect(
        tester
            .widget<TweenAnimationBuilder<Offset>>(
              find.byKey(const ValueKey<String>('tool-palette-position')),
            )
            .duration,
        AppMotion.reduced,
      );
      expect(
        tester
            .widget<TweenAnimationBuilder<Offset>>(
              find.descendant(
                of: find.byKey(const ValueKey<String>('history-position')),
                matching: find.byType(TweenAnimationBuilder<Offset>),
              ),
            )
            .duration,
        AppMotion.reduced,
      );
      await tester.pumpAndSettle(AppMotion.reduced);
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('scope', () {
    testWidgets('offers pen, eraser, Select, sticky note, and AI mode', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);

      // The six tools and the arrow that unfolds the recordings and the ruler.
      expect(find.byType(PaletteButton), findsNWidgets(7));
      expect(find.byTooltip('Expand toolbar'), findsOneWidget);
      expect(find.byTooltip('Recordings'), findsNothing);
      expect(find.byTooltip('Show ruler'), findsNothing);
      expect(find.byTooltip('Sticky note'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('palette-surface')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.drag_handle), findsNothing);
      expect(find.byTooltip('Pen'), findsOneWidget);
      expect(find.byTooltip('Eraser'), findsOneWidget);
      expect(find.byTooltip('Select'), findsOneWidget);
      expect(find.byTooltip('Insert image'), findsOneWidget);
      // AI mode replaces the old AI-notes eye, and is there before the page
      // has any AI notes.
      expect(find.byTooltip('Turn on AI'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('ai-notes-visibility-toggle')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('ai-mode-toggle')),
          matching: find.text('AI'),
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('Ink color'), findsNothing);
      expect(find.byTooltip('Stroke width'), findsNothing);
      // The highlighter is a style of the one writing tool, not a tool.
      for (final String unsupported in <String>[
        'Highlighter',
        'Pencil',
        'Shapes',
        'Text',
      ]) {
        expect(find.byTooltip(unsupported), findsNothing);
      }
    });
  });
}
