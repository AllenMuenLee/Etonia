# Implementation Prompt 28: Study Desk In-Situ Editing, Practice Studio (Quizzes & Flashcards), and Printable Handwritten Test Generator

You are working in the **Greatnote** (`Etonia`) Flutter repository. Extend the **Study Desk** workspace (`StudyDesk.title`) to provide:
1. **In-Situ Note Editing**: When tapping "Edit" on a cited note preview, directly mount the drawing tools and toolbar in-place inside the inspection pane—eliminating disruptive full-screen page transitions into the main note editor.
2. **Practice Studio (Flashcards & Multiple Choice)**: A built-in, beautifully designed practice widget to generate, review, save, and manage AI-crafted interactive flashcards and multiple-choice quizzes from active study sources.
3. **Printable / Handwritten Test PDF Generator**: Export generated tests as clean, academic-grade PDFs featuring dedicated handwriting rule lines/boxes modeled after Etonia's paper templates, allowing users to print them or solve them by hand with Apple Pencil.

---

## 1. What Currently Exists (Baseline Architecture Inventory)

Before adding new capabilities, the following Study Desk components are currently active in the codebase:

1. **Navigation & Entry Point (`lib/features/library/library_screen.dart`)**:
   - Primary `StudyDesk` row in `_FolderSidebar` located above the folder hierarchy with active source counter badge.
   - Drag-and-drop target (`_DropTarget`) allowing notes or entire folder trees to be dropped directly onto the sidebar row to populate the study context.
   - Dynamic top bar (`_StudyDeskBar`) replacing standard folder controls when Study Desk is open.
   - Round-trip navigation tracking (`_openedFromStudyDesk`), where tapping the current "Edit Note" button opens `_openNote(note)` into `EditorScreen` and uses `PopScope` to return to Study Desk on back gesture.

2. **State & Persistence (`lib/features/library/study_desk/study_desk_models.dart`, `study_desk_store.dart`)**:
   - `StudyDeskController` manages active session state, source selections, transcript messages, and citation focus.
   - `StudyDeskStore` persists active sessions and source note IDs to `<libraryDir>/study_desk.json`.
   - Models include `StudySession`, `StudySourceItem`, `StudyChunk`, `StudyChunkKind`, `StudyCitation`, and `StudyParagraphLinks`.

3. **Multi-Modal Handwriting & Diagram RAG (`lib/features/library/study_desk/study_rag_index.dart`)**:
   - **Stage 1 (Spatial 2D Chunking)**: `StudyChunker` unites strokes, recognized handwriting words (`StoredRecognizedInkWord`), typed text, and SVGs/diagrams within 32pt proximity into bounded 2D clusters (`StudyChunkKind.text`, `diagram`, `mixed`). Diagrams harvest nearby handwriting labels as anchors.
   - **Stage 2 (Hybrid Retrieval)**: `StudyContextAssembler` runs BM25 + fuzzy trigrams with diagram intent boost, capping context to Top-5 chunks (~3,000 token budget) and selectively cropping only visual chunks via `SelectionImageRenderer`.

4. **Study Chat UX (`lib/features/library/study_desk/study_desk_screen.dart`)**:
   - Chat transcript rendering with `GptMarkdown` and LaTeX math (`chat_math.dart`).
   - Quick starter prompt chips ("Summarize key concepts", "Quiz me on these notes", "Explain the diagrams", "Find connections & gaps").
   - Voice dictation (`SpeechToText`), model picker (`AiModelId`), and credit gating (`AiUsageGate`).

5. **Citation Inspection Pane (`lib/features/library/study_desk/study_citation_preview.dart`)**:
   - Responsive presentation: side-by-side pane on `WindowSizeClass.expanded`; modal sheet on compact/medium screens.
   - Interactive zoom/pan viewport (`InteractiveViewer`) that auto-animates (`Matrix4Tween`) to center cited ink and diagram bounding boxes with 24pt padding.
   - Visual marks: `AiCitationMarks` paints `#FFE600` under cited strokes and `#E5342B` rings around diagrams.
   - Top header with note title, page counter, and an **"Edit Note"** button which currently navigates out of Study Desk into the primary editor.

---

## 2. In-Situ In-Place Note Editing (`lib/features/library/study_desk/study_in_situ_editor.dart`)

### Objective
Eliminate full-screen navigation away from Study Desk when editing a cited page. When the user taps **"Edit"**, the inspection pane immediately transforms into an active inking surface with a docked/floating toolbar.

### Implementation Details

