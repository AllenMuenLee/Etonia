# Study material sources and note canvas

Generated tests retain the originating chat ID and the source-note IDs. Capture
these before asynchronous generation; switching chats must neither change the
saved origin nor open the finished paper over a different chat. Include the
originating conversation in test-generation context. Preserve origin IDs through
serialization, grading, edits, reset, and legacy deck conversion.

The test player exposes its source conversation directly and flushes pending
answers before navigating. Tests and flashcards expose a source browser from the
library and their players. Browse source notes inside their actual folder
hierarchy; retain ancestor folders, open notes, and explicitly disable missing
conversations or notes. The same folder tree supports nested, tri-state source
selection in both generation sheets.

The editor assistant offers Import conversation into Study Desk. Disable it for
an empty chat or a pending response. Finalize recording and flush the source note
before importing. Copy the conversation into a new persisted Study Desk session,
attach the source note, retain existing chats, and open Study Desk.
Import quick-action labels as shown in the assistant. Strip standalone generated
end/stop markers and their trailing text, completion footers, sign-offs, and
placeholder final lines from assistant messages before persisting them; omit
answers that become empty. Preserve user messages, quoted examples, fenced code,
formulas, SVG content, and substantive review prompts. Tutor prompts start with
the answer, keep each sentence about the subject, and finish with the explanation.
Remove standalone "Notation:" paragraphs describing annotation colors or
positions during import, including wrapped descriptions and Markdown labels.
Preserve mathematical notation definitions and literal code or quoted examples.
Express teaching, citation, grading, and response-format requirements as positive
actions in both client and backend instructions. Give the chat model the subject,
source context, and response format. Keep drawing workflow details in the drawing
request. Preserve source grounding, lesson progression, and SVG contracts.
For the editor assistant, choose prose for reasoning, LaTeX for mathematical
expressions, tables for comparisons, and fenced code for programming. Render a
reciprocal as $\frac{1}{s}$; use inline math for short expressions and display math
for important or long equations, aligned derivations, matrices, and cases. Define
symbols and units in surrounding prose. Scope this added math guidance to the
editor assistant and verify fractions and display equations through its UI.

Test response areas use the note editor's PageViewport, WritingSurfaceFrame,
PageBackgroundLayer, and InkCanvas, with the focused test-only toolbar. Preserve
logical answer coordinates while zooming and resizing. Share pen, highlighter,
eraser, lasso, ruling, and stylus settings across response areas. Lock submitted
answers. Show grader strokes on the original work and make positioned feedback
callouts tappable. Completed PDF exports include both positioned annotations and
their numbered explanations, including graders that return callouts without ink.

Verification includes imported transcript restoration, origin preservation while
switching chats during generation, pending-answer saves before source navigation,
nested folder selection and opening, assistant button availability, and annotation
viewing/export. Reuse existing canvas, grading, navigation, assistant, practice,
and library regressions. Preview the folder tree with nested sample material.
