# Implementation Prompt 25: Monochrome Fluid Glass Theme Drawn from the Etonia Logo

You are working in the **Greatnote** (`Etonia`) Flutter repository. Redesign the app theme from the logo outward: about 70% Apple (grouped backgrounds, large titles, continuous corners, fluid glass chrome, system behaviour) and 30% Etonia's own, where that 30% is taken directly from `assets/icon/etonia.png` rather than invented. Prompt 24 (motion tokens) should be done first; prompt 26 (element interactions) builds on this one.

---

## The logo, read as a design brief

`assets/icon/etonia.png` is a solid white "E" on black. Look at it before writing anything. Five facts in it become the theme:

1. **Two tones, no colour.** Ink and paper, nothing else. The brand is not a hue.
2. **Mass, not outline.** The letter is one fat filled shape. There are no strokes, borders or thin lines in it.
3. **Pill-ended slots.** The two gaps between the E's arms are stadium shapes with fully round ends. Everything soft in the logo is a capsule.
4. **A dog-ear.** The top-right corner is cut diagonally and folded back, with a hairline gap around the flap. The E is also a sheet of paper.
5. **Big, even corner radius** on the outer shape (about 16% of its width), tightening nowhere.

So: the chrome is black and white, the only colour in the app belongs to the user's content, shapes are fat and capsule-ended, and the dog-ear is the one recurring graphic detail.

If a choice is a toss-up between Apple and Etonia, pick the Apple answer.

---

## Why the current theme goes

- **The "ink rule"** (`lib/shared/widgets/ink_rule.dart`, 7 call sites) is a green tapered underline under breadcrumbs, tabs, section labels and empty states. It is the thing the owner calls "weird". It goes away entirely.
- **The "nib corner"** (`AppCorners`, a tight bottom-leading corner) makes every surface look slightly broken next to system UI, and it appears nowhere in the logo. It goes away.
- **Verdigris on warm paper** contradicts the logo, which has no colour, and looks muddy. The palette is replaced.
- **"Glass"** is a 97%-opaque tint (`AppGlass.opacity = 0.97`): no blur, no rim light. It was made that way for a good performance reason (section 5); the redesign keeps the reason and gets the look back.

Keep the existing hard rules (see `docs/design_language.md`): everything runs on a ticker, only transform and opacity animate, `RepaintBoundary` on moving layers, reduced motion honoured. Data paths stay `greatnote/`; ids stay `com.etonia.app` / `etonia_*`. Never write a colour literal in feature code.

---

## Theme

### 1. Direction: "ink and paper, with colour only from the user"

70% Apple: grouped backgrounds, large titles, continuous (squircle) corners, concentric radii, glass chrome that floats over content, standard control proportions, SF-style symbols, Dynamic Type. 30% Etonia, all from the logo:

1. **Monochrome chrome.** Black and white are the brand. The primary action, the selected tool and the focus ring are ink (near-black on light, white on dark), exactly as the logo inverts between the app icon and a light page. There is no brand accent colour.
2. **Colour belongs to content.** A six-colour highlighter palette is the only colour in the app. The user assigns one to a folder or a note; AI activity uses a soft highlighter glow. Nothing else is coloured except status (danger, success).
3. **Fat, capsule-ended controls.** Buttons, toggles, tracks, progress bars, the selection indicator and the segmented thumb are stadium shapes with chunky proportions, echoing the logo's pill slots.
4. **The dog-ear** (section 4) on every document.
5. **Heavy, rounded titles** that match the logo's weight.

### 2. Colour (replace `AppColors`; same field names where possible)

Dark mode is the logo as drawn: true black with white ink. Light mode is its inverse. Verify every pair for WCAG AA (4.5:1 body, 3:1 large and graphics) and update `test/shared/etonia_identity_test.dart` to pin the new pairs.

