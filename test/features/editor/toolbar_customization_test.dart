import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/pen_settings.dart';
import 'package:greatnote/features/editor/ink/ruler.dart';
import 'package:greatnote/features/editor/sticky/sticky_note.dart';
import 'package:greatnote/features/editor/widgets/palette_button.dart';
import 'package:greatnote/features/editor/widgets/sticky_options.dart';
import 'package:greatnote/features/editor/widgets/tool_palette.dart';
import 'package:greatnote/features/editor/widgets/toolbar_customizer.dart';
import 'package:greatnote/features/editor/widgets/toolbar_layout.dart';

const ValueKey<String> _customize = ValueKey<String>('customize-toolbar');

Future<ValueNotifier<ToolbarLayout>> _pumpPalette(
  WidgetTester tester, {
  ToolbarLayout initial = ToolbarLayout.standard,
}) async {
  final ValueNotifier<ToolbarLayout> layout = ValueNotifier<ToolbarLayout>(
    initial,
  );
  final ValueNotifier<EditorTool> tool = ValueNotifier<EditorTool>(
    EditorTool.pen,
  );
  final ValueNotifier<PenSettings> pen = ValueNotifier<PenSettings>(
    PenSettings.defaults(),
  );
  final ValueNotifier<EraserSettings> eraser = ValueNotifier<EraserSettings>(
    EraserSettings.defaults(),
  );
  final ValueNotifier<bool> selectPdf = ValueNotifier<bool>(false);
  final ValueNotifier<bool> aiActive = ValueNotifier<bool>(false);
  final ValueNotifier<StickyNoteSettings> sticky =
      ValueNotifier<StickyNoteSettings>(const StickyNoteSettings());
  final RulerController ruler = RulerController();
  final ToolPaletteController controller = ToolPaletteController();
  addTearDown(() {
    layout.dispose();
    tool.dispose();
    pen.dispose();
    eraser.dispose();
    selectPdf.dispose();
    aiActive.dispose();
    sticky.dispose();
    ruler.dispose();
    controller.expanded.dispose();
  });
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1000, 800);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: ToolPalette(
            tool: tool,
            penSettings: pen,
            eraserSettings: eraser,
            selectPdf: selectPdf,
            aiActive: aiActive,
            onTurnOnAi: () {},
            controller: controller,
            ruler: ruler,
            stickySettings: sticky,
            layout: layout,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return layout;
}

double _x(WidgetTester tester, Finder finder) => tester.getCenter(finder).dx;

Future<void> _unfold(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Expand toolbar'));
  await tester.pumpAndSettle();
}

