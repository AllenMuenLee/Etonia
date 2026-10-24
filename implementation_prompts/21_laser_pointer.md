# Implementation Prompt 21: Laser Pointer Tool and Toolbar Extension

You are working in the **Greatnote** (`Etonia`) Flutter tablet repository. Add a presentation **Laser Pointer** tool and a **toolbar extension system** (right arrow expansion) to the editor's floating tool palette.

The app already features responsive tablet layouts, a low-latency 120Hz ink canvas, pen and highlighter styles, area and stroke erasers, lasso selection and transforms, sticky notes, image insertion, and an AI assistant. Preserve all existing drawing behaviors, input pipelines, and accessibility contracts.

---

## Product outcome

1. **Toolbar Extension via Right Arrow:**
   - The primary floating `ToolPalette` retains its clean, focused primary toolset (Pen, Eraser, Select, Sticky Note, Insert Image, AI Mode).
   - At the trailing end of the palette (right side in horizontal dock, bottom in vertical dock), add an extension toggle button featuring a right arrow icon (`AppIcons.forward` / `CupertinoIcons.chevron_right`).
   - Tapping the right arrow expands the toolbar with a smooth, responsive transition to reveal secondary tools: the **Laser Pointer** and the **Ruler**.
   - When expanded, the arrow flips to indicate collapsing (`AppIcons.back` / `CupertinoIcons.chevron_left`), allowing the user to tuck secondary tools away and regain canvas space.
2. **Presentation Laser Pointer:**
   - An ephemeral, non-destructive pointing tool tailored for live presentations, teaching, screen projection, and video recording.
   - Dragging a stylus, finger, or mouse across the canvas draws a luminous, glowing laser dot and decaying light trail that automatically fades out over time.
   - **Zero persistence / zero document mutation:** Laser marks do not create permanent strokes, do not modify `NoteDocument`, do not trigger undo/redo, do not mark notes as dirty, and do not trigger autosave.
   - **Ultra-low latency (120Hz / ProMotion):** Drawn in a dedicated transient overlay layer with zero re-rasterization of completed document ink.

---

## Scope

### What to build
- A collapsible toolbar extension mechanism on `ToolPalette` with a right arrow expand/collapse button.
- Responsive animation and touch target layout for expanded and collapsed states, adjusting `ToolPalette.sizeFor` dynamically.
- `EditorTool.laser` in `eraser_settings.dart` and the editor state machines.
- Laser configuration model (`LaserSettings` and `LaserConfig`): laser mode (trail vs. dot-only), color palette (Ruby Red, Emerald Green, Electric Cyan, Amber Gold), and trail persistence duration (300ms to 2000ms).
- Floating laser options popover (opened by pressing the Laser button while active), matching existing `PalettePopover` patterns.
- High-performance decaying laser trail renderer (`LaserPainter`) operating on a localized `Ticker` that sleeps when no trail is visible.
- Full dark and light page contrast handling, ensuring laser beams remain vivid and readable across pure white, dark, and PDF backgrounds.

### What to exclude
- Do not persist laser trails into saved note files or exports.
- Do not include the laser in undo/redo history or selection hit-testing.
- Do not route audio recording controls into the tool palette (audio recording belongs strictly in the main bar).
- Do not alter existing pen smoothing or eraser geometry pipelines.

---

## Architecture and existing code to build on

Inspect and integrate with these core modules:
- `lib/features/editor/widgets/tool_palette.dart`:
  - `_PaletteButtonsLayout`: currently calculates fixed sizes based on `_buttonCount = 6` and `_buttonStep = 44`.
  - `ToolPalette.sizeFor`: derives palette dimensions for layout margins in `editor_screen.dart`.
  - `ToolPaletteController`: holds `MenuController` handles for popovers. Add `laserMenu`.
- `lib/features/editor/ink/eraser_settings.dart`:
  - `EditorTool`: add `laser` to `enum EditorTool { pen, eraser, select, sticky, ai, laser, ruler }`.
- `lib/features/editor/ink/ink_canvas.dart`:
  - Pointer routing: routes stylus, touch, and mouse events to laser tracking when `EditorTool.laser` is active.
- `lib/features/editor/editor_screen.dart`:
  - Layout calculations and palette positioning when expanding/collapsing.
- `lib/app/theme/app_icons.dart`:
  - Add icons for laser (`CupertinoIcons.rays` or `CupertinoIcons.scope`) and expand/collapse chevrons.
- `lib/app/theme/app_tokens.dart`:
  - Ensure high contrast standards for laser colors against both light and dark canvas surfaces.

---

## Detailed design specifications

### 1. Toolbar extension mechanism (Right Arrow)

- **Button placement:**
  - Place the right arrow button at the end of the primary button sequence in `ToolPalette`.
  - In horizontal orientation (top/bottom docked), it sits at the right end (`CupertinoIcons.chevron_right`).
  - In vertical orientation (left/right docked), it sits at the bottom end (`CupertinoIcons.chevron_down`).
- **Expanded state:**
  - When pressed, the palette animates smoothly (200ms ease-out) to an extended width/height to reveal the secondary tools:
    1. **Laser pointer** (`PaletteButton`)
    2. **Ruler** (`PaletteButton`)
  - The toggle icon flips to a left chevron (`CupertinoIcons.chevron_left` / `CupertinoIcons.chevron_up`) with the tooltip "Collapse toolbar".
