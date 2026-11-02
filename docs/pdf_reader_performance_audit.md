# PDF reader performance audit

Date: 2026-11-01

## Scope and measurement status

This audit covers the mobile editor's PDF display, scrolling, zooming,
render scheduling, caches, annotations, and resource ownership. Static
analysis and host-side Flutter tests are repeatable in this repository. The
existing `integration_test/pdf_scroll_performance_test.dart` is the profile
build/device benchmark for generated textbook and scanned PDFs, but no iOS or
Android device was attached for this audit. Consequently, this document makes
no before/after frame-time claim.

## Existing architecture

- `pdfrx` 2.4.8 renders PDFium pages. `PdfDocument.openData` uses progressive
  loading, and an open document is reused across page renders.
- PDFium rasterization is asynchronous in the plugin/native engine. Copying
  large BGRA results into Flutter images still crosses the Dart UI isolate, so
  `document_platform.dart` divides large page images into roughly 0.5 MP
  bands before handing them to the engine.
- `PageViewport` keeps lightweight geometry for all pages and builds only the
  visible page plus roughly one viewport before and after it.
- `PdfPageRenderCache` owns a single-concurrency priority queue. Visible
  previews precede sharp renders; sharp work pauses during rapid movement;
  duplicate requests share one entry; canceled or obsolete results are
  ignored and disposed.
- Page resolution uses displayed size, device-pixel ratio, and a quantized
  zoom scale. Existing paper remains visible while a sharper result loads.
- At deep zoom, `pdfrx`'s clipped `x/y/width/height` rendering sharpens only
  the visible page region. This is real clipped PDFium rendering, not
  full-page rendering followed by a crop.
- Decoded PDF paper, inserted images, source bytes, ink geometry, and open
  documents share `NoteCachePool`. The pool evicts least-recently-used idle
  notes/pages and protects shown pages. Small PDF previews may also persist in
  a bounded disk cache.
- PDF paper, masks, inserted images, completed ink, active ink, and interaction
  controls are separate layers. PDF rasterization is not triggered by a
  stroke. Completed ink uses spatial culling; native wet ink is available for
  low-latency stylus feedback.
- PDF documents, `PdfImage` objects, codecs, Flutter images, cache entries,
  timers, listeners, and render tickets have explicit close/dispose paths.
  Memory-pressure notifications release idle decoded images, source bytes,
  and open PDFs.

## Findings and changes selected

| Finding | Impact | Change |
| --- | --- | --- |
| `PageViewport` recreated all page rectangles and linearly scanned all pages on every scroll frame. | UI-isolate work grew with total document length even though only nearby page widgets were built. | Reuse unchanged column geometry, binary-search ordered page rectangles, and iterate only the viewport build window. |
| The default shared cache budget was 1 GiB. | Excessive decoded/native image retention and memory-pressure risk on mobile. | Use a conservative 128 MiB total default, with about 115 MiB available to open notes after the library share. |
| Scheduler/cache behavior had test visibility but no coherent snapshot. | Queue depth, cache effectiveness, cancellation, and render latency were hard to compare in benchmarks. | Add a low-overhead diagnostic snapshot and include its counters in the profile benchmark output. |
| A timer-based scheduler test can fail when unrelated Flutter test processes contend for the host. | False negative in parallel local validation. | Keep performance-sensitive Flutter tests in one process; the test passes in isolation. |

## Known limits

- Physical-device profile measurements remain required on representative
  60 Hz and 120 Hz iOS/Android hardware.
- Deep zoom currently renders one clipped, margin-inflated visible region at
  a time. PDFium supports the required clipping efficiently; fixed 256/512 px
  independently cached tiles should only replace this simpler region strategy
  if device traces show reuse or latency benefits exceeding scheduling and
  compositing overhead.
- PDFium work already runs through `pdfrx`; adding another PDF engine is not
  justified by current evidence and would add licensing, compatibility, and
  maintenance risk.
- Text selection/search and hyperlinks should continue to use PDF structure,
  not page rasters. The current editor preserves outlines but does not expose
  every PDF interaction feature listed as a possible requirement.

## Validation completed

- Targeted PDF, viewport, document-I/O, ink-culling, cache, memory-pressure,
  multi-tab, and gesture suites: 129 tests passed.
- Static analysis of changed paths: no errors or warnings. Flutter 3.50 emits
  prerelease migration infos for legacy `flutter/material.dart` imports.
- The complete host suite reached 1,718 passes and 7 skips, with 50 failures
  in pre-existing editor/library golden images and the unrelated
  `no_spinners_test` rule. The PDF-focused suites remained green.
- A profile APK benchmark was attempted for the connected Android 16 device,
  but the build is blocked in the existing
  `android/app/src/main/kotlin/com/etonia/app/NativeInkModel.kt` at lines
  77-79 (invalid Kotlin constructor parameters), with follow-on unresolved
  references around lines 405-409. No device performance numbers are reported.
