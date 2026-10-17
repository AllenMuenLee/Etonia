# Implementation Prompt 3: Implement Basic Handwriting, Highlighter, and Direction-Aware Smoothing

You are adding the first real writing capability to **Greatnote**, a Flutter tablet application for Android and iPadOS. A modern responsive editor shell already exists. Preserve its design system, testing setup, and responsive behavior.

## Goal

Implement a low-latency writing canvas with one writing tool offering **Pen** and **Highlighter** styles, selectable color, adjustable stroke width, and a deterministic direction-aware smoothing algorithm. The feature must work with a stylus, finger, and mouse for development, while prioritizing stylus behavior on physical tablets.

## Scope

Implement only:

- one writing tool with Pen and Highlighter style choices;
- ink color selection;
- stroke-width adjustment;
- freehand stroke capture and rendering;
- the smoothing algorithm specified below;
- hold-to-shape: holding the pen still at the end of a stroke replaces it with a beautified geometric shape (specified below);
- in-memory stroke state for the current editor session.

Do not add an eraser, pencil variants, a separate highlighter toolbar tool, a separate shape tool or shape menu, selection/lasso, handwriting recognition, zoom, persistence, synchronization, or export. If an existing placeholder suggests any of those features, leave it disabled or remove it from the active UI. Hold-to-shape is part of the Pen style, not a new tool.

## Writing controls

- Keep the writing tool selected at all times. Represent it with one selected writing/pen button; do not add a second top-level highlighter button.
- Put a two-choice **Pen / Highlighter** style selector at the top of the writing subpanel. Open the subpanel by pressing the writing button while it is selected (pressing it again closes it). When another tool is selected, the first press selects the writing tool using its last style; the next opens the subpanel.
- Put the ink color and stroke width below the style selector in that same subpanel. There are no separate color or width buttons in the palette.
- The subpanel has a curated, accessible set of at least six colors plus a custom color input only if it can be implemented without a large dependency. Choosing a color keeps the subpanel open so the width can be changed too.
- Indicate the current color with both color and a non-color cue such as a checkmark and semantic label.
- Below the colors, provide stroke-width adjustment with a slider and a live line preview in the current ink.
- The writing button shows the current style and color with a small visual sample and announces the style, color, and width (for example "Highlighter, Yellow, 12 px").
- Use a practical configurable range, defaulting to 1-20 logical pixels and 3 logical pixels respectively. Store width in logical canvas units so it behaves consistently across device pixel ratios.
- Changing color or width affects the next stroke and must not mutate strokes already drawn.
- Preserve the selected color and width during orientation changes for the current app session.

### Highlighter style

- Highlighter is a writing style inside the existing writing tool, not an independent editor tool. Switching between Pen and Highlighter must not interrupt the active tool, create a second palette button, or change how the palette is docked.
- Remember color and width independently for Pen and Highlighter during the session. Pen keeps its existing defaults. Highlighter defaults to a translucent yellow and **12 logical pixels**, with a configurable width range of **4-40 logical pixels**.
- Store the writing style in `StrokeStyle` (or an equivalent immutable value captured at pointer-down), alongside color and width. Existing or legacy strokes with no style field are Pen strokes. Changing style, color, width, or opacity affects only later strokes.
- Render a highlighter with a fixed configurable opacity, default **0.35**, using ordinary source-over compositing. One mark remains translucent and overlapping marks become visibly darker. Apply opacity exactly once: active-stroke rendering, completed-stroke rendering, snapshots, thumbnails, selection previews, and later export code must agree. Do not pre-blend the color against the current paper, because the mark must remain correct over different paper colors and imported content.
- Use round caps and joins and the same low-latency point capture and stabilization pipeline as Pen. A highlighter tap produces a translucent round dot.
- Highlighter width is even along the stroke: it does not taper or react to pressure. **Draw and hold for shapes** is unavailable for Highlighter, and holding a highlighter stroke never converts it. Keep the advanced controls visible only for Pen, or show them disabled with a concise explanation and correct disabled semantics.
- The color UI must preview the effective translucent result over both light and dark sample backgrounds. Keep a curated set of useful highlighter colors; the selected swatch still needs a checkmark and semantic label rather than relying on color alone.
- Preserve document order. Highlighter strokes do not jump behind existing pen strokes after completion; later marks paint later. Erasing and later selection features must treat a highlighter stroke as one normal stroke whose style happens to be translucent.
- Keep compositing deterministic and isolated to each page. Do not use a `saveLayer` covering the entire writing surface on every frame; if a layer is required for a specific blend operation, bound it to the dirty stroke region and justify it with profiling.

