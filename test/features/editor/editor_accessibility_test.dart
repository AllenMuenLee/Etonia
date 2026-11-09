import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_icons.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/features/editor/widgets/editor_app_bar.dart';
import 'package:greatnote/features/editor/widgets/palette_button.dart';

import '../../helpers/pump_app.dart';

/// Whether keyboard focus is on, or inside, the widget found by [finder].
bool _hasFocus(WidgetTester tester, Finder finder) {
  final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) {
    return false;
  }
  final Element target = tester.element(finder);
  bool found = focused == target;
  focused.visitAncestorElements((Element ancestor) {
    found = found || ancestor == target;
    return !found;
  });
  return found;
}

Future<void> _pumpComponent(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  // Previous and next page are disabled on a one-page note, so they are
  // skipped; the overview remains available at every width.
  List<String> tooltipsAt(TestViewport viewport) {
    if (viewport == TestViewport.compact) {
      return <String>[
        'Open navigation menu',
        'Rename note',
        'Settings',
        'Page overview',
        'Add',
        'Page settings',
        'Pen',
        'Eraser',
        'Select',
      ];
    }
    return <String>[
      'Open navigation menu',
      'Rename note',
      'Settings',
      'Page overview',
      'Pen',
      'Eraser',
      'Select',
      'Turn on AI',
      'Expand toolbar',
      'Add',
      'Page settings',
    ];
  }

  for (final TestViewport viewport in TestViewport.values) {
    final List<String> controlTooltips = tooltipsAt(viewport);
    group(viewport.name, () {
      testWidgets('every control has a tooltip and a 48 px touch target', (
        WidgetTester tester,
      ) async {
        await pumpApp(tester, viewport: viewport);

        for (final String tooltip in controlTooltips) {
          final Finder control = find.byTooltip(tooltip);
          expect(control, findsOneWidget, reason: tooltip);
          final Size size = tester.getSize(control);
          expect(
            size.width,
            greaterThanOrEqualTo(AppSizes.minTouchTarget),
            reason: tooltip,
          );
          expect(
            size.height,
            greaterThanOrEqualTo(AppSizes.minTouchTarget),
            reason: tooltip,
          );
        }
      });

      testWidgets('Tab visits the controls in reading order', (
        WidgetTester tester,
      ) async {
        await pumpApp(tester, viewport: viewport);

        for (final String tooltip in controlTooltips) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          expect(
            _hasFocus(tester, find.byTooltip(tooltip)),
            isTrue,
            reason: 'expected focus on "$tooltip"',
          );
        }
      });
    });
  }

  testWidgets('controls expose semantic labels; the pen starts selected', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await pumpApp(tester);

    expect(
      tester.getSemantics(find.bySemanticsLabel('Pen, Black, 3 px')),
      isSemantics(
        label: 'Pen, Black, 3 px',
        isButton: true,
        isSelected: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Eraser, Area, 24 px')),
      isSemantics(
        isButton: true,
        isSelected: false,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Note title, Untitled note')),
      isSemantics(isButton: true, hasTapAction: true),
    );
    expect(
      tester.getSemantics(find.widgetWithIcon(IconButton, AppIcons.sidebar)),
      isSemantics(tooltip: 'Open navigation menu', isButton: true),
    );
    expect(
      tester.getSemantics(find.widgetWithIcon(IconButton, AppIcons.settings)),
      isSemantics(tooltip: 'Settings', isButton: true),
    );
    expect(find.bySemanticsLabel('Writing surface'), findsOneWidget);
    expect(find.bySemanticsLabel('Tools'), findsOneWidget);
    handle.dispose();
  });

  group('PaletteButton', () {
    testWidgets('shows a focus ring for keyboard focus only', (
      WidgetTester tester,
    ) async {
      await _pumpComponent(
        tester,
        PaletteButton(
          tooltip: 'Sample',
          onPressed: () {},
          child: const Icon(AppIcons.pen),
        ),
      );

      BoxDecoration decoration() {
        final AnimatedContainer body = tester.widget<AnimatedContainer>(
          find.descendant(
            of: find.byType(PaletteButton),
            matching: find.byType(AnimatedContainer),
          ),
        );
        return body.decoration! as BoxDecoration;
      }

      expect((decoration().border! as Border).top.color.a, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      expect((decoration().border! as Border).top.color, AppColors.light.focus);
    });

    testWidgets('selected and unselected states differ', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pumpComponent(
        tester,
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            PaletteButton(
              tooltip: 'On',
              selected: true,
              onPressed: () {},
              child: const Icon(AppIcons.pen),
            ),
            PaletteButton(
              tooltip: 'Off',
              onPressed: () {},
              child: const Icon(AppIcons.pen),
            ),
          ],
        ),
      );

      Color fill(String tooltip) {
        final AnimatedContainer body = tester.widget<AnimatedContainer>(
          find.descendant(
            of: find.byTooltip(tooltip),
            matching: find.byType(AnimatedContainer),
          ),
        );
        return (body.decoration! as BoxDecoration).color!;
      }

      expect(fill('On'), AppColors.light.selected);
      expect(fill('Off').a, 0);
      expect(
        tester.getSemantics(find.bySemanticsLabel('On')),
        isSemantics(isSelected: true),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('Off')),
        isSemantics(isSelected: false),
      );
      handle.dispose();
    });

    testWidgets('is disabled without a callback and reacts when enabled', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      int taps = 0;
      await _pumpComponent(
        tester,
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const PaletteButton(
              tooltip: 'Disabled',
              onPressed: null,
              child: Icon(AppIcons.pen),
            ),
            PaletteButton(
              tooltip: 'Enabled',
              dense: true,
              onPressed: () => taps++,
              child: const Icon(AppIcons.pen),
            ),
          ],
        ),
      );

      expect(
        tester.getSemantics(find.bySemanticsLabel('Disabled')),
        isSemantics(
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
          hasTapAction: false,
        ),
      );
      await tester.tap(find.byTooltip('Disabled'));
      await tester.tap(find.byTooltip('Enabled'));
      await tester.pumpAndSettle();

      expect(taps, 1);
      // Dense shrinks the painted body but never the touch target.
      expect(
        tester.getSize(find.byTooltip('Enabled')),
        const Size.square(AppSizes.minTouchTarget),
      );
      handle.dispose();
    });
  });

  group('EditorAppBar', () {
    testWidgets('invokes its callbacks and disables controls without them', (
      WidgetTester tester,
    ) async {
      final List<String> pressed = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            appBar: EditorAppBar(
              title: 'Untitled note',
              centerTitle: true,
              onMenuPressed: () => pressed.add('menu'),
              onTitlePressed: () => pressed.add('title'),
            ),
          ),
        ),
      );

      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.tap(find.byTooltip('Rename note'));
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();

      expect(pressed, <String>['menu', 'title']);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, AppIcons.settings),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester.getSize(find.byType(EditorAppBar)).height,
        AppSizes.appBarHeight,
      );
    });

    testWidgets('a long title is ellipsized, not overflowed', (
      WidgetTester tester,
    ) async {
      setViewportSize(tester, TestViewport.compact.size);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            appBar: EditorAppBar(
              title: 'A very long note title ' * 8,
              centerTitle: false,
              onTitlePressed: () {},
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });
  });
}
