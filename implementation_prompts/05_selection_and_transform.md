# Implementation Prompt 5: Select, Transform, Copy, and Cut Ink

You are adding ink selection and transformation to **Greatnote**, a Flutter
tablet application for Android and iPadOS. The editor already has a responsive
shell, a floating palette, a low-latency pen, and vector-based area and stroke
erasers. Preserve the design system, testing setup, responsive behavior,
stroke smoothing, and eraser behavior.

## Goal

Add one **Select** tool that lets the user draw a freeform region around ink,
then operate on every selected stroke as a group. The user must be able to:

- move the selection;
- scale it uniformly;
- rotate it;
- copy it to an in-app vector clipboard;
- cut it to that clipboard; and
- paste copied or cut ink back onto the page.

All operations remain vector-based. Never flatten selected ink into a bitmap,
and never resample transformed points through the handwriting smoother.

## Scope

Implement only:

- a Select tool beside the pen and eraser;
- freeform lasso-region capture;
- deterministic stroke/region intersection;
- a visible selection frame and transform handles;
- direct manipulation for move, uniform scale, and rotation;
- Copy, Cut, and Paste using an in-memory vector clipboard for the current
  editor session;
- standard keyboard shortcuts for Copy, Cut, and Paste when the editor has
  focus;
- in-memory selection and transform state.

Do not add non-uniform scaling, skewing, mirroring, point editing, partial
stroke selection, handwriting recognition, text or image selection, multiple
pages, persistence, synchronization, export, or system-wide clipboard
interchange. Do not add undo/redo in this task. Cut is intentionally
destructive until history is implemented, so keep every committed transform,
cut, and paste representable as one controller-level mutation for a future
history layer.

Paste is included only to make Copy and Cut complete. Clipboard contents use
Greatnote's stroke model and are not exposed to other applications.

## Existing code to build on

Read these before designing anything; selection must extend the existing ink
pipeline rather than create a parallel document model:

- `lib/features/editor/ink/stroke.dart`: immutable `Stroke`, cached `Path` and
  rendered bounds, `Stroke.fromPoints`, and the distinction between input and
  derived geometry.
- `lib/features/editor/ink/ink_controller.dart`: stroke ownership, separate
  repaint notifiers, single-active-pointer behavior, and controller-level
  mutations used by the eraser.
- `lib/features/editor/ink/ink_canvas.dart`: raw pointer routing, local logical
  coordinates, inverted-stylus behavior, input blocking, clipping, and gesture
  finalization on metrics or tool changes.
- `lib/features/editor/ink/ink_painter.dart`: completed, active, and eraser
  layers behind independent repaint boundaries.
- `lib/features/editor/ink/eraser_settings.dart`: the current `EditorTool`
  enum and immutable settings/config conventions.
- `lib/features/editor/widgets/tool_palette.dart`: fixed palette button count,
  popover ownership, and selected-state behavior.
- `lib/features/editor/editor_screen.dart`: session state and responsive page
  layout.

Some existing tests explicitly assert that Lasso or Select is unsupported and
that the palette contains four buttons. Update those assertions to the new
product scope without deleting unrelated coverage.

## Selection tool and session state

- Extend `EditorTool` with `select`. Pen remains the default tool on launch.
- Add a Select palette button next to the eraser. Exactly one of Pen, Eraser,
  and Select is selected, using the existing `PaletteButton` treatment and
  semantics.
- Give the control the visible tooltip and semantic label `Select`; do not
  expose the internal geometry term as the only accessible name.
- Pressing Select when another tool is active selects it. Pressing an already
  selected Select button opens a small options popover containing Paste. Paste
  is disabled when the in-app clipboard is empty.
- Add any new menu controller to `ToolPaletteController.hasOpenPopover`, so a
  tap that dismisses the menu cannot start a lasso or transform.
- Update `ToolPalette.sizeFor` and the responsive editor layout for the extra
  button. The palette keeps floating over the full-screen page, inside it,
  and must not overflow at any existing reference viewport.
