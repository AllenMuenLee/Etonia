# Implementation prompt: zero-latency cross-platform canvas engine (iOS & Android)

You are working in the Greatnote (`Etonia`) Flutter repository. Implement a comprehensive, low-level performance engine upgrade that eliminates perceptible latency, input lag, and frame drops across all four core canvas interactions: **drawing (inking)**, **erasing**, **scrolling (panning)**, and **zooming (scaling)**.

This implementation **must fit natively and optimally for both iOS (iPadOS / Apple Pencil) and Android (Android Tablets / S-Pen / USI)**. It must leverage each operating system's platform-specific hardware acceleration, digitizer APIs, front-buffer/low-latency presentation layers, and touch prediction pipelines, while sharing a high-performance, zero-allocation Dart/Flutter graphics and spatial engine.

Do not treat this as a speculative refactor: profile before and after, preserve all existing behavioral contracts and document serialization compatibility, keep all unit/widget/integration tests green, and prove the speedups with deterministic latency benchmarks and DevTools frame-timing measurements.

---

## 1. Product & Platform Performance Targets

| Interaction | Target Latency / Frame Budget | iOS (iPadOS / Apple Pencil) Implementation | Android (S-Pen / USI / Stylus) Implementation |
|---|---|---|---|
| **Drawing (Inking)** | **≤ 2–4ms** glass-to-photon | `CAMetalLayer` / CoreGraphics dirty-rect overlay, 120Hz ProMotion `CAFrameRateRange`, 240Hz `UIEvent.coalescedTouches`, `predictedTouches(for:)` | `CanvasFrontBufferedRenderer` (Jetpack Graphics Core) on `SurfaceView`, `MotionEventPredictor` (Kalman), 120–240Hz `getHistorical*` batching |
| **Erasing** | **0ms visual lag** (< 8.3ms VSYNC) | Subtractive `BlendMode.clear` / CoreGraphics visual mask; instant object tombstoning; async segment splitting | Subtractive hardware mask / `RenderNode` clear; instant object tombstoning; worker isolate segment splitting |
| **Scrolling (Pan)** | **Locked 120 FPS / 60 FPS** (0 jank) | Composited `Flow` / `Transform.translate` GPU matrix translation; `UIPanGestureRecognizer` immediate touch handoff | Composited `Flow` / `Transform.translate` GPU matrix translation; raw unbuffered `MotionEvent` velocity tracker bypass |
| **Zooming (Scale)** | **Locked 120 FPS / 60 FPS** (0 jank) | Cached tile transforms with progressive resolution updates | Cached tile transforms with progressive resolution updates |

---

## 2. Start with Investigation, Not a Rewrite

Before making code edits, audit the platform implementations and establish baseline measurements:

