import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_icons.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/pen_settings.dart';
import 'package:greatnote/features/editor/widgets/eraser_options.dart';
import 'package:greatnote/features/editor/widgets/ink_color_picker.dart';
import 'package:greatnote/features/editor/widgets/stroke_width_picker.dart';

import '../../helpers/editor_harness.dart';
import '../../helpers/pump_app.dart';

Finder _swatch(String id) => find.byKey(ValueKey<String>('ink-swatch-$id'));

/// Opens the pen's options: the pen starts selected, so one press does it.
Future<void> _openPen(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Pen'));
  await tester.pumpAndSettle();
}

Future<void> _setWidth(WidgetTester tester, double width) async {
  tester.widget<Slider>(find.byType(Slider)).onChanged!(width);
  await tester.pumpAndSettle();
}

/// Dismisses an open popover by tapping the app bar background.
Future<void> _dismiss(WidgetTester tester) async {
  await tester.tapAt(const Offset(150, 4));
  await tester.pumpAndSettle();
}

void main() {
  test('pen defaults: black ink, 3 px, range 1-20', () {
    const PenConfig config = PenConfig();
    final PenSettings settings = PenSettings.defaults();

    expect(config.minWidth, 1);
    expect(config.maxWidth, 20);
    expect(settings.width, 3);
    expect(settings.ink, InkPalette.ink);
  });

  for (final TestViewport viewport in <TestViewport>[
    TestViewport.tabletLandscape,
    TestViewport.tabletPortrait,
    TestViewport.compact,
  ]) {
    group(viewport.name, () {
      testWidgets('the pen panel opens on screen and selects an ink', (
        WidgetTester tester,
      ) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        await pumpEditor(tester, viewport: viewport);

        await _openPen(tester);

        final Rect screen = Offset.zero & viewport.size;
        final Rect picker = tester.getRect(find.byType(InkColorPicker));
        expect(screen.contains(picker.topLeft), isTrue);
        expect(screen.contains(picker.bottomRight), isTrue);
        expect(
          find.descendant(
            of: find.byType(InkColorPicker),
            matching: find.byType(InkWell),
          ),
          findsNWidgets(InkPalette.colors.length),
        );
        // The current ink has a checkmark and a selected state, not only a
        // color.
        expect(
          find.descendant(
            of: _swatch('ink'),
            matching: find.byIcon(AppIcons.check),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(InkColorPicker),
            matching: find.byIcon(AppIcons.check),
          ),
          findsOneWidget,
        );
        expect(
          tester.getSemantics(find.bySemanticsLabel('Black')),
          isSemantics(label: 'Black', isButton: true, isSelected: true),
        );
        expect(
          tester.getSemantics(find.bySemanticsLabel('Blue')),
          isSemantics(label: 'Blue', isButton: true, isSelected: false),
        );

        await tester.tap(_swatch('blue'));
        await tester.pumpAndSettle();

        // The panel stays open for the width, and the pen shows the ink.
        expect(find.byType(InkColorPicker), findsOneWidget);
        expect(find.bySemanticsLabel('Pen, Blue, 3 px'), findsOneWidget);
        expect(tester.takeException(), isNull);
        handle.dispose();
      });

      testWidgets('the pen panel has a width slider and a live preview', (
        WidgetTester tester,
      ) async {
        await pumpEditor(tester, viewport: viewport);

        await _openPen(tester);

        final Rect screen = Offset.zero & viewport.size;
        final Rect picker = tester.getRect(find.byType(StrokeWidthPicker));
        expect(screen.contains(picker.topLeft), isTrue);
        expect(screen.contains(picker.bottomRight), isTrue);
        final Slider slider = tester.widget<Slider>(find.byType(Slider));
        expect(slider.min, 1);
        expect(slider.max, 20);
        expect(slider.value, 3);

        StrokePreviewPainter preview() {
          final CustomPaint paint = tester.widget<CustomPaint>(
            find.byKey(const ValueKey<String>('stroke-width-preview')),
          );
          return paint.painter! as StrokePreviewPainter;
        }

        expect(preview().width, 3);

        // Drag the thumb to the far end of the track.
        final Rect track = tester.getRect(find.byType(Slider));
        await tester.dragFrom(
          Offset(track.left + 30, track.center.dy),
          Offset(track.width, 0),
        );
        await tester.pumpAndSettle();

        expect(tester.widget<Slider>(find.byType(Slider)).value, 20);
        expect(preview().width, 20);
        expect(find.text('20 px'), findsOneWidget);
        expect(find.bySemanticsLabel('Pen, Black, 20 px'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });
  }

  testWidgets('the preview uses the current ink color', (
    WidgetTester tester,
  ) async {
    await pumpEditor(tester);
    await _openPen(tester);
    await tester.tap(_swatch('red'));
    await tester.pumpAndSettle();

    final CustomPaint paint = tester.widget<CustomPaint>(
      find.byKey(const ValueKey<String>('stroke-width-preview')),
    );
    final InkColor red = InkPalette.colors.firstWhere(
      (InkColor ink) => ink.id == 'red',
    );
    expect((paint.painter! as StrokePreviewPainter).color, red.onLightPaper);
  });

  testWidgets('dismissing a popover does not draw on the page', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    await _openPen(tester);

    // Clear of the panel, which opens below the palette across the top.
    await tester.tapAt(canvasRect(tester).bottomRight - const Offset(40, 40));
    await tester.pumpAndSettle();

    expect(find.byType(InkColorPicker), findsNothing);
    expect(controller.strokes, isEmpty);
  });

  testWidgets('color and width survive rotation and breakpoint changes', (
    WidgetTester tester,
  ) async {
    await pumpEditor(tester, viewport: TestViewport.tabletPortrait);
    await _openPen(tester);
    await tester.tap(_swatch('green'));
    await tester.pumpAndSettle();
    await _setWidth(tester, 12);
    await _dismiss(tester);

    for (final Size size in <Size>[
      TestViewport.tabletPortrait.size.flipped,
      TestViewport.compact.size,
      TestViewport.tabletLandscape.size,
    ]) {
      setViewportSize(tester, size);
      await tester.pumpAndSettle();

      expect(
        find.bySemanticsLabel('Pen, Green, 12 px'),
        findsOneWidget,
        reason: '$size',
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('pressing the selected pen toggles its panel and keeps it '
      'selected', (WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await pumpEditor(tester);

    await _openPen(tester);
    expect(find.byType(InkColorPicker), findsOneWidget);
    expect(find.byType(StrokeWidthPicker), findsOneWidget);
    expect(find.byType(EraserOptions), findsNothing);
    await tester.tap(find.byTooltip('Pen'));
    await tester.pumpAndSettle();
    expect(find.byType(InkColorPicker), findsNothing);

    expect(
      tester.getSemantics(find.bySemanticsLabel('Pen, Black, 3 px')),
      isSemantics(isSelected: true),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Eraser, Area, 24 px')),
      isSemantics(isSelected: false),
    );
    handle.dispose();
  });

  testWidgets('with another tool selected, the pen selects first', (
    WidgetTester tester,
  ) async {
    await pumpEditor(tester);
    await tester.tap(find.byTooltip('Eraser'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Pen'));
    await tester.pumpAndSettle();
    expect(find.byType(InkColorPicker), findsNothing);
    await _openPen(tester);
    expect(find.byType(InkColorPicker), findsOneWidget);
  });
}
