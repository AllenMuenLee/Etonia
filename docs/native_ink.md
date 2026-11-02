# Native ink bridge

The editor UI and document model remain Flutter. Android and iOS observe only
active-stylus input before Flutter's pointer pipeline, render a temporary native
preview, and send full-rate actual samples to the existing `InkController`.

## Data flow

1. Each visible `InkCanvas` registers its size, screen transform, current pen
   color/width, pressure setting, writing style, and stabilization value
   through `NativeInkBridge`.
2. Native code hit-tests a pen-down against those registered surfaces. Finger
   input is not consumed and continues to drive Flutter scrolling and zoom.
3. Android sends all `MotionEvent` historical samples. iOS sends UIKit
   coalesced Pencil touches. A flat `x, y, timestamp, pressure` array keeps the
   platform-channel payload small.
4. A native overlay immediately previews opaque pen ink, drawn by a port of
   Flutter's pen model (see Preview rendering). Jetpack Ink renders it on
   Android; shape layers render it on iOS. Predicted samples are never sent to
   Dart.
5. Dart feeds actual batches into the same stroke, erase, smoothing,
   hold-to-shape, and persistence code used by the Flutter fallback.
6. On up, native code retains the finished wet stroke while Dart commits the
   canonical stroke. Flutter removes the native preview only when the third
   frame after the commit frame begins. The engine queues at most two built
   frames for the raster thread and frees a slot only once one is rasterized,
   so by then the commit frame has been drawn (however long a long stroke kept
   the raster thread busy) and the display has had a vsync to show it.
   Removing it at the next frame instead flashed bare paper after long
   strokes. Cancel and rejected gestures clear immediately.

If the native channel is absent, registration fails quietly and `InkCanvas`
keeps using Flutter pointer events. This is the expected path for desktop, web,
and widget tests.

## Platform files

- `android/app/src/main/kotlin/com/etonia/app/NativeInkChannel.kt`
- `ios/Runner/NativeInkChannel.swift`
- `lib/features/editor/ink/native_ink_bridge.dart`

## Device validation

Use a physical S Pen/USI tablet and iPad with Apple Pencil; emulators do not
reproduce hardware sampling or display latency. Verify pen dots, fast curves,
pressure, palm contact, lift outside the page, zoomed pages, hold-to-shape, and
eraser-end input on Android. Use profile/release mode because debug mode adds
JIT and diagnostics overhead.

The native overlay currently previews opaque pen and pencil strokes.
Highlighter strokes still receive full-rate native samples, but use Flutter
rendering so their transparency is not compounded by two layers. Android also
calls `requestUnbufferedDispatch`.

## Preview rendering

The wet ink must be the stroke Flutter commits, or the line visibly shifts
when the pen lifts. Both platforms therefore run a port of Flutter's pen
model over the same samples they send to Dart, rather than a platform brush:

- the One Euro smoother, with the exact `SmoothingConfig` the stroke uses
  (stabilization applied by `PenSettings.smoothing` in Dart and sent with the
  surface, so the mapping lives in one place);
- the eased pressure reading and its width factor (pressure sensitivity);
- the tapered start while drawing, and on lift the finishing tail and both
  ends tapered over at most 40% of the stroke (tip sharpness);
- the quadratic midpoint curve, flattened to 1/8 px as `buildInkOutline`
  does, and a dot drawn at full width.

On lift the native layer swaps to that finished geometry, so the hand-off to
Flutter's committed stroke shows no change.

- **Android** (`NativeInkModel.kt`) feeds the model's points to Jetpack Ink's
  `InProgressStrokesView` as `StrokeInput`s in canvas pixels, with a
  stroke-to-view matrix for the page's zoom. Each point's width factor rides
  in the pressure channel, and the brush maps pressure linearly to 0-2× its
  size, using Jetpack Ink's pass-through input model. Settled points are real
  inputs. The straight run to the newest point and the `MotionEventPredictor`
  guesses (filtered by a copy of the smoother) are prediction. The view is
  eagerly initialized so loading native Ink code does not hitch the first
  stroke.
- **iOS** (bottom of `NativeInkChannel.swift`) draws the same outline,
  a disc per end and sharp turn joined by quadrilaterals, into
  `CAShapeLayer`s. Settled stretches of 64 points are frozen into their own
  layers so each touch redraws only the newest stretch. UIKit's predicted
  touches extend the live tail. PencilKit is no longer used: its pen cannot
  express Flutter's pressure, taper, or stabilization.

`test/fixtures/native_ink_parity.txt` holds Flutter's output for strokes
across the advanced settings. `native_ink_parity_test.dart` fails when the
Dart model drifts from it, and `NativeInkModelTest` (run with
`gradlew :app:testDebugUnitTest`) checks the Kotlin port against it. Port any
pen-model change to both native files, then regenerate the fixture with
`UPDATE_NATIVE_INK_FIXTURE=1`.

The native preview is only the latency-critical wet layer. Actual coalesced
samples still feed the shared Dart document model so files, undo, selection,
shape recognition, and cross-platform rendering keep one representation.
Finished Flutter ink uses continuously tangent quadratic paths (and adaptively
flattened variable-width outlines) rather than exposing its sampled polyline at
high zoom.

## Platform references

- [Android Ink API: draw a stroke](https://developer.android.com/develop/ui/views/touch-and-input/stylus-input/ink-api-draw-stroke)
  documents `InProgressStrokesView`, `MotionEventPredictor`, world transforms,
  and retaining finished wet strokes until the client commits them.
- [Apple: Getting high-fidelity input with coalesced touches](https://developer.apple.com/documentation/uikit/getting-high-fidelity-input-with-coalesced-touches)
  documents the Pencil sample stream used for the canonical Dart stroke.
- [Apple: Minimizing latency with predicted touches](https://developer.apple.com/documentation/uikit/minimizing-latency-with-predicted-touches)
  documents the predicted touches that extend the iOS wet ink.
- [Flutter `addPostFrameCallback`](https://api.flutter.dev/flutter/scheduler/SchedulerBinding/addPostFrameCallback.html)
  defines the rendering-pipeline boundary used by the handoff.
