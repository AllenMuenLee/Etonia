# Implementation Prompt 22: Interactive Ruler and Straightedge Guide

You are working in the **Greatnote** (`Etonia`) Flutter tablet repository. Add an **interactive virtual ruler and straightedge guide** to the note canvas, accessible from the extended secondary section of the floating tool palette.

The app already features a 120Hz ink canvas, pen/pencil/highlighter styles, smoothing with One Euro filter, area/stroke erasing, lasso transforms, and sticky notes. Preserve all existing stylus latency and vector fidelity standards.

---

## Product outcome

1. **Toolbar Placement via Right Arrow Extension:**
   - The Ruler tool is housed in the extended section of the floating `ToolPalette`, revealed by tapping the right arrow expand button (`CupertinoIcons.chevron_right`).
   - Tapping the Ruler button toggles the on-screen ruler guide on or off. The ruler remains visible across active drawing tools (Pen, Pencil, Highlighter, Eraser) so the user can freely switch writing instruments while keeping their straightedge in position.
2. **Interactive On-Canvas Ruler:**
   - Renders a semi-transparent, frosted-glass acrylic straightedge with clear metric tick marks (centimeters and millimeters), measurement numbers, an origin zero-mark, and an angular readout.
   - **Multi-touch manipulation:** Users can drag the ruler with one finger/mouse to translate it across the canvas, and use a two-finger pinch-rotate gesture (or a dedicated rotation wheel/dial) to rotate it smoothly through 360 degrees.
   - **Magnetic angular snapping:** Provides subtle haptic feedback and snap detents at key angles: `0°`, `30°`, `45°`, `60°`, `90°`, `180°`, and orthogonal equivalents.
3. **Collinear Stroke Snapping & Guided Drawing:**
   - When drawing with any writing tool (Pen, Pencil, Highlighter, or Eraser) near either long edge of the ruler (within a configurable snap threshold, e.g. 20 logical canvas pixels), input coordinates snap smoothly to the straight edge.
   - Drawing along the ruler produces a crisp, perfectly straight vector stroke.
   - A live numeric distance badge (e.g. `4.8 cm`) follows the stylus tip along the ruler edge during the stroke.

---

## Scope

### What to build
- Ruler button in the extended `ToolPalette` (unfolded by the right arrow button).
- Ruler model and controller (`RulerController`, `RulerState`) managing position (offset in page coordinates), rotation (radians), length, scale, visibility, and unit system (cm/mm or inches).
- Touch and gesture interaction layer on the canvas allowing translation, rotation, and fine angular adjustment without fighting page zoom/pan.
- Mathematical projection engine in `RulerGeometry` to test stroke proximity and project raw pointer samples onto the ruler's collinear edge vector.
- Integrated snap pipeline in `InkCanvas` and `ActiveStroke`: points within the snap threshold are projected onto the straight line segment, with smooth entry and exit transitions.
- High-contrast visual rendering of the ruler body, tick marks, number labels, angle badge, and active edge highlight.
- Ruler persistence per-page during the editor session (surviving device rotation and orientation changes).

### What to exclude
- The ruler visual guide is not rendered into exported PDFs or thumbnail images.
- The ruler does not alter non-guided freehand strokes drawn away from its edge.
- Do not add curved rulers, French curves, or compasses in this pass.

---

## Architecture and existing code to build on

Inspect and integrate with:
- `lib/features/editor/widgets/tool_palette.dart`:
  - Extended tool button for Ruler with active toggled state.
- `lib/features/editor/ink/ink_canvas.dart`:
  - Intercepting pointer events: distinguishing between a touch interacting with the ruler body (moving/rotating) and a stylus/pen drawing along the ruler edge.
- `lib/features/editor/ink/stroke.dart`:
  - `ActiveStroke.addSample`: integrating projected collinear points into the active stroke without distorting pressure dynamics or end tapers.
- `lib/features/editor/ink/ink_controller.dart`:
  - Coordinating with `RulerController`.
- `lib/app/theme/app_icons.dart`:
  - Add `CupertinoIcons.pencil_ruler` or custom ruler glyph for `AppIcons.ruler`.
- `lib/app/theme/app_tokens.dart`:
  - High-contrast tick marks and label colors for light and dark paper backgrounds.

---

## Detailed design specifications

### 1. Palette UI and extended bar integration

- In the secondary tool section of `ToolPalette` (revealed when the right arrow is expanded), add a `PaletteButton` for the Ruler.
- Tapping the Ruler button toggles `rulerController.isVisible`:
  - When visible, the button displays a toggled/selected background state.
  - Tapping again hides the ruler from the canvas and turns off the button highlight.
  - The currently selected drawing tool (e.g. Pen or Highlighter) remains selected; toggling the ruler does not deselect the pen.
- Assistive technology announces: "Ruler shown" / "Ruler hidden".

### 2. Ruler state & configuration

