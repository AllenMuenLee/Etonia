import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/page/note_document.dart';
import 'package:greatnote/features/editor/page/page_background.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/page/page_viewport.dart';
import 'package:greatnote/features/editor/widgets/page_controls.dart';

import '../../helpers/editor_harness.dart';
import '../../helpers/pump_app.dart';

const Duration _sampleInterval = Duration(milliseconds: 8);

Future<NoteDocument> _pumpDocument(
  WidgetTester tester, {
  TestViewport viewport = TestViewport.tabletLandscape,
  PageSetup setup = const PageSetup(),
}) async {
  final NoteDocument document = NoteDocument(
    pages: <NotePage>[NotePage(ink: InkController(), setup: setup)],
  );
  addTearDown(document.dispose);
  await pumpApp(
    tester,
    viewport: viewport,
    home: EditorScreen(document: document),
  );
  return document;
}

Future<void> _drawLine(
  WidgetTester tester,
  Offset from,
  Offset to, {
  PointerDeviceKind kind = PointerDeviceKind.stylus,
}) async {
  final TestGesture gesture = await tester.startGesture(from, kind: kind);
  for (int i = 1; i <= 10; i++) {
    await gesture.moveTo(
      Offset.lerp(from, to, i / 10)!,
      timeStamp: _sampleInterval * i,
    );
  }
  await gesture.up(timeStamp: _sampleInterval * 11);
  await tester.pump();
}

/// The page's scale on screen: its drawn width over its logical width.
double _scale(WidgetTester tester) {
  final Size logical = tester.getSize(find.byType(InkCanvas));
  return canvasRect(tester).width / logical.width;
}

Future<void> _openPanel(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Page setup'));
  await tester.pumpAndSettle();
}

