# Implementation prompt: native framework acceleration, O(1) ink rendering, spatial geometry, and storage/PDF speedups

You are working in the Greatnote (`Etonia`) Flutter repository. Implement a comprehensive, measured performance pass that upgrades the native Android/iOS stylus and OCR pipelines, eliminates `O(N²)` and `O(N)` per-frame bottlenecks in ink rendering and hit-testing, replaces main-isolate pure-Dart image/PDF/JSON bottlenecks with native or isolate-backed fast paths, and adds persistent thumbnail and page-level storage optimizations.

Do not treat this as a speculative refactor: profile, preserve every existing behavioral contract and storage backward compatibility, keep all unit/widget/integration tests green, and prove the speedups with deterministic tests and measurements.

---

## Product outcome

The target is hardware-level responsiveness on iPad (ProMotion 120Hz) and Android tablets (S-Pen / USI):

1. **Ultra-low-latency native ink (`2–4ms` glass-to-photon):**
   - Android uses hardware front-buffer rendering (`androidx.graphics:graphics-core` `CanvasFrontBufferedRenderer`) and Kalman motion prediction (`androidx.input:input-motionprediction`) instead of full-view `invalidate()` on a standard `View`.
   - iOS/iPadOS uses dirty-rect invalidation (`setNeedsDisplay(_:)`) and incremental segment rendering with 120Hz `CAFrameRateRange` hints instead of redrawing the entire stroke from sample `0` across the full screen on every 240Hz Apple Pencil sample.
   - Dart's `ActiveStroke` builds variable-width outlines incrementally (`O(1)` per added sample) instead of invalidating `_outline = null` and rebuilding all `0..N` quads/discs on every sample (`O(N²)` over a stroke).
2. **Instant canvas rendering, erasing, and lassoing on dense pages (`10,000+` strokes):**
   - `CompletedStrokesPainter` performs frustum/viewport culling against the visible page rect so zoomed-in views and tall/infinite pages only issue draw calls for strokes overlapping the visible viewport.
   - Static ink layers and/or dense stroke groups avoid redundant per-frame path tessellation.
   - Erasing (`EraseGeometry` / `InkController`) and lasso selection (`LassoRegion` / `InkController`) use a 2D spatial index (uniform grid or R-tree) per page and sticky note rather than scanning every stroke and segment linearly on every pointer move.
3. **Zero-waste on-device handwriting recognition (ML Kit & Apple Vision):**
   - On Android, when ML Kit `DigitalInkRecognizer` is ready (which reads raw `(x, y, t)` stroke vectors directly), Dart does **not** render an offscreen `ui.Picture` -> `ui.Image` -> PNG on the UI isolate just to throw the PNG away in Kotlin. Offscreen PNG rendering is performed lazily only when falling back to bitmap OCR.
   - On iOS/iPadOS, raw stroke coordinates are sent across the channel and rasterized natively on the background `DispatchQueue` via `CoreGraphics` (`CGContext`) directly into a `CGImage` for `VNImageRequestHandler`, removing GPU readback and PNG encode/decode from the Flutter UI isolate.
4. **Native-speed PDF rendering & vector PDF export:**
   - Remove pure-Dart `image.encodePng` from `PdfrxRasterizer.render` on the main isolate; use native C++/platform image encoding (`ui.Image.toByteData` or native platform codecs).
   - When exporting PDF-backed pages (`PdfExporter`), avoid synchronous main-isolate rasterization stalls and preserve vector fidelity or hardware-accelerated native rendering (`PDFKit` / `CGPDFDocument` on iOS, native/off-main-thread PDFium composition where applicable).
5. **Fast cold-start thumbnails & non-blocking autosave / storage:**
   - `ThumbnailCache` persists rendered first-page thumbnails to disk (keyed by note `id`, `modified` timestamp, and `brightness`) and/or reads only page `0` metadata so library cold start never loads and parses all pages/strokes of every notebook just to paint a card.
   - `FileNoteRepository` offloads large JSON `jsonEncode(content.toJson())` serialization from the UI isolate during `NoteAutosaver.flush()` and `GoogleDriveBackupService` hashing/encoding, preventing frame drops when autosaving multi-megabyte notebooks.

---

## Start with investigation, not a rewrite

Inspect the current implementation and tests before editing:

- **Native Ink & Stylus Input:**
  - `docs/native_ink.md`
  - `android/app/build.gradle.kts`
  - `android/app/src/main/kotlin/com/etonia/app/NativeInkChannel.kt`
  - `android/app/src/main/kotlin/com/etonia/app/MainActivity.kt`
  - `ios/Runner/NativeInkChannel.swift`
  - `ios/Runner/AppDelegate.swift`
  - `lib/features/editor/ink/native_ink_bridge.dart`
