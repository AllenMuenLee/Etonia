import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/page/page_viewport.dart';
import 'package:greatnote/features/editor/widgets/tool_palette.dart';
import 'package:greatnote/features/editor/widgets/toolbar_layout.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/document_io/document_platform.dart';
import 'package:greatnote/features/library/library_screen.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/study_desk/practice/import_test_paper_sheet.dart';
import 'package:greatnote/features/library/study_desk/practice/study_practice_models.dart';
import 'package:greatnote/features/library/study_desk/practice/study_practice_store.dart';
import 'package:greatnote/features/library/study_desk/practice/study_test_paper_player.dart';
import 'package:greatnote/features/library/study_desk/practice/test_handwriting_canvas.dart';
import 'package:greatnote/features/library/study_desk/study_desk_controller.dart';
import 'package:greatnote/features/library/study_desk/study_desk_screen.dart';

import '../../../helpers/ai_fakes.dart';
import '../../../helpers/document_io_fakes.dart';
import '../../../helpers/pump_app.dart';

final _now = DateTime(2026, 11, 5);

StudyTestPaper _paper({List<TestReferenceSheet> sheets = const []}) =>
    StudyTestPaper(
      id: 'canvas-test',
      title: 'Algebra test',
      courseName: 'Math',
      instructions: 'Choose the best answer.',
      createdAt: _now,
      updatedAt: _now,
      referenceSheets: sheets,
      questions: const [
        TestMultipleChoiceQuestion(
          id: 'q1',
          prompt: '2 + 2?',
          points: 2,
          options: [
            PracticeChoiceOption(id: 'A', text: '4'),
            PracticeChoiceOption(id: 'B', text: '5'),
          ],
          correctOptionId: 'A',
        ),
      ],
    );

Future<StudyDeskController> _controller(StudyTestPaper paper) async {
  final repository = InMemoryNoteRepository();
  final client = FakeAiClient();
  final desk = StudyDeskController(
    repository: repository,
    client: client,
    practiceStore: InMemoryStudyPracticeStore(),
    clock: () => _now,
  );
  await desk.load();
  await desk.saveTestPaper(paper);
  addTearDown(() {
    desk.dispose();
    repository.dispose();
    client.close();
  });
  return desk;
}

Finder _key(String value) => find.byKey(ValueKey(value));

Future<void> _mount(
  WidgetTester tester,
  StudyDeskController desk, {
  Size size = const Size(1200, 900),
  ThemeMode theme = ThemeMode.light,
}) async {
  await pumpApp(
    tester,
    size: size,
    themeMode: theme,
    home: Scaffold(
      body: StudyTestPaperPlayer(
        paper: desk.testPapers.single,
        controller: desk,
        onClose: () {},
        onViewCitation: (_) {},
      ),
    ),
  );
}

