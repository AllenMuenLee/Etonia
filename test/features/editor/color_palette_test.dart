import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/pen_settings.dart';
import 'package:greatnote/features/editor/sticky/sticky_note.dart';
import 'package:greatnote/features/editor/widgets/color_palette_dialog.dart';
import 'package:greatnote/features/editor/widgets/ink_color_picker.dart';
import 'package:greatnote/features/editor/widgets/sticky_options.dart';
import 'package:greatnote/features/library/library_dialogs.dart';
import 'package:greatnote/features/library/library_models.dart';

void main() {
  group('InkPalette custom color persistence', () {
    test('creates custom InkColor and serializes/deserializes via byId', () {
      const Color color = Color(0xFF1E88E5);
      final InkColor custom = InkPalette.custom(color);
      expect(custom.id, 'custom-ff1e88e5');
      expect(custom.onLightPaper, color);
      expect(custom.onDarkPaper, color);

      final InkColor? restored = InkPalette.byId('custom-ff1e88e5');
      expect(restored, isNotNull);
      expect(restored!.id, 'custom-ff1e88e5');
      expect(restored.onLightPaper, color);
      expect(restored == custom, isTrue);
    });

    test('byId returns null for invalid custom ID format', () {
      expect(InkPalette.byId('custom-xyz'), isNull);
      expect(InkPalette.byId('custom-123'), isNull);
    });
  });

  group('StickyPalette custom color persistence', () {
    test('creates custom StickyPaperColor and resolves via byId', () {
      const Color color = Color(0xFFFFB74D);
      final StickyPaperColor custom = StickyPalette.custom(color);
      expect(custom.id, 'custom-ffffb74d');
      expect(custom.paper, color);

      final StickyPaperColor? restored = StickyPalette.byId('custom-ffffb74d');
      expect(restored, isNotNull);
      expect(restored!.id, 'custom-ffffb74d');
      expect(restored.paper, color);
      expect(restored == custom, isTrue);

      final StickyPaperColor resolved = StickyPalette.resolve(
        'custom-ffffb74d',
      );
      expect(resolved.paper, color);
    });

    test('byId returns null for non-matching or invalid custom id', () {
      expect(StickyPalette.byId('custom-invalid'), isNull);
      expect(StickyPalette.byId(123), isNull);
    });
  });

  group('ColorPaletteDialog widget', () {
    testWidgets('renders HSV area, slider, presets, preview, and hex input', (
      WidgetTester tester,
    ) async {
      Color? pickedColor;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light().copyWith(
            extensions: <ThemeExtension<dynamic>>[AppColors.light],
          ),
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) {
                return ElevatedButton(
                  onPressed: () async {
                    pickedColor = await showColorPaletteDialog(
                      context,
                      initialColor: const Color(0xFF00FF00),
                    );
                  },
                  child: const Text('Open Palette'),
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Palette'));
      await tester.pumpAndSettle();

      expect(find.text('Color palette'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('color-hex-input')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('color-select-button')),
        findsOneWidget,
      );

      // Change color using hex input.
      await tester.enterText(
        find.byKey(const ValueKey<String>('color-hex-input')),
        'FF0000',
      );
      await tester.pumpAndSettle();

      // Tap select.
      await tester.tap(
        find.byKey(const ValueKey<String>('color-select-button')),
      );
      await tester.pumpAndSettle();

      expect(pickedColor, isNotNull);
      expect(pickedColor!.toARGB32(), const Color(0xFFFF0000).toARGB32());
    });
  });

  group('InkSwatches 色盤 integration', () {
    Future<void> pumpSwatches(
      WidgetTester tester,
      List<InkColor> swatches,
      ValueGetter<InkColor> selected,
      ValueChanged<int> onSelected,
      void Function(int, InkColor) onReplaced,
    ) {
      return tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light().copyWith(
            extensions: <ThemeExtension<dynamic>>[AppColors.light],
          ),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
                return InkSwatches(
                  swatches: swatches,
                  selected: selected(),
                  onSelected: (int i) => setState(() => onSelected(i)),
                  onReplaced: (int i, InkColor ink) =>
                      setState(() => onReplaced(i, ink)),
                );
              },
            ),
          ),
        ),
      );
    }

    testWidgets('a first tap picks a swatch; a second, on the one picked, '
        'puts a custom ink in its place', (WidgetTester tester) async {
      final List<InkColor> swatches = List<InkColor>.of(
        PenSettings.defaultSwatches,
      );
      InkColor selected = swatches.first;
      await pumpSwatches(
        tester,
        swatches,
        () => selected,
        (int i) => selected = swatches[i],
        (int i, InkColor ink) {
          swatches[i] = ink;
          selected = ink;
        },
      );
      expect(find.byKey(const ValueKey<String>('ink-swatch-3')), findsNothing);

      // The first tap only picks the ink.
      await tester.tap(find.byKey(const ValueKey<String>('ink-swatch-1')));
      await tester.pumpAndSettle();
      expect(selected, InkPalette.blue);
      expect(
        find.byKey(const ValueKey<String>('color-hex-input')),
        findsNothing,
      );

      // The second opens the palette, and what is chosen there takes the
      // swatch's place.
      await tester.tap(find.byKey(const ValueKey<String>('ink-swatch-1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('color-hex-input')),
        'E91E63',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('color-select-button')),
      );
      await tester.pumpAndSettle();

      expect(selected.id, 'custom-ffe91e63');
      expect(swatches, <InkColor>[InkPalette.ink, selected, InkPalette.red]);
    });
  });

  group('StickyOptions 色盤 integration', () {
    testWidgets('shows color-palette-button and picks a custom paper color', (
      WidgetTester tester,
    ) async {
      StickyNoteSettings settings = const StickyNoteSettings();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light().copyWith(
            extensions: <ThemeExtension<dynamic>>[AppColors.light],
          ),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
                return StickyOptions(
                  settings: settings,
                  onChanged: (StickyNoteSettings next) {
                    setState(() => settings = next);
                  },
                );
              },
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey<String>('color-palette-button')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('color-palette-button')),
      );
      await tester.pumpAndSettle();

      // Type lavender hex code #CE93D8.
      await tester.enterText(
        find.byKey(const ValueKey<String>('color-hex-input')),
        'CE93D8',
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('color-select-button')),
      );
      await tester.pumpAndSettle();

      expect(settings.color.id, 'custom-ffce93d8');
      expect(
        settings.color.paper.toARGB32(),
        const Color(0xFFCE93D8).toARGB32(),
      );
      expect(
        find.byKey(const ValueKey<String>('sticky-color-custom-ffce93d8')),
        findsOneWidget,
      );
    });
  });

  group('FolderColorPicker 色盤 integration', () {
    testWidgets(
      'shows color-palette-button and matches to closest folder color',
      (WidgetTester tester) async {
        FolderColor selected = FolderColor.accent;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.light().copyWith(
              extensions: <ThemeExtension<dynamic>>[AppColors.light],
            ),
            home: Scaffold(
              body: StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) {
                  return FolderColorPicker(
                    selected: selected,
                    onSelected: (FolderColor next) {
                      setState(() => selected = next);
                    },
                  );
                },
              ),
            ),
          ),
        );

        expect(
          find.byKey(const ValueKey<String>('color-palette-button')),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(const ValueKey<String>('color-palette-button')),
        );
        await tester.pumpAndSettle();

        // Type red hex code #D9480F.
        await tester.enterText(
          find.byKey(const ValueKey<String>('color-hex-input')),
          'D9480F',
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const ValueKey<String>('color-select-button')),
        );
        await tester.pumpAndSettle();

        // #D9480F is nearest the Peach highlighter among the six.
        expect(selected, FolderColor.orange);
      },
    );
  });
}