- **Ink Geometry, Spatial Hit-Testing, & Painting:**
  - `lib/features/editor/ink/stroke.dart` (`ActiveStroke`, `buildInkOutline`)
  - `lib/features/editor/ink/ink_painter.dart` (`CompletedStrokesPainter`, `ActiveStrokePainter`, `SelectionPainter`)
  - `lib/features/editor/ink/ink_controller.dart`
  - `lib/features/editor/ink/ink_canvas.dart`
  - `lib/features/editor/ink/erase_geometry.dart`
  - `lib/features/editor/ink/selection_geometry.dart`
  - `lib/features/editor/page/page_viewport.dart`
- **On-Device Handwriting Recognition:**
  - `lib/features/editor/ai/canvas_text_recognizer.dart`
  - `lib/features/editor/handwriting/handwriting_indexer.dart`
  - `android/app/src/main/kotlin/com/etonia/app/HandwritingRecognizerChannel.kt`
- **PDF, Goodnotes Import, Storage, & Thumbnails:**
  - `lib/features/editor/document_io/document_platform.dart` (`PdfrxRasterizer`)
  - `lib/features/editor/document_io/pdf_page_layer.dart`
  - `lib/features/editor/document_io/pdf_exporter.dart`
  - `lib/features/editor/document_io/goodnotes_archive_extractor.dart`
  - `lib/features/library/file_note_repository.dart`
  - `lib/features/library/note_content.dart`
  - `lib/features/library/note_autosaver.dart`
  - `lib/features/library/note_thumbnails.dart`
  - `lib/features/library/cloud/google_drive_backup_service.dart`
- **Performance & Integration Tests:**
  - `integration_test/ink_performance_test.dart`
  - `integration_test/loading_palette_performance_test.dart`
  - `test_driver/perf_driver.dart`

Run existing tests before making changes to establish a clean baseline.

---

## Workstream 1: Native Stylus Front-Buffer, Motion Prediction, & Incremental Active Ink

### 1.1 Android Front-Buffered Rendering & Motion Prediction (`NativeInkChannel.kt`)
- Add `androidx.graphics:graphics-core` and `androidx.input:input-motionprediction` to `android/app/build.gradle.kts`.
- In `NativeInkChannel.kt`:
  - Integrate `MotionEventPredictor.newInstance(view)` to record incoming stylus `MotionEvent`s and generate predicted sample points on `ACTION_MOVE` (used exclusively for transient native preview rendering, never emitted to Dart—matching the iOS contract in `docs/native_ink.md`).
  - Upgrade `NativeInkOverlay` to use `CanvasFrontBufferedRenderer` when supported by the device/API level, falling back cleanly to a dirty-rect-invalidated `View` (`invalidate(left, top, right, bottom)`) where front-buffer rendering is unavailable or during tests.
  - Ensure `finishPreview` and `PREVIEW_TIMEOUT_MS` clear the front buffer / overlay cleanly without visual flicker when Dart commits the finished stroke.

### 1.2 iOS Incremental Overlay & Dirty-Rect Rendering (`NativeInkChannel.swift`)
- In `NativeInkChannel.swift`:
  - Replace full-screen `setNeedsDisplay()` in `NativeInkOverlay` with targeted `setNeedsDisplay(dirtyRect)` covering only the union of the newly appended `actual` segment(s), the previous `predicted` tail (which is being erased/replaced), and the new `predicted` tail, inflated by the maximum stroke width.
  - In `draw(_ rect: CGRect)`, skip segments whose bounding box does not intersect `rect`, or maintain an incremental committed path/layer for `actual` points so a 1,000-point stroke does not re-stroke all 1,000 segments on every 240Hz Pencil callback.

### 1.3 Dart Incremental Variable-Width Outline (`lib/features/editor/ink/stroke.dart`)
- Currently, `ActiveStroke._appendPoint` sets `_outline = null`, causing `ActiveStroke.outline` to call `buildInkOutline(_points, _widths, style.width)` from index `0` on every frame (`O(N)` per frame, `O(N²)` per stroke).
- Refactor `ActiveStroke` so that while a variable-width stroke is in progress, each accepted point appends only the new segment's quad, turn disc/wedge, and end cap to the running outline `Path` in `O(1)` time.
- When `ActiveStroke.finish()` computes `_finalWidths()` (which tapers the tail over the last 40% of the stroke), build the final `Stroke.outline` cleanly so finished stroke geometry remains bit-for-bit identical to `buildInkOutline`.

---

