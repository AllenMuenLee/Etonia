# Implementation Prompt 10: Import PDFs and Images, and Export Notes as PDF

You are adding document import and export to **Greatnote**, a Flutter tablet application for Android and iPadOS. The app already opens to a library of persisted notes and folders (prompt 9). The editor has multi-page notes with per-page size and background (prompt 2), one pen with hold-to-shape (prompt 3), area and stroke erasers, lasso selection with move, scale, rotate, copy, cut, and paste (prompt 5), and the AI assistant and AI notation features. Preserve the design system, testing setup, responsive behavior, storage guarantees, and every editor behavior.

## Goal

The user can bring existing material into a note and take a finished note out of the app:

- **Import a PDF** as a new note, or insert its pages into an open note, then write on those pages as on any other page.
- **Insert an image** (a photo, screenshot, or scanned page) onto the current page, then move, scale, rotate, copy, cut, and paste it with the existing Select tool.
- **Export a note as a PDF** that looks like the note on paper: every page with its background, imported PDF page, images, and ink, and hand it to the system share sheet.

## Scope

Implement only:

- PDF-backed pages: a page whose paper is one page of an imported PDF;
- importing a PDF as a new note from the library, and inserting a PDF's pages after the current page from the editor;
- image elements on a page: inserting, displaying, selecting, transforming, copying, cutting, and pasting them;
- storing imported files as note assets in both repositories, with a schema migration;
- exporting a whole note, or its current page, to a PDF file and sharing it;
- including PDF pages and images in library thumbnails and in the images the AI features render.

Do not add PDF text selection, search, links, outlines, form filling, or annotation interchange (reading or writing PDF annotation objects); password prompts for encrypted PDFs; camera capture; image cropping, filters, or editing; text boxes; exporting to images, Markdown, or other formats; printing; or cloud upload. Undo and redo are prompt 11; keep each import and each image mutation a single controller or repository call, so that history records each as one step.

## Existing code to build on

Read these first; import and export must extend the existing document, storage, and rendering paths rather than sit beside them:

- `lib/features/editor/page/note_document.dart`: `NoteDocument`, `NotePage` (ink, setup, extent), and `structureRevision`.
- `lib/features/editor/page/page_setup.dart`: `PageSize`, `PageBackground`, `PageSetup`, `PageGeometry.of`, and `PageConfig`.
- `lib/features/editor/page/page_background.dart` and `page_viewport.dart`: how paper and rules are painted and how pages are laid out and scaled.
- `lib/features/editor/ink/stroke.dart`, `ink_controller.dart`, `ink_painter.dart`: the stroke model, document revisions, mutations, and paint layers.
- `lib/features/editor/ink/ink_selection.dart`, `selection_geometry.dart`, `selection_transform.dart`, `selection_config.dart`: lasso overlap, frames, transforms, and the in-app clipboard.
- `lib/features/editor/widgets/editor_app_bar.dart` and `editor_settings_sheet.dart`: the More options entry point and page setup controls.
- `lib/features/editor/ai/note_image_renderer.dart` and `selection_image_renderer.dart`: how a page or selection becomes an image for the AI.
- `lib/features/library/note_content.dart`, `note_repository.dart`, `file_note_repository.dart`, `note_autosaver.dart`, `library_screen.dart`: the stored schema, repository operations, atomic writes, autosave, and thumbnails.
- `lib/app/theme/app_tokens.dart`: colors, spacing, radii, sizes, and motion.

## Dependencies and platform seams