1. **In-Situ Inking Surface (`StudyInSituEditor`)**:
   - In `_CitedPage` / `StudyCitationPreview`, maintain an editing state enum: `_InspectionMode.preview` vs. `_InspectionMode.editing`.
   - When entering `editing`:
     - Load an active `InkController` initialized with the page's existing strokes (`_page.strokes`) and elements.
     - Replace the read-only `NoteThumbnailPainter` ink layer with a live interactive `DrawingCanvas` / `InkCanvas` layer.
     - Support Apple Pencil and stylus inking, pressure sensitivity, and direct finger drawing.
     - Two-finger drag and pinch seamlessly pan and zoom the page without leaving ink marks.

2. **Context-Adaptive Study Toolbar (`StudyInSituToolbar`)**:
   - Mount a sleek, compact floating toolbar anchored to the top or bottom edge of the inspection pane (built with `GlassSurface` and `AppRadii.lg`).
   - Essential tool set tailored for study annotation:
     - **Pen** (with 3 quick-color presets: Black/White, Blue, Red and stroke width slider).
     - **Highlighter** (Yellow `#FFE600`, Mint Green `#4CD964`, Pastel Pink `#FF2D55` with semi-transparent blending).
     - **Eraser** (stroke eraser and area eraser toggle).
     - **Lasso / Selection Tool** (move, duplicate, or delete handwritten annotations).
     - **Undo / Redo** action buttons.
     - **Clear Annotations** option.

3. **Header Mode Transition & Auto-Commit**:
   - In `_Header`:
     - When `_InspectionMode.preview`: Display **"Edit Note"** button (`FilledButton.tonalIcon` with `AppIcons.pen`).
     - When `_InspectionMode.editing`: Display **"Done"** (`FilledButton` with checkmark icon) and **"Revert"** (`TextButton`).
   - When tapping **"Done"**:
     - Commit the modified page strokes to `NoteRepository.saveNote()` asynchronously.
     - Notify `StudyDeskController.reindexNote(noteId)` to update the background RAG spatial chunks for that note without blocking the UI.
     - Update the preview thumbnail and refresh citation marks against the updated stroke list.
     - Revert back to `_InspectionMode.preview` without resetting chat scroll position or closing the pane.

---

## 3. Practice Studio: Interactive Flashcards & Multiple Choice (`lib/features/library/study_desk/practice/`)

### Objective
Improvise a modern, fluid glass UI for test preparation that enables users to generate, review, save, and manage quizzes and flashcard decks derived from their notes.

### Architecture & Data Models (`study_practice_models.dart`, `study_practice_store.dart`)

1. **Data Models**:
   ```dart
   enum PracticeItemType { flashcard, multipleChoice }

   class PracticeFlashcard {
     final String id;
     final String frontPrompt;
     final String backAnswer;
     final String explanation;
     final StudyCitation? sourceCitation;
     final Uint8List? diagramCrop; // Optional cropped stroke/SVG diagram
     final bool isMastered;
     final int reviewCount;
   }

   class PracticeChoiceOption {
     final String id; // 'A', 'B', 'C', 'D'
     final String text;
   }

   class PracticeMultipleChoice {
     final String id;
     final String question;
     final List<PracticeChoiceOption> options;
     final String correctOptionId;
     final String explanation;
     final StudyCitation? sourceCitation;
     final String? userSelectedOptionId;
     final bool isAnswered;
   }

   class StudyPracticeSet {
     final String id;
     final String title;
     final DateTime createdAt;
     final DateTime updatedAt;
     final List<String> sourceNoteIds;
     final List<PracticeFlashcard> flashcards;
     final List<PracticeMultipleChoice> multipleChoiceQuestions;
     final double? bestQuizScore;
     final int totalQuestions;
   }
   ```

2. **Persistence (`study_practice_store.dart`)**:
   - Store all practice sets in `<libraryDir>/study_practice_sets.json`.
   - Provide atomic CRUD methods: `saveSet()`, `deleteSet()`, `updateSet()`, `loadSets()`.

### Visual UI/UX Design & Components

1. **Practice Studio Hub (`StudyPracticeStudioView`)**:
   - Study Desk segmented header toggle: `[ Chat ]` | `[ Practice Studio ]`.
   - When `Practice Studio` is active:
     - **Header Bar**: Display active decks counter, overall mastery progress ring, and a prominent `+ Generate Study Set` action button.
     - **Saved Decks Carousel / Grid**: Responsive grid of deck cards rendered with `GlassSurface`. Each card shows:
       - Deck Title & Source note tags (e.g. `Biology 101`, `Calculus II`).
       - Breakdown badge: `10 Flashcards • 10 MCQs`.
       - Mastery status bar with progress percentage.
       - Quick action menu: `Practice Flashcards`, `Take Quiz`, `Export Test PDF`, `Edit/Manage`.

