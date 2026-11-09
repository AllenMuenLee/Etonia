# Etonia design language

Premium minimalism, modern stationery, soft editorial. Etonia is a digital
notebook and study workspace: 75% clean contemporary minimalism, 20% refined
stationery warmth, 5% editorial character. The brief is
`implementation_prompts/39_visual_theme_redesign.md`; this file records how the
code implements it. The theme restyles; it never changes layout, icons,
behaviour, or anything a user wrote.

The logo supplies the geometry: simple shapes, controlled corners, clean
contours, strong negative space, a single restrained accent. Warmth comes from
colour temperature and type, never from textures or illustration. Where a
platform convention and the theme compete, the platform decides how things are
arranged and the theme decides how they look.

## Where it lives

Everything is centralised; features read tokens and never write a literal.

| Concern | Home |
| --- | --- |
| Colour, spacing, radii, sizes, shadows, motion, tabular figures | `lib/app/theme/app_tokens.dart` |
| `ThemeData`, `ColorScheme`, `TextTheme`, every component theme | `lib/app/theme/app_theme.dart` |
| Icons (SVG line assets, one 1.3 px stroke) | `lib/app/theme/app_icons.dart` |
| Fonts | `assets/fonts/` (Inter, Newsreader; SIL OFL, licences alongside) |

`AppColors` is a `ThemeExtension`, read with `AppColors.of(context)`. Light
and dark are two `const` instances of the same class, so the themes cannot
drift apart.

## Colour

Warm off-white chrome with white cards; one lavender accent for interactive
emphasis; layered charcoal at night. Lavender is never a large workspace
background.

| Token (`AppColors`) | Light | Dark |
| --- | --- | --- |
| `background` (backgroundPrimary) | `#FAF9F7` | `#1C1B20` |
| `backgroundSecondary` (sidebars) | `#F3F2F0` | `#1E1D22` |
| `surface` | `#FFFFFF` | `#25242A` |
| `surfaceMuted` (surfaceSecondary: fields, tracks) | `#F7F6F4` | `#2D2B32` |
| `surfaceElevated` (dialogs, popovers) | `#FFFFFF` | `#333039` |
| `textPrimary` / `textSecondary` / `textTertiary` | `#343239` / `#706D76` / `#96919C` | `#F5F2F6` / `#B7B1BD` / `#8E8795` |
| `divider` (borderSubtle) / `borderStrong` | `#E9E6E9` / `#D4CFD8` | `#3C3842` / `#56505D` |
| `accent` (brandPrimary) | `#7761A5` (see below) | `#B8A2DF` |
| `brandHover` / `brandPressed` | `#66518F` / `#574479` | `#C5B3E7` / `#A48CD4` |
| `brandSubtle` | `#F0EBF8` | `#332A40` |
| `accentText` (accent as small text) | `#66518F` | `#B8A2DF` |
| `selected` (selectedSurface) | `#EEE8F7` | `#40344E` |
| `success` / `warning` / `danger` | `#408B75` / `#B68036` / `#C45757` | `#79BFA6` / `#DDB16C` / `#DF898B` |
| `focus` (focusRing) | `#7761A5` | `#B8A2DF` |

**One deliberate deviation.** The brief's light `brandPrimary` `#8873B4` gives
white text 4.07:1 and the focus ring `#A58DCC` gives 2.9:1 on white, both under
WCAG AA, which the brief also requires. Following its rule to adjust the
pairing when a colour fails, the light brand ramp sits one step darker
(`#7761A5` / `#66518F` / `#574479`, 5.2:1 under white text) and the focus ring
uses `#7761A5`. Dark mode takes the brief's values unchanged. Pairs are pinned
by `test/app/theme_test.dart` and `test/shared/etonia_identity_test.dart`.

The page a person writes on (`writingSurface`, `pageRule`, `pageMarginRule`,
the ink palette and `highlighters`) belongs to the document, not the theme.
`pencil`, `sprout`, `lilac` and `fold` survive only as aliases of the brand and
status tokens so call sites need not change; do not add new uses.