- Define `RulerState`:
  ```dart
  @immutable
  class RulerState {
    const RulerState({
      required this.center,
      required this.rotationRadians,
      this.length = 320.0,
      this.thickness = 64.0,
      this.unit = RulerUnit.centimeters,
      this.isVisible = false,
      this.isLocked = false,
    });

    final Offset center;
    final double rotationRadians; // normalized to [-pi, pi]
    final double length;
    final double thickness;
    final RulerUnit unit;
    final bool isVisible;
    final bool isLocked;

    double get degrees => (rotationRadians * 180 / math.pi) % 360;
  }
  ```
- Define `RulerConfig`:
  - Default length: `360` logical page pixels.
  - Default thickness: `64` logical page pixels.
  - Snap capture threshold: `22` logical canvas pixels from the top or bottom edge.
  - Snap angular detents: `0°`, `30°`, `45°`, `60°`, `90°`, `120°`, `135°`, `150°`, `180°` (snap radius: `1.8°`).
  - Metric scale: 1 cm = 37.8 logical pixels (approx. 96 dpi standard), with millimeter subdivs.

### 3. Gesture handling & manipulation

- **Coordinate transformations:**
  - The ruler's position and rotation are maintained in page coordinates so the ruler remains glued to the correct page location when the user zooms or pans the page.
- **Ruler hit testing:**
  - Transform pointer events into the ruler's local coordinate frame:
    $$\begin{pmatrix} x' \\ y' \end{pmatrix} = R(-\theta) \cdot (\mathbf{p} - \mathbf{c})$$
  - If a touch lands inside the ruler's body (`|x'| \le length/2` and `|y'| \le thickness/2`):
    - Single-finger drag: translates the ruler center $\mathbf{c}$.
    - Two-finger gesture: computes the delta angle between the two touches to rotate $\theta$, and delta centroid to translate.
  - Rotation dial / handle: Include an intuitive center angle indicator (circular dial) that allows single-finger rotational dragging when two fingers are unavailable.
- **Magnetic snap:**
  - When the rotation angle is within `1.8°` of a cardinal/standard angle, snap to the exact detent angle and trigger a subtle haptic click via `AppHaptics.selectionClick()`.

### 4. Edge snapping & guided drawing pipeline

- **Collinear projection:**
  - Let the ruler's active edge line be parameterized by point $\mathbf{e}_0$ and unit direction $\mathbf{u}$.
  - When a drawing stroke is active (stylus or pen touch):
    1. Check perpendicular distance $d$ from the sample $\mathbf{p}$ to the ruler's top and bottom edges.
    2. If $d \le \text{snapThreshold}$ and the sample lies within the edge longitudinal bounds plus a small end-cap tolerance (`12 px`):
       - Project $\mathbf{p}$ orthogonally onto the edge:
         $$\mathbf{p}_{\text{snapped}} = \mathbf{e}_0 + ((\mathbf{p} - \mathbf{e}_0) \cdot \mathbf{u}) \mathbf{u}$$
       - Feed $\mathbf{p}_{\text{snapped}}$ into `ActiveStroke`.
    3. If the pointer moves decisively beyond the snap threshold ($d > 1.5 \times \text{snapThreshold}$), smoothly release the snap so the user can draw away freely without abrupt jumps.
- **Live distance readout:**
  - While drawing a snapped stroke along the ruler edge, display an ephemeral floating badge showing the measured distance drawn (e.g. `5.2 cm`) in real time next to the stylus tip.
- **Eraser compatibility:**
  - Erasing along the ruler edge allows erasing along a perfectly straight line, making technical diagramming and clean drafting effortless.

### 5. High-contrast visual rendering

- **Material & contrast:**
  - Semi-transparent glass body with subtle drop shadow and border highlight.
  - Contrast rule compliance:
    - On light paper: frosted bright background with deep charcoal ticks (`#212121`) and high-contrast numbers.
    - On dark paper: frosted tinted dark background with crisp white ticks (`#F5F5F5`) and bright numerals.
  - Edge guide glow: when a stylus tip enters the snapping zone of an edge, the corresponding edge illuminates with the accent theme color to signal magnetic engagement.
- **Angle badge:**
  - Centered circular protractor readout showing the exact angle in degrees (e.g. `45.0°`) with high-contrast text.

---

## Automated tests

1. **Toolbar Extension & Toggle Tests:**
   - Ruler button appears when tool palette is extended via the right arrow.
   - Tapping Ruler toggles visibility on and off without modifying active pen settings.
2. **Ruler Geometry & Transform Tests:**
   - Unit tests for local coordinate transformations, rotation, and distance calculations in `RulerGeometry`.
   - Angular detent snapping logic and magnetic snap threshold tests.
3. **Stroke Snapping Tests:**
   - Pointer events within 20px of ruler edge project strictly onto the line vector.
   - Verifying all points in `Stroke.points` are collinear ($R^2 = 1.0$) when drawn along the ruler.
   - Snapping releases when pointer moves beyond threshold.
4. **Rendering & Export Isolation:**
   - Ruler overlay renders in its own layer above ink without causing ink repaints.
   - Verifying `PdfExporter` and thumbnail generation do not render the ruler guide.
