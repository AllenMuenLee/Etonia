import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/features/editor/page/note_document.dart';
import 'package:greatnote/features/editor/widgets/page_controls.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  testWidgets('a page overview that was never opened is disposed cleanly', (
    WidgetTester tester,
  ) async {
    final NoteDocument doc = NoteDocument();
    addTearDown(doc.dispose);
    final ValueNotifier<bool> open = ValueNotifier<bool>(false);
    addTearDown(open.dispose);

    await tester.pumpWidget(
      _wrap(
        PageOverviewAnchor(
          open: open,
          document: doc,
          writingArea: const Size(800, 1000),
          child: const SizedBox(width: 120, height: 48),
        ),
      ),
    );
    // Leaving the editor unmounts it; its animation must not be made then,
    // from a context that can no longer be read.
    await tester.pumpWidget(_wrap(const SizedBox()));
    expect(tester.takeException(), isNull);
  });

  group('AddMenuButton', () {
    testWidgets('initial tap opens menu', (WidgetTester tester) async {
      int addPageCount = 0;
      int insertPdfCount = 0;

      await tester.pumpWidget(
        _wrap(
          AddMenuButton(
            onAddPage: () => addPageCount++,
            onInsertPdf: () => insertPdfCount++,
          ),
        ),
      );

      // Initially no menu is visible.
      expect(find.text('Insert PDF'), findsNothing);
      expect(find.text('Add blank page'), findsNothing);

      // Tap Add button.
      await tester.tap(find.byTooltip('Add'));
      await tester.pumpAndSettle();

      // Menu is now visible.
      expect(find.text('Insert PDF'), findsOneWidget);
      expect(find.text('Add blank page'), findsOneWidget);
      expect(addPageCount, 0);
      expect(insertPdfCount, 0);
    });

    testWidgets(
      'choosing Add blank page adds blank page and does not set button default; next tap opens menu again',
      (WidgetTester tester) async {
        int addPageCount = 0;
        int insertPdfCount = 0;

        await tester.pumpWidget(
          _wrap(
            AddMenuButton(
              onAddPage: () => addPageCount++,
              onInsertPdf: () => insertPdfCount++,
            ),
          ),
        );

        // Open menu.
        await tester.tap(find.byTooltip('Add'));
        await tester.pumpAndSettle();

        // Select "Add blank page".
        await tester.tap(find.text('Add blank page'));
        await tester.pumpAndSettle();

        expect(addPageCount, 1);
        expect(insertPdfCount, 0);
        expect(find.text('Add blank page'), findsNothing);

        // Tap Add button again - it should open menu again, NOT default to adding a page directly.
        await tester.tap(find.byTooltip('Add'));
        await tester.pumpAndSettle();

        expect(addPageCount, 1);
        expect(find.text('Insert PDF'), findsOneWidget);
        expect(find.text('Add blank page'), findsOneWidget);
      },
    );

    testWidgets(
      'choosing Insert PDF triggers onInsertPdf and does not set button default; next tap opens menu again',
      (WidgetTester tester) async {
        int addPageCount = 0;
        int insertPdfCount = 0;

        await tester.pumpWidget(
          _wrap(
            AddMenuButton(
              onAddPage: () => addPageCount++,
              onInsertPdf: () => insertPdfCount++,
            ),
          ),
        );

        // Open menu.
        await tester.tap(find.byTooltip('Add'));
        await tester.pumpAndSettle();

        // Choose "Insert PDF".
        await tester.tap(find.text('Insert PDF'));
        await tester.pumpAndSettle();

        expect(insertPdfCount, 1);
        expect(addPageCount, 0);
        expect(find.text('Insert PDF'), findsNothing);

        // Next tap opens the menu again, NOT directly inserting PDF.
        await tester.tap(find.byTooltip('Add'));
        await tester.pumpAndSettle();

        expect(insertPdfCount, 1);
        expect(find.text('Insert PDF'), findsOneWidget);
        expect(find.text('Add blank page'), findsOneWidget);
      },
    );

    testWidgets('tapping Add button toggles menu open and closed', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          AddMenuButton(
            onAddPage: () {},
            onInsertPdf: () {},
          ),
        ),
      );

      // Open menu.
      await tester.tap(find.byTooltip('Add'));
      await tester.pumpAndSettle();
      expect(find.text('Insert PDF'), findsOneWidget);

      // Tap again closes menu.
      await tester.tap(find.byTooltip('Add'));
      await tester.pumpAndSettle();
      expect(find.text('Insert PDF'), findsNothing);
    });
  });

  group('page navigation and actions', () {
    testWidgets('keeps navigation separate from settings and actions', (
      WidgetTester tester,
    ) async {
      final NoteDocument doc = NoteDocument();
      addTearDown(doc.dispose);
      doc.addPage(); // 2 pages total

      bool openedOverview = false;
      bool openedSettings = false;
      bool searched = false;

      await tester.pumpWidget(
        _wrap(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              PageNavigationControls(
                onOpenOverview: () => openedOverview = true,
              ),
              PageControls(
                document: doc,
                canFind: true,
                onFind: (_) => searched = true,
                onOpenSettings: () => openedSettings = true,
              ),
            ],
          ),
        ),
      );

      // The page number and the arrows live in the overview, not in the bar.
      expect(
        find.byKey(const ValueKey<String>('page-number-button')),
        findsNothing,
      );
      expect(find.byTooltip('Previous page'), findsNothing);
      expect(find.byTooltip('Next page'), findsNothing);
      expect(find.byTooltip('Find handwriting'), findsOneWidget);
      expect(find.byTooltip('Add'), findsOneWidget);
      expect(find.byTooltip('Page overview'), findsOneWidget);
      expect(find.byTooltip('Page settings'), findsOneWidget);

      // Tap search
      await tester.tap(find.byTooltip('Find handwriting'));
      await tester.pumpAndSettle();
      expect(searched, isTrue);

      await tester.tap(find.byTooltip('Page overview'));
      await tester.pumpAndSettle();
      expect(openedOverview, isTrue);

      await tester.tap(find.byTooltip('Page settings'));
      await tester.pumpAndSettle();
      expect(openedSettings, isTrue);
    });

    testWidgets('the overview header steps between pages with its arrows', (
      WidgetTester tester,
    ) async {
      final NoteDocument doc = NoteDocument();
      addTearDown(doc.dispose);
      doc.addPage(); // 2 pages total, on the second

      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: PageOverviewPanel.width,
            height: 600,
            child: PageOverviewPanel(
              document: doc,
              writingArea: const Size(800, 600),
            ),
          ),
        ),
      );

      await tester.tap(find.byTooltip('Previous page'));
      await tester.pumpAndSettle();
      expect(doc.currentIndex, 0);

      await tester.tap(find.byTooltip('Next page'));
      await tester.pumpAndSettle();
      expect(doc.currentIndex, 1);
    });

    testWidgets('the overview header shows the page number to type into', (
      WidgetTester tester,
    ) async {
      final NoteDocument doc = NoteDocument();
      addTearDown(doc.dispose);
      doc.addPage();
      doc.addPage();
      doc.addPage(); // 4 pages total
      doc.goTo(0);

      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: PageOverviewPanel.width,
            height: 600,
            child: PageOverviewPanel(
              document: doc,
              writingArea: const Size(800, 600),
            ),
          ),
        ),
      );

      expect(find.text('/ 4'), findsOneWidget);

      expect(doc.currentIndex, 0);
      final Finder button = find.byKey(
        const ValueKey<String>('page-number-button'),
      );
      expect(button, findsOneWidget);
      await tester.tap(button);
      await tester.pumpAndSettle();

      final Finder input = find.byKey(
        const ValueKey<String>('page-number-input'),
      );
      expect(input, findsOneWidget);

      // Type page 3 and submit
      await tester.enterText(input, '3');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();

      expect(doc.currentIndex, 2);
    });
  });
}
