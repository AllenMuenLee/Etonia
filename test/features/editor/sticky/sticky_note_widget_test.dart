import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_painter.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/input_defaults.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/sticky/sticky_note.dart';
import 'package:greatnote/features/editor/widgets/sticky_options.dart';
import 'package:greatnote/features/editor/widgets/tool_palette.dart';

import '../../../helpers/editor_harness.dart';
import '../../../helpers/pump_app.dart';

/// Where page position [page] is on screen, through the viewport's zoom.
Offset _global(WidgetTester tester, InkVector page) {
  final RenderBox box = tester.renderObject<RenderBox>(
    find.byType(InkCanvas).first,
  );
  return box.localToGlobal(Offset(page.x, page.y));
}

EditorTool _tool(WidgetTester tester) {
  return tester.widget<ToolPalette>(find.byType(ToolPalette)).tool.value;
}

Future<void> _drawOnPage(
  WidgetTester tester,
  InkVector from,
  InkVector to, {
  PointerDeviceKind kind = PointerDeviceKind.stylus,
  int steps = 10,
}) async {
  final TestGesture gesture = await tester.startGesture(
    _global(tester, from),
    kind: kind,
  );
  for (int i = 1; i <= steps; i++) {
    await gesture.moveTo(
      _global(tester, from + (to - from) * (i / steps)),
      timeStamp: Duration(milliseconds: 8 * i),
    );
  }
  await gesture.up(timeStamp: Duration(milliseconds: 8 * (steps + 1)));
  await tester.pumpAndSettle();
}

Future<void> _tapPage(WidgetTester tester, InkVector at) async {
  final TestGesture gesture = await tester.startGesture(
    _global(tester, at),
    kind: PointerDeviceKind.stylus,
  );
  await gesture.up();
  await tester.pump();
}