## Type

Inter carries the whole UI. Newsreader is used only for `displaySmall`, the
large low-density titles (study overview, practice library, quiz score), and
never for buttons, navigation, labels, dense or small text, or mathematics.
Fallbacks for CJK, maths, and symbols are listed in `AppTheme.fontFallback`.

| Brief token | `TextTheme` role | Size / weight / height |
| --- | --- | --- |
| display | `displaySmall` (Newsreader), `displayMedium` (Inter, tabular) | 34 / 500 / 1.15 |
| headingLarge | `headlineMedium` | 28 / 600 / 1.20 |
| headingMedium | `headlineSmall`, `titleLarge` | 22 / 600 / 1.25 |
| headingSmall | `titleMedium` | 18 / 600 / 1.30 |
| bodyLarge / bodyMedium / bodySmall | same names | 16 / 14 / 13, w400 |
| label | `labelLarge` (14, buttons), `labelMedium` (13) | w500 |
| micro | `labelSmall` | 11 / 500 / 1.30 |

Headings are medium-weight (never w800); only sizes of 22 and up are tightened.
Numerals that change (timers, scores, prices, dates) use
`AppText.tabular`. Text scales with the system.

## Shape, borders, shadow

| Token | px | Applied to |
| --- | --- | --- |
| `AppRadii.xs` | 4 | tiny marks |
| `small` | 8 | compact controls, chips, menu rows, tooltips |
| `medium` | 12 | buttons, inputs, list tiles, snack bars |
| `large` / `glass` | 16 | cards, menus, floating panels |
| `xl` | 22 | dialogs, sheets, drawers |
| `xxl` | 28 | reserved |

No capsule buttons: pills remain only for true tracks (switch, progress,
skeleton bars). Borders are 1 px hairlines (`divider`; `borderStrong` for
secondary buttons and unchecked boxes). `GlassSurface`/`AppGlass` keep their
names but are plain opaque, bordered surfaces: no blur, no rim gradient.

Shadows are one soft neutral layer (`AppShadows`): `paper` 2/8/4%, `floating`
6/18/7%, `raised` 12/32/10% (y / blur / opacity). In dark mode they are a
whisper and surfaces separate by tone and border instead.

## Components

Primary buttons fill with `accent` (`brandHover`, `brandPressed` on hover and
press), white text, no shadow. Secondary buttons are a `surface` with a
`borderStrong` hairline. Text buttons are transparent with a 4% hover tint.
Fields are `surfaceMuted` with a hairline and a 2 px `focus` ring. Switches,
checkboxes, radios and sliders turn `accent` when on. Selection (tabs,
segments, toolbar tools, sidebar rows) is `selected` with `accentText` or
`accent` content. Default icons are `textSecondary`, active icons `accent`,
disabled `textTertiary`, destructive `danger`. Every icon is a line drawing with
one universal 1.3 px stroke (`kIconStrokeWidth`), at any size: `EtoniaIcon`
rewrites each SVG's stroke to that width, and `AppIcon` draws the Material
and Cupertino glyphs listed in `LineIcons` as SVGs (`assets/icons/system/`)
instead of fills. Icons no longer take a pencil grain (`EtoniaIcon.applyPencilTexture` is opt-in).
Sidebars and drawers sit on `backgroundSecondary`; dialogs and popovers on
`surfaceElevated`; scrims are 28% (light) / 50% (dark) neutral.

## Motion

Motion answers touch immediately, preserves spatial relationships and remains
interruptible. Movement uses the four `AppMotion` springs:

| Token | Duration / bounce | Use |
| --- | --- | --- |
| `snappy` | 300 ms / 0 | presses, selection, chips and tools |
| `smooth` | 400 ms / 0 | pages, panels, tabs, popovers and chrome |
| `bouncy` | 450 ms / 0.25 | docking and rare success emphasis |
| `sheet` | 450 ms / 0.05 | sheets and detents |

Colour and opacity changes use the duration tokens `fast` (150 ms, controls),
`standard` (220 ms, interface) and `panel` (280 ms, large panels).

