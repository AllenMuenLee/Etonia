# Implementation Prompt 30: Study Desk Practice Studio & Test Paper Redesign (Tests vs. Flashcards, In-Situ Handwriting Canvas, Real Exam Layout, AI Grading, and Chat-to-Test Bridge)

You are working in the **Greatnote** (`Etonia`) Flutter codebase. Redesign the **Practice Studio** inside Study Desk (`lib/features/library/study_desk/`) to separate flashcards and tests into two distinct modalities, provide a formal "Real Test Paper" exam experience with handwriting canvases for both MCQs and FRQs, enable importing user test papers with AI grading, and build a direct chat-to-test launch bridge.

---

## 1. What Currently Exists & Problems to Solve

### Current Architecture (`lib/features/library/study_desk/practice/`)
- `StudyPracticeSet` currently bundles both `flashcards` (`List<PracticeFlashcard>`) and `multipleChoiceQuestions` (`List<PracticeMultipleChoice>`) into a single mixed deck.
- `StudyPracticeStudioView` renders a unified hub that launches either `StudyFlashcardPlayer` or `StudyQuizPlayer`.
- There is currently no support for Free Response Questions (FRQ), no handwritten scratchpad or working canvas, no exam paper layout, and no workflow to import outside exams for automated AI evaluation.
- When studying in the chat, there is no direct conversational recommendation that proactively suggests an exam and takes the student directly to test taking.

### Redesign Goals
1. **Decouple Flashcards and Tests**: Separate Practice Studio into two distinct tabs/sections: **Flashcards** and **Tests**.
2. **Real Test Paper Exam Layout**: Present tests as authentic academic examination sheets with title block, instructions, point allocations, and structured problem cards.
3. **Dual Question Modalities with Handwriting Canvases**:
   - **MCQs**: Question stem + interactive option selector widgets (A, B, C, D) + collapsible/inline handwriting scratchpad for math derivations and scratch work.
   - **FRQs**: Multi-part question prompts + official handwriting answer canvas + structured rubrics.
4. **Import Custom Test Papers & AI Grading**: Allow importing user test papers (PDF or images), drawing handwritten solutions directly over them, and running multimodal AI grading.
5. **Chat-to-Test Recommendation Bridge**: In Chat, when the student completes a study milestone, provide an interactive banner/button to generate the test and navigate directly into the test paper player.

---

## 2. Data Model & Storage Refactoring (`lib/features/library/study_desk/practice/study_practice_models.dart`, `study_practice_store.dart`)

### 2.1 Domain Separation
Refactor `study_practice_models.dart` to clearly differentiate study modalities:

```dart
/// Represents the user's active studio section.
enum PracticeStudioSection { flashcards, tests }

/// Distinct flashcard deck.
@immutable
class StudyFlashcardDeck {
  const StudyFlashcardDeck({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.sourceNoteIds = const <String>[],
    this.flashcards = const <PracticeFlashcard>[],
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<String> sourceNoteIds;
  final List<PracticeFlashcard> flashcards;

  int get totalCards => flashcards.length;
  int get masteredCount => flashcards.where((f) => f.isMastered).length;
  double get masteryRate => totalCards == 0 ? 0 : masteredCount / totalCards;
}
```

### 2.2 Real Test Paper & Question Hierarchy
Model formal test papers, supporting both MCQ and FRQ with drawing stroke payloads:

