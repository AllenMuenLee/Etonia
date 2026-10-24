# Implementation Prompt 26: Interaction Animations for Every UI Element

You are working in the **Greatnote** (`Etonia`) Flutter repository. Give every interactive element one consistent, responsive, not-too-fancy behaviour built on the spring and fade tokens from prompt 24, styled with the theme from prompt 25. Do prompts 24 and 25 first.

---

## Rules

Every interactive element gets exactly one of the behaviours below; do not invent a new one per widget. Build them as reusable pieces in `lib/shared/widgets/` (`Pressable`, `app_controls.dart`) so feature code only picks a type. Feedback begins on touch-down (0 ms); the action fires on release. Direct manipulation (drag, slider, swipe) tracks the finger 1:1 and only eases after release, seeded with release velocity. Honour reduced motion via `AppMotion`.

Token names (`snappy`, `smooth`, `bouncy`, `sheet`, `fadeIn`, `fadeOut`, `press`) are defined in prompt 24. "(#7)" below means popover transition 7 in prompt 24's table.

## Element behaviours

Every interactive element gets exactly one of these behaviours; do not invent
a new one per widget. Put them in `lib/shared/widgets/` as reusable pieces.

| Element | Behaviour |
| ------- | --------- |
| **Button (filled / tonal / text)** | Down: scale 0.97 over 80 ms and a 10% darker (light) / lighter (dark) overlay, instantly. Up: spring back with `snappy`; overlay `press` out. Disabled: 38% opacity, `fadeIn` between states. |
| **Icon button / toolbar glyph** | Down: a round highlight (surfaceMuted) fades in over 0 ms, glyph scales 0.92. Up: highlight relaxes over 220 ms. Hit target stays 48 pt. |
| **Glass capsule button** | Down: surface brightens slightly and scale 0.97; the rim highlight intensifies. Up: `snappy`. |
| **List row** | Touch-down highlight is instant, `press` out. Swipe actions track 1:1 with rubber-band at the end; a full swipe commits with a haptic. Delete: row fades `fadeOut` and collapses (height only for one row, `snappy`). Reorder: lift 1.03 + raised shadow, siblings part with `snappy`. |
| **Card / note thumbnail** | Down: scale 0.98, shadow tightens, the dog-ear flap darkens. Long-press: lift 1.04, raised shadow, `lift` haptic, then the context menu (#7). Selection mode: a checkmark badge pops in (`snappy`, scale 0.6 → 1). |
| **Toggle (switch)** | Thumb widens on press, travels with `snappy`, track colour cross-fades 160 ms, `tap` haptic. |
| **Segmented control** | A single glass thumb slides under the selected segment (`snappy`); labels change colour only, never weight (no text jitter). |
| **Slider** | Value tracks the finger 1:1 with no animation. Thumb scales to 1.15 while dragging and back with `snappy`. A value pill fades in above the thumb. Detents click with a haptic. |
| **Checkbox / radio / chip** | Fill `fadeIn` 140 ms; the checkmark draws on over 180 ms (stroke draw-on). Chips scale 0.96 on press. |
| **Text field** | Focus: border ring fades in 150 ms and the placeholder/label floats up with `snappy`. Error: a 6 pt horizontal shake over 240 ms plus `error` haptic. |
| **Tool palette button** | Selecting a tool: the solid ink selection capsule (paper-coloured glyph) glides from the old tool to the new one (`snappy`), the new glyph does a 1.0 → 1.12 → 1.0 pop, `toolSwitch` haptic. Re-tapping the active tool opens its popover (#7). Replaces the `InkRule` under the tool. |
| **Colour swatch** | Selected ring grows from the swatch's centre (`snappy`); the swatch pops 1.08 → 1.0. |
| **Palette drag** | Follows the finger 1:1 with a raised shadow and `lift` haptic. On release it projects the fling velocity and snaps to the nearest dock with `bouncy`. |
| **Undo / redo / page stepper** | Press as an icon button. A changing number rolls vertically 8 pt with a cross-fade (`snappy`). Enabled/disabled fades over 150 ms. |
| **Search field** | Tapping expands the field to full width while the Cancel button slides in (`snappy`); results fade in. |
| **Progress and loading** | Indeterminate: system-style spinner. Content loading: skeleton blocks with a slow 1.6 s shimmer. App launch, import, export and AI thinking: the three-bar `EtoniaBarsLoader` from prompt 25. AI working on a surface: the existing `AmbientGlow`/`Breathe`, retinted to the Lilac, Sky and Peach highlighter gradient (at most one per screen). Determinate bars animate value changes with `smooth` and never move backwards. |
| **Success / error feedback** | Success: a plain checkmark draws on, `success` haptic. Error: the shake above plus `error` haptic. |
| **Pull to refresh / overscroll** | Platform behaviour; do not restyle. |

Haptic map stays in `AppHaptics` (`toolSwitch`, `tap`, `lift`, `success`,
`error`); every behaviour above names the one it uses.

---

## Files in scope

Rewrite: `lib/shared/widgets/pressable.dart`, `lib/shared/widgets/app_controls.dart`, `lib/shared/widgets/processing.dart` (retint to the highlighter glow; shimmer skeletons; `EtoniaBarsLoader` lives in prompt 25's `etonia_mark.dart`).

Touch: `lib/features/editor/widgets/{tool_palette,palette_button,palette_popover,ink_color_picker,stroke_width_picker,history_controls,page_controls,selection_action_bar,editor_app_bar}.dart`, `lib/features/library/{library_screen,note_tab_strip}.dart`, `lib/features/payment/plans_button.dart`.

New pieces: selection capsule (shared sliding indicator), stroke draw-on check, rolling number, shake. The note card's dog-ear press response (flap darkens) is in prompt 25.

## Do not

- No animation that delays an action, and no animation of text weight or large-subtree size.
- Do not add haptics outside the `AppHaptics` map (`toolSwitch`, `tap`, `lift`, `success`, `error`).

## Automated tests

- Widget tests: the pressed state is visible on the pointer-down frame; release returns to rest; disabled controls do not scale.
- Reduced motion: no scale or travel, only a short fade.
- The selection capsule lands on the tapped tool; slider value equals the finger position with no lag.

## Acceptance

On the tablet, tool switching, palette drag and dock, colour pick, undo/redo and tab close all feel instant with no dropped frames while the pencil is drawing. `flutter analyze` and `flutter test` pass. Commit separately from prompts 24 and 25.