/// Picks the Sticky note tool, which opens its options.
Future<void> _pickSticky(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Sticky note'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('choose a color and paper, tap to place, and write on it', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    await _pickSticky(tester);
    expect(_tool(tester), EditorTool.sticky);
    expect(find.byType(StickyOptions), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('sticky-color-blue')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('sticky-paper-grid')));
    await tester.pumpAndSettle();

    await _tapPage(tester, const InkVector(400, 400));
    await tester.pumpAndSettle();

    expect(controller.stickyNotes, hasLength(1));
    final StickyNoteElement note = controller.stickyNotes.single;
    expect(note.center.x, closeTo(400, 1e-6));
    expect(note.center.y, closeTo(400, 1e-6));
    expect(note.colorId, 'blue');
    expect(note.paper, StickyPaperStyle.grid);
    // Back to writing, on the new note.
    expect(_tool(tester), EditorTool.pen);
    expect(controller.editingSticky?.id, note.id);
    expect(controller.strokes, isEmpty);

    await _drawOnPage(
      tester,
      const InkVector(330, 380),
      const InkVector(470, 380),
    );
    expect(controller.strokes, isEmpty);
    expect(controller.stickyNotes.single.strokes, hasLength(1));

    // Writing elsewhere closes the note and writes on the page.
    await _drawOnPage(
      tester,
      const InkVector(100, 700),
      const InkVector(200, 700),
    );
    expect(controller.editingSticky, isNull);
    expect(controller.strokes, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the options remember their choice; defaults are yellow, lined', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    expect(
      find.bySemanticsLabel(RegExp('Sticky note, Yellow, Lined')),
      findsOneWidget,
    );
    await _pickSticky(tester);
    await tester.tap(find.byKey(const ValueKey<String>('sticky-color-pink')));
    await tester.pumpAndSettle();
    await _tapPage(tester, const InkVector(300, 300));
    await tester.pumpAndSettle();
    await _pickSticky(tester);
    // Tapping off the panel places the next note straight away.
    await _tapPage(tester, const InkVector(300, 650));
    await tester.pumpAndSettle();
    expect(
      controller.stickyNotes.map((StickyNoteElement n) => n.colorId),
      <String>['pink', 'pink'],
    );
  });

  testWidgets('a double tap with the pen opens a note, leaving no dots', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    controller.insertStickyNote(
      StickyNoteElement(
        id: 'n',
        center: const InkVector(300, 300),
        size: const Size(240, 180),
        colorId: 'green',
      ),
    );
    controller.exitStickyEditing();
    await tester.pumpAndSettle();

    // A single tap is just a dot, and it belongs to the note.
    await _tapPage(tester, const InkVector(300, 300));
    expect(controller.strokes, isEmpty);
    expect(controller.stickyNotes.single.strokes, hasLength(1));
    await _tapPage(tester, const InkVector(302, 301));
    await tester.pumpAndSettle();
    expect(controller.stickyNotes.single.strokes, isEmpty);
    expect(controller.editingSticky?.id, 'n');
  });

  testWidgets('erasing on the open note erases only its ink', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    controller.insertStickyNote(
      StickyNoteElement(
        id: 'n',
        center: const InkVector(300, 300),
        size: const Size(240, 180),
        colorId: 'yellow',
      ),
    );
    await tester.pumpAndSettle();
    await _drawOnPage(
      tester,
      const InkVector(220, 300),
      const InkVector(380, 300),
    );
    expect(controller.stickyNotes.single.strokes, hasLength(1));
    await tester.tap(find.byTooltip('Eraser'));
    await tester.pumpAndSettle();
    await _drawOnPage(
      tester,
      const InkVector(300, 260),
      const InkVector(300, 340),
    );
    expect(controller.stickyNotes.single.strokes.length, isNot(1));
    expect(controller.stickyNotes, hasLength(1));
  });

  testWidgets('eraser removes ink from a sticky note that is not selected', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);
    controller.insertStickyNote(
      StickyNoteElement(
        id: 'n',
        center: const InkVector(300, 300),
        size: const Size(240, 180),
        colorId: 'yellow',
        strokes: <Stroke>[
          Stroke.fromPoints(
            style: const StrokeStyle(ink: InkPalette.ink, width: 3),
            points: const <InkVector>[InkVector(40, 90), InkVector(200, 90)],
          ),
        ],
      ),
    );
    controller.exitStickyEditing();
    await tester.pumpAndSettle();
    expect(controller.selection, isNull);
    expect(controller.editingSticky, isNull);

    await tester.tap(find.byTooltip('Eraser'));
    await tester.pumpAndSettle();
    await _drawOnPage(
      tester,
      const InkVector(300, 260),
      const InkVector(300, 340),
    );

    expect(controller.stickyNotes.single.strokes.length, isNot(1));
    expect(controller.stickyNotes, hasLength(1));
  });

  testWidgets('Select taps a note, and Delete removes it with its ink', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final InkController controller = await pumpEditor(tester);
    controller.insertStickyNote(
      StickyNoteElement(
        id: 'n',
        center: const InkVector(300, 300),
        size: const Size(240, 180),
        colorId: 'yellow',
        strokes: <Stroke>[
          Stroke.fromPoints(
            style: const StrokeStyle(ink: InkPalette.ink, width: 3),
            points: const <InkVector>[InkVector(10, 10), InkVector(90, 10)],
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.bySemanticsLabel(RegExp('Yellow lined sticky note')),
      findsWidgets,
    );

    await tester.tap(find.byTooltip('Select'));
    await tester.pumpAndSettle();
    expect(controller.editingSticky, isNull);
    await _tapPage(tester, const InkVector(300, 300));
    await tester.pumpAndSettle();
    expect(controller.selection?.stickyIndices, <int>[0]);
    expect(
      find.bySemanticsLabel('Yellow lined sticky note selected'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(controller.stickyNotes, isEmpty);
    controller.undo();
    expect(controller.stickyNotes.single.strokes, hasLength(1));
    handle.dispose();
  });

  testWidgets(
    'choosing the Sticky note tool with a note selected restyles it',
    (WidgetTester tester) async {
      final InkController controller = await pumpEditor(tester);
      controller.insertStickyNote(
        StickyNoteElement(
          id: 'n',
          center: const InkVector(300, 300),
          size: const Size(240, 180),
          colorId: 'yellow',
        ),
      );
      await tester.tap(find.byTooltip('Select'));
      await tester.pumpAndSettle();
      await _tapPage(tester, const InkVector(300, 300));
      await tester.pumpAndSettle();
      await _pickSticky(tester);
      await tester.tap(
        find.byKey(const ValueKey<String>('sticky-paper-dotted')),
      );
      await tester.pumpAndSettle();
      expect(controller.stickyNotes.single.paper, StickyPaperStyle.dotted);
      expect(controller.stickyNotes.single.colorId, 'yellow');
    },
  );

  group('minimize button', () {
    Future<InkController> pumpNote(WidgetTester tester) async {
      final InkController controller = await pumpEditor(tester);
      controller.insertStickyNote(
        StickyNoteElement(
          id: 'n',
          center: const InkVector(300, 300),
          size: const Size(240, 180),
          colorId: 'yellow',
          strokes: <Stroke>[
            Stroke.fromPoints(
              style: const StrokeStyle(ink: InkPalette.ink, width: 3),
              points: const <InkVector>[InkVector(60, 90), InkVector(200, 90)],
            ),
          ],
        ),
      );
      controller.exitStickyEditing();
      await tester.pumpAndSettle();
      return controller;
    }

    // The note's top-left corner is at (180, 210); its button's middle 22
    // in from each edge.
    const InkVector button = InkVector(202, 232);

    testWidgets('a pen tap minimizes the note, and another opens it', (
      WidgetTester tester,
    ) async {
      final InkController controller = await pumpNote(tester);

      await _tapPage(tester, button);
      await tester.pumpAndSettle();
      StickyNoteElement note = controller.stickyNotes.single;
      expect(note.minimized, isTrue);
      expect(note.strokes, hasLength(1));
      expect(controller.strokes, isEmpty);
      // What it covered is the page again.
      expect(controller.stickyAt(const InkVector(300, 300)), isNull);

      await _tapPage(tester, button);
      await tester.pumpAndSettle();
      note = controller.stickyNotes.single;
      expect(note.minimized, isFalse);
      expect(note.strokes, hasLength(1));
      expect(note.center, const InkVector(300, 300));
      expect(controller.strokes, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a mouse click works too, and undo brings the note back', (
      WidgetTester tester,
    ) async {
      final InkController controller = await pumpNote(tester);
      final TestGesture mouse = await tester.startGesture(
        _global(tester, button),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.up();
      await tester.pumpAndSettle();
      expect(controller.stickyNotes.single.minimized, isTrue);

      controller.undo();
      await tester.pumpAndSettle();
      expect(controller.stickyNotes.single.minimized, isFalse);
    });

    testWidgets('a finger tap works when only the pen writes', (
      WidgetTester tester,
    ) async {
      final bool saved = InputDefaults.stylusOnly;
      InputDefaults.stylusOnly = true;
      addTearDown(() => InputDefaults.stylusOnly = saved);
      final InkController controller = InkController(
        stickyNotes: <StickyNoteElement>[
          StickyNoteElement(
            id: 'n',
            center: const InkVector(300, 300),
            size: const Size(240, 180),
            colorId: 'yellow',
          ),
        ],
      );
      addTearDown(controller.dispose);
      await pumpApp(tester, home: EditorScreen(inkController: controller));

      final TestGesture finger = await tester.startGesture(
        _global(tester, button),
        kind: PointerDeviceKind.touch,
      );
      await finger.up();
      await tester.pumpAndSettle();
      expect(controller.stickyNotes.single.minimized, isTrue);
    });

    testWidgets('a stroke begun on the button neither writes nor toggles', (
      WidgetTester tester,
    ) async {
      final InkController controller = await pumpNote(tester);
      await _drawOnPage(tester, button, const InkVector(330, 240));
      final StickyNoteElement note = controller.stickyNotes.single;
      expect(note.minimized, isFalse);
      expect(note.strokes, hasLength(1));
      expect(controller.strokes, isEmpty);
    });

    testWidgets('writing just past the button is ordinary ink on the note', (
      WidgetTester tester,
    ) async {
      final InkController controller = await pumpNote(tester);
      await _drawOnPage(
        tester,
        const InkVector(240, 232),
        const InkVector(330, 232),
      );
      expect(controller.stickyNotes.single.minimized, isFalse);
      expect(controller.stickyNotes.single.strokes, hasLength(2));
    });

    testWidgets('the eraser cannot reach the ink of a minimized note', (
      WidgetTester tester,
    ) async {
      final InkController controller = await pumpNote(tester);
      await _tapPage(tester, button);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Eraser'));
      await tester.pumpAndSettle();
      // Across where its hidden ink would be.
      await _drawOnPage(
        tester,
        const InkVector(300, 260),
        const InkVector(300, 340),
      );
      expect(controller.stickyNotes.single.strokes, hasLength(1));
      expect(controller.stickyNotes.single.minimized, isTrue);
    });

    testWidgets(
      'with the Sticky note tool it toggles on a tap, drags if moved',
      (WidgetTester tester) async {
        final InkController controller = await pumpNote(tester);
        await _pickSticky(tester);
        await _tapPage(tester, button);
        await tester.pumpAndSettle();
        expect(controller.stickyNotes.single.minimized, isTrue);
        expect(controller.stickyNotes, hasLength(1));

        final InkVector corner = controller.stickyNotes.single.corners.first;
        await _drawOnPage(tester, button, const InkVector(402, 432));
        final StickyNoteElement moved = controller.stickyNotes.single;
        expect(moved.minimized, isTrue);
        expect(moved.corners.first.x, closeTo(corner.x + 200, 1e-6));
        expect(moved.corners.first.y, closeTo(corner.y + 200, 1e-6));
      },
    );

    testWidgets('a selected note belongs to its frame', (
      WidgetTester tester,
    ) async {
      final InkController controller = await pumpNote(tester);
      await tester.tap(find.byTooltip('Select'));
      await tester.pumpAndSettle();
      await _tapPage(tester, const InkVector(300, 300));
      await tester.pumpAndSettle();
      expect(controller.selection?.stickyIndices, <int>[0]);
      await _tapPage(tester, button);
      await tester.pumpAndSettle();
      expect(controller.stickyNotes.single.minimized, isFalse);
    });

    testWidgets('assistive technology can minimize and open it', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final InkController controller = await pumpNote(tester);
      void perform(String action, Pattern label) {
        final SemanticsNode node = tester.getSemantics(
          find.bySemanticsLabel(label),
        );
        node.owner!.performAction(
          node.id,
          SemanticsAction.customAction,
          CustomSemanticsAction.getIdentifier(
            CustomSemanticsAction(label: action),
          ),
        );
      }

      perform('Minimize note', RegExp(r'Yellow lined sticky note$'));
      await tester.pumpAndSettle();
      expect(controller.stickyNotes.single.minimized, isTrue);

      perform('Open note', 'Yellow lined sticky note, minimized');
      await tester.pumpAndSettle();
      expect(controller.stickyNotes.single.minimized, isFalse);
      handle.dispose();
    });
  });

  for (final TestViewport viewport in <TestViewport>[
    TestViewport.tabletLandscape,
    TestViewport.compact,
  ]) {
    testWidgets('${viewport.name}: the sticky options fit on screen', (
      WidgetTester tester,
    ) async {
      await pumpEditor(tester, viewport: viewport);
      await _pickSticky(tester);
      final Rect screen = Offset.zero & viewport.size;
      final Rect options = tester.getRect(find.byType(StickyOptions));
      expect(screen.contains(options.topLeft), isTrue);
      expect(screen.contains(options.bottomRight), isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  group('highlighter', () {
    testWidgets('one writing tool, with Pen and Highlighter styles', (
      WidgetTester tester,
    ) async {
      final InkController controller = await pumpEditor(tester);
      // The pen is chosen, its options beside the palette.
      await tester.tap(
        find.byKey(const ValueKey<String>('writing-style-highlighter')),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Highlighter'), findsOneWidget);
      expect(find.byTooltip('Pen'), findsNothing);
      expect(
        find.bySemanticsLabel('Highlighter, Yellow, 12 px'),
        findsOneWidget,
      );
      // The highlighter's own inks at hand.
      expect(find.byTooltip('Change Yellow'), findsOneWidget);
      expect(find.byTooltip('Black'), findsNothing);
      // Pen-only settings are not offered.
      expect(
        find.byKey(const ValueKey<String>('pen-advanced-toggle')),
        findsNothing,
      );
      final Slider slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.min, 4);
      expect(slider.max, 40);

      await _drawOnPage(
        tester,
        const InkVector(100, 300),
        const InkVector(300, 300),
      );
      final Stroke stroke = controller.strokes.single;
      expect(stroke.style.isHighlighter, isTrue);
      expect(stroke.style.opacity, 0.35);
      expect(stroke.style.width, 6);
      expect(stroke.widths, isNull);

      // Back to the pen: its own settings.
      await tester.tap(find.byKey(const ValueKey<String>('writing-style-pen')));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Pen, Black, 3 px'), findsOneWidget);
    });
  });

  group('stylus only', () {
    testWidgets('is on by default: a finger scrolls and does not write', (
      WidgetTester tester,
    ) async {
      final bool saved = InputDefaults.stylusOnly;
      InputDefaults.stylusOnly = true;
      addTearDown(() => InputDefaults.stylusOnly = saved);
      final InkController controller = InkController();
      addTearDown(controller.dispose);
      await pumpApp(tester, home: EditorScreen(inkController: controller));

      await _drawOnPage(
        tester,
        const InkVector(100, 300),
        const InkVector(300, 300),
        kind: PointerDeviceKind.touch,
      );
      expect(controller.strokes, isEmpty);
      await _drawOnPage(
        tester,
        const InkVector(100, 300),
        const InkVector(300, 300),
      );
      expect(controller.strokes, hasLength(1));
    });

    testWidgets('sticky note layer is stacked above completed strokes layer', (
      WidgetTester tester,
    ) async {
      final InkController controller = InkController();
      addTearDown(controller.dispose);
      await pumpApp(tester, home: EditorScreen(inkController: controller));

      final Stack stack = tester.widget<Stack>(
        find
            .descendant(
              of: find.byType(InkCanvas).first,
              matching: find.byType(Stack),
            )
            .first,
      );
      int stickyLayerIndex = -1;
      int completedStrokesIndex = -1;
      for (int i = 0; i < stack.children.length; i++) {
        final Widget child = stack.children[i];
        if (child is RepaintBoundary && child.child is CustomPaint) {
          final CustomPaint cp = child.child! as CustomPaint;
          if (cp.key == const ValueKey<String>('sticky-notes-layer')) {
            stickyLayerIndex = i;
          } else if (cp.painter is CompletedStrokesPainter) {
            completedStrokesIndex = i;
          }
        }
      }
      expect(completedStrokesIndex, isNonNegative);
      expect(stickyLayerIndex, greaterThan(completedStrokesIndex));
    });
  });
}
