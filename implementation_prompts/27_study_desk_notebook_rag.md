# Implementation Prompt 27: Multi-Note Study Desk & Handwriting/Diagram RAG

You are working in the **Greatnote** (`Etonia`) Flutter repository. Build a NotebookLM-style study and review workspace (**Study Desk**; keep the user-facing name in a single constant `StudyDesk.title` so it can be renamed in one place) located at the top of the home sidebar above the folder system. It lets the user curate notes/folders as context, chat with AI using a strict token-saving RAG pipeline (indexing typed text, handwriting, and hand-drawn diagrams/SVGs), click any citation to inspect the cited note page with live stroke/region highlights, and click **Edit** to jump directly into the note editor and return back to the chat interface on **Back/Return**.

---

## Rules

- Reuse existing theme, motion, and control tokens (`AppColors`, `AppSpacing`, `AppRadii`, `AppMotion`, `Pressable`, `GlassSurface`, `SceneCrossfade`, `EtoniaBarsLoader`). Maintain high contrast between text color and background color in both light and dark themes.
- Never send all pages or full-resolution images of selected notes in a chat request. Always run the local two-stage RAG pipeline first and enforce a strict per-request token and image crop budget.
- Keep indexing off the UI isolate (`compute`) for large note files (`>= 8 KB`), matching `FileNoteRepository`.
- Do not break existing single-note editor AI assistant (`AiAssistantController`, `AiAssistantPanel`, `AiCitationHighlight`). Share citation highlight painting and markdown/math rendering rather than duplicating them.

---

## 1. Entry Point & Home Layout Integration (`lib/features/library/library_screen.dart`)

