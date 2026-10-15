# Implementation Prompt 2: Build the Modern, Minimal Tablet UI

You are implementing the visual foundation of **Greatnote**, a handwriting-focused Flutter application for Android tablets and iPads. A working Flutter project and test environment should already exist. Preserve its tooling and conventions.

## Goal

Build a polished, modern, minimal, tablet-first interface. The design should keep attention on the page, make common controls reachable without clutter, and adapt cleanly between portrait, landscape, and compact fallback sizes. This task establishes the design system and screen shell; it does not implement real drawing, persistence, account features, or document management.

## Design direction

- Use Material 3 as a foundation, but give the app a quiet, product-specific visual identity rather than leaving stock widget styling unchanged.
- Favor generous whitespace, restrained typography, subtle elevation, and a neutral canvas.
- Use rounded corners sparingly and consistently. Avoid excessive cards, gradients, glass effects, decorative animation, and heavy shadows.
- Use one accent color for selection and focus. Keep the writing surface visually dominant.
- Support light and dark themes. In light mode, use a warm off-white app background and a paper-white writing surface. In dark mode, distinguish the writing surface from surrounding chrome without using pure black.
- Use system fonts for reliable platform rendering. Define a compact, intentional type scale rather than introducing a font dependency.

## Design tokens

Create centralized, immutable tokens or theme extensions for:

- semantic colors, including background, surface, writing surface, primary text, secondary text, divider, accent, selected state, and focus state;
- spacing based on a 4-logical-pixel grid, with named values for 4, 8, 12, 16, 24, 32, and 48;
- corner radii, with no more than three standard values;
- control sizes and minimum touch targets;
- subtle elevation/shadow styles;
- animation durations and curves.

Do not scatter unexplained color literals, spacing values, or radii through feature widgets.

## Primary screen

Implement a responsive editor shell with these regions:

1. A slim top app bar containing:
   - a navigation/menu affordance;
   - the editable-looking document title `Untitled note` (visual only for now);
   - a compact overflow menu affordance.
2. A writing surface that spans the whole screen below the app bar, edge to edge: no outer margins, no rounded frame, no reserved gutter, and no maximum content width. Only a side panel opened beside the editor (the AI assistant, later) may take width from it. Render a subtle paper boundary only where it helps orientation, such as between pages narrower than the area.
3. A compact tool palette floating over the writing surface, containing a visual placeholder for the single pen tool, shown as selected. The pen's ink color and stroke width are not separate palette buttons: they live in a subpanel that opens when the already-selected pen is pressed again. The pen button shows the current ink as a small dot on its glyph, and its semantic label names the ink and width (for example "Pen, Black, 3 px").

Do not show eraser, highlighter, shape, text, lasso, or multiple pen choices. Those are outside the current product scope.

## Pages and canvas

A note is a sequence of one or more pages. Each page has its own page setup, made of a size and a background. The writing surface shows all pages as one continuous, connected column: each page sits directly below the one before it with no gap, separated only by a hairline seam, and scrolling flows from one page into the next.

### Page setup

- **Size**, one of:
  - *Fit to screen* (the default): the page fills the writing area, as a whiteboard would, and follows it when the window changes. It never scrolls.
  - fixed paper sizes: A4 portrait, A4 landscape, US Letter portrait, US Letter landscape, and Square. Store them in logical page units (A4 is 794 × 1123, Letter 816 × 1056, Square 1000 × 1000).
  - *Infinite*: the page starts at the size of the writing area and grows only when the user writes near its edge (below).
- **Background**, one of Blank (default), Lined, Grid, and Dotted. Rules are painted in page coordinates, under the ink, in a subtle themed color that reads on both light and dark pages, and are never part of the ink. Spacings are named tokens (default 32 for lines, 24 for grid and dots), and lined paper has a left margin rule.
- Changing the size of a page that already has ink resizes the page only; the ink keeps its page coordinates. Ink outside a smaller page is kept, clipped from view, and visible again if the page grows.

### Display and scrolling

- Ink and every page overlay use page coordinates. Each page's canvas converts pointer positions through that page's transform, so ink stays put whatever the page's scale or scroll position.
- Each page is laid out at its own scale: a fit page is the size of the writing area, a fixed-size page is scaled to the width of the area, and an infinite page is at scale 1. Pages narrower than the area are centered across it; a column shorter than the area is centered in it.
- The column scrolls vertically through all pages, and horizontally when an infinite page is wider than the area.
- Pages far outside the visible area need not be built; their ink stays in their controllers.
- The current page is the page a pointer last went down on, or, after a scroll, the page holding the middle of the area. Selection, Paste, the page indicator, and the page panel act on it. The current page does not change while a pointer is writing, erasing, or selecting on another page.
- One pointer owns the whole note at a time: while one page has a gesture in progress, a pointer on any other page is ignored, so a resting palm cannot let the pen write elsewhere.
- Writing input is never consumed by scrolling: on a scrollable page, scroll with two fingers, a mouse wheel, or a trackpad. When a second finger starts a two-finger scroll during a one-finger stroke, that stroke is discarded rather than committed. On a page that cannot scroll, a second finger is ignored as before.
- Show slim scroll indicators only while the page is larger than the area.

### Infinite growth

