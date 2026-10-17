# Implementation Prompt 4: Implement the Eraser (Area and Stroke Modes)

You are adding an eraser to **Greatnote**, a Flutter tablet application for Android and iPadOS. The editor already has a responsive shell, a floating tool palette, and a low-latency ink canvas with one pen. Preserve the design system, testing setup, responsive behavior, and the existing pen and smoothing behavior.

## Goal

Add one eraser tool with two modes:

1. **Area erase**: a circular eraser removes only the ink it passes over. Strokes it crosses are cut, and the parts outside the eraser remain. The eraser size is adjustable.
2. **Stroke erase**: any stroke the eraser touches is removed in its entirety.

Erasing is vector-based: it changes the stroke collection. Do not implement it by painting the page color, by `BlendMode.clear`, or by any other pixel mask, because erased ink must really be gone from the model.

## Scope

Implement only:

- tool selection between the pen and the eraser;
- the two eraser modes and a control to switch between them;
- an adjustable eraser size for area mode;
- an on-canvas eraser indicator while erasing;
- in-memory results for the current editor session.

Do not add undo/redo, clear-page, lasso or selection, a highlighter, pressure-controlled eraser size, persistence, or export. Undo is expected later, so keep each erase gesture (pointer-down to pointer-up) identifiable as one unit of change in the controller, but do not build the history itself.

## Existing code to build on

Read these before designing anything; the eraser must fit their structure rather than sit beside it:

- `lib/features/editor/ink/ink_controller.dart`: owns the completed strokes and the active stroke, with separate notifiers for each.
- `lib/features/editor/ink/stroke.dart`: `Stroke` is immutable, has a private constructor, and caches its `Path`. `ActiveStroke` is the only thing that creates one today.
- `lib/features/editor/ink/ink_canvas.dart`: raw pointer capture, single active pointer, `isInputBlocked`, and stroke finalization on metrics change.
- `lib/features/editor/ink/ink_painter.dart`: one painter for completed strokes and one for the active stroke, each behind its own `RepaintBoundary`.
- `lib/features/editor/widgets/tool_palette.dart`: the palette, whose pen button is hard-wired as selected and whose size is derived from a fixed `_buttonCount`.
- `lib/features/editor/editor_screen.dart`: owns `PenSettings` so it survives rotation, and lays the page out around `ToolPalette.sizeFor`.

Several existing tests assert that the pen is the only tool and that it is always selected (see `test/features/editor/`). Those assertions are now out of date. Update them to describe the new behavior; do not delete coverage that still applies.

## Tool and eraser state

- Introduce an explicit active tool (pen or eraser) and an immutable eraser settings value holding the mode and the size, with a config object for the size limits, mirroring `PenSettings` and `PenConfig`.
- Own this state in the same place as `PenSettings` so it survives orientation and breakpoint changes for the session.
- The pen is the default tool on launch. Area is the default eraser mode.
- Eraser size is a diameter in logical **screen** pixels. Default range 8 to 80, default value 24. Keep these in the config object, not as magic numbers.
- The eraser keeps the same size on screen however the page is shown: when a page is scaled to fit or zoomed in, the eraser does not grow with it. At pointer-down, measure how many screen pixels one canvas pixel covers (through the page's fit scale and any zoom, from the canvas's own transform to the screen) and divide the eraser's radius by it, in both area mode and stroke mode's hit radius. The radius is fixed for the rest of the gesture. The indicator, drawn in canvas coordinates at that radius, therefore also appears at the set size on screen, matching the options preview.
- Changing tool, mode, or size affects the next gesture only. If the tool changes while a stroke or erase gesture is in progress, end that gesture first.
- Pen color and width are untouched by anything the eraser does.

## Palette UI

- Add an eraser button next to the pen button. Exactly one of the two is shown as selected, using the existing `PaletteButton` selected treatment, and the selection is exposed to assistive technology.
- Pressing the eraser button selects the eraser. Pressing it again while it is selected opens an eraser options popover built with the existing `PalettePopover`.
- The popover contains:
  - a two-option mode control labelled "Area" and "Stroke", with the current mode indicated by more than color;
  - a size slider with a live circle preview at true size, following the pattern of `StrokeWidthPicker`. The slider applies to area mode; disable it, with its value preserved, in stroke mode.
