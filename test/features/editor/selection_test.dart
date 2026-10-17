import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_painter.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/ink_selection.dart';
import 'package:greatnote/features/editor/ink/selection_transform.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/widgets/clipboard_shortcuts.dart';
import 'package:greatnote/features/editor/widgets/select_options.dart';
import 'package:greatnote/features/editor/widgets/selection_action_bar.dart';
import 'package:greatnote/features/editor/widgets/tool_palette.dart';

import '../../helpers/editor_harness.dart';
import '../../helpers/pump_app.dart';

const Duration _sampleInterval = Duration(milliseconds: 8);

final InkColor _red = InkPalette.colors.firstWhere(
  (InkColor ink) => ink.id == 'red',
);

/// The corners of the frame around the first two strokes of [_page], in
/// canvas coordinates: top-left, top-right, bottom-right, bottom-left.
const List<Offset> _corners = <Offset>[
  Offset(118, 198),
  Offset(222, 198),
  Offset(222, 242),
  Offset(118, 242),
];
const Offset _center = Offset(170, 220);
const Offset _rotationHandle = Offset(170, 166);

/// A 4 px horizontal stroke at height [y] with a point every 20 px.
Stroke _line(
  double y, {
  double from = 120,
  double to = 220,
  InkColor ink = InkPalette.ink,
}) {
  return Stroke.fromPoints(
    style: StrokeStyle(ink: ink, width: 4),
    points: <InkVector>[
      for (double x = from; x <= to; x += 20) InkVector(x, y),
    ],
  );
}

/// Two lines close together, which [_selectPair] selects, and a third well
/// below them. It fits every reference viewport.
List<Stroke> _page() {
  return <Stroke>[_line(200), _line(240, ink: _red), _line(500)];
}

/// A canvas position in global coordinates.
Offset _at(WidgetTester tester, Offset local) {
  return canvasRect(tester).topLeft + local;
}

Matcher _near(double x, double y) {
  return isA<InkVector>()
      .having((InkVector v) => v.x, 'x', closeTo(x, 1e-6))
      .having((InkVector v) => v.y, 'y', closeTo(y, 1e-6));
}

Future<void> _selectTool(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Select'));
  await tester.pumpAndSettle();
}

/// Moves a pointer from [from] to [to], both in canvas coordinates, in
/// [steps] timed samples.
Future<void> _drag(
  WidgetTester tester,
  Offset from,
  Offset to, {
  int steps = 10,
  PointerDeviceKind kind = PointerDeviceKind.stylus,
}) async {
  final TestGesture gesture = await tester.startGesture(
    _at(tester, from),
    kind: kind,
  );
  for (int i = 1; i <= steps; i++) {
    await gesture.moveTo(
      _at(tester, Offset.lerp(from, to, i / steps)!),
      timeStamp: _sampleInterval * i,
    );
  }
  await gesture.up(timeStamp: _sampleInterval * (steps + 1));
  await tester.pumpAndSettle();
}

/// Starts a freeform lasso around [box], in canvas coordinates, and leaves
/// the pointer down: back where it began, or with [close] false on the last
/// corner, a side short of closing the loop.
Future<TestGesture> _startLasso(
  WidgetTester tester,
  Rect box, {
  PointerDeviceKind kind = PointerDeviceKind.stylus,
  bool close = true,
}) async {
  final List<Offset> path = <Offset>[
    box.topLeft,
    box.topRight,
    box.bottomRight,
    box.bottomLeft,
    if (close) box.topLeft,
  ];
  final TestGesture gesture = await tester.startGesture(
    _at(tester, path.first),
    kind: kind,
  );
  int sample = 0;
  for (int side = 0; side < path.length - 1; side++) {
    for (int i = 1; i <= 8; i++) {
      await gesture.moveTo(
        _at(tester, Offset.lerp(path[side], path[side + 1], i / 8)!),
        timeStamp: _sampleInterval * ++sample,
      );
    }
  }
  await tester.pump();
  return gesture;
}

Future<void> _lasso(
  WidgetTester tester,
  Rect box, {
  PointerDeviceKind kind = PointerDeviceKind.stylus,
}) async {
  final TestGesture gesture = await _startLasso(tester, box, kind: kind);
  await gesture.up();
  await tester.pumpAndSettle();
}

/// Picks the Select tool and lassos the first two strokes of [_page].
Future<void> _selectPair(WidgetTester tester, InkController controller) async {
  await _selectTool(tester);
  await _lasso(tester, const Rect.fromLTRB(100, 170, 240, 270));
  expect(controller.selection?.indices, <int>[0, 1]);
}

Future<void> _chord(
  WidgetTester tester,
  LogicalKeyboardKey modifier,
  LogicalKeyboardKey key,
) async {
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(modifier);
  await tester.pumpAndSettle();
}

/// The selected state of a palette button, as assistive technology sees it.
bool _isSelected(WidgetTester tester, String label) {
  return isSemantics(isSelected: true).matches(
    tester.getSemantics(find.bySemanticsLabel(RegExp('^$label'))),
    <dynamic, dynamic>{},
  );
}

/// The action bar: the box around Copy, Cut, and AI.
Rect _actionBarRect(WidgetTester tester) {
  return tester.getRect(
    find
        .ancestor(
          of: find.byTooltip('Copy'),
          matching: find.byType(DecoratedBox),
        )
        .first,
  );
}

/// Dismisses an open popover by tapping the app bar background.
Future<void> _dismiss(WidgetTester tester) async {
  await tester.tapAt(const Offset(150, 4));
  await tester.pumpAndSettle();
}

