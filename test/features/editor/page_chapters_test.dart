import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/features/editor/document_io/document_models.dart';
import 'package:greatnote/features/editor/document_io/document_platform.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/page/note_document.dart';
import 'package:greatnote/features/editor/widgets/page_chapters.dart';
import 'package:greatnote/features/editor/widgets/page_controls.dart';

NotePage _pdfPage(String assetId, int pageIndex) => NotePage(
  ink: InkController(),
  pdfSource: PdfPageSource(
    assetId: assetId,
    pageIndex: pageIndex,
    pageSize: const Size(612, 792),
  ),
);

NotePage _blankPage() => NotePage(ink: InkController());

const List<PdfOutlineEntry> _bookOutline = <PdfOutlineEntry>[
  PdfOutlineEntry(title: 'Preface', pageIndex: 0),
  PdfOutlineEntry(
    title: 'Chapter 1',
    pageIndex: 1,
    children: <PdfOutlineEntry>[
      PdfOutlineEntry(title: 'Section 1.1', pageIndex: 1),
      PdfOutlineEntry(title: 'Section 1.2', pageIndex: 2),
    ],
  ),
  PdfOutlineEntry(title: 'Chapter 2', pageIndex: 3),
];

void main() {
  group('noteChapters', () {
    test('opens each entry at the note page showing its PDF page', () {
      // A blank page added before the PDF shifts every chapter by one.
      final List<NotePage> pages = <NotePage>[
        _blankPage(),
        for (int i = 0; i < 4; i++) _pdfPage('book', i),
      ];
      final List<NoteChapter> chapters = noteChapters(
        pages,
        const <String, List<PdfOutlineEntry>>{'book': _bookOutline},
      );

      expect(
        chapters.map((NoteChapter c) => (c.title, c.pageIndex)).toList(),
        <(String, int)>[('Preface', 1), ('Chapter 1', 2), ('Chapter 2', 4)],
      );
      expect(
        chapters[1].children
            .map((NoteChapter c) => (c.title, c.pageIndex))
            .toList(),
        <(String, int)>[('Section 1.1', 2), ('Section 1.2', 3)],
      );
    });

    test('falls back to a remaining section, and drops what is gone', () {
      // PDF pages 0 and 1 were deleted from the note.
      final List<NotePage> pages = <NotePage>[
        _pdfPage('book', 2),
        _pdfPage('book', 3),
      ];
      final List<NoteChapter> chapters = noteChapters(
        pages,
        const <String, List<PdfOutlineEntry>>{'book': _bookOutline},
      );

      expect(
        chapters.map((NoteChapter c) => (c.title, c.pageIndex)).toList(),
        <(String, int)>[('Chapter 1', 0), ('Chapter 2', 1)],
      );
      expect(chapters.first.children.single.title, 'Section 1.2');
    });

    test('lists the chapters of each PDF in the order the note shows it', () {
      final List<NotePage> pages = <NotePage>[
        _pdfPage('second', 0),
        _pdfPage('first', 0),
      ];
      final List<NoteChapter> chapters = noteChapters(
        pages,
        const <String, List<PdfOutlineEntry>>{
          'first': <PdfOutlineEntry>[PdfOutlineEntry(title: 'A', pageIndex: 0)],
          'second': <PdfOutlineEntry>[
            PdfOutlineEntry(title: 'B', pageIndex: 0),
          ],
        },
      );

      expect(chapters.map((NoteChapter c) => c.title), <String>['B', 'A']);
    });
  });

  test('chapterPathAt finds the innermost chapter at a page', () {
    final List<NoteChapter> chapters = noteChapters(
      <NotePage>[for (int i = 0; i < 4; i++) _pdfPage('book', i)],
      const <String, List<PdfOutlineEntry>>{'book': _bookOutline},
    );

    expect(chapterPathAt(chapters, 2).map((NoteChapter c) => c.title), <String>[
      'Chapter 1',
      'Section 1.2',
    ]);
    // A section opening on its chapter's first page is the nearer one.
    expect(chapterPathAt(chapters, 1).map((NoteChapter c) => c.title), <String>[
      'Chapter 1',
      'Section 1.1',
    ]);
    expect(chapterPathAt(chapters, 3).map((NoteChapter c) => c.title), <String>[
      'Chapter 2',
    ]);
  });

  group('page overview chapters', () {
    Future<NoteDocument> pumpPanel(
      WidgetTester tester, {
      required List<PdfOutlineEntry> outline,
      VoidCallback? onSelected,
    }) async {
      final NoteDocument doc = NoteDocument(
        pages: <NotePage>[for (int i = 0; i < 4; i++) _pdfPage('book', i)],
      );
      addTearDown(doc.dispose);
      final NoteChapterIndex index = NoteChapterIndex(
        document: doc,
        loadOutline: (String assetId) async => outline,
      );
      addTearDown(index.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: PageOverviewPanel.width,
                height: 600,
                child: PageOverviewPanel(
                  document: doc,
                  writingArea: const Size(800, 600),
                  chapters: index,
                  onSelected: onSelected,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return doc;
    }

    testWidgets('offers chapters only when the PDF has an outline', (
      WidgetTester tester,
    ) async {
      await pumpPanel(tester, outline: const <PdfOutlineEntry>[]);

      expect(
        find.byKey(const ValueKey<String>('page-overview-chapters')),
        findsNothing,
      );
      expect(find.text('Chapters'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('page-overview-grid')),
        findsOneWidget,
      );
    });

    testWidgets('choosing a chapter goes to its page', (
      WidgetTester tester,
    ) async {
      int selected = 0;
      final NoteDocument doc = await pumpPanel(
        tester,
        outline: _bookOutline,
        onSelected: () => selected++,
      );
      doc.goTo(0);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Chapters'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('page-overview-grid')),
        findsNothing,
      );
      // Sections start folded away, outside the chapter at the current page.
      expect(find.text('Section 1.2'), findsNothing);

      await tester.tap(find.text('Chapter 2'));
      await tester.pumpAndSettle();
      expect(doc.currentIndex, 3);
      expect(selected, 1);
    });

    testWidgets('a chapter opens to show its sections', (
      WidgetTester tester,
    ) async {
      final NoteDocument doc = await pumpPanel(tester, outline: _bookOutline);
      doc.goTo(0);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chapters'));
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Expand sections'));
      await tester.pumpAndSettle();
      // Opening the chapter does not go to it.
      expect(doc.currentIndex, 0);

      await tester.tap(find.text('Section 1.2'));
      await tester.pumpAndSettle();
      expect(doc.currentIndex, 2);
    });
  });
}