1. **Sidebar Entry Above Folder Systems**:
   - In `_FolderSidebar`, place the primary **Study Desk** navigation row above the `'Folders'` header and `'Library'` row.
   - Style it with `_SidebarRow` and `AppColors` tokens (`colors.selected` / `colors.accent` when selected; `colors.textPrimary` when unselected). Show a badge count of currently active context notes when non-zero.
   - Wrap the row in `_DropTarget` so dragging and dropping a note or folder (`_Dragged`) onto the Study Desk sidebar row adds that note (or all notes in that folder's subtree) directly into the Study Desk source set and announces it via a floating `SnackBar`.
2. **Workspace Scene Switching**:
   - When Study Desk is selected in `LibraryScreen`, transition the main library body (`_buildBody`) to `StudyDeskScreen` via `SceneCrossfade` and hide `_NewNoteButton`.
   - Update `_LibraryBar` when Study Desk is open to show the Study Desk header, active source count pill, "+ Add Sources" button, and "New Chat" action instead of folder breadcrumbs/sort controls.
3. **Editor Round-Trip Navigation (`Edit` → `Return`)**:
   - Track whether the editor was entered from Study Desk (`_openedFromStudyDesk`).
   - When the user clicks **Edit** on a cited note inside Study Desk, open the note in `NoteTabsPage` / `EditorScreen` at the cited page index, reveal the cited strokes/region, and keep the citation highlight active on that page.
   - When `_openedFromStudyDesk` is true, pressing the editor's top-left Back/Return button or system back gesture (`PopScope` in `LibraryScreen.build`) transitions directly back to Study Desk (preserving the active chat scroll position, selected citation preview, and source set) instead of returning to the folder grid.
   - When returning from the editor, if the note was saved/modified (`_editedNotes`), re-index only that note in the background and re-resolve the active citation links against its updated strokes.

---

## 2. Context Picker & Source Management (`lib/features/library/study_desk/`)

Create `lib/features/library/study_desk/`:
- `study_desk_models.dart`: Immutable models for `StudySession`, `StudySourceItem`, `StudyChunk`, `StudyChunkKind`, `StudyCitation`, and `StudyParagraphLinks`.
- `study_desk_store.dart`: Persists sessions and selected source IDs atomically to `<libraryDir>/study_desk.json` (and an in-memory store for `InMemoryNoteRepository`).
- `study_source_picker.dart`:
  - **Source Strip / Drawer**: Shows all added notes/folders with miniature `_NoteThumbnail` previews, titles, and checkboxes to toggle individual notes in/out of the active query context without removing them from the desk.
  - **Add Sources Sheet**: A modal sheet using `showAppSheet` with search, folder tree filtering, multi-select checkboxes for notes and whole folders, and a quick "Select folder" toggle.

---

## 3. Multi-Modal RAG for Handwriting, Diagrams & SVGs (`lib/features/library/study_desk/study_rag_index.dart`)

Implement a local, zero-external-DB RAG engine that handles typed text, recognized handwriting, and hand-drawn diagrams / inline SVGs while preventing massive token usage:

### Stage 1: Spatial 2D Chunking (`StudyChunker`)
Instead of fixed character windows, partition each `StoredPage` into bounded 2D **Spatial Chunks (`StudyChunk`)**:
1. **Stroke & Element Clustering**:
   - Group `StoredPage.strokes`, `StoredPage.textElements`, `StoredPage.stickyNotes`, and `StoredPage.images` into spatial clusters by uniting elements whose page-coordinate bounding boxes intersect when inflated by `32.0` logical pt (keeping clusters within a max logical height of `360.0` pt so a full page of dense writing splits into paragraph-sized bands).
2. **Handwriting Binding**:
   - Map each `StoredRecognizedInkWord` (`text`, `confidence`, `alternatives`, `strokeIndices`, `stickyId`) to the spatial chunk containing its strokes.
3. **Diagram & SVG Detection (`StudyChunkKind`)**:
   - Classify each spatial chunk as:
     - `StudyChunkKind.text`: Primarily typed `NoteTextElement` or strokes covered (`>= 45%`) by searchable `StoredRecognizedInkWord` entries.
     - `StudyChunkKind.diagram`:
       - Contains a `NoteImageElement` with an inline `EditableSvg` (`image.vector != null`) or raster crop, **or**
       - Contains `>= 4` non-highlighter strokes where `< 45%` of strokes belong to recognized words and the cluster bounding box is at least `80 x 80` pt (capturing hand-drawn diagrams, flowcharts, axes/plots, geometric figures, and tables).
     - `StudyChunkKind.mixed`: Contains both diagram strokes/SVGs and recognized handwriting labels.
4. **Diagram Context Enrichment (How Diagrams & SVGs become Retrievable)**:
   - **Spatial Label Harvesting**: For every `diagram` or `mixed` chunk, collect all recognized handwritten words (`StoredRecognizedInkWord`) and typed `NoteTextElement`s lying inside or within `64.0` pt of the diagram's bounding box as **anchor labels** (capturing axis labels, callout arrows, titles, and captions written beside a drawing).
   - **SVG Metadata & Structural Descriptors**: If the chunk includes an `EditableSvg`, extract its `<title>`, `<desc>`, and any `<text>` element content. For raw ink diagrams, compute lightweight structural tags from stroke geometry (`closed-loop/box`, `axes/grid`, `arrow/connector`, `curve/plot`, stroke count) and attach them to the chunk's searchable metadata.
5. **Revision-Keyed Cache**:
   - Cache the computed `List<StudyChunk>` per note keyed by `(noteEntry.id, noteEntry.revision)` in memory and on disk so unchanged notes are never re-parsed.

### Stage 2: Hybrid Scoring & Token-Bounded Context Assembly (`StudyContextAssembler`)
When the user sends a prompt:
1. **Hybrid Retrieval**:
   - Score all chunks from enabled sources using **BM25 + Fuzzy Character Trigram Similarity** over:
     - Note title and folder name;
     - Primary recognized handwriting (`word.text`) + weighted OCR `word.alternatives` (so messy handwriting still matches);
     - Typed `NoteTextElement` text;
     - Diagram anchor labels and SVG `<title>`/`<desc>`/`<text>` metadata.
   - Apply a **Diagram Intent Boost** when the user's query mentions visual/structural concepts (e.g. *diagram, drawing, graph, plot, chart, figure, arrow, sketch, flow, shape, picture, table, layout*) or when the user selects the **"Explain the diagrams"** quick action.
   - Select the **Top-$K$ chunks** (`K = 5`, capped at a total text budget of `~3,000` tokens).
2. **Adaptive Payload Packing (Minimizing Token Usage)**:
   - **Text / High-Confidence Handwriting Chunks**: Sent purely as structured text blocks with addressable line/stroke identifiers:
     ```text
     [Source N1:P2:C3 | Note: "Cell Biology", Page 2]
     L1-L8: Mitosis phases: prophase -> metaphase -> anaphase -> telophase
     ```
     (**Zero image or SVG coordinate tokens** are spent on readable text chunks.)
   - **Diagram / Sketch / SVG / Low-Confidence Ink Chunks**:
     - For at most the **Top 2 visual chunks**, crop and render **only that chunk's `logicalBounds`** using `SelectionImageRenderer` + `SelectionSvgRenderer` (emitting `data-etonia-line` stroke lines for exact citation mapping).
     - Never send unselected pages, full-page bitmaps, or unretrieved chunks.

---

## 4. Multi-Note Citation Grammar & Highlighted Note Inspection (`lib/features/library/study_desk/study_citation_preview.dart`)

1. **Multi-Note Citation Grammar**:
   - Extend the citation parser in `lib/features/editor/ai/ai_citation.dart` (or wrap it in `study_desk/study_citation.dart`) to support note-and-page-qualified citations:
     - Stroke/line range citation: `[[N<noteIdx>:P<pageIdx>:L<first>-L<last>]]` (or chunk-level `[[N<noteIdx>:P<pageIdx>:C<chunkIdx>]]`).
     - Picture/diagram detail ring citation: `[[N<noteIdx>:P<pageIdx>:C <top> <left> <bottom> <right>]]`.
   - Strip raw citation brackets from displayed markdown paragraphs and render interactive **Citation Chips** (`[Note Title · p.2]`) below/beside each cited paragraph.
2. **Interactive Note Preview with Live Highlight**:
   - Clicking a citation chip (or scrolling/focusing a cited paragraph, just like `AiAssistantPanel`) opens or updates the **Note Inspection Pane**:
     - On `WindowSizeClass.expanded`, display the Note Inspection Pane in a side-by-side split view beside the chat transcript.
     - On `WindowSizeClass.compact` / `medium`, open a responsive inspection sheet/pane over the chat with a close/return button.
   - Render the cited note page read-only with `AiCitationHighlight` (`aiCitationHighlightColor` `#FFE600` under cited strokes and `aiCitationRingColor` `#E5342B` rings around cited diagram/picture boxes).
   - Smoothly pan and zoom the read-only page viewport so the union bounding box of the cited strokes/rings is centered in view with a `24 pt` margin.
3. **Header Actions on the Note Inspection Pane**:
   - Show the cited Note Title, Page number (`Page X of Y`), and an **"Edit Note"** button (`FilledButton.tonalIcon` with `AppIcons.pen` / edit icon).
   - Clicking **"Edit Note"** triggers the round-trip editor flow in Section 1.3.

---

## 5. Native Study Chat UX (`lib/features/library/study_desk/study_desk_screen.dart`)

- Render assistant messages with `GptMarkdown` and `chat_math.dart` LaTeX support, matching `AiAssistantPanel`.
- Integrate `AiUsageGate`, model picker (`AiModelId`), and `SubscriptionController` credit checks.
- Provide study-focused starter chips when a conversation starts or sources change:
  - **Summarize key concepts**
  - **Quiz me on these notes**
  - **Explain the diagrams**
  - **Find connections & gaps**
- Support voice dictation in the composer (`SpeechToText`) and keyboard shortcuts (`Enter` to send, `Shift+Enter` for newline).

---

## Files in Scope

New files:
- `lib/features/library/study_desk/study_desk_models.dart`
- `lib/features/library/study_desk/study_desk_store.dart`
- `lib/features/library/study_desk/study_rag_index.dart`
- `lib/features/library/study_desk/study_desk_controller.dart`
- `lib/features/library/study_desk/study_source_picker.dart`
- `lib/features/library/study_desk/study_citation_preview.dart`
- `lib/features/library/study_desk/study_desk_screen.dart`
- `test/features/library/study_desk_test.dart`

Touch:
- `lib/features/library/library_screen.dart` (sidebar entry above folders, drag-to-add drop target, scene switching, and Edit → Return `PopScope` round-trip)
- `lib/features/editor/ai/ai_citation.dart` (expose or share helpers for multi-note citation parsing and highlight resolution)
- `lib/app/theme/app_icons.dart` (add icon constant for Study Desk if needed)

---

## Automated Tests & Acceptance

Add tests in `test/features/library/study_desk_test.dart` verifying:
1. **Handwriting & Diagram Spatial RAG**:
   - A page with handwritten words (`StoredRecognizedInkWord`), an unlabelled hand-drawn diagram cluster with nearby handwritten labels, and an inline `EditableSvg` chunks into distinct `StudyChunk`s (`text`, `diagram`, `mixed`).
   - Querying for a diagram label or visual term retrieves the diagram chunk while excluding unrelated pages and notes.
   - Text-only chunks do not trigger bitmap rendering, keeping token/image payloads bounded.
2. **Citations & Highlight Inspection**:
   - Assistant answers containing `[[N1:P2:L4-L7]]` and `[[N1:P2:C 100 200 300 400]]` strip the raw tags from markdown, render clickable citation chips, and resolve to the exact `Stroke` set and `Rect` rings on note 1, page 2.
   - Tapping a citation chip opens the Note Inspection Pane on page 2 with `AiCitationHighlight` painted over the cited strokes.
3. **Edit & Return Round-Trip**:
   - Tapping **Edit Note** in the Note Inspection Pane opens the note editor at the cited page.
   - Tapping Back/Return in the editor returns directly to `StudyDeskScreen` (not the folder grid) with the conversation and source selection intact, and refreshes the edited note's RAG chunks.

Run `flutter analyze` and `flutter test` and ensure zero issues.
