import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/features/editor/document_io/document_models.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
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
const PageSetup _shortPage = PageSetup(
  size: PageSize.custom,
  customSize: Size(1000, 500),
);

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
  await tester.tap(find.byTooltip('Page settings'));
  await tester.pumpAndSettle();
}

/// Opens the dropdown keyed [dropdown] in the page panel and picks [label].
Future<void> _choose(WidgetTester tester, String dropdown, String label) async {
  final Finder field = find.byKey(ValueKey<String>(dropdown));
  await tester.ensureVisible(field);
  // The field's centre can fall on its helper text; tap the dropdown itself.
  await tester.tap(
    find.descendant(
      of: field,
      matching: find.byWidgetPredicate((Widget w) => w is DropdownButton),
    ),
  );
  await tester.pumpAndSettle();
  // The open menu's entry is the last one built.
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

/// Steps a page with the overview's arrow [tooltip], opening the overview
/// for it and closing it after.
Future<void> _stepPage(WidgetTester tester, String tooltip) async {
  await tester.tap(find.byTooltip('Page overview'));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip(tooltip));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Page overview'));
  await tester.pumpAndSettle();
}

/// Turns on Only write with stylus, so fingers pan and zoom.
Future<void> _onlyStylusWrites(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Settings'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Only write with stylus'));
  await tester.pumpAndSettle();
  await tester.tapAt(const Offset(10, 10));
  await tester.pumpAndSettle();
}

const StrokeStyle _pen = StrokeStyle(ink: InkPalette.ink, width: 4);

/// A stroke drawn on [ink] as a pen would, one step of history.
void _write(InkController ink, double x, double y) {
  ink.startStroke(
    pointer: 1,
    sample: RawInkSample(position: InkVector(x, y), timestamp: Duration.zero),
    style: _pen,
  );
  for (int i = 1; i <= 5; i++) {
    ink.addSamples(1, <RawInkSample>[
      RawInkSample(
        position: InkVector(x + i * 10, y),
        timestamp: _sampleInterval * i,
      ),
    ]);
  }
  ink.endStroke(1);
}

Future<void> _closePanel(WidgetTester tester) async {
  await tester.tapAt(const Offset(10, 10));
  await tester.pumpAndSettle();
}

