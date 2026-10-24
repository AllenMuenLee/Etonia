# Implementation Prompt 24: iOS-Grade Motion System and Page Transitions

You are working in the **Greatnote** (`Etonia`) Flutter tablet and phone repository. Replace the app's slow, shallow motion with an Apple-style motion system and rebuild every page, sheet, dialog and popover transition on it. This is prompt 1 of 3 in the redesign; prompt 25 (theme and glass) and prompt 26 (element interactions) build on the tokens defined here, so do this one first.

---

## Why

The current motion is described as "calm" in `docs/design_language.md` and feels laggy in the hand: pages move only 5.5% of the screen over 440 ms (`AppPageTransitionsBuilder`), there is no interactive swipe back, menus and dialogs run 320 ms with a soft curve, and lists stagger on every navigation. iOS users expect responsive, soft, spring-driven motion that is never slow.

Keep from the existing rules: everything runs on a ticker (no `Timer`/`Future.delayed`), only transform and opacity animate, one controller per group, `RepaintBoundary` on moving layers, reduced motion honoured. Never write a raw duration or curve in feature code.

---

## Motion system

### 1. Principles (what "Apple-like" means here)

1. **Answer on touch-down.** Visual feedback begins the same frame the finger
   lands (0 ms). The *action* fires on release, but the control must already
   look pressed.
2. **Springs, not tweened curves.** iOS motion is spring physics: it starts
   fast, has no hard end, carries the finger's velocity. Use
   `SpringDescription.withDurationAndBounce` for anything that moves, and a
   short ease-out only for opacity and colour.
3. **Interruptible and reversible.** A transition can be grabbed mid-flight
   and reversed; velocity carries over. Never lock input while something
   animates (no `IgnorePointer` during transitions).
