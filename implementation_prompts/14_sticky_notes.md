# Implementation Prompt 14: Configurable Sticky Notes

You are extending **Greatnote**, a Flutter tablet note application for Android and iPadOS. The app already has multi-page notes, pen and highlighter strokes, erasing, selection and transforms, undo/redo, persisted note storage, page backgrounds, images, PDF-backed pages, thumbnails, AI rendering, and PDF export. Preserve those behaviors and the established responsive tablet UI.

## Product outcome

Add sticky notes that users can place anywhere on a page, write on with the existing Pen or Highlighter styles, and configure without leaving the editor. Each sticky note has an independently configurable paper color and paper style: **Blank**, **Dotted**, **Grid**, or **Lined**. A sticky note and all ink inside it move, resize, rotate, copy, paste, delete, persist, and export as one coherent page element.

This feature is for handwritten sticky notes. Do not add rich text, typed-text editing, comments, collaboration, reminders, cloud synchronization, or a separate document format.

## Start with the current architecture

Before editing, trace the existing tool state, pointer routing, painting, selection, history, persistence, thumbnails, AI image rendering, and PDF export. At minimum inspect:

- `lib/features/editor/editor_screen.dart` and `widgets/tool_palette.dart`;
- `lib/features/editor/page/note_document.dart` and `page/page_viewport.dart`;
- `lib/features/editor/ink/ink_controller.dart`, `ink_canvas.dart`, `ink_painter.dart`, `ink_selection.dart`, and `stroke.dart`;
- `lib/features/editor/document_io/image_layer.dart`, `document_models.dart`, and `pdf_exporter.dart`;
- `lib/features/library/note_content.dart`, `note_thumbnails.dart`, and the repository implementations;
- existing editor, selection, storage, export, accessibility, and golden tests.

Extend the existing ownership and history model deliberately. Do not build a parallel editor inside an overlay that bypasses persistence, export, selection, or undo.

## Sticky-note model

Create an immutable or copy-on-write `StickyNoteElement` (name may follow repository conventions) with at least:

- a stable unique ID;
- center in page coordinates;
- unrotated size in logical page units;
- rotation in radians;
- a supported paper color ID, not a theme-dependent resolved color;
- `StickyPaperStyle.blank`, `dotted`, `grid`, or `lined`;
- child strokes stored in sticky-local coordinates.

Use a small curated, accessible palette with at least yellow, pink, blue, green, and neutral paper. Choose fixed light/dark appearance values so a saved color does not silently change identity with the app theme. Derive grid/rule color from the paper color with sufficient but subtle contrast.

Keep sticky notes in an ordered page-element collection owned by the page/controller. Define and document z-order. The required default is: PDF/page paper, placed images, sticky-note paper and its child ink, then ordinary page ink. Among sticky notes, list order is paint order. Selecting or editing a sticky note may show controls above everything, but must not permanently change its z-order unless an explicit arrange action already exists.

All values loaded from storage must be validated. Reject or repair non-finite transforms, non-positive or unreasonable sizes, unknown enum values, malformed child strokes, and duplicate IDs without crashing. Bound the number of sticky notes and child points accepted from one file using named configuration values.

## Creation and controls

- Add one **Sticky note** button to the existing tool palette using the same visual, tooltip, focus, keyboard, hover, and selected-state conventions as other tools.
- Selecting the tool opens a compact sticky-note options panel. It contains an accessible paper-color picker and a four-choice paper-style control with visual previews and text labels.
- Remember the last selected color and paper style for the session. Defaults are yellow and lined.
- A tap on free page space creates one sticky note centered at the tapped page coordinate, clamped fully inside finite page bounds. On an infinite page, creation may grow the recorded extent using the existing page-growth rules.
- Use a named `StickyNoteConfig` for default size, minimum and maximum size, corner radius, shadow/elevation, content padding, pattern spacing, rule thickness, hit slop, and file limits. Sensible initial defaults are **240 x 180 logical page units**, **120 x 90 minimum**, **640 x 480 maximum**, **12 radius**, **16 content padding**, **20 pattern spacing**, and **1 logical pixel rules**. Do not scatter magic numbers through widgets and painters.
- Show an immediate preview during placement. One tap produces one undoable insertion. Pointer cancel, tool change, page change, or disposal before placement commits nothing.
- After placement, return to the previously active Pen/Highlighter style and enter sticky editing mode so the user can write immediately. This is one product flow, not two unrelated tool selections.