- Add well-maintained packages for: picking files (PDFs and images, including the iPad Photos library); rasterizing PDF pages on Android and iOS; writing PDF files; and opening the system share sheet. Prefer `file_picker`, `pdfrx`, `pdf`, and `share_plus` unless one of them is incompatible with Flutter 3.44.2 / Dart 3.12. Pin exact versions, check each license, and list them in the completion report.
- Add the required platform configuration (iOS usage descriptions, Android SDK levels or manifest entries) and nothing more.
- Put every platform-dependent piece behind a small interface owned by the app so widget tests never touch a real picker, PDF engine, or share sheet:
  - `DocumentPicker`: pick one PDF, pick one image; a cancelled pick returns null, not an error.
  - `PdfRasterizer`: open a PDF from bytes or a file, report its page count, each page's size, and whether it is encrypted, and render one page to an image at a requested pixel size.
  - `ExportSink`: hand a finished PDF file to the user (the share sheet in production).
- Inject them the way the AI client is injected into the editor today, with production defaults and fakes in `test/helpers/`.

## Units

Page units stay logical pixels at 96 per inch, which already makes A4 `794 x 1123`. A PDF point is 1/72 inch, so one point is `4/3` page units. Use a single named conversion for import and export; do not scatter `0.75` or `1.333` literals.

## PDF-backed pages

- A page may carry a **PDF source**: the id of a PDF asset in the note, a zero-based page index, and the PDF page's size in page units (its crop box, with its `/Rotate` applied). A page with a PDF source is fixed size: its size comes from the source, and it is laid out and scaled to the writing area's width like the other fixed sizes. Extend `PageGeometry.of` accordingly instead of special-casing callers.
- Paint order on a page, bottom to top: paper color and background rules, the PDF page, images, ink, then editor chrome (selection, eraser indicator, AI playback).
- Background rules default to Blank for imported pages. The size control in page setup is disabled on a PDF-backed page with a short explanation; the background control still works.
- Adding a page after a PDF-backed page creates a normal page with the same paper size as a fixed custom size and a blank background, not another copy of the PDF page. Document how that size is represented.
- Rasterize lazily and asynchronously, at the page's displayed size times the device pixel ratio, capped by a configurable maximum pixel dimension. Show the paper color with a quiet loading treatment until the first image arrives. Keep a small least-recently-used cache of rendered pages (the current page and its neighbors) and release images that leave it. Re-render after a size change once the size has settled, not on every frame.
- A size change alone (the AI panel opening, closing, or moving beside the page; a rotation; a window resize) must never flash the loading treatment or blank the page: keep showing the image already on screen, stretched to the new size, request the render for the new size in the background, and swap it in, disposing the old image, only when it arrives. Only a different page, a different PDF, or a replaced cache starts from the loading treatment. Toggling the panel back to a size still in the cache swaps instantly.
- Across the same resizes, the page column keeps the same page, and the same place on it, in the middle of the area (see prompt 6); a resize never moves the user to a different page of the PDF.
- Rendering never blocks a pointer event, and writing works on a page whose PDF image has not arrived yet.
- A page whose PDF asset is missing or cannot be rendered shows the paper with an inline message; its ink still loads, shows, and saves.
- Ink, the erasers, and selection treat the PDF page as paper: they never modify or select it.

## Importing a PDF

- **From the library:** an **Import PDF** action next to New note and New folder. It creates a note in the current folder titled after the file name (without extension, trimmed, length-limited), with one PDF-backed page per PDF page, and opens it.
- **From the editor:** **Insert PDF pages** in More options inserts one PDF-backed page per PDF page after the current page and shows the first inserted page.
- Copy the PDF into the note's assets once per import; every page from that import references the same asset.
- Validate before changing anything: the file opens, it is not encrypted, it has at least one page, it is within configurable limits for file size and page count, and every page size is finite and positive. On failure, show a clear message (`This PDF is password-protected`, `This PDF could not be opened`, `This PDF has more than 500 pages`) and leave the library and the note unchanged. A partially written asset is removed.
- Show progress for imports that take noticeable time, and let the user cancel before the note or pages are created.

## Images

### Model