### Basic and advanced Pen settings

- The subpanel shows the basic settings, ink color and width, at all times. Below them, behind a divider, an **Advanced** row with a chevron folds out the advanced settings; it starts folded each time the panel opens, and exposes its expanded state to screen readers.
- The advanced settings are:
  - **Tip sharpness** (slider, 0-100%): how sharply both ends of a stroke taper. 0 draws round, full-width ends.
  - **Pressure sensitivity** (switch, with a sensitivity slider that is disabled while the switch is off): how much stylus pressure changes the width.
  - **Stroke stabilization** (switch, with a strength slider that is disabled while the switch is off): how strongly the line is smoothed.
  - **Draw and hold for shapes** (switch): whether hold-to-shape (below) is armed.
- Every advanced setting is **on** by default, at a middle strength (50%). The pen's settings, basic and advanced, carry from note to note for the session.
- Like color and width, these are captured at pointer-down and affect only later Pen strokes.

### Stroke width along a stroke

- A stroke may vary in width. Store this as an optional width factor per filtered point, a multiple of the stroke's width; a stroke without factors is drawn at an even width exactly as before. Render a varying stroke as one filled outline (a disc at each end and at each sharp turn, joined by a quadrilateral per segment, all wound the same way so the union fills under the nonzero rule), built once per finished stroke.
- **Taper**: over a length that grows with sharpness (from one to eight stroke widths), the start of a stroke narrows toward a tip of `1 - 0.85 × sharpness` of the width, with an ease-out curve. While drawing, only the start is tapered; when the stroke finishes, both ends are, each over at most 40% of the stroke so short strokes still reach full width.
- **Pressure**: read pressure only from a stylus (or its eraser end) whose reported pressure range is not empty, normalized to 0-1; fingers, mice, and styluses without a pressure sensor report none. Smooth the reading (exponential, 0.3 of each new reading) so a noisy sensor does not ripple the edge. The width factor is `1 + sensitivity × 0.75 × (2p - 1)`: neutral pressure (0.5), and a device that reports none, leaves the width as set.
- A stroke's bounds use its widest factor (never less than 1), so hit-testing and repaint regions stay conservative.
- Stabilization maps onto the smoother below: at the default (50%) the smoother uses exactly its configured tuning; stronger stabilization lowers the minimum cutoff (smoother, more lag), weaker raises it, and turning stabilization off raises it far enough that the pen is followed without visible smoothing.

## Input capture