## Paper rendering

- Render paper, pattern, and child ink clipped to the sticky note's rounded rectangle. A small shadow may extend outside the clip. Avoid a full-page `saveLayer` or blur on every pointer update.
- Blank has no pattern. Dotted uses evenly spaced round dots. Grid uses evenly spaced horizontal and vertical rules. Lined uses horizontal rules only. Anchor every pattern in sticky-local coordinates so it moves, rotates, resizes, thumbnails, and exports identically.
- Keep pattern stroke widths visually stable and deterministic under zoom and device-pixel-ratio changes. Clip the final partial row/column rather than shifting the pattern to make it fit.
- Paper color and pattern are part of the document, not theme decoration. Light/dark app theme changes must not alter a saved sticky note's exported appearance.
- Factor shared sticky rendering geometry into a renderer/painter that screen rendering, thumbnails, AI note rendering, and PDF export can follow. If PDF export uses native PDF drawing primitives, add parity tests for geometry and color rather than rasterizing the whole page.

## Editing and handwriting

- A selected sticky note has two modes: **content editing** and **object transform**. Make the current mode visually and semantically clear.
- Immediately after creation, and when a user double-taps an existing sticky note with the Pen or Highlighter active, enter content editing. Route a stroke that starts inside the padded sticky content area to that sticky note, convert samples into sticky-local coordinates before smoothing/storage, and clip it to the note. Continue receiving the active pointer if it briefly leaves the bounds; the rendered result remains clipped.
- Child ink uses the existing Pen/Highlighter capture, smoothing, pressure, opacity, and stroke rendering behavior. Eraser gestures that start inside the active sticky edit surface affect its child ink only. Undo/redo uses the editor's single visible history order rather than a hidden nested history stack.
- A single tap with Select active selects the sticky as an object. Reuse the existing selection handles and similarity-transform behavior where practical. Moving, rotating, or resizing transforms the sticky frame; child strokes remain in local coordinates and therefore follow without destructive point-by-point rewrites.
- Preserve the sticky's aspect ratio during corner scaling unless the existing selection interaction provides an explicit modifier for free resize. Clamp to configured minimum/maximum size. Compute transforms from the gesture start, not cumulatively, to avoid drift.
- Color and paper-style changes apply live to the selected sticky and commit as one undo step when the interaction closes or a new option is chosen. They never recolor child ink.
- Copy/cut/paste and duplicate include the sticky and child strokes, generate fresh IDs on paste, use the existing paste offset policy, and select the pasted result. Delete removes the entire sticky. Area/stroke erasers do not delete sticky paper accidentally; object deletion happens through selection actions.
- Ordinary page ink above a sticky remains ordinary page ink. Only strokes explicitly routed while that sticky is in content-editing mode become children, so moving a sticky never captures unrelated existing ink.
- Define conflict behavior with page pan/zoom and palm input consistently with the existing editor. Only one sticky-content or transform gesture may be active at once, and timers/listeners must not outlive it.

## History, saving, and compatibility

- Extend the existing snapshot/command history so insertion, deletion, paste, each completed child stroke, each eraser gesture, each completed transform, and each color/style change are undoable and redoable in correct chronological order with ordinary ink and image edits.
- Count one completed gesture as one history step. Pointer previews and option-hover previews do not modify the document revision or trigger autosave.
- Increment the persisted storage schema and serialize sticky notes per page, including transforms, paper settings, and child-stroke style/width/points/width factors. Continue opening every older schema; a page with no `stickyNotes` field has none. Never rewrite or lose PDF sources, images, playbacks, AI state, or existing strokes during migration.
- Unknown future paper styles or colors use safe documented fallbacks while preserving the rest of the page when possible. Malformed individual sticky notes are skipped or repaired rather than making the entire note unreadable; surface diagnostics in debug logging without exposing file contents.
- A save/load round trip must preserve ordering and all finite values closely enough that rendered geometry is unchanged. Autosave observes sticky changes through the same revision mechanism as other document edits.

