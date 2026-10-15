import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
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
  group('breakpoints', () {
    testWidgets('expanded: vertical palette over the page, centered title', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);
      final Size screen = TestViewport.tabletLandscape.size;
      final Rect palette = _paletteRect(tester);
      final Rect surface = _surfaceRect(tester);

      expect(_palette(tester).axis, Axis.vertical);
      expect(_palette(tester).dense, isFalse);
      expect(surface.left, 0);
      expect(surface.right, screen.width);
      expect(surface.bottom, screen.height);
      expect(palette.left, AppSpacing.lg);
      expect(palette.top, surface.top + AppSpacing.lg);
      expect(
        tester.getCenter(find.text('Untitled note')).dx,
        closeTo(screen.width / 2, 1),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('medium: dense vertical palette and smaller margins', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, viewport: TestViewport.tabletPortrait);
      final Size screen = TestViewport.tabletPortrait.size;
      final Rect palette = _paletteRect(tester);
      final Rect surface = _surfaceRect(tester);

      expect(_palette(tester).axis, Axis.vertical);
      expect(_palette(tester).dense, isTrue);
      expect(surface.left, 0);
      expect(surface.right, screen.width);
      expect(palette.left, AppSpacing.sm);
      // The title sits beside the menu button, not in the middle.
      expect(
        tester.getCenter(find.text('Untitled note')).dx,
        lessThan(screen.width / 3),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('compact: horizontal palette along the bottom of the page', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, viewport: TestViewport.compact);
      final Size screen = TestViewport.compact.size;
      final Rect palette = _paletteRect(tester);
      final Rect surface = _surfaceRect(tester);

      expect(_palette(tester).axis, Axis.horizontal);
      expect(surface.bottom, screen.height);
      expect(palette.bottom, surface.bottom - AppSpacing.xs);
      expect(palette.center.dx, closeTo(screen.width / 2, 0.5));
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
      expect(_paletteRect(tester).left, AppSpacing.lg);
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

    testWidgets('right-to-left mirrors the palette to the leading edge', (
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
        _paletteRect(tester).right,
        _surfaceRect(tester).right - AppSpacing.lg,
      );
      expect(tester.takeException(), isNull);
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
      expect(_palette(tester).axis, Axis.vertical);

      setViewportSize(tester, TestViewport.tabletPortrait.size);
      await tester.pumpAndSettle();
      expect(_palette(tester).dense, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('compact rotation moves the palette without overflow', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, viewport: TestViewport.compact);
      expect(_palette(tester).axis, Axis.horizontal);

      setViewportSize(tester, TestViewport.compact.size.flipped);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();

      expect(_palette(tester).axis, Axis.vertical);
      expect(_surfaceRect(tester).left, 0);
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
            .widget<AnimatedPositioned>(find.byType(AnimatedPositioned))
            .duration,
        Duration.zero,
      );
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('scope', () {
    testWidgets(
      'offers a pen, an eraser, and Select; color and width are in the pen',
      (WidgetTester tester) async {
        await pumpApp(tester);

        expect(find.byType(PaletteButton), findsNWidgets(3));
        expect(find.byTooltip('Pen'), findsOneWidget);
        expect(find.byTooltip('Eraser'), findsOneWidget);
        expect(find.byTooltip('Select'), findsOneWidget);
        expect(find.byTooltip('Ink color'), findsNothing);
        expect(find.byTooltip('Stroke width'), findsNothing);
        for (final String unsupported in <String>[
          'Highlighter',
          'Pencil',
          'Shapes',
          'Text',
        ]) {
          expect(find.byTooltip(unsupported), findsNothing);
        }
      },
    );
  });
}