- Capture raw pointer samples with Flutter pointer events rather than gesture callbacks that discard low-level sample detail.
- Accept stylus, inverted stylus, touch, and mouse input, but process only one active writing pointer at a time for this first version.
- Ignore additional pointers while a stroke is active so that a palm or second finger does not corrupt the stroke. Document that full platform palm rejection remains future work.
- Convert all samples into writing-surface-local logical coordinates before smoothing or storage.
- Each sample must contain position and a monotonic timestamp, and pressure when the device reports it (see the pen's advanced settings). Preserve device kind for diagnostics.
- Start a stroke on pointer down, append samples on pointer move, and finalize it on pointer up or cancel. A tap must render a round dot.
- Clip ink to the writing surface.
- Prefer any coalesced/historical pointer samples exposed by the supported Flutter/platform APIs. The implementation must still work when only the latest event is available.

## Stroke data model

Create immutable or append-only models that clearly separate:

- raw input samples;
- smoothed samples or render points;
- stroke style captured at pointer-down time;
- completed strokes and the active stroke.

Keep the smoothing engine as a pure Dart component with no widget or renderer dependency. Keep canvas state scoped so pointer updates repaint the canvas without rebuilding the full editor shell.

## Direction-aware smoothing algorithm

Implement the following algorithm explicitly; do not substitute a generic Bézier package or an opaque smoothing library.

### Definitions

For an incoming raw sample `p[i]` at time `t[i]`:

1. Clamp `dt = t[i] - t[i-1]` to a configurable safe interval before division, so duplicate timestamps and long event gaps cannot produce invalid velocity.
2. Compute raw velocity `v[i] = (p[i] - p[i-1]) / dt` and speed `|v[i]|`.
3. Maintain a short rolling window of recent velocity samples. The initial default window is 6 samples and must be configurable.
4. Define the dominant direction `d` as the normalized direction of the fastest non-zero velocity in that window. To prevent direction sign flips, orient it so its dot product with the previous dominant direction is non-negative. If every velocity is effectively zero, reuse the last valid direction; if none exists, use the direction from the stroke start to the newest distinct point.
5. Define the perpendicular unit vector `n = (-d.y, d.x)`.

### Decomposition and filtering

Treat motion along `d` as intentional fast motion and preserve it with minimal filtering. Smooth the perpendicular component with an acceleration-limited follower:

1. Project the raw displacement from the previous output point onto the two axes:
   - `parallel = dot(p[i] - output[i-1], d)`;
   - `perpendicularTarget = dot(p[i] - output[i-1], n)`.
2. Advance the parallel component directly: `parallelStep = parallel * d`.
3. Maintain scalar perpendicular velocity `uPerp`, expressed in logical pixels per second.
4. Compute the perpendicular error after accounting for current perpendicular velocity. Accelerate `uPerp` toward that error with constant-magnitude acceleration, capped at `aPerp`:

   ```text
   desiredPerpVelocity = perpendicularTarget / dt
   velocityError = desiredPerpVelocity - uPerp
   maxVelocityChange = aPerp * dt
   uPerp += clamp(velocityError, -maxVelocityChange, +maxVelocityChange)
   perpendicularStep = uPerp * dt
   ```

5. Prevent overshoot by clamping `perpendicularStep` to the signed magnitude of `perpendicularTarget`.
6. Produce `output[i] = output[i-1] + parallelStep + perpendicularStep * n`.
7. When the dominant basis rotates, project the existing perpendicular-velocity vector onto the new `n` before continuing. Do not carry a scalar value across a basis change without reprojection.

Use a default `aPerp` of **3 logical px/s²**. The original product requirement described this as `3 px/s`, but acceleration has units of distance per time squared; therefore the implementation and configuration must use `px/s²`. Keep this value in a named configuration object, not as a magic number. Also expose the rolling-window size and `dt` clamp values in that object for later tuning.

### Stroke completion and rendering

- Keep the rendered stroke responsive during pointer movement; do not wait until pointer-up to show ink.
- Render the filtered polyline with anti-aliasing, round caps, and round joins.
- Use a lightweight curve interpolation between filtered points only if it remains deterministic and does not replace the specified filter. If used, document it and test it independently.
- On pointer-up, process the final sample and ensure the visible endpoint reaches the intended raw endpoint. If endpoint convergence conflicts with the acceleration constraint, add a short deterministic tail/finalization step rather than snapping during active drawing.
- Do not run an unbounded post-processing loop. Set a small documented maximum for any finalization points.
- Repaint only when the active stroke or completed stroke collection changes.

## Hold to convert to shape

After drawing a stroke, the user can keep the pen on the page and hold it still. This is the pen's **Draw and hold for shapes** setting, on by default; with it off, holding still does nothing and the stroke stays freehand. After a short hold the stroke is replaced, in place, by a clean version of the shape it was meant to be. Lifting the pen without holding keeps the freehand stroke exactly as before.

### Trigger

- Only a pen stroke can be converted. Erasing, selecting, or any other gesture never triggers it.
- Arm the hold only once the active stroke is long enough to be a shape (default path length 24 logical px), so a tap or a short pause at the start of a stroke never converts anything.
- The hold starts at the last position where the pointer moved more than a slop distance (default 6 logical px) and fires after a hold duration (default 550 ms) without leaving that slop. Small jitter inside the slop does not restart the timer; leaving it does.
- When the hold fires, recognize the active stroke's filtered points. If a shape is recognized, the freehand ink is replaced on screen by the shape at once and the pointer starts adjusting it (below). If nothing is recognized, nothing happens and the user may continue the stroke.
- Pointer-up, pointer-cancel, a metrics change, a tool change, and disposal cancel a pending hold. No timer may outlive its stroke.
- Keep every trigger value in a named configuration object (`ShapeConfig`), not as magic numbers.

### Recognizer

Implement the recognizer as a pure Dart component with no widget or rendering dependency, in the same spirit as the smoother. It takes a polyline and returns either nothing or a recognized shape: its kind and the points of the beautified polyline. Recognize as many shapes as practical, at least:

- **Line**: a nearly straight stroke. Snap to horizontal or vertical within a few degrees.
- **Arrow**: a straight shaft followed, at its end, by a short arrowhead drawn in the same stroke (the pen goes back along one or both barbs). Produce a straight shaft and two symmetric barbs at a fixed angle, sized from the drawn head.
- **Circle** and **ellipse**: closed, smooth strokes. Fit the center, the radii, and the rotation; a nearly round fit becomes a circle; snap the ellipse axis to horizontal or vertical within a few degrees.
- **Polygons (多角形)**: closed strokes with corners. Detect corners, straighten every edge, and support at least triangles, quadrilaterals, pentagons, hexagons, and larger n-gons up to a configured limit. Beautify in order of specificity:
  - a quadrilateral with right angles becomes a rectangle, and a rectangle with nearly equal sides a square, aligned to the axes when nearly aligned;
  - a quadrilateral with nearly equal sides that is not a rectangle becomes a rhombus (diamond);
  - any n-gon with nearly equal sides and angles becomes a regular n-gon fitted to the drawn one (center, circumradius, rotation), with an upright orientation when nearly upright;
  - a closed zig-zag that alternates between two radii around its center becomes a regular star;
  - any other polygon, including concave ones, keeps its detected corners with straight edges.
- **Open polyline**: an open stroke made of a few straight segments (a zig-zag, a check mark, an angle) keeps its corners and straightens its segments.
- **Arc**: an open stroke that follows part of a circle.
- **Sine wave**: an open, smooth stroke that oscillates about a straight axis for at least about one period. Fit the axis, amplitude, wavelength, and phase, and generate an evenly sampled sine over the drawn extent.
- **Spiral**: an open stroke that winds at least about one and a quarter turns around a center while its radius grows or shrinks steadily. Fit an Archimedean spiral (`r = a + b·θ`) over the drawn angle range.

Requirements for the recognizer:

- Resample the input to an evenly spaced, bounded number of points before analysis, so results do not depend on input sample density or speed.
- Each candidate shape reports a normalized fit error (relative to the stroke's size). Accept a candidate only within its documented tolerance, and when several are acceptable, prefer the most specific one with the best fit. A wobbly scribble, handwriting, or a shape that does not match any kind well returns nothing.
- Output points are generated geometry, not the input points. Closed shapes end where they start. Output size is bounded (a configured maximum of points per shape).
- Keep all tolerances and limits in `ShapeConfig`.
- Every output must be finite for degenerate input (a dot, repeated points, collinear points, two-point strokes), and identical input must give identical output.

### Adjusting the shape before lifting

After the snap, the pen stays down and controls the shape until it lifts:

- Moving the pen scales and rotates the shape about a pivot so that the point where the pen held follows the pen. The pivot is a closed shape's center and an open shape's start, so a line or arrow pivots on its tail while its end follows the pen, and a circle or polygon grows, shrinks, and turns about its center.
- The transform is a similarity (uniform scale and rotation, no skew), always computed from where the adjustment began, never accumulated move by move.
- Small wobble right after the snap must not undo it: rotations under a few degrees and scales within a few percent of 1 are ignored, so a shape snapped axis-aligned stays aligned unless deliberately turned. Clamp the scale to a sensible range, and ignore moves too close to the pivot to define a direction.
- The stroke width does not change when the shape is scaled.
- While adjusting, the shape is a preview painted in the active-stroke layer; the document is unchanged and the controller reports a gesture in progress, so autosave, page switching, and other pointers wait.
- Pointer-up commits the adjusted shape as one change. Pointer-cancel, a metrics change, or a tool change commits it as last shown. A two-finger scroll that starts during the adjustment discards it.

### Model and rendering

- The shape is committed as one ordinary stroke with the original stroke's style, built from the shape's points (never passed through the smoother again). Because it is not raw input, it carries no raw samples; mark it as derived the same way any later code builds strokes from points.
- Converting is one change to the stroke collection, made when the adjustment ends: the freehand stroke never appears in the completed strokes, only the final shape does. Notify listeners once.
- Announce the recognized shape to assistive technology (for example "Circle") when it is converted.
- Drawing feedback stays immediate: the freehand ink stays visible during the hold and is replaced in one frame.

## Robustness requirements

- Handle zero-length moves, duplicate timestamps, very large event gaps, very short strokes, taps, abrupt direction changes, cancellation, points outside the canvas, and orientation changes without exceptions, NaN, or infinity.
- Scale positions and widths using logical coordinates; results must not depend on device pixel ratio.
- Bound rolling buffers and any cached geometry.
- Do not perform allocation-heavy whole-stroke recomputation for every pointer event.
- Dispose of controllers and listeners.
- If a rotation occurs during an active stroke, cancel/finalize that stroke deterministically before applying the new layout.

## Automated tests

Add deterministic tests with synthetic positions and timestamps.

### Smoothing unit tests

- a horizontal constant-speed line stays horizontal and its endpoint is correct;
- vertical and diagonal lines remain stable;
- the fastest velocity in the configured rolling window determines `d`;
- direction sign does not flip between equivalent opposite vector representations;
- perpendicular jitter is reduced relative to raw input;
- each update changes perpendicular velocity by no more than `aPerp * dt`, within floating-point tolerance;
- a change in dominant direction correctly reprojects perpendicular velocity;
- duplicate timestamps and long gaps respect the `dt` clamps;
- taps, repeated points, abrupt 90-degree turns, and cancellation yield finite coordinates;
- two runs over identical samples produce identical output;
- finalization reaches the intended endpoint within a documented tolerance and point limit.

### Shape recognizer unit tests

- synthetic, slightly noisy versions of every supported kind are recognized as that kind: line, arrow, circle, ellipse, triangle, rectangle, square, rhombus, regular pentagon and hexagon, star, irregular polygon, open polyline, arc, sine wave, and spiral;
- beautified output is clean: a recognized line or rectangle is axis-aligned when drawn nearly axis-aligned, a circle's points are all at the fitted radius, a polygon's edges are straight, and closed shapes end at their start;
- scribbles, handwriting-like strokes, and dots are not recognized;
- results do not depend on sample density;
- degenerate input yields no shape or a finite one, and repeated runs are identical.

### Widget and interaction tests

- draw with simulated pointer events and verify that a visible stroke is produced;
- verify one active pointer and ignored secondary-pointer behavior;
- verify clipping to the writing surface;
- verify color and width changes affect only later strokes;
- verify the writing subpanel opens from the selected writing button in tablet and compact layouts, exposes Pen and Highlighter styles plus the applicable colors and width slider, and has no separate highlighter, color, or width palette buttons;
- verify Pen and Highlighter remember independent color and width values, survive a layout/orientation rebuild, and capture their full style at pointer-down so existing strokes never change;
- verify one highlighter mark uses the configured opacity exactly once, overlapping marks darken in document order, and active and completed strokes render equivalently over light, dark, and imported backgrounds;
- verify a highlighter tap is a translucent round dot, its width stays even regardless of pressure, and holding it never invokes shape conversion;
- verify Highlighter hides or correctly disables Pen-only advanced settings and exposes useful labels, disabled semantics, and previews over light and dark samples;
- verify the advanced settings start folded, unfold from the Advanced row, are all on by default, and that each one reaches the pen (a disabled switch also disables its slider);
- verify tapering narrows both ends and leaves the middle at full width, that sharper tips narrow further, that harder pressure draws wider and lighter narrower, that a device without pressure leaves the width as set, and that turning Draw and hold off keeps a held stroke freehand;
- verify default stabilization gives the smoother its configured tuning unchanged;
- verify a tap produces a dot;
- verify cancelling a pointer leaves valid state;
- verify there is exactly one top-level writing tool, with Pen and Highlighter only, and no unsupported writing styles;
- drawing a rough circle and holding still converts it into a circle with the same style, shown as a preview until the pen lifts and committed then;
- after the snap, moving the pen away from a circle's center scales it, and swinging a snapped line's end turns and stretches it about its start; small wobble changes nothing; cancel keeps the shape;
- lifting without holding, holding at the start of a stroke, and holding a scribble all leave the freehand stroke unchanged;
- jitter inside the hold slop still converts, and moving out of the slop restarts the hold.

### Performance validation

- Add a benchmark or profiling harness that feeds a long synthetic stroke at a representative high sample rate.
- Profile on at least one physical Android tablet and one physical iPad when hardware is available.
- Target smooth interactive rendering at the display refresh rate, with no obvious input backlog and no full editor rebuild per sample.
- Report frame timing and memory observations; do not invent physical-device results if only an emulator is available.

## Acceptance criteria

- The user can draw immediately with a stylus or finger and see ink during the stroke.
- The UI offers one top-level writing tool with Pen and Highlighter style selection, accessible color selection, and width adjustment.
- Highlighter defaults to translucent yellow at 12 logical pixels and 0.35 opacity, uses the same responsive capture/smoothing path as Pen, and never applies taper, pressure width, or hold-to-shape.
- Pen and Highlighter settings are remembered independently, and every stroke retains the style, color, width, and opacity behavior captured when it began.
- Straight fast strokes retain their intended direction while perpendicular jitter is visibly reduced.
- The implementation uses the specified fastest-velocity direction and acceleration-limited perpendicular filter with default `aPerp = 3 logical px/s²`.
- Existing strokes retain the color and width with which they were created.
- Holding the pen still at the end of a stroke turns a recognizable line, arrow, circle, ellipse, polygon, star, polyline, arc, sine wave, or spiral into its clean version, and leaves anything else untouched. Before lifting, the user can move the pen to scale and rotate the shape.
- No raw input sequence in the test suite produces NaN, infinity, a crash, or unbounded work.
- Formatting, static analysis, unit tests, widget tests, and existing golden tests pass.

## Completion report

At the end, describe the data flow from pointer input to painting, explain how writing style and opacity are captured and applied exactly once, list the independent Pen and Highlighter defaults, list every smoothing and shape configuration value and its default, list the recognized shape kinds and how each is beautified, report automated and physical-device verification separately, and call out any platform limitation such as unavailable coalesced events or incomplete palm rejection. Include a short tuning note explaining that `aPerp = 3 logical px/s²` is intentionally configurable and may feel extremely restrictive at tablet scale.