| Role | Light | Dark |
| ---- | ----- | ---- |
| `background` (grouped) | `#F2F2F4` | `#000000` |
| `surface` (cards, sheets) | `#FFFFFF` | `#151517` |
| `surfaceMuted` | `#E9E9EC` | `#232326` |
| `writingSurface` (the page) | `#FFFFFF` | `#161618` |
| `textPrimary` (ink) | `#0A0A0B` | `#F5F5F7` |
| `textSecondary` | `#6B6B70` | `#9A9AA0` |
| `divider` | ink @ 10% | white @ 14% |
| `accent` (= ink) | `#0A0A0B` | `#FFFFFF` |
| `onAccent` (= paper) | `#FFFFFF` | `#000000` |
| `selected` (tinted fill) | ink @ 8% | white @ 14% |
| `focus` ring | ink | white |
| `danger` | `#E5362B` | `#FF6B61` |
| `success` (status only) | `#1E9E4A` | `#4CD27A` |

`accent` now means ink. Audit every use of `colors.accent` and decide per use: a filled primary action or selected control stays `accent`; anything that only wanted "a bit of colour" becomes a highlighter or goes neutral. Do not recreate a brand hue.

**Highlighter palette** (`AppColors.highlighters`, a `List<Color>`): swatches at 100%, marker fills at about 55% alpha; dark mode drops lightness about 15%.

| Name | Light |
| ---- | ----- |
| Lemon | `#FFE66D` |
| Peach | `#FFB48A` |
| Rose  | `#FF9DB8` |
| Lilac | `#C9B8FF` |
| Sky   | `#8FD3FF` |
| Mint  | `#8FE8C4` |

Uses: folder colour, note colour (the dog-ear flap, section 4), tag chips, the AI glow (a slow Lilac to Sky to Peach gradient, at most one glowing surface per screen), and a "new" dot. Pen ink colours inside the editor are user content and are not part of this palette.

### 3. Shape, type and layout