2. **Interactive 3D Flashcard Deck Player (`StudyFlashcardPlayer`)**:
   - Card container with realistic 3D perspective flip:
     - Uses `Transform` with 3D perspective `Matrix4.identity()..setEntry(3, 2, 0.001)..rotateY(angle)`.
     - Smooth spring animation curves (`AppMotion.springDefault`).
   - **Card Front**:
     - Topic badge & source note citation pill (`[Cell Bio · p.4]`).
     - High-contrast typography with markdown and LaTeX math support.
     - Optional hand-drawn diagram crop rendered cleanly in high resolution.
     - Subdued hint: *"Tap to flip"*.
   - **Card Back**:
     - Clear, definitive answer text.
     - Key concept explanation block.
     - Direct **"View in Note"** button: Opens the note inspection pane centered on the cited diagram/stroke with citation highlight active.
   - **Gesture & Interaction Controls**:
     - Swipe Left / Tap Red Pill: **"Still Learning"** (re-queues card in current session).
     - Swipe Right / Tap Green Pill: **"Mastered"** (marks card mastered, updates deck progress).
     - Shuffle, Flip All, and Progress Counter (`Card 4 of 12`).

3. **Multiple Choice Quiz Player (`StudyQuizPlayer`)**:
   - Clean, focused test environment with high contrast and readable typography.
   - Progress bar at top with timer toggle.
   - **Question Box**: Question number (`Question 3 of 10`), question body (with markdown & math).
   - **Option Pills**: 4 custom styled options (`A`, `B`, `C`, `D`):
     - Unselected: High-contrast border, subtle surface tint.
     - Hover/Focus: Micro-scale feedback (`Pressable`).
     - Selected: Accent fill with primary contrast text.
   - **Instant Feedback Mode vs. Exam Mode**:
     - *Instant Mode*: Selecting an option immediately reveals correct answer (Emerald Green) or wrong answer (Crimson Red), slides open the explanation card, and offers the citation link.
     - *Exam Mode*: User answers all questions, reviews flagged items, and hits **"Submit Exam"** to see a celebratory score summary screen with score breakdown, time spent, and review list.

4. **AI Generation Engine (`StudyPracticeGenerator`)**:
   - Bottom sheet (`StudyGenerateSheet`) to configure generation:
     - Target Sources: All enabled desk notes or selective picker.
     - Question Types: Flashcards, Multiple Choice, or Mixed Test.
     - Item Count: 5, 10, 15, or 20 questions.
     - Difficulty: Fundamental Definitions, Application & Problem Solving, or Comprehensive Exam.
     - Custom Focus: Optional text prompt (e.g., *"Focus on diagram labels and formulas in Chapter 3"*).
   - Prompt pipeline sends retrieved RAG context to `AiClient` requesting strict JSON matching `StudyPracticeSet`.
   - Fallback and retry validation if JSON format is malformed.

---

## 4. Printable / Handwritten Test PDF Generator (`lib/features/library/study_desk/practice/study_test_pdf_exporter.dart`)

### Objective
Allow students to generate the complete test as a printable or digital PDF with designated handwriting answer spaces (ruled lines and diagram answer boxes) matching Etonia's note-taking paper styles—enabling testing with pen and paper or Apple Pencil without AI assistance.

### Architecture & PDF Layout Engine

1. **PDF Engine Dependencies**:
   - Utilize `package:pdf/pdf.dart` and `package:pdf/widgets.dart` (`pdf: 3.13.1` already configured in `pubspec.yaml`).
   - Integrate page geometry and margins matching `pdf_exporter.dart`.

