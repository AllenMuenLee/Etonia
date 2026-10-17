# Implementation Prompt 12: Recover Editable Ink from Goodnotes PDF Exports

You are extending **Greatnote**, a Flutter tablet note application for Android and iPadOS. The app already imports arbitrary PDFs as fixed PDF-backed pages, inserts images, stores editable ink as immutable `Stroke` polylines, exports notes as PDFs, and persists every page and asset. Preserve all existing import, storage, editing, undo, export, and failure behavior.

Implement a conservative, best-effort recovery path for PDFs exported by the Android version of Goodnotes. A captured Goodnotes/PDFium export shows that each page consists of ordinary vector paper/template content, a full-page transparent RGB image plus grayscale soft mask containing Goodnotes page elements, and a small separate “Made with Goodnotes” image. Handwriting and inserted images may already be flattened together inside that full-page transparent image; there are no PDF Ink annotations or original stroke records.

## Required behavior

- Keep ordinary PDF import unchanged for PDFs that do not confidently match the observed Goodnotes/PDFium structure or whose recovery fails at any point.
- Detect the format conservatively from PDF metadata and repeated page structure. Do not classify a document solely because its creator is PDFium.
- Support the classic cross-reference-table PDF structure produced by the observed Goodnotes Android export. Parse only the narrow subset required for detection and image extraction; reject unsupported filters, object streams, malformed references, unexpected dimensions, and unreasonable allocations without crashing.
- Find each page's large, full-page, 8-bit DeviceRGB `/Image` XObject and its 8-bit DeviceGray `/SMask`, both using `/FlateDecode`. Remove the separately recognized repeated Goodnotes badge by clearing its soft mask, including when there is no recoverable ink.
- Decode the full-page RGBA overlay and divide its connected opaque content conservatively:
  - large, dense rectangular regions are fixed image/content regions and remain in the page background;
  - smaller or sparse connected regions are candidate ink;
  - uncertain or pathological regions remain fixed rather than becoming editable ink.
- Convert candidate ink into Greatnote `Stroke` objects:
  - thin the raster mask to centerlines;
  - trace centerlines into one or more polylines;
  - filter pixel staircases before simplification and smooth polylines without destroying handwriting shape, endpoints, junctions, or closed loops;
  - estimate a base width from the component area and centerline length, resample the path, and measure a smoothed local width profile across the trace so pressure variation survives geometry simplification, storage, and export;
  - repair small pencil-grain holes and notches within individual connected components, prune short terminal spurs without deleting real branches, and approximate textured marks with smooth ink at their average opacity; preserve ambiguous networks in the PDF rather than inventing brush texture or original pressure samples;
  - preserve the sampled RGB color through a stable persisted imported-color ink ID;
  - map overlay pixels into Greatnote page coordinates with top-to-bottom rows, without an extra Y flip.
- Do not leave a flattened copy of recovered ink under the editable stroke. Rewrite the full-page image's grayscale soft-mask pixels corresponding to high-confidence recovered ink and clear the recognized badge's soft mask, then rebuild the classic cross-reference table. This must preserve the source PDF's vector paper/template content, fixed image pixels, unrecognized marks, and graphics state without rasterizing the whole page.
- Import the rewritten PDF as the pages' `PdfPageSource` and store recovered strokes in each page. Both “import as a new note” and “insert PDF pages” must use the recovery path.
- Run parsing, bitmap analysis, tracing, stream recompression, and PDF rebuilding off the UI isolate. Continue honoring import cancellation between expensive phases and roll back every created note/asset on failure.
- Bound CPU and memory work. Reject images whose decoded byte count is inconsistent, whose dimensions exceed configured render limits, or whose page count/dimensions do not match inspection.

## Accuracy and fallback policy

This feature is explicitly best effort. Prefer false negatives over false positives. Text or artwork inside a dense rectangular screenshot must not be traced as ink. Ink touching a fixed image, very dense artwork, unsupported PDF encodings, and ambiguous components should remain fixed. An unrecoverable page or document must still import normally as the original PDF.

Connected regions with substantial color variation must also remain fixed instead of being averaged into a single pen color. This is an appearance-based safeguard, not semantic text classification or OCR; monochrome drawings and handwriting cannot reliably be distinguished from the flattened raster alone.

## Tests

Add focused tests for:

- conservative Goodnotes structure recognition and malformed-data rejection;
- RGB plus soft-mask extraction and decompression limits;
- dense rectangular image regions remaining fixed;
- isolated black and colored strokes becoming finite Greatnote polylines with sensible widths and preserved imported colors;
- raster-to-page coordinate conversion;
- rewritten soft masks no longer containing recovered ink pixels while fixed regions remain unchanged;
- automatic fallback to the existing PDF import for ordinary or unsupported PDFs;
- recovered imports storing one replacement PDF asset and editable strokes for both new-note and insert flows;
- imported color IDs surviving note JSON round trips.

Run formatting, static analysis, and the relevant document I/O and storage tests. Do not weaken existing limits or tests.