/// Opens the dropdown keyed [dropdown] in the page panel and picks [label].
Future<void> _choose(WidgetTester tester, String dropdown, String label) async {
  final Finder field = find.byKey(ValueKey<String>(dropdown));
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  // The open menu's entry is the last one built.
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _closePanel(WidgetTester tester) async {
  await tester.tapAt(const Offset(10, 10));
  await tester.pumpAndSettle();
}

void main() {
  group('PageGeometry', () {
    const Size viewport = Size(1000, 700);

    test('a fit page is the writing area at scale 1', () {
      final PageGeometry geometry = PageGeometry.of(
        const PageSetup(),
        null,
        viewport,
      );
      expect(geometry.pageSize, viewport);
      expect(geometry.scale, 1);
    });

    test('a fixed page is scaled to the width', () {
      final PageGeometry geometry = PageGeometry.of(
        const PageSetup(size: PageSize.a4Portrait),
        null,
        viewport,
      );
      expect(geometry.pageSize, const Size(794, 1123));
      expect(geometry.displaySize.width, closeTo(1000, 1e-9));
      expect(geometry.displaySize.height, greaterThan(700));
    });

    test('an infinite page is at least the area, at scale 1', () {
      expect(
        PageGeometry.of(
          const PageSetup(size: PageSize.infinite),
          null,
          viewport,
        ).pageSize,
        viewport,
      );
      expect(
        PageGeometry.of(
          const PageSetup(size: PageSize.infinite),
          const Size(1600, 500),
          viewport,
        ).pageSize,
        const Size(1600, 700),
      );
    });
  });

  group('grownPageExtent', () {
    const Size page = Size(1000, 700);

    test('does not grow for ink away from the edges', () {
      expect(
        grownPageExtent(
          current: page,
          viewport: page,
          ink: const Rect.fromLTWH(100, 100, 600, 400),
        ),
        isNull,
      );
    });

    test('grows right and down by a step when ink nears an edge', () {
      final Size? right = grownPageExtent(
        current: page,
        viewport: page,
        ink: const Rect.fromLTWH(800, 100, 120, 50),
      );
      expect(right, const Size(1500, 700));
      final Size? down = grownPageExtent(
        current: page,
        viewport: page,
        ink: const Rect.fromLTWH(100, 640, 50, 30),
      );
      expect(down, const Size(1000, 1050));
    });

    test('grows far enough for ink past the edge, up to the limit', () {
      expect(
        grownPageExtent(
          current: page,
          viewport: page,
          ink: const Rect.fromLTWH(0, 0, 3000, 10),
        ),
        const Size(3096, 700),
      );
      expect(
        grownPageExtent(
          current: page,
          viewport: page,
          ink: const Rect.fromLTWH(0, 0, 1e9, 10),
          config: const PageConfig(maxExtent: 5000),
        ),
        const Size(5000, 700),
      );
    });
  });

  group('NoteDocument', () {
    test('adds a page after the current one with its setup', () {
      final NoteDocument document = NoteDocument(
        pages: <NotePage>[
          NotePage(
            ink: InkController(),
            setup: const PageSetup(background: PageBackground.grid),
          ),
          NotePage(ink: InkController()),
        ],
      );
      addTearDown(document.dispose);
      int notified = 0;
      document.addListener(() => notified++);

      final NotePage added = document.addPage();
      expect(document.pageCount, 3);
      expect(document.currentIndex, 1);
      expect(document.pages[1], same(added));
      expect(added.setup.background, PageBackground.grid);
      expect(notified, 1);
    });

    test('deletes pages, but never the last one', () {
      final NoteDocument document = NoteDocument();
      addTearDown(document.dispose);
      expect(document.deletePage(0), isFalse);
      document.addPage();
      document.addPage();
      expect(document.currentIndex, 2);
      expect(document.deletePage(2), isTrue);
      expect(document.currentIndex, 1);
      expect(document.deletePage(0), isTrue);
      expect(document.currentIndex, 0);
      expect(document.pageCount, 1);
    });

    test('moves between pages within range', () {
      final NoteDocument document = NoteDocument();
      addTearDown(document.dispose);
      document.addPage();
      document.previousPage();
      expect(document.currentIndex, 0);
      document.previousPage();
      expect(document.currentIndex, 0);
      document.goTo(5);
      expect(document.currentIndex, 0);
      document.nextPage();
      expect(document.currentIndex, 1);
    });
  });

  testWidgets('each page keeps its own ink', (WidgetTester tester) async {
    final NoteDocument document = await _pumpDocument(tester);
    final Offset origin = canvasRect(tester).topLeft;
    await _drawLine(
      tester,
      origin + const Offset(100, 100),
      origin + const Offset(300, 100),
    );

    await tester.tap(find.byTooltip('Add page'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    expect(document.current.ink.strokes, isEmpty);
    await _drawLine(
      tester,
      origin + const Offset(100, 200),
      origin + const Offset(300, 200),
    );
    await _drawLine(
      tester,
      origin + const Offset(100, 300),
      origin + const Offset(300, 300),
    );

    await tester.tap(find.byTooltip('Previous page'));
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);
    expect(document.pages[0].ink.strokes, hasLength(1));
    expect(document.pages[1].ink.strokes, hasLength(2));
  });

  testWidgets('switching pages drops the selection and keeps the clipboard', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(tester);
    final Offset origin = canvasRect(tester).topLeft;
    await _drawLine(
      tester,
      origin + const Offset(100, 100),
      origin + const Offset(300, 100),
    );
    await tester.tap(find.byTooltip('Select'));
    await tester.pumpAndSettle();
    await _drawLine(
      tester,
      // Clear of the palette floating over the page's top-left.
      origin + const Offset(150, 50),
      origin + const Offset(350, 150),
    );
    final InkController first = document.current.ink;
    expect(first.selection, isNotNull);
    expect(first.copySelection(), isTrue);

    await tester.tap(find.byTooltip('Add page'));
    await tester.pumpAndSettle();
    expect(first.selection, isNull);
    expect(document.current.ink.canPaste, isTrue);
  });

  testWidgets('the page panel sets the size and background', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(tester);
    await _openPanel(tester);
    expect(find.text('Page 1 of 1'), findsOneWidget);
    // The panel sits under the top bar, at its trailing end.
    final Rect panel = tester.getRect(find.byType(PagePanel));
    expect(
      panel.right,
      greaterThan(tester.getSize(find.byType(Scaffold)).width - 40),
    );
    expect(panel.width, lessThanOrEqualTo(PagePanel.width));
    expect(find.byKey(const ValueKey<String>('page-preview')), findsOneWidget);
    final Size fitPreview = tester.getSize(
      find.byKey(const ValueKey<String>('page-preview')),
    );

    await _choose(tester, 'page-size-dropdown', 'A4 portrait');
    expect(document.current.setup.size, PageSize.a4Portrait);
    // The preview takes the new page's shape.
    final Size a4Preview = tester.getSize(
      find.byKey(const ValueKey<String>('page-preview')),
    );
    expect(a4Preview.height / a4Preview.width, closeTo(1123 / 794, 0.02));
    expect(a4Preview, isNot(fitPreview));

    await _choose(tester, 'page-background-dropdown', 'Lined');
    await _closePanel(tester);
    expect(find.byType(PagePanel), findsNothing);

    expect(document.current.setup.size, PageSize.a4Portrait);
    expect(document.current.setup.background, PageBackground.lined);
    expect(
      find.byKey(const ValueKey<String>('page-background')),
      findsOneWidget,
    );
    expect(tester.getSize(find.byType(InkCanvas)), const Size(794, 1123));
    // Scaled to the area's width, taller than the area, so it scrolls.
    final Rect viewport = tester.getRect(find.byType(PageViewport));
    expect(canvasRect(tester).width, closeTo(viewport.width, 0.01));
    expect(canvasRect(tester).height, greaterThan(viewport.height));
    expect(
      find.byKey(const ValueKey<String>('page-scroll-indicators')),
      findsOneWidget,
    );
  });

  testWidgets('pointer positions map to page coordinates when scaled and '
      'scrolled', (WidgetTester tester) async {
    final NoteDocument document = await _pumpDocument(
      tester,
      setup: const PageSetup(size: PageSize.a4Portrait),
    );
    final double scale = _scale(tester);
    expect(scale, isNot(1));

    // Two fingers scroll the page down by 200 screen pixels.
    final Offset middle = tester.getCenter(find.byType(PageViewport));
    final TestGesture a = await tester.createGesture(
      kind: PointerDeviceKind.touch,
    );
    final TestGesture b = await tester.createGesture(
      kind: PointerDeviceKind.touch,
    );
    await a.down(middle);
    await b.down(middle + const Offset(60, 0));
    await tester.pump();
    for (int i = 1; i <= 4; i++) {
      await a.moveBy(const Offset(0, -50));
      await b.moveBy(const Offset(0, -50));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await tester.pump();
    expect(document.current.ink.strokes, isEmpty);

    final Rect page = canvasRect(tester);
    expect(
      page.top,
      closeTo(tester.getRect(find.byType(PageViewport)).top - 200, 0.5),
    );
    final Offset from = middle + const Offset(-100, 0);
    await _drawLine(tester, from, from + const Offset(150, 0));
    final Stroke stroke = document.current.ink.strokes.single;
    final Offset expected = (from - page.topLeft) / scale;
    expect(stroke.points.first.x, closeTo(expected.dx, 0.01));
    expect(stroke.points.first.y, closeTo(expected.dy, 0.01));
  });

  testWidgets('a second finger that starts a scroll drops the first stroke', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(
      tester,
      setup: const PageSetup(size: PageSize.a4Portrait),
    );
    final Offset middle = tester.getCenter(find.byType(PageViewport));
    final TestGesture a = await tester.createGesture(
      kind: PointerDeviceKind.touch,
    );
    await a.down(middle);
    await a.moveBy(const Offset(40, 0), timeStamp: _sampleInterval);
    await tester.pump();
    expect(document.current.ink.activeStroke, isNotNull);

    final TestGesture b = await tester.createGesture(
      kind: PointerDeviceKind.touch,
    );
    await b.down(middle + const Offset(80, 0));
    await tester.pump();
    expect(document.current.ink.activeStroke, isNull);
    await a.moveBy(const Offset(0, -60));
    await b.moveBy(const Offset(0, -60));
    await a.up();
    await b.up();
    await tester.pump();
    expect(document.current.ink.strokes, isEmpty);
  });

  testWidgets('on a page that cannot scroll, a second finger is ignored', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(tester);
    final Offset origin = canvasRect(tester).topLeft + const Offset(100, 100);
    final TestGesture a = await tester.createGesture(
      kind: PointerDeviceKind.touch,
    );
    await a.down(origin);
    final TestGesture b = await tester.createGesture(
      kind: PointerDeviceKind.touch,
    );
    await b.down(origin + const Offset(0, 100));
    await a.moveBy(const Offset(100, 0), timeStamp: _sampleInterval);
    await a.up(timeStamp: _sampleInterval * 2);
    await b.up();
    await tester.pump();
    expect(document.current.ink.strokes, hasLength(1));
  });

  testWidgets('a mouse wheel scrolls a tall page', (WidgetTester tester) async {
    await _pumpDocument(tester, setup: const PageSetup(size: PageSize.square));
    final double top = canvasRect(tester).top;
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    final Offset middle = tester.getCenter(find.byType(PageViewport));
    await tester.sendEventToBinding(mouse.hover(middle));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
    await tester.pump();
    expect(canvasRect(tester).top, closeTo(top - 120, 0.5));
  });

  testWidgets('an infinite page grows only when ink reaches its edge', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(
      tester,
      setup: const PageSetup(size: PageSize.infinite),
    );
    final Rect start = canvasRect(tester);
    await _drawLine(
      tester,
      start.topLeft + const Offset(100, 100),
      start.topLeft + const Offset(400, 100),
    );
    expect(canvasRect(tester).size, start.size);
    expect(document.current.extent, isNull);

    final InkVector before = document.current.ink.strokes.single.points.first;
    await _drawLine(
      tester,
      start.topLeft + Offset(start.width - 300, 300),
      start.topLeft + Offset(start.width - 20, 300),
    );
    await tester.pump();
    expect(document.current.extent!.width, greaterThan(start.width));
    expect(document.current.extent!.height, start.height);
    expect(canvasRect(tester).width, document.current.extent!.width);
    // Nothing already drawn moved.
    expect(document.current.ink.strokes.first.points.first, before);
  });

  testWidgets('each background paints its rules', (WidgetTester tester) async {
    for (final PageBackground background in PageBackground.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(body: PageBackgroundLayer(background: background)),
        ),
      );
      expect(
        find.byKey(const ValueKey<String>('page-background')),
        background == PageBackground.blank ? findsNothing : findsOneWidget,
      );
    }
  });

  testWidgets('deleting a page with ink asks first', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(tester);
    await tester.tap(find.byTooltip('Add page'));
    await tester.pumpAndSettle();
    // The new page is scrolled into view, below the first.
    final Offset origin = tester.getRect(find.byType(InkCanvas).at(1)).topLeft;
    await _drawLine(
      tester,
      origin + const Offset(100, 100),
      origin + const Offset(300, 100),
    );

    await _openPanel(tester);
    await tester.tap(find.text('Delete page'));
    await tester.pumpAndSettle();
    expect(find.text('Delete page?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(document.pageCount, 2);

    await tester.tap(find.text('Delete page'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(document.pageCount, 1);
    expect(find.text('Page 1 of 1'), findsOneWidget);
  });

  testWidgets('pages are separate sheets with a gap between them', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(tester);
    document.addPage();
    await tester.pumpAndSettle();
    final Rect first = tester.getRect(find.byType(InkCanvas).first);
    final Rect second = tester.getRect(find.byType(InkCanvas).last);
    expect(second.top - first.bottom, closeTo(16, 0.01));
    expect(second.left, first.left);
    // Adding the page scrolled it to the top of the area.
    expect(
      second.top,
      closeTo(tester.getRect(find.byType(PageViewport)).top, 0.5),
    );
  });

  testWidgets('scrolling past the middle makes the next page current', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(tester);
    document.addPage();
    document.goTo(0);
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);
    final Rect area = tester.getRect(find.byType(PageViewport));

    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(area.center));
    await tester.sendEventToBinding(mouse.scroll(Offset(0, area.height * 0.6)));
    await tester.pumpAndSettle();
    expect(document.currentIndex, 1);
    expect(find.text('2 / 2'), findsOneWidget);

    await tester.tap(find.byTooltip('Previous page'));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byType(InkCanvas).first).top,
      closeTo(area.top, 0.5),
    );
  });

  testWidgets('writing on another page makes it current and drops the '
      'selection on the first', (WidgetTester tester) async {
    final NoteDocument document = await _pumpDocument(
      tester,
      setup: const PageSetup(size: PageSize.square),
    );
    document.addPage();
    document.goTo(0);
    await tester.pumpAndSettle();
    final Rect first = tester.getRect(find.byType(InkCanvas).first);
    await _drawLine(
      tester,
      first.topLeft + const Offset(100, 100),
      first.topLeft + const Offset(300, 100),
    );
    await tester.tap(find.byTooltip('Select'));
    await tester.pumpAndSettle();
    await _drawLine(
      tester,
      // Clear of the palette floating over the page's top-left.
      first.topLeft + const Offset(150, 50),
      first.topLeft + const Offset(350, 150),
    );
    expect(document.pages[0].ink.selection, isNotNull);
    await tester.tap(find.byTooltip('Pen'));
    await tester.pumpAndSettle();

    // Scroll so the seam is on screen, then write below it.
    final Rect area = tester.getRect(find.byType(PageViewport));
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(area.center));
    await tester.sendEventToBinding(
      mouse.scroll(Offset(0, first.height - area.height / 4)),
    );
    await tester.pumpAndSettle();
    final Rect second = tester.getRect(find.byType(InkCanvas).last);
    final Offset start = Offset(second.left + 100, second.top + 40);
    await _drawLine(tester, start, start + const Offset(200, 0));

    expect(document.currentIndex, 1);
    expect(document.pages[1].ink.strokes, hasLength(1));
    expect(document.pages[0].ink.strokes, hasLength(1));
  });

  testWidgets('a pointer on one page keeps others from writing elsewhere', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(
      tester,
      setup: const PageSetup(size: PageSize.letterLandscape),
    );
    document.addPage();
    document.goTo(0);
    await tester.pumpAndSettle();
    final Rect first = tester.getRect(find.byType(InkCanvas).first);
    final Rect second = tester.getRect(find.byType(InkCanvas).last);

    final TestGesture palm = await tester.startGesture(
      first.center,
      kind: PointerDeviceKind.touch,
    );
    await palm.moveBy(const Offset(10, 0), timeStamp: _sampleInterval);
    await tester.pump();
    final Offset pen = Offset(second.left + 100, second.top + 40);
    await _drawLine(tester, pen, pen + const Offset(100, 0));
    await palm.up(timeStamp: _sampleInterval * 2);
    await tester.pump();

    expect(document.pages[1].ink.strokes, isEmpty);
    expect(document.pages[0].ink.strokes, hasLength(1));
    expect(document.currentIndex, 0);
  });

  testWidgets('with only stylus writing, fingers leave no ink', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(tester);
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Only write with stylus'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    final Offset origin = canvasRect(tester).topLeft;
    await _drawLine(
      tester,
      origin + const Offset(100, 100),
      origin + const Offset(300, 100),
      kind: PointerDeviceKind.touch,
    );
    expect(document.current.ink.strokes, isEmpty);
    await _drawLine(
      tester,
      origin + const Offset(100, 200),
      origin + const Offset(300, 200),
    );
    expect(document.current.ink.strokes, hasLength(1));
    // A finger resting on the page does not keep the pen from writing.
    final TestGesture palm = await tester.startGesture(
      origin + const Offset(400, 400),
      kind: PointerDeviceKind.touch,
    );
    await _drawLine(
      tester,
      origin + const Offset(100, 300),
      origin + const Offset(300, 300),
    );
    await palm.up();
    expect(document.current.ink.strokes, hasLength(2));
  });

  Future<void> onlyStylusWrites(WidgetTester tester) async {
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Only write with stylus'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  }

  testWidgets('with only stylus writing, one finger scrolls the page', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(
      tester,
      setup: const PageSetup(size: PageSize.a4Portrait),
    );
    await onlyStylusWrites(tester);
    final double top = canvasRect(tester).top;
    final Offset middle = tester.getCenter(find.byType(PageViewport));
    final TestGesture finger = await tester.startGesture(
      middle,
      kind: PointerDeviceKind.touch,
    );
    await finger.moveBy(const Offset(0, -60));
    await finger.moveBy(const Offset(0, -60));
    await finger.up();
    await tester.pump();
    expect(canvasRect(tester).top, closeTo(top - 120, 0.5));
    expect(document.current.ink.strokes, isEmpty);
  });

  testWidgets('with only stylus writing, two fingers pinch to zoom', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(tester);
    await onlyStylusWrites(tester);
    final double width = canvasRect(tester).width;
    final Offset middle = tester.getCenter(find.byType(PageViewport));
    final TestGesture a = await tester.startGesture(
      middle - const Offset(50, 0),
      kind: PointerDeviceKind.touch,
    );
    final TestGesture b = await tester.startGesture(
      middle + const Offset(50, 0),
      kind: PointerDeviceKind.touch,
    );
    await a.moveBy(const Offset(-50, 0));
    await b.moveBy(const Offset(50, 0));
    await a.up();
    await b.up();
    await tester.pump();
    final PageViewportState viewport = tester.state<PageViewportState>(
      find.byType(PageViewport),
    );
    expect(viewport.zoom, greaterThan(1.3));
    expect(canvasRect(tester).width, greaterThan(width * 1.3));
    expect(document.current.ink.strokes, isEmpty);

    // The pen still writes, where it touches the zoomed page.
    final Rect page = canvasRect(tester);
    await _drawLine(tester, page.center, page.center + const Offset(100, 0));
    expect(document.current.ink.strokes, hasLength(1));
  });

  testWidgets('compact layouts reach page navigation through the panel', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(
      tester,
      viewport: TestViewport.compact,
    );
    expect(find.byTooltip('Add page'), findsNothing);
    await _openPanel(tester);
    await tester.tap(find.text('Add page'));
    await tester.pumpAndSettle();
    expect(document.pageCount, 2);
    expect(find.text('Page 2 of 2'), findsOneWidget);
  });
}
