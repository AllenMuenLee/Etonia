import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../../app/theme/app_theme.dart';
import 'practice/study_material_library.dart';
import 'practice/study_practice_models.dart';

@Preview(
  name: 'Flashcard library - Light',
  group: 'Study Desk',
  size: Size(980, 760),
)
Widget studyDeskLightPreview() => _preview(false);

@Preview(name: 'Test library - Dark', group: 'Study Desk', size: Size(390, 844))
Widget studyDeskDarkPreview() => _preview(true);

Widget _preview(bool dark) {
  final now = DateTime(2026, 11, 5);
  return MaterialApp(
    theme: dark ? AppTheme.dark() : AppTheme.light(),
    home: Scaffold(
      body: StudyMaterialLibrary(
        decks: [
          StudyPracticeSet(
            id: 'mechanics',
            title: 'Motion, forces & energy',
            createdAt: now,
            updatedAt: now,
            flashcards: const [
              PracticeFlashcard(
                id: 'card',
                frontPrompt: 'What does momentum describe?',
                backAnswer: 'Mass multiplied by velocity.',
              ),
            ],
          ),
        ],
        papers: [
          StudyTestPaper(
            id: 'paper',
            title: 'Understanding motion',
            courseName: 'Physics',
            instructions: 'Show your reasoning.',
            createdAt: now,
            updatedAt: now,
            questions: const [
              TestMultipleChoiceQuestion(
                id: 'question',
                prompt: 'Which quantity is conserved in an isolated system?',
                options: [
                  PracticeChoiceOption(id: 'A', text: 'Momentum'),
                  PracticeChoiceOption(id: 'B', text: 'Velocity'),
                ],
                correctOptionId: 'A',
              ),
            ],
          ),
        ],
        groupByCourse: true,
        courseNames: const {'physics': 'Physics'},
        section: dark
            ? PracticeStudioSection.tests
            : PracticeStudioSection.flashcards,
        onSection: (_) {},
        onGenerateFlashcards: () {},
        onGenerateTest: () {},
        onImport: () {},
        onOpenDeck: (_) {},
        onOpenPaper: (_) {},
        onExportDeck: (_) {},
        onManageDeck: (_) {},
        sourceLabel: (_) => 'Mechanics notes',
      ),
    ),
  );
}