- An **image element** belongs to one page and has an id, the id of an image asset in the note, the image's pixel size, and its placement in page units: a center, a size that keeps the image's aspect ratio, and a rotation. Store placement so that a rotated image round-trips exactly.
- Images on a page keep insertion order among themselves and always sit below all ink. Document this choice.
- Keep image elements in the same page-level owner that commits ink mutations (`InkController` or a focused collaborator it owns), so a selection that contains both strokes and images commits as one mutation and the existing revision counters drive autosave. Images do not change `Stroke` or the stroke list.

### Inserting

- **Insert image** in the editor (in More options, or as a control next to it if that fits the shell better; keep the palette's button count unchanged) opens the picker for images.
- Accept PNG, JPEG, WebP, and HEIC/HEIF where the platform decoder supports it. Apply EXIF orientation. Store the asset as PNG (if it has transparency) or JPEG, downscaled so its longer side does not exceed a configurable limit; never upscale. An image that cannot be decoded shows a message and changes nothing.
- Place the new image centered in the visible part of the current page, scaled down to fit within a configurable fraction of that area, never larger than its natural size at 1 pixel per page unit. Select it immediately with the Select tool active, so it can be adjusted right away.

### Selection and editing

- With Select active, a tap on an image (when no handle or existing frame is hit) selects that image alone. A tap on empty paper still clears the selection.
- A lasso selects every image whose placed, rotated rectangle overlaps the lasso region under the same even-odd rule and tolerance used for strokes. Put this test in the pure geometry component and use the image's bounds as a broad phase.
- A selection may contain strokes, images, or both. The frame covers all of them. Move, uniform scale, and rotation apply to images exactly as to strokes, from the gesture-start snapshot. Scaling clamps image size so it stays finite and visible.
- Preview transformed images in the selection layer without re-decoding; commit once.
- Copy, Cut, and Paste include images. The clipboard holds image elements and references to their asset bytes so a paste still works after the source image is cut, and pasting into another note copies the asset into that note.
- The erasers do not affect images. Document this; cutting is how an image is removed.
- An image's decoded `ui.Image` is cached per asset at a resolution suited to its displayed size, shared between elements that use the same asset, and disposed when no longer shown.

## Storage

- Bump `storageSchema` to 2. A page gains an optional PDF source and a list of image elements; a Fit page also records the writing-area size it was last shown at, for export (see below). Schema 1 notes load unchanged; unknown future schemas are still rejected and unknown fields still ignored.
- Add asset operations to `NoteRepository`: store bytes as a new asset of a note and return its id, read an asset, and list or remove a note's assets. Ids are generated locally; asset kind and extension are recorded.
- The file repository keeps assets in a per-note directory beside the content files, writes each asset atomically before any content that references it is saved, copies assets when a note is duplicated, and deletes them with the note or folder. The in-memory repository keeps bytes in memory.
- Remove assets no longer referenced by any page or by the in-app clipboard when a note is opened or closed, never mid-session in a way that could break a pending paste or save.
- A missing or corrupt asset affects only the pages or images that use it, with an inline message; it never makes the note or the library fail to open.
- Library thumbnails include the first page's PDF image and images at reduced detail, falling back to the paper when an asset is not yet rendered.

## Exporting a note as PDF

### Entry points

- **Export as PDF** in the editor's More options and in each note's overflow menu in the library.
- A small options sheet: which pages (all pages, or the current page when opened from the editor), and whether to include background rules (on by default). Then export and hand the file to `ExportSink`.
- Before exporting from the editor, finalize any gesture or transform in progress and use the in-memory document, so the export matches what is on screen even if autosave has not run yet. A committed AI notation is exported; a playback in progress is exported as its committed state.
- Name the file after the note title, with characters that are invalid in file names replaced, and a `.pdf` extension. Write it to a temporary location and delete old exports there.

### Page sizes

- Fixed sizes export at their paper size: A4 and Letter export at exactly their standard point sizes.
- A PDF-backed page exports at its source page's size.
- An Infinite page exports as one page at its grown extent (at least the area it was shown at).
- A Fit page exports at the writing-area size it last recorded, then the current writing area, then A4 portrait if it has never been shown.
- PDF pages may not exceed 14,400 points on a side. Scale a larger page's content down uniformly to fit and record it in the completion report.

### Content

- Export the paper appearance, independent of the app theme: the light paper color, light-theme ink colors, and background rules as thin vector lines matching the screen spacing.
- Ink is vector. Each stroke becomes the same geometry the screen paints: round caps and joins, the stroke's width, dots as filled circles. A stroke of varying width (prompt 3) is drawn segment by segment, each at the mean of its ends' widths with round caps closing the joins. Do not rasterize ink, and do not resample or smooth points again.
- Images are embedded once per asset at their stored resolution, placed with their rotation, below the ink. JPEG assets are embedded without re-encoding where the PDF library allows it.
- Imported PDF pages: keep the original page as vector content if the chosen libraries can do so reliably on both platforms. Otherwise rasterize it at a configurable resolution (default 200 dpi) and embed it as the page's bottom layer. Say which path was taken and what it means for file size and for text in the original.
- Set document metadata: title, creator `Greatnote`, and creation date.
- Exported ink sits at the same place relative to the paper as on screen, whatever device or orientation exported it.

### Performance and feedback

- Build the PDF off the UI isolate. Prepare an immutable snapshot of the document on the UI isolate (strokes, images, PDF sources, sizes), then generate the file elsewhere; rasterize PDF pages through `PdfRasterizer` wherever the engine requires.
- Show determinate progress by page with a Cancel button. Cancelling stops the work and removes the partial file. The editor stays usable but read-only during export, or the export works from its snapshot; pick one and document it.
- A failure shows a message with the reason and leaves the note untouched.

## AI features

`NoteImageRenderer` and `SelectionImageRenderer` paint PDF pages and images under the ink, using already-rendered images when available, so the assistant sees what the user sees. Keep their size limits, crops, and coordinate mapping unchanged. Tests use the existing fakes and must not call the real Gemini API.

## Configuration

Introduce an immutable `DocumentIoConfig` with documented defaults and validated invariants. Use at least:

| Value | Default | Meaning |
| --- | ---: | --- |
| `maxImportPdfBytes` | `200 MB` | Largest PDF accepted for import |
| `maxImportPdfPages` | `500` | Most pages one PDF import may add |
| `maxImageImportBytes` | `50 MB` | Largest image file accepted |
| `maxStoredImageDimension` | `4096 px` | Longer side of a stored image asset |
| `insertedImageMaxFraction` | `0.6` | Largest share of the visible page a new image fills |
| `maxPdfRenderDimension` | `4096 px` | Longest side of an on-screen PDF page render |
| `pdfRenderCacheSize` | `3` | Rendered PDF pages kept in memory |
| `exportPdfRasterDpi` | `200` | Resolution of rasterized PDF pages in exports |
| `maxPdfPagePoints` | `14400 pt` | Largest exported page side, the PDF limit |

## Accessibility and responsiveness

- Import PDF, Insert PDF pages, Insert image, and Export as PDF have labels, tooltips where they are icons, 48 × 48 targets, and visible focus, and are reachable by keyboard.
- An image exposes a semantic label (`Image`, plus the file name if known) and its selected state. A PDF-backed page announces its page number and that it comes from a PDF.
- Progress and failures are announced to screen readers.
- Import, insert, and export dialogs and sheets fit without overflow at `390 x 844`, `800 x 1280`, and `1194 x 834`, in light and dark themes, and in both orientations.

## Automated tests

Generate PDF and image fixtures inside the tests (for example with the PDF-writing package and `dart:ui`) rather than committing large binaries. A small encrypted PDF and an EXIF-rotated JPEG may be committed if they cannot be generated.

### Model and storage

- schema 2 round-trips PDF sources, image placements (including rotation), and Fit pages' recorded sizes exactly; schema 1 notes load unchanged; unknown future schemas are rejected;
- both repositories store, read, copy (on duplicate), and delete assets; a note's assets are removed with it and with its folder;
- the file repository writes assets atomically, before content that refers to them, and a missing or corrupt asset fails only its page or image;
- unreferenced assets are cleaned up at open/close and never while the clipboard references them;
- the point/page-unit conversion and `PageGeometry.of` for PDF-backed pages.

### Import

- importing a PDF creates a note with one PDF-backed page per page, the right sizes (including a rotated page), one asset, and the file-name title;
- inserting pages puts them after the current page and shows the first;
- encrypted, corrupt, empty, too-large, and too-many-pages PDFs show their messages and change nothing; a cancelled pick or a cancelled import changes nothing;
- an inserted image is downscaled, oriented, normalized to PNG or JPEG, placed and fitted as specified, and selected.

### Selection with images

- a tap selects an image; a lasso selects images by rotated-rectangle overlap and even-odd rule, including a lasso that crosses an image between its corners;
- mixed selections move, scale, and rotate strokes and images together and commit as one mutation; identity transforms change nothing;
- copy, cut, and paste of images work within a note and across notes, and a paste after cutting the source still has the image;
- erasers leave images untouched.

### Export

- pages export at the specified sizes for every page kind, including the 14,400-point limit; page count and order match the chosen range;
- ink is written as vector paths with the right colors, widths, caps, and positions, in light colors from a dark-themed editor; images and PDF pages are present below the ink; background rules follow the option (write uncompressed in tests and inspect the content, or render the result back through `PdfRasterizer` in an integration test);
- unsaved changes and an in-progress transform are included; cancel removes the partial file; a failure leaves the note unchanged;
- the file name is sanitized, and the file goes to the fake `ExportSink`.

### Widget and golden tests

- the library's Import PDF action and the editor's Insert PDF pages, Insert image, and Export as PDF are reachable, labelled, and keyboard accessible, and show progress and errors;
- a PDF-backed page shows its loading state, then its image (from a fake rasterizer), and writing works before the image arrives;
- resizing a PDF-backed page while its new render is held back (a gated fake rasterizer) keeps the previous image on screen with no loading indicator, then shows the new render; opening and closing the AI panel on a later page of an imported PDF keeps that page and position in view;
- page setup disables the size control on a PDF-backed page;
- goldens: a PDF-backed page with ink (tablet landscape, light and dark), a page with a rotated image under ink, a mixed selection containing an image, the export options sheet (compact and tablet), and a library thumbnail of an imported note.

### Performance validation

- Measure first render and page-turn latency on a many-page imported PDF, memory with the render cache full, and export time for a long note with images. Separate emulator/simulator results from physical Android tablet and iPad results, and do not invent physical-device measurements when hardware is unavailable.

## Acceptance criteria

- A PDF can be imported as a new note or inserted into a note, and its pages can be written on, erased, and selected over like any page.
- Images can be inserted, then moved, scaled, rotated, copied, cut, and pasted, alone or together with ink.
- Imported material persists with the note, is duplicated and deleted with it, and survives an app restart.
- A note exports to a PDF whose pages have the right sizes and contain the paper, PDF pages, images, and vector ink as they appear on screen.
- Pen, erasers, selection, AI features, the library, and autosave otherwise behave as before.
- Formatting, static analysis, unit tests, widget tests, integration tests, and existing and updated golden tests pass.

## Completion report

At the end, describe: the packages added, their versions and licenses, and the platform configuration changed; the schema 2 changes and the migration; the asset layout, lifecycle, and cleanup rule; how PDF pages are rasterized, cached, and released; how images are modeled, ordered, hit-tested, and transformed; how export maps each page kind to a PDF page size, how ink is written as vectors, and whether imported PDF pages are embedded as vectors or rasterized; every `DocumentIoConfig` value; the tests added and any existing tests or goldens changed and why; automated, emulator/simulator, and physical-device results separately; and deferred work (password-protected PDFs, PDF text and annotations, camera capture, image cropping, other export formats, printing).
