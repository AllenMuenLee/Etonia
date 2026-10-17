# Implementation Prompt 16: Native `.goodnotes` File Extractor and Exact Page/Vector Ink Reconstruction

You are extending **Greatnote**, a Flutter tablet note application for Android and iPadOS. The app already imports PDFs (`DocumentImporter`), recovers rasterized ink from Goodnotes Android PDF exports (`GoodnotesPdfRecoverer` in `lib/features/editor/document_io/goodnotes_pdf_recovery.dart`), stores multi-page notes with `PdfPageSource` and immutable `Stroke` polylines (`Stroke.fromPoints` with per-point `widths`), and exports vector PDFs (`PdfExporter`). Preserve all existing behaviors, storage schemas, and responsive UI.

## Goal

Add a native `.goodnotes` archive extractor (`GoodnotesArchiveExtractor`) that reads `.goodnotes` files (such as `2026+MGY377+Lecture+15.goodnotes`), extracts embedded PDF attachments, reconstructs every page's exact dimensions and page order, and decodes Goodnotes' binary protobuf + `bv41` (LZ4) + `tpl` vector ink records so that every page, background PDF slide, pen stroke, highlighter mark, and geometric shape is replicated in Greatnote with its exact size, position, width profile, color, and opacity—just like a PDF, while keeping all strokes natively editable.

Support importing `.goodnotes` files both from the library (**Import PDF / Goodnotes** or dedicated picker support) and programmatically from raw `Uint8List` bytes (so cloud importers such as Google Drive Goodnotes replication can convert `.goodnotes` files directly into Greatnote notes).

## Reverse- engineered `.goodnotes` specification (`2026+MGY377+Lecture+15.goodnotes`)

A `.goodnotes` file is a standard PKZIP archive (`PK\x03\x04`) containing varint-length-delimited Protocol Buffer streams and `bv41` LZ4-compressed `tpl` containers:

### 1. Archive layout
- `schema.pb`: protobuf message `{1: varint}` (e.g., schema `26`).
- `index.attachments.pb`: varint-length-delimited protobuf messages `{1: string logicalAttachmentId, 2: string zipEntryPath}` mapping logical attachment UUIDs (e.g., `5181AF5B-...`) to ZIP paths (e.g., `attachments/3A36E15F-...`, which is a raw `%PDF-1.7` file).
- `index.notes.pb`: varint-length-delimited protobuf messages `{1: string noteStreamId, 2: string zipEntryPath}` listing each page's stroke stream file (`notes/<UUID>`) in document page order (e.g., 38 pages).
- `index.events.pb`: varint-length-delimited CRDT event messages `{1: string entityId, <eventField>: submessage}` describing document metadata, attachment descriptors, page descriptors, and page-to-background bindings:
  - **Field `30` (Document metadata):** submessage field `2.1` holds the document title string (e.g., `"2026+MGY377+Lecture+15"`).
  - **Field `6` (Attachment registration):** `{1: string logicalAttachmentId, 2: string attachmentFileUuid, 5: varint byteLength}`.
  - **Field `2` (Background PDF page descriptor):** `{1: string docId, 2: string pageTemplateId, 4: string logicalAttachmentId, 5: varint oneBasedPdfPageNumber, 8: {1: fixed32 width, 2: fixed32 height}}` (in `2026+MGY377+Lecture+15.goodnotes`, Goodnotes logical page dimensions are `1760.0 x 990.0` while the underlying PDF `/MediaBox` is `960 x 540 pt`, i.e., `1280.0 x 720.0` Greatnote page units at `4/3` page units per PDF point).
  - **Field `54` (Page creation & template binding):** `{1: string docId, 2: string pageId, 3: {1: string pageTemplateId}, 4: {1: string sortOrderCode}, 17: {1: {2: {1: {1: fixed32 r, 2: fixed32 g, 3: fixed32 b, 4: fixed32 a}}}}}`:
    - Each `field 54` event binds a page (ordered by `index.notes.pb` / sort code `49Bv101`..`49Bv138`) to its `pageTemplateId` from `field 2`.
    - Note that `pageId` in `field 54` shares the first 34 characters of the 36-character UUID in `index.notes.pb` (with the final byte incremented by `+1` in `index.notes.pb`), and `index.notes.pb` lists the 38 pages in exact 1-to-1 sequential order corresponding to the 38 `field 54` / `field 2` page entries.