- **Dynamic size & layout:**
  - Update `ToolPalette.sizeFor(Axis axis, {bool expanded = false})` so `EditorScreen` adjusts safe boundaries and page margins without jumps or clipping.
  - Palette placement clamping: when docked near the right or bottom screen edge, expanding the palette must not push buttons off-screen; it expands inward or re-clamps safely within viewport bounds.
  - Semantics: announce "Tools expanded, 2 additional tools available" and "Tools collapsed" to assistive screen readers.

### 2. Laser pointer tool state & configuration

- Create `LaserSettings` (immutable value object):
  ```dart
  enum LaserMode { trail, dot }

  @immutable
  class LaserSettings {
    const LaserSettings({
      this.mode = LaserMode.trail,
      this.colorIndex = 0,
      this.durationMs = 750,
      this.width = 6.0,
    });

    final LaserMode mode;
    final int colorIndex;
    final int durationMs;
    final double width;
  }
  ```
- Create `LaserConfig` with pre-validated limits:
  - Default duration: `750ms` (range: `300ms` – `2000ms`).
  - Default width: `6.0` canvas pixels (range: `3.0` – `16.0`).
  - Accessible high-contrast color choices:
    - Ruby Red: `#FF1744` (glow: `#FF8A80`)
    - Emerald Green: `#00E676` (glow: `#B9F6CA`)
    - Electric Cyan: `#00E5FF` (glow: `#84FFFF`)
    - Amber Sun: `#FFD600` (glow: `#FFFF8D`)
  - Ensure high contrast: each laser color has a luminous core and an outer ambient blur/glow ring that guarantees immediate visibility on pitch-black paper, off-white paper, and colorful imported images/PDFs.

### 3. Laser options popover

- Pressing the Laser button when already selected opens the `LaserOptions` popover.
- UI elements:
  - **Mode toggle:** Segmented switch between "Trail" and "Dot".
  - **Color row:** 4 round color chips with high-contrast active ring indicator.
  - **Trail duration slider:** (disabled in Dot mode) with text labels "Short", "Normal", "Long" and live millisecond readout.
- Dismissal: touching anywhere outside the popover closes it without creating any laser marks.

### 4. Input handling & laser trail geometry

- **Pointer routing in `InkCanvas`:**
  - When `tool.value == EditorTool.laser`, raw pointer events (`onPointerDown`, `onPointerMove`, `onPointerUp`, `onPointerCancel`) are routed exclusively to `LaserController`.
  - Stylus pressure can subtly modulate laser core width (from 0.8x to 1.3x), but position tracking never blocks or waits for stroke smoothing. Raw 120Hz/240Hz samples are ingested directly for zero perceived latency.
- **Trail data structure:**
  - Maintain a bounded ring-buffer of timestamped laser points:
    ```dart
    class LaserPoint {
      LaserPoint({required this.position, required this.timestamp, required this.width});
      final Offset position;
      final DateTime timestamp;
      final double width;
    }
    ```
- **Decay & garbage collection:**
  - Points older than `LaserSettings.durationMs` are pruned during the animation tick.
  - When pointer is released, the remaining tail continues to decay until all points expire, at which point the animation ticker stops immediately.

### 5. High-performance rendering pipeline

- **Layer isolation:**
  - Render the laser in a dedicated `CustomPaint` widget placed inside its own `RepaintBoundary` strictly above the completed ink, active stroke, and image layers.
  - Moving the laser pointer must **never** repaint or dirty the completed stroke layer or PDF cache.
- **Visual rendering:**
  - **Laser Head (Dot):** A bright white-hot center circle surrounded by a radial glow in the chosen laser hue.
  - **Laser Tail:** A smooth Catmull-Rom or quadratic spline connecting points, painted in two passes:
    1. *Outer pass:* Wide, semi-transparent blurred stroke for the ambient glow.
    2. *Inner pass:* Narrow, high-intensity core stroke tapering down to zero width at the oldest point.
- **Ticker lifecycle:**
  - Use a `SingleTickerProviderMixin` or `Ticker` that only runs when `points.isNotEmpty`.
  - When the screen is idle, ticker is stopped (`0%` CPU/GPU usage).

---

## Automated tests

1. **Toolbar Extension Tests:**
   - Palette button count, default compact size, and layout in both horizontal and vertical modes.
   - Tapping right arrow extends the palette; tapping left arrow collapses it.
   - Laser and Ruler buttons are only accessible/visible when extended.
   - Semantics and accessibility announcements on expand/collapse.
2. **Laser State & Options Tests:**
   - Default settings (Trail mode, Ruby Red, 750ms duration).
   - Popover opens on re-selecting Laser, updates settings, and preserves values across tool switches.
3. **Canvas Input & Decay Tests:**
   - Pointer down, move, and up correctly record `LaserPoint`s with timestamps.
   - Document ink collection remains completely untouched during and after laser gestures.
   - Points decay and prune after duration elapsed; ticker stops when empty.
   - Golden tests verifying laser visibility and high contrast on both pure white and dark backgrounds.
