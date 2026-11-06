import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/features/editor/page/page_viewport.dart';
import 'package:greatnote/features/editor/widgets/tool_options_bar.dart';
import 'package:greatnote/features/editor/widgets/tool_palette.dart';
import 'package:greatnote/shared/layout/breakpoints.dart';

import '../../helpers/pump_app.dart';

void main() {
  group('note scroll down margin under toolbar and subtoolbar', () {
    testWidgets(
      'scrolling down allows a nice margin between top of note and toolbar, and under subtoolbar when open',
      (WidgetTester tester) async {
        await pumpApp(tester, viewport: TestViewport.tabletLandscape);
        final PageViewportState viewport = tester.state<PageViewportState>(
          find.byType(PageViewport),
        );
        final Finder canvas = find.byType(InkCanvas).first;
        final Finder paletteCard = find.byKey(
          const ValueKey<String>('tool-palette-card'),
        );

        // Initially with Pen selected, subtoolbar (options bar) is open.
        expect(find.byType(ToolOptionsBar), findsOneWidget);
        final Rect subtoolbarRect = tester.getRect(find.byType(ToolOptionsBar));
        final Rect paletteRect = tester.getRect(paletteCard);

        // Scroll the note down as far as it can go.
        viewport.scrollBy(const Offset(0, -1000));
        await tester.pump();

        final Rect canvasWithSubtoolbar = tester.getRect(canvas);

        // The top of the note is under the subtoolbar, with a margin of AppSpacing.md.
        expect(canvasWithSubtoolbar.top, greaterThan(subtoolbarRect.bottom));
        expect(
          canvasWithSubtoolbar.top - subtoolbarRect.bottom,
          closeTo(AppSpacing.md, 0.5),
        );

        // Now close the subtoolbar by tapping the Pen tool again.
        await tester.tap(find.byTooltip('Pen'));
        await tester.pumpAndSettle();

        // Subtoolbar is now closed.
        expect(find.byType(ToolOptionsBar), findsNothing);

        // Scroll the note down as far as it can go.
        viewport.scrollBy(const Offset(0, -1000));
        await tester.pump();

        final Rect canvasWithoutSubtoolbar = tester.getRect(canvas);

        // The top of the note now stops with a nice margin between note top and toolbar.
        expect(canvasWithoutSubtoolbar.top, greaterThan(paletteRect.bottom));
        expect(
          canvasWithoutSubtoolbar.top - paletteRect.bottom,
          closeTo(AppSpacing.md, 0.5),
        );

        // Open the subtoolbar again by tapping Pen.
        await tester.tap(find.byTooltip('Pen'));
        await tester.pumpAndSettle();

        expect(find.byType(ToolOptionsBar), findsOneWidget);

        // The note can now scroll down further so it is under the subtoolbar.
        viewport.scrollBy(const Offset(0, -1000));
        await tester.pump();

        final Rect canvasReopened = tester.getRect(canvas);
        final Rect newSubtoolbarRect = tester.getRect(
          find.byType(ToolOptionsBar),
        );
        expect(canvasReopened.top, greaterThan(newSubtoolbarRect.bottom));
        expect(
          canvasReopened.top - newSubtoolbarRect.bottom,
          closeTo(AppSpacing.md, 0.5),
        );
      },
    );

    testWidgets(
      'compact viewport: top of note stops below row-2 toolbar and subtoolbar',
      (WidgetTester tester) async {
        await pumpApp(tester, viewport: TestViewport.compact);
        final PageViewportState viewport = tester.state<PageViewportState>(
          find.byType(PageViewport),
        );
        final Finder canvas = find.byType(InkCanvas).first;

        // In a multi-page or tall note, the column starts at the top under the toolbars.
        await tester.tap(find.byTooltip('Page settings'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add page'));
        await tester.pumpAndSettle();

        expect(find.byType(ToolOptionsBar), findsOneWidget);
        final Rect subtoolbarRect = tester.getRect(find.byType(ToolOptionsBar));

        viewport.scrollBy(const Offset(0, -1000));
        await tester.pump();

        final Rect canvasWithSubtoolbar = tester.getRect(canvas);
        expect(canvasWithSubtoolbar.top, greaterThan(subtoolbarRect.bottom));
        expect(
          canvasWithSubtoolbar.top - subtoolbarRect.bottom,
          closeTo(AppSpacing.md, 0.5),
        );
      },
    );

    testWidgets(
      'two-finger scroll gesture scrolls the note down to the margin',
      (WidgetTester tester) async {
        await pumpApp(tester, viewport: TestViewport.tabletLandscape);
        final Finder canvas = find.byType(InkCanvas).first;
        final Rect subtoolbarRect = tester.getRect(find.byType(ToolOptionsBar));

        final Offset center = tester.getCenter(find.byType(PageViewport));
        final TestGesture first = await tester.startGesture(
          center + const Offset(-30, 0),
          kind: PointerDeviceKind.touch,
        );
        final TestGesture second = await tester.startGesture(
          center + const Offset(30, 0),
          kind: PointerDeviceKind.touch,
        );
        for (int i = 0; i < 20; i++) {
          await first.moveBy(const Offset(0, 20));
          await second.moveBy(const Offset(0, 20));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await first.up();
        await second.up();
        await tester.pumpAndSettle();

        final Rect canvasAfterGesture = tester.getRect(canvas);
        expect(canvasAfterGesture.top, greaterThan(subtoolbarRect.bottom));
        expect(
          canvasAfterGesture.top - subtoolbarRect.bottom,
          closeTo(AppSpacing.md, 0.5),
        );
      },
    );
  });
}