## Workstream 2: Spatial Indexing & Viewport Culling for Canvas Performance

### 2.1 Viewport Frustum Culling in `CompletedStrokesPainter`
- `PageViewport` already computes `ValueListenable<Rect> visible` in page coordinates for each mounted page and passes it to `pageBuilder`.
- Wire the visible page `Rect` into `InkCanvas` / `CompletedStrokesPainter` (and `StickyNotesPainter` where applicable).
- In `CompletedStrokesPainter.paint`, skip any `Stroke` whose `stroke.bounds` does not overlap the current visible `Rect` (inflated by a small safety margin if needed). Ensure full-page rendering still occurs when `visible` is null or covers the full page (such as in snapshots/thumbnails/tests).

### 2.2 2D Spatial Index for Erasing & Lasso Selection
- Implement a lightweight, pure-Dart 2D spatial index (e.g., uniform spatial hash grid or R-tree over `Rect` bounds) in `lib/features/editor/ink/`.
- Use it in `InkController` (and `LassoRegion` / erase passes) to quickly query candidate strokes whose `bounds` intersect:
  - the eraser capsule bounding box `(minX - radius, minY - radius, maxX + radius, maxY + radius)` during `updateErase` / area and stroke erasing;
  - the lasso bounding box / edge cells during `selectWithOutline`;
  - `StrokeFollower` nearby-stroke queries and `ScribbleErase` overlap checks.
- Keep index maintenance incremental or lazily built per committed stroke list so undo/redo, transforms, and erases never return stale stroke references or alter paint/selection order (indices must still be returned in ascending document order).

---

## Workstream 3: Zero-Waste Native Handwriting Recognition (ML Kit & Apple Vision)

### 3.1 Lazy PNG Fallback on Android (`canvas_text_recognizer.dart` & `HandwritingRecognizerChannel.kt`)
- Currently, `HandwritingImageRenderer.render` always rasterizes strokes to a `ui.Image` and encodes a PNG before calling `com.etonia.app/handwriting_recognizer`, even though Android's primary `DigitalInkRecognizer` only reads the `strokes` vector array and ignores `png` unless the digital ink model is unavailable.
- Update the recognition pipeline so that:
  - `HandwritingBatch` can carry lazy/optional PNG bytes or `HandwritingIndexer` / `PlatformCanvasTextRecognizer` can query or send vector `strokes` first on Android, generating the PNG fallback only when native answers that bitmap OCR is required (or render the fallback bitmap natively on Android using `android.graphics.Canvas` + `Bitmap` off the UI thread directly from `strokes`, completely eliminating Dart-side PNG encoding!).
- Rendering the fallback `Bitmap` natively in Kotlin (`Bitmap.createBitmap` + `android.graphics.Canvas`) and `CGImage` natively in Swift (`CGContext`) from the `strokes` payload is even cleaner:
  - Both Android and iOS already receive `strokes` (`x, y, t`), `logicalWidth`, and `logicalHeight` in `PlatformCanvasTextRecognizer.recognizeDetailed`!
  - If iOS `HandwritingRecognizerChannel` in `AppDelegate.swift` renders the smooth quadratic path directly into a grayscale/RGB `CGContext` on its background `DispatchQueue` when `png` is omitted/empty, and Android `HandwritingRecognizerChannel.kt` renders a `Bitmap` only when `recognizePicture` fallback is actually triggered, **Dart never has to allocate a `ui.PictureRecorder`, GPU `ui.Image`, or PNG `ByteData` on the UI isolate for handwriting recognition.**
  - Keep backward compatibility in the native channels and `HandwritingImageRenderer` so existing unit tests and any explicit `png` callers continue to pass unchanged.

---

## Workstream 4: Native-Speed PDF Rendering, Export, & Storage/Autosave

### 4.1 Eliminate Pure-Dart PNG Encoding in `PdfrxRasterizer.render`
- In `lib/features/editor/document_io/document_platform.dart`, `PdfrxRasterizer.render` currently wraps `rendered.pixels` in `package:image` and runs `image.encodePng(decoded)` synchronously on the main isolate.
- Replace this with `rendered.createImage()` followed by `ui.Image.toByteData(format: ui.ImageByteFormat.png)` (and dispose the `ui.Image` in `finally`), or offload encoding to native/isolate so main-isolate UI frames are never blocked by Dart PNG compression.

