@Tags(<String>['golden'])
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/page/note_document.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';

import '../../helpers/pump_app.dart';

List<Stroke> _ink() {
  Stroke wave(double y, double width) {
    return Stroke.fromPoints(
      style: StrokeStyle(ink: InkPalette.ink, width: width),
      points: <InkVector>[
        for (int i = 0; i <= 60; i++)
          InkVector(110 + i * 5, y + 10 * math.sin(i / 4)),
      ],
    );
  }

  return <Stroke>[wave(150, 3), wave(214, 3), wave(278, 5)];
}

Future<NoteDocument> _pump(
  WidgetTester tester,
  PageSetup setup, {
  TestViewport viewport = TestViewport.tabletLandscape,
  ThemeMode themeMode = ThemeMode.light,
}) async {
  final NoteDocument document = NoteDocument(
    pages: <NotePage>[
      NotePage(
        ink: InkController(strokes: _ink()),
        setup: setup,
      ),
    ],
  );
  addTearDown(document.dispose);
  await pumpApp(
    tester,
    viewport: viewport,
    themeMode: themeMode,
    home: EditorScreen(document: document),
  );
  return document;
}

void main() {
  testWidgets('page: lined_a4_tablet_portrait_light', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      const PageSetup(
        size: PageSize.a4Portrait,
        background: PageBackground.lined,
      ),
      viewport: TestViewport.tabletPortrait,
    );
    await expectLater(
      find.byType(GreatnoteApp),
      matchesGoldenFile('goldens/page_lined_a4_tablet_portrait_light.png'),
    );
  });

  testWidgets('page: grid_infinite_tablet_landscape_dark', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      const PageSetup(size: PageSize.infinite, background: PageBackground.grid),
      themeMode: ThemeMode.dark,
    );
    await expectLater(
      find.byType(GreatnoteApp),
      matchesGoldenFile('goldens/page_grid_infinite_tablet_landscape_dark.png'),
    );
  });

  testWidgets('page: dotted_letter_landscape_compact_light', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      const PageSetup(
        size: PageSize.letterLandscape,
        background: PageBackground.dotted,
      ),
      viewport: TestViewport.compact,
    );
    await expectLater(
      find.byType(GreatnoteApp),
      matchesGoldenFile('goldens/page_dotted_letter_compact_light.png'),
    );
  });

  testWidgets('page panel: tablet_landscape_light', (
    WidgetTester tester,
  ) async {
    final NoteDocument document = await _pump(
      tester,
      const PageSetup(background: PageBackground.grid),
    );
    document.addPage();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Page setup'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(GreatnoteApp),
      matchesGoldenFile('goldens/page_panel_tablet_landscape_light.png'),
    );
  });

  testWidgets('pages: gap_tablet_landscape_light', (WidgetTester tester) async {
    final NoteDocument document = await _pump(
      tester,
      const PageSetup(
        size: PageSize.letterLandscape,
        background: PageBackground.lined,
      ),
    );
    document.addPage();
    await tester.pumpAndSettle();
    // Back up a little, so the end of page 1 and the top of page 2 show.
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(const Offset(600, 400)));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -300)));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(GreatnoteApp),
      matchesGoldenFile('goldens/pages_gap_tablet_landscape_light.png'),
    );
  });

  testWidgets('pen options: tablet_landscape_light', (
    WidgetTester tester,
  ) async {
    await _pump(tester, const PageSetup());
    await tester.tap(find.byTooltip('Pen'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(GreatnoteApp),
      matchesGoldenFile('goldens/pen_options_tablet_landscape_light.png'),
    );
  });
}