### 2. Coordinate scaling (`Goodnotes units` $\rightarrow$ `Greatnote page units`)
- Greatnote represents PDF-backed pages in **page units** (`96 dpi`, where `1 PDF point = 4/3 page units`, `DocumentUnits.pageUnitsPerPdfPoint`). For a `960 x 540 pt` PDF slide, the Greatnote page size is `1280.0 x 720.0` page units.
- Goodnotes stores page coordinates in the coordinate space declared in `field 2` submessage `8` (`goodnotesWidth x goodnotesHeight`, e.g., `1760.0 x 990.0`, origin at top-left, $+X$ right, $+Y$ down).
- Therefore, for each page $i$ with target Greatnote `pageSize` $(W_{\text{gnote}}, H_{\text{gnote}})$ and Goodnotes page dimensions $(W_{\text{gn}}, H_{\text{gn}})$:
  - $s_x = W_{\text{gnote}} / W_{\text{gn}}$ and $s_y = H_{\text{gnote}} / H_{\text{gn}}$ (for `1280 / 1760` and `720 / 990`, $s_x = s_y = 8 / 11 \approx 0.7272727$).
  - Every Goodnotes point $(x, y)$ maps to Greatnote page coordinates $(x \cdot s_x,\; y \cdot s_y)$.
  - Every Goodnotes stroke width $w$ scales by $s = (s_x + s_y) / 2$.
- If a `.goodnotes` page has no PDF attachment (a blank/template page), set its Greatnote `PageSetup` to `PageSize.custom` with `customSize: Size(W_gn * (1280.0 / 1760.0), H_gn * (720.0 / 990.0))` (or standard size if matching) and map coordinates with the same scale factor.

### 3. Stroke stream records (`notes/<UUID>`)
Each non-empty `notes/<UUID>` file is a sequence of varint-length-delimited protobuf messages. Messages alternate between element headers (`{1: string strokeUuid, 2: {1: varint versionOrDeletionState, 2: varint timestamp}, 3: varint layer, ...}`) and stroke payload wrappers (`{7: StrokePayload}`):
- **Active vs. deleted/superseded records:**
  - In the header message preceding a `{7: StrokePayload}` (and in `StrokePayload` field `15`), `field 2` is `{1: varint state, 2: varint clock}`.
  - Keep a map of `strokeUuid -> latest record`. Note that in `notes/8FF3B8F3-CA92-587B-BBFF-DCDCEBBCB530`, a shape-converted highlighter stroke has a `tpl` container with `0` curve segments and stores its snapped line endpoints in `StrokePayload` **field `9`** (`{1: repeated PointMessage, 15: fixed32 width}`, where each `PointMessage` has `{1: fixed32 x, 2: fixed32 y}`).
- **`StrokePayload` (`field 7` submessage) fields:**
  - `field 1` (`string`): `strokeUuid`.
  - `field 2` (`bytes`): `bv4` compressed `tpl` container.
  - `field 3` (`varint`, optional): `1` for fountain/ballpoint pen strokes.
  - `field 4` (`submessage`): RGBA color `{1: fixed32 r, 2: fixed32 g, 3: fixed32 b, 4: fixed32 a}` with float components in `[0.0, 1.0]`.
  - `field 5` (`varint`, optional): `1` for highlighter strokes (`WritingStyle.highlighter` when `field 5 == 1` or alpha `< 0.95` or `tpl` format is `vuA(v)A(S(uu))A(S(uuuu))vA(f)`).
  - `field 9` (`submessage`, optional): Snapped shape/line geometry fallback when the `tpl` curve arrays are empty.