- The selection action bar and the Paste prompt float over the page too.
  Pass them the palette's rectangle in the page area's coordinates; when the
  position beside the frame would put a bar under the palette, move it the
  shortest way clear (past the palette's right, left, bottom, or top edge,
  by the bar's usual margin) that stays inside the page area, so every
  action can always be pressed.
- Selection and clipboard state belong to the same editor session as the ink.
  A breakpoint or orientation rebuild must not lose either. Clipboard contents
  survive tool changes. A selection may survive a metrics change if its page
  coordinates are still valid, but any operation in progress must be
  finalized first.
- When leaving the Select tool, commit any transform in progress and clear the
  visible selection. Changing tools must never reinterpret a pointer gesture
  halfway through.
- An inverted stylus continues to erase with the current eraser settings,
  regardless of the selected tool, and does not change the selected tool.

## Pointer-state model

Preserve the controller's one-active-pointer invariant across writing,
erasing, lassoing, moving, scaling, and rotating. A second pointer is ignored
until the active gesture finishes. Do not turn this task into pinch-to-scale
or two-finger rotation.

With Select active, pointer-down chooses exactly one operation using this
precedence:

1. the rotation handle, when a selection exists;
2. the nearest corner scale handle, when a selection exists;
3. the interior of the selection frame, which begins a move;
4. otherwise, a new lasso gesture, which replaces the old selection when it
   finishes.

The hit regions for handles may be larger than their painted circles. Resolve
overlap deterministically by nearest handle and then a fixed corner order.
Moving must also work when the pointer is over visible ink inside the frame.

Use raw pointer events and canvas-local logical coordinates, as the pen and
eraser do. Accept stylus, touch, and primary-button mouse input. Ignore
secondary mouse buttons and unsupported device kinds. Pointer-up commits the
operation. For pointer cancel:

- discard an unfinished lasso without changing the previous selection;
- commit the current move, scale, or rotation at its latest finite transform,
  matching the existing rule that cancellation keeps ink changes made so far.

All operation entry points must reject non-finite coordinates without changing
state. Pointer events outside the page may continue an operation that began
inside it; visuals remain clipped, while transformed vector points may lie
outside the page and be clipped by rendering.

## Freeform selection region

### Capture and display

- From pointer-down to pointer-up, collect a freeform polyline in page-local
  logical coordinates.
- Show the lasso while it is being drawn in a dedicated overlay layer above
  ink. Close it visually from its latest point to its first point without
  adding duplicate endpoints to the stored data.
- Bound work and memory by accepting a new lasso point only after it is a
  configurable minimum distance from the previous accepted point. Always keep
  the first point and the final finite point.
- A tap, fewer than three distinct points, or a region with effectively zero
  area selects nothing. It must not leave a dot or erase ink.
- Use an even-odd fill rule for a self-intersecting lasso. Document this choice
  and test it; do not let platform `Path.contains` behavior be the only
  specification of the result.

### What is selected

Selection is stroke-granular: a selected stroke is always moved, transformed,
copied, or cut in full. A stroke is selected when any part of its **rendered
ink** overlaps the closed lasso region.

Implement the test in a pure Dart geometry component. Account for stroke
width, round caps, and dots:

- a dot overlaps when its rendered disc overlaps the region interior or
  boundary;
- a polyline overlaps when a centerline segment enters the region, crosses a
  region edge, or comes within half the stroke width of an edge;
- a stroke fully inside the lasso is selected;
- a lasso fully inside the rendered area of a very wide stroke also counts as
  overlap;
- touching the boundary within a documented floating-point tolerance counts
  as overlap.

Use the lasso bounds and each stroke's cached rendered `bounds` as a broad
phase. Do not walk points of a stroke whose bounds cannot overlap the lasso
bounds. Return selected stroke indices in document order; do not change the
stroke collection or z-order merely by selecting it.

Do not use only `Stroke.points.any(Path.contains)`: that misses segments that
cross the region between vertices, wide strokes near a boundary, and lassos
drawn within a wide stroke.

## Selection representation

Keep a clear separation between:

- the immutable document strokes;
- the selected stroke indices and their gesture-start snapshots;
- the lasso currently being captured;
- the active transform preview; and
- the in-app clipboard snapshot.

Selection references must not depend on geometric equality. Indices are
acceptable while all mutations remain inside `InkController`, provided every
mutation updates or clears them atomically. Stable stroke IDs are also
acceptable, but do not add IDs unless they simplify the implementation enough
to justify the model change.

Expose read-only selection state from the controller. Do not let widgets
mutate the stroke list or selected indices directly. The controller API should
make lasso begin/update/end, transform begin/update/end, copy, cut, paste,
clear-selection, and finalization explicit.

## Selection frame and controls

- After selection, draw a frame around the union of the selected strokes'
  rendered bounds.
- The frame must retain its orientation during rotation instead of snapping to
  a new axis-aligned bounding box on every pointer move. Store or derive its
  center, local axes, and four corners. Preserve that orientation after commit
  and through later move or scale gestures while the same selection remains
  active.
- Draw one scale handle at each corner and one rotation handle centered above
  the top edge, connected by a short stem. Use a quiet dashed or solid accent
  outline consistent with the existing theme.
- Use theme tokens for colors, spacing, and motion. Add a feature-level config
  for geometry-specific dimensions instead of scattering literals.
- Visual handle radii may be small, but their interactive target must be at
  least 48 logical pixels where space permits. When targets overlap on a very
  small selection, nearest-handle precedence must still make the behavior
  deterministic.
- Keep the frame, lasso, handles, and transform preview in their own clipped
  repaint boundary. They are visual chrome and must not become part of the
  copied stroke data.
- Show a compact contextual action bar for a non-empty selection with Copy and
  Cut buttons. Use real Flutter buttons so they have keyboard focus, tooltips,
  pressed/focus states, and semantics. Position it above the frame when space
  allows, otherwise below it, and clamp it inside the page.
- Pointer events on the action bar must not also reach the canvas and start a
  move or lasso.
- Expose a semantic summary such as `3 strokes selected`. The transform frame
  itself may be excluded from semantics if it cannot offer a useful accessible
  action, but Copy, Cut, Paste, and the Select tool must be accessible.

## Transform mathematics

Put affine transform math in a pure Dart component. Do not depend on a
rendering-only matrix as the sole source of truth. Every pointer move must
derive a preview from the gesture-start snapshot and current pointer, not from
the result of the previous move; this prevents accumulated drift and makes
results independent of event frequency.

### Move

- Dragging inside the frame translates every selected point by the pointer
  delta from gesture start.
- Stroke widths and frame orientation are unchanged.

### Uniform scale

- Dragging a corner scales uniformly about the opposite corner, which remains
  fixed in page coordinates.
- Compute the scale from the distance between the pointer and fixed corner at
  gesture start versus the current distance. Do not allow zero, negative, or
  mirrored scale.
- Clamp the factor to configurable finite minimum and maximum values.
- Scale every selected point and every selected stroke width by the same
  factor. Pen configuration limits apply to newly drawn strokes, not to
  transformed existing ink; do not clamp transformed widths to `PenConfig`.
- Scale dots by moving their centers and scaling their width.

### Rotation

- Rotate around the selection frame's center.
- The angle is the finite difference between the start and current pointer
  angles around that center. Handle wraparound at `-pi`/`pi` without a jump.
- Rotate points and the frame; stroke widths are unchanged.
- Do not add angle snapping in this task.

### Preview and commit

- During move, scale, or rotation, render selected strokes through the preview
  transform in the selection layer. Do not rebuild a `Path` on every pointer
  sample.
- Avoid drawing the original selected strokes underneath the preview. The
  completed-strokes painter may skip selected indices while the selection
  layer owns them. Changing selection membership may repaint the completed
  layer once; moving a preview must not repaint it on every sample.
- On pointer-up or transform cancellation, apply the final transform once.
  Replace each selected stroke at its original index, preserving document and
  z-order. Build each replacement path once.
- A transformed stroke is derived geometry. Its points are the transformed
  filtered points, its style is retained except for width during scale, its
  `source` is `StrokeSource.derived`, and its `rawSamples` are empty. Raw input
  samples are not transformed or invented because they no longer describe the
  stored geometry.
- An identity transform is a no-op: keep the original stroke instances and do
  not notify the completed-strokes layer.
- After commit, keep the transformed strokes selected and update the frame to
  their committed geometry.
- Reject or clamp any transform that would produce NaN, infinity, a zero-width
  stroke, or unbounded coordinates.

## Copy, Cut, and Paste

The in-app clipboard stores an immutable deep snapshot of selected strokes in
document order, plus the copied selection bounds. It must not retain mutable
controller state or depend on the selected indices remaining valid.

- **Copy** first finalizes any transform preview, snapshots the selected
  strokes, leaves the document unchanged, and keeps the selection active.
- **Cut** performs the same snapshot and then removes all selected strokes in
  one controller mutation. Unselected strokes keep their relative order and
  identity. Clear the selection after the removal.
- **Paste** creates new derived strokes from the clipboard snapshot, appends
  them in clipboard order above existing ink, and selects the pasted strokes.
- Offset a paste by a configurable `(24, 24)` logical pixels from the copied
  geometry so it is visibly distinct. Repeated paste commands add another
  `(24, 24)` offset relative to the previous paste from that clipboard. Reset
  the paste cascade when Copy or Cut replaces the clipboard.
- Keep pasted ink in logical page coordinates. Do not silently clamp it to the
  page; rendering already clips outside geometry.
- Preserve color, relative positions, relative z-order, rotation, and stroke
  widths exactly.
- An empty selection makes Copy and Cut no-ops. An empty clipboard makes Paste
  a no-op and leaves its UI disabled.
- Support `Ctrl+C`, `Ctrl+X`, and `Ctrl+V`, plus the platform-equivalent Meta
  shortcuts on iPad keyboards. Shortcuts act only while the editor is the
  active focus scope and must not steal text-editing shortcuts from a focused
  editable control.
- Do not serialize private data into a string or claim interoperability with
  the operating-system clipboard.

## Controller and painting architecture

- Keep document mutations in `InkController` or a focused collaborator it
  owns. The canvas routes input; it does not edit stroke collections.
- Add a dedicated selection listenable for lasso updates, preview transforms,
  selection membership, and clipboard/action availability. Dispose it with the
  controller.
- Notify `completedStrokesListenable` only when committed document geometry or
  membership changes, or once when selection ownership requires that layer to
  stop/start painting selected strokes. Empty lasso moves and transform
  previews must not cause a full completed-ink repaint.
- Preserve the independent active-stroke and eraser indicator repaint paths.
- A pen stroke or erase gesture cannot begin while a selection gesture owns the
  pointer, and the reverse.
- Erasing after leaving Select operates on transformed/pasted strokes exactly
  like any other `Stroke.fromPoints` result.
- A future history feature must be able to observe one before/after document
  mutation for each committed transform, Cut, or Paste. Do not implement the
  history stack now.

## Selection configuration

Introduce an immutable `SelectionConfig` with documented logical-coordinate
defaults. Use at least:

| Value | Default | Meaning |
| --- | ---: | --- |
| `minLassoPointSpacing` | `2 px` | Minimum distance before accepting another lasso point |
| `geometryTolerance` | `0.001 px` | Inclusive tolerance for intersection and identity checks |
| `handleVisualRadius` | `6 px` | Painted radius of scale and rotation handles |
| `handleHitRadius` | `24 px` | Pointer hit radius, yielding a 48 px target |
| `rotationHandleOffset` | `32 px` | Distance from the top edge to the rotation handle |
| `minScale` | `0.1` | Smallest scale allowed in one gesture |
| `maxScale` | `10` | Largest scale allowed in one gesture |
| `pasteOffset` | `(24, 24) px` | Offset added by each paste in a cascade |

Validate config invariants in its constructor. All lengths are page-local
logical pixels and must behave identically across device pixel ratios. If the
implementation needs another tolerance, name it, document it, and test its
boundary instead of introducing a magic number.

## Robustness requirements

- Handle an empty page, an empty clipboard, dots, one-segment strokes, very
  wide strokes, coincident points, duplicate lasso samples, self-intersecting
  lassos, lassos that cross a stroke only between stored vertices, selections
  containing differently colored and sized strokes, selections partly outside
  the page, and a frame smaller than overlapping handle targets.
- Moving, scaling, or rotating the same selection through different pointer
  sample counts must produce the same final geometry within floating-point
  tolerance.
- Repeated rotations and identity operations must not inject duplicate points.
- No valid or degenerate input may produce NaN, infinity, a negative/zero
  width, an exception, or unbounded per-event work.
- Selection and transforms depend only on logical coordinates, not device
  pixel ratio.
- Selection changes do not alter pen color/width or eraser mode/size.
- Copy must not alias later document replacements. Pasting, moving, or erasing
  a copied result must not mutate the clipboard or the source strokes.
- Dispose all new notifiers, focus nodes, menu controllers, and overlays.

## Automated tests

Add deterministic tests using synthetic points and transforms.

### Selection geometry unit tests

- a stroke fully inside a simple lasso is selected;
- a stroke fully outside is not selected and is rejected by the bounds broad
  phase;
- a two-point stroke crossing the region is selected even when both endpoints
  are outside;
- a wide stroke just touching the region is selected, while one beyond half
  its width plus tolerance is not;
- dot strokes are selected or ignored according to their rendered discs;
- a lasso entirely inside a very wide rendered stroke selects it;
- touching an edge or vertex is inclusive and deterministic;
- self-intersecting lassos follow the documented even-odd rule;
- duplicate points, zero-area lassos, and non-finite inputs are handled without
  invalid output;
- selected indices are returned once, in original document order;
- two runs over identical data return identical results.

### Transform unit tests

- translation applies the same delta to every point and preserves width;
- rotation around the frame center produces exact expected points for 90 and
  180 degrees and crosses the angle wraparound without a jump;
- corner scaling leaves the opposite corner fixed, preserves relative
  positions, and scales widths and dots;
- scale clamps at the configured minimum and maximum without mirroring;
- transforms are computed from the gesture-start snapshot rather than
  accumulating intermediate results;
- an identity transform retains original stroke instances and emits no
  completed change;
- a committed transform replaces only selected indices and preserves neighbor
  order and identity;
- transformed strokes are derived, have no raw samples, and have valid cached
  paths and bounds;
- degenerate frames and invalid pointer coordinates produce finite,
  deterministic results.

### Controller and clipboard tests

- selection cannot start while writing or erasing, and those gestures cannot
  start during a selection operation;
- lasso cancel retains the previous selection, while transform cancel commits
  the latest preview;
- a metrics change finalizes an active transform without losing selection;
- Copy changes no document stroke and does not notify the completed-strokes
  layer; it snapshots the current geometry and updates clipboard/action state;
- Cut copies, removes exactly the selected strokes in one mutation, and keeps
  all unselected strokes in order;
- Paste appends independent derived strokes, selects them, and preserves style
  and relative z-order;
- repeated pastes use successive offsets, and a new Copy/Cut resets the
  cascade;
- later transformations and erases do not mutate clipboard contents;
- relevant listenables fire only for their documented state changes.

### Widget and interaction tests

- Select appears in tablet and compact palettes; exactly one of Pen, Eraser,
  and Select is selected;
- drawing a lasso selects every overlapping stroke and no non-overlapping
  stroke, without drawing ink;
- tapping empty paper clears the selection;
- dragging inside the frame moves all selected strokes together;
- each corner handle scales uniformly about its opposite corner;
- the rotation handle rotates the group around its center;
- selection visuals update during a transform while the completed ink layer is
  not repainted per pointer move;
- Copy and Cut buttons are reachable, labelled, and do not leak their pointer
  events to the canvas;
- pressing selected Select opens Paste, which is disabled for an empty
  clipboard and enabled after Copy or Cut;
- `Ctrl`/`Meta` Copy, Cut, and Paste work when the editor has focus and do not
  intercept shortcuts in an editable text control;
- switching tools commits an active transform, clears the visible selection,
  and preserves clipboard contents;
- an inverted stylus erases while Select is active, without changing the
  selected tool;
- a secondary pointer is ignored throughout lasso and transform gestures;
- lasso, frame, handles, and action bar are clipped/repositioned correctly near
  every page edge, and the action bar never sits under the floating palette;
- selection and clipboard survive orientation and breakpoint rebuilds;
- semantic labels report the selected tool, selection count, and clipboard
  actions;
- palette/layout tests and golden baselines are updated for the fifth button
  and representative selection states in light and dark themes.

### Performance validation

- Add a selection micro-benchmark with at least several hundred strokes and a
  long lasso. Report broad-phase candidates, geometry time, and total selection
  time.
- Extend the integration performance harness with a selection containing many
  strokes and long move/scale/rotate previews at a representative pointer
  sample rate.
- Verify that preview moves repaint only the selection layer, do not rebuild
  the editor shell, and do not rebuild stroke paths until commit.
- Report frame timing and memory observations. Separate emulator/simulator
  results from physical Android tablet and iPad results, and do not invent
  physical-device measurements when hardware is unavailable.

## Acceptance criteria

- The user can activate Select, draw a freeform region, and see all overlapping
  strokes selected as whole strokes.
- The selected group can be moved, uniformly scaled, and rotated with direct,
  visible feedback.
- Transform commits preserve color, relative geometry, relative stacking, and
  document order; scaling also scales stroke widths.
- Copy preserves the document, Cut removes the selected strokes, and Paste
  creates an independent vector copy with a visible offset.
- Fast preview interaction updates only the selection layer and rebuilds paths
  once at commit.
- Pen drawing, smoothing, both eraser modes, inverted-stylus erasing, and
  responsive layouts continue to behave as before.
- Formatting, static analysis, unit tests, widget tests, integration tests, and
  existing and updated golden tests pass.

## Completion report

At the end, describe:

- pointer routing for lasso, move, scale, and rotation;
- the exact rendered-ink/region overlap rule and even-odd behavior;
- the transform pivot and width rules;
- how preview painting avoids rebuilding paths and repainting completed ink;
- how transformed, copied, cut, and pasted strokes represent source and raw
  samples;
- every `SelectionConfig` value and default;
- clipboard lifetime and the repeated-paste offset rule;
- existing tests and golden files changed, with reasons;
- automated, emulator/simulator, and physical-device verification separately;
- deferred work, especially undo/redo, non-uniform transforms, multi-touch
  transforms, persistence, and operating-system clipboard interchange.
