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
  group('AddMenuButton', () {
    testWidgets('initial tap opens menu when no action is remembered', (
      WidgetTester tester,
    ) async {
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
      'choosing Add blank page remembers action; subsequent taps invoke directly',
      (WidgetTester tester) async {
        int addPageCount = 0;
        int insertPdfCount = 0;
        AddPageAction? lastReportedAction;

        await tester.pumpWidget(
          _wrap(
            AddMenuButton(
              onAddPage: () => addPageCount++,
              onInsertPdf: () => insertPdfCount++,
              onActionChanged: (AddPageAction a) => lastReportedAction = a,
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
        expect(lastReportedAction, AddPageAction.addPage);

        // Now tap Add button again - it should NOT open menu or dialog, but directly add page.
        await tester.tap(find.byTooltip('Add'));
        await tester.pumpAndSettle();

        expect(addPageCount, 2);
        expect(find.text('Insert PDF'), findsNothing);
        expect(find.text('Add blank page'), findsNothing);
      },
    );

    testWidgets(
      'choosing Insert PDF remembers action; subsequent taps invoke directly',
      (WidgetTester tester) async {
        int addPageCount = 0;
        int insertPdfCount = 0;
        AddPageAction? lastReportedAction;

        await tester.pumpWidget(
          _wrap(
            AddMenuButton(
              onAddPage: () => addPageCount++,
              onInsertPdf: () => insertPdfCount++,
              onActionChanged: (AddPageAction a) => lastReportedAction = a,
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
        expect(lastReportedAction, AddPageAction.insertPdf);

        // Next tap directly triggers insertPdf.
        await tester.tap(find.byTooltip('Add'));
        await tester.pumpAndSettle();

        expect(insertPdfCount, 2);
        expect(addPageCount, 0);
        expect(find.text('Insert PDF'), findsNothing);
      },
    );

    testWidgets('long press reopens menu allowing user to change action', (
      WidgetTester tester,
    ) async {
      int addPageCount = 0;
      int insertPdfCount = 0;
      AddPageAction? currentAction = AddPageAction.addPage;

      await tester.pumpWidget(
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            return _wrap(
              AddMenuButton(
                lastAction: currentAction,
                onAddPage: () => addPageCount++,
                onInsertPdf: () => insertPdfCount++,
                onActionChanged: (AddPageAction a) {
                  setState(() {
                    currentAction = a;
                  });
                },
              ),
            );
          },
        ),
      );

      // Normal tap does addPage directly.
      await tester.tap(find.byTooltip('Add'));
      await tester.pumpAndSettle();
      expect(addPageCount, 1);
      expect(insertPdfCount, 0);

      // Long press opens menu.
      await tester.longPress(find.byTooltip('Add'));
      await tester.pumpAndSettle();

      expect(find.text('Insert PDF'), findsOneWidget);

      // Switch to Insert PDF.
      await tester.tap(find.text('Insert PDF'));
      await tester.pumpAndSettle();

      expect(insertPdfCount, 1);
      expect(currentAction, AddPageAction.insertPdf);

      // Next tap directly invokes Insert PDF.
      await tester.tap(find.byTooltip('Add'));
      await tester.pumpAndSettle();

      expect(insertPdfCount, 2);
      expect(addPageCount, 1);
    });
  });

  group('PageControls and FloatingPageControls', () {
    testWidgets('shows previous, indicator, next, search, and add', (
      WidgetTester tester,
    ) async {
      final NoteDocument doc = NoteDocument();
      addTearDown(doc.dispose);
      doc.addPage(); // 2 pages total

      bool openedPanel = false;
      bool searched = false;

      await tester.pumpWidget(
        _wrap(
          FloatingPageControls(
            height: 48,
            width: FloatingPageControls.widthFor(
              48,
              find: true,
              navigation: true,
            ),
            child: PageControls(
              document: doc,
              showNavigation: true,
              canFind: true,
              onFind: (_) => searched = true,
              onOpenPanel: () => openedPanel = true,
            ),
          ),
        ),
      );

      expect(find.byTooltip('Previous page'), findsOneWidget);
      expect(find.text('2 / 2'), findsOneWidget);
      expect(find.byTooltip('Next page'), findsOneWidget);
      expect(find.byTooltip('Find handwriting'), findsOneWidget);
      expect(find.byTooltip('Add'), findsOneWidget);

      // Tap search
      await tester.tap(find.byTooltip('Find handwriting'));
      await tester.pumpAndSettle();
      expect(searched, isTrue);

      // Tap page indicator
      await tester.tap(find.byTooltip('Page setup'));
      await tester.pumpAndSettle();
      expect(openedPanel, isTrue);

      // Previous page
      await tester.tap(find.byTooltip('Previous page'));
      await tester.pumpAndSettle();
      expect(doc.currentIndex, 0);
      expect(find.text('1 / 2'), findsOneWidget);

      // Next page
      await tester.tap(find.byTooltip('Next page'));
      await tester.pumpAndSettle();
      expect(doc.currentIndex, 1);
      expect(find.text('2 / 2'), findsOneWidget);
    });

    testWidgets('allows typing in what page to go to in page number section', (
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
          PageControls(document: doc, showNavigation: true, onOpenPanel: () {}),
        ),
      );

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
