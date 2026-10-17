# Implementation prompt: instant note switching, bounded memory, and direct-manipulation toolbar dragging

You are working in the Greatnote Flutter repository. Implement a measured performance pass that makes opening/switching notes feel immediate and makes the floating tool palette track the user’s finger without perceptible lag, while reducing avoidable retained memory. Do not treat this as a cosmetic loading-state task: profile, identify the critical paths, implement the smallest safe architecture changes, and prove the result with tests and measurements.

## Product outcome

The interaction target is the feel of a native iPad note app:

1. When a note is opened or a tab is selected, the incoming note’s first page (or an accurate, already-available visual representation of it) is visible during the transition rather than a blank editor, shimmer, or a delayed route. A previously visited tab must be visually ready before its transition starts.
2. A toolbar drag must follow every delivered finger update on the next frame. Moving it must not cause the page viewport, ink canvases, PDF/image layers, or unrelated editor UI to rebuild or repaint on every pointer update.
3. The above must not be achieved by retaining every document, decoded image, PDF byte buffer, thumbnail, or asynchronous result indefinitely. Caches must have explicit ownership, invalidation, and bounded memory policies.

“Apple-level” is a responsiveness goal, not a license to claim a frame rate without evidence. Report actual measurements, device/profile mode, and any remaining platform constraint.

## Start with investigation, not a rewrite

Read the relevant implementation and tests before changing code. At minimum inspect:

- `lib/features/library/library_screen.dart` (`_openNote`, `_preloaded`)
- `lib/features/library/note_tabs_page.dart` and `open_notes.dart`
- `lib/features/library/note_editor_page.dart`
- `lib/features/library/note_content.dart`, `note_repository.dart`, and `file_note_repository.dart`
- `lib/features/library/note_thumbnails.dart`
- `lib/features/editor/editor_screen.dart`
- `lib/features/editor/widgets/tool_palette.dart`
- `lib/features/editor/page/page_viewport.dart`
- `lib/features/editor/document_io/pdf_page_layer.dart` and `document_io_config.dart`
- `lib/features/editor/document_io/image_layer.dart`
- the existing performance/integration tests under `benchmark/`, `test_driver/`, `integration_test/`, and `test/`.

Use `rg` to trace construction, disposal, image decoding, repository reads, timers, and all cache-like collections. Run the existing relevant tests before edits. Capture a profile-mode DevTools trace on a representative physical tablet if available; otherwise use profile mode on the configured emulator and clearly say so. Inspect UI/raster frame timing, rebuild/repaint activity, allocation growth, and GC pauses for these flows:

- cold open of a large note;
- opening a second note while an editor is already displayed;
- repeatedly switching between two loaded tabs;
- switching among more tabs than the selected warm-cache budget;
- dragging the palette continuously for several seconds over a page containing ink, images, and a PDF.

Do not optimize speculative hotspots. State the baseline findings in the final handoff and use them to choose the changes below.

## Note-opening and tab-switching work

The current code already attempts a short preload in `LibraryScreen`, retains editors in `NoteTabsPage`, and preloads neighbouring PDF pages. Evaluate those mechanisms rather than duplicating them.

Implement an explicit, bounded two-tier strategy appropriate to this app:

- **Visible-path priority:** navigate/activate promptly and ensure that the first meaningful frame has a page. For a truly cold note, use a faithful first-page preview already available in the library thumbnail cache or a lightweight page shell while hydration completes; do not hold navigation behind an arbitrary timeout merely hoping the full document finishes loading.
- **Warm state:** retain enough state for recently used tabs to switch with no repository read, parse, or first-page render in the transition path. Preserve editor correctness: unsaved content, undo/redo, current page, selections, clipboard, AI state, and autosave behavior must not be lost or race with eviction.
- **Cold state / eviction:** do not retain an unbounded number of heavyweight editor trees and documents. Choose a small, documented LRU or memory-pressure-aware warm budget. On eviction, flush safely, cancel/detach listeners and async work, dispose controllers/resources, and retain only the minimum cheap restoration/preview data required. Never evict the active note or discard unsaved changes.
- **Request coordination:** coalesce duplicate loads for the same note, prevent stale late completions from changing the active tab, and do not decode or create the same initial content twice. Cancellation/ignoring stale work must be safe when a tab closes or the widget disposes.
- **Transition correctness:** outgoing and incoming content may overlap only for the transition duration, should receive ticks only when necessary, and must not show an incorrect note, blank flash, or a full-screen loading shimmer for an already-warm tab. Respect reduced-motion settings.

Prefer a cache whose entries have a stated cost/budget and lifecycle over a global `Map` of permanently retained `NoteContent`/documents. Cache small preview representations separately from live `NoteDocument` instances. Do not serialize a document on every tab switch just to cache it.