### 4.2 Off-Main-Isolate Serialization for Autosave & Cloud Backup
- In `lib/features/library/file_note_repository.dart`:
  - `writeContent` currently runs `jsonEncode(content.toJson())` synchronously on the main isolate. For large notes (`>= 512 KB` or high stroke counts, matching the read path threshold), convert the plain-data JSON map and run `jsonEncode` (or UTF-8 byte encoding) in a background isolate via `compute` / `Isolate.run` before writing atomically to disk.
  - Ensure `FileNoteRepository` write ordering / atomicity is preserved so rapid saves or `flush()` calls never race or overwrite newer content with older content.
- In `lib/features/library/cloud/google_drive_backup_service.dart`:
  - Offload heavy `utf8.encode(jsonEncode(...))` and `sha256.convert(...)` for large note contents/assets to a background isolate when above a reasonable byte threshold so background auto-backups never jank active writing.

### 4.3 Fast First-Page Inspection & Persistent Disk Thumbnail Cache
- In `lib/features/library/note_thumbnails.dart` and `lib/features/library/file_note_repository.dart`:
  - Add a persistent disk cache for rendered thumbnails (e.g., under `<libraryDir>/thumbnails/<noteId>_<modifiedUs>_<brightness>.png`) or a lightweight first-page loader (`loadFirstPage(noteId)`) so `ThumbnailCache._draw` does not have to hydrate the `ui.Path`s of pages `1..N` of a 100-page notebook just to draw page `0`.
  - When a cached thumbnail PNG exists on disk for the exact `note.modified` timestamp and `style.brightness`, decode it directly via `ui.instantiateImageCodec` without loading `notes/<id>.json` or opening the PDF at all.
  - Clean up stale thumbnail files when a note is updated, deleted, or when `retainOnly` runs.

### 4.4 Faster PDF Export (`lib/features/editor/document_io/pdf_exporter.dart`)
- Optimize `PdfExporter.buildPdf` so PDF background preparation yields between pages, uses native/engine PNG encoding, and on iOS/macOS (or via a platform fast path when available) can composite vector ink over existing PDF pages without unnecessary quality loss or main-thread stalls. Keep the pure-Dart `pw.Document` path as a rock-solid cross-platform fallback so all existing `pdf_exporter_test.dart` tests continue to pass.

---

## Validation and acceptance criteria

Add focused unit, widget, and performance regression tests covering:

1. **Incremental `ActiveStroke` outline equivalence:**
   - Verify that a variable-width stroke (`StrokeDynamics(taper: ..., pressure: ...)`) produces a valid, non-empty `ActiveStroke.outline` at every step without rebuilding from scratch, and that `finish().outline` matches `buildInkOutline` geometry.
2. **Spatial index & viewport culling:**
   - Verify that erasing (area and stroke modes) and lasso selection (`LassoRegion` / `InkController.selectWithOutline`) with 1,000+ strokes return the exact same remaining pieces, stroke indices, and undo/redo history as the reference geometry.
   - Verify that `CompletedStrokesPainter` culls off-screen strokes when given a visible viewport `Rect` while painting all intersecting strokes in exact document order.
3. **Zero-copy / lazy handwriting recognition:**
   - Verify that recognition requests succeed when `strokes` are provided without blocking on redundant main-isolate PNG encoding, and that existing `HandwritingIndexer` and `PlatformCanvasTextRecognizer` tests pass.
4. **Storage, Autosave, & Persistent Thumbnail Cache:**
   - Verify that `ThumbnailCache` serves a cold-reopened library from the persistent disk cache without re-reading/re-rasterizing the note's PDF or full JSON content when `note.modified` and `brightness` are unchanged, and invalidates immediately when `note.modified` or `brightness` changes.
   - Verify that `FileNoteRepository.writeContent` preserves atomic write ordering under concurrent/sequential saves of both small and large notes.

Run and ensure zero issues on:

```powershell
flutter analyze
flutter test
```

And verify platform compilation:
- Android: `./gradlew compileDebugKotlin` (in `android/`)
- iOS (when on macOS): `xcodebuild` / `flutter build ios --simulator --no-codesign`

---

## Guardrails

- **Do not break schema compatibility:** Notes saved in schemas 1 through 5 must continue to load and save identically.
- **Preserve visual fidelity:** Ink smoothing (`OneEuroSmoother`), variable-width outlines, highlighter opacity compositing, sticky note clipping, and PDF export coordinates must remain visually identical.
- **Bounded memory:** Any new spatial index, native buffer, or disk/memory thumbnail cache must have explicit cleanup and disposal on widget/controller dispose and note deletion.

## Final handoff

Summarize:
1. Bottlenecks confirmed and architectural changes made across Android, iOS, and Dart.
2. How the incremental outline, 2D spatial index, native OCR rasterization, and persistent thumbnail cache work.
3. Verification results (`flutter analyze`, `flutter test`, native build checks, and benchmark metrics).