- The pen's ink color and stroke width live in the pen's own subpanel. The eraser never changes them, and switching tools leaves them as they were.
- Update `ToolPalette.sizeFor` so the editor layout still reserves the right space in both the vertical and horizontal arrangements, and register the new popover with `ToolPaletteController.hasOpenPopover` so the tap that dismisses it does not erase anything.
- Reuse the existing tokens for spacing, radii, and touch targets. Add no new dependency.

## Input

- Reuse the existing pointer pipeline in `InkCanvas`: raw pointer events, canvas-local logical coordinates, one active pointer at a time, additional pointers ignored, `isInputBlocked` respected at pointer-down.
- With the eraser selected, stylus, touch, and mouse input erase instead of drawing.
- An inverted stylus erases regardless of the selected tool, using the current eraser settings, and does not change the selected tool.
- Erasing happens live on pointer-down and on every pointer-move, not at pointer-up.
- Pointer-up and pointer-cancel both end the gesture and keep what has been erased so far.
- A metrics change (rotation or resize) ends an erase gesture the same way it ends a stroke.

## Erase geometry

Treat a stroke as its filtered centerline (`Stroke.points`) drawn with round caps and joins at width `w`. Treat the eraser as a disc of radius `r` (half the size setting). Between two consecutive eraser samples the eraser covers a swept capsule: every point within `r` of the segment joining the two sample positions. Always test against the swept capsule, never only the sample positions, so a fast flick cannot skip over ink. The first sample of a gesture is a capsule of zero length.

### Stroke mode

- A stroke is hit when the distance between its centerline and the eraser's swept segment is at most `rHit + w / 2`, where `rHit` is a small fixed radius (default 6 logical pixels, in the config object) rather than the area size.
- A dot stroke is hit when its center is within `rHit + w / 2` of the swept segment.
- A hit stroke is removed whole. Other strokes are unchanged, and the order of the remaining strokes is preserved.

### Area mode

- The part of a centerline to remove is every point within `r + w / 2` of the eraser's swept segment. Cutting at this distance means the round cap of each remaining piece ends tangent to the eraser's edge, so no ink is left inside the erased area.
- Cut precisely. Where a stroke segment crosses that boundary, compute the crossing point and insert it as a new end vertex of the remaining piece. Do not approximate by dropping whole vertices, which leaves visibly ragged gaps on strokes with widely spaced points.
- One stroke may be cut into zero, one, or many pieces by a single eraser move. Each remaining piece becomes a new immutable `Stroke` with the original's `StrokeStyle`.
- The pieces replace the original stroke at its position in the collection, in order along the original direction of travel, so z-order relative to other strokes does not change.
- Discard a piece whose centerline length is below a small documented epsilon. A dot stroke is removed when its center is within `r + w / 2` of the swept segment, and is otherwise unchanged.
- Pieces must never be passed through the smoother again. Their points are the original filtered points plus the computed cut points.
- `Stroke` currently carries `rawSamples`, which do not map index-for-index onto `points`. Do not invent raw samples for a piece. Choose a clear representation (for example, raw samples only on strokes that came straight from input), document it on the model, and keep the "came from input" and "derived by erasing" cases distinguishable.
- Give `Stroke` a way to be built from a list of points and a style, with its `Path` built once at creation, without loosening the invariants `ActiveStroke.finish()` relies on.

### Purity

Put the geometry (point-to-segment and segment-to-segment distance, capsule intersection, splitting a polyline) in a pure Dart component with no widget or rendering dependency, in the same spirit as the smoother. The controller calls it; the canvas does not.

## Controller and painting

- Add the erase operations to `InkController` (or a collaborator it owns), with a begin, a move, and an end that mirror the stroke lifecycle and share the single-active-pointer rule. A pointer cannot be writing and erasing at once.
- Notify the completed-strokes listenable only when an eraser move actually changed the collection. A move over empty paper causes no completed-layer repaint.
- Give each stroke a cached bounding box, inflated by half its width, and reject strokes whose box does not intersect the eraser capsule's box before doing any per-segment work.
- Do not rebuild paths for strokes that were not touched.
- Draw the eraser indicator in its own layer above the ink, behind its own `RepaintBoundary`, repainting from its own listenable so that moving the eraser does not repaint the completed strokes. In area mode the indicator is a circle outline at the true eraser size; in stroke mode it is a small outline at `rHit`. It is visible only while an erase pointer is down, is clipped to the writing surface, uses theme colors that read on both light and dark pages, and is excluded from semantics.