## Selection, rendering, and downstream integration

- Extend selection bounds, hit testing, lasso/rectangle selection, transform previews, clipboard content, and selection image rendering to include sticky-note elements. Hit testing must account for inverse rotation and rounded bounds.
- Include sticky notes in library thumbnails, full-note and selection images sent to the AI assistant, and PDF export at the correct page coordinates and z-order. Child highlighter opacity must still be applied exactly once.
- Export paper colors and patterns as vector fills/rules/dots where supported, then clip child strokes to the rounded note bounds. Do not flatten unrelated page content. A PDF created from the same saved document must remain deterministic.
- Update memory/caching code only where sticky rendering demonstrably requires it. Pattern drawing must not allocate an unbounded object per dot or grid intersection on every frame; cap work for malformed zoom/size input and reuse bounded geometry where beneficial.
- Preserve accessibility. Announce creation and deletion, expose labels such as "Yellow lined sticky note", provide semantic actions for edit/move/delete where the current editor has equivalents, maintain logical focus after popovers close, and never rely on color or pattern preview alone.

## Automated tests

Add focused deterministic tests for at least:

- model validation, stable IDs, defaults, and all four paper styles;
- storage migration from the previous schema and exact save/load round trips for every color/style, transform, and child Pen/Highlighter stroke;
- creating at the tapped page coordinate, finite-page clamping, infinite-page growth, cancellation, and automatic return to writing;
- pattern geometry remaining anchored through move, resize, rotation, zoom, and device-pixel-ratio changes;
- content-mode coordinate conversion and clipping, including a stroke crossing the edge;
- Pen and Highlighter child rendering, erasing only sticky-local ink, and ordinary page ink remaining independent;
- selection and rotated hit testing; move/resize/rotate previews; minimum/maximum clamps; delete, duplicate, copy, cut, and paste with fresh IDs;
- chronological undo/redo across sticky insertion, child writing, style change, transform, ordinary page ink, and deletion;
- z-order relative to PDF paper, images, other sticky notes, and ordinary page ink;
- thumbnail, AI whole-note/selection rendering, and PDF export containing the paper, selected pattern, child ink, transform, clipping, color, and opacity;
- tablet and compact layouts, keyboard/focus behavior, semantic labels/actions, light/dark editor chrome, and golden coverage for every paper style without theme-dependent paper changes;
- malformed persisted data and configured count/point limits producing finite bounded work without crashing.

Run the smallest relevant tests while iterating, then at least:

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

## Acceptance criteria

- The user can choose a sticky-note color and Blank, Dotted, Grid, or Lined paper, tap to place it, and handwrite on it immediately.
- A sticky note and its child ink behave as one coherent object when selected, moved, resized, rotated, copied, pasted, deleted, undone, or redone.
- Saved notes reopen with the same sticky geometry, color, pattern, z-order, and Pen/Highlighter appearance, while older note files continue to load unchanged.
- Sticky notes appear consistently in the editor, selection captures, library thumbnails, AI renders, and exported PDFs.
- Pointer interaction remains responsive, painting is clipped and bounded, no full editor rebuild occurs for each child-ink sample, and malformed input cannot cause NaN, infinity, unbounded allocation, or a crash.
- Existing formatting, analysis, unit, widget, integration, and golden tests pass.

## Completion report

At the end, describe the model and z-order, pointer routing between page ink and sticky-local ink, history ownership, storage migration and fallbacks, every `StickyNoteConfig` default, rendering/export parity, changed tests and goldens, commands run, physical-device verification, and any remaining platform limitation. Do not claim device or performance results that were not measured.
