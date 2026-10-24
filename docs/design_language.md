# Etonia design language

Etonia is 70% Apple platform convention and 30% its own mark. When those
directions compete, use the Apple answer: familiar navigation, grouped
backgrounds, large titles, Dynamic Type, platform scrolling, and restrained
motion. The Etonia portion comes only from `assets/icon/etonia.png`.

## The five facts in the mark

1. It is two-tone: ink and paper, without a brand hue.
2. It uses filled mass, not decorative outlines.
3. Its openings are fat, pill-ended slots.
4. Its top-trailing dog-ear makes the E a sheet of paper.
5. Its outside corners are large, even, and continuous.

These facts produce monochrome chrome, capsule controls, heavy rounded titles,
continuous corners, and one document-only dog-ear. Colour belongs to user
content. The six highlighters may mark notes, folders and tags; Lilac, Sky and
Peach may form the single active AI glow. Danger and success are status colours,
not brand colours.

## Surfaces and glass

`AppColors`, `AppRadii`, `AppBorderRadius` and `AppGlass` are the only sources
for app chrome. Feature code does not invent colour or radius literals. The
background is grouped gray in light mode and true black in dark mode. Cards and
writing pages are opaque. Floating chrome uses `GlassSurface`:

- `GlassQuality.full` clips a shared, saturated 24-point backdrop blur and is
  for static library chrome, menus, dialogs and sheets.
- `GlassQuality.tinted` has the same tint, top light, rim and shadow without a
  live filter. Editor chrome always uses this tier.
- A screen may contain at most three full glass surfaces, none larger than
  roughly one third of the screen. Memory-constrained presentation uses tinted
  glass.

Buttons, chips, switches, segmented thumbs, search fields and progress tracks
are stadiums. Text fields use radius 14, cards and popovers 22, glass bars 24,
and modal surfaces 28. Inner corners remain concentric with their outer surface.
Touch targets are at least 44 points and normally 48.

`DogEar` owns the document silhouette and flap. It appears on note thumbnails,
the document empty state, the mark and branded loading—not on general controls.
`EtoniaMark` is the scalable mark; `EtoniaBarsLoader` is reserved for launch,
import/export and AI thinking.

## Type and symbols

Body, labels and controls use the platform system face. Titles use the rounded
system face where available: large title 34/800, title 22/700, headline 17/600,
body 17, callout 16, subhead 15, footnote 13 and caption 12. Text always follows
the system text scaler. Selection changes colour, never font weight, so labels
do not jitter.

Symbols use one medium, rounded visual weight. Selected icon controls use the
filled symbol in a solid ink capsule with paper-coloured foreground. Text rows
use the neutral `selected` capsule. Section headings have no decorative mark.

## Motion

Motion answers touch immediately, preserves spatial relationships and remains
interruptible. Movement uses the four `AppMotion` springs:

| Token | Duration / bounce | Use |
| --- | --- | --- |
| `snappy` | 300 ms / 0 | presses, selection, chips and tools |
| `smooth` | 400 ms / 0 | pages, panels, tabs, popovers and chrome |
| `bouncy` | 450 ms / 0.25 | docking and rare success emphasis |
| `sheet` | 450 ms / 0.05 | sheets and detents |

Opacity and colour use `fadeIn` (160 ms ease-out), `fadeOut` (110 ms ease-in)
and `press` (instant in, 220 ms out). Reduced motion replaces travel and scale
with a 120 ms linear cross-fade. Feature code does not introduce raw animation
durations or curves.

Pages use Flutter's Cupertino transition on every platform, including its
interactive leading-edge pop gesture. Full-screen modals rise from the bottom;
alerts fade from 1.08 scale; popovers originate at their anchor. Opening a note zooms the editor out of its
card's thumbnail on a `smooth` spring while the library recedes to 0.96, and
closing shrinks it back into the card's current position; the spring keeps its
velocity if reversed mid-flight. Library detail
columns and note tabs cross-fade rather than slide. Navigation never staggers
list items. Direct manipulation tracks the pointer 1:1 and springs only after
release, seeded with signed release velocity.

The plans and the account are full-screen modals (`StorePageShell`): a quiet
title with a close capsule over a centred, scrolling column. The account page
gathers profile, subscription and backup as three headed sections. On the
plans page the recommended plan is drawn in ink (accent fill, paper-coloured
text) and the others as glass; no brand colour is used, and a breadcrumb or
selection is never wrapped in a grey capsule.

Only transform and opacity animate on large subtrees. Moving layers use a
`RepaintBoundary`; controllers use a ticker and are disposed. No interaction
waits for decorative motion, and no transition disables all input.

## Shared interaction vocabulary

`Pressable` supplies synchronous touch-down feedback and spring release for
buttons, icons, glass, cards and chips. `SelectionCapsule`, `StrokeDrawCheck`,
`RollingNumber` and `Shake` cover repeated selection, confirmation, numeric and
error behavior. Sliders and drags follow the pointer directly. Haptics are only
the semantic events in `AppHaptics`: `toolSwitch`, `tap`, `lift`, `success` and
`error`.

Content placeholders shimmer on a 1.6-second ticker. Determinate progress moves
forward with `smooth`. Tiny inline waits use the platform activity indicator.
At most one Lilac–Sky–Peach ambient AI glow appears on a screen.