### 4. `bv4` (LZ4) decompression and `tpl` binary unpacking
- **`bv4` stream format:**
  - Consists of one or more blocks followed by a 4-byte footer `bv4$`:
    - `bv41` block: `4B` magic `"bv41"`, `uint32_le uncompressedSize`, `uint32_le compressedSize`, followed by `compressedSize` bytes of raw **LZ4 block** data (standard LZ4 token + literal length + literals + `uint16_le` back-reference offset + match length). Note: multi-block streams may reference bytes from earlier blocks in the same stream buffer.
    - `bv4-` block: `4B` magic `"bv4-"`, `uint32_le uncompressedSize`, followed by `uncompressedSize` raw uncompressed bytes.
    - `bv4$` footer: `4B` magic `"bv4$"` marking end of stream.
- **`tpl` container format:**
  - Starts with `4B` magic `"tpl\x00"`, `uint32_le totalByteLength`, then a NUL-terminated ASCII format string (e.g., `"vA(v)A(u)A(u)A(v)A(v)A(u)A(u)A(u)A(u)A(v)"` or `"vuA(v)A(S(uu))A(S(uuuu))vA(f)"`), followed immediately by little-endian binary values matching the format string:
    - `v`: `uint16_le` (2 bytes)
    - `u` / `f`: 32-bit little-endian value (4 bytes; in Goodnotes stroke `tpl` payloads, `u` slots store IEEE-754 `float32_le` coordinates/widths)
    - `S(...)`: inline struct of the enclosed types
    - `A(...)`: `uint32_le count` followed by `count` elements of the enclosed type/struct.
- **Two observed stroke `tpl` schemas in `2026+MGY377+Lecture+15.goodnotes`:**
  1. **Pen stroke schema (`"vA(v)A(u)A(u)A(v)A(v)A(u)A(u)A(u)A(u)A(v)"` — 820 strokes in the file):**
     - `tpl[1]` (`A(v)`, length $N$): segment command tags (`4` = moveTo start, `5` = cubic segment, etc.).
     - `tpl[2]` (`A(u)` as `float32`, length 4): start point `[x0, y0, pressure0, baseRadiusOrHalfWidth0]`.
     - `tpl[3]` (`A(u)` as `float32`, length $9 \times (N - 1)$): $N - 1$ segments of 9 floats each:
       `[cp2x, cp2y, p_mid, endX, endY, p_end, w_start, w_end, tension]` (where `(endX, endY)` is the segment endpoint, `(cp2x, cp2y)` is an intermediate control/sample point, and `w_start, w_end` are the stroke radius/half-width values in Goodnotes units, e.g., `~0.86` for normal pen and `~3.12` for thick pen).
     - `tpl[8]` (`A(u)` as `float32`): dense pre-subdivided polyline coordinates `(x, y)` pairs along the curve, and `tpl[6]` (`A(u)` as `float32`, length $2 \times (N - 1)$): first control points `(cp1x, cp1y)` for each cubic Bézier segment from `P_{k-1}` through `cp1_k`, `cp2_k` to `P_k`.
     - **Reconstruction:** Either evaluate each cubic Bézier segment `P_{k-1} -> cp1_k -> cp2_k -> P_k` (using `tpl[2]`, `tpl[6]`, `tpl[3]`) or sample the centerline points, interpolating the local stroke diameter `2 * w` (scaled by $s = (s_x + s_y)/2$) to produce a smooth `Stroke.fromPoints` with base `style.width` equal to the median/max diameter and per-point `widths` factors (`localWidth / style.width`).
  2. **Highlighter / uniform curve schema (`"vuA(v)A(S(uu))A(S(uuuu))vA(f)"` — 12 strokes in the file):**
     - `tpl[1]` (`u` as `float32`): full stroke width in Goodnotes units (e.g., `12.992`).
     - `tpl[3]` (`A(S(uu))` as `float32` pairs): start point `[(x0, y0)]`.
     - `tpl[4]` (`A(S(uuuu))` as `float32` 4-tuples): quadratic/curve segments `(cpx, cpy, endX, endY)`.
     - If `tpl[3]` and `tpl[4]` are empty and `StrokePayload` `field 9` is present, extract the polyline points and width from `field 9` (the snapped straight-line highlighter mark on Slide 12).
     - Map to `StrokeStyle(ink: InkPalette.imported(color), width: tplWidth * scale, writing: WritingStyle.highlighter, opacity: alpha)`.