Opacity and colour use `fadeIn` (160 ms ease-out), `fadeOut` (110 ms ease-in)
and `press` (instant in, 220 ms out). Reduced motion replaces travel and scale
with a 120 ms linear cross-fade. Feature code does not introduce raw animation
durations or curves.

Every transition is paced by `MotionMemory` before it plays: the first time
something is shown (a folder, a note, a dialog, a page, a loaded picture) it
plays its movement slowly and smoothly (`AppMotion.firstLookScale`); when it
has been shown before and is still in memory, the movement is dropped and it
only fades in slightly where it is (`AppMotion.glance`, 180 ms ease-out).
A revisit is never a sped-up version of the long animation. Sheets and menus,
which must rise or unfold, keep their standard timing on a revisit. Feature
code asks with `MotionMemory.instance.recall(key)` (or passes a `motionKey` /
`memoryKey` to `showAppDialog`, `showAppSheet`, `AppPageRoute` and
`LoadingReveal`). What may be shown again is kept within one `CacheBudget`: a
tenth for the folder pages (listings and thumbnails, least recently shown going
first), and the rest for one `NoteCachePool` shared by every open tab. Over its
limit the pool lets go of the pages of the note used longest ago, each page with
its PDF paper, pictures and ink paths, then what that note's pages share, then
its editor; pages on screen and unsaved work always stay. What leaves its cache
is forgotten by `MotionMemory`, and the system's low-memory signal
(`MemoryPressure`) lets go of more on top and resets `MotionMemory`.

The home page never zooms. Switching folders (`SceneCrossfade`) is a quick
cross-fade where the scenes are: the folder left fades out (`AppMotion.fadeOut`),
drawn once into a picture (`scenePicture`), and the folder's cards fade in one
after another (`StaggeredReveal`/`StaggerItem`: `staggerStep` apart after
`staggerLead`, each over `fadeIn`; a revisit runs `staggerRevisitStep` apart
with a `glance`, reduced motion fades all together). The cards fade only:
no slide or scale. Startup is the same: the wordmark fades in, the library
fades over it, then its cards one by one. Opening a note still zooms: the
note grows from 0.9 and fades in while the library grows past the viewer to
1.1 and fades out (`AppMotion.zoom`, `zoomInCurve`/`zoomOutCurve`); closing
it is the same move reversed. While it runs each scene is drawn once into a
picture (`scenePicture`) and only the pictures move; a note's heavy content
is built after the move ends, never during it. `MotionWarmUp` draws this move once out
of sight at startup so the Skia renderer has its GPU programs ready before
the first tap. Every folder's contents are read with the library, so any
folder opens on the frame it is tapped. Going fullscreen slides the top bar and
the page up together on the `smooth` spring, and leaving slides them back down;
the page is laid out once for the move, never on its frames. Pages use
Flutter's Cupertino transition on every platform, including its interactive leading-edge pop
gesture. Full-screen modals rise from the bottom; alerts fade from 1.08
scale; popovers originate at their anchor. Note tabs share one toolbar
element, handed to the tab in front; each tab keeps only its tool and fold
state (`ToolbarMemo`). Library detail columns and note tabs cross-fade rather
than slide. Only the library's cards stagger, and only by fading. Direct manipulation tracks the pointer 1:1 and springs only after
release, seeded with signed release velocity.

The plans and the account are full-screen modals (`StorePageShell`): a quiet
title with a close capsule over a centred, scrolling column. The account page
gathers profile, subscription and backup as three headed sections. On the
plans page the recommended plan is filled with the brand `accent` (on-accent
text) and the others are plain surfaces; a breadcrumb or selection is never
wrapped in a grey capsule.

The editor's settings are a popover of headed groups, each a list of rows on
one quiet surface with hairlines between them: the stylus, the assistant, then
export. A row's name is on the leading side and its value or chevron on the
trailing side. The stylus group is named for, and offers only the gestures of,
the stylus the platform pairs with (`StylusFamily`).

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
At most one soft brand-tinted ambient AI glow appears on a screen.