2. **Exam Document Layout**:
   - **Header Block**:
     - Clean academic header with Test Title, Date, Course/Subject, and Student Name line (`Name: __________________________`).
     - Score box in top-right corner: `Score: [ _____ / _____ pts ]`.
     - Standard test instructions (*"Read each question carefully. For written responses, show all work in the designated lined area."*).
   - **Part I: Multiple Choice Questions**:
     - Clear question numbers with formatted question text.
     - Standard academic bubble checkboxes:
       - `[ ] A. Option text`
       - `[ ] B. Option text`
       - `[ ] C. Option text`
       - `[ ] D. Option text`
     - Optional scratchwork margin rule beside questions.
   - **Part II: Free Response, Problem Solving & Diagram Questions**:
     - Converted from flashcard prompts, definition items, or diagram analysis prompts.
     - **Dedicated Handwriting Answer Space**:
       - Rendered using `pw.CustomPaint` or repeating `pw.Divider` lines replicating Etonia's notebook ruled lines (`24 pt` rule spacing with subtle grey `#D0D0D0` strokes and margin guide).
       - For diagram reconstruction questions, provide a bordered **Diagram Box** with subtle grid/dot-matrix backing.
       - Configurable answer height: Small (3 lines), Medium (6 lines), Large (half page), or Full Page.
   - **Part III: Detachable Answer Key (Optional Appendix)**:
     - Appended to a separate page at the very end of the document.
     - Includes correct option letters, detailed model answers for open-ended questions, and note page citations (`Ref: Note "Calculus Notes", Page 4`).

3. **Export Dialog & In-App Note Creation**:
   - **"Export Test PDF" Dialog**:
     - Paper Size: `A4` or `US Letter`.
     - Ruling Style: `Ruled Lined`, `Grid / Graph`, `Dot Grid`, or `Blank Box`.
     - Answer Key Option: Toggle switch `[x] Include Answer Key on separate final page`.
   - **Two Export Options**:
     1. **"Share / Save PDF"**: Generates PDF bytes and invokes native system share sheet / file save.
     2. **"Open as Handwritten Test Note"**: Directly converts the generated test PDF into a new blank notebook inside Etonia's library (using `PdfImporter`), opening it immediately in `EditorScreen` so the student can write their answers with Apple Pencil using Etonia's inking tools!

---

## 5. Files in Scope

### New Files to Create:
- `lib/features/library/study_desk/study_in_situ_editor.dart` (in-situ live canvas and annotation layer)
- `lib/features/library/study_desk/study_in_situ_toolbar.dart` (compact floating annotation toolbar for study desk)
- `lib/features/library/study_desk/practice/study_practice_models.dart` (flashcards, MCQs, and practice set data models)
- `lib/features/library/study_desk/practice/study_practice_store.dart` (JSON file storage for practice decks)
- `lib/features/library/study_desk/practice/study_practice_generator.dart` (RAG prompt assembler and JSON parser for practice sets)
- `lib/features/library/study_desk/practice/study_practice_studio_view.dart` (main deck manager and practice hub)
- `lib/features/library/study_desk/practice/study_flashcard_player.dart` (interactive 3D flip flashcard player)
- `lib/features/library/study_desk/practice/study_quiz_player.dart` (multiple choice quiz engine with instant and exam modes)
- `lib/features/library/study_desk/practice/study_test_pdf_exporter.dart` (academic printable PDF generator with lined answer spaces)
- `test/features/library/study_practice_test.dart` (unit & widget tests for practice generator, store, and PDF export)

### Files to Modify:
- `lib/features/library/study_desk/study_citation_preview.dart` (add in-situ editing mode toggle and toolbar integration)
- `lib/features/library/study_desk/study_desk_screen.dart` (add Practice Studio segmented tab toggle and header integration)
- `lib/features/library/study_desk/study_desk_controller.dart` (add practice store hooks and note re-indexing triggers)

---

## 6. Automated Tests & Acceptance Criteria

Add tests in `test/features/library/study_practice_test.dart` and `test/features/library/study_desk_test.dart` verifying:
1. **In-Situ In-Place Editing**:
   - Tapping "Edit Note" in `StudyCitationPreview` switches to `_InspectionMode.editing` without triggering navigation away or calling `onEditCitation`.
   - Drawing strokes on the in-situ canvas records new strokes in the active `InkController`.
   - Tapping "Done" saves modified strokes to `NoteRepository` and refreshes the preview.
2. **Practice Set Persistence & CRUD**:
   - Creating a `StudyPracticeSet` with flashcards and MCQs persists correctly to JSON and reloads with all fields intact.
   - Mastery status and quiz scores update and persist accurately.
3. **Practice UI Micro-Interactions**:
   - Flashcard player flips 180 degrees on tap and updates mastery counters on swipe.
   - Multiple choice quiz correctly validates option selection and renders explanation.
4. **PDF Generation with Handwriting Ruling**:
   - Exporting a test produces valid PDF bytes containing question text, multiple choice bubbles, and lined answer rule dividers.
   - Toggle to include or exclude the answer key appendix works as expected.
5. **Design & Accessibility Guidelines**:
   - High contrast between text and background colors is maintained across both light and dark modes.
   - Run `flutter analyze` and `flutter test` with zero warnings or errors.
