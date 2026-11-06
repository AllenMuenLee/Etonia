import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/study_desk/practice/study_generate_test_sheet.dart';
import 'package:greatnote/features/library/study_desk/practice/study_practice_models.dart';
import 'package:greatnote/features/library/study_desk/practice/study_practice_store.dart';
import 'package:greatnote/features/library/study_desk/practice/study_practice_studio_view.dart';
import 'package:greatnote/features/library/study_desk/study_desk_controller.dart';
import 'package:greatnote/features/library/study_desk/study_desk_models.dart';
import 'package:greatnote/features/library/study_desk/study_desk_screen.dart';
import 'package:greatnote/features/library/study_desk/study_desk_store.dart';
import 'package:greatnote/features/library/study_desk/study_source_picker.dart';

import '../../../helpers/ai_fakes.dart';
import '../../../helpers/pump_app.dart';

const _capture = bool.fromEnvironment('STUDY_DESIGN_CAPTURE');

void main() {
  for (final size in [
    const Size(320, 720),
    const Size(390, 844),
    const Size(800, 1000),
    const Size(1200, 900),
  ]) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 1.6]) {
        testWidgets('study layouts at $size, dark=$dark, text=$scale', (
          tester,
        ) async {
          setViewportSize(tester, size);
          if (_capture) {
            await tester.runAsync(() async {
              final fontPath = Platform.isWindows
                  ? 'C:/Windows/Fonts/segoeui.ttf'
                  : Platform.isMacOS
                  ? '/System/Library/Fonts/Supplemental/Arial.ttf'
                  : '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf';
              final bytes = await File(fontPath).readAsBytes();
              for (final family in [
                'StudyCapture',
                'Roboto',
                '.SF Pro Rounded',
              ]) {
                final font = FontLoader(family)
                  ..addFont(Future.value(ByteData.sublistView(bytes)));
                await font.load();
              }
            });
          }
          final now = DateTime(2026, 11, 5);
          final repository = InMemoryNoteRepository();
          final note = await repository.createNote(
            title: 'Mechanics · Chapter 01',
          );
          final client = FakeAiClient();
          final store = InMemoryStudyPracticeStore();
          final course = StudyCourse(
            id: 'physics',
            colorHex: '#A5A5A5',
            name: 'Physics & the natural world',
            createdAt: now,
            associatedNoteIds: [note.id],
          );
          final deck = StudyPracticeSet(
            id: 'layout-deck',
            title: 'Motion, forces & energy',
            createdAt: now,
            updatedAt: now,
            courseId: course.id,
            sourceNoteIds: [note.id],
            flashcards: const [
              PracticeFlashcard(
                id: 'card',
                frontPrompt: 'What does momentum describe?',
                backAnswer:
                    'The quantity of motion: mass multiplied by velocity.',
                topic: 'Mechanics',
              ),
            ],
          );
          await store.saveSet(deck);
          final paper = StudyTestPaper(
            id: 'layout-paper',
            title: 'Understanding motion',
            courseName: course.name,
            courseId: course.id,
            createdAt: now,
            updatedAt: now,
            instructions:
                'Take your time. Show your reasoning in the working area.',
            questions: const [
              TestMultipleChoiceQuestion(
                id: 'choice',
                prompt: 'Which quantity is conserved in an isolated system?',
                points: 2,
                options: [
                  PracticeChoiceOption(id: 'A', text: 'Momentum'),
                  PracticeChoiceOption(id: 'B', text: 'Velocity'),
                ],
                correctOptionId: 'A',
              ),
            ],
          );
          await store.savePaper(paper);
          final saved = InMemoryStudyDeskStore();
          await saved.write(StudyDeskState(courses: [course]));
          final desk = StudyDeskController(
            repository: repository,
            client: client,
            store: saved,
            practiceStore: store,
          );
          addTearDown(() {
            desk.dispose();
            repository.dispose();
            client.close();
          });
          await desk.load();
          desk.newChat(noteIds: [note.id]);
          final captureKey = GlobalKey();
          ThemeData theme = dark ? AppTheme.dark() : AppTheme.light();
          if (_capture) {
            theme = theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'StudyCapture'),
            );
          }

          Future<void> mount(Widget child) async {
            await tester.pumpWidget(
              MaterialApp(
                theme: theme,
                home: MediaQuery(
                  data: MediaQueryData(
                    size: size,
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: RepaintBoundary(
                    key: captureKey,
                    child: Scaffold(body: child),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
          }

          Future<void> check(String screen) async {
            expect(tester.takeException(), isNull, reason: screen);
            if (_capture && scale == 1) {
              final boundary =
                  captureKey.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              await tester.runAsync(() async {
                final image = await boundary.toImage();
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                image.dispose();
                final file = File(
                  'build/study_design/${size.width.toInt()}-${dark ? "dark" : "light"}-$screen.png',
                );
                await file.parent.create(recursive: true);
                await file.writeAsBytes(bytes!.buffer.asUint8List());
              });
            }
          }

          await mount(
            StudyDeskScreen(
              controller: desk,
              thumbnail: (_) => const SizedBox(),
              onEditCitation: (_) {},
              onAddSources: () {},
            ),
          );
          await check('chat');
          await tester.enterText(
            find.byKey(const ValueKey('study-composer')),
            'Explain how momentum is conserved.',
          );
          expect(
            tester.getSize(find.byTooltip('Send')).height,
            greaterThanOrEqualTo(48),
          );
          desk.openCourse(course);
          await tester.pumpAndSettle();
          await check('class');
          desk.setMode(StudyDeskMode.practice);
          await tester.pumpAndSettle();
          await check('decks');
          await tester.enterText(
            find.byKey(const ValueKey('study-material-search')),
            'no matching title',
          );
          await tester.pumpAndSettle();
          expect(find.text('No matching material'), findsOneWidget);
          await tester.tap(find.byTooltip('Clear search'));
          await tester.pumpAndSettle();
          desk.setPracticeSection(PracticeStudioSection.tests);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('practice-deck-layout-deck')),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey('study-paper-layout-paper')),
            findsOneWidget,
          );
          desk.setPracticeSection(PracticeStudioSection.flashcards);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('study-paper-layout-paper')),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey('practice-deck-layout-deck')),
            findsOneWidget,
          );
          desk.openFlashcardSet(deck);
          await tester.pumpAndSettle();
          await check('flashcard');
          await tester.tap(find.byKey(const ValueKey('flashcard-drag')));
          await tester.pumpAndSettle();
          await check('answer');
          desk.closeFlashcardSet();
          desk.setPracticeSection(PracticeStudioSection.tests);
          await tester.pumpAndSettle();
          await check('tests');
          desk.openTestPaper(paper);
          await tester.pumpAndSettle();
          await check('paper');
          await tester.tap(find.byTooltip('Reference sheets'));
          await tester.pumpAndSettle();
          await check('references');
          desk.closeTestPaper();
          await tester.pumpAndSettle();
          final graded = paper.copyWith(isSubmitted: true, totalScore: 2);
          await desk.saveTestPaper(graded);
          desk.openTestReview(graded);
          await tester.pumpAndSettle();
          await check('review');
          if (size.width < 840) {
            await tester.tap(find.byTooltip('Close graded paper'));
            await tester.pumpAndSettle();
          }
          await mount(StudySourcePicker(controller: desk));
          await tester.enterText(
            find.byKey(const ValueKey('study-source-search')),
            'nothing matches',
          );
          await tester.pumpAndSettle();
          expect(find.text('No notes found.'), findsOneWidget);
          await check('sources');
          await mount(StudyGenerateTestSheet(controller: desk));
          await check('generate');
          await mount(StudyGenerateSheet(controller: desk));
          await check('generate-flashcards');
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }
}
