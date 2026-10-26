# Etonia

A handwriting-focused note app for Android tablets and iPads, built with
Flutter. The current build is an editor with a single pen, selectable ink
color, adjustable stroke width, adaptive One Euro stroke smoothing, an
eraser with area and stroke modes, a Select tool that lassos ink to move,
scale, rotate, copy, cut, and paste it, and an AI assistant that explains or
grades the selected ink. Notes live in memory for the session; nothing is
saved yet.

## Versions

| Item | Value |
| --- | --- |
| Flutter | 3.44.2 (stable), pinned in `.fvmrc` |
| Dart | 3.12.2 (bundled with that Flutter) |
| Android `minSdk` | 24 (Android 7.0), set in `android/app/build.gradle.kts` |
| Android `compileSdk` / `targetSdk` | 36, from the Flutter Gradle plugin |
| iOS deployment target | 14.0, set in `ios/Runner.xcodeproj` |
| Application ID / bundle ID | `com.etonia.app` |

The layout targets tablets. Widths below 600 logical pixels get a working
compact fallback, not the primary experience.

## Prerequisites

All platforms:

- Git
- [FVM](https://fvm.app/documentation/getting-started/installation), which
  installs the pinned Flutter SDK. Do not rely on a global `flutter`.
- Android Studio with the Android SDK, platform tools, and an Android tablet
  emulator image.
- JDK 17 or newer. The JDK bundled with Android Studio works.

**Android development works on Windows, macOS, and Linux.**

**iOS development and simulator builds require macOS** with Xcode, CocoaPods,
and the Xcode license accepted. Windows and Linux cannot produce or run an iOS
build locally; use the CI job or a Mac.

## Setup

Run these from the repository root. Every later command in this README is
written as `fvm flutter ...` / `fvm dart ...` so that the pinned SDK is used.

### Windows (PowerShell)

```powershell
choco install fvm          # or: dart pub global activate fvm
fvm install                # installs the Flutter version from .fvmrc
fvm flutter doctor -v
fvm flutter doctor --android-licenses
fvm flutter pub get
```

### macOS

```sh
brew tap leoafarias/fvm && brew install fvm
fvm install
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
brew install cocoapods
fvm flutter doctor -v
fvm flutter doctor --android-licenses
fvm flutter pub get
```

### Linux

```sh
curl -fsSL https://fvm.app/install.sh | bash
fvm install
fvm flutter doctor -v
fvm flutter doctor --android-licenses
fvm flutter pub get
```

## Devices

Emulators and simulators are fine for layout work. **Test pen input on
physical tablets**: emulators do not reproduce stylus sampling rate, latency,
pressure, or palm contact.

### Android tablet emulator

In Android Studio open **Device Manager > Create Virtual Device**, choose a
device from the **Tablet** category (for example Pixel Tablet), pick a recent
system image, and finish. Or from a terminal, with the SDK's `cmdline-tools`
on your `PATH`:

```sh
sdkmanager "system-images;android-36;google_apis;x86_64"
avdmanager create avd -n greatnote_tablet -k "system-images;android-36;google_apis;x86_64" -d pixel_tablet
fvm flutter emulators --launch greatnote_tablet
```

Use an `arm64-v8a` image instead of `x86_64` on Apple silicon.

### iPad simulator (macOS only)

```sh
xcrun simctl list devicetypes | grep iPad      # pick a device type
xcrun simctl create "Greatnote iPad" "iPad Pro 11-inch (M4)"
open -a Simulator
```

### Run the app

```sh
fvm flutter devices
fvm flutter run -d <device-id>
```

## Commands

| Task | Command |
| --- | --- |
| Run with account-backed AI enabled | `fvm flutter run -d <device-id> --dart-define-from-file=dart_defines.json` |
| Format | `fvm dart format .` |
| Verify formatting | `fvm dart format --output=none --set-exit-if-changed .` |
| Static analysis | `fvm flutter analyze` |
| Unit and widget tests | `fvm flutter test --exclude-tags golden` |
| Golden tests | `fvm flutter test --tags golden` |
| Update golden baselines | `fvm flutter test --tags golden --update-goldens` |
| All tests | `fvm flutter test` |
| Integration smoke test | `fvm flutter test integration_test/app_smoke_test.dart -d <device-id>` |
| Android debug build | `fvm flutter build apk --debug` |
| iOS simulator build (macOS) | `fvm flutter build ios --simulator` |
| Smoothing micro-benchmark | `fvm dart run benchmark/smoothing_benchmark.dart` |
| Eraser micro-benchmark | `fvm flutter test benchmark/eraser_benchmark.dart` |
| Selection micro-benchmark | `fvm flutter test benchmark/selection_benchmark.dart` |
| Ink, eraser, selection, and AI-notation frame timing | `fvm flutter drive --profile --no-dds --driver=test_driver/perf_driver.dart --target=integration_test/ink_performance_test.dart -d <device-id>` |

Golden baselines in `test/features/editor/goldens/` are rendered on Windows.
Regenerate and compare them on Windows (CI does this on `windows-latest`);
other hosts can differ by a few anti-aliased pixels.

CI (`.github/workflows/ci.yml`) runs formatting, analysis, tests, golden
tests, an Android debug build, and an unsigned iOS simulator build on every
push and pull request. It needs no secrets: no test calls the AI service.

## Project layout

```
lib/
  main.dart                 entry point
  app/                      app widget, theme, design tokens
  features/library/         home screen, note storage, autosave
  features/editor/          editor screen
    widgets/                app bar, page frame, palette, popovers,
                            page controls, selection actions, clipboard
                            shortcuts, AI panel
    page/                   pages, page setup, backgrounds, page viewport
    ai/                     selection image, AI client, Gemini client,
                            assistant state, AI configuration
    ink/                    samples, smoothing, strokes, erasing, selection,
                            shape recognition, canvas
  shared/layout/            breakpoints
test/                       unit, widget, and golden tests
  helpers/                  viewport, editor, and AI test helpers
integration_test/           on-device smoke test and profiling harness
benchmark/                  smoothing, eraser, and selection micro-benchmarks
```

Test helpers in `test/helpers/pump_app.dart` pump the app at the three
reference viewports: `390 x 844` (compact), `800 x 1280` (8-inch tablet
portrait), and `1194 x 834` (11-inch tablet landscape).

## Design system

Tokens live in `lib/app/theme/app_tokens.dart`: semantic colors (`AppColors`,
a `ThemeExtension`), spacing on a 4 px grid, three corner radii, control
sizes, two shadow styles, and motion durations. Feature widgets read these
rather than literals.

Breakpoints are width-based and defined once in
`lib/shared/layout/breakpoints.dart`:

| Class | Width | Palette inset |
| --- | --- | --- |
| compact | below 600 | 4 px |
| medium | 600-839 | 8 px, dense buttons |
| expanded | 840 and up | 24 px, centered title |

The tool palette floats centered across the top of the page by default.
Drag it by its grip to any edge: it docks against the nearest one when let
go, lying across the top and bottom and down the sides, and its panels open
toward the page. Where it sits carries from note to note for the session.

The page spans the whole area below the top bar, edge to edge, and the top
bar spans the whole width; only the AI panel, when open beside the editor,
takes space from the page. The palette floats over the page, and the page's
own floating bars (selection actions, Paste) move clear of it.

## Tabs and split view

One top bar spans the window: back, the open notes' tabs, and Settings.
Hold a tab and drag it to the left or right of the window to show its note
beside the one shown. Each pane then has tabs of its own over it, while the
bar and Settings stay single and follow the pane last pressed (outlined).
Pull the handle between the panes to resize them, or all the way to an edge
to put a pane away. Two panes at most.

## Undo and redo

Undo and Redo hang from the top bar at the left, on one card with find and
the page controls, and answer to
`Ctrl`/`Cmd`+Z, `Ctrl`/`Cmd`+Shift+Z, and `Ctrl`+Y. History is per page and
per session, kept by `InkController`: every committed change (a stroke, a
shape, a whole erase gesture, a transform, a cut, a paste, an inserted
image, an AI notation) is one step, at most `historyLimit` (100) deep. A
step is a snapshot of the page's strokes and images, which are immutable and
shared, so it costs one list each. Undo and redo drop the selection, bump
the document revision (so autosave and AI staleness checks follow), and do
nothing while a gesture is in progress. Page add, delete, and setup changes
are not part of the history.

## Handwriting

Pointer events flow through these steps:

1. `InkCanvas` listens to raw pointer events (not gesture callbacks) and turns
   each into a `RawInkSample`: position in page-local logical pixels, the
   platform timestamp, and the device kind.
2. `InkController` owns the active stroke and the completed strokes. Only one
   pointer writes at a time; others are ignored while a stroke is active.
3. `OneEuroSmoother` (pure Dart) filters each sample as it arrives.
4. Each filtered point extends a cached `Path` by one segment. Two painters,
   each behind a repaint boundary, draw the active stroke and the completed
   strokes; a pointer move repaints only the active layer and rebuilds no
   widgets.

### Pen settings

The pen panel shows the ink color and width; **Advanced** folds out the
rest, all on by default:

| Setting | Effect |
| --- | --- |
| Tip sharpness | how sharply both ends of a stroke taper |
| Pressure sensitivity | how much stylus pressure widens or narrows the line |
| Stroke stabilization | how strongly the smoother below evens the line; 50% is its configured tuning |
| Draw and hold for shapes | whether holding still at the end of a stroke makes it a shape |

A tapered or pressure-sensitive stroke keeps a width factor per point
(`Stroke.widths`) and is painted as one filled outline; erasing, moving,
copying, saving, and PDF export all keep its widths.

### Smoothing

The smoother implements the [One Euro filter](https://doi.org/10.1145/2207676.2208639),
an adaptive first-order low-pass filter designed for noisy interactive input.
At low pen speeds its low cutoff suppresses jitter. The cutoff rises with the
filtered pen speed to reduce lag during fast handwriting. The actual interval
between pointer samples is part of the filter coefficient, so irregular event
delivery does not change the time response. A single 2D speed controls both
axes, avoiding direction-dependent distortion. When the stroke ends, a short
tail brings the visible endpoint to the raw endpoint.

Everything is tunable in `SmoothingConfig`
(`lib/features/editor/ink/smoothing_config.dart`):

| Value | Default | Meaning |
| --- | --- | --- |
| `minCutoff` | 1 Hz | base cutoff; lower values suppress more low-speed jitter |
| `beta` | 0.02 Hz/(px/s) | raises the cutoff with speed to reduce fast-motion lag |
| `derivativeCutoff` | 1 Hz | cutoff used to stabilize the speed estimate |
| `minDtSeconds` | 0.001 | lower clamp on time between samples |
| `maxDtSeconds` | 0.1 | upper clamp on time between samples |
| `maxFinalizationPoints` | 8 | cap on end-of-stroke tail points |
| `finalizationSpacing` | 2 px | target distance between tail points |
| `endpointTolerance` | 0.01 px | no tail if the output is already this close |

**Tuning note.** Start with `beta = 0`, adjust `minCutoff` until a stationary
or slowly moving pen is stable, then raise `beta` until fast strokes feel
responsive. `derivativeCutoff` normally stays at the published 1 Hz default.
The checked-in defaults are tuned for logical-pixel tablet coordinates and
should still be validated on physical hardware.

### Known limitations

- Flutter delivers one sample per pointer event. Android's batched historical
  samples arrive as separate events; iOS coalesced touches are not exposed to
  the framework.
- There is no platform palm rejection. A palm that lands before the pen
  becomes the writing pointer.
- Tilt is ignored. Pressure is read only from a stylus that reports a
  pressure range; fingers and mice draw at neutral pressure.
- Rotating the device mid-stroke ends that stroke. Existing ink keeps its
  page coordinates and is clipped if the page becomes smaller.

### Hold to shape

Keep the pen on the page and hold it still at the end of a stroke: after
`holdDuration` the stroke is replaced by a clean version of the shape it was
meant to be, with the same color and width. Lifting without holding keeps the
freehand stroke. Nothing is converted when no shape fits well, so handwriting
and scribbles are left alone.

After the snap, keep the pen down to adjust the shape: moving it scales and
turns the shape about its pivot, a closed shape's center or an open shape's
start, so the point the pen held follows the pen. Turns under 4° and scales
within 2% of 1 are ignored, so a shape that snapped straight stays straight.
The width never changes. The shape is a preview until the pen lifts, and is
then committed as one change.

`ShapeRecognizer` (`lib/features/editor/ink/shape_recognizer.dart`, pure Dart)
resamples the stroke to evenly spaced points and finds corners where it turns
sharply. A nearly straight stroke is a line. A closed stroke with three or
more corners is a polygon, beautified to the most specific shape that still
fits: star (outline or pentagram), rectangle, square, rhombus, regular n-gon,
or a plain polygon with straight edges; with fewer corners it is an ellipse or
a circle. An open stroke whose long first segment ends in a short head that
turns back is an arrow; any other open stroke becomes whichever of polyline,
arc, sine wave, and Archimedean spiral fits best. Lines, rectangles, ellipse
axes, and wave axes snap to horizontal or vertical when close.

Every candidate is scored the same way: the root-mean-square distance between
stroke and shape, both ways, divided by the stroke's size. Tuning lives in
`ShapeConfig` (`lib/features/editor/ink/shape_config.dart`):

| Value | Default | Meaning |
| --- | --- | --- |
| `holdDuration` | 550 ms | how long the pen must stay still |
| `holdSlop` | 6 px | moving further restarts the hold |
| `minStrokeLength` | 24 px | shorter strokes never convert |
| `resampleCount` | 64 | points the stroke is resampled to |
| `closedGapFraction` | 0.15 | a gap this fraction of the length still closes |
| `cornerAngle` | 34° | turn that counts as a corner |
| `lineTolerance` | 0.045 | a line strays at most this fraction of its length |
| `fitTolerance` | 0.028 | other shapes' fit error, as a fraction of the size |
| `maxPolygonSides` | 12 | largest polygon recognized |
| `maxPolylineSegments` | 8 | longest open polyline recognized |
| `axisSnapAngle` | 7° | snapping to horizontal or vertical |
| `circleRoundness` | 0.85 | minor/major radius above which an ellipse is a circle |
| `rightAngleTolerance` | 14° | rectangle corners |
| `equalSideTolerance` | 0.18 | sides this close count as equal |
| `regularAngleTolerance` | 18° | regular polygon and star angles |
| `minSpiralTurns` | 1.25 | turns a spiral must wind |
| `minSineCrossings` | 2 | axis crossings a sine wave must make |
| `arrowHeadAngle` | 30° | angle between shaft and barb |
| `maxPoints` | 200 | points in any generated shape |

## Pages

A note is a list of pages shown as one continuous column: each page sits
directly below the one before, with a hairline seam between them. The current
page is the one a pointer last went down on, or, after scrolling, the one in
the middle of the area; selection, Paste, and the page panel act on it. The
app bar shows `current / count`, which opens the page panel; on tablets
previous, next, and add-page buttons sit beside it and scroll to their page.
The panel adds and deletes pages and sets the current page's size and
background. When the current page changes, the page left ends its gesture and
drops its selection, and the clipboard comes along. One pointer owns the
whole note at a time, so a palm on one page cannot let the pen write on
another.

| Size | Shown |
| --- | --- |
| Fit to screen (default) | as big as the writing area |
| A4, US Letter (portrait or landscape), Square | scaled to the area's width |
| Infinite | at scale 1, grows right or down when ink comes within `edgeMargin` of an edge; the column scrolls sideways when it is wider than the area |

Backgrounds are Blank, Lined, Grid, and Dotted, painted under the ink in page
coordinates. A scrollable page scrolls with two fingers, a mouse wheel, or a
trackpad, never with one finger or the pen; a second finger that starts a
scroll drops the stroke the first finger began. Spacings and growth are in
`PageConfig` (`lib/features/editor/page/page_setup.dart`): `lineSpacing` 32,
`gridSpacing` 24, `dotSpacing` 24, `edgeMargin` 96, `growthFraction` 0.5,
`minGrowthStep` 256, `maxExtent` 20000.

## Library

The app opens to the library: folders first, then notes, sorted by last
modified, date created, or title, as a grid of cards with first-page
thumbnails or as a list. A sidebar (a drawer on phones) shows the folder
tree: folders nest to any depth, each in its own color, and fold open under
their parents; a breadcrumb trail leads back up. New note first asks for the
note's template, its page size and paper. Each item's menu (also on long
press) renames, moves, duplicates (notes), and deletes, with confirmation;
a folder's also makes a subfolder and changes its color. Search matches
titles in every folder.

Notes are stored under the app's documents directory by `FileNoteRepository`
(`lib/features/library/`): `greatnote/library.json` indexes folders and notes,
and `greatnote/notes/<id>.json` holds each note's pages and strokes. Both carry
a schema number; a newer one is refused rather than misread. Every file is
written to a temporary file and renamed into place. Only a stroke's color,
width, and filtered points are stored, so a loaded stroke has no raw samples.

An open note saves itself 800 ms after its ink, pages, or page setups change,
waits for a gesture in progress to end, and saves again when leaving the
editor or when the app is paused. The editor's back arrow returns to the
library, and its title renames the note.

### Known limitations

- Saving encodes JSON on the main isolate; very large notes may cause a short
  pause.
- Thumbnails are painted from each note's content and cached for the session
  only.
- There is no live sync: Google Drive backups run on a schedule or when
  asked, and another device's backup is brought in when the app opens (see
  below).

## Google Drive

The cloud button in the library bar (tooltip **Google Drive**) opens a sheet
to connect a Google account, back the library up, restore it, and import the
user's GoodNotes folder. Everything lives in `lib/features/library/cloud/`;
sign-in and Drive REST v3 calls sit behind `GoogleDriveClient`, so tests use
`FakeGoogleDriveClient` (`test/helpers/google_drive_fakes.dart`) and never
touch the network.

**Backup** (`GoogleDriveBackupService`) writes to `My Drive/Etonia` (a
restore also finds an older `Greatnote Backup` folder): `manifest.json` (schema, `exportedAt`, folder and note counts, every folder
and note entry, and the SHA-256 and Drive file of each note's content and
assets) and a `notes/` folder of content-addressed files. Files already in
Drive with the same hash are not uploaded again; the manifest is replaced
last, so an interrupted backup leaves the previous one whole, and files no
manifest refers to are moved to the Drive trash. **Restore** downloads and
hash-checks everything before it changes the library. *Add to library*
reuses folders with the same name and place and skips notes whose title is
already in their folder; *Replace library* moves the current library to
Recently Deleted.

**Automatic backup** (`AutoBackupScheduler`) backs up every 15 minutes by
default while the app runs, once Drive has been connected on the device; the
sheet's *Back up automatically* menu picks 5 or 30 minutes, 1 or 4 hours, a
day, or off. It runs only when the library has changed, restores the Google
session silently or skips the turn, and takes turns with backups and
restores started from the sheet.

**Catching up with other devices.** Each backup records the installation
that made it (`deviceId` in the manifest). When the app opens or comes back
to the foreground, `pullIfChangedElsewhere` reads the manifest and, if
another device made it and it has not been brought here yet, brings its
changes in without sending anything: notes made, edited, renamed, moved,
deleted or deleted for good there. Every backup does the same before it
uploads, so an older copy on one device never replaces newer work in Drive.
A note changed on both devices since they last synced keeps this device's
version, and the other comes in beside it as "… (from another device)". A
note open in the editor is left alone and brought on the next launch.

**Goodnotes import** (`GoodnotesDriveReplicator`) looks for non-trashed
folders named GoodNotes in any case, asks which one to use when there are
several, rebuilds its subfolder tree breadth first directly in the library
root, and imports each `.goodnotes` notebook and PDF (with Goodnotes ink
recovery) into its folder. Other files are listed as skipped. Running it
again reuses the folders and skips files that have not changed since;
which Drive file became which note is kept in `greatnote/cloud_state.json`.

### Setting up Google sign-in

Sign-in uses `google_sign_in` with the scopes `drive.readonly` (to find the
GoodNotes folder) and `drive.file` (to write the backup). In a Google Cloud
project with the Google Drive API enabled, configure the OAuth consent screen
and create OAuth clients:

- **Web application**: its client ID goes in `GOOGLE_OAUTH_SERVER_CLIENT_ID`.
  Android needs it.
- **Android**: package `com.etonia.app` and the SHA-1 of your signing key
  (`cd android && ./gradlew signingReport`). Its client ID can be recorded in
  `GOOGLE_OAUTH_ANDROID_CLIENT_ID` (Google Play Services matches the app by
  package name + SHA-1).
- **iOS**: bundle ID `com.etonia.app` of the Runner target. Its client ID goes
  in `GOOGLE_OAUTH_IOS_CLIENT_ID` (or `GOOGLE_OAUTH_CLIENT_ID`), and its
  *reversed* client ID (`com.googleusercontent.apps.…`) must be added to
  `ios/Runner/Info.plist` as a URL scheme under `CFBundleURLTypes`.

Then put the IDs in `dart_defines.json` and run with
`--dart-define-from-file=dart_defines.json` (as `tool/run.sh` does):

```json
{
  "GOOGLE_OAUTH_IOS_CLIENT_ID": "<ios client id>.apps.googleusercontent.com",
  "GOOGLE_OAUTH_ANDROID_CLIENT_ID": "<android client id>.apps.googleusercontent.com",
  "GOOGLE_OAUTH_SERVER_CLIENT_ID": "<web client id>.apps.googleusercontent.com"
}
```

While the consent screen is in testing, only listed test users can sign in.

## Eraser

The palette has one eraser beside the pen. Pressing it selects it; pressing
it again opens its options: the mode, and the size used in area mode. An
inverted stylus erases with the current eraser settings whichever tool is
selected. The size is on screen: zooming in does not make the eraser bigger.

| Mode | Effect |
| --- | --- |
| Area | removes only the ink under the eraser; crossed strokes are cut |
| Stroke | removes every stroke the eraser touches, whole |

Erasing is vector-based: it edits the stroke collection, it does not paint
over ink. An eraser pointer event takes this path:

1. `InkCanvas` sends the position to `InkController.startErase`, `eraseTo`,
   or `endErase`. Writing and erasing share the single active pointer.
2. Between two samples the eraser covers a capsule: every point within its
   radius of the segment joining the two positions, so a fast flick cannot
   skip over ink. The controller skips every stroke whose cached bounding
   box misses the capsule's box.
3. `EraseGeometry` (pure Dart) tests the remaining strokes. A stroke of
   width `w` is treated as its centerline, so in area mode everything within
   `size / 2 + w / 2` of the eraser's path is removed, and in stroke mode a
   stroke is hit within `strokeHitRadius + w / 2`. Cut points are computed
   on the crossed segment, which leaves each piece's round cap tangent to
   the eraser's edge.
4. The pieces replace the original stroke at its index, in order, so
   stacking does not change. The completed-strokes layer repaints only if
   the collection changed; the eraser outline has its own layer.

A piece is a new `Stroke` whose `source` is `StrokeSource.derived`. It keeps
the original style and the original filtered points plus the cut points; it
is never smoothed again, and it has no `rawSamples`, because raw samples do
not map onto filtered points.

The limits live in `EraserConfig`
(`lib/features/editor/ink/eraser_settings.dart`):

| Value | Default | Meaning |
| --- | --- | --- |
| `minSize` | 8 px | smallest area eraser diameter |
| `maxSize` | 80 px | largest area eraser diameter |
| `defaultSize` | 24 px | area eraser diameter on launch |
| `strokeHitRadius` | 6 px | eraser radius in stroke mode |
| `minPieceLength` | 0.01 px | shorter leftover pieces are discarded |

`EraseGeometry.cutTolerance` (0.001 px) is the length below which a removal
is skipped and a cut point snaps to a neighboring vertex. It is what makes
erasing the same place twice a no-op.

### Known limitations

- Each erase gesture is one `EraseGesture` with its own `id`, and one step
  of undo history.
- The eraser outline shows only while a pointer is down; there is no hover
  preview.
- Every eraser move that removes ink repaints the whole completed-strokes
  layer. On a dense page that raster work, not the erase geometry, is the
  cost that grows.
## Selection

The palette has one Select tool beside the eraser. With it, a drag on empty
paper selects every stroke whose ink overlaps the region drawn, whole:

- A nearly straight drag, in any diagonal direction, selects the rectangle
  with the drag's start and end as opposite corners. A drag counts as
  straight while its path is no longer than `rectangleMaxDetour` times the
  distance between its ends.
- Anything more wandering is a freeform lasso. It selects only if it ends
  nearly where it began: the gap between its ends must be within
  `lassoClosingFraction` of the length drawn. A loop left open selects
  nothing.

The outline is dashed while it is drawn. A freeform loop is shown as drawn,
with no line added back to its start.

Paste is offered in two places: holding a pointer still on the page for
`pasteHoldDuration` shows a Paste button there, which pastes centered on
that point, and pressing Select again opens its options, which hold Paste
too.

A selection gets a frame with a handle at each corner and a rotation handle
above its top edge, and a small bar with Copy, Cut, Duplicate, and AI, which
ends level with the frame's top-right corner. Duplicate places an independent
copy one paste offset away and selects it without replacing the clipboard. A
pointer going down
does one thing, chosen in `SelectionFrame.hitTest`:

1. on a handle, within `handleHitRadius`: the nearest one, with ties going
   to the rotation handle and then to the earlier corner (top-left,
   top-right, bottom-right, bottom-left);
2. elsewhere on or inside the frame, ink included: a move;
3. anywhere else: a new selection drag, which replaces the selection when
   it ends. A tap has no area, so it clears the selection.

Inside a frame smaller than its handle targets, a handle wins only where
the pointer is at least as near to it as to the frame's center, so a small
selection can still be moved.

Selecting, like erasing, is vector-based and never smooths or rasterizes
ink:

- **Overlap.** `LassoRegion` (pure Dart) closes the region from its last
  point to its first. A stroke of width `w` is selected when its centerline
  comes within `w / 2 + geometryTolerance` of the lasso's outline, or lies
  in its interior. That covers a segment crossing the lasso between two
  stored points, wide ink that only grazes it, and a lasso drawn inside
  wide ink. A dot is the disc around its point. Strokes whose cached bounds
  miss the lasso's bounds are skipped without reading their points.
- **Even-odd.** The interior is decided by an even-odd crossing count in
  `LassoRegion.containsPoint`, not by a platform path: an area the lasso
  wraps twice is outside.
- **Transforms.** `SelectionTransforms` (pure Dart) derives each preview
  from where the pointer went down and where it is now, never from the
  previous preview, so the result does not depend on the sample rate. A
  move adds the pointer's delta. A corner scales uniformly about the
  opposite corner by the ratio of the pointer's distances from it, clamped
  to `minScale`..`maxScale`, and multiplies stroke widths by the same
  factor; pen width limits do not apply. The rotation handle turns the ink
  about the frame's center, leaving widths alone. The frame keeps its
  orientation: it turns with the ink instead of becoming a new upright box.
- **Preview and commit.** Selected strokes are painted by the selection
  layer for as long as they are selected. A preview draws their cached
  paths through the transform, so a pointer move repaints that layer only
  and builds no path. Lifting the pointer replaces each selected stroke at
  its own index with one built from its transformed points, once. A gesture
  that ends where it began changes nothing.
- **Result.** A transformed or pasted stroke is `StrokeSource.derived`: it
  keeps its color, has its filtered points transformed as they are, and has
  no `rawSamples`.

Copy and Cut put a snapshot of the selected strokes and images on an in-app
clipboard that lasts for the editor session and survives tool changes. On a
PDF-backed page, the lasso also selects the rectangular PDF-paper region
inside its bounds. Copy or Cut rasterizes that region on demand and adds it
to the clipboard as an ordinary image; the source PDF paper is never
modified. Pasting therefore produces a movable, scalable image excerpt,
along with any ink or placed images selected over it. Paste adds independent
copies above the existing ink and selects them. From the Select options or
the keyboard, the first paste lands
`pasteOffset` from the copied ink and each further paste another
`pasteOffset` on; a new Copy or Cut starts the cascade over. A paste from a
hold lands where the pointer was held and leaves the cascade alone. `Ctrl` or `Cmd` with C, X, and V do the same while the editor
has keyboard focus, and leave a focused text field's own shortcuts alone.
Nothing is written to the system clipboard.

Leaving the Select tool commits a transform in progress and clears the
selection. Erasing, including with an inverted stylus while Select is
active, clears it too.

The values live in `SelectionConfig`
(`lib/features/editor/ink/selection_config.dart`):

| Value | Default | Meaning |
| --- | --- | --- |
| `minLassoPointSpacing` | 2 px | distance before another lasso point is stored |
| `geometryTolerance` | 0.001 px | inclusive slack for overlap, zero-area, and identity checks |
| `handleVisualRadius` | 6 px | painted radius of the handles |
| `handleHitRadius` | 24 px | grab radius of a handle: a 48 px target |
| `rotationHandleOffset` | 32 px | from the frame's top edge to the rotation handle |
| `minScale` | 0.1 | smallest scale in one gesture |
| `maxScale` | 10 | largest scale in one gesture |
| `pasteOffset` | (24, 24) px | added by each paste in a cascade |
| `minStrokeWidth` | 0.01 px | scaling down stops where a stroke would get thinner |
| `maxCoordinate` | 1,000,000 px | a transform or paste that takes the frame further out is refused |
| `rectangleMaxDetour` | 1.25 | a drag this close to straight selects a rectangle |
| `lassoClosingFraction` | 0.2 | largest gap, as a share of its length, for a lasso to count as closed |
| `lassoDashLength` | 6 px | dash length of the outline while it is drawn |
| `lassoDashGap` | 4 px | gap between those dashes |
| `pasteHoldDuration` | 500 ms | how long a still pointer is held before Paste is offered |
| `pasteHoldSlop` | 10 px | how far a held pointer may drift |

### Known limitations

- A committed transform, a cut, and a paste each replace the stroke
  collection once and notify once, and each is one step of undo history.
- Scaling is uniform only, and there is no skew, mirror, or angle snapping.
- Transforms use one pointer; there is no pinch or two-finger rotation.
- Strokes are selected whole; a lasso cannot take part of one.
- Selected strokes are drawn above unselected ones while they are selected.
  Their place in the document does not change, and they drop back when the
  selection is cleared.
- The clipboard is in memory, for this session, and private to the app.

## AI assistant

A selection's bar ends with an **AI** button. Pressing it opens a chat panel
about the selected ink. Nothing is sent until you press **Explain this**,
**Grade this**, or Send.

| Width | Panel |
| --- | --- |
| medium and expanded | 360 px beside the editor, on the right to begin with; the page and palette move over, so nothing is covered |
| compact | a modal sheet from the chosen edge, at most `min(360, 88% of the width)`, over a barrier that closes it |

**Panel side** in the editor's **Settings** chooses the screen's physical
left or right edge, whatever the text direction. The side, the conversation, the
unsent draft, and the captured image live in the editor's state: they
survive rotation, breakpoint changes, and closing the panel. Pressing AI
again on the same ink brings the conversation back; pressing it on other
ink starts a new one. If the selection changes while the panel is open, the
conversation and its image stay as they are and the panel offers **Use
current selection**, which starts over with the new ink.

Enter starts a new line in the message field; `Ctrl` or `Cmd` with Enter
sends. Escape closes the panel.

The **Enable notation** switch is in the editor's **Settings** and is off
when an editor session starts. When enabled,
the assistant may add handwritten labels, arrows, circles, checks, and other
short teaching marks directly to the vector note. The switch survives panel
close/reopen, side changes, and rotation in that editor session. Turning it on
does not send anything; it affects only messages submitted while it is on.
Turning it off while a request is running revokes permission to apply that
request's drawing.

**Enable animation** is a separate opt-in setting. With notation enabled and
animation disabled, every accepted drawing is static. With both enabled, the
model may add timing only when motion carries explanatory meaning; ordinary
labels and formulas remain static. These preferences and the panel-side
choice stay out of the chat panel so the conversation remains uncluttered.

### What is sent

With Notation off, only an image of the selected strokes plus conversation
text is sent. Pressing AI copies the selected strokes' points, widths,
resolved colors, and order
into an immutable snapshot, and `SelectionImageRenderer`
(`lib/features/editor/ai/selection_image_renderer.dart`) draws that snapshot
off screen with `dart:ui`:

- the crop is the union of the strokes' rendered bounds plus 12 logical
  pixels on every side;
- it is drawn at 3 physical pixels per logical pixel, or less when that
  would make a side longer than 2048 pixels; never more;
- the background is the writing surface's color in the theme at the moment
  of capture, opaque, and the ink uses that theme's colors. A later theme
  change does not alter an open conversation's image;
- strokes are painted in document order by the same function the editor's
  layers use: round caps and joins, and a disc for a dot;
- unselected ink, the selection frame, its handles, and the action bar are
  never drawn;
- a selection that is empty or not finite is refused with a message, before
  any bitmap is allocated.

The panel's preview shows those same PNG bytes. They are held in memory for
the conversation and written nowhere.

With Notation on, the app still sends one tight, lossless selection crop. A
coordinate grid is composited onto that crop so marks can be placed accurately.
The rest of the page is represented only by compact numeric metadata: page size,
focus bounds, simplified selected ink, nearby occupied boxes, and available blank
areas. The full note and PDF are not uploaded.

The quick actions send fixed prompts, which are in `AiPrompts`
(`lib/features/editor/ai/ai_config.dart`) with the system instruction. The
transcript shows a quick action under its short label.

### Service

Requests go through the authenticated Supabase AI function, which routes the
chosen alias to its server-configured OpenAI, Anthropic, or Gemini model. The
provider endpoint keeps no app state, so each answer carries the selected crop
and a bounded, compact transcript. With Notation enabled, a small first pass
answers and returns `null`, `static`, or `animated`. Only the latter two cause a
second pass containing the large drawing grammar, response schema, and page
metadata. The first pass reads the clean crop; the second uses its gridded
variant for precise coordinates. A text-only answer therefore pays for neither
the notation prompt nor the grid image.

The service intermittently answers 500 or 503 at once, having generated
nothing; those are sent once more after a second. Nothing else is retried
automatically, because a retry could be another billable generation. A
failed message stays in the conversation with a **Retry** button; sending a different message instead replaces it. Timeouts,
connection failures, HTTP errors, blocked or empty answers, and unreadable
responses each have their own message. No message, and nothing logged,
contains the key, the image, the chat, or a response body. An answer that
arrives for a conversation that has since been replaced is dropped.

Every successful model answer is JSON matching a closed, versioned schema:

```json
{
  "version": 2,
  "message": "Readable Markdown answer",
  "notation": null
}
```

When enabled, `notation` may instead hold a label and 1–48 items. The model
says what to draw; Etonia draws it. Every item has a palette ID and a
1–20 logical-pixel pen width, and is one of:

| `type` | The model gives | Etonia draws |
| --- | --- | --- |
| `text` | the words, the top-left corner, and the capital height (8–120 px) | them in its built-in single-stroke handwriting font (letters, digits, punctuation, and common math symbols such as `× ÷ √ π ² ≤ → ✓`) |
| `plot` | the box on the note, the x range and an optional y range, whether to draw `axes` and number them with `ticks`, and `children` placed in the plot's own units (below) | a coordinate plane: axes through 0 (or along the box edge), round tick numbers, and every child mapped into the box and cut off at its edge |
| `graph` | a formula in x (`x^2 - 2x + 1`, `2 sin(x)`), where it starts and ends (`x_from`, `x_to`), an optional y range, the box on the note, and whether to draw axes | the curve, worked out at 240 points, broken where it is undefined or jumps, with axes in graphite; a plot is preferred |
| `line` | two points, a `line_style` (`solid`, `dashed`, `dotted`), and an `arrow` (`none`, `start`, `end`, `both`) | the line, cut into dashes or dots, with solid arrowheads sized to the pen |
| `shape` | `ellipse`, `circle`, `rectangle`, `triangle`, `triangle_down`, `triangle_left`, `triangle_right`, `right_triangle`, `diamond`, `pentagon`, `hexagon`, or `star`, the box it fills, and a `line_style` | the closed outline; directional triangles put their apex on the named edge, while `right_triangle` has a right angle; an `ellipse` around something circles it |
| `path` | key points (2–64) and, for each gap between neighbours, `straight` or `curve`; `closed` joins the last back to the first; a `line_style` and an `arrow` as for a line | straight lines, or a smooth centripetal Catmull–Rom curve through the points, with arrowheads that follow the curve |
| `stroke` | 1–128 points | one pen stroke through them, for small marks |

A plot's children use the graph's own x and y, never note coordinates, so
the model does no mapping arithmetic. Each has an ink; the plot's width is
theirs too:

| Child | The model gives | Etonia draws |
| --- | --- | --- |
| `function` | a formula, an optional `line_style`, and optional `marks`: `roots`, `extrema`, `y_intercept` | the curve, and for each mark the points it finds (`plot_features.dart`: sign changes refined by bisection, turning points by golden-section search, breaks such as `1/x` ignored), each dotted and labelled with its coordinates |
| `intersections` | `of`, two formulas | a labelled dot wherever their curves meet |
| `point` | `x`, `y`, an optional `label` | a dot, with the label beside it |
| `segment` | `from`, `to`, an optional `line_style` and `arrow` | the line, cut at the box |
| `label` | `x`, `y`, `text` | the text just above and right of the point |
| `shade` | a formula, an optional `base` (y = 0 by default), `from`, `to` | vertical hatching between the two curves |

The labels Etonia writes itself, tick numbers and marked coordinates, are
moved back onto the paper if they would run off it. A plot holds at most 16
children, and each mark labels at most 8 points.

```json
{
  "label": "Graph of y = x² - 1",
  "coordinate_space": "note_normalized",
  "items": [
    {"type": "plot", "left": 0.55, "top": 0.1, "right": 0.9, "bottom": 0.45,
     "x_from": -3, "x_to": 3, "y_from": -2, "y_to": 8, "axes": true,
     "ticks": true, "ink": "graphite", "width": 2, "children": [
       {"type": "function", "formula": "x^2 - 1",
        "marks": ["roots", "extrema"], "ink": "blue"},
       {"type": "label", "x": 2.2, "y": 6, "text": "y = x² - 1",
        "ink": "blue"}
     ]}
  ]
}
```

Formulas are read by a small arithmetic parser (`notation_formula.dart`):
numbers, `x`, `+ - * / ^`, parentheses, `pi`, `e`, and one-argument
functions such as `sin`, `sqrt`, `ln`, and `abs`. It never runs code. The
app validates the provider output again locally. A notation that breaks the
contract, such as unknown text characters or a formula that does not read,
is dropped whole and the text answer kept. Model turns are replayed to the
stateless service using this canonical JSON; local application state is never
sent.

Notation coordinates address the whole writing surface: `(0, 0)` is its
top-left and `(1, 1)` is its bottom-right. Etonia maps them with
`pageX = x * width` and `pageY = y * height`, without smoothing or clamping.
If the mode was disabled, the document or surface changed, a gesture is
active, or any trace falls outside the note, the whole notation is rejected
and the text answer is retained. Otherwise all traces are appended in one
`InkController` mutation and one completed-ink notification. They are normal
derived vector strokes and can be selected, transformed, copied, cut, and
erased.

### Timed notation playback

A notation may give items a `step` only when **Enable animation** is on.
The model is encouraged to animate, but only what moves or changes: current
or another flow travelling along a path, a body or wave changing position,
forces acting in turn, the stages of a mechanism or causal sequence, atoms
combining, separating, or rearranging. Fixed labeling is never animated:
labels, titles, axes, ticks, legends, formulas, worked text, pointer arrows,
and the figure the motion happens on carry no step. In a timed notation an
item without a step is fixed: it is shown whole from the start of every loop
and never redrawn, while the stepped items play over it. A notation with
nothing that moves has no steps at all and appears immediately.

A step is an integer from 1 through 24. The model gives only the order:
items are drawn lowest step first, and items that share a step are drawn
together. Steps need not be consecutive. Etonia works out the times
itself (`AiNotationTimeline.fromSteps`): each item takes about as long as a
hand would to draw it (about 140 ms a character of text, about 1.5 s for a
line across the whole note, longer for a plot with more children), each step
lasts as long as its slowest item, steps are 250 ms apart, and the loop holds
600 ms before it repeats. An animation that would run past 12000 ms is sped
up to fit; fixed items do not count toward it. If any step given is not an
integer in range, Etonia keeps the validated drawing but shows it
immediately.

Etonia lays each item out once into its final page-local vector strokes,
then distributes its time span over those strokes at a constant pen speed.
The final strokes are appended atomically before playback starts. While they
are being revealed, the completed-ink layer omits those exact stroke objects
and a clipped animation layer paints their time-dependent prefixes. A partial
segment is linearly interpolated from elapsed ticker time, so missed frames
and 60, 90, or 120 Hz displays reach the same geometry. Playback frames do
not mutate the document, increment its revision, or notify completed-ink
listeners. At the end of the loop the elapsed phase wraps to zero and the reveal
repeats continuously, like a GIF, without recommitting the strokes. Closing
the AI panel does not stop or finish it; playback belongs to the note and
continues across the resulting canvas resize. The chat shows no drawing
status or completion button.

A pointer down or any ink mutation finishes the reveal first, then preserves
the initiating input. Turning **Enable animation** off also shows the current
drawing whole. Disabling future notation or merely closing the AI panel does
not. When the platform requests reduced motion, the same final strokes are
committed and shown immediately.

If a playing stroke is replaced by an edit, playback follows the replacement,
including one with a different number of points; its reveal timing is spread
over the new geometry. If it is erased, playback releases only that stroke and
continues with the rest.

The profile command in [Commands](#commands) records separate timeline
summaries for ordinary animation frames, loop rollover, and forced finish. It
also writes `build/ai_notation_metrics.json` with the existing and animated
ink sizes, animation tick count, completed-layer invalidations, and the peak
cached path-measure count. The near-limit scenario animates 57,344 points over
a 30,000-point page. Run it on an emulator or simulator for repeatable
development comparisons and on physical target tablets for representative
build/raster times; do not treat debug-mode or emulator timing as device
performance.

### Account services and API keys

Production AI uses `BackendAiClient` and the Supabase Edge Functions in
`supabase/`. Follow [the backend deployment guide](supabase/README.md) to create
and configure your project, email-code authentication, store verification,
webhooks, and server secrets.

The app build needs only public Supabase configuration:

```json
{
  "SUPABASE_URL": "https://YOUR_PROJECT_REF.supabase.co",
  "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_REPLACE_ME"
}
```

Put those values in ignored `dart_defines.json` and run:

```sh
flutter run --dart-define-from-file=dart_defines.json
```

AI provider keys, store verification credentials, and the Supabase service-role
key stay on the server. `AiApiConfig.fromEnvironment` no longer reads provider
keys from build defines. Direct provider clients remain available for isolated
tests and explicit dependency injection; the editor uses the backend by default.
Without configured account services, local editing works and paid AI fails closed.

### Models and privacy

The picker offers Haiku, Luna, Sonnet, Sol, Opus, Argon, and Astra for the
answer. The notation/animation model is not user-selectable: the server chooses
it through `AI_NOTATION_MODEL`, defaulting to Luna. Provider model IDs, token
rates, and output limits come from the server's `AI_MODEL_CONFIG`, with an
example in `supabase/model-config.example.json`. Answer models use the
provider/model's default reasoning behavior; the separate notation pass always
uses high reasoning. The client cannot choose an arbitrary provider URL,
notation model, price, or balance.

Each AI request temporarily forwards the current question, at most 12 complete
turns from that selection's conversation, and the selected PNG crop. Older turns
are compacted, the newest two stay detailed, and prior drawing JSON is removed.
Notation also sends numeric page dimensions and crop bounds, so returned marks can
be placed on the page. Full note images and PDFs are never sent to Supabase. No
prompt, image, answer, or conversation is persisted or logged by the backend.
Responses currently arrive in full after server-side accounting.

### Plans and credits

| Plan | Display price | Included models without credit charges | AI credits |
| --- | --- | --- | --- |
| Starter | $6.99/month, $69.99/year | Haiku, Luna | $2.45/month ($29.40/year) for Sonnet & Sol |
| Pro | $14.99/month, $149.99/year | Haiku, Luna | $5.25/month ($63.00/year) for all metered models |
| Max | $24.99/month, $249.99/year | Haiku, Luna | $8.75/month ($105.00/year) for all metered models |

Store products: `com.etonia.app.plan.{699,1499,2499}.{monthly,yearly}` on the
App Store and `etonia_plan_{699,1499,2499}_{monthly,yearly}` on Google Play.
The earlier `499`/`1299`/`2999` products are retired; the database keeps them on
the renamed tiers, with their old allowances, for any subscription already on
them.

Actual localized prices come from the store. Product mappings and allowances
live in the database migration and must match the products configured in Apple
and Google. Store product-ID overrides still use the `IAP_ANDROID_*` and
`IAP_IOS_*` build defines.

Sign in from Plans & Credits before purchasing or restoring. The user UUID is
bound to each purchase. Only verified store transactions grant access or credits;
notifications and live verification maintain renewal, refund, grace-period and
expiry status. Unique transaction records prevent duplicate restore grants.

The server reserves credits before each AI call and settles provider-reported
usage atomically. Client roles cannot edit entitlements or balances. The app
refreshes its display after calls, on resume, and at expiry. `subscription.json`
now stores only the preferred model; local balances and `IAP_DEBUG_PLAN` are
ignored by the production controller. The in-memory/local accounting path remains
for isolated test harnesses. See the backend guide for uncertain-call recovery,
rate limits, and live sandbox validation before release.

The sizes and limits live in `AiLayoutConfig`, `AiImageConfig`, and
`AiNotationConfig`
(`lib/features/editor/ai/ai_config.dart`):

| Value | Default | Meaning |
| --- | --- | --- |
| `panelWidth` | 360 px | width beside the editor, and the widest a sheet gets |
| `minEditorWidth` | 280 px | what a panel beside the editor leaves for the page and palette |
| `sheetMaxWidthFraction` | 0.88 | most of the screen's width a compact sheet takes |
| `previewMaxHeight` | 160 px | tallest the selection preview gets |
| `composerMaxLines` | 4 | lines the message field grows to before it scrolls |
| `padding` | 12 px | background kept around the ink in the image |
| `pixelRatio` | 3 | physical pixels per logical pixel, at most |
| `maxDimension` | 2048 px | longest side of the image (lossless PNG) |
| `maxPngBytes` | 3.5 MB | larger PNGs are redrawn smaller, within the backend's limit |
| `maxOutputTokens` | 16,384 | hard ceiling for unusually detailed answers or drawings |
| `maxLabelRunes` | 80 | longest notation description |
| `maxItems` | 48 | most texts, plots, graphs, paths, and strokes in one response |
| `maxPointsPerStroke` | 128 | most points the model gives one stroke |
| `maxPathPoints` | 64 | most key points in one path |
| `maxTotalPoints` | 4096 | points the model gives over all strokes and paths |
| `maxTextRunes` / `maxTotalTextRunes` | 48 / 400 | characters in one text, and in all |
| `minTextSize` / `maxTextSize` | 8 / 120 px | height of a capital letter |
| `maxFormulaLength` | 160 | longest graph formula |
| `graphSamples` | 240 | points a graph's curve is worked out at |
| `GeneratedInkLimits` | 3000 strokes, 60000 points | most one laid-out notation may add to the note |
| `minWidth` / `maxWidth` | 1 / 20 px | accepted notation stroke widths |
| `minDurationMs` / `maxDurationMs` | 250 / 12000 ms | shortest and longest animation loop |
| `maxSteps` | 24 | highest `step` an animated item may give |
| `stepPauseMs` / `stepFinalHoldMs` | 250 / 600 ms | pause between steps, and hold before the loop repeats |
| `maxPlotChildren` | 16 | most children in one plot |
| `maxPlotMarks` | 8 | most points one mark or intersection labels |
| `plotTextSize` | 12 px | capital height of tick numbers and marked coordinates |

### Known limitations

- The key is embedded in the app; see above.
- With Notation off the assistant sees only selected ink. With Notation on,
  the explicitly submitted request also sends the current note image. No
  handwriting recognition runs locally.
- Answers are rendered as Markdown, with LaTeX formulas typeset
  (`gpt_markdown`). An image an answer links to is shown as `[image]` and
  never fetched. Your own messages are shown as typed.
- Conversations are in memory, for the editor session. Nothing is saved.
- Notation can only append validated strokes while explicitly enabled. It
  cannot edit or delete existing strokes.
- An applied AI notation is one step of undo history; it can also be
  removed with the normal eraser.
- While a request has failed, a new message replaces the unanswered one.
- Between 600 and 639 px wide the panel is narrower than 360 px, so that
  the page keeps room for the selection's action bar.
- Opening the panel beside the editor makes the page narrower, so ink near
  the far edge can be clipped until the panel is closed, as with rotation.

## Changing the application ID

`com.etonia.app` appears in these places (the Kotlin `namespace` and the native
handwriting channel name `com.etonia.app/handwriting_recognizer` must stay in step):

- `android/app/build.gradle.kts`: `namespace` and `applicationId`
- `android/app/src/main/kotlin/com/etonia/app/MainActivity.kt`: the
  `package` line, and the directory path, must match `namespace`
- `ios/Runner.xcodeproj/project.pbxproj`: every `PRODUCT_BUNDLE_IDENTIFIER`
  (the test target uses the same ID with a `.RunnerTests` suffix)

No signing is configured. Release builds currently fall back to the debug
key; add your own signing config before distributing, and never commit
keystores or provisioning profiles.

## Troubleshooting

Start with `fvm flutter doctor -v`.

- **Android licenses not accepted**: run
  `fvm flutter doctor --android-licenses` and accept each one.
- **No devices listed**: run `fvm flutter devices` and
  `fvm flutter emulators`. Start an emulator, or for a physical Android
  device enable USB debugging and confirm it appears in `adb devices`.
- **CocoaPods errors (macOS)**: run `pod --version` to confirm the install,
  then `cd ios && pod repo update && pod install`. If that fails, delete
  `ios/Pods` and `ios/Podfile.lock` and retry.
- **Incompatible Java version**: Gradle needs JDK 17 or newer. Check with
  `java -version`; point Flutter at the right one with
  `fvm flutter config --jdk-dir <path-to-jdk>`.
- **Stale build output**: `fvm flutter clean && fvm flutter pub get`.

## Document import and PDF export

Imported files are private note assets under `notes/<note-id>.assets/`, with
an atomic manifest next to the asset data. A PDF import stores one PDF asset
and has every imported page refer to it by asset id and zero-based page
index. Images are stored as normalized PNG or JPEG assets. They retain their
insertion order below every ink stroke; erasers affect ink only, so Cut is
the way to remove an image.

PDF-backed pages take their fixed size from the rotated PDF crop box. Adding
a normal page after one records the same dimensions as `PageSize.custom` plus
`PageSetup.customSize`; it does not duplicate the PDF source. Screen PDF
renders are lazy, capped, and held in a three-entry decoded-image LRU. Export
rasterizes imported PDF paper at 200 dpi, so original PDF text has no text
cursor or text search; the Select tool can instead copy a lassoed PDF region
as a bitmap image. Image-heavy imports can make larger exports. Images and
PDF paper remain raster content, while ink and paper rules are vector paths.
Pages above the PDF 14,400-point side limit are uniformly reduced.

The Goodnotes import option recovers editable ink from supported Android
exports. It keeps raster rows aligned with the page, smooths traced pixel
staircases while retaining endpoints and closed loops, and removes the
separate recognized “Made with Goodnotes” badge. This applies when importing
the file again; previously imported strokes are not reprocessed. Dense image
regions and connected multicolored artwork remain in the PDF background.
The flattened overlay has no text labels: handwriting and monochrome line
drawings still become ink, without OCR or reliable text-versus-drawing
classification.

Recovered ink also carries a width profile sampled along the trace, so
pressure-sensitive strokes retain thin ends and thick middles after saving
and exporting. A separate width control removes isolated spikes and limits
thickness changes to 0.35 pixels per pixel along the trace, in both directions
and across closed-loop seams. Pencil recovery repairs small grain holes and edge notches
within each connected mark before tracing, prunes short spurs, and estimates
average opacity. It approximates the pencil with smooth editable ink; it does
not reproduce the original brush texture or reconstruct missing pressure
samples. Ambiguous networks remain in the PDF background.

The export dialog is modal, making the editor read-only while export runs
from an immutable `NoteContent` snapshot. Cancelling removes any partial
temporary file. Old exports in the app's temporary export directory are
removed before a new one is written.

The PDF LRU owns decoded `ui.Image` instances, gives visible page layers
caller-owned clones, and disposes both on eviction or when the layer leaves
the viewport. When only a page's displayed size changes, as when the AI
panel opens or closes beside the page, the layer keeps showing its current
bitmap, stretched, until the render at the new size arrives; the progress
indicator shows only for a page with nothing to show yet. The page column
keeps the same place of the same page in the middle of the area across such
resizes, rather than keeping a pixel offset that would land on another page
once every page is rescaled. Placed images request a decode close to their displayed pixel
size through Flutter's shared image cache. Note duplication copies assets
before writing referring content; note/folder deletion removes them. Cleanup
runs only on editor open/close and preserves assets referenced by the in-app
clipboard. Copy/Cut snapshots image bytes, so a cross-note paste stores a new
asset in the destination even after the source image was cut.

`DocumentIoConfig` centralizes the settings; imports have no size or page
limit:

| Value | Default |
| --- | ---: |
| `maxStoredImageDimension` | 4096 px |
| `insertedImageMaxFraction` | 0.6 |
| `maxPdfRenderDimension` | 4096 px |
| `pdfRenderCacheSize` | 3 pages |
| `exportPdfRasterDpi` | 200 dpi |
| `maxPdfPagePoints` | 14,400 pt |