```dart
enum TestQuestionKind { multipleChoice, freeResponse }

sealed class TestQuestion {
  String get id;
  String get prompt;
  int get points;
  String get topic;
  StudyCitation? get sourceCitation;
  Uint8List? get handwritingStrokes; // Encoded ink strokes drawn by user
}

@immutable
class TestMultipleChoiceQuestion implements TestQuestion {
  const TestMultipleChoiceQuestion({
    required this.id,
    required this.prompt,
    required this.options,
    required this.correctOptionId,
    this.points = 2,
    this.explanation = '',
    this.topic = '',
    this.sourceCitation,
    this.selectedOptionId,
    this.handwritingStrokes,
    this.isGraded = false,
  });

  @override final String id;
  @override final String prompt;
  @override final int points;
  @override final String topic;
  @override final StudyCitation? sourceCitation;
  @override final Uint8List? handwritingStrokes;

  final List<PracticeChoiceOption> options;
  final String correctOptionId;
  final String explanation;
  final String? selectedOptionId;
  final bool isGraded;

  bool get isCorrect => selectedOptionId != null && selectedOptionId == correctOptionId;

  TestMultipleChoiceQuestion copyWithSelected(String optionId) => ...
  TestMultipleChoiceQuestion copyWithStrokes(Uint8List strokes) => ...
}

@immutable
class TestFreeResponseQuestion implements TestQuestion {
  const TestFreeResponseQuestion({
    required this.id,
    required this.prompt,
    required this.subParts,
    required this.rubric,
    this.points = 10,
    this.topic = '',
    this.sourceCitation,
    this.modelAnswer = '',
    this.handwritingStrokes,
    this.aiEvaluation,
  });

  @override final String id;
  @override final String prompt;
  @override final int points;
  @override final String topic;
  @override final StudyCitation? sourceCitation;
  @override final Uint8List? handwritingStrokes;

  final List<String> subParts; // e.g. ["(a) Derive...", "(b) Calculate..."]
  final List<String> rubric;   // Key criteria evaluated by AI grader
  final String modelAnswer;
  final TestAiEvaluation? aiEvaluation;

  TestFreeResponseQuestion copyWithStrokes(Uint8List strokes) => ...
  TestFreeResponseQuestion copyWithEvaluation(TestAiEvaluation eval) => ...
}

@immutable
class TestAiEvaluation {
  const TestAiEvaluation({
    required this.awardedPoints,
    required this.maxPoints,
    required this.feedback,
    required this.breakdown,
    this.recognizedMathOrText = '',
  });

  final int awardedPoints;
  final int maxPoints;
  final String feedback;
  final List<String> breakdown;
  final String recognizedMathOrText;
}

@immutable
class StudyTestPaper {
  const StudyTestPaper({
    required this.id,
    required this.title,
    required this.courseName,
    required this.instructions,
    required this.createdAt,
    required this.updatedAt,
    this.sourceNoteIds = const <String>[],
    this.questions = const <TestQuestion>[],
    this.importedPdfPath,
    this.importedImagePaths = const <String>[],
    this.isSubmitted = false,
    this.submittedAt,
    this.totalScore,
  });

  final String id;
  final String title;
  final String courseName;
  final String instructions;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<String> sourceNoteIds;
  final List<TestQuestion> questions;
  final String? importedPdfPath;
  final List<String> importedImagePaths;
  final bool isSubmitted;
  final DateTime? submittedAt;
  final double? totalScore;

  int get totalPoints => questions.fold(0, (sum, q) => sum + q.points);
}
```

---

## 3. UI/UX: Practice Studio Redesign (`lib/features/library/study_desk/practice/`)

### 3.1 Segmented Studio Hub (`study_practice_studio_view.dart`)
1. **Studio Header Tabs**:
   - Provide a top segmented bar: `[ Flashcards (N decks) ]` | `[ Tests (N papers) ]`.
   - Switching between tabs maintains scroll position and filter state.
2. **Context Actions**:
   - In **Flashcards** tab: Primary action button `+ New Flashcard Deck`.
   - In **Tests** tab: Two primary actions:
     - `+ Generate Test Paper` (prompts for topic, number of MCQs, number of FRQs, difficulty).
     - `Import Test Paper` (picks a PDF or photo of a physical test).
3. **Test Paper Grid / List Card**:
   - Displays test title, course badge, question breakdown (`6 MCQs · 2 FRQs`), status chip (`Completed: 92%` or `In Progress`), and primary button (`Take Test` / `Review Graded Paper`).

### 3.2 Real Test Paper Player (`study_test_paper_player.dart`)
Design the test-taking environment to replicate the visual hierarchy of an authentic academic examination paper:
1. **Paper Header Block**:
   - University/Class title banner, Student Name placeholder, Date, Exam Title, Total Points (`100 Pts`), and estimated time limit.
   - Academic instructions box: *"Read all questions carefully. Show all working steps in the canvas provided for full credit."*
2. **MCQ Problem Component**:
   - Question index badge and point indicator (e.g. `Question 3 [4 Pts]`).
   - Clear markdown-rendered question stem with LaTeX math equations.
   - **Interactive Option Selector Widget**:
     - Large tactile option cards (A, B, C, D) with circular radio bubbles.
     - Selected option is clearly highlighted with `AppColors.selected` and high-contrast outline.
   - **Integrated Handwriting Scratchpad**:
     - A collapsible/dockable canvas right beneath the options labeled *"Scratchpad / Working Area (Apple Pencil / Stylus)"*.
     - Allows student to solve equations, scratch out choices, and write intermediate steps.