### Core Files to Audit:
1. **iOS Native Layer:**
   - [`ios/Runner/NativeInkChannel.swift`](file:///C:/Users/limue/Documents/Projects/Etonia/ios/Runner/NativeInkChannel.swift): Inspect `NativeInkOverlay`, `NativeInkRecognizer`, `coalescedTouches`, `predictedTouches`, dirty-rect logic, and `UIPencilInteraction`.
   - `ios/Runner/AppDelegate.swift`: Check root view controller attachment and ProMotion CADisplayLink setup.
2. **Android Native Layer:**
   - [`android/app/src/main/kotlin/com/etonia/app/NativeInkChannel.kt`](file:///C:/Users/limue/Documents/Projects/Etonia/android/app/src/main/kotlin/com/etonia/app/NativeInkChannel.kt): Inspect `NativeInkOverlay`, `InProgressStrokesView`, `MotionEventPredictor`, and stylus event consumption.
   - `android/app/build.gradle.kts`: Check dependencies for `androidx.graphics:graphics-core`, `androidx.input:input-motionprediction`, and `androidx.ink`.
3. **Dart Flutter Engine Layer:**
   - [`lib/features/editor/ink/native_ink_bridge.dart`](file:///C:/Users/limue/Documents/Projects/Etonia/lib/features/editor/ink/native_ink_bridge.dart): Bridge protocol, pointer serialization, surface registration.
   - [`lib/features/editor/ink/stroke.dart`](file:///C:/Users/limue/Documents/Projects/Etonia/lib/features/editor/ink/stroke.dart): `ActiveStroke._appendPoint`, incremental outline generation.
   - [`lib/features/editor/ink/ink_canvas.dart`](file:///C:/Users/limue/Documents/Projects/Etonia/lib/features/editor/ink/ink_canvas.dart): Pointer dispatch, gesture coordination, widget boundaries.
   - [`lib/features/editor/ink/ink_painter.dart`](file:///C:/Users/limue/Documents/Projects/Etonia/lib/features/editor/ink/ink_painter.dart): `ActiveStrokePainter`, `CompletedStrokesPainter`, culling.
   - [`lib/features/editor/ink/stroke_spatial_index.dart`](file:///C:/Users/limue/Documents/Projects/Etonia/lib/features/editor/ink/stroke_spatial_index.dart): 2D spatial queries.
   - [`lib/features/editor/ink/erase_geometry.dart`](file:///C:/Users/limue/Documents/Projects/Etonia/lib/features/editor/ink/erase_geometry.dart): Stroke segment intersection math.
   - [`lib/features/editor/page/page_viewport.dart`](file:///C:/Users/limue/Documents/Projects/Etonia/lib/features/editor/page/page_viewport.dart): Zoom/pan transform, gesture disambiguation.

### Baseline Diagnostics:
- Execute `flutter test` to ensure existing baseline tests pass.
- Capture DevTools Performance profiles on an iPad (ProMotion 120Hz) and an Android tablet (Samsung S-Pen 120Hz or emulator with stylus emulation).
- Record UI thread ms, Raster thread ms, GC pause duration, and input latency for:
  - High-speed handwriting with stylus.
  - Erasing back-and-forth across 5,000+ vector strokes.
  - Continuous two-finger panning down a multi-page document.
  - Rapid pinch-to-zoom gestures (0.5x to 4x).

---

## 3. Workstream Breakdown

### Workstream 1: Inking Pipeline — Dual-Platform Hardware Acceleration

#### 1.1 iOS / iPadOS Implementation (`NativeInkChannel.swift`)
- **ProMotion 120Hz & 240Hz Digitizer Synchronization:**
  - Request 120Hz refresh rates using `CADisplayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)`.
  - Process all `UIEvent.coalescedTouches(for: touch)` inside `touchesMoved` to ensure no 240Hz sub-frame samples from the Apple Pencil are discarded.
  - Read `UIEvent.predictedTouches(for: touch)` and render the predicted stroke tail to the pencil tip.
- **Incremental Dirty-Rect Overlay:**
  - Replace any full-view invalidation with targeted `setNeedsDisplay(_ rect: CGRect)`.
  - Calculate `rect` as the exact bounding union of:
    1. The newly appended actual sample segment(s);
    2. The previous predicted tail (which must be cleared);
    3. The new predicted tail, inflated by the maximum stroke width + padding.
  - Maintain a committed CGPath or Metal sub-texture so historical points in a 2,000-point stroke are never re-stroked on each new touch sample.
- **Apple Pencil Pro / Pencil 2 Features:**
  - Wire `UIPencilInteractionDelegate` for double-tap and squeeze (tool switching, eraser toggles, palette popups) without breaking Flutter event routing.

#### 1.2 Android Implementation (`NativeInkChannel.kt`)
- **Hardware Front-Buffered Rendering (`androidx.graphics:graphics-core`):**
  - Use `CanvasFrontBufferedRenderer` with an overlay `SurfaceView` to bypass the Android compositor (Choreographer/SurfaceFlinger) during active drawing.
  - Render wet stylus strokes directly to the hardware front buffer to reach ~2–4ms glass-to-photon latency.
  - Provide a safe fallback to dirty-rect invalidated `View` (`invalidate(l, t, r, b)`) on devices/APIs that do not support front-buffer rendering.
- **Input Motion Prediction (`androidx.input:input-motionprediction`):**
  - Integrate `MotionEventPredictor.newInstance(view)`.
  - Feed every incoming stylus `MotionEvent` into the predictor.
  - On `ACTION_MOVE`, retrieve predicted samples and render them exclusively to the transient front buffer (never dispatch predicted points to Dart, preserving document fidelity).
- **Historical Sample Extraction:**
  - Extract all batched points via `motionEvent.getHistoricalX/Y/Pressure/EventTime` in `ACTION_MOVE` and send the complete high-frequency packet to Dart.
- **Clean Handshake & Tear-Down:**
  - On `finishPreview`, transition from the front buffer to Flutter's committed layer smoothly without screen tearing or visual flicker.

#### 1.3 Shared Dart $O(1)$ Incremental Geometry (`stroke.dart`)
- **Eliminate $O(N^2)$ Outline Construction:**
  - In `ActiveStroke._appendPoint`, do not set `_outline = null` or re-tessellate from index 0.
  - Construct an incremental outline `Path`: on each accepted `InkSample`, compute only the trapezoid/quad between point $N-1$ and $N$, plus the joint disc/wedge, and append directly to the active path in $O(1)$ time.
  - On `ActiveStroke.finish()`, compute final tapering/smoothing and bake the immutable `Stroke.outline`.
- **Zero-Allocation Touch Loop:**
  - In `ink_canvas.dart`, eliminate all dynamic object creation, closure allocations, and string formatting in `onPointerMove`. Reuse fixed scratch `Offset`s and `Matrix4` instances.

---

### Workstream 2: Eraser Pipeline — Subtractive Visual Mask & Spatial Indexing

#### 2.1 Instant Visual Subtraction (0ms Perceptual Latency)
- **Immediate Visual Eraser Layer:**
  - Introduce an `EraserMaskPainter` on an isolated `RepaintBoundary` positioned directly above the completed strokes layer.
  - On both iOS and Android, when the eraser pointer moves, paint the eraser trajectory immediately using `BlendMode.clear` into the intermediate layer.
  - Strokes visually disappear beneath the eraser cursor on the very next frame, completely decoupled from underlying vector math or model modifications.

#### 2.2 $O(1)$ Spatial Index Queries (`stroke_spatial_index.dart`)
- **Dynamic 2D Spatial Partitioning:**
  - Enhance `StrokeSpatialIndex` (uniform grid or R-tree) to support dynamic $O(1)$ stroke removals and incremental additions.
  - When an eraser event arrives at $(x, y)$ with radius $R$, query only the bounding cells intersecting `Rect.fromCircle(center: Offset(x, y), radius: R)`.
  - In **Object Eraser** mode: tombstone intersecting strokes instantly in a `BitSet` / `HashSet<int>`, triggering a minimal dirty-rect repaint without re-allocating stroke arrays.

#### 2.3 Asynchronous Stroke Segment Splitting (`erase_geometry.dart`)
- **Offload Heavy Geometry Math:**
  - In **Partial / Segment Eraser** mode, cutting a bezier stroke into multiple sub-strokes involves complex polynomial intersection math.
  - Collect cut points in a pending batch and execute the geometric splitting off the main UI isolate (or in a scheduled microtask).
  - Once calculated, replace the original stroke with the new split stroke fragments in `InkController` and push the batch operation to `UndoHistory`.

---

### Workstream 3: Scrolling & Panning Pipeline — Decoupled GPU Compositing

#### 3.1 GPU Matrix Translation (Zero Repaint Overhead)
- **Transform-Only Panning (`page_viewport.dart`):**
  - Mount document pages and completed ink canvases inside an isolated `RenderTransform` / `Flow` layer wrapped in a `RepaintBoundary`.
  - During two-finger scroll or trackpad pan, apply pan deltas directly to the layer's 2D translation matrix (`Matrix4.translationValues(dx, dy, 0)`).
  - Ensure that panning executes strictly as a GPU texture blit: verify that `CustomPainter.paint` is **never** invoked on completed strokes, background sheets, or PDF pages during a pan gesture.

#### 3.2 Viewport Frustum Culling (`ink_painter.dart`)
- **Bounds-Based Draw Call Elimination:**
  - In `CompletedStrokesPainter.paint`:
    - Derive the visible page rectangle from `PageTransform`.
    - Query `StrokeSpatialIndex.query(visibleRect)` to retrieve only visible strokes.
    - Skip drawing all strokes located outside the visible viewport rect.
  - Apply identical culling to PDF vector layers, images, and sticky notes.

#### 3.3 Platform Gesture Arena Bypass
- **iOS:** Route two-finger touches through `UIPanGestureRecognizer` directly to `PageViewport`. Claim pointers immediately via `PointerClaims` to avoid waiting for tap/press gesture recognition timeouts.
- **Android:** Handle multi-finger `ACTION_POINTER_DOWN` without latency; immediately consume events once a two-finger scroll threshold (4dp) is reached, bypassing competing gesture detectors.

---

### Workstream 4: Zooming & Scaling Pipeline — Two-Phase Scale & Level of Detail (LOD)

#### 4.1 Cached Tiles During Pinch and Scroll
- Keep vector strokes as the canonical document. Composite reusable 256-unit document tiles during gestures; do not capture the whole viewport or redraw warm stroke paths every frame.
- Retain power-of-two resolution levels from 1/8x through 8x. Fractional scale changes within a level reuse its images, and returning to a previous level reuses retained images.
- Prioritize missing visible content, then visible detail, then a one-tile prefetch band. During active pinch, only missing visible previews may run; defer higher-resolution detail and prefetch until a pause or release so they do not compete with animation frames. Use existing levels immediately; cold content remains visible through spatially queried vector fallback while its first image is prepared. Retain that fallback display list so repeated cold frames and the first raster job reuse its commands, then release it after the first image arrives.
- Set `CustomPaint.willChange` during pinch to prevent the framework from raster-caching the entire already-tiled ink layer at every new scale. Keep the tile images themselves cached.
- Add a pixel gutter to each tile so filtered edges remain continuous, including transparent highlighters.

#### 4.2 Progressive Detail and Bounded Work
- Share one scheduler across pages. Record at most 64 strokes per slice and yield after a 2 ms deadline checked between strokes. Run recording slices after frames, and allow only one asynchronous `Picture.toImage` operation at a time. Never call `toImageSync` from the paint path.
- Keep all cached images under a shared 96 MiB ownership budget. Evict least recently used detail levels before coarse previews, and keep offscreen tiles at preview resolution rather than spending GPU work and memory on invisible detail. Dispose cancelled recorders, discarded late images, and replaced levels.
- Validate tile content against immutable stroke identity and spatial-index changes. Erase, undo, selection, native handoff, visibility, theme changes, and disposal must never display stale tile results.
- Hold padded page-local paint coverage until the view leaves it. Repaint completed ink on resolution-level changes, document/visibility changes, tile completion, and gesture settling; reuse its recorded layer for fractional zoom transforms within a level. The cache owns and disposes its filtered scale subscription. Reuse unscaled column metrics across pinch updates and compute rectangles only for pages actually queried.
- Retain release/cancellation and 120 ms stillness settling behavior, without discarding useful levels or blocking on sharp tile production.
- Extend density profiling with tile memory, queued work, raster counts, vector-fallback counts, and the actual display refresh budget. Use `DENSITY_ZOOM_ONLY=true` for pinch-only runs; `INK_PROFILE_EVERY_ZOOM_FRAME=true` restores the previous repaint/detail behavior for controlled comparison builds. Verify real latency and frame percentiles in profile mode on representative physical tablets; widget tests alone do not establish speed.
- **Paper & Grid Shaders:**
  - Render background paper grids (dots, lines, isometric) using a lightweight procedural fragment shader (`ui.FragmentProgram`) or tiled paint shader that evaluates grid math dynamically at any scale without raster memory reallocation.

#### 4.3 Zero Layout Invalidation
- Guarantee that neither scroll nor zoom adjustments call `markNeedsLayout()`. Viewport scale and translation must operate exclusively on the `RenderBox` paint transform.

---

## 4. Multi-Layer Render Architecture

Organize the canvas widget hierarchy into strictly isolated rendering layers, each separated by a `RepaintBoundary`:

```
┌─────────────────────────────────────────────────────────────┐
│ 1. Viewport Layer (GPU Transform / Matrix4 Translation)     │
├─────────────────────────────────────────────────────────────┤
│ 2. Background Layer (Grid / Lines / Procedural Shader)      │
│    -> Cached ui.Picture; painted once                       │
├─────────────────────────────────────────────────────────────┤
│ 3. Document Content Layer (PDF, Images, Text)               │
│    -> Frustum-culled; cached raster textures                │
├─────────────────────────────────────────────────────────────┤
│ 4. Completed Ink Layer (Baked Vector Strokes)               │
│    -> Cached ui.Picture chunks / spatial tile grid          │
├─────────────────────────────────────────────────────────────┤
│ 5. Active Inking & Eraser Mask Layer                        │
│    -> Unbuffered, isolated 120Hz direct paint layer         │
├─────────────────────────────────────────────────────────────┤
│ 6. Native Hardware Front-Buffer Overlay (Android/iOS)       │
│    -> Stylus preview & motion prediction (bypasses Flutter) │
├─────────────────────────────────────────────────────────────┤
│ 7. UI Controls & Selection Handles Layer                    │
│    -> Lasso boundary, ruler, laser pointer                  │
└─────────────────────────────────────────────────────────────┘
```

---

## 5. Architectural Constraints & Platform Guardrails

- **Zero Widget Rebuilds in Hot Paths:** Never call `setState()` in pointer event callbacks (`onPointerDown`, `onPointerMove`, `onPointerUp`). Use `ValueListenable` or direct `RenderObject` painting.
- **Zero Allocations in Pointer Loops:** No dynamic list growth, no closure allocation, no string interpolation inside `onPointerMove`.
- **Cross-Platform Parity:** Feature implementations on iOS and Android must adhere to the exact same coordinate space, event order, and stroke serialization schema.
- **Preserve Full Document & Storage Compatibility:** Do not change the JSON format or model representation of `Stroke`, `InkVector`, or `NoteContent`. All changes must be transparent to `FileNoteRepository`.
- **Maintain Undo/Redo Invariants:** Erasing, drawing, and transforming strokes must push identical, deterministic commands to `UndoHistory`.
- **Preserve All Interaction Capabilities:** Laser pointer, ruler snapping, sticky notes, handwriting OCR indexing, and PDF export must continue to function flawlessly.

---

## 6. Verification, Benchmarks & Acceptance Criteria

### Automated Verification:
1. **Unit & Geometry Tests:**
   - `test/features/editor/ink/stroke_test.dart`: Verify that incremental outline generation matches `buildInkOutline` output bit-for-bit upon completion.
   - `test/features/editor/ink/erase_geometry_test.dart`: Verify precision and object erase correctness across overlapping strokes.
   - `test/features/editor/page/page_viewport_test.dart`: Verify transform matrix math, culling rect calculations, and zoom limits.

2. **Cross-Platform Performance Benchmarks (`benchmark/` & `integration_test/`):**
   - Run `ink_performance_test.dart` on iOS and Android:
     - Stylus drawing input-to-render latency must measure **≤ 4ms** (with front-buffering/native overlay enabled).
     - Frame drop rate during continuous drawing must be **0.0%**.
   - 10,000-stroke density benchmark:
     - Viewport pan/scroll frame times must remain strictly < 16.6ms (60 FPS) and < 8.3ms (120 FPS).
     - Pinch zoom must maintain 60+ FPS throughout the entire gesture duration without GC spikes.
     - Eraser hit-test time on a 10,000-stroke page must complete in < 1.0ms per pointer event.

3. **DevTools Profile Mode Validation:**
   - Confirm zero unnecessary widget rebuilds in `_InkCanvasState` during pointer moves.
   - Confirm tile reuse during scrolling and zooming on both platforms, bounded progressive updates, and no warm-frame vector fallback.
