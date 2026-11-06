# Study Desk test papers

Practice Studio separates flashcard decks and test papers. Existing mixed sets
remain readable in `study_practice_sets.json`; their MCQs migrate once to the
versioned `study_practice_sets.json.papers.json` sidecar. Exam writes are queued
and use a temporary file plus rename. An unreadable exam file blocks writes,
preserving handwritten answers for recovery. The PDF paper-size enum is now
`StudyTestPaperSize`, leaving `StudyTestPaper` for the exam domain model.

Generated exams accept independent MCQ/FRQ counts and difficulty. After two
assistant replies, chat offers a test on the latest topic. Generation retrieves
note context, resolves citations, saves the paper, and opens it directly. AI
requests use the configured client, selected model, access gate, and usage
accounting. MCQs score locally; FRQs send rendered ink, question text, model
answers, and rubrics to the AI grader. Submission commits only after every
evaluation validates; failures keep the draft editable for retry.

The answer canvas reuses the editor's native InkCanvas and StudyInSituToolbar.
It stores strokes in fixed logical coordinates, so resizing preserves alignment.
Touch writing is disabled by default; pen, highlighter, eraser, lasso, undo/redo,
and ruled/grid/blank paper are available. Ink is encoded after committed changes,
with debounced disk saves. Graded papers show feedback, point breakdowns,
positioned callouts, recognized text, and source-note links. Completed PDF export
includes questions, selections, handwritten snapshots, and grading feedback.

PDF imports rasterize pages sequentially into app-owned PNGs; photos are decoded
into app-owned PNGs. Each imported page has an independent transparent ink layer.
Imports support unlocked PDFs with up to 30 pages and files under 40 MB. Imported
page scores are explicitly normalized to 100 points per page, rather than
claiming to recover an original exam's point allocation.

Automated coverage includes model/ink/grade serialization, MCQ scoring, partial
credit, invalid grader responses, migration, concurrent persistence, corrupt-file
preservation, native-canvas touch rejection and stylus restoration, PDF export,
test submission/review, and direct generation with resolved citations.

Device verification still required:

- Import an actual PDF and photo through the platform pickers; reopen the app
  and confirm page alignment and saved handwriting.
- Exercise real AI grading on handwritten math, including partial credit,
  unreadable work, network failure, and positioned feedback.
- On physical iPad/Android stylus hardware, verify pressure, palm rejection,
  erasing, lasso, undo/redo, and sustained 120 Hz writing in profile mode.
- Share a completed PDF on each supported platform and inspect its printed math,
  original page backgrounds, and handwritten solutions.

Automated tests do not establish real-device latency or live grading accuracy.