- Replace `AppCorners` (nib) with **continuous corners**: `RoundedSuperellipseBorder` / `ClipRSuperellipse` (check they exist on the pinned Flutter 3.44.2; if a widget lacks support keep `BorderRadius` with the same radii).
- Radii: note and folder cards 22 (about the logo's 16% at card size), popover 22, glass bar 24, sheet and dialog 28 (top corners for sheets), text field 14. **Buttons, toggles, chips, segmented controls, search fields and progress bars are stadiums (fully round).** Concentric rule: inner radius = outer radius minus padding.
- **Chunky proportions:** button height 44 to 50, slider and progress track 8 pt, toggle 51 x 31 (Apple's size), selection indicator a full capsule. Nothing hairline except dividers and the glass rim.
- Keep `AppSpacing` (4-pt grid). Touch targets 44 to 48 pt.
- **Type:** body, labels and controls use the system font (SF on iOS). **Titles use a rounded heavy face** to echo the pill ends: SF Pro Rounded on iOS if Flutter can resolve it (try family `.SF Pro Rounded`; verify on device), otherwise bundle Nunito ExtraBold (OFL; ship its `OFL.txt` under `assets/`, as is done for EMS Readability). Scale: Large title 34 w800, tracking -1.0, collapsing to a 17 pt centred nav-bar title on scroll (Library, Account, Settings); Title 22 w700; Headline 17 w600; Body 17; Callout 16; Subhead 15; Footnote 13; Caption 12. Dynamic Type must scale it. Secondary text steps down by colour, not only size. Drop the tracked-out uppercase micro-labels except grouped-list section headers.
- Remove the dot grid from Library and settings. Keep it only as the faint surround behind the page in the editor.
- **Icons:** `cupertino_icons` is already a dependency. Use medium-weight glyphs with round caps and joins, and the **filled variant for the selected state** (it matches the logo's mass). Keep one weight across the app.

### 4. The dog-ear and the E mark (the 30%)

**Selection indicators** (replace `InkRule` everywhere):

- **Icon controls** (palette tools, bottom or tab icons): a solid ink capsule with the glyph in paper colour. It glides between items (prompt 26).
- **Text rows** (sidebar folder, breadcrumb, tab titles): a `selected` capsule fill behind the row. Text weight never changes.
- **Section headers:** no mark, only the caps label.

**Dog-ear.** A note is a sheet of paper, so a note's thumbnail card has the logo's folded corner: the top-trailing corner is cut diagonally (about 22% of the shorter side) and a small flap is drawn folded back, separated from the body by a 1.5 pt gap, as in the logo.

- The flap takes the note's highlighter colour; with no colour set it is `surfaceMuted`.
- Where it appears: note thumbnail cards, the empty-state illustration (a large dog-eared sheet in `surfaceMuted` with pill-shaped text lines), the loader, and the launch mark. **Nowhere else:** not on folders, buttons, bars or tabs.
- Build it as one widget (`DogEar` clipper + painter, in `lib/shared/widgets/`) so cards, tests and the transition in prompt 24 (#2, the card that unfolds into the editor) share it.
- Pressing a card darkens the flap slightly; opening a note unfolds it into the page when the zoom transition is implemented.

**The E mark.** Trace `assets/icon/etonia.png` into a vector `Path` (`lib/shared/widgets/etonia_mark.dart`, `EtoniaMark(size, color)`), so it is crisp at any size and takes `textPrimary`. Use it on the launch screen (set the native iOS LaunchScreen and Android splash to black with the white mark), the Account panel and the empty state. Do not put it in the app bar of every screen.

**Branded loader.** `EtoniaBarsLoader`: three stadium bars with the widths of the E's arms, filling in sequence over about 1.2 s on a loop. Use it only for app launch, import, export and AI thinking. Tiny inline waits (inside a button) use the platform spinner.

### 5. Glass (the "fluid glass" look, done within the performance budget)

Context: live `BackdropFilter`s were removed because several of them over the high-DPI editor canvas dominated raster time on the tablet. Keep that constraint. The answer is **tiers**, not "blur everywhere". Neutral black-and-white glass with a bright rim suits this palette: it looks best on near-black.

Surface tiers:

| Tier | What | Treatment |
| ---- | ---- | --------- |
| L0 | background | flat `background` |
| L1 | content: cards, list groups, the page | opaque `surface`, hairline `divider` (in dark, the surface step from pure black is the edge), soft `paper` shadow in light only |
| L2 | floating chrome: nav bar, tab strip, tool palette, selection bar, popovers, menus | **glass** (below) |
| L3 | modal: sheets, dialogs | glass or opaque `surface` over a scrim |

Glass recipe (one widget, `GlassSurface`, one place to tune):

1. `BackdropFilter` blur sigma about 24 plus a saturation lift (colour matrix x1.6), clipped to the squircle. Use `BackdropGroup` + `BackdropFilter.grouped` (Flutter 3.29 or later, verify on 3.44.2) so one screen's glass shares one backdrop capture.
2. Tint fill: white @ 60% (light) / `#000000` @ 50% (dark).
3. A subtle top-lit gradient over the fill (white 14% to 0%).
4. A 1 px **specular rim**: gradient stroke, brightest at the top-leading corner (white @ 70%) fading to white @ 10% at the bottom-trailing; in dark mode the rim is the main edge, so keep it at 60% of those values and never remove it.
5. Soft shadow: `shadow` @ 12% (light) / none (dark), blur 24, y 8, spread -4, plus a 1 px contact shadow.
6. Interaction: pressed glass brightens about 6% and the rim intensifies; it never goes transparent.

Budget and fallback (a testable contract):

- At most **3 live blur surfaces on screen at once**, and none larger than about a third of the screen.
- **Library, Account, Payment, Settings, sheets, menus, dialogs: full glass.** Their backdrop is static or the app is not drawing.
- **Editor chrome (palette, app bar, selection bar): `tinted` glass**, no live blur: tint at about 86%, with the same rim, gradient and shadow. It still reads as glass at a glance and costs nothing per frame. Popovers and sheets opened *from* the editor may use full blur because the canvas is idle while they are open.
- `GlassSurface` takes `GlassQuality { full, tinted }`; a low-end-device flag from `lib/shared/memory/memory_pressure.dart` (or a raster-time probe) forces `tinted` everywhere. Never fade blur sigma in and out during a transition: switch tier only between screens.
- Verify on the wireless tablet (see the tablet-testing notes) with the performance overlay: no dropped frames while drawing with the pencil with the palette and app bar visible, and while a sheet is dragged.

### 6. Material theme wiring

Rebuild `app_theme.dart` so no screen needs a local style override:

- Colour scheme built from the table in section 2 (not `ColorScheme.fromSeed`, which will invent a hue).
- Page transitions: the Cupertino-based builder from prompt 24 for all platforms.
- Nav bar, tab bar, switch, slider, segmented, text field, dialog, bottom sheet, popup menu and snackbar themes all point at the tokens above. Prefer Cupertino-style widgets where the platform is iOS (switch, activity indicator, context menu, sliding segmented control) and the themed Material ones elsewhere, behind one shared widget so call sites do not branch.
- Switches: on = ink track with paper thumb (no green).

---

## Files in scope

Rewrite: `lib/app/theme/app_tokens.dart` (colours, radii, glass; motion belongs to prompt 24), `lib/app/theme/app_theme.dart`, `lib/app/theme/app_icons.dart`, `docs/design_language.md`.

New: `lib/shared/widgets/etonia_mark.dart` (mark and `EtoniaBarsLoader`), `lib/shared/widgets/dog_ear.dart`; native launch screens in `ios/Runner` and `android` (black with the white mark).

Delete: `lib/shared/widgets/ink_rule.dart`, `AppCorners`.

Touch (replace `InkRule` / `AppCorners` / colour literals / `accent` uses): `lib/features/library/{library_screen,library_dialogs,note_tab_strip,note_tabs_page,note_editor_page,note_thumbnails}.dart`, `lib/features/library/cloud/google_drive_sheet.dart`, `lib/features/editor/editor_screen.dart`, `lib/features/editor/widgets/{tool_palette,palette_button,palette_popover,editor_app_bar,editor_chrome,page_controls,ai_assistant_panel,ai_context_glow,editor_settings_sheet,export_options_sheet,ink_color_picker,color_palette_dialog,selection_action_bar,history_controls}.dart`, `lib/features/payment/{payment_page,account_panel,plans_button}.dart`, `lib/shared/widgets/processing.dart`.

Find offenders with: `grep -rnE "InkRule|AppCorners|Color\(0x|\.accent\b" lib --include=*.dart`.

## Do not

- Do not add a brand colour, a gradient on chrome, or a coloured tint on controls. Colour appears only as a user-assigned highlighter, the AI glow, and status.
- Do not use the dog-ear outside documents, or draw the E mark as decoration on every screen.
- Do not blur the editor canvas or put live blur under anything that moves during ink.
- Do not introduce colours or radii outside the token files, and do not leave both the old and new theme alive: migrate fully, then delete.

## Automated tests

- Update `test/shared/etonia_identity_test.dart` to pin AA contrast for the new pairs in light and dark (ink on paper, secondary on both surfaces, `onAccent` on `accent`); remove the `InkRule` and nib tests.
- `AppColors` contains no hue outside `highlighters`, `danger` and `success` (assert saturation of the neutral roles is near zero).
- `GlassSurface(quality: tinted)` builds no `BackdropFilter`; a screen never builds more than 3.
- `DogEar` clips only the top-trailing corner and draws the flap in the note colour (golden, light and dark).
- The grep above returns nothing outside token files.

## Acceptance

Screens eyeballed in light and dark, side by side with the app icon: Library (root, folder, empty), editor with each palette popover, AI panel, settings and export sheets, Account, Payment, dialogs. The app should look like the icon's sibling: black, white, fat and round, with colour only in the user's notes and folders. On the tablet with the performance overlay: no dropped frames while drawing with the palette and app bar visible, and while a sheet is dragged. `docs/design_language.md` is rewritten and states the 70/30 rule and the five logo facts. `flutter analyze` and `flutter test` pass. Commit separately from prompts 24 and 26.