3. **FRQ Problem Component**:
   - Multi-part question prompts (e.g. `Part (a) [4 Pts]`, `Part (b) [6 Pts]`).
   - **In-Situ Handwriting Answer Box**:
     - A large, beautifully textured paper response area (college-ruled lines, grid paper, or blank paper options).
     - Built on Etonia's native ink canvas engine (`InkCanvas` / `DrawingCanvas`).
     - Includes a docked floating stylus toolbar: Pen (with stroke width & color presets), Highlighter, Stroke Eraser, Lasso, and Undo/Redo.
     - Full palm rejection and stylus-only mode support.
4. **Paper Footer & Submission**:
   - Sticky bottom bar showing completion progress: `8 of 10 answered`.
   - Primary action: `Submit Paper for AI Grading`.

---

## 4. Custom Test Paper Import & Multimodal AI Grading

### 4.1 Import Workflow
- Implement `ImportTestPaperSheet`:
  - Supports selecting a local PDF or image files (via `file_picker` or image picker).
  - Converts imported document pages into a test paper canvas where pages are rendered as high-resolution background layers.
  - Overlays transparent ink canvas layers on each page so students can write their solutions directly on the imported test paper.

### 4.2 Automated Multimodal AI Grading
- Implement `StudyTestGrader`:
  - Bundles:
    1. Question text, rubrics, and point values.
    2. MCQ selected options.
    3. Rendered PNG snapshots of the student's handwritten working process and FRQ solutions.
  - Sends to multimodal AI endpoint with structured system prompt:
    - *"You are an academic exam grader. Evaluate the student's handwritten responses against the rubric. Award partial credit for correct intermediate steps shown in the handwriting. Identify any conceptual or computational errors and provide constructive feedback."*
  - Populates `TestAiEvaluation` on each question.
  - Displays a comprehensive **Grading Report**:
    - Final letter grade and score (`87 / 100 · B+`).
    - Side-by-side view of the student's handwriting with AI annotations (green checkmarks, red callouts, and step-by-step point additions/deductions).
    - One-tap citations linking mistake concepts back to original notes in the notebook.

---

## 5. Chat-to-Test Bridge: In-Chat Recommendation & Instant Navigation

### 5.1 AI Test Recommendation in Chat
- Enhance `StudyDeskController` and chat prompt handling:
  - When the user finishes reviewing a topic or reaches a natural milestone in the chat, the AI includes a structured trigger block or `StudyDeskController` detects study completion.
- Render a dedicated **Test Recommendation Card** directly inside the chat transcript:
  - Icon: Exam / test paper glyph (`AppIcons.studyDesk`).
  - Title: *"Ready for a quick test on [Current Topic]?"*
  - Subtitle: *"Generated from the notes and explanations above (4 MCQs, 1 FRQ with handwriting canvas)."*
  - Quick CTA Button: `[ Generate Test & Start Now ]`.

### 5.2 Direct Navigation Pipeline
- When the user taps `[ Generate Test & Start Now ]`:
  1. Show inline loading spinner on the button.
  2. Call `controller.generateTestPaperFromActiveTopic()`.
  3. Switch `StudyDeskController.setMode(StudyDeskMode.practice)`.
  4. Set `PracticeStudioSection.tests`.
  5. Automatically launch the freshly generated `StudyTestPaper` directly in the `StudyTestPaperPlayer` without requiring the user to search for it.

---

## 6. Implementation Steps & Verification

1. **Model & Storage Migration**:
   - Create models in `lib/features/library/study_desk/practice/study_practice_models.dart`.
   - Update `study_practice_store.dart` to serialize and restore `StudyFlashcardDeck` and `StudyTestPaper` collections cleanly without breaking existing stored files.
2. **Build Test Player & Handwriting Canvas**:
   - Implement `StudyTestPaperPlayer` and in-situ `TestHandwritingCanvas` reusing Etonia's ink engine.
   - Verify smooth 120Hz Apple Pencil / stylus inking, pressure response, palm rejection, and eraser operations.
3. **Split Studio View**:
   - Refactor `StudyPracticeStudioView` to feature the segmented tab header (`Flashcards` vs `Tests`).
4. **Implement AI Grader & Paper Import**:
   - Implement image/PDF import workflow and AI multimodal grading service.
5. **Wire Chat Trigger**:
   - Add the test recommendation card in `study_desk_screen.dart` and wire direct navigation into the test player.
6. **Automated & Manual Tests**:
   - Write unit tests in `test/features/library/study_desk/study_test_paper_test.dart` verifying MCQ scoring, FRQ rubric evaluation, and serialization round-trips.
   - Test PDF export of completed handwritten test papers.
