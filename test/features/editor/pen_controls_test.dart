import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_icons.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/pen_settings.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/widgets/eraser_options.dart';
import 'package:greatnote/features/editor/widgets/tool_palette.dart';
import 'package:greatnote/shared/widgets/app_controls.dart';

import '../../helpers/editor_harness.dart';
import '../../helpers/pump_app.dart';

Finder _swatch(int index) => find.byKey(ValueKey<String>('ink-swatch-$index'));

final Finder _penBar = find.byKey(const ValueKey<String>('pen-options-bar'));

Future<void> _setWidth(WidgetTester tester, double width) async {
  tester.widget<Slider>(find.byType(Slider)).onChanged!(width);
  await tester.pumpAndSettle();
}

/// Taps [target], scrolled into the bar's view first: a narrow window
/// shows only part of it.
Future<void> _tapInBar(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
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
    expect(settings.strokeStyle(config).width, 1.5);
  });

  test('the pen and highlighter keep three inks at hand each', () {
    final PenSettings settings = PenSettings.defaults();
    expect(settings.activeSwatches, <InkColor>[
      InkPalette.ink,
      InkPalette.blue,
      InkPalette.red,
    ]);
    final PenSettings highlighter = settings.copyWith(
      style: WritingStyle.highlighter,
    );
    expect(highlighter.activeSwatches, <InkColor>[
      InkPalette.highlighterYellow,
      InkPalette.highlighterGreen,
      InkPalette.highlighterPink,
    ]);

    const InkColor teal = InkColor(
      id: 'custom-ff0f7c82',
      label: 'Custom',
      onLightPaper: Color(0xFF0F7C82),
      onDarkPaper: Color(0xFF0F7C82),
    );
    final PenSettings changed = settings.withActiveSwatch(2, teal);
    expect(changed.ink, teal);
    expect(changed.swatches, <InkColor>[InkPalette.ink, InkPalette.blue, teal]);
    // The highlighter's are its own.
    expect(changed.highlighterSwatches, PenSettings.defaultHighlighterSwatches);
  });

  for (final TestViewport viewport in <TestViewport>[
    TestViewport.tabletLandscape,
    TestViewport.tabletPortrait,
    TestViewport.compact,
  ]) {
    group(viewport.name, () {
      testWidgets('the pen bar lies along the palette with three inks', (
        WidgetTester tester,
      ) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        await pumpEditor(tester, viewport: viewport);

        // The pen is chosen from the start, and its bar shows with it.
        final Rect screen = Offset.zero & viewport.size;
        final Rect bar = tester.getRect(_penBar);
        final Rect palette = tester.getRect(
          find.byKey(const ValueKey<String>('palette-surface')),
        );
        expect(screen.contains(bar.topLeft), isTrue);
        expect(screen.contains(bar.bottomRight), isTrue);
        expect(bar.top, greaterThan(palette.bottom));
        expect(bar.height, moreOrLessEquals(palette.height));

        expect(_swatch(2), findsOneWidget);
        expect(_swatch(3), findsNothing);
        // The current ink has a checkmark and a selected state, not only a
        // color.
        expect(
          find.descendant(
            of: _swatch(0),
            matching: find.byIcon(AppIcons.check),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: _penBar, matching: find.byIcon(AppIcons.check)),
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

        await _tapInBar(tester, _swatch(1));

        expect(_penBar, findsOneWidget);
        expect(find.bySemanticsLabel('Pen, Blue, 3 px'), findsOneWidget);
        expect(tester.takeException(), isNull);
        handle.dispose();
      });

      testWidgets('the pen bar has a width slider', (
        WidgetTester tester,
      ) async {
        await pumpEditor(tester, viewport: viewport);

        final Slider slider = tester.widget<Slider>(find.byType(Slider));
        expect(slider.min, 1);
        expect(slider.max, 20);
        expect(slider.value, 3);

        await _setWidth(tester, 20);

        expect(tester.widget<Slider>(find.byType(Slider)).value, 20);
        expect(find.bySemanticsLabel('Pen, Black, 20 px'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });
  }

  testWidgets('a tap on the chosen ink opens the palette to change it', (
    WidgetTester tester,
  ) async {
    await pumpEditor(tester);
    await tester.tap(_swatch(0));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('color-hex-input')),
      '0F7C82',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('color-select-button')));
    await tester.pumpAndSettle();

    final PenSettings pen = tester
        .widget<ToolPalette>(find.byType(ToolPalette))
        .penSettings
        .value;
    expect(pen.ink.id, 'custom-ff0f7c82');
    expect(pen.swatches.first, pen.ink);
    expect(pen.swatches.skip(1), <InkColor>[InkPalette.blue, InkPalette.red]);
  });

  testWidgets('pen styles use icons; the highlighter has inks of its own', (
    WidgetTester tester,
  ) async {
    await pumpEditor(tester);

    expect(find.text('Pen'), findsNothing);
    expect(find.text('Pencil'), findsNothing);
    expect(find.text('Highlighter'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('writing-style-pencil')),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Pencil, Black, 3 px'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('writing-style-highlighter')),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Highlighter, Yellow, 12 px'), findsOneWidget);
    expect(find.byTooltip('Change Yellow'), findsOneWidget);
    expect(find.byTooltip('Pink'), findsOneWidget);
    // Taper and pressure belong to the pen.
    expect(
      find.byKey(const ValueKey<String>('pen-advanced-toggle')),
      findsNothing,
    );
  });

  testWidgets('the chosen tool is filled; the chosen option is framed', (
    WidgetTester tester,
  ) async {
    await pumpEditor(tester);
    final AppColors colors = AppColors.of(
      tester.element(find.byType(ToolPalette)),
    );

    final DecoratedBox capsule = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byType(SelectionCapsule),
        matching: find.byType(DecoratedBox),
      ),
    );
    expect((capsule.decoration as ShapeDecoration).color, colors.selected);

    BoxDecoration option(String style) {
      return tester
              .widget<AnimatedContainer>(
                find.descendant(
                  of: find.byKey(ValueKey<String>('writing-style-$style')),
                  matching: find.byType(AnimatedContainer),
                ),
              )
              .decoration!
          as BoxDecoration;
    }

    expect(option('pen').color, isNull);
    expect((option('pen').border! as Border).top.color, colors.accent);
    expect(option('pencil').color, isNull);
    expect((option('pencil').border! as Border).top.color.a, 0);
  });

  testWidgets('color and width survive rotation and breakpoint changes', (
    WidgetTester tester,
  ) async {
    await pumpEditor(tester, viewport: TestViewport.tabletPortrait);
    await _tapInBar(tester, _swatch(2));
    await _setWidth(tester, 12);

    for (final Size size in <Size>[
      TestViewport.tabletPortrait.size.flipped,
      TestViewport.compact.size,
      TestViewport.tabletLandscape.size,
    ]) {
      setViewportSize(tester, size);
      await tester.pumpAndSettle();

      expect(
        find.bySemanticsLabel('Pen, Red, 12 px'),
        findsOneWidget,
        reason: '$size',
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('pressing the chosen tool hides its bar, for every tool after, '
      'until pressed again', (WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await pumpEditor(tester);

    expect(_penBar, findsOneWidget);
    expect(find.byType(EraserOptions), findsNothing);
    await tester.tap(find.byTooltip('Pen'));
    await tester.pumpAndSettle();
    expect(_penBar, findsNothing);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Pen, Black, 3 px')),
      isSemantics(isSelected: true),
    );

    // Another tool, chosen, keeps its bar hidden too.
    await tester.tap(find.byTooltip('Eraser'));
    await tester.pumpAndSettle();
    expect(find.byType(EraserOptions), findsNothing);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Eraser, Area, 24 px')),
      isSemantics(isSelected: true),
    );

    // Pressed again, it shows, and stays shown for the next.
    await tester.tap(find.byTooltip('Eraser'));
    await tester.pumpAndSettle();
    expect(find.byType(EraserOptions), findsOneWidget);
    await tester.tap(find.byTooltip('Pen'));
    await tester.pumpAndSettle();
    expect(_penBar, findsOneWidget);
    expect(find.byType(EraserOptions), findsNothing);
    handle.dispose();
  });
}