## Memory work

Audit the whole relevant path, not only tab widgets. In particular investigate decoded `ui.Image` objects, `ImageProvider`/Flutter image cache participation, PDF source byte buffers, PDF render entries, PNG re-encodes, note thumbnails, page image layers, asset reads, timers, notifiers/listeners, and in-flight futures.

Fix demonstrable unnecessary retention. Requirements:

- Every image/resource owner has a clear disposal path. Dispose only images the app owns; do not prematurely dispose a borrowed or framework-owned image.
- Convert count-only caches to a defensible bounded policy where byte cost can vary materially (especially PDF images). Account for decoded pixel memory (`width * height * 4`) and any concurrently retained encoded bytes; maintain LRU behavior and never evict an item while it is actively borrowed.
- Keep cache keys correct across note ID, asset ID, page index, dimensions/device pixel ratio, and visual state as applicable. Do not reuse a preview for the wrong note/page or at an invalid scale.
- Deduplicate simultaneous asset reads/renders and remove failed/cancelled/stale entries reliably.
- Release cache entries when their note/tab is closed or evicted, and clear any app-owned cache on relevant configuration/source changes.
- Do not globally call `imageCache.clear()` as a shortcut. Do not lower raster quality or cache size blindly; choose quality/cache limits based on measured memory and first-page latency.

If the repository format currently requires parsing all note data to reach page one, make a narrowly scoped plan/implementation that avoids main-isolate jank without breaking backward compatibility. Use an isolate only for work that is safe to transfer and demonstrate that serialization overhead does not outweigh the benefit.

## Toolbar drag work

Trace the pointer event through `_LiftableSurface`, `ToolPalette`, `EditorScreen`, `_EditorLayout`, and `PageViewport`. The drag currently routes updates through editor-level state; verify precisely what rebuilds/repaints as a consequence.

Rework it so direct manipulation is isolated:

- Keep the current interaction contract unless evidence supports a small documented change: a normal tool tap must still work, a deliberate hold/lift begins a drag, placement docks and persists on release, and accessibility move actions continue to work.
- After drag activation, use the latest pointer position/delta for each delivered update. Avoid timer/debounce/throttle behavior that makes the palette visibly trail the finger.
- Move only the palette/its minimal positioning layer during drag (for example a dedicated `ValueNotifier`/render boundary/positioning widget). Do not call `setState` on the editor shell for every move, recompute page geometry, schedule PDF preloads, or rebuild the page stack because the palette moved.
- Separate the transient free-drag position from the persisted docked `PalettePlacement`; write the persistent placement once at drop (and when moved with accessibility actions), not on every update.
- Use `RepaintBoundary` deliberately around the movable palette and expensive page layers where DevTools confirms it helps. Avoid excessive boundaries and do not add a blur/filter that forces the whole page to repaint during a drag.
- Verify no hit-testing, gesture-arena, scale animation, `AnimatedPositioned`, or `BackdropFilter` behavior is introducing a one-frame delay. Preserve correct clipping, safe-area, edge snapping, and all window-size classes.

## Validation and acceptance criteria

Add focused regression tests, using fakes/controllable futures where useful, for at least:

- immediate first-page/preview presentation for a cold open and direct presentation for a warm tab;
- no duplicate load when a note is requested repeatedly or activated while already loading;
- stale completions cannot replace a different active note;
- warm-cache eviction is bounded, flushes/disposes safely, and reopening still restores correct content;
- PDF/image cache LRU and byte/resource eviction, including disposal and in-flight borrow safety;
- palette drag updates transient position without rebuilding the page viewport/editor shell on every move (instrument with a test seam/counter instead of relying solely on a wall-clock assertion);
- final palette docking, persistence, taps, and accessibility move actions still work.

Run the smallest relevant tests while iterating, then at least:

```powershell
flutter analyze
flutter test
```

Run an integration/profile benchmark for the two target interactions when the environment permits. Include before/after results for first meaningful page latency, warm-switch latency, p50/p95 UI and raster frame times, jank-frame count, and memory after repeated tab switching/dragging. If a metric cannot be collected in CI, provide a reproducible command/script and state the limitation; do not invent numbers.

## Guardrails

- Preserve existing note storage compatibility and user data. Never drop unsaved edits.
- Make no unrelated redesigns, formatting churn, or package additions unless essential and justified.
- Maintain accessibility, reduced motion, mouse/trackpad behavior, and existing tests/goldens.
- Prefer small testable units and comments that explain cache ownership, budget choice, and disposal invariants.

## Final handoff

Summarize: root causes confirmed by profiling; changed files and design; cache budgets and why; before/after measurements with environment; tests/commands run; and any remaining follow-up or device-specific limitation.