- When ink (the stroke in progress or a newly committed stroke) comes within an edge margin (default 96 logical px) of the right or bottom edge, extend the page in that direction by a growth step (default half the writing area's extent, at least 256 px). Growth happens live during the stroke, never shrinks the page automatically, and keeps the origin at the top-left so no existing ink moves.
- Keep the page's grown extent bounded by the ink coordinate limit already used elsewhere.
- Keep all margins, steps, and limits in a named configuration object.

### Page controls

- Add a page indicator to the app bar, before the overflow control, showing `current / count` (for example `2 / 5`). It opens a page panel.
- At medium and expanded widths, also show previous-page, next-page, and add-page buttons beside the indicator. At compact width these live only in the page panel.
- The page panel contains: previous and next page, Add page, Delete page (disabled for the only page, confirmed when the page has ink), the size choice, and the background choice. The current choices are indicated by more than color.
- Previous page, next page, and Add page scroll the column so that page's top is at the top of the area. Add page inserts a new, empty page right after the current one with the current page's setup.
- When the current page changes, the page left ends any gesture in progress and drops its selection; the clipboard comes along to the new current page.
- All page controls have tooltips, semantic labels (for example "Page 2 of 5"), 48 × 48 targets, and logical keyboard order after the title.

## Responsive behavior

- Use width-based breakpoints defined in one place; do not branch based on device model or operating system.
- The writing surface always fills the whole area below the app bar at every breakpoint; the palette floats above it, inset from the surface's edge by a small margin, and never shrinks it.
- At expanded widths (`>= 840` logical pixels), float the tool palette vertically near the top of the writing surface's leading edge (24 px inset) and keep the title centered in the app bar.
- At medium widths (`600-839`), use a compact vertical palette with a smaller inset (8 px).
- Below `600`, use a horizontal palette floating centered along the bottom of the writing surface (4 px inset) as a functional fallback.
- Pointer input on the palette goes to the palette, never to the page below it. Anything else that floats over the page (later: selection actions, Paste) moves clear of the palette rather than sitting under it.
- Respect safe areas, display cutouts, keyboard insets, and system navigation areas.
- Support portrait and landscape transitions without losing UI state or producing overflow.
- Do not cap the width of the writing surface or the app bar on very wide windows; both span the window.

## Interaction and motion

- All interactive controls must have visible hover, focus, pressed, selected, and disabled states where applicable.
- Use tooltips for icon-only controls.
- Use short, subtle animations for palette relocation, selection, and popover appearance. Honor the platform's reduced-motion/accessibility setting.
- Do not use animation on the future ink-rendering path.
- Keep every touch target at least 48 by 48 logical pixels, even when the visible icon is smaller.
- Make keyboard traversal logical and expose semantic labels for screen readers.

## Components and previews

Create reusable, focused widgets for the app bar, writing-surface frame, tool palette, and palette button. Avoid a single oversized screen widget. Add a development-only gallery or widget tests that render key components and states without adding a runtime dependency.

Use placeholder callbacks and view state so the controls are interactive enough to demonstrate pressed/selected states. Do not create fake production services or speculative domain architecture.

## Testing requirements

- Add widget tests at `390 x 844`, `800 x 1280`, and `1194 x 834` logical pixels.
- Test both light and dark themes at a representative tablet size.
- Verify that no overflow occurs after rotating between portrait and landscape.
- Verify palette orientation and placement at each breakpoint, that the writing surface spans the full width and the full height below the app bar at every breakpoint and on a very wide window, and that the palette lies inside the surface.
- Verify semantics labels, tooltips, minimum tap-target dimensions, keyboard focus order, and selected state.
- Add or update stable golden tests for the primary screen in:
  - tablet portrait, light theme;
  - tablet landscape, light theme;
  - tablet landscape, dark theme;
  - compact fallback, light theme.
- Keep golden tests deterministic by disabling or settling animation and using the project's fixed test surface configuration.
- Pages: verify that pages form one connected column with no gap; that scrolling past the middle of the area makes the next page current and the page buttons scroll to their page; that writing on another page makes it current and drops the first page's selection; that a pointer busy on one page blocks writing on another; adding, navigating, and deleting pages; that each page keeps its own ink and setup; that a fixed-size page is scaled to fit the width and scrolls vertically while an infinite page scrolls in both directions; that pointer positions map to page coordinates at any scale and scroll offset; that two-finger scrolling discards the stroke it interrupts; that an infinite page grows only when ink reaches the edge margin and never moves existing ink; and that each background paints its rules.
- Add goldens for a lined fixed-size page, a grid page in dark theme, the seam between two connected pages, the page panel, and the pen's subpanel.

## Non-goals

- Do not implement drawing or smoothing.
- Do not implement notes lists, folders, search, or storage here; the file-management home screen is prompt 9.
- Do not implement cloud synchronization, authentication, sharing, or import/export.
- Do not implement zoom. Scrolling a page larger than the writing area is in scope.
- Do not add an eraser or additional writing tools.
- Do not add a design-system package when Flutter theming and small local abstractions are sufficient.

## Acceptance criteria

- The writing surface is the strongest visual element, spans the whole screen below the app bar, and the interface remains calm and uncluttered.
- Layout works without clipping or overflow at all specified viewport sizes and in both orientations.
- Light and dark themes meet WCAG AA contrast for text and controls.
- Controls have at least 48-logical-pixel touch targets and accessible labels.
- The UI exposes exactly one pen tool, with its color and width in the pen's subpanel.
- A note can have many pages; each page can be fit-to-screen, a fixed paper size, or infinite, with a blank, lined, grid, or dotted background; an infinite page grows only when the user writes at its edge.
- Formatting, analysis, unit/widget tests, and golden tests pass.

## Completion report

At the end, summarize the design decisions, breakpoints, reusable components, accessibility behavior, and verification results. Include screenshots or golden-file locations when available, and explicitly identify any visual checks that still require a physical tablet.