void main() {
  for (final TestViewport viewport in TestViewport.values) {
    group(viewport.name, () {
      testWidgets('exactly one of pen, eraser, and select is selected', (
        WidgetTester tester,
      ) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        await pumpEditor(tester, viewport: viewport);
        List<bool> selected() => <bool>[
          _isSelected(tester, 'Pen'),
          _isSelected(tester, 'Eraser'),
          _isSelected(tester, 'Select'),
        ];

        expect(find.byTooltip('Select'), findsOneWidget);
        expect(selected(), <bool>[true, false, false]);

        await _selectTool(tester);
        expect(selected(), <bool>[false, false, true]);
        // The first press only selects; it does not open the options.
        expect(find.byType(SelectOptions), findsNothing);

        await tester.tap(find.byTooltip('Eraser'));
        await tester.pumpAndSettle();
        expect(selected(), <bool>[false, true, false]);

        await _selectTool(tester);
        await tester.tap(find.byTooltip('Pen'));
        await tester.pumpAndSettle();
        expect(selected(), <bool>[true, false, false]);
        expect(tester.takeException(), isNull);
        handle.dispose();
      });

      testWidgets('a lasso selects what it overlaps and draws no ink', (
        WidgetTester tester,
      ) async {
        final InkController controller = await pumpEditor(
          tester,
          viewport: viewport,
          strokes: _page(),
        );
        final List<Stroke> before = List<Stroke>.of(controller.strokes);

        await _selectPair(tester, controller);

        expect(controller.strokes, before);
        expect(controller.activeStroke, isNull);
        expect(controller.activeLasso, isNull);
        final SelectionFrame frame = controller.selection!.frame;
        expect(frame.center, const InkVector(170, 220));
        expect(frame.halfWidth, 52);
        expect(frame.halfHeight, 22);
        // Copy and Cut appear beside the frame, on the page.
        final Rect bar = _actionBarRect(tester);
        final Rect canvas = canvasRect(tester);
        expect(canvas.contains(bar.topLeft), isTrue);
        expect(canvas.contains(bar.bottomRight), isTrue);
        expect(bar.bottom, lessThan(canvas.top + 166));
        expect(tester.takeException(), isNull);
      });

      testWidgets(
        'the options hold Paste, disabled until something is copied',
        (WidgetTester tester) async {
          final SemanticsHandle handle = tester.ensureSemantics();
          final InkController controller = await pumpEditor(
            tester,
            viewport: viewport,
            strokes: _page(),
          );
          await _selectPair(tester, controller);

          // Select is already selected: this press opens its options.
          await _selectTool(tester);

          final Rect screen = Offset.zero & viewport.size;
          final Rect options = tester.getRect(find.byType(SelectOptions));
          expect(screen.contains(options.topLeft), isTrue);
          expect(screen.contains(options.bottomRight), isTrue);
          expect(
            tester.getSemantics(find.bySemanticsLabel('Paste')),
            isSemantics(
              label: 'Paste',
              isButton: true,
              hasEnabledState: true,
              isEnabled: false,
            ),
          );
          await tester.tap(find.text('Paste'));
          await tester.pumpAndSettle();
          expect(controller.strokes.length, 3);
          await _dismiss(tester);

          await tester.tap(find.byTooltip('Copy'));
          await tester.pumpAndSettle();
          await _selectTool(tester);

          expect(
            tester.getSemantics(find.bySemanticsLabel('Paste')),
            isSemantics(
              label: 'Paste',
              isButton: true,
              hasEnabledState: true,
              isEnabled: true,
              hasTapAction: true,
              isFocusable: true,
            ),
          );
          await tester.tap(find.text('Paste'));
          await tester.pumpAndSettle();

          // It pasted, selected the copies, and closed.
          expect(find.byType(SelectOptions), findsNothing);
          expect(controller.strokes.length, 5);
          expect(controller.selection!.indices, <int>[3, 4]);
          expect(controller.strokes[3].points.first, const InkVector(144, 224));
          expect(controller.strokes[4].style.ink, _red);
          expect(_isSelected(tester, 'Select'), isTrue);
          expect(tester.takeException(), isNull);
          handle.dispose();
        },
      );
    });
  }

  /// How many pixels from ([from], y) to ([to], y), in canvas coordinates,
  /// are not bare paper.
  Future<int> inked(
    WidgetTester tester,
    double y,
    double from,
    double to,
  ) async {
    final ScreenPixels pixels = await captureScreen(tester);
    final Matcher paper = isSameColorAs(AppColors.light.writingSurface);
    int count = 0;
    for (double x = from; x < to; x++) {
      if (!paper.matches(
        pixels.at(_at(tester, Offset(x, y))),
        <dynamic, dynamic>{},
      )) {
        count++;
      }
    }
    return count;
  }

  testWidgets('the lasso is dashed and open, and selects once nearly closed', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester, strokes: _page());
    await _selectTool(tester);
    final Matcher paper = isSameColorAs(AppColors.light.writingSurface);
    // Halfway down the side the loop has not drawn yet.
    final Offset onGap = _at(tester, const Offset(100, 220));

    final TestGesture gesture = await _startLasso(
      tester,
      const Rect.fromLTRB(100, 170, 240, 270),
      close: false,
    );

    final LassoGesture lasso = controller.activeLasso!;
    expect(lasso.shape, LassoShape.freeform);
    expect(lasso.isClosed, isFalse);
    expect(lasso.points.first, const InkVector(100, 170));
    expect(lasso.points.last, const InkVector(100, 270));
    expect(lasso.points.length, lessThan(30));
    // Dashes of 6 px with gaps of 4 px along the 140 px top side: some of
    // it is drawn and some of it is not.
    final int drawn = await inked(tester, 170, 100, 240);
    expect(drawn, greaterThan(60));
    expect(drawn, lessThan(110));
    // No line is drawn back to the start to close the loop.
    expect((await captureScreen(tester)).at(onGap), paper);
    expect(controller.selection, isNull);

    // Up the last side, to within a few pixels of the start.
    await gesture.moveTo(
      _at(tester, const Offset(100, 176)),
      timeStamp: _sampleInterval * 40,
    );
    expect(lasso.isClosed, isTrue);
    await gesture.up();
    await tester.pumpAndSettle();

    // Selected, and nothing of the outline was left as ink.
    expect(controller.selection!.indices, <int>[0, 1]);
    expect(controller.activeLasso, isNull);
    expect(controller.strokes.length, 3);
    // Left of the rotation handle, where only the outline had been.
    expect(await inked(tester, 170, 100, 150), 0);
  });

  testWidgets('a loop left open selects nothing', (WidgetTester tester) async {
    final InkController controller = await pumpEditor(tester, strokes: _page());
    await _selectPair(tester, controller);

    // Three sides of a box around the third stroke; the fourth is too
    // long a gap to count as closed.
    final TestGesture gesture = await _startLasso(
      tester,
      const Rect.fromLTRB(100, 440, 240, 560),
      close: false,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(controller.selection, isNull);
    expect(controller.strokes.length, 3);
    expect(find.byTooltip('Copy'), findsNothing);
  });

  testWidgets('a diagonal drag selects a rectangle, in either direction', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester, strokes: _page());
    await _selectTool(tester);

    // Top-left to bottom-right, held at the end.
    final TestGesture gesture = await tester.startGesture(
      _at(tester, const Offset(100, 170)),
      kind: PointerDeviceKind.stylus,
    );
    for (int i = 1; i <= 10; i++) {
      await gesture.moveTo(
        _at(tester, Offset(100 + 14.0 * i, 170 + 10.0 * i)),
        timeStamp: _sampleInterval * i,
      );
    }
    await tester.pump();

    final LassoGesture lasso = controller.activeLasso!;
    expect(lasso.shape, LassoShape.rectangle);
    expect(lasso.outline, const <InkVector>[
      InkVector(100, 170),
      InkVector(240, 170),
      InkVector(240, 270),
      InkVector(100, 270),
    ]);
    // The rectangle is what is shown: dashes along its top and bottom
    // sides, where the pointer never went.
    for (final double y in <double>[170, 270]) {
      final int drawn = await inked(tester, y, 100, 240);
      expect(drawn, greaterThan(60), reason: 'y = $y');
      expect(drawn, lessThan(110), reason: 'y = $y');
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.selection!.indices, <int>[0, 1]);
    expect(controller.strokes.length, 3);

    // Top-right to bottom-left, around the third stroke.
    await _drag(tester, const Offset(240, 470), const Offset(100, 530));
    expect(controller.selection!.indices, <int>[2]);

    // And upwards, bottom-right to top-left.
    await _drag(tester, const Offset(240, 270), const Offset(100, 170));
    expect(controller.selection!.indices, <int>[0, 1]);
    expect(controller.strokes.length, 3);
  });

  group('holding the pointer still', () {
    const Offset spot = Offset(400, 600);

    Future<TestGesture> hold(WidgetTester tester, Offset local) async {
      final TestGesture gesture = await tester.startGesture(
        _at(tester, local),
        kind: PointerDeviceKind.stylus,
      );
      await tester.pump(const Duration(milliseconds: 600));
      return gesture;
    }

    testWidgets('offers Paste there, and pastes centered on that spot', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final InkController controller = await pumpEditor(
        tester,
        strokes: _page(),
      );
      await _selectPair(tester, controller);
      await tester.tap(find.byTooltip('Copy'));
      await tester.pumpAndSettle();
      final InkSelection selection = controller.selection!;
      expect(find.byTooltip('Paste'), findsNothing);

      final TestGesture gesture = await hold(tester, spot);

      // The drag the hold began was dropped: nothing was deselected.
      expect(controller.activePointer, isNull);
      expect(controller.selection, same(selection));
      expect(
        tester.getSemantics(find.bySemanticsLabel('Paste')),
        isSemantics(label: 'Paste', isButton: true, hasTapAction: true),
      );
      // Just above the held point, on the page.
      final Rect button = tester.getRect(find.byTooltip('Paste'));
      final Offset held = _at(tester, spot);
      expect(button.center.dx, held.dx);
      expect(button.bottom, lessThan(held.dy));
      expect(held.dy - button.bottom, lessThan(20));
      // Letting go, or moving on afterwards, changes nothing.
      await gesture.moveBy(const Offset(50, 50), timeStamp: _sampleInterval);
      await gesture.up(timeStamp: _sampleInterval * 2);
      await tester.pumpAndSettle();
      expect(controller.selection, same(selection));
      expect(find.byTooltip('Paste'), findsOneWidget);

      await tester.tap(find.byTooltip('Paste'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Paste'), findsNothing);
      expect(controller.strokes.length, 5);
      expect(controller.selection!.indices, <int>[3, 4]);
      expect(controller.selection!.frame.center, const InkVector(400, 600));
      // The copied frame was centered on (170, 220).
      expect(controller.strokes[3].points.first, const InkVector(350, 580));
      expect(controller.strokes[4].style.ink, _red);
      expect(find.byTooltip('Copy'), findsOneWidget);
      expect(tester.takeException(), isNull);
      handle.dispose();
    });

    testWidgets('offers nothing while the clipboard is empty', (
      WidgetTester tester,
    ) async {
      final InkController controller = await pumpEditor(
        tester,
        strokes: _page(),
      );
      await _selectPair(tester, controller);

      final TestGesture gesture = await hold(tester, spot);

      expect(find.byTooltip('Paste'), findsNothing);
      // It is still an ordinary tap on empty paper.
      expect(controller.activeLasso, isNotNull);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(controller.selection, isNull);
    });

    testWidgets('a pointer that moves away is a drag, not a hold', (
      WidgetTester tester,
    ) async {
      final InkController controller = await pumpEditor(
        tester,
        strokes: _page(),
      );
      await _selectPair(tester, controller);
      await tester.tap(find.byTooltip('Copy'));
      await tester.pumpAndSettle();

      final TestGesture drag = await tester.startGesture(
        _at(tester, const Offset(240, 470)),
        kind: PointerDeviceKind.stylus,
      );
      await drag.moveBy(const Offset(-140, 60), timeStamp: _sampleInterval);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byTooltip('Paste'), findsNothing);
      expect(controller.activeLasso, isNotNull);
      await drag.up(timeStamp: _sampleInterval * 100);
      await tester.pumpAndSettle();
      expect(controller.selection!.indices, <int>[2]);

      // A little drift inside the slop is still a hold.
      final TestGesture shaky = await tester.startGesture(
        _at(tester, spot),
        kind: PointerDeviceKind.touch,
      );
      await shaky.moveBy(const Offset(4, 3), timeStamp: _sampleInterval);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byTooltip('Paste'), findsOneWidget);
      await shaky.up();

      // A quick tap is not.
      await tester.tapAt(_at(tester, const Offset(300, 650)));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byTooltip('Paste'), findsNothing);
    });

    testWidgets('works inside the selection frame without moving it', (
      WidgetTester tester,
    ) async {
      final InkController controller = await pumpEditor(
        tester,
        strokes: _page(),
      );
      final List<Stroke> before = List<Stroke>.of(controller.strokes);
      await _selectPair(tester, controller);
      await tester.tap(find.byTooltip('Copy'));
      await tester.pumpAndSettle();

      final TestGesture gesture = await hold(tester, _center);

      expect(find.byTooltip('Paste'), findsOneWidget);
      expect(controller.activeTransform, isNull);
      expect(controller.strokes, before);
      await gesture.up();
    });

    testWidgets('the offer goes away with the next touch or a tool change', (
      WidgetTester tester,
    ) async {
      final InkController controller = await pumpEditor(
        tester,
        strokes: _page(),
      );
      await _selectPair(tester, controller);
      await tester.tap(find.byTooltip('Copy'));
      await tester.pumpAndSettle();

      TestGesture gesture = await hold(tester, spot);
      await gesture.up();
      expect(find.byTooltip('Paste'), findsOneWidget);
      await tester.tapAt(_at(tester, const Offset(300, 650)));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Paste'), findsNothing);
      expect(controller.strokes.length, 3);

      gesture = await hold(tester, spot);
      await gesture.up();
      expect(find.byTooltip('Paste'), findsOneWidget);
      await tester.tap(find.byTooltip('Pen'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Paste'), findsNothing);

      // Holding the pen does not offer it: it writes.
      gesture = await hold(tester, spot);
      expect(find.byTooltip('Paste'), findsNothing);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(controller.strokes.length, 4);
      expect(controller.canPaste, isTrue);
    });

    testWidgets('near an edge the offer stays on the page', (
      WidgetTester tester,
    ) async {
      final InkController controller = await pumpEditor(
        tester,
        strokes: _page(),
      );
      await _selectPair(tester, controller);
      await tester.tap(find.byTooltip('Copy'));
      await tester.pumpAndSettle();
      final Rect canvas = canvasRect(tester);

      for (final Offset corner in <Offset>[
        const Offset(3, 3),
        Offset(canvas.width - 3, 3),
        Offset(3, canvas.height - 3),
        Offset(canvas.width - 3, canvas.height - 3),
      ]) {
        final TestGesture gesture = await hold(tester, corner);
        await gesture.up();
        await tester.pumpAndSettle();

        final Rect button = tester.getRect(find.byTooltip('Paste'));
        expect(
          button.left,
          greaterThanOrEqualTo(canvas.left),
          reason: '$corner',
        );
        expect(button.top, greaterThanOrEqualTo(canvas.top), reason: '$corner');
        expect(
          button.right,
          lessThanOrEqualTo(canvas.right),
          reason: '$corner',
        );
        expect(
          button.bottom,
          lessThanOrEqualTo(canvas.bottom),
          reason: '$corner',
        );
      }
      expect(controller.strokes.length, 3);
    });
  });

  testWidgets('tapping empty paper clears the selection and leaves no dot', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester, strokes: _page());
    await _selectPair(tester, controller);
    expect(find.byTooltip('Copy'), findsOneWidget);

    await tester.tapAt(_at(tester, const Offset(300, 600)));
    await tester.pumpAndSettle();

    expect(controller.selection, isNull);
    expect(controller.strokes.length, 3);
    expect(find.byTooltip('Copy'), findsNothing);
    expect(find.byTooltip('Cut'), findsNothing);
  });

  testWidgets('a finger and a mouse can lasso; a secondary button cannot', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester, strokes: _page());
    await _selectTool(tester);
    const Rect pair = Rect.fromLTRB(100, 170, 240, 270);

    final TestGesture secondary = await tester.startGesture(
      _at(tester, pair.topLeft),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    expect(controller.activeLasso, isNull);
    await secondary.up();

    await _lasso(tester, pair, kind: PointerDeviceKind.touch);
    expect(controller.selection!.indices, <int>[0, 1]);

    await _lasso(
      tester,
      const Rect.fromLTRB(100, 470, 240, 530),
      kind: PointerDeviceKind.mouse,
    );
    expect(controller.selection!.indices, <int>[2]);
  });

  testWidgets('dragging inside the frame moves every selected stroke', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester, strokes: _page());
    final List<Stroke> before = List<Stroke>.of(controller.strokes);
    await _selectPair(tester, controller);

    // The press lands on ink, which does not get in the way.
    await _drag(tester, const Offset(170, 200), const Offset(230, 250));

    for (final int index in <int>[0, 1]) {
      final Stroke moved = controller.strokes[index];
      for (int i = 0; i < moved.points.length; i++) {
        expect(
          moved.points[i],
          before[index].points[i] + const InkVector(60, 50),
        );
      }
      expect(moved.style, same(before[index].style));
      expect(moved.source, StrokeSource.derived);
    }
    expect(controller.strokes[2], same(before[2]));
    expect(controller.strokes.length, 3);
    // Still selected, and the actions came back beside the moved frame.
    expect(controller.selection!.indices, <int>[0, 1]);
    expect(controller.selection!.frame.center, const InkVector(230, 270));
    expect(find.byTooltip('Copy'), findsOneWidget);
    final ScreenPixels pixels = await captureScreen(tester);
    expect(
      pixels.at(_at(tester, const Offset(200, 250))),
      isSameColorAs(InkPalette.ink.onLightPaper),
    );
    // Clear of the action bar, which now floats above the moved frame.
    expect(
      pixels.at(_at(tester, const Offset(130, 200))),
      isSameColorAs(AppColors.light.writingSurface),
    );
  });

  for (int corner = 0; corner < 4; corner++) {
    testWidgets('corner $corner scales about the corner opposite it', (
      WidgetTester tester,
    ) async {
      final InkController controller = await pumpEditor(
        tester,
        strokes: _page(),
      );
      final List<Stroke> before = List<Stroke>.of(controller.strokes);
      await _selectPair(tester, controller);
      final Offset grabbed = _corners[corner];
      final Offset fixed = _corners[(corner + 2) % 4];

      // Out to twice the distance from the fixed corner.
      await _drag(tester, grabbed, grabbed + (grabbed - fixed));

      for (final int index in <int>[0, 1]) {
        final Stroke scaled = controller.strokes[index];
        for (int i = 0; i < scaled.points.length; i++) {
          final InkVector point = before[index].points[i];
          expect(
            scaled.points[i],
            _near(
              fixed.dx + 2 * (point.x - fixed.dx),
              fixed.dy + 2 * (point.y - fixed.dy),
            ),
          );
        }
        expect(scaled.style.width, closeTo(8, 1e-9));
        expect(scaled.style.ink, before[index].style.ink);
      }
      expect(controller.strokes[2], same(before[2]));
      final SelectionFrame frame = controller.selection!.frame;
      expect(frame.corners[(corner + 2) % 4], _near(fixed.dx, fixed.dy));
      expect(frame.halfWidth, closeTo(104, 1e-6));
      expect(frame.halfHeight, closeTo(44, 1e-6));
    });
  }

  testWidgets('the rotation handle turns the group about its center', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester, strokes: _page());
    final List<Stroke> before = List<Stroke>.of(controller.strokes);
    await _selectPair(tester, controller);

    // From above the center round to its right: a quarter turn.
    await _drag(tester, _rotationHandle, _center + const Offset(54, 0));

    for (final int index in <int>[0, 1]) {
      final Stroke turned = controller.strokes[index];
      for (int i = 0; i < turned.points.length; i++) {
        final InkVector point = before[index].points[i];
        expect(
          turned.points[i],
          _near(
            _center.dx - (point.y - _center.dy),
            _center.dy + (point.x - _center.dx),
          ),
        );
      }
      expect(turned.style, same(before[index].style));
    }
    expect(controller.strokes[0].points.first, _near(190, 170));
    expect(controller.strokes[2], same(before[2]));
    final SelectionFrame frame = controller.selection!.frame;
    expect(frame.angle, closeTo(math.pi / 2, 1e-9));
    expect(frame.halfWidth, 52);
    expect(frame.halfHeight, 22);

    // The turned frame's corner still scales about its opposite.
    final List<InkVector> corners = frame.corners;
    final Offset grabbed = Offset(corners[0].x, corners[0].y);
    final Offset fixed = Offset(corners[2].x, corners[2].y);
    await _drag(tester, grabbed, fixed + (grabbed - fixed) * 0.5);

    final SelectionFrame scaled = controller.selection!.frame;
    expect(scaled.angle, closeTo(math.pi / 2, 1e-9));
    expect(scaled.corners[2], _near(fixed.dx, fixed.dy));
    expect(scaled.halfWidth, closeTo(26, 1e-6));
    expect(controller.strokes[0].style.width, closeTo(2, 1e-9));
  });

  testWidgets('a preview repaints only the selection layer', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester, strokes: _page());
    final List<Stroke> before = List<Stroke>.of(controller.strokes);
    await _selectPair(tester, controller);
    int completed = 0;
    int selection = 0;
    controller.completedStrokesListenable.addListener(() => completed++);
    controller.selectionListenable.addListener(() => selection++);
    final TestGesture gesture = await tester.startGesture(
      _at(tester, _center),
      kind: PointerDeviceKind.stylus,
    );
    await tester.pump();
    // The actions step aside while the frame is dragged.
    expect(find.byTooltip('Copy'), findsNothing);

    int rebuilds = 0;
    debugOnRebuildDirtyWidget = (Element element, bool builtOnce) => rebuilds++;
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    for (int i = 1; i <= 20; i++) {
      await gesture.moveBy(
        const Offset(3, 2.5),
        timeStamp: _sampleInterval * i,
      );
      await tester.pump();
    }
    debugOnRebuildDirtyWidget = null;

    // Mid-gesture: nothing rebuilt, no ink repainted, no stroke replaced,
    // and yet the ink is already drawn 60 px across and 50 px down.
    expect(rebuilds, 0);
    expect(completed, 0);
    expect(selection, 21);
    expect(controller.strokes, before);
    expect(
      controller.activeTransform!.transform,
      InkTransform.translation(const InkVector(60, 50)),
    );
    final ScreenPixels pixels = await captureScreen(tester);
    expect(
      pixels.at(_at(tester, const Offset(200, 250))),
      isSameColorAs(InkPalette.ink.onLightPaper),
    );
    expect(
      pixels.at(_at(tester, const Offset(200, 290))),
      isSameColorAs(_red.onLightPaper),
    );
    expect(
      pixels.at(_at(tester, const Offset(200, 200))),
      isSameColorAs(AppColors.light.writingSurface),
    );

    await gesture.up(timeStamp: _sampleInterval * 21);
    await tester.pumpAndSettle();

    // The paths were rebuilt once, at the end.
    expect(completed, 1);
    expect(controller.strokes[0], isNot(same(before[0])));
    expect(controller.strokes[0].points.first, const InkVector(180, 250));
    expect(find.byTooltip('Copy'), findsOneWidget);
  });

  testWidgets('selected strokes are drawn once, by the selection layer', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester, strokes: _page());
    await _selectPair(tester, controller);

    // Painted from the selection layer alone, the ink is still there.
    final ScreenPixels pixels = await captureScreen(tester);
    expect(
      pixels.at(_at(tester, const Offset(170, 200))),
      isSameColorAs(InkPalette.ink.onLightPaper),
    );
    expect(
      pixels.at(_at(tester, const Offset(170, 240))),
      isSameColorAs(_red.onLightPaper),
    );
    expect(
      pixels.at(_at(tester, const Offset(170, 500))),
      isSameColorAs(InkPalette.ink.onLightPaper),
    );
    // The frame is on screen too: a handle's ring, and the stem up to the
    // rotation handle.
    final Matcher paper = isSameColorAs(AppColors.light.writingSurface);
    expect(
      pixels.at(_at(tester, _corners[0] + const Offset(6, 0))),
      isNot(paper),
    );
    expect(pixels.at(_at(tester, const Offset(170, 180))), isNot(paper));
    expect(pixels.at(_at(tester, const Offset(150, 180))), paper);
    expect(
      find.byKey(const ValueKey<String>('selection-layer')),
      findsOneWidget,
    );
  });

  testWidgets('Copy and Cut act on the selection without touching the page', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final InkController controller = await pumpEditor(tester, strokes: _page());
    final List<Stroke> before = List<Stroke>.of(controller.strokes);
    await _selectPair(tester, controller);
    final InkSelection selection = controller.selection!;
    for (final String label in <String>['Copy', 'Cut']) {
      expect(
        tester.getSemantics(find.bySemanticsLabel(label)),
        isSemantics(
          label: label,
          isButton: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      final Size size = tester.getSize(find.byTooltip(label));
      expect(size.width, greaterThanOrEqualTo(AppSizes.minTouchTarget));
      expect(size.height, greaterThanOrEqualTo(AppSizes.minTouchTarget));
    }

    // A pointer held on a button, and one on the bar's own padding, start
    // nothing on the canvas underneath.
    final Rect bar = _actionBarRect(tester);
    for (final Offset position in <Offset>[
      tester.getCenter(find.byTooltip('Copy')),
      bar.topLeft + const Offset(2, 2),
    ]) {
      final TestGesture press = await tester.startGesture(position);
      await press.moveBy(const Offset(4, 30));
      expect(controller.activePointer, isNull);
      expect(controller.activeLasso, isNull);
      expect(controller.activeTransform, isNull);
      await press.cancel();
      await tester.pumpAndSettle();
    }
    expect(controller.selection, same(selection));
    expect(controller.canPaste, isFalse);

    await tester.tap(find.byTooltip('Copy'));
    await tester.pumpAndSettle();

    expect(controller.canPaste, isTrue);
    expect(controller.strokes, before);
    expect(controller.selection, same(selection));
    expect(find.byTooltip('Copy'), findsOneWidget);

    await tester.tap(find.byTooltip('Cut'));
    await tester.pumpAndSettle();

    expect(controller.strokes.single, same(before[2]));
    expect(controller.selection, isNull);
    expect(controller.clipboard!.strokes.length, 2);
    expect(find.byTooltip('Cut'), findsNothing);
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  testWidgets('Copy and Cut can be reached and pressed from the keyboard', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester, strokes: _page());
    await _selectPair(tester, controller);

    bool focused(String tooltip) {
      final BuildContext? context = FocusManager.instance.primaryFocus?.context;
      bool found = false;
      context?.visitAncestorElements((Element ancestor) {
        found =
            ancestor.widget is Tooltip &&
            (ancestor.widget as Tooltip).message == tooltip;
        return !found;
      });
      return found;
    }

    for (int i = 0; i < 12 && !focused('Copy'); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(focused('Copy'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(focused('Cut'), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(controller.strokes.length, 1);
    expect(controller.canPaste, isTrue);
  });

  testWidgets('the tap that dismisses the options starts no lasso or move', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester, strokes: _page());
    final List<Stroke> before = List<Stroke>.of(controller.strokes);
    await _selectPair(tester, controller);
    final InkSelection selection = controller.selection!;
    await _selectTool(tester);
    final ToolPaletteController palette = tester
        .widget<ToolPalette>(find.byType(ToolPalette))
        .controller!;
    expect(palette.selectMenu.isOpen, isTrue);
    expect(palette.hasOpenPopover, isTrue);

    // Once inside the frame, which would move it, and once on empty paper,
    // which would clear it.
    await _drag(tester, _center, _center + const Offset(80, 80));

    expect(find.byType(SelectOptions), findsNothing);
    expect(palette.hasOpenPopover, isFalse);
    expect(controller.selection, same(selection));
    expect(controller.strokes, before);

    await _selectTool(tester);
    await tester.tapAt(_at(tester, const Offset(300, 600)));
    await tester.pumpAndSettle();
    expect(controller.selection, same(selection));

    // The next touch does act.
    await tester.tapAt(_at(tester, const Offset(300, 600)));
    await tester.pumpAndSettle();
    expect(controller.selection, isNull);
  });

  group('keyboard shortcuts', () {
    testWidgets('Ctrl and Meta with C, X, and V copy, cut, and paste', (
      WidgetTester tester,
    ) async {
      final InkController controller = await pumpEditor(
        tester,
        strokes: _page(),
      );
      await _selectPair(tester, controller);

      await _chord(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.keyC,
      );
      expect(controller.canPaste, isTrue);
      expect(controller.strokes.length, 3);

      await _chord(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.keyV,
      );
      expect(controller.strokes.length, 5);
      expect(controller.selection!.indices, <int>[3, 4]);

      // The iPad keyboard's Command key.
      await _chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.keyX,
      );
      expect(controller.strokes.length, 3);
      expect(controller.selection, isNull);

      await _chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.keyV,
      );
      await _chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.keyV,
      );
      expect(controller.strokes.length, 7);
      // Cut took the first paste; these are one and two offsets from it.
      expect(controller.strokes[3].points.first, const InkVector(168, 248));
      expect(controller.strokes[5].points.first, const InkVector(192, 272));

      await _chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.keyC,
      );
      expect(controller.clipboard!.strokes.first.points.first.x, 192);
      expect(tester.takeException(), isNull);
    });

    testWidgets('other chords, and the bare keys, do nothing', (
      WidgetTester tester,
    ) async {
      final InkController controller = await pumpEditor(
        tester,
        strokes: _page(),
      );
      await _selectPair(tester, controller);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
      await _chord(tester, LogicalKeyboardKey.altLeft, LogicalKeyboardKey.keyX);
      await _chord(
        tester,
        LogicalKeyboardKey.shiftLeft,
        LogicalKeyboardKey.keyC,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await _chord(
        tester,
        LogicalKeyboardKey.shiftLeft,
        LogicalKeyboardKey.keyX,
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      expect(controller.strokes.length, 3);
      expect(controller.canPaste, isFalse);

      // Nothing selected, nothing copied: the shortcuts are no-ops.
      await tester.tapAt(_at(tester, const Offset(300, 600)));
      await tester.pumpAndSettle();
      for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.keyC,
        LogicalKeyboardKey.keyX,
        LogicalKeyboardKey.keyV,
      ]) {
        await _chord(tester, LogicalKeyboardKey.controlLeft, key);
      }
      expect(controller.strokes.length, 3);
      expect(controller.canPaste, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('pasting from another tool switches to Select', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final InkController controller = await pumpEditor(
        tester,
        strokes: _page(),
      );
      await _selectPair(tester, controller);
      await _chord(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.keyC,
      );
      await tester.tap(find.byTooltip('Pen'));
      await tester.pumpAndSettle();
      expect(controller.selection, isNull);

      // With nothing selected these two do nothing, whatever the tool.
      await _chord(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.keyX,
      );
      expect(controller.strokes.length, 3);

      await _chord(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.keyV,
      );

      expect(_isSelected(tester, 'Select'), isTrue);
      expect(_isSelected(tester, 'Pen'), isFalse);
      expect(controller.strokes.length, 5);
      expect(controller.selection!.indices, <int>[3, 4]);
      expect(find.byTooltip('Copy'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a focused text field keeps its own shortcuts', (
      WidgetTester tester,
    ) async {
      final List<String> calls = <String>[];
      final TextEditingController text = TextEditingController(text: 'note');
      addTearDown(text.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: ClipboardShortcuts(
              onCopy: () => calls.add('copy'),
              onCut: () => calls.add('cut'),
              onPaste: () => calls.add('paste'),
              child: Column(
                children: <Widget>[
                  TextField(controller: text),
                  const Expanded(child: ColoredBox(color: Colors.white)),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // The editor has the focus to begin with.
      await _chord(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.keyC,
      );
      expect(calls, <String>['copy']);

      await tester.tap(find.byType(TextField));
      await tester.pump();
      text.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
      for (final LogicalKeyboardKey modifier in <LogicalKeyboardKey>[
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.metaLeft,
      ]) {
        for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
          LogicalKeyboardKey.keyC,
          LogicalKeyboardKey.keyX,
          LogicalKeyboardKey.keyV,
        ]) {
          await _chord(tester, modifier, key);
        }
      }

      // None of them reached the editor's handlers.
      expect(calls, <String>['copy']);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('leaving Select commits a transform and clears the selection', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester, strokes: _page());
    await _selectPair(tester, controller);
    await tester.tap(find.byTooltip('Copy'));
    await tester.pumpAndSettle();

    // A move is under way when another finger presses the pen button.
    final TestGesture move = await tester.startGesture(
      _at(tester, _center),
      kind: PointerDeviceKind.stylus,
    );
    await move.moveBy(const Offset(60, 50), timeStamp: _sampleInterval);
    await tester.tap(find.byTooltip('Pen'));
    await tester.pumpAndSettle();

    expect(controller.activeTransform, isNull);
    expect(controller.selection, isNull);
    expect(controller.strokes[0].points.first, const InkVector(180, 250));
    expect(find.byTooltip('Copy'), findsNothing);
    // The clipboard is still what was copied before the move.
    expect(controller.canPaste, isTrue);
    expect(
      controller.clipboard!.strokes.first.points.first,
      const InkVector(120, 200),
    );

    // The rest of that gesture neither moves nor writes.
    await move.moveBy(const Offset(100, 100), timeStamp: _sampleInterval * 2);
    await move.up(timeStamp: _sampleInterval * 3);
    await tester.pumpAndSettle();
    expect(controller.strokes.length, 3);
    expect(controller.strokes[0].points.first, const InkVector(180, 250));
    expect(controller.activeStroke, isNull);

    // Back on Select nothing is selected, and Paste still works.
    await _selectTool(tester);
    expect(controller.selection, isNull);
    await _selectTool(tester);
    await tester.tap(find.text('Paste'));
    await tester.pumpAndSettle();
    expect(controller.strokes.length, 5);
  });

  testWidgets('a lasso under way when the tool changes selects nothing', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester, strokes: _page());
    await _selectTool(tester);
    final TestGesture gesture = await _startLasso(
      tester,
      const Rect.fromLTRB(100, 170, 240, 270),
    );

    await tester.tap(find.byTooltip('Eraser'));
    await tester.pumpAndSettle();

    expect(controller.activeLasso, isNull);
    await gesture.moveBy(const Offset(0, 100), timeStamp: _sampleInterval * 40);
    await gesture.up(timeStamp: _sampleInterval * 41);
    await tester.pumpAndSettle();
    // It did not turn into an erase halfway, either.
    expect(controller.selection, isNull);
    expect(controller.activeErase, isNull);
    expect(controller.strokes.length, 3);
  });

  testWidgets('the pen and the eraser are as they were after selecting', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final InkController controller = await pumpEditor(tester, strokes: _page());
    await _selectPair(tester, controller);
    await _drag(tester, _corners[2], _corners[2] + const Offset(104, 44));
    await tester.tap(find.byTooltip('Copy'));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Pen, Black, 3 px'), findsOneWidget);
    expect(find.bySemanticsLabel('Eraser, Area, 24 px'), findsOneWidget);

    await tester.tap(find.byTooltip('Pen'));
    await tester.pumpAndSettle();
    await _drag(tester, const Offset(100, 620), const Offset(300, 620));

    // A new stroke, at the pen's width, not the scaled one.
    expect(controller.strokes.length, 4);
    expect(controller.strokes.last.source, StrokeSource.input);
    expect(controller.strokes.last.style.width, 3);
    expect(controller.strokes[0].style.width, closeTo(8, 1e-9));

    // Scaled ink erases like any other: the area eraser cuts it.
    await tester.tap(find.byTooltip('Eraser'));
    await tester.pumpAndSettle();
    await _drag(tester, const Offset(220, 170), const Offset(220, 230));
    expect(controller.strokes.length, 5);
    handle.dispose();
  });

  testWidgets('an inverted stylus erases while Select stays selected', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final InkController controller = await pumpEditor(tester, strokes: _page());
    await _selectPair(tester, controller);

    // Across the third line, which is not part of the selection.
    await _drag(
      tester,
      const Offset(170, 480),
      const Offset(170, 520),
      kind: PointerDeviceKind.invertedStylus,
    );

    // It used the current eraser settings: area mode at 24 px.
    expect(controller.strokes.length, 4);
    expect(controller.strokes[2].points.last.x, closeTo(156, 1e-6));
    expect(_isSelected(tester, 'Select'), isTrue);
    expect(_isSelected(tester, 'Eraser'), isFalse);
    // Erasing let go of the selection.
    expect(controller.selection, isNull);

    // The tip still selects.
    await _lasso(tester, const Rect.fromLTRB(100, 170, 240, 270));
    expect(controller.selection!.indices, <int>[0, 1]);
    handle.dispose();
  });

  testWidgets('a second pointer is ignored during a lasso and a transform', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester, strokes: _page());
    await _selectTool(tester);

    final TestGesture lasso = await _startLasso(
      tester,
      const Rect.fromLTRB(100, 170, 240, 270),
    );
    final InkVector tip = controller.activeLasso!.tip;
    final TestGesture palm = await tester.startGesture(
      _at(tester, const Offset(300, 500)),
    );
    await palm.moveBy(const Offset(-200, 0), timeStamp: _sampleInterval);
    await palm.up(timeStamp: _sampleInterval * 2);
    expect(controller.activeLasso!.tip, tip);
    expect(controller.activePointer, isNotNull);
    await lasso.up();
    await tester.pumpAndSettle();
    expect(controller.selection!.indices, <int>[0, 1]);

    final TestGesture move = await tester.startGesture(
      _at(tester, _center),
      kind: PointerDeviceKind.stylus,
    );
    await move.moveBy(const Offset(10, 10), timeStamp: _sampleInterval);
    // On a corner handle, and then on empty paper.
    final TestGesture other = await tester.startGesture(
      _at(tester, _corners[0] + const Offset(10, 10)),
    );
    await other.moveBy(const Offset(-80, -80), timeStamp: _sampleInterval);
    await other.cancel();
    final TestGesture tap = await tester.startGesture(
      _at(tester, const Offset(300, 620)),
    );
    await tap.up();
    expect(
      controller.activeTransform!.transform,
      InkTransform.translation(const InkVector(10, 10)),
    );
    expect(controller.activeTransform!.operation, SelectionOperation.move);
    await move.up();
    await tester.pumpAndSettle();

    expect(controller.strokes[0].points.first, const InkVector(130, 210));
    expect(controller.strokes[0].style.width, 4);
    expect(controller.selection!.indices, <int>[0, 1]);
    expect(controller.strokes.length, 3);
  });

  testWidgets('a cancelled lasso keeps the selection; a cancelled move stays', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester, strokes: _page());
    await _selectPair(tester, controller);
    final InkSelection selection = controller.selection!;

    final TestGesture lasso = await _startLasso(
      tester,
      const Rect.fromLTRB(100, 470, 240, 530),
    );
    await lasso.cancel();
    await tester.pumpAndSettle();

    expect(controller.activeLasso, isNull);
    expect(controller.selection, same(selection));

    final TestGesture move = await tester.startGesture(
      _at(tester, _center),
      kind: PointerDeviceKind.stylus,
    );
    await move.moveBy(const Offset(30, 20), timeStamp: _sampleInterval);
    await move.cancel(timeStamp: _sampleInterval * 2);
    await tester.pumpAndSettle();

    expect(controller.activeTransform, isNull);
    expect(controller.activePointer, isNull);
    expect(controller.strokes[0].points.first, const InkVector(150, 220));
    expect(controller.selection!.indices, <int>[0, 1]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a gesture carries on outside the page, and is clipped to it', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester, strokes: _page());
    await _selectTool(tester);
    final Rect canvas = canvasRect(tester);
    // In the app bar, straight above the page.
    final Offset above = canvas.topLeft + const Offset(170, -20);
    final Color background = (await captureScreen(tester)).at(above);

    // A lasso that starts on the page and loops up over the app bar.
    final TestGesture lasso = await tester.startGesture(
      _at(tester, const Offset(100, 270)),
      kind: PointerDeviceKind.stylus,
    );
    int sample = 0;
    for (final Offset corner in const <Offset>[
      Offset(100, -20),
      Offset(240, -20),
      Offset(240, 270),
      Offset(100, 270),
    ]) {
      await lasso.moveTo(
        _at(tester, corner),
        timeStamp: _sampleInterval * ++sample,
      );
    }
    await tester.pump();
    expect(controller.activeLasso!.points[1].y, -20);
    expect((await captureScreen(tester)).at(above), isSameColorAs(background));
    await lasso.up();
    await tester.pumpAndSettle();
    expect(controller.selection!.indices, <int>[0, 1]);

    // Dragged up until the frame and its handle are partly off the page.
    final TestGesture move = await tester.startGesture(
      _at(tester, _center),
      kind: PointerDeviceKind.stylus,
    );
    await move.moveBy(const Offset(0, -215), timeStamp: _sampleInterval);
    await tester.pump();
    expect((await captureScreen(tester)).at(above), isSameColorAs(background));
    await move.up(timeStamp: _sampleInterval * 2);
    await tester.pumpAndSettle();

    // The points are where they were put; only the drawing is clipped.
    expect(controller.strokes[0].points.first, const InkVector(120, -15));
    expect((await captureScreen(tester)).at(above), isSameColorAs(background));
    final Rect bar = _actionBarRect(tester);
    expect(canvas.contains(bar.topLeft), isTrue);
    expect(canvas.contains(bar.bottomRight), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the actions stay on the page beside a frame at any edge', (
    WidgetTester tester,
  ) async {
    await pumpEditor(tester);
    final Size page = canvasRect(tester).size;
    final Map<String, Offset> places = <String, Offset>{
      'top left': const Offset(10, 10),
      'top right': Offset(page.width - 60, 10),
      'bottom left': Offset(10, page.height - 10),
      'bottom right': Offset(page.width - 60, page.height - 10),
      'middle': Offset(page.width / 2, page.height / 2),
      'off the left': Offset(-400, page.height / 2),
      'off the bottom': Offset(page.width / 2, page.height + 400),
    };

    for (final MapEntry<String, Offset> place in places.entries) {
      // A fresh editor each time, back on the pen.
      await tester.pumpWidget(const SizedBox.shrink());
      final InkController controller = await pumpEditor(
        tester,
        strokes: <Stroke>[
          _line(place.value.dy, from: place.value.dx, to: place.value.dx + 50),
        ],
      );
      await _selectTool(tester);
      final Rect box = Rect.fromLTWH(
        place.value.dx - 10,
        place.value.dy - 10,
        70,
        20,
      );
      controller
        ..beginLasso(pointer: 9, position: InkVector(box.left, box.top))
        ..updateLasso(9, InkVector(box.right, box.top))
        ..updateLasso(9, InkVector(box.right, box.bottom))
        ..updateLasso(9, InkVector(box.left, box.bottom))
        ..endLasso(9, InkVector(box.left, box.top));
      await tester.pumpAndSettle();

      expect(controller.selection, isNotNull, reason: place.key);
      final Rect canvas = canvasRect(tester);
      final Rect bar = _actionBarRect(tester);
      expect(bar.left, greaterThanOrEqualTo(canvas.left), reason: place.key);
      expect(bar.top, greaterThanOrEqualTo(canvas.top), reason: place.key);
      expect(bar.right, lessThanOrEqualTo(canvas.right), reason: place.key);
      expect(bar.bottom, lessThanOrEqualTo(canvas.bottom), reason: place.key);
      // All three buttons are whole, so each can be pressed.
      expect(bar.size, const Size(152, 56), reason: place.key);
      await tester.tap(find.byTooltip('Copy'));
      expect(controller.canPaste, isTrue, reason: place.key);
      expect(tester.takeException(), isNull, reason: place.key);
    }
  });

  testWidgets(
    'the actions sit above the frame, or below when there is no room',
    (WidgetTester tester) async {
      final InkController controller = await pumpEditor(
        tester,
        strokes: _page(),
      );
      await _selectPair(tester, controller);
      final Rect canvas = canvasRect(tester);

      final Rect palette = tester.getRect(find.byType(ToolPalette));
      // Ending level with the outside of the frame's right-hand handles;
      // the palette floats across the top, clear of it.
      double expectedRight(Rect bar) => canvas.left + 222 + 6;

      // Above the rotation handle.
      Rect bar = _actionBarRect(tester);
      expect(bar.right, expectedRight(bar));
      expect(bar.overlaps(palette), isFalse);
      expect(bar.bottom, canvas.top + 166 - 6 - AppSpacing.xs);

      // With the frame near the top, it goes below instead.
      await _drag(tester, _center, _center + const Offset(0, -150));
      bar = _actionBarRect(tester);
      expect(bar.top, canvas.top + 92 + 6 + AppSpacing.xs);
      expect(bar.right, expectedRight(bar));
      expect(bar.overlaps(palette), isFalse);
    },
  );

  testWidgets('selection and clipboard survive rotation and breakpoints', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final InkController controller = await pumpEditor(
      tester,
      viewport: TestViewport.tabletPortrait,
      strokes: _page(),
    );
    await _selectPair(tester, controller);
    await tester.tap(find.byTooltip('Copy'));
    await tester.pumpAndSettle();
    final InkSelection selection = controller.selection!;

    for (final Size size in const <Size>[
      Size(1280, 800),
      Size(390, 844),
      Size(1194, 834),
    ]) {
      setViewportSize(tester, size);
      await tester.pumpAndSettle();

      expect(controller.selection, same(selection), reason: '$size');
      expect(controller.canPaste, isTrue, reason: '$size');
      expect(_isSelected(tester, 'Select'), isTrue, reason: '$size');
      expect(find.bySemanticsLabel('2 strokes selected'), findsOneWidget);
      final Rect canvas = canvasRect(tester);
      final Rect bar = _actionBarRect(tester);
      expect(canvas.contains(bar.topLeft), isTrue, reason: '$size');
      expect(canvas.contains(bar.bottomRight), isTrue, reason: '$size');
      expect(tester.takeException(), isNull);
    }

    // Both still work on the new layout.
    await _drag(tester, _center, _center + const Offset(40, 40));
    expect(controller.strokes[0].points.first, const InkVector(160, 240));
    await _selectTool(tester);
    await tester.tap(find.text('Paste'));
    await tester.pumpAndSettle();
    expect(controller.strokes.length, 5);
    expect(controller.strokes[3].points.first, const InkVector(144, 224));
    handle.dispose();
  });

  testWidgets('rotating mid-transform commits it and keeps the selection', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(
      tester,
      viewport: TestViewport.tabletPortrait,
      strokes: _page(),
    );
    await _selectPair(tester, controller);

    final TestGesture move = await tester.startGesture(
      _at(tester, _center),
      kind: PointerDeviceKind.stylus,
    );
    await move.moveBy(const Offset(30, 20), timeStamp: _sampleInterval);
    expect(controller.activeTransform, isNotNull);

    setViewportSize(tester, TestViewport.tabletPortrait.size.flipped);
    await tester.pumpAndSettle();

    expect(controller.activeTransform, isNull);
    expect(controller.strokes[0].points.first, const InkVector(150, 220));
    expect(controller.selection!.indices, <int>[0, 1]);
    expect(controller.selection!.frame.center, const InkVector(200, 240));
    // The pointer that was down no longer moves it.
    await move.moveBy(const Offset(100, 100), timeStamp: _sampleInterval * 2);
    await move.up(timeStamp: _sampleInterval * 3);
    await tester.pumpAndSettle();
    expect(controller.strokes[0].points.first, const InkVector(150, 220));
    expect(find.byTooltip('Copy'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('semantics report the tool, the selection, and its actions', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final InkController controller = await pumpEditor(tester, strokes: _page());

    expect(
      tester.getSemantics(find.bySemanticsLabel('Select')),
      isSemantics(
        label: 'Select',
        isButton: true,
        isSelected: false,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    // Nothing selected: the page has nothing to announce.
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('Writing surface'))
          .childrenCount,
      0,
    );

    await _selectPair(tester, controller);

    expect(
      tester.getSemantics(find.bySemanticsLabel('Select')),
      isSemantics(label: 'Select', isButton: true, isSelected: true),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('2 strokes selected')),
      isSemantics(label: '2 strokes selected', isLiveRegion: true),
    );
    expect(find.bySemanticsLabel('Copy'), findsOneWidget);
    expect(find.bySemanticsLabel('Cut'), findsOneWidget);
    // The frame and its handles are decoration: the summary and its three
    // buttons are all the page exposes.
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('Writing surface'))
          .childrenCount,
      1,
    );

    await _lasso(tester, const Rect.fromLTRB(100, 470, 240, 530));
    expect(find.bySemanticsLabel('1 stroke selected'), findsOneWidget);
    expect(SelectionActionBar.describe(1), '1 stroke selected');
    expect(SelectionActionBar.describe(12), '12 strokes selected');
    handle.dispose();
  });

  testWidgets('the selection layer takes its colors from the theme', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(
      tester,
      themeMode: ThemeMode.dark,
      strokes: _page(),
    );
    await _selectPair(tester, controller);

    final SelectionPainter painter =
        tester
                .widget<CustomPaint>(
                  find.byKey(const ValueKey<String>('selection-layer')),
                )
                .painter!
            as SelectionPainter;
    expect(painter.color, AppColors.dark.accent);
    expect(painter.handleColor, AppColors.dark.writingSurface);
    expect(painter.brightness, Brightness.dark);
    for (final AppColors colors in <AppColors>[
      AppColors.light,
      AppColors.dark,
    ]) {
      expect(
        contrastRatio(colors.accent, colors.writingSurface),
        greaterThan(3),
      );
    }
    // Selected ink keeps its dark-paper color in the selection layer.
    expect(
      (await captureScreen(tester)).at(_at(tester, const Offset(170, 240))),
      isSameColorAs(_red.onDarkPaper),
    );
  });
}