## Robustness requirements

- Handle an empty page, zero-length eraser moves, duplicate positions, taps, a stroke that lies entirely inside the eraser, a stroke crossed many times in one gesture, single-segment strokes, dot strokes, positions outside the canvas, cancellation, and rotation mid-gesture without exceptions, NaN, or infinity.
- Erasing the same place twice changes nothing the second time.
- Repeated area erasing must not accumulate degenerate or duplicate vertices.
- Results depend only on logical coordinates, not on device pixel ratio.
- Work per eraser move is bounded by the strokes near the eraser, not by the whole page. Do not add a spatial index unless the benchmark below shows the bounding-box rejection is insufficient; if you add one, justify it with numbers.
- Dispose of any new notifiers and controllers.

## Automated tests

Add deterministic tests with synthetic geometry.

### Geometry unit tests

- an eraser crossing the middle of a straight stroke leaves two pieces whose inner ends lie at `r + w / 2` from the eraser path, within a stated tolerance;
- an eraser over one end leaves one shortened piece;
- an eraser covering the whole stroke leaves nothing;
- an eraser that misses by more than `r + w / 2` leaves the stroke identical, and the same instance;
- a fast move whose two sample positions are both far from the stroke, but whose connecting segment crosses it, still cuts;
- a stroke crossed twice by one move yields three pieces in original order;
- cut points are computed on the segment, not snapped to existing vertices, shown with a two-point stroke;
- dot strokes are removed or kept according to the distance rule;
- pieces below the length epsilon are discarded;
- erasing twice at the same place is idempotent;
- stroke-mode hit testing honors `rHit + w / 2` for wide and thin strokes;
- all outputs are finite for degenerate inputs, and two runs over identical input produce identical output.

### Controller tests

- area erase replaces a stroke with its pieces at the same index, and neighboring strokes keep their order and identity;
- pieces keep the original style;
- stroke erase removes exactly the touched strokes;
- the completed-strokes listenable fires only when something changed;
- an erase gesture cannot start while a stroke is active, and the reverse;
- cancel and metrics change end the gesture and keep the result.

### Widget and interaction tests

- the eraser button is present and selectable in tablet and compact layouts, and exactly one tool is selected at a time;
- with the eraser selected, dragging over a drawn stroke removes or cuts it and draws no new ink;
- switching back to the pen draws again with the unchanged color and width;
- the options popover opens from the selected eraser button, switches mode, and changes size;
- the size slider is disabled in stroke mode and keeps its value;
- the tap that dismisses the popover erases nothing;
- an inverted-stylus pointer erases while the pen is selected, and the pen stays selected;
- the indicator appears only while erasing and matches the configured size;
- on a page shown scaled up, the eraser's reach on the page is its screen size divided by the scale, so it covers the same screen area at every zoom;
- erasing through a stroke of varying width (a tapered or pressure-sensitive pen stroke) keeps each piece's widths along it;
- tool, mode, and size survive a layout/orientation rebuild;
- semantic labels announce the tool, the mode, and the size;
- existing golden tests are updated for the new palette and pass.

### Performance validation

- Extend the existing benchmark or integration performance harness with a page of many strokes (at least several hundred) and a long eraser gesture at a representative high sample rate, in both modes.
- Report time per eraser move and frame timing. Report physical-device results separately, and do not invent them if only an emulator is available.

## Acceptance criteria

- The user can switch between pen and eraser from the palette, and between area and stroke modes from the eraser options.
- In area mode, only ink under the eraser disappears, strokes are cut cleanly at the eraser's edge, and the eraser size can be changed.
- In stroke mode, touching a stroke removes the whole stroke.
- Erasing is visible during the gesture, and a fast gesture does not skip over ink.
- Remaining ink keeps its color, width, position, and stacking order.
- Pen drawing and smoothing behave exactly as before.
- Formatting, static analysis, unit tests, widget tests, and golden tests pass.

## Completion report

At the end, describe the data flow from an eraser pointer event to the repaint, state the cut rule and every eraser configuration value with its default, explain how derived strokes represent their raw samples, list the existing tests you changed and why, report automated and physical-device verification separately, and call out anything left for later, in particular undo/redo and hover preview of the eraser.