void main() {
  _pullTests();
  _appendTests();

  group('PageGeometry', () {
    const Size viewport = Size(1000, 700);

    test('the default page is A4 portrait', () {
      final PageGeometry geometry = PageGeometry.of(
        const PageSetup(),
        null,
        viewport,
      );
      expect(geometry.pageSize, PageSize.a4Portrait.fixedSize);
      expect(geometry.displaySize.width, closeTo(viewport.width, 1e-9));
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

    test('an infinite page is the whole board, at scale 1', () {
      for (final Size? extent in <Size?>[null, const Size(1600, 500)]) {
        final PageGeometry geometry = PageGeometry.of(
          const PageSetup(size: PageSize.infinite),
          extent,
          viewport,
        );
        expect(geometry.pageSize, InfiniteBoard.size);
        expect(geometry.scale, 1);
      }
    });
  });

  testWidgets('the editor opens A4 at its minimum zoom', (
    WidgetTester tester,
  ) async {
    await _pumpDocument(tester);

    final PageViewportState viewport = tester.state<PageViewportState>(
      find.byType(PageViewport),
    );
    expect(viewport.zoom, 0.7);
  });

  group('InfiniteBoard', () {
    test('its origin is in the middle, on the rules\' lattice', () {
      expect(InfiniteBoard.origin.dx, closeTo(InfiniteBoard.extent / 2, 96));
      expect(InfiniteBoard.origin.dy, InfiniteBoard.origin.dx);
      const PageConfig config = PageConfig();
      for (final double spacing in <double>[
        config.lineSpacing,
        config.gridSpacing,
        config.dotSpacing,
      ]) {
        expect(InfiniteBoard.origin.dx % spacing, 0);
      }
    });

    test('an empty board is framed at its origin', () {
      expect(
        InfiniteBoard.frameOf(null),
        InfiniteBoard.origin & InfiniteBoard.minFrame,
      );
    });

    test('ink is framed with a margin, from a corner on the lattice', () {
      final Rect ink = Rect.fromLTWH(
        InfiniteBoard.origin.dx - 1000,
        InfiniteBoard.origin.dy + 30,
        2000,
        900,
      );
      final Rect frame = InfiniteBoard.frameOf(ink);
      expect(frame.left % InfiniteBoard.frameSnap, 0);
      expect(frame.top % InfiniteBoard.frameSnap, 0);
      expect(
        frame.contains(ink.inflate(InfiniteBoard.frameMargin).topLeft),
        isTrue,
      );
      expect(frame.right, ink.right + InfiniteBoard.frameMargin);
      expect(frame.bottom, ink.bottom + InfiniteBoard.frameMargin);
      // A dot still makes a frame of the smallest size.
      expect(
        InfiniteBoard.frameOf(
          Rect.fromCenter(center: InfiniteBoard.origin, width: 4, height: 4),
        ).size,
        InfiniteBoard.minFrame,
      );
    });

    test('ink leaving the board for paper lands on the paper', () {
      const Offset o = InfiniteBoard.origin;
      // Written right of and below the origin: straight back.
      expect(
        InfiniteBoard.toPage(Rect.fromLTWH(o.dx + 10, o.dy + 20, 100, 100)),
        -o,
      );
      // Written above and left of it: brought just inside the paper.
      final Rect above = Rect.fromLTWH(o.dx - 500, o.dy - 300, 100, 100);
      final Rect landed = above.shift(InfiniteBoard.toPage(above));
      expect(landed.left, InfiniteBoard.frameMargin);
      expect(landed.top, InfiniteBoard.frameMargin);
    });
  });

  group('whiteboard conversion', () {
    test('ink moves onto the board and back, its history with it', () {
      final InkController ink = InkController();
      final NoteDocument document = NoteDocument(
        pages: <NotePage>[NotePage(ink: ink)],
      );
      addTearDown(document.dispose);
      _write(ink, 100, 100);
      _write(ink, 100, 200);
      final Stroke first = ink.strokes.first;
      final InkVector o = InkVector(
        InfiniteBoard.origin.dx,
        InfiniteBoard.origin.dy,
      );

      document.setSetup(const PageSetup(size: PageSize.infinite));
      expect(ink.strokes.first.points.first, first.points.first + o);
      expect(
        ink.strokes.first.rawSamples.first.position,
        first.rawSamples.first.position + o,
      );
      expect(ink.strokes.first.id, first.id);
      expect(ink.strokes.first.source, StrokeSource.input);

      // Undo finds the earlier ink on the board too, not on the old paper.
      expect(document.undo(), isTrue);
      expect(ink.strokes.single.points.first, first.points.first + o);
      expect(document.redo(), isTrue);
      expect(ink.strokes, hasLength(2));

      document.setSetup(const PageSetup());
      expect(ink.strokes.first.points.first, first.points.first);
      expect(document.undo(), isTrue);
      expect(ink.strokes.single.points.first, first.points.first);
    });

    test('a background change leaves the board\'s ink where it is', () {
      final InkController ink = InkController();
      final NoteDocument document = NoteDocument(
        pages: <NotePage>[
          NotePage(
            ink: ink,
            setup: const PageSetup(size: PageSize.infinite),
          ),
        ],
      );
      addTearDown(document.dispose);
      _write(ink, 70000, 70000);
      final InkVector before = ink.strokes.single.points.first;
      document.setSetup(
        const PageSetup(
          size: PageSize.infinite,
          background: PageBackground.grid,
        ),
      );
      expect(ink.strokes.single.points.first, before);
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

    await tester.tap(find.byTooltip('Add'));

    await tester.pumpAndSettle();

    await tester.tap(find.text('Add blank page'));
    await tester.pumpAndSettle();
    expect(document.pageCount, 2);
    expect(document.currentIndex, 1);
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

    await _stepPage(tester, 'Previous page');
    expect(document.currentIndex, 0);
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

    await tester.tap(find.byTooltip('Add'));

    await tester.pumpAndSettle();

    await tester.tap(find.text('Add blank page'));
    await tester.pumpAndSettle();
    expect(first.selection, isNull);
    expect(document.current.ink.canPaste, isTrue);
  });

  testWidgets('a fast two-finger flick keeps coasting after release', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(
      tester,
      setup: const PageSetup(size: PageSize.a4Portrait),
    );
    final Offset middle = tester.getCenter(find.byType(PageViewport));
    final TestGesture first = await tester.startGesture(
      middle + const Offset(-40, 40),
      kind: PointerDeviceKind.touch,
    );
    final TestGesture second = await tester.startGesture(
      middle + const Offset(40, 40),
      kind: PointerDeviceKind.touch,
    );

    // Both fingers together, so their spread, and the zoom, stay as they
    // are.
    const Duration step = Duration(milliseconds: 4);
    for (int i = 1; i <= 15; i++) {
      await first.moveBy(const Offset(0, -10), timeStamp: step * (2 * i - 1));
      await second.moveBy(const Offset(0, -10), timeStamp: step * (2 * i));
    }
    await tester.pump();
    final PageViewportState viewport = tester.state<PageViewportState>(
      find.byType(PageViewport),
    );
    final double releasedAt = viewport.scrollOffset.dy;
    expect(releasedAt, greaterThan(0));

    await first.up(timeStamp: step * 31);
    await second.up(timeStamp: step * 31);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 120));

    expect(viewport.scrollOffset.dy, greaterThan(releasedAt));
    expect(document.currentIndex, greaterThanOrEqualTo(0));
  });

  testWidgets(
    'a delayed frame cannot jump ballistic scrolling and the page settles '
    'only after the longer coast',
    (WidgetTester tester) async {
      final NoteDocument document = await _pumpDocument(
        tester,
        setup: _shortPage,
      );
      for (int i = 0; i < 8; i++) {
        document.appendPage();
      }
      await tester.pump();

      final Offset middle = tester.getCenter(find.byType(PageViewport));
      final TestGesture first = await tester.startGesture(
        middle + const Offset(-40, 40),
        kind: PointerDeviceKind.touch,
      );
      final TestGesture second = await tester.startGesture(
        middle + const Offset(40, 40),
        kind: PointerDeviceKind.touch,
      );
      const Duration step = Duration(milliseconds: 4);
      for (int i = 1; i <= 15; i++) {
        await first.moveBy(const Offset(0, -10), timeStamp: step * (2 * i - 1));
        await second.moveBy(const Offset(0, -10), timeStamp: step * (2 * i));
      }
      await tester.pump();
      final PageViewportState viewport = tester.state<PageViewportState>(
        find.byType(PageViewport),
      );
      final double releasedAt = viewport.scrollOffset.dy;

      await first.up(timeStamp: step * 31);
      await second.up(timeStamp: step * 31);
      await tester.pump(const Duration(milliseconds: 16));
      final double beforeDelayedFrame = viewport.scrollOffset.dy;
      // Simulates an image upload or other missed frame. The next frame may
      // advance normally, but must not catch up the full pause in one jump.
      await tester.pump(const Duration(milliseconds: 250));
      final double afterDelayedFrame = viewport.scrollOffset.dy;
      expect(afterDelayedFrame, greaterThan(beforeDelayedFrame));
      expect(afterDelayedFrame - beforeDelayedFrame, lessThan(80));
      expect(viewport.isScrolling, isTrue);
      expect(document.currentIndex, 0);

      var frames = 0;
      while (viewport.isScrolling && frames < 240) {
        await tester.pump(const Duration(milliseconds: 16));
        if (viewport.isScrolling) expect(document.currentIndex, 0);
        frames++;
      }
      expect(viewport.isScrolling, isFalse);
      expect(frames, greaterThan(45));
      expect(viewport.scrollOffset.dy, greaterThan(releasedAt + 350));
      expect(document.currentIndex, greaterThan(0));
    },
  );

  testWidgets('the final drag direction owns momentum after a reversal', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(
      tester,
      setup: _shortPage,
    );
    for (int i = 0; i < 8; i++) {
      document.appendPage();
    }
    await tester.pump();
    final PageViewportState viewport = tester.state<PageViewportState>(
      find.byType(PageViewport),
    );
    viewport.scrollBy(const Offset(0, 1000));
    await tester.pump();

    final Offset middle = tester.getCenter(find.byType(PageViewport));
    final TestGesture first = await tester.startGesture(
      middle + const Offset(-40, 40),
      kind: PointerDeviceKind.touch,
    );
    final TestGesture second = await tester.startGesture(
      middle + const Offset(40, 40),
      kind: PointerDeviceKind.touch,
    );
    const Duration step = Duration(milliseconds: 5);
    var sample = 0;
    for (int i = 0; i < 5; i++) {
      sample++;
      await first.moveBy(const Offset(0, -12), timeStamp: step * sample);
      sample++;
      await second.moveBy(const Offset(0, -12), timeStamp: step * sample);
    }
    for (int i = 0; i < 5; i++) {
      sample++;
      await first.moveBy(const Offset(0, 12), timeStamp: step * sample);
      sample++;
      await second.moveBy(const Offset(0, 12), timeStamp: step * sample);
    }
    await tester.pump();
    final double releasedAt = viewport.scrollOffset.dy;
    await first.up(timeStamp: step * (sample + 1));
    await second.up(timeStamp: step * (sample + 1));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 32));
    expect(viewport.scrollOffset.dy, lessThan(releasedAt));
  });

  testWidgets('momentum waits until the final scroll finger is released', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(
      tester,
      setup: _shortPage,
    );
    for (int i = 0; i < 8; i++) {
      document.appendPage();
    }
    await tester.pump();

    final Offset middle = tester.getCenter(find.byType(PageViewport));
    final TestGesture first = await tester.startGesture(
      middle + const Offset(-40, 40),
      kind: PointerDeviceKind.touch,
    );
    final TestGesture second = await tester.startGesture(
      middle + const Offset(40, 40),
      kind: PointerDeviceKind.touch,
    );
    const Duration step = Duration(milliseconds: 4);
    for (int i = 1; i <= 12; i++) {
      await first.moveBy(const Offset(0, -10), timeStamp: step * (2 * i - 1));
      await second.moveBy(const Offset(0, -10), timeStamp: step * (2 * i));
    }
    await tester.pump();
    final PageViewportState viewport = tester.state<PageViewportState>(
      find.byType(PageViewport),
    );

    await first.up(timeStamp: step * 25);
    final double oneFingerOffset = viewport.scrollOffset.dy;
    await tester.pump(const Duration(milliseconds: 32));
    expect(viewport.scrollOffset.dy, oneFingerOffset);
    expect(viewport.isScrolling, isFalse);

    await second.up(timeStamp: step * 26);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 32));
    expect(viewport.scrollOffset.dy, greaterThan(oneFingerOffset));
    expect(viewport.isScrolling, isTrue);
  });

  testWidgets('the page panel sets the size and background', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(tester);
    await _openPanel(tester);
    expect(find.text('Page settings'), findsOneWidget);
    expect(find.text('Page 1 of 1'), findsOneWidget);
    // The panel sits under the top bar, at its trailing end.
    final Rect panel = tester.getRect(find.byType(PagePanel));
    expect(
      panel.right,
      greaterThan(tester.getSize(find.byType(Scaffold)).width - 40),
    );
    expect(panel.width, lessThanOrEqualTo(PagePanel.width));
    expect(find.byKey(const ValueKey<String>('page-preview')), findsOneWidget);
    final Size portraitPreview = tester.getSize(
      find.byKey(const ValueKey<String>('page-preview')),
    );

    await _choose(tester, 'page-size-dropdown', 'A4 landscape');
    expect(document.current.setup.size, PageSize.a4Landscape);
    // The preview takes the new page's shape.
    final Size a4Preview = tester.getSize(
      find.byKey(const ValueKey<String>('page-preview')),
    );
    expect(a4Preview.height / a4Preview.width, closeTo(794 / 1123, 0.02));
    expect(a4Preview, isNot(portraitPreview));

    await _choose(tester, 'page-background-dropdown', 'Lined');
    await _closePanel(tester);
    expect(find.byType(PagePanel), findsNothing);

    expect(document.current.setup.size, PageSize.a4Landscape);
    expect(document.current.setup.background, PageBackground.lined);
    expect(
      find.byKey(const ValueKey<String>('page-background')),
      findsOneWidget,
    );
    expect(tester.getSize(find.byType(InkCanvas)), const Size(1123, 794));
  });

  testWidgets('hovering an overview arrow shows its tooltip', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(tester);
    document.addPage();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Page overview'));
    await tester.pumpAndSettle();

    // The panel hangs from a CompositedTransformFollower; a tooltip placed
    // across one used to throw as soon as a mouse or pencil hovered it.
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byTooltip('Previous page')));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
    final Finder panel = find.byType(PageOverviewPanel);
    final Finder tip = find.text('Previous page');
    expect(tip, findsOneWidget);
    // Shown beside the arrow, not somewhere else on the screen.
    expect(
      (tester.getCenter(tip) -
              tester.getCenter(find.byTooltip('Previous page')))
          .distance,
      lessThan(80),
    );
    expect(
      tester.getRect(panel).inflate(40).contains(tester.getCenter(tip)),
      isTrue,
    );
  });

  testWidgets('the top-left overview switches pages from a preview grid', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(tester);
    document.addPage();
    document.addPage();
    document.goTo(0);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Page overview'));
    await tester.pumpAndSettle();

    final Finder panel = find.byType(PageOverviewPanel);
    expect(panel, findsOneWidget);
    // It is the left side of the editor, top to bottom, with the top-left
    // card and the page moved over beside it.
    final Rect card = tester.getRect(
      find.byKey(const ValueKey<String>('history-card')),
    );
    final Rect pages = tester.getRect(find.byType(PageViewport));
    expect(tester.getRect(panel).left, 0);
    expect(tester.getRect(panel).top, card.top);
    expect(tester.getRect(panel).bottom, pages.bottom);
    expect(card.left, tester.getRect(panel).right);
    expect(pages.left, tester.getRect(panel).right);
    expect(
      find.byKey(const ValueKey<String>('page-overview-grid')),
      findsOneWidget,
    );
    // The page number shows in the overview.
    expect(
      find.descendant(
        of: panel,
        matching: find.byKey(const ValueKey<String>('page-number-button')),
      ),
      findsOneWidget,
    );

    // Its arrows step pages and leave it open, the grid following along.
    await tester.tap(find.byTooltip('Next page'));
    await tester.pumpAndSettle();
    expect(document.currentIndex, 1);
    expect(find.byType(PageOverviewPanel), findsOneWidget);
    await tester.tap(find.byTooltip('Previous page'));
    await tester.pumpAndSettle();
    expect(document.currentIndex, 0);

    // The bar stays usable while it shows: the grid button closes it, and
    // opens it again.
    await tester.tap(find.byTooltip('Page overview'));
    await tester.pumpAndSettle();
    expect(find.byType(PageOverviewPanel), findsNothing);
    await tester.tap(find.byTooltip('Page overview'));
    await tester.pumpAndSettle();
    expect(find.byType(PageOverviewPanel), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('page-thumbnail-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('page-thumbnail-2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('page-size-dropdown')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey<String>('page-thumbnail-2')));
    await tester.pumpAndSettle();

    // Beside the page it stays, to choose another or write on this one.
    expect(document.currentIndex, 2);
    expect(find.byType(PageOverviewPanel), findsOneWidget);
    await tester.tap(find.byTooltip('Page overview'));
    await tester.pumpAndSettle();
    expect(find.byType(PageOverviewPanel), findsNothing);
    expect(tester.getRect(find.byType(PageViewport)).left, 0);
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
      final Duration time = Duration(milliseconds: 200 * i);
      await a.moveBy(const Offset(0, -50), timeStamp: time);
      await b.moveBy(const Offset(0, -50), timeStamp: time);
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

  testWidgets('a mouse wheel scrolls a tall page', (WidgetTester tester) async {
    await _pumpDocument(
      tester,
      setup: const PageSetup(size: PageSize.a4Portrait),
    );
    final double top = canvasRect(tester).top;
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    final Offset middle = tester.getCenter(find.byType(PageViewport));
    await tester.sendEventToBinding(mouse.hover(middle));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
    await tester.pump();
    expect(canvasRect(tester).top, closeTo(top - 120, 0.5));
  });

  testWidgets('a whiteboard fills the area and pans past where it opened', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(
      tester,
      setup: const PageSetup(size: PageSize.infinite),
    );
    await _onlyStylusWrites(tester);
    final Finder surface = find.byType(PageViewport);
    final Rect area = tester.getRect(surface);
    // Edge to edge: no desk round it, wherever it is panned.
    expect(canvasRect(tester).contains(area.topLeft), isTrue);
    expect(
      canvasRect(tester).contains(area.bottomRight - const Offset(1, 1)),
      isTrue,
    );
    expect(
      find.byKey(const ValueKey<String>('page-scroll-indicators')),
      findsNothing,
    );
    // An empty board opens on its middle.
    const Offset o = InfiniteBoard.origin;
    expect(pageToGlobal(tester, o).dx, closeTo(area.center.dx, 1));
    expect(pageToGlobal(tester, o).dy, closeTo(area.center.dy, 1));

    // Fingers pan up and to the left of where it opened, far past it.
    for (int i = 0; i < 4; i++) {
      await tester.dragFrom(
        area.center,
        const Offset(400, 300),
        kind: PointerDeviceKind.touch,
      );
      await tester.pumpAndSettle();
    }
    expect(pageToGlobal(tester, o).dx, greaterThan(area.right + 500));
    expect(pageToGlobal(tester, o).dy, greaterThan(area.bottom + 300));
    expect(canvasRect(tester).contains(area.topLeft), isTrue);

    // Ink written there is on the board, above and left of its origin.
    await _drawLine(tester, area.center, area.center + const Offset(200, 0));
    final Stroke stroke = document.current.ink.strokes.single;
    expect(stroke.bounds.right, lessThan(o.dx));
    expect(stroke.bounds.bottom, lessThan(o.dy));
    expect(document.current.extent, isNull);
  });

  testWidgets('a whiteboard opens on its ink', (WidgetTester tester) async {
    const Offset o = InfiniteBoard.origin;
    final InkController ink = InkController(
      strokes: <Stroke>[
        Stroke.fromPoints(
          style: _pen,
          points: <InkVector>[
            InkVector(o.dx - 3000, o.dy - 2000),
            InkVector(o.dx - 2800, o.dy - 1900),
          ],
        ),
      ],
    );
    final NoteDocument document = NoteDocument(
      pages: <NotePage>[
        NotePage(
          ink: ink,
          setup: const PageSetup(size: PageSize.infinite),
        ),
      ],
    );
    addTearDown(document.dispose);
    await pumpApp(
      tester,
      viewport: TestViewport.tabletLandscape,
      home: EditorScreen(document: document),
    );
    final Rect area = tester.getRect(find.byType(PageViewport));
    final Offset middle = pageToGlobal(
      tester,
      ink.strokes.single.bounds.center,
    );
    expect(middle.dx, closeTo(area.center.dx, 1));
    expect(middle.dy, closeTo(area.center.dy, 1));
  });

  testWidgets('a whiteboard zooms far out, its rules thinned', (
    WidgetTester tester,
  ) async {
    await _pumpDocument(
      tester,
      setup: const PageSetup(
        size: PageSize.infinite,
        background: PageBackground.dotted,
      ),
    );
    await _onlyStylusWrites(tester);
    final Finder surface = find.byType(PageViewport);
    final Offset middle = tester.getCenter(surface);
    final TestGesture a = await tester.startGesture(
      middle - const Offset(300, 0),
      kind: PointerDeviceKind.touch,
    );
    final TestGesture b = await tester.startGesture(
      middle + const Offset(300, 0),
      kind: PointerDeviceKind.touch,
    );
    for (int i = 0; i < 10; i++) {
      await a.moveBy(const Offset(29, 0));
      await b.moveBy(const Offset(-29, 0));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await tester.pump();
    final PageViewportState viewport = tester.state<PageViewportState>(surface);
    expect(viewport.zoom, lessThan(0.1 + 1e-9));
    expect(viewport.zoom, greaterThanOrEqualTo(EditorScreen.boardMinZoom));
    final Rect area = tester.getRect(surface);
    expect(canvasRect(tester).contains(area.topLeft), isTrue);
    expect(tester.takeException(), isNull);
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
    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add blank page'));
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
    expect(
      second.top - first.bottom,
      closeTo(16 * EditorScreen.openingZoom, 0.01),
    );
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
    final NoteDocument document = await _pumpDocument(
      tester,
      setup: _shortPage,
    );
    document.addPage();
    document.goTo(0);
    await tester.pumpAndSettle();
    expect(document.currentIndex, 0);
    final Rect area = tester.getRect(find.byType(PageViewport));

    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(area.center));
    await tester.sendEventToBinding(mouse.scroll(Offset(0, area.height * 0.6)));
    await tester.pumpAndSettle();
    expect(document.currentIndex, 1);

    // Not through the overview: opening it narrows the page area, where these
    // short pages both fit and there is nothing to scroll.
    document.previousPage();
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

  testWidgets('a selection dragged onto another page moves there', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(
      tester,
      setup: const PageSetup(size: PageSize.square),
    );
    document.addPage();
    document.goTo(0);
    await tester.pumpAndSettle();
    // Scroll so the seam between the pages is in the middle of the area.
    final Rect area = tester.getRect(find.byType(PageViewport));
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(area.center));
    await tester.sendEventToBinding(
      mouse.scroll(
        Offset(0, tester.getRect(find.byType(InkCanvas).first).height / 2),
      ),
    );
    await tester.pumpAndSettle();
    final Rect first = tester.getRect(find.byType(InkCanvas).first);
    final Rect second = tester.getRect(find.byType(InkCanvas).last);
    expect(first.bottom, lessThan(area.bottom));
    expect(second.top, greaterThan(area.top));

    final Offset ink = Offset(first.left + 300, first.bottom - 60);
    await _drawLine(tester, ink, ink + const Offset(200, 0));
    await tester.tap(find.byTooltip('Select'));
    await tester.pumpAndSettle();
    await _drawLine(
      tester,
      ink + const Offset(-50, -40),
      ink + const Offset(250, 40),
    );
    expect(document.pages[0].ink.selection, isNotNull);

    // Grab the stroke and drag it down across the seam.
    final Offset grab = ink + const Offset(100, 0);
    final Offset drop = Offset(grab.dx, second.top + 100);
    final TestGesture gesture = await tester.startGesture(
      grab,
      kind: PointerDeviceKind.stylus,
    );
    for (int i = 1; i <= 10; i++) {
      await gesture.moveTo(Offset.lerp(grab, drop, i / 10)!);
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(document.pages[0].ink.strokes, isEmpty);
    final InkController target = document.pages[1].ink;
    expect(target.strokes, hasLength(1));
    expect(target.selection?.count, 1);
    expect(document.currentIndex, 1);
    // It is where it was let go, and the view did not move.
    expect(tester.getRect(find.byType(InkCanvas).last), second);
    final double scale =
        second.width / tester.getSize(find.byType(InkCanvas).last).width;
    final Stroke moved = target.strokes.single;
    expect(moved.bounds.center.dy, closeTo(100 / scale, 4));

    // One history for both pages: the arrival on the target goes first,
    // then the leaving of the first page, which is shown again.
    expect(document.undo(), isTrue);
    expect(target.strokes, isEmpty);
    expect(document.pages[0].ink.strokes, isEmpty);
    expect(document.undo(), isTrue);
    expect(document.pages[0].ink.strokes, hasLength(1));
    expect(document.currentIndex, 0);
  });

  testWidgets('selection and paste bars over another page can be pressed', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(
      tester,
      setup: const PageSetup(size: PageSize.square),
    );
    document.addPage();
    document.goTo(0);
    await tester.pumpAndSettle();
    // Scroll so the seam between the pages is in the middle of the area.
    final Rect area = tester.getRect(find.byType(PageViewport));
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(area.center));
    await tester.sendEventToBinding(
      mouse.scroll(
        Offset(0, tester.getRect(find.byType(InkCanvas).first).height / 2),
      ),
    );
    await tester.pumpAndSettle();
    final Rect first = tester.getRect(find.byType(InkCanvas).first);
    final Rect second = tester.getRect(find.byType(InkCanvas).last);

    // Ink at the very top of the second page, so its bar sits on the first.
    final Offset ink = Offset(second.left + 300, second.top + 30);
    await _drawLine(tester, ink, ink + const Offset(200, 0));
    await tester.tap(find.byTooltip('Select'));
    await tester.pumpAndSettle();
    await _drawLine(
      tester,
      ink + const Offset(-50, -20),
      ink + const Offset(250, 40),
    );
    final InkController page = document.pages[1].ink;
    expect(document.currentIndex, 1);
    expect(page.selection, isNotNull);
    expect(
      tester.getCenter(find.byTooltip('Duplicate')).dy,
      lessThan(first.bottom),
    );

    await tester.tap(find.byTooltip('Duplicate'));
    await tester.pumpAndSettle();

    expect(page.strokes, hasLength(2));
    expect(page.selection, isNotNull);
    expect(document.currentIndex, 1);
    expect(document.pages[0].ink.strokes, isEmpty);

    await tester.tap(find.byTooltip('Copy'));
    await tester.pumpAndSettle();
    expect(page.canPaste, isTrue);

    // Held near the top of the page, Paste is offered on the page above.
    final TestGesture hold = await tester.startGesture(
      Offset(second.left + 700, second.top + 10),
      kind: PointerDeviceKind.stylus,
    );
    await tester.pump(const Duration(milliseconds: 600));
    await hold.up();
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(find.byTooltip('Paste')).dy,
      lessThan(first.bottom),
    );

    await tester.tap(find.byTooltip('Paste'));
    await tester.pumpAndSettle();

    // Duplicate left only the new copy selected, so one stroke was copied.
    expect(page.strokes, hasLength(3));
    expect(document.currentIndex, 1);
    expect(document.pages[0].ink.strokes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a lasso dragged across pages selects strokes on both pages '
      'and moves them together', (WidgetTester tester) async {
    final NoteDocument document = await _pumpDocument(
      tester,
      setup: const PageSetup(size: PageSize.square),
    );
    document.addPage();
    document.goTo(0);
    await tester.pumpAndSettle();

    final Rect area = tester.getRect(find.byType(PageViewport));
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(area.center));
    await tester.sendEventToBinding(
      mouse.scroll(
        Offset(0, tester.getRect(find.byType(InkCanvas).first).height / 2),
      ),
    );
    await tester.pumpAndSettle();
    final Rect first = tester.getRect(find.byType(InkCanvas).first);
    final Rect second = tester.getRect(find.byType(InkCanvas).last);

    final Offset upperInk = Offset(first.left + 300, first.bottom - 50);
    final Offset lowerInk = Offset(second.left + 300, second.top + 50);
    await _drawLine(tester, upperInk, upperInk + const Offset(160, 0));
    await _drawLine(tester, lowerInk, lowerInk + const Offset(160, 0));
    expect(document.pages[0].ink.strokes, hasLength(1));
    expect(document.pages[1].ink.strokes, hasLength(1));

    await tester.tap(find.byTooltip('Select'));
    await tester.pumpAndSettle();

    // Drag a rectangle lasso starting on the first page and ending on the second.
    await _drawLine(
      tester,
      upperInk + const Offset(-40, -40),
      lowerInk + const Offset(200, 40),
    );
    await tester.pump();

    expect(document.pages[0].ink.selection?.count, 1);
    expect(document.pages[1].ink.selection?.count, 1);

    // Drag the combined selection sideways: both strokes move together,
    // staying on their respective pages with half above and half below.
    final Offset grab = upperInk + const Offset(80, 0);
    final double beforeX0 =
        document.pages[0].ink.strokes.single.bounds.center.dx;
    final double beforeX1 =
        document.pages[1].ink.strokes.single.bounds.center.dx;
    await _drawLine(tester, grab, grab + const Offset(100, 0));
    await tester.pump();

    expect(document.pages[0].ink.strokes, hasLength(1));
    expect(document.pages[1].ink.strokes, hasLength(1));
    expect(document.pages[0].ink.selection?.count, 1);
    expect(document.pages[1].ink.selection?.count, 1);
    expect(
      document.pages[0].ink.strokes.single.bounds.center.dx,
      greaterThan(beforeX0 + 50),
    );
    expect(
      document.pages[1].ink.strokes.single.bounds.center.dx,
      greaterThan(beforeX1 + 50),
    );
  });

  testWidgets('a selection released half on the previous page and half below '
      'stays on both pages without jumping and moves as one unit', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(
      tester,
      setup: const PageSetup(size: PageSize.square),
    );
    document.addPage();
    document.goTo(0);
    await tester.pumpAndSettle();

    final Rect area = tester.getRect(find.byType(PageViewport));
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(area.center));
    await tester.sendEventToBinding(
      mouse.scroll(
        Offset(0, tester.getRect(find.byType(InkCanvas).first).height / 2),
      ),
    );
    await tester.pumpAndSettle();
    final Rect first = tester.getRect(find.byType(InkCanvas).first);
    final Rect second = tester.getRect(find.byType(InkCanvas).last);

    // Draw a tall vertical stroke on the first page above the seam.
    final Offset strokeTop = Offset(first.left + 350, first.bottom - 140);
    final Offset strokeBottom = Offset(first.left + 350, first.bottom - 20);
    await _drawLine(tester, strokeTop, strokeBottom);
    expect(document.pages[0].ink.strokes, hasLength(1));

    await tester.tap(find.byTooltip('Select'));
    await tester.pumpAndSettle();
    await _drawLine(
      tester,
      strokeTop + const Offset(-40, -20),
      strokeBottom + const Offset(40, 20),
    );
    expect(document.pages[0].ink.selection?.count, 1);

    // Drag the stroke down by 80px so its top half remains on page 0
    // (first.bottom - 60) and its bottom half is on page 1 (second.top + 44).
    final Offset grab = Offset(first.left + 350, first.bottom - 80);
    final Offset straddleDrop = grab + const Offset(0, 80);
    final TestGesture drag = await tester.startGesture(
      grab,
      kind: PointerDeviceKind.stylus,
    );
    for (int i = 1; i <= 8; i++) {
      await drag.moveTo(Offset.lerp(grab, straddleDrop, i / 8)!);
      await tester.pump();
      // The viewport never jumps during cross-page dragging.
      expect(tester.getRect(find.byType(InkCanvas).first), first);
      expect(tester.getRect(find.byType(InkCanvas).last), second);
    }
    await drag.up();
    await tester.pumpAndSettle();

    // Both pages hold the straddling stroke and keep it selected together.
    expect(document.pages[0].ink.strokes, hasLength(1));
    expect(document.pages[1].ink.strokes, hasLength(1));
    expect(document.pages[0].ink.selection?.count, 1);
    expect(document.pages[1].ink.selection?.count, 1);

    // Grabbing the bottom half on page 1 and dragging the straddling selection
    // further down completely onto page 1 moves both linked copies as one unit
    // and removes the page 0 copy once it no longer overlaps page 0.
    final Offset grabOnSecond = Offset(second.left + 350, second.top + 20);
    final Offset fullDrop = grabOnSecond + const Offset(0, 120);
    await _drawLine(tester, grabOnSecond, fullDrop);
    await tester.pumpAndSettle();

    expect(document.pages[0].ink.strokes, isEmpty);
    expect(document.pages[0].ink.selection, isNull);
    expect(document.pages[1].ink.strokes, hasLength(1));
    expect(document.pages[1].ink.selection?.count, 1);
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
    await tester.tap(find.byTooltip('Settings'));
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

  testWidgets('with only stylus writing, one finger scrolls the page', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(
      tester,
      setup: const PageSetup(size: PageSize.a4Portrait),
    );
    await _onlyStylusWrites(tester);
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
    final NoteDocument document = await _pumpDocument(
      tester,
      setup: _shortPage,
    );
    await _onlyStylusWrites(tester);
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

  testWidgets('pinching a centered page does not scroll it vertically', (
    WidgetTester tester,
  ) async {
    await _pumpDocument(tester, setup: _shortPage);
    await _onlyStylusWrites(tester);
    final Offset focal = canvasRect(tester).center;
    final TestGesture a = await tester.startGesture(
      focal - const Offset(50, 0),
      kind: PointerDeviceKind.touch,
    );
    final TestGesture b = await tester.startGesture(
      focal + const Offset(50, 0),
      kind: PointerDeviceKind.touch,
    );

    await a.moveBy(const Offset(-50, 0));
    await b.moveBy(const Offset(50, 0));
    await tester.pump();
    expect(canvasRect(tester).center.dy, closeTo(focal.dy, 0.5));

    await a.moveBy(const Offset(50, 0));
    await b.moveBy(const Offset(-50, 0));
    await tester.pump();
    expect(canvasRect(tester).center.dy, closeTo(focal.dy, 0.5));

    await a.up();
    await b.up();
  });

  testWidgets('a whiteboard stays edge to edge when pinched out', (
    WidgetTester tester,
  ) async {
    await _pumpDocument(
      tester,
      setup: const PageSetup(size: PageSize.infinite),
    );
    await _onlyStylusWrites(tester);

    final Finder surface = find.byType(PageViewport);
    bool covers() {
      final Rect area = tester.getRect(surface);
      final Rect canvas = canvasRect(tester);
      return canvas.contains(area.topLeft) &&
          canvas.contains(area.bottomRight - const Offset(1, 1));
    }

    expect(covers(), isTrue);

    final Offset middle = tester.getCenter(surface);
    final TestGesture a = await tester.startGesture(
      middle - const Offset(100, 0),
      kind: PointerDeviceKind.touch,
    );
    final TestGesture b = await tester.startGesture(
      middle + const Offset(100, 0),
      kind: PointerDeviceKind.touch,
    );
    await a.moveBy(const Offset(50, 0));
    await b.moveBy(const Offset(-50, 0));
    await a.up();
    await b.up();
    await tester.pump();

    final PageViewportState viewport = tester.state<PageViewportState>(surface);
    expect(viewport.zoom, lessThan(1));
    expect(covers(), isTrue);
  });

  testWidgets('compact layouts reach page editing through settings', (
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

/// Two fingers moving up together by [distance], in steps, then let go.
Future<void> _pullUp(WidgetTester tester, Offset at, double distance) async {
  final TestGesture a = await tester.createGesture(
    kind: PointerDeviceKind.touch,
  );
  final TestGesture b = await tester.createGesture(
    kind: PointerDeviceKind.touch,
  );
  await a.down(at);
  await b.down(at + const Offset(80, 0));
  for (int i = 0; i < 10; i++) {
    await a.moveBy(Offset(0, -distance / 10));
    await b.moveBy(Offset(0, -distance / 10));
    await tester.pump();
  }
  await a.up();
  await b.up();
  await tester.pumpAndSettle();
}

void _pullTests() {
  testWidgets('pulled up past the last page, a page is added after it', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(
      tester,
      setup: _shortPage,
    );
    final Offset middle = tester.getCenter(find.byType(PageViewport));
    await _pullUp(tester, middle, 200);

    expect(document.pageCount, 2);
    // The new page waits below; the view stays on the page it was on.
    expect(document.currentIndex, 0);
    expect(document.pages.first.ink.strokes, isEmpty);
    expect(
      find.byKey(const ValueKey<String>('pull-to-add-page')),
      findsNothing,
    );
  });

  testWidgets('a short pull adds nothing', (WidgetTester tester) async {
    final NoteDocument document = await _pumpDocument(
      tester,
      setup: _shortPage,
    );
    final Offset middle = tester.getCenter(find.byType(PageViewport));
    await _pullUp(tester, middle, 60);

    expect(document.pageCount, 1);
  });

  testWidgets('a tall page scrolls to its end before the pull begins', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(
      tester,
      setup: const PageSetup(size: PageSize.a4Portrait),
    );
    final Offset middle = tester.getCenter(find.byType(PageViewport));
    await _pullUp(tester, middle + const Offset(0, 200), 150);
    expect(document.pageCount, 1);

    await _pullUp(tester, middle + const Offset(0, 200), 2000);
    expect(document.pageCount, 2);
  });
}

void _appendTests() {
  Rect firstPage(WidgetTester tester) =>
      tester.getRect(find.byType(InkCanvas).first);

  testWidgets('writing low on the last page adds one below, staying put', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(
      tester,
      setup: _shortPage,
    );
    final Rect before = firstPage(tester);
    final double y = before.top + before.height * 0.85;
    await _drawLine(
      tester,
      Offset(before.left + 100, y),
      Offset(before.left + 300, y),
    );
    await tester.pumpAndSettle();

    expect(document.pageCount, 2);
    expect(document.currentIndex, 0);
    expect(document.pages.last.ink.strokes, isEmpty);
    // The page written on has not moved.
    expect(firstPage(tester), before);

    // Writing low again adds nothing more: the last page is the new one.
    await _drawLine(
      tester,
      Offset(before.left + 100, y - 20),
      Offset(before.left + 300, y - 20),
    );
    await tester.pumpAndSettle();
    expect(document.pageCount, 2);
  });

  testWidgets('writing above three quarters adds nothing', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(
      tester,
      setup: _shortPage,
    );
    final Rect page = firstPage(tester);
    final double y = page.top + page.height * 0.6;
    await _drawLine(
      tester,
      Offset(page.left + 100, y),
      Offset(page.left + 300, y),
    );
    await tester.pumpAndSettle();
    expect(document.pageCount, 1);
  });

  testWidgets('a short, centered page does not move when one is added', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(
      tester,
      viewport: TestViewport.tabletPortrait,
      setup: const PageSetup(size: PageSize.a4Landscape),
    );
    final Rect before = firstPage(tester);
    final Rect area = tester.getRect(find.byType(PageViewport));
    // Centered: shorter than the area, with room above it.
    expect(before.top, greaterThan(area.top + 50));
    final double y = before.top + before.height * 0.9;
    await _drawLine(
      tester,
      Offset(before.left + 100, y),
      Offset(before.left + 300, y),
    );
    await tester.pumpAndSettle();

    expect(document.pageCount, 2);
    expect(firstPage(tester), before);
  });

  testWidgets('writing low on a whiteboard adds no page', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pumpDocument(
      tester,
      setup: const PageSetup(size: PageSize.infinite),
    );
    final Rect area = tester.getRect(find.byType(PageViewport));
    final double y = area.top + area.height * 0.9;
    await _drawLine(
      tester,
      Offset(area.left + 100, y),
      Offset(area.left + 300, y),
    );
    await tester.pumpAndSettle();
    expect(document.pageCount, 1);
  });

  testWidgets(
    'imported PDF document does not allow infinite canvas in page panel or document setup',
    (WidgetTester tester) async {
      final NoteDocument document = NoteDocument(
        pages: <NotePage>[
          NotePage(
            ink: InkController(),
            setup: const PageSetup(
              size: PageSize.custom,
              customSize: Size(800, 1100),
            ),
            pdfSource: const PdfPageSource(
              assetId: 'pdf1',
              pageIndex: 0,
              pageSize: Size(800, 1100),
            ),
          ),
        ],
      );
      addTearDown(document.dispose);
      expect(document.isImportedPdf, isTrue);

      // document.setSetup directly refuses infinite canvas
      document.setSetup(const PageSetup(size: PageSize.infinite));
      expect(document.current.setup.size, isNot(PageSize.infinite));

      // Adding a page also inherits custom PDF size, not infinite
      document.addPage();
      expect(document.pageCount, 2);
      expect(document.isImportedPdf, isTrue);
      expect(document.current.setup.size, isNot(PageSize.infinite));

      // Even on added page, setSetup refuses infinite
      document.setSetup(const PageSetup(size: PageSize.infinite));
      expect(document.current.setup.size, isNot(PageSize.infinite));

      await pumpApp(tester, home: EditorScreen(document: document));

      await _openPanel(tester);
      final Finder dropdown = find.byKey(
        const ValueKey<String>('page-size-dropdown'),
      );
      await tester.ensureVisible(dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();

      // Infinite option is not present
      expect(find.text('Infinite'), findsNothing);
      await _closePanel(tester);
    },
  );
}