4. **90% of the motion in the first 250 ms.** Total settle can be longer
   (that is the spring's tail) but the eye must feel "arrived" by about
   250 ms. If a design needs more than 400 ms it is too much.
5. **Direct manipulation is 1:1.** While the finger is down (back swipe,
   sheet drag, palette drag, slider) the thing tracks the finger with no
   easing and no lag. Easing only starts on release, seeded with the
   release velocity.
6. **Motion explains, never decorates.** Every animation says where
   something came from or went to, or what changed. If it does neither, cut
   it.
7. **Reduced motion = cross-fade, not nothing.** Replace travel/scale with a
   120 ms opacity fade (what iOS does), do not snap.
8. **120 Hz budget.** 8 ms per frame. Animate only transform and opacity;
   never `AnimatedSize` on big subtrees; one controller per group.

### 2. Tokens (replace the current `AppMotion` durations)

Springs are the primary tokens; durations are for opacity/colour only.

| Token           | Spring (duration / bounce) | Feels like              | Use                                              |
| --------------- | -------------------------- | ----------------------- | ------------------------------------------------ |
| `snappy`        | 0.30 s / 0.00              | decisive, no overshoot  | toggles, selection, chips, tool switch, press release |
| `smooth`        | 0.40 s / 0.00              | soft, no overshoot      | pages, panels, tab content, popovers, chrome show/hide |
| `bouncy`        | 0.45 s / 0.25              | a little life           | drops, palette docking, success pops (use sparingly) |
| `sheet`         | 0.45 s / 0.05              | heavy, settles firmly   | bottom sheets, modal pages, detent changes       |

| Fade token | Duration | Curve          | Use                                  |
| ---------- | -------- | -------------- | ------------------------------------ |
| `fadeIn`   | 160 ms   | easeOut        | appearing content, highlights        |
| `fadeOut`  | 110 ms   | easeIn         | leaving content (always shorter)     |
| `press`    | 0 ms in / 220 ms out | easeOut | pressed highlight appears instantly, relaxes slowly |
| `reduced`  | 120 ms   | linear         | every transition under reduced motion |

Remove: `AppMotion.stagger` on navigation, `coverCurve`/`cover()`, and the
320–440 ms duration family. Keep `resolve(context, …)` and add
`AppMotion.spring(context, token)` that returns the reduced variant when
`MediaQuery.disableAnimationsOf` is true.

## Page transitions

### 3. Every transition

| # | Transition | Spec |
| - | ---------- | ---- |
| 1 | **Push / pop** (Library → Account, Payment, Settings, any `AppPageRoute`) | Exactly the iOS push. New page enters from the trailing edge, full width (offset 1.0 → 0). The page below moves 30% of the width to the leading side (-0.3) and dims to ~90% brightness. The incoming page has a soft leading-edge shadow. Use `smooth`. **Interactive swipe-back from the leading edge**, tracking 1:1, completing if past 50% or flung faster than ~700 px/s; interruptible. Start from Flutter's `CupertinoPageTransitionsBuilder` on every platform (including Android) rather than re-deriving the geometry; wrap only for the opaque ground and reduced motion. |
| 2 | **Library card → editor** (opening a note) | Zoom transition: the note's thumbnail expands from its rect into the full editor, the rest of the library fades back and scales to 0.96. Reverse on close, back into the card's current rect (it may have scrolled). Falls back to #1 if the card is off-screen. `smooth`. Phase-2 polish, not required for first release. |
| 3 | **Folder navigation** inside Library | Phone width: this is a push (#1) of the content column with the large title collapsing into the nav-bar title. Tablet/split view: the detail column does **not** slide; it cross-fades (`fadeIn`/`fadeOut`, 8 pt vertical drift) and the sidebar selection moves immediately. Replaces `SceneSwitcher`'s slide-from-the-side. No stagger. |
| 4 | **Modal page** (`fullscreenDialog`: Payment, Handwriting calibration, Drive) | Slides up from the bottom (offset 1.0 → 0, `sheet`). The page below scales to 0.94, rounds its corners, and dims. Swipe-down to dismiss, tracking 1:1, from the top region only (so inner scroll views keep working). |
| 5 | **Bottom sheet** (settings, export, Drive) | Rises with `sheet`; scrim fades in at `fadeIn` with a 35% black. **Detents** (medium ≈ 50%, large) with a grabber; drag follows the finger, release snaps to the nearest detent projected from velocity; flick down dismisses. On iPad width it becomes a centered form-sheet (max 540 pt) that scales 0.96 → 1 with fade instead of rising. |
| 6 | **Alert / dialog** | Scale 1.08 → 1.0 + fade (iOS alert), `snappy`; leaving: scale to 0.96 + `fadeOut`. Scrim `fadeIn`. Buttons use the press behaviour in prompt 26. Replaces the 320 ms `AppDialogRoute`. |
| 7 | **Menus and popovers** (palette popovers, context menus, `MenuAnchor`) | Scale from the **anchor point** (alignment = where the trigger is), 0.88 → 1.0 + fade, `snappy`; leaving `fadeOut` + scale to 0.94. Long-press context menus: the item lifts (scale 1.04, raised shadow, haptic) while the menu appears beside it. |
| 8 | **Switching between palette popovers** in the editor | Morph, do not close-and-reopen: the old popover cross-fades into the new one while its frame animates to the new size (`snappy`). Dismiss only on tap-outside or tool change. |
| 9 | **Note tab switch** (`note_tab_strip`, `note_tabs_page`) | Content cross-fades `fadeIn`/`fadeOut`, no slide (like Safari tabs). The selection capsule glides between tabs (shared indicator, `snappy`). Closing a tab: the tab shrinks and fades, neighbours close the gap (`snappy`). |
| 10 | **Editor chrome show/hide** (focus mode, palette/app-bar auto-hide) | Fade + 12 pt translate toward the nearest edge, `smooth`. Chrome never covers the page while the pencil is down: hide immediately on pencil touch-down (`fadeOut`), return after lift. |
| 11 | **AI assistant panel** | Slides in from the edge it docks to with `smooth`, with detents like a sheet when narrow; at tablet width it is a trailing side panel that pushes the page (no scrim). Streamed text appears by chunk (`fadeIn` 120 ms), never per character. |
| 12 | **Pages inside a note** (scroll/zoom/page switch) | Platform scroll physics (`BouncingScrollPhysics` on iOS). Page-number jumps scroll with `smooth`; no custom flip animation. Pinch-zoom is 1:1; double-tap-zoom is `snappy`. |
| 13 | **App launch → Library** | A short `fadeIn` of the whole content (no per-item stagger). Thumbnails fade in as they load (`fadeIn`, no layout shift). At most one subtle stagger: the first 6 cards, 20 ms apart, **only on cold start**. |
| 14 | **Toast / banner** | Drops from the top (or rises from the bottom above the palette) with `snappy`, auto-dismisses after 2.5 s, swipe to dismiss. |

Delete: `SceneSwitcher` slide behaviour, `StaggerScope` use on navigation,
`AppMotion.popupStyle`/`sheetStyle` values (re-point them at the new
springs; keep the names so call sites do not churn).

### 4. Hard rules

- No raw `Duration(...)`, `Curves.*` or `Cubic(...)` in feature code: only
  `AppMotion` tokens.
- No animation that delays an action. Tapping a row navigates on the same
  frame the page begins to move.
- Nothing animates `width`/`height`/`padding` of a large subtree. Small
  single-row collapses are the one exception.
- A transition built with `AnimationController` must be driven by
  `vsync`; spring release uses `SpringSimulation` seeded with the real
  gesture velocity.

---

---

## Files in scope

Rewrite: the `AppMotion` section of `lib/app/theme/app_tokens.dart`, `lib/shared/navigation/app_page_route.dart`, `lib/shared/navigation/app_dialogs.dart`, `lib/shared/widgets/scene_transitions.dart`.

Touch (replace raw durations/curves and old transitions): `lib/features/library/{library_screen,library_dialogs,note_tab_strip,note_tabs_page,note_editor_page}.dart`, `lib/features/library/cloud/google_drive_sheet.dart`, `lib/features/editor/editor_screen.dart`, `lib/features/editor/widgets/{palette_popover,ai_assistant_panel,editor_settings_sheet,export_options_sheet,editor_chrome}.dart`, `lib/features/payment/{payment_page,account_panel}.dart`.

Find offenders with: `grep -rnE "Duration\(milliseconds|Curves\.|Cubic\(|StaggerScope|SceneSwitcher" lib --include=*.dart`.

## Do not

- Do not add an edge-swipe that eats pencil strokes: swipe-back applies to **touch** pointers only and never on the editor canvas. In the editor, back is the button, plus a 16 pt leading-edge swipe zone active only while the "draw with finger" setting is off.
- Do not stagger lists on navigation, slide detail columns sideways on iPad, or lock input during a transition.
- Do not leave the old durations alive next to the new springs: migrate fully, then delete. Keep the `popupStyle`/`sheetStyle` names so call sites do not churn, but point them at the new springs.

## Automated tests

- Reduced motion yields only a short cross-fade (no offset or scale).
- The page route supports interactive pop and can be reversed mid-flight.
- The grep above returns nothing outside the token file.
- Sheet detent snapping picks the nearest detent from release velocity.

## Acceptance

On an iPhone and an iPad (or the wireless test tablet), a push, a back swipe, a sheet drag and a menu open all respond on the first frame, can be interrupted, and are visually settled by about 250 ms. `flutter analyze` and `flutter test` pass; the motion section of `docs/design_language.md` is rewritten to match. Commit this prompt's work separately so it can be reverted alone.
