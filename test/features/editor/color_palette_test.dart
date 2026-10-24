import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
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

  group('InkColorPicker 色盤 integration', () {
    testWidgets('shows color-palette-button and picks a custom ink', (
      WidgetTester tester,
    ) async {
      InkColor selected = InkPalette.ink;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light().copyWith(
            extensions: <ThemeExtension<dynamic>>[AppColors.light],
          ),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
                return InkColorPicker(
                  selected: selected,
                  onSelected: (InkColor next) {
                    setState(() => selected = next);
                  },
                );
              },
            ),
          ),
        ),
      );

      // The color palette button is present.
      expect(
        find.byKey(const ValueKey<String>('color-palette-button')),
        findsOneWidget,
      );

      // Tap the palette button to open the dialog.
      await tester.tap(
        find.byKey(const ValueKey<String>('color-palette-button')),
      );
      await tester.pumpAndSettle();

      // Enter hex #E91E63 (Pink).
      await tester.enterText(
        find.byKey(const ValueKey<String>('color-hex-input')),
        'E91E63',
      );
      await tester.pumpAndSettle();

      // Select it.
      await tester.tap(
        find.byKey(const ValueKey<String>('color-select-button')),
      );
      await tester.pumpAndSettle();

      expect(selected.id, 'custom-ffe91e63');
      expect(
        selected.onLightPaper.toARGB32(),
        const Color(0xFFE91E63).toARGB32(),
      );

      // The custom swatch is now visible in the picker.
      expect(
        find.byKey(const ValueKey<String>('ink-swatch-custom-ffe91e63')),
        findsOneWidget,
      );
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