void main() {
  testWidgets(
    'the chosen test tool is ready before writing on another question',
    (tester) async {
      final desk = await _controller(
        _paper().copyWith(
          questions: const [
            TestFreeResponseQuestion(
              id: 'first',
              prompt: 'First question',
              subParts: [],
              rubric: [],
              points: 5,
            ),
            TestFreeResponseQuestion(
              id: 'second',
              prompt: 'Second question',
              subParts: [],
              rubric: [],
              points: 5,
            ),
          ],
        ),
      );
      await _mount(tester, desk);
      final editor = tester.widget<EditorScreen>(find.byType(EditorScreen));
      final document = editor.document!;
      expect(find.byType(TestHandwritingCanvas), findsNothing);
      expect(find.byType(PageViewport), findsOneWidget);
      final palette = tester.widget<ToolPalette>(find.byType(ToolPalette));
      expect(palette.layout!.value.shown, [
        PaletteItem.pen,
        PaletteItem.eraser,
        PaletteItem.select,
        PaletteItem.ruler,
      ]);
      expect(palette.layout!.value.folded, isEmpty);
      expect(
        document.pages.every((p) => p.setup.customSize!.height > 1000),
        isTrue,
      );
      palette.tool.value = EditorTool.eraser;
      document.goTo(1);
      await tester.pumpAndSettle();
      expect(find.text('Second question'), findsOneWidget);
      for (final canvas in tester.widgetList<InkCanvas>(
        find.byType(InkCanvas),
      )) {
        expect(canvas.tool.value, EditorTool.eraser);
      }
      palette.tool.value = EditorTool.select;
      document.goTo(0);
      await tester.pumpAndSettle();
      for (final canvas in tester.widgetList<InkCanvas>(
        find.byType(InkCanvas),
      )) {
        expect(canvas.tool.value, EditorTool.select);
      }
      await tester.tap(_key('ruler-toggle'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<InkCanvas>(find.byType(InkCanvas).first).ruler!.isVisible,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'writing over the question uses the full note page and survives reopening',
    (tester) async {
      final desk = await _controller(_paper());
      await _mount(tester, desk);
      final finder = find.byType(InkCanvas);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('2 + 2?')),
        kind: PointerDeviceKind.stylus,
      );
      await gesture.moveBy(const Offset(20, 24));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      final canvas = tester.widget<InkCanvas>(finder);
      expect(canvas.controller.strokes, hasLength(1));
      final saved = desk.testPapers.single.questions.single.handwritingStrokes;
      expect(saved, isNotNull);
      expect(testInkPageSize(saved)!.height, greaterThan(1000));
      expect(decodeTestInk(saved), hasLength(1));
      await tester.pumpWidget(const SizedBox());
      await _mount(tester, desk);
      expect(tester.widget<InkCanvas>(finder).controller.strokes, hasLength(1));
      expect(
        tester.widget<InkCanvas>(finder).controller.strokes.single.points,
        decodeTestInk(saved).single.points,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final kind in [null, ...TestReferenceKind.values]) {
    testWidgets(
      'PDF import stores app-owned pages for ${kind?.name ?? 'tests'}',
      (tester) async {
        final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('test-canvas-import-'),
        ))!;
        addTearDown(() => directory.delete(recursive: true));
        const channel = MethodChannel('plugins.flutter.io/path_provider');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => directory.path,
        );
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final png = (await tester.runAsync(() => renderTestAnswer(null)))!;
        final picker = FakeDocumentPicker()
          ..pdf = PickedDocument(
            name: 'Exam.pdf',
            bytes: Uint8List.fromList([1, 2, 3]),
          );
        final rasterizer = FakePdfRasterizer(renderedPng: png);
        Future<Object?>? completed;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => FilledButton(
                  onPressed: () {
                    completed = showModalBottomSheet<Object>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => ImportTestPaperSheet(
                        picker: picker,
                        rasterizer: rasterizer,
                        referenceKind: kind,
                      ),
                    );
                  },
                  child: const Text('Open import'),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open import'));
        await tester.pumpAndSettle();
        Object? imported;
        unawaited(
          completed!.then((value) {
            imported = value;
          }),
        );
        await tester.tap(find.text('Choose PDF'));
        for (var i = 0; i < 400 && imported == null; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();
        expect(imported, isNotNull);
        final List<String> paths;
        if (kind == null) {
          final paper = imported! as StudyTestPaper;
          expect(paper.questions.single, isA<TestFreeResponseQuestion>());
          expect(paper.referenceSheets, isEmpty);
          paths = paper.importedImagePaths;
        } else {
          final sheet = imported! as TestReferenceSheet;
          expect(sheet.kind, kind);
          expect(sheet.name, 'Exam.pdf');
          paths = sheet.imagePaths;
        }
        expect(rasterizer.renderCalls, 1);
        await tester.runAsync(() async {
          expect(await File(paths.single).readAsBytes(), png);
        });
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('embedded choices save and Grade now locks the graded canvas', (
    tester,
  ) async {
    final desk = await _controller(_paper());
    await _mount(tester, desk, theme: ThemeMode.dark);
    expect(
      find.descendant(
        of: _key('test-paper-canvas'),
        matching: _key('test-mcq-widget-q1'),
      ),
      findsOneWidget,
    );
    expect(find.byType(ToolPalette), findsOneWidget);
    expect(
      Theme.of(tester.element(_key('test-mcq-widget-q1'))).brightness,
      Brightness.light,
    );
    final canvas = tester.widget<InkCanvas>(find.byType(InkCanvas));
    final choiceCenter = tester.getCenter(_key('test-option-q1-B'));
    expect(
      canvas.exclusionRects!().any((rect) => rect.contains(choiceCenter)),
      isTrue,
    );
    final pen = await tester.startGesture(
      choiceCenter,
      kind: PointerDeviceKind.stylus,
    );
    await pen.up();
    await tester.pumpAndSettle();
    expect(canvas.controller.strokes, isEmpty);
    await tester.tap(_key('test-option-q1-A'));
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
    expect(
      (desk.testPapers.single.questions.single as TestMultipleChoiceQuestion)
          .selectedOptionId,
      'A',
    );
    await tester.tap(find.text('Grade now'));
    await tester.pumpAndSettle();
    expect(desk.testPapers.single.totalScore, 2);
    expect(find.text('Grade now'), findsNothing);
    expect(find.byType(ToolPalette), findsNothing);
    expect(tester.widget<InkWell>(_key('test-option-q1-B')).onTap, isNull);
    final lockedCanvas = tester.widget<InkCanvas>(find.byType(InkCanvas));
    expect(lockedCanvas.enableNativeInk, isFalse);
    final count = lockedCanvas.controller.strokes.length;
    final attempt = await tester.startGesture(
      tester.getCenter(find.text('2 + 2?')),
      kind: PointerDeviceKind.stylus,
    );
    await attempt.moveBy(const Offset(20, 10));
    await attempt.up();
    await tester.pumpAndSettle();
    expect(lockedCanvas.controller.strokes, hasLength(count));
    await tester.pumpWidget(const SizedBox());
  });

  for (final size in [const Size(390, 844), const Size(1200, 900)]) {
    testWidgets('full note canvas layout at $size', (tester) async {
      final desk = await _controller(_paper());
      await _mount(tester, desk, size: size);
      await expectLater(
        find.byType(StudyTestPaperPlayer),
        matchesGoldenFile('goldens/test_note_canvas_${size.width.toInt()}.png'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('long questions grow the sheet while keeping room to write', (
    tester,
  ) async {
    final question = TestFreeResponseQuestion(
      id: 'long',
      prompt: List.filled(70, 'Explain the reasoning in detail.').join('\n\n'),
      subParts: const [],
      rubric: const [],
      points: 10,
    );
    final desk = await _controller(_paper().copyWith(questions: [question]));
    await _mount(tester, desk, size: const Size(390, 844));
    final document = tester
        .widget<EditorScreen>(find.byType(EditorScreen))
        .document!;
    expect(document.pages.single.setup.customSize!.height, greaterThan(3000));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an empty test opens a blank note canvas safely', (tester) async {
    final desk = await _controller(_paper().copyWith(questions: []));
    await _mount(tester, desk);
    expect(find.byType(PageViewport), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Grade now'))
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
  });

  for (final size in [const Size(390, 600), const Size(1200, 900)]) {
    testWidgets(
      'references preserve the canvas when toggled and resized at $size',
      (tester) async {
        final desk = await _controller(
          _paper(
            sheets: const [
              TestReferenceSheet(
                kind: TestReferenceKind.answerSheet,
                name: 'Marking key',
                imagePaths: ['missing-key-1.png', 'missing-key-2.png'],
              ),
              TestReferenceSheet(
                kind: TestReferenceKind.equationSheet,
                name: 'Formulas',
                imagePaths: ['missing-formulas.png'],
              ),
            ],
          ),
        );
        await _mount(tester, desk, size: size);
        await tester.pumpAndSettle();
        final originalInk = tester
            .widget<InkCanvas>(find.byType(InkCanvas))
            .controller;
        await tester.tap(find.byTooltip('Reference sheets'));
        await tester.pumpAndSettle();
        expect(_key('test-reference-panel'), findsOneWidget);
        expect(find.text('1 / 1'), findsOneWidget);
        if (size.width >= 820) {
          await tester.tap(find.text('Answer sheet'));
        } else {
          await tester.tap(find.byType(DropdownButton<TestReferenceKind>));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Answer sheet').last);
        }
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Next reference page'));
        await tester.pumpAndSettle();
        expect(find.text('2 / 2'), findsOneWidget);
        tester.view.physicalSize = size.width >= 820
            ? const Size(390, 600)
            : const Size(1200, 900);
        await tester.pumpAndSettle();
        await tester.pumpAndSettle();
        expect(
          tester.widget<InkCanvas>(find.byType(InkCanvas)).controller,
          same(originalInk),
        );
        await tester.tap(find.byTooltip('Close reference sheets'));
        await tester.pumpAndSettle();
        expect(_key('test-reference-panel'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets('open tests keep navigation and Back in the sidebar', (
    tester,
  ) async {
    final desk = await _controller(_paper());
    desk.openTestPaper(desk.testPapers.single);
    await pumpApp(
      tester,
      home: Scaffold(
        body: StudyDeskScreen(
          controller: desk,
          thumbnail: (_) => const SizedBox(),
          onEditCitation: (_) {},
          onAddSources: () {},
        ),
      ),
    );
    expect(find.text('Grade now'), findsOneWidget);
    expect(_key('study-add-sources'), findsNothing);
    expect(_key('study-toggle-history'), findsNothing);
    expect(_key('study-navigation-sidebar'), findsOneWidget);
    expect(find.byTooltip('Back to Tests'), findsNothing);
    await tester.tap(_key('study-sidebar-back'));
    await tester.pumpAndSettle();
    expect(_key('study-practice-studio'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'New note opens a test import that can be cancelled without a note',
    (tester) async {
      final repository = InMemoryNoteRepository();
      final client = FakeAiClient();
      addTearDown(repository.dispose);
      addTearDown(client.close);
      await pumpApp(
        tester,
        home: LibraryScreen(
          repository: repository,
          aiClient: client,
          clock: () => _now,
        ),
      );
      await tester.tap(find.byTooltip('New note'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import test'));
      await tester.pumpAndSettle();
      expect(find.byType(ImportTestPaperSheet), findsOneWidget);
      expect(find.text('Choose PDF'), findsOneWidget);
      expect(find.text('Choose Photo'), findsOneWidget);
      Navigator.of(tester.element(find.byType(ImportTestPaperSheet))).pop();
      await tester.pumpAndSettle();
      expect((await repository.list(null)).notes, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