void main() {
  group('ToolbarLayout', () {
    test('round-trips through JSON', () {
      const ToolbarLayout layout = ToolbarLayout(
        shown: <PaletteItem>[PaletteItem.text, PaletteItem.pen],
        folded: <PaletteItem>[PaletteItem.ruler, PaletteItem.customize],
      );
      expect(ToolbarLayout.fromJson(layout.toJson()), layout);
    });

    test('puts tools it does not mention where they come', () {
      final ToolbarLayout layout = ToolbarLayout.fromJson(<String, Object?>{
        'shown': <String>['eraser', 'nonsense', 'eraser'],
        'folded': <String>['pen'],
        'hidden': <String>['ai', 'text'],
      });
      expect(layout.shown.first, PaletteItem.eraser);
      expect(layout.folded.first, PaletteItem.pen);
      expect(layout.hidden, <PaletteItem>[PaletteItem.ai, PaletteItem.text]);
      // Each tool lands in exactly one place.
      expect(
        layout.shown.length + layout.folded.length + layout.hidden.length,
        PaletteItem.values.length,
      );
    });

    test('folds the sticky note and the customize button by default', () {
      expect(
        ToolbarLayout.standard.folded,
        containsAll(<PaletteItem>[PaletteItem.sticky, PaletteItem.customize]),
      );
      expect(ToolbarLayout.standard.shown, isNot(contains(PaletteItem.sticky)));
    });

    test('keeps a layout saved before the customize button was a tool', () {
      final ToolbarLayout layout = ToolbarLayout.fromJson(<String, Object?>{
        'shown': <String>['pen', 'sticky'],
        'folded': <String>['ruler'],
        'hidden': <String>['ai'],
      });
      expect(layout.shown.take(2), <PaletteItem>[
        PaletteItem.pen,
        PaletteItem.sticky,
      ]);
      expect(layout.folded, contains(PaletteItem.customize));
      expect(layout.hidden, contains(PaletteItem.ai));
    });

    test('never hides the customize button', () {
      expect(
        ToolbarLayout.standard.hide(PaletteItem.customize),
        ToolbarLayout.standard,
      );
      final ToolbarLayout read = ToolbarLayout.fromJson(<String, Object?>{
        'hidden': <String>['customize'],
      });
      expect(read.hidden, isNot(contains(PaletteItem.customize)));
    });

    test('reads anything else as the standard layout', () {
      expect(ToolbarLayout.fromJson('junk'), ToolbarLayout.standard);
    });

    test('hiding and showing move a tool', () {
      final ToolbarLayout hidden = ToolbarLayout.standard.hide(
        PaletteItem.eraser,
      );
      expect(hidden.hidden, <PaletteItem>[PaletteItem.eraser]);
      expect(hidden.show(PaletteItem.eraser).shown.last, PaletteItem.eraser);
    });
  });

  group('palette size', () {
    test('counts the shown tools, the arrow, and the customize button', () {
      final Size standard = ToolPalette.sizeFor(Axis.horizontal);
      final Size fewer = ToolPalette.sizeFor(
        Axis.horizontal,
        tools: ToolbarLayout.standard.hide(PaletteItem.image),
      );
      expect(standard.width - fewer.width, 44);
      // With nothing folded away there is no arrow, and unfolding changes
      // nothing.
      const ToolbarLayout flat = ToolbarLayout(
        shown: <PaletteItem>[PaletteItem.pen],
        folded: <PaletteItem>[],
      );
      expect(
        ToolPalette.sizeFor(Axis.horizontal, tools: flat),
        ToolPalette.sizeFor(Axis.horizontal, expanded: true, tools: flat),
      );
      expect(ToolPalette.unfoldGrowth(Axis.horizontal, tools: flat), 0);
    });
  });

  group('palette', () {
    testWidgets('folds the customize button away behind the arrow', (
      WidgetTester tester,
    ) async {
      await _pumpPalette(tester);
      expect(find.byKey(_customize), findsNothing);
      await _unfold(tester);
      final Finder toggle = find.byKey(
        const ValueKey<String>('palette-extension-toggle'),
      );
      expect(find.byKey(_customize), findsOneWidget);
      expect(_x(tester, find.byKey(_customize)), lessThan(_x(tester, toggle)));
    });

    testWidgets('a folded sticky note fills its own selection', (
      WidgetTester tester,
    ) async {
      await _pumpPalette(tester);
      await _unfold(tester);
      final Finder sticky = find.byKey(
        const ValueKey<String>('sticky-note-tool'),
      );
      await tester.tap(sticky);
      await tester.pumpAndSettle();
      final PaletteButton button = tester.widget<PaletteButton>(sticky);
      expect(button.selected, isTrue);
      expect(button.hostsSelection, isFalse);
      expect(find.byType(StickyOptions), findsOneWidget);
    });

    testWidgets('the customize button can move to the toolbar, not to hidden', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<ToolbarLayout> layout = await _pumpPalette(tester);
      await _unfold(tester);
      await tester.tap(find.byKey(_customize));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('toolbar-visibility-customize')),
        findsNothing,
      );

      void reorder(int from, int to) => tester
          .widget<ReorderableListView>(
            find.byKey(const ValueKey<String>('toolbar-customizer-list')),
          )
          .onReorderItem!(from, to);

      // The headings, the tools, and the hidden group's placeholder, in
      // order: the customize button is at 11, the placeholder at 13.
      reorder(11, 13);
      await tester.pumpAndSettle();
      expect(layout.value, ToolbarLayout.standard);

      reorder(11, 5);
      await tester.pumpAndSettle();
      expect(layout.value.shown, contains(PaletteItem.customize));
      expect(layout.value.folded, isNot(contains(PaletteItem.customize)));
    });

    testWidgets('follows the layout as it changes', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<ToolbarLayout> layout = await _pumpPalette(tester);
      await _unfold(tester);
      final Finder sticky = find.byKey(
        const ValueKey<String>('sticky-note-tool'),
      );
      final Finder image = find.byKey(
        const ValueKey<String>('insert-image-button'),
      );
      expect(_x(tester, image), lessThan(_x(tester, sticky)));

      layout.value = const ToolbarLayout(
        shown: <PaletteItem>[
          PaletteItem.pen,
          PaletteItem.sticky,
          PaletteItem.image,
        ],
        folded: <PaletteItem>[],
      );
      await tester.pumpAndSettle();
      expect(_x(tester, sticky), lessThan(_x(tester, image)));
      expect(
        find.byKey(const ValueKey<String>('ai-mode-toggle')),
        findsNothing,
      );
      // Nothing folded: no arrow.
      expect(
        find.byKey(const ValueKey<String>('palette-extension-toggle')),
        findsNothing,
      );
    });

    testWidgets('opens the customizer, whose eye hides a tool', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<ToolbarLayout> layout = await _pumpPalette(tester);
      await _unfold(tester);
      await tester.tap(find.byKey(_customize));
      await tester.pumpAndSettle();
      expect(find.byType(ToolbarCustomizer), findsOneWidget);
      expect(find.text('Customize toolbar'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('toolbar-visibility-eraser')),
      );
      await tester.pumpAndSettle();
      expect(layout.value.hidden, contains(PaletteItem.eraser));
      expect(layout.value.shown, isNot(contains(PaletteItem.eraser)));

      // Shown again, it goes at the end of the toolbar.
      final Finder eye = find.byKey(
        const ValueKey<String>('toolbar-visibility-eraser'),
      );
      await tester.scrollUntilVisible(
        eye,
        100,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey<String>('toolbar-customizer-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(eye);
      await tester.pumpAndSettle();
      expect(layout.value.shown.last, PaletteItem.eraser);

      await tester.tap(find.byKey(const ValueKey<String>('reset-toolbar')));
      await tester.pumpAndSettle();
      expect(layout.value, ToolbarLayout.standard);
    });
  });
}
