import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/widgets/tool_palette.dart';

import '../../helpers/pump_app.dart';

final Finder _bar = find.byKey(const ValueKey<String>('text-options-bar'));
final Finder _surface = find.byKey(const ValueKey<String>('palette-surface'));

Future<void> _chooseText(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('palette-extension-toggle')),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey<String>('text-tool')));
  await tester.pumpAndSettle();
}

void main() {
  group('Text options', () {
    testWidgets('pressing Text again hides them, and they stay hidden', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<bool> shown = ValueNotifier<bool>(true);
      addTearDown(shown.dispose);
      await pumpApp(tester, home: EditorScreen(toolOptionsShown: shown));
      await _chooseText(tester);
      expect(_bar, findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('text-tool')));
      await tester.pumpAndSettle();
      expect(_bar, findsNothing);
      expect(shown.value, isFalse);
      expect(
        tester.widget<ToolPalette>(find.byType(ToolPalette)).tool.value,
        EditorTool.text,
      );

      await tester.tap(find.byTooltip('Eraser'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('text-tool')));
      await tester.pumpAndSettle();
      expect(_bar, findsNothing);

      await tester.tap(find.byKey(const ValueKey<String>('text-tool')));
      await tester.pumpAndSettle();
      expect(_bar, findsOneWidget);
      expect(shown.value, isTrue);
    });

    for (final PaletteEdge edge in PaletteEdge.values) {
      testWidgets('lie along the palette, centered on its page side, docked '
          'at the '
          '${edge.label}', (WidgetTester tester) async {
        final ValueNotifier<PalettePlacement> placement =
            ValueNotifier<PalettePlacement>(PalettePlacement(edge: edge));
        addTearDown(placement.dispose);
        await pumpApp(tester, home: EditorScreen(palettePlacement: placement));
        await tester.tap(
          find.byKey(const ValueKey<String>('palette-extension-toggle')),
        );
        await tester.pumpAndSettle();
        final Rect before = tester.getRect(_surface);
        await tester.tap(find.byKey(const ValueKey<String>('text-tool')));
        await tester.pumpAndSettle();

        final Rect palette = tester.getRect(_surface);
        final Rect bar = tester.getRect(_bar);
        // Choosing Text leaves the palette where it was docked.
        expect(palette, before);
        switch (edge) {
          case PaletteEdge.top:
            expect(bar.top, greaterThan(palette.bottom));
          case PaletteEdge.bottom:
            expect(bar.bottom, lessThan(palette.top));
          case PaletteEdge.left:
            expect(bar.left, greaterThan(palette.right));
          case PaletteEdge.right:
            expect(bar.right, lessThan(palette.left));
        }
        // Parallel: as thick as the palette, and long the same way.
        if (edge.axis == Axis.horizontal) {
          expect(bar.height, moreOrLessEquals(palette.height));
          expect(bar.width, greaterThan(bar.height));
          // Centered on the palette.
          expect(bar.center.dx, moreOrLessEquals(palette.center.dx));
        } else {
          expect(bar.width, moreOrLessEquals(palette.width));
          expect(bar.height, greaterThan(bar.width));
          expect(bar.center.dy, moreOrLessEquals(palette.center.dy));
        }
        // On screen, and its controls can be pressed.
        expect(
          tester.getRect(find.byType(Scaffold).first).contains(bar.center),
          isTrue,
        );
        await tester.tap(find.byKey(const ValueKey<String>('text-bold')));
        await tester.pump();
      });
    }
  });
}