## Architecture & UI Integration

1. **Create `lib/features/editor/document_io/goodnotes_archive_extractor.dart`:**
   - Implement pure-Dart ZIP parsing (central directory / local file headers + `ZLibCodec(raw: true)` inflate), varint protobuf decoding, `bv41`/`bv4-` LZ4 block decompression, and `tpl` binary unpacking without external native dependencies so it runs in `Isolate.run` on all platforms and in `flutter test`.
   - Expose `GoodnotesArchiveExtraction`:
     - `String title`: extracted document title (falling back to the sanitized file name).
     - `Uint8List? pdfBytes`: the extracted background PDF attachment bytes (if the notebook is PDF-backed).
     - `List<Size> pageSizes`: each page's size in Greatnote page units.
     - `List<int?> pdfPageIndices`: 0-based PDF page index for each page (or `null` for non-PDF template pages).
     - `List<List<Stroke>> pageStrokes`: reconstructed editable `Stroke` objects for each page.
2. **Extend `DocumentPicker` and `DocumentImporter`:**
   - Update `SystemDocumentPicker` / `DocumentPicker` so picking a document for import accepts both `.pdf` and `.goodnotes` files (or add `importGoodnotesAsNote` alongside `importPdfAsNote` and auto-detect `.goodnotes` by ZIP magic `PK\x03\x04` + internal `schema.pb` / `index.notes.pb`).
   - When importing a `.goodnotes` file in `DocumentImporter`:
     - Run extraction off the UI isolate via `Isolate.run`, honoring `ImportCancellationToken` and bounding memory/decompression sizes via `DocumentIoConfig`.
     - Store the extracted PDF attachment (if present) once via `repository.storeAsset(..., kind: NoteAssetKind.pdf, extension: 'pdf')`.
     - Save all `StoredPage`s with their `PdfPageSource` (when PDF-backed), `PageSetup`, and reconstructed `Stroke` lists.
     - Roll back any created note/asset on cancellation or error.

## Automated Tests

Add comprehensive unit and widget tests in `test/features/editor/goodnotes_archive_extractor_test.dart`:

1. **Real-file extraction test (`2026+MGY377+Lecture+15.goodnotes`):**
   - Load `2026+MGY377+Lecture+15.goodnotes` from the project root (skipping gracefully only if the file is absent in CI).
   - Verify:
     - `title` is `'2026+MGY377+Lecture+15'`;
     - `38` pages are extracted in exact order, each backed by the `2,905,600`-byte PDF attachment with Greatnote page size `1280.0 x 720.0` (`960 x 540 pt` $\times 4/3$);
     - all `832` strokes across the 13 annotated pages are decoded without error, with finite coordinates strictly mapped into the `1280 x 720` page coordinate frame;
     - pen strokes preserve variable width profiles (`widths != null`) and imported colors;
     - highlighter strokes (including the shape-snapped straight line on page 12 / `8FF3B8F3-CA92-587B-BBFF-DCDCEBBCB530`) are reconstructed with `WritingStyle.highlighter` and translucent opacity;
     - exporting the imported note via `PdfExporter` produces a valid 38-page PDF whose page sizes and vector ink positions match the original pages.
2. **Synthetic unit & security tests:**
   - `bv41` LZ4 block decompression (literals, overlapping match copies, multi-block `bv41` + `bv4-` + `bv4$`);
   - `tpl` parser for both pen and highlighter schemas;
   - corrupt ZIPs, oversized decompression bombs, and truncated protobufs fail cleanly with `DocumentImportException` without crashing.

Run formatting, static analysis, and tests:

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```
